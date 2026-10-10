//! dbt's Agate projection is distinct from the original DB-API cursor values.
const std = @import("std");
const expr = @import("expression.zig");
const cursor = @import("query_cursor.zig");
const native = @import("adapter_value.zig");
const A = std.mem.Allocator;
const Value = expr.Value;

pub const Names = struct { names: []Value, indices: []usize };
pub fn names(a: A, original: []const Value) !Names {
    const processed = try expr.allocateValues(a, original.len);
    const output = try expr.allocateValues(a, original.len);
    const indices = try a.alloc(usize, original.len);
    for (original, processed, 0..) |raw, *item, i| {
        if (raw != .string) return error.NativeCursorMetadataMissing;
        var count: usize = 1;
        for (original[0..i]) |prior| if (std.mem.eql(u8, raw.string, prior.string)) {
            count += 1;
        };
        item.* = .{ .string = if (count == 1) raw.string else try std.fmt.allocPrint(a, "{s}_{d}", .{ raw.string, count }) };
    }
    for (processed, output, indices, 0..) |item, *renamed, *index, i| {
        index.* = i;
        for (processed[i + 1 ..], i + 1..) |later, j| if (std.mem.eql(u8, item.string, later.string)) {
            index.* = j;
        };
        const base = if (item.string.len != 0) item.string else blk: {
            const letters = try a.alloc(u8, i / 26 + 1);
            @memset(letters, @as(u8, 'a') + @as(u8, @intCast(i % 26)));
            break :blk letters;
        };
        var candidate: []const u8 = base;
        var suffix: usize = 2;
        while (true) {
            var duplicate = false;
            for (output[0..i]) |prior| if (std.mem.eql(u8, candidate, prior.string)) {
                duplicate = true;
                break;
            };
            if (!duplicate) break;
            candidate = try std.fmt.allocPrint(a, "{s}_{d}", .{ base, suffix });
            suffix += 1;
        }
        renamed.* = .{ .string = candidate };
    }
    return .{ .names = output, .indices = indices };
}

pub fn column(a: A, cells: []const native.Cell, originals: []const Value) anyerror![]const Value {
    if (cells.len != originals.len) return error.NativeCursorValuesMissing;
    var integers = true;
    var numbers = true;
    var dates = true;
    var datetimes = true;
    var booleans = true;
    var text_only = false;
    for (cells) |cell| {
        if (cell == .none) continue;
        integers = integers and cell == .integer;
        numbers = numbers and (cell == .integer or cell == .decimal or cell == .floating);
        dates = dates and cell == .date;
        datetimes = datetimes and (cell == .date or cell == .timestamp);
        booleans = booleans and try booleanCandidate(a, cell);
        text_only = text_only or cell == .text or cell == .list or cell == .tuple or cell == .object or cell == .map;
    }
    const output = try expr.allocateValues(a, cells.len);
    for (cells, originals, output) |cell, original, *item| {
        if (cell == .none) {
            item.* = .none;
            continue;
        }
        if (text_only) {
            const converted = try value(a, cell, original);
            item.* = if (converted == .string) converted else .{ .string = try expr.textWithHost(a, converted, null) };
        } else if (integers or dates) {
            item.* = original;
        } else if (numbers) {
            item.* = if (cell == .integer) try @import("decimal_value.zig").value(a, cell.integer) else try value(a, cell, original);
        } else if (datetimes) {
            item.* = if (cell == .date) try @import("timestamp_context.zig").datetimeValue(a, @as(i96, cell.date) * std.time.ns_per_day, false, null) else original;
        } else if (booleans) {
            item.* = if (cell == .boolean) original else .{ .boolean = (try @import("decimal_number.zig").order(a, try @import("decimal_number.zig").parse(a, if (cell == .integer) cell.integer else cell.decimal), try @import("decimal_number.zig").parse(a, "0"))) != .eq };
        } else {
            item.* = .{ .string = try expr.textWithHost(a, original, null) };
        }
    }
    return output;
}

fn booleanCandidate(a: A, cell: native.Cell) !bool {
    if (cell == .boolean) return true;
    if (cell == .integer) return std.mem.eql(u8, cell.integer, "0") or std.mem.eql(u8, cell.integer, "1");
    if (cell != .decimal) return false;
    const decimal = @import("decimal_number.zig");
    const number = decimal.parse(a, cell.decimal) catch |err| {
        if (err == error.OutOfMemory) return err;
        return false;
    };
    return try decimal.order(a, number, try decimal.parse(a, "0")) == .eq or try decimal.order(a, number, try decimal.parse(a, "1")) == .eq;
}

