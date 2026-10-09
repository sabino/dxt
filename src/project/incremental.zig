const std = @import("std");
const compiler = @import("compiler.zig");
const adapter = @import("adapter.zig");
const config = @import("incremental_config.zig");
const types = @import("types.zig");

pub const RelationKind = enum { missing, table, view };
pub const Column = struct { column_name: []const u8, data_type: []const u8 };

fn query(runtime: types.Runtime, db_path: []const u8, sql: []const u8, readonly: bool) ![]const u8 {
    return try adapter.queryJson(runtime, db_path, sql, readonly);
}

fn executeSql(runtime: types.Runtime, db_path: []const u8, sql: []const u8) !void {
    const output = try query(runtime, db_path, sql, false);
    runtime.allocator.free(output);
}

fn quoteString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (input) |char| {
        try out.append(allocator, char);
        if (char == '\'') try out.append(allocator, char);
    }
    try out.append(allocator, '\'');
    return try out.toOwnedSlice(allocator);
}

pub fn relationKind(runtime: types.Runtime, db_path: []const u8, graph: *const types.Graph, node: *const types.Node) !RelationKind {
    if (!std.mem.eql(u8, db_path, ":memory:")) {
        const file = std.Io.Dir.cwd().openFile(runtime.io, db_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return .missing,
            else => return err,
        };
        file.close(runtime.io);
    }
    const schema = try compiler.relationSchemaForNode(runtime.allocator, graph, node);
    defer runtime.allocator.free(schema);
    const schema_literal = try quoteString(runtime.allocator, schema);
    defer runtime.allocator.free(schema_literal);
    const identifier = try quoteString(runtime.allocator, compiler.relationIdentifierForNode(node));
    defer runtime.allocator.free(identifier);
    const sql = try std.fmt.allocPrint(runtime.allocator, "select table_type from information_schema.tables where table_catalog = current_database() and table_schema = {s} and table_name = {s};", .{ schema_literal, identifier });
    defer runtime.allocator.free(sql);
    const output = try query(runtime, db_path, sql, true);
    defer runtime.allocator.free(output);
    if (std.mem.trim(u8, output, " \t\r\n").len == 0) return .missing;
    const rows = try std.json.parseFromSlice([]struct { table_type: []const u8 }, runtime.allocator, output, .{});
    defer rows.deinit();
    if (rows.value.len == 0) return .missing;
    return if (std.mem.eql(u8, rows.value[0].table_type, "VIEW")) .view else .table;
}

pub fn isIncremental(runtime: types.Runtime, db_path: []const u8, graph: *const types.Graph, node: *const types.Node) !bool {
    if (!std.mem.eql(u8, node.materialized, "incremental") or config.fullRefresh(graph, node)) return false;
    return try relationKind(runtime, db_path, graph, node) == .table;
}

fn findColumn(items: []const Column, name: []const u8) ?Column {
    for (items) |item| if (std.mem.eql(u8, item.column_name, name)) return item;
    return null;
}

fn schemaChanged(source: []const Column, target: []const Column) bool {
    if (source.len != target.len) return true;
    for (source) |column| {
        const existing = findColumn(target, column.column_name) orelse return true;
        if (!std.mem.eql(u8, existing.data_type, column.data_type)) return true;
    }
    return false;
}

