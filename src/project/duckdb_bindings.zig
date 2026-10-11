//! Nested Python-style parameters become actual prepared DuckDB expressions.
//! Only parameter tokens are rewritten; every scalar remains bound data.
const std = @import("std");
const params = @import("query_parameters.zig");
const Parameter = params.Parameter;
pub const Expanded = struct { sql: []const u8, bindings: []const Parameter };
pub fn needed(bindings: []const Parameter) bool {
    for (bindings) |binding| if (binding.recursive() or binding == .time_tz or binding == .interval or binding == .uuid) return true;
    return false;
}
pub fn expand(a: std.mem.Allocator, sql: []const u8, bindings: []const Parameter) !Expanded {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var leaves: std.ArrayList(Parameter) = .empty;
    errdefer leaves.deinit(a);
    var index: usize = 0;
    var positional: usize = 0;
    var maximum: usize = 0;
    var named_mode: ?bool = null;
    const referenced = try a.alloc(bool, bindings.len);
    @memset(referenced, false);
    while (index < sql.len) {
        if (opaqueEnd(sql, index)) |end| {
            try out.writer.writeAll(sql[index..end]);
            index = end;
            continue;
        }
        var end = index + 1;
        var slot: ?usize = null;
        if (try token(sql, index, &positional)) |parameter| {
            end = parameter.end;
            const named = parameter.name != null;
            if (named_mode) |previous| {
                if (previous != named) return error.InvalidQueryParameterPlaceholder;
            } else named_mode = named;
            if (parameter.name != null) return error.InvalidQueryParameter;
            slot = parameter.slot;
        }
        if (slot) |actual| {
            if (actual >= bindings.len) return error.QueryParameterCountMismatch;
            maximum = @max(maximum, actual + 1);
            positional = @max(positional, actual + 1);
            referenced[actual] = true;
            try expression(a, &out.writer, &leaves, bindings[actual], 0);
        } else try out.writer.writeByte(sql[index]);
        index = end;
    }
    if (maximum != bindings.len) return error.QueryParameterCountMismatch;
    for (referenced) |used| if (!used) return error.QueryParameterCountMismatch;
    return .{ .sql = try out.toOwnedSlice(), .bindings = try leaves.toOwnedSlice(a) };
}

pub const Token = struct { end: usize, name: ?[]const u8 = null, slot: ?usize = null };
fn identifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$' or byte >= 128;
}
fn dollarBoundary(sql: []const u8, start: usize) bool {
    return start == 0 or !identifierByte(sql[start - 1]);
}
/// Recognize the same token boundaries before both mapping and recursive
/// binding adaptation. A dollar inside an unquoted identifier is literal SQL.
pub fn token(sql: []const u8, start: usize, next_slot: *usize) !?Token {
    const byte = sql[start];
    if (byte != '?' and byte != '$') return null;
    if (byte == '$' and !dollarBoundary(sql, start)) return null;
    var end = start + 1;
    if (end < sql.len and std.ascii.isDigit(sql[end])) {
        while (end < sql.len and std.ascii.isDigit(sql[end])) : (end += 1) {}
        const number = std.fmt.parseUnsigned(usize, sql[start + 1 .. end], 10) catch return error.InvalidQueryParameterPlaceholder;
        if (number == 0) return error.InvalidQueryParameterPlaceholder;
        next_slot.* = @max(next_slot.*, number);
        return .{ .end = end, .slot = number - 1 };
    }
    if (byte == '?') {
        const slot = next_slot.*;
        next_slot.* += 1;
        return .{ .end = end, .slot = slot };
    }
    if (end >= sql.len or !(std.ascii.isAlphabetic(sql[end]) or sql[end] == '_' or sql[end] >= 128)) return null;
    while (end < sql.len and (std.ascii.isAlphanumeric(sql[end]) or sql[end] == '_' or sql[end] >= 128)) : (end += 1) {}
    return .{ .end = end, .name = sql[start + 1 .. end] };
}

