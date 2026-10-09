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

fn word(ascii: bool) []const u8 {
    return if (ascii) "a-zA-Z0-9_" else "\\p{L}\\p{N}_";
}
fn space(ascii: bool) []const u8 {
    return if (ascii) "\\x09-\\x0d " else "\\x09-\\x0d\\x1c-\\x20\\x85\\x{a0}\\x{1680}\\x{2000}-\\x{200a}\\x{2028}\\x{2029}\\x{202f}\\x{205f}\\x{3000}";
}
fn classBody(a: std.mem.Allocator, body: []const u8, ascii: bool) ![]const u8 {
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
        const component: ?[]const u8 = switch (escaped) {
            'w', 'W' => word(ascii),
            'd', 'D' => if (ascii) "0-9" else "\\p{Nd}",
            's', 'S' => space(ascii),
            else => null,
        };
        if (component) |set| {
            if (std.ascii.isUpper(escaped)) try alternatives.append(a, try std.fmt.allocPrint(a, "[^{s}]", .{set})) else try positive.appendSlice(a, set);
        } else {
            if (std.mem.indexOfScalar(u8, "ABZpPKRQEXhHgz", escaped) != null) return error.InvalidRegularExpression;
            if (escaped == 'b') try positive.appendSlice(a, "\\x08") else if (escaped == 'v') try positive.appendSlice(a, "\\x0b") else try positive.appendSlice(a, body[index .. index + 2]);
        }
        index += 2;
    }
    if (alternatives.items.len == 0) return try std.fmt.allocPrint(a, "[{s}{s}]", .{ if (negative) "^" else "", positive.items });
    if (positive.items.len != 0) try alternatives.append(a, try std.fmt.allocPrint(a, "[{s}]", .{positive.items}));
    const combined = try std.mem.join(a, "|", alternatives.items);
    return if (negative) try std.fmt.allocPrint(a, "(?!(?:{s}))[\\s\\S]", .{combined}) else try std.fmt.allocPrint(a, "(?:{s})", .{combined});
}

pub fn normalize(a: std.mem.Allocator, input: []const u8, authored_flags: u32) !Pattern {
    if (authored_flags & L != 0 or authored_flags & (A | U) == A | U) return error.InvalidRegularExpressionFlags;
    var flags = authored_flags | (if (authored_flags & A == 0) U else @as(u32, 0));
    var ascii = flags & A != 0;
    var stack: std.ArrayList(bool) = .empty;
    defer stack.deinit(a);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    var index: usize = 0;
    var character_class = false;
    while (index < input.len) {
        const ch = input[index];
        if (ch == '[') {
            var close = index + 1;
            if (close < input.len and input[close] == '^') close += 1;
            if (close < input.len and input[close] == ']') close += 1;
            while (close < input.len and input[close] != ']') : (close += 1) {
                if (input[close] == '\\') close += 1;
            }
            if (close >= input.len) return error.InvalidRegularExpression;
            try output.appendSlice(a, try classBody(a, input[index + 1 .. close], ascii));
            index = close + 1;
            continue;
        }
        if (ch == '\\') {
            if (index + 1 == input.len) return error.InvalidRegularExpression;
            const escaped = input[index + 1];
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
                if (std.mem.indexOfScalar(u8, "pPKRQEXhHgz", escaped) != null) return error.InvalidRegularExpression;
                try output.appendSlice(a, input[index .. index + 2]);
            }
            index += 2;
            continue;
        }
        if (!character_class and ch == '(') {
            if (std.mem.startsWith(u8, input[index..], "(?")) {
                var end = index + 2;
                while (end < input.len and std.mem.indexOfScalar(u8, "aiLmsux-", input[end]) != null) end += 1;
                if (end > index + 2 and end < input.len and (input[end] == ')' or input[end] == ':')) {
                    const modifiers = input[index + 2 .. end];
                    if (std.mem.indexOfScalar(u8, modifiers, 'L') != null) return error.InvalidRegularExpressionFlags;
                    const previous = ascii;
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
                if (index + 2 >= input.len or std.mem.indexOfScalar(u8, ":=!<>P#", input[index + 2]) == null) return error.InvalidRegularExpression;
                if (input[index + 2] == '<' and (index + 3 == input.len or (input[index + 3] != '=' and input[index + 3] != '!'))) return error.InvalidRegularExpression;
            }
            try stack.append(a, ascii);
        } else if (!character_class and ch == ')') {
            if (stack.pop()) |previous| ascii = previous;
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
