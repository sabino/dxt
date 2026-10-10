//! Stock psycopg2 client adaptation for native PostgreSQL parameters.
//! The connection supplies libpq quoting; recursive containers retain the
//! driver's SQL type inference, including unknown empty/all-null arrays.
const std = @import("std");
const parameters = @import("query_parameters.zig");
const Parameter = parameters.Parameter;
const Allocator = std.mem.Allocator;

pub const QuoteFn = *const fn (Allocator, ?*anyopaque, []const u8) anyerror![]const u8;

/// The quote callback returns a literal owned by its supplied allocator.
/// Return one owned string and release all recursive scratch data on failure.
pub fn literal(a: Allocator, input: Parameter, context: ?*anyopaque, quote: QuoteFn) anyerror![]const u8 {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    return a.dupe(u8, try adapt(scratch.allocator(), input, context, quote, 0));
}

fn adapt(a: Allocator, input: Parameter, context: ?*anyopaque, quote: QuoteFn, depth: usize) anyerror![]const u8 {
    if (depth > 128) return error.InvalidQueryParameter;
    switch (input) {
        .none => return "NULL",
        .object, .uuid => return error.InvalidQueryParameter,
        .tuple => |members| {
            var result: std.ArrayList(u8) = .empty;
            try result.append(a, '(');
            for (members, 0..) |member, i| {
                if (i != 0) try result.appendSlice(a, ", ");
                try result.appendSlice(a, try adapt(a, member, context, quote, depth + 1));
            }
            try result.append(a, ')');
            return result.toOwnedSlice(a);
        },
        .list => |members| {
            if (members.len == 0) return quote(a, context, "{}");
            if (try allNull(input, depth)) {
                var array: std.ArrayList(u8) = .empty;
                try nullArray(a, &array, input, depth);
                return quote(a, context, array.items);
            }
            var result: std.ArrayList(u8) = .empty;
            try result.appendSlice(a, "ARRAY[");
            for (members, 0..) |member, i| {
                if (i != 0) try result.append(a, ',');
                // psycopg2 deliberately emits a typed-context-dependent empty
                // ARRAY[] inside a nonempty outer array, rather than '{}'.
                const text = if (member == .list and member.list.len == 0) "ARRAY[]" else try adapt(a, member, context, quote, depth + 1);
                try result.appendSlice(a, text);
            }
            try result.append(a, ']');
            return result.toOwnedSlice(a);
        },
        .decimal => |text| {
            if (nonFiniteDecimal(text)) return "'NaN'::numeric";
            _ = try parameters.decimal(a, text);
            return numericLiteral(a, text);
        },
        .floating => |number| {
            if (std.math.isNan(number)) return "'NaN'::float";
            if (std.math.isInf(number)) return if (number > 0) "'Infinity'::float" else "'-Infinity'::float";
        },
        .interval => |micros| {
            const days = @divFloor(micros, std.time.us_per_day);
            const remainder = @mod(micros, std.time.us_per_day);
            const text = try std.fmt.allocPrint(a, "{d} days {d}.{d:0>6} seconds", .{ days, @as(u64, @intCast(@divFloor(remainder, std.time.us_per_s))), @as(u32, @intCast(@mod(remainder, std.time.us_per_s))) });
            return std.fmt.allocPrint(a, "{s}::interval", .{try quote(a, context, text)});
        },
        .time_tz => |clock| if (clock.micros < 0 or clock.micros >= std.time.us_per_day) return error.InvalidQueryParameter,
        else => {},
    }
    const text = (try input.postgresText(a)).?;
    switch (input) {
        .boolean => return text,
        .integer, .floating => return numericLiteral(a, text),
        else => {},
    }
    const cast = switch (input) {
        .binary => "::bytea",
        .date => "::date",
        .time => "::time",
        .time_tz => "::timetz",
        .timestamp => "::timestamp",
        .timestamp_tz => "::timestamptz",
        .text => "",
        else => unreachable,
    };
    const rendered = if (input == .timestamp or input == .timestamp_tz) blk: {
        const iso = try a.dupe(u8, text);
        iso[10] = 'T';
        break :blk iso;
    } else text;
    return std.fmt.allocPrint(a, "{s}{s}", .{ try quote(a, context, rendered), cast });
}

fn numericLiteral(a: Allocator, text: []const u8) ![]const u8 {
    // This space prevents a preceding SQL '-' from combining with a negative
    // value into '--', just as psycopg2's integer/float/Decimal adapters do.
    return if (text.len != 0 and text[0] == '-') std.fmt.allocPrint(a, " {s}", .{text}) else text;
}

