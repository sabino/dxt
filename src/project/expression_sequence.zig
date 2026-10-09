//! Python tuple/dictionary-view/consuming-zip protocols in native values.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;

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
    entries[1] = .{ .key = "__dxt_sequence_source", .value = .{ .list = try a.dupe(Value, inputs) } };
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

fn nextIterator(a: std.mem.Allocator, value: Value) !?Value {
    const source = value.attribute("__dxt_sequence_source");
    if (source != .list) return error.JinjaTypeError;
    const index: usize = @intCast(try expression.integerIndex(value.attribute("__dxt_sequence_cursor")));
    if (index >= source.list.len) return null;
    for (@constCast(value.object)) |*entry| if (std.mem.eql(u8, entry.key, "__dxt_sequence_cursor")) {
        entry.value = try expression.integerValue(a, index + 1);
        break;
    };
    return source.list[index];
}

fn viewItems(a: std.mem.Allocator, value: Value, name: []const u8) ![]const Value {
    const source = value.attribute("__dxt_sequence_source");
    if (source != .object) return error.JinjaTypeError;
    const values = try expression.allocateValues(a, source.object.len);
    for (source.object, values) |entry, *result| {
        if (std.mem.eql(u8, name, "keys")) result.* = .{ .string = entry.key } else if (std.mem.eql(u8, name, "values")) result.* = entry.value else {
            const pair = try expression.allocateValues(a, 2);
            pair[0] = .{ .string = entry.key };
            pair[1] = entry.value;
            result.* = .{ .tuple = pair };
        }
    }
    return values;
}

pub fn items(a: std.mem.Allocator, value: Value) !?[]const Value {
    const name = kind(value) orelse return null;
    if (std.mem.eql(u8, name, "iterator")) {
        var values: std.ArrayList(Value) = .empty;
        while (try nextIterator(a, value)) |item| try values.append(a, item);
        return try values.toOwnedSlice(a);
    }
    if (!std.mem.eql(u8, name, "zip")) return try viewItems(a, value, name);
    var rows: std.ArrayList(Value) = .empty;
    errdefer rows.deinit(a);
    while (try nextZip(a, value, 0)) |row| {
        if (rows.items.len == 100000) return error.JinjaIterationLimitExceeded;
        try rows.append(a, row);
    }
    return try rows.toOwnedSlice(a);
}

fn nextZip(a: std.mem.Allocator, value: Value, depth: usize) anyerror!?Value {
    if (depth > 128) return error.JinjaExpressionDepthExceeded;
    const source = value.attribute("__dxt_sequence_source");
    const cursor_value = value.attribute("__dxt_sequence_cursor");
    if (source != .list or cursor_value != .list or source.list.len != cursor_value.list.len) return error.JinjaTypeError;
    if (source.list.len == 0) return null;
    const fields = try expression.allocateValues(a, source.list.len);
    for (source.list, fields, @constCast(cursor_value.list)) |input, *field, *cursor| {
        if (kind(input)) |input_kind| if (std.mem.eql(u8, input_kind, "zip")) {
            field.* = (try nextZip(a, input, depth + 1)) orelse return null;
            continue;
        } else if (std.mem.eql(u8, input_kind, "iterator")) {
            field.* = (try nextIterator(a, input)) orelse return null;
            continue;
        };
        const values = try expression.iterableValues(a, input);
        const index: usize = @intCast(@max(0, try expression.integerIndex(cursor.*)));
        if (index >= values.len) return null;
        field.* = values[index];
        cursor.* = try expression.integerValue(a, index + 1);
    }
    return .{ .tuple = fields };
}

pub fn text(a: std.mem.Allocator, value: Value) !?[]const u8 {
    const name = kind(value) orelse return null;
    if (std.mem.eql(u8, name, "zip") or std.mem.eql(u8, name, "iterator")) return error.JinjaTypeError;
    const values = try viewItems(a, value, name);
    return try std.fmt.allocPrint(a, "dict_{s}({s})", .{ name, try (Value{ .list = values }).text(a) });
}

pub fn length(value: Value) !?usize {
    const name = kind(value) orelse return null;
    if (std.mem.eql(u8, name, "zip") or std.mem.eql(u8, name, "iterator")) return error.JinjaTypeError;
    const source = value.attribute("__dxt_sequence_source");
    return if (source == .object) source.object.len else error.JinjaTypeError;
}

pub fn truthy(value: Value) ?bool {
    const name = kind(value) orelse return null;
    if (std.mem.eql(u8, name, "zip") or std.mem.eql(u8, name, "iterator")) return true;
    return (length(value) catch 0 orelse 0) != 0;
}
