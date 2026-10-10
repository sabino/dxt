//! Python tuple/dictionary-view/consuming-zip protocols in native values.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
threadlocal var pull_depth: usize = 0;

pub fn kind(value: Value) ?[]const u8 {
    const marker = value.attribute("__dxt_sequence_kind");
    return if (marker == .string) marker.string else null;
}

pub fn view(a: std.mem.Allocator, object: Value, name: []const u8) !Value {
    const entries = try expression.allocateEntries(a, 2);
    entries[0] = .{ .key = "__dxt_sequence_kind", .value = .{ .string = name } };
    entries[1] = .{ .key = "__dxt_sequence_source", .value = object };
    return .{ .object = entries };
}

pub fn zip(a: std.mem.Allocator, inputs: []const Value) !Value {
    const entries = try expression.allocateEntries(a, 3);
    entries[0] = .{ .key = "__dxt_sequence_kind", .value = .{ .string = "zip" } };
    const iterators = try expression.allocateValues(a, inputs.len);
    for (inputs, iterators) |input, *output| output.* = try iter(a, input);
    entries[1] = .{ .key = "__dxt_sequence_source", .value = .{ .list = iterators } };
    const cursors = try expression.allocateValues(a, inputs.len);
    for (cursors) |*cursor| cursor.* = .{ .integer = "0" };
    entries[2] = .{ .key = "__dxt_sequence_cursor", .value = .{ .list = cursors } };
    return .{ .object = entries };
}

pub fn iterator(a: std.mem.Allocator, values: []const Value) !Value {
    const entries = try expression.allocateEntries(a, 3);
    entries[0] = .{ .key = "__dxt_sequence_kind", .value = .{ .string = "iterator" } };
    entries[1] = .{ .key = "__dxt_sequence_source", .value = .{ .list = values } };
    entries[2] = .{ .key = "__dxt_sequence_cursor", .value = .{ .integer = "0" } };
    return .{ .object = entries };
}

pub fn isIterator(value: Value) bool {
    const name = kind(value) orelse return false;
    return std.mem.eql(u8, name, "iterator") or std.mem.eql(u8, name, "zip") or std.mem.startsWith(u8, name, "itertools_") or std.mem.startsWith(u8, name, "filter_");
}

/// Creating an iterator is non-consuming; aliases share each one-shot cursor.
pub fn iter(a: std.mem.Allocator, input: Value) !Value {
    if (isIterator(input)) return input;
    if (!expression.isIterable(input)) return error.JinjaTypeError;
    const entries = try expression.allocateEntries(a, 3);
    entries[0] = .{ .key = "__dxt_sequence_kind", .value = .{ .string = "iterator" } };
    entries[1] = .{ .key = "__dxt_sequence_source", .value = input };
    entries[2] = .{ .key = "__dxt_sequence_cursor", .value = .{ .integer = "0" } };
    return .{ .object = entries };
}

pub fn next(a: std.mem.Allocator, value: Value, host: ?expression.Host) anyerror!?Value {
    if (pull_depth == 128) return error.JinjaExpressionDepthExceeded;
    pull_depth += 1;
    defer pull_depth -= 1;
    const name = kind(value) orelse return error.JinjaTypeError;
    if (std.mem.eql(u8, name, "iterator")) return nextIterator(a, value, host);
    if (std.mem.eql(u8, name, "zip")) return nextZip(a, value, host);
    if (std.mem.startsWith(u8, name, "itertools_")) return @import("itertools_context.zig").pull(a, value, host);
    if (std.mem.startsWith(u8, name, "filter_")) return @import("expression_filter_iterator.zig").pull(a, value, host);
    // No native callback pointers are stored in authored expression values.
    return error.UnsupportedJinjaIterator;
}

fn nextIterator(a: std.mem.Allocator, value: Value, host: ?expression.Host) !?Value {
    const source = value.attribute("__dxt_sequence_source");
    const members = try expression.iterableValuesWithHost(a, source, host);
    const index: usize = @intCast(try expression.integerIndex(value.attribute("__dxt_sequence_cursor")));
    if (index >= members.len) return null;
    for (@constCast(value.object)) |*entry| if (std.mem.eql(u8, entry.key, "__dxt_sequence_cursor")) {
        entry.value = try expression.integerValue(a, index + 1);
        break;
    };
    return members[index];
}

