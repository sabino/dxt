//! Core seeds/helpers.sql: existing views fail; normal runs truncate/reload;
//! full-refresh recreates the table using native CSV inference and overrides.
const std = @import("std");
const types = @import("types.zig");
const adapter = @import("adapter.zig");
const compiler = @import("compiler.zig");
const csv = @import("seed_csv.zig");
const values = @import("config_value.zig");

pub fn execute(runtime: types.Runtime, graph: *const types.Graph, path: []const u8, node: *const types.Node) !void {
    return executeWithPolicy(runtime, graph, path, node, .{});
}

pub fn executeWithPolicy(runtime: types.Runtime, graph: *const types.Graph, path: []const u8, node: *const types.Node, policy: @import("postgres_materialization.zig").ExecutionPolicy) !void {
    if (!policy.manage_transaction and runtime.adapter_session == null) return error.NativeAdapterSessionRequired;
    var owned: ?adapter.Session = null;
    defer if (owned) |*session| session.deinit();
    const session = runtime.adapter_session orelse blk: {
        owned = try adapter.openSession(runtime, graph, path);
        break :blk &owned.?;
    };
    const a = runtime.allocator;
    const schema = try compiler.relationSchemaForNode(a, graph, node);
    defer a.free(schema);
    const identifier = compiler.relationIdentifierForNode(node);
    const quoted_schema = try adapter.quoteIdentifier(a, schema);
    defer a.free(quoted_schema);
    const relation = try compiler.relationNameForNode(a, graph, node);
    defer a.free(relation);
    const schema_lit = try adapter.quoteLiteral(a, schema);
    defer a.free(schema_lit);
    const identifier_lit = try adapter.quoteLiteral(a, identifier);
    defer a.free(identifier_lit);
    const lookup = try std.fmt.allocPrint(a, "select table_type from information_schema.tables where table_schema={s} and table_name={s}", .{ schema_lit, identifier_lit });
    defer a.free(lookup);
    var existing = try session.query(lookup);
    defer existing.deinit(a);
    const old_kind = existing.firstScalar();
    if (old_kind) |kind| if (std.mem.eql(u8, kind, "VIEW")) return error.CannotSeedView;
    var full_refresh = graph.command_options.full_refresh or graph.full_refresh;
    if (values.get(node.effective_config, "full_refresh")) |flag| if (flag == .bool) {
        full_refresh = flag.bool;
    };
    const create = old_kind == null or full_refresh;
    const sql = if (create) try csv.renderSql(a, graph, node) else try csv.renderInsertSql(a, graph, node);
    defer a.free(sql);
    if (policy.manage_transaction) try session.begin();
    errdefer if (policy.manage_transaction) session.rollback() catch {};
    if (old_kind != null) {
        const reset = try std.fmt.allocPrint(a, "{s} {s}{s}", .{ if (full_refresh) "drop table" else if (std.mem.eql(u8, graph.adapter_type, "postgres")) "truncate table" else "delete from", relation, if (full_refresh and std.mem.eql(u8, graph.adapter_type, "postgres")) " cascade" else "" });
        defer a.free(reset);
        try session.execute(reset);
    }
    try session.execute(sql);
    if (policy.manage_transaction) try session.commit();
}
