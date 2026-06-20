const std = @import("std");
const catalog = @import("catalog.zig");
const compiler = @import("compiler.zig");
const project_fs = @import("fs.zig");
const selector = @import("selector.zig");
const types = @import("types.zig");

const Runtime = types.Runtime;
const Graph = types.Graph;
const Node = types.Node;
const GenericTestNode = types.GenericTestNode;
const SingularTestNode = types.SingularTestNode;
const SourceDef = types.SourceDef;

const DuckDbObjectKind = enum { table, view };

pub const GenericTestExecutionResult = struct {
    compiled_code: []const u8,
    failures: u64,
};

pub const FreshnessQueryResult = struct {
    max_loaded_at: []const u8,
    snapshotted_at: []const u8,
    age_seconds: f64,
};

pub fn deinitFreshnessQueryResult(allocator: std.mem.Allocator, result: FreshnessQueryResult) void {
    allocator.free(result.max_loaded_at);
    allocator.free(result.snapshotted_at);
}

pub fn databasePath(allocator: std.mem.Allocator, target_dir: []const u8, graph: *const Graph) ![]const u8 {
    if (graph.database_path) |configured_path| {
        if (isUnsupportedConnectionPath(configured_path)) return error.UnsupportedDuckDbPath;
        if (std.fs.path.isAbsolute(configured_path)) return try allocator.dupe(u8, configured_path);
        const base = graph.database_path_base orelse ".";
        return try project_fs.pathJoin(allocator, &.{ base, configured_path });
    }
    return try project_fs.pathJoin(allocator, &.{ target_dir, "dxt.duckdb" });
}

pub fn isSupportedMaterialization(value: []const u8) bool {
    return std.mem.eql(u8, value, "table") or std.mem.eql(u8, value, "view");
}

fn isUnsupportedConnectionPath(value: []const u8) bool {
    return std.mem.eql(u8, value, ":memory:") or
        std.mem.startsWith(u8, value, "md:") or
        std.mem.startsWith(u8, value, "motherduck:");
}

pub fn executeModel(runtime: Runtime, db_path: []const u8, graph: *const Graph, node: *const Node) !void {
    try dropConflictingMaterialization(runtime, db_path, graph, node);

    const sql = try renderModelSql(runtime.allocator, graph, node);
    defer runtime.allocator.free(sql);

    try executeSql(runtime, db_path, sql);
}

pub fn executeSeed(runtime: Runtime, db_path: []const u8, project_dir: []const u8, graph: *const Graph, node: *const Node) !void {
    try dropRelationIfExists(runtime, db_path, graph, node, .view);

    const sql = try renderSeedSql(runtime.allocator, project_dir, graph, node);
    defer runtime.allocator.free(sql);

    try executeSql(runtime, db_path, sql);
}

pub fn executeGenericTest(runtime: Runtime, db_path: []const u8, graph: *const Graph, test_node: *const GenericTestNode) !GenericTestExecutionResult {
    const compiled_sql = try renderGenericTestSql(runtime.allocator, graph, test_node);
    errdefer runtime.allocator.free(compiled_sql);
    const execution_sql = try renderGenericTestExecutionSql(runtime.allocator, compiled_sql);
    defer runtime.allocator.free(execution_sql);
    const failures = try queryGenericTestFailures(runtime, db_path, execution_sql);
    return .{ .compiled_code = compiled_sql, .failures = failures };
}

pub fn executeSingularTest(runtime: Runtime, db_path: []const u8, graph: *const Graph, test_node: *const SingularTestNode) !GenericTestExecutionResult {
    const compiled_sql = try compiler.compileSingularTest(runtime.allocator, graph, test_node);
    errdefer runtime.allocator.free(compiled_sql);
    const execution_sql = try renderGenericTestExecutionSql(runtime.allocator, compiled_sql);
    defer runtime.allocator.free(execution_sql);
    const failures = try queryGenericTestFailures(runtime, db_path, execution_sql);
    return .{ .compiled_code = compiled_sql, .failures = failures };
}

pub fn querySourceFreshness(runtime: Runtime, db_path: []const u8, source: *const SourceDef) !FreshnessQueryResult {
    if (!databaseFileExists(runtime, db_path)) return error.DuckDbExecutionFailed;
    const sql = try renderSourceFreshnessSql(runtime.allocator, source);
    defer runtime.allocator.free(sql);

    const result = std.process.run(runtime.allocator, runtime.io, .{
        .argv = &.{ "duckdb", "-readonly", db_path, "-json", "-batch", "-bail", "-c", sql },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.DuckDbCliNotFound,
        else => return err,
    };
    errdefer runtime.allocator.free(result.stdout);
    defer runtime.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0) {
            const parsed = try parseFreshnessQueryJson(runtime.allocator, result.stdout);
            runtime.allocator.free(result.stdout);
            return parsed;
        },
        else => {},
    }
    runtime.allocator.free(result.stdout);
    return error.DuckDbExecutionFailed;
}

pub fn renderSourceFreshnessSql(allocator: std.mem.Allocator, source: *const SourceDef) ![]const u8 {
    if (source.loaded_at_query) |loaded_at_query| {
        const query = std.mem.trim(u8, loaded_at_query, " \t\r\n");
        if (query.len == 0) return error.UnsupportedSourceFreshness;
        return try std.fmt.allocPrint(
            allocator,
            "with source_query as ({s}), freshness as (select (select * from source_query) as max_loaded_at, current_timestamp as snapshotted_at) select coalesce(strftime(max_loaded_at, '%Y-%m-%dT%H:%M:%SZ'), '0001-01-01T00:00:00Z') as max_loaded_at, strftime(snapshotted_at, '%Y-%m-%dT%H:%M:%SZ') as snapshotted_at, coalesce(epoch(snapshotted_at) - epoch(max_loaded_at), 9.223372036854776e18) as age_seconds from freshness;",
            .{query},
        );
    }
    const loaded_at_field = source.loaded_at_field orelse return error.UnsupportedSourceFreshness;
    const loaded_at_expression = std.mem.trim(u8, loaded_at_field, " \t\r\n");
    if (loaded_at_expression.len == 0) return error.UnsupportedSourceFreshness;
    const relation_name = try compiler.relationNameForSource(allocator, source);
    defer allocator.free(relation_name);
    const filter = if (source.freshness) |threshold| threshold.filter else null;
    const filter_expression = if (filter) |value| std.mem.trim(u8, value, " \t\r\n") else "";
    if (filter_expression.len != 0) {
        return try std.fmt.allocPrint(
            allocator,
            "select coalesce(strftime(max({s}), '%Y-%m-%dT%H:%M:%SZ'), '0001-01-01T00:00:00Z') as max_loaded_at, strftime(current_timestamp, '%Y-%m-%dT%H:%M:%SZ') as snapshotted_at, coalesce(epoch(current_timestamp) - epoch(max({s})), 9.223372036854776e18) as age_seconds from {s} where {s};",
            .{ loaded_at_expression, loaded_at_expression, relation_name, filter_expression },
        );
    }
    return try std.fmt.allocPrint(
        allocator,
        "select coalesce(strftime(max({s}), '%Y-%m-%dT%H:%M:%SZ'), '0001-01-01T00:00:00Z') as max_loaded_at, strftime(current_timestamp, '%Y-%m-%dT%H:%M:%SZ') as snapshotted_at, coalesce(epoch(current_timestamp) - epoch(max({s})), 9.223372036854776e18) as age_seconds from {s};",
        .{ loaded_at_expression, loaded_at_expression, relation_name },
    );
}

