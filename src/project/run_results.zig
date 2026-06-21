const std = @import("std");
const Io = std.Io;
const project_fs = @import("fs.zig");
const json = @import("json.zig");
const types = @import("types.zig");

const Node = types.Node;
const GenericTestNode = types.GenericTestNode;
const SingularTestNode = types.SingularTestNode;
const UnitTestDef = types.UnitTestDef;
const Runtime = types.Runtime;

pub const NodeResult = struct {
    node: ?*const Node = null,
    test_node: ?*const GenericTestNode = null,
    singular_test_node: ?*const SingularTestNode = null,
    unit_test_node: ?*const UnitTestDef = null,
    status: []const u8 = "success",
    message: ?[]const u8 = null,
    failures: ?u64 = null,
    compiled_code: ?[]const u8 = null,
    owns_compiled_code: bool = false,
    relation_name: ?[]const u8 = null,
    owns_relation_name: bool = false,
};

pub const ResultStatusRow = struct {
    unique_id: []const u8,
    status: []const u8,
};

pub const ResultStatusIndex = struct {
    rows: []ResultStatusRow = &.{},

    pub fn deinit(self: *ResultStatusIndex, allocator: std.mem.Allocator) void {
        for (self.rows) |row| {
            allocator.free(row.unique_id);
            allocator.free(row.status);
        }
        allocator.free(self.rows);
        self.* = .{};
    }

    pub fn statusFor(self: *const ResultStatusIndex, unique_id: []const u8) ?[]const u8 {
        for (self.rows) |row| {
            if (std.mem.eql(u8, row.unique_id, unique_id)) return row.status;
        }
        return null;
    }
};

pub fn loadResultStatusIndex(runtime: Runtime, state_dir: []const u8) !ResultStatusIndex {
    const path = try project_fs.pathJoin(runtime.allocator, &.{ state_dir, "run_results.json" });
    defer runtime.allocator.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.MissingRunResultsArtifact,
        else => return err,
    };
    defer runtime.allocator.free(text);
    return try parseResultStatusIndex(runtime.allocator, text);
}

pub fn parseResultStatusIndex(allocator: std.mem.Allocator, text: []const u8) !ResultStatusIndex {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return error.MalformedRunResultsArtifact;
    defer parsed.deinit();

    const root = if (parsed.value == .object) parsed.value.object else return error.MalformedRunResultsArtifact;
    const metadata_value = root.get("metadata") orelse return error.MalformedRunResultsArtifact;
    const metadata = if (metadata_value == .object) metadata_value.object else return error.MalformedRunResultsArtifact;
    const schema_value = metadata.get("dbt_schema_version") orelse return error.MalformedRunResultsArtifact;
    const schema_version = if (schema_value == .string) schema_value.string else return error.MalformedRunResultsArtifact;
    if (!std.mem.eql(u8, schema_version, "https://schemas.getdbt.com/dbt/run-results/v6.json")) return error.UnsupportedRunResultsSchemaVersion;

    const results_value = root.get("results") orelse return error.MalformedRunResultsArtifact;
    const results = if (results_value == .array) results_value.array else return error.MalformedRunResultsArtifact;

    var rows: std.ArrayList(ResultStatusRow) = .empty;
    errdefer {
        for (rows.items) |row| {
            allocator.free(row.unique_id);
            allocator.free(row.status);
        }
        rows.deinit(allocator);
    }

    for (results.items) |result_value| {
        const result = if (result_value == .object) result_value.object else return error.MalformedRunResultsArtifact;
        const unique_id_value = result.get("unique_id") orelse return error.MalformedRunResultsArtifact;
        const status_value = result.get("status") orelse return error.MalformedRunResultsArtifact;
        const unique_id = if (unique_id_value == .string) unique_id_value.string else return error.MalformedRunResultsArtifact;
        const status = if (status_value == .string) status_value.string else return error.MalformedRunResultsArtifact;
        try rows.append(allocator, .{
            .unique_id = try allocator.dupe(u8, unique_id),
            .status = try allocator.dupe(u8, status),
        });
    }

    return .{ .rows = try rows.toOwnedSlice(allocator) };
}

pub fn isSupportedResultSelectorStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "success") or
        std.mem.eql(u8, status, "error") or
        std.mem.eql(u8, status, "fail") or
        std.mem.eql(u8, status, "skipped");
}

