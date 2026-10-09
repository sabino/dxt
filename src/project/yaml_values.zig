//! SafeLoader's bytes and timestamp scalars retain their runtime identities.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const Argument = expression.Argument;

const Timestamp = struct { ns: i96, date: bool, offset: ?i32 };

fn timestamp(value: Value) ?Timestamp {
    const method = value.attribute("isoformat");
    const prefix = "__dxt_datetime:isoformat:";
    if (method != .callable or !std.mem.startsWith(u8, method.callable, prefix)) return null;
    var parts = std.mem.splitScalar(u8, method.callable[prefix.len..], ':');
    const ns = std.fmt.parseInt(i96, parts.next() orelse return null, 10) catch return null;
    const kind = parts.next() orelse return null;
    const zone = parts.next() orelse return null;
    return .{ .ns = ns, .date = std.mem.eql(u8, kind, "date"), .offset = if (std.mem.eql(u8, zone, "naive")) null else std.fmt.parseInt(i32, zone, 10) catch return null };
}

pub fn isHashable(value: Value) bool {
    return value.attribute("__dxt_binary") == .string or timestamp(value) != null;
}

pub fn timestampText(value: Value) ?[]const u8 {
    if (timestamp(value) == null) return null;
    const rendered = value.attribute("__dxt_rendered");
    return if (rendered == .string) rendered.string else null;
}

pub fn order(lhs: Value, rhs: Value) !std.math.Order {
    const lhs_bytes = lhs.attribute("__dxt_binary");
    const rhs_bytes = rhs.attribute("__dxt_binary");
    if (lhs_bytes == .string or rhs_bytes == .string) {
        if (lhs_bytes != .string or rhs_bytes != .string) return error.JinjaTypeError;
        return std.mem.order(u8, lhs_bytes.string, rhs_bytes.string);
    }
    const left = timestamp(lhs) orelse return error.JinjaTypeError;
    const right = timestamp(rhs) orelse return error.JinjaTypeError;
    if (left.date != right.date or (left.offset == null) != (right.offset == null)) return error.JinjaTypeError;
    const lhs_instant = left.ns - @as(i96, left.offset orelse 0) * std.time.ns_per_min;
    const rhs_instant = right.ns - @as(i96, right.offset orelse 0) * std.time.ns_per_min;
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
    const lhs_bytes = lhs.attribute("__dxt_binary");
    const rhs_bytes = rhs.attribute("__dxt_binary");
    if (lhs_bytes == .string or rhs_bytes == .string)
        return lhs_bytes == .string and rhs_bytes == .string and std.mem.eql(u8, lhs_bytes.string, rhs_bytes.string);
    const left = timestamp(lhs) orelse return false;
    const right = timestamp(rhs) orelse return false;
    if (left.date != right.date) return false;
    if (left.date) return @divFloor(left.ns, std.time.ns_per_day) == @divFloor(right.ns, std.time.ns_per_day);
    if ((left.offset == null) != (right.offset == null)) return false;
    const lhs_instant = left.ns - @as(i96, left.offset orelse 0) * std.time.ns_per_min;
    const rhs_instant = right.ns - @as(i96, right.offset orelse 0) * std.time.ns_per_min;
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

pub fn call(a: std.mem.Allocator, name: []const u8, args: []const Argument) !?Value {
    const decode_prefix = "__dxt_yaml_bytes_decode:";
    const hex_prefix = "__dxt_yaml_bytes_hex:";
    const decoding = std.mem.startsWith(u8, name, decode_prefix);
    if (!decoding and !std.mem.startsWith(u8, name, hex_prefix)) return null;
    const encoded = name[if (decoding) decode_prefix.len else hex_prefix.len..];
    const bytes = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
    try std.base64.standard.Decoder.decode(bytes, encoded);
    if (!decoding) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        var out: std.Io.Writer.Allocating = .init(a);
        for (bytes) |byte| try out.writer.print("{x:0>2}", .{byte});
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
    if (!std.ascii.eqlIgnoreCase(handling, "strict")) return error.JinjaTypeError;
    if (std.ascii.eqlIgnoreCase(encoding, "utf-8") or std.ascii.eqlIgnoreCase(encoding, "utf8")) {
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.JinjaTypeError;
        return .{ .string = bytes };
    }
    if (std.ascii.eqlIgnoreCase(encoding, "ascii")) {
        for (bytes) |byte| if (byte > 127) return error.JinjaTypeError;
        return .{ .string = bytes };
    }
    if (std.ascii.eqlIgnoreCase(encoding, "latin1") or std.ascii.eqlIgnoreCase(encoding, "latin-1") or std.ascii.eqlIgnoreCase(encoding, "iso-8859-1")) {
        var out: std.Io.Writer.Allocating = .init(a);
        for (bytes) |byte| {
            var buffer: [4]u8 = undefined;
            const length = try std.unicode.utf8Encode(byte, &buffer);
            try out.writer.writeAll(buffer[0..length]);
        }
        return .{ .string = try out.toOwnedSlice() };
    }
    return error.JinjaTypeError;
}
