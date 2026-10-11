//! Stock psycopg2 cursor conversions from owned PostgreSQL text results.
const std = @import("std");
const values = @import("adapter_value.zig");
const datetime = @import("datetime_parse.zig");
pub const Cell = values.Cell;
const Allocator = std.mem.Allocator;

pub const Description = struct {
    name: []const u8,
    type_code: u32,
    display_size: ?i32 = null,
    internal_size: ?i32,
    precision: ?i32 = null,
    scale: ?i32 = null,
    null_ok: ?bool = null,
};

/// The name borrows the owning query column's storage.
pub fn description(name: []const u8, oid: u32, native_size: i32, fmod: i32) Description {
    const modifier = if (fmod > 0) fmod - 4 else fmod;
    var result: Description = .{ .name = name, .type_code = oid, .internal_size = native_size };
    if (oid == 1042 or oid == 1043) result.internal_size = modifier;
    if (oid == 1700) {
        // psycopg2 exposes these raw typmod fields, including the untyped -1
        // and negative-scale encodings, rather than normalized SQL scales.
        result.internal_size = modifier >> 16;
        result.precision = (modifier >> 16) & 65535;
        result.scale = modifier & 65535;
    }
    return result;
}

/// SQL NULL is handled by PQgetisnull before this non-null conversion.
pub fn cell(a: Allocator, oid: u32, text: []const u8) anyerror!Cell {
    if (arrayElement(oid)) |element| return array(a, element, text);
    if (rangeType(oid)) |registered| return range(a, registered, text);
    return switch (oid) {
        16 => if (std.mem.eql(u8, text, "t")) .{ .boolean = true } else if (std.mem.eql(u8, text, "f")) .{ .boolean = false } else error.InvalidPostgresValue,
        20, 21, 23, 26 => blk: {
            try integerText(text);
            break :blk .{ .integer = try a.dupe(u8, text) };
        },
        700, 701 => .{ .floating = try float(text) },
        1700 => blk: {
            if (!specialNumber(text)) _ = std.fmt.parseFloat(f64, text) catch return error.InvalidPostgresValue;
            break :blk .{ .decimal = try a.dupe(u8, text) };
        },
        17 => .{ .memoryview = try binary(a, text) },
        114, 3802 => try json(a, text),
        1082 => try date(a, text),
        1083, 1266 => try time(a, text),
        1114, 1184 => try timestamp(a, text, oid == 1184),
        704, 1186 => try interval(text),
        // UUID, money and unregistered composite/array types are strings in
        // the stock Core PostgreSQL connection, without custom registrations.
        else => .{ .text = try a.dupe(u8, text) },
    };
}

