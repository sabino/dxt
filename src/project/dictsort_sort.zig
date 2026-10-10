//! Native adaptation of CPython 3.12.14 Objects/listobject.c list sorting.
//! https://github.com/python/cpython/blob/v3.12.14/Objects/listobject.c
//! PSF license and copyright notices: vendor/cpython-strptime/LICENSE.txt.
//! Changes: generic Zig items/comparator, allocator-owned temporary storage,
//! slice indices instead of Python object pointers, and no Python runtime.
//! Preserve comparison order as well as stability: unordered float keys make
//! natural runs, powersort merges and galloping observable in dictsort output.
const std = @import("std");
const Allocator = std.mem.Allocator;
const minimum_gallop = 7;

pub fn sort(comptime T: type, a: Allocator, items: []T, context: anytype, comptime less: fn (@TypeOf(context), T, T) bool) !void {
    if (items.len < 2) return;
    var state = State(T, @TypeOf(context), less){ .allocator = a, .items = items, .context = context };
    defer a.free(state.temporary);
    const minimum = minRun(items.len);
    var start: usize = 0;
    while (start < items.len) {
        var length = state.countRun(start);
        if (length < minimum) {
            const forced = @min(minimum, items.len - start);
            state.binarySort(start, forced, length);
            length = forced;
        }
        try state.foundRun(length);
        std.debug.assert(state.pending_count < state.pending.len);
        state.pending[state.pending_count] = .{ .start = start, .length = length };
        state.pending_count += 1;
        start += length;
    }
    while (state.pending_count > 1) {
        var index = state.pending_count - 2;
        if (index > 0 and state.pending[index - 1].length < state.pending[index + 1].length) index -= 1;
        try state.mergeAt(index);
    }
}

fn minRun(length: usize) usize {
    var n = length;
    var remainder: usize = 0;
    while (n >= 64) : (n >>= 1) remainder |= n & 1;
    return n + remainder;
}

fn runPower(start: usize, first: usize, second: usize, length: usize) usize {
    // Wider intermediates retain the midpoint calculation at usize limits.
    var left = @as(u128, start) * 2 + first;
    var right = left + first + second;
    var power: usize = 0;
    while (true) {
        power += 1;
        if (left >= length) {
            left -= length;
            right -= length;
        } else if (right >= length) break;
        left *= 2;
        right *= 2;
    }
    return power;
}

// Clamp the exponential search step before arithmetic can overflow.
fn nextOffset(offset: usize, limit: usize) usize {
    return if (offset > (limit - 1) / 2) limit else offset * 2 + 1;
}