pub fn renderRunResults(allocator: std.mem.Allocator, results: []const NodeResult) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\n  \"metadata\": {\"dbt_schema_version\": ");
    try json.string(writer, "https://schemas.getdbt.com/dbt/run-results/v6.json");
    try writer.writeAll(", \"dbt_version\": ");
    try json.string(writer, "0.0.0");
    try writer.writeAll(", \"generated_at\": ");
    try json.string(writer, "1970-01-01T00:00:00Z");
    try writer.writeAll(", \"invocation_id\": null, \"invocation_started_at\": null, \"env\": {}},\n");
    try writer.writeAll("  \"results\": [");
    for (results, 0..) |result, index| {
        if (index != 0) try writer.writeAll(",");
        try writeResult(writer, result);
    }
    try writer.writeAll("\n  ],\n  \"elapsed_time\": 0.0\n}\n");
    return try out.toOwnedSlice();
}

fn writeResult(writer: *Io.Writer, result: NodeResult) !void {
    try writer.writeAll("\n    {\"status\": ");
    try json.string(writer, result.status);
    try writer.writeAll(", \"timing\": [");
    try writer.writeAll("{\"name\": \"compile\", \"started_at\": null, \"completed_at\": null}, ");
    try writer.writeAll("{\"name\": \"execute\", \"started_at\": null, \"completed_at\": null}");
    try writer.writeAll("], \"thread_id\": \"Thread-1\", \"execution_time\": 0.0, \"adapter_response\": {}, \"message\": ");
    if (result.message) |message| {
        try json.string(writer, message);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(", \"failures\": ");
    if (result.failures) |failures| {
        try writer.print("{d}", .{failures});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(", \"unique_id\": ");
    try json.string(writer, resultUniqueId(result));
    try writer.writeAll(", \"compiled\": ");
    if (result.test_node != null or result.singular_test_node != null or result.unit_test_node != null or result.compiled_code != null) {
        try writer.writeAll("true");
    } else if (result.node) |node| if (isCompiledResultNode(node)) {
        try writer.writeAll(if (node.compiled) "true" else "false");
    } else {
        try writer.writeAll("null");
    } else try writer.writeAll("null");
    try writer.writeAll(", \"compiled_code\": ");
    if (result.compiled_code) |compiled_code| {
        try json.string(writer, compiled_code);
    } else if (result.node) |node| if (isCompiledResultNode(node) and node.compiled_code != null) {
        const compiled_code = node.compiled_code.?;
        try json.string(writer, compiled_code);
    } else {
        try writer.writeAll("null");
    } else try writer.writeAll("null");
    try writer.writeAll(", \"relation_name\": ");
    if (result.relation_name) |relation_name| {
        try json.string(writer, relation_name);
    } else if (result.node) |node| if (isCompiledResultNode(node) and node.relation_name != null) {
        const relation_name = node.relation_name.?;
        try json.string(writer, relation_name);
    } else {
        try writer.writeAll("null");
    } else try writer.writeAll("null");
    try writer.writeAll("}");
}

fn resultUniqueId(result: NodeResult) []const u8 {
    if (result.node) |node| return node.unique_id;
    if (result.test_node) |test_node| return test_node.unique_id;
    if (result.singular_test_node) |test_node| return test_node.unique_id;
    if (result.unit_test_node) |unit_test| return unit_test.unique_id;
    return "";
}

fn isCompiledResultNode(node: *const Node) bool {
    return std.mem.eql(u8, node.resource_type, "model");
}

test "run-results writer emits dbt v6 success shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select 1 as id",
        .compiled = true,
        .compiled_code = "select 1 as id",
        .relation_name = "\"main\".\"customers\"",
    });

    const rendered = try renderRunResults(allocator, &.{.{ .node = &graph.nodes.items[0] }});
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("https://schemas.getdbt.com/dbt/run-results/v6.json", root.get("metadata").?.object.get("dbt_schema_version").?.string);
    const result = root.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("success", result.get("status").?.string);
    try std.testing.expectEqualStrings("model.demo.customers", result.get("unique_id").?.string);
    try std.testing.expectEqual(true, result.get("compiled").?.bool);
    try std.testing.expectEqualStrings("select 1 as id", result.get("compiled_code").?.string);
    try std.testing.expectEqualStrings("\"main\".\"customers\"", result.get("relation_name").?.string);
}

