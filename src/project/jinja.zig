const std = @import("std");
const resolve = @import("resolve.zig");
const types = @import("types.zig");
const util = @import("util.zig");

const Graph = types.Graph;
const Node = types.Node;

const appendUnique = util.appendUnique;
const sortStrings = util.sortStrings;
const findMacroIdForAdapterDispatch = resolve.findMacroIdForAdapterDispatch;
const findMacroIdByPackageAndName = resolve.findMacroIdByPackageAndName;
const findMacroIdForUnqualifiedMacroDependency = resolve.findMacroIdForUnqualifiedMacroDependency;
const findMacroIdForUnqualifiedNamespaceCall = resolve.findMacroIdForUnqualifiedNamespaceCall;
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

pub const AdapterDispatchArgs = struct {
    macro_name: []const u8,
    macro_namespace: ?[]const u8 = null,
};

pub const DispatchPrefixes = struct {
    values: [3][]const u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const DispatchPrefixes) []const []const u8 {
        return self.values[0..self.len];
    }
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

pub fn parseLiteralOrVarArgs(allocator: std.mem.Allocator, args: []const u8, graph: ?*const Graph, unsupported_error: anyerror) !std.ArrayList([]const u8) {
    return parseLiteralOrVarArgsWithBindings(allocator, args, graph, &.{}, unsupported_error);
}

fn parseLiteralOrVarArgsWithBindings(
    allocator: std.mem.Allocator,
    args: []const u8,
    graph: ?*const Graph,
    bindings: []const LocalBinding,
    unsupported_error: anyerror,
) !std.ArrayList([]const u8) {
    var strings: std.ArrayList([]const u8) = .empty;
    errdefer strings.deinit(allocator);

    var i: usize = 0;
    var saw_arg = false;
    while (i < args.len) {
        i = skipWs(args, i);
        if (i >= args.len) break;
        if (args[i] == ',') {
            i += 1;
            continue;
        }

        if (args[i] == '"' or args[i] == '\'') {
            const parsed = try parseQuoted(allocator, args, i);
            try strings.append(allocator, parsed.value);
            saw_arg = true;
            i = skipWs(args, parsed.next);
        } else if (std.mem.startsWith(u8, args[i..], "var")) {
            if (readJinjaCall(args, "var", i + "var".len) catch return unsupported_error) |call| {
                if (call.package_name != null or !std.mem.eql(u8, call.name, "var")) return unsupported_error;
                var var_name_args = try parseLiteralArgs(allocator, args[call.open + 1 .. call.close], unsupported_error);
                defer var_name_args.deinit(allocator);
                if (!(var_name_args.items.len == 1 or var_name_args.items.len == 2)) return unsupported_error;
                const value = if (graph) |known_graph|
                    findVarValue(known_graph, var_name_args.items[0])
                else
                    null;
                if (value) |resolved_value| {
                    try strings.append(allocator, resolved_value);
                } else if (var_name_args.items.len == 2) {
                    try strings.append(allocator, var_name_args.items[1]);
                } else {
                    return error.UnresolvedVar;
                }
                saw_arg = true;
                i = skipWs(args, call.close + 1);
            } else {
                const parsed = parseLocalBindingArg(args, i, bindings) orelse return unsupported_error;
                if (parsed.blocked) return unsupported_error;
                try strings.append(allocator, try allocator.dupe(u8, parsed.value));
                saw_arg = true;
                i = skipWs(args, parsed.next);
            }
        } else if (isIdentStart(args[i])) {
            const parsed = parseLocalBindingArg(args, i, bindings) orelse return unsupported_error;
            if (parsed.blocked) return unsupported_error;
            try strings.append(allocator, try allocator.dupe(u8, parsed.value));
            saw_arg = true;
            i = skipWs(args, parsed.next);
        } else {
            return unsupported_error;
        }

        if (i < args.len and args[i] != ',') return unsupported_error;
    }
    if (!saw_arg) return unsupported_error;
    return strings;
}

const LocalBinding = struct {
    name: []const u8,
    value: ?[]const u8,
};

const LocalBindingArg = struct {
    value: []const u8 = "",
    next: usize,
    blocked: bool = false,
};

fn parseLocalBindingArg(args: []const u8, start: usize, bindings: []const LocalBinding) ?LocalBindingArg {
    var end = start;
    if (end >= args.len or !isIdentStart(args[end])) return null;
    end += 1;
    while (end < args.len and isIdentChar(args[end])) end += 1;
    const name = args[start..end];
    for (0..bindings.len) |offset| {
        const index = bindings.len - 1 - offset;
        if (std.mem.eql(u8, bindings[index].name, name)) {
            return if (bindings[index].value) |value|
                .{ .value = value, .next = end }
            else
                .{ .next = end, .blocked = true };
        }
    }
    return null;
}

fn findVarValue(graph: *const Graph, name: []const u8) ?[]const u8 {
    for (graph.vars.items) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
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
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '"' or text[i] == '\'') {
            i = skipQuotedSpan(text, i) orelse return null;
            continue;
        }
        if (i + keyword.len <= text.len and std.mem.eql(u8, text[i .. i + keyword.len], keyword)) {
            const before_ok = i == 0 or !isIdentChar(text[i - 1]);
            const after = i + keyword.len;
            const after_ok = after >= text.len or !isIdentChar(text[after]);
            if (before_ok and after_ok) return i;
        }
        i += 1;
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
    var context = ScanContext{ .allocator = allocator };
    defer context.deinit();
    try scanRange(allocator, sql, 0, sql.len, node, graph, &context);
}

