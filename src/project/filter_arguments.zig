//! Bind the named and positional parameters of standard Jinja filters.
const std = @import("std");
const expression = @import("expression.zig");

pub fn bind(a: std.mem.Allocator, args: []const expression.Argument, names: []const []const u8, defaults: []const expression.Value, required: usize) ![]expression.Value {
    const values = try a.dupe(expression.Value, defaults);
    const seen = try a.alloc(bool, names.len);
    @memset(seen, false);
    var position: usize = 0;
    var keyword_seen = false;
    for (args) |arg| {
        const at = if (arg.name) |name| blk: {
            keyword_seen = true;
            for (names, 0..) |parameter, index| if (std.mem.eql(u8, parameter, name)) break :blk index;
            return error.InvalidJinjaArguments;
        } else blk: {
            if (keyword_seen or position >= names.len) return error.InvalidJinjaArguments;
            const index = position;
            position += 1;
            break :blk index;
        };
        if (seen[at]) return error.InvalidJinjaArguments;
        seen[at] = true;
        values[at] = arg.value;
    }
    for (seen[0..required]) |supplied| if (!supplied) return error.InvalidJinjaArguments;
    return values;
}

test "filter arguments reject duplicates and preserve explicit None" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = &[_][]const u8{ "count", "fill" };
    const defaults = &[_]expression.Value{ .undefined, .none };
    const values = try bind(a, &.{ .{ .name = "fill", .value = .none }, .{ .name = "count", .value = .{ .integer = "2" } } }, names, defaults, 1);
    try std.testing.expectEqualStrings("2", values[0].integer);
    try std.testing.expectError(error.InvalidJinjaArguments, bind(a, &.{ .{ .value = .{ .integer = "2" } }, .{ .name = "count", .value = .none } }, names, defaults, 1));
    try std.testing.expectError(error.InvalidJinjaArguments, bind(a, &.{}, names, defaults, 1));
}
