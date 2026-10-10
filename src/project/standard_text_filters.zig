//! Standard Jinja URL quoting and text wrapping, implemented natively.
const std = @import("std");
const expression = @import("expression.zig");
const unicode = @import("expression_unicode.zig");
const engine = @import("regex_engine.zig");
const Value = expression.Value;

pub fn call(a: std.mem.Allocator, name: []const u8, value: Value, args: []const expression.Argument) !?Value {
    return callWithHost(a, name, value, args, null);
}
pub fn callWithHost(a: std.mem.Allocator, name: []const u8, value: Value, args: []const expression.Argument, host: ?expression.Host) !?Value {
    if (std.mem.eql(u8, name, "urlencode")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        return .{ .string = try urlencode(a, value, host) };
    }
    if (!std.mem.eql(u8, name, "wordwrap")) return null;
    const bound = try @import("filter_arguments.zig").bind(a, args, &.{ "width", "break_long_words", "wrapstring", "break_on_hyphens" }, &.{ .{ .integer = "79" }, .{ .boolean = true }, .none, .{ .boolean = true } }, 0);
    if (bound[2] == .capture_undefined) return try expression.callUndefined(bound[2]);
    if (expression.isUndefined(bound[2])) return error.UndefinedJinjaValue;
    const separator = if (bound[2] == .none) "\n" else if (bound[2] == .string) bound[2].string else return error.JinjaTypeError;
    if (value == .capture_undefined) {
        _ = try expression.callUndefined(value);
        return .{ .string = "" };
    }
    if (expression.isUndefined(value)) return error.UndefinedJinjaValue;
    if (value != .string) return error.JinjaTypeError;
    return .{ .string = try wrap(a, value.string, bound[0], bound[1].truthy(), separator, bound[3]) };
}

fn quote(a: std.mem.Allocator, value: Value, query: bool, host: ?expression.Host) ![]const u8 {
    const binary = value.attribute("__dxt_binary");
    const text = if (binary == .string) binary.string else try expression.textWithHost(a, value, host);
    var out: std.Io.Writer.Allocating = .init(a);
    for (text) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "-._~", byte) != null or (!query and byte == '/')) {
            try out.writer.writeByte(byte);
        } else if (query and byte == ' ') {
            try out.writer.writeByte('+');
        } else try out.writer.print("%{X:0>2}", .{byte});
    }
    return out.toOwnedSlice();
}

fn urlencode(a: std.mem.Allocator, value: Value, host: ?expression.Host) ![]const u8 {
    if (value == .string or !expression.isIterable(value)) return quote(a, value, false, host);
    var out: std.Io.Writer.Allocating = .init(a);
    var count: usize = 0;
    // Jinja special-cases actual dicts. Mapping providers such as pytz's
    // LazyDict instead supply their visible keys to pair unpacking.
    if (value == .object and expression.mappingSource(value) == null and @import("expression_sequence.zig").kind(value) == null and value.attribute("__dxt_iterable") != .list and !@import("set_context.zig").isSet(value)) {
        for (value.object) |entry| {
            if (count != 0) try out.writer.writeByte('&');
            try out.writer.print("{s}={s}", .{ try quote(a, expression.entryKey(entry), true, host), try quote(a, entry.value, true, host) });
            count += 1;
        }
    } else {
        const sequence = @import("expression_sequence.zig");
        const iterator = try sequence.iter(a, value);
        while (try sequence.next(a, iterator, host)) |item| {
            // Tuple unpacking reads only enough to distinguish two from three.
            const pair = try sequence.iter(a, item);
            const key = (try sequence.next(a, pair, host)) orelse return error.JinjaValueError;
            const member = (try sequence.next(a, pair, host)) orelse return error.JinjaValueError;
            if (try sequence.next(a, pair, host) != null) return error.JinjaValueError;
            if (count != 0) try out.writer.writeByte('&');
            try out.writer.print("{s}={s}", .{ try quote(a, key, true, host), try quote(a, member, true, host) });
            count += 1;
        }
    }
    return out.toOwnedSlice();
}

test "URL pairs stop pulling at unpack failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sequence = @import("expression_sequence.zig");
    const outer = try sequence.iterator(a, &.{ .{ .integer = "1" }, .{ .integer = "2" } });
    try std.testing.expectError(error.JinjaTypeError, call(a, "urlencode", outer, &.{}));
    try std.testing.expectEqualStrings("1", outer.attribute("__dxt_sequence_cursor").integer);
    const inner = try sequence.iterator(a, &.{ .{ .integer = "1" }, .{ .integer = "2" }, .{ .integer = "3" }, .{ .integer = "4" } });
    const nested = try sequence.iterator(a, &.{inner});
    try std.testing.expectError(error.JinjaValueError, call(a, "urlencode", nested, &.{}));
    try std.testing.expectEqualStrings("3", inner.attribute("__dxt_sequence_cursor").integer);
}

const Chunk = struct { text: []const u8, length: usize };

