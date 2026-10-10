//! Native Python time values, with effective timezone offsets evaluated at None.
const std = @import("std");
const expr = @import("expression.zig");
const zones = @import("timezone_context.zig");
const abstract_zone = @import("datetime_tzinfo.zig");
const strftime = @import("datetime_strftime.zig");
const bind = @import("filter_arguments.zig").bind;
const Value = expr.Value;
const Allocator = std.mem.Allocator;
pub const State = struct { micros: i64, timezone: ?Value, fold: u1, offset_us: ?i64 };
pub fn state(candidate: Value) ?State {
    const marker = candidate.attribute("__dxt_time");
    if (marker != .integer) return null;
    const zone = candidate.attribute("tzinfo");
    const offset = candidate.attribute("__dxt_offset_us");
    return .{ .micros = std.fmt.parseInt(i64, marker.integer, 10) catch return null, .timezone = if (zone == .none) null else zone, .fold = @intCast(expr.integerIndex(candidate.attribute("fold")) catch return null), .offset_us = if (offset == .integer) expr.integerIndex(offset) catch return null else null };
}
fn zoneCall(a: Allocator, timezone: ?Value, method: []const u8) anyerror!Value {
    const zone = timezone orelse return .none;
    const function = expr.callableName(zone.attribute(method)) orelse return error.JinjaTypeError;
    return (try zones.call(a, function, &.{.{ .value = .none }})) orelse error.UnsupportedJinjaCall;
}
fn effectiveOffset(a: Allocator, timezone: ?Value) !?i64 {
    const result = try zoneCall(a, timezone, "utcoffset");
    if (result == .none) return null;
    return @intCast(@import("datetime_operations.zig").duration(result) orelse return error.JinjaTypeError);
}
fn writeOffset(writer: *std.Io.Writer, offset: i64) !void {
    const magnitude = @abs(offset);
    const seconds = magnitude / std.time.us_per_s;
    try writer.print("{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (offset < 0) '-' else '+'), seconds / 3600, seconds / 60 % 60 });
    if (seconds % 60 != 0 or magnitude % std.time.us_per_s != 0) {
        try writer.print(":{d:0>2}", .{seconds % 60});
        if (magnitude % std.time.us_per_s != 0) try writer.print(".{d:0>6}", .{magnitude % std.time.us_per_s});
    }
}
pub fn isoformat(a: Allocator, micros: i64, offset: ?i64, timespec: []const u8) ![]const u8 {
    const spec = if (std.mem.eql(u8, timespec, "auto")) (if (@mod(micros, std.time.us_per_s) == 0) "seconds" else "microseconds") else timespec;
    var writer: std.Io.Writer.Allocating = .init(a);
    try writer.writer.print("{d:0>2}", .{@as(u64, @intCast(@divFloor(micros, std.time.us_per_hour)))});
    if (!std.mem.eql(u8, spec, "hours")) {
        if (!std.mem.eql(u8, spec, "minutes") and !std.mem.eql(u8, spec, "seconds") and !std.mem.eql(u8, spec, "milliseconds") and !std.mem.eql(u8, spec, "microseconds")) return error.InvalidDatetimeTimespec;
        try writer.writer.print(":{d:0>2}", .{@as(u64, @intCast(@divFloor(@mod(micros, std.time.us_per_hour), std.time.us_per_min)))});
        if (!std.mem.eql(u8, spec, "minutes")) try writer.writer.print(":{d:0>2}", .{@as(u64, @intCast(@divFloor(@mod(micros, std.time.us_per_min), std.time.us_per_s)))});
        if (std.mem.eql(u8, spec, "milliseconds")) try writer.writer.print(".{d:0>3}", .{@as(u64, @intCast(@divTrunc(@mod(micros, std.time.us_per_s), 1000)))});
        if (std.mem.eql(u8, spec, "microseconds")) try writer.writer.print(".{d:0>6}", .{@as(u64, @intCast(@mod(micros, std.time.us_per_s)))});
    }
    if (offset) |actual| try writeOffset(&writer.writer, actual);
    return writer.toOwnedSlice();
}
pub fn value(a: Allocator, micros: i64, timezone: ?Value, fold: u1) anyerror!Value {
    if (micros < 0 or micros >= std.time.us_per_day) return error.InvalidDatetime;
    if (timezone) |zone| if (!zones.isTimezone(zone)) return error.JinjaTypeError;
    const abstract = if (timezone) |zone| abstract_zone.isAbstract(zone) else false;
    const offset = if (abstract) null else try effectiveOffset(a, timezone);
    const hour = @divFloor(micros, std.time.us_per_hour);
    const minute = @divFloor(@mod(micros, std.time.us_per_hour), std.time.us_per_min);
    const second = @divFloor(@mod(micros, std.time.us_per_min), std.time.us_per_s);
    const fraction = @mod(micros, std.time.us_per_s);
    var repr: std.Io.Writer.Allocating = .init(a);
    try repr.writer.print("datetime.time({d}, {d}", .{ hour, minute });
    if (second != 0 or fraction != 0) try repr.writer.print(", {d}", .{second});
    if (fraction != 0) try repr.writer.print(", {d}", .{fraction});
    if (timezone) |zone| try repr.writer.print(", tzinfo={s}", .{try expr.repr(zone, a)});
    if (fold != 0) try repr.writer.print(", fold={d}", .{fold});
    try repr.writer.writeByte(')');
    var entries: std.ArrayList(expr.Entry) = .empty;
    try entries.appendSlice(a, &.{
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_temporal_offset_error", .value = if (abstract) .{ .callable = "__dxt_temporal_offset_error" } else .none },
        .{ .key = "__dxt_string_error", .value = .{ .boolean = abstract } },
        .{ .key = "__dxt_time", .value = try expr.integerValue(a, micros) },
        .{ .key = "__dxt_offset_us", .value = if (offset) |actual| try expr.integerValue(a, actual) else .none },
        .{ .key = "__dxt_rendered", .value = .{ .string = try isoformat(a, micros, offset, "auto") } },
        .{ .key = "__dxt_repr", .value = .{ .string = try repr.toOwnedSlice() } },
        .{ .key = "hour", .value = try expr.integerValue(a, hour) },
        .{ .key = "minute", .value = try expr.integerValue(a, minute) },
        .{ .key = "second", .value = try expr.integerValue(a, second) },
        .{ .key = "microsecond", .value = try expr.integerValue(a, fraction) },
        .{ .key = "tzinfo", .value = timezone orelse .none },
        .{ .key = "fold", .value = try expr.integerValue(a, fold) },
    });
    for ([_][]const u8{ "isoformat", "replace", "strftime", "utcoffset", "dst", "tzname" }) |method| try entries.append(a, .{ .key = method, .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_time:{s}:{d}:{d}:{s}", .{ method, micros, fold, if (timezone) |zone| zone.attribute("__dxt_timezone_identity").string else "" }) } });
    return .{ .object = try entries.toOwnedSlice(a) };
}
pub fn call(a: Allocator, name: []const u8, args: []const expr.Argument) anyerror!?Value {
    const prefix = "__dxt_time:";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    var parts = std.mem.splitScalar(u8, name[prefix.len..], ':');
    const method = parts.next() orelse return error.InvalidDatetime;
    const micros = try std.fmt.parseInt(i64, parts.next() orelse return error.InvalidDatetime, 10);
    const fold = try std.fmt.parseInt(u1, parts.next() orelse return error.InvalidDatetime, 10);
    const timezone: ?Value = if (parts.rest().len == 0) null else try zones.fromIdentity(a, parts.rest());
    if (std.mem.eql(u8, method, "replace")) {
        const defaults = [_]Value{ try expr.integerValue(a, @divFloor(micros, std.time.us_per_hour)), try expr.integerValue(a, @divFloor(@mod(micros, std.time.us_per_hour), std.time.us_per_min)), try expr.integerValue(a, @divFloor(@mod(micros, std.time.us_per_min), std.time.us_per_s)), try expr.integerValue(a, @mod(micros, std.time.us_per_s)), timezone orelse .none, try expr.integerValue(a, fold) };
        const bound = try bind(a, args, &.{ "hour", "minute", "second", "microsecond", "tzinfo", "fold" }, &defaults, 0);
        var positions: usize = 0;
        for (args) |argument| if (argument.name == null) {
            positions += 1;
        };
        if (positions > 5) return error.InvalidJinjaArguments;
        const limits = [_]i64{ 23, 59, 59, 999999, 1 };
        var fields: [5]i64 = undefined;
        for ([_]usize{ 0, 1, 2, 3, 5 }, limits, &fields) |index, limit, *field| {
            field.* = try expr.integerIndex(bound[index]);
            if (field.* < 0 or field.* > limit) return error.InvalidDatetime;
        }
        return try value(a, fields[0] * std.time.us_per_hour + fields[1] * std.time.us_per_min + fields[2] * std.time.us_per_s + fields[3], if (bound[4] == .none) null else bound[4], @intCast(fields[4]));
    }
    if (std.mem.eql(u8, method, "isoformat")) {
        const bound = try bind(a, args, &.{"timespec"}, &.{.{ .string = "auto" }}, 0);
        if (bound[0] != .string) return error.JinjaTypeError;
        return .{ .string = try isoformat(a, micros, try effectiveOffset(a, timezone), bound[0].string) };
    }
    if (std.mem.eql(u8, method, "strftime")) {
        const bound = try bind(a, args, &.{"format"}, &.{.undefined}, 1);
        if (bound[0] != .string) return error.JinjaTypeError;
        const requirements = strftime.zoneRequirements(bound[0].string);
        const abbreviation = if (requirements.name) try zoneCall(a, timezone, "tzname") else .none;
        return .{ .string = try strftime.render(a, -2208988800 * @as(i96, std.time.ns_per_s) + @as(i96, micros) * std.time.ns_per_us, bound[0].string, .{ .offset_us = if (requirements.offset) try effectiveOffset(a, timezone) else null, .abbreviation = if (abbreviation == .string) abbreviation.string else null }) };
    }
    if (args.len != 0) return error.InvalidJinjaArguments;
    return try zoneCall(a, timezone, method);
}

test "time strftime requests abstract timezone only for exact zone substitutions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const clock = try value(a, 4500000000, try abstract_zone.value(a), 0);
    const function = clock.attribute("strftime").callable;
    try std.testing.expectEqualStrings("01 000000 %z ", (try call(a, function, &.{.{ .value = .{ .string = "%H %f %%z %_z" } }})).?.string);
    try std.testing.expectError(error.AbstractTimeZoneMethod, call(a, function, &.{.{ .value = .{ .string = "%z" } }}));
    try std.testing.expectError(error.AbstractTimeZoneMethod, call(a, function, &.{.{ .value = .{ .string = "%Z" } }}));
}
