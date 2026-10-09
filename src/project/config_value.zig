const std = @import("std");
const expression = @import("expression.zig");

pub fn toExpression(allocator: std.mem.Allocator, value: std.json.Value) anyerror!expression.Value {
    return switch (value) {
        .null => .none,
        .bool => |v| .{ .boolean = v },
        .integer => |v| try expression.integerValue(allocator, v),
        .float => |v| .{ .number = v },
        .number_string => |v| if (std.mem.indexOfAny(u8, v, ".eE") != null) .{ .number = try std.fmt.parseFloat(f64, v) } else .{ .integer = try @import("expression_number.zig").canonical(allocator, v, 10) },
        .string => |v| .{ .string = v },
        .array => |items| blk: {
            const values = try expression.allocateValues(allocator, items.items.len);
            for (items.items, values) |item, *result| result.* = try toExpression(allocator, item);
            break :blk .{ .list = values };
        },
        .object => |object| blk: {
            const entries = try expression.allocateEntries(allocator, object.count());
            var it = object.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) entries[i] = .{ .key = entry.key_ptr.*, .value = try toExpression(allocator, entry.value_ptr.*) };
            break :blk .{ .object = entries };
        },
    };
}

pub fn fromExpression(allocator: std.mem.Allocator, value: expression.Value) anyerror!std.json.Value {
    if (expression.integerProtocol(value)) |number| return fromExpression(allocator, .{ .integer = number });
    return switch (value) {
        .none => .null,
        .undefined, .conditional_undefined, .callable, .complex => error.InvalidConfiguration,
        .boolean => |v| .{ .bool = v },
        .integer => |v| if (std.fmt.parseInt(i64, v, 10)) |number| .{ .integer = number } else |_| .{ .number_string = try allocator.dupe(u8, v) },
        .number => |v| .{ .float = v },
        .string => |v| .{ .string = try allocator.dupe(u8, v) },
        .list, .tuple => |items| blk: {
            var array = std.json.Array.init(allocator);
            for (items) |item| try array.append(try fromExpression(allocator, item));
            break :blk .{ .array = array };
        },
        .object => |entries| blk: {
            var object: std.json.ObjectMap = .empty;
            for (entries) |entry| try object.put(allocator, try allocator.dupe(u8, entry.key), try fromExpression(allocator, entry.value));
            break :blk .{ .object = object };
        },
    };
}

/// Configuration values own their storage, independent of YAML documents and
/// temporary Jinja frames. This permits the raw and effective maps to survive
/// until artifact emission without retaining profile documents or credentials.
pub fn clone(allocator: std.mem.Allocator, value: std.json.Value) anyerror!std.json.Value {
    return switch (value) {
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .array => |items| blk: {
            var result = std.json.Array.init(allocator);
            errdefer {
                for (result.items) |*item| deinit(allocator, item);
                result.deinit();
            }
            for (items.items) |item| try result.append(try clone(allocator, item));
            break :blk .{ .array = result };
        },
        .object => |object| blk: {
            var result: std.json.ObjectMap = .empty;
            errdefer {
                var it = result.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    deinit(allocator, entry.value_ptr);
                }
                result.deinit(allocator);
            }
            var it = object.iterator();
            while (it.next()) |entry| try result.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try clone(allocator, entry.value_ptr.*));
            break :blk .{ .object = result };
        },
        else => value,
    };
}

pub fn deinit(allocator: std.mem.Allocator, value: *std.json.Value) void {
    switch (value.*) {
        .string, .number_string => |s| allocator.free(s),
        .array => |*items| {
            for (items.items) |*item| deinit(allocator, item);
            items.deinit();
        },
        .object => |*object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinit(allocator, entry.value_ptr);
            }
            object.deinit(allocator);
        },
        else => {},
    }
    value.* = .null;
}

pub fn get(value: std.json.Value, key: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(key) else null;
}

pub fn put(allocator: std.mem.Allocator, target: *std.json.Value, key: []const u8, value: std.json.Value) !void {
    if (target.* == .null) target.* = .{ .object = .empty };
    if (target.* != .object) return error.InvalidConfiguration;
    if (target.object.getPtr(key)) |existing| {
        const copy = try clone(allocator, value);
        deinit(allocator, existing);
        existing.* = copy;
    } else try target.object.put(allocator, try allocator.dupe(u8, key), try clone(allocator, value));
}

pub fn overlay(allocator: std.mem.Allocator, target: *std.json.Value, source: std.json.Value) !void {
    if (source == .null) return;
    if (source != .object) return error.InvalidConfiguration;
    var it = source.object.iterator();
    while (it.next()) |entry| try put(allocator, target, entry.key_ptr.*, entry.value_ptr.*);
}

pub fn scalarText(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return if (value == .string) try allocator.dupe(u8, value.string) else try std.json.Stringify.valueAlloc(allocator, value, .{});
}

test "typed configuration clones nested data and replaces independently" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"list\":[1,true,null,{\"label\":\"false\"}]}", .{});
    var copy = try clone(allocator, parsed.value);
    defer deinit(allocator, &copy);
    parsed.deinit();
    try std.testing.expectEqualStrings("false", copy.object.get("list").?.array.items[3].object.get("label").?.string);
    try put(allocator, &copy, "list", .{ .integer = 3 });
    try std.testing.expectEqual(@as(i64, 3), copy.object.get("list").?.integer);
}
