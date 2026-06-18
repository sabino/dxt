const std = @import("std");
const fs = @import("fs.zig");
const jinja = @import("jinja.zig");
const resolve = @import("resolve.zig");
const types = @import("types.zig");
const util = @import("util.zig");

const JsonScalar = types.JsonScalar;
const ExposureDef = types.ExposureDef;
const GenericTestDef = types.GenericTestDef;
const Graph = types.Graph;
const MacroDef = types.MacroDef;
const MacroArgument = types.MacroArgument;
const MacroProperty = types.MacroProperty;
const MetaEntry = types.MetaEntry;
const RefDep = types.RefDep;
const UnitTestFixture = types.UnitTestFixture;
const UnitTestRow = types.UnitTestRow;
const KeyValue = util.KeyValue;
const dupTrimmedScalar = util.dupTrimmedScalar;
const isIdentChar = jinja.isIdentChar;
const isIdentStart = jinja.isIdentStart;
const leadingSpaces = util.leadingSpaces;
const parseInlineStringList = util.parseInlineStringList;
const pathJoin = fs.pathJoin;
const relativeUnderResourcePath = fs.relativeUnderResourcePath;
const sortStrings = util.sortStrings;
const splitKeyValue = util.splitKeyValue;
const stripYamlComment = util.stripYamlComment;
const findMatchingParen = jinja.findMatchingParen;
const parseLiteralArgs = jinja.parseLiteralArgs;
const skipQuotedSpan = jinja.skipQuotedSpan;
const skipWs = jinja.skipWs;
const findMacroIndexByPackageAndName = resolve.findMacroIndexByPackageAndName;

const FreshnessTimeKey = enum { warn_after, error_after };
const SourceConfigScope = enum { none, source, table };
const FreshnessScope = enum { none, source, table };
const SourceTestTarget = enum { none, table, column };
const UnitTestSection = enum { none, given, expect, config };
const UnitTestRowsTarget = enum { none, given, expect };

const SourceDefaults = struct {
    schema_name: ?[]const u8 = null,
    loaded_at_field: ?[]const u8 = null,
    loaded_at_query: ?[]const u8 = null,
    freshness: ?types.FreshnessThreshold = null,
};

pub fn parseBool(value: []const u8) !bool {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (std.ascii.eqlIgnoreCase(trimmed, "true")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "false")) return false;
    return error.UnsupportedYaml;
}

pub fn parseJsonScalar(allocator: std.mem.Allocator, value: []const u8) !JsonScalar {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    const unquoted = try dupTrimmedScalar(allocator, trimmed);
    if (std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "false")) return .{ .text = unquoted, .kind = .bool };
    if (std.mem.eql(u8, trimmed, "null")) return .{ .text = unquoted, .kind = .null };
    if (isJsonNumber(trimmed)) return .{ .text = unquoted, .kind = .number };
    return .{ .text = unquoted, .kind = .string };
}

fn isJsonNumber(value: []const u8) bool {
    if (value.len == 0) return false;
    var i: usize = 0;
    if (value[i] == '-') {
        i += 1;
        if (i == value.len) return false;
    }
    if (value[i] == '0') {
        i += 1;
        if (i < value.len and std.ascii.isDigit(value[i])) return false;
    } else if (value[i] >= '1' and value[i] <= '9') {
        i += 1;
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {}
    } else {
        return false;
    }
    if (i < value.len and value[i] == '.') {
        i += 1;
        var frac_digits: usize = 0;
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {
            frac_digits += 1;
        }
        if (frac_digits == 0) return false;
    }
    if (i < value.len and (value[i] == 'e' or value[i] == 'E')) {
        i += 1;
        if (i < value.len and (value[i] == '+' or value[i] == '-')) i += 1;
        var exp_digits: usize = 0;
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {
            exp_digits += 1;
        }
        if (exp_digits == 0) return false;
    }
    return i == value.len;
}

pub fn testNameFromYamlItem(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (trimmed.len == 0) return error.UnsupportedYaml;
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse trimmed.len;
    return try dupTrimmedScalar(allocator, trimmed[0..colon]);
}

pub fn parseInlineGenericTestList(allocator: std.mem.Allocator, value: []const u8, out: *std.ArrayList(GenericTestDef)) !void {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
        _ = try appendGenericTestDef(allocator, out, try dupTrimmedScalar(allocator, trimmed));
        return;
    }
    var pieces = std.mem.splitScalar(u8, trimmed[1 .. trimmed.len - 1], ',');
    while (pieces.next()) |piece| {
        const item = std.mem.trim(u8, piece, " \t");
        if (item.len != 0) _ = try appendGenericTestDef(allocator, out, try dupTrimmedScalar(allocator, item));
    }
}

pub fn appendGenericTestDef(allocator: std.mem.Allocator, tests: *std.ArrayList(GenericTestDef), test_name: []const u8) !usize {
    try tests.append(allocator, .{ .name = test_name });
    return tests.items.len - 1;
}

pub fn appendGenericTestDefClone(graph: *Graph, tests: *std.ArrayList(GenericTestDef), source: GenericTestDef) !void {
    var cloned = GenericTestDef{
        .name = source.name,
        .column_name = source.column_name,
        .accepted_values_quote = source.accepted_values_quote,
        .relationship_to = source.relationship_to,
        .relationship_field = source.relationship_field,
    };
    errdefer cloned.accepted_values.deinit(graph.allocator);
    for (source.accepted_values.items) |value| {
        try cloned.accepted_values.append(graph.allocator, value);
    }
    try tests.append(graph.allocator, cloned);
}

pub fn parseMacros(runtime: types.Runtime, project_dir: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    const path = try pathJoin(runtime.allocator, &.{ project_dir, relative_path });
    const text = try std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(4 * 1024 * 1024));
    try parseMacrosFromText(runtime.allocator, text, relative_path, package_name, graph);
}

pub fn parseMacrosFromText(allocator: std.mem.Allocator, text: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    var index: usize = 0;
    var control_depth: usize = 0;
    while (try nextJinjaBlockOutsideIgnoredSpans(text, &index)) |open| {
        const close = findJinjaBlockClose(text, open) orelse return error.MalformedMacroBlock;
        const tag = std.mem.trim(u8, text[open + 2 .. close], " \t\r\n-");
        if (std.mem.eql(u8, tag, "raw")) {
            const end = try findRawEndTag(text, close + 2);
            index = end.close + 2;
            continue;
        }
        if (isControlFlowStartTag(tag)) {
            control_depth += 1;
            index = close + 2;
            continue;
        }
        if (isControlFlowEndTag(tag)) {
            if (control_depth == 0) return error.MalformedMacroBlock;
            control_depth -= 1;
            index = close + 2;
            continue;
        }
        var macro_tag = parseMacroOpenTag(allocator, tag, graph.validate_macro_args) catch |err| switch (err) {
            error.NotMacroBlock => {
                index = close + 2;
                continue;
            },
            else => return err,
        };
        if (control_depth != 0) return error.MalformedMacroBlock;

        const end = try findEndMacroTag(text, close + 2, macro_tag.end_tag);

        const macro_sql = std.mem.trim(u8, text[open .. end.close + 2], " \t\r\n");
        var macro = try macroDefFromParts(allocator, package_name, macro_tag.name, relative_path, macro_sql);
        macro.signature_arguments = macro_tag.arguments;
        macro_tag.arguments = .empty;
        if (graph.validate_macro_args) {
            try appendMacroArgumentClones(graph, &macro.arguments, macro.signature_arguments.items);
        }
        macro.supported_languages = macro_tag.supported_languages;
        macro_tag.supported_languages = .empty;
        macro.has_supported_languages = macro_tag.has_supported_languages;
        try graph.macros.append(allocator, macro);
        index = end.close + 2;
    }
    if (control_depth != 0) return error.MalformedMacroBlock;
}

fn nextJinjaBlockOutsideIgnoredSpans(text: []const u8, index: *usize) !?usize {
    while (true) {
        const block_open = std.mem.indexOfPos(u8, text, index.*, "{%");
        const comment_open = std.mem.indexOfPos(u8, text, index.*, "{#");
        const expr_open = std.mem.indexOfPos(u8, text, index.*, "{{");
        if (comment_open) |comment| {
            if (isBeforeOptional(comment, block_open) and isBeforeOptional(comment, expr_open)) {
                const comment_close = std.mem.indexOfPos(u8, text, comment + 2, "#}") orelse return error.MalformedMacroBlock;
                index.* = comment_close + 2;
                continue;
            }
        }
        if (expr_open) |expr| {
            if (isBeforeOptional(expr, block_open)) {
                const expr_close = findJinjaExprClose(text, expr) orelse return error.MalformedMacroBlock;
                index.* = expr_close + 2;
                continue;
            }
        }
        return block_open;
    }
}

fn isBeforeOptional(value: usize, maybe_other: ?usize) bool {
    return maybe_other == null or value < maybe_other.?;
}

fn findJinjaBlockClose(text: []const u8, open: usize) ?usize {
    var index = open + 2;
    while (index + 1 < text.len) : (index += 1) {
        if (text[index] == '"' or text[index] == '\'') {
            index = (skipQuotedSpan(text, index) orelse return null) - 1;
            continue;
        }
        if (text[index] == '%' and text[index + 1] == '}') return index;
    }
    return null;
}

fn findJinjaExprClose(text: []const u8, open: usize) ?usize {
    var index = open + 2;
    while (index + 1 < text.len) : (index += 1) {
        if (text[index] == '"' or text[index] == '\'') {
            index = (skipQuotedSpan(text, index) orelse return null) - 1;
            continue;
        }
        if (text[index] == '}' and text[index + 1] == '}') return index;
    }
    return null;
}

const MacroOpenTag = struct {
    name: []const u8,
    end_tag: []const u8,
    arguments: std.ArrayList(MacroArgument) = .empty,
    supported_languages: std.ArrayList([]const u8) = .empty,
    has_supported_languages: bool = false,
};

const CallableBlock = struct {
    name: []const u8,
    arguments: std.ArrayList(MacroArgument) = .empty,
};

fn parseMacroOpenTag(allocator: std.mem.Allocator, tag: []const u8, extract_arguments: bool) !MacroOpenTag {
    if (std.mem.startsWith(u8, tag, "macro") and tag.len > "macro".len and std.ascii.isWhitespace(tag["macro".len])) {
        const block = try parseCallableBlock(allocator, tag, "macro", extract_arguments);
        return .{ .name = block.name, .end_tag = "endmacro", .arguments = block.arguments };
    }
    if (std.mem.startsWith(u8, tag, "test") and tag.len > "test".len and std.ascii.isWhitespace(tag["test".len])) {
        const block = try parseCallableBlock(allocator, tag, "test", extract_arguments);
        return .{ .name = try std.fmt.allocPrint(allocator, "test_{s}", .{block.name}), .end_tag = "endtest", .arguments = block.arguments };
    }
    if (std.mem.startsWith(u8, tag, "data_test") and tag.len > "data_test".len and std.ascii.isWhitespace(tag["data_test".len])) {
        const block = try parseCallableBlock(allocator, tag, "data_test", extract_arguments);
        return .{ .name = try std.fmt.allocPrint(allocator, "test_{s}", .{block.name}), .end_tag = "enddata_test", .arguments = block.arguments };
    }
    if (std.mem.startsWith(u8, tag, "materialization") and tag.len > "materialization".len and std.ascii.isWhitespace(tag["materialization".len])) {
        return try parseMaterializationOpenTag(allocator, tag);
    }
    return error.NotMacroBlock;
}

fn parseCallableBlock(allocator: std.mem.Allocator, tag: []const u8, keyword: []const u8, extract_arguments: bool) !CallableBlock {
    const name_start = skipWs(tag, keyword.len);
    if (name_start >= tag.len or !isIdentStart(tag[name_start])) return error.MalformedMacroBlock;
    var name_end = name_start + 1;
    while (name_end < tag.len and isIdentChar(tag[name_end])) name_end += 1;
    const call_pos = skipWs(tag, name_end);
    if (call_pos >= tag.len or tag[call_pos] != '(') return error.MalformedMacroBlock;
    const close = findMatchingParen(tag, call_pos) orelse return error.MalformedMacroBlock;
    var arguments: std.ArrayList(MacroArgument) = .empty;
    errdefer arguments.deinit(allocator);
    if (extract_arguments) {
        parseSignatureArguments(allocator, tag[call_pos + 1 .. close], &arguments) catch {
            arguments.clearRetainingCapacity();
        };
    }
    return .{ .name = tag[name_start..name_end], .arguments = arguments };
}

fn parseSignatureArguments(allocator: std.mem.Allocator, text: []const u8, out: *std.ArrayList(MacroArgument)) !void {
    var start: usize = 0;
    var pos: usize = 0;
    var depth: usize = 0;
    while (pos < text.len) : (pos += 1) {
        const ch = text[pos];
        if (ch == '"' or ch == '\'') {
            pos = (skipQuotedSpan(text, pos) orelse return error.MalformedMacroBlock) - 1;
            continue;
        }
        if (ch == '(' or ch == '[' or ch == '{') {
            depth += 1;
            continue;
        }
        if (ch == ')' or ch == ']' or ch == '}') {
            if (depth == 0) return error.MalformedMacroBlock;
            depth -= 1;
            continue;
        }
        if (ch == ',' and depth == 0) {
            try appendSignatureArgument(allocator, text[start..pos], out);
            start = pos + 1;
        }
    }
    if (depth != 0) return error.MalformedMacroBlock;
    try appendSignatureArgument(allocator, text[start..], out);
}

fn appendSignatureArgument(allocator: std.mem.Allocator, segment: []const u8, out: *std.ArrayList(MacroArgument)) !void {
    const trimmed = std.mem.trim(u8, segment, " \t\r\n");
    if (trimmed.len == 0) return;
    if (!isIdentStart(trimmed[0])) return error.MalformedMacroBlock;
    var name_end: usize = 1;
    while (name_end < trimmed.len and isIdentChar(trimmed[name_end])) name_end += 1;
    const rest = skipWs(trimmed, name_end);
    if (rest < trimmed.len and trimmed[rest] != '=' and trimmed[rest] != ':') return error.MalformedMacroBlock;
    const name = try allocator.dupe(u8, trimmed[0..name_end]);
    try out.append(allocator, .{ .name = name });
}

fn parseMaterializationOpenTag(allocator: std.mem.Allocator, tag: []const u8) !MacroOpenTag {
    const name_start = skipWs(tag, "materialization".len);
    if (name_start >= tag.len or !isIdentStart(tag[name_start])) return error.MalformedMacroBlock;
    var name_end = name_start + 1;
    while (name_end < tag.len and isIdentChar(tag[name_end])) name_end += 1;

    var rest_start = skipWs(tag, name_end);
    var adapter_part: []const u8 = "default";
    var languages: std.ArrayList([]const u8) = .empty;
    errdefer languages.deinit(allocator);
    var has_languages = false;

    while (rest_start < tag.len) {
        if (tag[rest_start] != ',') return error.MalformedMacroBlock;
        rest_start += 1;
        rest_start = skipWs(tag, rest_start);

        const option = try parseIdentifier(tag, &rest_start);
        if (std.mem.eql(u8, option, "default")) {
            rest_start = skipWs(tag, rest_start);
            continue;
        }
        if (std.mem.eql(u8, option, "adapter")) {
            rest_start = skipWs(tag, rest_start);
            if (rest_start >= tag.len or tag[rest_start] != '=') return error.MalformedMacroBlock;
            rest_start = skipWs(tag, rest_start + 1);
            adapter_part = try parseQuotedString(tag, &rest_start);
            rest_start = skipWs(tag, rest_start);
            continue;
        }
        if (std.mem.eql(u8, option, "supported_languages")) {
            try parseSupportedLanguagesValue(allocator, tag, &rest_start, &languages);
            has_languages = true;
            rest_start = skipWs(tag, rest_start);
            continue;
        }
        return error.MalformedMacroBlock;
    }

    if (!has_languages) {
        try languages.append(allocator, "sql");
    }

    return .{
        .name = try std.fmt.allocPrint(allocator, "materialization_{s}_{s}", .{ tag[name_start..name_end], adapter_part }),
        .end_tag = "endmaterialization",
        .supported_languages = languages,
        .has_supported_languages = true,
    };
}