pub fn collectCatalogEntries(runtime: Runtime, db_path: []const u8, graph: *const Graph, selected: []const selector.SelectedResource) !catalog.CatalogEntries {
    var entries: catalog.CatalogEntries = .{};
    errdefer catalog.deinitCatalogEntries(runtime.allocator, &entries);
    if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return entries;
    if (!databaseFileExists(runtime, db_path)) return entries;

    const rows_json = try queryCatalogColumnsJson(runtime, db_path);
    defer runtime.allocator.free(rows_json);
    var parsed_rows = try std.json.parseFromSlice(std.json.Value, runtime.allocator, rows_json, .{});
    defer parsed_rows.deinit();
    if (parsed_rows.value != .array) return error.DuckDbExecutionFailed;
    const rows = parsed_rows.value.array.items;

    for (graph.nodes.items) |*node| {
        if (!selectionContains(selected, node.unique_id)) continue;
        if (!std.mem.eql(u8, node.resource_type, "model") and !std.mem.eql(u8, node.resource_type, "seed")) continue;
        const entry = try catalogEntryForNode(runtime.allocator, graph, node, rows) orelse continue;
        try entries.nodes.append(runtime.allocator, entry);
    }
    for (graph.sources.items) |*source| {
        if (!selectionContains(selected, source.unique_id)) continue;
        const entry = try catalogEntryForSource(runtime.allocator, source, rows) orelse continue;
        try entries.sources.append(runtime.allocator, entry);
    }

    return entries;
}

fn databaseFileExists(runtime: Runtime, db_path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(runtime.io, db_path, .{}) catch return false;
    file.close(runtime.io);
    return true;
}

fn queryCatalogColumnsJson(runtime: Runtime, db_path: []const u8) ![]const u8 {
    const sql =
        \\select
        \\    c.table_catalog,
        \\    c.table_schema,
        \\    c.table_name,
        \\    t.table_type,
        \\    c.column_name,
        \\    c.ordinal_position,
        \\    c.data_type
        \\from information_schema.columns c
        \\join information_schema.tables t
        \\    on c.table_schema = t.table_schema
        \\    and c.table_name = t.table_name
        \\where c.table_schema not in ('information_schema', 'pg_catalog')
        \\order by c.table_schema, c.table_name, c.ordinal_position;
    ;
    const result = std.process.run(runtime.allocator, runtime.io, .{
        .argv = &.{ "duckdb", "-readonly", db_path, "-json", "-batch", "-bail", "-c", sql },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.DuckDbCliNotFound,
        else => return err,
    };
    errdefer runtime.allocator.free(result.stdout);
    defer runtime.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0) return result.stdout,
        else => {},
    }
    return error.DuckDbExecutionFailed;
}

fn catalogEntryForNode(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node, rows: []const std.json.Value) !?catalog.CatalogEntry {
    const schema_name = try compiler.relationSchemaForNode(allocator, graph, node);
    defer allocator.free(schema_name);
    const identifier = compiler.relationIdentifierForNode(node);

    return try catalogEntryForRelation(allocator, node.unique_id, null, schema_name, identifier, rows);
}

fn catalogEntryForSource(allocator: std.mem.Allocator, source: *const SourceDef, rows: []const std.json.Value) !?catalog.CatalogEntry {
    return try catalogEntryForRelation(allocator, source.unique_id, compiler.sourceDatabaseName(source), compiler.sourceSchemaName(source), compiler.sourceIdentifier(source), rows);
}

fn catalogEntryForRelation(allocator: std.mem.Allocator, unique_id: []const u8, database_name: ?[]const u8, schema_name: []const u8, identifier: []const u8, rows: []const std.json.Value) !?catalog.CatalogEntry {
    var entry = catalog.CatalogEntry{
        .unique_id = try allocator.dupe(u8, unique_id),
        .database = if (database_name) |database| try allocator.dupe(u8, database) else null,
        .schema = try allocator.dupe(u8, schema_name),
        .name = try allocator.dupe(u8, identifier),
        .relation_type = try allocator.dupe(u8, ""),
    };
    errdefer deinitCatalogEntry(allocator, &entry);

    for (rows) |row| {
        const object = if (row == .object) row.object else return error.DuckDbExecutionFailed;
        const row_catalog = jsonObjectString(object, "table_catalog") orelse return error.DuckDbExecutionFailed;
        const row_schema = jsonObjectString(object, "table_schema") orelse return error.DuckDbExecutionFailed;
        const row_table = jsonObjectString(object, "table_name") orelse return error.DuckDbExecutionFailed;
        const row_type = jsonObjectString(object, "table_type") orelse return error.DuckDbExecutionFailed;
        const row_column = jsonObjectString(object, "column_name") orelse return error.DuckDbExecutionFailed;
        const row_index = jsonObjectUnsigned(object, "ordinal_position") orelse return error.DuckDbExecutionFailed;
        const row_data_type = jsonObjectString(object, "data_type") orelse return error.DuckDbExecutionFailed;
        if (database_name) |database| {
            if (!std.mem.eql(u8, row_catalog, database)) continue;
        }
        if (!std.mem.eql(u8, row_schema, schema_name) or !std.mem.eql(u8, row_table, identifier)) continue;
        if (entry.columns.items.len == 0) {
            allocator.free(entry.relation_type);
            entry.relation_type = try allocator.dupe(u8, row_type);
        }
        try entry.columns.append(allocator, .{
            .name = try allocator.dupe(u8, row_column),
            .data_type = try allocator.dupe(u8, row_data_type),
            .index = row_index,
        });
    }

    if (entry.columns.items.len == 0) {
        deinitCatalogEntry(allocator, &entry);
        return null;
    }
    return entry;
}

