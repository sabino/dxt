//! Render-owned forwarding for saved methods whose mutable receiver changes
//! backing storage. Descriptors contain values and IDs, never a render pointer.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const Allocator = std.mem.Allocator;

pub const Key = struct {
    tag: std.meta.Tag(Value),
    pointer: usize,
    length: usize,

    pub fn from(value: Value) ?Key {
        return switch (value) {
            .object => .{ .tag = .object, .pointer = @intFromPtr(value.object.ptr), .length = value.object.len },
            .list => .{ .tag = .list, .pointer = @intFromPtr(value.list.ptr), .length = value.list.len },
            .tuple => .{ .tag = .tuple, .pointer = if (value.tuple.len == 0) 0 else @intFromPtr(value.tuple.ptr), .length = value.tuple.len },
            .string => .{ .tag = .string, .pointer = if (value.string.len == 0) 0 else @intFromPtr(value.string.ptr), .length = value.string.len },
            else => null,
        };
    }
};

pub const Registry = struct {
    receivers: std.AutoHashMapUnmanaged(Key, *Cell) = .empty,
    identities: std.AutoHashMapUnmanaged(usize, void) = .empty,
    const Cell = struct { identity: usize, current: Value };

    pub fn identity(self: *Registry, a: Allocator, value: Value) !usize {
        const key = Key.from(value) orelse return error.JinjaTypeError;
        if (self.receivers.get(key)) |cell| return cell.identity;
        // The initial destination backing address also gives unregistered,
        // publicly cloned descriptors the same identity as a fresh lookup.
        var id = key.pointer;
        while (id != 0 and self.identities.contains(id)) id = @intFromPtr(try a.create(u8));
        const cell = try a.create(Cell);
        cell.* = .{ .identity = id, .current = value };
        try self.receivers.put(a, key, cell);
        try self.identities.put(a, id, {});
        return id;
    }

    pub fn current(self: *const Registry, value: Value) Value {
        const key = Key.from(value) orelse return value;
        if (self.receivers.get(key)) |cell| return cell.current;
        return value;
    }

    pub fn forward(self: *Registry, a: Allocator, original: Value, replacement: Value) !void {
        _ = try self.identity(a, original);
        const cell = self.receivers.get(Key.from(original).?).?;
        const key = Key.from(replacement) orelse return error.JinjaTypeError;
        cell.current = replacement;
        try self.receivers.put(a, key, cell);
    }
};

test "receiver forwarding retains IDs and separates equal empty containers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var registry: Registry = .{};
    const first = Value{ .list = try expression.allocateValues(a, 0) };
    const distinct = Value{ .list = try expression.allocateValues(a, 0) };
    const id = try registry.identity(a, first);
    try std.testing.expect(id != try registry.identity(a, distinct));
    const second = Value{ .list = try a.dupe(Value, &.{.{ .integer = "1" }}) };
    const third = Value{ .list = try a.dupe(Value, &.{ .{ .integer = "1" }, .{ .integer = "2" } }) };
    try registry.forward(a, first, second);
    try registry.forward(a, second, third);
    try std.testing.expectEqual(id, try registry.identity(a, third));
    try std.testing.expect(registry.current(first).list.ptr == third.list.ptr);
    try std.testing.expectEqual(try registry.identity(a, .{ .tuple = try expression.allocateValues(a, 0) }), try registry.identity(a, .{ .tuple = try expression.allocateValues(a, 0) }));
    try std.testing.expectEqual(try registry.identity(a, .{ .string = try a.dupe(u8, "") }), try registry.identity(a, .{ .string = "" }));
}
