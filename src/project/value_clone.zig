//! An owned graph copy preserves aliases across public render boundaries.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const Allocator = std.mem.Allocator;

const Key = struct { tag: std.meta.Tag(Value), pointer: usize, length: usize };

fn cachedCharacter(text: []const u8) bool {
    if (text.len == 0) return true;
    if (text.len > 2 or (std.unicode.utf8ByteSequenceLength(text[0]) catch return false) != text.len) return false;
    if ((std.unicode.utf8Decode(text) catch return false) > 255) return false;
    return @import("expression_identity.zig").cachedString(text).ptr == text.ptr;
}

pub fn clone(a: Allocator, value: Value, host: ?expression.Host) anyerror!Value {
    var graph: Graph = .{ .allocator = a, .host = host };
    defer graph.memo.deinit(a);
    return graph.copy(value);
}

const Graph = struct {
    allocator: Allocator,
    host: ?expression.Host,
    memo: std.AutoHashMapUnmanaged(Key, Value) = .empty,

    fn copy(self: *Graph, source: Value) anyerror!Value {
        const value = if (self.host) |host| if (host.receiver_value) |current| try current(host.context, source) else source else source;
        const key: Key = switch (value) {
            .string => |text| .{ .tag = .string, .pointer = @intFromPtr(text.ptr), .length = text.len },
            .integer => |text| .{ .tag = .integer, .pointer = @intFromPtr(text.ptr), .length = text.len },
            .callable => |text| .{ .tag = .callable, .pointer = @intFromPtr(text.ptr), .length = text.len },
            .list, .tuple => |items| .{ .tag = std.meta.activeTag(value), .pointer = @intFromPtr(items.ptr), .length = items.len },
            .object => |entries| .{ .tag = .object, .pointer = @intFromPtr(entries.ptr), .length = entries.len },
            .capture_undefined, .ordinary_undefined => |payload| .{ .tag = std.meta.activeTag(value), .pointer = @intFromPtr(payload), .length = 1 },
            else => return value,
        };
        if (self.memo.get(key)) |previous| return previous;
        const a = self.allocator;
        switch (value) {
            .string, .integer, .callable => |text| {
                const canonical = @import("expression_identity.zig").cachedString(text);
                const copied = if (value == .string and cachedCharacter(text)) canonical else try a.dupe(u8, text);
                const result: Value = switch (value) {
                    .string => .{ .string = copied },
                    .integer => .{ .integer = copied },
                    else => .{ .callable = copied },
                };
                try self.memo.put(a, key, result);
                return result;
            },
            .capture_undefined, .ordinary_undefined => |original| {
                const copied = try a.create(expression.CaptureUndefined);
                copied.* = original.*;
                copied.allocator = a;
                copied.name = if (original.name) |name| try a.dupe(u8, name) else null;
                copied.hint = if (original.hint) |hint| try a.dupe(u8, hint) else null;
                const result: Value = if (value == .capture_undefined) .{ .capture_undefined = copied } else .{ .ordinary_undefined = copied };
                try self.memo.put(a, key, result);
                return result;
            },
            .list, .tuple => |items| {
                const copied = try expression.allocateValues(a, items.len);
                @memset(copied, .none);
                const result: Value = if (value == .tuple) .{ .tuple = copied } else .{ .list = copied };
                try self.memo.put(a, key, result);
                for (items, copied) |item, *target| target.* = try self.copy(item);
                return result;
            },
            .object => |entries| {
                const copied = try expression.allocateEntries(a, entries.len);
                @memset(copied, .{ .key = "", .value = .none });
                const result: Value = .{ .object = copied };
                try self.memo.put(a, key, result);
                const bound = @import("builtin_bound_method.zig").isBound(value);
                for (entries, copied) |entry, *target| {
                    target.* = .{
                        .key = try a.dupe(u8, entry.key),
                        .typed_key = if (entry.typed_key) |typed| try self.copy(typed) else null,
                        .value = try self.copy(entry.value),
                    };
                }
                if (bound) {
                    // A new render owns a new registry: foreign IDs must not
                    // compare equal to unrelated local receiver records.
                    const receiver = result.attribute("__dxt_builtin_receiver");
                    const receiver_key = @import("compiler_receivers.zig").Key.from(receiver) orelse return error.JinjaTypeError;
                    for (copied) |*entry| {
                        if (std.mem.eql(u8, entry.key, "__dxt_builtin_receiver_identity")) entry.value = try expression.integerValue(a, receiver_key.pointer);
                        if (std.mem.eql(u8, entry.key, "__dxt_builtin_registered_identity")) entry.value = .{ .boolean = false };
                        if (std.mem.eql(u8, entry.key, "__dxt_builtin_portable_identity")) entry.value = .{ .boolean = true };
                    }
                }
                return result;
            },
            else => unreachable,
        }
    }
};

