//! Shared iterator provider interface; constructors land in the next slice.
const std = @import("std");
const expression = @import("expression.zig");
pub fn resolve(_: std.mem.Allocator, _: []const u8) !?expression.Value {
    return null;
}
pub fn call(_: std.mem.Allocator, _: []const u8, _: []const expression.Argument, _: ?expression.Host) !?expression.Value {
    return null;
}
pub fn pull(_: std.mem.Allocator, _: expression.Value, _: ?expression.Host) !?expression.Value {
    return error.UnsupportedJinjaIterator;
}
