//! dbt's context tojson uses Python JSON defaults: ASCII escapes, spaces after
//! separators, insertion order and native integer/float identities.
const std = @import("std");
const expression = @import("expression.zig");

pub fn stringify(allocator: std.mem.Allocator, value: expression.Value) ![]const u8 {
    return stringifySorted(allocator, value, false);
}

test "context JSON preserves typed key names and exact numeric sorting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const mixed = try expression.evaluate(allocator, "{none:'null',true:'boolean',2.0:'float'}", null);
    try std.testing.expectEqualStrings("{\"null\": \"null\", \"true\": \"boolean\", \"2.0\": \"float\"}", try stringify(allocator, mixed));
    try std.testing.expectError(error.JinjaTypeError, stringifySorted(allocator, mixed, true));
    const numeric = try expression.evaluate(allocator, "{10:'ten',2:'two'}", null);
    try std.testing.expectEqualStrings("{\"2\": \"two\", \"10\": \"ten\"}", try stringifySorted(allocator, numeric, true));
}

test "context JSON detects circular references and handles boxed NaN scalars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const items = try expression.allocateValues(allocator, 1);
    const cycle = expression.Value{ .list = items };
    items[0] = cycle;
    try std.testing.expectError(error.JinjaCircularReference, stringify(allocator, cycle));
    const number = try expression.floatValue(allocator, std.math.nan(f64));
    try std.testing.expectEqualStrings("NaN", try stringify(allocator, number));
}

test "context JSON rejects iterable sets without serializing native protocol fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const set = try @import("set_context.zig").fromMembers(allocator, &.{.{ .integer = "1" }});
    try std.testing.expectError(error.JinjaTypeError, stringify(allocator, set));
    try std.testing.expectError(error.JinjaTypeError, @import("expression_json.zig").render(allocator, set, null));
}

test "both JSON serializers expose opaque tuples as arrays and preserve authored maps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const items = [_]expression.Value{ .{ .integer = "2026" }, .{ .integer = "41" }, .{ .integer = "6" } };
    const tuple = expression.Value{ .object = &.{
        .{ .key = "__dxt_native_tuple", .value = .{ .callable = "__dxt_native_tuple" } },
        .{ .key = "__dxt_iterable", .value = .{ .list = &items } },
        .{ .key = "year", .value = items[0] },
    } };
    try std.testing.expectEqualStrings("[2026, 41, 6]", try stringifySorted(allocator, tuple, true));
    try std.testing.expectEqualStrings("[\n  2026,\n  41,\n  6\n]", try @import("expression_json.zig").render(allocator, tuple, "  "));
    const forged = expression.Value{ .object = &.{
        .{ .key = "__dxt_native_tuple", .value = .{ .string = "__dxt_native_tuple" } },
        .{ .key = "__dxt_iterable", .value = .{ .list = &items } },
    } };
    try std.testing.expectEqualStrings("{\"__dxt_native_tuple\": \"__dxt_native_tuple\", \"__dxt_iterable\": [2026, 41, 6]}", try stringify(allocator, forged));
    try std.testing.expectEqualStrings("{\"__dxt_iterable\": [2026, 41, 6], \"__dxt_native_tuple\": \"__dxt_native_tuple\"}", try @import("expression_json.zig").render(allocator, forged, null));
    const cycle_items = try expression.allocateValues(allocator, 1);
    const cycle = expression.Value{ .object = &.{
        .{ .key = "__dxt_native_tuple", .value = .{ .callable = "__dxt_native_tuple" } },
        .{ .key = "__dxt_iterable", .value = .{ .list = cycle_items } },
    } };
    cycle_items[0] = cycle;
    try std.testing.expectError(error.JinjaCircularReference, stringify(allocator, cycle));
}

pub fn stringifySorted(allocator: std.mem.Allocator, value: expression.Value, sort_keys: bool) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try write(allocator, &output.writer, value, sort_keys, &.{});
    return try output.toOwnedSlice();
}

fn write(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: expression.Value, sort_keys: bool, path: []const usize) anyerror!void {
    if (path.len > 128) return error.JinjaExpressionDepthExceeded;
    if (expression.integerProtocol(value)) |number| return writer.writeAll(number);
    if (expression.floatProtocol(value)) |number| {
        if (std.math.isNan(number)) return writer.writeAll("NaN");
        if (std.math.isInf(number)) return writer.writeAll(if (number < 0) "-Infinity" else "Infinity");
        return @import("native_repr.zig").float(allocator, writer, number);
    }
    const pointer: ?usize = switch (value) {
        .object => |entries| @intFromPtr(entries.ptr),
        .list, .tuple => |items| @intFromPtr(items.ptr),
        else => null,
    };
    const ancestry = if (pointer) |identity| blk: {
        for (path) |previous| if (previous == identity) return error.JinjaCircularReference;
        const extended = try allocator.alloc(usize, path.len + 1);
        @memcpy(extended[0..path.len], path);
        extended[path.len] = identity;
        break :blk extended;
    } else null;
    defer if (ancestry) |extended| allocator.free(extended);
    const next_path: []const usize = if (ancestry) |extended| extended else path;
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
                try write(allocator, writer, item, sort_keys, next_path);
            }
            try writer.writeByte(']');
        },
        .object => |entries| {
            if (@import("native_tuple.zig").items(value)) |items| {
                try writer.writeByte('[');
                for (items, 0..) |item, index| {
                    if (index != 0) try writer.writeAll(", ");
                    try write(allocator, writer, item, sort_keys, next_path);
                }
                try writer.writeByte(']');
                return;
            }
            if (value.attribute("__dxt_noniterable").truthy() or value.attribute("__dxt_relation") != .undefined or @import("expression_sequence.zig").kind(value) != null or @import("set_context.zig").isSet(value)) return error.JinjaTypeError;
            const sorted = if (sort_keys) try allocator.dupe(expression.Entry, entries) else null;
            defer if (sorted) |items| allocator.free(items);
            if (sorted) |items| try @import("mapping_keys.zig").sortJsonKeys(allocator, items);
            try writer.writeByte('{');
            const items: []const expression.Entry = if (sorted) |values| values else entries;
            for (items, 0..) |entry, index| {
                if (index != 0) try writer.writeAll(", ");
                try std.json.Stringify.value(try @import("mapping_keys.zig").jsonKey(allocator, expression.entryKey(entry)), .{ .escape_unicode = true }, writer);
                try writer.writeAll(": ");
                try write(allocator, writer, entry.value, sort_keys, next_path);
            }
            try writer.writeByte('}');
        },
        .missing, .undefined, .conditional_undefined, .ordinary_undefined, .capture_undefined, .complex, .callable => return error.JinjaTypeError,
    }
}
