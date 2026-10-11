//! Normalize Python's Unicode string-pattern vocabulary for the native engine.
const std = @import("std");

pub const Pattern = struct { text: []const u8, flags: u32 };
pub const I: u32 = 2;
pub const L: u32 = 4;
pub const M: u32 = 8;
pub const S: u32 = 16;
pub const U: u32 = 32;
pub const X: u32 = 64;
pub const A: u32 = 256;

const Escape = struct { code: u21, end: usize };
fn unicodeEscape(a: std.mem.Allocator, input: []const u8, at: usize) !?Escape {
    const kind = input[at + 1];
    if (kind == 'N') {
        if (at + 2 == input.len or input[at + 2] != '{') return error.InvalidRegularExpression;
        const close = std.mem.indexOfScalarPos(u8, input, at + 3, '}') orelse return error.InvalidRegularExpression;
        return .{ .code = try @import("unicode_name.zig").lookup(a, input[at + 3 .. close]), .end = close + 1 };
    }
    const digits: usize = switch (kind) {
        'x' => 2,
        'u' => 4,
        'U' => 8,
        else => return null,
    };
    const end = at + 2 + digits;
    if (end > input.len) return error.InvalidRegularExpression;
    const code = std.fmt.parseInt(u21, input[at + 2 .. end], 16) catch return error.InvalidRegularExpression;
    if (code > 0x10ffff) return error.InvalidRegularExpression;
    return .{ .code = code, .end = end };
}

