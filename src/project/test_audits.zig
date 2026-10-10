//! dbt Core 1.10.5 TestConfig.finalize_and_validate and default test
//! materialization: audit relations exist even for passing/empty results;
//! aggregate failure calculations and threshold predicates run in the adapter.
const std = @import("std");
const types = @import("types.zig");
const adapter = @import("adapter.zig");
const compiler = @import("compiler.zig");

pub const Result = struct {
    failures: i64,
    should_warn: bool,
    should_error: bool,
    relation_name: ?[]const u8 = null,
    adapter_response: ?@import("run_results.zig").AdapterResponse = null,
};

pub fn configuredStore(config: types.GenericTestConfig) ?bool {
    if (config.store_failures_as) |kind| return !std.mem.eql(u8, kind, "ephemeral");
    return config.store_failures;
}

pub fn configuredKind(config: types.GenericTestConfig) ?[]const u8 {
    if (config.store_failures_as) |kind| return kind;
    if (config.store_failures) |enabled| return if (enabled) "table" else "ephemeral";
    return null;
}

pub fn shouldStore(config: types.GenericTestConfig, options: types.Options) bool {
    return configuredStore(config) orelse options.store_failures;
}

pub fn auditNode(config: types.GenericTestConfig, alias: []const u8, package: []const u8) types.Node {
    return .{ .resource_type = "test", .package_name = package, .unique_id = "", .name = alias, .path = "", .original_file_path = "", .raw_code = "", .config_schema = config.schema orelse "dbt_test__audit", .config_alias = config.alias orelse alias };
}

pub fn auditNodeWithIdentity(config: types.GenericTestConfig, alias: []const u8, package: []const u8, identity: ?types.ResolvedIdentity) types.Node {
    var node = auditNode(config, alias, package);
    node.resolved_identity = identity;
    return node;
}

pub fn relationName(allocator: std.mem.Allocator, graph: *const types.Graph, config: types.GenericTestConfig, alias: []const u8, package: []const u8) ![]const u8 {
    return relationNameWithIdentity(allocator, graph, config, alias, package, null);
}

pub fn relationNameWithIdentity(allocator: std.mem.Allocator, graph: *const types.Graph, config: types.GenericTestConfig, alias: []const u8, package: []const u8, identity: ?types.ResolvedIdentity) ![]const u8 {
    var node = auditNode(config, alias, package);
    node.resolved_identity = identity;
    var object: std.json.ObjectMap = .empty;
    defer object.deinit(allocator);
    if (config.database) |database| try object.put(allocator, "database", .{ .string = database });
    node.effective_config = .{ .object = object };
    return compiler.relationNameForNode(allocator, graph, &node);
}

pub fn execute(runtime: types.Runtime, graph: *const types.Graph, db_path: []const u8, config: types.GenericTestConfig, alias: []const u8, package: []const u8, compiled_sql: []const u8) !Result {
    return executeWithIdentity(runtime, graph, db_path, config, alias, package, compiled_sql, null);
}