pub fn value(a: A, cell: native.Cell, original: Value) anyerror!Value {
    return switch (cell) {
        .none => .none,
        .boolean, .integer, .decimal, .date, .timestamp => original,
        .floating => |n| try @import("decimal_value.zig").value(a, if (std.math.isNan(n)) "NaN" else if (std.math.isInf(n)) (if (n < 0) "-Infinity" else "Infinity") else try @import("expression_number.zig").floatText(a, n)),
        .text => original,
        .list, .tuple, .object, .map => blk: {
            var out: std.Io.Writer.Allocating = .init(a);
            errdefer out.deinit();
            try json(a, &out.writer, cell, 0);
            break :blk .{ .string = try out.toOwnedSlice() };
        },
        else => .{ .string = try expr.textWithHost(a, original, null) },
    };
}

fn quote(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    while (iterator.nextCodepoint()) |code| switch (code) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        8 => try w.writeAll("\\b"),
        12 => try w.writeAll("\\f"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...7, 11, 14...31, 127...0xffff => try w.print("\\u{x:0>4}", .{@as(u16, @intCast(code))}),
        0x10000...0x10ffff => {
            const offset = @as(u32, code) - 0x10000;
            try w.print("\\u{x:0>4}\\u{x:0>4}", .{ @as(u16, @intCast(0xd800 + (offset >> 10))), @as(u16, @intCast(0xdc00 + (offset & 0x3ff))) });
        },
        else => try w.writeByte(@intCast(code)),
    };
    try w.writeByte('"');
}
fn json(a: A, w: *std.Io.Writer, cell: native.Cell, depth: usize) anyerror!void {
    if (depth > 128) return error.JinjaExpressionDepthExceeded;
    switch (cell) {
        .none => try w.writeAll("null"),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |n| try w.writeAll(n),
        .decimal, .floating => {
            const n = if (cell == .decimal) try std.fmt.parseFloat(f64, cell.decimal) else cell.floating;
            if (std.math.isNan(n)) try w.writeAll("NaN") else if (std.math.isInf(n)) try w.writeAll(if (n < 0) "-Infinity" else "Infinity") else try w.writeAll(try @import("expression_number.zig").floatText(a, n));
        },
        .list, .tuple => |members| {
            try w.writeByte('[');
            for (members, 0..) |item, i| {
                if (i != 0) try w.writeAll(", ");
                try json(a, w, item, depth + 1);
            }
            try w.writeByte(']');
        },
        .object => |fields| {
            try w.writeByte('{');
            for (fields, 0..) |item, i| {
                if (i != 0) try w.writeAll(", ");
                try quote(w, item.name);
                try w.writeAll(": ");
                try json(a, w, item.value, depth + 1);
            }
            try w.writeByte('}');
        },
        .map => |pairs| {
            var dictionary = true;
            for (pairs) |pair| expr.hashableKey(try cursor.value(a, pair.key)) catch {
                dictionary = false;
            };
            if (!dictionary) {
                const keys = try a.alloc(native.Cell, pairs.len);
                const values = try a.alloc(native.Cell, pairs.len);
                for (pairs, keys, values) |pair, *key, *item| {
                    key.* = pair.key;
                    item.* = pair.value;
                }
                return json(a, w, .{ .object = @constCast(&[_]native.Field{
                    .{ .name = "key", .value = .{ .list = keys } },
                    .{ .name = "value", .value = .{ .list = values } },
                }) }, depth + 1);
            }
            try w.writeByte('{');
            for (pairs, 0..) |pair, i| {
                if (i != 0) try w.writeAll(", ");
                const key = switch (pair.key) {
                    .text => |s| s,
                    .integer => |s| s,
                    .boolean => |b| if (b) "true" else "false",
                    .none => "null",
                    .floating => |n| try @import("expression_number.zig").floatText(a, n),
                    else => return error.JinjaTypeError,
                };
                try quote(w, key);
                try w.writeAll(": ");
                try json(a, w, pair.value, depth + 1);
            }
            try w.writeByte('}');
        },
        else => {
            const original = try cursor.value(a, cell);
            // ForgivingJSONEncoder formats dates/times with isoformat(), and
            // uses str() for remaining non-JSON driver scalar types.
            const text = if (cell == .date or cell == .timestamp) try @import("timestamp_context.zig").call(a, expr.callableName(original.attribute("isoformat")).?, &.{}) else if (cell == .time) try @import("datetime_time.zig").call(a, expr.callableName(original.attribute("isoformat")).?, &.{}) else null;
            try quote(w, if (text) |actual| actual.string else try expr.textWithHost(a, original, null));
        },
    }
}

test "Agate names distinguish raw cursor duplicates and generated-name collisions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const projection = try names(a, &.{ .{ .string = "x" }, .{ .string = "x" }, .{ .string = "x_2" }, .{ .string = "x" } });
    for (projection.names, [_][]const u8{ "x", "x_2", "x_2_2", "x_3" }) |actual, expected| try std.testing.expectEqualStrings(expected, actual.string);
    try std.testing.expectEqualSlices(usize, &.{ 0, 2, 2, 3 }, projection.indices);
}
