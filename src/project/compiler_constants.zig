//! Compiled functions retain immutable constants while mutable literals stay fresh.
const std = @import("std");
const expression = @import("expression.zig");
const constants = @import("expression_constants.zig");
const Value = expression.Value;

pub const Pool = struct {
    values: std.StringHashMapUnmanaged(Value) = .empty,

    /// The allocator belongs to the render arena, shared by all macro frames.
    pub fn intern(self: *Pool, allocator: std.mem.Allocator, function: []const u8, value: Value) anyerror!Value {
        return self.internDepth(allocator, function, value, 0);
    }

    fn internDepth(self: *Pool, allocator: std.mem.Allocator, function: []const u8, value: Value, depth: usize) anyerror!Value {
        if (depth > 128) return error.JinjaExpressionDepthExceeded;
        // Numeric objects are immutable scalar protocols, including nonfinite
        // runtime constructors, rather than authored mutable dictionaries.
        const numeric = expression.floatProtocol(value) != null or expression.complexProtocol(value) != null;
        const token = try constants.key(allocator, value);
        if (token) |key| {
            const scope = if (constants.globallyInterned(value)) "" else function;
            const scoped_key = try std.fmt.allocPrint(allocator, "{d}:{s}:{s}", .{ scope.len, scope, key });
            if (self.values.get(scoped_key)) |previous| return previous;
            var constant = constants.globalString(value);
            if (value == .tuple) {
                const members = try expression.allocateValues(allocator, value.tuple.len);
                for (value.tuple, members) |member, *target| target.* = try self.internDepth(allocator, function, member, depth + 1);
                constant = .{ .tuple = members };
            }
            try self.values.put(allocator, scoped_key, constant);
            return constant;
        }
        if (numeric) return value;
        return switch (value) {
            .list => |original| blk: {
                const members = try expression.allocateValues(allocator, original.len);
                for (original, members) |member, *target| target.* = try self.internDepth(allocator, function, member, depth + 1);
                break :blk .{ .list = members };
            },
            .object => |original| blk: {
                const entries = try expression.allocateEntries(allocator, original.len);
                for (original, entries) |entry, *target| target.* = .{
                    .key = entry.key,
                    .typed_key = if (entry.typed_key) |key| try self.internDepth(allocator, function, key, depth + 1) else null,
                    .value = try self.internDepth(allocator, function, entry.value, depth + 1),
                };
                break :blk .{ .object = entries };
            },
            else => value,
        };
    }
};

test "function constants remain distinct and mutable literal containers stay fresh" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var pool: Pool = .{};
    const first = try pool.intern(a, "macro.first", try expression.integerValue(a, 1000));
    const repeated = try pool.intern(a, "macro.first", try expression.integerValue(a, 1000));
    const other = try pool.intern(a, "macro.second", try expression.integerValue(a, 1000));
    try std.testing.expect(first.integer.ptr == repeated.integer.ptr);
    try std.testing.expect(first.integer.ptr != other.integer.ptr);
    const word = try pool.intern(a, "macro.first", .{ .string = try a.dupe(u8, "word") });
    const other_word = try pool.intern(a, "macro.second", .{ .string = try a.dupe(u8, "word") });
    try std.testing.expect(word.string.ptr == other_word.string.ptr);
    const values = [_]Value{first};
    const left = try pool.intern(a, "macro.first", .{ .list = &values });
    const right = try pool.intern(a, "macro.first", .{ .list = &values });
    try std.testing.expect(left.list.ptr != right.list.ptr);
    try std.testing.expect(left.list[0].integer.ptr == right.list[0].integer.ptr);
}
