//! Python-compatible representations used by dbt's unit-definition checksum.
//! This is a native artifact codec; no interpreter is required by the product.
const std = @import("std");
const Writer = std.Io.Writer;

pub fn string(w: *Writer, text: []const u8) !void {
    const quote: u8 = if (std.mem.indexOfScalar(u8, text, '\'') != null and std.mem.indexOfScalar(u8, text, '"') == null) '"' else '\'';
    try w.writeByte(quote);
    var iter = (try std.unicode.Utf8View.init(text)).iterator();
    while (iter.nextCodepointSlice()) |bytes| {
        const code = try std.unicode.utf8Decode(bytes);
        switch (code) {
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => if (code == quote) {
                try w.writeByte('\\');
                try w.writeByte(quote);
            } else if (!printable(code)) {
                if (code <= 0xff) try w.print("\\x{x:0>2}", .{code}) else if (code <= 0xffff) try w.print("\\u{x:0>4}", .{code}) else try w.print("\\U{x:0>8}", .{code});
            } else try w.writeAll(bytes),
        }
    }
    try w.writeByte(quote);
}

fn printable(code: u21) bool {
    if (code < 128) return code >= 32 and code != 127;
    const ranges = @import("unicode_repr.zig").non_printable;
    var low: usize = 0;
    var high: usize = ranges.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (code < ranges[mid][0]) high = mid else if (code > ranges[mid][1]) low = mid + 1 else return false;
    }
    return true;
}

pub fn value(a: std.mem.Allocator, w: *Writer, v: std.json.Value) anyerror!void {
    switch (v) {
        .null => try w.writeAll("None"),
        .bool => |b| try w.writeAll(if (b) "True" else "False"),
        .string => |s| try string(w, s),
        .integer => |n| try w.print("{d}", .{n}),
        .float => |n| try float(a, w, n),
        .number_string => |s| if (std.mem.indexOfAny(u8, s, ".eE") != null) try float(a, w, try std.fmt.parseFloat(f64, s)) else try w.writeAll(s),
        .array => |items| {
            try w.writeByte('[');
            for (items.items, 0..) |item, i| {
                if (i != 0) try w.writeAll(", ");
                try value(a, w, item);
            }
            try w.writeByte(']');
        },
        .object => |object| {
            try w.writeByte('{');
            var it = object.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                if (i != 0) try w.writeAll(", ");
                try string(w, entry.key_ptr.*);
                try w.writeAll(": ");
                try value(a, w, entry.value_ptr.*);
            }
            try w.writeByte('}');
        },
    }
}

/// Preserve the integer/float distinction inside normalized fixture JSON.
/// std.json's compact float formatter emits `1` for 1.0, which changes Core's
/// repr checksum after nested fixture values are decoded again.
pub fn jsonAlloc(a: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    var out: Writer.Allocating = .init(a);
    errdefer out.deinit();
    try json(a, &out.writer, v);
    return out.toOwnedSlice();
}
fn json(a: std.mem.Allocator, w: *Writer, v: std.json.Value) anyerror!void {
    switch (v) {
        .float => |n| {
            if (!std.math.isFinite(n)) return error.NonFiniteUnitFixture;
            try float(a, w, n);
        },
        .array => |items| {
            try w.writeByte('[');
            for (items.items, 0..) |item, i| {
                if (i != 0) try w.writeByte(',');
                try json(a, w, item);
            }
            try w.writeByte(']');
        },
        .object => |object| {
            try w.writeByte('{');
            var it = object.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                if (i != 0) try w.writeByte(',');
                try std.json.Stringify.value(entry.key_ptr.*, .{}, w);
                try w.writeByte(':');
                try json(a, w, entry.value_ptr.*);
            }
            try w.writeByte('}');
        },
        else => try std.json.Stringify.value(v, .{}, w),
    }
}

pub fn float(a: std.mem.Allocator, w: *Writer, n: f64) !void {
    if (std.math.isNan(n)) return w.writeAll("nan");
    if (std.math.isInf(n)) return w.writeAll(if (n < 0) "-inf" else "inf");
    if (std.math.signbit(n)) try w.writeByte('-');
    const formatted = try std.fmt.allocPrint(a, "{e}", .{@abs(n)});
    defer a.free(formatted);
    const e = std.mem.indexOfScalar(u8, formatted, 'e') orelse return error.InvalidFloatRepresentation;
    const exponent = try std.fmt.parseInt(i32, formatted[e + 1 ..], 10);
    var digits: [32]u8 = undefined;
    var count: usize = 0;
    for (formatted[0..e]) |ch| if (ch != '.') {
        digits[count] = ch;
        count += 1;
    };
    while (count > 1 and digits[count - 1] == '0') count -= 1;
    if (exponent < -4 or exponent >= 16) {
        try w.writeByte(digits[0]);
        if (count > 1) {
            try w.writeByte('.');
            try w.writeAll(digits[1..count]);
        }
        try w.print("e{c}{d:0>2}", .{ @as(u8, if (exponent < 0) '-' else '+'), @abs(exponent) });
    } else {
        const position = exponent + 1;
        if (position <= 0) {
            try w.writeAll("0.");
            for (0..@intCast(-position)) |_| try w.writeByte('0');
            try w.writeAll(digits[0..count]);
        } else if (position >= count) {
            try w.writeAll(digits[0..count]);
            for (count..@intCast(position)) |_| try w.writeByte('0');
            try w.writeAll(".0");
        } else {
            try w.writeAll(digits[0..@intCast(position)]);
            try w.writeByte('.');
            try w.writeAll(digits[@intCast(position)..count]);
        }
    }
}

test "native repr matches Core floats and Unicode strings" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try string(&out.writer, "quote' and \"double\"\x00\xc2\xa0\xe2\x80\xa8café");
    try std.testing.expectEqualStrings("'quote\\' and \"double\"\\x00\\xa0\\u2028café'", out.written());
    out.clearRetainingCapacity();
    for ([_]f64{ 1.0, -0.0, 1.25, 0.0001, 0.00001, 1e15, 1e16, 1.23456789e20 }, 0..) |n, i| {
        if (i != 0) try out.writer.writeAll(",");
        try float(std.testing.allocator, &out.writer, n);
    }
    try std.testing.expectEqualStrings("1.0,-0.0,1.25,0.0001,1e-05,1000000000000000.0,1e+16,1.23456789e+20", out.written());
}
