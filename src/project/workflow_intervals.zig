//! dxt interval accounting uses UTC half-open ranges. Reference: SQLMesh
//! b44fdf6 docs/guides/incremental_time.md; this is independent of dbt's
//! incremental materialization and snapshot resources.
const std = @import("std");

pub const Interval = struct { start: i64, end: i64 };
pub const Unit = enum { five_minute, quarter_hour, half_hour, hour, day, month, year };

pub fn parseTimestamp(text: []const u8) !i64 {
    if (text.len < 10 or text[4] != '-' or text[7] != '-') return error.InvalidWorkflowDate;
    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return error.InvalidWorkflowDate;
    const month = std.fmt.parseInt(i64, text[5..7], 10) catch return error.InvalidWorkflowDate;
    const day = std.fmt.parseInt(i64, text[8..10], 10) catch return error.InvalidWorkflowDate;
    if (year < 1 or month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) return error.InvalidWorkflowDate;
    const adjusted = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(adjusted, 400);
    const yoe = adjusted - era * 400;
    const shifted = month + @as(i64, if (month > 2) -3 else 9);
    const doy = @divFloor(153 * shifted + 2, 5) + day - 1;
    const days = era * 146097 + yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy - 719468;
    if (text.len == 10) return days * 86400;
    if ((text.len != 19 and text.len != 20) or (text[10] != 'T' and text[10] != ' ') or text[13] != ':' or text[16] != ':') return error.InvalidWorkflowDate;
    if (text.len == 20 and text[19] != 'Z') return error.InvalidWorkflowDate;
    const hour = std.fmt.parseInt(i64, text[11..13], 10) catch return error.InvalidWorkflowDate;
    const minute = std.fmt.parseInt(i64, text[14..16], 10) catch return error.InvalidWorkflowDate;
    const second = std.fmt.parseInt(i64, text[17..19], 10) catch return error.InvalidWorkflowDate;
    if (hour > 23 or minute > 59 or second > 59 or hour < 0 or minute < 0 or second < 0) return error.InvalidWorkflowDate;
    return days * 86400 + hour * 3600 + minute * 60 + second;
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        2 => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

pub fn formatTimestamp(allocator: std.mem.Allocator, value: i64) ![]const u8 {
    const days = @divFloor(value, 86400);
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    var year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = mp + @as(i64, if (mp < 10) 3 else -9);
    year += if (month <= 2) @as(i64, 1) else 0;
    const seconds = @mod(value, 86400);
    if (year < 0 or year > 9999) return error.InvalidWorkflowDate;
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(year)), @as(u64, @intCast(month)), @as(u64, @intCast(day)), @as(u64, @intCast(@divFloor(seconds, 3600))), @as(u64, @intCast(@divFloor(@mod(seconds, 3600), 60))), @as(u64, @intCast(@mod(seconds, 60))) });
}

pub fn parseUnit(unit: []const u8) !Unit {
    return std.meta.stringToEnum(Unit, unit) orelse error.InvalidWorkflowIntervalUnit;
}

fn fixedSeconds(unit: Unit) ?i64 {
    return switch (unit) {
        .five_minute => 300,
        .quarter_hour => 900,
        .half_hour => 1800,
        .hour => 3600,
        .day => 86400,
        .month, .year => null,
    };
}

fn calendarFloor(allocator: std.mem.Allocator, value: i64, unit: Unit, subtract: u32) !i64 {
    if (fixedSeconds(unit)) |seconds| return @divFloor(value, seconds) * seconds - seconds * subtract;
    const label = try formatTimestamp(allocator, value);
    defer allocator.free(label);
    const year = try std.fmt.parseInt(i64, label[0..4], 10);
    const month = try std.fmt.parseInt(i64, label[5..7], 10);
    const adjusted_year = if (unit == .year) year - subtract else @divFloor(year * 12 + month - 1 - subtract, 12);
    const adjusted_month = if (unit == .year) @as(i64, 1) else @mod(year * 12 + month - 1 - subtract, 12) + 1;
    // The same proleptic Gregorian conversion as parseTimestamp permits
    // lookback before the requested lower bound; missing() clamps that bound.
    const adjusted = adjusted_year - @as(i64, if (adjusted_month <= 2) 1 else 0);
    const era = @divFloor(adjusted, 400);
    const yoe = adjusted - era * 400;
    const shifted = adjusted_month + @as(i64, if (adjusted_month > 2) -3 else 9);
    const doy = @divFloor(153 * shifted + 2, 5);
    return (era * 146097 + yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy - 719468) * 86400;
}