test "run-results status index loads dbt v6 result statuses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text =
        \\{
        \\  "metadata": {"dbt_schema_version": "https://schemas.getdbt.com/dbt/run-results/v6.json"},
        \\  "results": [
        \\    {"unique_id": "model.demo.customers", "status": "success"},
        \\    {"unique_id": "model.demo.orders", "status": "error"},
        \\    {"unique_id": "test.demo.not_null_customers_id.abc", "status": "fail"},
        \\    {"unique_id": "model.demo.downstream", "status": "skipped"},
        \\    {"unique_id": "test.demo.accepted_values_orders_status.def", "status": "pass"}
        \\  ],
        \\  "elapsed_time": 0.0
        \\}
    ;

    var index = try parseResultStatusIndex(allocator, text);
    defer index.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), index.rows.len);
    try std.testing.expectEqualStrings("success", index.statusFor("model.demo.customers").?);
    try std.testing.expectEqualStrings("error", index.statusFor("model.demo.orders").?);
    try std.testing.expectEqualStrings("fail", index.statusFor("test.demo.not_null_customers_id.abc").?);
    try std.testing.expectEqualStrings("skipped", index.statusFor("model.demo.downstream").?);
    try std.testing.expectEqualStrings("pass", index.statusFor("test.demo.accepted_values_orders_status.def").?);
    try std.testing.expect(index.statusFor("model.demo.missing") == null);
}

test "run-results status index reports malformed and version mismatch artifacts" {
    try std.testing.expectError(error.MalformedRunResultsArtifact, parseResultStatusIndex(std.testing.allocator, "{}"));
    try std.testing.expectError(
        error.UnsupportedRunResultsSchemaVersion,
        parseResultStatusIndex(std.testing.allocator,
            \\{"metadata":{"dbt_schema_version":"https://schemas.getdbt.com/dbt/run-results/v5.json"},"results":[]}
        ),
    );
    try std.testing.expectError(
        error.MalformedRunResultsArtifact,
        parseResultStatusIndex(std.testing.allocator,
            \\{"metadata":{"dbt_schema_version":"https://schemas.getdbt.com/dbt/run-results/v6.json"},"results":[{"unique_id":"model.demo.customers"}]}
        ),
    );
}

test "run-results writer emits seed result with dbt Core null compiled fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
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

    const rendered = try renderRunResults(allocator, &.{.{ .node = &graph.nodes.items[0] }});
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("seed.demo.raw_customers", result.get("unique_id").?.string);
    try std.testing.expectEqual(.null, result.get("compiled").?);
    try std.testing.expectEqual(.null, result.get("compiled_code").?);
    try std.testing.expectEqual(.null, result.get("relation_name").?);
}

test "run-results writer emits compiled model error result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select * from missing_relation",
        .compiled = true,
        .compiled_code = "select * from missing_relation",
        .relation_name = "\"main\".\"orders\"",
    });

    const rendered = try renderRunResults(allocator, &.{.{
        .node = &graph.nodes.items[0],
        .status = "error",
        .message = "DuckDB execution failed",
    }});
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("error", result.get("status").?.string);
    try std.testing.expectEqualStrings("DuckDB execution failed", result.get("message").?.string);
    try std.testing.expectEqual(.null, result.get("failures").?);
    try std.testing.expectEqualStrings("model.demo.orders", result.get("unique_id").?.string);
    try std.testing.expectEqual(true, result.get("compiled").?.bool);
    try std.testing.expectEqualStrings("select * from missing_relation", result.get("compiled_code").?.string);
    try std.testing.expectEqualStrings("\"main\".\"orders\"", result.get("relation_name").?.string);
}

test "run-results writer emits compiled model skipped result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select * from {{ ref('customers') }}",
        .compiled = true,
        .compiled_code = "select * from \"main\".\"customers\"",
        .relation_name = "\"main\".\"orders\"",
    });

    const rendered = try renderRunResults(allocator, &.{.{
        .node = &graph.nodes.items[0],
        .status = "skipped",
    }});
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("skipped", result.get("status").?.string);
    try std.testing.expectEqual(.null, result.get("message").?);
    try std.testing.expectEqual(.null, result.get("failures").?);
    try std.testing.expectEqualStrings("model.demo.orders", result.get("unique_id").?.string);
    try std.testing.expectEqual(true, result.get("compiled").?.bool);
    try std.testing.expectEqualStrings("select * from \"main\".\"customers\"", result.get("compiled_code").?.string);
    try std.testing.expectEqualStrings("\"main\".\"orders\"", result.get("relation_name").?.string);
}

