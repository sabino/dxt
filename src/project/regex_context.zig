//! Python-compatible string regular expressions in dbt's native modules context.
const std = @import("std");
const expr = @import("expression.zig");
const engine = @import("regex_engine.zig");
const Value = expr.Value;
const Argument = expr.Argument;
const Allocator = std.mem.Allocator;
const Pattern = struct { pattern: []const u8, flags: u32 };
const Capture = struct {
    pattern: Pattern,
    string: []const u8,
    spans: []const engine.Span,
    names: []const engine.Name,
    lastindex: ?usize,
    pos: i64,
    endpos: i64,
};
const functions = [_][]const u8{ "compile", "search", "match", "fullmatch", "findall", "finditer", "sub", "subn", "split", "escape", "purge" };
const flags = [_]struct { name: []const u8, value: u32 }{
    .{ .name = "NOFLAG", .value = 0 },     .{ .name = "TEMPLATE", .value = 1 },  .{ .name = "T", .value = 1 },
    .{ .name = "IGNORECASE", .value = 2 }, .{ .name = "I", .value = 2 },         .{ .name = "LOCALE", .value = 4 },
    .{ .name = "L", .value = 4 },          .{ .name = "MULTILINE", .value = 8 }, .{ .name = "M", .value = 8 },
    .{ .name = "DOTALL", .value = 16 },    .{ .name = "S", .value = 16 },        .{ .name = "UNICODE", .value = 32 },
    .{ .name = "U", .value = 32 },         .{ .name = "VERBOSE", .value = 64 },  .{ .name = "X", .value = 64 },
    .{ .name = "DEBUG", .value = 128 },    .{ .name = "ASCII", .value = 256 },   .{ .name = "A", .value = 256 },
};

fn entry(a: Allocator, fields: []const expr.Entry) !Value {
    return .{ .object = try a.dupe(expr.Entry, fields) };
}
fn string(value: Value) ![]const u8 {
    return if (value == .string) value.string else error.JinjaTypeError;
}
fn argument(args: []const Argument, name: []const u8, position: usize) Value {
    var index: usize = 0;
    for (args) |arg| {
        if (arg.name) |key| {
            if (std.mem.eql(u8, key, name)) return arg.value;
        } else {
            if (index == position) return arg.value;
            index += 1;
        }
    }
    return .undefined;
}
fn integerArg(args: []const Argument, name: []const u8, position: usize, fallback: i64) !i64 {
    const value = argument(args, name, position);
    return if (value == .undefined) fallback else try expr.integerIndex(value);
}
fn bound(a: Allocator, prefix: []const u8, method: []const u8, definition: anytype) !Value {
    return .{ .callable = try std.fmt.allocPrint(a, "{s}{s}:{s}", .{ prefix, method, try std.json.Stringify.valueAlloc(a, definition, .{}) }) };
}
fn flagValue(a: Allocator, number: u32) !Value {
    const label = if (number == 0) "re.NOFLAG" else (try flagText(a, number))[2..];
    return try entry(a, &.{
        .{ .key = "__dxt_integer", .value = .{ .string = (try expr.integerValue(a, number)).integer } },
        .{ .key = "__dxt_rendered", .value = .{ .string = label } },
        .{ .key = "value", .value = try expr.integerValue(a, number) },
        .{ .key = "name", .value = .{ .string = label[3..] } },
    });
}

pub fn resolve(a: Allocator, path: []const u8) !?Value {
    if (std.mem.eql(u8, path, "modules") or std.mem.eql(u8, path, "modules.re")) {
        var fields: std.ArrayList(expr.Entry) = .empty;
        for (functions) |name| try fields.append(a, .{ .key = name, .value = .{ .callable = try std.fmt.allocPrint(a, "modules.re.{s}", .{name}) } });
        for (flags) |flag| try fields.append(a, .{ .key = flag.name, .value = try flagValue(a, flag.value) });
        const module = Value{ .object = try fields.toOwnedSlice(a) };
        return if (std.mem.eql(u8, path, "modules")) try entry(a, &.{.{ .key = "re", .value = module }}) else module;
    }
    if (std.mem.startsWith(u8, path, "modules.re.")) {
        const name = path[11..];
        for (flags) |flag| if (std.mem.eql(u8, name, flag.name)) return try flagValue(a, flag.value);
        for (functions) |function| if (std.mem.eql(u8, name, function)) return .{ .callable = path };
    }
    return null;
}

