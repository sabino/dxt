//! SafeLoader's bytes and timestamp scalars retain their runtime identities.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const Argument = expression.Argument;
const temporal = @import("datetime_operations.zig");
const timestamps = @import("timestamp_context.zig");

const Timestamp = struct { ns: i96, date: bool, offset: ?i64, timezone: ?Value = null, fold: u1 = 0 };

fn timestamp(value: Value) ?Timestamp {
    if (timestamps.state(value)) |state| return .{ .ns = state.civil_ns, .date = state.date_only, .offset = state.offset_us, .timezone = state.timezone, .fold = state.fold };
    const method = value.attribute("isoformat");
    const prefix = "__dxt_datetime:isoformat:";
    if (method != .callable or !std.mem.startsWith(u8, method.callable, prefix)) return null;
    var parts = std.mem.splitScalar(u8, method.callable[prefix.len..], ':');
    const ns = std.fmt.parseInt(i96, parts.next() orelse return null, 10) catch return null;
    const kind = parts.next() orelse return null;
    const zone = parts.next() orelse return null;
    return .{ .ns = ns, .date = std.mem.eql(u8, kind, "date"), .offset = if (std.mem.eql(u8, zone, "naive")) null else (std.fmt.parseInt(i64, zone, 10) catch return null) * std.time.us_per_min };
}

pub fn isHashable(value: Value) bool {
    return value.attribute("__dxt_binary") == .string or timestamp(value) != null or temporal.hashable(value);
}

pub fn timestampText(value: Value) ?[]const u8 {
    if (timestamp(value) == null) return null;
    const rendered = value.attribute("__dxt_rendered");
    return if (rendered == .string) rendered.string else null;
}

pub fn order(lhs: Value, rhs: Value) !std.math.Order {
    if (temporal.hashable(lhs) or temporal.hashable(rhs)) return temporal.order(lhs, rhs);
    const lhs_bytes = lhs.attribute("__dxt_binary");
    const rhs_bytes = rhs.attribute("__dxt_binary");
    if (lhs_bytes == .string or rhs_bytes == .string) {
        if (lhs_bytes != .string or rhs_bytes != .string) return error.JinjaTypeError;
        return std.mem.order(u8, lhs_bytes.string, rhs_bytes.string);
    }
    const left = timestamp(lhs) orelse return error.JinjaTypeError;
    const right = timestamp(rhs) orelse return error.JinjaTypeError;
    if (left.date != right.date or (left.offset == null) != (right.offset == null)) return error.JinjaTypeError;
    const lhs_instant = left.ns - @as(i96, left.offset orelse 0) * std.time.ns_per_us;
    const rhs_instant = right.ns - @as(i96, right.offset orelse 0) * std.time.ns_per_us;
    return std.math.order(lhs_instant, rhs_instant);
}

pub fn nan(a: std.mem.Allocator) !Value {
    const result = try expression.floatValue(a, std.math.nan(f64));
    for (@constCast(result.object)) |*entry| {
        if (std.mem.eql(u8, entry.key, "__dxt_float_identity")) entry.value = .{ .string = "python-yaml-constant-nan" };
    }
    return result;
}

/// Immutable SafeLoader scalar keys obey Python bytes/date/datetime equality.
pub fn keyEqual(lhs: Value, rhs: Value) bool {
    if (temporal.hashable(lhs) or temporal.hashable(rhs)) return temporal.equal(lhs, rhs);
    const lhs_bytes = lhs.attribute("__dxt_binary");
    const rhs_bytes = rhs.attribute("__dxt_binary");
    if (lhs_bytes == .string or rhs_bytes == .string)
        return lhs_bytes == .string and rhs_bytes == .string and std.mem.eql(u8, lhs_bytes.string, rhs_bytes.string);
    const left = timestamp(lhs) orelse return false;
    const right = timestamp(rhs) orelse return false;
    if (left.date != right.date) return false;
    if (left.date) return @divFloor(left.ns, std.time.ns_per_day) == @divFloor(right.ns, std.time.ns_per_day);
    if ((left.offset == null) != (right.offset == null)) return false;
    const lhs_instant = left.ns - @as(i96, left.offset orelse 0) * std.time.ns_per_us;
    const rhs_instant = right.ns - @as(i96, right.offset orelse 0) * std.time.ns_per_us;
    return lhs_instant == rhs_instant;
}