pub fn normalize(allocator: std.mem.Allocator, input: []const Interval) ![]Interval {
    const sorted = try allocator.dupe(Interval, input);
    defer allocator.free(sorted);
    for (sorted) |interval| if (interval.start >= interval.end) return error.InvalidWorkflowInterval;
    std.mem.sort(Interval, sorted, {}, struct {
        fn less(_: void, lhs: Interval, rhs: Interval) bool {
            return lhs.start < rhs.start;
        }
    }.less);
    var result: std.ArrayList(Interval) = .empty;
    errdefer result.deinit(allocator);
    for (sorted) |interval| {
        if (result.items.len != 0 and interval.start <= result.items[result.items.len - 1].end) {
            result.items[result.items.len - 1].end = @max(result.items[result.items.len - 1].end, interval.end);
        } else try result.append(allocator, interval);
    }
    return result.toOwnedSlice(allocator);
}

pub fn missing(allocator: std.mem.Allocator, requested: Interval, processed: []const Interval, unit: Unit, lookback: u32, restate: bool) ![]Interval {
    if (requested.start >= requested.end) return error.InvalidWorkflowInterval;
    const start = try calendarFloor(allocator, requested.start, unit, 0);
    const end = try calendarFloor(allocator, requested.end, unit, 0);
    if (start >= end) return allocator.alloc(Interval, 0);
    if (restate) return allocator.dupe(Interval, &.{.{ .start = start, .end = end }});
    const covered = try normalize(allocator, processed);
    defer allocator.free(covered);
    var output: std.ArrayList(Interval) = .empty;
    errdefer output.deinit(allocator);
    var cursor = start;
    for (covered) |interval| {
        if (interval.end <= cursor) continue;
        if (interval.start >= end) break;
        if (interval.start > cursor) try output.append(allocator, .{ .start = cursor, .end = @min(interval.start, end) });
        cursor = @max(cursor, interval.end);
    }
    if (cursor < end) try output.append(allocator, .{ .start = cursor, .end = end });
    if (lookback != 0 and covered.len != 0) try output.append(allocator, .{ .start = @max(start, try calendarFloor(allocator, end, unit, lookback)), .end = end });
    const result = try normalize(allocator, output.items);
    output.deinit(allocator);
    return result;
}

test "workflow UTC ranges reject invalid dates and preserve half-open gaps" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(i64, 0), try parseTimestamp("1970-01-01"));
    try std.testing.expectError(error.InvalidWorkflowDate, parseTimestamp("2025-02-29"));
    try std.testing.expectEqual(@as(i64, 86400), try parseTimestamp("1970-01-02T00:00:00Z"));
    const label = try formatTimestamp(a, -1);
    defer a.free(label);
    try std.testing.expectEqualStrings("1969-12-31 23:59:59", label);
    const gaps = try missing(a, .{ .start = 0, .end = 5 * 86400 }, &.{ .{ .start = 86400, .end = 2 * 86400 }, .{ .start = 3 * 86400, .end = 4 * 86400 } }, .day, 0, false);
    defer a.free(gaps);
    try std.testing.expectEqualDeep(&[_]Interval{ .{ .start = 0, .end = 86400 }, .{ .start = 2 * 86400, .end = 3 * 86400 }, .{ .start = 4 * 86400, .end = 5 * 86400 } }, gaps);
    const late = try missing(a, .{ .start = 0, .end = 5 * 86400 }, &.{.{ .start = 0, .end = 5 * 86400 }}, .day, 2, false);
    defer a.free(late);
    try std.testing.expectEqualDeep(&[_]Interval{.{ .start = 3 * 86400, .end = 5 * 86400 }}, late);
}

test "calendar interval floors respect leap years and variable month lengths" {
    const a = std.testing.allocator;
    const end = try parseTimestamp("2024-03-15");
    const start = try parseTimestamp("2024-01-01");
    const ranges = try missing(a, .{ .start = start, .end = end }, &.{.{ .start = start, .end = try parseTimestamp("2024-03-01") }}, .month, 1, false);
    defer a.free(ranges);
    try std.testing.expectEqualDeep(&[_]Interval{.{ .start = try parseTimestamp("2024-02-01"), .end = try parseTimestamp("2024-03-01") }}, ranges);
    try std.testing.expectEqual(try parseTimestamp("2023-01-01"), try calendarFloor(a, end, .year, 1));
}
