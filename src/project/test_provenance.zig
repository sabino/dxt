//! Inherited test-node metadata follows dbt Core's compiled resource contract.
//! Creation belongs to parsing; a build path exists only after an actual write.
const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");
const json = @import("json.zig");

pub fn initialize(runtime: types.Runtime, graph: *types.Graph) !void {
    const created: f64 = @as(f64, @floatFromInt(@import("execution_clock.zig").now(runtime.io))) / std.time.ns_per_s;
    for (graph.tests.items) |*node| {
        // Repeated generic config calls merge docs/contract as mappings.
        // YAML null values are removed by TestBuilder before this stage.
        inline for (.{ "docs", "contract" }) |field| {
            const value = values.get(node.config_values, field) orelse .null;
            if (value != .null and value != .object) return error.InvalidTestMetadataConfiguration;
        }
        try validate(node.config_values);
        if (node.created_at == 0) node.created_at = created;
    }
    for (graph.singular_tests.items) |*node| {
        try validate(node.config_values);
        if (node.created_at == 0) node.created_at = created;
    }
}

fn validate(config: std.json.Value) !void {
    const contract = values.get(config, "contract") orelse .null;
    // Core copies/validates only truthy contract values, including config
    // extras on tests. False, None and empty containers retain defaults.
    if (truthy(contract)) {
        if (contract != .object) return error.InvalidTestMetadataConfiguration;
        var iterator = contract.object.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "enforced") or std.mem.eql(u8, key, "alias_types")) {
                if (entry.value_ptr.* != .bool) return error.InvalidTestMetadataConfiguration;
            } else if (std.mem.eql(u8, key, "checksum")) {
                if (entry.value_ptr.* != .string and entry.value_ptr.* != .null) return error.InvalidTestMetadataConfiguration;
            } else return error.InvalidTestMetadataConfiguration;
        }
    }
}

fn truthy(value: std.json.Value) bool {
    return switch (value) {
        .null => false,
        .bool => value.bool,
        .integer => value.integer != 0,
        .float => value.float != 0,
        .number_string => !std.mem.eql(u8, value.number_string, "0"),
        .string => value.string.len != 0,
        .array => value.array.items.len != 0,
        .object => value.object.count() != 0,
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

/// ParsedNode writes beneath the configured target prefix. Absolute overrides
/// remain absolute; default and relative prefixes stay relative in artifacts.
pub fn compiledPath(a: std.mem.Allocator, graph: *const types.Graph, node: anytype) ![]const u8 {
    const relative = try @import("artifact_paths.zig").relative(a, node.path, node.original_file_path);
    defer a.free(relative);
    return std.fs.path.join(a, &.{ targetPrefix(graph), "compiled", node.package_name, relative });
}

fn targetPrefix(graph: *const types.Graph) []const u8 {
    if (graph.command_options.target_path) |path| return path;
    for (graph.semantic_project_configs.items) |config| {
        if (std.mem.eql(u8, config.package_name, graph.project_name)) if (values.get(config.rendered, "target-path")) |path| {
            if (path == .string) return path.string;
        };
    }
    return "target";
}

/// The canonical compiled SQL file exists before a test materialization starts.
/// Return its logical path for the worker's runtime resource context.
pub fn writeCompiled(runtime: types.Runtime, graph: *const types.Graph, node: anytype, sql: []const u8) ![]const u8 {
    const logical = try compiledPath(runtime.allocator, graph, node);
    errdefer runtime.allocator.free(logical);
    const physical = if (std.fs.path.isAbsolute(logical)) logical else try std.fs.path.join(runtime.allocator, &.{ graph.command_options.project_dir, logical });
    defer if (physical.ptr != logical.ptr) runtime.allocator.free(physical);
    if (std.fs.path.dirname(physical)) |parent| try std.Io.Dir.cwd().createDirPath(runtime.io, parent);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = physical, .data = sql });
    return logical;
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

test "compiled test paths retain project and CLI target prefixes" {
    const a = std.testing.allocator;
    var graph: types.Graph = .{ .allocator = a, .project_name = "demo" };
    defer graph.deinit();
    const node = types.SingularTestNode{ .package_name = "demo", .unique_id = "test.demo.check", .name = "check", .alias = "check", .path = "check.sql", .original_file_path = "tests/check.sql", .raw_code = "select 1" };
    const default = try compiledPath(a, &graph, &node);
    defer a.free(default);
    try std.testing.expectEqualStrings("target/compiled/demo/tests/check.sql", default);
    var rendered = try std.json.parseFromSlice(std.json.Value, a, "{\"target-path\":\"project-output\"}", .{});
    defer rendered.deinit();
    try graph.semantic_project_configs.append(a, .{ .package_name = try a.dupe(u8, "demo"), .raw = .null, .rendered = try values.clone(a, rendered.value) });
    const configured = try compiledPath(a, &graph, &node);
    defer a.free(configured);
    try std.testing.expectEqualStrings("project-output/compiled/demo/tests/check.sql", configured);
    for ([_][]const u8{ "relative-output", "/absolute-output" }, [_][]const u8{ "relative-output/compiled/demo/tests/check.sql", "/absolute-output/compiled/demo/tests/check.sql" }) |prefix, expected| {
        graph.command_options.target_path = prefix;
        const override = try compiledPath(a, &graph, &node);
        defer a.free(override);
        try std.testing.expectEqualStrings(expected, override);
    }
}
