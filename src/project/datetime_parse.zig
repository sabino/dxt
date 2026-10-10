//! Native ISO calendar and time parsing for Python's restricted datetime API.
const std = @import("std");
const calendar = @import("workflow_intervals.zig");
const Allocator = std.mem.Allocator;
pub const Parsed = struct { civil_ns: i96, offset_us: ?i64 = null };
const Date = struct { days: i64, consumed: usize };
fn decimal(text: []const u8) !i64 {
    if (text.len == 0) return error.InvalidDatetime;
    for (text) |c| if (!std.ascii.isDigit(c)) return error.InvalidDatetime;
    return std.fmt.parseInt(i64, text, 10) catch error.InvalidDatetime;
}
fn day(a: Allocator, year: i64, month: i64, date: i64) !i64 {
    if (year < 1 or year > 9999) return error.InvalidDatetime;
    const label = try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(year)), @as(u64, @intCast(month)), @as(u64, @intCast(date)) });
    return @divFloor(calendar.parseTimestamp(label) catch return error.InvalidDatetime, std.time.s_per_day);
}
pub fn isoCalendar(a: Allocator, year: i64, week: i64, weekday: i64) !i96 {
    if (year < 1 or year > 9999 or week < 1 or week > 53 or weekday < 1 or weekday > 7) return error.InvalidDatetime;
    const january4 = try day(a, year, 1, 4);
    const monday = january4 - @mod(january4 + 3, 7);
    const target = monday + (week - 1) * 7 + weekday - 1;
    const thursday = monday + (week - 1) * 7 + 3;
    const label = calendar.formatTimestamp(a, thursday * std.time.s_per_day) catch return error.InvalidDatetime;
    if (try decimal(label[0..4]) != year) return error.InvalidDatetime;
    return @as(i96, target) * std.time.ns_per_day;
}
fn parseDate(a: Allocator, text: []const u8) !Date {
    if (text.len < 7) return error.InvalidDatetime;
    const year = try decimal(text[0..4]);
    const extended = text[4] == '-';
    const at: usize = if (extended) 5 else 4;
    if (text[at] == 'W') {
        if (text.len < at + 3) return error.InvalidDatetime;
        const week = try decimal(text[at + 1 .. at + 3]);
        var consumed = at + 3;
        var weekday: i64 = 1;
        if (text.len > consumed and ((extended and text[consumed] == '-') or (!extended and std.ascii.isDigit(text[consumed])))) {
            if (extended) consumed += 1;
            if (text.len <= consumed) return error.InvalidDatetime;
            weekday = try decimal(text[consumed .. consumed + 1]);
            consumed += 1;
        }
        return .{ .days = @intCast(@divFloor(try isoCalendar(a, year, week, weekday), std.time.ns_per_day)), .consumed = consumed };
    }
    const length: usize = if (extended) 10 else 8;
    if (text.len < length or (extended and text[7] != '-')) return error.InvalidDatetime;
    const month = try decimal(text[at .. at + 2]);
    const start: usize = if (extended) 8 else 6;
    return .{ .days = try day(a, year, month, try decimal(text[start .. start + 2])), .consumed = length };
}
fn fractional(text: []const u8) !i64 {
    if (text.len == 0) return error.InvalidDatetime;
    var result: i64 = 0;
    for (text, 0..) |character, i| {
        if (!std.ascii.isDigit(character)) return error.InvalidDatetime;
        if (i < 6) result = result * 10 + character - '0';
    }
    for (0..6 - @min(text.len, 6)) |_| result *= 10;
    return result;
}
fn clock(text: []const u8, zone: bool) !i64 {
    var body = text;
    var micros: i64 = 0;
    if (std.mem.indexOfAny(u8, body, ".,")) |index| {
        micros = try fractional(body[index + 1 ..]);
        body = body[0..index];
    }
    var hour: i64 = 0;
    var minute: i64 = 0;
    var second: i64 = 0;
    if (std.mem.indexOfScalar(u8, body, ':') != null) {
        if (body.len != 5 and body.len != 8) return error.InvalidDatetime;
        if (body[2] != ':' or (body.len == 8 and body[5] != ':')) return error.InvalidDatetime;
        hour = try decimal(body[0..2]);
        minute = try decimal(body[3..5]);
        if (body.len == 8) second = try decimal(body[6..8]);
    } else {
        if (body.len != 2 and body.len != 4 and body.len != 6) return error.InvalidDatetime;
        hour = try decimal(body[0..2]);
        if (body.len >= 4) minute = try decimal(body[2..4]);
        if (body.len >= 6) second = try decimal(body[4..6]);
    }
    const total = hour * std.time.us_per_hour + minute * std.time.us_per_min + second * std.time.us_per_s + micros;
    if (zone) {
        if (total >= std.time.us_per_day) return error.InvalidDatetime;
    } else if (hour > 23 or minute > 59 or second > 59) return error.InvalidDatetime;
    return total;
}
pub fn time(text: []const u8) !Parsed {
    return parseTime(text, true);
}
fn parseTime(text_: []const u8, allow_prefix: bool) !Parsed {
    const text = if (allow_prefix and std.mem.startsWith(u8, text_, "T")) text_[1..] else text_;
    if (text.len < 2) return error.InvalidDatetime;
    var offset: ?i64 = null;
    var body = text;
    if (std.mem.indexOfAny(u8, text, "+-Z")) |at| {
        body = text[0..at];
        if (text[at] == 'Z') {
            if (at + 1 != text.len) return error.InvalidDatetime;
            offset = 0;
        } else {
            offset = (try clock(text[at + 1 ..], true)) * @as(i64, if (text[at] == '-') -1 else 1);
            // CPython treats a fractional zero-hour offset as UTC.
            if (@abs(offset.?) < std.time.us_per_s) offset = 0;
        }
    }
    return .{ .civil_ns = @as(i96, try clock(body, false)) * std.time.ns_per_us, .offset_us = offset };
}
pub fn iso(a: Allocator, text: []const u8, date_only: bool) !Parsed {
    const boundary = if (date_only) text.len else try datetimeBoundary(text);
    if (boundary > text.len) return error.InvalidDatetime;
    const date = try parseDate(a, text[0..boundary]);
    if (date.consumed != boundary) return error.InvalidDatetime;
    if (date.consumed == text.len) return .{ .civil_ns = @as(i96, date.days) * std.time.ns_per_day };
    if (date_only) return error.InvalidDatetime;
    const separator = std.unicode.utf8ByteSequenceLength(text[date.consumed]) catch return error.InvalidDatetime;
    if (date.consumed + separator >= text.len) return error.InvalidDatetime;
    _ = std.unicode.utf8Decode(text[date.consumed .. date.consumed + separator]) catch return error.InvalidDatetime;
    var result = try parseTime(text[date.consumed + separator ..], false);
    result.civil_ns += @as(i96, date.days) * std.time.ns_per_day;
    return result;
}