fn integerText(text: []const u8) !void {
    const start: usize = if (text.len != 0 and (text[0] == '-' or text[0] == '+')) 1 else 0;
    if (start == text.len) return error.InvalidPostgresValue;
    for (text[start..]) |c| if (!std.ascii.isDigit(c)) return error.InvalidPostgresValue;
}
fn specialNumber(text: []const u8) bool {
    return std.mem.eql(u8, text, "NaN") or std.mem.eql(u8, text, "Infinity") or std.mem.eql(u8, text, "-Infinity");
}
fn float(text: []const u8) !f64 {
    if (std.mem.eql(u8, text, "NaN")) return std.math.nan(f64);
    if (std.mem.eql(u8, text, "Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, text, "-Infinity")) return -std.math.inf(f64);
    return std.fmt.parseFloat(f64, text) catch error.InvalidPostgresValue;
}

fn binary(a: Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    if (std.mem.startsWith(u8, text, "\\x")) {
        if ((text.len - 2) % 2 != 0) return error.InvalidPostgresValue;
        var at: usize = 2;
        while (at < text.len) : (at += 2) {
            try output.append(a, std.fmt.parseInt(u8, text[at..][0..2], 16) catch return error.InvalidPostgresValue);
        }
    } else {
        var at: usize = 0;
        while (at < text.len) {
            if (text[at] != '\\') {
                try output.append(a, text[at]);
                at += 1;
            } else if (at + 1 < text.len and text[at + 1] == '\\') {
                try output.append(a, '\\');
                at += 2;
            } else {
                if (at + 4 > text.len) return error.InvalidPostgresValue;
                for (text[at + 1 ..][0..3]) |c| if (c < '0' or c > '7') return error.InvalidPostgresValue;
                try output.append(a, std.fmt.parseInt(u8, text[at + 1 ..][0..3], 8) catch return error.InvalidPostgresValue);
                at += 4;
            }
        }
    }
    return output.toOwnedSlice(a);
}

fn json(a: Allocator, text: []const u8) !Cell {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{ .allocate = .alloc_always, .parse_numbers = false, .duplicate_field_behavior = .use_last });
    defer parsed.deinit();
    return jsonValue(a, parsed.value);
}
fn jsonValue(a: Allocator, value: std.json.Value) anyerror!Cell {
    return switch (value) {
        .null => .none,
        .bool => |v| .{ .boolean = v },
        .string => |v| .{ .text = try a.dupe(u8, v) },
        .number_string => |v| if (std.mem.indexOfAny(u8, v, ".eE") == null) .{ .integer = try a.dupe(u8, v) } else .{ .floating = try float(v) },
        .integer => |v| .{ .integer = try std.fmt.allocPrint(a, "{d}", .{v}) },
        .float => |v| .{ .floating = v },
        .array => |v| blk: {
            const items = try a.alloc(Cell, v.items.len);
            var initialized: usize = 0;
            errdefer {
                for (items[0..initialized]) |*item| item.deinit(a);
                a.free(items);
            }
            for (v.items, items) |input, *item| {
                item.* = try jsonValue(a, input);
                initialized += 1;
            }
            break :blk .{ .list = items };
        },
        .object => |v| blk: {
            const fields = try a.alloc(values.Field, v.count());
            var initialized: usize = 0;
            errdefer {
                for (fields[0..initialized]) |*field| {
                    a.free(field.name);
                    field.value.deinit(a);
                }
                a.free(fields);
            }
            var entries = v.iterator();
            while (entries.next()) |entry| {
                const name = try a.dupe(u8, entry.key_ptr.*);
                errdefer a.free(name);
                fields[initialized] = .{ .name = name, .value = try jsonValue(a, entry.value_ptr.*) };
                initialized += 1;
            }
            break :blk .{ .object = fields };
        },
    };
}

fn arrayElement(oid: u32) ?u32 {
    return switch (oid) {
        1000 => 16,
        1001 => 17,
        1002, 1003, 1009, 1014, 1015, 651, 1040, 1041 => 25,
        1005, 1006 => 21,
        1007 => 23,
        1016 => 20,
        1013, 1028 => 26,
        1021 => 700,
        1022 => 701,
        1182 => 1082,
        1183 => 1083,
        1270 => 1266,
        1115 => 1114,
        1185 => 1184,
        1187 => 1186,
        1231 => 1700,
        199 => 114,
        3807 => 3802,
        3905 => 3904,
        3927 => 3926,
        3907 => 3906,
        3913 => 3912,
        3909 => 3908,
        3911 => 3910,
        else => null,
    };
}

const RangeKind = @TypeOf(@as(values.Range, undefined).kind);
const RegisteredRange = struct { kind: RangeKind, subtype: u32 };
fn rangeType(oid: u32) ?RegisteredRange {
    return switch (oid) {
        3904 => .{ .kind = .numeric, .subtype = 23 },
        3926 => .{ .kind = .numeric, .subtype = 20 },
        3906 => .{ .kind = .numeric, .subtype = 1700 },
        3912 => .{ .kind = .date, .subtype = 1082 },
        3908 => .{ .kind = .datetime, .subtype = 1114 },
        3910 => .{ .kind = .datetimetz, .subtype = 1184 },
        else => null,
    };
}
fn range(a: Allocator, registered: RegisteredRange, text: []const u8) !Cell {
    var result: Cell = .{ .range = .{ .kind = registered.kind } };
    errdefer result.deinit(a);
    if (std.mem.eql(u8, text, "empty")) {
        result.range.empty = true;
        return result;
    }
    if (text.len < 3 or (text[0] != '(' and text[0] != '[')) return error.InvalidPostgresValue;
    const last = text[text.len - 1];
    if (last != ')' and last != ']') return error.InvalidPostgresValue;
    result.range.bounds = .{ text[0], last };
    var parser: RangeParser = .{ .a = a, .subtype = registered.subtype, .text = text[1 .. text.len - 1] };
    result.range.lower = try parser.bound(',');
    if (parser.at >= parser.text.len or parser.text[parser.at] != ',') return error.InvalidPostgresValue;
    parser.at += 1;
    result.range.upper = try parser.bound(null);
    if (parser.at != parser.text.len) return error.InvalidPostgresValue;
    return result;
}
const RangeParser = struct {
    a: Allocator,
    subtype: u32,
    text: []const u8,
    at: usize = 0,
    fn bound(self: *RangeParser, delimiter: ?u8) !?*Cell {
        if (self.at == self.text.len or (delimiter != null and self.text[self.at] == delimiter.?)) return null;
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.a);
        if (self.text[self.at] == '"') {
            self.at += 1;
            var closed = false;
            while (self.at < self.text.len) {
                const character = self.text[self.at];
                self.at += 1;
                if ((character == '"' or character == '\\') and self.at < self.text.len and self.text[self.at] == character) {
                    self.at += 1;
                } else if (character == '"') {
                    closed = true;
                    break;
                }
                try bytes.append(self.a, character);
            }
            if (!closed) return error.InvalidPostgresValue;
        } else {
            while (self.at < self.text.len and (delimiter == null or self.text[self.at] != delimiter.?)) : (self.at += 1) {
                if (self.text[self.at] == '"') return error.InvalidPostgresValue;
                try bytes.append(self.a, self.text[self.at]);
            }
        }
        const output = try self.a.create(Cell);
        errdefer self.a.destroy(output);
        output.* = try cell(self.a, self.subtype, bytes.items);
        return output;
    }
};
fn array(a: Allocator, element: u32, text: []const u8) !Cell {
    var parser: ArrayParser = .{ .a = a, .element = element, .text = text };
    if (text.len != 0 and text[0] == '[') parser.at = (std.mem.indexOfScalar(u8, text, '=') orelse return error.InvalidPostgresValue) + 1;
    var result = try parser.members(0);
    errdefer result.deinit(a);
    if (parser.at != text.len) return error.InvalidPostgresValue;
    return result;
}
const ArrayParser = struct {
    a: Allocator,
    element: u32,
    text: []const u8,
    at: usize = 0,
    fn members(self: *ArrayParser, depth: usize) anyerror!Cell {
        if (depth > 64 or self.at >= self.text.len or self.text[self.at] != '{') return error.InvalidPostgresValue;
        self.at += 1;
        var items: std.ArrayList(Cell) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(self.a);
            items.deinit(self.a);
        }
        if (self.at < self.text.len and self.text[self.at] == '}') {
            self.at += 1;
            return .{ .list = try items.toOwnedSlice(self.a) };
        }
        while (self.at < self.text.len) {
            var item = if (self.text[self.at] == '{') try self.members(depth + 1) else try self.scalar();
            items.append(self.a, item) catch |err| {
                item.deinit(self.a);
                return err;
            };
            if (self.at >= self.text.len) return error.InvalidPostgresValue;
            const separator = self.text[self.at];
            self.at += 1;
            if (separator == '}') return .{ .list = try items.toOwnedSlice(self.a) };
            if (separator != ',' or self.at >= self.text.len or self.text[self.at] == '}') return error.InvalidPostgresValue;
        }
        return error.InvalidPostgresValue;
    }
    fn scalar(self: *ArrayParser) !Cell {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.a);
        const quoted = self.text[self.at] == '"';
        if (quoted) self.at += 1;
        var closed = !quoted;
        while (self.at < self.text.len) {
            const c = self.text[self.at];
            if (!quoted and (c == ',' or c == '}')) break;
            self.at += 1;
            if (quoted and c == '"') {
                closed = true;
                break;
            }
            if (c == '\\') {
                if (self.at >= self.text.len) return error.InvalidPostgresValue;
                try bytes.append(self.a, self.text[self.at]);
                self.at += 1;
            } else try bytes.append(self.a, c);
        }
        if (!closed or (!quoted and bytes.items.len == 0)) return error.InvalidPostgresValue;
        if (!quoted and std.ascii.eqlIgnoreCase(bytes.items, "NULL")) return .none;
        return cell(self.a, self.element, bytes.items);
    }
};