fn scanRange(allocator: std.mem.Allocator, sql: []const u8, start: usize, range_end: usize, node: *Node, graph: ?*const Graph, context: *ScanContext) !void {
    var index: usize = start;
    while (index + 1 < range_end) {
        if (sql[index] != '{') {
            index += 1;
            continue;
        }
        if (sql[index + 1] == '#') {
            const end = std.mem.indexOfPos(u8, sql, index + 2, "#}") orelse return error.UnsupportedJinja;
            index = end + 2;
            continue;
        }
        const tag_kind = sql[index + 1];
        const close = if (tag_kind == '{')
            std.mem.indexOfPos(u8, sql, index + 2, "}}")
        else if (tag_kind == '%')
            std.mem.indexOfPos(u8, sql, index + 2, "%}")
        else
            null;
        if (close) |tag_end| {
            if (tag_end + 2 > range_end) return error.UnsupportedJinja;
            const span = std.mem.trim(u8, sql[index + 2 .. tag_end], " \t\r\n-");
            if (tag_kind == '%') {
                if (std.mem.startsWith(u8, span, "set ")) {
                    if (parseSetListStatement(allocator, span)) |assignment| {
                        try context.setList(assignment.name, assignment.values);
                        index = tag_end + 2;
                        continue;
                    } else |err| switch (err) {
                        error.UnsupportedJinja => {},
                        else => return err,
                    }
                }
                if (isForStatement(span)) {
                    if (parseForBlockOrNull(sql, tag_end + 2, span) catch null) |block| {
                        if (block.end_tag_close > range_end) return error.UnsupportedJinja;
                        if (context.getList(block.list_name)) |values| {
                            for (values) |value| {
                                try context.enterScope();
                                try context.pushBinding(block.variable_name, value);
                                scanRange(allocator, sql, block.body_start, block.body_end, node, graph, context) catch |err| {
                                    context.exitScope();
                                    return err;
                                };
                                context.exitScope();
                            }
                            index = block.end_tag_close;
                            continue;
                        }
                    }
                    if (parseForShadowBlockOrNull(sql, tag_end + 2, span)) |block| {
                        if (block.end_tag_close > range_end) return error.UnsupportedJinja;
                        try scanJinjaSpan(allocator, span, node, graph, context);
                        try context.enterScope();
                        for (block.variable_names[0..block.variable_names_len]) |variable_name| {
                            try context.pushBlockedBinding(variable_name);
                        }
                        scanRange(allocator, sql, block.body_start, block.body_end, node, graph, context) catch |err| {
                            context.exitScope();
                            return err;
                        };
                        context.exitScope();
                        index = block.end_tag_close;
                        continue;
                    }
                }
            }
            try scanJinjaSpan(allocator, span, node, graph, context);
            index = tag_end + 2;
            continue;
        }
        index += 1;
    }
}

const ScanList = struct {
    name: []const u8,
    values: std.ArrayList([]const u8),
};

const ScanContext = struct {
    allocator: std.mem.Allocator,
    lists: std.ArrayList(ScanList) = .empty,
    bindings: std.ArrayList(LocalBinding) = .empty,
    scopes: std.ArrayList(ScanScope) = .empty,

    fn deinit(self: *ScanContext) void {
        for (self.lists.items) |*list| {
            for (list.values.items) |value| self.allocator.free(value);
            list.values.deinit(self.allocator);
        }
        self.lists.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        self.scopes.deinit(self.allocator);
    }

    fn setList(self: *ScanContext, name: []const u8, values: std.ArrayList([]const u8)) !void {
        const current_scope_start = self.currentListScopeStart();
        for (self.lists.items[current_scope_start..]) |*list| {
            if (std.mem.eql(u8, list.name, name)) {
                for (list.values.items) |value| self.allocator.free(value);
                list.values.deinit(self.allocator);
                list.values = values;
                return;
            }
        }
        try self.lists.append(self.allocator, .{ .name = name, .values = values });
    }

    fn getList(self: *const ScanContext, name: []const u8) ?[]const []const u8 {
        for (0..self.lists.items.len) |offset| {
            const index = self.lists.items.len - 1 - offset;
            const list = &self.lists.items[index];
            if (std.mem.eql(u8, list.name, name)) return list.values.items;
        }
        return null;
    }

    fn pushBinding(self: *ScanContext, name: []const u8, value: []const u8) !void {
        try self.bindings.append(self.allocator, .{ .name = name, .value = value });
    }

    fn pushBlockedBinding(self: *ScanContext, name: []const u8) !void {
        try self.bindings.append(self.allocator, .{ .name = name, .value = null });
    }

    fn enterScope(self: *ScanContext) !void {
        try self.scopes.append(self.allocator, .{
            .lists_len = self.lists.items.len,
            .bindings_len = self.bindings.items.len,
        });
    }

    fn exitScope(self: *ScanContext) void {
        const scope = self.scopes.pop().?;
        while (self.lists.items.len > scope.lists_len) {
            var list = self.lists.pop().?;
            for (list.values.items) |value| self.allocator.free(value);
            list.values.deinit(self.allocator);
        }
        while (self.bindings.items.len > scope.bindings_len) {
            _ = self.bindings.pop();
        }
    }

    fn currentListScopeStart(self: *const ScanContext) usize {
        if (self.scopes.items.len == 0) return 0;
        return self.scopes.items[self.scopes.items.len - 1].lists_len;
    }
};

const ScanScope = struct {
    lists_len: usize,
    bindings_len: usize,
};

const SetListAssignment = struct {
    name: []const u8,
    values: std.ArrayList([]const u8),
};

fn parseSetListStatement(allocator: std.mem.Allocator, span: []const u8) !SetListAssignment {
    var index: usize = "set ".len;
    index = skipWs(span, index);
    const name_start = index;
    if (index >= span.len or !isIdentStart(span[index])) return error.UnsupportedJinja;
    index += 1;
    while (index < span.len and isIdentChar(span[index])) index += 1;
    const name = span[name_start..index];
    index = skipWs(span, index);
    if (index >= span.len or span[index] != '=') return error.UnsupportedJinja;
    index = skipWs(span, index + 1);
    if (index >= span.len) return error.UnsupportedJinja;
    var values: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }
    try parseJinjaStringListLiteral(allocator, span[index..], &values);
    return .{ .name = name, .values = values };
}

fn parseJinjaStringListLiteral(allocator: std.mem.Allocator, value: []const u8, out: *std.ArrayList([]const u8)) !void {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return error.UnsupportedJinja;
    var index: usize = 1;
    const end = trimmed.len - 1;
    while (true) {
        index = skipWs(trimmed, index);
        if (index >= end) return;
        const quote = trimmed[index];
        if (quote != '\'' and quote != '"') return error.UnsupportedJinja;
        index += 1;
        var item: std.ArrayList(u8) = .empty;
        errdefer item.deinit(allocator);
        while (index < end and trimmed[index] != quote) {
            if (trimmed[index] == '\\') return error.UnsupportedJinja;
            try item.append(allocator, trimmed[index]);
            index += 1;
        }
        if (index >= end or trimmed[index] != quote) return error.UnsupportedJinja;
        index += 1;
        try out.append(allocator, try item.toOwnedSlice(allocator));
        index = skipWs(trimmed, index);
        if (index >= end) return;
        if (trimmed[index] != ',') return error.UnsupportedJinja;
        index += 1;
    }
}

