//! Unicode 15 character names, including control aliases and algorithmic names.
const std = @import("std");
const data = @import("unicode_names").data;
const ranges = @import("unicode_name_ranges.zig").ranges;

fn integer(at: usize) usize {
    return std.mem.readInt(u32, data[at..][0..4], .little);
}
pub fn lookup(a: std.mem.Allocator, authored: []const u8) !u21 {
    const name = try a.dupe(u8, authored);
    for (name) |*ch| ch.* = std.ascii.toUpper(ch.*);
    for (ranges) |range| if (std.mem.startsWith(u8, name, range.prefix)) {
        const hex = name[range.prefix.len..];
        const code = std.fmt.parseInt(u21, hex, 16) catch return error.UnknownUnicodeCharacterName;
        if (code >= range.first and code <= range.last) {
            const expected = try std.fmt.allocPrint(a, "{X}", .{code});
            if (std.mem.eql(u8, hex, expected)) return code;
        }
    };
    const count = integer(0);
    const base = 4 + count * 4;
    var low: usize = 0;
    var high = count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const at = base + integer(4 + middle * 4);
        const tail = data[at + 4 ..];
        const candidate = tail[0..std.mem.indexOfScalar(u8, tail, 0).?];
        switch (std.mem.order(u8, name, candidate)) {
            .eq => return @intCast(integer(at)),
            .lt => high = middle,
            .gt => low = middle + 1,
        }
    }
    return error.UnknownUnicodeCharacterName;
}

test "Unicode names include case-insensitive aliases and algorithmic ideographs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(u21, 'é'), try lookup(a, "latin small letter e with acute"));
    try std.testing.expectEqual(@as(u21, 0), try lookup(a, "NULL"));
    try std.testing.expectEqual(@as(u21, 0x597d), try lookup(a, "CJK UNIFIED IDEOGRAPH-597D"));
    // Native Unicode 15 is an explicit contract, independent of the Python
    // version used to run developer Core comparisons on older characters.
    try std.testing.expectEqual(@as(u21, 0x11f04), try lookup(a, "KAWI LETTER A"));
    try std.testing.expectError(error.UnknownUnicodeCharacterName, lookup(a, "CJK UNIFIED IDEOGRAPH-0597D"));
}
