//! Native, isolated unit fixtures. Core's dict/CSV fixtures fill omitted input
//! columns with typed NULL; expected dict columns define a partial assertion.
const std = @import("std");
const types = @import("types.zig");
const adapter = @import("adapter.zig");
const compiler = @import("compiler.zig");
const commands = @import("commands.zig");
const plan = @import("unit_test.zig");
const clock = @import("execution_clock.zig");
const values = @import("config_value.zig");
const Column = struct { name: []const u8, data_type: []const u8 };
pub const Result = struct {
    compiled_code: []const u8,
    failures: u64,
    failure_message: ?[]const u8 = null,
    execution_error: bool = false,
    execution_cancelled: bool = false,
    compile_started_at: ?i96 = null,
    compile_completed_at: ?i96 = null,
};

pub fn execute(runtime: types.Runtime, database_path: []const u8, graph: *const types.Graph, unit: *const types.UnitTestDef) !Result {
    try plan.validateUnitTest(runtime.allocator, graph, unit);
    const started = clock.now(runtime.io);
    const a = runtime.allocator;
    var owned_session: ?adapter.Session = null;
    defer if (owned_session) |*session| session.deinit();
    const session = runtime.adapter_session orelse blk: {
        owned_session = try adapter.openUnitSession(runtime, graph);
        break :blk &owned_session.?;
    };
    try session.begin();
    defer session.rollback() catch {};
    var fixture_graph = graph.*;
    fixture_graph.unit_fixture_relations = true;
    fixture_graph.unit_overrides = unit.overrides;
    fixture_graph.deferred_relations = .empty;
    var aliases: std.ArrayList(types.DeferredRelation) = .empty;
    defer aliases.deinit(a);
    for (unit.given.items, 0..) |fixture, i| {
        const id = try plan.fixtureUniqueId(a, graph, unit, fixture.input.?);
        for (aliases.items) |alias| if (std.mem.eql(u8, alias.unique_id, id)) return error.DuplicateUnitTestInput;
        const name = try std.fmt.allocPrint(a, "__dxt_unit_input_{d}", .{i});
        try aliases.append(a, .{ .unique_id = id, .relation_name = try compiler.quoteIdentifier(a, name) });
    }
    fixture_graph.unit_fixture_aliases = aliases.items;
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var unit_runtime = runtime;
    unit_runtime.adapter_session = session;
    var host = try commands.OperationHost.initLazy(unit_runtime, &fixture_graph, ":memory:", &output.writer);
    host.transaction_open = true;
    host.log_events = graph.log_collector;
    defer host.deinit();
    fixture_graph.execution_hooks = host.host();
    // Read only column metadata from the real target; fixture DDL is exclusively
    // temporary and runs on the separate unit connection.
    var real_runtime = runtime;
    real_runtime.adapter_session = null;
    var real_session: ?adapter.Session = null;
    const target_exists = if (std.mem.eql(u8, graph.adapter_type, "duckdb") and !std.mem.eql(u8, database_path, ":memory:")) exists(runtime, database_path) else true;
    if (target_exists) real_session = try adapter.openSession(real_runtime, graph, database_path);
    if (real_session) |*real| if (runtime.cancellation_token) |token| real.setCancellationToken(token);
    defer if (real_session) |*real| real.deinit();
    var fixture_queries: std.ArrayList([]const u8) = .empty;
    defer fixture_queries.deinit(a);
    for (unit.given.items, aliases.items) |fixture, alias| {
        var columns: std.ArrayList(Column) = .empty;
        defer columns.deinit(a);
        if (!std.mem.eql(u8, fixture.format, "sql")) {
            try inputColumns(a, graph, if (real_session) |*real| real else null, &fixture_graph, session, alias.unique_id, &columns);
            if (columns.items.len == 0) try inferredColumns(a, fixture, &columns);
        }
        const query = if (std.mem.eql(u8, fixture.format, "sql")) try a.dupe(u8, plan.trimTrailingSqlTerminator(fixture.rows_string.?)) else try renderRows(a, fixture.rows.items, columns.items);
        try fixture_queries.append(a, query);
        const setup = try std.fmt.allocPrint(a, "create temporary table {s} as select * from (\n{s}\n) __dxt_fixture", .{ alias.relation_name, query });
        defer a.free(setup);
        try session.execute(setup);
    }
    const model = try plan.modelNodeForUnitTest(&fixture_graph, unit);
    var compiled = try compiler.compileModelWithInjectedCtes(a, &fixture_graph, model);
    defer compiled.deinit(a);
    // Bind the actual projection before constructing typed expected rows. LIMIT
    // zero obtains metadata without running the model's relation scan.
    var actual_columns = try bindColumns(a, session, plan.trimTrailingSqlTerminator(compiled.compiled_code));
    defer actual_columns.deinit(a);
    var expected_columns: std.ArrayList(Column) = .empty;
    defer expected_columns.deinit(a);
    if (unit.expect.rows.items.len != 0 and !std.mem.eql(u8, unit.expect.format, "sql")) {
        for (unit.expect.rows.items[0].entries.items) |entry| {
            const actual = findColumn(actual_columns.items, entry.key) orelse return error.UnknownUnitTestColumn;
            try expected_columns.append(a, actual);
        }
    } else try expected_columns.appendSlice(a, actual_columns.items);
    try validateColumns(unit.expect.rows.items, actual_columns.items);
    if (unit.expect.rows.items.len != 0) try validateExpectedRows(unit.expect.rows.items, expected_columns.items);
    const expected = if (std.mem.eql(u8, unit.expect.format, "sql")) try a.dupe(u8, plan.trimTrailingSqlTerminator(unit.expect.rows_string.?)) else try renderProjectedRows(a, unit.expect.rows.items, expected_columns.items);
    defer a.free(expected);
    const projection = try columnList(a, expected_columns.items);
    defer a.free(projection);
    var code: std.Io.Writer.Allocating = .init(a);
    errdefer code.deinit();
    try code.writer.writeAll("with ");
    for (aliases.items, fixture_queries.items) |alias, query| try code.writer.print("{s} as (\n{s}\n),\n", .{ alias.relation_name, query });
    try code.writer.print("dxt_unit_actual as (select {s} from (\n{s}\n) __dxt_actual),\ndxt_unit_expected as (select {s} from (\n{s}\n) __dxt_expected),\ndxt_actual_minus_expected as (select * from dxt_unit_actual except all select * from dxt_unit_expected),\ndxt_expected_minus_actual as (select * from dxt_unit_expected except all select * from dxt_unit_actual)\nselect count(*) as failures from (select * from dxt_actual_minus_expected union all select * from dxt_expected_minus_actual) __dxt_diff", .{ projection, plan.trimTrailingSqlTerminator(compiled.compiled_code), projection, expected });
    const compiled_code = try code.toOwnedSlice();
    errdefer a.free(compiled_code);
    const completed = clock.now(runtime.io);
    // Evaluate model and expectation once on the temporary fixture relations.
    // SQL fixtures and models may be nondeterministic; diagnostics must show
    // the exact records used for the comparison rather than rerunning SQL.
    const actual_setup = try std.fmt.allocPrint(a, "create temporary table __dxt_unit_actual_records as select {s} from (\n{s}\n) __dxt_actual", .{ projection, plan.trimTrailingSqlTerminator(compiled.compiled_code) });
    defer a.free(actual_setup);
    const expected_setup = try std.fmt.allocPrint(a, "create temporary table __dxt_unit_expected_records as select {s} from (\n{s}\n) __dxt_expected", .{ projection, expected });
    defer a.free(expected_setup);
    session.execute(actual_setup) catch |err| return queryFailure(compiled_code, started, completed, err);
    session.execute(expected_setup) catch |err| return queryFailure(compiled_code, started, completed, err);
    var comparison = session.query("select count(*) as failures from ((select * from __dxt_unit_actual_records except all select * from __dxt_unit_expected_records) union all (select * from __dxt_unit_expected_records except all select * from __dxt_unit_actual_records)) __dxt_diff") catch |err| return queryFailure(compiled_code, started, completed, err);
    defer comparison.deinit(a);
    const failures = try std.fmt.parseUnsigned(u64, comparison.firstScalar() orelse return error.InvalidUnitTestResult, 10);
    const message = if (failures != 0) try differenceMessage(a, session) else null;
    return .{ .compiled_code = compiled_code, .failures = if (failures == 0) 0 else 1, .failure_message = message, .compile_started_at = started, .compile_completed_at = completed };
}