const ForBlock = struct {
    variable_name: []const u8,
    list_name: []const u8,
    body_start: usize,
    body_end: usize,
    end_tag_close: usize,
};

const ForShadowBlock = struct {
    variable_names: [16][]const u8 = undefined,
    variable_names_len: usize = 0,
    body_start: usize = 0,
    body_end: usize = 0,
    end_tag_close: usize = 0,
};

fn isForStatement(span: []const u8) bool {
    return std.mem.startsWith(u8, span, "for ") or std.mem.eql(u8, span, "for");
}

fn isEndForStatement(span: []const u8) bool {
    return std.mem.eql(u8, span, "endfor");
}

fn isElseStatement(span: []const u8) bool {
    return std.mem.eql(u8, span, "else");
}

fn parseForBlock(sql: []const u8, body_start: usize, span: []const u8) !ForBlock {
    return (try parseForBlockOrNull(sql, body_start, span)) orelse return error.UnsupportedJinja;
}

fn parseForBlockOrNull(sql: []const u8, body_start: usize, span: []const u8) !?ForBlock {
    var index: usize = "for".len;
    index = skipWs(span, index);
    const variable_start = index;
    if (index >= span.len or !isIdentStart(span[index])) return error.UnsupportedJinja;
    index += 1;
    while (index < span.len and isIdentChar(span[index])) index += 1;
    const variable_name = span[variable_start..index];
    index = skipWs(span, index);
    if (index + "in".len > span.len or !std.mem.eql(u8, span[index .. index + "in".len], "in")) return error.UnsupportedJinja;
    const before_ok = index == 0 or !isIdentChar(span[index - 1]);
    const after = index + "in".len;
    const after_ok = after >= span.len or !isIdentChar(span[after]);
    if (!before_ok or !after_ok) return error.UnsupportedJinja;
    index = skipWs(span, after);
    const list_start = index;
    if (index >= span.len or !isIdentStart(span[index])) return error.UnsupportedJinja;
    index += 1;
    while (index < span.len and isIdentChar(span[index])) index += 1;
    const list_name = span[list_start..index];
    if (std.mem.trim(u8, span[index..], " \t\r\n").len != 0) return null;

    const endfor = findMatchingEndFor(sql, body_start) orelse return error.UnsupportedJinja;
    return .{
        .variable_name = variable_name,
        .list_name = list_name,
        .body_start = body_start,
        .body_end = endfor.start,
        .end_tag_close = endfor.close,
    };
}

fn parseForShadowBlockOrNull(sql: []const u8, body_start: usize, span: []const u8) ?ForShadowBlock {
    var index: usize = "for".len;
    var block = ForShadowBlock{};
    var after: usize = 0;
    while (index < span.len) {
        index = skipWs(span, index);
        if (index >= span.len) return null;
        if (isKeywordAt(span, index, "in")) {
            if (block.variable_names_len == 0) return null;
            after = index + "in".len;
            break;
        }
        if (isIdentStart(span[index])) {
            const variable_start = index;
            index += 1;
            while (index < span.len and isIdentChar(span[index])) index += 1;
            if (block.variable_names_len >= block.variable_names.len) return null;
            block.variable_names[block.variable_names_len] = span[variable_start..index];
            block.variable_names_len += 1;
            continue;
        }
        index += 1;
    }
    if (after == 0) return null;
    if (std.mem.trim(u8, span[after..], " \t\r\n").len == 0) return null;
    const endfor = findMatchingEndForPermissive(sql, body_start) orelse return null;
    block.body_start = body_start;
    block.body_end = endfor.start;
    block.end_tag_close = endfor.close;
    return block;
}

fn isKeywordAt(text: []const u8, index: usize, keyword: []const u8) bool {
    if (index + keyword.len > text.len) return false;
    if (!std.mem.eql(u8, text[index .. index + keyword.len], keyword)) return false;
    const before_ok = index == 0 or !isIdentChar(text[index - 1]);
    const after = index + keyword.len;
    const after_ok = after >= text.len or !isIdentChar(text[after]);
    return before_ok and after_ok;
}

const EndForTag = struct {
    start: usize,
    close: usize,
};

fn findMatchingEndFor(sql: []const u8, start: usize) ?EndForTag {
    var index = start;
    var depth: usize = 1;
    while (index + 1 < sql.len) {
        if (sql[index] != '{') {
            index += 1;
            continue;
        }
        if (sql[index + 1] == '#') {
            const close = std.mem.indexOfPos(u8, sql, index + 2, "#}") orelse return null;
            index = close + 2;
            continue;
        }
        if (sql[index + 1] != '%') {
            index += 1;
            continue;
        }
        const close = std.mem.indexOfPos(u8, sql, index + 2, "%}") orelse return null;
        const span = std.mem.trim(u8, sql[index + 2 .. close], " \t\r\n-");
        if (isForStatement(span)) {
            depth += 1;
        } else if (isEndForStatement(span)) {
            depth -= 1;
            if (depth == 0) return .{ .start = index, .close = close + 2 };
        } else if (depth == 1 and isElseStatement(span)) {
            return null;
        }
        index = close + 2;
    }
    return null;
}

fn findMatchingEndForPermissive(sql: []const u8, start: usize) ?EndForTag {
    var index = start;
    var depth: usize = 1;
    while (index + 1 < sql.len) {
        if (sql[index] != '{') {
            index += 1;
            continue;
        }
        if (sql[index + 1] == '#') {
            const close = std.mem.indexOfPos(u8, sql, index + 2, "#}") orelse return null;
            index = close + 2;
            continue;
        }
        if (sql[index + 1] != '%') {
            index += 1;
            continue;
        }
        const close = std.mem.indexOfPos(u8, sql, index + 2, "%}") orelse return null;
        const span = std.mem.trim(u8, sql[index + 2 .. close], " \t\r\n-");
        if (isForStatement(span)) {
            depth += 1;
        } else if (isEndForStatement(span)) {
            depth -= 1;
            if (depth == 0) return .{ .start = index, .close = close + 2 };
        }
        index = close + 2;
    }
    return null;
}