fn patternValue(a: Allocator, definition: Pattern) !Value {
    const regex = try engine.compile(a, definition.pattern, definition.flags);
    defer regex.deinit();
    const actual = Pattern{ .pattern = definition.pattern, .flags = regex.flags };
    var fields: std.ArrayList(expr.Entry) = .empty;
    try fields.appendSlice(a, &.{
        .{ .key = "__dxt_regex_pattern", .value = .{ .string = try std.json.Stringify.valueAlloc(a, actual, .{}) } },
        .{ .key = "pattern", .value = .{ .string = definition.pattern } },
        .{ .key = "flags", .value = try expr.integerValue(a, regex.flags) },
        .{ .key = "groups", .value = try expr.integerValue(a, regex.groups) },
        .{ .key = "__dxt_rendered", .value = .{ .string = try std.fmt.allocPrint(a, "re.compile({s}{s})", .{ try expr.repr(.{ .string = definition.pattern }, a), try flagText(a, regex.flags & ~@as(u32, 32)) }) } },
    });
    var names: std.ArrayList(expr.Entry) = .empty;
    for (regex.names) |name| try names.append(a, .{ .key = name.name, .value = try expr.integerValue(a, name.index) });
    try fields.append(a, .{ .key = "groupindex", .value = .{ .object = try names.toOwnedSlice(a) } });
    for ([_][]const u8{ "search", "match", "fullmatch", "findall", "finditer", "sub", "subn", "split" }) |method| try fields.append(a, .{ .key = method, .value = try bound(a, "__dxt_regex_pattern:", method, actual) });
    return .{ .object = try fields.toOwnedSlice(a) };
}
fn flagText(a: Allocator, bits: u32) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for ([_][]const u8{ "TEMPLATE", "IGNORECASE", "LOCALE", "MULTILINE", "DOTALL", "UNICODE", "VERBOSE", "DEBUG", "ASCII" }, 0..) |name, index| {
        if (bits & (@as(u32, 1) << @intCast(index)) == 0) continue;
        try text.appendSlice(a, if (text.items.len == 0) ", re." else "|re.");
        try text.appendSlice(a, name);
    }
    return try text.toOwnedSlice(a);
}
fn groupIndex(capture: Capture, authored: Value) !usize {
    if (authored == .string) {
        for (capture.names) |name| if (std.mem.eql(u8, authored.string, name.name)) return name.index;
        return error.RegularExpressionGroupError;
    }
    const index = expr.integerIndex(authored) catch return error.RegularExpressionGroupError;
    if (index < 0 or index >= capture.spans.len) return error.RegularExpressionGroupError;
    return @intCast(index);
}
fn group(capture: Capture, index: usize, fallback: Value) Value {
    const span = capture.spans[index];
    return if (span.start < 0) fallback else .{ .string = capture.string[@intCast(span.start)..@intCast(span.end)] };
}
fn matchValue(a: Allocator, capture: Capture) !Value {
    var fields: std.ArrayList(expr.Entry) = .empty;
    const start = try engine.characterOffset(capture.string, capture.spans[0].start);
    const end = try engine.characterOffset(capture.string, capture.spans[0].end);
    const groups = try expr.allocateValues(a, capture.spans.len);
    for (groups, 0..) |*value, index| value.* = group(capture, index, .none);
    var names: std.ArrayList(expr.Entry) = .empty;
    for (capture.names) |name| try names.append(a, .{ .key = name.name, .value = group(capture, name.index, .none) });
    var lastgroup: Value = .none;
    if (capture.lastindex) |index| for (capture.names) |name| {
        if (name.index == index) lastgroup = .{ .string = name.name };
    };
    try fields.appendSlice(a, &.{
        .{ .key = "__dxt_indexed", .value = .{ .list = groups } },                                                                                                                                     .{ .key = "__dxt_string_index", .value = .{ .object = try names.toOwnedSlice(a) } },
        .{ .key = "string", .value = .{ .string = capture.string } },                                                                                                                                  .{ .key = "re", .value = try patternValue(a, capture.pattern) },
        .{ .key = "pos", .value = try expr.integerValue(a, capture.pos) },                                                                                                                             .{ .key = "endpos", .value = try expr.integerValue(a, capture.endpos) },
        .{ .key = "lastindex", .value = if (capture.lastindex) |index| try expr.integerValue(a, index) else .none },                                                                                   .{ .key = "lastgroup", .value = lastgroup },
        .{ .key = "__dxt_rendered", .value = .{ .string = try std.fmt.allocPrint(a, "<re.Match object; span=({d}, {d}), match={s}>", .{ start, end, try expr.repr(group(capture, 0, .none), a) }) } },
    });
    for ([_][]const u8{ "group", "groups", "groupdict", "start", "end", "span", "expand" }) |method| try fields.append(a, .{ .key = method, .value = try bound(a, "__dxt_regex_match:", method, capture) });
    return .{ .object = try fields.toOwnedSlice(a) };
}

