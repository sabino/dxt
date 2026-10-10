//! Native UTC datetime values exposed by dbt's microbatch model context.
const std = @import("std");
const expression = @import("expression.zig");
const calendar = @import("workflow_intervals.zig");
const timezones = @import("timezone_context.zig");
const Value = expression.Value;
const Argument = expression.Argument;

pub fn value(a: std.mem.Allocator, epoch_ns: i96) !Value {
    return datetimeValue(a, epoch_ns, false, 0);
}

/// Core config datetimes retain authored timezone awareness; batch datetimes
/// themselves are always UTC. The epoch argument here represents civil fields.
pub fn configuredValue(a: std.mem.Allocator, civil_ns: i96, original: []const u8) !Value {
    var offset: ?i32 = null;
    if (original.len > 19 and std.mem.endsWith(u8, original, "Z")) offset = 0 else if (original.len >= 25) {
        const zone = original[original.len - 6 ..];
        if ((zone[0] == '+' or zone[0] == '-') and zone[3] == ':') {
            const hour = try std.fmt.parseInt(i32, zone[1..3], 10);
            const minute = try std.fmt.parseInt(i32, zone[4..6], 10);
            offset = (hour * 60 + minute) * @as(i32, if (zone[0] == '-') -1 else 1);
        }
    }
    return datetimeValue(a, civil_ns, false, offset);
}

pub fn fromYaml(a: std.mem.Allocator, canonical: []const u8) !Value {
    const seconds = try calendar.parseTimestamp(if (canonical.len == 10) canonical else canonical[0..19]);
    var ns = @as(i96, seconds) * std.time.ns_per_s;
    if (canonical.len > 19 and canonical[19] == '.') ns += @as(i96, try std.fmt.parseInt(u32, canonical[20..26], 10)) * std.time.ns_per_us;
    const original = if (canonical.len == 10) try datetimeValue(a, ns, true, null) else try configuredValue(a, ns, canonical);
    const entries = try expression.allocateEntries(a, original.object.len + 1);
    @memcpy(entries[0..original.object.len], original.object);
    entries[original.object.len] = .{ .key = "__dxt_yaml_timestamp", .value = .{ .string = canonical } };
    return .{ .object = entries };
}

