//! Civil calendar methods and native named tuple results.
const std = @import("std");
const expr = @import("expression.zig");
const calendar = @import("workflow_intervals.zig");
const Allocator = std.mem.Allocator;
const Value = expr.Value;

pub fn namedTuple(a: Allocator, items: []const Value, names: []const []const u8, rendered: []const u8) !Value {
    const entries = try expr.allocateEntries(a, items.len + 3);
    for (items, names, entries[0..items.len]) |item, name, *entry| entry.* = .{ .key = name, .value = item };
    entries[items.len] = .{ .key = "__dxt_native_tuple", .value = .{ .callable = "__dxt_native_tuple" } };
    entries[items.len + 1] = .{ .key = "__dxt_iterable", .value = .{ .list = items } };
    entries[items.len + 2] = .{ .key = "__dxt_rendered", .value = .{ .string = rendered } };
    return .{ .object = entries };
}
pub fn isoCalendar(a: Allocator, civil_ns: i96) !Value {
    const days: i64 = @intCast(@divFloor(civil_ns, std.time.ns_per_day));
    const weekday = @mod(days + 3, 7) + 1;
    const thursday = days + 4 - weekday;
    const label = try calendar.formatTimestamp(a, thursday * std.time.s_per_day);
    const year = try std.fmt.parseInt(i64, label[0..4], 10);
    const january4label = try std.fmt.allocPrint(a, "{d:0>4}-01-04", .{@as(u64, @intCast(year))});
    const january4 = @divFloor(try calendar.parseTimestamp(january4label), std.time.s_per_day);
    const week = @divFloor(thursday - (january4 - @mod(january4 + 3, 7)), 7) + 1;
    const items = try expr.allocateValues(a, 3);
    for ([_]i64{ year, week, weekday }, items) |number, *item| item.* = try expr.integerValue(a, number);
    return namedTuple(a, items, &.{ "year", "week", "weekday" }, try std.fmt.allocPrint(a, "datetime.IsoCalendarDate(year={d}, week={d}, weekday={d})", .{ year, week, weekday }));
}
pub fn timeTuple(a: Allocator, civil_ns: i96, dst: i64) !Value {
    const label = try calendar.formatTimestamp(a, @intCast(@divFloor(civil_ns, std.time.ns_per_s)));
    const year = try std.fmt.parseInt(i64, label[0..4], 10);
    const january1 = try calendar.parseTimestamp(try std.fmt.allocPrint(a, "{d:0>4}-01-01", .{@as(u64, @intCast(year))}));
    const day = @divFloor(civil_ns, std.time.ns_per_day);
    const values = [_]i64{ year, try std.fmt.parseInt(i64, label[5..7], 10), try std.fmt.parseInt(i64, label[8..10], 10), try std.fmt.parseInt(i64, label[11..13], 10), try std.fmt.parseInt(i64, label[14..16], 10), try std.fmt.parseInt(i64, label[17..19], 10), @intCast(@mod(day + 3, 7)), @intCast(day - @divFloor(january1, std.time.s_per_day) + 1), dst };
    const names = [_][]const u8{ "tm_year", "tm_mon", "tm_mday", "tm_hour", "tm_min", "tm_sec", "tm_wday", "tm_yday", "tm_isdst" };
    const items = try expr.allocateValues(a, values.len);
    var text: std.Io.Writer.Allocating = .init(a);
    try text.writer.writeAll("time.struct_time(");
    for (values, items, names, 0..) |number, *item, name, i| {
        item.* = try expr.integerValue(a, number);
        try text.writer.print("{s}{s}={d}", .{ if (i == 0) @as([]const u8, "") else ", ", name, number });
    }
    try text.writer.writeByte(')');
    const original = try namedTuple(a, items, &names, try text.toOwnedSlice());
    const entries = try expr.allocateEntries(a, original.object.len + 5);
    @memcpy(entries[0..original.object.len], original.object);
    entries[original.object.len] = .{ .key = "tm_zone", .value = .none };
    entries[original.object.len + 1] = .{ .key = "tm_gmtoff", .value = .none };
    entries[original.object.len + 2] = .{ .key = "n_fields", .value = try expr.integerValue(a, 11) };
    entries[original.object.len + 3] = .{ .key = "n_sequence_fields", .value = try expr.integerValue(a, 9) };
    entries[original.object.len + 4] = .{ .key = "n_unnamed_fields", .value = try expr.integerValue(a, 0) };
    return .{ .object = entries };
}
pub fn ctime(a: Allocator, civil_ns: i96) ![]const u8 {
    const label = try calendar.formatTimestamp(a, @intCast(@divFloor(civil_ns, std.time.ns_per_s)));
    const weekdays = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const weekday: usize = @intCast(@mod(@divFloor(civil_ns, std.time.ns_per_day) + 3, 7));
    const month = try std.fmt.parseInt(usize, label[5..7], 10);
    const day = try std.fmt.parseInt(u32, label[8..10], 10);
    return std.fmt.allocPrint(a, "{s} {s} {d: >2} {s} {s}", .{ weekdays[weekday], months[month - 1], day, label[11..19], label[0..4] });
}

test "native calendar result has tuple identity equality and immutable tuple operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ns = @as(i96, try calendar.parseTimestamp("2021-01-01")) * std.time.ns_per_s;
    const value = try isoCalendar(a, ns);
    try std.testing.expectEqualStrings("datetime.IsoCalendarDate(year=2020, week=53, weekday=5)", try value.text(a));
    try std.testing.expect(expr.equalValues(value, .{ .tuple = &.{ .{ .integer = "2020" }, .{ .integer = "53" }, .{ .integer = "5" } } }));
    try std.testing.expectEqualStrings("2020", (try expr.indexValue(a, value, .{ .integer = "0" })).integer);
    try std.testing.expectEqualStrings("53", (try expr.indexValue(a, value, .{ .string = "week" })).integer);
    try std.testing.expect((try expr.indexValue(a, value, .{ .string = "__dxt_native_tuple" })) == .undefined);
    try std.testing.expectEqualStrings("Fri Jan  1 00:00:00 2021", try ctime(a, ns));
    try std.testing.expectEqualStrings("time.struct_time(tm_year=2021, tm_mon=1, tm_mday=1, tm_hour=0, tm_min=0, tm_sec=0, tm_wday=4, tm_yday=1, tm_isdst=-1)", try (try timeTuple(a, ns, -1)).text(a));
}
