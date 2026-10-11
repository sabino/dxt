//! Stock psycopg2 Column descriptors are tuple-comparable sequences, without
//! tuple hashing, methods or arithmetic.
const std = @import("std");
const expr = @import("expression.zig");
const Value = expr.Value;
const Allocator = std.mem.Allocator;
const marker = "__dxt_cursor_column";
const fields_names = [_][]const u8{ "name", "type_code", "display_size", "internal_size", "precision", "scale", "null_ok" };

fn field(input: Value, name: []const u8) ?Value {
    if (input != .object) return null;
    for (input.object) |entry| if (std.mem.eql(u8, entry.key, name)) return entry.value;
    return null;
}

/// Authored string metadata cannot impersonate a native cursor descriptor.
pub fn items(input: Value) ?[]const Value {
    const token = field(input, marker) orelse return null;
    if (token != .callable or !std.mem.eql(u8, token.callable, marker)) return null;
    const context = field(input, "__dxt_context_object") orelse return null;
    if (context != .callable or !std.mem.eql(u8, context.callable, "__dxt_context_object")) return null;
    const members = field(input, "__dxt_iterable") orelse return null;
    if (members != .list or members.list.len != 7) return null;
    return members.list;
}

/// Fields share the render arena; copy the field slice before exposing it.
pub fn value(a: Allocator, fields: []const Value) !Value {
    if (fields.len != 7 or fields[0] != .string) return error.InvalidNativeCursorColumn;
    const type_code = std.math.cast(u32, try expr.integerIndex(fields[1])) orelse return error.InvalidNativeCursorColumn;
    for (fields[2..6]) |optional| if (optional != .none) {
        _ = try expr.integerIndex(optional);
    };
    if (fields[6] != .none and fields[6] != .boolean) return error.InvalidNativeCursorColumn;
    const name = try expr.reprWithHost(a, fields[0], null);
    defer a.free(name);
    const rendered = try std.fmt.allocPrint(a, "Column(name={s}, type_code={d})", .{ name, type_code });
    errdefer a.free(rendered);
    const members = try a.dupe(Value, fields);
    errdefer a.free(members);
    const entries = try a.alloc(expr.Entry, 12);
    entries[0] = .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } };
    entries[1] = .{ .key = marker, .value = .{ .callable = marker } };
    entries[2] = .{ .key = "__dxt_iterable", .value = .{ .list = members } };
    entries[3] = .{ .key = "__dxt_repr", .value = .{ .string = rendered } };
    entries[4] = .{ .key = "__dxt_rendered", .value = .{ .string = rendered } };
    for (fields_names, fields, entries[5..]) |name_, input, *entry| entry.* = .{ .key = name_, .value = input };
    return .{ .object = entries };
}

fn comparable(input: Value) ?[]const Value {
    return items(input) orelse expr.tupleProtocol(input);
}

/// A null result leaves non-Column operands to their own comparison protocol.
pub fn equal(left: Value, right: Value) ?bool {
    if (items(left) == null and items(right) == null) return null;
    const lhs = comparable(left) orelse return false;
    const rhs = comparable(right) orelse return false;
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |x, y| if (!expr.equalValues(x, y)) return false;
    return true;
}

/// Preserve checked member protocols when this descriptor appears in a
/// larger collection comparison or a tuple supplies non-metadata members.
pub fn equalChecked(left: Value, right: Value) anyerror!?bool {
    if (items(left) == null and items(right) == null) return null;
    const lhs = comparable(left) orelse return false;
    const rhs = comparable(right) orelse return false;
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |x, y| if (!try expr.equalMemberChecked(x, y)) return false;
    return true;
}

pub fn order(a: Allocator, left: Value, right: Value) anyerror!?std.math.Order {
    if (items(left) == null and items(right) == null) return null;
    const lhs = comparable(left) orelse return error.JinjaTypeError;
    const rhs = comparable(right) orelse return error.JinjaTypeError;
    for (lhs[0..@min(lhs.len, rhs.len)], rhs[0..@min(lhs.len, rhs.len)]) |x, y| {
        if (try expr.equalMemberChecked(x, y)) continue;
        return try expr.valueOrder(a, x, y);
    }
    return std.math.order(lhs.len, rhs.len);
}

