//! Jinja attribute paths use decimal digit parts as integer subscripts.
//! Unicode tables follow Python 3.12 / Unicode 15, generated with unicodedata.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const decimal_starts = [_]u21{ 0x30, 0x660, 0x6f0, 0x7c0, 0x966, 0x9e6, 0xa66, 0xae6, 0xb66, 0xbe6, 0xc66, 0xce6, 0xd66, 0xde6, 0xe50, 0xed0, 0xf20, 0x1040, 0x1090, 0x17e0, 0x1810, 0x1946, 0x19d0, 0x1a80, 0x1a90, 0x1b50, 0x1bb0, 0x1c40, 0x1c50, 0xa620, 0xa8d0, 0xa900, 0xa9d0, 0xa9f0, 0xaa50, 0xabf0, 0xff10, 0x104a0, 0x10d30, 0x11066, 0x110f0, 0x11136, 0x111d0, 0x112f0, 0x11450, 0x114d0, 0x11650, 0x116c0, 0x11730, 0x118e0, 0x11950, 0x11c50, 0x11d50, 0x11da0, 0x11f50, 0x16a60, 0x16ac0, 0x16b50, 0x1d7ce, 0x1d7d8, 0x1d7e2, 0x1d7ec, 0x1d7f6, 0x1e140, 0x1e2f0, 0x1e4f0, 0x1e950, 0x1fbf0 };
const nondecimal_digits = [_][2]u21{ .{ 0xb2, 0xb3 }, .{ 0xb9, 0xb9 }, .{ 0x1369, 0x1371 }, .{ 0x19da, 0x19da }, .{ 0x2070, 0x2070 }, .{ 0x2074, 0x2079 }, .{ 0x2080, 0x2089 }, .{ 0x2460, 0x2468 }, .{ 0x2474, 0x247c }, .{ 0x2488, 0x2490 }, .{ 0x24ea, 0x24ea }, .{ 0x24f5, 0x24fd }, .{ 0x24ff, 0x24ff }, .{ 0x2776, 0x277e }, .{ 0x2780, 0x2788 }, .{ 0x278a, 0x2792 }, .{ 0x10a40, 0x10a43 }, .{ 0x10e60, 0x10e68 }, .{ 0x11052, 0x1105a }, .{ 0x1f100, 0x1f10a } };

pub fn parts(a: std.mem.Allocator, attribute: Value) ![]const Value {
    if (attribute == .none) return &.{};
    if (attribute != .string) return a.dupe(Value, &.{attribute});
    var result: std.ArrayList(Value) = .empty;
    var segments = std.mem.splitScalar(u8, attribute.string, '.');
    while (segments.next()) |segment| try result.append(a, try part(a, segment));
    return result.toOwnedSlice(a);
}
fn part(a: std.mem.Allocator, text: []const u8) !Value {
    if (text.len == 0) return .{ .string = text };
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(a);
    var invalid = false;
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    while (iterator.nextCodepoint()) |code| {
        var digit: ?u8 = null;
        for (decimal_starts) |start| if (code >= start and code < start + 10) {
            digit = @intCast(code - start);
            break;
        };
        if (digit) |number| {
            try digits.append(a, '0' + number);
            continue;
        }
        var is_digit = false;
        for (nondecimal_digits) |range| if (code >= range[0] and code <= range[1]) {
            is_digit = true;
            break;
        };
        if (!is_digit) return .{ .string = text };
        invalid = true;
    }
    if (invalid) return error.InvalidJinjaArguments;
    return .{ .integer = try @import("expression_number.zig").canonical(a, digits.items, 10) };
}

pub fn get(a: std.mem.Allocator, input: Value, path: []const Value, fallback: Value, host: ?expression.Host) !Value {
    var result = input;
    for (path) |key| {
        const receiver = result;
        result = expression.indexValueWithHost(a, receiver, key, host) catch |err| switch (err) {
            error.JinjaTypeError => if (key == .string) try expression.attributeWithHost(a, receiver, key.string, host) else .undefined,
            else => return err,
        };
        if (result == .undefined and key == .string and receiver != .capture_undefined)
            result = try expression.attributeWithHost(a, receiver, key.string, host);
        if (result == .undefined) {
            const name = if (key == .string) key.string else try key.text(a);
            result = if (host != null and host.?.capture_undefined) try expression.captureUndefined(a, name) else try expression.undefinedValue(a, name);
        }
        if (expression.isUndefined(result) and fallback != .none) result = fallback;
    }
    return result;
}

test "attribute paths distinguish signed string keys and Unicode decimal indices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try parts(a, .{ .string = "١.０" });
    try std.testing.expectEqualStrings("1", path[0].integer);
    try std.testing.expectEqualStrings("0", path[1].integer);
    try std.testing.expectEqualStrings("-1", (try parts(a, .{ .string = "-1" }))[0].string);
    try std.testing.expectError(error.InvalidJinjaArguments, parts(a, .{ .string = "²" }));
}