fn State(comptime T: type, comptime Context: type, comptime less: fn (Context, T, T) bool) type {
    return struct {
        const Self = @This();
        const Run = struct { start: usize, length: usize, power: usize = 0 };

        allocator: Allocator,
        items: []T,
        context: Context,
        temporary: []T = &.{},
        min_gallop: usize = minimum_gallop,
        pending: [@bitSizeOf(usize)]Run = undefined,
        pending_count: usize = 0,

        fn countRun(self: *Self, start: usize) usize {
            const remaining = self.items.len - start;
            if (remaining == 1) return 1;
            const descending = less(self.context, self.items[start + 1], self.items[start]);
            var length: usize = 2;
            while (length < remaining) : (length += 1) {
                if (less(self.context, self.items[start + length], self.items[start + length - 1]) != descending) break;
            }
            if (descending) std.mem.reverse(T, self.items[start..][0..length]);
            return length;
        }

        fn binarySort(self: *Self, start: usize, length: usize, sorted: usize) void {
            var at = @max(sorted, 1);
            while (at < length) : (at += 1) {
                const pivot = self.items[start + at];
                var left: usize = 0;
                var right = at;
                while (left < right) {
                    const middle = left + (right - left) / 2;
                    if (less(self.context, pivot, self.items[start + middle])) right = middle else left = middle + 1;
                }
                std.mem.copyBackwards(T, self.items[start + left + 1 .. start + at + 1], self.items[start + left .. start + at]);
                self.items[start + left] = pivot;
            }
        }

        fn gallopLeft(self: *Self, key: T, values: []const T, hint: usize) usize {
            std.debug.assert(values.len > 0 and hint < values.len);
            var last_offset: usize = 0;
            var offset: usize = 1;
            var left: usize = undefined;
            var right: usize = undefined;
            if (less(self.context, values[hint], key)) {
                const limit = values.len - hint;
                while (offset < limit) {
                    if (!less(self.context, values[hint + offset], key)) break;
                    last_offset = offset;
                    offset = nextOffset(offset, limit);
                }
                offset = @min(offset, limit);
                left = hint + last_offset + 1;
                right = hint + offset;
            } else {
                const limit = hint + 1;
                while (offset < limit) {
                    if (less(self.context, values[hint - offset], key)) break;
                    last_offset = offset;
                    offset = nextOffset(offset, limit);
                }
                offset = @min(offset, limit);
                left = hint + 1 - offset;
                right = hint - last_offset;
            }
            while (left < right) {
                const middle = left + (right - left) / 2;
                if (less(self.context, values[middle], key)) left = middle + 1 else right = middle;
            }
            return right;
        }

        fn gallopRight(self: *Self, key: T, values: []const T, hint: usize) usize {
            std.debug.assert(values.len > 0 and hint < values.len);
            var last_offset: usize = 0;
            var offset: usize = 1;
            var left: usize = undefined;
            var right: usize = undefined;
            if (less(self.context, key, values[hint])) {
                const limit = hint + 1;
                while (offset < limit) {
                    if (!less(self.context, key, values[hint - offset])) break;
                    last_offset = offset;
                    offset = nextOffset(offset, limit);
                }
                offset = @min(offset, limit);
                left = hint + 1 - offset;
                right = hint - last_offset;
            } else {
                const limit = values.len - hint;
                while (offset < limit) {
                    if (less(self.context, key, values[hint + offset])) break;
                    last_offset = offset;
                    offset = nextOffset(offset, limit);
                }
                offset = @min(offset, limit);
                left = hint + last_offset + 1;
                right = hint + offset;
            }
            while (left < right) {
                const middle = left + (right - left) / 2;
                if (less(self.context, key, values[middle])) right = middle else left = middle + 1;
            }
            return right;
        }

        fn ensureTemporary(self: *Self, needed: usize) !void {
            if (self.temporary.len >= needed) return;
            const replacement = try self.allocator.alloc(T, needed);
            self.allocator.free(self.temporary);
            self.temporary = replacement;
        }

        fn mergeLow(self: *Self, start: usize, first: usize, second: usize) !void {
            try self.ensureTemporary(first);
            std.mem.copyForwards(T, self.temporary[0..first], self.items[start..][0..first]);
            var a_index: usize = 0;
            var b_index = start + first;
            var destination = start;
            var a_left = first;
            var b_left = second;

            self.items[destination] = self.items[b_index];
            destination += 1;
            b_index += 1;
            b_left -= 1;
            var min_gallop = self.min_gallop;
            merge: while (b_left > 0 and a_left > 1) {
                var a_count: usize = 0;
                var b_count: usize = 0;
                while (true) {
                    if (less(self.context, self.items[b_index], self.temporary[a_index])) {
                        self.items[destination] = self.items[b_index];
                        destination += 1;
                        b_index += 1;
                        b_count += 1;
                        a_count = 0;
                        b_left -= 1;
                        if (b_left == 0) break :merge;
                        if (b_count >= min_gallop) break;
                    } else {
                        self.items[destination] = self.temporary[a_index];
                        destination += 1;
                        a_index += 1;
                        a_count += 1;
                        b_count = 0;
                        a_left -= 1;
                        if (a_left == 1) break :merge;
                        if (a_count >= min_gallop) break;
                    }
                }
                min_gallop += 1;
                while (true) {
                    if (min_gallop > 1) min_gallop -= 1;
                    self.min_gallop = min_gallop;
                    a_count = self.gallopRight(self.items[b_index], self.temporary[a_index..][0..a_left], 0);
                    if (a_count > 0) {
                        std.mem.copyForwards(T, self.items[destination..][0..a_count], self.temporary[a_index..][0..a_count]);
                        destination += a_count;
                        a_index += a_count;
                        a_left -= a_count;
                        // Non-total comparators can exhaust the run here.
                        if (a_left <= 1) break :merge;
                    }
                    self.items[destination] = self.items[b_index];
                    destination += 1;
                    b_index += 1;
                    b_left -= 1;
                    if (b_left == 0) break :merge;

                    b_count = self.gallopLeft(self.temporary[a_index], self.items[b_index..][0..b_left], 0);
                    if (b_count > 0) {
                        std.mem.copyForwards(T, self.items[destination..][0..b_count], self.items[b_index..][0..b_count]);
                        destination += b_count;
                        b_index += b_count;
                        b_left -= b_count;
                        if (b_left == 0) break :merge;
                    }
                    self.items[destination] = self.temporary[a_index];
                    destination += 1;
                    a_index += 1;
                    a_left -= 1;
                    if (a_left == 1) break :merge;
                    if (a_count < minimum_gallop and b_count < minimum_gallop) break;
                }
                min_gallop += 1;
                self.min_gallop = min_gallop;
            }
            if (a_left == 1 and b_left > 0) {
                std.mem.copyForwards(T, self.items[destination..][0..b_left], self.items[b_index..][0..b_left]);
                self.items[destination + b_left] = self.temporary[a_index];
            } else if (a_left > 0) {
                std.mem.copyForwards(T, self.items[destination..][0..a_left], self.temporary[a_index..][0..a_left]);
            }
        }

        fn mergeHigh(self: *Self, start: usize, first: usize, second: usize) !void {
            try self.ensureTemporary(second);
            std.mem.copyForwards(T, self.temporary[0..second], self.items[start + first ..][0..second]);
            // Exclusive destination and remaining lengths avoid negative indices.
            var destination = start + first + second;
            var a_left = first;
            var b_left = second;
            destination -= 1;
            a_left -= 1;
            self.items[destination] = self.items[start + a_left];
            var min_gallop = self.min_gallop;
            merge: while (a_left > 0 and b_left > 1) {
                var a_count: usize = 0;
                var b_count: usize = 0;
                while (true) {
                    if (less(self.context, self.temporary[b_left - 1], self.items[start + a_left - 1])) {
                        destination -= 1;
                        a_left -= 1;
                        self.items[destination] = self.items[start + a_left];
                        a_count += 1;
                        b_count = 0;
                        if (a_left == 0) break :merge;
                        if (a_count >= min_gallop) break;
                    } else {
                        destination -= 1;
                        b_left -= 1;
                        self.items[destination] = self.temporary[b_left];
                        b_count += 1;
                        a_count = 0;
                        if (b_left == 1) break :merge;
                        if (b_count >= min_gallop) break;
                    }
                }
                min_gallop += 1;
                while (true) {
                    if (min_gallop > 1) min_gallop -= 1;
                    self.min_gallop = min_gallop;
                    a_count = a_left - self.gallopRight(self.temporary[b_left - 1], self.items[start..][0..a_left], a_left - 1);
                    if (a_count > 0) {
                        destination -= a_count;
                        a_left -= a_count;
                        std.mem.copyBackwards(T, self.items[destination..][0..a_count], self.items[start + a_left ..][0..a_count]);
                        if (a_left == 0) break :merge;
                    }
                    destination -= 1;
                    b_left -= 1;
                    self.items[destination] = self.temporary[b_left];
                    if (b_left == 1) break :merge;

                    b_count = b_left - self.gallopLeft(self.items[start + a_left - 1], self.temporary[0..b_left], b_left - 1);
                    if (b_count > 0) {
                        destination -= b_count;
                        b_left -= b_count;
                        std.mem.copyForwards(T, self.items[destination..][0..b_count], self.temporary[b_left..][0..b_count]);
                        if (b_left <= 1) break :merge;
                    }
                    destination -= 1;
                    a_left -= 1;
                    self.items[destination] = self.items[start + a_left];
                    if (a_left == 0) break :merge;
                    if (a_count < minimum_gallop and b_count < minimum_gallop) break;
                }
                min_gallop += 1;
                self.min_gallop = min_gallop;
            }
            if (b_left == 1 and a_left > 0) {
                destination -= a_left;
                std.mem.copyBackwards(T, self.items[destination..][0..a_left], self.items[start..][0..a_left]);
                self.items[destination - 1] = self.temporary[0];
            } else if (b_left > 0) {
                std.mem.copyForwards(T, self.items[destination - b_left .. destination], self.temporary[0..b_left]);
            }
        }

        fn mergeAt(self: *Self, index: usize) !void {
            std.debug.assert(self.pending_count >= 2 and index + 1 < self.pending_count);
            var start = self.pending[index].start;
            var first = self.pending[index].length;
            const second_start = self.pending[index + 1].start;
            var second = self.pending[index + 1].length;
            std.debug.assert(start + first == second_start);
            self.pending[index].length = first + second;
            if (index + 3 == self.pending_count) self.pending[index + 1] = self.pending[index + 2];
            self.pending_count -= 1;

            const skipped = self.gallopRight(self.items[second_start], self.items[start..][0..first], 0);
            start += skipped;
            first -= skipped;
            if (first == 0) return;
            second = self.gallopLeft(self.items[start + first - 1], self.items[second_start..][0..second], second - 1);
            if (second == 0) return;
            if (first <= second) try self.mergeLow(start, first, second) else try self.mergeHigh(start, first, second);
        }

        fn foundRun(self: *Self, length: usize) !void {
            if (self.pending_count == 0) return;
            const previous = self.pending[self.pending_count - 1];
            const power = runPower(previous.start, previous.length, length, self.items.len);
            while (self.pending_count > 1 and self.pending[self.pending_count - 2].power > power) {
                try self.mergeAt(self.pending_count - 2);
            }
            self.pending[self.pending_count - 1].power = power;
        }
    };
}

