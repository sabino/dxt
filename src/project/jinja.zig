const std = @import("std");
const resolve = @import("resolve.zig");
const types = @import("types.zig");
const util = @import("util.zig");

const Graph = types.Graph;
const Node = types.Node;

const appendUnique = util.appendUnique;
const sortStrings = util.sortStrings;
const findMacroIdByPackageAndName = resolve.findMacroIdByPackageAndName;
const findMacroIdForUnqualifiedCall = resolve.findMacroIdForUnqualifiedCall;
const hasMacroPackage = resolve.hasMacroPackage;
const packageNameFromMacroUniqueId = resolve.packageNameFromMacroUniqueId;

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

pub fn scanSql(allocator: std.mem.Allocator, sql: []const u8, node: *Node, graph: ?*const Graph) !void {
    var index: usize = 0;
    while (index + 1 < sql.len) {
        if (sql[index] != '{') {
            index += 1;
            continue;
        }
        if (sql[index + 1] == '#') {
            const end = std.mem.indexOfPos(u8, sql, index + 2, "#}") orelse return error.UnsupportedJinja;
            index = end + 2;
            continue;
        }
        const close = if (sql[index + 1] == '{')
            std.mem.indexOfPos(u8, sql, index + 2, "}}")
        else if (sql[index + 1] == '%')
            std.mem.indexOfPos(u8, sql, index + 2, "%}")
        else
            null;
        if (close) |end| {
            try scanJinjaSpan(allocator, sql[index + 2 .. end], node, graph);
            index = end + 2;
            continue;
        }
        index += 1;
    }
}

fn scanJinjaSpan(allocator: std.mem.Allocator, span: []const u8, node: *Node, graph: ?*const Graph) !void {
    var i: usize = 0;
    while (i < span.len) {
        if (span[i] == '"' or span[i] == '\'') {
            i = skipQuotedSpan(span, i) orelse return error.UnsupportedJinja;
            continue;
        }
        if (!isIdentStart(span[i])) {
            i += 1;
            continue;
        }
        const start = i;
        i += 1;
        while (i < span.len and isIdentChar(span[i])) i += 1;
        const ident = span[start..i];
        const call = (try readJinjaCall(span, ident, i)) orelse continue;
        const args = span[call.open + 1 .. call.close];

        if (call.package_name) |package_name| {
            if (graph) |known_graph| {
                if (findMacroIdByPackageAndName(known_graph, package_name, call.name)) |macro_id| {
                    try appendUnique(allocator, &node.macro_depends_on, macro_id);
                    i = call.close + 1;
                    continue;
                }
                if (hasMacroPackage(known_graph, package_name)) return error.UnresolvedMacro;
            }
            return error.UnsupportedJinja;
        } else if (std.mem.eql(u8, call.name, "ref")) {
            var strings = try parseLiteralArgs(allocator, args, error.UnsupportedDynamicRef);
            defer strings.deinit(allocator);
            if (!(strings.items.len == 1 or strings.items.len == 2)) return error.UnsupportedDynamicRef;
            try node.refs.append(allocator, .{
                .package = if (strings.items.len == 2) strings.items[0] else null,
                .name = if (strings.items.len == 2) strings.items[1] else strings.items[0],
            });
        } else if (std.mem.eql(u8, call.name, "source")) {
            var strings = try parseLiteralArgs(allocator, args, error.UnsupportedDynamicSource);
            defer strings.deinit(allocator);
            if (strings.items.len != 2) return error.UnsupportedDynamicSource;
            try node.source_refs.append(allocator, .{
                .source_name = strings.items[0],
                .table_name = strings.items[1],
            });
        } else if (std.mem.eql(u8, call.name, "config")) {
            try parseConfig(allocator, args, node);
        } else {
            if (graph) |known_graph| {
                if (findMacroIdForUnqualifiedCall(known_graph, node.package_name, call.name)) |macro_id| {
                    try appendUnique(allocator, &node.macro_depends_on, macro_id);
                    i = call.close + 1;
                    continue;
                }
            }
            return error.UnsupportedJinja;
        }
        i = call.close + 1;
    }
}

