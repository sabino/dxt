const std = @import("std");
const jinja = @import("jinja.zig");
const resolve = @import("resolve.zig");
const types = @import("types.zig");

const Graph = types.Graph;
const GenericTestNode = types.GenericTestNode;
const MacroDef = types.MacroDef;
const Node = types.Node;
const RefDep = types.RefDep;
const SingularTestNode = types.SingularTestNode;
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

const IfBlock = struct {
    condition_value: bool,
    body_start: usize,
    body_end: usize,
    else_body_start: ?usize = null,
    else_body_end: ?usize = null,
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
    validating_skipped_loop_body: bool = false,

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

pub fn compileSingularTest(allocator: std.mem.Allocator, graph: *const Graph, test_node: *const SingularTestNode) ![]const u8 {
    const node = Node{
        .resource_type = "test",
        .package_name = test_node.package_name,
        .unique_id = test_node.unique_id,
        .name = test_node.name,
        .path = test_node.path,
        .original_file_path = test_node.original_file_path,
        .raw_code = test_node.raw_code,
        .materialized = "test",
    };
    var context = CompileContext.init(allocator, graph, &node);
    defer context.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try renderRange(&context, test_node.raw_code, 0, test_node.raw_code.len, &out);
    return try out.toOwnedSlice(allocator);
}

pub fn compileGenericTest(allocator: std.mem.Allocator, graph: *const Graph, test_node: *const GenericTestNode) ![]const u8 {
    const column_name = genericTestNodeColumnName(test_node) orelse return error.UnsupportedTestExecution;
    const is_not_null = std.mem.eql(u8, test_node.test_name, "not_null");
    const is_unique = std.mem.eql(u8, test_node.test_name, "unique");
    const is_accepted_values = std.mem.eql(u8, test_node.test_name, "accepted_values");
    const is_relationships = std.mem.eql(u8, test_node.test_name, "relationships");
    if (!is_not_null and !is_unique and !is_accepted_values and !is_relationships) {
        return error.UnsupportedTestExecution;
    }
    if (is_accepted_values and test_node.accepted_values.items.len == 0) return error.UnsupportedTestExecution;
    if (is_relationships and (test_node.relationship_to.len == 0 or test_node.relationship_field.len == 0)) return error.UnsupportedTestExecution;

    const relation_name = try genericTestRelationName(allocator, graph, test_node);
    defer allocator.free(relation_name);
    const model_sql = try genericTestModelSql(allocator, relation_name, test_node.config.where);
    defer allocator.free(model_sql);
    const quoted_column = try quoteIdentifier(allocator, column_name);
    defer allocator.free(quoted_column);

    if (is_not_null) {
        const sql = try std.fmt.allocPrint(
            allocator,
            "select {s}\nfrom {s}\nwhere {s} is null",
            .{ quoted_column, model_sql, quoted_column },
        );
        return try applyGenericTestLimit(allocator, sql, test_node.config.limit);
    }
    if (is_accepted_values) {
        const accepted_values = try renderAcceptedValuesList(allocator, test_node.accepted_values.items, test_node.accepted_values_quote orelse true);
        defer allocator.free(accepted_values);
        const sql = try std.fmt.allocPrint(
            allocator,
            "with all_values as (\n    select\n        {s} as value_field,\n        count(*) as n_records\n    from {s}\n    group by {s}\n)\nselect *\nfrom all_values\nwhere value_field not in ({s})",
            .{ quoted_column, model_sql, quoted_column, accepted_values },
        );
        return try applyGenericTestLimit(allocator, sql, test_node.config.limit);
    }
    if (is_relationships) {
        const parent_relation_name = try relationshipTargetRelationName(allocator, graph, test_node);
        defer allocator.free(parent_relation_name);
        const quoted_parent_field = try quoteIdentifier(allocator, test_node.relationship_field);
        defer allocator.free(quoted_parent_field);
        const sql = try std.fmt.allocPrint(
            allocator,
            "with child as (\n    select {s} as from_field\n    from {s}\n    where {s} is not null\n),\nparent as (\n    select {s} as to_field\n    from {s}\n)\nselect\n    from_field\nfrom child\nleft join parent\n    on child.from_field = parent.to_field\nwhere parent.to_field is null",
            .{ quoted_column, model_sql, quoted_column, quoted_parent_field, parent_relation_name },
        );
        return try applyGenericTestLimit(allocator, sql, test_node.config.limit);
    }
    const sql = try std.fmt.allocPrint(
        allocator,
        "select\n    {s} as unique_field,\n    count(*) as n_records\nfrom {s}\nwhere {s} is not null\ngroup by {s}\nhaving count(*) > 1",
        .{ quoted_column, model_sql, quoted_column, quoted_column },
    );
    return try applyGenericTestLimit(allocator, sql, test_node.config.limit);
}

fn genericTestModelSql(allocator: std.mem.Allocator, relation_name: []const u8, where_sql: ?[]const u8) ![]const u8 {
    if (where_sql) |filter| {
        return try std.fmt.allocPrint(allocator, "(select * from {s} where {s}) dbt_subquery", .{ relation_name, filter });
    }
    return try allocator.dupe(u8, relation_name);
}

fn applyGenericTestLimit(allocator: std.mem.Allocator, sql: []const u8, limit: ?u64) ![]const u8 {
    if (limit) |row_limit| {
        defer allocator.free(sql);
        return try std.fmt.allocPrint(allocator, "{s}\nlimit {d}", .{ sql, row_limit });
    }
    return sql;
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
            if (isEndIfStatement(span) or isElseStatement(span) or isElifStatement(span)) return error.UnsupportedJinja;
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
            if (isIfStatement(span)) {
                const block = try parseIfBlock(sql, close + 2, span);
                if (block.condition_value) {
                    try renderRange(context, sql, block.body_start, block.body_end, out);
                } else if (block.else_body_start) |else_start| {
                    try renderRange(context, sql, else_start, block.else_body_end.?, out);
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
    const previous_validation_mode = context.validating_skipped_loop_body;
    context.validating_skipped_loop_body = true;
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(context.allocator);
    renderRange(context, sql, block.body_start, block.body_end, &scratch) catch |err| {
        context.validating_skipped_loop_body = previous_validation_mode;
        context.popVar();
        context.popScope();
        return err;
    };
    context.validating_skipped_loop_body = previous_validation_mode;
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
        var strings = try parseCompileStringArgs(context, args, error.UnsupportedDynamicRef);
        defer strings.deinit(allocator);
        if (!(strings.items.items.len == 1 or strings.items.items.len == 2)) return error.UnsupportedDynamicRef;
        if (context.validating_skipped_loop_body and strings.used_local_binding) return try allocator.dupe(u8, "");
        const dep = RefDep{
            .package = if (strings.items.items.len == 2) strings.items.items[0] else null,
            .name = if (strings.items.items.len == 2) strings.items.items[1] else strings.items.items[0],
        };
        const unique_id = try resolve.resolveRefDependency(graph, node.package_name, dep);
        const target = findNodeByUniqueId(graph, unique_id) orelse return error.UnresolvedRef;
        return try relationNameForNode(allocator, graph, target);
    }
    if (std.mem.eql(u8, call.name, "source")) {
        var strings = try parseCompileStringArgs(context, args, error.UnsupportedDynamicSource);
        defer strings.deinit(allocator);
        if (strings.items.items.len != 2) return error.UnsupportedDynamicSource;
        if (context.validating_skipped_loop_body and strings.used_local_binding) return try allocator.dupe(u8, "");
        const dep = SourceDep{ .source_name = strings.items.items[0], .table_name = strings.items.items[1] };
        const unique_id = try resolve.resolveSourceDependency(graph, node.package_name, dep);
        const source = findSourceByUniqueId(graph, unique_id) orelse return error.UnresolvedSource;
        return try relationNameForSource(allocator, source);
    }
    const current_package = context.current_macro_package orelse node.package_name;
    if (resolve.findMacroIdForUnqualifiedNamespaceCall(graph, current_package, call.name)) |macro_id| {
        const macro = findMacroByUniqueId(graph, macro_id) orelse return error.UnresolvedMacro;
        return try renderMacroCall(context, macro, args);
    }
    return error.UnsupportedJinja;
}

const CompileStringArgs = struct {
    items: std.ArrayList([]const u8) = .empty,
    used_local_binding: bool = false,

    fn deinit(self: *CompileStringArgs, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }
};

fn parseCompileStringArgs(context: *CompileContext, args: []const u8, unsupported_error: anyerror) !CompileStringArgs {
    const allocator = context.allocator;
    var strings = CompileStringArgs{};
    errdefer strings.deinit(allocator);

    var index: usize = 0;
    var saw_arg = false;
    while (index < args.len) {
        index = jinja.skipWs(args, index);
        if (index >= args.len) break;
        if (args[index] == ',') {
            index += 1;
            continue;
        }

        if (args[index] == '"' or args[index] == '\'') {
            const parsed = try jinja.parseQuoted(allocator, args, index);
            try strings.items.append(allocator, parsed.value);
            saw_arg = true;
            index = jinja.skipWs(args, parsed.next);
        } else if (std.mem.startsWith(u8, args[index..], "var")) {
            if (readCompileVarCall(context, args, index, unsupported_error)) |parsed| {
                try strings.items.append(allocator, parsed.value);
                saw_arg = true;
                index = jinja.skipWs(args, parsed.next);
            } else |err| switch (err) {
                error.NotCompileVarCall => {
                    const parsed = try readCompileLocalArg(context, args, index, unsupported_error);
                    try strings.items.append(allocator, parsed.value);
                    strings.used_local_binding = true;
                    saw_arg = true;
                    index = jinja.skipWs(args, parsed.next);
                },
                else => return err,
            }
        } else if (jinja.isIdentStart(args[index])) {
            const parsed = try readCompileLocalArg(context, args, index, unsupported_error);
            try strings.items.append(allocator, parsed.value);
            strings.used_local_binding = true;
            saw_arg = true;
            index = jinja.skipWs(args, parsed.next);
        } else {
            return unsupported_error;
        }

        if (index < args.len and args[index] != ',') return unsupported_error;
    }
    if (!saw_arg) return unsupported_error;
    return strings;
}

const CompileStringArg = struct {
    value: []const u8,
    next: usize,
};

const NotCompileVarCall = error{NotCompileVarCall};

fn readCompileVarCall(
    context: *CompileContext,
    args: []const u8,
    start: usize,
    unsupported_error: anyerror,
) (NotCompileVarCall || anyerror)!CompileStringArg {
    const call = (jinja.readJinjaCall(args, "var", start + "var".len) catch return unsupported_error) orelse return error.NotCompileVarCall;
    if (call.package_name != null or !std.mem.eql(u8, call.name, "var")) return unsupported_error;

    var var_name_args = try jinja.parseLiteralArgs(context.allocator, args[call.open + 1 .. call.close], unsupported_error);
    defer var_name_args.deinit(context.allocator);
    if (!(var_name_args.items.len == 1 or var_name_args.items.len == 2)) return unsupported_error;

    if (findGraphVarValue(context.graph, var_name_args.items[0])) |resolved_value| {
        return .{ .value = resolved_value, .next = call.close + 1 };
    }
    if (var_name_args.items.len == 2) {
        return .{ .value = var_name_args.items[1], .next = call.close + 1 };
    }
    return error.UnresolvedVar;
}

fn readCompileLocalArg(
    context: *CompileContext,
    args: []const u8,
    start: usize,
    unsupported_error: anyerror,
) !CompileStringArg {
    var end = start;
    if (end >= args.len or !jinja.isIdentStart(args[end])) return unsupported_error;
    end += 1;
    while (end < args.len and jinja.isIdentChar(args[end])) end += 1;
    const name = args[start..end];
    const value = context.getVar(name) orelse return unsupported_error;
    return .{ .value = value, .next = end };
}

fn findGraphVarValue(graph: *const Graph, name: []const u8) ?[]const u8 {
    for (graph.vars.items) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.value;
    }
    return null;
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

fn isIfStatement(span: []const u8) bool {
    return std.mem.startsWith(u8, span, "if ") or std.mem.eql(u8, span, "if");
}

fn isEndIfStatement(span: []const u8) bool {
    return std.mem.eql(u8, span, "endif");
}

fn isElifStatement(span: []const u8) bool {
    return std.mem.startsWith(u8, span, "elif ") or std.mem.eql(u8, span, "elif");
}

fn parseIfBlock(sql: []const u8, body_start: usize, span: []const u8) !IfBlock {
    const condition_value = try parseStaticIfCondition(span);
    const endif = try findMatchingEndIf(sql, body_start);
    return .{
        .condition_value = condition_value,
        .body_start = body_start,
        .body_end = endif.body_end,
        .else_body_start = endif.else_body_start,
        .else_body_end = endif.else_body_end,
        .end_tag_close = endif.end_tag_close,
    };
}

fn parseStaticIfCondition(span: []const u8) !bool {
    if (!isIfStatement(span)) return error.UnsupportedJinja;
    const condition = std.mem.trim(u8, span["if".len..], " \t\r\n");
    if (std.ascii.eqlIgnoreCase(condition, "true")) return true;
    if (std.ascii.eqlIgnoreCase(condition, "false")) return false;
    if (std.mem.eql(u8, condition, "execute")) return true;
    if (std.mem.eql(u8, condition, "not execute")) return false;
    if (std.mem.eql(u8, condition, "is_incremental()")) return false;
    if (std.mem.eql(u8, condition, "not is_incremental()")) return true;
    return error.UnsupportedJinja;
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

const EndIfTag = struct {
    body_end: usize,
    else_body_start: ?usize = null,
    else_body_end: ?usize = null,
    end_tag_close: usize,
};

fn findMatchingEndIf(sql: []const u8, start: usize) !EndIfTag {
    var index = start;
    var depth: usize = 1;
    var else_start: ?usize = null;
    var else_close: ?usize = null;
    while (index + 1 < sql.len) {
        if (sql[index] != '{') {
            index += 1;
            continue;
        }
        if (sql[index + 1] == '#') {
            const close = std.mem.indexOfPos(u8, sql, index + 2, "#}") orelse return error.UnsupportedJinja;
            index = close + 2;
            continue;
        }
        if (sql[index + 1] != '%') {
            index += 1;
            continue;
        }
        const close = std.mem.indexOfPos(u8, sql, index + 2, "%}") orelse return error.UnsupportedJinja;
        const span = std.mem.trim(u8, sql[index + 2 .. close], " \t\r\n-");
        if (isIfStatement(span)) {
            depth += 1;
        } else if (isEndIfStatement(span)) {
            depth -= 1;
            if (depth == 0) {
                return .{
                    .body_end = else_start orelse index,
                    .else_body_start = else_close,
                    .else_body_end = if (else_start != null) index else null,
                    .end_tag_close = close + 2,
                };
            }
        } else if (depth == 1 and isElifStatement(span)) {
            return error.UnsupportedJinja;
        } else if (depth == 1 and isElseStatement(span)) {
            if (else_start != null) return error.UnsupportedJinja;
            else_start = index;
            else_close = close + 2;
        }
        index = close + 2;
    }
    return error.UnsupportedJinja;
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

fn findSourceByRef(graph: *const Graph, source_ref: SourceDep) ?*const SourceDef {
    for (graph.sources.items) |*source| {
        if (std.mem.eql(u8, source.source_name, source_ref.source_name) and std.mem.eql(u8, source.table_name, source_ref.table_name)) return source;
    }
    return null;
}

fn genericTestNodeColumnName(test_node: *const GenericTestNode) ?[]const u8 {
    return test_node.argument_column_name orelse test_node.column_name;
}

fn genericTestRelationName(allocator: std.mem.Allocator, graph: *const Graph, test_node: *const GenericTestNode) ![]const u8 {
    if (test_node.attached_node) |attached_unique_id| {
        const attached_node = findNodeByUniqueId(graph, attached_unique_id) orelse return error.UnsupportedTestExecution;
        if (attached_node.relation_name) |relation_name| return try allocator.dupe(u8, relation_name);
        return try relationNameForNode(allocator, graph, attached_node);
    }
    if (test_node.attached_source_unique_id) |unique_id| {
        const source = findSourceByUniqueId(graph, unique_id) orelse return error.UnsupportedTestExecution;
        return try relationNameForSource(allocator, source);
    }
    const source_ref = test_node.attached_source orelse blk: {
        if (test_node.source_refs.items.len != 1) return error.UnsupportedTestExecution;
        break :blk test_node.source_refs.items[0];
    };
    const source = findSourceByRef(graph, source_ref) orelse return error.UnsupportedTestExecution;
    return try relationNameForSource(allocator, source);
}

fn relationshipTargetRelationName(allocator: std.mem.Allocator, graph: *const Graph, test_node: *const GenericTestNode) ![]const u8 {
    if (test_node.relationship_source_to_unique_id) |unique_id| {
        const source = findSourceByUniqueId(graph, unique_id) orelse return error.UnsupportedTestExecution;
        return try relationNameForSource(allocator, source);
    }
    if (test_node.relationship_source_to) |source_ref| {
        const source = findSourceByRef(graph, source_ref) orelse return error.UnsupportedTestExecution;
        return try relationNameForSource(allocator, source);
    }
    const parent_node = findRelationshipTargetNode(graph, test_node) orelse return error.UnsupportedTestExecution;
    if (parent_node.relation_name) |relation_name| return try allocator.dupe(u8, relation_name);
    return try relationNameForNode(allocator, graph, parent_node);
}

fn findRelationshipTargetNode(graph: *const Graph, test_node: *const GenericTestNode) ?*const Node {
    var attached: ?*const Node = null;
    for (test_node.depends_on.items) |unique_id| {
        const node = findNodeByUniqueId(graph, unique_id) orelse continue;
        if (test_node.attached_node) |attached_unique_id| {
            if (std.mem.eql(u8, unique_id, attached_unique_id)) {
                attached = node;
                continue;
            }
        }
        return node;
    }
    return attached;
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

pub fn relationNameForSource(allocator: std.mem.Allocator, source: *const SourceDef) ![]const u8 {
    return renderRelation(allocator, .{ .schema = sourceSchemaName(source), .identifier = sourceIdentifier(source) });
}

pub fn sourceSchemaName(source: *const SourceDef) []const u8 {
    if (source.schema_name) |schema_name| {
        const trimmed = std.mem.trim(u8, schema_name, " \t\r\n");
        if (trimmed.len != 0) return trimmed;
    }
    return source.source_name;
}

pub fn sourceIdentifier(source: *const SourceDef) []const u8 {
    if (source.identifier) |identifier| {
        const trimmed = std.mem.trim(u8, identifier, " \t\r\n");
        if (trimmed.len != 0) return trimmed;
    }
    return source.table_name;
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

fn quoteSqlString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') try out.append(allocator, '\'');
        try out.append(allocator, byte);
    }
    try out.append(allocator, '\'');
    return try out.toOwnedSlice(allocator);
}

fn renderAcceptedValuesList(allocator: std.mem.Allocator, values: []const []const u8, quote_values: bool) ![]const u8 {
    if (values.len == 0) return error.UnsupportedTestExecution;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (values, 0..) |value, index| {
        if (index != 0) try out.appendSlice(allocator, ", ");
        if (quote_values) {
            const quoted = try quoteSqlString(allocator, value);
            defer allocator.free(quoted);
            try out.appendSlice(allocator, quoted);
        } else {
            try out.appendSlice(allocator, value);
        }
    }
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
        .identifier = "raw_payments",
        .original_file_path = "models/schema.yml",
        .schema_name = "raw_source",
    });

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[1]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("select * from \"main\".\"customers\" union all select * from \"raw_source\".\"raw_payments\" ", compiled);
}

test "compileSingularTest renders refs and sources" {
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
    try graph.sources.append(allocator, .{
        .package_name = "demo",
        .unique_id = "source.demo.raw.payments",
        .source_name = "raw",
        .table_name = "payments",
        .identifier = "raw_payments",
        .original_file_path = "models/schema.yml",
        .schema_name = "raw_source",
    });
    try graph.singular_tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.assert_customers",
        .name = "assert_customers",
        .alias = "assert_customers",
        .path = "assert_customers.sql",
        .original_file_path = "tests/assert_customers.sql",
        .raw_code = "select * from {{ ref('customers') }} union all select * from {{ source('raw', 'payments') }};",
    });

    const compiled = try compileSingularTest(allocator, &graph, &graph.singular_tests.items[0]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("select * from \"main\".\"customers\" union all select * from \"raw_source\".\"raw_payments\";", compiled);
}