const min_micros: i64 = -62135596800000000;
const max_micros: i64 = 253402300799999999;
fn date(a: Allocator, text: []const u8) !Cell {
    if (std.mem.eql(u8, text, "infinity")) return .{ .date = 2932896 };
    if (std.mem.eql(u8, text, "-infinity")) return .{ .date = -719162 };
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const parsed = try datetime.iso(scratch.allocator(), text, true);
    return .{ .date = std.math.cast(i32, @divFloor(parsed.civil_ns, std.time.ns_per_day)) orelse return error.InvalidPostgresValue };
}
fn clock(text: []const u8, allow_large_hours: bool) !i64 {
    var body = text;
    var sign: i64 = 1;
    if (body.len != 0 and (body[0] == '-' or body[0] == '+')) {
        sign = if (body[0] == '-') -1 else 1;
        body = body[1..];
    }
    var fields = std.mem.splitScalar(u8, body, ':');
    const hour = std.fmt.parseInt(i64, fields.next() orelse return error.InvalidPostgresValue, 10) catch return error.InvalidPostgresValue;
    const minute = std.fmt.parseInt(i64, fields.next() orelse return error.InvalidPostgresValue, 10) catch return error.InvalidPostgresValue;
    const last = fields.next() orelse "0";
    if (fields.next() != null) return error.InvalidPostgresValue;
    const dot = std.mem.indexOfScalar(u8, last, '.');
    const second = std.fmt.parseInt(i64, last[0 .. dot orelse last.len], 10) catch return error.InvalidPostgresValue;
    var micros: i64 = 0;
    if (dot) |at| {
        const fraction = last[at + 1 ..];
        if (fraction.len == 0 or fraction.len > 6) return error.InvalidPostgresValue;
        for (fraction) |c| if (!std.ascii.isDigit(c)) return error.InvalidPostgresValue;
        micros = std.fmt.parseInt(i64, fraction, 10) catch return error.InvalidPostgresValue;
        for (fraction.len..6) |_| micros *= 10;
    }
    if (hour < 0 or (!allow_large_hours and hour >= 24) or minute < 0 or minute > 59 or second < 0 or second > 59) return error.InvalidPostgresValue;
    const hours = std.math.mul(i64, hour, std.time.us_per_hour) catch return error.InvalidPostgresValue;
    const rest = minute * std.time.us_per_min + second * std.time.us_per_s + micros;
    return sign * (std.math.add(i64, hours, rest) catch return error.InvalidPostgresValue);
}
fn time(a: Allocator, text: []const u8) !Cell {
    const zone = std.mem.indexOfAny(u8, text, "+-");
    const body = text[0 .. zone orelse text.len];
    const micros = if (std.mem.startsWith(u8, body, "24:00:00")) blk: {
        // PostgreSQL stores 24:00; psycopg2 returns midnight on the clock.
        const normalized = try std.fmt.allocPrint(a, "00{s}", .{body[2..]});
        defer a.free(normalized);
        break :blk try clock(normalized, false);
    } else try clock(body, false);
    var offset: ?i64 = null;
    if (zone) |at| {
        const label = text[at + 1 ..];
        const magnitude = if (std.mem.indexOfScalar(u8, label, ':') == null)
            std.math.mul(i64, std.fmt.parseInt(i64, label, 10) catch return error.InvalidPostgresValue, std.time.us_per_hour) catch return error.InvalidPostgresValue
        else
            try clock(label, false);
        if (magnitude < 0 or magnitude >= std.time.us_per_day) return error.InvalidPostgresValue;
        offset = if (text[at] == '-') -magnitude else magnitude;
    }
    return .{ .time = .{ .micros = micros, .offset_us = offset } };
}
fn timestamp(a: Allocator, text: []const u8, aware: bool) !Cell {
    if (std.mem.eql(u8, text, "infinity") or std.mem.eql(u8, text, "-infinity")) return .{ .timestamp = .{
        .micros = if (text[0] == '-') min_micros else max_micros,
        .offset_us = if (aware) 0 else null,
    } };
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const parsed = try datetime.iso(scratch.allocator(), text, false);
    if (aware != (parsed.offset_us != null)) return error.InvalidPostgresValue;
    var micros = std.math.cast(i64, @divTrunc(parsed.civil_ns, std.time.ns_per_us)) orelse return error.InvalidPostgresValue;
    if (parsed.offset_us) |offset| micros = std.math.sub(i64, micros, offset) catch return error.InvalidPostgresValue;
    return .{ .timestamp = .{ .micros = micros, .offset_us = parsed.offset_us } };
}
fn interval(text: []const u8) !Cell {
    if (std.mem.startsWith(u8, text, "P")) return error.UnsupportedPostgresIntervalStyle;
    var tokens = std.mem.tokenizeScalar(u8, text, ' ');
    var days: i64 = 0;
    var micros: i64 = 0;
    var negate = false;
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "@")) continue;
        if (std.mem.eql(u8, token, "ago")) {
            negate = true;
            continue;
        }
        if (std.mem.indexOfScalar(u8, token, ':') != null) {
            micros = std.math.add(i64, micros, try clock(token, true)) catch return error.InvalidPostgresValue;
        } else {
            const amount = std.fmt.parseInt(i64, token, 10) catch return error.InvalidPostgresValue;
            const unit = tokens.next() orelse return error.InvalidPostgresValue;
            const multiplier: i64 = if (std.mem.startsWith(u8, unit, "year")) 365 else if (std.mem.startsWith(u8, unit, "mon")) 30 else if (std.mem.startsWith(u8, unit, "day")) 1 else return error.InvalidPostgresValue;
            days = std.math.add(i64, days, std.math.mul(i64, amount, multiplier) catch return error.InvalidPostgresValue) catch return error.InvalidPostgresValue;
        }
    }
    if (negate) {
        days = std.math.negate(days) catch return error.InvalidPostgresValue;
        micros = std.math.negate(micros) catch return error.InvalidPostgresValue;
    }
    days = std.math.add(i64, days, @divFloor(micros, std.time.us_per_day)) catch return error.InvalidPostgresValue;
    if (days < -999999999 or days > 999999999) return error.InvalidPostgresValue;
    return .{ .interval = .{ .months = 0, .days = @intCast(days), .micros = @mod(micros, std.time.us_per_day) } };
}