fn inputColumns(a: std.mem.Allocator, graph: *const types.Graph, real: ?*adapter.Session, fixture_graph: *const types.Graph, isolated: *adapter.Session, id: []const u8, columns: *std.ArrayList(Column)) !void {
    var schema: []const u8 = "";
    var identifier: []const u8 = "";
    var database: ?[]const u8 = null;
    var node: ?*const types.Node = null;
    var source: ?*const types.SourceDef = null;
    for (graph.nodes.items) |*candidate| if (std.mem.eql(u8, candidate.unique_id, id)) {
        node = candidate;
        break;
    };
    for (graph.sources.items) |*candidate| if (std.mem.eql(u8, candidate.unique_id, id)) {
        source = candidate;
        break;
    };
    if (node) |n| {
        schema = try compiler.relationSchemaForNode(a, graph, n);
        identifier = compiler.relationIdentifierForNode(n);
        database = compiler.relationDatabaseForNode(graph, n);
    } else if (source) |s| {
        schema = compiler.sourceSchemaName(s);
        identifier = compiler.sourceIdentifier(s);
        database = compiler.sourceDatabaseName(s);
    } else return error.UnresolvedUnitTestInput;
    if (real) |actual| {
        var result = try actual.columnsInDatabase(a, database, schema, identifier);
        defer result.deinit(a);
        for (result.rows) |row| try columns.append(a, .{ .name = try a.dupe(u8, row[0] orelse return error.InvalidAdapterIntrospection), .data_type = try a.dupe(u8, row[1] orelse return error.InvalidAdapterIntrospection) });
    }
    if (columns.items.len != 0) return;
    if (node) |n| {
        // Self-contained units can bind a literal upstream even before its first
        // materialization. Otherwise declared columns provide the schema.
        var upstream_graph = fixture_graph.*;
        upstream_graph.unit_fixture_aliases = &.{};
        const sql = compiler.compileModel(a, &upstream_graph, n) catch null;
        if (sql) |query| {
            defer a.free(query);
            if (isolated.* == .postgres) try isolated.execute("savepoint __dxt_unit_bind");
            var bound = bindColumns(a, isolated, plan.trimTrailingSqlTerminator(query)) catch blk: {
                if (isolated.* == .postgres) try isolated.execute("rollback to savepoint __dxt_unit_bind");
                break :blk null;
            };
            if (isolated.* == .postgres) try isolated.execute("release savepoint __dxt_unit_bind");
            if (bound) |*b| {
                defer b.deinit(a);
                try columns.appendSlice(a, b.items);
            }
        }
        if (columns.items.len == 0) for (n.columns.items) |column| if (column.data_type) |data_type| try columns.append(a, .{ .name = column.name, .data_type = data_type });
    } else if (source) |s| for (s.columns.items) |column| if (column.data_type) |data_type| try columns.append(a, .{ .name = column.name, .data_type = data_type });
}
fn bindColumns(a: std.mem.Allocator, session: *adapter.Session, query: []const u8) !std.ArrayList(Column) {
    var columns: std.ArrayList(Column) = .empty;
    errdefer columns.deinit(a);
    const sql = if (session.* == .duckdb) try std.fmt.allocPrint(a, "describe select * from (\n{s}\n) __dxt_bind", .{query}) else try std.fmt.allocPrint(a, "select * from (\n{s}\n) __dxt_bind limit 0", .{query});
    defer a.free(sql);
    var result = try session.query(sql);
    defer result.deinit(a);
    if (session.* == .duckdb) {
        for (result.rows) |row| try columns.append(a, .{ .name = try a.dupe(u8, row[0] orelse ""), .data_type = try a.dupe(u8, row[1] orelse "VARCHAR") });
    } else for (result.columns) |column| {
        const type_sql = try std.fmt.allocPrint(a, "select format_type({d},{d})", .{ column.native_type, column.native_type_modifier });
        defer a.free(type_sql);
        var type_result = try session.query(type_sql);
        defer type_result.deinit(a);
        try columns.append(a, .{ .name = try a.dupe(u8, column.name), .data_type = try a.dupe(u8, type_result.firstScalar() orelse "text") });
    }
    return columns;
}
fn inferredColumns(a: std.mem.Allocator, fixture: types.UnitTestFixture, columns: *std.ArrayList(Column)) !void {
    for (fixture.rows.items) |row| for (row.entries.items) |entry| {
        if (findColumn(columns.items, entry.key) != null) continue;
        var data_type: []const u8 = "varchar";
        // Choose a non-null scalar over NULL's unknown type, across sparse rows.
        for (fixture.rows.items) |other| for (other.entries.items) |candidate| if (std.ascii.eqlIgnoreCase(candidate.key, entry.key) and candidate.value.kind != .null) {
            data_type = switch (candidate.value.kind) {
                .number => "double precision",
                .bool => "boolean",
                else => "varchar",
            };
        };
        try columns.append(a, .{ .name = entry.key, .data_type = data_type });
    };
    if (columns.items.len == 0) return error.UnitTestInputSchemaUnavailable;
}
fn findColumn(columns: []const Column, name: []const u8) ?Column {
    for (columns) |column| if (std.ascii.eqlIgnoreCase(column.name, name)) return column;
    return null;
}
fn renderRows(a: std.mem.Allocator, rows: []const types.UnitTestRow, columns: []const Column) ![]const u8 {
    if (columns.len == 0) return error.UnitTestInputSchemaUnavailable;
    try validateColumns(rows, columns);
    return renderProjectedRows(a, rows, columns);
}
fn validateColumns(rows: []const types.UnitTestRow, columns: []const Column) !void {
    for (rows) |row| for (row.entries.items) |entry| if (findColumn(columns, entry.key) == null) return error.UnknownUnitTestColumn;
}
fn renderProjectedRows(a: std.mem.Allocator, rows: []const types.UnitTestRow, columns: []const Column) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const count = @max(rows.len, 1);
    for (0..count) |r| {
        if (r != 0) try out.writer.writeAll(" union all ");
        try out.writer.writeAll("select ");
        for (columns, 0..) |column, c| {
            if (c != 0) try out.writer.writeAll(", ");
            var scalar: types.JsonScalar = .{ .text = "null", .kind = .null };
            if (rows.len != 0) for (rows[r].entries.items) |entry| if (std.ascii.eqlIgnoreCase(entry.key, column.name)) {
                scalar = entry.value;
            };
            const literal = try plan.renderScalarLiteral(a, scalar);
            defer a.free(literal);
            const identifier = try compiler.quoteIdentifier(a, column.name);
            defer a.free(identifier);
            try out.writer.print("cast({s} as {s}) as {s}", .{ literal, column.data_type, identifier });
        }
        if (rows.len == 0) try out.writer.writeAll(" limit 0");
    }
    return try out.toOwnedSlice();
}
fn columnList(a: std.mem.Allocator, columns: []const Column) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    for (columns, 0..) |column, i| {
        if (i != 0) try out.writer.writeAll(", ");
        const name = try compiler.quoteIdentifier(a, column.name);
        defer a.free(name);
        try out.writer.writeAll(name);
    }
    return try out.toOwnedSlice();
}