pub fn renderUpdateSql(allocator: std.mem.Allocator, target: []const u8, stage: []const u8, source_columns: []const Column, target_columns: []const Column, model_config: types.IncrementalConfig, begin_transaction: bool) ![]const u8 {
    try config.validate(model_config);
    const policy = config.schemaPolicy(model_config);
    if (std.mem.eql(u8, policy, "fail") and schemaChanged(source_columns, target_columns)) return error.IncrementalSchemaMismatch;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    if (begin_transaction) try writer.writeAll("begin transaction;\n");
    if (std.mem.eql(u8, policy, "append_new_columns") or std.mem.eql(u8, policy, "sync_all_columns")) {
        for (source_columns) |column| {
            const name = try compiler.quoteIdentifier(allocator, column.column_name);
            defer allocator.free(name);
            if (findColumn(target_columns, column.column_name) == null) try writer.print("alter table {s} add column {s} {s};\n", .{ target, name, column.data_type });
        }
        if (std.mem.eql(u8, policy, "sync_all_columns")) {
            for (target_columns) |column| {
                if (findColumn(source_columns, column.column_name) != null) continue;
                const name = try compiler.quoteIdentifier(allocator, column.column_name);
                defer allocator.free(name);
                try writer.print("alter table {s} drop column {s};\n", .{ target, name });
            }
            // Native ALTER TYPE avoids Core's copy/update/drop transaction conflict.
            for (source_columns) |column| {
                const existing = findColumn(target_columns, column.column_name) orelse continue;
                if (std.mem.eql(u8, existing.data_type, column.data_type)) continue;
                const name = try compiler.quoteIdentifier(allocator, column.column_name);
                defer allocator.free(name);
                try writer.print("alter table {s} alter column {s} type {s};\n", .{ target, name, column.data_type });
            }
        }
    }
    const strategy = model_config.strategy orelse "default";
    if (!std.mem.eql(u8, strategy, "append")) {
        if (model_config.unique_key) |key| switch (key) {
            .string => |expression| if (expression.len != 0) {
                try writer.print("delete from {s} where ({s}) in (select ({s}) from {s})", .{ target, expression, expression, stage });
                for (model_config.predicates.items) |predicate| try writer.print(" and ({s})", .{predicate});
                try writer.writeAll(";\n");
            },
            .list => |keys| if (keys.items.len != 0) {
                try writer.print("delete from {s} as DBT_INCREMENTAL_TARGET using {s} where (", .{ target, stage });
                for (keys.items, 0..) |key_name, index| {
                    if (index != 0) try writer.writeAll(" and ");
                    try writer.print("{s}.{s} = DBT_INCREMENTAL_TARGET.{s}", .{ stage, key_name, key_name });
                }
                for (model_config.predicates.items) |predicate| try writer.print(" and ({s})", .{predicate});
                try writer.writeAll(");\n");
            },
        };
    }
    const dest_columns = if (std.mem.eql(u8, policy, "ignore")) target_columns else source_columns;
    var column_names: std.Io.Writer.Allocating = .init(allocator);
    defer column_names.deinit();
    for (dest_columns, 0..) |column, index| {
        if (index != 0) try column_names.writer.writeAll(", ");
        const name = try compiler.quoteIdentifier(allocator, column.column_name);
        defer allocator.free(name);
        try column_names.writer.writeAll(name);
    }
    try writer.print("insert into {s} ({s}) select {s} from {s};\ndrop table {s};\ncommit;\n", .{ target, column_names.written(), column_names.written(), stage, stage });
    return try out.toOwnedSlice();
}

