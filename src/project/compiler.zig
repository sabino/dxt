const std = @import("std");
const jinja = @import("jinja.zig");
const resolve = @import("resolve.zig");
const types = @import("types.zig");

const Graph = types.Graph;
const MacroDef = types.MacroDef;
const Node = types.Node;
const RefDep = types.RefDep;
const SourceDep = types.SourceDep;
const SourceDef = types.SourceDef;

const max_macro_render_depth = 8;

const Relation = struct {
    schema: []const u8,
    identifier: []const u8,
};

const StaticList = struct {
    name: []const u8,
    scope_depth: usize,
    values: std.ArrayList([]const u8) = .empty,
};

const StaticVar = struct {
    name: []const u8,
    value: []const u8,
};

const ForBlock = struct {
    variable_name: []const u8,
    list_name: []const u8,
    body_start: usize,
    body_end: usize,
    end_tag_close: usize,
};

const CompileContext = struct {
    allocator: std.mem.Allocator,
    graph: *const Graph,
    node: *const Node,
    lists: std.ArrayList(StaticList) = .empty,
    vars: std.ArrayList(StaticVar) = .empty,
    scope_depth: usize = 0,
    current_macro_package: ?[]const u8 = null,
    macro_render_depth: usize = 0,

    fn init(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node) CompileContext {
        return .{ .allocator = allocator, .graph = graph, .node = node };
    }

    fn deinit(self: *CompileContext) void {
        for (self.lists.items) |*list| {
            for (list.values.items) |value| self.allocator.free(value);
            list.values.deinit(self.allocator);
        }
        self.lists.deinit(self.allocator);
        self.vars.deinit(self.allocator);
    }

    fn setList(self: *CompileContext, name: []const u8, values: std.ArrayList([]const u8)) !void {
        for (self.lists.items) |*list| {
            if (list.scope_depth == self.scope_depth and std.mem.eql(u8, list.name, name)) {
                for (list.values.items) |value| self.allocator.free(value);
                list.values.deinit(self.allocator);
                list.values = values;
                return;
            }
        }
        try self.lists.append(self.allocator, .{ .name = name, .scope_depth = self.scope_depth, .values = values });
    }

    fn getList(self: *const CompileContext, name: []const u8) ?[]const []const u8 {
        var index = self.lists.items.len;
        while (index > 0) {
            index -= 1;
            const list = &self.lists.items[index];
            if (std.mem.eql(u8, list.name, name)) return list.values.items;
        }
        return null;
    }

    fn pushScope(self: *CompileContext) void {
        self.scope_depth += 1;
    }

    fn popScope(self: *CompileContext) void {
        while (self.lists.items.len > 0 and self.lists.items[self.lists.items.len - 1].scope_depth == self.scope_depth) {
            var list = self.lists.pop().?;
            for (list.values.items) |value| self.allocator.free(value);
            list.values.deinit(self.allocator);
        }
        self.scope_depth -= 1;
    }

    fn pushVar(self: *CompileContext, name: []const u8, value: []const u8) !void {
        try self.vars.append(self.allocator, .{ .name = name, .value = value });
    }

    fn popVar(self: *CompileContext) void {
        _ = self.vars.pop();
    }

    fn getVar(self: *const CompileContext, name: []const u8) ?[]const u8 {
        var index = self.vars.items.len;
        while (index > 0) {
            index -= 1;
            const variable = self.vars.items[index];
            if (std.mem.eql(u8, variable.name, name)) return variable.value;
        }
        return null;
    }
};

pub fn compileModel(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node) ![]const u8 {
    var context = CompileContext.init(allocator, graph, node);
    defer context.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try renderRange(&context, node.raw_code, 0, node.raw_code.len, &out);
    return try out.toOwnedSlice(allocator);
}

