//! DuckDBPyType equality and dictionary keys use its canonical SQL label.
const std = @import("std");
pub fn notImplemented(a: std.mem.Allocator) !@import("expression.zig").Value {
    return .{ .object = try a.dupe(@import("expression.zig").Entry, &.{
        .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_rendered", .value = .{ .string = "NotImplemented" } },
        .{ .key = "__dxt_repr", .value = .{ .string = "NotImplemented" } },
        .{ .key = "__dxt_not_implemented", .value = .{ .callable = "__dxt_not_implemented" } },
    }) };
}
const Value = @import("expression.zig").Value;
pub fn name(value: Value) ?[]const u8 {
    const marker = value.attribute("__dxt_duck_type");
    if (marker != .callable or !std.mem.eql(u8, marker.callable, "__dxt_duck_type")) return null;
    const shown = value.attribute("__dxt_rendered");
    return if (shown == .string) shown.string else null;
}
pub fn child(value: Value, key: []const u8) !Value {
    if (name(value) == null) return error.QueryTypeChildNotFound;
    const children = value.attribute("children");
    if (children == .list) for (children.list) |entry| {
        if (entry == .tuple and entry.tuple.len == 2 and entry.tuple[0] == .string and std.mem.eql(u8, key, entry.tuple[0].string)) return entry.tuple[1];
    };
    return error.QueryTypeChildNotFound;
}

test "DuckDB nested type lookup uses exact declared child names" {
    const integer: Value = .{ .object = &.{
        .{ .key = "__dxt_duck_type", .value = .{ .callable = "__dxt_duck_type" } },
        .{ .key = "__dxt_rendered", .value = .{ .string = "INTEGER" } },
    } };
    const structure: Value = .{ .object = &.{
        .{ .key = "__dxt_duck_type", .value = .{ .callable = "__dxt_duck_type" } },
        .{ .key = "__dxt_rendered", .value = .{ .string = "STRUCT(x INTEGER)" } },
        .{ .key = "children", .value = .{ .list = &.{.{ .tuple = &.{ .{ .string = "x" }, integer } }} } },
    } };
    try std.testing.expectEqualStrings("INTEGER", name(try child(structure, "x")).?);
    try std.testing.expectError(error.QueryTypeChildNotFound, child(structure, "X"));
    try std.testing.expectError(error.QueryTypeChildNotFound, child(integer, "id"));
}
pub fn equal(lhs: Value, rhs: Value) ?bool {
    const left = name(lhs);
    const right = name(rhs);
    if (left == null and right == null) return null;
    const lhs_text = left orelse if (lhs == .string) lhs.string else return false;
    const rhs_text = right orelse if (rhs == .string) rhs.string else return false;
    return std.ascii.eqlIgnoreCase(lhs_text, rhs_text);
}
pub fn keyEqual(lhs: Value, rhs: Value) ?bool {
    const left = name(lhs);
    const right = name(rhs);
    if (left == null and right == null) return null;
    const lhs_text = left orelse if (lhs == .string) lhs.string else return false;
    const rhs_text = right orelse if (rhs == .string) rhs.string else return false;
    // Python hashes a DuckDBPyType using ToString(), even though equality to
    // a string ignores case. Lowercase strings therefore miss these keys.
    return std.mem.eql(u8, lhs_text, rhs_text);
}

test "DuckDB type equality retains the distinct Python dictionary hash contract" {
    const value: Value = .{ .object = &.{
        .{ .key = "__dxt_duck_type", .value = .{ .callable = "__dxt_duck_type" } },
        .{ .key = "__dxt_rendered", .value = .{ .string = "INTEGER" } },
    } };
    try std.testing.expect(equal(value, .{ .string = "integer" }).?);
    try std.testing.expect(!equal(value, .{ .string = "INT" }).?);
    try std.testing.expect(keyEqual(value, .{ .string = "INTEGER" }).?);
    try std.testing.expect(!keyEqual(value, .{ .string = "integer" }).?);
    const forged: Value = .{ .object = &.{.{ .key = "__dxt_duck_type", .value = .{ .string = "__dxt_duck_type" } }} };
    try std.testing.expect(name(forged) == null);
}
