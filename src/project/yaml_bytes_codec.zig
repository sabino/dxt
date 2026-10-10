//! Native text codecs used by SafeLoader byte scalar methods.
const std = @import("std");

const Encoding = enum { utf8, utf8_sig, ascii, latin1, cp1252, utf16, utf16_le, utf16_be, utf32, utf32_le, utf32_be };

pub fn decode(a: std.mem.Allocator, bytes: []const u8, name: []const u8, handling: []const u8) ![]const u8 {
    const encoding = try findEncoding(name);
    var out: std.Io.Writer.Allocating = .init(a);
    var offset: usize = 0;
    if (encoding == .utf8_sig and std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) offset = 3;
    if (encoding == .utf8 or encoding == .utf8_sig or encoding == .ascii) {
        while (offset < bytes.len) {
            if (bytes[offset] < 128) {
                try out.writer.writeByte(bytes[offset]);
                offset += 1;
                continue;
            }
            var consumed: usize = 1;
            if (encoding != .ascii) {
                const width = std.unicode.utf8ByteSequenceLength(bytes[offset]) catch 0;
                if (width != 0) {
                    var available: usize = 1;
                    while (available < width and offset + available < bytes.len and bytes[offset + available] >= 0x80 and bytes[offset + available] <= 0xbf) : (available += 1) {}
                    const constrained = available >= 2 and ((bytes[offset] == 0xe0 and bytes[offset + 1] < 0xa0) or (bytes[offset] == 0xed and bytes[offset + 1] >= 0xa0) or (bytes[offset] == 0xf0 and bytes[offset + 1] < 0x90) or (bytes[offset] == 0xf4 and bytes[offset + 1] >= 0x90));
                    if (available == width and !constrained and std.unicode.utf8ValidateSlice(bytes[offset..][0..width])) {
                        try out.writer.writeAll(bytes[offset..][0..width]);
                        offset += width;
                        continue;
                    }
                    if (!constrained) consumed = available;
                }
            }
            try invalid(&out.writer, bytes[offset..][0..consumed], handling);
            offset += consumed;
        }
    } else if (encoding == .latin1 or encoding == .cp1252) {
        for (bytes) |byte| {
            const code: u21 = if (encoding == .cp1252 and byte >= 0x80 and byte <= 0x9f) cp1252[byte - 0x80] else byte;
            if (code == 0 and byte >= 0x80) try invalid(&out.writer, &.{byte}, handling) else try writeCode(&out.writer, code);
        }
    } else {
        const width: usize = if (encoding == .utf16 or encoding == .utf16_le or encoding == .utf16_be) 2 else 4;
        var little = encoding != .utf16_be and encoding != .utf32_be;
        if (encoding == .utf16 or encoding == .utf32) {
            if (width == 2 and std.mem.startsWith(u8, bytes, "\xff\xfe")) {
                offset = 2;
                little = true;
            } else if (width == 2 and std.mem.startsWith(u8, bytes, "\xfe\xff")) {
                offset = 2;
                little = false;
            } else if (width == 4 and std.mem.startsWith(u8, bytes, "\xff\xfe\x00\x00")) {
                offset = 4;
                little = true;
            } else if (width == 4 and std.mem.startsWith(u8, bytes, "\x00\x00\xfe\xff")) {
                offset = 4;
                little = false;
            }
        }
        while (offset < bytes.len) {
            if (bytes.len - offset < width) {
                try invalid(&out.writer, bytes[offset..], handling);
                break;
            }
            var consumed = width;
            var code = unit(bytes[offset..][0..width], little);
            if (width == 2 and code >= 0xd800 and code <= 0xdbff) {
                if (bytes.len - offset < 4) {
                    try invalid(&out.writer, bytes[offset..], handling);
                    break;
                }
                const lower = unit(bytes[offset + 2 ..][0..2], little);
                if (lower >= 0xdc00 and lower <= 0xdfff) {
                    code = 0x10000 + (code - 0xd800) * 1024 + lower - 0xdc00;
                    consumed = 4;
                }
            }
            if (code > 0x10ffff or (code >= 0xd800 and code <= 0xdfff)) try invalid(&out.writer, bytes[offset..][0..consumed], handling) else try writeCode(&out.writer, @intCast(code));
            offset += consumed;
        }
    }
    return out.toOwnedSlice();
}

