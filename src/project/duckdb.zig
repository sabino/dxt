const std = @import("std");
const compiler = @import("compiler.zig");
const project_fs = @import("fs.zig");
const types = @import("types.zig");

const Runtime = types.Runtime;
const Graph = types.Graph;
const Node = types.Node;
const GenericTestNode = types.GenericTestNode;

const DuckDbObjectKind = enum { table, view };

pub const GenericTestExecutionResult = struct {
    compiled_code: []const u8,
    failures: u64,
};

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
    if (!std.mem.eql(u8, node.package_name, graph.project_name)) {
        return error.UnsupportedSeedExecution;
    }

    const seed_file_path = try project_fs.pathJoin(allocator, &.{ project_dir, node.original_file_path });
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

pub fn renderGenericTestSql(allocator: std.mem.Allocator, graph: *const Graph, test_node: *const GenericTestNode) ![]const u8 {
    const column_name = test_node.column_name orelse return error.UnsupportedTestExecution;
    if (!std.mem.eql(u8, test_node.test_name, "not_null") and !std.mem.eql(u8, test_node.test_name, "unique")) {
        return error.UnsupportedTestExecution;
    }

    const attached_node = findNodeByUniqueId(graph, test_node.attached_node) orelse return error.UnsupportedTestExecution;
    const relation_name = attached_node.relation_name orelse try compiler.relationNameForNode(allocator, graph, attached_node);
    const should_free_relation = attached_node.relation_name == null;
    defer if (should_free_relation) allocator.free(relation_name);
    const quoted_column = try compiler.quoteIdentifier(allocator, column_name);
    defer allocator.free(quoted_column);

    if (std.mem.eql(u8, test_node.test_name, "not_null")) {
        return try std.fmt.allocPrint(
            allocator,
            "select {s}\nfrom {s}\nwhere {s} is null",
            .{ quoted_column, relation_name, quoted_column },
        );
    }
    return try std.fmt.allocPrint(
        allocator,
        "select\n    {s} as unique_field,\n    count(*) as n_records\nfrom {s}\nwhere {s} is not null\ngroup by {s}\nhaving count(*) > 1",
        .{ quoted_column, relation_name, quoted_column, quoted_column },
    );
}

pub fn renderGenericTestExecutionSql(allocator: std.mem.Allocator, compiled_sql: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(
        allocator,
        "select\n  count(*) as failures,\n  count(*) != 0 as should_warn,\n  count(*) != 0 as should_error\nfrom (\n{s}\n) dbt_internal_test;\n",
        .{compiled_sql},
    );
}

fn findNodeByUniqueId(graph: *const Graph, unique_id: []const u8) ?*const Node {
    for (graph.nodes.items) |*node| {
        if (std.mem.eql(u8, node.unique_id, unique_id)) return node;
    }
    return null;
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

test "quoteSqlString escapes single quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const quoted = try quoteSqlString(allocator, "seed's/file.csv");
    try std.testing.expectEqualStrings("'seed''s/file.csv'", quoted);
}
