//! Native constructors exposed by dbt's restricted datetime module.
const std = @import("std");
const expr = @import("expression.zig");
const dates = @import("timestamp_context.zig");
const calendar = @import("workflow_intervals.zig");
const local_time = @import("native_local_time.zig");
const timezone_context = @import("timezone_context.zig");
const Value = expr.Value;
const Argument = expr.Argument;
const Allocator = std.mem.Allocator;
pub const exports = [_][]const u8{ "date", "datetime", "time", "timedelta", "tzinfo" };
pub const Options = struct { io: ?std.Io = null, now_ns: ?i96 = null };

fn object(a: Allocator, entries: []const expr.Entry) !Value {
    return .{ .object = try a.dupe(expr.Entry, entries) };
}
fn function(a: Allocator, kind: []const u8, method: []const u8) !Value {
    return .{ .callable = try std.fmt.allocPrint(a, "__dxt_datetime_class:{s}:{s}", .{ kind, method }) };
}
fn classValue(a: Allocator, kind: []const u8) !Value {
    var entries: std.ArrayList(expr.Entry) = .empty;
    try entries.appendSlice(a, &.{
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_class_identity", .value = .{ .string = try std.fmt.allocPrint(a, "datetime.{s}", .{kind}) } },
        .{ .key = "__dxt_callable", .value = try function(a, kind, "new") },
        .{ .key = "__dxt_rendered", .value = .{ .string = try std.fmt.allocPrint(a, "<class 'datetime.{s}'>", .{kind}) } },
    });
    if (std.mem.eql(u8, kind, "date") or std.mem.eql(u8, kind, "datetime")) {
        const date_only = std.mem.eql(u8, kind, "date");
        for ([_][]const u8{ "today", "fromtimestamp", "fromordinal", "fromisoformat" }) |method| try entries.append(a, .{ .key = method, .value = try function(a, kind, method) });
        if (!date_only) for ([_][]const u8{ "now", "utcnow", "utcfromtimestamp", "strptime", "combine" }) |method| try entries.append(a, .{ .key = method, .value = try function(a, kind, method) });
        const first = @as(i96, try calendar.parseTimestamp("0001-01-01")) * std.time.ns_per_s;
        const last = @as(i96, try calendar.parseTimestamp("9999-12-31")) * std.time.ns_per_s + if (date_only) @as(i96, 0) else std.time.ns_per_day - std.time.ns_per_us;
        try entries.appendSlice(a, &.{
            .{ .key = "min", .value = try dates.datetimeValue(a, first, date_only, null) },
            .{ .key = "max", .value = try dates.datetimeValue(a, last, date_only, null) },
            .{ .key = "resolution", .value = try durationValue(a, if (date_only) std.time.us_per_day else 1) },
        });
    } else if (std.mem.eql(u8, kind, "time")) {
        try entries.append(a, .{ .key = "fromisoformat", .value = try function(a, kind, "fromisoformat") });
        try entries.appendSlice(a, &.{
            .{ .key = "min", .value = try timeValue(a, 0, null, 0) },
            .{ .key = "max", .value = try timeValue(a, std.time.us_per_day - 1, null, 0) },
            .{ .key = "resolution", .value = try durationValue(a, 1) },
        });
    } else if (std.mem.eql(u8, kind, "timedelta")) try entries.appendSlice(a, &.{
        .{ .key = "min", .value = try durationValue(a, -999999999 * @as(i96, std.time.us_per_day)) },
        .{ .key = "max", .value = try durationValue(a, 1000000000 * @as(i96, std.time.us_per_day) - 1) },
        .{ .key = "resolution", .value = try durationValue(a, 1) },
    });
    return .{ .object = try entries.toOwnedSlice(a) };
}
pub fn resolve(a: Allocator, path: []const u8) !?Value {
    if (std.mem.eql(u8, path, "modules.datetime")) {
        const entries = try expr.allocateEntries(a, exports.len);
        for (exports, entries) |name, *entry| entry.* = .{ .key = name, .value = try classValue(a, name) };
        return .{ .object = entries };
    }
    const prefix = "modules.datetime.";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    var parts = std.mem.splitScalar(u8, path[prefix.len..], '.');
    const kind = parts.next().?;
    for (exports) |name| if (std.mem.eql(u8, name, kind)) {
        var value = try classValue(a, kind);
        while (parts.next()) |attribute| value = try expr.checkedAttribute(value, attribute);
        return value;
    };
    return .undefined;
}

