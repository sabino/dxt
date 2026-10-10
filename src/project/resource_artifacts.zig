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
