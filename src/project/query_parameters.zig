//! Typed native query bindings. Text is data, never SQL interpolation.
const std = @import("std");
const calendar = @import("workflow_intervals.zig");
pub const Field = struct { name: []const u8, value: Parameter };
pub const ZonedTime = struct { micros: i64, offset_us: i64 };

pub const Parameter = union(enum) {
    none,
    boolean: bool,
    integer: []const u8,
    decimal: []const u8,
    floating: f64,
    text: []const u8,
    binary: []const u8,
    date: i32,
    time: i64,
    timestamp: i64,
    timestamp_tz: i64,
    time_tz: ZonedTime,
    interval: i64,
    uuid: []const u8,
    list: []const Parameter,
    tuple: []const Parameter,
    object: []const Field,

    pub fn recursive(self: Parameter) bool {
        return self == .list or self == .tuple or self == .object;
    }

    pub fn postgresType(self: Parameter) u32 {
        return switch (self) {
            // psycopg2 quotes text as an unknown literal: the SQL context
            // determines its type, including explicit CSV column overrides.
            .none, .text => 0,
            .boolean => 16,
            .integer => |text| if (std.fmt.parseInt(i32, text, 10)) |_| 23 else |_| if (std.fmt.parseInt(i64, text, 10)) |_| 20 else |_| 1700,
            .decimal => 1700,
            .floating => |number| if (std.math.isFinite(number)) 1700 else 701,
            .binary => 17,
            .date => 1082,
            .time => 1083,
            .timestamp => 1114,
            .timestamp_tz => 1184,
            .time_tz => 1266,
            .interval => 1186,
            .uuid => 2950,
            .list, .tuple, .object => 0,
        };
    }

    pub fn postgresText(self: Parameter, a: std.mem.Allocator) !?[:0]const u8 {
        var temporary = std.heap.ArenaAllocator.init(a);
        defer temporary.deinit();
        const scratch = temporary.allocator();
        const text = switch (self) {
            .none => return null,
            .boolean => |value| if (value) "true" else "false",
            .integer => |value| blk: {
                if (value.len == 0 or (value.len == 1 and (value[0] == '-' or value[0] == '+'))) return error.InvalidQueryParameter;
                for (value, 0..) |byte, i| if (!std.ascii.isDigit(byte) and !(i == 0 and (byte == '-' or byte == '+'))) return error.InvalidQueryParameter;
                break :blk value;
            },
            .decimal => |value| value,
            .floating => |value| try @import("expression_number.zig").floatText(scratch, value),
            .text => |value| value,
            .binary => |value| try std.fmt.allocPrint(scratch, "\\x{s}", .{try hex(scratch, value)}),
            .date => |days| (try calendar.formatTimestamp(scratch, @as(i64, days) * std.time.s_per_day))[0..10],
            .time => |micros| blk: {
                if (micros < 0 or micros >= std.time.us_per_day) return error.InvalidQueryParameter;
                break :blk (try timestampText(scratch, micros))[11..];
            },
            .timestamp => |micros| try timestampText(scratch, micros),
            .timestamp_tz => |micros| try std.fmt.allocPrint(scratch, "{s}+00:00", .{try timestampText(scratch, micros)}),
            .time_tz => |clock| try std.fmt.allocPrint(scratch, "{s}{s}", .{ (try timestampText(scratch, clock.micros))[11..], try offsetText(scratch, clock.offset_us) }),
            .interval => |micros| try std.fmt.allocPrint(scratch, "{d} microseconds", .{micros}),
            .uuid, .list, .tuple, .object => return error.InvalidQueryParameter,
        };
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidQueryParameter;
        return try a.dupeZ(u8, text);
    }
};