fn renderRange(context: *CompileContext, sql: []const u8, start: usize, end_index: usize, out: *std.ArrayList(u8)) anyerror!void {
    var index = start;
    while (index < end_index) {
        if (index + 1 >= end_index or sql[index] != '{') {
            try out.append(context.allocator, sql[index]);
            index += 1;
            continue;
        }

        const tag_kind = sql[index + 1];
        if (tag_kind == '#') {
            const close = std.mem.indexOfPos(u8, sql, index + 2, "#}") orelse return error.UnsupportedJinja;
            if (close + 2 > end_index) return error.UnsupportedJinja;
            index = close + 2;
            continue;
        }

        const close_marker: []const u8 = if (tag_kind == '{')
            "}}"
        else if (tag_kind == '%')
            "%}"
        else {
            try out.append(context.allocator, sql[index]);
            index += 1;
            continue;
        };
        const close = std.mem.indexOfPos(u8, sql, index + 2, close_marker) orelse return error.UnsupportedJinja;
        if (close + 2 > end_index) return error.UnsupportedJinja;
        const span = std.mem.trim(u8, sql[index + 2 .. close], " \t\r\n-");
        if (tag_kind == '{') {
            const rendered = try renderExpression(context, span);
            defer context.allocator.free(rendered);
            try out.appendSlice(context.allocator, rendered);
        } else {
            if (context.macro_render_depth > 0) return error.UnsupportedJinja;
            if (isEndForStatement(span)) return error.UnsupportedJinja;
            if (isForStatement(span)) {
                const block = try parseForBlock(sql, close + 2, span);
                const values = context.getList(block.list_name) orelse return error.UnsupportedJinja;
                if (values.len == 0) try validateSkippedLoopBody(context, sql, block);
                for (values) |value| {
                    context.pushScope();
                    try context.pushVar(block.variable_name, value);
                    renderRange(context, sql, block.body_start, block.body_end, out) catch |err| {
                        context.popVar();
                        context.popScope();
                        return err;
                    };
                    context.popVar();
                    context.popScope();
                }
                index = block.end_tag_close;
                continue;
            }
            try renderStatement(context, span);
        }
        index = close + 2;
    }
}

fn validateSkippedLoopBody(context: *CompileContext, sql: []const u8, block: ForBlock) anyerror!void {
    context.pushScope();
    context.pushVar(block.variable_name, "") catch |err| {
        context.popScope();
        return err;
    };
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(context.allocator);
    renderRange(context, sql, block.body_start, block.body_end, &scratch) catch |err| {
        context.popVar();
        context.popScope();
        return err;
    };
    context.popVar();
    context.popScope();
}

pub fn relationNameForNode(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node) ![]const u8 {
    const schema = try relationSchemaForNode(allocator, graph, node);
    defer allocator.free(schema);
    const identifier = relationIdentifierForNode(node);
    return renderRelation(allocator, .{ .schema = schema, .identifier = identifier });
}

fn renderExpression(context: *CompileContext, span: []const u8) ![]const u8 {
    const allocator = context.allocator;
    const graph = context.graph;
    const node = context.node;
    if (context.getVar(span)) |value| return try allocator.dupe(u8, value);
    if (context.macro_render_depth > 0 and
        (std.mem.eql(u8, span, "this") or std.mem.startsWith(u8, span, "this.") or std.mem.startsWith(u8, span, "target.")))
    {
        return error.UnsupportedJinja;
    }
    if (std.mem.eql(u8, span, "this")) {
        return try relationNameForNode(allocator, graph, node);
    }
    if (std.mem.startsWith(u8, span, "this.")) {
        return try renderThisAttribute(allocator, graph, node, span["this.".len..]);
    }
    if (std.mem.startsWith(u8, span, "target.")) {
        return try renderTargetAttribute(allocator, graph, span["target.".len..]);
    }
    if (std.mem.startsWith(u8, span, "adapter.dispatch")) {
        return try renderAdapterDispatchExpression(context, span);
    }

    const call = try parseSingleCall(span);
    const args = span[call.open + 1 .. call.close];
    if (call.package_name) |package_name| {
        if (context.macro_render_depth > 0) return error.UnsupportedJinja;
        if (resolve.findMacroIdByPackageAndName(graph, package_name, call.name)) |macro_id| {
            const macro = findMacroByUniqueId(graph, macro_id) orelse return error.UnresolvedMacro;
            return try renderMacroCall(context, macro, args);
        }
        return error.UnsupportedJinja;
    }
    if (std.mem.eql(u8, call.name, "config")) {
        return try allocator.dupe(u8, "");
    }
    if (std.mem.eql(u8, call.name, "return")) {
        const inner = std.mem.trim(u8, args, " \t\r\n");
        return try renderExpression(context, inner);
    }
    if (context.macro_render_depth > 0) return error.UnsupportedJinja;
    if (std.mem.eql(u8, call.name, "ref")) {
        var strings = try jinja.parseLiteralOrVarArgs(allocator, args, graph, error.UnsupportedDynamicRef);
        defer strings.deinit(allocator);
        if (!(strings.items.len == 1 or strings.items.len == 2)) return error.UnsupportedDynamicRef;
        const dep = RefDep{
            .package = if (strings.items.len == 2) strings.items[0] else null,
            .name = if (strings.items.len == 2) strings.items[1] else strings.items[0],
        };
        const unique_id = try resolve.resolveRefDependency(graph, node.package_name, dep);
        const target = findNodeByUniqueId(graph, unique_id) orelse return error.UnresolvedRef;
        return try relationNameForNode(allocator, graph, target);
    }
    if (std.mem.eql(u8, call.name, "source")) {
        var strings = try jinja.parseLiteralOrVarArgs(allocator, args, graph, error.UnsupportedDynamicSource);
        defer strings.deinit(allocator);
        if (strings.items.len != 2) return error.UnsupportedDynamicSource;
        const dep = SourceDep{ .source_name = strings.items[0], .table_name = strings.items[1] };
        const unique_id = try resolve.resolveSourceDependency(graph, node.package_name, dep);
        const source = findSourceByUniqueId(graph, unique_id) orelse return error.UnresolvedSource;
        return try renderRelation(allocator, .{ .schema = source.source_name, .identifier = source.table_name });
    }
    const current_package = context.current_macro_package orelse node.package_name;
    if (resolve.findMacroIdForUnqualifiedNamespaceCall(graph, current_package, call.name)) |macro_id| {
        const macro = findMacroByUniqueId(graph, macro_id) orelse return error.UnresolvedMacro;
        return try renderMacroCall(context, macro, args);
    }
    return error.UnsupportedJinja;
}