fn scanJinjaSpan(allocator: std.mem.Allocator, span: []const u8, node: *Node, graph: ?*const Graph, context: *const ScanContext) !void {
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
                if (std.mem.eql(u8, package_name, "adapter") and std.mem.eql(u8, call.name, "dispatch")) {
                    const dispatch_args = try parseAdapterDispatchArgs(allocator, args);
                    defer deinitAdapterDispatchArgs(allocator, dispatch_args);
                    const dispatch_prefixes = dispatchPrefixesForAdapter(known_graph.adapter_type);
                    if (findMacroIdForAdapterDispatch(known_graph, node.package_name, dispatch_args.macro_name, dispatch_args.macro_namespace, dispatch_prefixes.slice())) |macro_id| {
                        try appendUnique(allocator, &node.macro_depends_on, macro_id);
                        i = call.close + 1;
                        continue;
                    }
                    return error.UnresolvedMacro;
                }
                if (findMacroIdByPackageAndName(known_graph, package_name, call.name)) |macro_id| {
                    try appendUnique(allocator, &node.macro_depends_on, macro_id);
                    i = call.close + 1;
                    continue;
                }
                if (hasMacroPackage(known_graph, package_name)) return error.UnresolvedMacro;
            }
            return error.UnsupportedJinja;
        } else if (std.mem.eql(u8, call.name, "ref")) {
            var strings = try parseLiteralOrVarArgsWithBindings(allocator, args, graph, context.bindings.items, error.UnsupportedDynamicRef);
            defer strings.deinit(allocator);
            if (!(strings.items.len == 1 or strings.items.len == 2)) return error.UnsupportedDynamicRef;
            try node.refs.append(allocator, .{
                .package = if (strings.items.len == 2) strings.items[0] else null,
                .name = if (strings.items.len == 2) strings.items[1] else strings.items[0],
            });
        } else if (std.mem.eql(u8, call.name, "source")) {
            var strings = try parseLiteralOrVarArgsWithBindings(allocator, args, graph, context.bindings.items, error.UnsupportedDynamicSource);
            defer strings.deinit(allocator);
            if (strings.items.len != 2) return error.UnsupportedDynamicSource;
            try node.source_refs.append(allocator, .{
                .source_name = strings.items[0],
                .table_name = strings.items[1],
            });
        } else if (std.mem.eql(u8, call.name, "config")) {
            try parseConfig(allocator, args, node);
        } else if (std.mem.eql(u8, call.name, "is_incremental")) {
            if (std.mem.trim(u8, args, " \t\r\n").len != 0) return error.UnsupportedJinja;
        } else {
            if (graph) |known_graph| {
                if (findMacroIdForUnqualifiedNamespaceCall(known_graph, node.package_name, call.name)) |macro_id| {
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
        if (call.package_name == null and std.mem.eql(u8, call.name, "return")) {
            try scanMacroSpanForKnownMacroCalls(allocator, span[call.open + 1 .. call.close], graph, current_macro_id, macro_depends_on);
            i = call.close + 1;
            continue;
        }
        const macro_id = if (call.package_name) |package_name| blk: {
            if (std.mem.eql(u8, package_name, "adapter") and std.mem.eql(u8, call.name, "dispatch")) {
                const args = span[call.open + 1 .. call.close];
                const dispatch_args = parseAdapterDispatchArgs(allocator, args) catch {
                    i = call.close + 1;
                    continue;
                };
                defer deinitAdapterDispatchArgs(allocator, dispatch_args);
                const dispatch_prefixes = dispatchPrefixesForAdapter(graph.adapter_type);
                const resolved = findMacroIdForAdapterDispatch(graph, current_package, dispatch_args.macro_name, dispatch_args.macro_namespace, dispatch_prefixes.slice());
                if (resolved == null) return error.UnresolvedMacro;
                break :blk resolved;
            }
            const resolved = findMacroIdByPackageAndName(graph, package_name, call.name);
            if (resolved == null and hasMacroPackage(graph, package_name)) return error.UnresolvedMacro;
            break :blk resolved;
        } else findMacroIdForUnqualifiedMacroDependency(graph, current_package, call.name);
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

pub fn dispatchPrefixesForAdapter(adapter_type: []const u8) DispatchPrefixes {
    var prefixes = DispatchPrefixes{};
    if (std.mem.eql(u8, adapter_type, "redshift")) {
        prefixes.values = .{ "redshift", "postgres", "default" };
        prefixes.len = 3;
    } else if (std.mem.eql(u8, adapter_type, "databricks")) {
        prefixes.values = .{ "databricks", "spark", "default" };
        prefixes.len = 3;
    } else if (std.mem.eql(u8, adapter_type, "postgresql")) {
        prefixes.values = .{ "postgres", "default", undefined };
        prefixes.len = 2;
    } else {
        prefixes.values = .{ adapter_type, "default", undefined };
        prefixes.len = 2;
    }
    return prefixes;
}

pub fn parseAdapterDispatchArgs(allocator: std.mem.Allocator, args: []const u8) !AdapterDispatchArgs {
    var result = AdapterDispatchArgs{ .macro_name = "" };
    errdefer deinitAdapterDispatchArgs(allocator, result);
    var positional_count: usize = 0;
    var saw_keyword = false;
    var i: usize = 0;

    while (i < args.len) {
        i = skipWs(args, i);
        if (i >= args.len) break;
        if (args[i] == ',') return error.UnsupportedJinja;

        var key: ?[]const u8 = null;
        if (isIdentStart(args[i])) {
            const key_start = i;
            i += 1;
            while (i < args.len and isIdentChar(args[i])) i += 1;
            const maybe_key = args[key_start..i];
            const after_key = skipWs(args, i);
            if (after_key < args.len and args[after_key] == '=') {
                key = maybe_key;
                i = skipWs(args, after_key + 1);
            } else {
                return error.UnsupportedJinja;
            }
        }

        if (i >= args.len or (args[i] != '"' and args[i] != '\'')) return error.UnsupportedJinja;
        const parsed = try parseQuoted(allocator, args, i);
        var parsed_owned = true;
        errdefer if (parsed_owned) allocator.free(parsed.value);
        i = skipWs(args, parsed.next);

        if (key) |name| {
            saw_keyword = true;
            if (std.mem.eql(u8, name, "macro_name")) {
                if (result.macro_name.len != 0) return error.UnsupportedJinja;
                result.macro_name = parsed.value;
                parsed_owned = false;
            } else if (std.mem.eql(u8, name, "macro_namespace")) {
                if (result.macro_namespace != null) return error.UnsupportedJinja;
                result.macro_namespace = parsed.value;
                parsed_owned = false;
            } else if (std.mem.eql(u8, name, "packages")) {
                return error.UnsupportedJinja;
            } else {
                return error.UnsupportedJinja;
            }
        } else {
            if (saw_keyword) return error.UnsupportedJinja;
            if (positional_count == 0) {
                result.macro_name = parsed.value;
                parsed_owned = false;
            } else if (positional_count == 1) {
                result.macro_namespace = parsed.value;
                parsed_owned = false;
            } else {
                return error.UnsupportedJinja;
            }
            positional_count += 1;
        }

        if (i < args.len) {
            if (args[i] != ',') return error.UnsupportedJinja;
            i += 1;
        }
    }

    if (result.macro_name.len == 0) return error.UnsupportedJinja;
    if (std.mem.indexOfScalar(u8, result.macro_name, '.') != null) return error.UnsupportedJinja;
    return result;
}

pub fn deinitAdapterDispatchArgs(allocator: std.mem.Allocator, args: AdapterDispatchArgs) void {
    if (args.macro_name.len != 0) allocator.free(args.macro_name);
    if (args.macro_namespace) |namespace| allocator.free(namespace);
}

fn parseConfig(allocator: std.mem.Allocator, args: []const u8, node: *Node) !void {
    if (try parseConfigQuotedValue(allocator, args, "materialized")) |value| {
        node.materialized = value;
        node.inline_materialized = true;
    }
    if (findKeyword(args, "tags")) |pos| {
        if (findValueStart(args, pos + "tags".len)) |value_pos| {
            try parseTagList(allocator, args[value_pos..], &node.tags);
            node.inline_tags = true;
            sortStrings(node.tags.items);
        }
    }
    if (try parseConfigQuotedValue(allocator, args, "schema")) |value| {
        node.config_schema = value;
    }
    if (try parseConfigQuotedValue(allocator, args, "alias")) |value| {
        node.config_alias = value;
    }
}

fn parseConfigQuotedValue(allocator: std.mem.Allocator, args: []const u8, key: []const u8) !?[]const u8 {
    if (findKeyword(args, key)) |pos| {
        if (findValueStart(args, pos + key.len)) |value_pos| {
            if (args[value_pos] != '"' and args[value_pos] != '\'') return error.UnsupportedJinja;
            const parsed = try parseQuoted(allocator, args, value_pos);
            return parsed.value;
        }
    }
    return null;
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

test "parseLiteralOrVarArgs resolves scalar vars from graph context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.vars.append(allocator, .{ .name = "model_name", .value = "customers" });

    var strings = try parseLiteralOrVarArgs(allocator, "'pkg', var('model_name')", &graph, error.UnsupportedDynamicRef);
    defer strings.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), strings.items.len);
    try std.testing.expectEqualStrings("pkg", strings.items[0]);
    try std.testing.expectEqualStrings("customers", strings.items[1]);

    try std.testing.expectError(error.UnresolvedVar, parseLiteralOrVarArgs(allocator, "var('missing')", &graph, error.UnsupportedDynamicRef));
    var defaulted = try parseLiteralOrVarArgs(allocator, "var('missing', 'fallback')", &graph, error.UnsupportedDynamicRef);
    defer defaulted.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), defaulted.items.len);
    try std.testing.expectEqualStrings("fallback", defaulted.items[0]);
    try std.testing.expectError(error.UnsupportedDynamicRef, parseLiteralOrVarArgs(allocator, "var('model_name', 'fallback', 'extra')", &graph, error.UnsupportedDynamicRef));
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
    try std.testing.expectEqual(@as(?usize, 16), findKeyword("alias='schema', schema='mart'", "schema"));
    try std.testing.expectEqual(@as(?usize, 16), findKeyword("schema='alias', alias='orders'", "alias"));
    try std.testing.expect(findKeyword("note='schema", "schema") == null);
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