pub fn executeWithIdentity(runtime: types.Runtime, graph: *const types.Graph, db_path: []const u8, config: types.GenericTestConfig, alias: []const u8, package: []const u8, compiled_sql: []const u8, identity: ?types.ResolvedIdentity) !Result {
    const a = runtime.allocator;
    var scoped_runtime = runtime;
    var owned_session: ?adapter.Session = null;
    defer if (owned_session) |*session| session.deinit();
    // The default PostgreSQL test materialization uses statement auto_begin
    // and commits its audit CREATE. DuckDB drops prior relations with
    // auto_begin=False, so a failed CREATE retains that drop's effects.
    const postgres = std.mem.eql(u8, graph.adapter_type, "postgres");
    if (postgres and scoped_runtime.adapter_session == null) {
        owned_session = try adapter.openSession(runtime, graph, db_path);
        scoped_runtime.adapter_session = &owned_session.?;
    }
    if (postgres) try scoped_runtime.adapter_session.?.begin();
    errdefer if (postgres) scoped_runtime.adapter_session.?.rollback() catch {};
    const options = runtime.invocation_options orelse runtime.global_options orelse &graph.command_options;
    const store = shouldStore(config, options.*);
    var relation: ?[]const u8 = null;
    errdefer if (relation) |name| a.free(name);
    if (store) {
        const kind = configuredKind(config) orelse "table";
        if (!std.mem.eql(u8, kind, "table") and !std.mem.eql(u8, kind, "view")) return error.InvalidTestFailureMaterialization;
        relation = try relationNameWithIdentity(a, graph, config, alias, package, identity);
        var node = auditNode(config, alias, package);
        node.resolved_identity = identity;
        const schema = try compiler.relationSchemaForNode(a, graph, &node);
        defer a.free(schema);
        const identifier = compiler.relationIdentifierForNode(&node);
        const schema_lit = try adapter.quoteLiteral(a, schema);
        defer a.free(schema_lit);
        const identifier_lit = try adapter.quoteLiteral(a, identifier);
        defer a.free(identifier_lit);
        const lookup = try std.fmt.allocPrint(a, "select table_type from information_schema.tables where table_schema={s} and table_name={s}", .{ schema_lit, identifier_lit });
        defer a.free(lookup);
        var existing = try adapter.queryForGraph(scoped_runtime, graph, db_path, lookup);
        defer existing.deinit(a);
        const schema_sql = try adapter.quoteIdentifier(a, schema);
        defer a.free(schema_sql);
        const create_schema = try std.fmt.allocPrint(a, "create schema if not exists {s}", .{schema_sql});
        defer a.free(create_schema);
        try adapter.executeForGraph(scoped_runtime, graph, db_path, create_schema);
        if (existing.firstScalar()) |old_kind| {
            const drop = try std.fmt.allocPrint(a, "drop {s} {s}", .{ if (std.mem.eql(u8, old_kind, "VIEW")) "view" else "table", relation.? });
            defer a.free(drop);
            try adapter.executeForGraph(scoped_runtime, graph, db_path, drop);
        }
        const create = try std.fmt.allocPrint(a, "create {s} {s} as ({s})", .{ kind, relation.?, trimTerminator(compiled_sql) });
        defer a.free(create);
        try adapter.executeForGraph(scoped_runtime, graph, db_path, create);
        if (postgres) {
            // Core publishes stored failures before evaluating fail_calc and
            // thresholds. An aggregate error must retain the new audit table.
            try scoped_runtime.adapter_session.?.commit();
            try scoped_runtime.adapter_session.?.begin();
        }
    }
    const query = if (relation) |name| try std.fmt.allocPrint(a, "select * from {s}", .{name}) else try a.dupe(u8, compiled_sql);
    defer a.free(query);
    const sql = try renderExecutionSql(a, query, config);
    defer a.free(sql);
    var result = try adapter.queryForGraph(scoped_runtime, graph, db_path, sql);
    defer result.deinit(a);
    if (result.columns.len != 3 or result.rows.len != 1 or result.rows[0].len != 3) return error.InvalidTestResult;
    const output = Result{ .failures = try parseFailures(result.rows[0][0]), .should_warn = try parseBoolean(result.rows[0][1]), .should_error = try parseBoolean(result.rows[0][2]), .relation_name = relation };
    if (postgres) try scoped_runtime.adapter_session.?.commit();
    return output;
}

/// Execute the actual selected materialization and its namespace helpers on
/// the held connection. Schema preparation and published relation identity
/// still follow authored config/CLI, independently of helper overrides.
pub fn executeNode(runtime: types.Runtime, graph: *const types.Graph, db_path: []const u8, config: types.GenericTestConfig, node: *const types.Node, dependencies: *std.ArrayList([]const u8)) !Result {
    return executeNodeWithArtifacts(runtime, graph, db_path, config, node, dependencies, null);
}