fn renderAdapterDispatchExpression(context: *CompileContext, span: []const u8) ![]const u8 {
    const allocator = context.allocator;
    const call = (try jinja.readJinjaCall(span, "adapter", "adapter".len)) orelse return error.UnsupportedJinja;
    if (call.package_name == null or !std.mem.eql(u8, call.package_name.?, "adapter") or !std.mem.eql(u8, call.name, "dispatch")) {
        return error.UnsupportedJinja;
    }

    const arg_open = jinja.skipWs(span, call.close + 1);
    if (arg_open >= span.len or span[arg_open] != '(') return error.UnsupportedJinja;
    const arg_close = findMatchingParen(span, arg_open) orelse return error.UnsupportedJinja;
    if (std.mem.trim(u8, span[arg_close + 1 ..], " \t\r\n").len != 0) return error.UnsupportedJinja;

    const dispatch_raw_args = span[call.open + 1 .. call.close];
    const dispatch_args = try jinja.parseAdapterDispatchArgs(allocator, dispatch_raw_args);
    defer jinja.deinitAdapterDispatchArgs(allocator, dispatch_args);

    const dispatch_prefixes = jinja.dispatchPrefixesForAdapter(context.graph.adapter_type);
    const current_package = context.current_macro_package orelse context.node.package_name;
    const macro_id = resolve.findMacroIdForAdapterDispatch(
        context.graph,
        current_package,
        dispatch_args.macro_name,
        dispatch_args.macro_namespace,
        dispatch_prefixes.slice(),
    ) orelse return error.UnresolvedMacro;
    const macro = findMacroByUniqueId(context.graph, macro_id) orelse return error.UnresolvedMacro;
    return try renderMacroCall(context, macro, span[arg_open + 1 .. arg_close]);
}

