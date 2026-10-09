//! Native PostgreSQL incremental strategies from the pinned Core macros.
const std = @import("std");
const adapter = @import("adapter.zig");
const compiler = @import("compiler.zig");
const values = @import("config_value.zig");
const config = @import("incremental_config.zig");
const materialization = @import("postgres_materialization.zig");
const types = @import("types.zig");
pub const Column = @import("incremental.zig").Column;
pub const ExecutionPolicy = materialization.ExecutionPolicy;

pub fn executeWithPolicy(runtime: types.Runtime, graph: *const types.Graph, node: *const types.Node, policy: ExecutionPolicy) !void {
    try config.validateForAdapter("postgres", node.incremental);
    if (!policy.manage_transaction and runtime.adapter_session == null) return error.NativeAdapterSessionRequired;
    var owned: ?adapter.Session = null;
    defer if (owned) |*session| session.deinit();
    const session = runtime.adapter_session orelse blk: {
        owned = try adapter.openSession(runtime, graph, ":memory:");
        break :blk &owned.?;
    };
    if (policy.manage_transaction) try session.begin();
    errdefer if (policy.manage_transaction) session.rollback() catch {};
    const schema = try compiler.relationSchemaForNode(runtime.allocator, graph, node);
    defer runtime.allocator.free(schema);
    const kind = try session.relationTypeInDatabase(runtime.allocator, compiler.relationDatabaseForNode(graph, node), schema, compiler.relationIdentifierForNode(node));
    defer if (kind) |value| runtime.allocator.free(value);
    if (kind == null or std.mem.eql(u8, kind.?, "view") or config.fullRefresh(graph, node)) {
        var table = node.*;
        table.materialized = "table";
        var held_runtime = runtime;
        held_runtime.adapter_session = session;
        var creation_policy = policy;
        creation_policy.manage_transaction = false;
        try materialization.executeWithPolicy(held_runtime, graph, &table, trimmedSql(node), creation_policy);
    } else {
        if (!std.mem.eql(u8, kind.?, "table")) return error.PostgresExecutionFailed;
        try update(runtime.allocator, session, graph, node, schema, policy);
    }
    if (policy.manage_transaction) try session.commit();
}

fn trimmedSql(node: *const types.Node) []const u8 {
    return std.mem.trimEnd(u8, node.compiled_code orelse "", " \t\r\n;");
}
fn update(allocator: std.mem.Allocator, session: *adapter.Session, graph: *const types.Graph, node: *const types.Node, schema: []const u8, policy: ExecutionPolicy) !void {
    const strategy = node.incremental.strategy orelse "default";
    if ((std.mem.eql(u8, strategy, "merge") or std.mem.eql(u8, strategy, "microbatch")) and !session.capabilities().merge) return error.PostgresExecutionFailed;
    const target = try compiler.relationNameForNode(allocator, graph, node);
    defer allocator.free(target);
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(node.unique_id, &digest, .{});
    const stage_id = try std.fmt.allocPrint(allocator, "__dxt_incremental_{x}", .{&digest});
    defer allocator.free(stage_id);
    const stage = try adapter.quoteIdentifier(allocator, stage_id);
    defer allocator.free(stage);
    const header_value = values.get(node.effective_config, "sql_header") orelse .null;
    const header = if (header_value == .null) "" else if (header_value == .string) header_value.string else return error.InvalidPostgresMaterializationConfig;
    const creation = try std.fmt.allocPrint(allocator, "{s}\ncreate temporary table {s} on commit drop as (\n{s}\n)", .{ header, stage, trimmedSql(node) });
    defer allocator.free(creation);
    try session.execute(creation);
    var temp_schema_result = try session.query("select nspname from pg_namespace where oid=pg_my_temp_schema()");
    defer temp_schema_result.deinit(allocator);
    const temp_schema = temp_schema_result.firstScalar() orelse return error.InvalidAdapterIntrospection;
    var source_result = try session.columns(allocator, temp_schema, stage_id);
    defer source_result.deinit(allocator);
    var target_result = try session.columnsInDatabase(allocator, compiler.relationDatabaseForNode(graph, node), schema, compiler.relationIdentifierForNode(node));
    defer target_result.deinit(allocator);
    const source_columns = try columnsFromResult(allocator, source_result);
    defer allocator.free(source_columns);
    const target_columns = try columnsFromResult(allocator, target_result);
    defer allocator.free(target_columns);
    // Core widens character columns before checking on_schema_change.
    const contract = values.get(node.effective_config, "contract") orelse .null;
    const enforced = values.get(contract, "enforced") orelse .null;
    const expansion = if (enforced == .bool and enforced.bool) try allocator.dupe(u8, "") else try renderExpansionSql(allocator, target, source_columns, target_columns);
    defer allocator.free(expansion);
    if (expansion.len != 0) try session.execute(expansion);
    var refreshed = try session.columnsInDatabase(allocator, compiler.relationDatabaseForNode(graph, node), schema, compiler.relationIdentifierForNode(node));
    defer refreshed.deinit(allocator);
    const expanded_columns = try columnsFromResult(allocator, refreshed);
    defer allocator.free(expanded_columns);
    const schema_sql = try renderSchemaChanges(allocator, target, source_columns, expanded_columns, config.schemaPolicy(node.incremental));
    defer allocator.free(schema_sql);
    if (schema_sql.len != 0) try session.execute(schema_sql);
    const dest = if (std.mem.eql(u8, config.schemaPolicy(node.incremental), "ignore")) expanded_columns else source_columns;
    const mutation = if (std.mem.eql(u8, strategy, "merge") or std.mem.eql(u8, strategy, "microbatch")) try renderMergeSql(allocator, graph, node, target, stage, dest) else try renderInsertSql(allocator, node, target, stage, dest);
    defer allocator.free(mutation);
    var main = try session.query(mutation);
    defer main.deinit(allocator);
    try @import("materialization_result.zig").captureQuery(allocator, policy.main_result, main);
    const cleanup = try std.fmt.allocPrint(allocator, "drop table {s}", .{stage});
    defer allocator.free(cleanup);
    try session.execute(cleanup);
}