fn bind(args: []const Argument, names: []const []const u8, required: usize, defaults: []const Value, values: []Value) !void {
    if (values.ptr != defaults.ptr) @memcpy(values, defaults);
    var present: [10]bool = @splat(false);
    var position: usize = 0;
    for (args) |arg| {
        const at = if (arg.name) |key| blk: {
            for (names, 0..) |name, i| if (std.mem.eql(u8, name, key)) break :blk i;
            return error.InvalidJinjaArguments;
        } else blk: {
            const i = position;
            position += 1;
            break :blk i;
        };
        if (at >= names.len or present[at]) return error.InvalidJinjaArguments;
        present[at] = true;
        values[at] = arg.value;
    }
    for (present[0..required]) |supplied| if (!supplied) return error.InvalidJinjaArguments;
}
fn component(value: Value, min: i64, max: i64) !i64 {
    const number = try expr.integerIndex(value);
    if (number < min or number > max) return error.InvalidDatetime;
    return number;
}
fn timezoneOffsetUs(value: Value) !?i64 {
    if (value == .none) return null;
    const exact = value.attribute("__dxt_timezone_offset_us");
    if (exact == .integer) return try expr.integerIndex(exact);
    return if (try timezoneOffset(value)) |minutes| @as(i64, minutes) * std.time.us_per_min else null;
}
fn timezoneOffset(value: Value) !?i32 {
    if (value == .none) return null;
    const offset = value.attribute("__dxt_timezone_offset");
    if (offset == .integer) return @intCast(try component(offset, -1439, 1439));
    return error.JinjaTypeError;
}
fn fromComponents(a: Allocator, kind: []const u8, args: []const Argument) !Value {
    if (std.mem.eql(u8, kind, "tzinfo")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        return object(a, &.{
            .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
            .{ .key = "__dxt_rendered", .value = .{ .string = "<datetime.tzinfo object>" } },
        });
    }
    if (std.mem.eql(u8, kind, "timedelta")) {
        const names = [_][]const u8{ "days", "seconds", "microseconds", "milliseconds", "minutes", "hours", "weeks" };
        var values: [7]Value = @splat(.{ .integer = "0" });
        try bind(args, &names, 0, &@as([7]Value, @splat(.{ .integer = "0" })), &values);
        const scales = [_]f64{ std.time.us_per_day, std.time.us_per_s, 1, 1000, std.time.us_per_min, std.time.us_per_hour, 7 * std.time.us_per_day };
        var total: f64 = 0;
        for (values, scales) |value, scale| total += try expr.numericFloat(value) * scale;
        if (!std.math.isFinite(total) or total < -999999999.0 * std.time.us_per_day or total >= 1000000000.0 * std.time.us_per_day) return error.JinjaNumericOverflow;
        const floor = @floor(total);
        const fraction = total - floor;
        const rounded = floor + @as(f64, if (fraction > 0.5 or (fraction == 0.5 and @mod(floor, 2) != 0)) 1 else 0);
        return durationValue(a, @intFromFloat(rounded));
    }
    const time_only = std.mem.eql(u8, kind, "time");
    const date_only = std.mem.eql(u8, kind, "date");
    const all_names = [_][]const u8{ "year", "month", "day", "hour", "minute", "second", "microsecond", "tzinfo", "fold" };
    const names = if (date_only) all_names[0..3] else if (time_only) all_names[3..] else &all_names;
    const defaults = [_]Value{ .undefined, .undefined, .undefined, .{ .integer = "0" }, .{ .integer = "0" }, .{ .integer = "0" }, .{ .integer = "0" }, .none, .{ .integer = "0" } };
    var values: [9]Value = defaults;
    const bound = if (time_only) values[3..] else values[0..names.len];
    try bind(args, names, if (time_only) 0 else 3, if (time_only) defaults[3..] else defaults[0..names.len], bound);
    if ((!date_only and !time_only and args.len > 8 and args[8].name == null) or (time_only and args.len > 5 and args[5].name == null)) return error.InvalidJinjaArguments;
    var ns: i96 = 0;
    if (!time_only) {
        const year = try component(values[0], 1, 9999);
        const month = try component(values[1], 1, 12);
        const day = try component(values[2], 1, 31);
        const text = try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}", .{ @as(u64, @intCast(year)), @as(u64, @intCast(month)), @as(u64, @intCast(day)) });
        ns = @as(i96, calendar.parseTimestamp(text) catch return error.InvalidDatetime) * std.time.ns_per_s;
    }
    if (!date_only) {
        ns += @as(i96, try component(values[3], 0, 23)) * std.time.ns_per_hour + @as(i96, try component(values[4], 0, 59)) * std.time.ns_per_min + @as(i96, try component(values[5], 0, 59)) * std.time.ns_per_s + @as(i96, try component(values[6], 0, 999999)) * std.time.ns_per_us;
        _ = try component(values[8], 0, 1);
    }
    if (time_only) return timeValue(a, @intCast(@divFloor(ns, std.time.ns_per_us)), try timezoneOffset(values[7]), @intCast(try expr.integerIndex(values[8])));
    return dates.datetimeValueWithOffsetUs(a, ns, date_only, if (date_only) null else try timezoneOffsetUs(values[7]), if (date_only or values[7] == .none) null else values[7], if (date_only) 0 else @intCast(try expr.integerIndex(values[8])));
}