pub const TemporalState = struct {
    civil_ns: i96,
    date_only: bool,
    utc_offset: ?i32,
    offset_us: ?i64,
    zone_name: ?[]const u8 = null,
    timezone: ?Value = null,
    fold: u1 = 0,
};
fn signedInteger(comptime T: type, v: Value) ?T {
    if (v != .integer) return null;
    return std.fmt.parseInt(T, v.integer, 10) catch null;
}
pub fn state(v: Value) ?TemporalState {
    const ns = signedInteger(i96, v.attribute("__dxt_civil_ns")) orelse return null;
    const date_only = v.attribute("__dxt_date_only");
    if (date_only != .boolean) return null;
    const offset = signedInteger(i64, v.attribute("__dxt_offset_us"));
    const zone = v.attribute("__dxt_timezone");
    const zone_name = if (zone != .undefined) zone.attribute("__dxt_timezone_name") else .undefined;
    return .{
        .civil_ns = ns,
        .date_only = date_only.boolean,
        .utc_offset = if (offset) |micros| @intCast(@divTrunc(micros, std.time.us_per_min)) else null,
        .offset_us = offset,
        .zone_name = if (zone_name == .string) zone_name.string else null,
        .timezone = if (zone == .object) zone else null,
        .fold = signedInteger(u1, v.attribute("fold")) orelse 0,
    };
}
fn writeZone(w: *std.Io.Writer, offset_us: i64, colon: bool) !void {
    const total = @abs(offset_us);
    const seconds = total / std.time.us_per_s;
    const fraction = total % std.time.us_per_s;
    try w.print("{c}{d:0>2}{s}{d:0>2}", .{ @as(u8, if (offset_us < 0) '-' else '+'), seconds / 3600, if (colon) ":" else "", (seconds % 3600) / 60 });
    if (seconds % 60 != 0 or fraction != 0) {
        try w.print("{s}{d:0>2}", .{ if (colon) @as([]const u8, ":") else "", seconds % 60 });
        if (fraction != 0) try w.print(".{d:0>6}", .{fraction});
    }
}
fn zoneName(a: std.mem.Allocator, offset_us: i64) ![]const u8 {
    if (offset_us == 0) return "UTC";
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.writeAll("UTC");
    try writeZone(&out.writer, offset_us, true);
    return out.toOwnedSlice();
}
pub fn datetimeValue(a: std.mem.Allocator, civil_ns: i96, date_only: bool, utc_offset: ?i32) anyerror!Value {
    return datetimeValueWithOffsetUs(a, civil_ns, date_only, if (utc_offset) |offset| @as(i64, offset) * std.time.us_per_min else null, null, 0);
}
pub fn attachTimezone(a: std.mem.Allocator, civil_ns: i96, zone: Value) anyerror!Value {
    const offset_us = signedInteger(i64, zone.attribute("__dxt_timezone_offset_us")) orelse return error.JinjaTypeError;
    return datetimeValueWithOffsetUs(a, civil_ns, false, offset_us, zone, 0);
}
pub fn datetimeValueWithOffsetUs(a: std.mem.Allocator, civil_ns: i96, date_only: bool, offset_us: ?i64, timezone: ?Value, fold: u1) anyerror!Value {
    if (offset_us) |offset| if (@abs(offset) >= std.time.us_per_day) return error.InvalidTimeZoneOffset;
    const label = try calendar.formatTimestamp(a, @intCast(@divFloor(civil_ns, std.time.ns_per_s)));
    const year = try std.fmt.parseInt(u32, label[0..4], 10);
    if (year < 1 or year > 9999) return error.InvalidDatetime;
    const micros: u64 = @intCast(@divFloor(@mod(civil_ns, std.time.ns_per_s), std.time.ns_per_us));
    const rendered = if (date_only) try a.dupe(u8, label[0..10]) else try isoformat(a, civil_ns, " ", "auto", offset_us);
    var entries: std.ArrayList(expression.Entry) = .empty;
    try entries.appendSlice(a, &.{
        .{ .key = "__dxt_rendered", .value = .{ .string = rendered } },
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_civil_ns", .value = try expression.integerValue(a, civil_ns) },
        .{ .key = "__dxt_date_only", .value = .{ .boolean = date_only } },
        .{ .key = "__dxt_offset_us", .value = if (offset_us) |offset| try expression.integerValue(a, offset) else .none },
        .{ .key = "__dxt_timezone", .value = timezone orelse .none },
    });
    var representation: std.Io.Writer.Allocating = .init(a);
    try representation.writer.writeAll(if (date_only) "datetime.date(" else "datetime.datetime(");
    for ([_][2]usize{ .{ 0, 4 }, .{ 5, 7 }, .{ 8, 10 } }, 0..) |span, i| {
        if (i != 0) try representation.writer.writeAll(", ");
        try representation.writer.print("{d}", .{try std.fmt.parseInt(u32, label[span[0]..span[1]], 10)});
    }
    if (!date_only) {
        const hour = try std.fmt.parseInt(u32, label[11..13], 10);
        const minute = try std.fmt.parseInt(u32, label[14..16], 10);
        const second = try std.fmt.parseInt(u32, label[17..19], 10);
        try representation.writer.print(", {d}, {d}", .{ hour, minute });
        if (second != 0 or micros != 0) try representation.writer.print(", {d}", .{second});
        if (micros != 0) try representation.writer.print(", {d}", .{micros});
        if (offset_us) |offset| {
            if (timezone) |zone| {
                try representation.writer.print(", tzinfo={s}", .{try expression.repr(zone, a)});
            } else if (offset == 0) try representation.writer.writeAll(", tzinfo=datetime.timezone.utc") else {
                const days = @divFloor(offset, std.time.us_per_day);
                const seconds = @divFloor(@mod(offset, std.time.us_per_day), std.time.us_per_s);
                const fraction = @mod(offset, std.time.us_per_s);
                try representation.writer.writeAll(", tzinfo=datetime.timezone(datetime.timedelta(");
                if (days != 0) try representation.writer.print("days={d}, ", .{days});
                try representation.writer.print("seconds={d}", .{seconds});
                if (fraction != 0) try representation.writer.print(", microseconds={d}", .{fraction});
                try representation.writer.writeAll("))");
            }
        }
        if (fold != 0) try representation.writer.print(", fold={d}", .{fold});
    }
    try representation.writer.writeByte(')');
    try entries.append(a, .{ .key = "__dxt_repr", .value = .{ .string = try representation.toOwnedSlice() } });
    inline for (.{ .{ "year", 0, 4 }, .{ "month", 5, 7 }, .{ "day", 8, 10 }, .{ "hour", 11, 13 }, .{ "minute", 14, 16 }, .{ "second", 17, 19 } }) |field| {
        if (!date_only or field[1] < 10) try entries.append(a, .{ .key = field[0], .value = try expression.integerValue(a, try std.fmt.parseInt(u64, label[field[1]..field[2]], 10)) });
    }
    if (!date_only) try entries.appendSlice(a, &.{
        .{ .key = "microsecond", .value = try expression.integerValue(a, micros) },
        .{ .key = "tzinfo", .value = if (timezone) |zone| zone else if (offset_us) |offset| .{ .string = try zoneName(a, offset) } else .none },
        .{ .key = "fold", .value = try expression.integerValue(a, fold) },
    });
    const spec = try std.fmt.allocPrint(a, "{d}:{s}:{s}:{s}:{d}:{s}", .{ civil_ns, if (date_only) "date" else "datetime", if (offset_us) |offset| try std.fmt.allocPrint(a, "{d}", .{@divTrunc(offset, std.time.us_per_min)}) else "naive", if (offset_us) |offset| try std.fmt.allocPrint(a, "{d}", .{offset}) else "naive", fold, if (timezone) |zone| zone.attribute("__dxt_timezone_identity").string else "" });
    for ([_][]const u8{ "strftime", "isoformat", "date", "timestamp", "weekday", "isoweekday", "replace", "utcoffset", "dst", "tzname", "astimezone" }) |method| {
        if (date_only and (std.mem.eql(u8, method, "date") or std.mem.eql(u8, method, "timestamp") or std.mem.eql(u8, method, "utcoffset") or std.mem.eql(u8, method, "dst") or std.mem.eql(u8, method, "tzname") or std.mem.eql(u8, method, "astimezone"))) continue;
        try entries.append(a, .{ .key = method, .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_datetime:{s}:{s}", .{ method, spec }) } });
    }
    return .{ .object = try entries.toOwnedSlice(a) };
}

fn named(args: []const Argument, name: []const u8, position: usize) ?Value {
    for (args) |arg| if (arg.name) |key| if (std.mem.eql(u8, key, name)) return arg.value;
    var index: usize = 0;
    for (args) |arg| if (arg.name == null) {
        if (index == position) return arg.value;
        index += 1;
    };
    return null;
}

fn textArg(args: []const Argument, name: []const u8, position: usize, fallback: []const u8) ![]const u8 {
    const v = named(args, name, position) orelse return fallback;
    if (v != .string) return error.JinjaTypeError;
    return v.string;
}

fn checkArgs(args: []const Argument, names: []const []const u8, required: usize) !void {
    var present: [10]bool = @splat(false);
    var position: usize = 0;
    for (args) |arg| {
        const index = if (arg.name) |key| blk: {
            for (names, 0..) |name, i| if (std.mem.eql(u8, name, key)) break :blk i;
            return error.InvalidJinjaArguments;
        } else blk: {
            const at = position;
            position += 1;
            break :blk at;
        };
        if (index >= names.len or present[index]) return error.InvalidJinjaArguments;
        present[index] = true;
    }
    for (present[0..required]) |supplied| if (!supplied) return error.InvalidJinjaArguments;
}
pub fn call(a: std.mem.Allocator, name: []const u8, args: []const Argument) anyerror!?Value {
    const prefix = "__dxt_datetime:";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    var parts = std.mem.splitScalar(u8, name[prefix.len..], ':');
    const method = parts.next() orelse return error.InvalidDatetime;
    const ns = std.fmt.parseInt(i96, parts.next() orelse return error.InvalidDatetime, 10) catch return error.InvalidDatetime;
    const date_only = std.mem.eql(u8, parts.next() orelse return error.InvalidDatetime, "date");
    const offset_text = parts.next() orelse "0";
    const exact_text = parts.next();
    const offset_us: ?i64 = if (exact_text) |exact| (if (std.mem.eql(u8, exact, "naive")) null else try std.fmt.parseInt(i64, exact, 10)) else if (std.mem.eql(u8, offset_text, "naive")) null else @as(i64, try std.fmt.parseInt(i32, offset_text, 10)) * std.time.us_per_min;
    const fold: u1 = if (parts.next()) |field| try std.fmt.parseInt(u1, field, 10) else 0;
    const timezone: ?Value = if (parts.rest().len != 0) try timezones.fromIdentity(a, parts.rest()) else null;
    if (std.mem.eql(u8, method, "strftime")) {
        try checkArgs(args, &.{"format"}, 1);
        return .{ .string = try strftime(a, ns, try textArg(args, "format", 0, ""), date_only, offset_us, timezone) };
    }
    if (std.mem.eql(u8, method, "isoformat")) {
        try checkArgs(args, if (date_only) &.{} else &.{ "sep", "timespec" }, 0);
        if (date_only) {
            const label = try calendar.formatTimestamp(a, @intCast(@divFloor(ns, std.time.ns_per_s)));
            return .{ .string = try a.dupe(u8, label[0..10]) };
        }
        return .{ .string = try isoformat(a, ns, try textArg(args, "sep", 0, "T"), try textArg(args, "timespec", 1, "auto"), offset_us) };
    }
    if (std.mem.eql(u8, method, "replace")) {
        const names = [_][]const u8{ "year", "month", "day", "hour", "minute", "second", "microsecond", "tzinfo", "fold" };
        try checkArgs(args, if (date_only) names[0..3] else &names, 0);
        var positions: usize = 0;
        for (args) |arg| if (arg.name == null) {
            positions += 1;
        };
        if (positions > 8) return error.InvalidJinjaArguments;
        const original = try calendar.formatTimestamp(a, @intCast(@divFloor(ns, std.time.ns_per_s)));
        var fields: [7]u64 = undefined;
        inline for (.{ .{ "year", 0, 4 }, .{ "month", 5, 7 }, .{ "day", 8, 10 }, .{ "hour", 11, 13 }, .{ "minute", 14, 16 }, .{ "second", 17, 19 } }, 0..) |field, index| {
            fields[index] = try std.fmt.parseInt(u64, original[field[1]..field[2]], 10);
            if (named(args, field[0], index)) |replacement| fields[index] = try integer(replacement);
        }
        fields[6] = @intCast(@divFloor(@mod(ns, std.time.ns_per_s), std.time.ns_per_us));
        if (named(args, "microsecond", 6)) |replacement| fields[6] = try integer(replacement);
        if (fields[6] > 999999 or fields[0] == 0 or fields[0] > 9999) return error.InvalidDatetime;
        const label = try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ fields[0], fields[1], fields[2], fields[3], fields[4], fields[5] });
        const timestamp = @as(i96, calendar.parseTimestamp(label) catch return error.InvalidDatetime) * std.time.ns_per_s;
        var replaced_zone = timezone;
        var replaced_offset = offset_us;
        if (named(args, "tzinfo", 7)) |zone| {
            replaced_zone = if (zone == .none) null else zone;
            replaced_offset = if (zone == .none) null else signedInteger(i64, zone.attribute("__dxt_timezone_offset_us")) orelse return error.JinjaTypeError;
        }
        const replacement_fold = if (named(args, "fold", 8)) |value_| signedInteger(u1, value_) orelse return error.InvalidDatetime else fold;
        return try datetimeValueWithOffsetUs(a, timestamp + @as(i96, @intCast(fields[6])) * std.time.ns_per_us, date_only, replaced_offset, replaced_zone, replacement_fold);
    }
    if (std.mem.eql(u8, method, "astimezone")) {
        try checkArgs(args, &.{"tz"}, 0);
        const zone = named(args, "tz", 0) orelse .none;
        const target = if (zone == .none) try timezones.timezoneValue(a, "UTC", null) else zone;
        if (target.attribute("__dxt_timezone_offset_us") != .integer) return error.JinjaTypeError;
        const utc_ns = ns - @as(i96, offset_us orelse 0) * std.time.ns_per_us;
        const actual = try timezones.atUtc(a, target, @intCast(@divFloor(utc_ns, std.time.ns_per_s)));
        const offset = signedInteger(i64, actual.attribute("__dxt_timezone_offset_us")).?;
        return try attachTimezone(a, utc_ns + @as(i96, offset) * std.time.ns_per_us, actual);
    }
    try checkArgs(args, &.{}, 0);
    if (std.mem.eql(u8, method, "date")) return try datetimeValue(a, @divFloor(ns, std.time.ns_per_day) * std.time.ns_per_day, true, null);
    if (std.mem.eql(u8, method, "timestamp") and !date_only) return .{ .number = @as(f64, @floatFromInt(ns - @as(i96, offset_us orelse 0) * std.time.ns_per_us)) / std.time.ns_per_s };
    if (std.mem.eql(u8, method, "utcoffset")) return if (offset_us) |offset| try timezones.durationValue(a, offset) else .none;
    if (std.mem.eql(u8, method, "dst")) return if (timezone) |zone| try timezones.durationValue(a, signedInteger(i64, zone.attribute("__dxt_timezone_dst_us")) orelse 0) else .none;
    if (std.mem.eql(u8, method, "tzname")) return if (timezone) |zone| zone.attribute("__dxt_timezone_abbreviation") else if (offset_us) |offset| .{ .string = try zoneName(a, offset) } else .none;
    const day = @divFloor(ns, std.time.ns_per_day);
    if (std.mem.eql(u8, method, "weekday")) return try expression.integerValue(a, @mod(day + 3, 7));
    if (std.mem.eql(u8, method, "isoweekday")) return try expression.integerValue(a, @mod(day + 3, 7) + 1);
    return error.JinjaTypeError;
}