fn parseSupportedLanguagesValue(allocator: std.mem.Allocator, tag: []const u8, index: *usize, out: *std.ArrayList([]const u8)) !void {
    var pos = index.*;
    pos = skipWs(tag, pos);
    if (pos >= tag.len or tag[pos] != '=') return error.MalformedMacroBlock;
    pos = skipWs(tag, pos + 1);
    if (pos >= tag.len or (tag[pos] != '[' and tag[pos] != '(')) return error.MalformedMacroBlock;
    const open = tag[pos];
    const close: u8 = if (open == '[') ']' else ')';
    pos += 1;
    var item_count: usize = 0;
    var trailing_comma = false;
    while (true) {
        pos = skipWs(tag, pos);
        if (pos >= tag.len) return error.MalformedMacroBlock;
        if (tag[pos] == close) {
            if (open == '(' and item_count == 1 and !trailing_comma) return error.MalformedMacroBlock;
            pos += 1;
            break;
        }
        const language = try parseQuotedString(tag, &pos);
        if (!isSupportedMaterializationLanguage(language)) return error.MalformedMacroBlock;
        try out.append(allocator, language);
        item_count += 1;
        trailing_comma = false;
        pos = skipWs(tag, pos);
        if (pos >= tag.len) return error.MalformedMacroBlock;
        if (tag[pos] == ',') {
            pos += 1;
            trailing_comma = true;
            continue;
        }
        if (tag[pos] == close) {
            if (open == '(' and item_count == 1) return error.MalformedMacroBlock;
            pos += 1;
            break;
        }
        return error.MalformedMacroBlock;
    }
    index.* = pos;
}

fn isSupportedMaterializationLanguage(language: []const u8) bool {
    if (std.mem.eql(u8, language, "sql")) return true;
    return language.len == 6 and
        language[0] == 'p' and
        language[1] == 'y' and
        language[2] == 't' and
        language[3] == 'h' and
        language[4] == 'o' and
        language[5] == 'n';
}

fn parseIdentifier(tag: []const u8, index: *usize) ![]const u8 {
    if (index.* >= tag.len or !isIdentStart(tag[index.*])) return error.MalformedMacroBlock;
    const start = index.*;
    index.* += 1;
    while (index.* < tag.len and isIdentChar(tag[index.*])) index.* += 1;
    return tag[start..index.*];
}

fn isControlFlowStartTag(tag: []const u8) bool {
    return startsWithKeyword(tag, "if") or startsWithKeyword(tag, "for");
}

fn isControlFlowEndTag(tag: []const u8) bool {
    return std.mem.eql(u8, tag, "endif") or std.mem.eql(u8, tag, "endfor");
}

fn startsWithKeyword(tag: []const u8, keyword: []const u8) bool {
    return std.mem.startsWith(u8, tag, keyword) and
        (tag.len == keyword.len or std.ascii.isWhitespace(tag[keyword.len]));
}

fn parseQuotedString(tag: []const u8, index: *usize) ![]const u8 {
    if (index.* >= tag.len or (tag[index.*] != '\'' and tag[index.*] != '"')) return error.MalformedMacroBlock;
    const quote = tag[index.*];
    const start = index.* + 1;
    var pos = start;
    while (pos < tag.len) : (pos += 1) {
        if (tag[pos] == '\\') {
            pos += 1;
            continue;
        }
        if (tag[pos] == quote) {
            index.* = pos + 1;
            return tag[start..pos];
        }
    }
    return error.MalformedMacroBlock;
}

const MacroEndTag = struct {
    close: usize,
};

fn findEndMacroTag(text: []const u8, start: usize, expected_tag: []const u8) !MacroEndTag {
    var index = start;
    while (try nextJinjaBlockOutsideIgnoredSpans(text, &index)) |open| {
        const close = findJinjaBlockClose(text, open) orelse return error.MalformedMacroBlock;
        const tag = std.mem.trim(u8, text[open + 2 .. close], " \t\r\n-");
        if (std.mem.eql(u8, tag, expected_tag)) return .{ .close = close };
        if (std.mem.eql(u8, tag, "raw")) {
            const end = try findRawEndTag(text, close + 2);
            index = end.close + 2;
            continue;
        }
        index = close + 2;
    }
    return error.MalformedMacroBlock;
}

fn findRawEndTag(text: []const u8, start: usize) !MacroEndTag {
    var index = start;
    while (std.mem.indexOfPos(u8, text, index, "{%")) |open| {
        var tag_start = skipWs(text, open + 2);
        if (tag_start < text.len and text[tag_start] == '-') tag_start = skipWs(text, tag_start + 1);
        if (!std.mem.startsWith(u8, text[tag_start..], "endraw")) {
            index = open + 2;
            continue;
        }
        const close = findJinjaBlockClose(text, open) orelse return error.MalformedMacroBlock;
        const tag = std.mem.trim(u8, text[open + 2 .. close], " \t\r\n-");
        if (std.mem.eql(u8, tag, "endraw")) return .{ .close = close };
        index = close + 2;
    }
    return error.MalformedMacroBlock;
}

fn macroDefFromParts(allocator: std.mem.Allocator, package_name: []const u8, macro_name: []const u8, relative_path: []const u8, macro_sql: []const u8) !MacroDef {
    return .{
        .unique_id = try std.fmt.allocPrint(allocator, "macro.{s}.{s}", .{ package_name, macro_name }),
        .package_name = package_name,
        .name = try allocator.dupe(u8, macro_name),
        .path = relative_path,
        .original_file_path = relative_path,
        .macro_sql = try allocator.dupe(u8, macro_sql),
    };
}

pub fn parseMacroPropertiesFromText(allocator: std.mem.Allocator, text: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    var in_macros = false;
    var in_arguments = false;
    var in_docs = false;
    var in_meta = false;
    var macros_indent: usize = 0;
    var macro_item_indent: ?usize = null;
    var arguments_indent: usize = 0;
    var argument_item_indent: ?usize = null;
    var docs_indent: usize = 0;
    var meta_indent: usize = 0;
    var current_macro: ?usize = null;
    var current_argument: ?usize = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);

        if (std.mem.eql(u8, trimmed, "macros:")) {
            in_macros = true;
            in_arguments = false;
            in_docs = false;
            in_meta = false;
            macros_indent = indent;
            macro_item_indent = null;
            argument_item_indent = null;
            current_macro = null;
            current_argument = null;
            continue;
        }
        if (!in_macros) continue;
        if (indent <= macros_indent and !std.mem.eql(u8, trimmed, "macros:")) break;

        if (in_arguments and indent <= arguments_indent and !std.mem.eql(u8, trimmed, "arguments:")) {
            in_arguments = false;
            argument_item_indent = null;
            current_argument = null;
        }
        if (in_docs and indent <= docs_indent) in_docs = false;
        if (in_meta and indent <= meta_indent) in_meta = false;

        if (std.mem.startsWith(u8, trimmed, "- name:")) {
            const name = try dupTrimmedScalar(allocator, trimmed["- name:".len..]);
            if (in_arguments and current_macro != null and indent > (macro_item_indent orelse 0)) {
                const macro_index = current_macro.?;
                try graph.macro_properties.items[macro_index].arguments.append(allocator, .{ .name = name });
                current_argument = graph.macro_properties.items[macro_index].arguments.items.len - 1;
                argument_item_indent = indent;
            } else {
                try graph.macro_properties.append(allocator, .{ .package_name = package_name, .name = name, .patch_path = relative_path });
                current_macro = graph.macro_properties.items.len - 1;
                macro_item_indent = indent;
                in_arguments = false;
                in_docs = false;
                in_meta = false;
                argument_item_indent = null;
                current_argument = null;
            }
            continue;
        }

        const macro_index = current_macro orelse continue;
        if (in_docs and indent > docs_indent) {
            const kv = splitKeyValue(trimmed) orelse return error.UnsupportedYaml;
            try applyMacroDocsConfigKeyValue(allocator, &graph.macro_properties.items[macro_index].docs, kv);
            continue;
        }
        if (in_meta and indent > meta_indent) {
            const kv = splitKeyValue(trimmed) orelse return error.UnsupportedYaml;
            if (std.mem.trim(u8, kv.value, " \t").len == 0) return error.UnsupportedYaml;
            try appendMetaEntry(allocator, &graph.macro_properties.items[macro_index].meta, kv.key, try parseJsonScalar(allocator, kv.value));
            continue;
        }
        if (splitKeyValue(trimmed)) |kv| {
            if (in_arguments and current_argument != null and indent > (argument_item_indent orelse 0)) {
                var argument = &graph.macro_properties.items[macro_index].arguments.items[current_argument.?];
                if (std.mem.eql(u8, kv.key, "type")) {
                    argument.type = try dupTrimmedScalar(allocator, kv.value);
                } else if (std.mem.eql(u8, kv.key, "description")) {
                    argument.description = try dupTrimmedScalar(allocator, kv.value);
                } else {
                    return error.UnsupportedYaml;
                }
                continue;
            }

            if (std.mem.eql(u8, kv.key, "description")) {
                graph.macro_properties.items[macro_index].description = try dupTrimmedScalar(allocator, kv.value);
            } else if (std.mem.eql(u8, kv.key, "arguments")) {
                if (std.mem.trim(u8, kv.value, " \t").len != 0) return error.UnsupportedYaml;
                in_arguments = true;
                in_docs = false;
                in_meta = false;
                arguments_indent = indent;
                argument_item_indent = null;
                current_argument = null;
            } else if (std.mem.eql(u8, kv.key, "docs")) {
                if (std.mem.trim(u8, kv.value, " \t").len != 0) return error.UnsupportedYaml;
                in_arguments = false;
                in_docs = true;
                in_meta = false;
                docs_indent = indent;
                graph.macro_properties.items[macro_index].docs.configured = true;
            } else if (std.mem.eql(u8, kv.key, "meta")) {
                if (std.mem.trim(u8, kv.value, " \t").len != 0) return error.UnsupportedYaml;
                in_arguments = false;
                in_docs = false;
                in_meta = true;
                meta_indent = indent;
            }
        }
    }
}

fn applyMacroDocsConfigKeyValue(allocator: std.mem.Allocator, docs: *types.DocsConfig, kv: util.KeyValue) !void {
    if (std.mem.eql(u8, kv.key, "show")) {
        docs.configured = true;
        docs.show = try parseBool(kv.value);
    } else if (std.mem.eql(u8, kv.key, "node_color")) {
        docs.configured = true;
        docs.node_color = try parseDocsNodeColor(allocator, kv.value);
    } else {
        return error.UnsupportedYaml;
    }
}

fn parseDocsNodeColor(allocator: std.mem.Allocator, value: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (std.mem.eql(u8, trimmed, "null") or std.mem.eql(u8, trimmed, "~")) return null;
    return try dupTrimmedScalar(allocator, value);
}

pub fn applyMacroProperties(graph: *Graph) !void {
    for (graph.macro_properties.items) |property| {
        const macro_index = findMacroIndexByPackageAndName(graph, property.package_name, property.name) orelse {
            try graph.unmatched_macro_properties.append(graph.allocator, .{ .name = property.name, .patch_path = property.patch_path });
            continue;
        };
        var macro = &graph.macros.items[macro_index];
        macro.patch_path = property.patch_path;
        if (property.description.len != 0) macro.description = property.description;
        if (property.docs.configured) macro.docs = property.docs;
        for (property.meta.items) |entry| {
            try appendMetaEntry(graph.allocator, &macro.meta, entry.key, entry.value);
        }
        if (graph.validate_macro_args) {
            try validateMacroPatchArguments(graph, macro, property);
            if (property.arguments.items.len != 0) {
                macro.arguments.clearRetainingCapacity();
                try appendMacroArgumentClones(graph, &macro.arguments, property.arguments.items);
            }
        } else {
            macro.arguments.clearRetainingCapacity();
            try appendMacroArgumentClones(graph, &macro.arguments, property.arguments.items);
        }
    }
}

fn validateMacroPatchArguments(graph: *Graph, macro: *const MacroDef, property: MacroProperty) !void {
    if (property.arguments.items.len == 0) return;
    const signature_arguments = macro.signature_arguments.items;
    const count = @min(signature_arguments.len, property.arguments.items.len);
    for (property.arguments.items[0..count], signature_arguments[0..count]) |patch_arg, macro_arg| {
        if (!std.mem.eql(u8, patch_arg.name, macro_arg.name)) {
            try appendMacroArgumentWarning(
                graph,
                "Argument {s} in yaml for macro {s} does not match the jinja definition.",
                .{ patch_arg.name, macro.name },
            );
        }
    }
    if (property.arguments.items.len != signature_arguments.len) {
        try appendMacroArgumentWarning(
            graph,
            "The number of arguments in the yaml for macro {s} does not match the jinja definition.",
            .{macro.name},
        );
    }
    for (property.arguments.items) |patch_arg| {
        if (patch_arg.type.len != 0 and !isValidMacroArgumentType(patch_arg.type)) {
            try appendMacroArgumentWarning(
                graph,
                "Argument {s} in the yaml for macro {s} has an invalid type.",
                .{ patch_arg.name, macro.name },
            );
        }
    }
}

fn appendMacroArgumentWarning(graph: *Graph, comptime fmt: []const u8, args: anytype) !void {
    try graph.macro_argument_warnings.append(graph.allocator, try std.fmt.allocPrint(graph.allocator, fmt, args));
}

fn appendMacroArgumentClones(graph: *Graph, arguments: *std.ArrayList(MacroArgument), source: []const MacroArgument) !void {
    for (source) |argument| {
        try arguments.append(graph.allocator, .{
            .name = argument.name,
            .type = argument.type,
            .description = argument.description,
        });
    }
}

pub fn isValidMacroArgumentType(value: []const u8) bool {
    var parser = MacroArgumentTypeParser{ .text = value };
    return parser.parseType() and parser.finished();
}

const MacroArgumentTypeParser = struct {
    text: []const u8,
    index: usize = 0,

    fn parseType(self: *MacroArgumentTypeParser) bool {
        self.skipIgnored();
        const start = self.index;
        while (self.index < self.text.len and self.text[self.index] >= 'a' and self.text[self.index] <= 'z') {
            self.index += 1;
        }
        if (start == self.index) return false;
        const name = self.text[start..self.index];
        const arg_count = macroArgumentTypeParamCount(name) orelse return false;
        if (arg_count == 0) return true;
        self.skipIgnored();
        if (self.index >= self.text.len or self.text[self.index] != '[') return false;
        self.index += 1;
        var arg_index: usize = 0;
        while (arg_index < arg_count) : (arg_index += 1) {
            if (!self.parseType()) return false;
            self.skipIgnored();
            if (arg_index + 1 < arg_count) {
                if (self.index >= self.text.len or self.text[self.index] != ',') return false;
                self.index += 1;
            }
        }
        self.skipIgnored();
        if (self.index >= self.text.len or self.text[self.index] != ']') return false;
        self.index += 1;
        return true;
    }

    fn finished(self: *MacroArgumentTypeParser) bool {
        self.skipIgnored();
        return self.index == self.text.len;
    }

    fn skipIgnored(self: *MacroArgumentTypeParser) void {
        while (self.index < self.text.len and (self.text[self.index] == ' ' or self.text[self.index] == '\t')) {
            self.index += 1;
        }
    }
};

fn macroArgumentTypeParamCount(name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "str")) return 0;
    if (std.mem.eql(u8, name, "string")) return 0;
    if (std.mem.eql(u8, name, "bool")) return 0;
    if (std.mem.eql(u8, name, "int")) return 0;
    if (std.mem.eql(u8, name, "integer")) return 0;
    if (std.mem.eql(u8, name, "float")) return 0;
    if (std.mem.eql(u8, name, "any")) return 0;
    if (std.mem.eql(u8, name, "list")) return 1;
    if (std.mem.eql(u8, name, "dict")) return 2;
    if (std.mem.eql(u8, name, "optional")) return 1;
    if (std.mem.eql(u8, name, "relation")) return 0;
    if (std.mem.eql(u8, name, "column")) return 0;
    return null;
}

pub fn refDepFromValue(allocator: std.mem.Allocator, value: []const u8) !RefDep {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (std.mem.startsWith(u8, trimmed, "ref(")) {
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return error.UnsupportedRef;
        const close = findMatchingParen(trimmed, open) orelse return error.UnsupportedRef;
        const args = std.mem.trim(u8, trimmed[open + 1 .. close], " \t\r");
        var strings = try parseLiteralArgs(allocator, args, error.UnsupportedRef);
        defer strings.deinit(allocator);
        if (!(strings.items.len == 1 or strings.items.len == 2)) return error.UnsupportedRef;
        return .{
            .package = if (strings.items.len == 2) strings.items[0] else null,
            .name = if (strings.items.len == 2) strings.items[1] else strings.items[0],
        };
    }
    return .{ .package = null, .name = try dupTrimmedScalar(allocator, trimmed) };
}