test "run-results writer emits generic test pass and fail statuses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
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

    const rendered = try renderRunResults(allocator, &.{
        .{
            .test_node = &graph.tests.items[0],
            .status = "fail",
            .message = "Got 1 result, configured to fail if != 0",
            .failures = 1,
            .compiled_code = "select 1 as failures",
            .relation_name = "\"dbt_test__audit\".\"not_null_customers_customer_id\"",
        },
    });
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("fail", result.get("status").?.string);
    try std.testing.expectEqualStrings("test.demo.not_null_customers_customer_id.abc", result.get("unique_id").?.string);
    try std.testing.expectEqual(@as(i64, 1), result.get("failures").?.integer);
    try std.testing.expectEqual(true, result.get("compiled").?.bool);
    try std.testing.expectEqualStrings("select 1 as failures", result.get("compiled_code").?.string);
    try std.testing.expectEqualStrings("\"dbt_test__audit\".\"not_null_customers_customer_id\"", result.get("relation_name").?.string);
}

test "run-results writer preserves mixed model and generic test order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select 1 as id",
        .compiled = true,
        .compiled_code = "select 1 as id",
        .relation_name = "\"main\".\"customers\"",
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

    const rendered = try renderRunResults(allocator, &.{
        .{ .node = &graph.nodes.items[0] },
        .{
            .test_node = &graph.tests.items[0],
            .status = "pass",
            .failures = 0,
            .compiled_code = "select * from customers where customer_id is null",
        },
    });
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const results = parsed.value.object.get("results").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("model.demo.customers", results[0].object.get("unique_id").?.string);
    try std.testing.expectEqualStrings("success", results[0].object.get("status").?.string);
    try std.testing.expectEqualStrings("test.demo.not_null_customers_customer_id.abc", results[1].object.get("unique_id").?.string);
    try std.testing.expectEqualStrings("pass", results[1].object.get("status").?.string);
    try std.testing.expectEqual(@as(i64, 0), results[1].object.get("failures").?.integer);
}

test "run-results writer preserves seed model and generic test shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
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
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select * from {{ ref(\"raw_customers\") }}",
        .compiled = true,
        .compiled_code = "select * from \"main\".\"raw_customers\"",
        .relation_name = "\"main\".\"customers\"",
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

    const rendered = try renderRunResults(allocator, &.{
        .{ .node = &graph.nodes.items[0] },
        .{ .node = &graph.nodes.items[1] },
        .{
            .test_node = &graph.tests.items[0],
            .status = "pass",
            .failures = 0,
            .compiled_code = "select customer_id from customers where customer_id is null",
        },
    });
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const results = parsed.value.object.get("results").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("seed.demo.raw_customers", results[0].object.get("unique_id").?.string);
    try std.testing.expectEqual(.null, results[0].object.get("compiled").?);
    try std.testing.expectEqual(.null, results[0].object.get("compiled_code").?);
    try std.testing.expectEqualStrings("model.demo.customers", results[1].object.get("unique_id").?.string);
    try std.testing.expectEqual(true, results[1].object.get("compiled").?.bool);
    try std.testing.expectEqualStrings("test.demo.not_null_customers_customer_id.abc", results[2].object.get("unique_id").?.string);
    try std.testing.expectEqualStrings("pass", results[2].object.get("status").?.string);
    try std.testing.expectEqual(true, results[2].object.get("compiled").?.bool);
    try std.testing.expectEqual(.null, results[2].object.get("relation_name").?);
}

test "run-results writer emits unit test pass and fail statuses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.unit_tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "unit_test.demo.orders.assert_order_flags",
        .name = "assert_order_flags",
        .model = "orders",
        .path = "schema.yml",
        .original_file_path = "models/schema.yml",
    });

    const rendered = try renderRunResults(allocator, &.{
        .{
            .unit_test_node = &graph.unit_tests.items[0],
            .status = "fail",
            .message = "Got 2 results, configured to fail if != 0",
            .failures = 2,
            .compiled_code = "select count(*) as failures from dxt_unit_diff",
        },
    });
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("fail", result.get("status").?.string);
    try std.testing.expectEqualStrings("unit_test.demo.orders.assert_order_flags", result.get("unique_id").?.string);
    try std.testing.expectEqual(@as(i64, 2), result.get("failures").?.integer);
    try std.testing.expectEqual(true, result.get("compiled").?.bool);
    try std.testing.expectEqualStrings("select count(*) as failures from dxt_unit_diff", result.get("compiled_code").?.string);
    try std.testing.expectEqual(.null, result.get("relation_name").?);
}
