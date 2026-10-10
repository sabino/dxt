//! DuckDBPyType equality and dictionary keys use its canonical SQL label.
const std = @import("std");
const Value = @import("expression.zig").Value;
pub fn name(value: Value) ?[]const u8 {
    const marker = value.attribute("__dxt_duck_type");
    if (marker != .callable or !std.mem.eql(u8, marker.callable, "__dxt_duck_type")) return null;
    const shown = value.attribute("__dxt_rendered");
    return if (shown == .string) shown.string else null;
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
