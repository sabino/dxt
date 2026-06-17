const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");

const Node = types.Node;

pub const ModelResult = struct {
    node: *const Node,
};

pub fn renderRunResults(allocator: std.mem.Allocator, results: []const ModelResult) ![]const u8 {
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
        try writeResult(writer, result.node);
    }
    try writer.writeAll("\n  ],\n  \"elapsed_time\": 0.0\n}\n");
    return try out.toOwnedSlice();
}

fn writeResult(writer: *Io.Writer, node: *const Node) !void {
    try writer.writeAll("\n    {\"status\": \"success\", \"timing\": [");
    try writer.writeAll("{\"name\": \"compile\", \"started_at\": null, \"completed_at\": null}, ");
    try writer.writeAll("{\"name\": \"execute\", \"started_at\": null, \"completed_at\": null}");
    try writer.writeAll("], \"thread_id\": \"Thread-1\", \"execution_time\": 0.0, \"adapter_response\": {}, \"message\": null, \"failures\": null, \"unique_id\": ");
    try writeJsonString(writer, node.unique_id);
    try writer.writeAll(", \"compiled\": ");
    try writer.writeAll(if (node.compiled) "true" else "false");
    try writer.writeAll(", \"compiled_code\": ");
    if (node.compiled_code) |compiled_code| {
        try writeJsonString(writer, compiled_code);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(", \"relation_name\": ");
    if (node.relation_name) |relation_name| {
        try writeJsonString(writer, relation_name);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}");
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