fn wrap(a: std.mem.Allocator, text: []const u8, width: Value, break_words: bool, separator: []const u8, hyphens: Value) ![]const u8 {
    if (text.len == 0) return "";
    const measure = if (expression.integerProtocol(width)) |integer|
        try std.fmt.parseFloat(f64, integer)
    else if (width == .integer)
        try std.fmt.parseFloat(f64, width.integer)
    else
        try expression.numericFloat(width);
    if (measure <= 0 or std.math.isNan(measure)) return error.JinjaValueError;
    // Whitespace chunks follow TextWrapper's ASCII splitting rules, while
    // trimming recognizes Python's complete Unicode whitespace table.
    const pattern = if (hyphens == .boolean and hyphens.boolean)
        "([\\t\\n\\v\\f\\r ]+|(?<=[\\w!\"'&.,?])--+(?=\\w)|[^\\t\\n\\v\\f\\r ]+?(?:-(?:(?<=[^\\d\\W]{2}-)|(?<=[^\\d\\W]-[^\\d\\W]-))(?=[^\\d\\W]-?[^\\d\\W])|(?=[\\t\\n\\v\\f\\r ]|\\Z)|(?<=[\\w!\"'&.,?])(?=--+\\w)))"
    else
        "([\\t\\n\\v\\f\\r ]+)";
    const regex = try engine.compile(a, pattern, 0);
    defer regex.deinit();
    var output: std.Io.Writer.Allocating = .init(a);
    var position: usize = 0;
    var paragraph: usize = 0;
    while (position < text.len) : (paragraph += 1) {
        var end = position;
        while (end < text.len and lineBreak(text[end..]) == 0) end += 1;
        if (paragraph != 0) try output.writer.writeAll(separator);
        try output.writer.writeAll(try wrapLine(a, text[position..end], regex, width, measure, break_words, hyphens.truthy(), separator));
        position = end + lineBreak(text[end..]);
    }
    return output.toOwnedSlice();
}

fn wrapLine(a: std.mem.Allocator, text: []const u8, regex: engine.Regex, width: Value, measure: f64, break_words: bool, hyphens: bool, separator: []const u8) ![]const u8 {
    var chunks: std.ArrayList(Chunk) = .empty;
    var cursor: usize = 0;
    while (try regex.find(a, text, cursor, text.len, 0)) |match| {
        const start: usize = @intCast(match.spans[0].start);
        const end: usize = @intCast(match.spans[0].end);
        if (start != cursor) try chunks.append(a, .{ .text = text[cursor..start], .length = try unicode.count(text[cursor..start]) });
        if (end == start) return error.InvalidRegularExpression;
        try chunks.append(a, .{ .text = text[start..end], .length = try unicode.count(text[start..end]) });
        cursor = end;
    }
    if (cursor != text.len) try chunks.append(a, .{ .text = text[cursor..], .length = try unicode.count(text[cursor..]) });
    var out: std.Io.Writer.Allocating = .init(a);
    var next: usize = 0;
    var line_count: usize = 0;
    while (next < chunks.items.len) {
        if (line_count != 0 and (try unicode.strip(chunks.items[next].text, null, true, true)).len == 0) next += 1;
        var pieces: std.ArrayList([]const u8) = .empty;
        var length: usize = 0;
        while (next < chunks.items.len and @as(f64, @floatFromInt(length + chunks.items[next].length)) <= measure) {
            try pieces.append(a, chunks.items[next].text);
            length += chunks.items[next].length;
            next += 1;
        }
        if (next < chunks.items.len and @as(f64, @floatFromInt(chunks.items[next].length)) > measure) {
            if (break_words) {
                const remaining = try expression.integerIndex(width) - @as(i64, @intCast(length));
                var take: usize = @intCast(@max(0, remaining));
                var end = try engine.byteOffset(chunks.items[next].text, @intCast(take));
                if (hyphens) if (std.mem.lastIndexOfScalar(u8, chunks.items[next].text[0..end], '-')) |at| {
                    var nonhyphen = false;
                    for (chunks.items[next].text[0..at]) |byte| if (byte != '-') {
                        nonhyphen = true;
                        break;
                    };
                    if (at != 0 and nonhyphen) {
                        end = at + 1;
                        take = try unicode.count(chunks.items[next].text[0..end]);
                    }
                };
                try pieces.append(a, chunks.items[next].text[0..end]);
                chunks.items[next].text = chunks.items[next].text[end..];
                chunks.items[next].length -= take;
            } else if (pieces.items.len == 0) {
                try pieces.append(a, chunks.items[next].text);
                next += 1;
            }
        }
        if (pieces.items.len != 0 and (try unicode.strip(pieces.items[pieces.items.len - 1], null, true, true)).len == 0) _ = pieces.pop();
        if (pieces.items.len != 0) {
            if (line_count != 0) try out.writer.writeAll(separator);
            for (pieces.items) |piece| try out.writer.writeAll(piece);
            line_count += 1;
        }
        if (line_count > 10000000) return error.JinjaIterationLimitExceeded;
    }
    return out.toOwnedSlice();
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

test "URL quoting distinguishes UTF-8 paths and ordered query pairs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a/b%20%C3%A9%3F", (try call(a, "urlencode", .{ .string = "a/b é?" }, &.{})).?.string);
    const dictionary = Value{ .object = &.{.{ .key = "a b", .value = .{ .string = "é/好" } }} };
    try std.testing.expectEqualStrings("a+b=%C3%A9%2F%E5%A5%BD", (try call(a, "urlencode", dictionary, &.{})).?.string);
}

test "word wrapping counts Unicode codepoints and preserves paragraphs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = &[_]expression.Argument{.{ .value = .{ .integer = "3" } }};
    try std.testing.expectEqualStrings("a b\nc\n\né好😀\nX", (try call(a, "wordwrap", .{ .string = "a b c\n\né好😀X" }, args)).?.string);
    try std.testing.expectEqualStrings("goof-\nball", (try call(a, "wordwrap", .{ .string = "goof-ball" }, &.{.{ .value = .{ .integer = "5" } }})).?.string);
    try std.testing.expectEqualStrings("", (try call(a, "wordwrap", .{ .string = "" }, &.{.{ .value = .none }})).?.string);
    try std.testing.expectError(error.JinjaTypeError, call(a, "wordwrap", .{ .string = "abcd" }, &.{.{ .value = .{ .number = 2.0 } }}));
}