fn renderMacroCall(context: *CompileContext, macro: *const MacroDef, raw_args: []const u8) ![]const u8 {
    if (context.macro_render_depth >= max_macro_render_depth) return error.UnsupportedJinja;

    var block = try parseMacroBlock(context.allocator, macro);
    defer block.params.deinit(context.allocator);

    var values = try parseMacroArgumentValues(context.allocator, context, raw_args);
    defer {
        for (values.items) |value| context.allocator.free(value);
        values.deinit(context.allocator);
    }
    if (values.items.len != block.params.items.len) return error.UnsupportedJinja;

    const previous_package = context.current_macro_package;
    context.current_macro_package = macro.package_name;
    context.macro_render_depth += 1;
    context.pushScope();
    var pushed_vars: usize = 0;
    errdefer {
        var index = pushed_vars;
        while (index > 0) : (index -= 1) context.popVar();
        context.popScope();
        context.macro_render_depth -= 1;
        context.current_macro_package = previous_package;
    }

    for (block.params.items, values.items) |name, value| {
        try context.pushVar(name, value);
        pushed_vars += 1;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(context.allocator);
    try renderRange(context, macro.macro_sql, block.body.start, block.body.end, &out);

    var index = pushed_vars;
    while (index > 0) : (index -= 1) context.popVar();
    context.popScope();
    context.macro_render_depth -= 1;
    context.current_macro_package = previous_package;

    return try out.toOwnedSlice(context.allocator);
}

const MacroBodyRange = struct {
    start: usize,
    end: usize,
};

const ParsedMacroBlock = struct {
    body: MacroBodyRange,
    params: std.ArrayList([]const u8),
};

fn parseMacroBlock(allocator: std.mem.Allocator, macro: *const MacroDef) !ParsedMacroBlock {
    const open_start = std.mem.indexOf(u8, macro.macro_sql, "{%") orelse return error.UnsupportedJinja;
    const open_close = std.mem.indexOfPos(u8, macro.macro_sql, open_start + 2, "%}") orelse return error.UnsupportedJinja;
    const open_span = std.mem.trim(u8, macro.macro_sql[open_start + 2 .. open_close], " \t\r\n-");
    var params = try parseMacroParameters(allocator, open_span, macro.name);
    errdefer params.deinit(allocator);

    const body_start = open_close + 2;
    const body_end = findEndMacroTag(macro.macro_sql, body_start) orelse return error.UnsupportedJinja;
    return .{ .body = .{ .start = body_start, .end = body_end }, .params = params };
}

fn parseMacroParameters(allocator: std.mem.Allocator, span: []const u8, expected_name: []const u8) !std.ArrayList([]const u8) {
    if (!std.mem.startsWith(u8, span, "macro")) return error.UnsupportedJinja;
    var index: usize = "macro".len;
    if (index < span.len and jinja.isIdentChar(span[index])) return error.UnsupportedJinja;
    index = jinja.skipWs(span, index);

    const name_start = index;
    if (index >= span.len or !jinja.isIdentStart(span[index])) return error.UnsupportedJinja;
    index += 1;
    while (index < span.len and jinja.isIdentChar(span[index])) index += 1;
    const name = span[name_start..index];
    if (!std.mem.eql(u8, name, expected_name)) return error.UnsupportedJinja;

    index = jinja.skipWs(span, index);
    if (index >= span.len or span[index] != '(') return error.UnsupportedJinja;
    const close = findMatchingParen(span, index) orelse return error.UnsupportedJinja;
    if (std.mem.trim(u8, span[close + 1 ..], " \t\r\n").len != 0) return error.UnsupportedJinja;

    var params: std.ArrayList([]const u8) = .empty;
    errdefer params.deinit(allocator);
    var arg_index: usize = index + 1;
    while (true) {
        arg_index = jinja.skipWs(span, arg_index);
        if (arg_index >= close) break;
        if (span[arg_index] == ',') return error.UnsupportedJinja;
        const param_start = arg_index;
        if (!jinja.isIdentStart(span[arg_index])) return error.UnsupportedJinja;
        arg_index += 1;
        while (arg_index < close and jinja.isIdentChar(span[arg_index])) arg_index += 1;
        try params.append(allocator, span[param_start..arg_index]);
        arg_index = jinja.skipWs(span, arg_index);
        if (arg_index >= close) break;
        if (span[arg_index] != ',') return error.UnsupportedJinja;
        arg_index += 1;
    }
    return params;
}

fn parseMacroArgumentValues(allocator: std.mem.Allocator, context: *CompileContext, args: []const u8) !std.ArrayList([]const u8) {
    var values: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (values.items) |value| allocator.free(value);
        values.deinit(allocator);
    }

    var index: usize = 0;
    while (true) {
        index = jinja.skipWs(args, index);
        if (index >= args.len) break;
        if (args[index] == ',') return error.UnsupportedJinja;

        if (args[index] == '"' or args[index] == '\'') {
            const parsed = try jinja.parseQuoted(allocator, args, index);
            try values.append(allocator, parsed.value);
            index = jinja.skipWs(args, parsed.next);
        } else {
            const name_start = index;
            if (!jinja.isIdentStart(args[index])) return error.UnsupportedJinja;
            index += 1;
            while (index < args.len and jinja.isIdentChar(args[index])) index += 1;
            const name = args[name_start..index];
            const value = context.getVar(name) orelse return error.UnsupportedJinja;
            try values.append(allocator, try allocator.dupe(u8, value));
            index = jinja.skipWs(args, index);
        }

        if (index >= args.len) break;
        if (args[index] != ',') return error.UnsupportedJinja;
        index += 1;
    }
    return values;
}