fn parseFreshnessQueryJson(allocator: std.mem.Allocator, rows_json: []const u8) !FreshnessQueryResult {
    var parsed_rows = try std.json.parseFromSlice(std.json.Value, allocator, rows_json, .{});
    defer parsed_rows.deinit();
    if (parsed_rows.value != .array) return error.DuckDbExecutionFailed;
    if (parsed_rows.value.array.items.len != 1) return error.DuckDbExecutionFailed;
    const row = parsed_rows.value.array.items[0];
    const object = if (row == .object) row.object else return error.DuckDbExecutionFailed;
    const max_loaded_at = jsonObjectString(object, "max_loaded_at") orelse return error.DuckDbExecutionFailed;
    const snapshotted_at = jsonObjectString(object, "snapshotted_at") orelse return error.DuckDbExecutionFailed;
    const age_seconds = jsonObjectNumber(object, "age_seconds") orelse return error.DuckDbExecutionFailed;
    return .{
        .max_loaded_at = try allocator.dupe(u8, max_loaded_at),
        .snapshotted_at = try allocator.dupe(u8, snapshotted_at),
        .age_seconds = age_seconds,
    };
}

fn jsonObjectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn jsonObjectNumber(object: std.json.ObjectMap, key: []const u8) ?f64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .float => |float| float,
        .integer => |integer| @floatFromInt(integer),
        else => null,
    };
}

fn jsonObjectUnsigned(object: std.json.ObjectMap, key: []const u8) ?u64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| if (integer < 0) null else @intCast(integer),
        else => null,
    };
}

fn deinitCatalogEntry(allocator: std.mem.Allocator, entry: *catalog.CatalogEntry) void {
    allocator.free(entry.unique_id);
    allocator.free(entry.schema);
    allocator.free(entry.name);
    allocator.free(entry.relation_type);
    for (entry.columns.items) |column| {
        allocator.free(column.name);
        allocator.free(column.data_type);
    }
    entry.columns.deinit(allocator);
}

fn selectionContains(selected: []const selector.SelectedResource, unique_id: []const u8) bool {
    for (selected) |item| {
        if (std.mem.eql(u8, item.unique_id, unique_id)) return true;
    }
    return false;
}

fn executeSql(runtime: Runtime, db_path: []const u8, sql: []const u8) !void {
    const result = std.process.run(runtime.allocator, runtime.io, .{
        .argv = &.{ "duckdb", db_path, "-batch", "-bail", "-c", sql },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.DuckDbCliNotFound,
        else => return err,
    };
    defer runtime.allocator.free(result.stdout);
    defer runtime.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.DuckDbExecutionFailed;
}

fn queryGenericTestFailures(runtime: Runtime, db_path: []const u8, sql: []const u8) !u64 {
    const result = std.process.run(runtime.allocator, runtime.io, .{
        .argv = &.{ "duckdb", db_path, "-csv", "-noheader", "-batch", "-bail", "-c", sql },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.DuckDbCliNotFound,
        else => return err,
    };
    defer runtime.allocator.free(result.stdout);
    defer runtime.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0) {
            const field = firstCsvField(result.stdout) orelse return error.DuckDbExecutionFailed;
            return std.fmt.parseUnsigned(u64, field, 10) catch error.DuckDbExecutionFailed;
        },
        else => {},
    }
    return error.DuckDbExecutionFailed;
}

fn firstCsvField(stdout: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    const end = std.mem.indexOfAny(u8, trimmed, ",\r\n") orelse trimmed.len;
    return std.mem.trim(u8, trimmed[0..end], " \t");
}

fn relationObjectExists(runtime: Runtime, db_path: []const u8, graph: *const Graph, node: *const Node, object_kind: DuckDbObjectKind) !bool {
    const schema_name = try compiler.relationSchemaForNode(runtime.allocator, graph, node);
    defer runtime.allocator.free(schema_name);
    const identifier = compiler.relationIdentifierForNode(node);
    const quoted_schema_literal = try quoteSqlString(runtime.allocator, schema_name);
    defer runtime.allocator.free(quoted_schema_literal);
    const quoted_identifier_literal = try quoteSqlString(runtime.allocator, identifier);
    defer runtime.allocator.free(quoted_identifier_literal);

    const query = try std.fmt.allocPrint(
        runtime.allocator,
        "select count(*) from {s}() where schema_name = {s} and {s} = {s};",
        .{
            if (object_kind == .table) "duckdb_tables" else "duckdb_views",
            quoted_schema_literal,
            if (object_kind == .table) "table_name" else "view_name",
            quoted_identifier_literal,
        },
    );
    defer runtime.allocator.free(query);

    const result = std.process.run(runtime.allocator, runtime.io, .{
        .argv = &.{ "duckdb", db_path, "-csv", "-noheader", "-batch", "-bail", "-c", query },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.DuckDbCliNotFound,
        else => return err,
    };
    defer runtime.allocator.free(result.stdout);
    defer runtime.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0) {
            const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
            return !std.mem.eql(u8, trimmed, "0");
        },
        else => {},
    }
    return error.DuckDbExecutionFailed;
}

fn dropConflictingMaterialization(runtime: Runtime, db_path: []const u8, graph: *const Graph, node: *const Node) !void {
    const drop_kind: DuckDbObjectKind = if (std.mem.eql(u8, node.materialized, "table")) .view else .table;
    try dropRelationIfExists(runtime, db_path, graph, node, drop_kind);
}

fn dropRelationIfExists(runtime: Runtime, db_path: []const u8, graph: *const Graph, node: *const Node, object_kind: DuckDbObjectKind) !void {
    if (!try relationObjectExists(runtime, db_path, graph, node, object_kind)) return;

    const drop_sql = try renderDropSql(runtime.allocator, graph, node, object_kind);
    defer runtime.allocator.free(drop_sql);
    try executeSql(runtime, db_path, drop_sql);
}

fn renderDropSql(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node, object_kind: DuckDbObjectKind) ![]const u8 {
    const relation_name = node.relation_name orelse try compiler.relationNameForNode(allocator, graph, node);
    const should_free_relation = node.relation_name == null;
    defer if (should_free_relation) allocator.free(relation_name);
    return try std.fmt.allocPrint(
        allocator,
        "drop {s} if exists {s};\n",
        .{ if (object_kind == .table) "table" else "view", relation_name },
    );
}

pub fn renderModelSql(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node) ![]const u8 {
    if (!isSupportedMaterialization(node.materialized)) {
        return error.UnsupportedModelMaterialization;
    }
    const compiled_code = trimTrailingSqlTerminator(node.compiled_code orelse return error.UnsupportedModelExecution);
    const schema_name = try compiler.relationSchemaForNode(allocator, graph, node);
    defer allocator.free(schema_name);
    const quoted_schema = try compiler.quoteIdentifier(allocator, schema_name);
    defer allocator.free(quoted_schema);
    const relation_name = node.relation_name orelse try compiler.relationNameForNode(allocator, graph, node);
    const should_free_relation = node.relation_name == null;
    defer if (should_free_relation) allocator.free(relation_name);

    const materialization_keyword: []const u8 = if (std.mem.eql(u8, node.materialized, "table")) "table" else "view";
    return try std.fmt.allocPrint(
        allocator,
        "create schema if not exists {s};\ncreate or replace {s} {s} as (\n{s}\n);\n",
        .{ quoted_schema, materialization_keyword, relation_name, compiled_code },
    );
}

