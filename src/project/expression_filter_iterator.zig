//! Shared lazy filter provider interface for the focused native filter slice.
const std = @import("std");
const expression = @import("expression.zig");
pub fn pull(_: std.mem.Allocator, _: expression.Value, _: ?expression.Host) !?expression.Value {
    return error.UnsupportedJinjaIterator;
}