pub fn scanMacroSqlForKnownMacroCalls(allocator: std.mem.Allocator, sql: []const u8, graph: *const Graph, current_macro_id: []const u8, macro_depends_on: *std.ArrayList([]const u8)) !void {
    var index: usize = 0;
    while (index + 1 < sql.len) {
        if (sql[index] != '{') {
            index += 1;
            continue;
        }
        if (sql[index + 1] == '#') {
            const end = std.mem.indexOfPos(u8, sql, index + 2, "#}") orelse break;
            index = end + 2;
            continue;
        }
        const close = if (sql[index + 1] == '{')
            std.mem.indexOfPos(u8, sql, index + 2, "}}")
        else if (sql[index + 1] == '%')
            std.mem.indexOfPos(u8, sql, index + 2, "%}")
        else
            null;
        if (close) |end| {
            try scanMacroSpanForKnownMacroCalls(allocator, sql[index + 2 .. end], graph, current_macro_id, macro_depends_on);
            index = end + 2;
            continue;
        }
        index += 1;
    }
}

fn scanMacroSpanForKnownMacroCalls(allocator: std.mem.Allocator, span: []const u8, graph: *const Graph, current_macro_id: []const u8, macro_depends_on: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    const current_package = packageNameFromMacroUniqueId(current_macro_id) orelse graph.project_name;
    while (i < span.len) {
        if (span[i] == '"' or span[i] == '\'') {
            i = skipQuotedSpan(span, i) orelse break;
            continue;
        }
        if (!isIdentStart(span[i])) {
            i += 1;
            continue;
        }
        const start = i;
        i += 1;
        while (i < span.len and isIdentChar(span[i])) i += 1;
        const ident = span[start..i];
        const call = (readJinjaCall(span, ident, i) catch break) orelse continue;
        const macro_id = if (call.package_name) |package_name| blk: {
            const resolved = findMacroIdByPackageAndName(graph, package_name, call.name);
            if (resolved == null and hasMacroPackage(graph, package_name)) return error.UnresolvedMacro;
            break :blk resolved;
        } else findMacroIdForUnqualifiedCall(graph, current_package, call.name);
        if (macro_id) |resolved_macro_id| {
            if (std.mem.eql(u8, resolved_macro_id, current_macro_id)) {
                i = call.close + 1;
                continue;
            }
            try appendUnique(allocator, macro_depends_on, resolved_macro_id);
        }
        i = call.close + 1;
    }
}

fn parseConfig(allocator: std.mem.Allocator, args: []const u8, node: *Node) !void {
    if (findKeyword(args, "materialized")) |pos| {
        if (findValueStart(args, pos + "materialized".len)) |value_pos| {
            if (args[value_pos] != '"' and args[value_pos] != '\'') return error.UnsupportedJinja;
            const parsed = try parseQuoted(allocator, args, value_pos);
            node.materialized = parsed.value;
            node.inline_materialized = true;
        }
    }
    if (findKeyword(args, "tags")) |pos| {
        if (findValueStart(args, pos + "tags".len)) |value_pos| {
            try parseTagList(allocator, args[value_pos..], &node.tags);
            node.inline_tags = true;
            sortStrings(node.tags.items);
        }
    }
}