fn exampleFields() [7]Value {
    return .{ .{ .string = "n" }, .{ .integer = "23" }, .none, .{ .integer = "4" }, .none, .none, .none };
}

test "cursor Column owns its sequence slice and exposes exact seven metadata attrs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var original = exampleFields();
    const column = try value(a, &original);
    original[0] = .{ .string = "changed" };
    try std.testing.expectEqualStrings("n", items(column).?[0].string);
    try std.testing.expectEqual(@as(usize, 7), items(column).?.len);
    const expected = exampleFields();
    for (fields_names, expected) |name, input| try std.testing.expect(expr.equalValues(column.attribute(name), input));
    try std.testing.expectEqualStrings("Column(name='n', type_code=23)", column.attribute("__dxt_repr").string);
    try std.testing.expectEqualStrings(column.attribute("__dxt_repr").string, column.attribute("__dxt_rendered").string);
    try std.testing.expect(expr.tupleProtocol(column) == null);
    try std.testing.expect(column.attribute("count") == .undefined and column.attribute("index") == .undefined);
    const authored: Value = .{ .object = try a.dupe(expr.Entry, &.{
        .{ .key = marker, .value = .{ .string = marker } },
        .{ .key = "__dxt_context_object", .value = .{ .string = "__dxt_context_object" } },
        .{ .key = "__dxt_iterable", .value = .{ .list = try a.dupe(Value, &expected) } },
    }) };
    try std.testing.expect(items(authored) == null);
    try std.testing.expect(equal(authored, authored) == null);
    try std.testing.expectError(error.InvalidNativeCursorColumn, value(a, expected[0..6]));
}

test "cursor Column equality follows tuple values while preserving list distinction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = exampleFields();
    const left = try value(a, &fields);
    const right = try value(a, &fields);
    const tuple: Value = .{ .tuple = try a.dupe(Value, &fields) };
    const list: Value = .{ .list = try a.dupe(Value, &fields) };
    try std.testing.expectEqual(@as(?bool, true), equal(left, right));
    try std.testing.expectEqual(@as(?bool, true), equal(left, tuple));
    try std.testing.expectEqual(@as(?bool, true), equal(tuple, left));
    try std.testing.expectEqual(@as(?bool, true), try equalChecked(tuple, left));
    try std.testing.expectEqual(@as(?bool, false), equal(left, list));
    try std.testing.expectEqual(@as(?bool, false), equal(list, left));
    try std.testing.expectEqual(@as(?bool, false), try equalChecked(list, left));
    try std.testing.expectEqual(@as(?bool, false), equal(left, .none));
    try std.testing.expect(equal(tuple, tuple) == null);
    try std.testing.expect((try equalChecked(tuple, tuple)) == null);
    var different = fields;
    different[1] = .{ .integer = "25" };
    try std.testing.expectEqual(@as(?bool, false), equal(left, try value(a, &different)));
    try std.testing.expectEqual(@as(?bool, false), equal(left, .{ .tuple = try a.dupe(Value, fields[0..6]) }));
}

test "cursor Column ordering is lexicographic and rejects unrelated sequences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = exampleFields();
    const column = try value(a, &fields);
    const tuple: Value = .{ .tuple = try a.dupe(Value, &fields) };
    try std.testing.expectEqual(@as(?std.math.Order, .eq), try order(a, column, tuple));
    var greater = fields;
    greater[1] = .{ .integer = "25" };
    try std.testing.expectEqual(@as(?std.math.Order, .lt), try order(a, column, try value(a, &greater)));
    try std.testing.expectEqual(@as(?std.math.Order, .gt), try order(a, .{ .tuple = try a.dupe(Value, &greater) }, column));
    try std.testing.expectEqual(@as(?std.math.Order, .gt), try order(a, column, .{ .tuple = try a.dupe(Value, fields[0..6]) }));
    try std.testing.expectError(error.JinjaTypeError, order(a, column, .{ .list = try a.dupe(Value, &fields) }));
    try std.testing.expectError(error.JinjaTypeError, order(a, .none, column));
    try std.testing.expect((try order(a, tuple, tuple)) == null);
}
