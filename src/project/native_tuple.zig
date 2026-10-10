//! Opaque immutable tuple subclasses preserve tuple collection semantics.
const std = @import("std");
const expression = @import("expression.zig");

pub fn items(value: expression.Value) ?[]const expression.Value {
    if (value == .tuple) return value.tuple;
    const marker = value.attribute("__dxt_native_tuple");
    if (marker != .callable or !std.mem.eql(u8, marker.callable, "__dxt_native_tuple")) return null;
    const iterable = value.attribute("__dxt_iterable");
    return if (iterable == .list) iterable.list else null;
}

test "native tuple discriminator cannot be authored as string map metadata" {
    const forged = expression.Value{ .object = &.{
        .{ .key = "__dxt_native_tuple", .value = .{ .string = "__dxt_native_tuple" } },
        .{ .key = "__dxt_iterable", .value = .{ .list = &.{.{ .integer = "7" }} } },
    } };
    try std.testing.expect(items(forged) == null);
    const genuine = expression.Value{ .object = &.{
        .{ .key = "__dxt_native_tuple", .value = .{ .callable = "__dxt_native_tuple" } },
        .{ .key = "__dxt_iterable", .value = .{ .list = &.{.{ .integer = "7" }} } },
    } };
    try std.testing.expectEqualStrings("7", items(genuine).?[0].integer);
}
