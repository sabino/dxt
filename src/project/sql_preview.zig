//! Pinned agate print_table/to_json presentation for native query results.
const std = @import("std");
const result = @import("adapter_result.zig");
const csv = @import("seed_csv.zig");
const types = @import("types.zig");

pub fn render(a: std.mem.Allocator, table: *const result.QueryResult, output: types.Output) ![]const u8 {
    // dbt's SQL adapter preserves text cells instead of inferring from strings.
    const columns = try a.dupe(result.Column, table.columns);
    defer a.free(columns);
    for (columns) |*column| if (column.kind == .time) {
        column.kind = .text;
    };
    var typed = table.*;
    typed.columns = columns;
    const names = try uniqueNames(a, typed.columns);
    defer {
        for (names) |name| a.free(name);
        a.free(names);
    }
    return if (output == .json) renderJson(a, &typed, names) else renderTable(a, &typed, names);
}

fn uniqueNames(a: std.mem.Allocator, columns: []const result.Column) ![][]const u8 {
    const names = try a.alloc([]const u8, columns.len);
    var filled: usize = 0;
    errdefer {
        for (names[0..filled]) |name| a.free(name);
        a.free(names);
    }
    for (columns, 0..) |column, i| {
        var name = try a.dupe(u8, column.name);
        var suffix: usize = 2;
        while (contains(names[0..i], name)) : (suffix += 1) {
            a.free(name);
            name = try std.fmt.allocPrint(a, "{s}_{d}", .{ column.name, suffix });
        }
        names[i] = name;
        filled += 1;
    }
    return names;
}
fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}
fn isNumber(kind: result.Kind) bool {
    return kind == .decimal or kind == .floating;
}
fn isText(kind: result.Kind) bool {
    return kind == .text or kind == .binary or kind == .other;
}
fn normalized(a: std.mem.Allocator, text: []const u8, kind: result.Kind) ![]const u8 {
    if (isNumber(kind)) {
        const number = try csv.number(a, text);
        defer a.free(number);
        const decimal = if (std.mem.indexOfAny(u8, number, "eE")) |exponent_at| try expandExponent(a, number, exponent_at) else try a.dupe(u8, number);
        defer a.free(decimal);
        var end = decimal.len;
        if (std.mem.indexOfScalar(u8, decimal, '.')) |dot| {
            while (end > dot + 1 and decimal[end - 1] == '0') end -= 1;
            if (end == dot + 1) end = dot;
        }
        return a.dupe(u8, decimal[0..end]);
    }
    if (kind == .boolean) return a.dupe(u8, if (std.mem.eql(u8, text, "t") or std.ascii.eqlIgnoreCase(text, "true") or std.mem.eql(u8, text, "1")) "True" else "False");
    if (kind == .timestamp) return timestampIso(a, text);
    return a.dupe(u8, text);
}
fn expandExponent(a: std.mem.Allocator, number: []const u8, exponent_at: usize) ![]const u8 {
    const exponent = try std.fmt.parseInt(i32, number[exponent_at + 1 ..], 10);
    if (exponent < -10000 or exponent > 10000) return error.InvalidPreviewNumber;
    const negative = number[0] == '-';
    const start: usize = if (negative or number[0] == '+') 1 else 0;
    const mantissa = number[start..exponent_at];
    const dot = std.mem.indexOfScalar(u8, mantissa, '.') orelse mantissa.len;
    var digits: std.Io.Writer.Allocating = .init(a);
    defer digits.deinit();
    for (mantissa) |digit| if (digit != '.') try digits.writer.writeByte(digit);
    const position = @as(i32, @intCast(dot)) + exponent;
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    if (negative) try out.writer.writeByte('-');
    if (position <= 0) {
        try out.writer.writeAll("0.");
        try out.writer.splatByteAll('0', @intCast(-position));
        try out.writer.writeAll(digits.written());
    } else if (position >= digits.written().len) {
        try out.writer.writeAll(digits.written());
        try out.writer.splatByteAll('0', @as(usize, @intCast(position)) - digits.written().len);
    } else {
        const split: usize = @intCast(position);
        try out.writer.writeAll(digits.written()[0..split]);
        try out.writer.writeByte('.');
        try out.writer.writeAll(digits.written()[split..]);
    }
    return out.toOwnedSlice();
}
fn timestampIso(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len < 19) return a.dupe(u8, text);
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try out.writer.writeAll(text[0..10]);
    try out.writer.writeByte('T');
    try out.writer.writeAll(text[11..19]);
    var tail: usize = 19;
    if (tail < text.len and text[tail] == '.') {
        const start = tail + 1;
        tail = start;
        var nonzero = false;
        while (tail < text.len and std.ascii.isDigit(text[tail])) : (tail += 1) if (tail - start < 6 and text[tail] != '0') {
            nonzero = true;
        };
        if (nonzero) {
            const length = @min(tail - start, 6);
            try out.writer.writeByte('.');
            try out.writer.writeAll(text[start..][0..length]);
            try out.writer.splatByteAll('0', 6 - length);
        }
    }
    const zone = text[tail..];
    if (std.mem.eql(u8, zone, "Z")) try out.writer.writeAll("+00:00") else if (zone.len == 3 and (zone[0] == '+' or zone[0] == '-')) {
        try out.writer.writeAll(zone);
        try out.writer.writeAll(":00");
    } else if (zone.len == 5 and (zone[0] == '+' or zone[0] == '-')) {
        try out.writer.writeAll(zone[0..3]);
        try out.writer.writeByte(':');
        try out.writer.writeAll(zone[3..]);
    } else try out.writer.writeAll(zone);
    return out.toOwnedSlice();
}
fn renderJson(a: std.mem.Allocator, table: *const result.QueryResult, names: []const []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try out.writer.writeByte('[');
    for (table.rows, 0..) |row, i| {
        if (i != 0) try out.writer.writeAll(", ");
        try out.writer.writeByte('{');
        for (names, table.columns, row, 0..) |name, column, cell, j| {
            if (j != 0) try out.writer.writeAll(", ");
            try std.json.Stringify.value(name, .{}, &out.writer);
            try out.writer.writeAll(": ");
            if (cell) |text| {
                const value = try normalized(a, text, column.kind);
                defer a.free(value);
                if (column.kind == .boolean) try out.writer.writeAll(if (std.mem.eql(u8, value, "True")) "true" else "false") else if (isNumber(column.kind)) {
                    const n = std.fmt.parseFloat(f64, value) catch std.math.nan(f64);
                    if (std.math.isFinite(n)) {
                        const json_number = try std.fmt.allocPrint(a, "{d}", .{n});
                        defer a.free(json_number);
                        try out.writer.writeAll(json_number);
                        if (std.mem.indexOfAny(u8, json_number, ".eE") == null) try out.writer.writeAll(".0");
                    } else try std.json.Stringify.value(value, .{}, &out.writer);
                } else if (column.kind == .integer) try out.writer.writeAll(value) else try std.json.Stringify.value(value, .{}, &out.writer);
            } else try out.writer.writeAll("null");
        }
        try out.writer.writeByte('}');
    }
    try out.writer.writeByte(']');
    return out.toOwnedSlice();
}
fn renderTable(a: std.mem.Allocator, table: *const result.QueryResult, all_names: []const []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const temp = arena.allocator();
    const actual = @min(6, table.columns.len);
    const count = actual + @as(usize, if (actual < table.columns.len) 1 else 0);
    const widths = try temp.alloc(usize, count);
    const names = try temp.alloc([]const u8, count);
    const places = try temp.alloc(usize, actual);
    @memset(places, 0);
    for (names, widths, 0..) |*name, *width, column| {
        name.* = if (column < actual) try truncate(temp, all_names[column]) else "...";
        width.* = try std.unicode.utf8CountCodepoints(name.*);
    }
    for (table.rows) |row| for (row[0..actual], places, table.columns[0..actual]) |cell, *precision, column| {
        if (!isNumber(column.kind)) continue;
        if (cell) |text| {
            const value = try normalized(temp, text, column.kind);
            if (std.mem.indexOfScalar(u8, value, '.')) |dot| precision.* = @max(precision.*, value.len - dot - 1);
        }
    };
    const rendered = try temp.alloc([]const []const u8, table.rows.len);
    for (table.rows, rendered) |row, *destination| {
        const cells = try temp.alloc([]const u8, count);
        for (cells, widths, 0..) |*cell, *width, column| {
            cell.* = if (column >= actual) "..." else if (row[column]) |text| value: {
                const value = try normalized(temp, text, table.columns[column].kind);
                break :value try truncate(temp, if (isNumber(table.columns[column].kind)) try formatNumber(temp, value, places[column]) else if (table.columns[column].kind == .timestamp) blk: {
                    const timestamp = try temp.dupe(u8, value);
                    if (timestamp.len > 10 and timestamp[10] == 'T') timestamp[10] = ' ';
                    break :blk timestamp;
                } else value);
            } else "";
            width.* = @max(width.*, try std.unicode.utf8CountCodepoints(cell.*));
        }
        destination.* = cells;
    }
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try writeRow(&out.writer, names, widths, table.columns);
    try out.writer.writeByte('|');
    for (widths) |width| {
        try out.writer.writeByte(' ');
        try out.writer.splatByteAll('-', width);
        try out.writer.writeAll(" |");
    }
    try out.writer.writeByte('\n');
    for (rendered) |row| try writeRow(&out.writer, row, widths, table.columns);
    return out.toOwnedSlice();
}
fn formatNumber(a: std.mem.Allocator, value: []const u8, max_places: usize) ![]const u8 {
    const places: usize = @min(max_places, 3);
    const negative = value.len != 0 and value[0] == '-';
    const body = if (negative) value[1..] else value;
    const dot = std.mem.indexOfScalar(u8, body, '.') orelse body.len;
    const fraction = if (dot < body.len) body[dot + 1 ..] else "";
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(a);
    try digits.appendSlice(a, body[0..dot]);
    for (0..places) |i| try digits.append(a, if (i < fraction.len) fraction[i] else '0');
    if (fraction.len > places) {
        const next = fraction[places];
        var greater = next > '5';
        if (next == '5') {
            for (fraction[places + 1 ..]) |digit| if (digit != '0') {
                greater = true;
                break;
            };
        }
        if (greater or (next == '5' and digits.items.len != 0 and (digits.items[digits.items.len - 1] - '0') % 2 != 0)) {
            var i = digits.items.len;
            while (i != 0) {
                i -= 1;
                if (digits.items[i] != '9') {
                    digits.items[i] += 1;
                    break;
                }
                digits.items[i] = '0';
            }
            if (i == 0 and digits.items[0] == '0') try digits.insert(a, 0, '1');
        }
    }
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    if (negative) try out.writer.writeByte('-');
    const whole = digits.items.len - places;
    for (digits.items[0..whole], 0..) |digit, i| {
        if (i != 0 and (whole - i) % 3 == 0) try out.writer.writeByte(',');
        try out.writer.writeByte(digit);
    }
    if (places != 0) {
        try out.writer.writeByte('.');
        try out.writer.writeAll(digits.items[whole..]);
    }
    if (max_places > 3) try out.writer.writeAll("…");
    return out.toOwnedSlice();
}
fn writeRow(writer: *std.Io.Writer, cells: []const []const u8, widths: []const usize, columns: []const result.Column) !void {
    try writer.writeByte('|');
    for (cells, widths, columns[0..cells.len]) |cell, width, column| {
        const padding = width -| try std.unicode.utf8CountCodepoints(cell);
        try writer.writeByte(' ');
        if (!isText(column.kind)) try writer.splatByteAll(' ', padding);
        try writer.writeAll(cell);
        if (isText(column.kind)) try writer.splatByteAll(' ', padding);
        try writer.writeAll(" |");
    }
    try writer.writeByte('\n');
}
fn truncate(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (try std.unicode.utf8CountCodepoints(text) <= 20) return text;
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    var end: usize = 0;
    for (0..17) |_| end += iterator.nextCodepointSlice().?.len;
    return std.fmt.allocPrint(a, "{s}...", .{text[0..end]});
}

test "preview number formatting groups and rounds half-even at column precision" {
    const a = std.testing.allocator;
    for ([_][3][]const u8{ .{ "1234.50", "2", "1,234.50" }, .{ "12.3455", "4", "12.346…" }, .{ "99.9985", "4", "99.998…" }, .{ "9.9999", "4", "10.000…" } }) |case| {
        const text = try formatNumber(a, case[0], try std.fmt.parseInt(usize, case[1], 10));
        defer a.free(text);
        try std.testing.expectEqualStrings(case[2], text);
    }
}