fn appendTestDispatchConfig(graph: *Graph, macro_namespace: []const u8, search_order: []const []const u8) !void {
    var order: std.ArrayList([]const u8) = .empty;
    errdefer order.deinit(graph.allocator);
    try order.appendSlice(graph.allocator, search_order);
    try graph.dispatch_configs.append(graph.allocator, .{
        .macro_namespace = macro_namespace,
        .search_order = order,
    });
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
        \\{{ config(materialized="table", tags=["nightly", 'core'], schema="mart", alias='customer_orders') }}
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
    try std.testing.expectEqualStrings("mart", node.config_schema.?);
    try std.testing.expectEqualStrings("customer_orders", node.config_alias.?);
    try std.testing.expectEqual(@as(usize, 2), node.tags.items.len);
}

test "sql scanner tolerates is_incremental while extracting config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.events",
        .name = "events",
        .path = "events.sql",
        .original_file_path = "models/events.sql",
        .raw_code = "",
    };
    defer deinitTestNode(allocator, &node);

    try scanSql(allocator,
        \\{{ config(materialized='incremental') }}
        \\select 1 as id
        \\{% if is_incremental() %}
        \\where id > 0
        \\{% endif %}
    , &node, null);
    try std.testing.expectEqualStrings("incremental", node.materialized);
    try std.testing.expect(node.inline_materialized);
}

test "sql scanner records refs and sources inside false jinja branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.events",
        .name = "events",
        .path = "events.sql",
        .original_file_path = "models/events.sql",
        .raw_code = "",
    };
    defer deinitTestNode(allocator, &node);

    try scanSql(allocator,
        \\select 1
        \\{% if execute %}
        \\union all select * from {{ ref('orders') }}
        \\union all select * from {{ source('raw', 'events') }}
        \\{% endif %}
    , &node, null);

    try std.testing.expectEqual(@as(usize, 1), node.refs.items.len);
    try std.testing.expectEqualStrings("orders", node.refs.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), node.source_refs.items.len);
    try std.testing.expectEqualStrings("raw", node.source_refs.items[0].source_name);
    try std.testing.expectEqualStrings("events", node.source_refs.items[0].table_name);
}

