//! Abstract datetime.tzinfo preserves identity while deferring abstract operations.
const std = @import("std");
const expression = @import("expression.zig");
const dates = @import("timestamp_context.zig");
const Value = expression.Value;
const Allocator = std.mem.Allocator;
var next_identity: std.atomic.Value(u64) = .init(0);
const prefix = "abstract_datetime:";
pub fn isAbstract(zone: Value) bool {
    const identity = zone.attribute("__dxt_timezone_identity");
    return identity == .string and (std.mem.startsWith(u8, identity.string, prefix) or std.mem.startsWith(u8, identity.string, "-2:"));
}
pub fn value(a: Allocator) !Value {
    return fromIdentity(a, try std.fmt.allocPrint(a, "{s}{d}", .{ prefix, next_identity.fetchAdd(1, .monotonic) + 1 }));
}
pub fn fromIdentity(a: Allocator, identity: []const u8) !Value {
    if (!std.mem.startsWith(u8, identity, prefix)) return error.InvalidTimeZone;
    const token = try std.fmt.parseInt(u64, identity[prefix.len..], 10);
    const text = try std.fmt.allocPrint(a, "<datetime.tzinfo object at 0x{x}>", .{token});
    var entries: std.ArrayList(expression.Entry) = .empty;
    try entries.appendSlice(a, &.{
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_timezone_identity", .value = .{ .string = identity } },
        .{ .key = "__dxt_rendered", .value = .{ .string = text } },
        .{ .key = "__dxt_repr", .value = .{ .string = text } },
    });
    for ([_][]const u8{ "utcoffset", "dst", "tzname", "fromutc" }) |method| try entries.append(a, .{ .key = method, .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_datetime_tzinfo:{s}:{s}", .{ method, identity }) } });
    return .{ .object = try entries.toOwnedSlice(a) };
}
pub fn call(a: Allocator, name: []const u8, args: []const expression.Argument) anyerror!?Value {
    _ = a;
    const call_prefix = "__dxt_datetime_tzinfo:";
    if (!std.mem.startsWith(u8, name, call_prefix)) return null;
    if (args.len != 1 or args[0].name != null) return error.InvalidJinjaArguments;
    var parts = std.mem.splitScalar(u8, name[call_prefix.len..], ':');
    const method = parts.next().?;
    if (std.mem.eql(u8, method, "fromutc")) {
        const temporal = dates.state(args[0].value) orelse return error.JinjaTypeError;
        if (temporal.date_only) return error.JinjaTypeError;
        const zone = temporal.timezone orelse return error.InvalidFromUtcTimezone;
        const identity = zone.attribute("__dxt_timezone_identity");
        if (identity != .string or !std.mem.eql(u8, identity.string, parts.rest())) return error.InvalidFromUtcTimezone;
    }
    return error.AbstractTimeZoneMethod;
}

pub fn unbound(a: Allocator, receiver: Value, method: []const u8, args: []const expression.Argument) anyerror!Value {
    if (args.len != 1 or args[0].name != null) return error.InvalidJinjaArguments;
    if (!std.mem.eql(u8, method, "fromutc")) return error.AbstractTimeZoneMethod;
    const state = dates.state(args[0].value) orelse return error.JinjaTypeError;
    if (state.date_only) return error.JinjaTypeError;
    const zone = state.timezone orelse return error.InvalidFromUtcTimezone;
    const identity = receiver.attribute("__dxt_timezone_identity");
    const original = zone.attribute("__dxt_timezone_identity");
    if (identity != .string or original != .string or !std.mem.eql(u8, identity.string, original.string)) return error.InvalidFromUtcTimezone;
    const zones = @import("timezone_context.zig");
    const operations = @import("datetime_operations.zig");
    const offset = operations.duration((try zones.call(a, expression.callableName(receiver.attribute("utcoffset")).?, args)).?) orelse return error.InvalidFromUtcTimezone;
    var dst = operations.duration((try zones.call(a, expression.callableName(receiver.attribute("dst")).?, args)).?) orelse return error.InvalidFromUtcTimezone;
    var current = args[0].value;
    const delta = offset - dst;
    if (delta != 0) {
        current = (try operations.apply(a, "+", current, try @import("modules_datetime.zig").durationValue(a, delta))).?;
        dst = operations.duration((try zones.call(a, expression.callableName(receiver.attribute("dst")).?, &.{.{ .value = current }})).?) orelse return error.InvalidFromUtcTimezone;
    }
    return (try operations.apply(a, "+", current, try @import("modules_datetime.zig").durationValue(a, dst))).?;
}