fn integer(v: Value) !u64 {
    const count = try expression.integerIndex(v);
    if (count < 0 or count > 999999999) return error.JinjaTypeError;
    return @intCast(count);
}

fn isoformat(a: std.mem.Allocator, ns: i96, separator: []const u8, timespec: []const u8, offset_us: ?i64) ![]const u8 {
    if ((std.unicode.utf8CountCodepoints(separator) catch return error.JinjaTypeError) != 1) return error.JinjaTypeError;
    const label = try calendar.formatTimestamp(a, @intCast(@divFloor(ns, std.time.ns_per_s)));
    const micros: u64 = @intCast(@divFloor(@mod(ns, std.time.ns_per_s), std.time.ns_per_us));
    const spec = if (std.mem.eql(u8, timespec, "auto")) (if (micros == 0) "seconds" else "microseconds") else timespec;
    const length: usize = if (std.mem.eql(u8, spec, "hours")) 13 else if (std.mem.eql(u8, spec, "minutes")) 16 else if (std.mem.eql(u8, spec, "seconds") or std.mem.eql(u8, spec, "milliseconds") or std.mem.eql(u8, spec, "microseconds")) 19 else return error.InvalidDatetimeTimespec;
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.print("{s}{s}{s}", .{ label[0..10], separator, label[11..length] });
    if (std.mem.eql(u8, spec, "milliseconds")) try out.writer.print(".{d:0>3}", .{micros / 1000});
    if (std.mem.eql(u8, spec, "microseconds")) try out.writer.print(".{d:0>6}", .{micros});
    if (offset_us) |offset| try writeZone(&out.writer, offset, true);
    return out.toOwnedSlice();
}

