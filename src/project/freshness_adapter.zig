const std = @import("std");
const types = @import("types.zig");
const adapter = @import("adapter.zig");
const duckdb = @import("duckdb.zig");
const compiler = @import("compiler.zig");

/// Reuses the scheduler's held adapter session. The caller owns transaction and
/// cancellation policy; results have the same ownership as DuckDB freshness.
pub fn querySourceFreshness(runtime: types.Runtime, graph: *const types.Graph, db_path: []const u8, source: *const types.SourceDef) !duckdb.FreshnessQueryResult {
    const sql = try renderSql(runtime.allocator, graph.adapter_type, source);
    defer runtime.allocator.free(sql);
    var result = try adapter.queryForGraph(runtime, graph, db_path, sql);
    defer result.deinit(runtime.allocator);
    if (result.rows.len != 1 or result.columns.len != 3) return error.InvalidSourceFreshnessResult;
    const row = result.rows[0];
    const maximum = row[0] orelse return error.InvalidSourceFreshnessResult;
    const snapshot = row[1] orelse return error.InvalidSourceFreshnessResult;
    const age = try std.fmt.parseFloat(f64, row[2] orelse return error.InvalidSourceFreshnessResult);
    if (!std.math.isFinite(age)) return error.InvalidSourceFreshnessResult;
    const owned_maximum = try runtime.allocator.dupe(u8, maximum);
    errdefer runtime.allocator.free(owned_maximum);
    return .{ .max_loaded_at = owned_maximum, .snapshotted_at = try runtime.allocator.dupe(u8, snapshot), .age_seconds = age };
}

pub fn renderSql(allocator: std.mem.Allocator, adapter_type: []const u8, source: *const types.SourceDef) ![]const u8 {
    if (std.mem.eql(u8, adapter_type, "duckdb")) return duckdb.renderSourceFreshnessSql(allocator, source);
    if (!std.mem.eql(u8, adapter_type, "postgres")) return error.UnsupportedSourceFreshnessAdapter;
    var source_sql: []const u8 = undefined;
    if (source.loaded_at_query) |query| {
        const trimmed = duckdb.trimTrailingSqlTerminator(query);
        if (trimmed.len == 0) return error.UnsupportedSourceFreshness;
        source_sql = try std.fmt.allocPrint(allocator, "select (select * from ({s}) source_query) as max_loaded_at, current_timestamp as snapshotted_at", .{trimmed});
    } else {
        const field = source.loaded_at_field orelse return error.UnsupportedSourceFreshness;
        if (std.mem.trim(u8, field, " \t\r\n").len == 0) return error.UnsupportedSourceFreshness;
        const relation = try compiler.relationNameForSource(allocator, source);
        defer allocator.free(relation);
        const filter = if (source.freshness) |threshold| threshold.filter else null;
        source_sql = if (filter) |where|
            try std.fmt.allocPrint(allocator, "select max({s}) as max_loaded_at, current_timestamp as snapshotted_at from {s} where {s}", .{ field, relation, where })
        else
            try std.fmt.allocPrint(allocator, "select max({s}) as max_loaded_at, current_timestamp as snapshotted_at from {s}", .{ field, relation });
    }
    defer allocator.free(source_sql);
    return try std.fmt.allocPrint(
        allocator,
        "with freshness as ({s}) select coalesce(to_char(max_loaded_at at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'), '0001-01-01T00:00:00Z') as max_loaded_at, to_char(snapshotted_at at time zone 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') as snapshotted_at, coalesce(extract(epoch from (snapshotted_at - max_loaded_at)), 9.223372036854776e18) as age_seconds from freshness;",
        .{source_sql},
    );
}

test "Postgres freshness renders one source query with UTC timestamps and numeric age" {
    const allocator = std.testing.allocator;
    const source = types.SourceDef{ .package_name = "demo", .unique_id = "source.demo.raw.events", .source_name = "raw", .table_name = "events", .original_file_path = "sources.yml", .database = "warehouse", .schema_name = "landing", .loaded_at_field = "loaded_at", .freshness = .{ .filter = "active" } };
    const sql = try renderSql(allocator, "postgres", &source);
    defer allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "from \"warehouse\".\"landing\".\"events\" where active") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "extract(epoch from (snapshotted_at - max_loaded_at))") != null);
    var custom = source;
    custom.loaded_at_query = "select max(loaded_at) from audit;";
    const query_sql = try renderSql(allocator, "postgres", &custom);
    defer allocator.free(query_sql);
    try std.testing.expect(std.mem.indexOf(u8, query_sql, "from (select max(loaded_at) from audit) source_query") != null);
}
