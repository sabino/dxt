//! Complete authored-date subset of Core 1.10.5's dateutil deserializer.
//! Added date grammar requires a complete four-digit year 1000..9999; existing
//! calendar ISO years 0001..9999 remain supported. Clock grammar is HH, HHMM,
//! HHMMSS or HH:MM[:SS], with optional fractional seconds and Z/numeric offsets.
//! Partial dates, rolling years, weekdays, prose clocks and named zones are excluded.
const std = @import("std");
const iso = @import("datetime_parse.zig");

const Token = struct { text: []const u8, number: ?u16, month: ?u8 };
fn month(text: []const u8) ?u8 {
    const names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
    for (names, 1..) |name, index| {
        if (std.ascii.eqlIgnoreCase(text, name) or std.ascii.eqlIgnoreCase(text, name[0..3]) or (index == 9 and std.ascii.eqlIgnoreCase(text, "Sept"))) return @intCast(index);
    }
    return null;
}
fn delimiter(c: u8) bool {
    return c == ' ' or c == ',' or c == '-' or c == '/' or c == '.';
}
fn digits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

pub fn parse(a: std.mem.Allocator, authored: []const u8) !iso.Parsed {
    const text = std.mem.trim(u8, authored, " ");
    if (text.len < 8) return error.InvalidDatetime;
    var boundary: usize = 0;
    var calendar_iso = true;
    var year: u16 = 0;
    var mon: u16 = 0;
    var day: u16 = 0;
    // Preserve the existing basic and extended calendar ISO forms explicitly.
    if (digits(text[0..8])) {
        year = try std.fmt.parseInt(u16, text[0..4], 10);
        mon = try std.fmt.parseInt(u16, text[4..6], 10);
        day = try std.fmt.parseInt(u16, text[6..8], 10);
        boundary = 8;
    } else if (text.len >= 10 and digits(text[0..4]) and text[4] == '-' and digits(text[5..7]) and text[7] == '-' and digits(text[8..10])) {
        year = try std.fmt.parseInt(u16, text[0..4], 10);
        mon = try std.fmt.parseInt(u16, text[5..7], 10);
        day = try std.fmt.parseInt(u16, text[8..10], 10);
        boundary = 10;
    } else {
        calendar_iso = false;
        var tokens: [3]Token = undefined;
        var pos: usize = 0;
        for (&tokens, 0..) |*token, index| {
            const start = pos;
            while (pos < text.len and std.ascii.isAlphanumeric(text[pos])) : (pos += 1) {}
            if (pos == start) return error.InvalidDatetime;
            const part = text[start..pos];
            token.* = .{ .text = part, .number = if (digits(part)) std.fmt.parseInt(u16, part, 10) catch return error.InvalidDatetime else null, .month = month(part) };
            if (index < 2) {
                const sep = pos;
                while (pos < text.len and delimiter(text[pos])) : (pos += 1) {}
                if (pos == sep) return error.InvalidDatetime;
            }
        }
        boundary = pos;
        if (tokens[0].number != null and tokens[0].text.len == 4) {
            year = tokens[0].number.?;
            mon = tokens[1].month orelse tokens[1].number orelse return error.InvalidDatetime;
            day = tokens[2].number orelse return error.InvalidDatetime;
        } else if (tokens[2].number != null and tokens[2].text.len == 4) {
            year = tokens[2].number.?;
            if (tokens[0].month) |m| {
                mon = m;
                day = tokens[1].number orelse return error.InvalidDatetime;
            } else if (tokens[1].month) |m| {
                mon = m;
                day = tokens[0].number orelse return error.InvalidDatetime;
            } else {
                mon = tokens[0].number orelse return error.InvalidDatetime;
                day = tokens[1].number orelse return error.InvalidDatetime;
                // Core defaults month-first, but an impossible month is day-first.
                if (mon > 12) std.mem.swap(u16, &mon, &day);
            }
        } else return error.InvalidDatetime;
    }
    if (year == 0 or (!calendar_iso and year < 1000) or year > 9999 or mon > 12 or day > 31) return error.InvalidDatetime;
    const date = try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, mon, day });
    if (boundary == text.len) return iso.iso(a, date, true);
    if (text[boundary] != ' ' and text[boundary] != 'T' and text[boundary] != 't') return error.InvalidDatetime;
    const clock = std.mem.trim(u8, text[boundary + 1 ..], " ");
    if (clock.len == 0) return error.InvalidDatetime;
    for (clock) |c| if (!std.ascii.isDigit(c) and std.mem.indexOfScalar(u8, ":.,+-Zz", c) == null) return error.InvalidDatetime;
    if (std.mem.indexOfAny(u8, clock, "+-")) |at| {
        // dateutil rejects offset seconds/fractions; minutes may normalize above 59.
        const offset = clock[at + 1 ..];
        if (!(offset.len == 2 or offset.len == 4 or (offset.len == 5 and offset[2] == ':'))) return error.InvalidDatetime;
    }
    const time_end = std.mem.indexOfAny(u8, clock, "+-Zz") orelse clock.len;
    if (std.mem.indexOfAny(u8, clock[0..time_end], ".,")) |fraction| {
        // Only fractional seconds are part of this grammar. dateutil's fractional
        // hours/minutes have different semantics from datetime.fromisoformat.
        if (fraction != 6 and fraction != 8) return error.InvalidDatetime;
    }
    const normalized = try a.dupe(u8, clock);
    if (normalized[normalized.len - 1] == 'z') normalized[normalized.len - 1] = 'Z';
    return iso.iso(a, try std.fmt.allocPrint(a, "{s}T{s}", .{ date, normalized }), false);
}

