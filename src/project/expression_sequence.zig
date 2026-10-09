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
    entries[2] = .{ .key = "__dxt_sequence_cursor", .value = try expression.integerValue(a, 0) };
    return .{ .object = entries };
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
    if (!std.mem.eql(u8, name, "zip")) return try viewItems(a, value, name);
    const source = value.attribute("__dxt_sequence_source");
    if (source != .list) return error.JinjaTypeError;
    var inputs: std.ArrayList([]const Value) = .empty;
    defer inputs.deinit(a);
    var row_count: usize = if (source.list.len == 0) 0 else std.math.maxInt(usize);
    for (source.list) |input| {
        const values = try expression.iterableValues(a, input);
        row_count = @min(row_count, values.len);
        try inputs.append(a, values);
    }
    const cursor_value = value.attribute("__dxt_sequence_cursor");
    const cursor: usize = @intCast(@max(0, try expression.integerIndex(cursor_value)));
    const start = @min(cursor, row_count);
    const rows = try expression.allocateValues(a, row_count - start);
    for (rows, start..) |*row, index| {
        const fields = try expression.allocateValues(a, inputs.items.len);
        for (inputs.items, fields) |input, *field| field.* = input[index];
        row.* = .{ .tuple = fields };
    }
    for (@constCast(value.object)) |*entry| if (std.mem.eql(u8, entry.key, "__dxt_sequence_cursor")) {
        entry.value = try expression.integerValue(a, row_count);
    };
    return rows;
}

pub fn text(a: std.mem.Allocator, value: Value) !?[]const u8 {
    const name = kind(value) orelse return null;
    if (std.mem.eql(u8, name, "zip")) return error.JinjaTypeError;
    const values = try viewItems(a, value, name);
    return try std.fmt.allocPrint(a, "dict_{s}({s})", .{ name, try (Value{ .list = values }).text(a) });
}

pub fn length(value: Value) !?usize {
    const name = kind(value) orelse return null;
    if (std.mem.eql(u8, name, "zip")) return error.JinjaTypeError;
    const source = value.attribute("__dxt_sequence_source");
    return if (source == .object) source.object.len else error.JinjaTypeError;
}

pub fn truthy(value: Value) ?bool {
    const name = kind(value) orelse return null;
    if (std.mem.eql(u8, name, "zip")) return true;
    return (length(value) catch 0 orelse 0) != 0;
}
