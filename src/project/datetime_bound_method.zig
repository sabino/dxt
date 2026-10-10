//! Builtin method lookup creates a fresh wrapper with an intrinsic receiver.
const std = @import("std");
const expression = @import("expression.zig");
const protocol = @import("datetime_protocol.zig");
const Value = expression.Value;
const Allocator = std.mem.Allocator;
var next_identity: std.atomic.Value(u64) = .init(0);
pub fn isBound(value: Value) bool {
    const tag = value.attribute("__dxt_native_bound_method");
    return tag == .callable and std.mem.eql(u8, tag.callable, "__dxt_native_bound_method");
}
pub fn equal(left: Value, right: Value) bool {
    if (!isBound(left) or !isBound(right)) return false;
    const function_left = left.attribute("__dxt_bound_method_function");
    const function_right = right.attribute("__dxt_bound_method_function");
    const self_left = left.attribute("__dxt_bound_method_self");
    const self_right = right.attribute("__dxt_bound_method_self");
    return function_left == .callable and function_right == .callable and self_left == .string and self_right == .string and std.mem.eql(u8, function_left.callable, function_right.callable) and std.mem.eql(u8, self_left.string, self_right.string);
}
pub fn attribute(a: Allocator, receiver: Value, name: []const u8, direct: Value) !Value {
    if (direct != .callable) return direct;
    const class_id = receiver.attribute("__dxt_class_identity");
    const class_method = class_id == .string and std.mem.startsWith(u8, direct.callable, "__dxt_datetime_class:") and !std.mem.endsWith(u8, direct.callable, ":new");
    const kind = protocol.kind(receiver);
    const genuine_timezone = @import("timezone_context.zig").isTimezone(receiver);
    const builtin_timezone = genuine_timezone and receiver.attribute("__dxt_timezone_builtin").truthy();
    const abstract_timezone = genuine_timezone and @import("datetime_tzinfo.zig").isAbstract(receiver);
    const pytz_class = receiver.attribute("__dxt_timezone_method_class");
    const pytz_method = genuine_timezone and pytz_class == .string and std.mem.startsWith(u8, direct.callable, "__dxt_pytz_method:");
    if (!class_method and kind == null and !builtin_timezone and !abstract_timezone and !pytz_method) return direct;
    const kind_name = if (kind) |temporal_kind| @tagName(temporal_kind) else if (builtin_timezone) "timezone" else "tzinfo";
    const receiver_identity = receiver.attribute("__dxt_immutable_identity");
    const timezone_identity = receiver.attribute("__dxt_timezone_identity");
    const self = if (class_method) class_id.string else if (receiver_identity == .callable) receiver_identity.callable else if (timezone_identity == .string) timezone_identity.string else try std.fmt.allocPrint(a, "datetime.{s}.instance:{x}", .{ kind_name, @intFromPtr(receiver.object.ptr) });
    const pytz_builtin = pytz_method and (std.mem.eql(u8, pytz_class.string, "BaseTzInfo") or (std.mem.eql(u8, pytz_class.string, "_FixedOffset") and std.mem.eql(u8, name, "fromutc")));
    const rendered = if (class_method) try std.fmt.allocPrint(a, "<built-in method {s} of type object at 0x{x}>", .{ name, @intFromPtr(receiver.object.ptr) }) else if (pytz_builtin) try std.fmt.allocPrint(a, "<built-in method {s} of {s} object at 0x{x}>", .{ name, pytz_class.string, @intFromPtr(receiver.object.ptr) }) else if (pytz_method) try std.fmt.allocPrint(a, "<bound method {s}.{s} of {s}>", .{ pytz_class.string, name, try expression.repr(receiver, a) }) else try std.fmt.allocPrint(a, "<built-in method {s} of datetime.{s} object at 0x{x}>", .{ name, kind_name, @intFromPtr(receiver.object.ptr) });
    return .{ .object = try a.dupe(expression.Entry, &.{
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_native_bound_method", .value = .{ .callable = "__dxt_native_bound_method" } },
        .{ .key = "__dxt_immutable_identity", .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_datetime_method_instance:{d}", .{next_identity.fetchAdd(1, .monotonic) + 1}) } },
        .{ .key = "__dxt_bound_method_function", .value = direct },
        .{ .key = "__dxt_bound_method_self", .value = .{ .string = self } },
        .{ .key = "__dxt_callable", .value = direct },
        .{ .key = "__dxt_rendered", .value = .{ .string = rendered } },
    }) };
}

test "lookup yields fresh method wrappers with receiver-based equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dates = @import("timestamp_context.zig");
    const value = try dates.fromYaml(a, "2024-01-01");
    const first = try attribute(a, value, "isoformat", value.attribute("isoformat"));
    const repeated = try attribute(a, value, "isoformat", value.attribute("isoformat"));
    try std.testing.expect(isBound(first));
    try std.testing.expect(equal(first, repeated));
    try std.testing.expect(first.object.ptr != repeated.object.ptr);
    try std.testing.expect(!expression.equalValues(first.attribute("__dxt_immutable_identity"), repeated.attribute("__dxt_immutable_identity")));
    try std.testing.expectEqualStrings("__dxt_datetime", expression.callableName(first).?[0..14]);
    try std.testing.expect((try expression.checkedAttribute(first, "__dxt_bound_method_self")) == .undefined);
    const separate = try dates.fromYaml(a, "2024-01-01");
    const different = try attribute(a, separate, "isoformat", separate.attribute("isoformat"));
    try std.testing.expect(!equal(first, different));
}

