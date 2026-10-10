//! Jinja normalizes physical template newlines before tokenizing strings.
//! Authored resource bytes and decoded expression results stay unchanged.
const std = @import("std");

/// dbt's non-native get_rendered bypasses Jinja for plain strings. Its trigger
/// pattern includes both opening and closing delimiters, even unmatched ones.
pub fn hasRenderCharacters(source: []const u8) bool {
    inline for (.{ "{{", "{%", "{#", "#}", "%}", "}}" }) |marker| {
        if (std.mem.indexOf(u8, source, marker) != null) return true;
    }
    return false;
}

pub fn normalize(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, source, '\r') == null) return source;
    var length = source.len;
    for (source, 0..) |byte, index| {
        if (byte == '\r' and index + 1 < source.len and source[index + 1] == '\n') length -= 1;
    }
    const output = try allocator.alloc(u8, length);
    var input_index: usize = 0;
    var output_index: usize = 0;
    while (input_index < source.len) : (input_index += 1) {
        const byte = source[input_index];
        output[output_index] = if (byte == '\r') '\n' else byte;
        output_index += 1;
        if (byte == '\r' and input_index + 1 < source.len and source[input_index + 1] == '\n') input_index += 1;
    }
    return output;
}

pub const Range = struct { source: []const u8, start: usize, end: usize };

pub fn range(allocator: std.mem.Allocator, source: []const u8, start: usize, end: usize) !Range {
    const normalized = try normalize(allocator, source);
    if (normalized.ptr == source.ptr) return .{ .source = source, .start = start, .end = end };
    return .{ .source = normalized, .start = offset(source, start), .end = offset(source, end) };
}

fn offset(source: []const u8, boundary: usize) usize {
    var normalized = boundary;
    for (source[0..boundary], 0..) |byte, index| {
        if (byte == '\r' and index + 1 < boundary and source[index + 1] == '\n') normalized -= 1;
    }
    return normalized;
}

test "physical CRLF and CR become LF while authored bytes remain unchanged" {
    const source = "a\r\nb\rc\nd\r\r\ne";
    const normalized = try normalize(std.testing.allocator, source);
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("a\nb\nc\nd\n\ne", normalized);
    try std.testing.expectEqualStrings("a\r\nb\rc\nd\r\r\ne", source);
}

test "escaped carriage returns and Unicode separators remain source text" {
    const source = "{{ 'a\\rb' }}\r\n{{ 'a\rb' }}\u{2028}\u{2029}\x0b\x0c";
    const normalized = try normalize(std.testing.allocator, source);
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("{{ 'a\\rb' }}\n{{ 'a\nb' }}\u{2028}\u{2029}\x0b\x0c", normalized);
}

test "unchanged LF templates keep their backing source" {
    const source = "a\nb";
    const normalized = try normalize(std.testing.allocator, source);
    try std.testing.expect(source.ptr == normalized.ptr);
    try std.testing.expectEqualStrings(source, normalized);
}

test "Core plain-string fast path recognizes opening and closing delimiters" {
    try std.testing.expect(!hasRenderCharacters("select 1\r\n-- no template"));
    try std.testing.expect(!hasRenderCharacters("100% # comment { }"));
    inline for (.{ "{{", "{%", "{#", "#}", "%}", "}}" }) |marker| {
        try std.testing.expect(hasRenderCharacters(marker));
    }
}

test "borrowed macro body offsets follow normalized complete template" {
    const source = "before\r\n{% macro probe() %}\r\nbody\r\n{% endmacro %}\r\n";
    const start = std.mem.indexOf(u8, source, "body").?;
    const end = std.mem.indexOf(u8, source, "{% endmacro").?;
    const normalized = try range(std.testing.allocator, source, start, end);
    defer std.testing.allocator.free(normalized.source);
    try std.testing.expectEqualStrings("body\n", normalized.source[normalized.start..normalized.end]);
    try std.testing.expectEqualStrings("before\n{% macro probe() %}\nbody\n{% endmacro %}\n", normalized.source);
}
