// Native DuckDB SCD2 follows dbt Core 1.10.5 global snapshot strategies/helpers
// and dbt-duckdb 1.9.6 snapshot update/insert materialization. Each node is atomic.
const std = @import("std");
const compiler = @import("compiler.zig");
const duckdb = @import("duckdb.zig");
const snapshot = @import("snapshot.zig");
const types = @import("types.zig");

const Column = struct { name: []const u8, data_type: []const u8 };
const Columns = std.ArrayList(Column);
const Runtime = types.Runtime;
const Graph = types.Graph;
const Node = types.Node;

pub fn validateExecution(graph: *const Graph, node: *const Node) !void {
    if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedSnapshotAdapter;
    if (!std.mem.eql(u8, node.resource_type, "snapshot") or node.snapshot_config == null) return error.InvalidSnapshotConfig;
    try snapshot.validateConfig(node);
}

pub fn execute(runtime: Runtime, db_path: []const u8, graph: *const Graph, node: *const Node) !void {
    try validateExecution(graph, node);
    const allocator = runtime.allocator;
    const query = node.compiled_code orelse return error.InvalidSnapshotConfig;
    const relation = try compiler.relationNameForNode(allocator, graph, node);
    defer allocator.free(relation);
    const describe_sql = try std.fmt.allocPrint(allocator, "describe select * from (\n{s}\n) dxt_snapshot_query", .{trimQuery(query)});
    defer allocator.free(describe_sql);
    var source_columns = try describe(runtime, db_path, describe_sql);
    defer deinitColumns(allocator, &source_columns);
    var target_columns = try targetColumns(runtime, db_path, graph, node);
    defer deinitColumns(allocator, &target_columns);
    const sql = try renderExecutionSql(allocator, graph, node, source_columns.items, target_columns.items);
    defer allocator.free(sql);
    // Source staging, schema changes, validity updates and new records share one transaction.
    try duckdb.executeSql(runtime, db_path, sql);
}