test "PostgreSQL description preserves stock psycopg2 raw typmods" {
    const cases = [_]struct { oid: u32, size: i32, modifier: i32, internal: i32, precision: ?i32 = null, scale: ?i32 = null }{
        .{ .oid = 23, .size = 4, .modifier = -1, .internal = 4 },
        .{ .oid = 1266, .size = 12, .modifier = -1, .internal = 12 },
        .{ .oid = 1043, .size = -1, .modifier = 11, .internal = 7 },
        .{ .oid = 1042, .size = -1, .modifier = 9, .internal = 5 },
        .{ .oid = 1043, .size = -1, .modifier = -1, .internal = -1 },
        .{ .oid = 1700, .size = -1, .modifier = 1966092, .internal = 30, .precision = 30, .scale = 8 },
        .{ .oid = 1700, .size = -1, .modifier = -1, .internal = -1, .precision = 65535, .scale = 65535 },
        .{ .oid = 1700, .size = -1, .modifier = 329730, .internal = 5, .precision = 5, .scale = 2046 },
        .{ .oid = 1700, .size = -1, .modifier = 196617, .internal = 3, .precision = 3, .scale = 5 },
    };
    for (cases) |input| {
        const output = description("column", input.oid, input.size, input.modifier);
        try std.testing.expectEqualStrings("column", output.name);
        try std.testing.expectEqual(input.oid, output.type_code);
        try std.testing.expectEqual(@as(?i32, input.internal), output.internal_size);
        try std.testing.expectEqual(input.precision, output.precision);
        try std.testing.expectEqual(input.scale, output.scale);
        try std.testing.expect(output.display_size == null and output.null_ok == null);
    }
}

