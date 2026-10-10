//! Paths from actual writes survive rendering frames and worker publication.
const std = @import("std");
const types = @import("types.zig");

pub fn capture(allocator: std.mem.Allocator, destination: ?*?[]const u8, path: ?[]const u8) !void {
    const output = destination orelse return;
    const written = path orelse return;
    const owned = try allocator.dupe(u8, written);
    if (output.*) |old| allocator.free(old);
    output.* = owned;
}

pub fn publish(allocator: std.mem.Allocator, node: *types.Node, path: ?[]const u8) !void {
    try capture(allocator, &node.build_path, path);
}

pub fn compiledPath(allocator: std.mem.Allocator, graph: *const types.Graph, node: *const types.Node) ![]const u8 {
    const path = if (node.hook_index != null or std.mem.eql(u8, node.resource_type, "sql_operation"))
        try std.fs.path.join(allocator, &.{ node.original_file_path, node.path })
    else if (node.snapshot_yaml_definition)
        try std.fmt.allocPrint(allocator, "{s}/{s}.sql", .{ node.original_file_path, node.name })
    else
        try allocator.dupe(u8, if (std.mem.eql(u8, node.resource_type, "analysis")) node.path else node.original_file_path);
    defer allocator.free(path);
    return std.fs.path.join(allocator, &.{ targetPrefix(graph), "compiled", node.package_name, path });
}

fn targetPrefix(graph: *const types.Graph) []const u8 {
    if (graph.command_options.target_path) |path| return path;
    for (graph.semantic_project_configs.items) |config| {
        if (std.mem.eql(u8, config.package_name, graph.project_name)) if (@import("config_value.zig").get(config.rendered, "target-path")) |path| {
            if (path == .string) return path.string;
        };
    }
    return "target";
}

/// Write the actual compiled source before the materialization begins. The
/// manifest retains the configured target prefix rather than its resolved cwd.
pub fn writeCompiled(runtime: types.Runtime, graph: *const types.Graph, node: *const types.Node, sql: []const u8) ![]const u8 {
    const logical = try compiledPath(runtime.allocator, graph, node);
    errdefer runtime.allocator.free(logical);
    const physical = if (std.fs.path.isAbsolute(logical)) logical else try std.fs.path.join(runtime.allocator, &.{ graph.command_options.project_dir, logical });
    defer if (physical.ptr != logical.ptr) runtime.allocator.free(physical);
    if (std.fs.path.dirname(physical)) |parent| try std.Io.Dir.cwd().createDirPath(runtime.io, parent);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = physical, .data = sql });
    return logical;
}

test "actual artifact publication owns its path and preserves unwritten state" {
    const a = std.testing.allocator;
    var node = types.Node{ .unique_id = "model.fixture.m", .package_name = "fixture", .name = "m", .path = "m.sql", .original_file_path = "models/m.sql", .raw_code = "" };
    defer if (node.build_path) |path| a.free(path);
    const path = "output/run/fixture/models/m.sql";
    try publish(a, &node, path);
    try std.testing.expectEqualStrings(path, node.build_path.?);
    try std.testing.expect(node.build_path.?.ptr != path.ptr);
    try publish(a, &node, null);
    try std.testing.expectEqualStrings(path, node.build_path.?);
}