test "sql scanner records refs and sources from static list loops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.looped",
        .name = "looped",
        .path = "looped.sql",
        .original_file_path = "models/looped.sql",
        .raw_code = "",
    };
    defer deinitTestNode(allocator, &node);

    try scanSql(allocator,
        \\{% set model_names = ['customers', "orders"] %}
        \\{% for model_name in model_names %}
        \\select * from {{ ref(model_name) }}
        \\{% endfor %}
        \\{% set table_names = ['events', 'payments'] %}
        \\{% for table_name in table_names %}
        \\union all select * from {{ source('raw', table_name) }}
        \\{% endfor %}
    , &node, null);

    try std.testing.expectEqual(@as(usize, 2), node.refs.items.len);
    try std.testing.expectEqualStrings("customers", node.refs.items[0].name);
    try std.testing.expectEqualStrings("orders", node.refs.items[1].name);
    try std.testing.expectEqual(@as(usize, 2), node.source_refs.items.len);
    try std.testing.expectEqualStrings("raw", node.source_refs.items[0].source_name);
    try std.testing.expectEqualStrings("events", node.source_refs.items[0].table_name);
    try std.testing.expectEqualStrings("raw", node.source_refs.items[1].source_name);
    try std.testing.expectEqualStrings("payments", node.source_refs.items[1].table_name);
}

test "sql scanner preserves literal refs in unknown loops without resolving loop vars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.looped",
        .name = "looped",
        .path = "looped.sql",
        .original_file_path = "models/looped.sql",
        .raw_code = "",
    };
    defer deinitTestNode(allocator, &node);

    try scanSql(allocator,
        \\{% for model_name in model_names %}
        \\select * from {{ ref('customers') }}
        \\{% endfor %}
    , &node, null);

    try std.testing.expectEqual(@as(usize, 1), node.refs.items.len);
    try std.testing.expectEqualStrings("customers", node.refs.items[0].name);
    try std.testing.expectError(error.UnsupportedDynamicRef, scanSql(allocator,
        \\{% for model_name in model_names %}
        \\select * from {{ ref(model_name) }}
        \\{% endfor %}
    , &node, null));
}

test "sql scanner preserves literal refs after unsupported scalar set statements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.scalar_set",
        .name = "scalar_set",
        .path = "scalar_set.sql",
        .original_file_path = "models/scalar_set.sql",
        .raw_code = "",
    };
    defer deinitTestNode(allocator, &node);

    try scanSql(allocator,
        \\{% set limit = 10 %}
        \\select * from {{ ref('customers') }}
    , &node, null);

    try std.testing.expectEqual(@as(usize, 1), node.refs.items.len);
    try std.testing.expectEqualStrings("customers", node.refs.items[0].name);
}

test "sql scanner loop scopes do not mutate static lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.scoped_loop",
        .name = "scoped_loop",
        .path = "scoped_loop.sql",
        .original_file_path = "models/scoped_loop.sql",
        .raw_code = "",
    };
    defer deinitTestNode(allocator, &node);

    try scanSql(allocator,
        \\{% set models = ['customers'] %}
        \\{% for model_name in models %}
        \\select * from {{ ref(model_name) }}
        \\{% set models = ['orders'] %}
        \\{% endfor %}
        \\union all select * from {{ ref('after_loop') }}
        \\{% for model_name in models %}
        \\union all select * from {{ ref(model_name) }}
        \\{% endfor %}
    , &node, null);

    try std.testing.expectEqual(@as(usize, 3), node.refs.items.len);
    try std.testing.expectEqualStrings("customers", node.refs.items[0].name);
    try std.testing.expectEqualStrings("after_loop", node.refs.items[1].name);
    try std.testing.expectEqualStrings("customers", node.refs.items[2].name);
}

test "sql scanner resolves loop-local list shadows before outer lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.shadowed_loop",
        .name = "shadowed_loop",
        .path = "shadowed_loop.sql",
        .original_file_path = "models/shadowed_loop.sql",
        .raw_code = "",
    };
    defer deinitTestNode(allocator, &node);

    try scanSql(allocator,
        \\{% set models = ['customers'] %}
        \\{% for model_name in models %}
        \\select * from {{ ref(model_name) }}
        \\{% set models = ['orders'] %}
        \\{% for model_name in models %}
        \\union all select * from {{ ref(model_name) }}
        \\{% endfor %}
        \\{% endfor %}
    , &node, null);

    try std.testing.expectEqual(@as(usize, 2), node.refs.items.len);
    try std.testing.expectEqualStrings("customers", node.refs.items[0].name);
    try std.testing.expectEqualStrings("orders", node.refs.items[1].name);
}

test "sql scanner loop scopes do not leak static lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.scoped_loop",
        .name = "scoped_loop",
        .path = "scoped_loop.sql",
        .original_file_path = "models/scoped_loop.sql",
        .raw_code = "",
    };
    defer deinitTestNode(allocator, &node);

    try std.testing.expectError(error.UnsupportedDynamicRef, scanSql(allocator,
        \\{% set models = ['customers'] %}
        \\{% for model_name in models %}
        \\select * from {{ ref(model_name) }}
        \\{% set inner_models = ['payments'] %}
        \\{% endfor %}
        \\{% for inner_model in inner_models %}
        \\union all select * from {{ ref(inner_model) }}
        \\{% endfor %}
    , &node, null));
}

test "sql scanner unsupported nested loops shadow outer loop variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.unsupported_nested_loop",
        .name = "unsupported_nested_loop",
        .path = "unsupported_nested_loop.sql",
        .original_file_path = "models/unsupported_nested_loop.sql",
        .raw_code = "",
    };
    defer deinitTestNode(allocator, &node);

    try std.testing.expectError(error.UnsupportedDynamicRef, scanSql(allocator,
        \\{% set models = ['customers'] %}
        \\{% for model_name in models %}
        \\select * from {{ ref(model_name) }}
        \\{% for model_name in unknown_models %}
        \\union all select * from {{ ref(model_name) }}
        \\{% endfor %}
        \\{% endfor %}
    , &node, null));
}