fn word(ascii: bool) []const u8 {
    return if (ascii) "a-zA-Z0-9_" else "\\p{L}\\p{N}_";
}
fn space(ascii: bool) []const u8 {
    return if (ascii) "\\x09-\\x0d " else "\\x09-\\x0d\\x1c-\\x20\\x85\\x{a0}\\x{1680}\\x{2000}-\\x{200a}\\x{2028}\\x{2029}\\x{202f}\\x{205f}\\x{3000}";
}
fn hasTurkishClass(body: []const u8) bool {
    var at: usize = 0;
    while (at < body.len) {
        if (body[at] == '\\') {
            at = @min(at + 2, body.len);
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(body[at]) catch return false;
        if (at + length > body.len) return false;
        const code = std.unicode.utf8Decode(body[at .. at + length]) catch return false;
        if (code == 'i' or code == 'I' or code == 0x130 or code == 0x131) return true;
        const next = at + length;
        if (next + 1 < body.len and body[next] == '-') {
            const end_length = std.unicode.utf8ByteSequenceLength(body[next + 1]) catch return false;
            if (next + 1 + end_length > body.len) return false;
            const end = std.unicode.utf8Decode(body[next + 1 .. next + 1 + end_length]) catch return false;
            for ([_]u21{ 'i', 'I', 0x130, 0x131 }) |special| if (code <= special and special <= end) return true;
        }
        at += length;
    }
    return false;
}
fn classBody(a: std.mem.Allocator, body: []const u8, ascii: bool, caseless: bool) ![]const u8 {
    const negative = body.len != 0 and body[0] == '^';
    var positive: std.ArrayList(u8) = .empty;
    var alternatives: std.ArrayList([]const u8) = .empty;
    var index: usize = if (negative) 1 else 0;
    while (index < body.len) {
        const ch = body[index];
        if (ch != '\\') {
            try positive.append(a, ch);
            index += 1;
            continue;
        }
        if (index + 1 == body.len) return error.InvalidRegularExpression;
        const escaped = body[index + 1];
        if (try unicodeEscape(a, body, index)) |decoded| {
            try positive.appendSlice(a, try std.fmt.allocPrint(a, "\\x{{{x}}}", .{decoded.code}));
            if (caseless and !ascii and (decoded.code == 'i' or decoded.code == 'I' or decoded.code == 0x130 or decoded.code == 0x131)) try positive.appendSlice(a, "iIİı");
            index = decoded.end;
            continue;
        }
        const component: ?[]const u8 = switch (escaped) {
            'w', 'W' => word(ascii),
            'd', 'D' => if (ascii) "0-9" else "\\p{Nd}",
            's', 'S' => space(ascii),
            else => null,
        };
        if (component) |set| {
            if (std.ascii.isUpper(escaped)) try alternatives.append(a, try std.fmt.allocPrint(a, "[^{s}]", .{set})) else try positive.appendSlice(a, set);
        } else {
            if (std.mem.indexOfScalar(u8, "ABZpPKRQEXhHgzGCce", escaped) != null) return error.InvalidRegularExpression;
            if (escaped == 'b') try positive.appendSlice(a, "\\x08") else if (escaped == 'v') try positive.appendSlice(a, "\\x0b") else try positive.appendSlice(a, body[index .. index + 2]);
        }
        index += 2;
    }
    if (caseless and !ascii and hasTurkishClass(body)) try positive.appendSlice(a, "iIİı");
    if (alternatives.items.len == 0) return try std.fmt.allocPrint(a, "[{s}{s}]", .{ if (negative) "^" else "", positive.items });
    if (positive.items.len != 0) try alternatives.append(a, try std.fmt.allocPrint(a, "[{s}]", .{positive.items}));
    const combined = try std.mem.join(a, "|", alternatives.items);
    return if (negative) try std.fmt.allocPrint(a, "(?:(?!(?:{s}))[\\s\\S])", .{combined}) else try std.fmt.allocPrint(a, "(?:{s})", .{combined});
}

// PCRE permits fixed lookbehind alternatives with differing widths. Python
// requires the entire lookbehind to have one width, including nested branches.
fn fixedWidth(input: []const u8) !?usize {
    var position: usize = 0;
    var width: ?usize = 0;
    var previous: ?usize = null;
    var has_previous = false;
    while (position < input.len) {
        const ch = input[position];
        if (ch == '|') {
            if (has_previous and previous != null and width != null and previous.? != width.?) return error.InvalidRegularExpression;
            previous = width;
            has_previous = true;
            width = 0;
            position += 1;
            continue;
        }
        var atom: ?usize = 1;
        if (ch == '(') {
            const close = try groupClose(input, position);
            var begin = position + 1;
            if (begin < close and input[begin] == '?') {
                if (std.mem.startsWith(u8, input[begin..], "?=") or std.mem.startsWith(u8, input[begin..], "?!") or std.mem.startsWith(u8, input[begin..], "?<=") or std.mem.startsWith(u8, input[begin..], "?<!")) atom = 0 else if (std.mem.startsWith(u8, input[begin..], "?:") or std.mem.startsWith(u8, input[begin..], "?>")) begin += 2 else if (std.mem.startsWith(u8, input[begin..], "?P<")) begin = (std.mem.indexOfScalarPos(u8, input, begin + 3, '>') orelse return error.InvalidRegularExpression) + 1 else atom = null;
            }
            if (atom != null and atom.? != 0) atom = try fixedWidth(input[begin..close]);
            position = close + 1;
        } else if (ch == '[') {
            position += 1;
            if (position < input.len and input[position] == '^') position += 1;
            if (position < input.len and input[position] == ']') position += 1;
            while (position < input.len and input[position] != ']') : (position += 1) if (input[position] == '\\') {
                position += 1;
            };
            if (position == input.len) return error.InvalidRegularExpression;
            position += 1;
        } else if (ch == '\\') {
            if (position + 1 == input.len) return error.InvalidRegularExpression;
            const escaped = input[position + 1];
            if (std.mem.indexOfScalar(u8, "AbBZ", escaped) != null) atom = 0;
            if (escaped >= '1' and escaped <= '9') atom = null;
            position += 2;
            const extra: usize = switch (escaped) {
                'x' => 2,
                'u' => 4,
                'U' => 8,
                else => 0,
            };
            position = @min(input.len, position + extra);
            if (escaped == 'N' and position < input.len and input[position] == '{') position = (std.mem.indexOfScalarPos(u8, input, position, '}') orelse return error.InvalidRegularExpression) + 1;
        } else {
            if (ch == '^' or ch == '$') atom = 0;
            position += std.unicode.utf8ByteSequenceLength(ch) catch return error.InvalidRegularExpression;
        }
        if (position < input.len and std.mem.indexOfScalar(u8, "*+?", input[position]) != null) {
            if (atom != null and atom.? != 0) atom = null;
            position += 1;
            if (position < input.len and (input[position] == '?' or input[position] == '+')) position += 1;
        } else if (position < input.len and input[position] == '{') {
            if (std.mem.indexOfScalarPos(u8, input, position, '}')) |close| {
                const authored = input[position + 1 .. close];
                const comma = std.mem.indexOfScalar(u8, authored, ',');
                const minimum = std.fmt.parseInt(usize, authored[0 .. comma orelse authored.len], 10) catch null;
                const maximum = if (comma) |at| std.fmt.parseInt(usize, authored[at + 1 ..], 10) catch null else minimum;
                if (minimum != null) {
                    if (atom) |size| atom = if (maximum != null and maximum.? == minimum.?) size * minimum.? else if (size == 0) 0 else null;
                    position = close + 1;
                    if (position < input.len and (input[position] == '?' or input[position] == '+')) position += 1;
                }
            }
        }
        width = if (width != null and atom != null) width.? + atom.? else null;
    }
    if (has_previous and previous != null and width != null and previous.? != width.?) return error.InvalidRegularExpression;
    return width;
}
fn groupClose(input: []const u8, start: usize) !usize {
    var depth: usize = 1;
    var index = start + 1;
    var character_class = false;
    while (index < input.len) : (index += 1) {
        if (input[index] == '\\') {
            index += 1;
            continue;
        }
        if (input[index] == '[') character_class = true else if (input[index] == ']') character_class = false;
        if (character_class) continue;
        if (input[index] == '(') depth += 1 else if (input[index] == ')') {
            depth -= 1;
            if (depth == 0) return index;
        }
    }
    return error.InvalidRegularExpression;
}

pub fn normalize(a: std.mem.Allocator, input: []const u8, authored_flags: u32) !Pattern {
    if (authored_flags & L != 0 or authored_flags & (A | U) == A | U) return error.InvalidRegularExpressionFlags;
    var flags = authored_flags | (if (authored_flags & A == 0) U else @as(u32, 0));
    var ascii = flags & A != 0;
    var caseless = flags & I != 0;
    var verbose = flags & X != 0;
    const Scope = struct { ascii: bool, caseless: bool, verbose: bool };
    var stack: std.ArrayList(Scope) = .empty;
    defer stack.deinit(a);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    var index: usize = 0;
    var character_class = false;
    while (index < input.len) {
        const ch = input[index];
        if (ch == '#' and verbose) {
            const end = std.mem.indexOfScalarPos(u8, input, index, '\n') orelse input.len;
            try output.appendSlice(a, input[index..end]);
            index = end;
            continue;
        }
        if (flags & 1 != 0 and (ch == '*' or ch == '+' or (ch == '?' and (index == 0 or input[index - 1] != '(')) or (ch == '{' and index + 1 < input.len and std.ascii.isDigit(input[index + 1])))) return error.UnsupportedRegularExpressionTemplate;
        if (ch == '[') {
            var close = index + 1;
            if (close < input.len and input[close] == '^') close += 1;
            if (close < input.len and input[close] == ']') close += 1;
            while (close < input.len and input[close] != ']') : (close += 1) {
                if (input[close] == '\\') close += 1;
            }
            if (close >= input.len) return error.InvalidRegularExpression;
            try output.appendSlice(a, try classBody(a, input[index + 1 .. close], ascii, caseless));
            index = close + 1;
            continue;
        }
        if (ch == '\\') {
            if (index + 1 == input.len) return error.InvalidRegularExpression;
            const escaped = input[index + 1];
            if (try unicodeEscape(a, input, index)) |decoded| {
                const code = decoded.code;
                if (caseless and !ascii and (code == 'i' or code == 'I' or code == 0x130 or code == 0x131)) try output.appendSlice(a, "[iIİı]") else try output.appendSlice(a, try std.fmt.allocPrint(a, "\\x{{{x}}}", .{code}));
                index = decoded.end;
                continue;
            }
            const replacement: ?[]const u8 = switch (escaped) {
                'w' => if (ascii) "a-zA-Z0-9_" else "\\p{L}\\p{N}_",
                'd' => if (ascii) "0-9" else "\\p{Nd}",
                's' => if (ascii) "\\x09-\\x0d " else "\\x09-\\x0d\\x1c-\\x20\\x85\\x{a0}\\x{1680}\\x{2000}-\\x{200a}\\x{2028}\\x{2029}\\x{202f}\\x{205f}\\x{3000}",
                else => null,
            };
            if (replacement) |text| {
                if (!character_class) try output.append(a, '[');
                try output.appendSlice(a, text);
                if (!character_class) try output.append(a, ']');
            } else if (!character_class and (escaped == 'W' or escaped == 'D' or escaped == 'S')) {
                const negative = if (escaped == 'W') (if (ascii) "[^a-zA-Z0-9_]" else "[^\\p{L}\\p{N}_]") else if (escaped == 'D') (if (ascii) "[^0-9]" else "[^\\p{Nd}]") else if (ascii) "[^\\x09-\\x0d ]" else "[^\\x09-\\x0d\\x1c-\\x20\\x85\\x{a0}\\x{1680}\\x{2000}-\\x{200a}\\x{2028}\\x{2029}\\x{202f}\\x{205f}\\x{3000}]";
                try output.appendSlice(a, negative);
            } else if (escaped == 'b' or escaped == 'B') {
                const set = word(ascii);
                const boundary = try std.fmt.allocPrint(a, "(?:(?<=[{s}])(?![{s}])|(?<![{s}])(?=[{s}]))", .{ set, set, set, set });
                if (escaped == 'b') try output.appendSlice(a, boundary) else try output.appendSlice(a, try std.fmt.allocPrint(a, "(?!{s})(?=[\\s\\S]|(?<=[\\s\\S]))", .{boundary}));
            } else if (escaped == 'Z') try output.appendSlice(a, "\\z") else if (escaped == 'v') try output.appendSlice(a, "\\x0b") else {
                if (std.mem.indexOfScalar(u8, "pPKRQEXhHgzGCce", escaped) != null) return error.InvalidRegularExpression;
                try output.appendSlice(a, input[index .. index + 2]);
            }
            index += 2;
            continue;
        }
        if (!character_class and ch == '(') {
            if (std.mem.startsWith(u8, input[index..], "(*")) return error.InvalidRegularExpression;
            if (std.mem.startsWith(u8, input[index..], "(?<=") or std.mem.startsWith(u8, input[index..], "(?<!")) _ = try fixedWidth(input[index + 4 .. try groupClose(input, index)]);
            if (std.mem.startsWith(u8, input[index..], "(?")) {
                var end = index + 2;
                while (end < input.len and std.mem.indexOfScalar(u8, "aiLmsux-", input[end]) != null) end += 1;
                if (end > index + 2 and end < input.len and (input[end] == ')' or input[end] == ':')) {
                    const modifiers = input[index + 2 .. end];
                    if (std.mem.indexOfScalar(u8, modifiers, 'L') != null) return error.InvalidRegularExpressionFlags;
                    const has_a = std.mem.indexOfScalar(u8, modifiers, 'a') != null;
                    const has_u = std.mem.indexOfScalar(u8, modifiers, 'u') != null;
                    if (has_a and has_u) return error.InvalidRegularExpressionFlags;
                    if (input[end] == ')' and std.mem.indexOfScalar(u8, modifiers, '-') != null) return error.InvalidRegularExpressionFlags;
                    const previous = Scope{ .ascii = ascii, .caseless = caseless, .verbose = verbose };
                    var cleaned: std.ArrayList(u8) = .empty;
                    defer cleaned.deinit(a);
                    var negate = false;
                    for (modifiers) |modifier| {
                        if (modifier == '-') {
                            negate = true;
                            try cleaned.append(a, modifier);
                        } else if (modifier == 'a' or modifier == 'u') {
                            if (negate) return error.InvalidRegularExpressionFlags;
                            ascii = modifier == 'a';
                        } else {
                            if (modifier == 'i') caseless = !negate;
                            if (modifier == 'x') verbose = !negate;
                            try cleaned.append(a, modifier);
                            if (input[end] == ')') {
                                const bit: u32 = switch (modifier) {
                                    'i' => I,
                                    'm' => M,
                                    's' => S,
                                    'x' => X,
                                    else => 0,
                                };
                                flags = if (negate) flags & ~bit else flags | bit;
                            }
                        }
                    }
                    if (input[end] == ':') {
                        if (has_a or has_u) {
                            if (ascii) try cleaned.insert(a, std.mem.indexOfScalar(u8, cleaned.items, '-') orelse cleaned.items.len, 'r') else if (std.mem.indexOfScalar(u8, cleaned.items, '-') != null) try cleaned.append(a, 'r') else try cleaned.appendSlice(a, "-r");
                        }
                        try stack.append(a, previous);
                        try output.appendSlice(a, "(?");
                        try output.appendSlice(a, cleaned.items);
                        try output.append(a, ':');
                    } else {
                        if (index != 0) return error.InvalidRegularExpressionFlags;
                        if (ascii) flags = (flags | A) & ~U else flags = (flags | U) & ~A;
                        if (cleaned.items.len != 0) {
                            try output.appendSlice(a, "(?");
                            try output.appendSlice(a, cleaned.items);
                            try output.append(a, ')');
                        }
                    }
                    index = end + 1;
                    continue;
                }
                if (index + 2 >= input.len or std.mem.indexOfScalar(u8, ":=!<>P#(", input[index + 2]) == null) return error.InvalidRegularExpression;
                if (input[index + 2] == '<' and (index + 3 == input.len or (input[index + 3] != '=' and input[index + 3] != '!'))) return error.InvalidRegularExpression;
            }
            if (std.mem.startsWith(u8, input[index..], "(?#") or std.mem.startsWith(u8, input[index..], "(?P=")) {
                const close = std.mem.indexOfScalarPos(u8, input, index + 3, ')') orelse return error.InvalidRegularExpression;
                try output.appendSlice(a, input[index .. close + 1]);
                index = close + 1;
                continue;
            }
            try stack.append(a, .{ .ascii = ascii, .caseless = caseless, .verbose = verbose });
            if (std.mem.startsWith(u8, input[index..], "(?(")) {
                const close = std.mem.indexOfScalarPos(u8, input, index + 3, ')') orelse return error.InvalidRegularExpression;
                if (input[index + 3] == '?') return error.InvalidRegularExpression;
                try output.appendSlice(a, input[index .. close + 1]);
                index = close + 1;
                continue;
            }
            if (std.mem.startsWith(u8, input[index..], "(?P<")) {
                const close = std.mem.indexOfScalarPos(u8, input, index + 4, '>') orelse return error.InvalidRegularExpression;
                try output.appendSlice(a, input[index .. close + 1]);
                index = close + 1;
                continue;
            }
        } else if (!character_class and ch == ')') {
            if (stack.pop()) |previous| {
                ascii = previous.ascii;
                caseless = previous.caseless;
                verbose = previous.verbose;
            }
        }
        if (caseless and !ascii and (ch == 'i' or ch == 'I' or std.mem.startsWith(u8, input[index..], "İ") or std.mem.startsWith(u8, input[index..], "ı"))) {
            try output.appendSlice(a, "[iIİı]");
            index += if (ch >= 0x80) @as(usize, 2) else 1;
            continue;
        }
        if (ch == '[') character_class = true else if (ch == ']') character_class = false;
        try output.append(a, ch);
        index += 1;
    }
    return .{ .text = try output.toOwnedSlice(a), .flags = flags };
}

test "Python Unicode words, whitespace and strict end anchor normalize natively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("[^\\p{L}\\p{N}_\\x09-\\x0d\\x1c-\\x20\\x85\\x{a0}\\x{1680}\\x{2000}-\\x{200a}\\x{2028}\\x{2029}\\x{202f}\\x{205f}\\x{3000}-]", (try normalize(a, "[^\\w\\s-]", 0)).text);
    try std.testing.expectEqualStrings("[a-zA-Z0-9_]\\z", (try normalize(a, "(?a)\\w\\Z", 0)).text);
    try std.testing.expectError(error.InvalidRegularExpression, normalize(a, "\\K", 0));
}