pub fn parseExposureDependency(allocator: std.mem.Allocator, raw_value: []const u8, exposure: *ExposureDef) !void {
    const value = std.mem.trim(u8, raw_value, " \t\r");
    if (std.mem.startsWith(u8, value, "ref(")) {
        const args_start = std.mem.indexOfScalar(u8, value, '(') orelse return error.UnsupportedDynamicRef;
        const args_end = findMatchingParen(value, args_start) orelse return error.UnsupportedDynamicRef;
        var strings = try parseLiteralArgs(allocator, value[args_start + 1 .. args_end], error.UnsupportedDynamicRef);
        defer strings.deinit(allocator);
        if (strings.items.len == 1) {
            try exposure.refs.append(allocator, .{ .package = null, .name = strings.items[0] });
        } else if (strings.items.len == 2) {
            try exposure.refs.append(allocator, .{ .package = strings.items[0], .name = strings.items[1] });
        } else {
            return error.UnsupportedDynamicRef;
        }
        return;
    }
    if (std.mem.startsWith(u8, value, "source(")) {
        const args_start = std.mem.indexOfScalar(u8, value, '(') orelse return error.UnsupportedDynamicSource;
        const args_end = findMatchingParen(value, args_start) orelse return error.UnsupportedDynamicSource;
        var strings = try parseLiteralArgs(allocator, value[args_start + 1 .. args_end], error.UnsupportedDynamicSource);
        defer strings.deinit(allocator);
        if (strings.items.len != 2) return error.UnsupportedDynamicSource;
        try exposure.source_refs.append(allocator, .{ .source_name = strings.items[0], .table_name = strings.items[1] });
        return;
    }
    return error.UnsupportedYaml;
}

pub fn parseSourcesFromText(allocator: std.mem.Allocator, text: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    var in_sources = false;
    var in_tables = false;
    var in_columns = false;
    var config_scope: SourceConfigScope = .none;
    var freshness_scope: FreshnessScope = .none;
    var test_target: SourceTestTarget = .none;
    var active_test_target: SourceTestTarget = .none;
    var active_values_target: SourceTestTarget = .none;
    var freshness_time_key: ?FreshnessTimeKey = null;
    var freshness_time_scope: FreshnessScope = .none;
    var freshness_time_update = types.FreshnessTime{};
    var sources_indent: usize = 0;
    var source_item_indent: ?usize = null;
    var table_item_indent: ?usize = null;
    var columns_indent: usize = 0;
    var column_item_indent: ?usize = null;
    var config_indent: usize = 0;
    var freshness_indent: usize = 0;
    var freshness_time_indent: usize = 0;
    var tests_indent: usize = 0;
    var active_test_indent: usize = 0;
    var active_values_indent: usize = 0;
    var current_source: ?[]const u8 = null;
    var current_table_index: ?usize = null;
    var current_column: ?usize = null;
    var active_test_index: ?usize = null;
    var active_values_index: ?usize = null;
    var source_defaults = SourceDefaults{};
    var source_top_loaded_at_field = false;
    var source_top_loaded_at_query = false;
    var source_config_loaded_at_field = false;
    var source_config_loaded_at_query = false;
    var table_top_loaded_at_field = false;
    var table_top_loaded_at_query = false;
    var table_config_loaded_at_field = false;
    var table_config_loaded_at_query = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);

        if (freshness_time_key != null and indent <= freshness_time_indent) {
            try applyPendingFreshnessTime(
                if (freshness_time_scope == .table and current_table_index != null) &graph.sources.items[current_table_index.?].freshness else &source_defaults.freshness,
                freshness_time_key.?,
                freshness_time_update,
            );
            freshness_time_key = null;
            freshness_time_scope = .none;
            freshness_time_update = .{};
        }

        if (std.mem.eql(u8, trimmed, "sources:")) {
            in_sources = true;
            in_tables = false;
            in_columns = false;
            sources_indent = indent;
            source_item_indent = null;
            table_item_indent = null;
            column_item_indent = null;
            current_table_index = null;
            current_column = null;
            config_scope = .none;
            freshness_scope = .none;
            test_target = .none;
            active_test_target = .none;
            active_values_target = .none;
            active_test_index = null;
            active_values_index = null;
            freshness_time_key = null;
            source_defaults = .{};
            source_top_loaded_at_field = false;
            source_top_loaded_at_query = false;
            source_config_loaded_at_field = false;
            source_config_loaded_at_query = false;
            table_top_loaded_at_field = false;
            table_top_loaded_at_query = false;
            table_config_loaded_at_field = false;
            table_config_loaded_at_query = false;
            continue;
        }
        if (!in_sources) continue;
        if (indent <= sources_indent and !std.mem.eql(u8, trimmed, "sources:")) {
            in_sources = false;
            in_tables = false;
            in_columns = false;
            current_source = null;
            current_table_index = null;
            current_column = null;
            config_scope = .none;
            freshness_scope = .none;
            test_target = .none;
            active_test_target = .none;
            active_values_target = .none;
            active_test_index = null;
            active_values_index = null;
            freshness_time_key = null;
            continue;
        }

        if (config_scope != .none and indent <= config_indent and !std.mem.eql(u8, trimmed, "config:")) {
            config_scope = .none;
        }
        if (freshness_scope != .none and indent <= freshness_indent) {
            freshness_scope = .none;
            freshness_time_key = null;
            freshness_time_scope = .none;
            freshness_time_update = .{};
        }

        if (test_target != .none and indent <= tests_indent and !std.mem.startsWith(u8, trimmed, "- ")) {
            test_target = .none;
        }
        if (active_test_index != null and indent <= active_test_indent) {
            active_test_target = .none;
            active_test_index = null;
        }
        if (active_values_index != null and indent <= active_values_indent) {
            active_values_target = .none;
            active_values_index = null;
        }
        if (in_columns and indent <= columns_indent and !std.mem.eql(u8, trimmed, "columns:")) {
            in_columns = false;
            current_column = null;
            column_item_indent = null;
            config_scope = if (config_scope == .table) .none else config_scope;
            freshness_scope = if (freshness_scope == .table) .none else freshness_scope;
            freshness_time_key = null;
            test_target = .none;
            active_test_target = .none;
            active_values_target = .none;
            active_test_index = null;
            active_values_index = null;
        }

        if (std.mem.eql(u8, trimmed, "tables:")) {
            in_tables = true;
            in_columns = false;
            table_item_indent = null;
            column_item_indent = null;
            current_table_index = null;
            current_column = null;
            config_scope = .none;
            freshness_scope = .none;
            test_target = .none;
            active_test_target = .none;
            active_values_target = .none;
            active_test_index = null;
            active_values_index = null;
            freshness_time_key = null;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "- ")) {
            if (active_values_index != null and indent > active_values_indent) {
                const source = &graph.sources.items[current_table_index orelse return error.UnsupportedYaml];
                const test_def = try currentSourceGenericTestDef(source, current_column, active_values_target, active_values_index.?);
                try test_def.accepted_values.append(allocator, try dupTrimmedScalar(allocator, trimmed[2..]));
                continue;
            }
            if (test_target != .none and indent > tests_indent) {
                const source = &graph.sources.items[current_table_index orelse return error.UnsupportedYaml];
                const test_name = try testNameFromYamlItem(allocator, trimmed[2..]);
                if (test_target == .table) {
                    active_test_index = try appendGenericTestDef(allocator, &source.tests, test_name);
                } else {
                    const column_index = current_column orelse return error.UnsupportedYaml;
                    active_test_index = try appendGenericTestDef(allocator, &source.columns.items[column_index].tests, test_name);
                }
                active_test_target = test_target;
                active_test_indent = indent;
                if (std.mem.indexOfScalar(u8, std.mem.trim(u8, trimmed[2..], " \t\r"), ':') == null) {
                    active_test_target = .none;
                    active_test_index = null;
                }
                continue;
            }
            if (!std.mem.startsWith(u8, trimmed, "- name:")) continue;

            const name = try dupTrimmedScalar(allocator, trimmed["- name:".len..]);
            if (in_columns and current_table_index != null and indent > columns_indent) {
                var source = &graph.sources.items[current_table_index.?];
                try source.columns.append(allocator, .{ .name = name });
                current_column = source.columns.items.len - 1;
                column_item_indent = indent;
                test_target = .none;
                active_test_target = .none;
                active_values_target = .none;
                active_test_index = null;
                active_values_index = null;
                config_scope = .none;
                freshness_scope = .none;
                freshness_time_key = null;
            } else if (source_item_indent == null or indent == source_item_indent.?) {
                source_item_indent = indent;
                current_source = name;
                in_tables = false;
                in_columns = false;
                table_item_indent = null;
                column_item_indent = null;
                current_table_index = null;
                current_column = null;
                config_scope = .none;
                freshness_scope = .none;
                test_target = .none;
                active_test_target = .none;
                active_values_target = .none;
                active_test_index = null;
                active_values_index = null;
                freshness_time_key = null;
                source_defaults = .{};
                source_top_loaded_at_field = false;
                source_top_loaded_at_query = false;
                source_config_loaded_at_field = false;
                source_config_loaded_at_query = false;
                table_top_loaded_at_field = false;
                table_top_loaded_at_query = false;
                table_config_loaded_at_field = false;
                table_config_loaded_at_query = false;
            } else if (in_tables and (table_item_indent == null or indent == table_item_indent.?)) {
                table_item_indent = indent;
                const source_name = current_source orelse return error.UnsupportedYaml;
                const unique_id = try std.fmt.allocPrint(allocator, "source.{s}.{s}.{s}", .{ package_name, source_name, name });
                try graph.sources.append(allocator, .{
                    .package_name = package_name,
                    .unique_id = unique_id,
                    .source_name = source_name,
                    .table_name = name,
                    .original_file_path = relative_path,
                    .schema_name = source_defaults.schema_name,
                    .loaded_at_field = source_defaults.loaded_at_field,
                    .loaded_at_query = source_defaults.loaded_at_query,
                    .freshness = source_defaults.freshness,
                });
                current_table_index = graph.sources.items.len - 1;
                in_columns = false;
                column_item_indent = null;
                current_column = null;
                config_scope = .none;
                freshness_scope = .none;
                test_target = .none;
                active_test_target = .none;
                active_values_target = .none;
                active_test_index = null;
                active_values_index = null;
                freshness_time_key = null;
                table_top_loaded_at_field = false;
                table_top_loaded_at_query = false;
                table_config_loaded_at_field = false;
                table_config_loaded_at_query = false;
            }
            continue;
        }
        if (in_tables and current_table_index != null and table_item_indent != null and indent > table_item_indent.?) {
            const kv = splitKeyValue(trimmed) orelse continue;
            const source = &graph.sources.items[current_table_index.?];

            if (active_test_index != null and indent > active_test_indent) {
                if (std.mem.eql(u8, kv.key, "arguments")) {
                    if (std.mem.trim(u8, kv.value, " \t").len != 0) return error.UnsupportedYaml;
                    continue;
                }
                const test_def = try currentSourceGenericTestDef(source, current_column, active_test_target, active_test_index.?);
                if (std.mem.eql(u8, kv.key, "values")) {
                    if (std.mem.trim(u8, kv.value, " \t").len == 0) {
                        active_values_target = active_test_target;
                        active_values_index = active_test_index;
                        active_values_indent = indent;
                    } else {
                        try parseInlineStringList(allocator, kv.value, &test_def.accepted_values);
                    }
                    continue;
                } else if (std.mem.eql(u8, kv.key, "quote")) {
                    if (std.mem.eql(u8, test_def.name, "accepted_values")) {
                        test_def.accepted_values_quote = try parseBool(kv.value);
                    }
                    continue;
                } else if (std.mem.eql(u8, kv.key, "column_name")) {
                    test_def.column_name = try dupTrimmedScalar(allocator, kv.value);
                    continue;
                } else if (std.mem.eql(u8, kv.key, "to")) {
                    test_def.relationship_to = try dupTrimmedScalar(allocator, kv.value);
                    continue;
                } else if (std.mem.eql(u8, kv.key, "field")) {
                    test_def.relationship_field = try dupTrimmedScalar(allocator, kv.value);
                    continue;
                }
            }

            if (freshness_scope == .table and indent > freshness_indent) {
                if (std.mem.eql(u8, kv.key, "filter")) {
                    try applyFreshnessFilter(allocator, &source.freshness, kv);
                    continue;
                }
                if (std.mem.eql(u8, kv.key, "warn_after")) {
                    if (std.mem.trim(u8, kv.value, " \t\r").len != 0) return error.UnsupportedYaml;
                    freshness_time_key = .warn_after;
                    freshness_time_scope = .table;
                    freshness_time_update = .{};
                    freshness_time_indent = indent;
                    continue;
                }
                if (std.mem.eql(u8, kv.key, "error_after")) {
                    if (std.mem.trim(u8, kv.value, " \t\r").len != 0) return error.UnsupportedYaml;
                    freshness_time_key = .error_after;
                    freshness_time_scope = .table;
                    freshness_time_update = .{};
                    freshness_time_indent = indent;
                    continue;
                }
                if (freshness_time_key != null and indent > freshness_time_indent) {
                    try applyFreshnessTimeKeyValue(allocator, &freshness_time_update, kv);
                    continue;
                }
            }

            if (in_columns and current_column != null and column_item_indent != null and indent > column_item_indent.?) {
                if (std.mem.eql(u8, kv.key, "description")) {
                    source.columns.items[current_column.?].description = try dupTrimmedScalar(allocator, kv.value);
                } else if (std.mem.eql(u8, kv.key, "tests") or std.mem.eql(u8, kv.key, "data_tests")) {
                    if (std.mem.trim(u8, kv.value, " \t").len != 0) {
                        try parseInlineGenericTestList(allocator, kv.value, &source.columns.items[current_column.?].tests);
                    } else {
                        test_target = .column;
                        tests_indent = indent;
                        active_test_target = .none;
                        active_values_target = .none;
                        active_test_index = null;
                        active_values_index = null;
                    }
                }
                continue;
            }

            const table_config = config_scope == .table and indent > config_indent;
            if (std.mem.eql(u8, kv.key, "config")) {
                if (std.mem.trim(u8, kv.value, " \t\r").len != 0) return error.UnsupportedYaml;
                config_scope = .table;
                config_indent = indent;
                freshness_scope = .none;
                freshness_time_key = null;
            } else if (std.mem.eql(u8, kv.key, "loaded_at_field")) {
                if ((table_top_loaded_at_query or table_config_loaded_at_query) and !isYamlNull(kv.value)) return error.UnsupportedYaml;
                if (table_config) {
                    table_config_loaded_at_field = true;
                } else {
                    table_top_loaded_at_field = true;
                }
                try setLoadedAtField(allocator, &source.loaded_at_field, &source.loaded_at_query, kv.value);
                freshness_scope = .none;
                freshness_time_key = null;
            } else if (std.mem.eql(u8, kv.key, "loaded_at_query")) {
                if ((table_top_loaded_at_field or table_config_loaded_at_field) and !isYamlNull(kv.value)) return error.UnsupportedYaml;
                if (table_config) {
                    table_config_loaded_at_query = true;
                } else {
                    table_top_loaded_at_query = true;
                }
                try setLoadedAtQuery(allocator, &source.loaded_at_field, &source.loaded_at_query, kv.value);
                freshness_scope = .none;
                freshness_time_key = null;
            } else if (std.mem.eql(u8, kv.key, "identifier")) {
                source.identifier = try dupTrimmedScalar(allocator, kv.value);
                freshness_scope = .none;
                freshness_time_key = null;
            } else if (std.mem.eql(u8, kv.key, "tests") or std.mem.eql(u8, kv.key, "data_tests")) {
                if (std.mem.trim(u8, kv.value, " \t").len != 0) {
                    try parseInlineGenericTestList(allocator, kv.value, &source.tests);
                } else {
                    test_target = .table;
                    tests_indent = indent;
                    active_test_target = .none;
                    active_values_target = .none;
                    active_test_index = null;
                    active_values_index = null;
                }
            } else if (std.mem.eql(u8, kv.key, "columns")) {
                if (std.mem.trim(u8, kv.value, " \t\r").len != 0) return error.UnsupportedYaml;
                in_columns = true;
                columns_indent = indent;
                current_column = null;
                column_item_indent = null;
                config_scope = .none;
                freshness_scope = .none;
                test_target = .none;
                active_test_target = .none;
                active_values_target = .none;
                active_test_index = null;
                active_values_index = null;
                freshness_time_key = null;
            } else if (std.mem.eql(u8, kv.key, "freshness")) {
                try beginFreshnessBlock(&source.freshness, kv.value);
                freshness_scope = if (source.freshness == null and isYamlNull(kv.value)) .none else .table;
                freshness_indent = indent;
                freshness_time_key = null;
            }
            continue;
        }

        if (current_source != null and source_item_indent != null and indent > source_item_indent.?) {
            const kv = splitKeyValue(trimmed) orelse continue;

            if (freshness_scope == .source and indent > freshness_indent) {
                if (std.mem.eql(u8, kv.key, "filter")) {
                    try applyFreshnessFilter(allocator, &source_defaults.freshness, kv);
                    continue;
                }
                if (std.mem.eql(u8, kv.key, "warn_after")) {
                    if (std.mem.trim(u8, kv.value, " \t\r").len != 0) return error.UnsupportedYaml;
                    freshness_time_key = .warn_after;
                    freshness_time_scope = .source;
                    freshness_time_update = .{};
                    freshness_time_indent = indent;
                    continue;
                }
                if (std.mem.eql(u8, kv.key, "error_after")) {
                    if (std.mem.trim(u8, kv.value, " \t\r").len != 0) return error.UnsupportedYaml;
                    freshness_time_key = .error_after;
                    freshness_time_scope = .source;
                    freshness_time_update = .{};
                    freshness_time_indent = indent;
                    continue;
                }
                if (freshness_time_key != null and indent > freshness_time_indent) {
                    try applyFreshnessTimeKeyValue(allocator, &freshness_time_update, kv);
                    continue;
                }
            }

            const source_config = config_scope == .source and indent > config_indent;
            if (std.mem.eql(u8, kv.key, "config")) {
                if (std.mem.trim(u8, kv.value, " \t\r").len != 0) return error.UnsupportedYaml;
                config_scope = .source;
                config_indent = indent;
                freshness_scope = .none;
                freshness_time_key = null;
            } else if (std.mem.eql(u8, kv.key, "schema")) {
                source_defaults.schema_name = try dupSourceSchemaScalar(allocator, graph, kv.value);
                freshness_scope = .none;
                freshness_time_key = null;
            } else if (std.mem.eql(u8, kv.key, "loaded_at_field")) {
                if ((source_top_loaded_at_query or source_config_loaded_at_query) and !isYamlNull(kv.value)) return error.UnsupportedYaml;
                if (source_config) {
                    source_config_loaded_at_field = true;
                } else {
                    source_top_loaded_at_field = true;
                }
                try setLoadedAtField(allocator, &source_defaults.loaded_at_field, &source_defaults.loaded_at_query, kv.value);
                freshness_scope = .none;
                freshness_time_key = null;
            } else if (std.mem.eql(u8, kv.key, "loaded_at_query")) {
                if ((source_top_loaded_at_field or source_config_loaded_at_field) and !isYamlNull(kv.value)) return error.UnsupportedYaml;
                if (source_config) {
                    source_config_loaded_at_query = true;
                } else {
                    source_top_loaded_at_query = true;
                }
                try setLoadedAtQuery(allocator, &source_defaults.loaded_at_field, &source_defaults.loaded_at_query, kv.value);
                freshness_scope = .none;
                freshness_time_key = null;
            } else if (std.mem.eql(u8, kv.key, "freshness")) {
                try beginFreshnessBlock(&source_defaults.freshness, kv.value);
                freshness_scope = if (source_defaults.freshness == null and isYamlNull(kv.value)) .none else .source;
                freshness_indent = indent;
                freshness_time_key = null;
            }
        }
    }
    if (freshness_time_key != null) {
        try applyPendingFreshnessTime(
            if (freshness_time_scope == .table and current_table_index != null) &graph.sources.items[current_table_index.?].freshness else &source_defaults.freshness,
            freshness_time_key.?,
            freshness_time_update,
        );
    }
}