test "PostgreSQL numeric and fallback text cells own exact wire values" {
    const a = std.testing.allocator;
    const cases = [_]struct { oid: u32, text: []const u8, tag: std.meta.Tag(Cell) }{
        .{ .oid = 20, .text = "-9223372036854775808", .tag = .integer },
        .{ .oid = 26, .text = "4294967295", .tag = .integer },
        .{ .oid = 1700, .text = "1234567890123456789012.12345678", .tag = .decimal },
        .{ .oid = 1700, .text = "3.1415926535897932384626433832795028841971", .tag = .decimal },
        .{ .oid = 1700, .text = "Infinity", .tag = .decimal },
        .{ .oid = 1700, .text = "NaN", .tag = .decimal },
        .{ .oid = 1042, .text = "xy   ", .tag = .text },
        .{ .oid = 2950, .text = "01234567-89ab-cdef-0123-456789abcdef", .tag = .text },
        .{ .oid = 2951, .text = "{01234567-89ab-cdef-0123-456789abcdef}", .tag = .text },
        .{ .oid = 790, .text = "$1,234.56", .tag = .text },
        .{ .oid = 16387, .text = "(7,\"two,quoted\")", .tag = .text },
    };
    for (cases) |input| {
        const borrowed = try a.dupe(u8, input.text);
        var output = cell(a, input.oid, borrowed) catch |err| {
            a.free(borrowed);
            return err;
        };
        a.free(borrowed);
        defer output.deinit(a);
        try std.testing.expectEqual(input.tag, std.meta.activeTag(output));
        const actual = switch (output) {
            .integer, .decimal, .text => |v| v,
            else => unreachable,
        };
        try std.testing.expectEqualStrings(input.text, actual);
    }
    try std.testing.expectEqual(true, (try cell(a, 16, "t")).boolean);
    try std.testing.expectEqual(false, (try cell(a, 16, "f")).boolean);
    try std.testing.expectEqual(@as(f64, 1.25), (try cell(a, 700, "1.25")).floating);
    try std.testing.expect(std.math.isNan((try cell(a, 701, "NaN")).floating));
    try std.testing.expectEqual(-std.math.inf(f64), (try cell(a, 701, "-Infinity")).floating);
    try std.testing.expectError(error.InvalidPostgresValue, cell(a, 23, "12oops"));
    try std.testing.expectError(error.InvalidPostgresValue, cell(a, 16, "True"));
}

test "PostgreSQL bytea decodes hex and escape output as owned memoryview" {
    const a = std.testing.allocator;
    var hex = try cell(a, 17, "\\x00ff414200");
    defer hex.deinit(a);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 65, 66, 0 }, hex.memoryview);
    var escaped = try cell(a, 17, "\\000\\377AB\\000\\\\");
    defer escaped.deinit(a);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 65, 66, 0, '\\' }, escaped.memoryview);
    for ([_][]const u8{ "\\x0", "\\xgg", "\\999", "\\40" }) |bad| try std.testing.expectError(error.InvalidPostgresValue, cell(a, 17, bad));
}

test "PostgreSQL JSON keeps exact integers and recursively owned native values" {
    const a = std.testing.allocator;
    var output = try cell(a, 114, "{\"n\":922337203685477580812345,\"x\":[true,null,1.25,\"a\\u0000b\"],\"n\":922337203685477580812346}");
    defer output.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), output.object.len);
    try std.testing.expectEqualStrings("n", output.object[0].name);
    try std.testing.expectEqualStrings("922337203685477580812346", output.object[0].value.integer);
    const items = output.object[1].value.list;
    try std.testing.expectEqual(true, items[0].boolean);
    try std.testing.expectEqual(.none, std.meta.activeTag(items[1]));
    try std.testing.expectEqual(@as(f64, 1.25), items[2].floating);
    try std.testing.expectEqualSlices(u8, &.{ 'a', 0, 'b' }, items[3].text);
    var scalar = try cell(a, 3802, "1e3");
    defer scalar.deinit(a);
    try std.testing.expectEqual(@as(f64, 1000), scalar.floating);
}