fn captures(a: Allocator, regex: engine.Regex, definition: Pattern, subject: []const u8, start: usize, end: usize, pos: i64, endpos: i64) ![]const Capture {
    var results: std.ArrayList(Capture) = .empty;
    var cursor = start;
    var after_empty = false;
    while (cursor <= end) {
        const options: u32 = if (after_empty) engine.c.PCRE2_NOTEMPTY_ATSTART | engine.c.PCRE2_ANCHORED else 0;
        const found = try regex.find(a, subject, cursor, end, options);
        if (found) |match| {
            if (results.items.len == 100000) return error.JinjaIterationLimitExceeded;
            try results.append(a, .{ .pattern = definition, .string = subject, .spans = match.spans, .names = regex.names, .lastindex = match.lastindex, .pos = pos, .endpos = endpos });
            cursor = @intCast(match.spans[0].end);
            after_empty = match.spans[0].start == match.spans[0].end;
        } else if (after_empty and cursor < end) {
            cursor += try std.unicode.utf8ByteSequenceLength(subject[cursor]);
            after_empty = false;
        } else break;
    }
    return try results.toOwnedSlice(a);
}

fn replacement(a: Allocator, template: []const u8, capture: Capture) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] != '\\') {
            try output.append(a, template[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i == template.len) return error.InvalidRegularExpressionReplacement;
        const ch = template[i];
        i += 1;
        var index: ?usize = null;
        if (ch == 'g') {
            if (i == template.len or template[i] != '<') return error.InvalidRegularExpressionReplacement;
            const close = std.mem.indexOfScalarPos(u8, template, i + 1, '>') orelse return error.InvalidRegularExpressionReplacement;
            const name = template[i + 1 .. close];
            const number = std.fmt.parseInt(i64, name, 10) catch null;
            index = try groupIndex(capture, if (number) |n| try expr.integerValue(a, n) else .{ .string = name });
            i = close + 1;
        } else if (ch >= '0' and ch <= '9') {
            if (ch == '0' or (ch <= '7' and i + 1 < template.len and template[i] >= '0' and template[i] <= '7' and template[i + 1] >= '0' and template[i + 1] <= '7')) {
                var code: u21 = ch - '0';
                var count: usize = 1;
                while (count < 3 and i < template.len and template[i] >= '0' and template[i] <= '7') : (count += 1) {
                    code = code * 8 + template[i] - '0';
                    i += 1;
                }
                if (code > 255) return error.InvalidRegularExpressionReplacement;
                var bytes: [4]u8 = undefined;
                const length = try std.unicode.utf8Encode(code, &bytes);
                try output.appendSlice(a, bytes[0..length]);
            } else {
                var number: usize = ch - '0';
                if (i < template.len and std.ascii.isDigit(template[i])) {
                    number = number * 10 + template[i] - '0';
                    i += 1;
                }
                if (number >= capture.spans.len) return error.InvalidRegularExpressionReplacement;
                index = number;
            }
        } else {
            const escaped: ?u8 = switch (ch) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'b' => 8,
                'f' => 12,
                'a' => 7,
                'v' => 11,
                '\\' => '\\',
                else => null,
            };
            if (escaped) |byte| try output.append(a, byte) else {
                if (std.ascii.isAlphabetic(ch)) return error.InvalidRegularExpressionReplacement;
                try output.appendSlice(a, &.{ '\\', ch });
            }
        }
        if (index) |number| try output.appendSlice(a, group(capture, number, .{ .string = "" }).string);
    }
    return try output.toOwnedSlice(a);
}

