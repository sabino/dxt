const std = @import("std");
const compiler = @import("compiler.zig");
const project_parse = @import("parse.zig");
const project_resolve = @import("resolve.zig");
const types = @import("types.zig");

const Graph = types.Graph;
const JsonScalar = types.JsonScalar;
const Node = types.Node;
const SourceDef = types.SourceDef;
const UnitTestDef = types.UnitTestDef;
const UnitTestFixture = types.UnitTestFixture;
const UnitTestRow = types.UnitTestRow;

pub const PlannedUnitTestSql = struct {
    execution_sql: []const u8,
    compiled_code: []const u8,

    pub fn deinit(self: *PlannedUnitTestSql, allocator: std.mem.Allocator) void {
        allocator.free(self.execution_sql);
        allocator.free(self.compiled_code);
        self.* = .{ .execution_sql = "", .compiled_code = "" };
    }
};

const ResolvedFixtureInput = struct {
    relation_name: []const u8,
    create_schema_name: []const u8,

    fn deinit(self: *ResolvedFixtureInput, allocator: std.mem.Allocator) void {
        allocator.free(self.relation_name);
        allocator.free(self.create_schema_name);
        self.* = .{ .relation_name = "", .create_schema_name = "" };
    }
};

pub fn validateUnitTest(allocator: std.mem.Allocator, graph: *const Graph, unit_test: *const UnitTestDef) !void {
    _ = try modelNodeForUnitTest(graph, unit_test);
    try validateOutputFixture(unit_test.expect);
    for (unit_test.given.items) |fixture| {
        try validateInputFixture(fixture);
        var resolved = try resolveFixtureInput(allocator, graph, unit_test, fixture.input.?);
        resolved.deinit(allocator);
    }
}

pub fn renderUnitTestSql(allocator: std.mem.Allocator, graph: *const Graph, unit_test: *const UnitTestDef) !PlannedUnitTestSql {
    try validateUnitTest(allocator, graph, unit_test);
    const model_node = try modelNodeForUnitTest(graph, unit_test);

    var compiled_model = try compiler.compileModelWithInjectedCtes(allocator, graph, model_node);
    defer compiled_model.deinit(allocator);

    var setup: std.ArrayList(u8) = .empty;
    defer setup.deinit(allocator);
    for (unit_test.given.items) |fixture| {
        var resolved = try resolveFixtureInput(allocator, graph, unit_test, fixture.input.?);
        defer resolved.deinit(allocator);
        const fixture_sql = try renderInputFixtureSql(allocator, resolved, fixture);
        defer allocator.free(fixture_sql);
        try setup.appendSlice(allocator, fixture_sql);
    }

    const comparison_sql = try renderComparisonSql(allocator, compiled_model.compiled_code, unit_test.expect);
    errdefer allocator.free(comparison_sql);
    const execution_sql = try std.fmt.allocPrint(
        allocator,
        "begin transaction;\n{s}{s}\nrollback;\n",
        .{ setup.items, comparison_sql },
    );
    errdefer allocator.free(execution_sql);

    return .{ .execution_sql = execution_sql, .compiled_code = comparison_sql };
}

fn validateInputFixture(fixture: UnitTestFixture) !void {
    if (fixture.input == null) return error.UnsupportedUnitTestExecution;
    try validateRowsFixture(fixture);
    if (fixture.rows.items.len == 0) return error.UnsupportedUnitTestExecution;
}

fn validateOutputFixture(fixture: UnitTestFixture) !void {
    try validateRowsFixture(fixture);
}

fn validateRowsFixture(fixture: UnitTestFixture) !void {
    if (!std.mem.eql(u8, fixture.format, "dict")) return error.UnsupportedUnitTestExecution;
    if (fixture.fixture != null or fixture.rows_string != null or !fixture.rows_set) return error.UnsupportedUnitTestExecution;
    if (fixture.rows.items.len == 0) return;
    const columns = fixture.rows.items[0].entries.items;
    if (columns.len == 0) return error.UnsupportedUnitTestExecution;
    for (columns, 0..) |column, index| {
        if (column.key.len == 0) return error.UnsupportedUnitTestExecution;
        var prior: usize = 0;
        while (prior < index) : (prior += 1) {
            if (std.mem.eql(u8, columns[prior].key, column.key)) return error.UnsupportedUnitTestExecution;
        }
    }
    for (fixture.rows.items[1..]) |row| {
        if (row.entries.items.len != columns.len) return error.UnsupportedUnitTestExecution;
        for (columns, row.entries.items) |expected, actual| {
            if (!std.mem.eql(u8, expected.key, actual.key)) return error.UnsupportedUnitTestExecution;
        }
    }
}