pub fn parseUnitTestsFromText(allocator: std.mem.Allocator, text: []const u8, resource_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    var in_unit_tests = false;
    var section: UnitTestSection = .none;
    var rows_target: UnitTestRowsTarget = .none;
    var unit_tests_indent: usize = 0;
    var unit_test_item_indent: ?usize = null;
    var section_indent: usize = 0;
    var given_item_indent: usize = 0;
    var rows_indent: usize = 0;
    var active_row_indent: usize = 0;
    var current_unit_test: ?usize = null;
    var current_given: ?usize = null;
    var active_row: ?usize = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);

        if (std.mem.eql(u8, trimmed, "unit_tests:")) {
            in_unit_tests = true;
            section = .none;
            rows_target = .none;
            unit_tests_indent = indent;
            unit_test_item_indent = null;
            current_unit_test = null;
            current_given = null;
            active_row = null;
            continue;
        }
        if (!in_unit_tests) continue;
        if (indent <= unit_tests_indent and !std.mem.eql(u8, trimmed, "unit_tests:")) {
            in_unit_tests = false;
            section = .none;
            rows_target = .none;
            current_unit_test = null;
            current_given = null;
            active_row = null;
            continue;
        }

        if (rows_target != .none) {
            if (indent <= rows_indent and !std.mem.startsWith(u8, trimmed, "- ")) {
                rows_target = .none;
                active_row = null;
            } else if (indent > rows_indent) {
                var fixture = try currentUnitTestRowsFixture(graph, current_unit_test, current_given, rows_target);
                if (std.mem.startsWith(u8, trimmed, "- ")) {
                    active_row = try appendUnitTestRow(allocator, fixture, trimmed[2..], indent);
                    active_row_indent = indent;
                    continue;
                }
                if (active_row) |row_index| {
                    if (indent > active_row_indent) {
                        if (std.mem.eql(u8, trimmed, "}")) {
                            active_row = null;
                            continue;
                        }
                        const closes = std.mem.endsWith(u8, trimmed, "}");
                        const row_line = if (closes) std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t\r,") else trimmed;
                        try appendUnitTestRowEntry(allocator, &fixture.rows.items[row_index], row_line);
                        if (closes) active_row = null;
                        continue;
                    }
                    active_row = null;
                }
            }
        }

        if (section != .none and indent <= section_indent and !isUnitTestSectionKey(trimmed)) {
            section = .none;
            current_given = null;
        }

        if (std.mem.startsWith(u8, trimmed, "- name:")) {
            if (unit_test_item_indent == null or indent == unit_test_item_indent.?) {
                unit_test_item_indent = indent;
                section = .none;
                rows_target = .none;
                current_given = null;
                active_row = null;
                const name = try dupTrimmedScalar(allocator, trimmed["- name:".len..]);
                try graph.unit_tests.append(allocator, .{
                    .package_name = package_name,
                    .name = name,
                    .path = relativeUnderResourcePath(relative_path, resource_root),
                    .original_file_path = relative_path,
                });
                current_unit_test = graph.unit_tests.items.len - 1;
                continue;
            }
        }

        const unit_test_index = current_unit_test orelse continue;
        if (unit_test_item_indent) |item_indent| {
            if (indent <= item_indent and !std.mem.startsWith(u8, trimmed, "- name:")) {
                section = .none;
                rows_target = .none;
                current_given = null;
                active_row = null;
            }
        }

        if (section == .given and std.mem.startsWith(u8, trimmed, "- input:") and indent > section_indent) {
            const input = try dupTrimmedScalar(allocator, trimmed["- input:".len..]);
            try graph.unit_tests.items[unit_test_index].given.append(allocator, .{ .input = input });
            current_given = graph.unit_tests.items[unit_test_index].given.items.len - 1;
            given_item_indent = indent;
            rows_target = .none;
            active_row = null;
            continue;
        }

        const kv = splitKeyValue(trimmed) orelse continue;
        if (section == .given and current_given != null and indent > given_item_indent) {
            const fixture = &graph.unit_tests.items[unit_test_index].given.items[current_given.?];
            try applyUnitTestFixtureKeyValue(allocator, fixture, kv, &rows_target, &rows_indent, .given, indent);
            active_row = null;
            continue;
        }
        if (section == .expect and indent > section_indent) {
            const fixture = &graph.unit_tests.items[unit_test_index].expect;
            try applyUnitTestFixtureKeyValue(allocator, fixture, kv, &rows_target, &rows_indent, .expect, indent);
            active_row = null;
            continue;
        }
        if (section == .config and indent > section_indent) {
            if (std.mem.eql(u8, kv.key, "enabled")) {
                graph.unit_tests.items[unit_test_index].enabled = try parseBool(kv.value);
            } else if (std.mem.eql(u8, kv.key, "tags")) {
                try parseInlineStringList(allocator, kv.value, &graph.unit_tests.items[unit_test_index].tags);
                sortStrings(graph.unit_tests.items[unit_test_index].tags.items);
            } else if (std.mem.eql(u8, kv.key, "meta")) {
                if (std.mem.trim(u8, kv.value, " \t\r").len != 0) return error.UnsupportedYaml;
            }
            continue;
        }

        if (indent <= (unit_test_item_indent orelse 0)) continue;
        if (std.mem.eql(u8, kv.key, "model")) {
            graph.unit_tests.items[unit_test_index].model = try dupTrimmedScalar(allocator, kv.value);
            try ensureUnitTestUniqueId(allocator, &graph.unit_tests.items[unit_test_index]);
        } else if (std.mem.eql(u8, kv.key, "description")) {
            graph.unit_tests.items[unit_test_index].description = try dupTrimmedScalar(allocator, kv.value);
        } else if (std.mem.eql(u8, kv.key, "given")) {
            if (std.mem.trim(u8, kv.value, " \t\r").len != 0) return error.UnsupportedYaml;
            section = .given;
            section_indent = indent;
            rows_target = .none;
            current_given = null;
        } else if (std.mem.eql(u8, kv.key, "expect")) {
            if (std.mem.trim(u8, kv.value, " \t\r").len != 0) return error.UnsupportedYaml;
            section = .expect;
            section_indent = indent;
            rows_target = .none;
            current_given = null;
        } else if (std.mem.eql(u8, kv.key, "config")) {
            if (std.mem.trim(u8, kv.value, " \t\r").len != 0) return error.UnsupportedYaml;
            section = .config;
            section_indent = indent;
            rows_target = .none;
            current_given = null;
        } else if (std.mem.eql(u8, kv.key, "overrides") or std.mem.eql(u8, kv.key, "versions")) {
            return error.UnsupportedYaml;
        }
    }

    for (graph.unit_tests.items) |*unit_test| {
        try ensureUnitTestUniqueId(allocator, unit_test);
        if (unit_test.model.len == 0 or unit_test.given.items.len == 0) return error.UnsupportedYaml;
        for (unit_test.given.items) |given| {
            if (given.input == null) return error.UnsupportedYaml;
        }
        if (!unit_test.expect.rows_set and unit_test.expect.fixture == null) return error.UnsupportedYaml;
    }
}

fn isUnitTestSectionKey(trimmed: []const u8) bool {
    return std.mem.eql(u8, trimmed, "given:") or std.mem.eql(u8, trimmed, "expect:") or std.mem.eql(u8, trimmed, "config:");
}

fn ensureUnitTestUniqueId(allocator: std.mem.Allocator, unit_test: *types.UnitTestDef) !void {
    if (unit_test.unique_id.len != 0 or unit_test.model.len == 0) return;
    unit_test.unique_id = try std.fmt.allocPrint(allocator, "unit_test.{s}.{s}.{s}", .{ unit_test.package_name, unit_test.model, unit_test.name });
}

fn currentUnitTestRowsFixture(graph: *Graph, current_unit_test: ?usize, current_given: ?usize, target: UnitTestRowsTarget) !*UnitTestFixture {
    const unit_test_index = current_unit_test orelse return error.UnsupportedYaml;
    if (target == .expect) return &graph.unit_tests.items[unit_test_index].expect;
    const given_index = current_given orelse return error.UnsupportedYaml;
    return &graph.unit_tests.items[unit_test_index].given.items[given_index];
}

fn applyUnitTestFixtureKeyValue(
    allocator: std.mem.Allocator,
    fixture: *UnitTestFixture,
    kv: KeyValue,
    rows_target: *UnitTestRowsTarget,
    rows_indent: *usize,
    target: UnitTestRowsTarget,
    indent: usize,
) !void {
    if (std.mem.eql(u8, kv.key, "rows")) {
        try beginUnitTestRows(allocator, fixture, kv.value, rows_target, rows_indent, target, indent);
    } else if (std.mem.eql(u8, kv.key, "format")) {
        const format = try dupTrimmedScalar(allocator, kv.value);
        if (!std.mem.eql(u8, format, "dict") and !std.mem.eql(u8, format, "csv") and !std.mem.eql(u8, format, "sql")) return error.UnsupportedYaml;
        fixture.format = format;
        rows_target.* = .none;
    } else if (std.mem.eql(u8, kv.key, "fixture")) {
        fixture.fixture = if (isYamlNull(kv.value)) null else try dupTrimmedScalar(allocator, kv.value);
        rows_target.* = .none;
    }
}

fn beginUnitTestRows(
    allocator: std.mem.Allocator,
    fixture: *UnitTestFixture,
    raw_value: []const u8,
    rows_target: *UnitTestRowsTarget,
    rows_indent: *usize,
    target: UnitTestRowsTarget,
    indent: usize,
) !void {
    const value = std.mem.trim(u8, raw_value, " \t\r");
    fixture.rows_set = true;
    if (value.len == 0) {
        rows_target.* = target;
        rows_indent.* = indent;
        return;
    }
    rows_target.* = .none;
    if (std.mem.eql(u8, value, "[]")) return;
    if (std.mem.eql(u8, value, "|") or std.mem.eql(u8, value, ">")) return error.UnsupportedYaml;
    if (std.mem.startsWith(u8, value, "{")) {
        _ = try appendUnitTestRow(allocator, fixture, value, indent);
        return;
    }
    return error.UnsupportedYaml;
}

fn appendUnitTestRow(allocator: std.mem.Allocator, fixture: *UnitTestFixture, raw_value: []const u8, indent: usize) !usize {
    _ = indent;
    var row = UnitTestRow{};
    errdefer row.entries.deinit(allocator);
    const value = std.mem.trim(u8, raw_value, " \t\r");
    if (value.len != 0 and !std.mem.eql(u8, value, "{")) {
        if (std.mem.startsWith(u8, value, "{")) {
            try parseInlineUnitTestRow(allocator, &row, value);
        } else {
            try appendUnitTestRowEntry(allocator, &row, value);
        }
    }
    try fixture.rows.append(allocator, row);
    return fixture.rows.items.len - 1;
}

fn parseInlineUnitTestRow(allocator: std.mem.Allocator, row: *UnitTestRow, raw_value: []const u8) !void {
    var value = std.mem.trim(u8, raw_value, " \t\r");
    if (value.len < 2 or value[0] != '{' or value[value.len - 1] != '}') return error.UnsupportedYaml;
    value = std.mem.trim(u8, value[1 .. value.len - 1], " \t\r");
    var start: usize = 0;
    while (start < value.len) {
        const comma = findUnitTestRowComma(value, start) orelse value.len;
        const piece = std.mem.trim(u8, value[start..comma], " \t\r");
        if (piece.len != 0) try appendUnitTestRowEntry(allocator, row, piece);
        start = comma + 1;
    }
}

fn findUnitTestRowComma(value: []const u8, start: usize) ?usize {
    var index = start;
    var quote: ?u8 = null;
    while (index < value.len) : (index += 1) {
        const byte = value[index];
        if (quote) |q| {
            if (byte == '\\') {
                index += 1;
                continue;
            }
            if (byte == q) quote = null;
            continue;
        }
        if (byte == '"' or byte == '\'') {
            quote = byte;
        } else if (byte == ',') {
            return index;
        }
    }
    return null;
}

fn appendUnitTestRowEntry(allocator: std.mem.Allocator, row: *UnitTestRow, raw_entry: []const u8) !void {
    const trimmed = std.mem.trim(u8, raw_entry, " \t\r,");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "}")) return;
    const kv = splitKeyValue(trimmed) orelse return error.UnsupportedYaml;
    const value = std.mem.trim(u8, kv.value, " \t\r,");
    try row.entries.append(allocator, .{ .key = try dupTrimmedScalar(allocator, kv.key), .value = try parseJsonScalar(allocator, value) });
}

fn currentSourceGenericTestDef(source: *types.SourceDef, current_column: ?usize, target: SourceTestTarget, test_index: usize) !*GenericTestDef {
    if (target == .table) return &source.tests.items[test_index];
    if (target == .column) {
        const column_index = current_column orelse return error.UnsupportedYaml;
        return &source.columns.items[column_index].tests.items[test_index];
    }
    return error.UnsupportedYaml;
}

fn isYamlNull(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    return std.mem.eql(u8, trimmed, "null") or std.mem.eql(u8, trimmed, "~");
}

