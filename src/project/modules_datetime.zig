//! Native constructors exposed by dbt's restricted datetime module.
const std = @import("std");
const expr = @import("expression.zig");
const dates = @import("timestamp_context.zig");
const calendar = @import("workflow_intervals.zig");
const local_time = @import("native_local_time.zig");
const timezone_context = @import("timezone_context.zig");
const iso_parser = @import("datetime_parse.zig");
const abstract_zone = @import("datetime_tzinfo.zig");
const times = @import("datetime_time.zig");
const operations = @import("datetime_operations.zig");
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
const date_methods = [_][]const u8{ "ctime", "isoformat", "isocalendar", "isoweekday", "replace", "strftime", "timetuple", "toordinal", "weekday" };
const datetime_methods = date_methods ++ [_][]const u8{ "astimezone", "date", "dst", "time", "timestamp", "timetz", "tzname", "utcoffset", "utctimetuple" };
const time_methods = [_][]const u8{ "dst", "isoformat", "replace", "strftime", "tzname", "utcoffset" };
fn instanceMethods(kind: []const u8) []const []const u8 {
    if (std.mem.eql(u8, kind, "date")) return &date_methods;
    if (std.mem.eql(u8, kind, "datetime")) return &datetime_methods;
    if (std.mem.eql(u8, kind, "time")) return &time_methods;
    if (std.mem.eql(u8, kind, "timedelta")) return &.{"total_seconds"};
    if (std.mem.eql(u8, kind, "tzinfo")) return &.{ "utcoffset", "dst", "tzname", "fromutc" };
    return &.{};
}
pub fn instanceClass(value: Value) ?[]const u8 {
    if (dates.state(value)) |state| return if (state.date_only) "date" else "datetime";
    if (times.state(value) != null) return "time";
    if (operations.duration(value) != null) return "timedelta";
    if (timezone_context.isTimezone(value)) return "tzinfo";
    return null;
}
pub fn inheritedAttributeName(kind: []const u8, name: []const u8) bool {
    if (!std.mem.eql(u8, kind, "tzinfo")) for ([_][]const u8{ "min", "max", "resolution" }) |member| if (std.mem.eql(u8, name, member)) return true;
    if (std.mem.eql(u8, kind, "date") or std.mem.eql(u8, kind, "datetime")) {
        for ([_][]const u8{ "today", "fromtimestamp", "fromordinal", "fromisoformat", "fromisocalendar" }) |member| if (std.mem.eql(u8, name, member)) return true;
        if (std.mem.eql(u8, kind, "datetime")) for ([_][]const u8{ "now", "utcnow", "utcfromtimestamp", "strptime", "combine" }) |member| if (std.mem.eql(u8, name, member)) return true;
    }
    return std.mem.eql(u8, kind, "time") and std.mem.eql(u8, name, "fromisoformat");
}
fn descriptor(a: Allocator, kind: []const u8, member: []const u8) !Value {
    const owner = if (std.mem.eql(u8, kind, "datetime") and (std.mem.eql(u8, member, "year") or std.mem.eql(u8, member, "month") or std.mem.eql(u8, member, "day"))) "date" else kind;
    return object(a, &.{
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_class_identity", .value = .{ .string = try std.fmt.allocPrint(a, "datetime.{s}.{s}.descriptor", .{ owner, member }) } },
        .{ .key = "__dxt_rendered", .value = .{ .string = try std.fmt.allocPrint(a, "<{s} '{s}' of 'datetime.{s}' objects>", .{ if (std.mem.eql(u8, kind, "timedelta")) @as([]const u8, "member") else "attribute", member, owner }) } },
    });
}
fn classValue(a: Allocator, kind: []const u8) !Value {
    var entries: std.ArrayList(expr.Entry) = .empty;
    try entries.appendSlice(a, &.{
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_class_identity", .value = .{ .string = try std.fmt.allocPrint(a, "datetime.{s}", .{kind}) } },
        .{ .key = "__dxt_callable", .value = try function(a, kind, "new") },
        .{ .key = "__dxt_rendered", .value = .{ .string = try std.fmt.allocPrint(a, "<class 'datetime.{s}'>", .{kind}) } },
    });
    for (instanceMethods(kind)) |method| try entries.append(a, .{ .key = method, .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_datetime_unbound:{s}:{s}", .{ kind, method }) } });
    const members: []const []const u8 = if (std.mem.eql(u8, kind, "date")) &.{ "year", "month", "day" } else if (std.mem.eql(u8, kind, "datetime")) &.{ "year", "month", "day", "hour", "minute", "second", "microsecond", "tzinfo", "fold" } else if (std.mem.eql(u8, kind, "time")) &.{ "hour", "minute", "second", "microsecond", "tzinfo", "fold" } else if (std.mem.eql(u8, kind, "timedelta")) &.{ "days", "seconds", "microseconds" } else &.{};
    for (members) |member| try entries.append(a, .{ .key = member, .value = try descriptor(a, kind, member) });
    if (std.mem.eql(u8, kind, "date") or std.mem.eql(u8, kind, "datetime")) {
        const date_only = std.mem.eql(u8, kind, "date");
        for ([_][]const u8{ "today", "fromtimestamp", "fromordinal", "fromisoformat", "fromisocalendar" }) |method| try entries.append(a, .{ .key = method, .value = try function(a, kind, method) });
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
            .{ .key = "min", .value = try times.value(a, 0, null, 0) },
            .{ .key = "max", .value = try times.value(a, std.time.us_per_day - 1, null, 0) },
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
        while (parts.next()) |attribute| value = try @import("datetime_bound_method.zig").attribute(a, value, attribute, try expr.checkedAttribute(value, attribute));
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
    if (!timezone_context.isTimezone(value)) return error.JinjaTypeError;
    if (abstract_zone.isAbstract(value)) return null;
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
        return abstract_zone.value(a);
    }
    if (std.mem.eql(u8, kind, "timedelta")) {
        const names = [_][]const u8{ "days", "seconds", "microseconds", "milliseconds", "minutes", "hours", "weeks" };
        var values: [7]Value = @splat(.{ .integer = "0" });
        try bind(args, &names, 0, &@as([7]Value, @splat(.{ .integer = "0" })), &values);
        const scales = [_]i96{ std.time.us_per_day, std.time.us_per_s, 1, 1000, std.time.us_per_min, std.time.us_per_hour, 7 * std.time.us_per_day };
        return operations.constructDuration(a, &values, &scales);
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
    if (time_only) return times.value(a, @intCast(@divFloor(ns, std.time.ns_per_us)), if (values[7] == .none) null else values[7], @intCast(try expr.integerIndex(values[8])));
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

fn durationRepr(a: Allocator, days: i96, seconds: i96, micros: i96) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.writeAll("datetime.timedelta(");
    var present = false;
    for ([_]i96{ days, seconds, micros }, [_][]const u8{ "days", "seconds", "microseconds" }) |value, label| if (value != 0) {
        try out.writer.print("{s}{s}={d}", .{ if (present) @as([]const u8, ", ") else "", label, value });
        present = true;
    };
    if (!present) try out.writer.writeByte('0');
    try out.writer.writeByte(')');
    return out.toOwnedSlice();
}
pub fn durationValue(a: Allocator, micros: i96) !Value {
    if (micros < -999999999 * @as(i96, std.time.us_per_day) or micros >= 1000000000 * @as(i96, std.time.us_per_day)) return error.JinjaNumericOverflow;
    const days = @divFloor(micros, std.time.us_per_day);
    const remainder = @mod(micros, std.time.us_per_day);
    const seconds = @divFloor(remainder, std.time.us_per_s);
    const fraction = @mod(remainder, std.time.us_per_s);
    var text: std.Io.Writer.Allocating = .init(a);
    if (days != 0) try text.writer.print("{s}{d} day{s}, ", .{ if (days < 0) @as([]const u8, "-") else "", @abs(days), if (days == 1 or days == -1) @as([]const u8, "") else "s" });
    try text.writer.print("{d}:{d:0>2}:{d:0>2}", .{ @as(u64, @intCast(@divFloor(seconds, 3600))), @as(u64, @intCast(@divFloor(@mod(seconds, 3600), 60))), @as(u64, @intCast(@mod(seconds, 60))) });
    if (fraction != 0) try text.writer.print(".{d:0>6}", .{@as(u64, @intCast(fraction))});
    return object(a, &.{
        .{ .key = "__dxt_temporal_value", .value = @import("datetime_protocol.zig").marker(.timedelta) },
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_duration", .value = try expr.integerValue(a, micros) },
        .{ .key = "__dxt_repr", .value = .{ .string = try durationRepr(a, days, seconds, fraction) } },
        .{ .key = "__dxt_rendered", .value = .{ .string = try text.toOwnedSlice() } },
        .{ .key = "days", .value = try expr.integerValue(a, days) },
        .{ .key = "seconds", .value = try expr.integerValue(a, seconds) },
        .{ .key = "microseconds", .value = try expr.integerValue(a, fraction) },
        .{ .key = "total_seconds", .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_duration_total:{d}", .{micros}) } },
    });
}
pub fn call(a: Allocator, name: []const u8, args: []const Argument, options: Options) !?Value {
    const unbound_prefix = "__dxt_datetime_unbound:";
    if (std.mem.startsWith(u8, name, unbound_prefix)) {
        var parts = std.mem.splitScalar(u8, name[unbound_prefix.len..], ':');
        const kind = parts.next() orelse return error.JinjaTypeError;
        const method = parts.next() orelse return error.JinjaTypeError;
        if (args.len == 0 or args[0].name != null) return error.InvalidJinjaArguments;
        var receiver = args[0].value;
        const actual_kind = instanceClass(receiver) orelse return error.JinjaTypeError;
        if (!std.mem.eql(u8, kind, actual_kind) and !(std.mem.eql(u8, kind, "date") and std.mem.eql(u8, actual_kind, "datetime"))) return error.JinjaTypeError;
        if (std.mem.eql(u8, kind, "tzinfo")) return try abstract_zone.unbound(a, receiver, method, args[1..]);
        if (std.mem.eql(u8, kind, "date") and std.mem.eql(u8, actual_kind, "datetime") and !std.mem.eql(u8, method, "strftime")) {
            const state = dates.state(receiver).?;
            receiver = try dates.datetimeValue(a, @divFloor(state.civil_ns, std.time.ns_per_day) * std.time.ns_per_day, !std.mem.eql(u8, method, "replace"), null);
            if (std.mem.eql(u8, method, "replace")) for (args[1..], 0..) |arg, position| {
                if (arg.name) |key| {
                    if (!std.mem.eql(u8, key, "year") and !std.mem.eql(u8, key, "month") and !std.mem.eql(u8, key, "day")) return error.InvalidJinjaArguments;
                } else if (position >= 3) return error.InvalidJinjaArguments;
            };
        }
        const bound = expr.callableName(receiver.attribute(method)) orelse return error.JinjaTypeError;
        if (try dates.call(a, bound, args[1..])) |value| return value;
        return call(a, bound, args[1..], options);
    }
    if (std.mem.startsWith(u8, name, "__dxt_duration_total:")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        const micros = try std.fmt.parseInt(i96, name[21..], 10);
        return .{ .number = try @import("expression_number.zig").divide(a, try std.fmt.allocPrint(a, "{d}", .{micros}), "1000000") };
    }
    if (try times.call(a, name, args)) |result| return result;
    if (try abstract_zone.call(a, name, args)) |result| return result;
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
        if (date_only or utc) for (args) |arg| {
            if (arg.name != null) return error.InvalidJinjaArguments;
        };
        try bind(args, if (date_only or utc) &.{"timestamp"} else &.{ "timestamp", "tz" }, 1, if (date_only or utc) values[0..1] else &values, if (date_only or utc) values[0..1] else &values);
        const seconds = try expr.numericFloat(values[0]);
        if (!std.math.isFinite(seconds) or @abs(seconds) > 4e11) return error.JinjaNumericOverflow;
        // A date uses the containing whole second; datetime's rounded
        // microseconds must not carry its date into the following day.
        if (date_only) return try fromInstant(a, @as(i96, @intFromFloat(@floor(seconds))) * std.time.ns_per_s, true, .none, false);
        // CPython splits seconds before rounding the fractional microseconds;
        // multiplying the whole timestamp would lose fractional precision.
        const integral = @trunc(seconds);
        const fractional = (seconds - integral) * std.time.us_per_s;
        var rounded = @floor(fractional);
        const fraction = fractional - rounded;
        if (fraction > 0.5 or (fraction == 0.5 and @mod(@as(i64, @intFromFloat(rounded)), 2) != 0)) rounded += 1;
        const ns = @as(i96, @intFromFloat(integral)) * std.time.ns_per_s + @as(i96, @intFromFloat(rounded)) * std.time.ns_per_us;
        return try fromInstant(a, ns, date_only, values[1], utc);
    }
    if (std.mem.eql(u8, method, "strptime")) {
        if (args.len != 2 or args[0].name != null or args[1].name != null) return error.InvalidJinjaArguments;
        if (args[0].value != .string or args[1].value != .string) return error.JinjaTypeError;
        const parsed = try @import("datetime_strptime.zig").parse(a, args[0].value.string, args[1].value.string);
        const zone: ?Value = if (parsed.offset_us) |offset| try timezone_context.builtinValue(a, offset, parsed.zone_name) else null;
        return try dates.datetimeValueWithOffsetUs(a, parsed.civil_ns, false, parsed.offset_us, zone, 0);
    }
    if (std.mem.eql(u8, method, "fromisoformat")) {
        if (args.len != 1 or args[0].name != null) return error.InvalidJinjaArguments;
        if (args[0].value != .string) return error.JinjaTypeError;
        const parsed = if (std.mem.eql(u8, kind, "time")) try iso_parser.time(args[0].value.string) else try iso_parser.iso(a, args[0].value.string, date_only);
        const zone: ?Value = if (parsed.offset_us) |offset| try timezone_context.builtinValue(a, offset, null) else null;
        if (std.mem.eql(u8, kind, "time")) return try times.value(a, @intCast(@divFloor(parsed.civil_ns, std.time.ns_per_us)), zone, 0);
        return try dates.datetimeValueWithOffsetUs(a, parsed.civil_ns, date_only, parsed.offset_us, zone, 0);
    }
    if (std.mem.eql(u8, method, "fromisocalendar")) {
        const bound = try @import("filter_arguments.zig").bind(a, args, &.{ "year", "week", "day" }, &.{ .undefined, .undefined, .undefined }, 3);
        return try dates.datetimeValue(a, try iso_parser.isoCalendar(a, try expr.integerIndex(bound[0]), try expr.integerIndex(bound[1]), try expr.integerIndex(bound[2])), date_only, null);
    }
    if (std.mem.eql(u8, method, "combine")) {
        const bound = try @import("filter_arguments.zig").bind(a, args, &.{ "date", "time", "tzinfo" }, &.{ .undefined, .undefined, .undefined }, 2);
        const day = dates.state(bound[0]) orelse return error.JinjaTypeError;
        const clock = times.state(bound[1]) orelse return error.JinjaTypeError;
        const zone: ?Value = if (bound[2] == .undefined) clock.timezone else if (bound[2] == .none) null else bound[2];
        return try dates.datetimeValueWithOffsetUs(a, @divFloor(day.civil_ns, std.time.ns_per_day) * std.time.ns_per_day + @as(i96, clock.micros) * std.time.ns_per_us, false, if (zone) |actual| try timezoneOffsetUs(actual) else null, zone, clock.fold);
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
    try std.testing.expect(abstract_zone.isAbstract((try call(a, "modules.datetime.tzinfo", &.{ .{ .value = .{ .integer = "1" } }, .{ .name = "extra", .value = .none } }, .{})).?));
    const dt = (try call(a, "modules.datetime.datetime", &.{ .{ .value = .{ .integer = "2024" } }, .{ .value = .{ .integer = "2" } }, .{ .value = .{ .integer = "29" } }, .{ .value = .{ .integer = "13" } } }, .{})).?;
    try std.testing.expectEqualStrings("2024-02-29 13:00:00", try dt.text(a));
    try std.testing.expectEqualStrings("1969-12-31 23:59:59.750000", try (try call(a, "modules.datetime.datetime.fromtimestamp", &.{.{ .value = .{ .number = -0.25 } }}, .{})).?.text(a));
    try std.testing.expectEqualStrings("1969-12-31", try (try call(a, "modules.datetime.date.fromtimestamp", &.{.{ .value = .{ .number = -0.0000001 } }}, .{})).?.text(a));
    try std.testing.expectEqualStrings("1970-01-01", try (try call(a, "modules.datetime.date.fromtimestamp", &.{.{ .value = .{ .number = 86399.9999999 } }}, .{})).?.text(a));
    try std.testing.expectEqualStrings("2024-02-29", try (try call(a, "modules.datetime.date.fromordinal", &.{.{ .value = .{ .integer = "738945" } }}, .{})).?.text(a));
    try std.testing.expectEqualStrings("1970-01-01 00:00:00.123456", try (try call(a, "modules.datetime.datetime.utcnow", &.{}, .{ .now_ns = 123456000 })).?.text(a));
    const huge_duration = try durationValue(a, 999999999 * @as(i96, std.time.us_per_day));
    try std.testing.expectEqual(@as(f64, 86399999913600.0), (try call(a, huge_duration.attribute("total_seconds").callable, &.{}, .{})).?.number);
    for ([_]f64{ 0.0000005, 0.0000015, -0.0000005, -0.0000015, 1.0000005, 1.0000015 }, [_][]const u8{ "1970-01-01 00:00:00", "1970-01-01 00:00:00.000002", "1970-01-01 00:00:00", "1969-12-31 23:59:59.999998", "1970-01-01 00:00:01.000001", "1970-01-01 00:00:01.000001" }) |instant, expected| try std.testing.expectEqualStrings(expected, try (try call(a, "modules.datetime.datetime.utcfromtimestamp", &.{.{ .value = .{ .number = instant } }}, .{})).?.text(a));
    try std.testing.expectEqualStrings("13:04:05.600007", try (try call(a, "modules.datetime.time", &.{ .{ .value = .{ .integer = "13" } }, .{ .value = .{ .integer = "4" } }, .{ .value = .{ .integer = "5" } }, .{ .value = .{ .integer = "600007" } } }, .{})).?.text(a));
    try std.testing.expectEqualStrings("0:00:00.000002", try (try call(a, "modules.datetime.timedelta", &.{.{ .name = "microseconds", .value = .{ .number = 1.5 } }}, .{})).?.text(a));
    try std.testing.expectError(error.JinjaTypeError, call(a, "modules.datetime.date", &.{ .{ .value = .{ .number = 2024 } }, .{ .value = .{ .integer = "1" } }, .{ .value = .{ .integer = "1" } } }, .{}));
    try std.testing.expect(expr.callableName((try resolve(a, "modules.datetime.datetime")).?) != null);
    try std.testing.expect((try resolve(a, "modules.datetime.timezone")).? == .undefined);
}

test "native datetime descriptors preserve inherited and base class semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ns = @as(i96, try calendar.parseTimestamp("2024-01-01 12:34:56")) * std.time.ns_per_s;
    const moment = try dates.datetimeValue(a, ns, false, 0);
    const dt_class = (try resolve(a, "modules.datetime.datetime")).?;
    try std.testing.expect(dt_class.attribute("year") != .undefined);
    try std.testing.expectEqualStrings("<attribute 'year' of 'datetime.date' objects>", try dt_class.attribute("year").text(a));
    try std.testing.expectEqualStrings("2024-01-01T12:34:56+00:00", (try call(a, dt_class.attribute("isoformat").callable, &.{.{ .value = moment }}, .{})).?.string);
    try std.testing.expectEqualStrings("2024-01-01", (try call(a, "__dxt_datetime_unbound:date:isoformat", &.{.{ .value = moment }}, .{})).?.string);
    try std.testing.expectEqualStrings("Mon Jan  1 00:00:00 2024", (try call(a, "__dxt_datetime_unbound:date:ctime", &.{.{ .value = moment }}, .{})).?.string);
    const tuple = (try call(a, "__dxt_datetime_unbound:date:timetuple", &.{.{ .value = moment }}, .{})).?;
    try std.testing.expectEqual(@as(i64, 0), try expr.integerIndex(tuple.attribute("tm_hour")));
    const replaced = (try call(a, "__dxt_datetime_unbound:date:replace", &.{ .{ .value = moment }, .{ .name = "year", .value = .{ .integer = "2023" } } }, .{})).?;
    try std.testing.expect(!dates.state(replaced).?.date_only);
    try std.testing.expectEqualStrings("2023-01-01 00:00:00", try replaced.text(a));
    try std.testing.expectError(error.InvalidJinjaArguments, call(a, "__dxt_datetime_unbound:date:replace", &.{ .{ .value = moment }, .{ .name = "hour", .value = .{ .integer = "1" } } }, .{}));
    try std.testing.expectError(error.JinjaTypeError, call(a, "__dxt_datetime_unbound:datetime:isoformat", &.{.{ .value = try dates.datetimeValue(a, ns, true, null) }}, .{}));
    const first = try expr.attributeWithHost(a, moment, "fromordinal", null);
    try std.testing.expectEqualStrings("0001-01-01 00:00:00", try (try call(a, expr.callableName(first).?, &.{.{ .value = .{ .integer = "1" } }}, .{})).?.text(a));
}

test "inherited datetime extrema use intrinsic render cache despite authored modules shadow" {
    const Fixture = struct {
        cache: @import("modules_context.zig").Cache = .{},
        fn resolve(context: *anyopaque, path: []const u8, a: Allocator) anyerror!Value {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.mem.startsWith(u8, path, "__dxt_modules.")) return (try @import("modules_context.zig").resolveCached(a, path[6..], &self.cache)).?;
            return .undefined;
        }
        fn invoke(_: *anyopaque, _: []const u8, _: []const Argument, _: Allocator) anyerror!Value {
            return error.UnsupportedJinjaCall;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture: Fixture = .{};
    const host: expr.Host = .{ .context = &fixture, .resolve = Fixture.resolve, .call = Fixture.invoke };
    const moment = try dates.datetimeValue(a, 0, false, null);
    const first = try expr.attributeWithHost(a, moment, "min", host);
    const next = (try @import("modules_context.zig").resolveCached(a, "modules.datetime.datetime.min", &fixture.cache)).?;
    try std.testing.expectEqual(first.object.ptr, next.object.ptr);
    try std.testing.expect((try expr.attributeWithHost(a, moment, "not_an_attribute", host)) == .undefined);
}

test "native timedeltas retain exact integer range rounding and datetime arithmetic" {
    const Fixture = struct {
        fn resolve(_: *anyopaque, name: []const u8, a: Allocator) !Value {
            return (try @import("modules_context.zig").resolve(a, name)) orelse .undefined;
        }
        fn call(context: *anyopaque, name: []const u8, args: []const Argument, a: Allocator) !Value {
            const host = expr.Host{ .context = context, .resolve = @This().resolve, .call = @This().call };
            return (try @import("modules_context.zig").call(a, name, args, .{ .host = host })) orelse (try dates.call(a, name, args)) orelse error.UnsupportedJinjaCall;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture: u8 = 0;
    const host = expr.Host{ .context = &fixture, .resolve = Fixture.resolve, .call = Fixture.call };
    const cases = [_][2][]const u8{
        .{ "modules.datetime.timedelta(days=999999999,microseconds=999999)", "999999999 days, 0:00:00.999999" },
        .{ "modules.datetime.timedelta(microseconds=-1.5)", "-1 day, 23:59:59.999998" },
        .{ "modules.datetime.timedelta(microseconds=3)*0.5", "0:00:00.000002" },
        .{ "modules.datetime.timedelta(microseconds=5)/2", "0:00:00.000002" },
        .{ "modules.datetime.timedelta(microseconds=-5)//2", "-1 day, 23:59:59.999997" },
        .{ "modules.datetime.timedelta(microseconds=-5)%modules.datetime.timedelta(microseconds=2)", "0:00:00.000001" },
        .{ "modules.datetime.datetime(2020,2,28,23,59,59)+modules.datetime.timedelta(seconds=2)", "2020-02-29 00:00:01" },
        .{ "modules.datetime.date(2020,3,1)-modules.datetime.timedelta(microseconds=1)", "2020-03-01" },
        .{ "modules.datetime.datetime(2020,2,29)-modules.datetime.datetime(2020,2,28)", "1 day, 0:00:00" },
        .{ "modules.datetime.timedelta(microseconds=3)/modules.datetime.timedelta(microseconds=2)", "1.5" },
        .{ "-modules.datetime.timedelta(seconds=2)", "-1 day, 23:59:58" },
        .{ "[modules.datetime.timedelta(microseconds=1)]", "[datetime.timedelta(microseconds=1)]" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case[1], try (try expr.evaluate(a, case[0], host)).text(a));
    try std.testing.expect(!(try call(a, "modules.datetime.timedelta", &.{}, .{})).?.truthy());
    try std.testing.expectError(error.JinjaNumericOverflow, expr.evaluate(a, "modules.datetime.timedelta.max+modules.datetime.timedelta.resolution", host));
    try std.testing.expectError(error.JinjaDivisionByZero, expr.evaluate(a, "modules.datetime.timedelta(seconds=1)/0", host));
}

test "native ISO constructors and full time methods preserve zones and exact offsets" {
    const Fixture = struct {
        fn resolve(_: *anyopaque, name: []const u8, a: Allocator) !Value {
            return (try @import("modules_context.zig").resolve(a, name)) orelse .undefined;
        }
        fn call(context: *anyopaque, name: []const u8, args: []const Argument, a: Allocator) !Value {
            return (try @import("modules_context.zig").call(a, name, args, .{ .host = .{ .context = context, .resolve = @This().resolve, .call = @This().call } })) orelse (try dates.call(a, name, args)) orelse error.UnsupportedJinjaCall;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture: u8 = 0;
    const host = expr.Host{ .context = &fixture, .resolve = Fixture.resolve, .call = Fixture.call };
    const cases = [_][2][]const u8{
        .{ "modules.datetime.date.fromisoformat('2024W011')", "2024-01-01" },
        .{ "modules.datetime.datetime.fromisoformat('20240229🐍120405,123456789+05:30:45.678901')", "2024-02-29 12:04:05.123456+05:30:45.678901" },
        .{ "modules.datetime.datetime.fromisocalendar(2020,53,7)", "2021-01-03 00:00:00" },
        .{ "modules.datetime.time.fromisoformat('T120405.123456+00:99').isoformat(timespec='milliseconds')", "12:04:05.123+01:39" },
        .{ "modules.datetime.time(1,2,3,4,tzinfo=modules.pytz.utc,fold=1).replace(hour=4).strftime('%H:%M:%S.%f %z %Z')", "04:02:03.000004 +0000 UTC" },
        .{ "modules.datetime.time(1,tzinfo=modules.pytz.timezone('America/New_York')).utcoffset()", "None" },
        .{ "modules.datetime.time(1,tzinfo=modules.pytz.utc).tzinfo is sameas modules.pytz.utc", "True" },
        .{ "modules.datetime.time(1,tzinfo=modules.pytz.FixedOffset(60)) == modules.datetime.time(0,tzinfo=modules.pytz.utc)", "True" },
        .{ "modules.datetime.datetime.combine(modules.datetime.date(2024,2,29),modules.datetime.time(1,2,3,tzinfo=modules.pytz.utc,fold=1))", "2024-02-29 01:02:03+00:00" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case[1], try (try expr.evaluate(a, case[0], host)).text(a));
    try std.testing.expectError(error.InvalidDatetime, expr.evaluate(a, "modules.datetime.date.fromisoformat('2023-W53')", host));
    try std.testing.expectError(error.InvalidJinjaArguments, expr.evaluate(a, "modules.datetime.date.fromtimestamp(timestamp=0)", host));
}

test "abstract timezone constructors defer offset errors while preserving identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zone = try abstract_zone.value(a);
    const other = try abstract_zone.value(a);
    try std.testing.expect(!expr.equalValues(zone, other));
    try std.testing.expect(expr.equalValues(zone, try abstract_zone.fromIdentity(a, zone.attribute("__dxt_timezone_identity").string)));
    const clock = try times.value(a, 0, zone, 1);
    try std.testing.expect(clock.truthy());
    try std.testing.expectError(error.JinjaTypeError, clock.text(a));
    try std.testing.expectError(error.AbstractTimeZoneMethod, times.call(a, clock.attribute("utcoffset").callable, &.{}));
    const moment = try dates.datetimeValueWithOffsetUs(a, 0, false, null, zone, 1);
    try std.testing.expect(moment.truthy());
    try std.testing.expectEqualStrings("Thu Jan  1 00:00:00 1970", (try dates.call(a, moment.attribute("ctime").callable, &.{})).?.string);
    try std.testing.expectError(error.AbstractTimeZoneMethod, dates.call(a, moment.attribute("isoformat").callable, &.{}));
    try std.testing.expect(operations.offsetError(moment));
    try std.testing.expectError(error.AbstractTimeZoneMethod, operations.validateComparison(moment, try dates.datetimeValue(a, 0, false, null)));
    try std.testing.expectError(error.JinjaTypeError, call(a, "modules.datetime.datetime", &.{ .{ .value = .{ .integer = "2024" } }, .{ .value = .{ .integer = "1" } }, .{ .value = .{ .integer = "1" } }, .{ .name = "tzinfo", .value = .{ .object = &.{.{ .key = "__dxt_timezone_offset_us", .value = .{ .integer = "0" } }} } } }, .{}));
}