fn findEndMacroTag(sql: []const u8, start: usize) ?usize {
    var index = start;
    while (index + 1 < sql.len) {
        if (sql[index] != '{' or sql[index + 1] != '%') {
            index += 1;
            continue;
        }
        const close = std.mem.indexOfPos(u8, sql, index + 2, "%}") orelse return null;
        const span = std.mem.trim(u8, sql[index + 2 .. close], " \t\r\n-");
        if (std.mem.eql(u8, span, "endmacro")) return index;
        index = close + 2;
    }
    return null;
}

fn findMatchingParen(text: []const u8, open: usize) ?usize {
    if (open >= text.len or text[open] != '(') return null;
    var depth: usize = 1;
    var index = open + 1;
    while (index < text.len) {
        if (text[index] == '"' or text[index] == '\'') {
            index = jinja.skipQuotedSpan(text, index) orelse return null;
            continue;
        }
        if (text[index] == '(') {
            depth += 1;
        } else if (text[index] == ')') {
            depth -= 1;
            if (depth == 0) return index;
        }
        index += 1;
    }
    return null;
}

fn renderThisAttribute(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node, attribute: []const u8) ![]const u8 {
    if (std.mem.eql(u8, attribute, "schema")) return try relationSchemaForNode(allocator, graph, node);
    if (std.mem.eql(u8, attribute, "name") or std.mem.eql(u8, attribute, "table") or std.mem.eql(u8, attribute, "identifier")) {
        return try allocator.dupe(u8, relationIdentifierForNode(node));
    }
    return error.UnsupportedJinja;
}

fn renderTargetAttribute(allocator: std.mem.Allocator, graph: *const Graph, attribute: []const u8) ![]const u8 {
    if (std.mem.eql(u8, attribute, "name") or std.mem.eql(u8, attribute, "target_name")) {
        return try allocator.dupe(u8, graph.target_name orelse "default");
    }
    if (std.mem.eql(u8, attribute, "schema")) return try allocator.dupe(u8, graph.target_schema);
    if (std.mem.eql(u8, attribute, "type")) return try allocator.dupe(u8, graph.adapter_type);
    if (std.mem.eql(u8, attribute, "profile_name")) return try allocator.dupe(u8, graph.profile_name orelse graph.project_name);
    return error.UnsupportedJinja;
}

fn renderStatement(context: *CompileContext, span: []const u8) !void {
    if (span.len == 0) return;
    if (std.mem.startsWith(u8, span, "set ")) {
        const assignment = try parseSetListStatement(context.allocator, span);
        try context.setList(assignment.name, assignment.values);
        return;
    }
    const call = try parseSingleCall(span);
    if (call.package_name == null and std.mem.eql(u8, call.name, "config")) return;
    return error.UnsupportedJinja;
}

const SetListAssignment = struct {
    name: []const u8,
    values: std.ArrayList([]const u8),
};

fn parseSetListStatement(allocator: std.mem.Allocator, span: []const u8) !SetListAssignment {
    var index: usize = "set ".len;
    index = jinja.skipWs(span, index);
    const name_start = index;
    if (index >= span.len or !jinja.isIdentStart(span[index])) return error.UnsupportedJinja;
    index += 1;
    while (index < span.len and jinja.isIdentChar(span[index])) index += 1;
    const name = span[name_start..index];
    index = jinja.skipWs(span, index);
    if (index >= span.len or span[index] != '=') return error.UnsupportedJinja;
    index = jinja.skipWs(span, index + 1);
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
        index = jinja.skipWs(trimmed, index);
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
        index = jinja.skipWs(trimmed, index);
        if (index >= end) return;
        if (trimmed[index] != ',') return error.UnsupportedJinja;
        index += 1;
    }
}

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
    var index: usize = "for".len;
    index = jinja.skipWs(span, index);
    const variable_start = index;
    if (index >= span.len or !jinja.isIdentStart(span[index])) return error.UnsupportedJinja;
    index += 1;
    while (index < span.len and jinja.isIdentChar(span[index])) index += 1;
    const variable_name = span[variable_start..index];
    index = jinja.skipWs(span, index);
    if (index + "in".len > span.len or !std.mem.eql(u8, span[index .. index + "in".len], "in")) return error.UnsupportedJinja;
    const before_ok = index == 0 or !jinja.isIdentChar(span[index - 1]);
    const after = index + "in".len;
    const after_ok = after >= span.len or !jinja.isIdentChar(span[after]);
    if (!before_ok or !after_ok) return error.UnsupportedJinja;
    index = jinja.skipWs(span, after);
    const list_start = index;
    if (index >= span.len or !jinja.isIdentStart(span[index])) return error.UnsupportedJinja;
    index += 1;
    while (index < span.len and jinja.isIdentChar(span[index])) index += 1;
    const list_name = span[list_start..index];
    if (std.mem.trim(u8, span[index..], " \t\r\n").len != 0) return error.UnsupportedJinja;

    const endfor = findMatchingEndFor(sql, body_start) orelse return error.UnsupportedJinja;
    return .{
        .variable_name = variable_name,
        .list_name = list_name,
        .body_start = body_start,
        .body_end = endfor.start,
        .end_tag_close = endfor.close,
    };
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

