//! Jinja html-safe, sorted, Python-style JSON serialization in native Zig.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;

pub fn render(a: std.mem.Allocator, value: Value, indent: ?[]const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try write(a, &out.writer, value, indent, 0);
    return out.toOwnedSlice();
}
fn quote(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    while (iterator.nextCodepoint()) |code| switch (code) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        8 => try w.writeAll("\\b"),
        12 => try w.writeAll("\\f"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        '<', '>', '&', '\'', 0...7, 11, 14...31, 127...0xffff => try w.print("\\u{x:0>4}", .{@as(u16, @intCast(code))}),
        0x10000...0x10ffff => {
            const offset = @as(u32, code) - 0x10000;
            try w.print("\\u{x:0>4}\\u{x:0>4}", .{ @as(u16, @intCast(0xd800 + (offset >> 10))), @as(u16, @intCast(0xdc00 + (offset & 0x3ff))) });
        },
        else => try w.writeByte(@intCast(code)),
    };
    try w.writeByte('"');
}
fn newline(w: *std.Io.Writer, indent: []const u8, depth: usize) !void {
    try w.writeByte('\n');
    for (0..depth) |_| try w.writeAll(indent);
}
fn write(a: std.mem.Allocator, w: *std.Io.Writer, value: Value, indent: ?[]const u8, depth: usize) anyerror!void {
    if (depth > 128) return error.JinjaExpressionDepthExceeded;
    if (expression.integerProtocol(value)) |number| return w.writeAll(number);
    if (expression.floatProtocol(value)) |number| {
        if (std.math.isNan(number)) return w.writeAll("NaN");
        if (std.math.isInf(number)) return w.writeAll(if (number < 0) "-Infinity" else "Infinity");
        return @import("native_repr.zig").float(a, w, number);
    }
    switch (value) {
        .none => try w.writeAll("null"),
        .boolean => |v| try w.writeAll(if (v) "true" else "false"),
        .integer => |v| try w.writeAll(v),
        .number => |v| if (std.math.isNan(v)) try w.writeAll("NaN") else if (std.math.isInf(v)) try w.writeAll(if (v < 0) "-Infinity" else "Infinity") else try @import("native_repr.zig").float(a, w, v),
        .string => |v| try quote(w, v),
        .list, .tuple => |values| {
            try w.writeByte('[');
            for (values, 0..) |item, index| {
                if (index != 0) try w.writeAll(if (indent != null) "," else ", ");
                if (indent) |spacing| try newline(w, spacing, depth + 1);
                try write(a, w, item, indent, depth + 1);
            }
            if (values.len != 0) if (indent) |spacing| try newline(w, spacing, depth);
            try w.writeByte(']');
        },
        .object => |entries| {
            if (value.attribute("__dxt_noniterable").truthy() or value.attribute("__dxt_rendered") != .undefined or @import("expression_sequence.zig").kind(value) != null or expression.sequence(value) != null) return error.JinjaTypeError;
            const sorted = try a.dupe(expression.Entry, entries);
            defer a.free(sorted);
            try @import("mapping_keys.zig").sortJsonKeys(a, sorted);
            try w.writeByte('{');
            for (sorted, 0..) |entry, index| {
                if (index != 0) try w.writeAll(if (indent != null) "," else ", ");
                if (indent) |spacing| try newline(w, spacing, depth + 1);
                try quote(w, try @import("mapping_keys.zig").jsonKey(a, expression.entryKey(entry)));
                try w.writeAll(": ");
                try write(a, w, entry.value, indent, depth + 1);
            }
            if (entries.len != 0) if (indent) |spacing| try newline(w, spacing, depth);
            try w.writeByte('}');
        },
        else => return error.JinjaTypeError,
    }
}

test "tojson keeps numeric identities, HTML escaping, Unicode and sorted keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try expression.evaluate(a, "{'z':(1,1.0,-0.0),'a':'<é好😀>&\\\''}", null);
    try std.testing.expectEqualStrings("{\"a\": \"\\u003c\\u00e9\\u597d\\ud83d\\ude00\\u003e\\u0026\\u0027\", \"z\": [1, 1.0, -0.0]}", try render(a, value, null));
    try std.testing.expectEqualStrings("[\n  1,\n  1.0\n]", try render(a, .{ .tuple = &.{ .{ .integer = "1" }, .{ .number = 1.0 } } }, "  "));
}