fn strftime(a: std.mem.Allocator, ns: i96, format: []const u8, date_only: bool, offset_us: ?i64, timezone: ?Value) ![]const u8 {
    const label = try calendar.formatTimestamp(a, @intCast(@divFloor(ns, std.time.ns_per_s)));
    const micros: u64 = if (date_only) 0 else @intCast(@divFloor(@mod(ns, std.time.ns_per_s), std.time.ns_per_us));
    const days: i64 = @intCast(@divFloor(ns, std.time.ns_per_day));
    const weekday: usize = @intCast(@mod(days + 4, 7));
    const year_start = try calendar.parseTimestamp(try std.fmt.allocPrint(a, "{s}-01-01", .{label[0..4]}));
    const year_day: u64 = @intCast(days - @divFloor(year_start, 86400) + 1);
    const hour = try std.fmt.parseInt(u64, label[11..13], 10);
    const month = try std.fmt.parseInt(usize, label[5..7], 10);
    const week_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
    const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
    var out: std.Io.Writer.Allocating = .init(a);
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        if (format[i] != '%' or i + 1 == format.len) {
            try out.writer.writeByte(format[i]);
            continue;
        }
        i += 1;
        switch (format[i]) {
            '%' => try out.writer.writeByte('%'),
            'Y' => try out.writer.writeAll(label[0..4]),
            'y' => try out.writer.writeAll(label[2..4]),
            'm' => try out.writer.writeAll(label[5..7]),
            'd' => try out.writer.writeAll(label[8..10]),
            'H' => try out.writer.writeAll(if (date_only) "00" else label[11..13]),
            'I' => try out.writer.print("{d:0>2}", .{if (date_only or @mod(hour, 12) == 0) @as(u64, 12) else @mod(hour, 12)}),
            'M' => try out.writer.writeAll(if (date_only) "00" else label[14..16]),
            'S' => try out.writer.writeAll(if (date_only) "00" else label[17..19]),
            'f' => try out.writer.print("{d:0>6}", .{micros}),
            'p' => try out.writer.writeAll(if (date_only or hour < 12) "AM" else "PM"),
            'z' => if (!date_only) if (offset_us) |offset| try writeZone(&out.writer, offset, false),
            'Z' => if (!date_only) if (timezone) |zone| {
                const abbreviation = zone.attribute("__dxt_timezone_abbreviation");
                if (abbreviation == .string) try out.writer.writeAll(abbreviation.string);
            } else if (offset_us) |offset| try out.writer.writeAll(try zoneName(a, offset)),
            'j' => try out.writer.print("{d:0>3}", .{year_day}),
            'w' => try out.writer.print("{d}", .{weekday}),
            'u' => try out.writer.print("{d}", .{@mod(weekday + 6, 7) + 1}),
            'a' => try out.writer.writeAll(week_names[weekday][0..3]),
            'A' => try out.writer.writeAll(week_names[weekday]),
            'b', 'h' => try out.writer.writeAll(month_names[month - 1][0..3]),
            'B' => try out.writer.writeAll(month_names[month - 1]),
            'F' => try out.writer.writeAll(label[0..10]),
            'T' => try out.writer.writeAll(if (date_only) "00:00:00" else label[11..19]),
            'n' => try out.writer.writeByte('\n'),
            't' => try out.writer.writeByte('\t'),
            else => try out.writer.print("%{c}", .{format[i]}),
        }
    }
    return out.toOwnedSlice();
}

