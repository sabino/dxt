const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");

const Node = types.Node;
const GenericTestNode = types.GenericTestNode;

pub const NodeResult = struct {
    node: ?*const Node = null,
    test_node: ?*const GenericTestNode = null,
    status: []const u8 = "success",
    message: ?[]const u8 = null,
    failures: ?u64 = null,
    compiled_code: ?[]const u8 = null,
    owns_compiled_code: bool = false,
};

pub fn renderRunResults(allocator: std.mem.Allocator, results: []const NodeResult) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\n  \"metadata\": {\"dbt_schema_version\": ");
    try writeJsonString(writer, "https://schemas.getdbt.com/dbt/run-results/v6.json");
    try writer.writeAll(", \"dbt_version\": ");
    try writeJsonString(writer, "0.0.0");
    try writer.writeAll(", \"generated_at\": ");
    try writeJsonString(writer, "1970-01-01T00:00:00Z");
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
    try writeJsonString(writer, result.status);
    try writer.writeAll(", \"timing\": [");
    try writer.writeAll("{\"name\": \"compile\", \"started_at\": null, \"completed_at\": null}, ");
    try writer.writeAll("{\"name\": \"execute\", \"started_at\": null, \"completed_at\": null}");
    try writer.writeAll("], \"thread_id\": \"Thread-1\", \"execution_time\": 0.0, \"adapter_response\": {}, \"message\": ");
    if (result.message) |message| {
        try writeJsonString(writer, message);
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
    try writeJsonString(writer, resultUniqueId(result));
    try writer.writeAll(", \"compiled\": ");
    if (result.test_node != null or result.compiled_code != null) {
        try writer.writeAll("true");
    } else if (result.node) |node| if (isCompiledResultNode(node)) {
        try writer.writeAll(if (node.compiled) "true" else "false");
    } else {
        try writer.writeAll("null");
    } else try writer.writeAll("null");
    try writer.writeAll(", \"compiled_code\": ");
    if (result.compiled_code) |compiled_code| {
        try writeJsonString(writer, compiled_code);
    } else if (result.node) |node| if (isCompiledResultNode(node) and node.compiled_code != null) {
        const compiled_code = node.compiled_code.?;
        try writeJsonString(writer, compiled_code);
    } else {
        try writer.writeAll("null");
    } else try writer.writeAll("null");
    try writer.writeAll(", \"relation_name\": ");
    if (result.node) |node| if (isCompiledResultNode(node) and node.relation_name != null) {
        const relation_name = node.relation_name.?;
        try writeJsonString(writer, relation_name);
    } else {
        try writer.writeAll("null");
    } else try writer.writeAll("null");
    try writer.writeAll("}");
}

fn resultUniqueId(result: NodeResult) []const u8 {
    if (result.node) |node| return node.unique_id;
    if (result.test_node) |test_node| return test_node.unique_id;
    return "";
}

fn isCompiledResultNode(node: *const Node) bool {
    return std.mem.eql(u8, node.resource_type, "model");
}

fn writeJsonString(writer: *Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
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
    try std.testing.expectEqual(.null, result.get("relation_name").?);
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