test "sql scanner unsupported destructuring loops shadow outer loop variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.unsupported_destructuring_loop",
        .name = "unsupported_destructuring_loop",
        .path = "unsupported_destructuring_loop.sql",
        .original_file_path = "models/unsupported_destructuring_loop.sql",
        .raw_code = "",
    };
    defer deinitTestNode(allocator, &node);

    try std.testing.expectError(error.UnsupportedDynamicRef, scanSql(allocator,
        \\{% set models = ['customers'] %}
        \\{% for model_name in models %}
        \\select * from {{ ref(model_name) }}
        \\{% for model_name, other_name in pairs %}
        \\union all select * from {{ ref(model_name) }}
        \\union all select * from {{ ref(other_name) }}
        \\{% endfor %}
        \\{% endfor %}
    , &node, null));
}

test "sql scanner unsupported loop fallback scans the for tag span" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.unsupported_loop_expression",
        .name = "unsupported_loop_expression",
        .path = "unsupported_loop_expression.sql",
        .original_file_path = "models/unsupported_loop_expression.sql",
        .raw_code = "",
    };
    defer deinitTestNode(allocator, &node);

    try scanSql(allocator,
        \\{% for relation in [ref('customers')] %}
        \\select 1
        \\{% endfor %}
    , &node, null);

    try std.testing.expectEqual(@as(usize, 1), node.refs.items.len);
    try std.testing.expectEqualStrings("customers", node.refs.items[0].name);
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

test "sql scanner uses package root and dbt macro namespace order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    _ = try appendTestMacro(&graph, "demo", "same_name");
    _ = try appendTestMacro(&graph, "demo", "root_only");
    _ = try appendTestMacro(&graph, "other_pkg", "package_only");
    _ = try appendTestMacro(&graph, "pkg", "same_name");
    _ = try appendTestMacro(&graph, "dbt", "internal_only");

    var package_node = Node{
        .package_name = "pkg",
        .unique_id = "model.pkg.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "",
    };
    defer deinitTestNode(allocator, &package_node);

    try scanSql(allocator,
        \\select {{ same_name('id') }}, {{ root_only('id') }}, {{ internal_only('id') }}
    , &package_node, &graph);

    try std.testing.expectEqual(@as(usize, 3), package_node.macro_depends_on.items.len);
    try std.testing.expectEqualStrings("macro.pkg.same_name", package_node.macro_depends_on.items[0]);
    try std.testing.expectEqualStrings("macro.demo.root_only", package_node.macro_depends_on.items[1]);
    try std.testing.expectEqualStrings("macro.dbt.internal_only", package_node.macro_depends_on.items[2]);
    try std.testing.expectError(error.UnsupportedJinja, scanSql(allocator, "select {{ package_only('id') }}", &package_node, &graph));

    var root_node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "",
    };
    defer deinitTestNode(allocator, &root_node);

    try scanSql(allocator, "select {{ same_name('id') }}", &root_node, &graph);
    try std.testing.expectEqual(@as(usize, 1), root_node.macro_depends_on.items.len);
    try std.testing.expectEqualStrings("macro.demo.same_name", root_node.macro_depends_on.items[0]);
}

test "sql scanner records literal adapter dispatch dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    _ = try appendTestMacro(&graph, "demo", "default__render_value");
    _ = try appendTestMacro(&graph, "pkg", "duckdb__render_value");
    _ = try appendTestMacro(&graph, "pkg", "default__package_value");
    _ = try appendTestMacro(&graph, "dbt", "default__internal_value");

    var node = Node{
        .package_name = "pkg",
        .unique_id = "model.pkg.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "",
    };
    defer deinitTestNode(allocator, &node);

    try scanSql(allocator,
        \\select
        \\  {{ adapter.dispatch('render_value')('customer_id') }},
        \\  {{ adapter.dispatch("package_value", "pkg")("customer_id") }},
        \\  {{ adapter.dispatch(macro_name='internal_value', macro_namespace='dbt')("customer_id") }}
    , &node, &graph);

    try std.testing.expectEqual(@as(usize, 3), node.macro_depends_on.items.len);
    try std.testing.expectEqualStrings("macro.pkg.duckdb__render_value", node.macro_depends_on.items[0]);
    try std.testing.expectEqualStrings("macro.pkg.default__package_value", node.macro_depends_on.items[1]);
    try std.testing.expectEqualStrings("macro.dbt.default__internal_value", node.macro_depends_on.items[2]);

    try std.testing.expectError(error.UnsupportedJinja, scanSql(allocator, "{{ adapter.dispatch(var('macro_name'))() }}", &node, &graph));
    try std.testing.expectError(error.UnsupportedJinja, scanSql(allocator, "{{ adapter.dispatch('pkg.render_value')() }}", &node, &graph));
    try std.testing.expectError(error.UnsupportedJinja, scanSql(allocator, "{{ adapter.dispatch('render_value', packages=['pkg'])() }}", &node, &graph));
    try std.testing.expectError(error.UnsupportedJinja, scanSql(allocator, "{{ adapter.dispatch(macro_name='render_value', 'pkg')() }}", &node, &graph));
    try std.testing.expectError(error.UnsupportedJinja, scanSql(allocator, "{{ adapter.dispatch(, 'render_value')() }}", &node, &graph));
    try std.testing.expectError(error.UnresolvedMacro, scanSql(allocator, "{{ adapter.dispatch('missing')() }}", &node, &graph));
}

test "sql scanner uses configured adapter dispatch search order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    _ = try appendTestMacro(&graph, "demo", "default__render_value");
    _ = try appendTestMacro(&graph, "override_pkg", "duckdb__render_value");
    _ = try appendTestMacro(&graph, "util_pkg", "duckdb__render_value");
    try appendTestDispatchConfig(&graph, "util_pkg", &[_][]const u8{ "override_pkg", "util_pkg" });

    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "",
    };
    defer deinitTestNode(allocator, &node);

    try scanSql(allocator, "select {{ adapter.dispatch('render_value', 'util_pkg')('customer_id') }}", &node, &graph);
    try std.testing.expectEqual(@as(usize, 1), node.macro_depends_on.items.len);
    try std.testing.expectEqualStrings("macro.override_pkg.duckdb__render_value", node.macro_depends_on.items[0]);
}