test "compileGenericTest renders supported built-in failure-row SQL" {
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
        .materialized = "table",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.accepted_values_customers_customer_type.abc",
        .name = "accepted_values_customers_customer_type",
        .alias = "accepted_values_customers_customer_type",
        .path = "accepted_values_customers_customer_type.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_accepted_values(**_dbt_generic_test_kwargs) }}",
        .test_name = "accepted_values",
        .column_name = "customer_type",
        .attached_node = "model.demo.customers",
    });
    try graph.tests.items[0].accepted_values.append(allocator, "new");
    try graph.tests.items[0].accepted_values.append(allocator, "returning");
    try graph.tests.items[0].depends_on.append(allocator, "model.demo.customers");

    const compiled = try compileGenericTest(allocator, &graph, &graph.tests.items[0]);
    defer allocator.free(compiled);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "with all_values as") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "\"customer_type\" as value_field") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "from \"main\".\"customers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "value_field not in ('new', 'returning')") != null);
}

test "compileGenericTest applies where and limit configs to failure-row SQL" {
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
        .materialized = "table",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.not_null_customers_customer_id.abc",
        .name = "not_null_customers_customer_id",
        .alias = "not_null_customers_customer_id",
        .path = "not_null_customers_customer_id.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_not_null(**_dbt_generic_test_kwargs) }}",
        .test_name = "not_null",
        .column_name = "customer_id",
        .attached_node = "model.demo.customers",
        .config = .{ .where = "status = 'active'", .limit = 5 },
    });
    try graph.tests.items[0].depends_on.append(allocator, "model.demo.customers");

    const compiled = try compileGenericTest(allocator, &graph, &graph.tests.items[0]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings(
        "select \"customer_id\"\nfrom (select * from \"main\".\"customers\" where status = 'active') dbt_subquery\nwhere \"customer_id\" is null\nlimit 5",
        compiled,
    );
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

test "compileModel resolves static loop vars inside refs and sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
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
        .raw_code = "select 1",
    });
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.looped",
        .name = "looped",
        .path = "looped.sql",
        .original_file_path = "models/looped.sql",
        .raw_code =
        \\{% set model_names = ['customers', 'orders'] %}
        \\{% for model_name in model_names %}
        \\select * from {{ ref(model_name) }}
        \\{% endfor %}
        \\{% set table_names = ['events', 'payments'] %}
        \\{% for table_name in table_names %}
        \\union all select * from {{ source('raw', table_name) }}
        \\{% endfor %}
        ,
    });
    try graph.sources.append(allocator, .{
        .package_name = "demo",
        .unique_id = "source.demo.raw.events",
        .source_name = "raw",
        .table_name = "events",
        .original_file_path = "models/schema.yml",
    });
    try graph.sources.append(allocator, .{
        .package_name = "demo",
        .unique_id = "source.demo.raw.payments",
        .source_name = "raw",
        .table_name = "payments",
        .original_file_path = "models/schema.yml",
    });

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[2]);
    defer allocator.free(compiled);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "from \"analytics\".\"customers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "from \"analytics\".\"orders\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "from \"raw\".\"events\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "from \"raw\".\"payments\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "{{") == null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "{%") == null);
}

test "compileModel resolves package refs with static loop vars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "pkg",
        .unique_id = "model.pkg.pkg_customers",
        .name = "pkg_customers",
        .path = "pkg_customers.sql",
        .original_file_path = "models/pkg_customers.sql",
        .raw_code = "select 1",
    });
    try graph.nodes.append(allocator, .{
        .package_name = "pkg",
        .unique_id = "model.pkg.pkg_orders",
        .name = "pkg_orders",
        .path = "pkg_orders.sql",
        .original_file_path = "models/pkg_orders.sql",
        .raw_code = "select 1",
    });
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.looped",
        .name = "looped",
        .path = "looped.sql",
        .original_file_path = "models/looped.sql",
        .raw_code =
        \\{% set model_names = ['pkg_customers', 'pkg_orders'] %}
        \\{% for model_name in model_names %}
        \\select * from {{ ref('pkg', model_name) }}
        \\{% endfor %}
        ,
    });

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[2]);
    defer allocator.free(compiled);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "from \"analytics\".\"pkg_customers\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "from \"analytics\".\"pkg_orders\"") != null);
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