fn columnsFromResult(allocator: std.mem.Allocator, result: adapter.QueryResult) ![]Column {
    const columns = try allocator.alloc(Column, result.rows.len);
    errdefer allocator.free(columns);
    for (result.rows, columns) |row, *column| {
        if (row.len < 2) return error.InvalidAdapterIntrospection;
        column.* = .{ .column_name = row[0] orelse return error.InvalidAdapterIntrospection, .data_type = row[1] orelse return error.InvalidAdapterIntrospection };
    }
    return columns;
}
fn findColumn(columns: []const Column, name: []const u8) ?Column {
    for (columns) |column| if (std.mem.eql(u8, column.column_name, name)) return column;
    return null;
}
fn characterSize(data_type: []const u8) ?u32 {
    for ([_][]const u8{ "character varying", "varchar", "character", "text" }) |kind| {
        if (std.mem.eql(u8, data_type, kind)) return 256;
        if (std.mem.startsWith(u8, data_type, kind) and data_type.len > kind.len and data_type[kind.len] == '(' and std.mem.endsWith(u8, data_type, ")")) return std.fmt.parseUnsigned(u32, data_type[kind.len + 1 .. data_type.len - 1], 10) catch null;
    }
    return null;
}
fn typeChanged(source: Column, target: Column) bool {
    if (std.mem.eql(u8, source.data_type, target.data_type)) return false;
    if (characterSize(source.data_type)) |source_size| if (characterSize(target.data_type)) |target_size| {
        if (target_size > source_size) return false;
    };
    return true;
}
fn writeAlterType(writer: *std.Io.Writer, allocator: std.mem.Allocator, target: []const u8, name: []const u8, data_type: []const u8) !void {
    const quoted = try adapter.quoteIdentifier(allocator, name);
    defer allocator.free(quoted);
    const temporary_id = try std.fmt.allocPrint(allocator, "{s}__dbt_alter", .{name});
    defer allocator.free(temporary_id);
    const temporary = try adapter.quoteIdentifier(allocator, temporary_id);
    defer allocator.free(temporary);
    // Core's copy/drop/rename also defines the observable column order and
    // dependent-index cleanup. Every step remains inside the model transaction.
    try writer.print("alter table {s} add column {s} {s};\nupdate {s} set {s}={s};\nalter table {s} drop column {s} cascade;\nalter table {s} rename column {s} to {s};\n", .{ target, temporary, data_type, target, temporary, quoted, target, quoted, target, temporary, quoted });
}
pub fn renderExpansionSql(allocator: std.mem.Allocator, target: []const u8, source: []const Column, existing: []const Column) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (source) |column| if (findColumn(existing, column.column_name)) |old| {
        const source_size = characterSize(column.data_type) orelse continue;
        const old_size = characterSize(old.data_type) orelse continue;
        if (source_size <= old_size) continue;
        const data_type = try std.fmt.allocPrint(allocator, "character varying({d})", .{source_size});
        defer allocator.free(data_type);
        try writeAlterType(&out.writer, allocator, target, column.column_name, data_type);
    };
    return out.toOwnedSlice();
}
pub fn renderSchemaChanges(allocator: std.mem.Allocator, target: []const u8, source: []const Column, existing: []const Column, policy: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    if (std.mem.eql(u8, policy, "fail")) {
        if (source.len != existing.len) return error.IncrementalSchemaMismatch;
        for (source) |column| {
            const old = findColumn(existing, column.column_name) orelse return error.IncrementalSchemaMismatch;
            if (typeChanged(column, old)) return error.IncrementalSchemaMismatch;
        }
    }
    if (std.mem.eql(u8, policy, "append_new_columns") or std.mem.eql(u8, policy, "sync_all_columns")) {
        for (source) |column| if (findColumn(existing, column.column_name) == null) {
            const quoted = try adapter.quoteIdentifier(allocator, column.column_name);
            defer allocator.free(quoted);
            try out.writer.print("alter table {s} add column {s} {s};\n", .{ target, quoted, column.data_type });
        };
        if (std.mem.eql(u8, policy, "sync_all_columns")) {
            for (existing) |column| if (findColumn(source, column.column_name) == null) {
                const quoted = try adapter.quoteIdentifier(allocator, column.column_name);
                defer allocator.free(quoted);
                try out.writer.print("alter table {s} drop column {s};\n", .{ target, quoted });
            };
            for (source) |column| if (findColumn(existing, column.column_name)) |old| {
                if (typeChanged(column, old)) try writeAlterType(&out.writer, allocator, target, column.column_name, column.data_type);
            };
        }
    }
    return out.toOwnedSlice();
}

