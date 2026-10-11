//! Native datetime.strptime semantics, checked against CPython 3.12 _strptime.
//! Locale data comes from libc; parsing uses the existing Unicode PCRE2 engine.
const std = @import("std");
const calendar = @import("workflow_intervals.zig");
const regex = @import("regex_engine.zig");
const unicode = @import("expression_unicode.zig");
const c = @cImport({
    @cInclude("time.h");
    @cInclude("langinfo.h");
});
const Allocator = std.mem.Allocator;
pub const Parsed = struct { civil_ns: i96, offset_us: ?i64 = null, zone_name: ?[]const u8 = null };

const Locale = struct {
    weekdays: [2][7][]const u8,
    months: [2][12][]const u8,
    am_pm: [2][]const u8,
    zones: []const []const u8,
    composites: [3][]const u8,

    fn init(a: Allocator) !Locale {
        c.tzset();
        var result: Locale = undefined;
        var fields: c.struct_tm = std.mem.zeroes(c.struct_tm);
        fields.tm_year = 99;
        fields.tm_mday = 17;
        for (0..7) |i| {
            fields.tm_wday = @intCast((i + 1) % 7);
            result.weekdays[0][i] = try format(a, "%a", &fields);
            result.weekdays[1][i] = try format(a, "%A", &fields);
        }
        for (0..12) |i| {
            fields.tm_mon = @intCast(i);
            result.months[0][i] = try format(a, "%b", &fields);
            result.months[1][i] = try format(a, "%B", &fields);
        }
        for ([_]c_int{ 1, 22 }, 0..) |hour, i| {
            fields.tm_hour = hour;
            result.am_pm[i] = try a.dupe(u8, std.mem.trim(u8, try format(a, "%p", &fields), " \t\r\n"));
        }
        var zones: std.ArrayList([]const u8) = .empty;
        try zones.appendSlice(a, &.{ "UTC", "GMT" });
        if (c.tzname[0] != null) try zones.append(a, try a.dupe(u8, std.mem.span(c.tzname[0])));
        if (c.daylight != 0 and c.tzname[1] != null) try zones.append(a, try a.dupe(u8, std.mem.span(c.tzname[1])));
        result.zones = try zones.toOwnedSlice(a);
        result.composites = .{
            try a.dupe(u8, std.mem.span(c.nl_langinfo(c.D_T_FMT))),
            try a.dupe(u8, std.mem.span(c.nl_langinfo(c.D_FMT))),
            try a.dupe(u8, std.mem.span(c.nl_langinfo(c.T_FMT))),
        };
        return result;
    }
    fn format(a: Allocator, fmt: [*:0]const u8, fields: *const c.struct_tm) ![]const u8 {
        var buffer: [4096]u8 = undefined;
        const length = c.strftime(&buffer, buffer.len, fmt, fields);
        return a.dupe(u8, buffer[0..length]);
    }
};

fn escaped(w: *std.Io.Writer, bytes: []const u8) !void {
    for (bytes) |byte| {
        if (std.mem.indexOfScalar(u8, "\\.^$*+?(){}[]|", byte) != null) try w.writeByte('\\');
        try w.writeByte(byte);
    }
}