fn queryJson(runtime: Runtime, db_path: []const u8, sql: []const u8) ![]const u8 {
    const result = std.process.run(runtime.allocator, runtime.io, .{
        .argv = &.{ "duckdb", db_path, "-json", "-batch", "-bail", "-c", sql },
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.DuckDbCliNotFound,
        else => return err,
    };
    defer runtime.allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    runtime.allocator.free(result.stdout);
    return error.DuckDbExecutionFailed;
}

fn describe(runtime: Runtime, db_path: []const u8, sql: []const u8) !Columns {
    const text = try queryJson(runtime, db_path, sql);
    defer runtime.allocator.free(text);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return .empty;
    var parsed = try std.json.parseFromSlice(std.json.Value, runtime.allocator, text, .{});
    defer parsed.deinit();
    var columns: Columns = .empty;
    errdefer deinitColumns(runtime.allocator, &columns);
    if (parsed.value != .array) return error.DuckDbExecutionFailed;
    for (parsed.value.array.items) |row| {
        if (row != .object) return error.DuckDbExecutionFailed;
        const name = row.object.get("column_name") orelse return error.DuckDbExecutionFailed;
        const data_type = row.object.get("column_type") orelse return error.DuckDbExecutionFailed;
        if (name != .string or data_type != .string) return error.DuckDbExecutionFailed;
        try columns.append(runtime.allocator, .{ .name = try runtime.allocator.dupe(u8, name.string), .data_type = try runtime.allocator.dupe(u8, data_type.string) });
    }
    return columns;
}

fn targetColumns(runtime: Runtime, db_path: []const u8, graph: *const Graph, node: *const Node) !Columns {
    const schema = try compiler.relationSchemaForNode(runtime.allocator, graph, node);
    defer runtime.allocator.free(schema);
    const sql = try std.fmt.allocPrint(
        runtime.allocator,
        "select column_name, data_type as column_type from information_schema.columns where table_catalog = {s} and table_schema = {s} and table_name = {s} order by ordinal_position",
        .{ try sqlString(runtime.allocator, compiler.relationDatabaseForNode(graph, node) orelse "memory"), try sqlString(runtime.allocator, schema), try sqlString(runtime.allocator, compiler.relationIdentifierForNode(node)) },
    );
    defer runtime.allocator.free(sql);
    return describe(runtime, db_path, sql);
}

fn deinitColumns(allocator: std.mem.Allocator, columns: *Columns) void {
    for (columns.items) |column| {
        allocator.free(column.name);
        allocator.free(column.data_type);
    }
    columns.deinit(allocator);
}

fn findColumn(columns: []const Column, name: []const u8) ?Column {
    for (columns) |column| if (std.mem.eql(u8, column.name, name)) return column;
    return null;
}

fn trimQuery(query: []const u8) []const u8 {
    return duckdb.trimTrailingSqlTerminator(query);
}

fn sqlString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (text) |byte| {
        try out.append(allocator, byte);
        if (byte == '\'') try out.append(allocator, byte);
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

fn keyCount(config: types.SnapshotConfig) usize {
    return switch (config.unique_key.?) {
        .string => 1,
        .list => |list| list.items.len,
    };
}

fn keyAt(config: types.SnapshotConfig, index: usize) []const u8 {
    return switch (config.unique_key.?) {
        .string => |value| value,
        .list => |list| list.items[index],
    };
}

fn hardDeletes(config: types.SnapshotConfig) []const u8 {
    return config.hard_deletes orelse if (config.invalidate_hard_deletes orelse false) "invalidate" else "ignore";
}

fn writeHash(writer: *std.Io.Writer, config: types.SnapshotConfig, updated_at: []const u8) !void {
    try writer.writeAll("md5(");
    for (0..keyCount(config)) |index| {
        const expression = keyAt(config, index);
        try writer.print("coalesce(cast(({s}) as varchar), '') || '|' || ", .{expression});
    }
    try writer.print("coalesce(cast(({s}) as varchar), ''))", .{updated_at});
}

fn writeKeyFields(writer: *std.Io.Writer, config: types.SnapshotConfig) !void {
    for (0..keyCount(config)) |index| try writer.print(", ({s}) as __dxt_snapshot_key_{d}", .{ keyAt(config, index), index });
}

fn writeKeyJoin(writer: *std.Io.Writer, config: types.SnapshotConfig, left: []const u8, right: []const u8) !void {
    const is_list = config.unique_key.? == .list;
    for (0..keyCount(config)) |index| {
        if (index != 0) try writer.writeAll(" and ");
        try writer.print("{s}.__dxt_snapshot_key_{d} {s} {s}.__dxt_snapshot_key_{d}", .{ left, index, if (is_list) "is not distinct from" else "=", right, index });
    }
}

fn writeChanged(writer: *std.Io.Writer, allocator: std.mem.Allocator, config: types.SnapshotConfig, source_columns: []const Column, target_columns: []const Column, valid_from: []const u8, deleted: []const u8) !void {
    if (std.mem.eql(u8, config.strategy.?, "timestamp")) {
        try writer.print("t.{s} < s.__dxt_snapshot_updated_at", .{valid_from});
    } else {
        var checked: std.ArrayList([]const u8) = .empty;
        defer checked.deinit(allocator);
        switch (config.check_cols.?) {
            .string => for (source_columns) |column| try checked.append(allocator, column.name),
            .list => |list| try checked.appendSlice(allocator, list.items),
        }
        for (checked.items) |name| {
            if (findColumn(source_columns, name) == null) return error.DuckDbExecutionFailed;
            if (findColumn(target_columns, name) == null) {
                try writer.writeAll("true");
                break;
            }
        } else {
            for (checked.items, 0..) |name, index| {
                if (index != 0) try writer.writeAll(" or ");
                const quoted = try compiler.quoteIdentifier(allocator, name);
                defer allocator.free(quoted);
                try writer.print("t.{s} is distinct from s.{s}", .{ quoted, quoted });
            }
        }
    }
    if (std.mem.eql(u8, hardDeletes(config), "new_record")) try writer.print(" or t.{s} = 'True'", .{deleted});
}

pub fn renderExecutionSql(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node, source_columns: []const Column, target_columns: []const Column) ![]const u8 {
    const config = node.snapshot_config.?;
    const names = config.meta_columns;
    const scd_id = try compiler.quoteIdentifier(allocator, names.dbt_scd_id);
    const updated = try compiler.quoteIdentifier(allocator, names.dbt_updated_at);
    const valid_from = try compiler.quoteIdentifier(allocator, names.dbt_valid_from);
    const valid_to = try compiler.quoteIdentifier(allocator, names.dbt_valid_to);
    const deleted = try compiler.quoteIdentifier(allocator, names.dbt_is_deleted);
    const relation = try compiler.relationNameForNode(allocator, graph, node);
    const schema = try compiler.relationSchemaForNode(allocator, graph, node);
    const namespace = if (compiler.relationDatabaseForNode(graph, node)) |database|
        try std.fmt.allocPrint(allocator, "{s}.{s}", .{ try compiler.quoteIdentifier(allocator, database), try compiler.quoteIdentifier(allocator, schema) })
    else
        try compiler.quoteIdentifier(allocator, schema);
    const updated_at = config.updated_at orelse "current_timestamp::timestamp";
    const current = config.dbt_valid_to_current orelse "null";
    const new_record = std.mem.eql(u8, hardDeletes(config), "new_record");
    for (source_columns) |column| {
        if (std.mem.eql(u8, column.name, names.dbt_scd_id) or std.mem.eql(u8, column.name, names.dbt_updated_at) or std.mem.eql(u8, column.name, names.dbt_valid_from) or std.mem.eql(u8, column.name, names.dbt_valid_to) or (new_record and std.mem.eql(u8, column.name, names.dbt_is_deleted)) or std.mem.startsWith(u8, column.name, "__dxt_snapshot_")) return error.DuckDbExecutionFailed;
    }
    if (target_columns.len != 0) {
        for ([_][]const u8{ names.dbt_scd_id, names.dbt_updated_at, names.dbt_valid_from, names.dbt_valid_to }) |name| if (findColumn(target_columns, name) == null) return error.DuckDbExecutionFailed;
        if (new_record and findColumn(target_columns, names.dbt_is_deleted) == null) return error.DuckDbExecutionFailed;
    }
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("begin transaction;\ncreate temporary table __dxt_snapshot_source as select q.*");
    try writeKeyFields(writer, config);
    try writer.print(", ({s}) as __dxt_snapshot_updated_at, ", .{updated_at});
    try writeHash(writer, config, updated_at);
    try writer.print(" as __dxt_snapshot_scd_id from (\n{s}\n) q;\ncreate schema if not exists {s};\n", .{ trimQuery(node.compiled_code.?), namespace });
    if (target_columns.len == 0) {
        try writer.print("create table {s} as select ", .{relation});
        try writeSourceColumns(writer, allocator, source_columns, "s");
        try writer.print(", __dxt_snapshot_scd_id as {s}, __dxt_snapshot_updated_at as {s}, __dxt_snapshot_updated_at as {s}, coalesce(nullif(__dxt_snapshot_updated_at,__dxt_snapshot_updated_at), {s}) as {s}", .{ scd_id, updated, valid_from, current, valid_to });
        if (new_record) try writer.print(", 'False' as {s}", .{deleted});
        try writer.writeAll(" from __dxt_snapshot_source s;\ncommit;\n");
        return out.toOwnedSlice();
    }
    try writer.print("create temporary table __dxt_snapshot_target as select t.*", .{});
    try writeKeyFields(writer, config);
    try writer.print(" from {s} t where {s} is null", .{ relation, valid_to });
    if (config.dbt_valid_to_current != null) try writer.print(" or {s} = ({s})", .{ valid_to, current });
    try writer.writeAll(";\n");
    for (source_columns) |column| {
        if (findColumn(target_columns, column.name) == null) {
            try writer.print("alter table {s} add column {s} {s};\n", .{ relation, try compiler.quoteIdentifier(allocator, column.name), column.data_type });
        }
    }
    try writer.writeAll("create temporary table __dxt_snapshot_changes as select s.*, case when (");
    try writeChanged(writer, allocator, config, source_columns, target_columns, valid_from, deleted);
    try writer.print(") then t.{s} end as __dxt_snapshot_old_id from __dxt_snapshot_source s left join __dxt_snapshot_target t on ", .{scd_id});
    try writeKeyJoin(writer, config, "t", "s");
    try writer.writeAll(" where t.__dxt_snapshot_key_0 is null or (");
    try writeChanged(writer, allocator, config, source_columns, target_columns, valid_from, deleted);
    try writer.writeAll(");\n");
    try writer.print("update {s} as d set {s} = c.__dxt_snapshot_updated_at from __dxt_snapshot_changes c where d.{s} = c.__dxt_snapshot_old_id and (d.{s} is null", .{ relation, valid_to, scd_id, valid_to });
    if (config.dbt_valid_to_current != null) try writer.print(" or d.{s} = ({s})", .{ valid_to, current });
    try writer.writeAll(");\n");
    if (!std.mem.eql(u8, hardDeletes(config), "ignore")) {
        try writer.print("create temporary table __dxt_snapshot_deletes as select t.* from __dxt_snapshot_target t left join __dxt_snapshot_source s on ", .{});
        try writeKeyJoin(writer, config, "t", "s");
        try writer.writeAll(" where s.__dxt_snapshot_key_0 is null");
        if (new_record) try writer.print(" and not (t.{s} = 'True' and t.{s} is null)", .{ deleted, valid_to });
        try writer.print(";\nupdate {s} d set {s} = current_timestamp::timestamp from __dxt_snapshot_deletes t where d.{s} = t.{s} and (d.{s} is null", .{ relation, valid_to, scd_id, scd_id, valid_to });
        if (config.dbt_valid_to_current != null) try writer.print(" or d.{s} = ({s})", .{ valid_to, current });
        try writer.writeAll(");\n");
        if (new_record) {
            try writeInsertColumns(writer, allocator, relation, source_columns, names, true);
            try writer.writeAll("select ");
            for (source_columns, 0..) |column, index| {
                if (index != 0) try writer.writeAll(", ");
                if (findColumn(target_columns, column.name) == null) try writer.print("null as {s}", .{try compiler.quoteIdentifier(allocator, column.name)}) else try writer.print("t.{s}", .{try compiler.quoteIdentifier(allocator, column.name)});
            }
            try writer.print(", md5(coalesce(cast(t.{s} as varchar),'') || '|' || cast(current_timestamp::timestamp as varchar)), current_timestamp::timestamp, current_timestamp::timestamp, t.{s}, 'True' from __dxt_snapshot_deletes t;\n", .{ scd_id, valid_to });
        }
    }
    try writeInsertColumns(writer, allocator, relation, source_columns, names, new_record);
    try writer.writeAll("select ");
    try writeSourceColumns(writer, allocator, source_columns, "s");
    try writer.print(", __dxt_snapshot_scd_id, __dxt_snapshot_updated_at, __dxt_snapshot_updated_at, coalesce(nullif(__dxt_snapshot_updated_at,__dxt_snapshot_updated_at), {s})", .{current});
    if (new_record) try writer.writeAll(", 'False'");
    try writer.writeAll(" from __dxt_snapshot_changes s;\ncommit;\n");
    return out.toOwnedSlice();
}

fn writeSourceColumns(writer: *std.Io.Writer, allocator: std.mem.Allocator, columns: []const Column, alias: []const u8) !void {
    for (columns, 0..) |column, index| {
        if (index != 0) try writer.writeAll(", ");
        if (alias.len != 0) try writer.print("{s}.", .{alias});
        try writer.writeAll(try compiler.quoteIdentifier(allocator, column.name));
    }
}

fn writeInsertColumns(writer: *std.Io.Writer, allocator: std.mem.Allocator, relation: []const u8, columns: []const Column, names: types.SnapshotMetaColumns, deleted: bool) !void {
    try writer.print("insert into {s} (", .{relation});
    try writeSourceColumns(writer, allocator, columns, "");
    for ([_][]const u8{ names.dbt_scd_id, names.dbt_updated_at, names.dbt_valid_from, names.dbt_valid_to }) |name| try writer.print(", {s}", .{try compiler.quoteIdentifier(allocator, name)});
    if (deleted) try writer.print(", {s}", .{try compiler.quoteIdentifier(allocator, names.dbt_is_deleted)});
    try writer.writeAll(") ");
}

test "snapshot SCD staging validates metadata and retains scalar versus composite null joins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo", .database_path = "warehouse.duckdb" };
    var node = Node{ .resource_type = "snapshot", .package_name = "demo", .unique_id = "snapshot.demo.history", .name = "history", .path = "history.sql", .original_file_path = "snapshots/history.sql", .raw_code = "select * from input", .compiled_code = "select * from input; -- note\n", .materialized = "snapshot", .snapshot_config = .{ .strategy = "timestamp", .unique_key = .{ .string = "id" }, .updated_at = "ts", .hard_deletes = "new_record" } };
    const source = [_]Column{ .{ .name = "id", .data_type = "INTEGER" }, .{ .name = "ts", .data_type = "TIMESTAMP" } };
    const target = source ++ [_]Column{ .{ .name = "dbt_scd_id", .data_type = "VARCHAR" }, .{ .name = "dbt_updated_at", .data_type = "TIMESTAMP" }, .{ .name = "dbt_valid_from", .data_type = "TIMESTAMP" }, .{ .name = "dbt_valid_to", .data_type = "TIMESTAMP" }, .{ .name = "dbt_is_deleted", .data_type = "VARCHAR" } };
    try validateExecution(&graph, &node);
    try std.testing.expectError(error.DuckDbExecutionFailed, renderExecutionSql(allocator, &graph, &node, &source, &source));
    try std.testing.expectError(error.DuckDbExecutionFailed, renderExecutionSql(allocator, &graph, &node, &target, &.{}));
    const sql = try renderExecutionSql(allocator, &graph, &node, &source, &target);
    try std.testing.expect(std.mem.startsWith(u8, sql, "begin transaction;"));
    try std.testing.expect(std.mem.endsWith(u8, sql, "commit;\n"));
    try std.testing.expect(std.mem.indexOf(u8, sql, "t.__dxt_snapshot_key_0 = s.__dxt_snapshot_key_0") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "'True' from __dxt_snapshot_deletes") != null);
    var keys: std.ArrayList([]const u8) = .empty;
    try keys.appendSlice(allocator, &.{ "id", "ts" });
    node.snapshot_config.?.unique_key = .{ .list = keys };
    const composite = try renderExecutionSql(allocator, &graph, &node, &source, &target);
    try std.testing.expect(std.mem.indexOf(u8, composite, "t.__dxt_snapshot_key_1 is not distinct from s.__dxt_snapshot_key_1") != null);
    graph.adapter_type = "postgres";
    try std.testing.expectError(error.UnsupportedSnapshotAdapter, validateExecution(&graph, &node));
}
