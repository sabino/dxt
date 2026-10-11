const std = @import("std");

pub fn now(io: std.Io) i96 {
    return std.Io.Clock.real.now(io).nanoseconds;
}

pub fn writeTimestamp(writer: *std.Io.Writer, timestamp: ?i96) !void {
    const nanos = timestamp orelse return try writer.writeAll("null");
    const secs: u64 = @intCast(@max(0, @divFloor(nanos, std.time.ns_per_s)));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = epoch.getEpochDay().calculateYearDay();
    const month_day = day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    try writer.print("\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}Z\"", .{
        day.year,                                                                month_day.month.numeric(), month_day.day_index + 1,
        time.getHoursIntoDay(),                                                  time.getMinutesIntoHour(), time.getSecondsIntoMinute(),
        @as(u64, @intCast(@mod(nanos, std.time.ns_per_s))) / std.time.ns_per_us,
    });
}

test "execution timestamps use actual UTC-compatible ISO representation" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeTimestamp(&out.writer, 1709251200123456000);
    try std.testing.expectEqualStrings("\"2024-03-01T00:00:00.123456Z\"", out.written());
}
