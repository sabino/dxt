const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const Argument = expression.Argument;

pub const Mutation = struct { result: Value = .none, original: ?Value = null, replacement: ?Value = null };

pub fn call(allocator: std.mem.Allocator, name: []const u8, args: []const Argument) !?Mutation {
    const prefix = "__dxt_value.";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    if (args.len == 0) return error.InvalidJinjaArguments;
    const method = name[prefix.len..];
    const receiver = args[0].value;
    if (receiver == .list) {
        var output: std.ArrayList(Value) = .empty;
        if (std.mem.eql(u8, method, "append")) {
            if (args.len != 2) return error.InvalidJinjaArguments;
            try output.appendSlice(allocator, receiver.list);
            try output.append(allocator, args[1].value);
        } else if (std.mem.eql(u8, method, "extend")) {
            if (args.len != 2) return error.InvalidJinjaArguments;
            try output.appendSlice(allocator, receiver.list);
            try output.appendSlice(allocator, try expression.iterableValues(allocator, args[1].value));
        } else if (std.mem.eql(u8, method, "clear")) {
            if (args.len != 1) return error.InvalidJinjaArguments;
        } else if (std.mem.eql(u8, method, "pop")) {
            if (args.len > 2) return error.InvalidJinjaArguments;
            if (receiver.list.len == 0) return error.JinjaIndexError;
            var index: i64 = @as(i64, @intCast(receiver.list.len)) - 1;
            if (args.len == 2) {
                index = try expression.integerIndex(args[1].value);
                if (index < 0) index += @intCast(receiver.list.len);
            }
            if (index < 0 or index >= receiver.list.len) return error.JinjaIndexError;
            const at: usize = @intCast(index);
            try output.appendSlice(allocator, receiver.list[0..at]);
            try output.appendSlice(allocator, receiver.list[at + 1 ..]);
            return .{ .result = receiver.list[at], .original = receiver, .replacement = .{ .list = try ownedList(allocator, output.items) } };
        } else return null;
        return .{ .original = receiver, .replacement = .{ .list = try ownedList(allocator, output.items) } };
    }
    if (receiver == .object) {
        var output: std.ArrayList(expression.Entry) = .empty;
        if (std.mem.eql(u8, method, "update")) {
            try output.appendSlice(allocator, receiver.object);
            var positional: usize = 0;
            for (args[1..]) |arg| {
                if (arg.name) |key| {
                    try put(allocator, &output, key, arg.value);
                } else {
                    positional += 1;
                    if (positional > 1) return error.InvalidJinjaArguments;
                    if (arg.value == .object) {
                        for (arg.value.object) |entry| try put(allocator, &output, entry.key, entry.value);
                    } else {
                        for (try expression.iterableValues(allocator, arg.value)) |pair| {
                            const cells = try expression.iterableValues(allocator, pair);
                            if (cells.len != 2 or cells[0] != .string) return error.JinjaTypeError;
                            try put(allocator, &output, cells[0].string, cells[1]);
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, method, "clear")) {
            if (args.len != 1) return error.InvalidJinjaArguments;
        } else if (std.mem.eql(u8, method, "pop")) {
            if (args.len < 2 or args.len > 3 or args[1].value != .string) return error.InvalidJinjaArguments;
            const key = args[1].value.string;
            var removed: ?Value = null;
            for (receiver.object) |entry| {
                if (std.mem.eql(u8, entry.key, key)) removed = entry.value else try output.append(allocator, entry);
            }
            if (removed) |value| return .{ .result = value, .original = receiver, .replacement = .{ .object = try ownedObject(allocator, output.items) } };
            if (args.len == 3) return .{ .result = args[2].value };
            return error.JinjaKeyError;
        } else return null;
        return .{ .original = receiver, .replacement = .{ .object = try ownedObject(allocator, output.items) } };
    }
    return null;
}

fn ownedList(allocator: std.mem.Allocator, items: []const Value) ![]const Value {
    const output = try allocator.alloc(Value, @max(items.len, 1));
    @memcpy(output[0..items.len], items);
    return output[0..items.len];
}

fn ownedObject(allocator: std.mem.Allocator, items: []const expression.Entry) ![]const expression.Entry {
    const output = try allocator.alloc(expression.Entry, @max(items.len, 1));
    @memcpy(output[0..items.len], items);
    return output[0..items.len];
}

fn put(allocator: std.mem.Allocator, output: *std.ArrayList(expression.Entry), key: []const u8, value: Value) !void {
    for (output.items) |*entry| if (std.mem.eql(u8, entry.key, key)) {
        entry.value = value;
        return;
    };
    try output.append(allocator, .{ .key = key, .value = value });
}

/// A mutable receiver can be shared by a local name, a macro argument and a
/// nested container. Updating every reachable alias preserves Python/Jinja's
/// reference behavior without retaining pointers to temporary stack values.
pub fn replaceAliases(value: *Value, original: Value, replacement: Value, depth: usize) !void {
    if (depth > 128) return error.JinjaExpressionDepthExceeded;
    if (value.* == .list) {
        if (original == .list and value.list.ptr == original.list.ptr and value.list.len == original.list.len) {
            value.* = replacement;
            return;
        }
        for (@constCast(value.list)) |*child| try replaceAliases(child, original, replacement, depth + 1);
    } else if (value.* == .tuple) {
        for (@constCast(value.tuple)) |*child| try replaceAliases(child, original, replacement, depth + 1);
    } else if (value.* == .object) {
        if (original == .object and value.object.ptr == original.object.ptr and value.object.len == original.object.len) {
            value.* = replacement;
            return;
        }
        for (@constCast(value.object)) |*entry| try replaceAliases(&entry.value, original, replacement, depth + 1);
    }
}

test "container mutations preserve nested shared receiver aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const original = Value{ .list = try ownedList(allocator, &.{.{ .number = 1 }}) };
    var alias = Value{ .object = try ownedObject(allocator, &.{.{ .key = "child", .value = original }}) };
    const change = (try call(allocator, "__dxt_value.append", &.{ .{ .value = original }, .{ .value = .{ .number = 2 } } })).?;
    try replaceAliases(&alias, change.original.?, change.replacement.?, 0);
    try std.testing.expectEqual(@as(usize, 2), alias.attribute("child").list.len);
}