test "cloning immutable receivers preserves method-key identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const clock = try @import("datetime_time.zig").value(a, 0, null, 0);
    const duration = try @import("modules_datetime.zig").durationValue(a, 1);
    const zone = try @import("datetime_tzinfo.zig").value(a);
    for ([_]Value{ clock, duration, zone }, [_][]const u8{ "isoformat", "total_seconds", "utcoffset" }) |receiver, name| {
        const copied = try @import("dbt_context.zig").cloneValue(a, receiver);
        const first = try attribute(a, receiver, name, receiver.attribute(name));
        const clone_method = try attribute(a, copied, name, copied.attribute(name));
        try std.testing.expect(isBound(first));
        try std.testing.expect(equal(first, clone_method));
        try std.testing.expect(first.object.ptr != clone_method.object.ptr);
    }
}

test "pytz Python methods use fresh wrappers with stable receiver equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zones = @import("timezone_context.zig");
    const zone = try zones.timezoneValue(a, "UTC", null);
    const first = try attribute(a, zone, "localize", zone.attribute("localize"));
    const repeated = try attribute(a, zone, "localize", zone.attribute("localize"));
    try std.testing.expect(equal(first, repeated));
    try std.testing.expect(first.object.ptr != repeated.object.ptr);
    try std.testing.expectEqualStrings("<bound method UTC.localize of <UTC>>", try first.text(a));
    const date = (try @import("modules_datetime.zig").resolve(a, "modules.datetime.date")).?;
    const datetime = (try @import("modules_datetime.zig").resolve(a, "modules.datetime.datetime")).?;
    try std.testing.expect(expression.equalValues(date.attribute("strftime"), datetime.attribute("strftime")));
    try std.testing.expect(!expression.equalValues(date.attribute("isoformat"), datetime.attribute("isoformat")));
    const holder = Value{ .object = &.{ .{ .key = "__dxt_timezone_builtin", .value = .{ .boolean = true } }, .{ .key = "method", .value = date.attribute("isoformat") } } };
    const descriptor_alias = try expression.attributeWithHost(a, holder, "method", null);
    try std.testing.expect(expression.equalValues(descriptor_alias, date.attribute("isoformat")));
    try std.testing.expectEqualStrings("<method 'isoformat' of 'datetime.date' objects>", try descriptor_alias.text(a));
}