fn parseSingleCall(span: []const u8) !jinja.JinjaCall {
    var i: usize = 0;
    while (i < span.len and jinja.isIdentStart(span[i])) i += 1;
    if (i == 0) return error.UnsupportedJinja;
    const call = (try jinja.readJinjaCall(span, span[0..i], i)) orelse return error.UnsupportedJinja;
    if (std.mem.trim(u8, span[call.close + 1 ..], " \t\r\n").len != 0) return error.UnsupportedJinja;
    return call;
}

fn findNodeByUniqueId(graph: *const Graph, unique_id: []const u8) ?*const Node {
    for (graph.nodes.items) |*node| {
        if (std.mem.eql(u8, node.unique_id, unique_id)) return node;
    }
    return null;
}

fn findSourceByUniqueId(graph: *const Graph, unique_id: []const u8) ?*const SourceDef {
    for (graph.sources.items) |*source| {
        if (std.mem.eql(u8, source.unique_id, unique_id)) return source;
    }
    return null;
}

fn findMacroByUniqueId(graph: *const Graph, unique_id: []const u8) ?*const MacroDef {
    for (graph.macros.items) |*macro| {
        if (std.mem.eql(u8, macro.unique_id, unique_id)) return macro;
    }
    return null;
}

pub fn relationSchemaForNode(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node) ![]const u8 {
    if (node.config_schema) |custom_schema| {
        const trimmed = std.mem.trim(u8, custom_schema, " \t\r\n");
        return try std.fmt.allocPrint(allocator, "{s}_{s}", .{ graph.target_schema, trimmed });
    }
    return try allocator.dupe(u8, graph.target_schema);
}

pub fn relationIdentifierForNode(node: *const Node) []const u8 {
    if (node.config_alias) |custom_alias| {
        const trimmed = std.mem.trim(u8, custom_alias, " \t\r\n");
        if (trimmed.len != 0) return trimmed;
    }
    return node.name;
}

fn renderRelation(allocator: std.mem.Allocator, relation: Relation) ![]const u8 {
    const schema = try quoteIdentifier(allocator, relation.schema);
    defer allocator.free(schema);
    const identifier = try quoteIdentifier(allocator, relation.identifier);
    defer allocator.free(identifier);
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ schema, identifier });
}

pub fn quoteIdentifier(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (value) |byte| {
        if (byte == '"') try out.append(allocator, '"');
        try out.append(allocator, byte);
    }
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}

test "compileModel renders config refs and sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select 1",
    });
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select * from {{ ref('customers') }} union all select * from {{ source('raw', 'payments') }} {{ config(materialized='table') }}",
    });
    try graph.sources.append(allocator, .{
        .package_name = "demo",
        .unique_id = "source.demo.raw.payments",
        .source_name = "raw",
        .table_name = "payments",
        .original_file_path = "models/schema.yml",
    });

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[1]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("select * from \"main\".\"customers\" union all select * from \"raw\".\"payments\" ", compiled);
}

test "compileModel rejects dynamic ref" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select * from {{ ref(var('model_name')) }}",
    });
    try std.testing.expectError(error.UnresolvedVar, compileModel(allocator, &graph, &graph.nodes.items[0]));
}

test "compileModel resolves vars inside refs and sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    try graph.vars.append(allocator, .{ .name = "model_name", .value = "customers" });
    try graph.vars.append(allocator, .{ .name = "source_table", .value = "payments" });

    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select 1",
    });
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select * from {{ ref(var('model_name')) }} union all select * from {{ source('raw', var('source_table')) }}",
    });
    try graph.sources.append(allocator, .{
        .package_name = "demo",
        .unique_id = "source.demo.raw.payments",
        .source_name = "raw",
        .table_name = "payments",
        .original_file_path = "models/schema.yml",
    });

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[1]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("select * from \"analytics\".\"customers\" union all select * from \"raw\".\"payments\"", compiled);
}