pub fn localCivil(a: Allocator, utc_ns: i96) !i96 {
    return local_time.civil(a, utc_ns);
}
pub fn localTimestamp(a: Allocator, civil_ns: i96, fold: u1) !i96 {
    return local_time.timestamp(a, civil_ns, fold);
}
fn fromInstant(a: Allocator, utc_ns: i96, date_only: bool, zone: Value, utc: bool) anyerror!Value {
    if (zone != .none) {
        const current = try timezone_context.atUtc(a, zone, @intCast(@divFloor(utc_ns, std.time.ns_per_s)));
        const offset = try timezoneOffsetUs(current);
        return dates.datetimeValueWithOffsetUs(a, utc_ns + @as(i96, offset orelse 0) * std.time.ns_per_us, false, offset, current, 0);
    }
    var civil_ns = if (utc) utc_ns else try localCivil(a, utc_ns);
    const fold: u1 = if (utc or date_only) 0 else try local_time.foldAt(a, utc_ns);
    if (date_only) civil_ns = @divFloor(civil_ns, std.time.ns_per_day) * std.time.ns_per_day;
    return dates.datetimeValueWithOffsetUs(a, civil_ns, date_only, null, null, fold);
}

pub fn durationValue(a: Allocator, micros: i96) !Value {
    const days = @divFloor(micros, std.time.us_per_day);
    const remainder = @mod(micros, std.time.us_per_day);
    const seconds = @divFloor(remainder, std.time.us_per_s);
    const fraction = @mod(remainder, std.time.us_per_s);
    var text: std.Io.Writer.Allocating = .init(a);
    if (days != 0) try text.writer.print("{s}{d} day{s}, ", .{ if (days < 0) @as([]const u8, "-") else "", @abs(days), if (days == 1 or days == -1) @as([]const u8, "") else "s" });
    try text.writer.print("{d}:{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(@divFloor(seconds, 3600))), @as(u64, @intCast(@divFloor(@mod(seconds, 3600), 60))), @as(u64, @intCast(@mod(seconds, 60))) });
    if (fraction != 0) try text.writer.print(".{d:0>6}", .{@as(u64, @intCast(fraction))});
    return object(a, &.{
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_duration", .value = try expr.integerValue(a, micros) },
        .{ .key = "__dxt_rendered", .value = .{ .string = try text.toOwnedSlice() } },
        .{ .key = "days", .value = try expr.integerValue(a, days) },
        .{ .key = "seconds", .value = try expr.integerValue(a, seconds) },
        .{ .key = "microseconds", .value = try expr.integerValue(a, fraction) },
        .{ .key = "total_seconds", .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_duration_total:{d}", .{micros}) } },
    });
}
fn timeValue(a: Allocator, micros: i64, offset: ?i32, fold: u1) !Value {
    var text: std.Io.Writer.Allocating = .init(a);
    try text.writer.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(@divFloor(micros, std.time.us_per_hour))), @as(u64, @intCast(@divFloor(@mod(micros, std.time.us_per_hour), std.time.us_per_min))), @as(u64, @intCast(@divFloor(@mod(micros, std.time.us_per_min), std.time.us_per_s))) });
    if (@mod(micros, std.time.us_per_s) != 0) try text.writer.print(".{d:0>6}", .{@as(u64, @intCast(@mod(micros, std.time.us_per_s)))});
    if (offset) |zone| try text.writer.print("{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (zone < 0) '-' else '+'), @abs(zone) / 60, @abs(zone) % 60 });
    return object(a, &.{
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_time", .value = try expr.integerValue(a, micros) },
        .{ .key = "__dxt_rendered", .value = .{ .string = try text.toOwnedSlice() } },
        .{ .key = "hour", .value = try expr.integerValue(a, @divFloor(micros, std.time.us_per_hour)) },
        .{ .key = "minute", .value = try expr.integerValue(a, @divFloor(@mod(micros, std.time.us_per_hour), std.time.us_per_min)) },
        .{ .key = "second", .value = try expr.integerValue(a, @divFloor(@mod(micros, std.time.us_per_min), std.time.us_per_s)) },
        .{ .key = "microsecond", .value = try expr.integerValue(a, @mod(micros, std.time.us_per_s)) },
        .{ .key = "tzinfo", .value = if (offset) |zone| try expr.integerValue(a, zone) else .none },
        .{ .key = "fold", .value = try expr.integerValue(a, fold) },
        .{ .key = "isoformat", .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_time_iso:{d}:{s}", .{ micros, if (offset) |zone| try std.fmt.allocPrint(a, "{d}", .{zone}) else "naive" }) } },
    });
}
pub fn call(a: Allocator, name: []const u8, args: []const Argument, options: Options) !?Value {
    if (std.mem.startsWith(u8, name, "__dxt_duration_total:")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        const micros = try std.fmt.parseInt(i96, name[21..], 10);
        return .{ .number = @as(f64, @floatFromInt(micros)) / std.time.us_per_s };
    }
    if (std.mem.startsWith(u8, name, "__dxt_time_iso:")) {
        var parts = std.mem.splitScalar(u8, name[15..], ':');
        const micros = try std.fmt.parseInt(i64, parts.next().?, 10);
        const zone = parts.next().?;
        const time = try timeValue(a, micros, if (std.mem.eql(u8, zone, "naive")) null else try std.fmt.parseInt(i32, zone, 10), 0);
        if (args.len != 0) return error.InvalidJinjaArguments;
        return time.attribute("__dxt_rendered");
    }
    const prefix = "__dxt_datetime_class:";
    var kind: []const u8 = undefined;
    var method: []const u8 = undefined;
    if (std.mem.startsWith(u8, name, prefix)) {
        var parts = std.mem.splitScalar(u8, name[prefix.len..], ':');
        kind = parts.next() orelse return error.InvalidDatetime;
        method = parts.next() orelse return error.InvalidDatetime;
    } else if (std.mem.startsWith(u8, name, "modules.datetime.")) {
        var parts = std.mem.splitScalar(u8, name[17..], '.');
        kind = parts.next().?;
        method = parts.next() orelse "new";
    } else return null;
    if (std.mem.eql(u8, method, "new")) return try fromComponents(a, kind, args);
    const date_only = std.mem.eql(u8, kind, "date");
    if (std.mem.eql(u8, method, "now") or std.mem.eql(u8, method, "utcnow") or std.mem.eql(u8, method, "today")) {
        var values = [_]Value{.none};
        if (std.mem.eql(u8, method, "now")) try bind(args, &.{"tz"}, 0, &.{.none}, &values) else if (args.len != 0) return error.InvalidJinjaArguments;
        const ns = @divFloor(options.now_ns orelse std.Io.Clock.real.now(options.io orelse std.Io.Threaded.global_single_threaded.io()).nanoseconds, std.time.ns_per_us) * std.time.ns_per_us;
        return try fromInstant(a, ns, date_only, values[0], std.mem.eql(u8, method, "utcnow"));
    }
    if (std.mem.eql(u8, method, "fromtimestamp") or std.mem.eql(u8, method, "utcfromtimestamp")) {
        var values = [_]Value{ .undefined, .none };
        const utc = std.mem.eql(u8, method, "utcfromtimestamp");
        try bind(args, if (date_only or utc) &.{"timestamp"} else &.{ "timestamp", "tz" }, 1, if (date_only or utc) values[0..1] else &values, if (date_only or utc) values[0..1] else &values);
        const seconds = try expr.numericFloat(values[0]);
        if (!std.math.isFinite(seconds) or @abs(seconds) > 4e11) return error.JinjaNumericOverflow;
        const ns = @as(i96, @intFromFloat(@round(seconds * std.time.us_per_s))) * std.time.ns_per_us;
        return try fromInstant(a, ns, date_only, values[1], utc);
    }
    if (std.mem.eql(u8, method, "fromordinal")) {
        if (args.len != 1 or args[0].name != null) return error.InvalidJinjaArguments;
        const ordinal = try component(args[0].value, 1, 3652059);
        return try dates.datetimeValue(a, @as(i96, ordinal - 719163) * std.time.ns_per_day, date_only, null);
    }
    return error.UnsupportedDatetimeMethod;
}

test "native datetime module constructors preserve civil values and fixed clock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dt = (try call(a, "modules.datetime.datetime", &.{ .{ .value = .{ .integer = "2024" } }, .{ .value = .{ .integer = "2" } }, .{ .value = .{ .integer = "29" } }, .{ .value = .{ .integer = "13" } } }, .{})).?;
    try std.testing.expectEqualStrings("2024-02-29 13:00:00", try dt.text(a));
    try std.testing.expectEqualStrings("1969-12-31 23:59:59.750000", try (try call(a, "modules.datetime.datetime.fromtimestamp", &.{.{ .value = .{ .number = -0.25 } }}, .{})).?.text(a));
    try std.testing.expectEqualStrings("2024-02-29", try (try call(a, "modules.datetime.date.fromordinal", &.{.{ .value = .{ .integer = "738945" } }}, .{})).?.text(a));
    try std.testing.expectEqualStrings("1970-01-01 00:00:00.123456", try (try call(a, "modules.datetime.datetime.utcnow", &.{}, .{ .now_ns = 123456000 })).?.text(a));
    try std.testing.expectEqualStrings("13:04:05.600007", try (try call(a, "modules.datetime.time", &.{ .{ .value = .{ .integer = "13" } }, .{ .value = .{ .integer = "4" } }, .{ .value = .{ .integer = "5" } }, .{ .value = .{ .integer = "600007" } } }, .{})).?.text(a));
    try std.testing.expectEqualStrings("0:00:00.000002", try (try call(a, "modules.datetime.timedelta", &.{.{ .name = "microseconds", .value = .{ .number = 1.5 } }}, .{})).?.text(a));
    try std.testing.expectError(error.JinjaTypeError, call(a, "modules.datetime.date", &.{ .{ .value = .{ .number = 2024 } }, .{ .value = .{ .integer = "1" } }, .{ .value = .{ .integer = "1" } } }, .{}));
    try std.testing.expect(expr.callableName((try resolve(a, "modules.datetime.datetime")).?) != null);
    try std.testing.expect((try resolve(a, "modules.datetime.timezone")).? == .undefined);
}