fn setLoadedAtField(allocator: std.mem.Allocator, field: *?[]const u8, query: *?[]const u8, value: []const u8) !void {
    field.* = if (isYamlNull(value)) null else try dupTrimmedScalar(allocator, value);
    query.* = null;
}

fn setLoadedAtQuery(allocator: std.mem.Allocator, field: *?[]const u8, query: *?[]const u8, value: []const u8) !void {
    query.* = if (isYamlNull(value)) null else try dupTrimmedScalar(allocator, value);
    _ = field;
}

fn beginFreshnessBlock(freshness: *?types.FreshnessThreshold, value: []const u8) !void {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (isYamlNull(trimmed)) {
        freshness.* = null;
        return;
    }
    if (trimmed.len != 0) return error.UnsupportedYaml;
    if (freshness.* == null) freshness.* = .{};
}

fn applyFreshnessFilter(allocator: std.mem.Allocator, freshness: *?types.FreshnessThreshold, kv: KeyValue) !void {
    var value = freshness.* orelse types.FreshnessThreshold{};
    value.filter = try dupTrimmedScalar(allocator, kv.value);
    freshness.* = value;
}

fn applyFreshnessTimeKeyValue(allocator: std.mem.Allocator, time: *types.FreshnessTime, kv: KeyValue) !void {
    if (!std.mem.eql(u8, kv.key, "count") and !std.mem.eql(u8, kv.key, "period")) return;
    if (std.mem.eql(u8, kv.key, "count")) {
        const count_text = std.mem.trim(u8, kv.value, " \t\r");
        time.count = try std.fmt.parseUnsigned(u64, count_text, 10);
    } else {
        const period = try dupTrimmedScalar(allocator, kv.value);
        if (!std.mem.eql(u8, period, "minute") and !std.mem.eql(u8, period, "hour") and !std.mem.eql(u8, period, "day")) return error.UnsupportedYaml;
        time.period = period;
    }
}

fn applyPendingFreshnessTime(freshness_target: *?types.FreshnessThreshold, time_key: FreshnessTimeKey, time: types.FreshnessTime) !void {
    if (time.count == null or time.period == null) return;
    var freshness = freshness_target.* orelse types.FreshnessThreshold{};
    switch (time_key) {
        .warn_after => freshness.warn_after = time,
        .error_after => freshness.error_after = time,
    }
    freshness_target.* = freshness;
}

fn dupSourceSchemaScalar(allocator: std.mem.Allocator, graph: *const Graph, value: []const u8) ![]const u8 {
    const scalar = try dupTrimmedScalar(allocator, value);
    if (std.mem.indexOf(u8, scalar, "{{") == null) return scalar;

    const token = "{{ target.schema }}";
    if (std.mem.indexOf(u8, scalar, token) == null) return error.UnsupportedYaml;

    var out: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, scalar, cursor, token)) |start| {
        try out.appendSlice(allocator, scalar[cursor..start]);
        try out.appendSlice(allocator, graph.target_schema);
        cursor = start + token.len;
    }
    try out.appendSlice(allocator, scalar[cursor..]);
    const rendered = try out.toOwnedSlice(allocator);
    if (std.mem.indexOf(u8, rendered, "{{") != null or std.mem.indexOf(u8, rendered, "}}") != null) return error.UnsupportedYaml;
    return rendered;
}

pub fn parseExposuresFromText(allocator: std.mem.Allocator, text: []const u8, resource_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    var in_exposures = false;
    var in_depends_on = false;
    var in_owner = false;
    var in_config = false;
    var in_meta = false;
    var exposures_indent: usize = 0;
    var exposure_item_indent: ?usize = null;
    var depends_on_indent: usize = 0;
    var owner_indent: usize = 0;
    var config_indent: usize = 0;
    var meta_indent: usize = 0;
    var current_exposure: ?usize = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);

        if (std.mem.eql(u8, trimmed, "exposures:")) {
            in_exposures = true;
            in_depends_on = false;
            in_owner = false;
            in_config = false;
            in_meta = false;
            exposures_indent = indent;
            exposure_item_indent = null;
            current_exposure = null;
            continue;
        }
        if (!in_exposures) continue;
        if (indent <= exposures_indent and !std.mem.eql(u8, trimmed, "exposures:")) {
            in_exposures = false;
            in_depends_on = false;
            in_owner = false;
            in_config = false;
            in_meta = false;
            current_exposure = null;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "- name:")) {
            if (exposure_item_indent == null or indent == exposure_item_indent.?) {
                exposure_item_indent = indent;
                in_depends_on = false;
                in_owner = false;
                in_config = false;
                in_meta = false;
                const name = try dupTrimmedScalar(allocator, trimmed["- name:".len..]);
                const unique_id = try std.fmt.allocPrint(allocator, "exposure.{s}.{s}", .{ package_name, name });
                try graph.exposures.append(allocator, .{
                    .package_name = package_name,
                    .unique_id = unique_id,
                    .name = name,
                    .path = relativeUnderResourcePath(relative_path, resource_root),
                    .original_file_path = relative_path,
                });
                current_exposure = graph.exposures.items.len - 1;
                continue;
            }
        }

        const exposure_index = current_exposure orelse continue;
        if (exposure_item_indent) |item_indent| {
            if (indent <= item_indent and !std.mem.startsWith(u8, trimmed, "- name:")) {
                in_depends_on = false;
                in_owner = false;
                in_config = false;
                in_meta = false;
            }
        }

        if (std.mem.eql(u8, trimmed, "depends_on:")) {
            in_depends_on = true;
            in_owner = false;
            in_config = false;
            in_meta = false;
            depends_on_indent = indent;
            continue;
        }
        if (std.mem.eql(u8, trimmed, "owner:")) {
            in_owner = true;
            in_depends_on = false;
            in_config = false;
            in_meta = false;
            owner_indent = indent;
            continue;
        }
        if (std.mem.eql(u8, trimmed, "config:")) {
            in_config = true;
            in_depends_on = false;
            in_owner = false;
            in_meta = false;
            config_indent = indent;
            continue;
        }
        if (std.mem.eql(u8, trimmed, "meta:")) {
            in_meta = true;
            in_depends_on = false;
            in_owner = false;
            meta_indent = indent;
            continue;
        }
        if (in_depends_on and indent <= depends_on_indent) in_depends_on = false;
        if (in_owner and indent <= owner_indent) in_owner = false;
        if (in_config and indent <= config_indent) in_config = false;
        if (in_meta and indent <= meta_indent) in_meta = false;

        if (in_depends_on and std.mem.startsWith(u8, trimmed, "- ")) {
            try parseExposureDependency(allocator, trimmed[2..], &graph.exposures.items[exposure_index]);
            continue;
        }

        if (splitKeyValue(trimmed)) |kv| {
            const value = try dupTrimmedScalar(allocator, kv.value);
            if (in_meta) {
                try appendMetaEntry(allocator, &graph.exposures.items[exposure_index].meta, kv.key, try parseJsonScalar(allocator, kv.value));
                continue;
            }
            if (in_owner) {
                if (std.mem.eql(u8, kv.key, "name")) {
                    graph.exposures.items[exposure_index].owner_name = value;
                } else if (std.mem.eql(u8, kv.key, "email")) {
                    graph.exposures.items[exposure_index].owner_email = value;
                }
                continue;
            }
            if (in_config) {
                if (std.mem.eql(u8, kv.key, "enabled")) {
                    graph.exposures.items[exposure_index].enabled = try parseBool(kv.value);
                } else if (std.mem.eql(u8, kv.key, "tags")) {
                    try parseInlineStringList(allocator, kv.value, &graph.exposures.items[exposure_index].tags);
                    sortStrings(graph.exposures.items[exposure_index].tags.items);
                } else if (std.mem.eql(u8, kv.key, "meta") and std.mem.trim(u8, kv.value, " \t").len == 0) {
                    in_meta = true;
                    meta_indent = indent;
                }
                continue;
            }
            if (std.mem.eql(u8, kv.key, "type")) {
                graph.exposures.items[exposure_index].exposure_type = value;
            } else if (std.mem.eql(u8, kv.key, "maturity")) {
                graph.exposures.items[exposure_index].maturity = value;
            } else if (std.mem.eql(u8, kv.key, "url")) {
                graph.exposures.items[exposure_index].url = value;
            } else if (std.mem.eql(u8, kv.key, "description")) {
                graph.exposures.items[exposure_index].description = value;
            } else if (std.mem.eql(u8, kv.key, "tags")) {
                try parseInlineStringList(allocator, kv.value, &graph.exposures.items[exposure_index].tags);
                sortStrings(graph.exposures.items[exposure_index].tags.items);
            }
        }
    }
}

fn appendMetaEntry(allocator: std.mem.Allocator, entries: *std.ArrayList(MetaEntry), key: []const u8, value: JsonScalar) !void {
    for (entries.items) |*existing| {
        if (std.mem.eql(u8, existing.key, key)) {
            existing.value = value;
            return;
        }
    }
    try entries.append(allocator, .{ .key = try allocator.dupe(u8, key), .value = value });
    sortMetaEntries(entries.items);
}

fn sortMetaEntries(entries: []MetaEntry) void {
    std.mem.sort(MetaEntry, entries, {}, struct {
        fn lessThan(_: void, a: MetaEntry, b: MetaEntry) bool {
            return std.mem.lessThan(u8, a.key, b.key);
        }
    }.lessThan);
}

pub const GenericTestNames = struct {
    full: []const u8,
    compiled: []const u8,
};

pub fn synthesizeGenericTestNames(allocator: std.mem.Allocator, test_def: GenericTestDef, model_name: []const u8, column_name: ?[]const u8) !GenericTestNames {
    var clean_args: std.ArrayList([]const u8) = .empty;
    defer {
        for (clean_args.items) |arg| allocator.free(arg);
        clean_args.deinit(allocator);
    }

    const argument_name = if (std.mem.startsWith(u8, test_def.name, "source_")) test_def.name["source_".len..] else test_def.name;
    if (column_name) |column| try clean_args.append(allocator, try cleanTestNamePart(allocator, column));
    if (std.mem.eql(u8, argument_name, "relationships")) {
        try clean_args.append(allocator, try cleanTestNamePart(allocator, test_def.relationship_field));
        try clean_args.append(allocator, try cleanTestNamePart(allocator, test_def.relationship_to));
    } else if (std.mem.eql(u8, argument_name, "accepted_values")) {
        if (test_def.accepted_values_quote) |quote| {
            try clean_args.append(allocator, try cleanTestNamePart(allocator, if (quote) "True" else "False"));
        }
        for (test_def.accepted_values.items) |value| {
            try clean_args.append(allocator, try cleanTestNamePart(allocator, value));
        }
    }

    const test_identifier = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ test_def.name, model_name });
    const unique = try joinStrings(allocator, clean_args.items, "__");
    defer allocator.free(unique);

    const full = if (unique.len == 0)
        try std.fmt.allocPrint(allocator, "{s}_", .{test_identifier})
    else
        try std.fmt.allocPrint(allocator, "{s}_{s}", .{ test_identifier, unique });
    if (full.len < 64) return .{ .full = full, .compiled = full };

    const label = genericTestHashFull(full);
    const prefix_len = @min(test_identifier.len, 30);
    const compiled = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ test_identifier[0..prefix_len], label });
    return .{ .full = full, .compiled = compiled };
}

pub fn genericTestUniqueId(allocator: std.mem.Allocator, package_name: []const u8, name: []const u8, test_def: GenericTestDef, model_name: []const u8, column_name: ?[]const u8) ![]const u8 {
    const model_kwarg = try std.fmt.allocPrint(allocator, "{{{{ get_where_subquery(ref('{s}')) }}}}", .{model_name});
    defer allocator.free(model_kwarg);
    return try genericTestUniqueIdForModelKwarg(allocator, package_name, name, test_def, model_kwarg, column_name);
}

pub fn genericTestUniqueIdForModelKwarg(allocator: std.mem.Allocator, package_name: []const u8, name: []const u8, test_def: GenericTestDef, model_kwarg: []const u8, column_name: ?[]const u8) ![]const u8 {
    const metadata = try genericTestMetadataRepr(allocator, test_def, model_kwarg, column_name);
    defer allocator.free(metadata);

    const hash_input = try std.fmt.allocPrint(allocator, "{s}{s}", .{ name, metadata });
    defer allocator.free(hash_input);
    const suffix = genericTestHashSuffix(hash_input);
    return try std.fmt.allocPrint(allocator, "test.{s}.{s}.{s}", .{ package_name, name, suffix });
}

fn genericTestMetadataRepr(allocator: std.mem.Allocator, test_def: GenericTestDef, model_kwarg: []const u8, column_name: ?[]const u8) ![]const u8 {
    if (std.mem.eql(u8, test_def.name, "accepted_values")) {
        const values = try pythonReprStringList(allocator, test_def.accepted_values.items);
        defer allocator.free(values);
        if (column_name) |column| {
            if (test_def.accepted_values_quote) |quote| {
                return try std.fmt.allocPrint(allocator, "{{'kwargs': {{'column_name': '{s}', 'model': \"{s}\", 'quote': '{s}', 'values': {s}}}, 'name': '{s}', 'namespace': 'None'}}", .{ column, model_kwarg, if (quote) "True" else "False", values, test_def.name });
            }
            return try std.fmt.allocPrint(allocator, "{{'kwargs': {{'column_name': '{s}', 'model': \"{s}\", 'values': {s}}}, 'name': '{s}', 'namespace': 'None'}}", .{ column, model_kwarg, values, test_def.name });
        }
    }
    if (std.mem.eql(u8, test_def.name, "relationships")) {
        if (column_name) |column| {
            return try std.fmt.allocPrint(allocator, "{{'kwargs': {{'column_name': '{s}', 'field': '{s}', 'model': \"{s}\", 'to': \"{s}\"}}, 'name': '{s}', 'namespace': 'None'}}", .{ column, test_def.relationship_field, model_kwarg, test_def.relationship_to, test_def.name });
        }
    }
    if (column_name) |column| {
        return try std.fmt.allocPrint(allocator, "{{'kwargs': {{'column_name': '{s}', 'model': \"{s}\"}}, 'name': '{s}', 'namespace': 'None'}}", .{ column, model_kwarg, test_def.name });
    }
    return try std.fmt.allocPrint(allocator, "{{'kwargs': {{'model': \"{s}\"}}, 'name': '{s}', 'namespace': 'None'}}", .{ model_kwarg, test_def.name });
}

fn genericTestHashSuffix(input: []const u8) [10]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(input, &digest, .{});
    var hex: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;
    var suffix: [10]u8 = undefined;
    @memcpy(&suffix, hex[22..32]);
    return suffix;
}

fn genericTestHashFull(input: []const u8) [32]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(input, &digest, .{});
    var hex: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;
    return hex;
}

fn pythonReprStringList(allocator: std.mem.Allocator, values: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (values, 0..) |value, index| {
        if (index != 0) try out.appendSlice(allocator, ", ");
        const repr = try pythonReprString(allocator, value);
        defer allocator.free(repr);
        try out.appendSlice(allocator, repr);
    }
    try out.append(allocator, ']');
    return try out.toOwnedSlice(allocator);
}

fn pythonReprString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const has_single = std.mem.indexOfScalar(u8, value, '\'') != null;
    const has_double = std.mem.indexOfScalar(u8, value, '"') != null;
    const quote: u8 = if (has_single and !has_double) '"' else '\'';

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, quote);
    for (value) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (ch == quote) try out.append(allocator, '\\');
                try out.append(allocator, ch);
            },
        }
    }
    try out.append(allocator, quote);
    return try out.toOwnedSlice(allocator);
}

fn joinStrings(allocator: std.mem.Allocator, values: []const []const u8, separator: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (values, 0..) |value, index| {
        if (index != 0) try out.appendSlice(allocator, separator);
        try out.appendSlice(allocator, value);
    }
    return try out.toOwnedSlice(allocator);
}

fn cleanTestNamePart(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var previous_was_replacement = false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            try out.append(allocator, ch);
            previous_was_replacement = false;
        } else {
            if (previous_was_replacement) continue;
            try out.append(allocator, '_');
            previous_was_replacement = true;
        }
    }
    return try out.toOwnedSlice(allocator);
}

test "parseBool accepts YAML bool scalars case-insensitively" {
    try std.testing.expect(try parseBool(" true "));
    try std.testing.expect(try parseBool("FALSE\r") == false);
    try std.testing.expectError(error.UnsupportedYaml, parseBool("yes"));
}