pub fn binary(a: std.mem.Allocator, encoded: []const u8) !Value {
    const bytes = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
    try std.base64.standard.Decoder.decode(bytes, encoded);
    const members = try expression.allocateValues(a, bytes.len);
    for (bytes, members) |byte, *member| member.* = try expression.integerValue(a, byte);
    var out: std.Io.Writer.Allocating = .init(a);
    const quote: u8 = if (std.mem.indexOfScalar(u8, bytes, '\'') != null and std.mem.indexOfScalar(u8, bytes, '"') == null) '"' else '\'';
    try out.writer.writeByte('b');
    try out.writer.writeByte(quote);
    for (bytes) |byte| if (byte == quote) {
        try out.writer.writeByte('\\');
        try out.writer.writeByte(byte);
    } else switch (byte) {
        '\\' => try out.writer.writeAll("\\\\"),
        '\n' => try out.writer.writeAll("\\n"),
        '\r' => try out.writer.writeAll("\\r"),
        '\t' => try out.writer.writeAll("\\t"),
        32...91, 93...126 => try out.writer.writeByte(byte),
        else => try out.writer.print("\\x{x:0>2}", .{byte}),
    };
    try out.writer.writeByte(quote);
    const entries = try expression.allocateEntries(a, 5);
    entries[0] = .{ .key = "__dxt_binary", .value = .{ .string = bytes } };
    entries[1] = .{ .key = "__dxt_iterable", .value = .{ .list = members } };
    entries[2] = .{ .key = "__dxt_rendered", .value = .{ .string = try out.toOwnedSlice() } };
    entries[3] = .{ .key = "decode", .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_yaml_bytes_decode:{s}", .{encoded}) } };
    entries[4] = .{ .key = "hex", .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_yaml_bytes_hex:{s}", .{encoded}) } };
    return .{ .object = entries };
}

pub fn fromBytes(a: std.mem.Allocator, bytes: []const u8) !Value {
    const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
    _ = std.base64.standard.Encoder.encode(encoded, bytes);
    return binary(a, encoded);
}

pub fn fromMembers(a: std.mem.Allocator, members: []const Value) !Value {
    const bytes = try a.alloc(u8, members.len);
    for (members, bytes) |member, *byte| {
        const integer = try expression.integerIndex(member);
        if (integer < 0 or integer > 255) return error.JinjaValueError;
        byte.* = @intCast(integer);
    }
    return fromBytes(a, bytes);
}

pub fn apply(a: std.mem.Allocator, op: []const u8, lhs: Value, rhs: Value) !?Value {
    const lhs_bytes = lhs.attribute("__dxt_binary");
    const rhs_bytes = rhs.attribute("__dxt_binary");
    if (lhs_bytes != .string and rhs_bytes != .string) return null;
    if (std.mem.eql(u8, op, "+")) {
        if (lhs_bytes != .string or rhs_bytes != .string) return error.JinjaTypeError;
        if (lhs_bytes.string.len > 10_000_000 or rhs_bytes.string.len > 10_000_000 - lhs_bytes.string.len) return error.JinjaIterationLimitExceeded;
        return try fromBytes(a, try std.mem.concat(a, u8, &.{ lhs_bytes.string, rhs_bytes.string }));
    }
    if (std.mem.eql(u8, op, "*")) {
        const bytes = if (lhs_bytes == .string) lhs_bytes.string else rhs_bytes.string;
        const repetitions = if (lhs_bytes == .string) rhs else lhs;
        const count: usize = @intCast(@max(0, try expression.integerIndex(repetitions)));
        if (bytes.len == 0) return try fromBytes(a, "");
        if (bytes.len != 0 and count > 10_000_000 / bytes.len) return error.JinjaIterationLimitExceeded;
        const repeated = try a.alloc(u8, bytes.len * count);
        for (0..count) |i| @memcpy(repeated[i * bytes.len ..][0..bytes.len], bytes);
        return try fromBytes(a, repeated);
    }
    return null;
}

pub fn contains(container: Value, needle: Value) !bool {
    const bytes = container.attribute("__dxt_binary");
    if (bytes != .string) return error.JinjaTypeError;
    const binary_needle = needle.attribute("__dxt_binary");
    if (binary_needle == .string) return std.mem.indexOf(u8, bytes.string, binary_needle.string) != null;
    const integer = try expression.integerIndex(needle);
    if (integer < 0 or integer > 255) return error.JinjaValueError;
    return std.mem.indexOfScalar(u8, bytes.string, @intCast(integer)) != null;
}

/// SafeConstructor uses Python's permissive base64 decoder: ASCII junk and
/// nonterminal padding are ignored, while incomplete quanta raise ValueError.
pub fn canonicalBinary(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    for (text) |byte| if (byte > 127) return error.InvalidYamlScalar;
    var bytes: std.Io.Writer.Allocating = .init(a);
    var position: u3 = 0;
    var padding: u3 = 0;
    var bits: u32 = 0;
    var ended = false;
    for (text) |byte| {
        if (byte == '=') {
            if (position >= 2) {
                padding += 1;
                if (@as(u4, position) + padding >= 4) {
                    ended = true;
                    break;
                }
            }
            continue;
        }
        const digit: u32 = if (byte >= 'A' and byte <= 'Z') byte - 'A' else if (byte >= 'a' and byte <= 'z') byte - 'a' + 26 else if (byte >= '0' and byte <= '9') byte - '0' + 52 else if (byte == '+') 62 else if (byte == '/') 63 else continue;
        padding = 0;
        bits = (bits << 6) | digit;
        position += 1;
        if (position >= 2) try bytes.writer.writeByte(@truncate(bits >> @as(u5, @intCast((4 - @as(u4, position)) * 2))));
        if (position == 4) {
            position = 0;
            bits = 0;
        }
    }
    if (!ended and position != 0) return error.InvalidYamlScalar;
    const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.written().len));
    return std.base64.standard.Encoder.encode(encoded, bytes.written());
}