test "compileModel expands static string-list for loops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code =
        \\{% set payment_methods = ['credit_card', 'coupon'] %}
        \\select
        \\{% for payment_method in payment_methods -%}
        \\  sum(case when payment_method = '{{ payment_method }}' then amount else 0 end) as {{ payment_method }}_amount,
        \\{% endfor -%}
        \\  sum(amount) as total_amount
        \\from {{ ref('payments') }}
        \\union all
        \\select
        \\{% for payment_method in payment_methods -%}
        \\  '{{ payment_method }}' as payment_method,
        \\{% endfor -%}
        \\  'done' as marker
        \\from payments
        ,
    });
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.payments",
        .name = "payments",
        .path = "payments.sql",
        .original_file_path = "models/payments.sql",
        .raw_code = "select 1",
    });

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[0]);
    defer allocator.free(compiled);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "credit_card_amount") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "coupon_amount") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "from \"main\".\"payments\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "{{") == null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "{%") == null);
}

test "compileModel renders Jaffle-style adapter-dispatched macro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo", .adapter_type = "duckdb" };
    defer graph.deinit();
    try graph.macros.append(allocator, .{
        .package_name = "demo",
        .unique_id = "macro.demo.cents_to_dollars",
        .name = "cents_to_dollars",
        .path = "macros/cents_to_dollars.sql",
        .original_file_path = "macros/cents_to_dollars.sql",
        .macro_sql = "{% macro cents_to_dollars(column_name) %}{{ return(adapter.dispatch('cents_to_dollars')(column_name)) }}{% endmacro %}",
    });
    try graph.macros.append(allocator, .{
        .package_name = "demo",
        .unique_id = "macro.demo.default__cents_to_dollars",
        .name = "default__cents_to_dollars",
        .path = "macros/cents_to_dollars.sql",
        .original_file_path = "macros/cents_to_dollars.sql",
        .macro_sql = "{% macro default__cents_to_dollars(column_name) %}({{ column_name }} / 100)::numeric(16, 2){% endmacro %}",
    });
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select {{ cents_to_dollars('subtotal') }} as subtotal",
    });

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[0]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("select (subtotal / 100)::numeric(16, 2) as subtotal", compiled);
}

test "compileModel prefers adapter-specific dispatched macro implementation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo", .adapter_type = "duckdb" };
    defer graph.deinit();
    try graph.macros.append(allocator, .{
        .package_name = "demo",
        .unique_id = "macro.demo.cents_to_dollars",
        .name = "cents_to_dollars",
        .path = "macros/cents_to_dollars.sql",
        .original_file_path = "macros/cents_to_dollars.sql",
        .macro_sql = "{% macro cents_to_dollars(column_name) %}{{ return(adapter.dispatch('cents_to_dollars')(column_name)) }}{% endmacro %}",
    });
    try graph.macros.append(allocator, .{
        .package_name = "demo",
        .unique_id = "macro.demo.default__cents_to_dollars",
        .name = "default__cents_to_dollars",
        .path = "macros/cents_to_dollars.sql",
        .original_file_path = "macros/cents_to_dollars.sql",
        .macro_sql = "{% macro default__cents_to_dollars(column_name) %}default({{ column_name }}){% endmacro %}",
    });
    try graph.macros.append(allocator, .{
        .package_name = "demo",
        .unique_id = "macro.demo.duckdb__cents_to_dollars",
        .name = "duckdb__cents_to_dollars",
        .path = "macros/cents_to_dollars.sql",
        .original_file_path = "macros/cents_to_dollars.sql",
        .macro_sql = "{% macro duckdb__cents_to_dollars(column_name) %}duck({{ column_name }}){% endmacro %}",
    });
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select {{ cents_to_dollars(\"subtotal\") }} as subtotal",
    });

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[0]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("select duck(subtotal) as subtotal", compiled);
}

test "compileModel rejects unsupported statements inside macros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.macros.append(allocator, .{
        .package_name = "demo",
        .unique_id = "macro.demo.render_value",
        .name = "render_value",
        .path = "macros/render_value.sql",
        .original_file_path = "macros/render_value.sql",
        .macro_sql = "{% macro render_value(column_name) %}{% if true %}{{ column_name }}{% endif %}{% endmacro %}",
    });
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select {{ render_value('subtotal') }} as subtotal",
    });

    try std.testing.expectError(error.UnsupportedJinja, compileModel(allocator, &graph, &graph.nodes.items[0]));
}