test "parseJsonScalar classifies JSON-compatible YAML scalars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const string_scalar = try parseJsonScalar(allocator, "\"blue\"");
    try std.testing.expectEqual(.string, string_scalar.kind);
    try std.testing.expectEqualStrings("blue", string_scalar.text);

    const number_scalar = try parseJsonScalar(allocator, "-12.5e+3");
    try std.testing.expectEqual(.number, number_scalar.kind);
    try std.testing.expectEqualStrings("-12.5e+3", number_scalar.text);

    const bool_scalar = try parseJsonScalar(allocator, "false");
    try std.testing.expectEqual(.bool, bool_scalar.kind);
    try std.testing.expectEqualStrings("false", bool_scalar.text);

    const null_scalar = try parseJsonScalar(allocator, "null");
    try std.testing.expectEqual(.null, null_scalar.kind);
    try std.testing.expectEqualStrings("null", null_scalar.text);
}

test "json number parser rejects invalid leading zero forms" {
    try std.testing.expect(isJsonNumber("0"));
    try std.testing.expect(isJsonNumber("-12.5e+3"));
    try std.testing.expect(!isJsonNumber("007"));
    try std.testing.expect(!isJsonNumber("-01"));
    try std.testing.expect(!isJsonNumber("1."));
}

test "testNameFromYamlItem reads scalar and mapping test names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("not_null", try testNameFromYamlItem(allocator, " not_null "));
    try std.testing.expectEqualStrings("relationships", try testNameFromYamlItem(allocator, "relationships:"));
    try std.testing.expectEqualStrings("accepted_values", try testNameFromYamlItem(allocator, "\"accepted_values\": {values: [a, b]}"));
    try std.testing.expectError(error.UnsupportedYaml, testNameFromYamlItem(allocator, "   "));
}

test "parseInlineGenericTestList reads scalar and inline generic tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tests: std.ArrayList(GenericTestDef) = .empty;
    defer tests.deinit(allocator);
    try parseInlineGenericTestList(allocator, "[unique, \"not_null\", ]", &tests);
    try std.testing.expectEqual(@as(usize, 2), tests.items.len);
    try std.testing.expectEqualStrings("unique", tests.items[0].name);
    try std.testing.expectEqualStrings("not_null", tests.items[1].name);

    var scalar: std.ArrayList(GenericTestDef) = .empty;
    defer scalar.deinit(allocator);
    try parseInlineGenericTestList(allocator, "'accepted_values'", &scalar);
    try std.testing.expectEqual(@as(usize, 1), scalar.items.len);
    try std.testing.expectEqualStrings("accepted_values", scalar.items[0].name);
}

test "appendGenericTestDefClone copies nested accepted values list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var source_values: std.ArrayList([]const u8) = .empty;
    defer source_values.deinit(allocator);
    try source_values.append(allocator, "placed");
    try source_values.append(allocator, "returned");

    const source = GenericTestDef{
        .name = "accepted_values",
        .accepted_values = source_values,
        .relationship_to = "ref('customers')",
        .relationship_field = "id",
    };
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    var clones: std.ArrayList(GenericTestDef) = .empty;
    defer clones.deinit(allocator);

    try appendGenericTestDefClone(&graph, &clones, source);
    try source_values.append(allocator, "cancelled");

    try std.testing.expectEqual(@as(usize, 1), clones.items.len);
    try std.testing.expectEqualStrings("accepted_values", clones.items[0].name);
    try std.testing.expectEqualStrings("ref('customers')", clones.items[0].relationship_to);
    try std.testing.expectEqualStrings("id", clones.items[0].relationship_field);
    try std.testing.expectEqual(@as(usize, 2), clones.items[0].accepted_values.items.len);
    try std.testing.expectEqualStrings("placed", clones.items[0].accepted_values.items[0]);
    try std.testing.expectEqualStrings("returned", clones.items[0].accepted_values.items[1]);
}

test "parseMacrosFromText extracts top-level macro blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    const sql =
        \\{% macro format_id(column_name) %}
        \\    cast({{ column_name }} as varchar)
        \\{% endmacro %}
        \\
        \\select 1
    ;

    try parseMacrosFromText(allocator, sql, "macros/format_id.sql", "demo", &graph);

    try std.testing.expectEqual(@as(usize, 1), graph.macros.items.len);
    try std.testing.expectEqualStrings("macro.demo.format_id", graph.macros.items[0].unique_id);
    try std.testing.expectEqualStrings("demo", graph.macros.items[0].package_name);
    try std.testing.expectEqualStrings("format_id", graph.macros.items[0].name);
    try std.testing.expectEqualStrings("macros/format_id.sql", graph.macros.items[0].path);
    try std.testing.expectEqualStrings("macros/format_id.sql", graph.macros.items[0].original_file_path);
    try std.testing.expectEqualStrings(
        "{% macro format_id(column_name) %}\n    cast({{ column_name }} as varchar)\n{% endmacro %}",
        graph.macros.items[0].macro_sql,
    );
    try std.testing.expectEqual(@as(usize, 0), graph.macros.items[0].arguments.items.len);
    try std.testing.expectEqual(@as(usize, 0), graph.macros.items[0].signature_arguments.items.len);
}

test "parseMacrosFromText extracts macro signature arguments when enabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .validate_macro_args = true };
    defer graph.deinit();

    const sql =
        \\{% macro format_id(column_name, optional_suffix='', options={"suffix": ","}, typed_arg: string='x') %}
        \\    cast({{ column_name }} as varchar)
        \\{% endmacro %}
        \\
        \\{% test positive_value(model, column_name) %}
        \\    select * from {{ model }} where {{ column_name }} <= 0
        \\{% endtest %}
    ;

    try parseMacrosFromText(allocator, sql, "macros/format_id.sql", "demo", &graph);

    try std.testing.expectEqual(@as(usize, 2), graph.macros.items.len);
    try std.testing.expectEqualStrings("format_id", graph.macros.items[0].name);
    try std.testing.expectEqual(@as(usize, 4), graph.macros.items[0].signature_arguments.items.len);
    try std.testing.expectEqualStrings("column_name", graph.macros.items[0].signature_arguments.items[0].name);
    try std.testing.expectEqualStrings("optional_suffix", graph.macros.items[0].signature_arguments.items[1].name);
    try std.testing.expectEqualStrings("options", graph.macros.items[0].signature_arguments.items[2].name);
    try std.testing.expectEqualStrings("typed_arg", graph.macros.items[0].signature_arguments.items[3].name);
    try std.testing.expectEqual(@as(usize, 4), graph.macros.items[0].arguments.items.len);
    try std.testing.expectEqualStrings("column_name", graph.macros.items[0].arguments.items[0].name);
    try std.testing.expectEqualStrings("test_positive_value", graph.macros.items[1].name);
    try std.testing.expectEqual(@as(usize, 2), graph.macros.items[1].arguments.items.len);
    try std.testing.expectEqualStrings("model", graph.macros.items[1].arguments.items[0].name);
    try std.testing.expectEqualStrings("column_name", graph.macros.items[1].arguments.items[1].name);
}

test "parseMacrosFromText extracts dbt macro block variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    const sql =
        \\{% test positive_value(model, column_name) %}
        \\    select * from {{ model }} where {{ column_name }} <= 0
        \\{% endtest %}
        \\
        \\{% data_test nonzero(model, column_name) %}
        \\    select * from {{ model }} where {{ column_name }} = 0
        \\{% enddata_test %}
        \\
        \\{% materialization table %}
        \\    {{ return({'relations': []}) }}
        \\{% endmaterialization %}
        \\
        \\{% materialization incremental, supported_languages=['sql'], adapter='duckdb' %}
        \\    {{ return({'relations': []}) }}
        \\{% endmaterialization %}
        \\
        \\{% materialization empty_langs, default, supported_languages=[] %}
        \\    {{ return({'relations': []}) }}
        \\{% endmaterialization %}
        \\
        \\{% materialization tuple_langs, supported_languages=('sql',), default %}
        \\    {{ return({'relations': []}) }}
        \\{% endmaterialization %}
    ;

    try parseMacrosFromText(allocator, sql, "macros/blocks.sql", "demo", &graph);

    try std.testing.expectEqual(@as(usize, 6), graph.macros.items.len);
    try std.testing.expectEqualStrings("macro.demo.test_positive_value", graph.macros.items[0].unique_id);
    try std.testing.expectEqualStrings("test_positive_value", graph.macros.items[0].name);
    try std.testing.expectEqualStrings("macro.demo.test_nonzero", graph.macros.items[1].unique_id);
    try std.testing.expectEqualStrings("test_nonzero", graph.macros.items[1].name);
    try std.testing.expectEqualStrings("macro.demo.materialization_table_default", graph.macros.items[2].unique_id);
    try std.testing.expectEqualStrings("materialization_table_default", graph.macros.items[2].name);
    try std.testing.expectEqual(@as(usize, 1), graph.macros.items[2].supported_languages.items.len);
    try std.testing.expectEqualStrings("sql", graph.macros.items[2].supported_languages.items[0]);
    try std.testing.expect(graph.macros.items[2].has_supported_languages);
    try std.testing.expectEqualStrings("macro.demo.materialization_incremental_duckdb", graph.macros.items[3].unique_id);
    try std.testing.expectEqualStrings("materialization_incremental_duckdb", graph.macros.items[3].name);
    try std.testing.expectEqual(@as(usize, 1), graph.macros.items[3].supported_languages.items.len);
    try std.testing.expectEqualStrings("sql", graph.macros.items[3].supported_languages.items[0]);
    try std.testing.expect(graph.macros.items[3].has_supported_languages);
    try std.testing.expectEqualStrings("macro.demo.materialization_empty_langs_default", graph.macros.items[4].unique_id);
    try std.testing.expectEqualStrings("materialization_empty_langs_default", graph.macros.items[4].name);
    try std.testing.expectEqual(@as(usize, 0), graph.macros.items[4].supported_languages.items.len);
    try std.testing.expect(graph.macros.items[4].has_supported_languages);
    try std.testing.expectEqualStrings("macro.demo.materialization_tuple_langs_default", graph.macros.items[5].unique_id);
    try std.testing.expectEqualStrings("materialization_tuple_langs_default", graph.macros.items[5].name);
    try std.testing.expectEqual(@as(usize, 1), graph.macros.items[5].supported_languages.items.len);
    try std.testing.expectEqualStrings("sql", graph.macros.items[5].supported_languages.items[0]);
    try std.testing.expect(graph.macros.items[5].has_supported_languages);
}

test "parseMacrosFromText rejects mismatched macro block end tags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try std.testing.expectError(
        error.MalformedMacroBlock,
        parseMacrosFromText(
            allocator,
            "{% materialization table, default %}select 1{% endmacro %}",
            "macros/broken.sql",
            "demo",
            &graph,
        ),
    );
    try std.testing.expectError(
        error.MalformedMacroBlock,
        parseMacrosFromText(
            allocator,
            "{% test positive_value(model, column_name) %}select 1{% endmacro %}",
            "macros/broken.sql",
            "demo",
            &graph,
        ),
    );
}

test "parseMacrosFromText rejects unsupported materialization languages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try std.testing.expectError(
        error.MalformedMacroBlock,
        parseMacrosFromText(
            allocator,
            "{% materialization table, supported_languages=['r'] %}select 1{% endmaterialization %}",
            "macros/broken.sql",
            "demo",
            &graph,
        ),
    );
    try std.testing.expectError(
        error.MalformedMacroBlock,
        parseMacrosFromText(
            allocator,
            "{% materialization table, supported_languages=['SQL'] %}select 1{% endmaterialization %}",
            "macros/broken.sql",
            "demo",
            &graph,
        ),
    );
    try std.testing.expectError(
        error.MalformedMacroBlock,
        parseMacrosFromText(
            allocator,
            "{% materialization table, supported_languages=('sql') %}select 1{% endmaterialization %}",
            "macros/broken.sql",
            "demo",
            &graph,
        ),
    );
    try std.testing.expectError(
        error.MalformedMacroBlock,
        parseMacrosFromText(
            allocator,
            "{% materialization table, adapter=duckdb %}select 1{% endmaterialization %}",
            "macros/broken.sql",
            "demo",
            &graph,
        ),
    );
}

test "parseMacrosFromText ignores Jinja comments and raw blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    const sql =
        \\{# {% materialization ignored, default %}
        \\    select 1
        \\{% endmaterialization %} #}
        \\{% raw %}
        \\{% test also_ignored(model) %}
        \\    select 1
        \\{% endtest %}
        \\{% endraw %}
        \\{% raw %}
        \\{% macro broken(
        \\{% endraw %}
        \\{{ "{% macro also_ignored() %}{% endmacro %}" }}
        \\{% macro actual() %}
        \\    select 1
        \\{% endmacro %}
    ;

    try parseMacrosFromText(allocator, sql, "macros/comments.sql", "demo", &graph);

    try std.testing.expectEqual(@as(usize, 1), graph.macros.items.len);
    try std.testing.expectEqualStrings("macro.demo.actual", graph.macros.items[0].unique_id);
    try std.testing.expectEqualStrings("actual", graph.macros.items[0].name);
}

test "parseMacrosFromText ignores end tags inside comments raw blocks and expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    const sql =
        \\{% materialization table, default %}
        \\    {# {% endmaterialization %} #}
        \\    {% raw %}{% endmaterialization %}{% endraw %}
        \\    {{ "{% endmaterialization %}" }}
        \\    select 1
        \\{% endmaterialization %}
        \\{% macro after() %}select 2{% endmacro %}
    ;

    try parseMacrosFromText(allocator, sql, "macros/end_tags.sql", "demo", &graph);

    try std.testing.expectEqual(@as(usize, 2), graph.macros.items.len);
    try std.testing.expectEqualStrings("macro.demo.materialization_table_default", graph.macros.items[0].unique_id);
    try std.testing.expectEqualStrings(
        \\{% materialization table, default %}
        \\    {# {% endmaterialization %} #}
        \\    {% raw %}{% endmaterialization %}{% endraw %}
        \\    {{ "{% endmaterialization %}" }}
        \\    select 1
        \\{% endmaterialization %}
    ,
        graph.macros.items[0].macro_sql,
    );
    try std.testing.expectEqualStrings("macro.demo.after", graph.macros.items[1].unique_id);
}

test "parseMacrosFromText rejects blocks nested under top-level control flow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try std.testing.expectError(
        error.MalformedMacroBlock,
        parseMacrosFromText(
            allocator,
            "{% if execute %}{% test positive_value(model) %}select 1{% endtest %}{% endif %}",
            "macros/nested.sql",
            "demo",
            &graph,
        ),
    );
    try std.testing.expectError(
        error.MalformedMacroBlock,
        parseMacrosFromText(
            allocator,
            "{% for item in items %}{% macro nested() %}select 1{% endmacro %}{% endfor %}",
            "macros/nested.sql",
            "demo",
            &graph,
        ),
    );
}

test "parseMacrosFromText ignores non-macro blocks and rejects malformed macros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try parseMacrosFromText(
        allocator,
        "{% if execute %}{{ log('skip') }}{% endif %}\n{% set value = 1 %}",
        "macros/no_macros.sql",
        "demo",
        &graph,
    );
    try std.testing.expectEqual(@as(usize, 0), graph.macros.items.len);

    try std.testing.expectError(
        error.MalformedMacroBlock,
        parseMacrosFromText(allocator, "{% macro broken(column_name) %}", "macros/broken.sql", "demo", &graph),
    );
}

