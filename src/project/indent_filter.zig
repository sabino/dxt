//! Jinja 3.1 filters.do_indent: preserve its appended-newline/splitlines
//! behavior, including Python's Unicode line separators and empty-line rules.
const std = @import("std");

pub const Width = union(enum) { spaces: usize, text: []const u8 };

pub fn render(allocator: std.mem.Allocator, text: []const u8, width: Width, first: bool, blank: bool) ![]const u8 {
    const augmented = try std.fmt.allocPrint(allocator, "{s}\n", .{text});
    defer allocator.free(augmented);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var start: usize = 0;
    var line: usize = 0;
    while (start < augmented.len) : (line += 1) {
        var end = start;
        while (lineBreak(augmented[end..]) == 0) end += 1;
        if (line != 0) try out.writer.writeByte('\n');
        if ((line == 0 and first) or (line != 0 and (blank or end != start))) {
            switch (width) {
                .spaces => |count| try out.writer.splatByteAll(' ', count),
                .text => |prefix| try out.writer.writeAll(prefix),
            }
        }
        try out.writer.writeAll(augmented[start..end]);
        start = end + lineBreak(augmented[end..]);
    }
    return try out.toOwnedSlice();
}

fn lineBreak(text: []const u8) usize {
    if (text.len == 0) return 0;
    return switch (text[0]) {
        '\r' => if (text.len > 1 and text[1] == '\n') 2 else 1,
        '\n', 0x0b, 0x0c, 0x1c...0x1e => 1,
        0xc2 => if (text.len > 1 and text[1] == 0x85) 2 else 0,
        0xe2 => if (text.len > 2 and text[1] == 0x80 and (text[2] == 0xa8 or text[2] == 0xa9)) 3 else 0,
        else => 0,
    };
}

test "indent preserves blank lines and the final newline split quirk" {
    const cases = [_]struct { input: []const u8, first: bool = false, blank: bool = false, expected: []const u8 }{
        .{ .input = "a\n\nb\n", .expected = "a\n\n  b\n" },
        .{ .input = "a\n\nb\n", .first = true, .blank = true, .expected = "  a\n  \n  b\n  " },
        .{ .input = "a\r", .expected = "a" },
        .{ .input = "a\r\n", .expected = "a\n" },
        .{ .input = "", .first = true, .expected = "  " },
    };
    for (cases) |case| {
        const result = try render(std.testing.allocator, case.input, .{ .spaces = 2 }, case.first, case.blank);
        defer std.testing.allocator.free(result);
        try std.testing.expectEqualStrings(case.expected, result);
    }
}

test "indent recognizes Python splitlines Unicode boundaries and string prefixes" {
    const result = try render(std.testing.allocator, "a\x0bb\x0cc\x1cd\x1de\x1ef\xc2\x85g\xe2\x80\xa8h\xe2\x80\xa9i", .{ .text = "> " }, true, false);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("> a\n> b\n> c\n> d\n> e\n> f\n> g\n> h\n> i", result);
}
