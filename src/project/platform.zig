//! Native host primitives shared by cache and artifact publication.
const std = @import("std");
const builtin = @import("builtin");

pub fn processId() u32 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .windows => std.os.windows.GetCurrentProcessId(),
        else => @intCast(std.c.getpid()),
    };
}

test "native process identity is stable and nonzero" {
    try std.testing.expect(processId() != 0);
    try std.testing.expectEqual(processId(), processId());
}