pub fn offsetText(a: std.mem.Allocator, micros: i64) ![]const u8 {
    if (@abs(micros) >= std.time.us_per_day) return error.InvalidQueryParameter;
    const absolute = @abs(micros);
    const seconds = absolute / std.time.us_per_s;
    const fraction = absolute % std.time.us_per_s;
    const base = try std.fmt.allocPrint(a, "{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (micros < 0) '-' else '+'), seconds / 3600, seconds / 60 % 60 });
    if (seconds % 60 == 0 and fraction == 0) return base;
    if (fraction == 0) return std.fmt.allocPrint(a, "{s}:{d:0>2}", .{ base, seconds % 60 });
    return std.fmt.allocPrint(a, "{s}:{d:0>2}.{d:0>6}", .{ base, seconds % 60, fraction });
}

fn timestampText(a: std.mem.Allocator, micros: i64) ![]const u8 {
    const base = try calendar.formatTimestamp(a, @divFloor(micros, std.time.us_per_s));
    const fraction = @mod(micros, std.time.us_per_s);
    if (fraction == 0) return base;
    return std.fmt.allocPrint(a, "{s}.{d:0>6}", .{ base, @as(u32, @intCast(fraction)) });
}

fn hex(a: std.mem.Allocator, input: []const u8) ![]const u8 {
    const result = try a.alloc(u8, input.len * 2);
    const digits = "0123456789abcdef";
    for (input, 0..) |byte, i| {
        result[i * 2] = digits[byte >> 4];
        result[i * 2 + 1] = digits[byte & 15];
    }
    return result;
}

pub const Decimal = struct { width: u8, scale: u8, coefficient: i128 };

/// DuckDB's Python adapter binds Decimal as DECIMAL while it fits width 38,
/// and promotes wider coefficients to DOUBLE. Preserve the original scale.
pub fn decimal(a: std.mem.Allocator, input: []const u8) !?Decimal {
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(a);
    var cursor: usize = 0;
    var negative = false;
    if (input.len == 0) return error.InvalidQueryParameter;
    if (input[0] == '-' or input[0] == '+') {
        negative = input[0] == '-';
        cursor += 1;
    }
    var scale: i64 = 0;
    var point = false;
    while (cursor < input.len and input[cursor] != 'e' and input[cursor] != 'E') : (cursor += 1) {
        const byte = input[cursor];
        if (byte == '.' and !point) {
            point = true;
            continue;
        }
        if (!std.ascii.isDigit(byte)) return error.InvalidQueryParameter;
        try digits.append(a, byte);
        if (point) scale += 1;
    }
    if (digits.items.len == 0) return error.InvalidQueryParameter;
    if (cursor != input.len) {
        const exponent = std.fmt.parseInt(i32, input[cursor + 1 ..], 10) catch return error.InvalidQueryParameter;
        scale -= exponent;
    }
    var first: usize = 0;
    while (first + 1 < digits.items.len and digits.items[first] == '0') first += 1;
    const significant = digits.items[first..];
    const width = @max(@as(i64, @intCast(significant.len)) + @max(-scale, 0), @max(scale, 1));
    if (width > 38 or scale > 38) return null;
    var coefficient = std.fmt.parseInt(i128, significant, 10) catch return error.InvalidQueryParameter;
    if (scale < 0) for (0..@intCast(-scale)) |_| {
        coefficient *= 10;
    };
    return .{ .width = @intCast(width), .scale = @intCast(@max(scale, 0)), .coefficient = if (negative) -coefficient else coefficient };
}

/// psycopg2's positional pyformat placeholders become libpq parameter slots.
/// Its parser treats percent escapes uniformly, including in SQL strings.
pub fn postgresSql(a: std.mem.Allocator, sql: []const u8, count: usize) ![]const u8 {
    return postgresTemplate(a, sql, count, null);
}

pub fn postgresAdaptedSql(a: std.mem.Allocator, sql: []const u8, literals: []const []const u8) ![]const u8 {
    return postgresTemplate(a, sql, literals.len, literals);
}

/// psycopg2 substitutes even inside quotes/comments; such placeholders are
/// SQL text rather than extended-protocol parameter slots. Dollar quoting and
/// multiple statements likewise use the real native client adaptation path.
pub fn needsClientAdaptation(sql: []const u8) bool {
    var quoted: ?u8 = null;
    var line_comment = false;
    var block_comment = false;
    var index: usize = 0;
    while (index < sql.len) : (index += 1) {
        const byte = sql[index];
        if (byte == ';' or byte == '$') return true;
        if (line_comment) {
            if (byte == '%') return true;
            if (byte == '\n') line_comment = false;
        } else if (block_comment) {
            if (byte == '%') return true;
            if (byte == '*' and index + 1 < sql.len and sql[index + 1] == '/') {
                block_comment = false;
                index += 1;
            }
        } else if (quoted) |quote| {
            if (byte == '%') return true;
            if (byte == quote) {
                if (index + 1 < sql.len and sql[index + 1] == quote) index += 1 else quoted = null;
            }
        } else if (byte == '\'' or byte == '"') {
            quoted = byte;
        } else if (index + 1 < sql.len and byte == '-' and sql[index + 1] == '-') {
            line_comment = true;
            index += 1;
        } else if (index + 1 < sql.len and byte == '/' and sql[index + 1] == '*') {
            block_comment = true;
            index += 1;
        }
    }
    return false;
}

fn postgresTemplate(a: std.mem.Allocator, sql: []const u8, count: usize, literals: ?[]const []const u8) ![]const u8 {
    var result: std.Io.Writer.Allocating = .init(a);
    errdefer result.deinit();
    var position: usize = 0;
    var index: usize = 0;
    while (index < sql.len) : (index += 1) {
        if (sql[index] != '%') {
            try result.writer.writeByte(sql[index]);
            continue;
        }
        index += 1;
        if (index == sql.len) return error.InvalidQueryParameterPlaceholder;
        switch (sql[index]) {
            '%' => try result.writer.writeByte('%'),
            's' => {
                position += 1;
                if (position > count) return error.QueryParameterCountMismatch;
                if (literals) |values| try result.writer.writeAll(values[position - 1]) else try result.writer.print("${d}", .{position});
            },
            else => return error.InvalidQueryParameterPlaceholder,
        }
    }
    if (position != count) return error.QueryParameterCountMismatch;
    return result.toOwnedSlice();
}

test "PostgreSQL binding templates preserve literal percent and validate arity" {
    const a = std.testing.allocator;
    const sql = try postgresSql(a, "select %s, %s, '100%%', %%", 2);
    defer a.free(sql);
    try std.testing.expectEqualStrings("select $1, $2, '100%', %", sql);
    try std.testing.expectError(error.QueryParameterCountMismatch, postgresSql(a, "select %s", 0));
    try std.testing.expectError(error.QueryParameterCountMismatch, postgresSql(a, "select 1", 1));
    try std.testing.expectError(error.InvalidQueryParameterPlaceholder, postgresSql(a, "select %d", 1));
    try std.testing.expect(!needsClientAdaptation("select %s"));
    try std.testing.expect(needsClientAdaptation("select '%s'"));
    try std.testing.expect(needsClientAdaptation("select %s; select %s"));
    try std.testing.expect(needsClientAdaptation("select %s -- %s"));
    const literal = try postgresAdaptedSql(a, "select '%s', %s", &.{ "42", "'quoted''text'" });
    defer a.free(literal);
    try std.testing.expectEqualStrings("select '42', 'quoted''text'", literal);
}

test "Native PostgreSQL parameter text retains exact numerics nulls and temporal precision" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try Parameter.postgresText(.none, a)) == null);
    try std.testing.expectEqual(@as(u32, 20), Parameter.postgresType(.{ .integer = "9223372036854775807" }));
    try std.testing.expectEqual(@as(u32, 1700), Parameter.postgresType(.{ .integer = "9223372036854775808" }));
    try std.testing.expectEqualStrings("0.123456789012345678901", (try Parameter.postgresText(.{ .decimal = "0.123456789012345678901" }, a)).?);
    try std.testing.expectEqualStrings("1970-01-01", (try Parameter.postgresText(.{ .date = 0 }, a)).?);
    try std.testing.expectEqualStrings("1969-12-31 23:59:59.999999", (try Parameter.postgresText(.{ .timestamp = -1 }, a)).?);
    try std.testing.expectEqualStrings("00:00:00.000001", (try Parameter.postgresText(.{ .time = 1 }, a)).?);
    try std.testing.expectEqualStrings("1970-01-01 00:00:00+00:00", (try Parameter.postgresText(.{ .timestamp_tz = 0 }, a)).?);
    try std.testing.expectEqualStrings("\\x00ff", (try Parameter.postgresText(.{ .binary = &.{ 0, 255 } }, a)).?);
    try std.testing.expectError(error.InvalidQueryParameter, Parameter.postgresText(.{ .text = "embedded\x00nul" }, a));
}

