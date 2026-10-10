//! Convert authored DB-API bindings without changing CSV seed inference.
const std = @import("std");
const expr = @import("expression.zig");
const params = @import("query_parameters.zig");
const Value = expr.Value;
pub const Bound = struct { sql: []const u8, values: []const params.Parameter };

pub fn bind(a: std.mem.Allocator, sql: []const u8, input: Value, postgres: bool) !Bound {
    if (input == .object and @import("builtin_bound_method.zig").isMapping(input)) {
        var out: std.Io.Writer.Allocating = .init(a);
        var values: std.ArrayList(params.Parameter) = .empty;
        var used: std.ArrayList([]const u8) = .empty;
        var index: usize = 0;
        var next_slot: usize = 0;
        var named_mode: ?bool = null;
        while (index < sql.len) {
            if (!postgres) if (@import("duckdb_bindings.zig").opaqueEnd(sql, index)) |end| {
                try out.writer.writeAll(sql[index..end]);
                index = end;
                continue;
            };
            var end = index + 1;
            var key: ?[]const u8 = null;
            if (postgres and sql[index] == '%') {
                if (end < sql.len and sql[end] == '%') {
                    try out.writer.writeAll("%%");
                    index += 2;
                    continue;
                }
                if (end >= sql.len or sql[end] != '(') return error.InvalidQueryParameterPlaceholder;
                end = std.mem.indexOfScalarPos(u8, sql, end + 1, ')') orelse return error.InvalidQueryParameterPlaceholder;
                key = sql[index + 2 .. end];
                end += 1;
                if (end >= sql.len or sql[end] != 's') return error.InvalidQueryParameterPlaceholder;
                end += 1;
            } else if (!postgres) {
                if (try @import("duckdb_bindings.zig").token(sql, index, &next_slot)) |token| {
                    const named = token.name != null;
                    if (named_mode) |previous| {
                        if (previous != named) return error.InvalidQueryParameterPlaceholder;
                    } else named_mode = named;
                    key = token.name orelse try std.fmt.allocPrint(a, "{d}", .{token.slot.? + 1});
                    end = token.end;
                }
            }
            if (key) |actual| {
                var member = try expr.mappingGet(input, .{ .string = actual });
                if (!postgres) for (input.object) |entry| {
                    const candidate = @import("mapping_keys.zig").key(entry);
                    if (candidate == .string and std.ascii.eqlIgnoreCase(candidate.string, actual)) member = entry.value;
                };
                if (expr.isUndefined(member)) return error.InvalidQueryParameter;
                if (postgres) try validatePostgres(member, 0);
                try values.append(a, try parameter(a, member));
                try used.append(a, actual);
                try out.writer.writeAll(if (postgres) "%s" else "?");
            } else try out.writer.writeByte(sql[index]);
            index = end;
        }
        if (!postgres) for (input.object) |entry| {
            const actual = @import("mapping_keys.zig").key(entry);
            if (actual != .string) return error.InvalidQueryParameter;
            var found = false;
            for (used.items) |key| if (std.ascii.eqlIgnoreCase(key, actual.string)) {
                found = true;
                break;
            };
            if (!found) return error.QueryParameterCountMismatch;
        };
        return .{ .sql = try out.toOwnedSlice(), .values = try values.toOwnedSlice(a) };
    }
    // Drivers accept sized Agate Row/Column carriers alongside list/tuple.
    // One-shot iterators do not have the required sequence protocol.
    if (input != .list and input != .tuple and !@import("builtin_bound_method.zig").isContextObject(input)) return error.InvalidQueryParameter;
    const members = expr.sequence(input) orelse return error.InvalidQueryParameter;
    if (!postgres) {
        var cursor: usize = 0;
        var next_slot: usize = 0;
        while (cursor < sql.len) {
            if (@import("duckdb_bindings.zig").opaqueEnd(sql, cursor)) |end| {
                cursor = end;
                continue;
            }
            if (try @import("duckdb_bindings.zig").token(sql, cursor, &next_slot)) |token| {
                if (token.name != null) return error.InvalidQueryParameter;
                cursor = token.end;
            } else cursor += 1;
        }
    }
    const values = try a.alloc(params.Parameter, members.len);
    for (members, values) |member, *item| {
        if (postgres) try validatePostgres(member, 0);
        item.* = try parameter(a, member);
    }
    return .{ .sql = sql, .values = values };
}