fn hasKey(key: ?types.SnapshotColumns) bool {
    return if (key) |value| switch (value) {
        .string => |s| s.len != 0,
        .list => |keys| keys.items.len != 0,
    } else false;
}
fn writeColumns(writer: *std.Io.Writer, allocator: std.mem.Allocator, columns: []const Column, prefix: []const u8) !void {
    for (columns, 0..) |column, i| {
        if (i != 0) try writer.writeAll(", ");
        const quoted = try adapter.quoteIdentifier(allocator, column.column_name);
        defer allocator.free(quoted);
        try writer.print("{s}{s}", .{ prefix, quoted });
    }
}
fn renderInsertSql(allocator: std.mem.Allocator, node: *const types.Node, target: []const u8, stage: []const u8, dest: []const Column) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    if (!std.mem.eql(u8, node.incremental.strategy orelse "default", "append") and hasKey(node.incremental.unique_key)) {
        try writer.print("delete from {s} as DBT_INTERNAL_DEST where (", .{target});
        var keys: std.Io.Writer.Allocating = .init(allocator);
        defer keys.deinit();
        switch (node.incremental.unique_key.?) {
            .string => |key| try keys.writer.writeAll(key),
            .list => |list| for (list.items, 0..) |key, i| {
                if (i != 0) try keys.writer.writeAll(", ");
                try keys.writer.writeAll(key);
            },
        }
        try writer.print("{s}) in (select distinct {s} from {s} as DBT_INTERNAL_SOURCE)", .{ keys.written(), keys.written(), stage });
        for (node.incremental.predicates.items) |predicate| try writer.print(" and ({s})", .{predicate});
        try writer.writeAll(";\n");
    }
    try writer.print("insert into {s} (", .{target});
    try writeColumns(writer, allocator, dest, "");
    try writer.writeAll(") select ");
    try writeColumns(writer, allocator, dest, "");
    try writer.print(" from {s};\n", .{stage});
    return out.toOwnedSlice();
}