pub fn renderSeedSql(allocator: std.mem.Allocator, project_dir: []const u8, graph: *const Graph, node: *const Node) ![]const u8 {
    if (!std.mem.eql(u8, node.resource_type, "seed") or !std.mem.eql(u8, node.materialized, "seed")) {
        return error.UnsupportedSeedExecution;
    }

    const seed_file_path = try seedFilePath(allocator, project_dir, graph, node);
    defer allocator.free(seed_file_path);
    const seed_file_literal = try quoteSqlString(allocator, seed_file_path);
    defer allocator.free(seed_file_literal);

    const schema_name = try compiler.relationSchemaForNode(allocator, graph, node);
    defer allocator.free(schema_name);
    const quoted_schema = try compiler.quoteIdentifier(allocator, schema_name);
    defer allocator.free(quoted_schema);
    const relation_name = try compiler.relationNameForNode(allocator, graph, node);
    defer allocator.free(relation_name);

    return try std.fmt.allocPrint(
        allocator,
        "create schema if not exists {s};\ncreate or replace table {s} as select * from read_csv_auto({s}, header = true);\n",
        .{ quoted_schema, relation_name, seed_file_literal },
    );
}

fn seedFilePath(allocator: std.mem.Allocator, project_dir: []const u8, graph: *const Graph, node: *const Node) ![]const u8 {
    if (!isSafeRelativePath(node.original_file_path)) return error.UnsupportedSeedExecution;
    const root = node.project_root orelse blk: {
        if (!std.mem.eql(u8, node.package_name, graph.project_name)) return error.UnsupportedSeedExecution;
        break :blk project_dir;
    };
    return try project_fs.pathJoin(allocator, &.{ root, node.original_file_path });
}

fn isSafeRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

pub fn renderGenericTestSql(allocator: std.mem.Allocator, graph: *const Graph, test_node: *const GenericTestNode) ![]const u8 {
    return try compiler.compileGenericTest(allocator, graph, test_node);
}

pub fn renderGenericTestExecutionSql(allocator: std.mem.Allocator, compiled_sql: []const u8) ![]const u8 {
    const query_sql = trimTrailingSqlTerminator(compiled_sql);
    return try std.fmt.allocPrint(
        allocator,
        "select\n  count(*) as failures,\n  count(*) != 0 as should_warn,\n  count(*) != 0 as should_error\nfrom (\n{s}\n) dbt_internal_test;\n",
        .{query_sql},
    );
}

fn quoteSqlString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') try out.append(allocator, '\'');
        try out.append(allocator, byte);
    }
    try out.append(allocator, '\'');
    return try out.toOwnedSlice(allocator);
}

fn trimTrailingSqlTerminator(sql: []const u8) []const u8 {
    const trimmed_end = trimSqlRightEnd(sql, sql.len);
    var end = trimmed_end;
    while (stripOneTrailingSqlComment(sql[0..end])) |comment_start| {
        end = trimSqlRightEnd(sql, comment_start);
    }
    if (end > 0 and sql[end - 1] == ';') return sql[0..trimSqlRightEnd(sql, end - 1)];
    return sql[0..trimmed_end];
}

fn trimSqlRightEnd(value: []const u8, initial_end: usize) usize {
    var end = initial_end;
    while (end > 0 and isSqlTrailingWhitespace(value[end - 1])) {
        end -= 1;
    }
    return end;
}

fn isSqlTrailingWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

fn stripOneTrailingSqlComment(value: []const u8) ?usize {
    if (std.mem.endsWith(u8, value, "*/")) {
        return lastIndexOf(value, "/*");
    }
    const line_start = lastLineStart(value);
    const first = skipSqlInlineWhitespace(value, line_start);
    if (first + 1 < value.len and value[first] == '-' and value[first + 1] == '-') return line_start;
    const dash = lastIndexOf(value, "--") orelse return null;
    if (dash < line_start) return null;
    const semi = lastByteBefore(value, ';', dash) orelse return null;
    if (skipSqlInlineWhitespace(value, semi + 1) == dash) return dash;
    return null;
}

fn lastLineStart(value: []const u8) usize {
    var index = value.len;
    while (index > 0) {
        index -= 1;
        if (value[index] == '\n') return index + 1;
    }
    return 0;
}

fn skipSqlInlineWhitespace(value: []const u8, start: usize) usize {
    var index = start;
    while (index < value.len and (value[index] == ' ' or value[index] == '\t' or value[index] == '\r')) {
        index += 1;
    }
    return index;
}

fn lastByteBefore(value: []const u8, needle: u8, before: usize) ?usize {
    var index = @min(before, value.len);
    while (index > 0) {
        index -= 1;
        if (value[index] == needle) return index;
    }
    return null;
}

fn lastIndexOf(value: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > value.len) return null;
    var index = value.len - needle.len + 1;
    while (index > 0) {
        index -= 1;
        if (std.mem.eql(u8, value[index .. index + needle.len], needle)) return index;
    }
    return null;
}

test "renderModelSql creates table materialization SQL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select 1 as id",
        .materialized = "table",
        .compiled = true,
        .compiled_code = "select 1 as id",
        .relation_name = "\"analytics\".\"customers\"",
    });

    const sql = try renderModelSql(allocator, &graph, &graph.nodes.items[0]);
    try std.testing.expectEqualStrings(
        "create schema if not exists \"analytics\";\ncreate or replace table \"analytics\".\"customers\" as (\nselect 1 as id\n);\n",
        sql,
    );
}

test "renderModelSql strips a trailing SQL terminator before wrapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select 1 as id;",
        .materialized = "view",
        .compiled = true,
        .compiled_code = "select 1 as id;\n",
        .relation_name = "\"analytics\".\"customers\"",
    });

    const sql = try renderModelSql(allocator, &graph, &graph.nodes.items[0]);
    try std.testing.expectEqualStrings(
        "create schema if not exists \"analytics\";\ncreate or replace view \"analytics\".\"customers\" as (\nselect 1 as id\n);\n",
        sql,
    );
}