fn modelNodeForUnitTest(graph: *const Graph, unit_test: *const UnitTestDef) !*const Node {
    const unique_id = try std.fmt.allocPrint(graph.allocator, "model.{s}.{s}", .{ unit_test.package_name, unit_test.model });
    defer graph.allocator.free(unique_id);
    for (graph.nodes.items) |*node| {
        if (!node.enabled or !std.mem.eql(u8, node.unique_id, unique_id)) continue;
        if (!std.mem.eql(u8, node.resource_type, "model")) return error.UnsupportedUnitTestExecution;
        if (std.mem.eql(u8, node.materialized, "ephemeral")) return error.UnsupportedUnitTestExecution;
        return node;
    }
    return error.UnresolvedUnitTestModel;
}

fn resolveFixtureInput(allocator: std.mem.Allocator, graph: *const Graph, unit_test: *const UnitTestDef, raw_input: []const u8) !ResolvedFixtureInput {
    const trimmed = std.mem.trim(u8, raw_input, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "source(")) {
        const source_dep = try project_parse.sourceDepFromValue(allocator, trimmed);
        const unique_id = try project_resolve.resolveSourceDependency(graph, unit_test.package_name, source_dep);
        const source = findSourceByUniqueId(graph, unique_id) orelse return error.UnresolvedSource;
        if (source.database != null) return error.UnsupportedUnitTestExecution;
        return try resolveSourceFixtureInput(allocator, source);
    }

    const ref_dep = try project_parse.refDepFromValue(allocator, trimmed);
    const unique_id = try project_resolve.resolveRefDependency(graph, unit_test.package_name, ref_dep);
    const node = findNodeByUniqueId(graph, unique_id) orelse return error.UnresolvedRef;
    if (std.mem.eql(u8, node.resource_type, "model") and std.mem.eql(u8, node.materialized, "ephemeral")) return error.UnsupportedUnitTestExecution;
    const relation_name = try compiler.relationNameForNode(allocator, graph, node);
    errdefer allocator.free(relation_name);
    const schema = try compiler.relationSchemaForNode(allocator, graph, node);
    defer allocator.free(schema);
    const create_schema_name = try compiler.quoteIdentifier(allocator, schema);
    errdefer allocator.free(create_schema_name);
    return .{ .relation_name = relation_name, .create_schema_name = create_schema_name };
}

fn resolveSourceFixtureInput(allocator: std.mem.Allocator, source: *const SourceDef) !ResolvedFixtureInput {
    if ((source.quoting.database orelse true) == false or
        (source.quoting.schema orelse true) == false or
        (source.quoting.identifier orelse true) == false)
    {
        return error.UnsupportedUnitTestExecution;
    }
    const relation_name = try compiler.relationNameForSource(allocator, source);
    errdefer allocator.free(relation_name);
    const schema = compiler.sourceSchemaName(source);
    const create_schema_name = try compiler.quoteIdentifier(allocator, schema);
    errdefer allocator.free(create_schema_name);
    return .{ .relation_name = relation_name, .create_schema_name = create_schema_name };
}

fn renderInputFixtureSql(allocator: std.mem.Allocator, resolved: ResolvedFixtureInput, fixture: UnitTestFixture) ![]const u8 {
    const rows_sql = try renderRowsSelectSql(allocator, fixture.rows.items);
    defer allocator.free(rows_sql);
    return try std.fmt.allocPrint(
        allocator,
        "create schema if not exists {s};\ncreate or replace table {s} as\n{s};\n",
        .{ resolved.create_schema_name, resolved.relation_name, rows_sql },
    );
}

pub fn renderComparisonSql(allocator: std.mem.Allocator, model_sql: []const u8, expect: UnitTestFixture) ![]const u8 {
    try validateOutputFixture(expect);
    const query_sql = trimTrailingSqlTerminator(model_sql);
    if (expect.rows.items.len == 0) {
        return try std.fmt.allocPrint(
            allocator,
            "select count(*) as failures from (\n{s}\n) dxt_unit_actual;\n",
            .{query_sql},
        );
    }
    const columns_sql = try renderColumnList(allocator, expect.rows.items[0]);
    defer allocator.free(columns_sql);
    const expected_sql = try renderRowsSelectSql(allocator, expect.rows.items);
    defer allocator.free(expected_sql);
    const indented_query = try indentSql(allocator, query_sql);
    defer allocator.free(indented_query);
    return try std.fmt.allocPrint(
        allocator,
        "with dxt_unit_actual as (\n    select {s}\n    from (\n{s}\n    ) dxt_model_actual\n),\ndxt_unit_expected as (\n{s}\n),\ndxt_actual_minus_expected as (\n    select * from dxt_unit_actual\n    except all\n    select * from dxt_unit_expected\n),\ndxt_expected_minus_actual as (\n    select * from dxt_unit_expected\n    except all\n    select * from dxt_unit_actual\n)\nselect count(*) as failures\nfrom (\n    select * from dxt_actual_minus_expected\n    union all\n    select * from dxt_expected_minus_actual\n) dxt_unit_diff;\n",
        .{ columns_sql, indented_query, expected_sql },
    );
}

