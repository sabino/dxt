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
    if (!class_method and kind == null) return direct;
    const receiver_identity = receiver.attribute("__dxt_immutable_identity");
    const self = if (class_method) class_id.string else if (receiver_identity == .callable) receiver_identity.callable else try std.fmt.allocPrint(a, "datetime.{s}.instance:{x}", .{ @tagName(kind.?), @intFromPtr(receiver.object.ptr) });
    const rendered = if (class_method) try std.fmt.allocPrint(a, "<built-in method {s} of type object at 0x{x}>", .{ name, @intFromPtr(receiver.object.ptr) }) else try std.fmt.allocPrint(a, "<built-in method {s} of datetime.{s} object at 0x{x}>", .{ name, @tagName(kind.?), @intFromPtr(receiver.object.ptr) });
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
