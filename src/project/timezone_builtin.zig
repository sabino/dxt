//! Genuine fixed datetime.timezone values returned by native datetime parsing.
const std = @import("std");
const expr = @import("expression.zig");
const dates = @import("timestamp_context.zig");
const timezones = @import("timezone_context.zig");
const Value = expr.Value;
const Argument = expr.Argument;
const Allocator = std.mem.Allocator;
var next_identity: std.atomic.Value(u64) = .init(1);
const State = struct { offset_us: i64, identity: u64, name: []const u8 };
fn offsetName(a: Allocator, offset_us: i64) ![]const u8 {
    if (offset_us == 0) return "UTC";
    const total = @abs(offset_us);
    const seconds = total / std.time.us_per_s;
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.print("UTC{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (offset_us < 0) '-' else '+'), seconds / 3600, (seconds % 3600) / 60 });
    const fraction = total % std.time.us_per_s;
    if (seconds % 60 != 0 or fraction != 0) {
        try out.writer.print(":{d:0>2}", .{seconds % 60});
        if (fraction != 0) try out.writer.print(".{d:0>6}", .{fraction});
    }
    return out.toOwnedSlice();
}
fn representation(a: Allocator, state: State) ![]const u8 {
    if (state.identity == 0) return "datetime.timezone.utc";
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.writeAll("datetime.timezone(datetime.timedelta(");
    const days = @divFloor(state.offset_us, std.time.us_per_day);
    const seconds = @divFloor(@mod(state.offset_us, std.time.us_per_day), std.time.us_per_s);
    const micros = @mod(state.offset_us, std.time.us_per_s);
    var any = false;
    if (days != 0) {
        try out.writer.print("days={d}", .{days});
        any = true;
    }
    if (seconds != 0) {
        try out.writer.print("{s}seconds={d}", .{ if (any) @as([]const u8, ", ") else "", seconds });
        any = true;
    }
    if (micros != 0) {
        try out.writer.print("{s}microseconds={d}", .{ if (any) @as([]const u8, ", ") else "", micros });
        any = true;
    }
    if (!any) try out.writer.writeByte('0');
    try out.writer.writeByte(')');
    // Identity high bit records whether the Python constructor supplied a name.
    if (state.identity & (@as(u64, 1) << 63) != 0) try out.writer.print(", {s}", .{try expr.repr(.{ .string = state.name }, a)});
    try out.writer.writeByte(')');
    return out.toOwnedSlice();
}
fn object(a: Allocator, state: State) !Value {
    if (@abs(state.offset_us) >= std.time.us_per_day) return error.InvalidTimeZoneOffset;
    const encoded = try std.fmt.allocPrint(a, "builtin:{d}:{d}:{s}", .{ state.offset_us, state.identity, state.name });
    var entries: std.ArrayList(expr.Entry) = .empty;
    try entries.appendSlice(a, &.{
        .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_rendered", .value = .{ .string = state.name } },
        .{ .key = "__dxt_repr", .value = .{ .string = try representation(a, state) } },
        .{ .key = "__dxt_timezone_builtin", .value = .{ .boolean = true } },
        .{ .key = "__dxt_timezone_offset", .value = try expr.integerValue(a, @divTrunc(state.offset_us, std.time.us_per_min)) },
        .{ .key = "__dxt_timezone_offset_us", .value = try expr.integerValue(a, state.offset_us) },
        .{ .key = "__dxt_timezone_dst_us", .value = .none },
        .{ .key = "__dxt_timezone_name", .value = .{ .string = state.name } },
        .{ .key = "__dxt_timezone_abbreviation", .value = .{ .string = state.name } },
        .{ .key = "__dxt_timezone_identity", .value = .{ .string = encoded } },
    });
    for ([_][]const u8{ "utcoffset", "dst", "tzname", "fromutc" }) |method| try entries.append(a, .{ .key = method, .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_builtin_timezone:{s}:{s}", .{ method, encoded }) } });
    return .{ .object = try entries.toOwnedSlice(a) };
}
pub fn value(a: Allocator, offset_us: i64, name: ?[]const u8) !Value {
    return object(a, .{
        .offset_us = offset_us,
        .identity = if (name != null) next_identity.fetchAdd(1, .monotonic) | (@as(u64, 1) << 63) else if (offset_us == 0) 0 else next_identity.fetchAdd(1, .monotonic),
        .name = name orelse try offsetName(a, offset_us),
    });
}
fn decode(encoded: []const u8) !State {
    if (!std.mem.startsWith(u8, encoded, "builtin:")) return error.InvalidTimeZone;
    var parts = std.mem.splitScalar(u8, encoded[8..], ':');
    return .{
        .offset_us = try std.fmt.parseInt(i64, parts.next() orelse return error.InvalidTimeZone, 10),
        .identity = try std.fmt.parseInt(u64, parts.next() orelse return error.InvalidTimeZone, 10),
        .name = parts.rest(),
    };
}
pub fn fromIdentity(a: Allocator, encoded: []const u8) !Value {
    return object(a, try decode(encoded));
}
pub fn call(a: Allocator, name: []const u8, args: []const Argument) anyerror!?Value {
    const prefix = "__dxt_builtin_timezone:";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    if (args.len != 1 or args[0].name != null) return error.InvalidJinjaArguments;
    var parts = std.mem.splitScalar(u8, name[prefix.len..], ':');
    const method = parts.next().?;
    const state = try decode(parts.rest());
    const dt = args[0].value;
    const temporal = if (dt == .none) null else dates.state(dt) orelse return error.JinjaTypeError;
    if (temporal) |fields| if (fields.date_only) return error.JinjaTypeError;
    if (std.mem.eql(u8, method, "utcoffset")) return try timezones.durationValue(a, state.offset_us);
    if (std.mem.eql(u8, method, "dst")) return .none;
    if (std.mem.eql(u8, method, "tzname")) return .{ .string = state.name };
    if (!std.mem.eql(u8, method, "fromutc")) return error.UndefinedJinjaValue;
    const fields = temporal orelse return error.JinjaTypeError;
    const actual = fields.timezone orelse return error.InvalidFromUtcTimezone;
    const encoded = actual.attribute("__dxt_timezone_identity");
    if (encoded != .string or !std.mem.eql(u8, encoded.string, parts.rest())) return error.InvalidFromUtcTimezone;
    return try dates.attachTimezone(a, fields.civil_ns + @as(i96, state.offset_us) * std.time.ns_per_us, actual);
}

test "native datetime timezone values preserve fixed offsets representations and instance identity" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const utc = try value(a, 0, null);
    try std.testing.expectEqualStrings("datetime.timezone.utc", try expr.repr(utc, a));
    const fixed = try value(a, -330000000, null);
    try std.testing.expectEqualStrings("UTC-00:05:30", try fixed.text(a));
    try std.testing.expectEqualStrings("datetime.timezone(datetime.timedelta(days=-1, seconds=86070))", try expr.repr(fixed, a));
    const named = try value(a, 0, "UTC");
    try std.testing.expectEqualStrings("datetime.timezone(datetime.timedelta(0), 'UTC')", try expr.repr(named, a));
    const dt = try dates.attachTimezone(a, 0, fixed);
    try std.testing.expect((try call(a, fixed.attribute("dst").callable, &.{.{ .value = dt }})).? == .none);
    try std.testing.expectEqualStrings("-1 day, 23:54:30", try (try call(a, fixed.attribute("utcoffset").callable, &.{.{ .value = .none }})).?.text(a));
    try std.testing.expectError(error.JinjaTypeError, call(a, fixed.attribute("utcoffset").callable, &.{.{ .value = .{ .integer = "1" } }}));
    try std.testing.expectEqualStrings(fixed.attribute("__dxt_timezone_identity").string, (try fromIdentity(a, fixed.attribute("__dxt_timezone_identity").string)).attribute("__dxt_timezone_identity").string);
}
