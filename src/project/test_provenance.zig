//! Inherited test-node metadata follows dbt Core's compiled resource contract.
//! Creation belongs to parsing; a build path exists only after an actual write.
const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");
const json = @import("json.zig");

pub fn initialize(runtime: types.Runtime, graph: *types.Graph) !void {
    const created: f64 = @as(f64, @floatFromInt(@import("execution_clock.zig").now(runtime.io))) / std.time.ns_per_s;
    for (graph.tests.items) |*node| {
        try validate(node.config_values);
        if (node.created_at == 0) node.created_at = created;
    }
    for (graph.singular_tests.items) |*node| {
        try validate(node.config_values);
        if (node.created_at == 0) node.created_at = created;
    }
}

fn validate(config: std.json.Value) !void {
    inline for (.{ "docs", "contract" }) |name| if (values.get(config, name)) |item| {
        if (item != .object and item != .null) return error.InvalidTestMetadataConfiguration;
        const fields = if (comptime std.mem.eql(u8, name, "docs")) &.{"show"} else &.{ "enforced", "alias_types" };
        inline for (fields) |field| if (values.get(item, field)) |setting| {
            if (setting != .bool) return error.InvalidTestMetadataConfiguration;
        };
        const text_field = if (comptime std.mem.eql(u8, name, "docs")) "node_color" else "checksum";
        if (values.get(item, text_field)) |setting| if (setting != .string and setting != .null) return error.InvalidTestMetadataConfiguration;
    };
}

pub fn writeInherited(writer: *std.Io.Writer, config: std.json.Value, created_at: f64, build_path: ?[]const u8) !void {
    // Test patches do not populate model columns or metrics. Docs and
    // contracts inherit typed config values with CompiledNode defaults.
    const contract = values.get(config, "contract") orelse .null;
    try writer.writeAll(",\"columns\":{},\"metrics\":[],\"contract\":{\"enforced\":");
    try std.json.Stringify.value(values.get(contract, "enforced") orelse @as(std.json.Value, .{ .bool = false }), .{}, writer);
    try writer.writeAll(",\"alias_types\":");
    try std.json.Stringify.value(values.get(contract, "alias_types") orelse @as(std.json.Value, .{ .bool = true }), .{}, writer);
    try writer.writeAll(",\"checksum\":");
    try std.json.Stringify.value(values.get(contract, "checksum") orelse @as(std.json.Value, .null), .{}, writer);
    try writer.writeAll("},\"docs\":{\"show\":");
    const docs = values.get(config, "docs") orelse .null;
    try std.json.Stringify.value(values.get(docs, "show") orelse @as(std.json.Value, .{ .bool = true }), .{}, writer);
    try writer.writeAll(",\"node_color\":");
    try std.json.Stringify.value(values.get(docs, "node_color") orelse @as(std.json.Value, .null), .{}, writer);
    try writer.print("}},\"created_at\":{d},\"build_path\":", .{created_at});
    if (build_path) |path| try json.string(writer, path) else try writer.writeAll("null");
}

pub fn fileKeyName(a: std.mem.Allocator, graph: *const types.Graph, test_node: *const types.GenericTestNode) !?[]const u8 {
    if (test_node.attached_source) |source| return try std.fmt.allocPrint(a, "sources.{s}", .{source.source_name});
    const attached = test_node.attached_node orelse return null;
    for (graph.nodes.items) |node| if (std.mem.eql(u8, node.unique_id, attached)) {
        return try std.fmt.allocPrint(a, "{s}.{s}", .{ pluralResource(node.resource_type), node.name });
    };
    // Synthetic graphs may contain the captured reference without its target.
    const first = std.mem.indexOfScalar(u8, attached, '.') orelse return null;
    const second = std.mem.indexOfScalarPos(u8, attached, first + 1, '.') orelse return null;
    return try std.fmt.allocPrint(a, "{s}.{s}", .{ pluralResource(attached[0..first]), attached[second + 1 ..] });
}

fn pluralResource(kind: []const u8) []const u8 {
    if (std.mem.eql(u8, kind, "seed")) return "seeds";
    if (std.mem.eql(u8, kind, "snapshot")) return "snapshots";
    return "models";
}

pub fn publishBuildPath(a: std.mem.Allocator, node: anytype, path: ?[]const u8) !void {
    const value = path orelse return;
    const copy = try a.dupe(u8, value);
    if (node.build_path) |previous| a.free(previous);
    node.build_path = copy;
}

test "test metadata preserves typed docs defaults and nullable build provenance" {
    const a = std.testing.allocator;
    var config = try std.json.parseFromSlice(std.json.Value, a, "{\"docs\":{\"show\":false,\"node_color\":\"#123456\"}}", .{});
    defer config.deinit();
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    try output.writer.writeAll("{");
    try writeInherited(&output.writer, config.value, 123.5, "target/run/demo/tests/check.sql");
    try output.writer.writeAll("}");
    // The fields append to an existing node object.
    const source = try std.mem.replaceOwned(u8, a, output.written(), "{,", "{");
    defer a.free(source);
    var document = try std.json.parseFromSlice(std.json.Value, a, source, .{});
    defer document.deinit();
    try std.testing.expect(!document.value.object.get("docs").?.object.get("show").?.bool);
    try std.testing.expectEqual(@as(f64, 123.5), document.value.object.get("created_at").?.float);
    try std.testing.expectEqualStrings("target/run/demo/tests/check.sql", document.value.object.get("build_path").?.string);
    try std.testing.expectEqual(@as(usize, 0), document.value.object.get("columns").?.object.count());
    try std.testing.expect(document.value.object.get("contract").?.object.get("checksum").? == .null);
}

test "generic file keys follow the attached YAML resource including model versions" {
    const a = std.testing.allocator;
    var graph: types.Graph = .{ .allocator = a, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(a, .{ .resource_type = "model", .package_name = "demo", .unique_id = "model.demo.input.v2", .name = "input", .path = "input_v2.sql", .original_file_path = "models/input_v2.sql", .raw_code = "select 1" });
    var node: types.GenericTestNode = .{ .package_name = "demo", .unique_id = "test.demo.bad_rows", .name = "bad_rows", .alias = "bad_rows", .path = "bad_rows.sql", .original_file_path = "models/schema.yml", .raw_code = "", .test_name = "bad_rows", .attached_node = "model.demo.input.v2" };
    for ([_][]const u8{ "model", "seed", "snapshot" }, [_][]const u8{ "models.input", "seeds.input", "snapshots.input" }) |kind, expected| {
        graph.nodes.items[0].resource_type = kind;
        const result = (try fileKeyName(a, &graph, &node)).?;
        defer a.free(result);
        try std.testing.expectEqualStrings(expected, result);
    }
    node.attached_source = .{ .source_name = "external", .table_name = "source_items" };
    const result = (try fileKeyName(a, &graph, &node)).?;
    defer a.free(result);
    try std.testing.expectEqualStrings("sources.external", result);
}
