const std = @import("std");

pub const JinjaCall = struct {
    package_name: ?[]const u8,
    name: []const u8,
    open: usize,
    close: usize,
};

pub const ParsedString = struct {
    value: []const u8,
    next: usize,
};

pub fn readJinjaCall(span: []const u8, first_ident: []const u8, first_ident_end: usize) !?JinjaCall {
    if (first_ident_end < span.len and span[first_ident_end] == '.') {
        const name_start = first_ident_end + 1;
        if (name_start >= span.len or !isIdentStart(span[name_start])) return error.UnsupportedJinja;
        var name_end = name_start + 1;
        while (name_end < span.len and isIdentChar(span[name_end])) name_end += 1;
        const call_pos = skipWs(span, name_end);
        if (call_pos >= span.len or span[call_pos] != '(') return null;
        const close = findMatchingParen(span, call_pos) orelse return error.UnsupportedJinja;
        return .{
            .package_name = first_ident,
            .name = span[name_start..name_end],
            .open = call_pos,
            .close = close,
        };
    }

    const call_pos = skipWs(span, first_ident_end);
    if (call_pos >= span.len or span[call_pos] != '(') return null;
    const close = findMatchingParen(span, call_pos) orelse return error.UnsupportedJinja;
    return .{
        .package_name = null,
        .name = first_ident,
        .open = call_pos,
        .close = close,
    };
}

pub fn parseLiteralArgs(allocator: std.mem.Allocator, args: []const u8, unsupported_error: anyerror) !std.ArrayList([]const u8) {
    var strings: std.ArrayList([]const u8) = .empty;
    errdefer strings.deinit(allocator);

    var i: usize = 0;
    var saw_literal = false;
    while (i < args.len) {
        i = skipWs(args, i);
        if (i >= args.len) break;
        if (args[i] == ',') {
            i += 1;
            continue;
        }
        if (args[i] != '"' and args[i] != '\'') return unsupported_error;
        const parsed = try parseQuoted(allocator, args, i);
        try strings.append(allocator, parsed.value);
        saw_literal = true;
        i = skipWs(args, parsed.next);
        if (i < args.len and args[i] != ',') return unsupported_error;
    }
    if (!saw_literal) return unsupported_error;
    return strings;
}

pub fn parseQuoted(allocator: std.mem.Allocator, text: []const u8, start: usize) !ParsedString {
    const quote = text[start];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == quote) {
            return .{ .value = try out.toOwnedSlice(allocator), .next = i + 1 };
        }
        if (ch == '\\' and i + 1 < text.len) {
            i += 1;
            try out.append(allocator, text[i]);
        } else {
            try out.append(allocator, ch);
        }
    }
    return error.UnsupportedJinja;
}

pub fn skipQuotedSpan(text: []const u8, start: usize) ?usize {
    const quote = text[start];
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len) {
            i += 1;
            continue;
        }
        if (text[i] == quote) return i + 1;
    }
    return null;
}

pub fn skipWs(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\r' or text[i] == '\n')) i += 1;
    return i;
}

pub fn findMatchingParen(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var quote: ?u8 = null;
    var i = open;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (quote) |q| {
            if (ch == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (ch == q) quote = null;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
        } else if (ch == '(') {
            depth += 1;
        } else if (ch == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

pub fn isIdentStart(ch: u8) bool {
    return (ch >= 'A' and ch <= 'Z') or (ch >= 'a' and ch <= 'z') or ch == '_';
}

pub fn isIdentChar(ch: u8) bool {
    return isIdentStart(ch) or (ch >= '0' and ch <= '9');
}

pub fn findKeyword(text: []const u8, keyword: []const u8) ?usize {
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, text, search_start, keyword)) |pos| {
        const before_ok = pos == 0 or !isIdentChar(text[pos - 1]);
        const after = pos + keyword.len;
        const after_ok = after >= text.len or !isIdentChar(text[after]);
        if (before_ok and after_ok) return pos;
        search_start = pos + keyword.len;
    }
    return null;
}

pub fn findValueStart(text: []const u8, start: usize) ?usize {
    var i = skipWs(text, start);
    if (i >= text.len or text[i] != '=') return null;
    i = skipWs(text, i + 1);
    return if (i < text.len) i else null;
}

test "findMatchingParen handles nested calls and quoted parens" {
    const text = "ref('a)', nested(\"b(c)\"))";
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(?usize, text.len - 1), findMatchingParen(text, open));
}

test "findMatchingParen handles escaped quotes inside strings" {
    const text = "call(\"a\\\" )\", other('x\\'y'))";
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(?usize, text.len - 1), findMatchingParen(text, open));
}

test "parseQuoted preserves current escape handling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const double = try parseQuoted(allocator, "\"a\\\"b\\\\c\"", 0);
    try std.testing.expectEqualStrings("a\"b\\c", double.value);
    try std.testing.expectEqual(@as(usize, 9), double.next);

    const single = try parseQuoted(allocator, "'a\\'b'", 0);
    try std.testing.expectEqualStrings("a'b", single.value);
    try std.testing.expectEqual(@as(usize, 6), single.next);
}

test "parseLiteralArgs accepts quoted args and preserves caller error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var strings = try parseLiteralArgs(allocator, "\"pkg\", 'model'", error.UnsupportedDynamicRef);
    defer strings.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), strings.items.len);
    try std.testing.expectEqualStrings("pkg", strings.items[0]);
    try std.testing.expectEqualStrings("model", strings.items[1]);

    try std.testing.expectError(error.UnsupportedDynamicSource, parseLiteralArgs(allocator, "var('source')", error.UnsupportedDynamicSource));
}

test "readJinjaCall parses unqualified and package-qualified calls" {
    const ref_span = "ref('customers')";
    const ref_call = (try readJinjaCall(ref_span, "ref", 3)) orelse return error.TestExpectedEqual;
    try std.testing.expect(ref_call.package_name == null);
    try std.testing.expectEqualStrings("ref", ref_call.name);
    try std.testing.expectEqual(@as(usize, 3), ref_call.open);
    try std.testing.expectEqual(@as(usize, ref_span.len - 1), ref_call.close);

    const package_span = "dbt_utils.star(from=ref('orders'))";
    const package_call = (try readJinjaCall(package_span, "dbt_utils", 9)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("dbt_utils", package_call.package_name.?);
    try std.testing.expectEqualStrings("star", package_call.name);
    try std.testing.expectEqual(@as(usize, 14), package_call.open);
    try std.testing.expectEqual(@as(usize, package_span.len - 1), package_call.close);

    try std.testing.expect((try readJinjaCall("ref + 1", "ref", 3)) == null);
}

test "skipQuotedSpan and findKeyword keep lexical boundaries" {
    try std.testing.expect(skipQuotedSpan("\"unterminated", 0) == null);
    try std.testing.expectEqual(@as(?usize, 0), findKeyword("materialized='table'", "materialized"));
    try std.testing.expect(findKeyword("not_materialized='table'", "materialized") == null);
    try std.testing.expectEqual(@as(?usize, 0), findKeyword("tags=['nightly']", "tags"));
    try std.testing.expect(findKeyword("tagspace=['nightly']", "tags") == null);
}
