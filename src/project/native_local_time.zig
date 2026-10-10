//! Host-local calendar conversion using the native C timezone database.
const std = @import("std");
const calendar = @import("workflow_intervals.zig");
const c = @cImport({
    @cInclude("time.h");
});

pub fn civil(allocator: std.mem.Allocator, utc_ns: i96) !i96 {
    var seconds: c.time_t = @intCast(@divFloor(utc_ns, std.time.ns_per_s));
    var local: c.struct_tm = undefined;
    c.tzset();
    if (c.localtime_r(&seconds, &local) == null) return error.InvalidDatetime;
    const year = @as(i64, local.tm_year) + 1900;
    if (year < 1 or year > 9999) return error.InvalidDatetime;
    const label = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(year)), @as(u64, @intCast(local.tm_mon + 1)), @as(u64, @intCast(local.tm_mday)) });
    return @as(i96, try calendar.parseTimestamp(label)) * std.time.ns_per_s + @as(i96, local.tm_hour) * std.time.ns_per_hour + @as(i96, local.tm_min) * std.time.ns_per_min + @as(i96, local.tm_sec) * std.time.ns_per_s + @mod(utc_ns, std.time.ns_per_s);
}

pub fn zoneName(allocator: std.mem.Allocator, utc_ns: i96) ![]const u8 {
    var seconds: c.time_t = @intCast(@divFloor(utc_ns, std.time.ns_per_s));
    var local: c.struct_tm = undefined;
    c.tzset();
    if (c.localtime_r(&seconds, &local) == null) return error.InvalidDatetime;
    var buffer: [128]u8 = undefined;
    const length = c.strftime(&buffer, buffer.len, "%Z", &local);
    return allocator.dupe(u8, buffer[0..length]);
}

fn candidate(civil_ns: i96, is_dst: c_int) !i96 {
    const seconds = @divFloor(civil_ns, std.time.ns_per_s);
    var utc: c.time_t = @intCast(seconds);
    var fields: c.struct_tm = undefined;
    if (c.gmtime_r(&utc, &fields) == null) return error.InvalidDatetime;
    fields.tm_isdst = is_dst;
    return @as(i96, c.mktime(&fields)) * std.time.ns_per_s + @mod(civil_ns, std.time.ns_per_s);
}

/// PEP 495: fold selects the later occurrence in an overlap and the earlier
/// synthetic timestamp in a gap. Fractional microseconds remain exact.
pub fn timestamp(allocator: std.mem.Allocator, civil_ns: i96, fold: u1) !i96 {
    c.tzset();
    const first = try candidate(civil_ns, 0);
    const second = try candidate(civil_ns, 1);
    const first_valid = (try civil(allocator, first)) == civil_ns;
    const second_valid = (try civil(allocator, second)) == civil_ns;
    if (first_valid and second_valid) return if (fold == 0) @min(first, second) else @max(first, second);
    if (first_valid) return first;
    if (second_valid) return second;
    return if (fold == 0) @max(first, second) else @min(first, second);
}

pub fn foldAt(allocator: std.mem.Allocator, utc_ns: i96) !u1 {
    const local = try civil(allocator, utc_ns);
    const first = try timestamp(allocator, local, 0);
    const second = try timestamp(allocator, local, 1);
    return if (first != second and second == utc_ns) 1 else 0;
}

test "native local civil and timestamp preserve fractional precision" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const instant: i96 = 1712345678123456000;
    const local = try civil(allocator, instant);
    try std.testing.expectEqual(@as(i96, 123456000), @mod(local, std.time.ns_per_s));
    try std.testing.expectEqual(instant, try timestamp(allocator, local, try foldAt(allocator, instant)));
}
