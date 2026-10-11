//! Native Unicode 15 text operations matching Python/Jinja strings.
const std = @import("std");
const data = @import("unicode_case_data.zig");
pub const Case = enum { lower, upper, title, casefold };

fn within(code: u21, ranges: []const [2]u21) bool {
    var first: usize = 0;
    var last = ranges.len;
    while (first < last) {
        const middle = first + (last - first) / 2;
        if (code < ranges[middle][0]) last = middle else if (code > ranges[middle][1]) first = middle + 1 else return true;
    }
    return false;
}

pub fn whitespace(code: u21) bool {
    return within(code, &data.whitespace);
}

fn mapping(code: u21, kind: Case) ?[]const u8 {
    const entries: []const data.Mapping = switch (kind) {
        .lower => &data.lower,
        .upper => &data.upper,
        .title => &data.title,
        .casefold => &data.casefold,
    };
    var first: usize = 0;
    var last = entries.len;
    while (first < last) {
        const middle = first + (last - first) / 2;
        if (code < entries[middle].code) last = middle else if (code > entries[middle].code) first = middle + 1 else return entries[middle].text;
    }
    return null;
}

fn finalSigma(codes: []const u21, index: usize) bool {
    var before = index;
    var preceded = false;
    while (before != 0) {
        before -= 1;
        if (within(codes[before], &data.case_ignorable)) continue;
        preceded = within(codes[before], &data.cased);
        break;
    }
    if (!preceded) return false;
    for (codes[index + 1 ..]) |code| {
        if (within(code, &data.case_ignorable)) continue;
        return !within(code, &data.cased);
    }
    return true;
}

pub fn count(text: []const u8) !usize {
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    var result: usize = 0;
    while (iterator.nextCodepoint() != null) result += 1;
    return result;
}

pub fn convert(a: std.mem.Allocator, text: []const u8, kind: Case) ![]const u8 {
    var codes: std.ArrayList(u21) = .empty;
    defer codes.deinit(a);
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    while (iterator.nextCodepoint()) |code| try codes.append(a, code);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (codes.items, 0..) |code, index| {
        if (kind == .lower and code == 0x3a3 and finalSigma(codes.items, index)) {
            try out.appendSlice(a, "ς");
        } else if (mapping(code, kind)) |converted| {
            try out.appendSlice(a, converted);
        } else {
            var buffer: [4]u8 = undefined;
            const size = try std.unicode.utf8Encode(code, &buffer);
            try out.appendSlice(a, buffer[0..size]);
        }
    }
    return out.toOwnedSlice(a);
}

/// Strip a set of code points, or Python's Unicode whitespace by default.
pub fn strip(text: []const u8, characters: ?[]const u8, left: bool, right: bool) ![]const u8 {
    var first: usize = 0;
    var last = text.len;
    if (left) while (first < last) {
        const length = try std.unicode.utf8ByteSequenceLength(text[first]);
        const code = try std.unicode.utf8Decode(text[first .. first + length]);
        if (!(if (characters) |set| try inSet(code, set) else whitespace(code))) break;
        first += length;
    };
    if (right) while (last > first) {
        var start = last - 1;
        while (start > first and text[start] & 0xc0 == 0x80) start -= 1;
        const code = try std.unicode.utf8Decode(text[start..last]);
        if (!(if (characters) |set| try inSet(code, set) else whitespace(code))) break;
        last = start;
    };
    return text[first..last];
}

fn inSet(code: u21, set: []const u8) !bool {
    var iterator = (try std.unicode.Utf8View.init(set)).iterator();
    while (iterator.nextCodepoint()) |candidate| if (candidate == code) return true;
    return false;
}

pub fn splitWhitespace(a: std.mem.Allocator, text: []const u8, maximum: i64, backwards: bool) ![]const []const u8 {
    var spans: std.ArrayList([2]usize) = .empty;
    defer spans.deinit(a);
    var index: usize = 0;
    var start: ?usize = null;
    while (index < text.len) {
        const size = try std.unicode.utf8ByteSequenceLength(text[index]);
        const code = try std.unicode.utf8Decode(text[index .. index + size]);
        if (whitespace(code)) {
            if (start) |first| try spans.append(a, .{ first, index });
            start = null;
        } else if (start == null) start = index;
        index += size;
    }
    if (start) |first| try spans.append(a, .{ first, text.len });
    if (spans.items.len == 0) return &.{};
    const split_count = if (maximum < 0) spans.items.len - 1 else @min(@as(usize, @intCast(maximum)), spans.items.len - 1);
    const values = try a.alloc([]const u8, split_count + 1);
    if (!backwards) {
        for (values[0..split_count], spans.items[0..split_count]) |*result, span| result.* = text[span[0]..span[1]];
        const final = spans.items[split_count];
        values[split_count] = text[final[0]..if (maximum >= 0 and split_count == maximum) text.len else final[1]];
    } else {
        const remaining = spans.items.len - split_count - 1;
        const final = spans.items[remaining];
        values[0] = text[if (maximum >= 0 and split_count == maximum) 0 else final[0]..final[1]];
        for (values[1..], spans.items[remaining + 1 ..]) |*result, span| result.* = text[span[0]..span[1]];
    }
    return values;
}

test "Unicode expansion, contextual sigma, codepoint length and whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("STRASSE İ ΑΣ", try convert(a, "Straße İ ας", .upper));
    try std.testing.expectEqualStrings("i̇ ος οσα ος́", try convert(a, "İ ΟΣ ΟΣΑ ΟΣ́", .lower));
    try std.testing.expectEqualStrings("ffi strasse", try convert(a, "ﬃ Straße", .casefold));
    try std.testing.expectEqual(@as(usize, 3), try count("aé好"));
    try std.testing.expectEqualStrings("é", try strip("\xc2\xa0\xe2\x80\x83é\xe3\x80\x80", null, true, true));
}