pub fn execute(runtime: types.Runtime, db_path: []const u8, graph: *const types.Graph, node: *const types.Node) !void {
    try config.validate(node.incremental);
    const existing = try relationKind(runtime, db_path, graph, node);
    const schema = try compiler.relationSchemaForNode(runtime.allocator, graph, node);
    defer runtime.allocator.free(schema);
    const schema_quoted = try compiler.quoteIdentifier(runtime.allocator, schema);
    defer runtime.allocator.free(schema_quoted);
    const target = try compiler.relationNameForNode(runtime.allocator, graph, node);
    defer runtime.allocator.free(target);
    const compiled = std.mem.trimEnd(u8, node.compiled_code orelse return error.UnsupportedModelExecution, " \t\r\n;");
    if (existing == .missing or existing == .view or config.fullRefresh(graph, node)) {
        // CTAS and replacement share one transaction, including view-to-table changes.
        const sql = try std.fmt.allocPrint(runtime.allocator, "begin transaction;\ncreate schema if not exists {s};\n{s}{s}{s}create or replace table {s} as (\n{s}\n);\ncommit;\n", .{ schema_quoted, if (existing == .view) "drop view " else "", if (existing == .view) target else "", if (existing == .view) ";\n" else "", target, compiled });
        defer runtime.allocator.free(sql);
        return try executeSql(runtime, db_path, sql);
    }
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(node.unique_id, &digest, .{});
    const stage_identifier = try std.fmt.allocPrint(runtime.allocator, "__dxt_incremental_{x}", .{&digest});
    defer runtime.allocator.free(stage_identifier);
    const stage = try compiler.quoteIdentifier(runtime.allocator, stage_identifier);
    defer runtime.allocator.free(stage);
    const stage_literal = try quoteString(runtime.allocator, stage_identifier);
    defer runtime.allocator.free(stage_literal);
    const schema_literal = try quoteString(runtime.allocator, schema);
    defer runtime.allocator.free(schema_literal);
    const target_literal = try quoteString(runtime.allocator, compiler.relationIdentifierForNode(node));
    defer runtime.allocator.free(target_literal);
    if (runtime.adapter_session) |session| switch (session.*) {
        .duckdb => |*connection| return try executeNativeUpdate(runtime, connection, target, stage, compiled, stage_literal, schema_literal, target_literal, node.incremental),
        else => {},
    };
    var temporary_pool = adapter.DuckDBPool.init(runtime.allocator, runtime.io, runtime.environment);
    defer temporary_pool.deinit();
    const pool = runtime.duckdb_pool orelse &temporary_pool;
    if (try pool.acquire(db_path, false)) |native| {
        var connection = native;
        defer connection.deinit();
        return try executeNativeUpdate(runtime, &connection, target, stage, compiled, stage_literal, schema_literal, target_literal, node.incremental);
    }
    // A single persistent native-owned CLI connection holds the transaction
    // across staging, schema inspection, schema changes and the data update.
    // Temporary staging disappears and all target changes roll back on failure.
    var child = std.process.spawn(runtime.io, .{
        .argv = &.{ "duckdb", db_path, "-batch", "-bail", "-noheader", "-list" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.DuckDbCliNotFound,
        else => return err,
    };
    defer child.kill(runtime.io);
    var input_buffer: [4096]u8 = undefined;
    var input = child.stdin.?.writerStreaming(runtime.io, &input_buffer);
    const output_buffer = try runtime.allocator.alloc(u8, 4 * 1024 * 1024);
    defer runtime.allocator.free(output_buffer);
    var output = child.stdout.?.readerStreaming(runtime.io, output_buffer);
    const initial_sql = try std.fmt.allocPrint(runtime.allocator, "begin transaction;\ncreate temporary table {s} as (\n{s}\n);\n" ++
        "select coalesce(to_json(list(struct_pack(column_name := column_name, data_type := data_type) order by ordinal_position))::varchar, '[]') from information_schema.columns where table_catalog='temp' and table_name={s};\n" ++
        "select coalesce(to_json(list(struct_pack(column_name := column_name, data_type := data_type) order by ordinal_position))::varchar, '[]') from information_schema.columns where table_catalog=current_database() and table_schema={s} and table_name={s};\n", .{ stage, compiled, stage_literal, schema_literal, target_literal });
    defer runtime.allocator.free(initial_sql);
    input.interface.writeAll(initial_sql) catch return error.DuckDbExecutionFailed;
    input.interface.flush() catch return error.DuckDbExecutionFailed;
    const source_line = (output.interface.takeDelimiter('\n') catch return error.DuckDbExecutionFailed) orelse return error.DuckDbExecutionFailed;
    const source_columns = try std.json.parseFromSlice([]Column, runtime.allocator, source_line, .{ .allocate = .alloc_always });
    defer source_columns.deinit();
    const target_line = (output.interface.takeDelimiter('\n') catch return error.DuckDbExecutionFailed) orelse return error.DuckDbExecutionFailed;
    const target_columns = try std.json.parseFromSlice([]Column, runtime.allocator, target_line, .{ .allocate = .alloc_always });
    defer target_columns.deinit();
    const sql = renderUpdateSql(runtime.allocator, target, stage, source_columns.value, target_columns.value, node.incremental, false) catch |err| switch (err) {
        error.IncrementalSchemaMismatch => return error.DuckDbExecutionFailed,
        else => return err,
    };
    defer runtime.allocator.free(sql);
    input.interface.writeAll(sql) catch return error.DuckDbExecutionFailed;
    input.interface.flush() catch return error.DuckDbExecutionFailed;
    child.stdin.?.close(runtime.io);
    child.stdin = null;
    const term = try child.wait(runtime.io);
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.DuckDbExecutionFailed;
}

fn executeNativeUpdate(runtime: types.Runtime, connection: *adapter.DuckDBConnection, target: []const u8, stage: []const u8, compiled: []const u8, stage_literal: []const u8, schema_literal: []const u8, target_literal: []const u8, model_config: types.IncrementalConfig) !void {
    try connection.begin();
    errdefer connection.rollback() catch {};
    const stage_sql = try std.fmt.allocPrint(runtime.allocator, "create temporary table {s} as (\n{s}\n)", .{ stage, compiled });
    defer runtime.allocator.free(stage_sql);
    try connection.execute(stage_sql);
    const source_sql = try std.fmt.allocPrint(runtime.allocator, "select column_name, data_type from information_schema.columns where table_catalog='temp' and table_name={s} order by ordinal_position", .{stage_literal});
    defer runtime.allocator.free(source_sql);
    const target_sql = try std.fmt.allocPrint(runtime.allocator, "select column_name, data_type from information_schema.columns where table_catalog=current_database() and table_schema={s} and table_name={s} order by ordinal_position", .{ schema_literal, target_literal });
    defer runtime.allocator.free(target_sql);
    var source_result = try connection.query(source_sql);
    defer source_result.deinit(runtime.allocator);
    var target_result = try connection.query(target_sql);
    defer target_result.deinit(runtime.allocator);
    const source_json = try source_result.json(runtime.allocator);
    defer runtime.allocator.free(source_json);
    const target_json = try target_result.json(runtime.allocator);
    defer runtime.allocator.free(target_json);
    const source_columns = try std.json.parseFromSlice([]Column, runtime.allocator, source_json, .{});
    defer source_columns.deinit();
    const target_columns = try std.json.parseFromSlice([]Column, runtime.allocator, target_json, .{});
    defer target_columns.deinit();
    const sql = renderUpdateSql(runtime.allocator, target, stage, source_columns.value, target_columns.value, model_config, false) catch |err| switch (err) {
        error.IncrementalSchemaMismatch => return error.DuckDbExecutionFailed,
        else => return err,
    };
    defer runtime.allocator.free(sql);
    try connection.execute(sql);
}

test "incremental update policies and composite keys preserve target changes in a transaction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const target = [_]Column{ .{ .column_name = "id", .data_type = "INTEGER" }, .{ .column_name = "old", .data_type = "VARCHAR" } };
    const source = [_]Column{ .{ .column_name = "id", .data_type = "BIGINT" }, .{ .column_name = "new", .data_type = "VARCHAR" } };
    try std.testing.expectError(error.IncrementalSchemaMismatch, renderUpdateSql(allocator, "events", "stage", &source, &target, .{ .on_schema_change = "fail" }, true));
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    try keys.appendSlice(allocator, &.{ "id", "new" });
    const sql = try renderUpdateSql(allocator, "events", "stage", &source, &target, .{ .on_schema_change = "sync_all_columns", .unique_key = .{ .list = keys } }, true);
    try std.testing.expect(std.mem.startsWith(u8, sql, "begin transaction;"));
    try std.testing.expect(std.mem.indexOf(u8, sql, "alter column \"id\" type BIGINT") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "drop column \"old\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "stage.id = DBT_INCREMENTAL_TARGET.id and stage.new = DBT_INCREMENTAL_TARGET.new") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "insert into events (\"id\", \"new\")") != null);
    try std.testing.expect(std.mem.endsWith(u8, sql, "drop table stage;\ncommit;\n"));
}