fn parseTagList(allocator: std.mem.Allocator, text: []const u8, tags: *std.ArrayList([]const u8)) !void {
    var i = skipWs(text, 0);
    if (i >= text.len) return;
    if (text[i] == '"' or text[i] == '\'') {
        const parsed = try parseQuoted(allocator, text, i);
        try appendUnique(allocator, tags, parsed.value);
        return;
    }
    if (text[i] != '[') return error.UnsupportedJinja;
    i += 1;
    while (i < text.len) {
        i = skipWs(text, i);
        if (i >= text.len or text[i] == ']') break;
        if (text[i] == ',') {
            i += 1;
            continue;
        }
        if (text[i] != '"' and text[i] != '\'') return error.UnsupportedJinja;
        const parsed = try parseQuoted(allocator, text, i);
        try appendUnique(allocator, tags, parsed.value);
        i = parsed.next;
    }
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

fn deinitTestNode(allocator: std.mem.Allocator, node: *Node) void {
    node.tags.deinit(allocator);
    node.refs.deinit(allocator);
    node.source_refs.deinit(allocator);
    node.depends_on.deinit(allocator);
    node.macro_depends_on.deinit(allocator);
}

fn appendTestMacro(graph: *Graph, package_name: []const u8, name: []const u8) ![]const u8 {
    const unique_id = try std.fmt.allocPrint(graph.allocator, "macro.{s}.{s}", .{ package_name, name });
    try graph.macros.append(graph.allocator, .{
        .unique_id = unique_id,
        .package_name = package_name,
        .name = name,
        .path = "",
        .original_file_path = "",
        .macro_sql = "",
    });
    return unique_id;
}

test "sql scanner extracts refs sources and config tags from jinja spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "",
    };
    defer deinitTestNode(allocator, &node);

    try scanSql(allocator,
        \\{{ config(materialized="table", tags=["nightly", 'core']) }}
        \\select * from {{ ref("stg_customers") }}
        \\union all select * from {{ source('raw', "customers") }}
        \\select {{ "ref('not_a_dependency')" }} as literal_ref
        \\{# {{ ref("ignored") }} #}
    , &node, null);

    try std.testing.expectEqual(@as(usize, 1), node.refs.items.len);
    try std.testing.expectEqualStrings("stg_customers", node.refs.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), node.source_refs.items.len);
    try std.testing.expectEqualStrings("raw", node.source_refs.items[0].source_name);
    try std.testing.expectEqualStrings("customers", node.source_refs.items[0].table_name);
    try std.testing.expectEqualStrings("table", node.materialized);
    try std.testing.expectEqual(@as(usize, 2), node.tags.items.len);
}

test "sql scanner records known unqualified and package macro calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    _ = try appendTestMacro(&graph, "demo", "format_id");
    _ = try appendTestMacro(&graph, "pkg", "star");

    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "",
    };
    defer deinitTestNode(allocator, &node);

    try scanSql(allocator,
        \\{{ config(tags="nightly") }}
        \\select {{ format_id('id') }}, {{ pkg.star() }}
        \\from {{ ref('customers') }}
    , &node, &graph);

    try std.testing.expectEqual(@as(usize, 2), node.macro_depends_on.items.len);
    try std.testing.expectEqualStrings("macro.demo.format_id", node.macro_depends_on.items[0]);
    try std.testing.expectEqualStrings("macro.pkg.star", node.macro_depends_on.items[1]);
    try std.testing.expectEqual(@as(usize, 1), node.refs.items.len);
    try std.testing.expectEqualStrings("customers", node.refs.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), node.tags.items.len);
    try std.testing.expectEqualStrings("nightly", node.tags.items[0]);
}

test "macro scanner records known dependencies skips self and rejects missing known package macros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    const current_macro = try appendTestMacro(&graph, "demo", "render_orders");
    _ = try appendTestMacro(&graph, "demo", "format_id");
    _ = try appendTestMacro(&graph, "pkg", "star");

    var macro_depends_on: std.ArrayList([]const u8) = .empty;
    defer macro_depends_on.deinit(allocator);

    try scanMacroSqlForKnownMacroCalls(allocator,
        \\{% macro render_orders() %}
        \\  {{ render_orders() }}
        \\  {{ format_id('id') }}
        \\  {{ pkg.star() }}
        \\{% endmacro %}
    , &graph, current_macro, &macro_depends_on);

    try std.testing.expectEqual(@as(usize, 2), macro_depends_on.items.len);
    try std.testing.expectEqualStrings("macro.demo.format_id", macro_depends_on.items[0]);
    try std.testing.expectEqualStrings("macro.pkg.star", macro_depends_on.items[1]);

    try std.testing.expectError(error.UnresolvedMacro, scanMacroSqlForKnownMacroCalls(allocator, "{{ pkg.missing() }}", &graph, current_macro, &macro_depends_on));
}
