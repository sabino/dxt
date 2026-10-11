//! DuckDB's warning-once scope is shared by all connections in an invocation.
const std = @import("std");

pub const Registry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: ?@import("types.zig").Runtime = null,
    mutex: std.Io.Mutex = .init,
    messages: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Registry {
        return .{ .allocator = allocator, .io = io, .messages = .init(allocator) };
    }
    pub fn deinit(self: *Registry) void {
        var keys = self.messages.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.messages.deinit();
    }
    pub fn first(self: *Registry, message: []const u8) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.messages.contains(message)) return false;
        const owned = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned);
        try self.messages.put(owned, {});
        return true;
    }
};

test "warning registry deduplicates messages and resets with invocation ownership" {
    var io: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer io.deinit();
    var registry = Registry.init(std.testing.allocator, io.io());
    defer registry.deinit();
    try std.testing.expect(try registry.first("shared"));
    try std.testing.expect(!try registry.first("shared"));
    try std.testing.expect(try registry.first("another"));
    var next = Registry.init(std.testing.allocator, io.io());
    defer next.deinit();
    try std.testing.expect(try next.first("shared"));
}