// CPython resolves ambiguous week-date separators before parsing the date.
// A numeric separator must not be mistaken for a weekday or a clock digit.
fn datetimeBoundary(text: []const u8) !usize {
    if (text.len < 7) return error.InvalidDatetime;
    if (text.len == 7) return 7;
    if (text[4] == '-') {
        if (text[5] != 'W') return 10;
        if (text.len > 8 and text[8] == '-') {
            if (text.len == 9) return error.InvalidDatetime;
            return if (text.len > 10 and std.ascii.isDigit(text[10])) 8 else 10;
        }
        return 8;
    }
    if (text[4] != 'W') return 8;
    var at: usize = 7;
    while (at < text.len and std.ascii.isDigit(text[at])) : (at += 1) {}
    if (at < 9) return at;
    return if (at % 2 == 0) 7 else 8;
}

test "native ISO parser preserves basic week dates and exact subminute offsets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual((try iso(a, "2024-01-01", true)).civil_ns, (try iso(a, "2024W011", true)).civil_ns);
    const value = try iso(a, "20240229🐍120405,123456789+05:30:45.678901", false);
    try std.testing.expectEqual(@as(i64, 19845678901), value.offset_us.?);
    try std.testing.expectEqual(@as(i96, 123456000), @mod(value.civil_ns, std.time.ns_per_s));
    try std.testing.expectError(error.InvalidDatetime, iso(a, "2023-W53-1", true));
    try std.testing.expectError(error.InvalidDatetime, iso(a, "2023-02-29", true));
    try std.testing.expectError(error.InvalidDatetime, iso(a, "2024-01-01TT12", false));
    for ([_][]const u8{ "2024-W01-12:30", "2024W01112:30", "2024W01012:30" }) |text| try std.testing.expectEqual((try iso(a, "2024-01-01T12:30", false)).civil_ns, (try iso(a, text, false)).civil_ns);
    try std.testing.expectError(error.InvalidDatetime, iso(a, "2024-W01-", false));
    try std.testing.expectError(error.InvalidDatetime, iso(a, "2024W010", true));
}