const ProofItem = struct {
    key: f64,
    identity: usize,
    fn less(_: void, left: @This(), right: @This()) bool {
        return left.key < right.key;
    }
};

test "adaptive dictsort preserves stable ties and every item through merges" {
    var items: [257]ProofItem = undefined;
    for (&items, 0..) |*item, index| item.* = .{ .key = @floatFromInt((index * 47) % 29), .identity = index };
    try sort(ProofItem, std.testing.allocator, &items, {}, ProofItem.less);
    var seen = [_]bool{false} ** items.len;
    for (items, 0..) |item, index| {
        try std.testing.expect(!seen[item.identity]);
        seen[item.identity] = true;
        if (index > 0) {
            try std.testing.expect(items[index - 1].key <= item.key);
            if (items[index - 1].key == item.key) try std.testing.expect(items[index - 1].identity < item.identity);
        }
    }
}

test "adaptive dictsort retains CPython unordered natural run and reverse merge order" {
    const nan = std.math.nan(f64);
    var items = [_]ProofItem{
        .{ .key = 2, .identity = 0 }, .{ .key = nan, .identity = 1 },
        .{ .key = 1, .identity = 2 }, .{ .key = 3, .identity = 3 },
    };
    try sort(ProofItem, std.testing.allocator, &items, {}, ProofItem.less);
    for (items, 0..) |item, index| try std.testing.expectEqual(index, item.identity);
    std.mem.reverse(ProofItem, &items);
    try sort(ProofItem, std.testing.allocator, &items, {}, ProofItem.less);
    std.mem.reverse(ProofItem, &items);
    for (items, [_]usize{ 1, 3, 0, 2 }) |item, expected| try std.testing.expectEqual(expected, item.identity);
}

fn allocationProof(a: Allocator) !void {
    var items: [257]ProofItem = undefined;
    for (&items, 0..) |*item, index| item.* = .{ .key = @floatFromInt((index * 47) % 101), .identity = index };
    try sort(ProofItem, a, &items, {}, ProofItem.less);
}

test "adaptive dictsort propagates temporary allocation failures without leaks" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProof, .{});
}