test "immutable YAML scalars preserve byte and aware datetime key identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try binary(a, "SGVsbG8=");
    try std.testing.expect(isHashable(first));
    try std.testing.expect(keyEqual(first, try binary(a, "SGVsbG8=")));
    try std.testing.expect(!keyEqual(first, .{ .string = "Hello" }));
    const dates = @import("timestamp_context.zig");
    const utc = try dates.fromYaml(a, "2020-01-02T03:04:05+00:00");
    try std.testing.expect(isHashable(utc));
    try std.testing.expect(keyEqual(utc, try dates.fromYaml(a, "2020-01-02T04:04:05+01:00")));
    try std.testing.expect(!keyEqual(utc, try dates.fromYaml(a, "2020-01-02T03:04:05")));
    try std.testing.expect(!keyEqual(utc, try dates.fromYaml(a, "2020-01-02")));
}

test "native bytes operators and membership retain immutable scalar values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try fromBytes(a, "Hello");
    try std.testing.expect(try contains(bytes, .{ .integer = "101" }));
    try std.testing.expect(try contains(bytes, try fromBytes(a, "ell")));
    try std.testing.expectError(error.JinjaValueError, contains(bytes, .{ .integer = "256" }));
    try std.testing.expectError(error.JinjaTypeError, contains(bytes, .{ .string = "e" }));
    try std.testing.expectEqualStrings("Hello!", (try apply(a, "+", bytes, try fromBytes(a, "!"))).?.attribute("__dxt_binary").string);
    try std.testing.expectEqualStrings("HelloHello", (try apply(a, "*", .{ .integer = "2" }, bytes)).?.attribute("__dxt_binary").string);
    try std.testing.expectEqualStrings("b'He'", (try fromMembers(a, (try expression.iterableValues(a, bytes))[0..2])).attribute("__dxt_rendered").string);
}

pub fn call(a: std.mem.Allocator, name: []const u8, args: []const Argument) !?Value {
    const decode_prefix = "__dxt_yaml_bytes_decode:";
    const hex_prefix = "__dxt_yaml_bytes_hex:";
    const decoding = std.mem.startsWith(u8, name, decode_prefix);
    if (!decoding and !std.mem.startsWith(u8, name, hex_prefix)) return null;
    const encoded = name[if (decoding) decode_prefix.len else hex_prefix.len..];
    const bytes = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
    try std.base64.standard.Decoder.decode(bytes, encoded);
    if (!decoding) {
        if (args.len > 2) return error.InvalidJinjaArguments;
        var separator: ?u8 = null;
        var group: i64 = 1;
        var supplied: [2]bool = .{ false, false };
        var position: usize = 0;
        for (args) |arg| {
            const at = if (arg.name) |key| if (std.mem.eql(u8, key, "sep")) @as(usize, 0) else if (std.mem.eql(u8, key, "bytes_per_sep")) @as(usize, 1) else return error.InvalidJinjaArguments else blk: {
                const index = position;
                position += 1;
                break :blk index;
            };
            if (at > 1 or supplied[at]) return error.InvalidJinjaArguments;
            supplied[at] = true;
            if (at == 0) {
                const text = if (arg.value == .string) arg.value.string else if (arg.value.attribute("__dxt_binary") == .string) arg.value.attribute("__dxt_binary").string else return error.JinjaTypeError;
                if (text.len != 1 or text[0] > 127) return error.JinjaValueError;
                separator = text[0];
            } else {
                group = try expression.integerIndex(arg.value);
                if (group < std.math.minInt(i32) or group > std.math.maxInt(i32)) return error.JinjaValueError;
            }
        }
        var out: std.Io.Writer.Allocating = .init(a);
        for (bytes, 0..) |byte, i| {
            if (separator) |delimiter| if (i != 0 and group != 0 and (if (group > 0) (bytes.len - i) % @as(usize, @intCast(group)) == 0 else i % @as(usize, @intCast(-group)) == 0)) try out.writer.writeByte(delimiter);
            try out.writer.print("{x:0>2}", .{byte});
        }
        return .{ .string = try out.toOwnedSlice() };
    }
    if (args.len > 2) return error.InvalidJinjaArguments;
    var encoding: []const u8 = "utf-8";
    var handling: []const u8 = "strict";
    var present: [2]bool = .{ false, false };
    var position: usize = 0;
    for (args) |arg| {
        const at = if (arg.name) |key| if (std.mem.eql(u8, key, "encoding")) @as(usize, 0) else if (std.mem.eql(u8, key, "errors")) @as(usize, 1) else return error.InvalidJinjaArguments else blk: {
            const index = position;
            position += 1;
            break :blk index;
        };
        if (at > 1 or present[at] or arg.value != .string) return error.InvalidJinjaArguments;
        present[at] = true;
        if (at == 0) encoding = arg.value.string else handling = arg.value.string;
    }
    return .{ .string = try @import("yaml_bytes_codec.zig").decode(a, bytes, encoding, handling) };
}