test "trimTrailingSqlTerminator preserves inner semicolons" {
    try std.testing.expectEqualStrings("select ';' as value", trimTrailingSqlTerminator("select ';' as value;\n"));
    try std.testing.expectEqualStrings("select ';' as value", trimTrailingSqlTerminator("select ';' as value"));
    try std.testing.expectEqualStrings("select 1", trimTrailingSqlTerminator("select 1;\n-- trailing note\n"));
    try std.testing.expectEqualStrings("select 1", trimTrailingSqlTerminator("select 1; -- noqa\n"));
    try std.testing.expectEqualStrings("select 1", trimTrailingSqlTerminator("select 1; /* trailing */\n"));
    try std.testing.expectEqualStrings("select 1 -- trailing note", trimTrailingSqlTerminator("select 1 -- trailing note\n"));
    try std.testing.expectEqualStrings("select 1 /* trailing */", trimTrailingSqlTerminator("select 1 /* trailing */\n"));
}

test "renderModelSql rejects unsupported materialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select 1 as id",
        .materialized = "incremental",
        .compiled = true,
        .compiled_code = "select 1 as id",
    });

    try std.testing.expectError(error.UnsupportedModelMaterialization, renderModelSql(allocator, &graph, &graph.nodes.items[0]));
}

test "renderDropSql targets the opposite materialization relation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select 1 as id",
        .materialized = "view",
        .relation_name = "\"analytics\".\"customers\"",
    });

    const sql = try renderDropSql(allocator, &graph, &graph.nodes.items[0], .table);
    try std.testing.expectEqualStrings("drop table if exists \"analytics\".\"customers\";\n", sql);
}

test "quoteSqlString escapes embedded quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const rendered = try quoteSqlString(arena.allocator(), "a'b");
    try std.testing.expectEqualStrings("'a''b'", rendered);
}

test "renderGenericTestSql renders not_null failure row query and wrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select 1 as id",
        .relation_name = "\"analytics\".\"customers\"",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.not_null_customers_customer_id.abc",
        .name = "not_null_customers_customer_id",
        .alias = "not_null_customers_customer_id",
        .path = "not_null_customers_customer_id.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_not_null(**_dbt_generic_test_kwargs) }}",
        .test_name = "not_null",
        .column_name = "customer_id",
        .attached_node = "model.demo.customers",
    });

    const sql = try renderGenericTestSql(allocator, &graph, &graph.tests.items[0]);
    try std.testing.expectEqualStrings(
        "select \"customer_id\"\nfrom \"analytics\".\"customers\"\nwhere \"customer_id\" is null",
        sql,
    );
    const execution_sql = try renderGenericTestExecutionSql(allocator, sql);
    try std.testing.expectEqualStrings(
        "select\n  count(*) as failures,\n  count(*) != 0 as should_warn,\n  count(*) != 0 as should_error\nfrom (\nselect \"customer_id\"\nfrom \"analytics\".\"customers\"\nwhere \"customer_id\" is null\n) dbt_internal_test;\n",
        execution_sql,
    );
    const terminated_execution_sql = try renderGenericTestExecutionSql(allocator, "select 1 as failure_row; -- dbt singular test note\n");
    try std.testing.expectEqualStrings(
        "select\n  count(*) as failures,\n  count(*) != 0 as should_warn,\n  count(*) != 0 as should_error\nfrom (\nselect 1 as failure_row\n) dbt_internal_test;\n",
        terminated_execution_sql,
    );
}

test "renderGenericTestSql renders unique failure row query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select 1 as id",
        .relation_name = "\"analytics\".\"customers\"",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.unique_customers_customer_id.abc",
        .name = "unique_customers_customer_id",
        .alias = "unique_customers_customer_id",
        .path = "unique_customers_customer_id.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_unique(**_dbt_generic_test_kwargs) }}",
        .test_name = "unique",
        .column_name = "customer_id",
        .attached_node = "model.demo.customers",
    });

    const sql = try renderGenericTestSql(allocator, &graph, &graph.tests.items[0]);
    try std.testing.expectEqualStrings(
        "select\n    \"customer_id\" as unique_field,\n    count(*) as n_records\nfrom \"analytics\".\"customers\"\nwhere \"customer_id\" is not null\ngroup by \"customer_id\"\nhaving count(*) > 1",
        sql,
    );
}

test "renderGenericTestSql renders accepted_values failure row query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select 1 as id",
        .relation_name = "\"analytics\".\"customers\"",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.accepted_values_customers_customer_type__new__Bob_s.abc",
        .name = "accepted_values_customers_customer_type__new__Bob_s",
        .alias = "accepted_values_customers_customer_type__new__Bob_s",
        .path = "accepted_values_customers_customer_type__new__Bob_s.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_accepted_values(**_dbt_generic_test_kwargs) }}",
        .test_name = "accepted_values",
        .column_name = "customer_type",
        .attached_node = "model.demo.customers",
    });
    try graph.tests.items[0].accepted_values.append(allocator, "new");
    try graph.tests.items[0].accepted_values.append(allocator, "Bob's");

    const sql = try renderGenericTestSql(allocator, &graph, &graph.tests.items[0]);
    try std.testing.expectEqualStrings(
        "with all_values as (\n    select\n        \"customer_type\" as value_field,\n        count(*) as n_records\n    from \"analytics\".\"customers\"\n    group by \"customer_type\"\n)\nselect *\nfrom all_values\nwhere value_field not in ('new', 'Bob''s')",
        sql,
    );
}

test "renderGenericTestSql renders accepted_values quote false raw values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select 1 as id",
        .relation_name = "\"analytics\".\"customers\"",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.accepted_values_customers_customer_id__False__1__2.abc",
        .name = "accepted_values_customers_customer_id__False__1__2",
        .alias = "accepted_values_customers_customer_id__False__1__2",
        .path = "accepted_values_customers_customer_id__False__1__2.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_accepted_values(**_dbt_generic_test_kwargs) }}",
        .test_name = "accepted_values",
        .column_name = "customer_id",
        .accepted_values_quote = false,
        .attached_node = "model.demo.customers",
    });
    try graph.tests.items[0].accepted_values.append(allocator, "1");
    try graph.tests.items[0].accepted_values.append(allocator, "2");

    const sql = try renderGenericTestSql(allocator, &graph, &graph.tests.items[0]);
    try std.testing.expectEqualStrings(
        "with all_values as (\n    select\n        \"customer_id\" as value_field,\n        count(*) as n_records\n    from \"analytics\".\"customers\"\n    group by \"customer_id\"\n)\nselect *\nfrom all_values\nwhere value_field not in (1, 2)",
        sql,
    );
}