fn callMatch(a: Allocator, method: []const u8, capture: Capture, args: []const Argument) !Value {
    if (std.mem.eql(u8, method, "group")) {
        if (args.len == 0) return group(capture, 0, .none);
        const values = try expr.allocateValues(a, args.len);
        for (args, values) |arg, *value| {
            if (arg.name != null) return error.InvalidJinjaArguments;
            value.* = group(capture, try groupIndex(capture, arg.value), .none);
        }
        return if (values.len == 1) values[0] else .{ .tuple = values };
    }
    if (std.mem.eql(u8, method, "groups") or std.mem.eql(u8, method, "groupdict")) {
        if (args.len > 1) return error.InvalidJinjaArguments;
        const default = argument(args, "default", 0);
        const fallback: Value = if (default == .undefined) .none else default;
        if (std.mem.eql(u8, method, "groups")) {
            const values = try expr.allocateValues(a, capture.spans.len - 1);
            for (values, 1..) |*value, index| value.* = group(capture, index, fallback);
            return .{ .tuple = values };
        }
        const fields = try expr.allocateEntries(a, capture.names.len);
        for (fields, capture.names) |*field, name| field.* = .{ .key = name.name, .value = group(capture, name.index, fallback) };
        return .{ .object = fields };
    }
    if (std.mem.eql(u8, method, "expand")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
        return .{ .string = try replacement(a, try string(args[0].value), capture) };
    }
    if (args.len > 1) return error.InvalidJinjaArguments;
    const authored = argument(args, "group", 0);
    const index = if (authored == .undefined) 0 else try groupIndex(capture, authored);
    const span = capture.spans[index];
    const start = try engine.characterOffset(capture.string, span.start);
    const end = try engine.characterOffset(capture.string, span.end);
    if (std.mem.eql(u8, method, "start")) return try expr.integerValue(a, start);
    if (std.mem.eql(u8, method, "end")) return try expr.integerValue(a, end);
    const values = try expr.allocateValues(a, 2);
    values[0] = try expr.integerValue(a, start);
    values[1] = try expr.integerValue(a, end);
    return .{ .tuple = values };
}