fn renderRowsSelectSql(allocator: std.mem.Allocator, rows: []const UnitTestRow) ![]const u8 {
    if (rows.len == 0) return error.UnsupportedUnitTestExecution;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (rows, 0..) |row, row_index| {
        if (row_index != 0) try out.appendSlice(allocator, "\nunion all\n");
        try out.appendSlice(allocator, "select ");
        for (row.entries.items, 0..) |entry, column_index| {
            if (column_index != 0) try out.appendSlice(allocator, ", ");
            const literal = try renderScalarLiteral(allocator, entry.value);
            defer allocator.free(literal);
            const quoted = try compiler.quoteIdentifier(allocator, entry.key);
            defer allocator.free(quoted);
            try out.appendSlice(allocator, literal);
            try out.appendSlice(allocator, " as ");
            try out.appendSlice(allocator, quoted);
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn renderColumnList(allocator: std.mem.Allocator, row: UnitTestRow) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (row.entries.items, 0..) |entry, index| {
        if (index != 0) try out.appendSlice(allocator, ", ");
        const quoted = try compiler.quoteIdentifier(allocator, entry.key);
        defer allocator.free(quoted);
        try out.appendSlice(allocator, quoted);
    }
    return try out.toOwnedSlice(allocator);
}

fn renderScalarLiteral(allocator: std.mem.Allocator, scalar: JsonScalar) ![]const u8 {
    return switch (scalar.kind) {
        .string => quoteSqlString(allocator, scalar.text),
        .number, .bool => allocator.dupe(u8, scalar.text),
        .null => allocator.dupe(u8, "null"),
    };
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
    var end = sql.len;
    while (end > 0 and std.ascii.isWhitespace(sql[end - 1])) end -= 1;
    if (end > 0 and sql[end - 1] == ';') {
        end -= 1;
        while (end > 0 and std.ascii.isWhitespace(sql[end - 1])) end -= 1;
    }
    return sql[0..end];
}

fn indentSql(allocator: std.mem.Allocator, sql: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, sql, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        try out.appendSlice(allocator, "        ");
        try out.appendSlice(allocator, line);
    }
    return try out.toOwnedSlice(allocator);
}

fn findNodeByUniqueId(graph: *const Graph, unique_id: []const u8) ?*const Node {
    for (graph.nodes.items) |*node| {
        if (std.mem.eql(u8, node.unique_id, unique_id)) return node;
    }
    return null;
}

fn findSourceByUniqueId(graph: *const Graph, unique_id: []const u8) ?*const SourceDef {
    for (graph.sources.items) |*source| {
        if (std.mem.eql(u8, source.unique_id, unique_id)) return source;
    }
    return null;
}

test "unit test SQL materializes dict ref fixtures and compares expected rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "main" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.stg_orders",
        .name = "stg_orders",
        .path = "stg_orders.sql",
        .original_file_path = "models/stg_orders.sql",
        .raw_code = "select 1 as order_id, true as has_food",
    });
    var orders = Node{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select * from {{ ref('stg_orders') }} where has_food",
    };
    try orders.depends_on.append(allocator, "model.demo.stg_orders");
    try graph.nodes.append(allocator, orders);

    var unit = UnitTestDef{
        .package_name = "demo",
        .unique_id = "unit_test.demo.orders.assert_food_orders",
        .name = "assert_food_orders",
        .model = "orders",
        .path = "schema.yml",
        .original_file_path = "models/schema.yml",
    };
    defer types.deinitUnitTestDef(allocator, &unit);
    try unit.given.append(allocator, .{ .input = "ref('stg_orders')", .rows_set = true });
    try unit.given.items[0].rows.append(allocator, .{});
    try unit.given.items[0].rows.items[0].entries.append(allocator, .{ .key = "order_id", .value = .{ .text = "1", .kind = .number } });
    try unit.given.items[0].rows.items[0].entries.append(allocator, .{ .key = "has_food", .value = .{ .text = "true", .kind = .bool } });
    unit.expect.rows_set = true;
    try unit.expect.rows.append(allocator, .{});
    try unit.expect.rows.items[0].entries.append(allocator, .{ .key = "order_id", .value = .{ .text = "1", .kind = .number } });
    try unit.expect.rows.items[0].entries.append(allocator, .{ .key = "has_food", .value = .{ .text = "true", .kind = .bool } });

    var planned = try renderUnitTestSql(allocator, &graph, &unit);
    defer planned.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, planned.execution_sql, "begin transaction;") != null);
    try std.testing.expect(std.mem.indexOf(u8, planned.execution_sql, "create or replace table \"main\".\"stg_orders\" as") != null);
    try std.testing.expect(std.mem.indexOf(u8, planned.execution_sql, "except all") != null);
    try std.testing.expect(std.mem.indexOf(u8, planned.execution_sql, "rollback;") != null);
    try std.testing.expect(std.mem.indexOf(u8, planned.compiled_code, "from \"main\".\"stg_orders\"") != null);
}

test "unit test comparison SQL supports empty expectations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const expect = UnitTestFixture{ .rows_set = true };

    const sql = try renderComparisonSql(allocator, "select 1 as id", expect);
    try std.testing.expectEqualStrings(
        "select count(*) as failures from (\nselect 1 as id\n) dxt_unit_actual;\n",
        sql,
    );
}