test "outer query bindings accept genuine sized carriers and reject authored metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const row: Value = .{ .object = &.{
        .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
        .{ .key = "__dxt_iterable", .value = .{ .list = &.{.{ .integer = "7" }} } },
    } };
    const bound = try bind(a, "select ?", row, false);
    try std.testing.expectEqual(@as(usize, 1), bound.values.len);
    try std.testing.expectEqualStrings("7", bound.values[0].integer);
    const authored: Value = .{ .object = &.{
        .{ .key = "__dxt_context_object", .value = .{ .string = "__dxt_context_object" } },
        .{ .key = "__dxt_iterable", .value = .{ .list = &.{.{ .integer = "7" }} } },
    } };
    try std.testing.expectError(error.InvalidQueryParameter, bind(a, "select ?", authored, false));
}
fn validatePostgres(input: Value, depth: usize) anyerror!void {
    if (depth == 128) return error.JinjaExpressionDepthExceeded;
    if (@import("timestamp_context.zig").state(input)) |stamp| if (stamp.offset_us) |offset| {
        // psycopg2 preserves the authored offset in its timestamp literal;
        // PostgreSQL rejects fractional-second offsets instead of silently
        // accepting a normalization to UTC.
        if (@mod(offset, std.time.us_per_s) != 0) return error.InvalidQueryParameter;
    };
    switch (input) {
        .list, .tuple => |members| for (members) |member| try validatePostgres(member, depth + 1),
        .object => |fields| for (fields) |field| try validatePostgres(field.value, depth + 1),
        else => {},
    }
}

pub fn parameter(a: std.mem.Allocator, input: Value) anyerror!params.Parameter {
    return convert(a, input, 0);
}
fn convert(a: std.mem.Allocator, input: Value, depth: usize) anyerror!params.Parameter {
    if (depth == 128) return error.JinjaExpressionDepthExceeded;
    if (@import("decimal_value.zig").state(input)) |decimal| return .{ .decimal = decimal };
    if (@import("datetime_time.zig").state(input)) |clock| {
        if (clock.offset_us) |offset| {
            if (@mod(offset, std.time.us_per_s) != 0) return error.InvalidQueryParameter;
            return .{ .time_tz = .{ .micros = clock.micros, .offset_us = offset } };
        }
        return .{ .time = clock.micros };
    }
    if (@import("datetime_operations.zig").duration(input)) |micros| return .{ .interval = std.math.cast(i64, micros) orelse return error.InvalidQueryParameter };
    const uuid = input.attribute("__dxt_uuid");
    if (uuid == .callable and std.mem.eql(u8, uuid.callable, "__dxt_uuid")) return .{ .uuid = input.attribute("__dxt_rendered").string };
    if (try @import("query_memoryview.zig").parameterBytes(a, input)) |raw| return .{ .binary = raw };
    switch (input) {
        .list, .tuple => |members| {
            const values = try a.alloc(params.Parameter, members.len);
            for (members, values) |member, *item| item.* = try convert(a, member, depth + 1);
            return if (input == .tuple) .{ .tuple = values } else .{ .list = values };
        },
        .object => |entries| {
            const marker = input.attribute("__dxt_context_object");
            if (marker == .callable and std.mem.eql(u8, marker.callable, "__dxt_context_object")) return @import("seed_table.zig").parameter(input);
            // Genuine numeric and timestamp protocols remain scalar bindings.
            if (expr.integerProtocol(input) != null or expr.floatProtocol(input) != null or @import("timestamp_context.zig").state(input) != null) return @import("seed_table.zig").parameter(input);
            const fields = try a.alloc(params.Field, entries.len);
            for (entries, fields) |entry, *field| field.* = .{ .name = try expr.textWithHost(a, @import("mapping_keys.zig").key(entry), null), .value = try convert(a, entry.value, depth + 1) };
            return .{ .object = fields };
        },
        else => return @import("seed_table.zig").parameter(input),
    }
}

test "mapping query bindings support positional slots without rewriting identifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const slots: Value = .{ .object = &.{
        .{ .key = "1", .value = .{ .integer = "11" } },
        .{ .key = "2", .value = .{ .integer = "22" } },
    } };
    const result = try bind(a, "select $2, $1, $2", slots, false);
    try std.testing.expectEqualStrings("select ?, ?, ?", result.sql);
    try std.testing.expectEqualStrings("22", result.values[0].integer);
    try std.testing.expectEqualStrings("11", result.values[1].integer);
    const words: Value = .{ .object = &.{.{ .key = "é", .value = .{ .integer = "7" } }} };
    try std.testing.expectEqualStrings("select ?", (try bind(a, "select $é", words, false)).sql);
    const embedded: Value = .{ .object = &.{.{ .key = "x", .value = .{ .integer = "7" } }} };
    try std.testing.expectEqualStrings("select 1 as a$x, ?", (try bind(a, "select 1 as a$x, $x", embedded, false)).sql);
}