test "PostgreSQL arrays preserve nesting nulls escaping and disregard lower bounds" {
    const a = std.testing.allocator;
    var numbers = try cell(a, 1007, "[0:1][4:5]={{1,NULL},{3,4}}");
    defer numbers.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), numbers.list.len);
    try std.testing.expectEqualStrings("1", numbers.list[0].list[0].integer);
    try std.testing.expectEqual(.none, std.meta.activeTag(numbers.list[0].list[1]));
    try std.testing.expectEqualStrings("4", numbers.list[1].list[1].integer);
    var texts = try cell(a, 1009, "{\"NULL\",NULL,\"a,b\",\"a\\\"b\",\"a\\\\b\",\"\"}");
    defer texts.deinit(a);
    try std.testing.expectEqualStrings("NULL", texts.list[0].text);
    try std.testing.expectEqual(.none, std.meta.activeTag(texts.list[1]));
    try std.testing.expectEqualStrings("a,b", texts.list[2].text);
    try std.testing.expectEqualStrings("a\"b", texts.list[3].text);
    try std.testing.expectEqualStrings("a\\b", texts.list[4].text);
    try std.testing.expectEqualStrings("", texts.list[5].text);
    var empty = try cell(a, 1007, "{}");
    defer empty.deinit(a);
    try std.testing.expectEqual(@as(usize, 0), empty.list.len);
    var decimals = try cell(a, 1231, "{1.234567890123456789,NaN,NULL}");
    defer decimals.deinit(a);
    try std.testing.expectEqualStrings("1.234567890123456789", decimals.list[0].decimal);
    try std.testing.expectEqualStrings("NaN", decimals.list[1].decimal);
    var binaries = try cell(a, 1001, "{\"\\\\x00ff\",NULL}");
    defer binaries.deinit(a);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255 }, binaries.list[0].memoryview);
    var objects = try cell(a, 3807, "{\"{\\\"a\\\": [1, null]}\"}");
    defer objects.deinit(a);
    try std.testing.expectEqualStrings("a", objects.list[0].object[0].name);
    try std.testing.expectEqual(.none, std.meta.activeTag(objects.list[0].object[0].value.list[1]));
}

test "PostgreSQL malformed array cleanup frees already transferred cells once" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "{a", "{a,}", "{{a},}", "{\"a\"x}", "{\"a}", "{a}junk", "[1:2]junk", "{{a},b" }) |bad| {
        try std.testing.expectError(error.InvalidPostgresValue, cell(a, 1009, bad));
    }
}

fn allocationFailureFixture(a: Allocator) !void {
    var parsed = try cell(a, 1009, "{{\"a,b\",NULL},{\"a\\\\b\",\"\"}}");
    defer parsed.deinit(a);
    var object = try cell(a, 3802, "{\"a\":[{\"n\":922337203685477580812345},null],\"b\":\"text\"}");
    defer object.deinit(a);
    var ranges = try cell(a, 3907, "{\"[1.234567890123456789,9.876543210987654321)\",empty,NULL}");
    defer ranges.deinit(a);
}

test "PostgreSQL recursive cursor ownership cleans every failed allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureFixture, .{});
}

test "PostgreSQL numeric ranges retain typed exact and unbounded endpoints" {
    const a = std.testing.allocator;
    var integer = try cell(a, 3904, "[1,3)");
    defer integer.deinit(a);
    try std.testing.expectEqual(.numeric, integer.range.kind);
    try std.testing.expectEqualStrings("1", integer.range.lower.?.integer);
    try std.testing.expectEqualStrings("3", integer.range.upper.?.integer);
    try std.testing.expectEqualSlices(u8, "[)", &integer.range.bounds);
    var decimal = try cell(a, 3906, "(1.234567890123456789,9.876543210987654321]");
    defer decimal.deinit(a);
    try std.testing.expectEqualStrings("1.234567890123456789", decimal.range.lower.?.decimal);
    try std.testing.expectEqualStrings("9.876543210987654321", decimal.range.upper.?.decimal);
    try std.testing.expectEqualSlices(u8, "(]", &decimal.range.bounds);
    var unbounded = try cell(a, 3926, "(,9223372036854775807)");
    defer unbounded.deinit(a);
    try std.testing.expect(unbounded.range.lower == null);
    try std.testing.expectEqualStrings("9223372036854775807", unbounded.range.upper.?.integer);
    var lower_boundary = try cell(a, 3926, "[-9223372036854775808,-9223372036854775806)");
    defer lower_boundary.deinit(a);
    try std.testing.expectEqualStrings("-9223372036854775808", lower_boundary.range.lower.?.integer);
    try std.testing.expectEqualStrings("-9223372036854775806", lower_boundary.range.upper.?.integer);
    var empty = try cell(a, 3906, "empty");
    defer empty.deinit(a);
    try std.testing.expect(empty.range.empty and empty.range.lower == null and empty.range.upper == null);
    var infinite = try cell(a, 3906, "[-Infinity,Infinity]");
    defer infinite.deinit(a);
    try std.testing.expectEqualStrings("-Infinity", infinite.range.lower.?.decimal);
    try std.testing.expectEqualStrings("Infinity", infinite.range.upper.?.decimal);
    var nan = try cell(a, 3906, "[NaN,NaN]");
    defer nan.deinit(a);
    try std.testing.expectEqualStrings("NaN", nan.range.lower.?.decimal);
    try std.testing.expectEqualStrings("NaN", nan.range.upper.?.decimal);
    var all = try cell(a, 3904, "(,)");
    defer all.deinit(a);
    try std.testing.expect(!all.range.empty and all.range.lower == null and all.range.upper == null);
    try std.testing.expectEqualSlices(u8, "()", &all.range.bounds);
}