fn execute(a: Allocator, method: []const u8, definition: Pattern, args: []const Argument, host: ?expr.Host) !Value {
    const regex = try engine.compile(a, definition.pattern, definition.flags);
    defer regex.deinit();
    const substitution = std.mem.eql(u8, method, "sub") or std.mem.eql(u8, method, "subn");
    const subject = try string(argument(args, "string", if (substitution) 1 else 0));
    const length: i64 = @intCast(try @import("expression_unicode.zig").count(subject));
    const has_bounds = !substitution and !std.mem.eql(u8, method, "split");
    const pos = if (has_bounds) @max(0, try integerArg(args, "pos", 1, 0)) else 0;
    const endpos = if (has_bounds) std.math.clamp(try integerArg(args, "endpos", 2, length), 0, length) else length;
    const start = try engine.byteOffset(subject, pos);
    const end = try engine.byteOffset(subject, endpos);
    const actual = Pattern{ .pattern = definition.pattern, .flags = regex.flags };
    if (std.mem.eql(u8, method, "search") or std.mem.eql(u8, method, "match") or std.mem.eql(u8, method, "fullmatch")) {
        if (pos > endpos) return .none;
        const options: u32 = if (std.mem.eql(u8, method, "fullmatch")) engine.c.PCRE2_ANCHORED | engine.c.PCRE2_ENDANCHORED else if (std.mem.eql(u8, method, "match")) engine.c.PCRE2_ANCHORED else 0;
        const found = (try regex.find(a, subject, start, end, options)) orelse return .none;
        return try matchValue(a, .{ .pattern = actual, .string = subject, .spans = found.spans, .names = regex.names, .lastindex = found.lastindex, .pos = pos, .endpos = endpos });
    }
    const matches = if (pos > endpos) &.{} else try captures(a, regex, actual, subject, start, end, pos, endpos);
    if (std.mem.eql(u8, method, "findall") or std.mem.eql(u8, method, "finditer")) {
        const values = try expr.allocateValues(a, matches.len);
        for (matches, values) |capture, *value| {
            if (std.mem.eql(u8, method, "finditer")) value.* = try matchValue(a, capture) else if (regex.groups == 0) value.* = group(capture, 0, .{ .string = "" }) else if (regex.groups == 1) value.* = group(capture, 1, .{ .string = "" }) else {
                const fields = try expr.allocateValues(a, regex.groups);
                for (fields, 1..) |*field, index| field.* = group(capture, index, .{ .string = "" });
                value.* = .{ .tuple = fields };
            }
        }
        return if (std.mem.eql(u8, method, "finditer")) try @import("expression_sequence.zig").iterator(a, values) else .{ .list = values };
    }
    const limit = try integerArg(args, if (substitution) "count" else "maxsplit", if (substitution) 2 else 1, 0);
    var output: std.ArrayList(u8) = .empty;
    var fields: std.ArrayList(Value) = .empty;
    var cursor: usize = 0;
    var count: usize = 0;
    const repl = if (substitution) argument(args, "repl", 0) else Value.none;
    if (substitution and repl != .string and repl != .callable) return error.JinjaTypeError;
    if (repl == .string) {
        const empty_spans = try a.alloc(engine.Span, regex.groups + 1);
        @memset(empty_spans, .{});
        _ = try replacement(a, repl.string, .{ .pattern = actual, .string = subject, .spans = empty_spans, .names = regex.names, .lastindex = null, .pos = 0, .endpos = length });
    }
    for (matches) |capture| {
        if (limit < 0 or (limit > 0 and count >= limit)) break;
        const span = capture.spans[0];
        const left: usize = @intCast(span.start);
        const right: usize = @intCast(span.end);
        if (substitution) {
            try output.appendSlice(a, subject[cursor..left]);
            const text = if (repl == .string) try replacement(a, repl.string, capture) else blk: {
                const current = host orelse return error.UnsupportedRegularExpressionCallable;
                const result = try current.call(current.context, repl.callable, &.{.{ .value = try matchValue(a, capture) }}, a);
                break :blk if (result == .none) "" else try string(result);
            };
            try output.appendSlice(a, text);
        } else {
            try fields.append(a, .{ .string = subject[cursor..left] });
            for (1..capture.spans.len) |index| try fields.append(a, group(capture, index, .none));
        }
        cursor = right;
        count += 1;
    }
    if (!substitution) {
        try fields.append(a, .{ .string = subject[cursor..] });
        return .{ .list = try fields.toOwnedSlice(a) };
    }
    try output.appendSlice(a, subject[cursor..]);
    const rendered = Value{ .string = try output.toOwnedSlice(a) };
    if (std.mem.eql(u8, method, "sub")) return rendered;
    const pair = try expr.allocateValues(a, 2);
    pair[0] = rendered;
    pair[1] = try expr.integerValue(a, count);
    return .{ .tuple = pair };
}

