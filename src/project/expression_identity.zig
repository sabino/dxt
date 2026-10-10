//! CPython's immutable scalar aliases and cached Latin-1 characters.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const Character = struct { bytes: [2]u8, length: u2 };
const characters: [256]Character = blk: {
    var values: [256]Character = undefined;
    for (&values, 0..) |*value, code| {
        value.* = if (code < 128)
            .{ .bytes = .{ @intCast(code), 0 }, .length = 1 }
        else
            .{ .bytes = .{ @intCast(0xc0 | (code >> 6)), @intCast(0x80 | (code & 0x3f)) }, .length = 2 };
    }
    break :blk values;
};

/// Literal and character-producing operations share CPython's Latin-1 cache.
/// Case conversions deliberately retain their separately allocated result.
pub fn cachedString(text: []const u8) []const u8 {
    if (text.len == 0) return "";
    if (text.len > 2) return text;
    if ((std.unicode.utf8ByteSequenceLength(text[0]) catch return text) != text.len) return text;
    const code = std.unicode.utf8Decode(text) catch return text;
    if (code > 255) return text;
    const character = &characters[code];
    return character.bytes[0..character.length];
}
pub fn substring(a: std.mem.Allocator, original: []const u8, text: []const u8) ![]const u8 {
    if (text.len == original.len and text.ptr == original.ptr) return original;
    return cachedString(try a.dupe(u8, text));
}
pub fn builtinBooleanText(text: []const u8) []const u8 {
    if (std.mem.eql(u8, text, "True")) return "True";
    if (std.mem.eql(u8, text, "False")) return "False";
    return text;
}

pub fn scalarSame(left: Value, right: Value) ?bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return null;
    return switch (left) {
        .string => |text| text.len == right.string.len and (text.len == 0 or text.ptr == right.string.ptr),
        .integer => |text| blk: {
            const integer = std.fmt.parseInt(i64, text, 10) catch break :blk text.ptr == right.integer.ptr and text.len == right.integer.len;
            if (integer >= -5 and integer <= 256) break :blk std.mem.eql(u8, text, right.integer);
            break :blk text.ptr == right.integer.ptr and text.len == right.integer.len;
        },
        .tuple => |members| members.len == right.tuple.len and (members.len == 0 or members.ptr == right.tuple.ptr),
        else => null,
    };
}

pub fn immutableSame(left: Value, right: Value) ?bool {
    const identity = left.attribute("__dxt_immutable_identity");
    const other = right.attribute("__dxt_immutable_identity");
    const native = identity == .callable and nativeImmutableToken(identity.callable);
    const other_native = other == .callable and nativeImmutableToken(other.callable);
    if (!native and !other_native) return null;
    return native and other_native and std.mem.eql(u8, identity.callable, other.callable);
}
fn nativeImmutableToken(token: []const u8) bool {
    return std.mem.startsWith(u8, token, "__dxt_datetime_instance:") or std.mem.startsWith(u8, token, "__dxt_datetime_method_instance:") or std.mem.startsWith(u8, token, "__dxt_regex_flag:");
}

test "Latin-1 characters share a cache while larger characters remain owned" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "a", "é", "\x00" }) |text|
        try std.testing.expect(cachedString(try a.dupe(u8, text)).ptr == cachedString(text).ptr);
    const larger = try a.dupe(u8, "好");
    try std.testing.expect(cachedString(larger).ptr == larger.ptr);
}