test "PostgreSQL date and timestamp ranges cast their quoted typed endpoints" {
    const a = std.testing.allocator;
    var dates = try cell(a, 3912, "[0001-01-01,infinity)");
    defer dates.deinit(a);
    try std.testing.expectEqual(.date, dates.range.kind);
    try std.testing.expectEqual(@as(i32, -719162), dates.range.lower.?.date);
    try std.testing.expectEqual(@as(i32, 2932896), dates.range.upper.?.date);
    var naive = try cell(a, 3908, "[\"2024-02-29 00:00:00\",\"2024-02-29 12:34:56.123456\")");
    defer naive.deinit(a);
    try std.testing.expectEqual(.datetime, naive.range.kind);
    try std.testing.expectEqual(@as(i64, 1709164800000000), naive.range.lower.?.timestamp.micros);
    try std.testing.expectEqual(@as(i64, 1709210096123456), naive.range.upper.?.timestamp.micros);
    var aware = try cell(a, 3910, "[\"2024-02-29 05:30:26+05:30:26\",infinity)");
    defer aware.deinit(a);
    try std.testing.expectEqual(.datetimetz, aware.range.kind);
    try std.testing.expectEqual(@as(i64, 1709164800000000), aware.range.lower.?.timestamp.micros);
    try std.testing.expectEqual(@as(?i64, 19826000000), aware.range.lower.?.timestamp.offset_us);
    try std.testing.expectEqual(max_micros, aware.range.upper.?.timestamp.micros);
    try std.testing.expectEqual(@as(?i64, 0), aware.range.upper.?.timestamp.offset_us);
}

test "PostgreSQL registered range arrays retain typed nested null and empty members" {
    const a = std.testing.allocator;
    var array_ranges = try cell(a, 3905, "[2:4]={\"[1,3)\",NULL,empty}");
    defer array_ranges.deinit(a);
    try std.testing.expectEqualStrings("3", array_ranges.list[0].range.upper.?.integer);
    try std.testing.expectEqual(.none, std.meta.activeTag(array_ranges.list[1]));
    try std.testing.expect(array_ranges.list[2].range.empty);
    const pairs = [_]struct { oid: u32, kind: RangeKind }{
        .{ .oid = 3927, .kind = .numeric },    .{ .oid = 3907, .kind = .numeric },
        .{ .oid = 3913, .kind = .date },       .{ .oid = 3909, .kind = .datetime },
        .{ .oid = 3911, .kind = .datetimetz },
    };
    for (pairs) |input| {
        var output = try cell(a, input.oid, "{{empty,NULL},{empty,empty}}");
        defer output.deinit(a);
        try std.testing.expectEqual(input.kind, output.list[0].list[0].range.kind);
        try std.testing.expectEqual(.none, std.meta.activeTag(output.list[0].list[1]));
    }
    for ([_][]const u8{ "", "garbage", "[1,2", "[\"1,2)", "[1,2,3)", "[1,\"2\"x)" }) |bad| {
        try std.testing.expectError(error.InvalidPostgresValue, cell(a, 3904, bad));
    }
}

test "PostgreSQL timestamp range arrays decode the server's nested quote escapes" {
    const a = std.testing.allocator;
    const naive_wire =
        \\{"(\"2024-02-29 00:00:00.000001\",\"2024-02-29 12:34:56.123456\"]",empty,"(,)",NULL}
    ;
    var naive = try cell(a, 3909, naive_wire);
    defer naive.deinit(a);
    const first = naive.list[0].range;
    try std.testing.expectEqual(@as(i64, 1709164800000001), first.lower.?.timestamp.micros);
    try std.testing.expectEqual(@as(i64, 1709210096123456), first.upper.?.timestamp.micros);
    try std.testing.expectEqualSlices(u8, "(]", &first.bounds);
    try std.testing.expect(naive.list[1].range.empty);
    try std.testing.expect(naive.list[2].range.lower == null and naive.list[2].range.upper == null);
    try std.testing.expectEqual(.none, std.meta.activeTag(naive.list[3]));
    const aware_wire =
        \\{"[\"2024-02-29 05:30:26+05:30:26\",\"2024-02-29 18:05:22.123456+05:30:26\")",empty,"(,)",NULL}
    ;
    var aware = try cell(a, 3911, aware_wire);
    defer aware.deinit(a);
    const shifted = aware.list[0].range;
    try std.testing.expectEqual(@as(i64, 1709164800000000), shifted.lower.?.timestamp.micros);
    try std.testing.expectEqual(@as(i64, 1709210096123456), shifted.upper.?.timestamp.micros);
    try std.testing.expectEqual(@as(?i64, 19826000000), shifted.lower.?.timestamp.offset_us);
    try std.testing.expectEqual(@as(?i64, 19826000000), shifted.upper.?.timestamp.offset_us);
}

