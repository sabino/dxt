//! Jinja dictionary keys retain their native values. String context objects
//! share the same Entry representation without converting user keys to text.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const Entry = expression.Entry;

pub fn key(item: Entry) Value {
    return item.typed_key orelse .{ .string = item.key };
}

pub fn matches(item: Entry, candidate: Value) bool {
    return keyEqual(key(item), candidate);
}

pub fn entry(container: Value, candidate: Value) anyerror!?Entry {
    try hashable(candidate);
    if (container != .object) return error.JinjaTypeError;
    for (container.object) |item| if (matches(item, candidate)) return item;
    return null;
}

pub fn create(candidate: Value, value: Value) anyerror!Entry {
    try hashable(candidate);
    return if (candidate == .string)
        Entry{ .key = candidate.string, .value = value }
    else
        Entry{ .key = "", .typed_key = candidate, .value = value };
}

pub fn hashable(candidate: Value) anyerror!void {
    return checkHashable(candidate, 0);
}

fn checkHashable(candidate: Value, depth: usize) anyerror!void {
    if (depth > 128) return error.JinjaExpressionDepthExceeded;
    if (expression.integerProtocol(candidate) != null) return;
    switch (candidate) {
        .none,
        .boolean,
        .integer,
        .number,
        .complex,
        .string,
        .callable,
        .undefined,
        .conditional_undefined,
        => {},
        .tuple => |items| for (items) |item| try checkHashable(item, depth + 1),
        .object => {
            // BaseRelation is immutable and implements hash(render()). The
            // native serialized definition supplies its complete equality
            // identity, including policies and adapter-specific attributes.
            if (candidate.attribute("__dxt_relation") != .string) return error.JinjaTypeError;
        },
        else => return error.JinjaTypeError,
    }
}

pub fn keyEqual(left: Value, right: Value) bool {
    if (left == .object or right == .object) {
        if (expression.integerProtocol(left) != null or expression.integerProtocol(right) != null)
            return expression.equalValues(left, right);
        const relation_left = left.attribute("__dxt_relation");
        const relation_right = right.attribute("__dxt_relation");
        return relation_left == .string and relation_right == .string and
            std.mem.eql(u8, relation_left.string, relation_right.string);
    }
    if (left == .tuple and right == .tuple) {
        if (left.tuple.len != right.tuple.len) return false;
        for (left.tuple, right.tuple) |a, b| if (!keyEqual(a, b)) return false;
        return true;
    }
    return expression.equalValues(left, right);
}

test "dictionary numeric and tuple keys preserve Python equality" {
    const boolean = try create(.{ .boolean = true }, .none);
    try std.testing.expect(matches(boolean, .{ .integer = "1" }));
    try std.testing.expect(matches(boolean, .{ .number = 1.0 }));
    try std.testing.expect(matches(boolean, .{ .complex = .{ .real = 1, .imaginary = 0 } }));
    try std.testing.expect(!matches(boolean, .{ .string = "1" }));
    try std.testing.expect(keyEqual(
        .{ .tuple = &.{ .{ .boolean = false }, .{ .string = "a" } } },
        .{ .tuple = &.{ .{ .integer = "0" }, .{ .string = "a" } } },
    ));
    try std.testing.expect(!keyEqual(.{ .integer = "9007199254740993" }, .{ .number = 9007199254740992.0 }));
}

test "dictionary keys reject mutable containers, including nested tuples" {
    try std.testing.expectError(error.JinjaTypeError, hashable(.{ .list = &.{} }));
    try std.testing.expectError(error.JinjaTypeError, hashable(.{ .object = &.{} }));
    try std.testing.expectError(error.JinjaTypeError, hashable(.{ .tuple = &.{.{ .list = &.{} }} }));
    try hashable(.{ .tuple = &.{ .none, .{ .integer = "7" }, .{ .tuple = &.{} } } });
}

test "relation keys compare complete identity and do not collapse to rendered SQL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const context = @import("dbt_context.zig");
    const table = try context.relationValue(allocator, .{ .schema = "main", .identifier = "a", .relation_type = "table" });
    const copy = try context.cloneValue(allocator, table);
    const view = try context.relationValue(allocator, .{ .schema = "main", .identifier = "a", .relation_type = "view" });
    try hashable(table);
    try std.testing.expect(keyEqual(table, copy));
    try std.testing.expect(!keyEqual(table, view));
    try std.testing.expect(!keyEqual(table, .{ .string = try table.text(allocator) }));
}