/// SQL comments and quoted strings/identifiers are opaque to bindings.
pub fn opaqueEnd(sql: []const u8, start: usize) ?usize {
    if (sql[start] == '\'' or sql[start] == '"') {
        const quote = sql[start];
        var index = start + 1;
        while (index < sql.len) : (index += 1) {
            if (sql[index] == '\\' and quote == '\'' and start > 0 and (sql[start - 1] == 'e' or sql[start - 1] == 'E')) {
                index += 1;
                continue;
            }
            if (sql[index] != quote) continue;
            if (index + 1 < sql.len and sql[index + 1] == quote) {
                index += 1;
                continue;
            }
            return index + 1;
        }
        return sql.len;
    }
    if (std.mem.startsWith(u8, sql[start..], "--")) return if (std.mem.indexOfScalarPos(u8, sql, start + 2, '\n')) |end| end + 1 else sql.len;
    if (std.mem.startsWith(u8, sql[start..], "/*")) {
        var depth: usize = 1;
        var index = start + 2;
        while (index + 1 < sql.len) : (index += 1) {
            if (std.mem.startsWith(u8, sql[index..], "/*")) {
                depth += 1;
                index += 1;
            } else if (std.mem.startsWith(u8, sql[index..], "*/")) {
                depth -= 1;
                index += 1;
                if (depth == 0) return index + 1;
            }
        }
        return sql.len;
    }
    if (sql[start] == '$' and dollarBoundary(sql, start)) {
        var end = start + 1;
        while (end < sql.len and (std.ascii.isAlphanumeric(sql[end]) or sql[end] == '_' or sql[end] >= 128)) : (end += 1) {}
        if (end < sql.len and sql[end] == '$') {
            const delimiter = sql[start .. end + 1];
            return if (std.mem.indexOfPos(u8, sql, end + 1, delimiter)) |closing| closing + delimiter.len else sql.len;
        }
    }
    return null;
}
fn expression(a: std.mem.Allocator, w: *std.Io.Writer, leaves: *std.ArrayList(Parameter), binding: Parameter, depth: usize) anyerror!void {
    if (depth == 128) return error.InvalidQueryParameter;
    switch (binding) {
        .list, .tuple => |members| {
            var text = false;
            for (members) |member| text = text or member == .text;
            try w.writeAll("list_value(");
            for (members, 0..) |member, index| {
                if (index != 0) try w.writeAll(", ");
                if (text) try w.writeAll("cast(");
                try expression(a, w, leaves, member, depth + 1);
                if (text) try w.writeAll(" as varchar)");
            }
            try w.writeByte(')');
        },
        .object => |fields| {
            if (fields.len == 0) return w.writeAll("map()");
            if (fields.len == 2) {
                var keys: ?Parameter = null;
                var values: ?Parameter = null;
                for (fields) |field| {
                    if (std.mem.eql(u8, field.name, "key")) keys = field.value;
                    if (std.mem.eql(u8, field.name, "value")) values = field.value;
                }
                if (keys != null and values != null and (keys.? == .list or keys.? == .tuple) and (values.? == .list or values.? == .tuple)) {
                    const key_items = if (keys.? == .list) keys.?.list else keys.?.tuple;
                    const value_items = if (values.? == .list) values.?.list else values.?.tuple;
                    if (key_items.len == value_items.len) {
                        try w.writeAll("map(");
                        try expression(a, w, leaves, keys.?, depth + 1);
                        try w.writeAll(", ");
                        try expression(a, w, leaves, values.?, depth + 1);
                        return w.writeByte(')');
                    }
                }
            }
            try w.writeAll("struct_pack(");
            for (fields, 0..) |field, index| {
                if (std.mem.indexOfScalar(u8, field.name, 0) != null) return error.InvalidQueryParameter;
                if (index != 0) try w.writeAll(", ");
                try w.writeByte('"');
                for (field.name) |byte| {
                    if (byte == '"') try w.writeByte('"');
                    try w.writeByte(byte);
                }
                try w.writeAll("\" := ");
                try expression(a, w, leaves, field.value, depth + 1);
            }
            try w.writeByte(')');
        },
        .time_tz, .interval, .uuid => {
            try w.writeAll("cast(? as ");
            try w.writeAll(if (binding == .time_tz) "timetz" else if (binding == .interval) "interval" else "uuid");
            try w.writeByte(')');
            try leaves.append(a, .{ .text = if (binding == .uuid) binding.uuid else (try binding.postgresText(a)).? });
        },
        else => {
            try w.writeByte('?');
            try leaves.append(a, binding);
        },
    }
}

test "nested bindings quote fields and preserve SQL strings comments and dollar quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = "select ?, '?', $$ ? $$, $tag$ ? $tag$ /* ? /* ? */ */ -- ?\n";
    const result = try expand(a, input, &.{.{ .object = &.{.{ .name = "x\" ); drop table target; --", .value = .{ .list = &.{ .{ .integer = "1" }, .none, .{ .text = "x\x00y" } } } }} }});
    try std.testing.expectEqualStrings("select struct_pack(\"x\"\" ); drop table target; --\" := list_value(cast(? as varchar), cast(? as varchar), cast(? as varchar))), '?', $$ ? $$, $tag$ ? $tag$ /* ? /* ? */ */ -- ?\n", result.sql);
    try std.testing.expectEqual(@as(usize, 3), result.bindings.len);
    try std.testing.expectEqualStrings("x\x00y", result.bindings[2].text);
    try std.testing.expectError(error.QueryParameterCountMismatch, expand(a, "select '?'", &.{.{ .list = &.{} }}));
    const reordered = try expand(a, "select ?2, ?1, ?2", &.{ .{ .list = &.{.{ .integer = "1" }} }, .{ .list = &.{.{ .integer = "2" }} } });
    try std.testing.expectEqualStrings("select list_value(?), list_value(?), list_value(?)", reordered.sql);
    try std.testing.expectEqualStrings("2", reordered.bindings[0].integer);
    try std.testing.expectEqualStrings("1", reordered.bindings[1].integer);
    try std.testing.expectEqualStrings("2", reordered.bindings[2].integer);
}

test "parameter tokens preserve Unicode names and embedded identifier dollars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nested: Parameter = .{ .list = &.{.{ .integer = "7" }} };
    try std.testing.expectError(error.InvalidQueryParameter, expand(a, "select $é, $é", &.{nested}));
    const identifier = try expand(a, "select 1 as a$1, ?", &.{nested});
    try std.testing.expectEqualStrings("select 1 as a$1, list_value(?)", identifier.sql);
    const literal = try expand(a, "select 1 as a$x, ?", &.{nested});
    try std.testing.expectEqualStrings("select 1 as a$x, list_value(?)", literal.sql);
}