const Pattern = struct {
    allocator: Allocator,
    locale: *const Locale,
    out: std.Io.Writer.Allocating,
    seen: [256]bool = @splat(false),

    fn group(self: *Pattern, name: u8, content: []const u8) !void {
        if (self.seen[name]) return error.InvalidDatetimeFormat;
        self.seen[name] = true;
        try self.out.writer.print("(?P<{c}>{s})", .{ name, content });
    }
    fn names(self: *Pattern, name: u8, values: []const []const u8) !void {
        var nonempty = false;
        for (values) |value| if (value.len != 0) {
            nonempty = true;
        };
        if (!nonempty) return;
        if (self.seen[name]) return error.InvalidDatetimeFormat;
        self.seen[name] = true;
        const sorted = try self.allocator.dupe([]const u8, values);
        std.mem.sort([]const u8, sorted, {}, struct {
            fn less(_: void, left: []const u8, right: []const u8) bool {
                return left.len > right.len;
            }
        }.less);
        try self.out.writer.print("(?P<{c}>", .{name});
        for (sorted, 0..) |value, i| {
            if (i != 0) try self.out.writer.writeByte('|');
            try escaped(&self.out.writer, value);
        }
        try self.out.writer.writeByte(')');
    }
    fn append(self: *Pattern, fmt: []const u8, composite: bool, depth: u8) anyerror!void {
        if (depth > 8) return error.InvalidDatetimeFormat;
        var i: usize = 0;
        while (i < fmt.len) {
            const length = std.unicode.utf8ByteSequenceLength(fmt[i]) catch return error.InvalidDatetimeFormat;
            if (length > fmt.len - i) return error.InvalidDatetimeFormat;
            const code = std.unicode.utf8Decode(fmt[i..][0..length]) catch return error.InvalidDatetimeFormat;
            if (unicode.whitespace(code)) {
                try self.out.writer.writeAll("\\s+");
                i += length;
                while (i < fmt.len) {
                    const size = std.unicode.utf8ByteSequenceLength(fmt[i]) catch return error.InvalidDatetimeFormat;
                    if (size > fmt.len - i) return error.InvalidDatetimeFormat;
                    const next = std.unicode.utf8Decode(fmt[i..][0..size]) catch return error.InvalidDatetimeFormat;
                    if (!unicode.whitespace(next)) break;
                    i += size;
                }
                continue;
            }
            if (code != '%') {
                if (code == '\'') try self.out.writer.writeAll("['ʼ]") else try escaped(&self.out.writer, fmt[i..][0..length]);
                i += length;
                continue;
            }
            i += 1;
            if (i == fmt.len) return error.InvalidDatetimeFormat;
            var directive = fmt[i];
            i += 1;
            if (directive == 'O') {
                if (i == fmt.len) return error.InvalidDatetimeFormat;
                directive = fmt[i];
                i += 1;
                if (std.mem.indexOfScalar(u8, "dmyHIMS", directive) != null) try self.group(directive, "\\d\\d|\\d| \\d") else if (directive == 'w') try self.group('w', "\\d") else return error.InvalidDatetimeFormat;
                continue;
            }
            if (composite) switch (directive) {
                'e' => directive = 'd',
                'n', 't' => {
                    try self.out.writer.writeAll("\\s+");
                    continue;
                },
                'D' => {
                    try self.append("%m/%d/%y", true, depth + 1);
                    continue;
                },
                'F' => {
                    try self.append("%Y-%m-%d", true, depth + 1);
                    continue;
                },
                'R' => {
                    try self.append("%H:%M", true, depth + 1);
                    continue;
                },
                'T' => {
                    try self.append("%H:%M:%S", true, depth + 1);
                    continue;
                },
                'r' => {
                    try self.append(std.mem.span(c.nl_langinfo(c.T_FMT_AMPM)), true, depth + 1);
                    continue;
                },
                else => {},
            };
            switch (directive) {
                '%' => try self.out.writer.writeByte('%'),
                'd' => try self.group('d', "3[0-1]|[1-2]\\d|0[1-9]|[1-9]| [1-9]"),
                'f' => try self.group('f', "[0-9]{1,6}"),
                'H' => try self.group('H', "2[0-3]|[0-1]\\d|\\d"),
                'I' => try self.group('I', "1[0-2]|0[1-9]|[1-9]| [1-9]"),
                'G', 'Y' => try self.group(directive, "\\d{4}"),
                'j' => try self.group('j', "36[0-6]|3[0-5]\\d|[1-2]\\d\\d|0[1-9]\\d|00[1-9]|[1-9]\\d|0[1-9]|[1-9]"),
                'm' => try self.group('m', "1[0-2]|0[1-9]|[1-9]"),
                'M' => try self.group('M', "[0-5]\\d|\\d"),
                'S' => try self.group('S', "6[0-1]|[0-5]\\d|\\d"),
                'U', 'W' => try self.group(directive, "5[0-3]|[0-4]\\d|\\d"),
                'w' => try self.group('w', "[0-6]"),
                'u' => try self.group('u', "[1-7]"),
                'V' => try self.group('V', "5[0-3]|0[1-9]|[1-4]\\d|\\d"),
                'y' => try self.group('y', "\\d{2}"),
                'z' => try self.group('z', "[+-]\\d\\d:?[0-5]\\d(:?[0-5]\\d(\\.\\d{1,6})?)?|(?-i:Z)"),
                'A', 'a' => try self.names(directive, &self.locale.weekdays[if (directive == 'a') 0 else 1]),
                'B', 'b' => try self.names(directive, &self.locale.months[if (directive == 'b') 0 else 1]),
                'p' => try self.names('p', &self.locale.am_pm),
                'Z' => try self.names('Z', self.locale.zones),
                'c', 'x', 'X' => try self.append(self.locale.composites[if (directive == 'c') 0 else if (directive == 'x') 1 else 2], true, depth + 1),
                else => return error.InvalidDatetimeFormat,
            }
        }
    }
};