fn nonFiniteDecimal(input: []const u8) bool {
    const text = if (input.len != 0 and (input[0] == '-' or input[0] == '+')) input[1..] else input;
    if (std.ascii.eqlIgnoreCase(text, "Infinity") or std.ascii.eqlIgnoreCase(text, "Inf")) return true;
    var suffix: []const u8 = undefined;
    if (text.len >= 3 and std.ascii.eqlIgnoreCase(text[0..3], "NaN")) {
        suffix = text[3..];
    } else if (text.len >= 4 and std.ascii.eqlIgnoreCase(text[0..4], "sNaN")) {
        suffix = text[4..];
    } else return false;
    for (suffix) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn allNull(input: Parameter, depth: usize) !bool {
    if (depth > 128) return error.InvalidQueryParameter;
    if (input == .none) return true;
    if (input != .list or input.list.len == 0) return false;
    for (input.list) |member| if (!try allNull(member, depth + 1)) return false;
    return true;
}

fn nullArray(a: Allocator, output: *std.ArrayList(u8), input: Parameter, depth: usize) !void {
    if (depth > 128) return error.InvalidQueryParameter;
    if (input == .none) return output.appendSlice(a, "NULL");
    try output.append(a, '{');
    for (input.list, 0..) |member, i| {
        if (i != 0) try output.append(a, ',');
        try nullArray(a, output, member, depth + 1);
    }
    try output.append(a, '}');
}

fn testQuote(a: Allocator, context: ?*anyopaque, text: []const u8) ![]const u8 {
    _ = context;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    try result.append(a, '\'');
    for (text) |byte| {
        if (byte == 0) return error.InvalidQueryParameter;
        if (byte == '\'') try result.append(a, '\'');
        try result.append(a, byte);
    }
    try result.append(a, '\'');
    return result.toOwnedSlice(a);
}

fn expectLiteral(input: Parameter, expected: []const u8) !void {
    const actual = try literal(std.testing.allocator, input, null, testQuote);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "PostgreSQL client literals preserve scalar casts and negative numeric spacing" {
    try expectLiteral(.none, "NULL");
    try expectLiteral(.{ .integer = "-1000" }, " -1000");
    try expectLiteral(.{ .decimal = "1.2500" }, "1.2500");
    try expectLiteral(.{ .floating = -1.25 }, " -1.25");
    try expectLiteral(.{ .floating = -0.0 }, " -0.0");
    try expectLiteral(.{ .floating = std.math.nan(f64) }, "'NaN'::float");
    try expectLiteral(.{ .floating = -std.math.inf(f64) }, "'-Infinity'::float");
    try expectLiteral(.{ .decimal = "Infinity" }, "'NaN'::numeric");
    try expectLiteral(.{ .text = "é'a\\b" }, "'é''a\\b'");
    try expectLiteral(.{ .binary = &.{ 'a', 0, 255 } }, "'\\x6100ff'::bytea");
    try expectLiteral(.{ .time = 3_723_000_004 }, "'01:02:03.000004'::time");
    try expectLiteral(.{ .time_tz = .{ .micros = 3_723_000_004, .offset_us = 19_826_000_007 } }, "'01:02:03.000004+05:30:26.000007'::timetz");
    try expectLiteral(.{ .timestamp = 1_709_168_523_000_004 }, "'2024-02-29T01:02:03.000004'::timestamp");
    try expectLiteral(.{ .timestamp_tz = 1_709_168_523_000_004 }, "'2024-02-29T01:02:03.000004+00:00'::timestamptz");
    try expectLiteral(.{ .interval = -172_796_999_996 }, "'-2 days 3.000004 seconds'::interval");
}

test "PostgreSQL recursive array inference distinguishes empty and all-null nesting" {
    const ints: Parameter = .{ .list = &.{ .{ .integer = "1" }, .{ .integer = "2" } } };
    const nulls: Parameter = .{ .list = &.{ .none, .none } };
    const empty: Parameter = .{ .list = &.{} };
    try expectLiteral(empty, "'{}'");
    try expectLiteral(nulls, "'{NULL,NULL}'");
    try expectLiteral(ints, "ARRAY[1,2]");
    try expectLiteral(.{ .list = &.{ .none, .{ .integer = "2" } } }, "ARRAY[NULL,2]");
    try expectLiteral(.{ .list = &.{ .{ .boolean = true }, .{ .integer = "2" } } }, "ARRAY[true,2]");
    try expectLiteral(.{ .list = &.{ nulls, nulls } }, "'{{NULL,NULL},{NULL,NULL}}'");
    try expectLiteral(.{ .list = &.{ nulls, ints } }, "ARRAY['{NULL,NULL}',ARRAY[1,2]]");
    try expectLiteral(.{ .list = &.{ empty, empty } }, "ARRAY[ARRAY[],ARRAY[]]");
    try expectLiteral(.{ .list = &.{ nulls, empty } }, "ARRAY['{NULL,NULL}',ARRAY[]]");
    try expectLiteral(.{ .list = &.{ empty, ints } }, "ARRAY[ARRAY[],ARRAY[1,2]]");
}

test "PostgreSQL tuple bindings retain record and single-member SQL syntax" {
    const pair: Parameter = .{ .tuple = &.{ .{ .integer = "1" }, .{ .integer = "2" } } };
    try expectLiteral(.{ .tuple = &.{} }, "()");
    try expectLiteral(.{ .tuple = &.{ .none, .none } }, "(NULL, NULL)");
    try expectLiteral(pair, "(1, 2)");
    try expectLiteral(.{ .tuple = &.{.{ .integer = "1" }} }, "(1)");
    try expectLiteral(.{ .list = &.{ pair, pair } }, "ARRAY[(1, 2),(1, 2)]");
    try expectLiteral(.{ .tuple = &.{ .{ .list = &.{.{ .integer = "1" }} }, pair } }, "(ARRAY[1], (1, 2))");
}

test "PostgreSQL recursive adaptation rejects unregistered objects and invalid data" {
    const a = std.testing.allocator;
    for ([_]Parameter{ .{ .object = &.{} }, .{ .uuid = "12345678-1234-5678-1234-567812345678" }, .{ .list = &.{.{ .object = &.{} }} }, .{ .text = "a\x00b" }, .{ .integer = "1;select 2" }, .{ .decimal = "nanSQL" } }) |input| {
        try std.testing.expectError(error.InvalidQueryParameter, literal(a, input, null, testQuote));
    }
}

fn allocationProbe(a: Allocator) !void {
    const input: Parameter = .{ .tuple = &.{ .{ .list = &.{ .{ .text = "é'a\\b" }, .{ .text = "x" } } }, .{ .list = &.{ .{ .list = &.{ .none, .none } }, .{ .list = &.{ .none, .none } } } } } };
    const text = try literal(a, input, null, testQuote);
    defer a.free(text);
}

test "PostgreSQL recursive adaptation releases scratch data at every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
