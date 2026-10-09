//! Native Python str.format fields used by dbt's SQL materialization macros.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const Argument = expression.Argument;

fn positional(args: []const Argument, index: usize) !Value {
    var seen: usize = 0;
    for (args) |arg| if (arg.name == null) {
        if (seen == index) return arg.value;
        seen += 1;
    };
    return error.JinjaIndexError;
}

fn ascii(a: std.mem.Allocator, value: Value) ![]const u8 {
    const representation = try expression.repr(value, a);
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var iterator = (try std.unicode.Utf8View.init(representation)).iterator();
    while (iterator.nextCodepoint()) |code| {
        if (code < 128) try out.writer.writeByte(@intCast(code)) else if (code <= 0xff) try out.writer.print("\\x{x:0>2}", .{code}) else if (code <= 0xffff) try out.writer.print("\\u{x:0>4}", .{code}) else try out.writer.print("\\U{x:0>8}", .{code});
    }
    return out.toOwnedSlice();
}

const Numbering = struct { next: usize = 0, automatic: bool = false, manual: bool = false };

fn fieldValue(a: std.mem.Allocator, field: []const u8, args: []const Argument, numbering: *Numbering) !Value {
    const first_end = std.mem.indexOfAny(u8, field, ".[!") orelse field.len;
    const first = field[0..first_end];
    var result: Value = undefined;
    if (first.len == 0) {
        if (numbering.manual) return error.InvalidJinjaArguments;
        numbering.automatic = true;
        result = try positional(args, numbering.next);
        numbering.next += 1;
    } else if (std.fmt.parseInt(usize, first, 10)) |index| {
        if (numbering.automatic) return error.InvalidJinjaArguments;
        numbering.manual = true;
        result = try positional(args, index);
    } else |_| {
        result = .undefined;
        for (args) |arg| if (arg.name) |name| if (std.mem.eql(u8, name, first)) {
            result = arg.value;
            break;
        };
        if (result == .undefined) return error.JinjaKeyError;
    }
    var position = first_end;
    while (position < field.len) {
        if (field[position] == '.') {
            position += 1;
            const end = position + (std.mem.indexOfAny(u8, field[position..], ".[!") orelse field.len - position);
            if (position == end) return error.InvalidJinjaExpression;
            result = try expression.checkedAttribute(result, field[position..end]);
            position = end;
        } else if (field[position] == '[') {
            const end = std.mem.indexOfScalarPos(u8, field, position + 1, ']') orelse return error.InvalidJinjaExpression;
            const key = field[position + 1 .. end];
            if (result == .object) {
                result = result.attribute(key);
            } else {
                const values = expression.sequence(result) orelse return error.JinjaTypeError;
                const index = std.fmt.parseInt(usize, key, 10) catch return error.JinjaTypeError;
                if (index >= values.len) return error.JinjaIndexError;
                result = values[index];
            }
            position = end + 1;
        } else return error.InvalidJinjaExpression;
        if (result == .undefined) return error.JinjaKeyError;
    }
    _ = a;
    return result;
}

pub fn render(a: std.mem.Allocator, format: []const u8, args: []const Argument) anyerror![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var numbering = Numbering{};
    var index: usize = 0;
    while (index < format.len) {
        const character = format[index];
        if ((character == '{' or character == '}') and index + 1 < format.len and format[index + 1] == character) {
            try out.append(a, character);
            index += 2;
        } else if (character == '{') {
            const end = std.mem.indexOfScalarPos(u8, format, index + 1, '}') orelse return error.InvalidJinjaExpression;
            const field = format[index + 1 .. end];
            const conversion_at = std.mem.indexOfScalar(u8, field, '!');
            const specification_at = std.mem.indexOfScalar(u8, field, ':');
            const name_end = @min(conversion_at orelse field.len, specification_at orelse field.len);
            const value = try fieldValue(a, field[0..name_end], args, &numbering);
            if (specification_at) |at| if (at + 1 != field.len) return error.UnsupportedJinjaFormat;
            const text = if (conversion_at) |at| blk: {
                if (at + 2 != (specification_at orelse field.len)) return error.InvalidJinjaExpression;
                break :blk switch (field[at + 1]) {
                    's' => try value.text(a),
                    'r' => try expression.repr(value, a),
                    'a' => try ascii(a, value),
                    else => return error.InvalidJinjaExpression,
                };
            } else try value.text(a);
            try out.appendSlice(a, text);
            index = end + 1;
        } else if (character == '}') return error.InvalidJinjaExpression else {
            try out.append(a, character);
            index += 1;
        }
    }
    return out.toOwnedSlice(a);
}

test "str.format keeps typed values, field paths, conversions and escaped braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try expression.evaluateArguments(a, "9007199254740993, 1.0, name='é'", null);
    try std.testing.expectEqualStrings("{9007199254740993} 1.0 'é' '\\xe9'", try render(a, "{{{0}}} {1} {name!r} {name!a}", args));
    try std.testing.expectError(error.InvalidJinjaArguments, render(a, "{} {0}", args));
    try std.testing.expectError(error.InvalidJinjaExpression, render(a, "{", args));
}