// Unicode 15.0.0 Decimal_Number starts, derived from unicodedata's Nd table.
// Each range has ten digits; the existing vendor/unicode/LICENSE applies.
const digit_zeroes = [_]u21{ 0x30, 0x660, 0x6f0, 0x7c0, 0x966, 0x9e6, 0xa66, 0xae6, 0xb66, 0xbe6, 0xc66, 0xce6, 0xd66, 0xde6, 0xe50, 0xed0, 0xf20, 0x1040, 0x1090, 0x17e0, 0x1810, 0x1946, 0x19d0, 0x1a80, 0x1a90, 0x1b50, 0x1bb0, 0x1c40, 0x1c50, 0xa620, 0xa8d0, 0xa900, 0xa9d0, 0xa9f0, 0xaa50, 0xabf0, 0xff10, 0x104a0, 0x10d30, 0x11066, 0x110f0, 0x11136, 0x111d0, 0x112f0, 0x11450, 0x114d0, 0x11650, 0x116c0, 0x11730, 0x118e0, 0x11950, 0x11c50, 0x11d50, 0x11da0, 0x11f50, 0x16a60, 0x16ac0, 0x16b50, 0x1d7ce, 0x1d7d8, 0x1d7e2, 0x1d7ec, 0x1d7f6, 0x1e140, 0x1e2f0, 0x1e4f0, 0x1e950, 0x1fbf0 };
fn decimal(code: u21) ?u8 {
    for (digit_zeroes) |zero| if (code >= zero and code < zero + 10) return @intCast(code - zero);
    return null;
}
fn number(text: []const u8) !i64 {
    var result: i64 = 0;
    var it = (std.unicode.Utf8View.init(text) catch return error.InvalidDatetime).iterator();
    while (it.nextCodepoint()) |code| {
        if (unicode.whitespace(code)) continue;
        const digit = decimal(code) orelse return error.InvalidDatetime;
        result = result * 10 + digit;
    }
    return result;
}
fn equivalent(a: Allocator, left: []const u8, right: []const u8) !bool {
    const lhs = try unicode.convert(a, left, .lower);
    const rhs = try unicode.convert(a, right, .lower);
    return std.mem.eql(u8, lhs, rhs);
}
fn nameIndex(a: Allocator, names: []const []const u8, text: []const u8) !i64 {
    for (names, 0..) |name, i| if (try equivalent(a, name, text)) return @intCast(i);
    return error.InvalidDatetime;
}
fn dayAt(a: Allocator, year: i64, month: i64, day: i64) !i64 {
    if (year < 1 or year > 9999) return error.InvalidDatetime;
    const label = try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(year)), @as(u64, @intCast(month)), @as(u64, @intCast(day)) });
    return @divFloor(calendar.parseTimestamp(label) catch return error.InvalidDatetime, std.time.s_per_day);
}
fn weekday(day: i64) i64 {
    return @mod(day + 3, 7);
}
fn isoDay(a: Allocator, year: i64, week: i64, week_day: i64) !i64 {
    if (week_day < 0 or week_day > 6) return error.InvalidDatetime;
    const january = try dayAt(a, year, 1, 1);
    const first_day = weekday(january);
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    if (week < 1 or week > 53 or (week == 53 and first_day != 3 and !(first_day == 2 and leap))) return error.InvalidDatetime;
    const fourth = january + 3;
    return fourth - weekday(fourth) + (week - 1) * 7 + week_day;
}
fn weekDay(a: Allocator, year: i64, week: i64, week_day: i64, monday: bool) !i64 {
    const january = try dayAt(a, year, 1, 1);
    var first_day = weekday(january);
    var day = week_day;
    if (!monday) {
        first_day = @mod(first_day + 1, 7);
        day = @mod(day + 1, 7);
    }
    return january + if (week == 0) day - first_day else @mod(7 - first_day, 7) + (week - 1) * 7 + day;
}
fn offset(a: Allocator, text: []const u8) !i64 {
    if (std.mem.eql(u8, text, "Z")) return 0;
    var normalized: std.Io.Writer.Allocating = .init(a);
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepointSlice()) |bytes| {
        const code = try std.unicode.utf8Decode(bytes);
        if (decimal(code)) |digit| try normalized.writer.writeByte('0' + digit) else try normalized.writer.writeAll(bytes);
    }
    const zone = normalized.written();
    const hour = try number(zone[1..3]);
    const minute_colon = zone[3] == ':';
    const minutes_start: usize = if (minute_colon) 4 else 3;
    const minute = try number(zone[minutes_start..][0..2]);
    var i = minutes_start + 2;
    var second: i64 = 0;
    var micros: i64 = 0;
    if (i < zone.len) {
        const second_colon = zone[i] == ':';
        if (second_colon != minute_colon) return error.InvalidDatetime;
        if (second_colon) i += 1;
        second = try number(zone[i..][0..2]);
        i += 2;
        if (i < zone.len) {
            if (zone[i] != '.') return error.InvalidDatetime;
            i += 1;
            micros = try number(zone[i..]);
            for (zone.len - i..6) |_| micros *= 10;
        }
    }
    const result = ((hour * 60 + minute) * 60 + second) * std.time.us_per_s + micros;
    if (result >= std.time.us_per_day) return error.InvalidTimeZoneOffset;
    return result * @as(i64, if (zone[0] == '-') -1 else 1);
}

