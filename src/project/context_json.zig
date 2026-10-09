//! dbt's context tojson uses Python JSON defaults: ASCII escapes, spaces after
//! separators, insertion order and native integer/float identities.
const std = @import("std");
const expression = @import("expression.zig");

pub fn stringify(allocator: std.mem.Allocator, value: expression.Value) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try write(allocator, &output.writer, value);
    return try output.toOwnedSlice();
}

fn write(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: expression.Value) anyerror!void {
    switch (value) {
        .none => try writer.writeAll("null"),
        .boolean => |boolean| try writer.writeAll(if (boolean) "true" else "false"),
        .integer => |integer| try writer.writeAll(integer),
        .number => |number| {
            if (std.math.isNan(number)) try writer.writeAll("NaN") else if (std.math.isInf(number)) try writer.writeAll(if (number < 0) "-Infinity" else "Infinity") else try writer.writeAll(try value.text(allocator));
        },
        .string => |text| try std.json.Stringify.value(text, .{ .escape_unicode = true }, writer),
        .list, .tuple => |items| {
            try writer.writeByte('[');
            for (items, 0..) |item, index| {
                if (index != 0) try writer.writeAll(", ");
                try write(allocator, writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |entries| {
            if (value.attribute("__dxt_relation") != .undefined or value.attribute("__dxt_sequence_kind") != .undefined or value.attribute("__dxt_iterable") != .undefined) return error.JinjaTypeError;
            try writer.writeByte('{');
            for (entries, 0..) |entry, index| {
                if (index != 0) try writer.writeAll(", ");
                try std.json.Stringify.value(entry.key, .{ .escape_unicode = true }, writer);
                try writer.writeAll(": ");
                try write(allocator, writer, entry.value);
            }
            try writer.writeByte('}');
        },
        .undefined, .conditional_undefined, .complex, .callable => return error.JinjaTypeError,
    }
}