test "deprecation date complete English and numeric grammar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const expected = (try iso.iso(a, "2099-01-02", true)).civil_ns;
    for ([_][]const u8{ "January 2, 2099", "2 JAN 2099", "2099-Jan-2", "Jan. 2 2099", "01/02/2099", "2099.01.02", "20990102", "2099-01-02" }) |text| try std.testing.expectEqual(expected, (try parse(a, text)).civil_ns);
    for ([_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" }, 1..) |name, number| {
        const canonical = try std.fmt.allocPrint(a, "2099-{d:0>2}-02", .{number});
        for ([_][]const u8{ name, name[0..3] }) |label| {
            const authored = try std.fmt.allocPrint(a, "{s} 2 2099", .{label});
            try std.testing.expectEqual((try iso.iso(a, canonical, true)).civil_ns, (try parse(a, authored)).civil_ns);
        }
    }
    try std.testing.expectEqual((try iso.iso(a, "2099-01-23", true)).civil_ns, (try parse(a, "23/1/2099")).civil_ns);
    for ([_][]const u8{ "September 2 2099", "Sept. 2 2099", "2 Sep 2099" }) |text| try std.testing.expectEqual((try iso.iso(a, "2099-09-02", true)).civil_ns, (try parse(a, text)).civil_ns);
}

test "deprecation date clocks precision and normalized offset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const actual = try parse(a, "2 January 2099 03:04:05.123456789+05:99");
    try std.testing.expectEqual(@as(i64, 23940 * std.time.us_per_s), actual.offset_us.?);
    try std.testing.expectEqual(@as(i96, 123456000), @mod(actual.civil_ns, std.time.ns_per_s));
    try std.testing.expectEqual(@as(?i64, null), (try parse(a, "January 2 2099")).offset_us);
}

test "deprecation date rejects incomplete unsupported and invalid values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "January 2099", "January 2", "01/02/99", "0001/01/02", "2099-W01-2", "2099-01-02🐍03:04", "2099-02-29", "Jan 32 2099", "Jan 2 2099 24:00", "Jan 2 2099 03:60", "Jan 2 2099 03:04:60", "Jan 2 2099 03:04+24:00", "Jan 2 2099 03:04+05:30:01", "Jan 2 2099 03:04+05:30.5", "Jan 2 2099 UTC", "Thursday Jan 2 2099", "Jan 2nd 2099", "Jan 2 2099 3h", "Jan 2 2099 03.5", "Jan 2 2099 03:04.5" }) |text| try std.testing.expectError(error.InvalidDatetime, parse(arena.allocator(), text));
}

test "deprecation date preserves low calendar ISO years" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "0001-01-02T03:04:05Z", "09990102T030405Z" }) |text| {
        const expected = try iso.iso(a, text, false);
        const actual = try parse(a, text);
        try std.testing.expectEqual(expected.civil_ns, actual.civil_ns);
        try std.testing.expectEqual(expected.offset_us, actual.offset_us);
    }
}