test "compileModel expands empty static string-list for loops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "{% set payment_methods = [] %}select{% for payment_method in payment_methods %} {{ payment_method }},{% endfor %} 1 as marker",
    });

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[0]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("select 1 as marker", compiled);
}

test "compileModel rejects static for loops over unknown lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "{% for payment_method in payment_methods %}{{ payment_method }}{% endfor %}",
    });

    try std.testing.expectError(error.UnsupportedJinja, compileModel(allocator, &graph, &graph.nodes.items[0]));
}

test "compileModel rejects non-list static set values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "{% set payment_methods = 'credit_card' %}select 1",
    });

    try std.testing.expectError(error.UnsupportedJinja, compileModel(allocator, &graph, &graph.nodes.items[0]));
}

test "compileModel rejects unquoted static list values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "{% set payment_methods = [credit_card] %}select 1",
    });

    try std.testing.expectError(error.UnsupportedJinja, compileModel(allocator, &graph, &graph.nodes.items[0]));
}

test "compileModel keeps static set assignments loop-local" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "{% set xs = ['a'] %}{% for x in xs %}{% set ys = ['b'] %}{% endfor %}{% for y in ys %}{{ y }}{% endfor %}",
    });

    try std.testing.expectError(error.UnsupportedJinja, compileModel(allocator, &graph, &graph.nodes.items[0]));
}

test "compileModel keeps iteration values stable when loop body shadows source list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "{% set xs = ['a', 'b'] %}{% for x in xs %}{{ x }}{% set xs = ['z'] %}{% endfor %}",
    });

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[0]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("ab", compiled);
}

test "compileModel rejects unsupported for else blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "{% set xs = [] %}{% for x in xs %}{{ x }}{% else %}empty{% endfor %}",
    });

    try std.testing.expectError(error.UnsupportedJinja, compileModel(allocator, &graph, &graph.nodes.items[0]));
}

test "compileModel validates unsupported syntax inside empty static loops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "{% set xs = [] %}{% for x in xs %}{% if true %}{{ x }}{% endif %}{% endfor %}select 1",
    });

    try std.testing.expectError(error.UnsupportedJinja, compileModel(allocator, &graph, &graph.nodes.items[0]));
}

test "compileModel rejects escaped static list values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "{% set xs = ['a\\n'] %}select 1",
    });

    try std.testing.expectError(error.UnsupportedJinja, compileModel(allocator, &graph, &graph.nodes.items[0]));
}

test "relationNameForNode quotes identifiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.customer_order",
        .name = "customer_order",
        .path = "customer_order.sql",
        .original_file_path = "models/customer_order.sql",
        .raw_code = "select 1",
    };
    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    const relation = try relationNameForNode(allocator, &graph, &node);
    defer allocator.free(relation);
    try std.testing.expectEqualStrings("\"analytics\".\"customer_order\"", relation);
}

test "relationNameForNode applies inline schema and alias defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select 1",
        .config_schema = "mart",
        .config_alias = "order_facts",
    };
    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    const relation = try relationNameForNode(allocator, &graph, &node);
    defer allocator.free(relation);
    try std.testing.expectEqualStrings("\"analytics_mart\".\"order_facts\"", relation);
}

test "compileModel renders target and this context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{
        .allocator = allocator,
        .project_name = "demo",
        .adapter_type = "postgres",
        .target_schema = "analytics",
        .profile_name = "demo_profile",
        .target_name = "dev",
    };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .config_schema = "mart",
        .config_alias = "order_facts",
        .raw_code = "select '{{ target.profile_name }}' as profile_name, '{{ target.name }}' as target_name, '{{ target.target_name }}' as target_name_alias, '{{ target.type }}' as adapter_type, '{{ target.schema }}' as target_schema, '{{ this.schema }}' as this_schema, '{{ this.name }}' as this_name, '{{ this.table }}' as this_table, '{{ this.identifier }}' as this_identifier from {{ this }}",
    });

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[0]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings(
        "select 'demo_profile' as profile_name, 'dev' as target_name, 'dev' as target_name_alias, 'postgres' as adapter_type, 'analytics' as target_schema, 'analytics_mart' as this_schema, 'order_facts' as this_name, 'order_facts' as this_table, 'order_facts' as this_identifier from \"analytics_mart\".\"order_facts\"",
        compiled,
    );
}