test "renderGenericTestSql renders source generic tests against source relation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    try graph.sources.append(allocator, .{
        .package_name = "demo",
        .unique_id = "source.demo.raw.customers",
        .source_name = "raw",
        .table_name = "customers",
        .identifier = "raw_customers",
        .database = "raw_db",
        .quoting = .{ .database = false, .schema = true, .identifier = false },
        .original_file_path = "models/schema.yml",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.source_not_null_raw_customers_customer_id.abc",
        .name = "source_not_null_raw_customers_customer_id",
        .alias = "source_not_null_raw_customers_customer_id",
        .path = "source_not_null_raw_customers_customer_id.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_not_null(**_dbt_generic_test_kwargs) }}",
        .test_name = "not_null",
        .column_name = "customer_id",
    });
    try graph.tests.items[0].source_refs.append(allocator, .{ .source_name = "raw", .table_name = "customers" });
    try graph.tests.items[0].depends_on.append(allocator, "source.demo.raw.customers");

    const sql = try renderGenericTestSql(allocator, &graph, &graph.tests.items[0]);
    try std.testing.expectEqualStrings(
        "select \"customer_id\"\nfrom raw_db.\"raw\".raw_customers\nwhere \"customer_id\" is null",
        sql,
    );
}

test "renderGenericTestSql renders source relationships against ref target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.sources.append(allocator, .{
        .package_name = "demo",
        .unique_id = "source.demo.raw.orders",
        .source_name = "raw",
        .table_name = "orders",
        .identifier = "raw_orders",
        .schema_name = "raw",
        .original_file_path = "models/schema.yml",
    });
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select 1 as customer_id",
        .materialized = "table",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.source_relationships_raw_orders_customer_id__customer_id__ref_customers_.abc",
        .name = "source_relationships_raw_orders_customer_id__customer_id__ref_customers_",
        .alias = "source_relationships_raw_orders_customer_id__customer_id__ref_customers_",
        .path = "source_relationships_raw_orders_customer_id__customer_id__ref_customers_.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_relationships(**_dbt_generic_test_kwargs) }}",
        .test_name = "relationships",
        .column_name = "customer_id",
        .relationship_to = "ref('customers')",
        .relationship_field = "customer_id",
    });
    try graph.tests.items[0].refs.append(allocator, .{ .package = null, .name = "customers" });
    try graph.tests.items[0].source_refs.append(allocator, .{ .source_name = "raw", .table_name = "orders" });
    try graph.tests.items[0].depends_on.append(allocator, "model.demo.customers");
    try graph.tests.items[0].depends_on.append(allocator, "source.demo.raw.orders");

    const sql = try renderGenericTestSql(allocator, &graph, &graph.tests.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, sql, "from \"raw\".\"raw_orders\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "from \"main\".\"customers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "left join parent") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "where parent.to_field is null") != null);
}

test "renderGenericTestSql renders source relationships against source target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.sources.append(allocator, .{
        .package_name = "demo",
        .unique_id = "source.demo.raw.orders",
        .source_name = "raw",
        .table_name = "orders",
        .identifier = "raw_orders",
        .schema_name = "raw",
        .original_file_path = "models/schema.yml",
    });
    try graph.sources.append(allocator, .{
        .package_name = "demo",
        .unique_id = "source.demo.raw.customers",
        .source_name = "raw",
        .table_name = "customers",
        .identifier = "raw_customers",
        .schema_name = "raw",
        .original_file_path = "models/schema.yml",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.source_relationships_raw_orders_customer_id__customer_id__source_raw_customers_.abc",
        .name = "source_relationships_raw_orders_customer_id__customer_id__source_raw_customers_",
        .alias = "source_relationships_raw_orders_customer_id__customer_id__source_raw_customers_",
        .path = "source_relationships_raw_orders_customer_id__customer_id__source_raw_customers_.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_relationships(**_dbt_generic_test_kwargs) }}",
        .test_name = "relationships",
        .column_name = "customer_id",
        .relationship_to = "source('raw', 'customers')",
        .relationship_field = "customer_id",
        .attached_source = .{ .source_name = "raw", .table_name = "orders" },
        .relationship_source_to = .{ .source_name = "raw", .table_name = "customers" },
    });
    try graph.tests.items[0].source_refs.append(allocator, .{ .source_name = "raw", .table_name = "customers" });
    try graph.tests.items[0].source_refs.append(allocator, .{ .source_name = "raw", .table_name = "orders" });
    try graph.tests.items[0].depends_on.append(allocator, "source.demo.raw.customers");
    try graph.tests.items[0].depends_on.append(allocator, "source.demo.raw.orders");

    const sql = try renderGenericTestSql(allocator, &graph, &graph.tests.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, sql, "from \"raw\".\"raw_orders\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "from \"raw\".\"raw_customers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "left join parent") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "where parent.to_field is null") != null);
}

test "renderGenericTestSql renders model relationships against source target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select 1 as customer_id",
        .relation_name = "\"analytics\".\"orders\"",
    });
    try graph.sources.append(allocator, .{
        .package_name = "demo",
        .unique_id = "source.demo.raw.customers",
        .source_name = "raw",
        .table_name = "customers",
        .identifier = "raw_customers",
        .schema_name = "raw",
        .original_file_path = "models/schema.yml",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.relationships_orders_customer_id__customer_id__source_raw_customers_.abc",
        .name = "relationships_orders_customer_id__customer_id__source_raw_customers_",
        .alias = "relationships_orders_customer_id__customer_id__source_raw_customers_",
        .path = "relationships_orders_customer_id__customer_id__source_raw_customers_.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_relationships(**_dbt_generic_test_kwargs) }}",
        .test_name = "relationships",
        .column_name = "customer_id",
        .relationship_to = "source('raw', 'customers')",
        .relationship_field = "customer_id",
        .attached_node = "model.demo.orders",
        .relationship_source_to = .{ .source_name = "raw", .table_name = "customers" },
    });
    try graph.tests.items[0].source_refs.append(allocator, .{ .source_name = "raw", .table_name = "customers" });
    try graph.tests.items[0].depends_on.append(allocator, "source.demo.raw.customers");
    try graph.tests.items[0].depends_on.append(allocator, "model.demo.orders");

    const sql = try renderGenericTestSql(allocator, &graph, &graph.tests.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, sql, "from \"analytics\".\"orders\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "from \"raw\".\"raw_customers\"") != null);
}

test "renderGenericTestSql resolves source target by unique id when names overlap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select 1 as customer_id",
    });
    try graph.sources.append(allocator, .{
        .package_name = "pkg",
        .unique_id = "source.pkg.raw.customers",
        .source_name = "raw",
        .table_name = "customers",
        .identifier = "pkg_customers",
        .schema_name = "pkg_raw",
        .original_file_path = "dbt_packages/pkg/models/schema.yml",
    });
    try graph.sources.append(allocator, .{
        .package_name = "demo",
        .unique_id = "source.demo.raw.customers",
        .source_name = "raw",
        .table_name = "customers",
        .identifier = "raw_customers",
        .schema_name = "raw",
        .original_file_path = "models/schema.yml",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.relationships_orders_customer_id__customer_id__source_raw_customers_.abc",
        .name = "relationships_orders_customer_id__customer_id__source_raw_customers_",
        .alias = "relationships_orders_customer_id__customer_id__source_raw_customers_",
        .path = "relationships_orders_customer_id__customer_id__source_raw_customers_.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_relationships(**_dbt_generic_test_kwargs) }}",
        .test_name = "relationships",
        .column_name = "customer_id",
        .relationship_to = "source('raw', 'customers')",
        .relationship_field = "customer_id",
        .attached_node = "model.demo.orders",
        .relationship_source_to = .{ .source_name = "raw", .table_name = "customers" },
        .relationship_source_to_unique_id = "source.demo.raw.customers",
    });

    const sql = try renderGenericTestSql(allocator, &graph, &graph.tests.items[0]);
    try std.testing.expect(std.mem.indexOf(u8, sql, "from \"raw\".\"raw_customers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "from \"pkg_raw\".\"pkg_customers\"") == null);
}