test "parseMacroPropertiesFromText records descriptions and arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    const yaml =
        \\version: 2
        \\macros:
        \\  - name: format_id
        \\    description: Format an identifier expression.
        \\    docs:
        \\      show: false
        \\      node_color: "#336699"
        \\    meta:
        \\      owner: analytics
        \\      audited: true
        \\      priority: 2
        \\    arguments:
        \\      - name: column_name
        \\        type: string
        \\        description: Identifier expression.
        \\      - name: quote
        \\        type: bool
        \\  - name: reset_color
        \\    docs:
        \\      node_color: null
        \\
        \\models:
        \\  - name: ignored
    ;

    try parseMacroPropertiesFromText(allocator, yaml, "macros/schema.yml", "demo", &graph);

    try std.testing.expectEqual(@as(usize, 2), graph.macro_properties.items.len);
    try std.testing.expectEqualStrings("demo", graph.macro_properties.items[0].package_name);
    try std.testing.expectEqualStrings("format_id", graph.macro_properties.items[0].name);
    try std.testing.expectEqualStrings("macros/schema.yml", graph.macro_properties.items[0].patch_path);
    try std.testing.expectEqualStrings("Format an identifier expression.", graph.macro_properties.items[0].description);
    try std.testing.expect(graph.macro_properties.items[0].docs.configured);
    try std.testing.expect(!graph.macro_properties.items[0].docs.show);
    try std.testing.expectEqualStrings("#336699", graph.macro_properties.items[0].docs.node_color.?);
    try std.testing.expectEqual(@as(usize, 3), graph.macro_properties.items[0].meta.items.len);
    try std.testing.expectEqualStrings("audited", graph.macro_properties.items[0].meta.items[0].key);
    try std.testing.expectEqualStrings("true", graph.macro_properties.items[0].meta.items[0].value.text);
    try std.testing.expectEqual(.bool, graph.macro_properties.items[0].meta.items[0].value.kind);
    try std.testing.expectEqualStrings("owner", graph.macro_properties.items[0].meta.items[1].key);
    try std.testing.expectEqualStrings("analytics", graph.macro_properties.items[0].meta.items[1].value.text);
    try std.testing.expectEqual(.string, graph.macro_properties.items[0].meta.items[1].value.kind);
    try std.testing.expectEqualStrings("priority", graph.macro_properties.items[0].meta.items[2].key);
    try std.testing.expectEqualStrings("2", graph.macro_properties.items[0].meta.items[2].value.text);
    try std.testing.expectEqual(.number, graph.macro_properties.items[0].meta.items[2].value.kind);
    try std.testing.expectEqual(@as(usize, 2), graph.macro_properties.items[0].arguments.items.len);
    try std.testing.expectEqualStrings("column_name", graph.macro_properties.items[0].arguments.items[0].name);
    try std.testing.expectEqualStrings("string", graph.macro_properties.items[0].arguments.items[0].type);
    try std.testing.expectEqualStrings("Identifier expression.", graph.macro_properties.items[0].arguments.items[0].description);
    try std.testing.expectEqualStrings("quote", graph.macro_properties.items[0].arguments.items[1].name);
    try std.testing.expectEqualStrings("bool", graph.macro_properties.items[0].arguments.items[1].type);
    try std.testing.expectEqualStrings("reset_color", graph.macro_properties.items[1].name);
    try std.testing.expect(graph.macro_properties.items[1].docs.configured);
    try std.testing.expect(graph.macro_properties.items[1].docs.node_color == null);
}

test "parseMacroPropertiesFromText rejects nested macro meta" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    const yaml =
        \\version: 2
        \\macros:
        \\  - name: format_id
        \\    meta:
        \\      owner:
        \\        team: analytics
    ;

    try std.testing.expectError(
        error.UnsupportedYaml,
        parseMacroPropertiesFromText(allocator, yaml, "macros/schema.yml", "demo", &graph),
    );
}

test "applyMacroProperties applies descriptions patch paths and replaces arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.macros.append(allocator, .{
        .unique_id = "macro.demo.format_id",
        .package_name = "demo",
        .name = "format_id",
        .path = "macros/format_id.sql",
        .original_file_path = "macros/format_id.sql",
        .macro_sql = "",
    });
    try graph.macro_properties.append(allocator, .{
        .package_name = "demo",
        .name = "format_id",
        .patch_path = "macros/schema.yml",
        .description = "Formats an identifier.",
    });
    graph.macro_properties.items[0].docs.configured = true;
    graph.macro_properties.items[0].docs.show = false;
    graph.macro_properties.items[0].docs.node_color = "#336699";
    try appendMetaEntry(allocator, &graph.macro_properties.items[0].meta, "owner", .{ .text = "analytics", .kind = .string });
    try appendMetaEntry(allocator, &graph.macro_properties.items[0].meta, "priority", .{ .text = "2", .kind = .number });
    try graph.macro_properties.items[0].arguments.append(allocator, .{
        .name = "column_name",
        .type = "",
        .description = "Identifier expression.",
    });
    try graph.macro_properties.items[0].arguments.append(allocator, .{
        .name = "quote",
        .type = "bool",
        .description = "Whether to quote.",
    });

    try applyMacroProperties(&graph);

    try std.testing.expectEqualStrings("macros/schema.yml", graph.macros.items[0].patch_path.?);
    try std.testing.expectEqualStrings("Formats an identifier.", graph.macros.items[0].description);
    try std.testing.expect(graph.macros.items[0].docs.configured);
    try std.testing.expect(!graph.macros.items[0].docs.show);
    try std.testing.expectEqualStrings("#336699", graph.macros.items[0].docs.node_color.?);
    try std.testing.expectEqual(@as(usize, 2), graph.macros.items[0].meta.items.len);
    try std.testing.expectEqualStrings("owner", graph.macros.items[0].meta.items[0].key);
    try std.testing.expectEqualStrings("analytics", graph.macros.items[0].meta.items[0].value.text);
    try std.testing.expectEqualStrings("priority", graph.macros.items[0].meta.items[1].key);
    try std.testing.expectEqualStrings("2", graph.macros.items[0].meta.items[1].value.text);
    try std.testing.expectEqual(@as(usize, 2), graph.macros.items[0].arguments.items.len);
    try std.testing.expectEqualStrings("column_name", graph.macros.items[0].arguments.items[0].name);
    try std.testing.expectEqualStrings("", graph.macros.items[0].arguments.items[0].type);
    try std.testing.expectEqualStrings("Identifier expression.", graph.macros.items[0].arguments.items[0].description);
    try std.testing.expectEqualStrings("quote", graph.macros.items[0].arguments.items[1].name);
    try std.testing.expectEqualStrings("bool", graph.macros.items[0].arguments.items[1].type);
}

test "applyMacroProperties validates macro patch arguments when enabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .validate_macro_args = true };
    defer graph.deinit();

    try graph.macros.append(allocator, .{
        .unique_id = "macro.demo.format_id",
        .package_name = "demo",
        .name = "format_id",
        .path = "macros/format_id.sql",
        .original_file_path = "macros/format_id.sql",
        .macro_sql = "",
    });
    try graph.macros.items[0].signature_arguments.append(allocator, .{ .name = "column_name" });
    try graph.macros.items[0].signature_arguments.append(allocator, .{ .name = "quote" });
    try graph.macros.items[0].arguments.append(allocator, .{ .name = "column_name" });
    try graph.macros.items[0].arguments.append(allocator, .{ .name = "quote" });

    try graph.macro_properties.append(allocator, .{
        .package_name = "demo",
        .name = "format_id",
        .patch_path = "macros/schema.yml",
    });
    try graph.macro_properties.items[0].arguments.append(allocator, .{
        .name = "column_name",
        .type = "string",
        .description = "Column expression.",
    });
    try graph.macro_properties.items[0].arguments.append(allocator, .{
        .name = "bad_name",
        .type = "list",
        .description = "Bad argument.",
    });
    try graph.macro_properties.items[0].arguments.append(allocator, .{
        .name = "extra_arg",
        .type = "optional[string]",
        .description = "Extra argument.",
    });

    try applyMacroProperties(&graph);

    try std.testing.expectEqual(@as(usize, 3), graph.macros.items[0].arguments.items.len);
    try std.testing.expectEqualStrings("column_name", graph.macros.items[0].arguments.items[0].name);
    try std.testing.expectEqualStrings("string", graph.macros.items[0].arguments.items[0].type);
    try std.testing.expectEqualStrings("bad_name", graph.macros.items[0].arguments.items[1].name);
    try std.testing.expectEqualStrings("extra_arg", graph.macros.items[0].arguments.items[2].name);
    try std.testing.expectEqual(@as(usize, 3), graph.macro_argument_warnings.items.len);
    try std.testing.expectEqualStrings(
        "Argument bad_name in yaml for macro format_id does not match the jinja definition.",
        graph.macro_argument_warnings.items[0],
    );
    try std.testing.expectEqualStrings(
        "The number of arguments in the yaml for macro format_id does not match the jinja definition.",
        graph.macro_argument_warnings.items[1],
    );
    try std.testing.expectEqualStrings(
        "Argument bad_name in the yaml for macro format_id has an invalid type.",
        graph.macro_argument_warnings.items[2],
    );
}

test "applyMacroProperties keeps signature arguments without YAML arguments when validation enabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .validate_macro_args = true };
    defer graph.deinit();

    try graph.macros.append(allocator, .{
        .unique_id = "macro.demo.format_id",
        .package_name = "demo",
        .name = "format_id",
        .path = "macros/format_id.sql",
        .original_file_path = "macros/format_id.sql",
        .macro_sql = "",
    });
    try graph.macros.items[0].signature_arguments.append(allocator, .{ .name = "column_name" });
    try graph.macros.items[0].arguments.append(allocator, .{ .name = "column_name" });
    try graph.macro_properties.append(allocator, .{
        .package_name = "demo",
        .name = "format_id",
        .patch_path = "macros/schema.yml",
        .description = "Formats an identifier.",
    });

    try applyMacroProperties(&graph);

    try std.testing.expectEqualStrings("Formats an identifier.", graph.macros.items[0].description);
    try std.testing.expectEqual(@as(usize, 1), graph.macros.items[0].arguments.items.len);
    try std.testing.expectEqualStrings("column_name", graph.macros.items[0].arguments.items[0].name);
    try std.testing.expectEqual(@as(usize, 0), graph.macro_argument_warnings.items.len);
}

test "isValidMacroArgumentType follows dbt Core macro annotation types" {
    try std.testing.expect(isValidMacroArgumentType("string"));
    try std.testing.expect(isValidMacroArgumentType("list[string]"));
    try std.testing.expect(isValidMacroArgumentType("dict[string, optional[int]]"));
    try std.testing.expect(isValidMacroArgumentType("optional[relation]"));
    try std.testing.expect(!isValidMacroArgumentType("list"));
    try std.testing.expect(!isValidMacroArgumentType("dict[string]"));
    try std.testing.expect(!isValidMacroArgumentType("boolean"));
    try std.testing.expect(!isValidMacroArgumentType("string | int"));
}

test "applyMacroProperties records unmatched macro properties" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.macro_properties.append(allocator, .{
        .package_name = "demo",
        .name = "missing_macro",
        .patch_path = "macros/schema.yml",
    });

    try applyMacroProperties(&graph);

    try std.testing.expectEqual(@as(usize, 1), graph.unmatched_macro_properties.items.len);
    try std.testing.expectEqualStrings("missing_macro", graph.unmatched_macro_properties.items[0].name);
    try std.testing.expectEqualStrings("macros/schema.yml", graph.unmatched_macro_properties.items[0].patch_path);
}

test "refDepFromValue parses relationship target refs and raw model names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const raw = try refDepFromValue(allocator, " customers ");
    try std.testing.expect(raw.package == null);
    try std.testing.expectEqualStrings("customers", raw.name);

    const local_ref = try refDepFromValue(allocator, "ref('orders')");
    try std.testing.expect(local_ref.package == null);
    try std.testing.expectEqualStrings("orders", local_ref.name);

    const package_ref = try refDepFromValue(allocator, " ref(\"pkg\", 'orders') ");
    try std.testing.expectEqualStrings("pkg", package_ref.package.?);
    try std.testing.expectEqualStrings("orders", package_ref.name);
}

test "refDepFromValue rejects unsupported dynamic or malformed refs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.UnsupportedRef, refDepFromValue(allocator, "ref(var('model'))"));
    try std.testing.expectError(error.UnsupportedRef, refDepFromValue(allocator, "ref('pkg', 'orders', 'extra')"));
    try std.testing.expectError(error.UnsupportedRef, refDepFromValue(allocator, "ref('orders'"));
}

test "parseExposureDependency records ref and source dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var exposure = ExposureDef{
        .package_name = "demo",
        .unique_id = "exposure.demo.weekly_kpis",
        .name = "weekly_kpis",
        .path = "models/schema.yml",
        .original_file_path = "models/schema.yml",
    };
    defer {
        exposure.refs.deinit(allocator);
        exposure.source_refs.deinit(allocator);
    }

    try parseExposureDependency(allocator, " ref('orders') ", &exposure);
    try parseExposureDependency(allocator, "ref(\"pkg\", 'customers')", &exposure);
    try parseExposureDependency(allocator, "source('raw', \"payments\")", &exposure);

    try std.testing.expectEqual(@as(usize, 2), exposure.refs.items.len);
    try std.testing.expect(exposure.refs.items[0].package == null);
    try std.testing.expectEqualStrings("orders", exposure.refs.items[0].name);
    try std.testing.expectEqualStrings("pkg", exposure.refs.items[1].package.?);
    try std.testing.expectEqualStrings("customers", exposure.refs.items[1].name);
    try std.testing.expectEqual(@as(usize, 1), exposure.source_refs.items.len);
    try std.testing.expectEqualStrings("raw", exposure.source_refs.items[0].source_name);
    try std.testing.expectEqualStrings("payments", exposure.source_refs.items[0].table_name);
}

test "parseExposureDependency rejects unsupported dependency forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var exposure = ExposureDef{
        .package_name = "demo",
        .unique_id = "exposure.demo.weekly_kpis",
        .name = "weekly_kpis",
        .path = "models/schema.yml",
        .original_file_path = "models/schema.yml",
    };
    defer {
        exposure.refs.deinit(allocator);
        exposure.source_refs.deinit(allocator);
    }

    try std.testing.expectError(error.UnsupportedDynamicRef, parseExposureDependency(allocator, "ref(var('model'))", &exposure));
    try std.testing.expectError(error.UnsupportedDynamicRef, parseExposureDependency(allocator, "ref('pkg', 'orders', 'extra')", &exposure));
    try std.testing.expectError(error.UnsupportedDynamicSource, parseExposureDependency(allocator, "source('raw')", &exposure));
    try std.testing.expectError(error.UnsupportedYaml, parseExposureDependency(allocator, "metric('orders')", &exposure));
}

test "parseSourcesFromText records source tables with package IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    const yaml =
        \\version: 2
        \\sources:
        \\  - name: raw
        \\    tables:
        \\      - name: orders
        \\      - name: payments
        \\  - name: app
        \\    tables:
        \\      - name: users
    ;

    try parseSourcesFromText(allocator, yaml, "models/schema.yml", "pkg", &graph);

    try std.testing.expectEqual(@as(usize, 3), graph.sources.items.len);
    try std.testing.expectEqualStrings("source.pkg.raw.orders", graph.sources.items[0].unique_id);
    try std.testing.expectEqualStrings("raw", graph.sources.items[0].source_name);
    try std.testing.expectEqualStrings("orders", graph.sources.items[0].table_name);
    try std.testing.expect(graph.sources.items[0].identifier == null);
    try std.testing.expectEqualStrings("source.pkg.raw.payments", graph.sources.items[1].unique_id);
    try std.testing.expectEqualStrings("source.pkg.app.users", graph.sources.items[2].unique_id);
    try std.testing.expectEqualStrings("models/schema.yml", graph.sources.items[2].original_file_path);
}

test "parseSourcesFromText records source table identifier without changing logical name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    const yaml =
        \\version: 2
        \\sources:
        \\  - name: raw
        \\    tables:
        \\      - name: customers
        \\        identifier: raw_customers
    ;

    try parseSourcesFromText(allocator, yaml, "models/schema.yml", "pkg", &graph);

    try std.testing.expectEqual(@as(usize, 1), graph.sources.items.len);
    try std.testing.expectEqualStrings("source.pkg.raw.customers", graph.sources.items[0].unique_id);
    try std.testing.expectEqualStrings("customers", graph.sources.items[0].table_name);
    try std.testing.expectEqualStrings("raw_customers", graph.sources.items[0].identifier.?);
}

test "parseSourcesFromText records table-level source freshness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    const yaml =
        \\version: 2
        \\sources:
        \\  - name: raw
        \\    tables:
        \\      - name: customers
        \\        loaded_at_field: loaded_at
        \\        freshness:
        \\          warn_after:
        \\            count: 12
        \\            period: hour
        \\          error_after:
        \\            count: 1
        \\            period: day
        \\          filter: customer_id > 0
        \\      - name: orders
        \\        loaded_at_query: select max(loaded_at) from raw.orders
        \\        freshness:
        \\          warn_after:
        \\            count: 3
        \\            period: hour
    ;

    try parseSourcesFromText(allocator, yaml, "models/schema.yml", "demo", &graph);

    try std.testing.expectEqual(@as(usize, 2), graph.sources.items.len);
    const customers = graph.sources.items[0];
    try std.testing.expectEqualStrings("loaded_at", customers.loaded_at_field.?);
    const freshness = customers.freshness.?;
    try std.testing.expectEqual(@as(u64, 12), freshness.warn_after.?.count.?);
    try std.testing.expectEqualStrings("hour", freshness.warn_after.?.period.?);
    try std.testing.expectEqual(@as(u64, 1), freshness.error_after.?.count.?);
    try std.testing.expectEqualStrings("day", freshness.error_after.?.period.?);
    try std.testing.expectEqualStrings("customer_id > 0", freshness.filter.?);
    try std.testing.expect(graph.sources.items[1].loaded_at_field == null);
    try std.testing.expectEqualStrings("select max(loaded_at) from raw.orders", graph.sources.items[1].loaded_at_query.?);
    try std.testing.expectEqual(@as(u64, 3), graph.sources.items[1].freshness.?.warn_after.?.count.?);
}