test "adapter dispatch prefixes come from graph adapter type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .adapter_type = "postgres" };
    defer graph.deinit();
    _ = try appendTestMacro(&graph, "demo", "duckdb__render_value");
    _ = try appendTestMacro(&graph, "demo", "postgres__render_value");
    _ = try appendTestMacro(&graph, "demo", "default__render_value");

    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "",
    };
    defer deinitTestNode(allocator, &node);

    try scanSql(allocator, "select {{ adapter.dispatch('render_value')('customer_id') }}", &node, &graph);
    try std.testing.expectEqual(@as(usize, 1), node.macro_depends_on.items.len);
    try std.testing.expectEqualStrings("macro.demo.postgres__render_value", node.macro_depends_on.items[0]);

    const redshift_prefixes = dispatchPrefixesForAdapter("redshift");
    try std.testing.expectEqual(@as(usize, 3), redshift_prefixes.slice().len);
    try std.testing.expectEqualStrings("redshift", redshift_prefixes.slice()[0]);
    try std.testing.expectEqualStrings("postgres", redshift_prefixes.slice()[1]);
    try std.testing.expectEqualStrings("default", redshift_prefixes.slice()[2]);

    const databricks_prefixes = dispatchPrefixesForAdapter("databricks");
    try std.testing.expectEqualStrings("spark", databricks_prefixes.slice()[1]);
}

test "adapter dispatch argument parser cleans up owned values on errors" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedJinja, parseAdapterDispatchArgs(allocator, "'render_value', packages='pkg'"));
    try std.testing.expectError(error.UnsupportedJinja, parseAdapterDispatchArgs(allocator, "'render_value', 'pkg', 'extra'"));
    try std.testing.expectError(error.UnsupportedJinja, parseAdapterDispatchArgs(allocator, "macro_name='render_value', macro_name='other'"));
    try std.testing.expectError(error.UnsupportedJinja, parseAdapterDispatchArgs(allocator, "'package.macro'"));
}

test "sql scanner resolves vars inside ref and source calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.vars.append(allocator, .{ .name = "orders_model", .value = "orders" });
    try graph.vars.append(allocator, .{ .name = "raw_table", .value = "payments" });

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
        \\select * from {{ ref(var('orders_model')) }}
        \\union all select * from {{ source('raw', var('raw_table')) }}
    , &node, &graph);

    try std.testing.expectEqual(@as(usize, 1), node.refs.items.len);
    try std.testing.expectEqualStrings("orders", node.refs.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), node.source_refs.items.len);
    try std.testing.expectEqualStrings("raw", node.source_refs.items[0].source_name);
    try std.testing.expectEqualStrings("payments", node.source_refs.items[0].table_name);
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

test "macro scanner uses package root and dbt macro namespace order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    _ = try appendTestMacro(&graph, "demo", "same_name");
    _ = try appendTestMacro(&graph, "demo", "root_only");
    const current_macro = try appendTestMacro(&graph, "pkg", "wrap");
    _ = try appendTestMacro(&graph, "pkg", "same_name");
    _ = try appendTestMacro(&graph, "other_pkg", "package_only");
    _ = try appendTestMacro(&graph, "dbt", "internal_only");

    var macro_depends_on: std.ArrayList([]const u8) = .empty;
    defer macro_depends_on.deinit(allocator);

    try scanMacroSqlForKnownMacroCalls(allocator,
        \\{% macro wrap(column_name) %}
        \\  {{ same_name(column_name) }}
        \\  {{ root_only(column_name) }}
        \\  {{ package_only(column_name) }}
        \\  {{ internal_only(column_name) }}
        \\{% endmacro %}
    , &graph, current_macro, &macro_depends_on);

    try std.testing.expectEqual(@as(usize, 4), macro_depends_on.items.len);
    try std.testing.expectEqualStrings("macro.pkg.same_name", macro_depends_on.items[0]);
    try std.testing.expectEqualStrings("macro.demo.root_only", macro_depends_on.items[1]);
    try std.testing.expectEqualStrings("macro.other_pkg.package_only", macro_depends_on.items[2]);
    try std.testing.expectEqualStrings("macro.dbt.internal_only", macro_depends_on.items[3]);
}

test "macro scanner records literal adapter dispatch dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    const current_macro = try appendTestMacro(&graph, "pkg", "wrap");
    _ = try appendTestMacro(&graph, "demo", "default__render_value");
    _ = try appendTestMacro(&graph, "pkg", "duckdb__render_value");
    _ = try appendTestMacro(&graph, "pkg", "default__package_value");

    var macro_depends_on: std.ArrayList([]const u8) = .empty;
    defer macro_depends_on.deinit(allocator);

    try scanMacroSqlForKnownMacroCalls(allocator,
        \\{% macro wrap(column_name) %}
        \\  {{ adapter.dispatch('render_value')(column_name) }}
        \\  {{ adapter.dispatch('package_value', macro_namespace='pkg')(column_name) }}
        \\{% endmacro %}
    , &graph, current_macro, &macro_depends_on);

    try std.testing.expectEqual(@as(usize, 2), macro_depends_on.items.len);
    try std.testing.expectEqualStrings("macro.pkg.duckdb__render_value", macro_depends_on.items[0]);
    try std.testing.expectEqualStrings("macro.pkg.default__package_value", macro_depends_on.items[1]);

    try std.testing.expectError(error.UnresolvedMacro, scanMacroSqlForKnownMacroCalls(allocator, "{{ adapter.dispatch('missing')() }}", &graph, current_macro, &macro_depends_on));
}

test "macro scanner records adapter dispatch dependencies inside return wrappers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    const current_macro = try appendTestMacro(&graph, "demo", "cents_to_dollars");
    _ = try appendTestMacro(&graph, "demo", "default__cents_to_dollars");

    var macro_depends_on: std.ArrayList([]const u8) = .empty;
    defer macro_depends_on.deinit(allocator);

    try scanMacroSqlForKnownMacroCalls(allocator,
        \\{% macro cents_to_dollars(column_name) %}
        \\  {{ return(adapter.dispatch('cents_to_dollars')(column_name)) }}
        \\{% endmacro %}
    , &graph, current_macro, &macro_depends_on);

    try std.testing.expectEqual(@as(usize, 1), macro_depends_on.items.len);
    try std.testing.expectEqualStrings("macro.demo.default__cents_to_dollars", macro_depends_on.items[0]);
}