pub fn parse(a: Allocator, input: []const u8, fmt: []const u8) !Parsed {
    const locale = try Locale.init(a);
    var pattern = Pattern{ .allocator = a, .locale = &locale, .out = .init(a) };
    try pattern.append(fmt, false, 0);
    const compiled = regex.compile(a, pattern.out.written(), 2) catch return error.InvalidDatetimeFormat;
    defer compiled.deinit();
    const matched = (try compiled.find(a, input, 0, input.len, regex.c.PCRE2_ANCHORED)) orelse return error.InvalidDatetime;
    if (matched.spans[0].end != input.len) return error.InvalidDatetime;
    var values: [256]?[]const u8 = @splat(null);
    for (compiled.names) |name| {
        const span = matched.spans[name.index];
        if (span.start >= 0) values[name.name[0]] = input[@intCast(span.start)..@intCast(span.end)];
    }
    var year: ?i64 = null;
    var iso_year: ?i64 = null;
    var month: i64 = 1;
    var day: i64 = 1;
    var hour: i64 = 0;
    var minute: i64 = 0;
    var second: i64 = 0;
    var micros: i64 = 0;
    var week_day: ?i64 = null;
    var ordinal: ?i64 = null;
    var week: ?i64 = null;
    var monday = false;
    var iso_week: ?i64 = null;
    var zone_offset: ?i64 = null;
    for (compiled.names) |name| {
        const text = values[name.name[0]] orelse continue;
        switch (name.name[0]) {
            'Y' => year = try number(text),
            'y' => {
                const short = try number(text);
                year = short + @as(i64, if (short <= 68) 2000 else 1900);
            },
            'G' => iso_year = try number(text),
            'm' => month = try number(text),
            'b', 'B' => month = 1 + try nameIndex(a, &locale.months[if (name.name[0] == 'b') 0 else 1], text),
            'd' => day = try number(text),
            'H' => hour = try number(text),
            'I' => {
                hour = try number(text);
                const ampm = values['p'] orelse "";
                if (ampm.len == 0 or try equivalent(a, ampm, locale.am_pm[0])) {
                    if (hour == 12) hour = 0;
                } else if (try equivalent(a, ampm, locale.am_pm[1])) {
                    if (hour != 12) hour += 12;
                }
            },
            'M' => minute = try number(text),
            'S' => second = try number(text),
            'f' => {
                micros = try number(text);
                for (text.len..6) |_| micros *= 10;
            },
            'a', 'A' => week_day = try nameIndex(a, &locale.weekdays[if (name.name[0] == 'a') 0 else 1], text),
            'w' => {
                const value = try number(text);
                week_day = if (value == 0) 6 else value - 1;
            },
            'u' => week_day = try number(text) - 1,
            'j' => ordinal = try number(text),
            'U', 'W' => {
                week = try number(text);
                monday = name.name[0] == 'W';
            },
            'V' => iso_week = try number(text),
            'z' => zone_offset = try offset(a, text),
            else => {},
        }
    }
    if (iso_year != null) {
        if (ordinal != null or iso_week == null or week_day == null) return error.InvalidDatetime;
    } else if (iso_week != null) return error.InvalidDatetime;
    const leap_fix = year == null and month == 2 and day == 29;
    const actual_year = year orelse if (leap_fix) @as(i64, 1904) else 1900;
    const date = if (ordinal) |numbered_day| (try dayAt(a, actual_year, 1, 1)) + numbered_day - 1 else if (week != null and week_day != null) try weekDay(a, actual_year, week.?, week_day.?, monday) else if (iso_year != null) try isoDay(a, iso_year.?, iso_week.?, week_day.?) else try dayAt(a, actual_year, month, day);
    var civil_seconds = date * std.time.s_per_day;
    if (leap_fix) {
        const label = try calendar.formatTimestamp(a, civil_seconds);
        const final_label = try std.fmt.allocPrint(a, "1900{s}", .{label[4..10]});
        civil_seconds = calendar.parseTimestamp(final_label) catch return error.InvalidDatetime;
    }
    if (hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 59) return error.InvalidDatetime;
    const civil_ns = @as(i96, civil_seconds + hour * 3600 + minute * 60 + second) * std.time.ns_per_s + @as(i96, micros) * std.time.ns_per_us;
    if (civil_ns < -62135596800 * @as(i96, std.time.ns_per_s) or civil_ns >= 253402300800 * @as(i96, std.time.ns_per_s)) return error.InvalidDatetime;
    return .{ .civil_ns = civil_ns, .offset_us = zone_offset, .zone_name = values['Z'] };
}

