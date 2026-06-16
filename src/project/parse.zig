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
const MetaEntry = types.MetaEntry;
const RefDep = types.RefDep;
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
        var macro_tag = parseMacroOpenTag(allocator, tag) catch |err| switch (err) {
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
    supported_languages: std.ArrayList([]const u8) = .empty,
    has_supported_languages: bool = false,
};

fn parseMacroOpenTag(allocator: std.mem.Allocator, tag: []const u8) !MacroOpenTag {
    if (std.mem.startsWith(u8, tag, "macro") and tag.len > "macro".len and std.ascii.isWhitespace(tag["macro".len])) {
        const name = try parseCallableBlockName(tag, "macro");
        return .{ .name = name, .end_tag = "endmacro" };
    }
    if (std.mem.startsWith(u8, tag, "test") and tag.len > "test".len and std.ascii.isWhitespace(tag["test".len])) {
        const name = try parseCallableBlockName(tag, "test");
        return .{ .name = try std.fmt.allocPrint(allocator, "test_{s}", .{name}), .end_tag = "endtest" };
    }
    if (std.mem.startsWith(u8, tag, "data_test") and tag.len > "data_test".len and std.ascii.isWhitespace(tag["data_test".len])) {
        const name = try parseCallableBlockName(tag, "data_test");
        return .{ .name = try std.fmt.allocPrint(allocator, "test_{s}", .{name}), .end_tag = "enddata_test" };
    }
    if (std.mem.startsWith(u8, tag, "materialization") and tag.len > "materialization".len and std.ascii.isWhitespace(tag["materialization".len])) {
        return try parseMaterializationOpenTag(allocator, tag);
    }
    return error.NotMacroBlock;
}

fn parseCallableBlockName(tag: []const u8, keyword: []const u8) ![]const u8 {
    const name_start = skipWs(tag, keyword.len);
    if (name_start >= tag.len or !isIdentStart(tag[name_start])) return error.MalformedMacroBlock;
    var name_end = name_start + 1;
    while (name_end < tag.len and isIdentChar(tag[name_end])) name_end += 1;
    const call_pos = skipWs(tag, name_end);
    if (call_pos >= tag.len or tag[call_pos] != '(') return error.MalformedMacroBlock;
    _ = findMatchingParen(tag, call_pos) orelse return error.MalformedMacroBlock;
    return tag[name_start..name_end];
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
    var macros_indent: usize = 0;
    var macro_item_indent: ?usize = null;
    var arguments_indent: usize = 0;
    var argument_item_indent: ?usize = null;
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
                argument_item_indent = null;
                current_argument = null;
            }
            continue;
        }

        const macro_index = current_macro orelse continue;
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
                arguments_indent = indent;
                argument_item_indent = null;
                current_argument = null;
            }
        }
    }
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
        for (property.arguments.items) |argument| {
            try appendMacroArgumentClone(graph, &macro.arguments, argument);
        }
    }
}