fn findEncoding(name: []const u8) !Encoding {
    var normalized: [64]u8 = undefined;
    var length: usize = 0;
    for (name) |byte| {
        if (byte == '-' or byte == '_' or byte == ' ') continue;
        if (length == normalized.len) return error.JinjaTypeError;
        normalized[length] = std.ascii.toLower(byte);
        length += 1;
    }
    const text = normalized[0..length];
    inline for (.{
        .{ "utf8", Encoding.utf8 },          .{ "utf8sig", Encoding.utf8_sig },
        .{ "ascii", Encoding.ascii },        .{ "usascii", Encoding.ascii },
        .{ "646", Encoding.ascii },          .{ "latin1", Encoding.latin1 },
        .{ "l1", Encoding.latin1 },          .{ "iso88591", Encoding.latin1 },
        .{ "cp819", Encoding.latin1 },       .{ "cp1252", Encoding.cp1252 },
        .{ "windows1252", Encoding.cp1252 }, .{ "utf16", Encoding.utf16 },
        .{ "utf16le", Encoding.utf16_le },   .{ "utf16be", Encoding.utf16_be },
        .{ "utf32", Encoding.utf32 },        .{ "utf32le", Encoding.utf32_le },
        .{ "utf32be", Encoding.utf32_be },
    }) |entry| if (std.mem.eql(u8, text, entry[0])) return entry[1];
    return error.JinjaTypeError;
}

fn unit(bytes: []const u8, little: bool) u32 {
    var result: u32 = 0;
    for (0..bytes.len) |index| result = result * 256 + bytes[if (little) bytes.len - index - 1 else index];
    return result;
}

fn writeCode(out: *std.Io.Writer, code: u21) !void {
    var encoded: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(code, &encoded) catch return error.JinjaTypeError;
    try out.writeAll(encoded[0..length]);
}

fn invalid(out: *std.Io.Writer, bytes: []const u8, handling: []const u8) !void {
    if (std.mem.eql(u8, handling, "replace")) try out.writeAll("\xef\xbf\xbd") else if (std.mem.eql(u8, handling, "backslashreplace")) {
        for (bytes) |byte| try out.print("\\x{x:0>2}", .{byte});
    } else if (!std.mem.eql(u8, handling, "ignore")) return error.JinjaTypeError;
}

const cp1252 = [_]u21{ 0x20ac, 0, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021, 0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017d, 0, 0, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0, 0x017e, 0x0178 };

test "byte text codecs preserve Unicode units and malformed input boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("A😀", try decode(a, "\xff\xfeA\x00\x3d\xd8\x00\xde", "utf-16", "strict"));
    try std.testing.expectEqualStrings("A😀", try decode(a, "\x00\x00\xfe\xff\x00\x00\x00A\x00\x01\xf6\x00", "UTF_32", "strict"));
    try std.testing.expectEqualStrings("€�", try decode(a, "\x80\x81", "windows-1252", "replace"));
    try std.testing.expectEqualStrings("�A", try decode(a, "\x00\xd8A\x00", "utf16le", "replace"));
    try std.testing.expectEqualStrings("\\x00\\xd8\\x41", try decode(a, "\x00\xd8A", "utf16le", "backslashreplace"));
    try std.testing.expectError(error.JinjaTypeError, decode(a, "\x00\xd8", "utf16le", "strict"));
    try std.testing.expectError(error.JinjaTypeError, decode(a, "", "utf..8", "strict"));
}