test "native decimal binding retains trailing scale and exponent without rounding" {
    const a = std.testing.allocator;
    try std.testing.expectEqualDeep(Decimal{ .width = 21, .scale = 21, .coefficient = 123456789012345678901 }, (try decimal(a, "0.123456789012345678901")).?);
    try std.testing.expectEqualDeep(Decimal{ .width = 4, .scale = 2, .coefficient = -1200 }, (try decimal(a, "-12.00")).?);
    try std.testing.expectEqualDeep(Decimal{ .width = 4, .scale = 0, .coefficient = 1200 }, (try decimal(a, "1.2e3")).?);
    try std.testing.expect((try decimal(a, "123456789012345678901234567890123456789")) == null);
    try std.testing.expectError(error.InvalidQueryParameter, decimal(a, "12x"));
}

test "PostgreSQL standalone bindings retain psycopg2 literal inference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(u32, 23), Parameter.postgresType(.{ .integer = "42" }));
    try std.testing.expectEqual(@as(u32, 20), Parameter.postgresType(.{ .integer = "2147483648" }));
    try std.testing.expectEqual(@as(u32, 1700), Parameter.postgresType(.{ .floating = 1.25 }));
    try std.testing.expectEqual(@as(u32, 701), Parameter.postgresType(.{ .floating = std.math.inf(f64) }));
    try std.testing.expectEqualStrings("-0.0", (try Parameter.postgresText(.{ .floating = -0.0 }, a)).?);
    try std.testing.expectEqualStrings("1e+20", (try Parameter.postgresText(.{ .floating = 1e20 }, a)).?);
}