test "owned clone preserves saved receiver aliases after the source arena closes" {
    var destination = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer destination.deinit();
    const a = destination.allocator();
    var source_string: usize = 0;
    const copied = blk: {
        var source = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer source.deinit();
        const b = source.allocator();
        const payload = try b.dupe(u8, "PAYLOAD FROM A CLOSED SOURCE ARENA");
        source_string = @intFromPtr(payload.ptr);
        const xs = Value{ .list = try b.dupe(Value, &.{.{ .string = payload }}) };
        const methods = @import("builtin_bound_method.zig");
        const first = (try methods.lookup(b, xs, "append")).?;
        const fresh = (try methods.lookup(b, xs, "append")).?;
        const distinct = (try methods.lookup(b, .{ .list = try b.dupe(Value, xs.list) }, "append")).?;
        const original = Value{ .object = try b.dupe(expression.Entry, &.{
            .{ .key = "receiver", .value = xs },
            .{ .key = "method", .value = first },
            .{ .key = "fresh", .value = fresh },
            .{ .key = "key", .typed_key = first, .value = xs },
            .{ .key = "distinct", .value = distinct },
        }) };
        break :blk try clone(a, original, null);
    };
    const receiver = copied.attribute("receiver");
    const first = copied.attribute("method");
    const fresh = copied.attribute("fresh");
    try std.testing.expect(@intFromPtr(receiver.list[0].string.ptr) != source_string);
    try std.testing.expectEqualStrings("PAYLOAD FROM A CLOSED SOURCE ARENA", receiver.list[0].string);
    try std.testing.expect(receiver.list.ptr == first.attribute("__dxt_builtin_receiver").list.ptr);
    try std.testing.expect(receiver.list.ptr == fresh.attribute("__dxt_builtin_receiver").list.ptr);
    try std.testing.expect(first.object.ptr != fresh.object.ptr);
    try std.testing.expect(@import("builtin_bound_method.zig").equal(first, fresh));
    try std.testing.expect(!@import("builtin_bound_method.zig").equal(first, copied.attribute("distinct")));
    try std.testing.expect(copied.object[3].typed_key.?.object.ptr == first.object.ptr);
    try std.testing.expect(!first.attribute("__dxt_builtin_registered_identity").boolean);
    try std.testing.expect(first.attribute("__dxt_builtin_portable_identity").boolean);
    try std.testing.expectEqualStrings("append", first.attribute("__dxt_builtin_name").string);
}

test "graph cloning closes cycles and retains repeated mutable Undefined cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cells = try expression.allocateValues(a, 3);
    const original = Value{ .list = cells };
    cells[0] = original;
    cells[1] = try expression.captureUndefined(a, "missing");
    cells[2] = cells[1];
    const copied = try clone(a, original, null);
    try std.testing.expect(copied.list.ptr != original.list.ptr);
    try std.testing.expect(copied.list[0].list.ptr == copied.list.ptr);
    try std.testing.expect(copied.list[1].capture_undefined == copied.list[2].capture_undefined);
    try std.testing.expect(copied.list[1].capture_undefined != cells[1].capture_undefined);
}