pub fn call(a: Allocator, name: []const u8, args: []const Argument, host: ?expr.Host) !?Value {
    const pattern_prefix = "__dxt_regex_pattern:";
    const match_prefix = "__dxt_regex_match:";
    if (std.mem.startsWith(u8, name, pattern_prefix) or std.mem.startsWith(u8, name, match_prefix)) {
        const is_pattern = std.mem.startsWith(u8, name, pattern_prefix);
        const prefix = if (is_pattern) pattern_prefix else match_prefix;
        const boundary = std.mem.indexOfScalarPos(u8, name, prefix.len, ':') orelse return error.InvalidRegularExpression;
        const method = name[prefix.len..boundary];
        if (is_pattern) return try execute(a, method, (try std.json.parseFromSlice(Pattern, a, name[boundary + 1 ..], .{})).value, args, host);
        return try callMatch(a, method, (try std.json.parseFromSlice(Capture, a, name[boundary + 1 ..], .{})).value, args);
    }
    if (!std.mem.startsWith(u8, name, "modules.re.")) return null;
    const method = name[11..];
    if (std.mem.eql(u8, method, "purge")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        return .none;
    }
    if (std.mem.eql(u8, method, "escape")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
        var text: std.ArrayList(u8) = .empty;
        for (try string(args[0].value)) |byte| {
            if (std.mem.indexOfScalar(u8, "()[]{}?*+-|^$\\.&~# \t\n\r\x0b\x0c", byte) != null) try text.append(a, '\\');
            try text.append(a, byte);
        }
        return .{ .string = try text.toOwnedSlice(a) };
    }
    const authored = argument(args, "pattern", 0);
    const substitution = std.mem.eql(u8, method, "sub") or std.mem.eql(u8, method, "subn");
    const flag_value = try integerArg(args, "flags", if (std.mem.eql(u8, method, "compile")) 1 else if (substitution) 4 else if (std.mem.eql(u8, method, "split")) 3 else 2, 0);
    if (flag_value < 0 or flag_value > std.math.maxInt(u32)) return error.InvalidRegularExpressionFlags;
    var definition: Pattern = undefined;
    if (authored == .object and authored.attribute("__dxt_regex_pattern") == .string) {
        if (flag_value != 0) return error.InvalidRegularExpressionFlags;
        definition = (try std.json.parseFromSlice(Pattern, a, authored.attribute("__dxt_regex_pattern").string, .{})).value;
        if (std.mem.eql(u8, method, "compile")) return authored;
    } else definition = .{ .pattern = try string(authored), .flags = @intCast(flag_value) };
    if (std.mem.eql(u8, method, "compile")) return try patternValue(a, definition);
    var forwarded: std.ArrayList(Argument) = .empty;
    var position: usize = 0;
    for (args) |arg| {
        if (arg.name) |key| {
            if (std.mem.eql(u8, key, "pattern") or std.mem.eql(u8, key, "flags")) continue;
        } else {
            defer position += 1;
            if (position == 0 or position == (if (substitution) @as(usize, 4) else if (std.mem.eql(u8, method, "split")) @as(usize, 3) else 2)) continue;
        }
        try forwarded.append(a, arg);
    }
    return try execute(a, method, definition, forwarded.items, host);
}

test "native regular expressions expose capture tuples and substitution backreferences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const found = (try call(a, "modules.re.findall", &.{ .{ .value = .{ .string = "(a)(b)?" } }, .{ .value = .{ .string = "a ab" } } }, null)).?;
    try std.testing.expectEqualStrings("[('a', ''), ('a', 'b')]", try found.text(a));
    const replaced = (try call(a, "modules.re.sub", &.{ .{ .value = .{ .string = "(?P<word>\\w+)" } }, .{ .value = .{ .string = "<\\g<word>>" } }, .{ .value = .{ .string = "é 好" } } }, null)).?;
    try std.testing.expectEqualStrings("<é> <好>", replaced.string);
}