test "compileModel skips loop-var refs and sources inside empty static loops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.looped",
        .name = "looped",
        .path = "looped.sql",
        .original_file_path = "models/looped.sql",
        .raw_code =
        \\{% set model_names = [] %}
        \\select 1 as marker
        \\{% for model_name in model_names %}
        \\union all select * from {{ ref(model_name) }}
        \\{% endfor %}
        \\{% set table_names = [] %}
        \\{% for table_name in table_names %}
        \\union all select * from {{ source('raw', table_name) }}
        \\{% endfor %}
        ,
    });

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[0]);
    defer allocator.free(compiled);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "select 1 as marker") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "union all") == null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "{{") == null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "{%") == null);
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

test "compileModel renders static if branches for render-only context" {
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
        .raw_code = "select {% if false %}0{% else %}1{% endif %} as value, {% if execute %}'compile'{% else %}'parse'{% endif %} as mode, {% if not execute %}0{% else %}1{% endif %} as executes, {% if is_incremental() %}1{% else %}0{% endif %} as incremental",
    });

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[0]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("select 1 as value, 'compile' as mode, 1 as executes, 0 as incremental", compiled);
}

test "compileModel rejects unsupported if conditions and elif branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.dynamic_if",
        .name = "dynamic_if",
        .path = "dynamic_if.sql",
        .original_file_path = "models/dynamic_if.sql",
        .raw_code = "{% if var('enabled') %}select 1{% endif %}",
    });
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.elif",
        .name = "elif",
        .path = "elif.sql",
        .original_file_path = "models/elif.sql",
        .raw_code = "{% if false %}select 1{% elif true %}select 2{% endif %}",
    });

    try std.testing.expectError(error.UnsupportedJinja, compileModel(allocator, &graph, &graph.nodes.items[0]));
    try std.testing.expectError(error.UnsupportedJinja, compileModel(allocator, &graph, &graph.nodes.items[1]));
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
        .raw_code = "{% set xs = [] %}{% for x in xs %}{% if var('enabled') %}{{ x }}{% endif %}{% endfor %}select 1",
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