test "native strptime retains calendar fractions exact offsets and locale names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try parse(a, "Thursday February 29 2024 04:17:18.1 pm +05:30:12.123456", "%A %B %d %Y %I:%M:%S.%f %p %z");
    try std.testing.expectEqual(@as(i96, 1709223438100000000), got.civil_ns);
    try std.testing.expectEqual(@as(?i64, 19812123456), got.offset_us);
    try std.testing.expectEqual(@as(i96, -62135596800 * @as(i96, std.time.ns_per_s)), (try parse(a, "０００１-01-01", "%Y-%m-%d")).civil_ns);
    try std.testing.expectEqual(@as(i96, 1704067200 * @as(i96, std.time.ns_per_s)), (try parse(a, "٢٠٢٤\x00 ١\t١", "%Y\x00 %Om %Od")).civil_ns);
    const named = try parse(a, "utc +0000", "%Z %z");
    try std.testing.expectEqualStrings("utc", named.zone_name.?);
    try std.testing.expectEqual(@as(?i64, 0), named.offset_us);
}

test "native strptime derives ISO ordinary week and ordinal calendars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(i96, 1609459200 * @as(i96, std.time.ns_per_s)), (try parse(a, "2020 53 5", "%G %V %u")).civil_ns);
    try std.testing.expectEqual(@as(i96, 1609459200 * @as(i96, std.time.ns_per_s)), (try parse(a, "2020 366", "%Y %j")).civil_ns + std.time.ns_per_day);
    try std.testing.expectEqual(@as(i96, 1546214400 * @as(i96, std.time.ns_per_s)), (try parse(a, "2019 00 1", "%Y %W %w")).civil_ns);
    try std.testing.expectEqual(@as(i96, 951782400 * @as(i96, std.time.ns_per_s)), (try parse(a, "Tue Feb 29 00:00:00 2000", "%c")).civil_ns);
}

test "native strptime rejects impossible and inconsistent format fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidDatetime, parse(a, "2021 53 1", "%G %V %u"));
    try std.testing.expectError(error.InvalidDatetime, parse(a, "2020 01 9", "%G %V %Ow"));
    try std.testing.expectError(error.InvalidDatetime, parse(a, "Feb 29", "%b %d"));
    try std.testing.expectError(error.InvalidDatetime, parse(a, "12:30:60", "%H:%M:%S"));
    try std.testing.expectError(error.InvalidDatetime, parse(a, "+05:3012", "%z"));
    try std.testing.expectError(error.InvalidDatetime, parse(a, "2020 extra", "%Y"));
    try std.testing.expectError(error.InvalidDatetimeFormat, parse(a, "2020 2020", "%Y %Y"));
    try std.testing.expectError(error.InvalidDatetimeFormat, parse(a, "2020-01-01", "%F"));
    try std.testing.expectError(error.InvalidDatetimeFormat, parse(a, "+00:00", "%:z"));
}