test "renderGenericTestSql renders relationships failure row query" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select 1 as customer_id",
        .relation_name = "\"analytics\".\"customers\"",
    });
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select 1 as order_id, 1 as customer_id",
        .relation_name = "\"analytics\".\"orders\"",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.relationships_orders_customer_id__customer_id__ref_customers_.abc",
        .name = "relationships_orders_customer_id__customer_id__ref_customers_",
        .alias = "relationships_orders_customer_id__customer_id__ref_customers_",
        .path = "relationships_orders_customer_id__customer_id__ref_customers_.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_relationships(**_dbt_generic_test_kwargs) }}",
        .test_name = "relationships",
        .column_name = "customer_id",
        .relationship_to = "ref('customers')",
        .relationship_field = "customer_id",
        .attached_node = "model.demo.orders",
    });
    try graph.tests.items[0].depends_on.append(allocator, "model.demo.customers");
    try graph.tests.items[0].depends_on.append(allocator, "model.demo.orders");

    const sql = try renderGenericTestSql(allocator, &graph, &graph.tests.items[0]);
    try std.testing.expectEqualStrings(
        "with child as (\n    select \"customer_id\" as from_field\n    from \"analytics\".\"orders\"\n    where \"customer_id\" is not null\n),\nparent as (\n    select \"customer_id\" as to_field\n    from \"analytics\".\"customers\"\n)\nselect\n    from_field\nfrom child\nleft join parent\n    on child.from_field = parent.to_field\nwhere parent.to_field is null",
        sql,
    );
}

test "renderGenericTestSql rejects unsupported relationships shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select 1 as order_id, 1 as customer_id",
        .relation_name = "\"analytics\".\"orders\"",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.relationships_orders_customer_id__customer_id__ref_customers_.abc",
        .name = "relationships_orders_customer_id__customer_id__ref_customers_",
        .alias = "relationships_orders_customer_id__customer_id__ref_customers_",
        .path = "relationships_orders_customer_id__customer_id__ref_customers_.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_relationships(**_dbt_generic_test_kwargs) }}",
        .test_name = "relationships",
        .column_name = "customer_id",
        .relationship_to = "ref('customers')",
        .relationship_field = "customer_id",
        .attached_node = "model.demo.orders",
    });
    try std.testing.expectError(error.UnsupportedTestExecution, renderGenericTestSql(allocator, &graph, &graph.tests.items[0]));

    try graph.tests.items[0].depends_on.append(allocator, "model.demo.orders");
    graph.tests.items[0].relationship_field = "";
    try std.testing.expectError(error.UnsupportedTestExecution, renderGenericTestSql(allocator, &graph, &graph.tests.items[0]));
}

test "renderGenericTestSql rejects unsupported accepted_values shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select 1 as id",
        .relation_name = "\"analytics\".\"customers\"",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.accepted_values_customers_customer_type.abc",
        .name = "accepted_values_customers_customer_type",
        .alias = "accepted_values_customers_customer_type",
        .path = "accepted_values_customers_customer_type.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_accepted_values(**_dbt_generic_test_kwargs) }}",
        .test_name = "accepted_values",
        .column_name = "customer_type",
        .attached_node = "model.demo.customers",
    });
    try std.testing.expectError(error.UnsupportedTestExecution, renderGenericTestSql(allocator, &graph, &graph.tests.items[0]));

    graph.tests.items[0].column_name = null;
    try graph.tests.items[0].accepted_values.append(allocator, "new");
    try std.testing.expectError(error.UnsupportedTestExecution, renderGenericTestSql(allocator, &graph, &graph.tests.items[0]));
}

test "firstCsvField reads the leading failures value" {
    try std.testing.expectEqualStrings("12", firstCsvField("12,true,true\n").?);
    try std.testing.expectEqualStrings("0", firstCsvField(" 0 \n").?);
    try std.testing.expect(firstCsvField("\n") == null);
}

test "databasePath resolves configured relative path from profile base" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{
        .allocator = allocator,
        .project_name = "demo",
        .database_path = "warehouse.duckdb",
        .database_path_base = "profiles",
    };
    defer graph.deinit();

    const resolved = try databasePath(allocator, "target", &graph);
    try std.testing.expectEqualStrings("profiles/warehouse.duckdb", resolved);
}

test "databasePath rejects unsupported connection strings for CLI backend" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{
        .allocator = allocator,
        .project_name = "demo",
        .database_path = ":memory:",
    };
    defer graph.deinit();

    try std.testing.expectError(error.UnsupportedDuckDbPath, databasePath(allocator, "target", &graph));
}

test "catalogEntryForNode maps DuckDB JSON rows to catalog metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "main" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select 1",
        .materialized = "table",
    });

    const rows_json =
        \\[
        \\  {"table_catalog":"dxt","table_schema":"main","table_name":"customers","table_type":"VIEW","column_name":"customer_id","ordinal_position":1,"data_type":"INTEGER"},
        \\  {"table_catalog":"dxt","table_schema":"main","table_name":"orders","table_type":"BASE TABLE","column_name":"customer_id","ordinal_position":1,"data_type":"INTEGER"},
        \\  {"table_catalog":"dxt","table_schema":"main","table_name":"orders","table_type":"BASE TABLE","column_name":"order_count","ordinal_position":2,"data_type":"BIGINT"}
        \\]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rows_json, .{});
    defer parsed.deinit();
    const entry = (try catalogEntryForNode(allocator, &graph, &graph.nodes.items[0], parsed.value.array.items)).?;
    defer {
        var owned = entry;
        deinitCatalogEntry(allocator, &owned);
    }

    try std.testing.expectEqualStrings("model.demo.orders", entry.unique_id);
    try std.testing.expectEqualStrings("main", entry.schema);
    try std.testing.expectEqualStrings("orders", entry.name);
    try std.testing.expectEqualStrings("BASE TABLE", entry.relation_type);
    try std.testing.expectEqual(@as(usize, 2), entry.columns.items.len);
    try std.testing.expectEqualStrings("customer_id", entry.columns.items[0].name);
    try std.testing.expectEqualStrings("INTEGER", entry.columns.items[0].data_type);
    try std.testing.expectEqual(@as(u64, 2), entry.columns.items[1].index);
    try std.testing.expectEqualStrings("BIGINT", entry.columns.items[1].data_type);
}

