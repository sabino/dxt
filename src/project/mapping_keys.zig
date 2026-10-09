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
    if (expression.floatProtocol(candidate) != null) return;
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
    if (expression.floatProtocol(left)) |a| {
        if (expression.floatProtocol(right)) |b| {
            if (std.math.isNan(a) or std.math.isNan(b)) {
                if (!std.math.isNan(a) or !std.math.isNan(b)) return false;
                const id_a = left.attribute("__dxt_float_identity");
                const id_b = right.attribute("__dxt_float_identity");
                return id_a == .string and id_b == .string and std.mem.eql(u8, id_a.string, id_b.string);
            }
        }
    }
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

/// Python's JSON encoder accepts primitive scalar keys and converts their
/// spelling at serialization time, independently of dictionary identity.
pub fn jsonKey(allocator: std.mem.Allocator, candidate: Value) ![]const u8 {
    if (candidate == .string) return candidate.string;
    if (candidate == .none) return "null";
    if (candidate == .boolean) return if (candidate.boolean) "true" else "false";
    if (integerKey(candidate)) |number| return number;
    if (expression.floatProtocol(candidate)) |number| {
        if (std.math.isNan(number)) return "NaN";
        if (std.math.isInf(number)) return if (number < 0) "-Infinity" else "Infinity";
        return @import("expression_number.zig").floatText(allocator, number);
    }
    return error.JinjaTypeError;
}

fn integerKey(candidate: Value) ?[]const u8 {
    if (expression.integerProtocol(candidate)) |number| return number;
    return switch (candidate) {
        .integer => |number| number,
        .boolean => |boolean| if (boolean) "1" else "0",
        else => null,
    };
}

/// sort_keys orders the original Python keys before converting them to JSON
/// names. Mixed incomparable types raise rather than sorting their spelling.
pub fn jsonOrder(allocator: std.mem.Allocator, left: Value, right: Value) !std.math.Order {
    if (left == .string and right == .string) return std.mem.order(u8, left.string, right.string);
    if (left == .none and right == .none) return .eq;
    const lhs_integer = integerKey(left);
    const rhs_integer = integerKey(right);
    const lhs_float = expression.floatProtocol(left);
    const rhs_float = expression.floatProtocol(right);
    const numbers = @import("expression_number.zig");
    if (lhs_integer) |a| {
        if (rhs_integer) |b| return numbers.order(a, b);
        if (rhs_float) |b| return if (std.math.isNan(b)) .eq else try numbers.orderFloat(allocator, a, b);
    }
    if (lhs_float) |a| {
        if (rhs_integer) |b| return if (std.math.isNan(a)) .eq else (try numbers.orderFloat(allocator, b, a)).invert();
        if (rhs_float) |b| return if (std.math.isNan(a) or std.math.isNan(b)) .eq else std.math.order(a, b);
    }
    return error.JinjaTypeError;
}

pub fn sortJsonKeys(allocator: std.mem.Allocator, entries: []Entry) !void {
    for (entries) |item| _ = try jsonKey(allocator, key(item));
    var failure: ?anyerror = null;
    const Context = struct {
        allocator: std.mem.Allocator,
        failure: *?anyerror,
        fn less(context: @This(), left: Entry, right: Entry) bool {
            const order = jsonOrder(context.allocator, key(left), key(right)) catch |err| {
                context.failure.* = err;
                return false;
            };
            return order == .lt;
        }
    };
    std.sort.block(Entry, entries, Context{ .allocator = allocator, .failure = &failure }, Context.less);
    if (failure) |err| return err;
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

test "NaN mapping keys preserve object identity independently of numeric equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const first = try expression.floatValue(allocator, std.math.nan(f64));
    const second = try expression.floatValue(allocator, std.math.nan(f64));
    const copy = try @import("dbt_context.zig").cloneValue(allocator, first);
    try hashable(first);
    try std.testing.expect(keyEqual(first, copy));
    try std.testing.expect(!keyEqual(first, second));
    try std.testing.expect(!expression.equalValues(first, first));
}

test "JSON keys stringify primitives and sort original numeric types exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("true", try jsonKey(allocator, .{ .boolean = true }));
    try std.testing.expectEqualStrings("null", try jsonKey(allocator, .none));
    try std.testing.expectEqualStrings("1.0", try jsonKey(allocator, .{ .number = 1 }));
    try std.testing.expectEqual(std.math.Order.gt, try jsonOrder(allocator, .{ .integer = "9007199254740993" }, .{ .number = 9007199254740992.0 }));
    try std.testing.expectError(error.JinjaTypeError, jsonOrder(allocator, .{ .integer = "1" }, .{ .string = "2" }));
    try std.testing.expectError(error.JinjaTypeError, jsonKey(allocator, .{ .tuple = &.{} }));
}
