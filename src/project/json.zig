const std = @import("std");
const Io = std.Io;

pub fn string(writer: *Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

pub fn nullableString(writer: *Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try string(writer, text);
    } else {
        try writer.writeAll("null");
    }
}

pub fn boolValue(writer: *Io.Writer, value: bool) !void {
    try writer.writeAll(if (value) "true" else "false");
}

pub fn stringArray(writer: *Io.Writer, values: []const []const u8) !void {
    try writer.writeAll("[");
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(",");
        try string(writer, value);
    }
    try writer.writeAll("]");
}

pub fn stringField(writer: *Io.Writer, key: []const u8, value: []const u8, wrote: *bool) !void {
    if (wrote.*) try writer.writeAll(",");
    wrote.* = true;
    try string(writer, key);
    try writer.writeAll(":");
    try string(writer, value);
}

pub fn stringArrayField(writer: *Io.Writer, key: []const u8, values: []const []const u8, wrote: *bool) !void {
    if (wrote.*) try writer.writeAll(",");
    wrote.* = true;
    try string(writer, key);
    try writer.writeAll(":");
    try stringArray(writer, values);
}

fn renderStringForTest(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try string(&out.writer, value);
    return try out.toOwnedSlice();
}

test "string delegates escaping to std json stringify" {
    const rendered = try renderStringForTest(std.testing.allocator, "quote\" slash\\ line\n tab\t");
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\"quote\\\" slash\\\\ line\\n tab\\t\"", rendered);
}

test "nullableString renders strings and nulls" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try nullableString(&out.writer, "value");
    try out.writer.writeAll(",");
    try nullableString(&out.writer, null);

    try std.testing.expectEqualStrings("\"value\",null", out.written());
}

test "stringArray renders valid ordered arrays" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try stringArray(&out.writer, &.{ "customers", "orders \"quoted\"" });

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    const items = parsed.value.array.items;
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("customers", items[0].string);
    try std.testing.expectEqualStrings("orders \"quoted\"", items[1].string);
}

test "stringField preserves compact object field formatting" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var wrote = false;

    try out.writer.writeAll("{");
    try stringField(&out.writer, "name", "customers", &wrote);
    try stringField(&out.writer, "path", "models/customers.sql", &wrote);
    try out.writer.writeAll("}");

    try std.testing.expectEqualStrings("{\"name\":\"customers\",\"path\":\"models/customers.sql\"}", out.written());
}

test "stringArrayField preserves compact object field formatting" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var wrote = false;

    try out.writer.writeAll("{");
    try stringField(&out.writer, "name", "orders", &wrote);
    try stringArrayField(&out.writer, "config.tags", &.{ "finance", "nightly" }, &wrote);
    try out.writer.writeAll("}");

    try std.testing.expectEqualStrings("{\"name\":\"orders\",\"config.tags\":[\"finance\",\"nightly\"]}", out.written());
}