fn viewItems(a: std.mem.Allocator, value: Value, name: []const u8) ![]const Value {
    const source = value.attribute("__dxt_sequence_source");
    if (source != .object) return error.JinjaTypeError;
    const values = try expression.allocateValues(a, source.object.len);
    for (source.object, values) |entry, *result| {
        if (std.mem.eql(u8, name, "keys")) result.* = expression.entryKey(entry) else if (std.mem.eql(u8, name, "values")) result.* = entry.value else {
            const pair = try expression.allocateValues(a, 2);
            pair[0] = expression.entryKey(entry);
            pair[1] = entry.value;
            result.* = .{ .tuple = pair };
        }
    }
    return values;
}

pub fn items(a: std.mem.Allocator, value: Value) !?[]const Value {
    return itemsWithHost(a, value, null);
}

pub fn itemsWithHost(a: std.mem.Allocator, value: Value, host: ?expression.Host) !?[]const Value {
    const name = kind(value) orelse return null;
    if (!isIterator(value)) return try viewItems(a, value, name);
    var rows: std.ArrayList(Value) = .empty;
    errdefer rows.deinit(a);
    while (try next(a, value, host)) |row| {
        if (rows.items.len == 100000) return error.JinjaIterationLimitExceeded;
        try rows.append(a, row);
    }
    return try rows.toOwnedSlice(a);
}

fn nextZip(a: std.mem.Allocator, value: Value, host: ?expression.Host) anyerror!?Value {
    const source = value.attribute("__dxt_sequence_source");
    const cursor_value = value.attribute("__dxt_sequence_cursor");
    if (source != .list or cursor_value != .list or source.list.len != cursor_value.list.len) return error.JinjaTypeError;
    if (source.list.len == 0) return null;
    const fields = try expression.allocateValues(a, source.list.len);
    for (source.list, fields) |input, *field| {
        field.* = (try next(a, input, host)) orelse return null;
    }
    return .{ .tuple = fields };
}

pub fn text(a: std.mem.Allocator, value: Value) !?[]const u8 {
    const name = kind(value) orelse return null;
    if (isIterator(value)) return error.JinjaTypeError;
    const values = try viewItems(a, value, name);
    return try std.fmt.allocPrint(a, "dict_{s}({s})", .{ name, try (Value{ .list = values }).text(a) });
}

pub fn length(value: Value) !?usize {
    _ = kind(value) orelse return null;
    if (isIterator(value)) return error.JinjaTypeError;
    const source = value.attribute("__dxt_sequence_source");
    return if (source == .object) source.object.len else error.JinjaTypeError;
}

pub fn truthy(value: Value) ?bool {
    _ = kind(value) orelse return null;
    if (isIterator(value)) return true;
    return (length(value) catch 0 orelse 0) != 0;
}

test "native pull iterators share cursors and zip consumes only one row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = Value{ .tuple = &.{ .{ .integer = "1" }, .{ .integer = "2" }, .{ .integer = "3" }, .{ .integer = "4" } } };
    const stream = try iter(a, input);
    const alias = try iter(a, stream);
    try std.testing.expectEqualStrings("1", (try next(a, stream, null)).?.integer);
    try std.testing.expectEqualStrings("2", (try next(a, alias, null)).?.integer);
    const zipped = try zip(a, &.{ stream, stream });
    try std.testing.expectEqualStrings("(3, 4)", try (try next(a, zipped, null)).?.text(a));
    try std.testing.expect((try next(a, zipped, null)) == null);
    try std.testing.expect((try next(a, stream, null)) == null);
    const characters = try iter(a, .{ .string = "a\u{1f600}" });
    try std.testing.expectEqualStrings("a", (try next(a, characters, null)).?.string);
    try std.testing.expectEqualStrings("\u{1f600}", (try next(a, characters, null)).?.string);
    try std.testing.expectError(error.JinjaTypeError, iter(a, .none));
}