test "parseSourcesFromText applies source config defaults and table overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();

    const yaml =
        \\version: 2
        \\sources:
        \\  - name: raw
        \\    schema: "{{ target.schema }}_raw"
        \\    config:
        \\      loaded_at_field: loaded_at
        \\      freshness:
        \\        warn_after:
        \\          count: 12
        \\          period: hour
        \\        error_after:
        \\          count: 1
        \\          period: day
        \\        filter: id > 0
        \\    tables:
        \\      - name: inherited
        \\      - name: query_override
        \\        config:
        \\          loaded_at_query: select max(loaded_at) from raw.query_override
        \\      - name: threshold_override
        \\        freshness:
        \\          warn_after:
        \\            count: 3
        \\      - name: disabled_freshness
        \\        freshness: null
    ;

    try parseSourcesFromText(allocator, yaml, "models/schema.yml", "demo", &graph);

    try std.testing.expectEqual(@as(usize, 4), graph.sources.items.len);
    const inherited = graph.sources.items[0];
    try std.testing.expectEqualStrings("analytics_raw", inherited.schema_name.?);
    try std.testing.expectEqualStrings("loaded_at", inherited.loaded_at_field.?);
    try std.testing.expect(inherited.loaded_at_query == null);
    try std.testing.expectEqual(@as(u64, 12), inherited.freshness.?.warn_after.?.count.?);
    try std.testing.expectEqualStrings("hour", inherited.freshness.?.warn_after.?.period.?);
    try std.testing.expectEqual(@as(u64, 1), inherited.freshness.?.error_after.?.count.?);
    try std.testing.expectEqualStrings("id > 0", inherited.freshness.?.filter.?);

    const query_override = graph.sources.items[1];
    try std.testing.expectEqualStrings("loaded_at", query_override.loaded_at_field.?);
    try std.testing.expectEqualStrings("select max(loaded_at) from raw.query_override", query_override.loaded_at_query.?);
    try std.testing.expectEqual(@as(u64, 12), query_override.freshness.?.warn_after.?.count.?);

    const threshold_override = graph.sources.items[2];
    try std.testing.expectEqualStrings("loaded_at", threshold_override.loaded_at_field.?);
    try std.testing.expectEqual(@as(u64, 12), threshold_override.freshness.?.warn_after.?.count.?);
    try std.testing.expectEqualStrings("hour", threshold_override.freshness.?.warn_after.?.period.?);
    try std.testing.expectEqual(@as(u64, 1), threshold_override.freshness.?.error_after.?.count.?);

    const disabled_freshness = graph.sources.items[3];
    try std.testing.expectEqualStrings("loaded_at", disabled_freshness.loaded_at_field.?);
    try std.testing.expect(disabled_freshness.freshness == null);
}

test "parseSourcesFromText rejects same-layer source loaded_at conflicts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const yaml =
        \\version: 2
        \\sources:
        \\  - name: raw
        \\    loaded_at_field: loaded_at
        \\    config:
        \\      loaded_at_query: select max(loaded_at) from raw.orders
        \\    tables:
        \\      - name: orders
    ;

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try std.testing.expectError(error.UnsupportedYaml, parseSourcesFromText(allocator, yaml, "models/schema.yml", "demo", &graph));

    const inverse_yaml =
        \\version: 2
        \\sources:
        \\  - name: raw
        \\    loaded_at_query: select max(loaded_at) from raw.orders
        \\    config:
        \\      loaded_at_field: loaded_at
        \\    tables:
        \\      - name: orders
    ;

    var inverse_graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer inverse_graph.deinit();
    try std.testing.expectError(error.UnsupportedYaml, parseSourcesFromText(allocator, inverse_yaml, "models/schema.yml", "demo", &inverse_graph));
}

test "parseSourcesFromText rejects same-layer table loaded_at conflicts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const yaml =
        \\version: 2
        \\sources:
        \\  - name: raw
        \\    tables:
        \\      - name: orders
        \\        loaded_at_field: loaded_at
        \\        config:
        \\          loaded_at_query: select max(loaded_at) from raw.orders
    ;

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try std.testing.expectError(error.UnsupportedYaml, parseSourcesFromText(allocator, yaml, "models/schema.yml", "demo", &graph));

    const inverse_yaml =
        \\version: 2
        \\sources:
        \\  - name: raw
        \\    tables:
        \\      - name: orders
        \\        loaded_at_query: select max(loaded_at) from raw.orders
        \\        config:
        \\          loaded_at_field: loaded_at
    ;

    var inverse_graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer inverse_graph.deinit();
    try std.testing.expectError(error.UnsupportedYaml, parseSourcesFromText(allocator, inverse_yaml, "models/schema.yml", "demo", &inverse_graph));
}

test "parseSourcesFromText records source column generic tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    const yaml =
        \\version: 2
        \\sources:
        \\  - name: raw
        \\    tables:
        \\      - name: customers
        \\        columns:
        \\          - name: customer_id
        \\            tests: [not_null, unique]
        \\          - name: customer_type
        \\            data_tests:
        \\              - accepted_values:
        \\                  values:
        \\                    - new
        \\                    - returning
        \\                  quote: false
        \\          - name: parent_customer_id
        \\            tests:
        \\              - relationships:
        \\                  arguments:
        \\                    to: ref('customers')
        \\                    field: customer_id
    ;

    try parseSourcesFromText(allocator, yaml, "models/schema.yml", "demo", &graph);

    try std.testing.expectEqual(@as(usize, 1), graph.sources.items.len);
    const source = graph.sources.items[0];
    try std.testing.expectEqual(@as(usize, 3), source.columns.items.len);
    try std.testing.expectEqualStrings("customer_id", source.columns.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), source.columns.items[0].tests.items.len);
    try std.testing.expectEqualStrings("not_null", source.columns.items[0].tests.items[0].name);
    try std.testing.expectEqualStrings("unique", source.columns.items[0].tests.items[1].name);
    try std.testing.expectEqualStrings("customer_type", source.columns.items[1].name);
    try std.testing.expectEqual(@as(usize, 1), source.columns.items[1].tests.items.len);
    const accepted = source.columns.items[1].tests.items[0];
    try std.testing.expectEqualStrings("accepted_values", accepted.name);
    try std.testing.expectEqual(@as(usize, 2), accepted.accepted_values.items.len);
    try std.testing.expectEqualStrings("new", accepted.accepted_values.items[0]);
    try std.testing.expectEqualStrings("returning", accepted.accepted_values.items[1]);
    try std.testing.expectEqual(false, accepted.accepted_values_quote.?);
    try std.testing.expectEqualStrings("parent_customer_id", source.columns.items[2].name);
    try std.testing.expectEqual(@as(usize, 1), source.columns.items[2].tests.items.len);
    const relationships = source.columns.items[2].tests.items[0];
    try std.testing.expectEqualStrings("relationships", relationships.name);
    try std.testing.expectEqualStrings("ref('customers')", relationships.relationship_to);
    try std.testing.expectEqualStrings("customer_id", relationships.relationship_field);
}

test "parseSourcesFromText records table-level source generic test column_name arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    const yaml =
        \\version: 2
        \\sources:
        \\  - name: raw
        \\    tables:
        \\      - name: customers
        \\        tests:
        \\          - not_null:
        \\              arguments:
        \\                column_name: customer_id
        \\          - accepted_values:
        \\              arguments:
        \\                column_name: customer_type
        \\                values:
        \\                  - new
        \\                  - returning
        \\                quote: false
        \\        columns:
        \\          - name: customer_id
        \\            description: customer id
    ;

    try parseSourcesFromText(allocator, yaml, "models/schema.yml", "demo", &graph);

    try std.testing.expectEqual(@as(usize, 1), graph.sources.items.len);
    const source = graph.sources.items[0];
    try std.testing.expectEqual(@as(usize, 2), source.tests.items.len);
    try std.testing.expectEqualStrings("not_null", source.tests.items[0].name);
    try std.testing.expectEqualStrings("customer_id", source.tests.items[0].column_name.?);
    try std.testing.expectEqualStrings("accepted_values", source.tests.items[1].name);
    try std.testing.expectEqualStrings("customer_type", source.tests.items[1].column_name.?);
    try std.testing.expectEqual(@as(usize, 2), source.tests.items[1].accepted_values.items.len);
    try std.testing.expectEqual(false, source.tests.items[1].accepted_values_quote.?);
    try std.testing.expectEqual(@as(usize, 1), source.columns.items.len);
}

test "parseUnitTestsFromText records dict fixtures and config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    const yaml =
        \\unit_tests:
        \\  - name: assert_order_flags
        \\    description: verifies item flags
        \\    model: orders
        \\    config:
        \\      tags: [unit, marts]
        \\    given:
        \\      - input: ref('order_items')
        \\        rows:
        \\          - {order_id: 1, is_food_item: true, item_count: 2}
        \\          - {
        \\              order_id: 2,
        \\              is_food_item: false,
        \\              item_count: 0,
        \\            }
        \\    expect:
        \\      rows:
        \\        - {order_id: 1, has_food: true}
        \\        - {order_id: 2, has_food: false}
        \\
    ;

    try parseUnitTestsFromText(allocator, yaml, "models", "models/schema.yml", "demo", &graph);

    try std.testing.expectEqual(@as(usize, 1), graph.unit_tests.items.len);
    const unit_test = graph.unit_tests.items[0];
    try std.testing.expectEqualStrings("unit_test.demo.orders.assert_order_flags", unit_test.unique_id);
    try std.testing.expectEqualStrings("orders", unit_test.model);
    try std.testing.expectEqualStrings("schema.yml", unit_test.path);
    try std.testing.expectEqualStrings("verifies item flags", unit_test.description);
    try std.testing.expectEqual(@as(usize, 2), unit_test.tags.items.len);
    try std.testing.expectEqualStrings("marts", unit_test.tags.items[0]);
    try std.testing.expectEqualStrings("unit", unit_test.tags.items[1]);
    try std.testing.expectEqual(@as(usize, 1), unit_test.given.items.len);
    try std.testing.expectEqualStrings("ref('order_items')", unit_test.given.items[0].input.?);
    try std.testing.expectEqual(@as(usize, 2), unit_test.given.items[0].rows.items.len);
    try std.testing.expectEqualStrings("order_id", unit_test.given.items[0].rows.items[0].entries.items[0].key);
    try std.testing.expectEqualStrings("1", unit_test.given.items[0].rows.items[0].entries.items[0].value.text);
    try std.testing.expectEqual(.number, unit_test.given.items[0].rows.items[0].entries.items[0].value.kind);
    try std.testing.expectEqualStrings("false", unit_test.given.items[0].rows.items[1].entries.items[1].value.text);
    try std.testing.expectEqual(.bool, unit_test.given.items[0].rows.items[1].entries.items[1].value.kind);
    try std.testing.expectEqual(@as(usize, 2), unit_test.expect.rows.items.len);
}

test "parseExposuresFromText records exposure metadata and dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    const yaml =
        \\version: 2
        \\exposures:
        \\  - name: weekly_kpis
        \\    type: dashboard
        \\    maturity: high
        \\    url: https://example.invalid/dashboard
        \\    description: Weekly KPI dashboard
        \\    tags: [finance, weekly]
        \\    depends_on:
        \\      - ref('orders')
        \\      - source('raw', 'payments')
        \\    owner:
        \\      name: Analytics
        \\      email: analytics@example.invalid
        \\    config:
        \\      enabled: false
        \\      tags: [disabled, finance]
        \\      meta:
        \\        priority: 2
        \\        pii: false
    ;

    try parseExposuresFromText(allocator, yaml, "models", "models/exposures.yml", "demo", &graph);

    try std.testing.expectEqual(@as(usize, 1), graph.exposures.items.len);
    const exposure = graph.exposures.items[0];
    try std.testing.expectEqualStrings("exposure.demo.weekly_kpis", exposure.unique_id);
    try std.testing.expectEqualStrings("weekly_kpis", exposure.name);
    try std.testing.expectEqualStrings("dashboard", exposure.exposure_type);
    try std.testing.expect(!exposure.enabled);
    try std.testing.expectEqualStrings("high", exposure.maturity.?);
    try std.testing.expectEqualStrings("https://example.invalid/dashboard", exposure.url.?);
    try std.testing.expectEqualStrings("Weekly KPI dashboard", exposure.description);
    try std.testing.expectEqualStrings("Analytics", exposure.owner_name);
    try std.testing.expectEqualStrings("analytics@example.invalid", exposure.owner_email.?);
    try std.testing.expectEqualStrings("exposures.yml", exposure.path);
    try std.testing.expectEqual(@as(usize, 4), exposure.tags.items.len);
    try std.testing.expectEqualStrings("disabled", exposure.tags.items[0]);
    try std.testing.expectEqualStrings("finance", exposure.tags.items[1]);
    try std.testing.expectEqualStrings("finance", exposure.tags.items[2]);
    try std.testing.expectEqualStrings("weekly", exposure.tags.items[3]);
    try std.testing.expectEqual(@as(usize, 1), exposure.refs.items.len);
    try std.testing.expectEqualStrings("orders", exposure.refs.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), exposure.source_refs.items.len);
    try std.testing.expectEqualStrings("raw", exposure.source_refs.items[0].source_name);
    try std.testing.expectEqualStrings("payments", exposure.source_refs.items[0].table_name);
    try std.testing.expectEqual(@as(usize, 2), exposure.meta.items.len);
    try std.testing.expectEqualStrings("pii", exposure.meta.items[0].key);
    try std.testing.expectEqualStrings("false", exposure.meta.items[0].value.text);
    try std.testing.expectEqual(.bool, exposure.meta.items[0].value.kind);
    try std.testing.expectEqualStrings("priority", exposure.meta.items[1].key);
    try std.testing.expectEqualStrings("2", exposure.meta.items[1].value.text);
    try std.testing.expectEqual(.number, exposure.meta.items[1].value.kind);
}

test "synthesizeGenericTestNames preserves short generic test identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const names = try synthesizeGenericTestNames(allocator, .{ .name = "not_null" }, "customers", "id");
    try std.testing.expectEqualStrings("not_null_customers_id", names.full);
    try std.testing.expectEqualStrings("not_null_customers_id", names.compiled);
}

test "synthesizeGenericTestNames normalizes accepted value arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(allocator);
    try values.append(allocator, "placed");
    try values.append(allocator, "shipped late");

    const names = try synthesizeGenericTestNames(allocator, .{ .name = "accepted_values", .accepted_values = values }, "orders", "status");
    try std.testing.expectEqualStrings("accepted_values_orders_status__placed__shipped_late", names.full);
    try std.testing.expectEqualStrings("accepted_values_orders_status__placed__shipped_late", names.compiled);
}

test "synthesizeGenericTestNames includes explicit accepted_values quote flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(allocator);
    try values.append(allocator, "1");
    try values.append(allocator, "2");

    const names = try synthesizeGenericTestNames(allocator, .{ .name = "accepted_values", .accepted_values = values, .accepted_values_quote = false }, "customers", "customer_id");
    try std.testing.expectEqualStrings("accepted_values_customers_customer_id__False__1__2", names.full);
    try std.testing.expectEqualStrings("accepted_values_customers_customer_id__False__1__2", names.compiled);
}

test "genericTestUniqueId keeps dbt-style hash suffix stable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_def = GenericTestDef{ .name = "not_null" };
    const unique_id = try genericTestUniqueId(allocator, "demo", "not_null_customers_id", test_def, "customers", "id");
    try std.testing.expectEqualStrings("test.demo.not_null_customers_id.422908bfae", unique_id);
}

test "genericTestUniqueId hashes explicit accepted_values quote flag like dbt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(allocator);
    try values.append(allocator, "1");
    try values.append(allocator, "2");

    const test_def = GenericTestDef{ .name = "accepted_values", .accepted_values = values, .accepted_values_quote = false };
    const unique_id = try genericTestUniqueId(allocator, "demo", "accepted_values_customers_customer_id__False__1__2", test_def, "customers", "customer_id");
    try std.testing.expectEqualStrings("test.demo.accepted_values_customers_customer_id__False__1__2.d3fda7ba1b", unique_id);
}