/// A completed write survives a later warehouse error, like Core's runner.
/// The caller owns the published path; worker threads never mutate graph nodes.
pub fn executeNodeWithArtifacts(runtime: types.Runtime, graph: *const types.Graph, db_path: []const u8, config: types.GenericTestConfig, node: *const types.Node, dependencies: *std.ArrayList([]const u8), build_path: ?*?[]const u8) !Result {
    const materialization = try @import("custom_materialization.zig").selected(graph, node) orelse
        return executeWithIdentity(runtime, graph, db_path, config, node.config_alias orelse node.name, node.package_name, node.compiled_code orelse return error.UnsupportedTestSelection, node.resolved_identity);
    var runtime_graph = graph.*;
    var output: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer output.deinit();
    var host = try @import("commands.zig").OperationHost.init(runtime, &runtime_graph, db_path, &output.writer);
    defer host.deinit();
    host.log_events = graph.log_collector;
    runtime_graph.execution_hooks = host.host();
    errdefer |err| if (host.lastError()) |message| @import("compile_diagnostics.zig").captureError(node.original_file_path, node.name, message, err);
    var scratch = std.heap.ArenaAllocator.init(runtime.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    // TestRunner ignores the materialization return value and consumes main.
    const rendered = compiler.renderMaterializationForNode(a, &runtime_graph, node, materialization, runtime.allocator, dependencies);
    if (build_path) |output_path| if (host.writtenPathForResource(node.unique_id)) |path| {
        output_path.* = try runtime.allocator.dupe(u8, path);
    };
    _ = try rendered;
    const main = host.result("main") orelse return error.InvalidTestResult;
    const rows = main.attribute("data");
    if (rows != .list or rows.list.len != 1) return error.InvalidTestResult;
    const row = switch (rows.list[0]) {
        .tuple => rows.list[0].tuple,
        .list => rows.list[0].list,
        else => return error.InvalidTestResult,
    };
    if (row.len != 3) return error.InvalidTestResult;
    const column_names = main.attribute("table").attribute("column_names");
    // Agate exposes column_names as a tuple; retained custom tables may use a list.
    const names = switch (column_names) {
        .tuple => column_names.tuple,
        .list => column_names.list,
        else => return error.InvalidTestResult,
    };
    if (names.len != 3) return error.InvalidTestResult;
    var failures: ?usize = null;
    var warn: ?usize = null;
    var err: ?usize = null;
    for (names, 0..) |name, index| {
        if (name != .string) return error.InvalidTestResult;
        if (std.ascii.eqlIgnoreCase(name.string, "failures")) failures = index;
        if (std.ascii.eqlIgnoreCase(name.string, "should_warn")) warn = index;
        if (std.ascii.eqlIgnoreCase(name.string, "should_error")) err = index;
    }
    const failure_value = row[failures orelse return error.InvalidTestResult];
    const warn_value = row[warn orelse return error.InvalidTestResult];
    const error_value = row[err orelse return error.InvalidTestResult];
    const options = runtime.invocation_options orelse runtime.global_options orelse &graph.command_options;
    var result = Result{
        .failures = try parseFailures(if (failure_value == .none) null else try failure_value.text(a)),
        .should_warn = if (warn_value == .boolean) warn_value.boolean else try parseBoolean(if (warn_value == .none) null else try warn_value.text(a)),
        .should_error = if (error_value == .boolean) error_value.boolean else try parseBoolean(if (error_value == .none) null else try error_value.text(a)),
        .relation_name = if (shouldStore(config, options.*)) try compiler.relationNameForNode(runtime.allocator, graph, node) else null,
    };
    errdefer if (result.relation_name) |relation| runtime.allocator.free(relation);
    const response = try @import("materialization_result.zig").fromValue(runtime.allocator, main.attribute("response"));
    runtime.allocator.free(response.message);
    result.adapter_response = response.response;
    return result;
}

pub fn renderExecutionSql(a: std.mem.Allocator, query: []const u8, config: types.GenericTestConfig) ![]const u8 {
    return std.fmt.allocPrint(a, "select {s} as failures, ({s} {s}) as should_warn, ({s} {s}) as should_error from ({s}) dbt_internal_test", .{ config.fail_calc, config.fail_calc, config.warn_if, config.fail_calc, config.error_if, trimTerminator(query) });
}

fn parseFailures(value: ?[]const u8) !i64 {
    const text = value orelse return error.InvalidTestResult;
    return std.fmt.parseInt(i64, text, 10) catch {
        // dbt's result coercion accepts integral Decimal aggregates.
        const number = std.fmt.parseFloat(f64, text) catch return error.InvalidTestResult;
        if (!std.math.isFinite(number) or number != @trunc(number) or number < -9223372036854775808.0 or number >= 9223372036854775808.0) return error.InvalidTestResult;
        return @intFromFloat(number);
    };
}
fn parseBoolean(value: ?[]const u8) !bool {
    const text = value orelse return false;
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "t") or std.mem.eql(u8, text, "1")) return true;
    if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "f") or std.mem.eql(u8, text, "0")) return false;
    return error.InvalidTestResult;
}
fn trimTerminator(query: []const u8) []const u8 {
    return @import("duckdb.zig").trimTrailingSqlTerminator(query);
}

test "test result coercion and normalized audit policies preserve signed failures" {
    try std.testing.expectEqual(@as(i64, -3), try parseFailures("-3.000"));
    try std.testing.expectError(error.InvalidTestResult, parseFailures("1.5"));
    try std.testing.expectError(error.InvalidTestResult, parseFailures(null));
    try std.testing.expect(configuredStore(.{ .store_failures = false, .store_failures_as = "view" }).?);
    try std.testing.expect(!configuredStore(.{ .store_failures = true, .store_failures_as = "ephemeral" }).?);
    const sql = try renderExecutionSql(std.testing.allocator, "select 1 as n;\n", .{ .fail_calc = "sum(n)", .warn_if = "between 1 and 3", .error_if = "> 3" });
    defer std.testing.allocator.free(sql);
    try std.testing.expectEqualStrings("select sum(n) as failures, (sum(n) between 1 and 3) as should_warn, (sum(n) > 3) as should_error from (select 1 as n) dbt_internal_test", sql);
}
