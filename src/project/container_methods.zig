const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const Argument = expression.Argument;

pub const Mutation = struct { result: Value = .none, original: ?Value = null, replacement: ?Value = null };

pub fn call(allocator: std.mem.Allocator, name: []const u8, args: []const Argument) !?Mutation {
    return callWithHost(allocator, name, args, null);
}

pub fn callWithHost(allocator: std.mem.Allocator, name: []const u8, args: []const Argument, host: ?expression.Host) !?Mutation {
    const prefix = "__dxt_value.";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    if (args.len == 0) return error.InvalidJinjaArguments;
    const method = name[prefix.len..];
    const receiver = args[0].value;
    if (receiver == .list) {
        var output: std.ArrayList(Value) = .empty;
        if (std.mem.eql(u8, method, "append")) {
            if (args.len != 2) return error.InvalidJinjaArguments;
            if (try growList(allocator, receiver, &.{args[1].value}, host)) |mutation| return mutation;
            try output.appendSlice(allocator, receiver.list);
            try output.append(allocator, args[1].value);
        } else if (std.mem.eql(u8, method, "extend")) {
            if (args.len != 2) return error.InvalidJinjaArguments;
            const additions = try expression.iterableValuesWithHost(allocator, args[1].value, host);
            if (try growList(allocator, receiver, additions, host)) |mutation| return mutation;
            try output.appendSlice(allocator, receiver.list);
            try output.appendSlice(allocator, additions);
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
        if (!@import("builtin_bound_method.zig").isMapping(receiver) or expression.mappingSource(receiver) != null) return null;
        var output: std.ArrayList(expression.Entry) = .empty;
        if (std.mem.eql(u8, method, "update")) {
            try output.appendSlice(allocator, receiver.object);
            var positional: usize = 0;
            for (args[1..]) |arg| {
                if (arg.name) |key| {
                    try expression.mappingPut(allocator, &output, .{ .string = key }, arg.value);
                } else {
                    positional += 1;
                    if (positional > 1) return error.InvalidJinjaArguments;
                    if (@import("builtin_bound_method.zig").isMapping(arg.value)) {
                        const source = expression.mappingSource(arg.value) orelse arg.value;
                        for (source.object) |entry| try expression.mappingPut(allocator, &output, expression.entryKey(entry), entry.value);
                    } else {
                        for (try expression.iterableValues(allocator, arg.value)) |pair| {
                            const cells = try expression.iterableValues(allocator, pair);
                            if (cells.len != 2) return error.JinjaTypeError;
                            try expression.mappingPut(allocator, &output, cells[0], cells[1]);
                        }
                    }
                }
            }
        } else if (std.mem.eql(u8, method, "clear")) {
            if (args.len != 1) return error.InvalidJinjaArguments;
        } else if (std.mem.eql(u8, method, "pop")) {
            if (args.len < 2 or args.len > 3) return error.InvalidJinjaArguments;
            for (args[1..]) |arg| if (arg.name != null) return error.InvalidJinjaArguments;
            const key = args[1].value;
            try expression.hashableKey(key);
            var removed: ?Value = null;
            for (receiver.object) |entry| {
                if (@import("mapping_keys.zig").matches(entry, key)) removed = entry.value else try output.append(allocator, entry);
            }
            if (removed) |value| return .{ .result = value, .original = receiver, .replacement = .{ .object = try ownedObject(allocator, output.items) } };
            if (args.len == 3) return .{ .result = args[2].value };
            return error.JinjaKeyError;
        } else if (std.mem.eql(u8, method, "setdefault")) {
            if (args.len < 2 or args.len > 3) return error.InvalidJinjaArguments;
            for (args[1..]) |arg| if (arg.name != null) return error.InvalidJinjaArguments;
            if (try expression.mappingEntry(receiver, args[1].value)) |entry| return .{ .result = entry.value };
            const value = if (args.len == 3) args[2].value else Value.none;
            try output.appendSlice(allocator, receiver.object);
            try expression.mappingPut(allocator, &output, args[1].value, value);
            return .{ .result = value, .original = receiver, .replacement = .{ .object = try ownedObject(allocator, output.items) } };
        } else if (std.mem.eql(u8, method, "popitem")) {
            if (args.len != 1) return error.InvalidJinjaArguments;
            if (receiver.object.len == 0) return error.JinjaKeyError;
            const entry = receiver.object[receiver.object.len - 1];
            const pair = try expression.allocateValues(allocator, 2);
            pair[0] = expression.entryKey(entry);
            pair[1] = entry.value;
            return .{ .result = .{ .tuple = pair }, .original = receiver, .replacement = .{ .object = try ownedObject(allocator, receiver.object[0 .. receiver.object.len - 1]) } };
        } else return null;
        return .{ .original = receiver, .replacement = .{ .object = try ownedObject(allocator, output.items) } };
    }
    return null;
}

fn growList(allocator: std.mem.Allocator, receiver: Value, additions: []const Value, host: ?expression.Host) !?Mutation {
    const current = host orelse return null;
    const extend = current.list_extend orelse return null;
    const replacement = try extend(current.context, receiver, additions, allocator);
    if (replacement != .list) return error.JinjaTypeError;
    return .{ .original = receiver, .replacement = replacement };
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
        for (@constCast(value.object)) |*entry| {
            if (entry.typed_key) |*key| try replaceAliases(key, original, replacement, depth + 1);
            try replaceAliases(&entry.value, original, replacement, depth + 1);
        }
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

test "render-owned list growth publishes aliases and keeps no-host mutation available" {
    const Fixture = struct {
        store: @import("mutable_list_growth.zig").Store(Value) = .{},
        calls: usize = 0,
        fn resolve(_: *anyopaque, _: []const u8, _: std.mem.Allocator) !Value {
            return .undefined;
        }
        fn invoke(_: *anyopaque, _: []const u8, _: []const Argument, _: std.mem.Allocator) !Value {
            return error.UnsupportedJinjaCall;
        }
        fn extend(raw: *anyopaque, receiver: Value, additions: []const Value, a: std.mem.Allocator) !Value {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return .{ .list = try self.store.extend(a, 1, receiver.list, additions) };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture: Fixture = .{};
    const host = expression.Host{ .context = &fixture, .resolve = Fixture.resolve, .call = Fixture.invoke, .list_extend = Fixture.extend };
    var receiver = Value{ .list = try ownedList(a, &.{.{ .integer = "1" }}) };
    var alias = Value{ .object = try ownedObject(a, &.{.{ .key = "child", .value = .{ .tuple = try a.dupe(Value, &.{receiver}) } }}) };
    const first = (try callWithHost(a, "__dxt_value.append", &.{ .{ .value = receiver }, .{ .value = .{ .integer = "2" } } }, host)).?;
    try replaceAliases(&alias, first.original.?, first.replacement.?, 0);
    receiver = first.replacement.?;
    const doubled = (try callWithHost(a, "__dxt_value.extend", &.{ .{ .value = receiver }, .{ .value = receiver } }, host)).?;
    try replaceAliases(&alias, doubled.original.?, doubled.replacement.?, 0);
    receiver = doubled.replacement.?;
    try std.testing.expectEqualStrings("[1, 2, 1, 2]", try receiver.text(a));
    try std.testing.expectEqualStrings("[1, 2, 1, 2]", try alias.attribute("child").tuple[0].text(a));
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    const fallback = (try call(a, "__dxt_value.append", &.{ .{ .value = receiver }, .{ .value = .{ .integer = "3" } } })).?;
    try std.testing.expectEqualStrings("[1, 2, 1, 2, 3]", try fallback.replacement.?.text(a));
    try std.testing.expectError(error.InvalidJinjaArguments, callWithHost(a, "__dxt_value.extend", &.{.{ .value = receiver }}, host));
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
}

test "method dictionary keys follow mutated receivers through nested tuple keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const methods = @import("builtin_bound_method.zig");
    const original = Value{ .object = try ownedObject(a, &.{}) };
    const method = (try methods.lookup(a, original, "get")).?;
    const nested_key = Value{ .tuple = try expression.allocateValues(a, 1) };
    @constCast(nested_key.tuple)[0] = method;
    var entries: std.ArrayList(expression.Entry) = .empty;
    try expression.mappingPut(a, &entries, method, .{ .string = "direct" });
    try expression.mappingPut(a, &entries, nested_key, .{ .string = "nested" });
    var mapping = Value{ .object = entries.items };
    const update = (try call(a, "__dxt_value.update", &.{
        .{ .value = original },
        .{ .value = .{ .object = &.{.{ .key = "x", .value = .{ .integer = "1" } }} } },
    })).?;
    try replaceAliases(&mapping, original, update.replacement.?, 0);
    const fresh = (try methods.lookup(a, update.replacement.?, "get")).?;
    try std.testing.expectEqualStrings("direct", (try expression.mappingGet(mapping, fresh)).string);
    try std.testing.expectEqualStrings("nested", (try expression.mappingGet(mapping, .{ .tuple = &.{fresh} })).string);
    try std.testing.expectEqualStrings("1", (try methods.call(a, expression.entryKey(mapping.object[0]), &.{.{ .value = .{ .string = "x" } }}, null)).integer);
}

test "dictionary updates preserve first numeric key and undefined stored values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const original = try expression.evaluate(allocator, "{true:'first'}", null);
    const update = try expression.evaluate(allocator, "{1.0:'new',none:'null'}", null);
    const changed = (try call(allocator, "__dxt_value.update", &.{ .{ .value = original }, .{ .value = update } })).?;
    const result = changed.replacement.?;
    try std.testing.expectEqual(@as(usize, 2), result.object.len);
    try std.testing.expectEqual(true, expression.entryKey(result.object[0]).boolean);
    try std.testing.expectEqualStrings("new", (try expression.mappingGet(result, .{ .integer = "1" })).string);
    const stored = expression.Value{ .object = try ownedObject(allocator, &.{.{ .key = "present", .value = .undefined }}) };
    const existing = (try call(allocator, "__dxt_value.setdefault", &.{ .{ .value = stored }, .{ .value = .{ .string = "present" } }, .{ .value = .{ .string = "fallback" } } })).?;
    try std.testing.expect(existing.result == .undefined);
    try std.testing.expect(existing.replacement == null);
}
