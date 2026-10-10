//! Statically linked Unicode PCRE2, with Python string offsets and match state.
const std = @import("std");
const pattern = @import("regex_pattern.zig");
pub const c = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cDefine("PCRE2_STATIC", "1");
    @cInclude("pcre2.h");
});
pub const Span = struct { start: i64 = -1, end: i64 = -1 };
pub const Match = struct { spans: []const Span, lastindex: ?usize = null };
pub const Name = struct { name: []const u8, index: usize };
pub const Regex = struct {
    code: *c.pcre2_code_8,
    flags: u32,
    groups: usize,
    names: []const Name,

    pub fn deinit(self: Regex) void {
        c.pcre2_code_free_8(self.code);
    }
    pub fn find(self: Regex, a: std.mem.Allocator, subject: []const u8, start: usize, end: usize, options: u32) !?Match {
        const data = c.pcre2_match_data_create_from_pattern_8(self.code, null) orelse return error.OutOfMemory;
        defer c.pcre2_match_data_free_8(data);
        const context = c.pcre2_match_context_create_8(null) orelse return error.OutOfMemory;
        defer c.pcre2_match_context_free_8(context);
        var lastindex: u32 = 0;
        _ = c.pcre2_set_callout_8(context, callout, &lastindex);
        _ = c.pcre2_set_match_limit_8(context, 10000000);
        _ = c.pcre2_set_depth_limit_8(context, 1000);
        const result = c.pcre2_match_8(self.code, subject.ptr, end, start, options, data, context);
        if (result == c.PCRE2_ERROR_NOMATCH) return null;
        if (result < 0) return error.RegularExpressionMatchFailed;
        const vector = c.pcre2_get_ovector_pointer_8(data);
        const spans = try a.alloc(Span, self.groups + 1);
        for (spans, 0..) |*span, index| {
            span.* = if (vector[index * 2] == std.math.maxInt(usize)) .{} else .{ .start = @intCast(vector[index * 2]), .end = @intCast(vector[index * 2 + 1]) };
        }
        return .{ .spans = spans, .lastindex = if (lastindex == 0) null else lastindex };
    }
};

fn callout(block: ?*c.pcre2_callout_block_8, user: ?*anyopaque) callconv(.c) c_int {
    const target: *u32 = @ptrCast(@alignCast(user.?));
    target.* = block.?.capture_last;
    return 0;
}

pub fn compile(a: std.mem.Allocator, raw: []const u8, flags: u32) !Regex {
    const normalized = try pattern.normalize(a, raw, flags);
    const context = c.pcre2_compile_context_create_8(null) orelse return error.OutOfMemory;
    defer c.pcre2_compile_context_free_8(context);
    _ = c.pcre2_set_max_varlookbehind_8(context, 0);
    var extra: u32 = c.PCRE2_EXTRA_ALLOW_SURROGATE_ESCAPES;
    if (normalized.flags & pattern.A != 0) extra |= c.PCRE2_EXTRA_CASELESS_RESTRICT;
    _ = c.pcre2_set_compile_extra_options_8(context, extra);
    var options: u32 = c.PCRE2_UTF | c.PCRE2_UCP | c.PCRE2_AUTO_CALLOUT;
    if (normalized.flags & pattern.I != 0) options |= c.PCRE2_CASELESS;
    if (normalized.flags & pattern.M != 0) options |= c.PCRE2_MULTILINE;
    if (normalized.flags & pattern.S != 0) options |= c.PCRE2_DOTALL;
    if (normalized.flags & pattern.X != 0) options |= c.PCRE2_EXTENDED;
    var error_code: c_int = 0;
    var error_offset: usize = 0;
    const code = c.pcre2_compile_8(normalized.text.ptr, normalized.text.len, options, &error_code, &error_offset, context) orelse return error.InvalidRegularExpression;
    errdefer c.pcre2_code_free_8(code);
    var count: u32 = 0;
    _ = c.pcre2_pattern_info_8(code, c.PCRE2_INFO_CAPTURECOUNT, &count);
    var name_count: u32 = 0;
    var name_size: u32 = 0;
    var table: [*c]const u8 = undefined;
    _ = c.pcre2_pattern_info_8(code, c.PCRE2_INFO_NAMECOUNT, &name_count);
    _ = c.pcre2_pattern_info_8(code, c.PCRE2_INFO_NAMEENTRYSIZE, &name_size);
    _ = c.pcre2_pattern_info_8(code, c.PCRE2_INFO_NAMETABLE, @ptrCast(&table));
    const names = try a.alloc(Name, name_count);
    for (names, 0..) |*name, index| {
        const row = table[index * name_size ..][0..name_size];
        name.* = .{ .name = try a.dupe(u8, row[2..std.mem.indexOfScalarPos(u8, row, 2, 0).?]), .index = @as(usize, row[0]) * 256 + row[1] };
    }
    std.mem.sort(Name, names, {}, struct {
        fn less(_: void, left: Name, right: Name) bool {
            return left.index < right.index;
        }
    }.less);
    return .{ .code = code, .flags = normalized.flags, .groups = count, .names = names };
}

pub fn byteOffset(text: []const u8, character: i64) !usize {
    if (character <= 0) return 0;
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    var index: usize = 0;
    var remaining = character;
    while (remaining > 0) : (remaining -= 1) {
        const bytes = iterator.nextCodepointSlice() orelse return text.len;
        index += bytes.len;
    }
    return index;
}
pub fn characterOffset(text: []const u8, byte: i64) !i64 {
    if (byte < 0) return -1;
    return @intCast(try @import("expression_unicode.zig").count(text[0..@intCast(byte)]));
}

test "native regex captures named groups and Python codepoint offsets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const regex = try compile(a, "(?P<word>\\w+)", 0);
    defer regex.deinit();
    const match = (try regex.find(a, "é 好", 0, "é 好".len, 0)).?;
    try std.testing.expectEqual(@as(i64, 2), match.spans[0].end);
    try std.testing.expectEqual(@as(i64, 1), try characterOffset("é 好", match.spans[0].end));
    try std.testing.expectEqualStrings("word", regex.names[0].name);
    try std.testing.expectEqual(@as(?usize, 1), match.lastindex);
}