test "native UTC datetime values retain microseconds and Python ISO/format behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ns = @as(i96, try calendar.parseTimestamp("2024-02-29 16:17:18")) * std.time.ns_per_s + 123456 * std.time.ns_per_us;
    const dt = try value(a, ns);
    try std.testing.expectEqualStrings("2024-02-29 16:17:18.123456+00:00", try dt.text(a));
    const formatted = (try call(a, dt.attribute("strftime").callable, &.{.{ .value = .{ .string = "%Y-%m-%d %H:%M:%S.%f %z %Z %A %j" } }})).?;
    try std.testing.expectEqualStrings("2024-02-29 16:17:18.123456 +0000 UTC Thursday 060", formatted.string);
    try std.testing.expectEqualStrings("2024-02-29T16:17:18.123+00:00", (try call(a, dt.attribute("isoformat").callable, &.{.{ .name = "timespec", .value = .{ .string = "milliseconds" } }})).?.string);
    const date = (try call(a, dt.attribute("date").callable, &.{})).?;
    try std.testing.expectEqualStrings("2024-02-29", try date.text(a));
    const replaced = (try call(a, dt.attribute("replace").callable, &.{ .{ .name = "hour", .value = .{ .integer = "0" } }, .{ .name = "microsecond", .value = .{ .integer = "0" } } })).?;
    try std.testing.expectEqualStrings("2024-02-29 00:17:18+00:00", try replaced.text(a));
    try std.testing.expectEqual(@as(i64, 3), try expression.integerIndex((try call(a, dt.attribute("weekday").callable, &.{})).?));
}
