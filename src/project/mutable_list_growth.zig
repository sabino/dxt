//! Render-owned amortized backing storage for mutable native lists.
const std = @import("std");

pub fn Store(comptime Item: type) type {
    return struct {
        buffers: std.AutoHashMapUnmanaged(usize, std.ArrayList(Item)) = .empty,
        const Self = @This();

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            var buffers = self.buffers.valueIterator();
            while (buffers.next()) |buffer| buffer.deinit(allocator);
            self.buffers.deinit(allocator);
            self.* = .{};
        }

        /// The identity is owned by the render's receiver registry. A clear,
        /// pop or external replacement supplies its current contents again.
        pub fn extend(self: *Self, allocator: std.mem.Allocator, identity: usize, receiver: []const Item, additions: []const Item) ![]const Item {
            if (additions.len == 0) return receiver;
            const entry = try self.buffers.getOrPut(allocator, identity);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            const buffer = entry.value_ptr;
            const unchanged = buffer.items.ptr == receiver.ptr and buffer.items.len == receiver.len;
            const borrowed_receiver = containedOffset(buffer.items, receiver);

            // Self-extension must keep its original input through reallocation.
            // An external replacement may also overwrite a borrowed input.
            const borrowed = containedOffset(buffer.items, additions);
            const snapshot = if (!unchanged and borrowed != null) try allocator.dupe(Item, additions) else null;
            defer if (snapshot) |owned| allocator.free(owned);
            const length = std.math.add(usize, receiver.len, additions.len) catch return error.OutOfMemory;
            try buffer.ensureTotalCapacity(allocator, length);
            if (!unchanged) {
                const current = if (borrowed_receiver) |offset| buffer.items[offset..][0..receiver.len] else receiver;
                std.mem.copyForwards(Item, buffer.allocatedSlice()[0..receiver.len], current);
                buffer.items.len = receiver.len;
            }
            const source = if (snapshot) |owned| owned else if (borrowed) |offset| buffer.items[offset..][0..additions.len] else additions;
            buffer.appendSliceAssumeCapacity(source);
            return buffer.items;
        }

        fn containedOffset(owner: []const Item, input: []const Item) ?usize {
            if (owner.len == 0 or input.len == 0 or @sizeOf(Item) == 0) return null;
            const start = @intFromPtr(owner.ptr);
            const address = @intFromPtr(input.ptr);
            if (address < start) return null;
            const bytes = address - start;
            if (bytes % @sizeOf(Item) != 0) return null;
            const offset = bytes / @sizeOf(Item);
            if (offset > owner.len or input.len > owner.len - offset) return null;
            return offset;
        }
    };
}

test "seventy thousand ordered bindings use a linear allocation budget" {
    const Item = struct { row: usize, column: usize, payload: [4]usize = @splat(0) };
    // Disallow in-place reallocations to exercise the worst arena growth case.
    var measured = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    const a = measured.allocator();
    var store: Store(Item) = .{};
    defer store.deinit(a);
    var values: []const Item = &.{};
    for (0..10_000) |row| {
        var batch: [7]Item = undefined;
        for (&batch, 0..) |*item, column| item.* = .{ .row = row, .column = column };
        values = try store.extend(a, 1, values, &batch);
    }
    try std.testing.expectEqual(@as(usize, 70_000), values.len);
    for (values, 0..) |item, index| {
        try std.testing.expectEqual(index / 7, item.row);
        try std.testing.expectEqual(index % 7, item.column);
    }
    try std.testing.expect(measured.allocated_bytes < 16 * values.len * @sizeOf(Item));
    try std.testing.expect(measured.allocations < 128);
}

test "self extension survives moving allocations and receiver replacements" {
    var measured = std.testing.FailingAllocator.init(std.testing.allocator, .{ .resize_fail_index = 0 });
    const a = measured.allocator();
    var store: Store(u32) = .{};
    defer store.deinit(a);
    var values = try store.extend(a, 1, &.{}, &.{ 1, 2, 3, 4 });
    for (0..5) |_| values = try store.extend(a, 1, values, values);
    try std.testing.expectEqual(@as(usize, 128), values.len);
    for (values, 0..) |item, index| try std.testing.expectEqual(@as(u32, @intCast(index % 4 + 1)), item);
    // Pop/clear can replace the slice while retaining its registry identity.
    values = try store.extend(a, 1, &.{9}, &.{10});
    try std.testing.expectEqualSlices(u32, &.{ 9, 10 }, values);
    values = try store.extend(a, 1, &.{}, &.{11});
    try std.testing.expectEqualSlices(u32, &.{11}, values);
    try std.testing.expectEqualSlices(u32, &.{11}, try store.extend(a, 1, values, &.{}));
    const other = try store.extend(a, 2, &.{}, &.{ 12, 13 });
    try std.testing.expectEqualSlices(u32, &.{ 12, 13 }, other);
    try std.testing.expectEqualSlices(u32, &.{11}, values);
}

test "replacement preserves additions borrowed from the previous backing" {
    const a = std.testing.allocator;
    var store: Store(u32) = .{};
    defer store.deinit(a);
    const first = try store.extend(a, 1, &.{}, &.{ 1, 2, 3, 4 });
    try std.testing.expectEqualSlices(u32, &.{ 9, 3, 4 }, try store.extend(a, 1, &.{9}, first[2..]));
}