test "catalogEntryForSource maps DuckDB JSON rows to catalog source metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = SourceDef{
        .package_name = "demo",
        .unique_id = "source.demo.raw.customers",
        .source_name = "raw",
        .table_name = "customers",
        .identifier = "raw_customers",
        .database = "dxt",
        .original_file_path = "models/schema.yml",
        .schema_name = "analytics_raw",
    };

    const rows_json =
        \\[
        \\  {"table_catalog":"dxt","table_schema":"analytics_raw","table_name":"raw_customers","table_type":"BASE TABLE","column_name":"customer_id","ordinal_position":1,"data_type":"INTEGER"}
        \\]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rows_json, .{});
    defer parsed.deinit();
    const entry = (try catalogEntryForSource(allocator, &source, parsed.value.array.items)).?;
    defer {
        var owned = entry;
        deinitCatalogEntry(allocator, &owned);
    }

    try std.testing.expectEqualStrings("source.demo.raw.customers", entry.unique_id);
    try std.testing.expectEqualStrings("dxt", entry.database.?);
    try std.testing.expectEqualStrings("analytics_raw", entry.schema);
    try std.testing.expectEqualStrings("raw_customers", entry.name);
    try std.testing.expectEqualStrings("BASE TABLE", entry.relation_type);
    try std.testing.expectEqualStrings("customer_id", entry.columns.items[0].name);
    try std.testing.expectEqualStrings("INTEGER", entry.columns.items[0].data_type);
}

test "renderSourceFreshnessSql quotes source relation and renders loaded_at_field as SQL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = SourceDef{
        .package_name = "demo",
        .unique_id = "source.demo.raw.orders",
        .source_name = "raw",
        .table_name = "orders",
        .identifier = "raw_orders",
        .database = "raw_db",
        .original_file_path = "models/schema.yml",
        .schema_name = "analytics_raw",
        .quoting = .{ .database = false, .schema = true, .identifier = false },
        .loaded_at_field = "loaded_at",
        .freshness = .{ .filter = "order_id > 0" },
    };

    const sql = try renderSourceFreshnessSql(allocator, &source);
    try std.testing.expectEqualStrings(
        "select coalesce(strftime(max(loaded_at), '%Y-%m-%dT%H:%M:%SZ'), '0001-01-01T00:00:00Z') as max_loaded_at, strftime(current_timestamp, '%Y-%m-%dT%H:%M:%SZ') as snapshotted_at, coalesce(epoch(current_timestamp) - epoch(max(loaded_at)), 9.223372036854776e18) as age_seconds from raw_db.\"analytics_raw\".raw_orders where order_id > 0;",
        sql,
    );

    const expression_source = SourceDef{
        .package_name = "demo",
        .unique_id = "source.demo.raw.events",
        .source_name = "raw",
        .table_name = "events",
        .original_file_path = "models/schema.yml",
        .loaded_at_field = "cast(loaded_at as timestamp)",
        .freshness = .{},
    };
    const expression_sql = try renderSourceFreshnessSql(allocator, &expression_source);
    try std.testing.expect(std.mem.indexOf(u8, expression_sql, "max(cast(loaded_at as timestamp))") != null);
}

test "renderSourceFreshnessSql renders loaded_at_query as custom freshness SQL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = SourceDef{
        .package_name = "demo",
        .unique_id = "source.demo.raw.orders",
        .source_name = "raw",
        .table_name = "orders",
        .original_file_path = "models/schema.yml",
        .loaded_at_query = "select max(loaded_at) from raw.orders",
        .freshness = .{ .filter = "ignored_for_custom_sql" },
    };

    const sql = try renderSourceFreshnessSql(allocator, &source);
    try std.testing.expectEqualStrings(
        "with source_query as (select max(loaded_at) from raw.orders), freshness as (select (select * from source_query) as max_loaded_at, current_timestamp as snapshotted_at) select coalesce(strftime(max_loaded_at, '%Y-%m-%dT%H:%M:%SZ'), '0001-01-01T00:00:00Z') as max_loaded_at, strftime(snapshotted_at, '%Y-%m-%dT%H:%M:%SZ') as snapshotted_at, coalesce(epoch(snapshotted_at) - epoch(max_loaded_at), 9.223372036854776e18) as age_seconds from freshness;",
        sql,
    );
    try std.testing.expect(std.mem.indexOf(u8, sql, "ignored_for_custom_sql") == null);
}

test "renderSeedSql creates table from root project seed CSV" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .resource_type = "seed",
        .package_name = "demo",
        .unique_id = "seed.demo.raw_customers",
        .name = "raw_customers",
        .path = "raw_customers.csv",
        .original_file_path = "seeds/raw_customers.csv",
        .raw_code = "",
        .materialized = "seed",
    });

    const sql = try renderSeedSql(allocator, "project", &graph, &graph.nodes.items[0]);
    try std.testing.expectEqualStrings(
        "create schema if not exists \"analytics\";\ncreate or replace table \"analytics\".\"raw_customers\" as select * from read_csv_auto('project/seeds/raw_customers.csv', header = true);\n",
        sql,
    );
}

test "renderSeedSql creates table from installed package seed CSV" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .resource_type = "seed",
        .package_name = "pkg",
        .unique_id = "seed.pkg.raw_customers",
        .name = "raw_customers",
        .project_root = try allocator.dupe(u8, "project/dbt_packages/pkg"),
        .path = "raw_customers.csv",
        .original_file_path = "seeds/raw_customers.csv",
        .raw_code = "",
        .materialized = "seed",
    });

    const sql = try renderSeedSql(allocator, "project", &graph, &graph.nodes.items[0]);
    try std.testing.expectEqualStrings(
        "create schema if not exists \"analytics\";\ncreate or replace table \"analytics\".\"raw_customers\" as select * from read_csv_auto('project/dbt_packages/pkg/seeds/raw_customers.csv', header = true);\n",
        sql,
    );
}

test "renderSeedSql rejects unsafe seed file paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .resource_type = "seed",
        .package_name = "demo",
        .unique_id = "seed.demo.outside",
        .name = "outside",
        .path = "outside.csv",
        .original_file_path = "../outside.csv",
        .raw_code = "",
        .materialized = "seed",
    });

    try std.testing.expectError(error.UnsupportedSeedExecution, renderSeedSql(allocator, "project", &graph, &graph.nodes.items[0]));
}

test "quoteSqlString escapes single quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const quoted = try quoteSqlString(allocator, "seed's/file.csv");
    try std.testing.expectEqualStrings("'seed''s/file.csv'", quoted);
}