fn exists(runtime: types.Runtime, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(runtime.io, path, .{}) catch return false;
    file.close(runtime.io);
    return true;
}

fn validateExpectedRows(rows: []const types.UnitTestRow, columns: []const Column) !void {
    for (rows) |row| {
        if (row.entries.items.len != columns.len) return error.InvalidUnitTestExpectedRows;
        for (row.entries.items) |entry| if (findColumn(columns, entry.key) == null) return error.InvalidUnitTestExpectedRows;
    }
}

test "typed fixtures fill sparse fields and retain an empty input schema" {
    const a = std.testing.allocator;
    var entries: std.ArrayList(types.MetaEntry) = .empty;
    defer entries.deinit(a);
    try entries.append(a, .{ .key = "ID", .value = .{ .kind = .number, .text = "2" } });
    const columns = [_]Column{ .{ .name = "id", .data_type = "INTEGER" }, .{ .name = "note", .data_type = "VARCHAR(24)" } };
    const row = [_]types.UnitTestRow{.{ .entries = entries }};
    const sql = try renderRows(a, &row, &columns);
    defer a.free(sql);
    try std.testing.expectEqualStrings("select cast(2 as INTEGER) as \"id\", cast(null as VARCHAR(24)) as \"note\"", sql);
    const empty = try renderRows(a, &.{}, &columns);
    defer a.free(empty);
    try std.testing.expect(std.mem.endsWith(u8, empty, "limit 0"));
    try std.testing.expectError(error.UnknownUnitTestColumn, renderRows(a, &row, columns[1..]));
}

fn queryFailure(compiled_code: []const u8, started: i96, completed: i96, err: anyerror) Result {
    return .{ .compiled_code = compiled_code, .failures = 0, .execution_error = true, .execution_cancelled = err == error.AdapterQueryCancelled, .compile_started_at = started, .compile_completed_at = completed };
}
fn differenceMessage(a: std.mem.Allocator, session: *adapter.Session) ![]const u8 {
    const actual_sql = "select * from __dxt_unit_actual_records";
    const expected_sql = "select * from __dxt_unit_expected_records";
    var actual = try session.query(actual_sql);
    defer actual.deinit(a);
    var expected = try session.query(expected_sql);
    defer expected.deinit(a);
    const actual_json = try actual.json(a);
    defer a.free(actual_json);
    const expected_json = try expected.json(a);
    defer a.free(expected_json);
    return try std.fmt.allocPrint(a, "\n\nactual differs from expected:\n\nActual: {s}\nExpected: {s}\n", .{ actual_json, expected_json });
}