pub fn renderMergeSql(allocator: std.mem.Allocator, graph: *const types.Graph, node: *const types.Node, target: []const u8, stage: []const u8, dest_columns: []const Column) ![]const u8 {
    const include = values.get(node.effective_config, "merge_update_columns") orelse .null;
    const exclude = values.get(node.effective_config, "merge_exclude_columns") orelse .null;
    const included = try columnList(include);
    const excluded = try columnList(exclude);
    if (included.len != 0 and excluded.len != 0) return error.InvalidPostgresMaterializationConfig;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    const header = values.get(node.effective_config, "sql_header") orelse .null;
    if (header != .null) {
        if (header != .string) return error.InvalidPostgresMaterializationConfig;
        try writer.print("{s}\n", .{header.string});
    }
    try writer.print("merge into {s} as DBT_INTERNAL_DEST using {s} as DBT_INTERNAL_SOURCE on (", .{ target, stage });
    for (node.incremental.predicates.items) |predicate| try writer.print("({s}) and ", .{predicate});
    if (hasKey(node.incremental.unique_key)) {
        switch (node.incremental.unique_key.?) {
            .string => |key| try writer.print("DBT_INTERNAL_SOURCE.{s}{s}DBT_INTERNAL_DEST.{s}", .{ key, if (graph.enable_truthy_nulls_equals_macro) " is not distinct from " else "=", key }),
            .list => |keys| for (keys.items, 0..) |key, i| {
                if (i != 0) try writer.writeAll(" and ");
                try writer.print("DBT_INTERNAL_SOURCE.{s}=DBT_INTERNAL_DEST.{s}", .{ key, key });
            },
        }
        try writer.writeAll(") when matched then update set ");
        if (included.len != 0) {
            for (included, 0..) |column, i| {
                if (i != 0) try writer.writeAll(", ");
                try writer.print("{s}=DBT_INTERNAL_SOURCE.{s}", .{ column.string, column.string });
            }
        } else {
            var count: usize = 0;
            for (dest_columns) |column| {
                var excluded_column = false;
                for (excluded) |candidate| if (std.ascii.eqlIgnoreCase(candidate.string, column.column_name)) {
                    excluded_column = true;
                };
                if (excluded_column) continue;
                if (count != 0) try writer.writeAll(", ");
                count += 1;
                const quoted = try adapter.quoteIdentifier(allocator, column.column_name);
                defer allocator.free(quoted);
                try writer.print("{s}=DBT_INTERNAL_SOURCE.{s}", .{ quoted, quoted });
            }
        }
    } else try writer.writeAll("false)");
    try writer.writeAll(" when not matched then insert (");
    try writeColumns(writer, allocator, dest_columns, "");
    try writer.writeAll(") values (");
    try writeColumns(writer, allocator, dest_columns, "DBT_INTERNAL_SOURCE.");
    try writer.writeAll(");\n");
    return out.toOwnedSlice();
}
fn columnList(value: std.json.Value) ![]const std.json.Value {
    if (value == .null) return &.{};
    if (value != .array) return error.InvalidPostgresMaterializationConfig;
    for (value.array.items) |column| if (column != .string) return error.InvalidPostgresMaterializationConfig;
    return value.array.items;
}

test "PostgreSQL merge renders keys predicates and configured update columns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"merge_exclude_columns\":[\"id\"]}", .{});
    var node: types.Node = undefined;
    node.effective_config = parsed.value;
    node.incremental = .{ .unique_key = .{ .string = "id" } };
    try node.incremental.predicates.append(allocator, "DBT_INTERNAL_DEST.id>0");
    const columns = [_]Column{ .{ .column_name = "id", .data_type = "integer" }, .{ .column_name = "payload", .data_type = "text" } };
    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    const sql = try renderMergeSql(allocator, &graph, &node, "target", "stage", &columns);
    try std.testing.expect(std.mem.indexOf(u8, sql, "(DBT_INTERNAL_DEST.id>0) and DBT_INTERNAL_SOURCE.id=DBT_INTERNAL_DEST.id") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "update set \"payload\"=DBT_INTERNAL_SOURCE.\"payload\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "values (DBT_INTERNAL_SOURCE.\"id\", DBT_INTERNAL_SOURCE.\"payload\")") != null);
    graph.enable_truthy_nulls_equals_macro = true;
    const truthy = try renderMergeSql(allocator, &graph, &node, "target", "stage", &columns);
    try std.testing.expect(std.mem.indexOf(u8, truthy, "DBT_INTERNAL_SOURCE.id is not distinct from DBT_INTERNAL_DEST.id") != null);
}