fn appendMacroArgumentClone(graph: *Graph, arguments: *std.ArrayList(MacroArgument), source: MacroArgument) !void {
    for (arguments.items) |*existing| {
        if (std.mem.eql(u8, existing.name, source.name)) {
            if (source.type.len != 0) existing.type = source.type;
            if (source.description.len != 0) existing.description = source.description;
            return;
        }
    }
    try arguments.append(graph.allocator, source);
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
    var sources_indent: usize = 0;
    var source_item_indent: ?usize = null;
    var table_item_indent: ?usize = null;
    var current_source: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);

        if (std.mem.eql(u8, trimmed, "sources:")) {
            in_sources = true;
            in_tables = false;
            sources_indent = indent;
            source_item_indent = null;
            table_item_indent = null;
            continue;
        }
        if (!in_sources) continue;
        if (indent <= sources_indent and !std.mem.eql(u8, trimmed, "sources:")) {
            in_sources = false;
            in_tables = false;
            current_source = null;
            continue;
        }

        if (std.mem.eql(u8, trimmed, "tables:")) {
            in_tables = true;
            table_item_indent = null;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "- name:")) {
            const name = try dupTrimmedScalar(allocator, trimmed["- name:".len..]);
            if (source_item_indent == null or indent == source_item_indent.?) {
                source_item_indent = indent;
                current_source = name;
                in_tables = false;
                table_item_indent = null;
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
                });
            }
        }
    }
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

    if (column_name) |column| try clean_args.append(allocator, try cleanTestNamePart(allocator, column));
    if (std.mem.eql(u8, test_def.name, "relationships")) {
        try clean_args.append(allocator, try cleanTestNamePart(allocator, test_def.relationship_field));
        try clean_args.append(allocator, try cleanTestNamePart(allocator, test_def.relationship_to));
    } else if (std.mem.eql(u8, test_def.name, "accepted_values")) {
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
        \\    arguments:
        \\      - name: column_name
        \\        type: string
        \\        description: Identifier expression.
        \\      - name: quote
        \\        type: bool
        \\
        \\models:
        \\  - name: ignored
    ;

    try parseMacroPropertiesFromText(allocator, yaml, "macros/schema.yml", "demo", &graph);

    try std.testing.expectEqual(@as(usize, 1), graph.macro_properties.items.len);
    try std.testing.expectEqualStrings("demo", graph.macro_properties.items[0].package_name);
    try std.testing.expectEqualStrings("format_id", graph.macro_properties.items[0].name);
    try std.testing.expectEqualStrings("macros/schema.yml", graph.macro_properties.items[0].patch_path);
    try std.testing.expectEqualStrings("Format an identifier expression.", graph.macro_properties.items[0].description);
    try std.testing.expectEqual(@as(usize, 2), graph.macro_properties.items[0].arguments.items.len);
    try std.testing.expectEqualStrings("column_name", graph.macro_properties.items[0].arguments.items[0].name);
    try std.testing.expectEqualStrings("string", graph.macro_properties.items[0].arguments.items[0].type);
    try std.testing.expectEqualStrings("Identifier expression.", graph.macro_properties.items[0].arguments.items[0].description);
    try std.testing.expectEqualStrings("quote", graph.macro_properties.items[0].arguments.items[1].name);
    try std.testing.expectEqualStrings("bool", graph.macro_properties.items[0].arguments.items[1].type);
}

test "applyMacroProperties applies descriptions patch paths and merges arguments" {
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
    try graph.macros.items[0].arguments.append(allocator, .{
        .name = "column_name",
        .type = "string",
        .description = "",
    });

    try graph.macro_properties.append(allocator, .{
        .package_name = "demo",
        .name = "format_id",
        .patch_path = "macros/schema.yml",
        .description = "Formats an identifier.",
    });
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
    try std.testing.expectEqual(@as(usize, 2), graph.macros.items[0].arguments.items.len);
    try std.testing.expectEqualStrings("column_name", graph.macros.items[0].arguments.items[0].name);
    try std.testing.expectEqualStrings("string", graph.macros.items[0].arguments.items[0].type);
    try std.testing.expectEqualStrings("Identifier expression.", graph.macros.items[0].arguments.items[0].description);
    try std.testing.expectEqualStrings("quote", graph.macros.items[0].arguments.items[1].name);
    try std.testing.expectEqualStrings("bool", graph.macros.items[0].arguments.items[1].type);
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
    try std.testing.expectEqualStrings("source.pkg.raw.payments", graph.sources.items[1].unique_id);
    try std.testing.expectEqualStrings("source.pkg.app.users", graph.sources.items[2].unique_id);
    try std.testing.expectEqualStrings("models/schema.yml", graph.sources.items[2].original_file_path);
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

test "genericTestUniqueId keeps dbt-style hash suffix stable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_def = GenericTestDef{ .name = "not_null" };
    const unique_id = try genericTestUniqueId(allocator, "demo", "not_null_customers_id", test_def, "customers", "id");
    try std.testing.expectEqualStrings("test.demo.not_null_customers_id.422908bfae", unique_id);
}
