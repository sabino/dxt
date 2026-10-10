const std = @import("std");
const config_value = @import("config_value.zig");
const expression = @import("expression.zig");

pub fn arguments(allocator: std.mem.Allocator, authored: std.json.Value, model: ?[]const u8, column: ?[]const u8) !std.json.Value {
    var value = if (authored == .object) try config_value.clone(allocator, authored) else std.json.Value{ .object = .empty };
    errdefer config_value.deinit(allocator, &value);
    if (model) |text| try config_value.put(allocator, &value, "model", .{ .string = text });
    if (column) |text| try config_value.put(allocator, &value, "column_name", .{ .string = text });
    return value;
}

pub fn sortedKeys(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![][]const u8 {
    const keys = try allocator.alloc([]const u8, object.count());
    var iterator = object.iterator();
    for (keys) |*key| key.* = iterator.next().?.key_ptr.*;
    std.mem.sort([]const u8, keys, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return keys;
}

/// dbt's schema generic-test identity recursively sorts mappings and converts
/// every scalar to its Python string representation before hashing repr().
pub fn hashableRepr(allocator: std.mem.Allocator, value: std.json.Value) anyerror![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    switch (value) {
        .object => |object| {
            try output.append(allocator, '{');
            const keys = try sortedKeys(allocator, object);
            defer allocator.free(keys);
            for (keys, 0..) |key, index| {
                if (index != 0) try output.appendSlice(allocator, ", ");
                const quoted = try quote(allocator, key);
                defer allocator.free(quoted);
                try output.appendSlice(allocator, quoted);
                try output.appendSlice(allocator, ": ");
                const child = try hashableRepr(allocator, object.get(key).?);
                defer allocator.free(child);
                try output.appendSlice(allocator, child);
            }
            try output.append(allocator, '}');
        },
        .array => |array| {
            try output.append(allocator, '[');
            for (array.items, 0..) |item, index| {
                if (index != 0) try output.appendSlice(allocator, ", ");
                const child = try hashableRepr(allocator, item);
                defer allocator.free(child);
                try output.appendSlice(allocator, child);
            }
            try output.append(allocator, ']');
        },
        else => {
            const text = try scalarText(allocator, value);
            defer allocator.free(text);
            const quoted = try quote(allocator, text);
            defer allocator.free(quoted);
            try output.appendSlice(allocator, quoted);
        },
    }
    return try output.toOwnedSlice(allocator);
}

pub fn scalarText(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const typed = try config_value.toExpression(arena.allocator(), value);
    return try allocator.dupe(u8, try typed.text(arena.allocator()));
}

fn quote(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const double = std.mem.indexOfScalar(u8, text, '\'') != null and std.mem.indexOfScalar(u8, text, '"') == null;
    const delimiter: u8 = if (double) '"' else '\'';
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.append(allocator, delimiter);
    for (text) |char| switch (char) {
        '\n' => try output.appendSlice(allocator, "\\n"),
        '\r' => try output.appendSlice(allocator, "\\r"),
        '\t' => try output.appendSlice(allocator, "\\t"),
        else => {
            if (char == delimiter or char == '\\') try output.append(allocator, '\\');
            try output.append(allocator, char);
        },
    };
    try output.append(allocator, delimiter);
    return try output.toOwnedSlice(allocator);
}

test "generic metadata sorts nested kwargs and stringifies typed leaves like Core" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"z\":true,\"a\":{\"n\":null,\"v\":[2,\"quoted'\"]}}", .{});
    defer parsed.deinit();
    const rendered = try hashableRepr(allocator, parsed.value);
    defer allocator.free(rendered);
    try std.testing.expectEqualStrings("{'a': {'n': 'None', 'v': ['2', \"quoted'\"]}, 'z': 'True'}", rendered);
}