test "PostgreSQL dates and timestamp boundaries match Python year limits" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(i32, -719162), (try cell(a, 1082, "0001-01-01")).date);
    try std.testing.expectEqual(@as(i32, 2932896), (try cell(a, 1082, "9999-12-31")).date);
    try std.testing.expectEqual(@as(i32, -719162), (try cell(a, 1082, "-infinity")).date);
    try std.testing.expectEqual(@as(i32, 2932896), (try cell(a, 1082, "infinity")).date);
    try std.testing.expectEqual(min_micros, (try cell(a, 1114, "0001-01-01 00:00:00")).timestamp.micros);
    try std.testing.expectEqual(max_micros, (try cell(a, 1114, "9999-12-31 23:59:59.999999")).timestamp.micros);
    for ([_][]const u8{ "10000-01-01", "0001-01-01 BC", "2023-02-29" }) |bad| try std.testing.expectError(error.InvalidDatetime, cell(a, 1082, bad));
    for ([_][]const u8{ "10000-01-01 00:00:00", "0001-01-01 00:00:00 BC" }) |bad| try std.testing.expectError(error.InvalidDatetime, cell(a, 1114, bad));
    for ([_]u32{ 1114, 1184 }) |oid| {
        const first = (try cell(a, oid, "-infinity")).timestamp;
        const last = (try cell(a, oid, "infinity")).timestamp;
        try std.testing.expectEqual(min_micros, first.micros);
        try std.testing.expectEqual(max_micros, last.micros);
        try std.testing.expectEqual(@as(?i64, if (oid == 1184) 0 else null), first.offset_us);
        try std.testing.expectEqual(first.offset_us, last.offset_us);
    }
}

test "PostgreSQL times keep microseconds and fixed subminute offsets" {
    const a = std.testing.allocator;
    const local = (try cell(a, 1083, "12:34:56.123456")).time;
    try std.testing.expectEqual(@as(i64, 45296123456), local.micros);
    try std.testing.expectEqual(@as(?i64, null), local.offset_us);
    const positive = (try cell(a, 1266, "12:34:56.123456+09:30:26")).time;
    try std.testing.expectEqual(local.micros, positive.micros);
    try std.testing.expectEqual(@as(?i64, 34226000000), positive.offset_us);
    const negative = (try cell(a, 1266, "12:34:56.000001-03:30:45")).time;
    try std.testing.expectEqual(@as(i64, 45296000001), negative.micros);
    try std.testing.expectEqual(@as(?i64, -12645000000), negative.offset_us);
    try std.testing.expectEqual(@as(i64, 0), (try cell(a, 1083, "24:00:00")).time.micros);
    const midnight = (try cell(a, 1266, "24:00:00+05:30:45")).time;
    try std.testing.expectEqual(@as(i64, 0), midnight.micros);
    try std.testing.expectEqual(@as(?i64, 19845000000), midnight.offset_us);
    try std.testing.expectError(error.InvalidPostgresValue, cell(a, 1083, "25:00:00"));
    try std.testing.expectError(error.InvalidPostgresValue, cell(a, 1266, "00:00:00+24"));
}

test "PostgreSQL aware timestamps retain fixed offsets on UTC epoch microseconds" {
    const a = std.testing.allocator;
    const utc = (try cell(a, 1184, "2024-02-29 03:04:30.123456+00")).timestamp;
    try std.testing.expectEqual(@as(i64, 1709175870123456), utc.micros);
    try std.testing.expectEqual(@as(?i64, 0), utc.offset_us);
    const shifted = (try cell(a, 1184, "2024-02-29 05:30:26+05:30:26")).timestamp;
    try std.testing.expectEqual(@as(i64, 1709164800000000), shifted.micros);
    try std.testing.expectEqual(@as(?i64, 19826000000), shifted.offset_us);
    try std.testing.expectEqual(@as(?[]const u8, null), shifted.timezone);
    const naive = (try cell(a, 1114, "2024-02-29 12:34:56.123456")).timestamp;
    try std.testing.expectEqual(@as(i64, 1709210096123456), naive.micros);
    try std.testing.expectEqual(@as(?i64, null), naive.offset_us);
    try std.testing.expectError(error.InvalidPostgresValue, cell(a, 1184, "2024-02-29 00:00:00"));
    try std.testing.expectError(error.InvalidPostgresValue, cell(a, 1114, "2024-02-29 00:00:00+00"));
}

test "PostgreSQL interval conversion matches stock driver year month and negative rules" {
    const positive = (try cell(std.testing.allocator, 1186, "2 years 3 mons 4 days 05:06:07.000008")).interval;
    try std.testing.expectEqual(@as(i32, 0), positive.months);
    try std.testing.expectEqual(@as(i32, 824), positive.days);
    try std.testing.expectEqual(@as(i64, 18367000008), positive.micros);
    const negative = (try cell(std.testing.allocator, 1186, "-1 mons -2 days -03:04:05.000006")).interval;
    try std.testing.expectEqual(@as(i32, -33), negative.days);
    try std.testing.expectEqual(@as(i64, 75354999994), negative.micros);
    const rounded = (try cell(std.testing.allocator, 1186, "00:00:00.000001")).interval;
    try std.testing.expectEqual(@as(i32, 0), rounded.days);
    try std.testing.expectEqual(@as(i64, 1), rounded.micros);
    const hours = (try cell(std.testing.allocator, 1186, "100:00:00")).interval;
    try std.testing.expectEqual(@as(i32, 4), hours.days);
    try std.testing.expectEqual(@as(i64, 4 * std.time.us_per_hour), hours.micros);
    try std.testing.expectError(error.InvalidPostgresValue, cell(std.testing.allocator, 1186, "1000000000 days"));
    try std.testing.expectError(error.UnsupportedPostgresIntervalStyle, cell(std.testing.allocator, 1186, "P1D"));
}
