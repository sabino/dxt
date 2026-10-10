const std = @import("std");
const dbt_context = @import("dbt_context.zig");
const jinja = @import("jinja.zig");
const snapshot = @import("snapshot.zig");
const resolve = @import("resolve.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const native_expr = @import("expression.zig");

const Graph = types.Graph;
const ExtraCte = types.ExtraCte;
const GenericTestNode = types.GenericTestNode;
const MacroDef = types.MacroDef;
const Node = types.Node;
const RefDep = types.RefDep;
const SingularTestNode = types.SingularTestNode;
const SourceDep = types.SourceDep;
const SourceDef = types.SourceDef;

const max_macro_render_depth = 64;

const Relation = struct {
    database: ?[]const u8 = null,
    schema: []const u8,
    identifier: []const u8,
    quoting: RelationQuoting = .{},
};

const RelationQuoting = struct {
    database: bool = true,
    schema: bool = true,
    identifier: bool = true,
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
    filter_expression: ?[]const u8 = null,
    body_start: usize,
    body_end: usize,
    else_body_start: ?usize = null,
    else_body_end: usize = 0,
    end_tag_close: usize,
};

const IfBlock = struct {
    selected_body_start: ?usize = null,
    selected_body_end: usize = 0,
    end_tag_close: usize,
};

const StaticConditionValue = union(enum) {
    boolean: bool,
    string: []const u8,
};

const StaticComparisonOperator = enum {
    equal,
    not_equal,
};

const StaticComparison = struct {
    operator: StaticComparisonOperator,
    operator_start: usize,
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
    value_arena: std.heap.ArenaAllocator,
    bindings: std.ArrayList(ValueBinding) = .empty,
    returned: ?native_expr.Value = null,
    parse_node: ?*Node = null,
    runtime_macro_dependencies: ?*std.ArrayList([]const u8) = null,
    runtime_dependency_allocator: std.mem.Allocator = undefined,
    dependency_depth: usize = 0,
    execute_override: ?bool = null,
    capture_undefined_override: ?bool = null,
    var_render_depth: usize = 0,
    loop_depth: usize = 0,
    loop_break: bool = false,
    loop_continue: bool = false,
    previous_host_node: ?*const anyopaque = null,
    documentation: bool = false,
    documentation_block: bool = false,
    caller_blocks: std.ArrayList(*CallerBlock) = .empty,
    loop_states: std.ArrayList(*LoopFrame) = .empty,

    const ValueBinding = struct {
        name: []const u8,
        value: native_expr.Value,
        scope_depth: usize,
    };

    fn init(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node) CompileContext {
        const previous = if (graph.execution_hooks) |execution_host| if (execution_host.set_node) |set_node| set_node(execution_host.context, node) else null else null;
        return .{ .allocator = allocator, .graph = graph, .node = node, .value_arena = std.heap.ArenaAllocator.init(allocator), .previous_host_node = previous };
    }

    fn recordMacroDependency(self: *CompileContext, unique_id: []const u8) !void {
        if (self.parse_node) |node| if (self.macro_render_depth == 0) try util.appendUnique(self.allocator, &node.macro_depends_on, unique_id);
        if (self.runtime_macro_dependencies) |dependencies| if (self.macro_render_depth == self.dependency_depth) try util.appendUnique(self.runtime_dependency_allocator, dependencies, unique_id);
    }

    fn namespacePackage(self: *const CompileContext) []const u8 {
        // ProviderContext builds one namespace for the resource package. A
        // callee's package governs vars/dispatch, not unqualified macro lookup.
        return self.node.package_name;
    }

    fn deinit(self: *CompileContext) void {
        if (self.graph.execution_hooks) |execution_host| if (execution_host.set_node) |set_node| {
            _ = set_node(execution_host.context, self.previous_host_node);
        };
        for (self.lists.items) |*list| {
            for (list.values.items) |value| self.allocator.free(value);
            list.values.deinit(self.allocator);
        }
        self.lists.deinit(self.allocator);
        self.vars.deinit(self.allocator);
        self.bindings.deinit(self.allocator);
        self.value_arena.deinit();
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
        while (self.bindings.items.len > 0 and self.bindings.items[self.bindings.items.len - 1].scope_depth == self.scope_depth) _ = self.bindings.pop();
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

    fn setValue(self: *CompileContext, name: []const u8, value: native_expr.Value) !void {
        var i = self.bindings.items.len;
        while (i > 0) {
            i -= 1;
            if (self.bindings.items[i].scope_depth == self.scope_depth and std.mem.eql(u8, self.bindings.items[i].name, name)) {
                self.bindings.items[i].value = value;
                return;
            }
        }
        try self.bindings.append(self.allocator, .{ .name = name, .value = value, .scope_depth = self.scope_depth });
    }

    fn host(self: *CompileContext) native_expr.Host {
        return .{ .context = self, .resolve = resolveExpressionValue, .call = callExpressionValue, .capture_undefined = self.capturesUndefined() };
    }

    fn capturesUndefined(self: *const CompileContext) bool {
        return self.parse_node != null and (self.capture_undefined_override orelse true);
    }

    fn evaluate(self: *CompileContext, span: []const u8) !native_expr.Value {
        return native_expr.evaluate(self.value_arena.allocator(), span, self.host()) catch |err| {
            if (@import("compile_diagnostics.zig").message(err) == null) {
                const detail = try std.fmt.allocPrint(self.value_arena.allocator(), "{s} evaluating expression: {s}", .{ @errorName(err), span });
                @import("compile_diagnostics.zig").captureError(self.node.original_file_path, self.node.name, detail, err);
            }
            return err;
        };
    }
};

pub const CompiledModel = struct {
    compiled_code: []const u8,
    extra_ctes: std.ArrayList(ExtraCte) = .empty,

    pub fn deinit(self: *CompiledModel, allocator: std.mem.Allocator) void {
        allocator.free(self.compiled_code);
        for (self.extra_ctes.items) |extra_cte| allocator.free(extra_cte.sql);
        self.extra_ctes.deinit(allocator);
    }
};

/// CTE IDs borrow graph storage; SQL is copied into the destination's ownership.
pub fn appendCteCopies(allocator: std.mem.Allocator, destination: *std.ArrayList(ExtraCte), originals: []const ExtraCte) !void {
    for (originals) |cte| {
        const sql = try allocator.dupe(u8, cte.sql);
        errdefer allocator.free(sql);
        try destination.append(allocator, .{ .id = cte.id, .sql = sql });
    }
}

fn cteCopyAllocationFailures(allocator: std.mem.Allocator) !void {
    var copies: std.ArrayList(ExtraCte) = .empty;
    defer {
        for (copies.items) |cte| allocator.free(cte.sql);
        copies.deinit(allocator);
    }
    const originals = [_]ExtraCte{
        .{ .id = "model.demo.base", .sql = " base as (select 1)" },
        .{ .id = "model.demo.value", .sql = " value as (select * from base)" },
    };
    try appendCteCopies(allocator, &copies, &originals);
    try std.testing.expectEqual(@as(usize, 2), copies.items.len);
    try std.testing.expectEqualStrings(originals[1].sql, copies.items[1].sql);
}

test "compiled CTE collection cleans up each allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cteCopyAllocationFailures, .{});
}

const EphemeralCompileState = struct {
    allocator: std.mem.Allocator,
    graph: *const Graph,
    extra_ctes: std.ArrayList(ExtraCte) = .empty,
    stack: std.ArrayList([]const u8) = .empty,

    fn init(allocator: std.mem.Allocator, graph: *const Graph) EphemeralCompileState {
        return .{ .allocator = allocator, .graph = graph };
    }

    fn deinit(self: *EphemeralCompileState) void {
        for (self.extra_ctes.items) |extra_cte| self.allocator.free(extra_cte.sql);
        self.extra_ctes.deinit(self.allocator);
        self.stack.deinit(self.allocator);
    }
};

pub fn compileModel(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node) ![]const u8 {
    return try compileModelBody(allocator, graph, node);
}

pub fn recordPythonScaffoldDependency(allocator: std.mem.Allocator, graph: *const Graph, node: *Node) !void {
    if (!std.mem.eql(u8, node.language, "python")) return;
    const id = resolve.findMacroIdForUnqualifiedNamespaceCall(graph, node.package_name, "py_script_postfix") orelse return error.UnresolvedMacro;
    try util.appendUnique(allocator, &node.macro_depends_on, id);
}

/// The parser shortcuts not_null/unique configuration. Rendering their model
/// argument during compilation calls the normally resolved where helper.
/// Publish its dependency after worker results have returned to the collector.
pub fn recordGenericCompilationDependency(allocator: std.mem.Allocator, graph: *const Graph, node: *GenericTestNode) !void {
    if (findCustomGenericTestMacro(graph, node) == null) return;
    const id = resolve.findMacroIdForUnqualifiedNamespaceCall(graph, node.package_name, "get_where_subquery") orelse return;
    try util.appendUnique(allocator, &node.macro_depends_on, id);
}

/// Render a runtime hook in the resource's own typed compilation context.
pub fn renderTextForNode(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node, text: []const u8) ![]const u8 {
    var context = CompileContext.init(allocator, graph, node);
    defer context.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try renderRange(&context, text, 0, text.len, &out);
    return try out.toOwnedSlice(allocator);
}

pub fn renderDocumentation(allocator: std.mem.Allocator, graph: *const Graph, package: []const u8, unique_id: []const u8, path: []const u8, text: []const u8) ![]const u8 {
    return renderDocumentationContext(allocator, graph, package, unique_id, path, text, false);
}

pub fn renderDocumentationBlock(allocator: std.mem.Allocator, graph: *const Graph, package: []const u8, unique_id: []const u8, path: []const u8, text: []const u8) ![]const u8 {
    return renderDocumentationContext(allocator, graph, package, unique_id, path, text, true);
}

fn renderDocumentationContext(allocator: std.mem.Allocator, graph: *const Graph, package: []const u8, unique_id: []const u8, path: []const u8, text: []const u8, block: bool) ![]const u8 {
    var node = Node{ .package_name = package, .unique_id = unique_id, .name = unique_id, .path = path, .original_file_path = path, .raw_code = text };
    defer types.deinitNode(allocator, &node);
    var context = CompileContext.init(allocator, graph, &node);
    defer context.deinit();
    context.documentation = true;
    context.documentation_block = block;
    context.parse_node = &node;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try renderRange(&context, text, 0, text.len, &out);
    return try out.toOwnedSlice(allocator);
}

/// Source freshness SQL is rendered at execution, when `this` is the source
/// relation and variables/macros have their normal package scope.
pub fn renderSourceExpression(allocator: std.mem.Allocator, graph: *const Graph, source: *const SourceDef, text: []const u8) ![]const u8 {
    var source_graph = graph.*;
    source_graph.target_schema = sourceSchemaName(source);
    var node = Node{ .resource_type = "source", .package_name = source.package_name, .unique_id = source.unique_id, .name = sourceIdentifier(source), .path = "", .original_file_path = source.original_file_path, .raw_code = text };
    defer types.deinitNode(allocator, &node);
    const relation = try relationNameForSource(allocator, source);
    defer allocator.free(relation);
    node.relation_name = relation;
    if (sourceDatabaseName(source)) |database| try @import("config_value.zig").put(allocator, &node.effective_config, "database", .{ .string = database });
    return try compileModel(allocator, &source_graph, &node);
}

/// Render with execute=false to discover dependencies through real expression,
/// scope and macro semantics, including macros returning a list of ref names.
pub fn scanDependencies(allocator: std.mem.Allocator, sql: []const u8, node: *Node, graph: ?*const Graph) !void {
    // Static extraction runs on an isolated node. A macro or dynamic expression
    // can force full rendering after literal configs were seen; those tentative
    // hooks and tags must not be applied a second time by the real renderer.
    var probe = Node{
        .package_name = node.package_name,
        .unique_id = node.unique_id,
        .name = node.name,
        .path = node.path,
        .original_file_path = node.original_file_path,
        .raw_code = node.raw_code,
        .resource_type = node.resource_type,
    };
    defer types.deinitNode(allocator, &probe);
    var static_success = graph == null or graph.?.command_options.static_parser;
    if (static_success) {
        const timing = try @import("timing_profile.zig").start(if (graph) |present| present.timing_profile else null, .{ .filename = @src().file, .line = @src().line, .function = "scanSqlStatic" });
        defer timing.finish();
        jinja.scanSql(allocator, sql, &probe, graph) catch |err| switch (err) {
            error.UnsupportedJinja, error.UnsupportedDynamicRef, error.UnsupportedDynamicSource, error.UnresolvedVar, error.UnresolvedMacro => static_success = false,
            else => return err,
        };
    }
    if (static_success and probe.macro_depends_on.items.len == 0 and !requiresNativeRendering(sql)) {
        try node.refs.appendSlice(allocator, probe.refs.items);
        try node.source_refs.appendSlice(allocator, probe.source_refs.items);
        try @import("resource_config.zig").applyParsedInline(allocator, probe.inline_config, node);
        return;
    }
    const fallback = Graph{ .allocator = allocator, .project_name = node.package_name };
    var context = CompileContext.init(allocator, graph orelse &fallback, node);
    defer context.deinit();
    context.parse_node = node;
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(allocator);
    try renderRange(&context, sql, 0, sql.len, &rendered);
}

fn requiresNativeRendering(sql: []const u8) bool {
    // Core's static parser accepts whole literal dependency/config calls.
    // Other output expressions must execute during parse as well, so invalid
    // arithmetic, conversions and attributes cannot be silently skipped.
    if (std.mem.indexOf(u8, sql, "{%") != null) return true;
    var output_position: usize = 0;
    while (std.mem.indexOfPos(u8, sql, output_position, "{{")) |open| {
        const close = jinja.findExpressionClose(sql, open + 2) orelse return true;
        output_position = close + 2;
        const span = tagContent(sql, open, close);
        var identifier_end: usize = 0;
        while (identifier_end < span.len and jinja.isIdentChar(span[identifier_end])) identifier_end += 1;
        const identifier = span[0..identifier_end];
        if (!std.mem.eql(u8, identifier, "config") and !std.mem.eql(u8, identifier, "ref") and !std.mem.eql(u8, identifier, "source")) return true;
        const call = jinja.readJinjaCall(span, identifier, identifier_end) catch return true;
        if (call == null or call.?.package_name != null or jinja.skipWs(span, call.?.close + 1) != span.len) return true;
    }
    for ([_][]const u8{ "var(", "var (", "env_var(", "env_var (", "{% set", "{%- set", "{% call", "{%- call", "{% for", "{%- for", "run_query(", "statement(", "log(", "print(", "exceptions." }) |needle|
        if (std.mem.indexOf(u8, sql, needle) != null) return true;
    // A positional configuration map is an expression, including its key
    // types. The literal keyword scanner cannot apply or validate that map.
    var position: usize = 0;
    while (std.mem.indexOfPos(u8, sql, position, "config")) |start| {
        position = start + "config".len;
        const call = std.mem.trimStart(u8, sql[position..], " \t\r\n");
        if (call.len == 0 or call[0] != '(') continue;
        const arguments = std.mem.trimStart(u8, call[1..], " \t\r\n");
        if (arguments.len != 0 and arguments[0] == '{') return true;
    }
    return false;
}

/// Generic schema tests bind typed arguments before rendering with execute=false.
/// Config calls and dependencies are recorded on the caller-owned test probe.
pub fn scanMacroDependencies(allocator: std.mem.Allocator, graph: *const Graph, node: *Node, macro_name: []const u8, arguments: []const native_expr.Argument) !void {
    var context = CompileContext.init(allocator, graph, node);
    defer context.deinit();
    context.parse_node = node;
    _ = try callExpressionValue(&context, macro_name, arguments, context.value_arena.allocator());
}

pub fn renderOperation(runtime: types.Runtime, graph: *const Graph, macro_name: []const u8, kwargs: std.json.Value) ![]const u8 {
    const node = Node{ .package_name = graph.project_name, .unique_id = "operation", .name = "operation", .path = "", .original_file_path = "", .raw_code = "" };
    var context = CompileContext.init(runtime.allocator, graph, &node);
    defer context.deinit();
    if (kwargs != .object) return error.InvalidJinjaArguments;
    var args: std.ArrayList(native_expr.Argument) = .empty;
    const allocator = context.value_arena.allocator();
    var iterator = kwargs.object.iterator();
    while (iterator.next()) |entry| try args.append(allocator, .{ .name = entry.key_ptr.*, .value = try valueFromJson(allocator, entry.value_ptr.*) });
    const result = try callExpressionValue(&context, macro_name, args.items, allocator);
    return try runtime.allocator.dupe(u8, if (result == .none) "" else try result.text(allocator));
}

/// Materializations and incremental strategies receive actual typed adapter
/// values. The result owns its storage independently of this render frame.
pub fn renderMacroForNode(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node, macro_name: []const u8, args: []const native_expr.Argument) !native_expr.Value {
    var context = CompileContext.init(allocator, graph, node);
    defer context.deinit();
    return try dbt_context.cloneValue(allocator, try callExpressionValue(&context, macro_name, args, context.value_arena.allocator()));
}

/// Core's materialization is the entry frame. Only its direct helper calls
/// become resource dependencies; helpers called inside other macros do not.
pub fn renderMaterializationForNode(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node, macro: *const MacroDef, dependency_allocator: std.mem.Allocator, dependencies: *std.ArrayList([]const u8)) !native_expr.Value {
    var context = CompileContext.init(allocator, graph, node);
    defer context.deinit();
    context.runtime_macro_dependencies = dependencies;
    context.runtime_dependency_allocator = dependency_allocator;
    context.dependency_depth = 1;
    return try dbt_context.cloneValue(allocator, try renderMacroValue(&context, macro, &.{}));
}

test "materialization uses the resource namespace and records direct helpers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph = Graph{ .allocator = a, .project_name = "root" };
    const definitions = [_][3][]const u8{
        .{ "dbt", "materialization_test_default", "{% materialization test, default %}{{ return({'relations': [], 'selected': helper()}) }}{% endmaterialization %}" },
        .{ "dbt", "helper", "{% macro helper() %}{{ return('core') }}{% endmacro %}" },
        .{ "root", "helper", "{% macro helper() %}{{ return('root ' ~ nested()) }}{% endmacro %}" },
        .{ "root", "nested", "{% macro nested() %}{{ return('nested') }}{% endmacro %}" },
    };
    for (definitions) |definition| try graph.macros.append(a, .{ .package_name = definition[0], .unique_id = try std.fmt.allocPrint(a, "macro.{s}.{s}", .{ definition[0], definition[1] }), .name = definition[1], .path = "macro.sql", .original_file_path = "macros/macro.sql", .macro_sql = definition[2] });
    const node = Node{ .resource_type = "test", .package_name = "root", .unique_id = "test.root.check", .name = "check", .path = "check.sql", .original_file_path = "tests/check.sql", .raw_code = "" };
    var dependencies: std.ArrayList([]const u8) = .empty;
    defer dependencies.deinit(std.testing.allocator);
    const result = try renderMaterializationForNode(a, &graph, &node, &graph.macros.items[0], std.testing.allocator, &dependencies);
    try std.testing.expectEqualStrings("root nested", result.attribute("selected").string);
    try std.testing.expectEqual(@as(usize, 1), dependencies.items.len);
    try std.testing.expectEqualStrings("macro.root.helper", dependencies.items[0]);
}

/// Name generation uses Core's execute=false macro context, with variables
/// scoped to the chosen macro package and no warehouse execution host.
pub fn renderNamingMacro(allocator: std.mem.Allocator, graph: *const Graph, macro: *const MacroDef, args: []const native_expr.Argument) !native_expr.Value {
    var naming_graph = graph.*;
    naming_graph.execution_hooks = null;
    const node = Node{ .resource_type = "macro", .package_name = macro.package_name, .unique_id = macro.unique_id, .name = macro.name, .path = macro.path, .original_file_path = macro.original_file_path, .raw_code = macro.macro_sql };
    var context = CompileContext.init(allocator, &naming_graph, &node);
    defer context.deinit();
    context.execute_override = false;
    const name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ macro.package_name, macro.name });
    defer allocator.free(name);
    return try dbt_context.cloneValue(allocator, try callExpressionValue(&context, name, args, context.value_arena.allocator()));
}

pub fn renderGenericArgumentValue(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node, argument: std.json.Value) !native_expr.Value {
    var context = CompileContext.init(allocator, graph, node);
    defer context.deinit();
    return try dbt_context.cloneValue(allocator, try genericArgumentValue(&context, argument));
}

pub fn parseGenericArgumentValue(allocator: std.mem.Allocator, graph: *const Graph, node: *Node, argument: std.json.Value) !native_expr.Value {
    var context = CompileContext.init(allocator, graph, node);
    defer context.deinit();
    context.parse_node = node;
    return try dbt_context.cloneValue(allocator, try genericArgumentValue(&context, argument));
}

fn genericArgumentValue(context: *CompileContext, argument: std.json.Value) anyerror!native_expr.Value {
    const allocator = context.value_arena.allocator();
    if (argument == .array) {
        const output = try native_expr.allocateValues(allocator, argument.array.items.len);
        for (argument.array.items, output) |input, *value| value.* = try genericArgumentValue(context, input);
        return .{ .list = output };
    }
    if (argument == .object) {
        const output = try native_expr.allocateEntries(allocator, argument.object.count());
        for (argument.object.keys(), argument.object.values(), output) |key, input, *entry| entry.* = .{ .key = key, .value = try genericArgumentValue(context, input) };
        return .{ .object = output };
    }
    if (argument != .string) return try valueFromJson(allocator, argument);
    const text = std.mem.trim(u8, argument.string, " \t\r\n");
    if (std.mem.startsWith(u8, text, "{{")) if (jinja.findExpressionClose(text, 2)) |end| {
        if (end + 2 == text.len) return try context.evaluate(std.mem.trim(u8, text[2..end], " \t\r\n-"));
    };
    inline for (.{ "env_var", "ref", "var", "source", "doc" }) |name| {
        if (std.mem.startsWith(u8, text, name)) {
            const next = jinja.skipWs(text, name.len);
            if (next < text.len and text[next] == '(') return try context.evaluate(text);
        }
    }
    var rendered: std.ArrayList(u8) = .empty;
    defer rendered.deinit(context.allocator);
    try renderRange(context, argument.string, 0, argument.string.len, &rendered);
    return .{ .string = try allocator.dupe(u8, rendered.items) };
}

fn valueFromJson(allocator: std.mem.Allocator, value: std.json.Value) anyerror!native_expr.Value {
    return try @import("config_value.zig").toExpression(allocator, value);
}

pub fn compileModelWithInjectedCtes(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node) !CompiledModel {
    if (std.mem.eql(u8, node.language, "python")) {
        for (node.depends_on.items) |id| {
            const parent = findNodeByUniqueId(graph, id) orelse continue;
            if (std.mem.eql(u8, parent.materialized, "ephemeral")) return error.PythonModelEphemeralDependency;
        }
        return .{ .compiled_code = try compileModelBody(allocator, graph, node) };
    }
    var state = EphemeralCompileState.init(allocator, graph);
    errdefer state.deinit();

    try collectEphemeralDependencies(&state, node);

    const body = try compileModelBody(allocator, graph, node);
    errdefer allocator.free(body);

    const compiled_code = if (state.extra_ctes.items.len == 0 or !graph.command_options.inject_ephemeral_ctes)
        body
    else blk: {
        const injected = try injectExtraCtes(allocator, body, state.extra_ctes.items);
        allocator.free(body);
        break :blk injected;
    };

    const extra_ctes = state.extra_ctes;
    state.extra_ctes = .empty;
    state.stack.deinit(allocator);
    return .{ .compiled_code = compiled_code, .extra_ctes = extra_ctes };
}

fn compileModelBody(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node) ![]const u8 {
    const timing = try @import("timing_profile.zig").start(graph.timing_profile, .{ .filename = @src().file, .line = @src().line, .function = "compileModelBody" });
    defer timing.finish();
    var context = CompileContext.init(allocator, graph, node);
    defer context.deinit();

    if (std.mem.eql(u8, node.language, "python")) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, node.raw_code);
        try out.appendSlice(allocator, "\n\n");
        try renderRange(&context, "{{ py_script_postfix(model) }}", 0, "{{ py_script_postfix(model) }}".len, &out);
        return try out.toOwnedSlice(allocator);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const end = node.raw_code.len - @as(usize, if (!std.mem.eql(u8, node.resource_type, "sql_operation") and std.mem.endsWith(u8, node.raw_code, "\n")) 1 else 0);
    try renderRange(&context, node.raw_code, 0, end, &out);
    return try out.toOwnedSlice(allocator);
}

fn collectEphemeralDependencies(state: *EphemeralCompileState, node: *const Node) anyerror!void {
    for (node.depends_on.items) |dependency| {
        if (state.graph.unitFixtureRelation(dependency) != null) continue;
        const dependency_node = findNodeByUniqueId(state.graph, dependency) orelse continue;
        if (!std.mem.eql(u8, dependency_node.resource_type, "model")) continue;
        if (!std.mem.eql(u8, dependency_node.materialized, "ephemeral")) continue;
        try collectEphemeralNode(state, dependency_node);
    }
}

fn collectEphemeralNode(state: *EphemeralCompileState, node: *const Node) anyerror!void {
    if (extraCteContains(state.extra_ctes.items, node.unique_id)) return;
    if (stringListContains(state.stack.items, node.unique_id)) return error.CyclicModelDependency;

    if (!state.graph.command_options.inject_ephemeral_ctes) {
        try state.extra_ctes.append(state.allocator, .{ .id = node.unique_id, .sql = try state.allocator.dupe(u8, "") });
        return;
    }
    try state.stack.append(state.allocator, node.unique_id);
    errdefer _ = state.stack.pop();

    try collectEphemeralDependencies(state, node);

    const cte_name = try ephemeralCteName(state.allocator, node);
    defer state.allocator.free(cte_name);
    const compiled = try compileModelBody(state.allocator, state.graph, node);
    defer state.allocator.free(compiled);
    const cte_sql = try std.fmt.allocPrint(
        state.allocator,
        " {s} as (\n{s}\n)",
        .{ cte_name, compiled },
    );
    errdefer state.allocator.free(cte_sql);

    try state.extra_ctes.append(state.allocator, .{ .id = node.unique_id, .sql = cte_sql });
    _ = state.stack.pop();
}

fn extraCteContains(extra_ctes: []const ExtraCte, id: []const u8) bool {
    for (extra_ctes) |extra_cte| {
        if (std.mem.eql(u8, extra_cte.id, id)) return true;
    }
    return false;
}

fn stringListContains(values: []const []const u8, value: []const u8) bool {
    for (values) |candidate| {
        if (std.mem.eql(u8, candidate, value)) return true;
    }
    return false;
}

pub fn ephemeralCteName(allocator: std.mem.Allocator, node: *const Node) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "__dbt__cte__{s}", .{relationIdentifierForNode(node)});
}

pub fn injectExtraCtes(allocator: std.mem.Allocator, body: []const u8, extra_ctes: []const ExtraCte) ![]const u8 {
    var ctes: std.ArrayList(u8) = .empty;
    defer ctes.deinit(allocator);
    for (extra_ctes, 0..) |extra_cte, index| {
        if (index != 0) try ctes.appendSlice(allocator, ", ");
        try ctes.appendSlice(allocator, extra_cte.sql);
    }

    const leading_end = skipSqlWhitespace(body, 0);
    var body_start = leading_end;
    while (body_start < body.len) {
        if (std.mem.startsWith(u8, body[body_start..], "--")) {
            body_start = if (std.mem.indexOfScalarPos(u8, body, body_start, '\n')) |end| skipSqlWhitespace(body, end + 1) else body.len;
        } else if (std.mem.startsWith(u8, body[body_start..], "/*")) {
            body_start = if (std.mem.indexOfPos(u8, body, body_start + 2, "*/")) |end| skipSqlWhitespace(body, end + 2) else body.len;
        } else break;
    }
    if (startsWithSqlWith(body[body_start..])) {
        var rest_start = skipSqlWhitespace(body, body_start + "with".len);
        if (body.len - rest_start >= "recursive".len and std.ascii.eqlIgnoreCase(body[rest_start..][0.."recursive".len], "recursive") and (body.len == rest_start + "recursive".len or !std.ascii.isAlphanumeric(body[rest_start + "recursive".len]))) rest_start = skipSqlWhitespace(body, rest_start + "recursive".len);
        return try std.fmt.allocPrint(
            allocator,
            "{s}{s}, {s}",
            .{ body[0..rest_start], ctes.items, body[rest_start..] },
        );
    }
    return try std.fmt.allocPrint(allocator, "{s}with{s} {s}", .{ body[0..leading_end], ctes.items, body[leading_end..] });
}

fn startsWithSqlWith(sql: []const u8) bool {
    if (sql.len < "with".len) return false;
    if (!std.ascii.eqlIgnoreCase(sql[0.."with".len], "with")) return false;
    return sql.len == "with".len or !std.ascii.isAlphanumeric(sql["with".len]);
}

fn skipSqlWhitespace(sql: []const u8, start: usize) usize {
    var index = start;
    while (index < sql.len and std.ascii.isWhitespace(sql[index])) index += 1;
    return index;
}

fn trimTrailingSqlTerminator(sql: []const u8) []const u8 {
    var end = trimSqlRight(sql).len;
    if (end > 0 and sql[end - 1] == ';') {
        end -= 1;
        end = trimSqlRight(sql[0..end]).len;
    }
    return sql[0..end];
}

fn trimSqlRight(sql: []const u8) []const u8 {
    var end = sql.len;
    while (end > 0 and std.ascii.isWhitespace(sql[end - 1])) end -= 1;
    return sql[0..end];
}

pub fn compileSingularTest(allocator: std.mem.Allocator, graph: *const Graph, test_node: *const SingularTestNode) ![]const u8 {
    var compiled = try compileSingularTestWithInjectedCtes(allocator, graph, test_node);
    defer {
        for (compiled.extra_ctes.items) |cte| allocator.free(cte.sql);
        compiled.extra_ctes.deinit(allocator);
    }
    return compiled.compiled_code;
}

pub fn compileSingularTestWithInjectedCtes(allocator: std.mem.Allocator, graph: *const Graph, test_node: *const SingularTestNode) !CompiledModel {
    const body = try compileSingularTestBody(allocator, graph, test_node);
    return try injectTestDependencies(allocator, graph, test_node.depends_on, body);
}

fn compileSingularTestBody(allocator: std.mem.Allocator, graph: *const Graph, test_node: *const SingularTestNode) ![]const u8 {
    const node = Node{
        .depends_on = test_node.depends_on,
        .resolved_identity = test_node.resolved_identity,
        .resource_type = "test",
        .package_name = test_node.package_name,
        .unique_id = test_node.unique_id,
        .name = test_node.name,
        .path = test_node.path,
        .original_file_path = test_node.original_file_path,
        .raw_code = test_node.raw_code,
        .materialized = "test",
        .test_config = test_node.config,
        .effective_config = test_node.config_values,
        .enabled = test_node.enabled,
    };
    var context = CompileContext.init(allocator, graph, &node);
    defer context.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try renderRange(&context, test_node.raw_code, 0, test_node.raw_code.len, &out);
    return try out.toOwnedSlice(allocator);
}

pub fn compileGenericTest(allocator: std.mem.Allocator, graph: *const Graph, test_node: *const GenericTestNode) ![]const u8 {
    var compiled = try compileGenericTestWithInjectedCtes(allocator, graph, test_node);
    defer {
        for (compiled.extra_ctes.items) |cte| allocator.free(cte.sql);
        compiled.extra_ctes.deinit(allocator);
    }
    return compiled.compiled_code;
}

pub fn compileGenericTestWithInjectedCtes(allocator: std.mem.Allocator, graph: *const Graph, test_node: *const GenericTestNode) !CompiledModel {
    const body = try compileGenericTestBody(allocator, graph, test_node);
    return try injectTestDependencies(allocator, graph, test_node.depends_on, body);
}

fn injectTestDependencies(allocator: std.mem.Allocator, graph: *const Graph, dependencies: std.ArrayList([]const u8), body: []const u8) !CompiledModel {
    errdefer allocator.free(body);
    var state = EphemeralCompileState.init(allocator, graph);
    defer state.deinit();
    const node = Node{ .depends_on = dependencies, .resource_type = "test", .package_name = "", .unique_id = "", .name = "", .path = "", .original_file_path = "", .raw_code = "" };
    try collectEphemeralDependencies(&state, &node);
    // The shared collector retains Core's leading space and respects the
    // no-injection flag, including empty SQL in dependency metadata.
    const injected = if (state.extra_ctes.items.len == 0 or !graph.command_options.inject_ephemeral_ctes)
        body
    else blk: {
        const sql = try injectTestCtes(allocator, body, state.extra_ctes.items);
        allocator.free(body);
        break :blk sql;
    };
    const ctes = state.extra_ctes;
    state.extra_ctes = .empty;
    return .{ .compiled_code = injected, .extra_ctes = ctes };
}

fn injectTestCtes(allocator: std.mem.Allocator, body: []const u8, ctes: []const ExtraCte) ![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(allocator);
    for (ctes, 0..) |cte, index| {
        if (index != 0) try joined.appendSlice(allocator, ", ");
        try joined.appendSlice(allocator, cte.sql);
    }
    const first = skipSqlWhitespace(body, 0);
    const keyword = skipSqlComments(body, first);
    if (startsWithSqlWith(body[keyword..])) {
        var insertion = skipSqlWhitespace(body, keyword + 4);
        if (body.len - insertion >= 9 and std.ascii.eqlIgnoreCase(body[insertion..][0..9], "recursive") and
            (body.len - insertion == 9 or !std.ascii.isAlphanumeric(body[insertion + 9])))
        {
            insertion = skipSqlWhitespace(body, insertion + 9);
        }
        return try std.fmt.allocPrint(allocator, "{s}{s}, {s}", .{ body[0..insertion], joined.items, body[insertion..] });
    }
    return try std.fmt.allocPrint(allocator, "{s}with{s} {s}", .{ body[0..first], joined.items, body[first..] });
}

fn skipSqlComments(sql: []const u8, start: usize) usize {
    var index = start;
    while (index < sql.len) {
        if (std.mem.startsWith(u8, sql[index..], "--")) {
            index = if (std.mem.indexOfScalarPos(u8, sql, index, '\n')) |end| end + 1 else sql.len;
        } else if (std.mem.startsWith(u8, sql[index..], "/*")) {
            index = if (std.mem.indexOfPos(u8, sql, index + 2, "*/")) |end| end + 2 else sql.len;
        } else break;
        index = skipSqlWhitespace(sql, index);
    }
    return index;
}

test "test CTE injection preserves leading trivia and recursive WITH" {
    const allocator = std.testing.allocator;
    const ctes = [_]ExtraCte{.{ .id = "model.demo.parent", .sql = " __dbt__cte__parent as (\nselect 1\n)" }};
    const plain = try injectTestCtes(allocator, "\n select * from __dbt__cte__parent", &ctes);
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("\n with __dbt__cte__parent as (\nselect 1\n) select * from __dbt__cte__parent", plain);
    const recursive = try injectTestCtes(allocator, "-- test\nWITH RECURSIVE own as (select * from __dbt__cte__parent) select * from own", &ctes);
    defer allocator.free(recursive);
    try std.testing.expectEqualStrings("-- test\nWITH RECURSIVE  __dbt__cte__parent as (\nselect 1\n), own as (select * from __dbt__cte__parent) select * from own", recursive);
}

test "generic and singular test compilation injects ephemeral dependency SQL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph = Graph{ .allocator = a, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(a, .{ .package_name = "demo", .unique_id = "model.demo.parent", .name = "parent", .config_alias = "custom", .path = "parent.sql", .original_file_path = "models/parent.sql", .raw_code = "select 1 as id", .materialized = "ephemeral" });
    var generic = GenericTestNode{ .package_name = "demo", .unique_id = "test.demo.not_null", .name = "not_null", .alias = "not_null", .path = "not_null.sql", .original_file_path = "models/schema.yml", .raw_code = "", .test_name = "not_null", .column_name = "id", .attached_node = "model.demo.parent" };
    try generic.depends_on.append(a, "model.demo.parent");
    var generic_compiled = try compileGenericTestWithInjectedCtes(a, &graph, &generic);
    defer generic_compiled.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), generic_compiled.extra_ctes.items.len);
    try std.testing.expectEqualStrings(" __dbt__cte__custom as (\nselect 1 as id\n)", generic_compiled.extra_ctes.items[0].sql);
    try std.testing.expect(std.mem.startsWith(u8, generic_compiled.compiled_code, "with __dbt__cte__custom as ("));
    var singular = SingularTestNode{ .package_name = "demo", .unique_id = "test.demo.assert_parent", .name = "assert_parent", .alias = "assert_parent", .path = "assert_parent.sql", .original_file_path = "tests/assert_parent.sql", .raw_code = "select * from {{ ref('parent') }} where id is null" };
    try singular.depends_on.append(a, "model.demo.parent");
    var singular_compiled = try compileSingularTestWithInjectedCtes(a, &graph, &singular);
    defer singular_compiled.deinit(a);
    try std.testing.expectEqualStrings(generic_compiled.extra_ctes.items[0].sql, singular_compiled.extra_ctes.items[0].sql);
    try std.testing.expectEqualStrings("with __dbt__cte__custom as (\nselect 1 as id\n) select * from __dbt__cte__custom where id is null", singular_compiled.compiled_code);
}

fn compileGenericTestBody(allocator: std.mem.Allocator, graph: *const Graph, test_node: *const GenericTestNode) ![]const u8 {
    if (findCustomGenericTestMacro(graph, test_node) != null) return try compileCustomGenericTest(allocator, graph, test_node, genericTestNodeColumnName(test_node));
    const is_not_null = std.mem.eql(u8, test_node.test_name, "not_null");
    const is_unique = std.mem.eql(u8, test_node.test_name, "unique");
    const is_accepted_values = std.mem.eql(u8, test_node.test_name, "accepted_values");
    const is_relationships = std.mem.eql(u8, test_node.test_name, "relationships");
    if (!is_not_null and !is_unique and !is_accepted_values and !is_relationships) {
        return try compileCustomGenericTest(allocator, graph, test_node, genericTestNodeColumnName(test_node));
    }
    const column_name = genericTestNodeColumnName(test_node) orelse return error.UnsupportedTestExecution;
    if (is_accepted_values and test_node.accepted_values.items.len == 0) return error.UnsupportedTestExecution;
    if (is_relationships and (test_node.relationship_to.len == 0 or test_node.relationship_field.len == 0)) return error.UnsupportedTestExecution;

    const relation_name = try genericTestRelationName(allocator, graph, test_node);
    defer allocator.free(relation_name);
    const model_sql = try genericTestModelSqlForNode(allocator, graph, test_node, relation_name);
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

fn compileCustomGenericTest(allocator: std.mem.Allocator, graph: *const Graph, test_node: *const GenericTestNode, column_name: ?[]const u8) ![]const u8 {
    const macro = findCustomGenericTestMacro(graph, test_node) orelse return error.UnsupportedTestExecution;
    const relation_name = try genericTestRelationName(allocator, graph, test_node);
    defer allocator.free(relation_name);

    var canonical_config = try @import("canonical_manifest_config.zig").testConfig(allocator, test_node.config, test_node.enabled, &.{}, test_node.config_values);
    defer @import("config_value.zig").deinit(allocator, &canonical_config);
    const node = Node{ .depends_on = test_node.depends_on, .resolved_identity = test_node.resolved_identity, .resource_type = "test", .package_name = test_node.package_name, .unique_id = test_node.unique_id, .name = test_node.name, .path = test_node.path, .original_file_path = test_node.original_file_path, .raw_code = test_node.raw_code, .materialized = "test", .effective_config = canonical_config, .test_config = test_node.config, .enabled = test_node.enabled };
    var context = CompileContext.init(allocator, graph, &node);
    defer context.deinit();
    const arena = context.value_arena.allocator();
    const model_value = try genericTestModelValueForNode(arena, graph, test_node, relation_name);
    var args: std.ArrayList(native_expr.Argument) = .empty;
    if (test_node.arguments == .object) {
        var iterator = test_node.arguments.object.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "model") or std.mem.eql(u8, entry.key_ptr.*, "column_name")) continue;
            const value = try genericArgumentValue(&context, entry.value_ptr.*);
            try args.append(arena, .{ .name = entry.key_ptr.*, .value = value });
        }
    }
    try args.append(arena, .{ .name = "model", .value = model_value });
    if (column_name) |column| try args.append(arena, .{ .name = "column_name", .value = .{ .string = column } });
    const result = try renderMacroValue(&context, macro, args.items);
    // Core keeps the macro body unchanged in compiled_code. Its test
    // materialization applies the configured limit to execution/storage SQL.
    return try allocator.dupe(u8, try result.text(arena));
}

fn genericTestModelSql(allocator: std.mem.Allocator, relation_name: []const u8, where_sql: ?[]const u8) ![]const u8 {
    if (where_sql) |filter| {
        return try std.fmt.allocPrint(allocator, "(select * from {s} where {s}) dbt_subquery", .{ relation_name, filter });
    }
    return try allocator.dupe(u8, relation_name);
}

fn genericTestModelSqlForNode(allocator: std.mem.Allocator, graph: *const Graph, test_node: *const GenericTestNode, relation_name: []const u8) ![]const u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const generated = try genericTestModelValueForNode(a, graph, test_node, relation_name);
    return try allocator.dupe(u8, try generated.text(a));
}

fn genericTestModelValueForNode(a: std.mem.Allocator, graph: *const Graph, test_node: *const GenericTestNode, relation_name: []const u8) !native_expr.Value {
    if (resolve.findMacroIdForUnqualifiedNamespaceCall(graph, test_node.package_name, "get_where_subquery") == null) return .{ .string = try genericTestModelSql(a, relation_name, test_node.config.where) };
    const node = Node{ .depends_on = test_node.depends_on, .resolved_identity = test_node.resolved_identity, .resource_type = "test", .package_name = test_node.package_name, .unique_id = test_node.unique_id, .name = test_node.name, .path = test_node.path, .original_file_path = test_node.original_file_path, .raw_code = test_node.raw_code, .materialized = "test", .effective_config = test_node.config_values, .test_config = test_node.config, .enabled = test_node.enabled };
    const relation = if (test_node.attached_node) |id| try relationValueForInputNode(a, graph, &node, findNodeByUniqueId(graph, id) orelse return error.UnresolvedRef) else if (test_node.attached_source_unique_id) |id| try relationValueForSource(a, graph, &node, findSourceByUniqueId(graph, id) orelse return error.UnresolvedSource) else native_expr.Value{ .string = relation_name };
    // The normal helper returns a Relation without a where clause and a string
    // for a filtered subquery. Preserve whichever value the resolved macro
    // returns so authored tests can call Relation methods and read attributes.
    return try renderMacroForNode(a, graph, &node, "get_where_subquery", &.{.{ .value = relation }});
}

fn applyGenericTestLimit(allocator: std.mem.Allocator, sql: []const u8, limit: ?i64) ![]const u8 {
    if (limit) |row_limit| {
        defer allocator.free(sql);
        return try std.fmt.allocPrint(allocator, "{s}\nlimit {d}", .{ sql, row_limit });
    }
    return sql;
}

fn renderRange(context: *CompileContext, sql: []const u8, start: usize, end_index: usize, out: *std.ArrayList(u8)) anyerror!void {
    var index = start;
    while (index < end_index) {
        if (context.returned != null or context.loop_break or context.loop_continue) return;
        if (index + 1 >= end_index or sql[index] != '{') {
            // Jinja whitespace control consumes only adjacent source text.
            // It must not trim a preceding expression's returned whitespace
            // or reach across an intervening comment/control tag.
            if (std.ascii.isWhitespace(sql[index])) {
                var next = index;
                while (next < end_index and std.ascii.isWhitespace(sql[next])) next += 1;
                if (next + 2 < sql.len and sql[next] == '{' and sql[next + 2] == '-' and (sql[next + 1] == '%' or sql[next + 1] == '{' or sql[next + 1] == '#')) {
                    index = next;
                    continue;
                }
            }
            try out.append(context.allocator, sql[index]);
            index += 1;
            continue;
        }

        const tag_kind = sql[index + 1];
        if (tag_kind == '#') {
            const close = std.mem.indexOfPos(u8, sql, index + 2, "#}") orelse return error.UnsupportedJinja;
            if (close + 2 > end_index) return error.UnsupportedJinja;
            index = afterTag(sql, close + 2, end_index);
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
        const close = (if (tag_kind == '{') jinja.findExpressionClose(sql, index + 2) else std.mem.indexOfPos(u8, sql, index + 2, close_marker)) orelse return error.UnsupportedJinja;
        if (close + 2 > end_index) return error.UnsupportedJinja;
        const span = tagContent(sql, index, close);
        if (tag_kind == '{') {
            const rendered = try renderExpression(context, span);
            defer context.allocator.free(rendered);
            try out.appendSlice(context.allocator, rendered);
        } else {
            if (std.mem.eql(u8, span, "raw")) {
                const block = try findCaptureBlock(sql, close + 2, end_index, "raw", "endraw");
                try out.appendSlice(context.allocator, sql[close + 2 .. block.start]);
                index = afterTag(sql, block.close, end_index);
                continue;
            }
            if (std.mem.startsWith(u8, span, "set ") and std.mem.indexOfScalar(u8, span, '=') == null) {
                const block = try findCaptureBlock(sql, close + 2, end_index, "set", "endset");
                var captured: std.ArrayList(u8) = .empty;
                defer captured.deinit(context.allocator);
                try renderRange(context, sql, afterTag(sql, close + 2, end_index), block.start, &captured);
                const pipe = std.mem.indexOfScalar(u8, span, '|');
                const target = std.mem.trim(u8, span[4 .. pipe orelse span.len], " \t\r\n");
                const value = native_expr.Value{ .string = try context.value_arena.allocator().dupe(u8, captured.items) };
                if (pipe) |filter_start| {
                    try context.setValue("__dxt_capture", value);
                    const expression = try std.fmt.allocPrint(context.value_arena.allocator(), "__dxt_capture{s}", .{span[filter_start..]});
                    try assignValue(context, target, try context.evaluate(expression));
                } else try assignValue(context, target, value);
                index = afterTag(sql, block.close, end_index);
                continue;
            }
            if (std.mem.startsWith(u8, span, "call") and span.len > 4 and (std.ascii.isWhitespace(span[4]) or span[4] == '(')) {
                const block = try findCaptureBlock(sql, close + 2, end_index, "call", "endcall");
                const arena = context.value_arena.allocator();
                var expression = std.mem.trim(u8, span[4..], " \t\r\n");
                var parameters: []const MacroParameter = &.{};
                if (expression.len != 0 and expression[0] == '(') {
                    const finish = findMatchingParen(expression, 0) orelse return error.UnsupportedJinja;
                    parameters = try macroParameters(arena, expression[1..finish]);
                    expression = std.mem.trim(u8, expression[finish + 1 ..], " \t\r\n");
                }
                const call = try parseSingleCall(expression);
                const args = try native_expr.evaluateArguments(arena, expression[call.open + 1 .. call.close], context.host());
                const caller = try arena.create(CallerBlock);
                caller.* = .{
                    .sql = sql,
                    .body = .{ .start = afterTag(sql, close + 2, end_index), .end = block.start },
                    .parameters = parameters,
                    .bindings = try arena.dupe(CompileContext.ValueBinding, context.bindings.items),
                    .vars = try arena.dupe(StaticVar, context.vars.items),
                    .lists = try arena.dupe(StaticList, context.lists.items),
                    .scope_depth = context.scope_depth,
                    .macro_package = context.current_macro_package,
                    .capture_undefined = context.capturesUndefined(),
                };
                const caller_name = try std.fmt.allocPrint(arena, "__dxt_caller:{d}", .{context.caller_blocks.items.len});
                try context.caller_blocks.append(arena, caller);
                const arguments = try arena.alloc(native_expr.Argument, args.len + 1);
                @memcpy(arguments[0..args.len], args);
                arguments[args.len] = .{ .name = "caller", .value = .{ .callable = caller_name } };
                const value = try callExpressionValue(context, std.mem.trim(u8, expression[0..call.open], " \t"), arguments, arena);
                if (value != .none) try out.appendSlice(context.allocator, try value.text(arena));
                index = afterTag(sql, block.close, end_index);
                continue;
            }
            if (std.mem.eql(u8, span, "with") or std.mem.startsWith(u8, span, "with ")) {
                const block = try findCaptureBlock(sql, close + 2, end_index, "with", "endwith");
                context.pushScope();
                defer context.popScope();
                const arena = context.value_arena.allocator();
                const args = try native_expr.evaluateArguments(arena, std.mem.trim(u8, span[4..], " \t"), context.host());
                for (args) |arg| try assignValue(context, arg.name orelse return error.InvalidJinjaArguments, arg.value);
                try renderRange(context, sql, afterTag(sql, close + 2, end_index), block.start, out);
                index = afterTag(sql, block.close, end_index);
                continue;
            }
            if (isEndForStatement(span)) return error.UnsupportedJinja;
            if (isEndIfStatement(span) or isElseStatement(span) or isElifStatement(span)) return error.UnsupportedJinja;
            if (isForStatement(span)) {
                const block = try parseForBlock(sql, afterTag(sql, close + 2, end_index), span);
                const iterable = try context.evaluate(block.list_name);
                const arena = context.value_arena.allocator();
                const frame = try arena.create(LoopFrame);
                frame.* = .{
                    .state = .{ .iterator = try @import("expression_sequence.zig").iter(arena, iterable) },
                    .block = block,
                    .bindings = try arena.dupe(CompileContext.ValueBinding, context.bindings.items),
                    .vars = try arena.dupe(StaticVar, context.vars.items),
                    .lists = try arena.dupe(StaticList, context.lists.items),
                    .scope_depth = context.scope_depth,
                    .macro_package = context.current_macro_package,
                    .capture_undefined = context.capturesUndefined(),
                };
                if (block.filter_expression == null and !@import("expression_sequence.zig").isIterator(iterable)) frame.state.known_length = (try native_expr.iterableValuesWithHost(arena, iterable, context.host())).len;
                const loop_id = context.loop_states.items.len;
                try context.loop_states.append(arena, frame);
                const loop_value = try @import("loop_context.zig").value(arena, loop_id);
                var loop_index: usize = 0;
                while (try loopItem(context, frame, loop_index)) |value| : (loop_index += 1) {
                    frame.state.index = loop_index;
                    context.pushScope();
                    try assignValue(context, block.variable_name, value);
                    try context.setValue("loop", loop_value);
                    context.loop_depth += 1;
                    renderRange(context, sql, block.body_start, block.body_end, out) catch |err| {
                        context.loop_depth -= 1;
                        context.popScope();
                        return err;
                    };
                    context.loop_depth -= 1;
                    context.popScope();
                    const stop = context.loop_break;
                    context.loop_break = false;
                    context.loop_continue = false;
                    if (stop or context.returned != null) break;
                }
                if (frame.state.items.items.len == 0 and context.returned == null) if (block.else_body_start) |else_start| try renderRange(context, sql, else_start, block.else_body_end, out);
                index = afterTag(sql, block.end_tag_close, end_index);
                continue;
            }
            if (isIfStatement(span)) {
                const block = try parseIfBlock(context, sql, afterTag(sql, close + 2, end_index), span);
                if (block.selected_body_start) |selected_start| {
                    try renderRange(context, sql, selected_start, block.selected_body_end, out);
                }
                index = afterTag(sql, block.end_tag_close, end_index);
                continue;
            }
            try renderStatement(context, span);
        }
        index = afterTag(sql, close + 2, end_index);
    }
}

const CaptureBlock = struct { start: usize, close: usize };

fn findCaptureBlock(sql: []const u8, start: usize, limit: usize, opening: []const u8, ending: []const u8) !CaptureBlock {
    var index = start;
    var depth: usize = 1;
    while (index < limit) {
        const tag = std.mem.indexOfPos(u8, sql, index, "{%") orelse return error.UnsupportedJinja;
        const close = std.mem.indexOfPos(u8, sql, tag + 2, "%}") orelse return error.UnsupportedJinja;
        if (close + 2 > limit) return error.UnsupportedJinja;
        const span = tagContent(sql, tag, close);
        if (std.mem.eql(u8, span, ending)) {
            depth -= 1;
            if (depth == 0) return .{ .start = tag, .close = close + 2 };
        } else if (std.mem.startsWith(u8, span, opening) and (span.len == opening.len or std.ascii.isWhitespace(span[opening.len]) or (std.mem.eql(u8, opening, "call") and span[opening.len] == '('))) {
            if (!std.mem.eql(u8, opening, "set") or std.mem.indexOfScalar(u8, span, '=') == null) depth += 1;
        }
        index = close + 2;
    }
    return error.UnsupportedJinja;
}

fn tagContent(sql: []const u8, start: usize, close: usize) []const u8 {
    const begin = start + 2 + @as(usize, if (sql[start + 2] == '-') 1 else 0);
    const finish = close - @as(usize, if (close > begin and sql[close - 1] == '-') 1 else 0);
    return std.mem.trim(u8, sql[begin..finish], " \t\r\n");
}

fn trimOutput(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) void {
    _ = allocator;
    while (out.items.len > 0 and std.ascii.isWhitespace(out.items[out.items.len - 1])) _ = out.pop();
}

fn afterTag(sql: []const u8, end: usize, limit: usize) usize {
    var next = end;
    if (end >= 3 and sql[end - 3] == '-') while (next < limit and std.ascii.isWhitespace(sql[next])) {
        next += 1;
    };
    return next;
}

const LoopFrame = struct {
    state: @import("loop_context.zig").State,
    block: ForBlock,
    bindings: []CompileContext.ValueBinding,
    vars: []StaticVar,
    lists: []StaticList,
    scope_depth: usize,
    macro_package: ?[]const u8,
    capture_undefined: bool,
};

fn loopItem(context: *CompileContext, frame: *LoopFrame, index: usize) anyerror!?native_expr.Value {
    while (frame.state.items.items.len <= index and !frame.state.ended) {
        const next = try @import("expression_sequence.zig").next(context.value_arena.allocator(), frame.state.iterator, context.host());
        if (next == null) {
            frame.state.ended = true;
            break;
        }
        if (frame.block.filter_expression) |filter| if (!try loopFilter(context, frame, next.?, filter)) continue;
        if (frame.state.items.items.len == 100000) return error.JinjaIterationLimitExceeded;
        try frame.state.items.append(context.value_arena.allocator(), next.?);
    }
    return if (index < frame.state.items.items.len) frame.state.items.items[index] else null;
}

fn loopFilter(context: *CompileContext, frame: *LoopFrame, value: native_expr.Value, filter: []const u8) anyerror!bool {
    const previous_bindings = context.bindings;
    const previous_vars = context.vars;
    const previous_lists = context.lists;
    const previous_scope = context.scope_depth;
    const previous_package = context.current_macro_package;
    const previous_capture = context.capture_undefined_override;
    context.bindings = .empty;
    context.vars = .empty;
    context.lists = .empty;
    context.scope_depth = frame.scope_depth;
    context.current_macro_package = frame.macro_package;
    context.capture_undefined_override = frame.capture_undefined;
    defer {
        context.bindings.deinit(context.allocator);
        context.vars.deinit(context.allocator);
        context.lists.deinit(context.allocator);
        context.bindings = previous_bindings;
        context.vars = previous_vars;
        context.lists = previous_lists;
        context.scope_depth = previous_scope;
        context.current_macro_package = previous_package;
        context.capture_undefined_override = previous_capture;
    }
    try context.bindings.appendSlice(context.allocator, frame.bindings);
    try context.vars.appendSlice(context.allocator, frame.vars);
    try context.lists.appendSlice(context.allocator, frame.lists);
    context.pushScope();
    defer context.popScope();
    try assignValue(context, frame.block.variable_name, value);
    return (try context.evaluate(filter)).truthy();
}

fn loopCall(context: *CompileContext, name: []const u8, args: []const native_expr.Argument, a: std.mem.Allocator) anyerror!native_expr.Value {
    const colon = std.mem.lastIndexOfScalar(u8, name, ':') orelse return error.InvalidJinjaArguments;
    const id = std.fmt.parseUnsigned(usize, name[colon + 1 ..], 10) catch return error.InvalidJinjaArguments;
    if (id >= context.loop_states.items.len) return error.InvalidJinjaArguments;
    const frame = context.loop_states.items[id];
    if (std.mem.startsWith(u8, name, "__dxt_loop_attribute:")) {
        if (args.len != 1 or args[0].name != null or args[0].value != .string) return error.InvalidJinjaArguments;
        const attribute = args[0].value.string;
        if (std.mem.eql(u8, attribute, "last") or std.mem.eql(u8, attribute, "nextitem")) _ = try loopItem(context, frame, frame.state.index + 1);
        if (frame.state.known_length == null and (std.mem.eql(u8, attribute, "length") or std.mem.eql(u8, attribute, "revindex") or std.mem.eql(u8, attribute, "revindex0"))) {
            while (try loopItem(context, frame, frame.state.items.items.len)) |_| {}
            frame.state.known_length = frame.state.items.items.len;
        }
        return @import("loop_context.zig").attribute(a, &frame.state, id, attribute);
    }
    return @import("loop_context.zig").method(a, &frame.state, name[11..colon], args);
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

pub fn relationNameForRefNode(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node) ![]const u8 {
    if (!std.mem.eql(u8, node.materialized, "ephemeral")) {
        if (graph.deferredRelation(node.unique_id)) |name| return try allocator.dupe(u8, name);
    }
    return try relationNameForNode(allocator, graph, node);
}

pub fn relationNameForNode(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node) ![]const u8 {
    if (graph.unitFixtureRelation(node.unique_id)) |relation| return try allocator.dupe(u8, relation);
    if (std.mem.eql(u8, node.resource_type, "source")) if (node.relation_name) |relation| return try allocator.dupe(u8, relation);
    const schema = try relationSchemaForNode(allocator, graph, node);
    defer allocator.free(schema);
    const identifier = relationIdentifierForNode(node);
    return renderRelation(allocator, .{ .database = if (graph.unit_fixture_relations) null else relationDatabaseForNode(graph, node), .schema = schema, .identifier = identifier });
}

pub fn relationValueForNode(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node, input: bool) !native_expr.Value {
    if (graph.unitFixtureRelation(node.unique_id)) |alias| return try dbt_context.relationValue(allocator, .{
        .adapter_type = graph.adapter_type,
        .identifier = alias,
        .relation_type = "cte",
        .quote_policy = .{ .identifier = false },
        .base_sql = alias,
    });
    const ephemeral = input and std.mem.eql(u8, node.resource_type, "model") and std.mem.eql(u8, node.materialized, "ephemeral");
    var definition = dbt_context.RelationDef{
        .adapter_type = graph.adapter_type,
        .database = if (graph.unit_fixture_relations or ephemeral) null else relationDatabaseForNode(graph, node),
        .schema = if (ephemeral) null else try relationSchemaForNode(allocator, graph, node),
        .identifier = if (ephemeral) try ephemeralCteName(allocator, node) else relationIdentifierForNode(node),
        .relation_type = if (ephemeral) "cte" else null,
    };
    if (ephemeral) definition.quote_policy.identifier = false;
    if (input and !ephemeral) definition.base_sql = try relationNameForRefNode(allocator, graph, node) else if (std.mem.eql(u8, node.resource_type, "source")) definition.base_sql = node.relation_name;
    return try dbt_context.relationValue(allocator, definition);
}

pub fn relationValueForSource(allocator: std.mem.Allocator, graph: *const Graph, current: *const Node, source: *const SourceDef) !native_expr.Value {
    if (graph.unitFixtureRelation(source.unique_id)) |alias| return try dbt_context.relationValue(allocator, .{
        .adapter_type = graph.adapter_type,
        .identifier = alias,
        .relation_type = "cte",
        .quote_policy = .{ .identifier = false },
        .base_sql = alias,
    });
    const base = try relationNameForSource(allocator, source);
    return try dbt_context.relationValue(allocator, .{
        .adapter_type = graph.adapter_type,
        .database = sourceDatabaseName(source),
        .schema = sourceSchemaName(source),
        .identifier = sourceIdentifier(source),
        .quote_policy = .{ .database = source.quoting.database orelse true, .schema = source.quoting.schema orelse true, .identifier = source.quoting.identifier orelse true },
        .base_sql = base,
        .rendered_sql = try @import("input_relations.zig").render(allocator, graph, current, source.effective_config, sourceIdentifier(source), base),
    });
}

pub fn relationValueForInputNode(allocator: std.mem.Allocator, graph: *const Graph, current: *const Node, target: *const Node) !native_expr.Value {
    if (graph.unitFixtureRelation(target.unique_id) != null) return try relationValueForNode(allocator, graph, target, true);
    var definition = try dbt_context.relationFromValue(allocator, try relationValueForNode(allocator, graph, target, true));
    const base = try dbt_context.renderRelation(allocator, definition);
    definition.rendered_sql = try @import("input_relations.zig").render(allocator, graph, current, target.effective_config, definition.identifier orelse target.name, base);
    return try dbt_context.relationValue(allocator, definition);
}

fn renderExpression(context: *CompileContext, span: []const u8) ![]const u8 {
    // Dispatch returns a callable macro in dbt's context. Preserve its existing
    // namespace resolution while ordinary expressions use native typed values.
    if (!context.documentation and std.mem.startsWith(u8, span, "adapter.dispatch")) return try renderAdapterDispatchExpression(context, span);
    const value = try context.evaluate(span);
    if (context.returned != null) return try context.allocator.dupe(u8, "");
    const rendered = value.text(context.value_arena.allocator()) catch |err| {
        if (@import("compile_diagnostics.zig").message(err) == null) {
            const detail = try std.fmt.allocPrint(context.value_arena.allocator(), "{s} rendering expression: {s}", .{ @errorName(err), span });
            @import("compile_diagnostics.zig").captureError(context.node.original_file_path, context.node.name, detail, err);
        }
        return err;
    };
    return try context.allocator.dupe(u8, rendered);
}

fn resolveExpressionValue(raw_context: *anyopaque, path: []const u8, allocator: std.mem.Allocator) anyerror!native_expr.Value {
    const context: *CompileContext = @ptrCast(@alignCast(raw_context));
    var parts = std.mem.splitScalar(u8, path, '.');
    const name = parts.next() orelse return .undefined;
    var index = context.bindings.items.len;
    while (index > 0) {
        index -= 1;
        const binding = context.bindings.items[index];
        if (std.mem.eql(u8, binding.name, name)) {
            var value = binding.value;
            while (parts.next()) |attribute| {
                if (value == .undefined and context.capturesUndefined()) value = try native_expr.captureUndefined(allocator, binding.name);
                value = try native_expr.attributeWithHost(allocator, value, attribute, context.host());
                if (value == .undefined and context.capturesUndefined()) value = try native_expr.captureUndefined(allocator, attribute);
            }
            return value;
        }
    }
    if (context.getVar(path)) |value| return .{ .string = value };
    if (context.getList(path)) |strings| {
        const values = try native_expr.allocateValues(allocator, strings.len);
        for (strings, values) |s, *v| v.* = .{ .string = s };
        return .{ .list = values };
    }
    if (context.documentation_block) return if (std.mem.indexOfScalar(u8, path, '.') == null) .conditional_undefined else error.UndefinedJinjaValue;
    if (@import("base_context.zig").callable(path)) return .{ .callable = path };
    if (try @import("modules_context.zig").resolve(allocator, path)) |value| return value;
    if (try @import("regex_context.zig").resolve(allocator, path)) |value| return value;
    if (context.documentation) {
        if (@import("doc_context.zig").baseCallable(path)) return .{ .callable = path };
        inline for (.{ "execute", "this", "model", "config", "adapter", "api", "graph", "sql", "compiled_code", "results", "schemas", "database_schemas", "pre_hooks", "post_hooks" }) |unavailable| {
            if (std.mem.eql(u8, name, unavailable)) return if (std.mem.eql(u8, path, name)) .conditional_undefined else error.UndefinedJinjaValue;
        }
    }
    if (std.mem.eql(u8, path, "execute")) return .{ .boolean = context.execute_override orelse (context.parse_node == null) };
    if (std.mem.eql(u8, path, "database")) return if (relationDatabaseForNode(context.graph, context.node)) |database| .{ .string = database } else .none;
    if (std.mem.eql(u8, path, "schema")) return .{ .string = try relationSchemaForNode(allocator, context.graph, context.node) };
    if (std.mem.eql(u8, path, "sql") or std.mem.eql(u8, path, "compiled_code")) return if (context.node.compiled_code) |sql| .{ .string = sql } else .undefined;
    if (std.mem.eql(u8, path, "pre_hooks") or std.mem.eql(u8, path, "post_hooks")) {
        const config = try @import("canonical_manifest_config.zig").node(allocator, context.node);
        return try valueFromJson(allocator, @import("config_value.zig").get(config, if (std.mem.eql(u8, path, "pre_hooks")) "pre-hook" else "post-hook").?);
    }
    if (std.mem.eql(u8, path, "dbt_version")) return .{ .string = @import("invocation.zig").compatible_core };
    if (std.mem.eql(u8, path, "flags") or std.mem.startsWith(u8, path, "flags.")) {
        const flags = try flagsValue(allocator, context.graph);
        if (std.mem.eql(u8, path, "flags")) return flags;
        for (flags.object) |entry| if (std.mem.eql(u8, entry.key, path[6..])) return entry.value;
        return .undefined;
    }
    if (std.mem.eql(u8, path, "adapter.behavior.enable_truthy_nulls_equals_macro.no_warn")) return .{ .boolean = context.graph.enable_truthy_nulls_equals_macro };
    if (std.mem.eql(u8, path, "model") or std.mem.startsWith(u8, path, "model.")) {
        const model = try @import("context_values.zig").model(allocator, context.graph, context.node);
        return if (path.len == 5) model else @import("context_values.zig").attribute(model, path[6..]);
    }
    if (std.mem.eql(u8, path, "config") or std.mem.startsWith(u8, path, "config.")) {
        const config = try configProxy(allocator, context);
        return if (path.len == 6) config else @import("context_values.zig").attribute(config, path[7..]);
    }
    if (std.mem.eql(u8, path, "this") or std.mem.startsWith(u8, path, "this.")) {
        if (context.node.hook_index != null) return .none;
        var value = try relationValueForNode(allocator, context.graph, context.node, false);
        if (path.len == 4) return value;
        var attributes = std.mem.splitScalar(u8, path[5..], '.');
        while (attributes.next()) |attribute| value = try native_expr.checkedAttribute(value, attribute);
        return value;
    }
    if (std.mem.eql(u8, path, "target") and context.graph.target_context != .null) return try valueFromJson(allocator, context.graph.target_context);
    if (std.mem.startsWith(u8, path, "target.")) {
        if (@import("config_value.zig").get(context.graph.target_context, path[7..])) |value| return try valueFromJson(allocator, value);
        // Native parse can inspect a project without a profile. Preserve its
        // absent catalog as None when stock naming macros read target.database.
        if (std.mem.eql(u8, path, "target.database") and context.graph.target_context == .null) return .none;
        return .{ .string = renderTargetAttribute(allocator, context.graph, path[7..]) catch |err| switch (err) {
            error.UnsupportedJinja => return .undefined,
            else => return err,
        } };
    }
    if (context.graph.execution_hooks) |hooks| {
        const value = try hooks.resolve(hooks.context, path, allocator);
        if (value != .undefined) return value;
    }
    if (context.node.hook_index != null) {
        if (std.mem.eql(u8, path, "results") or std.mem.eql(u8, path, "schemas") or std.mem.eql(u8, path, "database_schemas")) return .conditional_undefined;
        if (std.mem.eql(u8, path, "index")) return .conditional_undefined;
    }
    if (context.documentation) return if (std.mem.indexOfScalar(u8, path, '.') == null) .conditional_undefined else error.UndefinedJinjaValue;
    const macro_id = if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot|
        resolve.findMacroIdByPackageAndName(context.graph, path[0..dot], path[dot + 1 ..])
    else
        resolve.findMacroIdForUnqualifiedNamespaceCall(context.graph, context.namespacePackage(), path);
    if (macro_id) |unique_id| if (findMacroByUniqueId(context.graph, unique_id)) |macro| return .{ .callable = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ macro.package_name, macro.name }) };
    return .undefined;
}

fn flagsValue(allocator: std.mem.Allocator, graph: *const Graph) !native_expr.Value {
    const json = try std.json.Stringify.valueAlloc(allocator, graph.command_options, .{});
    const document = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    var entries: std.ArrayList(native_expr.Entry) = .empty;
    var it = document.value.object.iterator();
    while (it.next()) |entry| {
        var exposed = false;
        for ([_][]const u8{ "warn_error", "warn_error_options", "write_json", "use_colors", "profiles_dir", "log_format", "version_check", "fail_fast", "indirect_selection", "quiet", "target_path", "log_path", "which", "full_refresh", "store_failures", "debug", "cache_selected_only", "log_cache_events", "static_parser", "partial_parse", "introspect", "empty" }) |key| if (std.mem.eql(u8, key, entry.key_ptr.*)) {
            exposed = true;
            break;
        };
        if (!exposed) continue;
        const name = try std.ascii.allocUpperString(allocator, entry.key_ptr.*);
        const available = @import("cli_options.zig").commandHasFlag(graph.command_options.which, name);
        // Core FLAGS_DEFAULTS includes these three keys even when the command
        // has no decorator. EMPTY has no global default and remains None.
        const value = if (std.mem.eql(u8, name, "FULL_REFRESH")) native_expr.Value{ .boolean = available and graph.full_refresh } else if (std.mem.eql(u8, name, "STORE_FAILURES")) native_expr.Value{ .boolean = available and graph.command_options.store_failures } else if (std.mem.eql(u8, name, "INTROSPECT")) native_expr.Value{ .boolean = !available or graph.command_options.introspect } else if (std.mem.eql(u8, name, "EMPTY") and !available) native_expr.Value.none else try valueFromJson(allocator, entry.value_ptr.*);
        try entries.append(allocator, .{ .key = name, .value = value });
    }
    for ([_]native_expr.Entry{
        .{ .key = "SKIP_NODES_IF_ON_RUN_START_FAILS", .value = .{ .boolean = graph.skip_nodes_if_on_run_start_fails } },
        .{ .key = "ENABLE_TRUTHY_NULLS_EQUALS_MACRO", .value = .{ .boolean = graph.enable_truthy_nulls_equals_macro } },
        .{ .key = "NO_PRINT", .value = .none },
        .{ .key = "STORE_FAILURES", .value = .none },
        .{ .key = "STATIC_PARSER", .value = .{ .boolean = true } },
        .{ .key = "PARTIAL_PARSE", .value = .{ .boolean = true } },
        .{ .key = "USE_EXPERIMENTAL_PARSER", .value = .{ .boolean = false } },
        .{ .key = "SEND_ANONYMOUS_USAGE_STATS", .value = .{ .boolean = false } },
        .{ .key = "LOG_CACHE_EVENTS", .value = .{ .boolean = false } },
        .{ .key = "CACHE_SELECTED_ONLY", .value = .{ .boolean = false } },
        .{ .key = "INTROSPECT", .value = .{ .boolean = true } },
        .{ .key = "EMPTY", .value = .{ .boolean = false } },
        .{ .key = "PRINTER_WIDTH", .value = .{ .integer = "80" } },
        .{ .key = "DEBUG", .value = .{ .boolean = graph.command_options.log_level == .debug } },
    }) |default| {
        var present = false;
        for (entries.items) |entry| if (std.mem.eql(u8, entry.key, default.key)) {
            present = true;
            break;
        };
        if (!present) try entries.append(allocator, default);
    }
    return .{ .object = try entries.toOwnedSlice(allocator) };
}

fn upsertConfigArgument(allocator: std.mem.Allocator, values: *std.ArrayList(native_expr.Entry), key: []const u8, value: native_expr.Value) !void {
    for (values.items) |*entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            entry.value = value;
            return;
        }
    }
    try values.append(allocator, .{ .key = key, .value = value });
}

fn configProxy(allocator: std.mem.Allocator, context: *CompileContext) !native_expr.Value {
    const methods = try native_expr.allocateEntries(allocator, 4);
    inline for (.{ "get", "require", "persist_relation_docs", "persist_column_docs" }, 0..) |name, index| {
        methods[index] = .{ .key = name, .value = .{ .callable = "config." ++ name } };
    }
    _ = context;
    return .{ .object = methods };
}

fn callExpressionValue(raw_context: *anyopaque, name: []const u8, args: []const native_expr.Argument, allocator: std.mem.Allocator) anyerror!native_expr.Value {
    const context: *CompileContext = @ptrCast(@alignCast(raw_context));
    if (std.mem.startsWith(u8, name, "__dxt_loop_")) return loopCall(context, name, args, allocator);
    if (std.mem.startsWith(u8, name, "__dxt_caller:")) {
        const index = std.fmt.parseUnsigned(usize, name[13..], 10) catch return error.InvalidJinjaArguments;
        if (index >= context.caller_blocks.items.len) return error.InvalidJinjaArguments;
        return try renderCallerValue(context, context.caller_blocks.items[index], args);
    }
    if (context.documentation_block) {
        if (try @import("container_methods.zig").call(allocator, name, args)) |mutation| {
            if (mutation.original) |original| for (context.bindings.items) |*binding| try @import("container_methods.zig").replaceAliases(&binding.value, original, mutation.replacement.?, 0);
            return mutation.result;
        }
        return error.UnresolvedMacro;
    }
    const root_end = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
    var binding_index = context.bindings.items.len;
    while (binding_index != 0) {
        binding_index -= 1;
        if (!std.mem.eql(u8, context.bindings.items[binding_index].name, name[0..root_end])) continue;
        const bound = try resolveExpressionValue(context, name, allocator);
        if (bound == .capture_undefined) return try native_expr.callUndefined(bound);
        const callable = native_expr.callableName(bound);
        if (callable) |function| if (!std.mem.eql(u8, function, name)) return try callExpressionValue(context, function, args, allocator);
        if (root_end == name.len and callable == null) return error.JinjaTypeError;
        break;
    }
    if (context.documentation) {
        if (try @import("doc_context.zig").call(allocator, context.graph, context.node.package_name, name, args)) |value| return value;
        if (!@import("doc_context.zig").allowsCall(name)) return error.UnresolvedMacro;
    }
    if (try @import("base_context.zig").call(allocator, name, args)) |value| return value;
    if (try @import("bundled_macros.zig").callColumn(allocator, name, args)) |value| return value;
    if (try @import("container_methods.zig").call(allocator, name, args)) |mutation| {
        if (mutation.original) |original| for (context.bindings.items) |*binding| try @import("container_methods.zig").replaceAliases(&binding.value, original, mutation.replacement.?, 0);
        return mutation.result;
    }
    if (try @import("modules_context.zig").call(allocator, name, args, .{ .host = context.host() })) |value| return value;
    if (try @import("regex_context.zig").call(allocator, name, args, context.host())) |value| return value;
    if (try @import("grants_context.zig").call(allocator, name, args)) |value| return value;
    if (try @import("constraint_context.zig").call(allocator, context.graph.adapter_type, name, args, context.host())) |value| return value;
    if (try dbt_context.call(allocator, context.graph.adapter_type, name, args)) |value| return value;
    if (std.mem.eql(u8, name, "adapter.type")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        return .{ .string = context.graph.adapter_type };
    }
    if (std.mem.eql(u8, name, "config.get") or std.mem.eql(u8, name, "config.require")) {
        if (args.len < 1 or args.len > 2 or args[0].value != .string) return error.InvalidJinjaArguments;
        if (context.parse_node != null) return .{ .string = "" };
        const value = (try @import("context_values.zig").config(allocator, context.node)).attribute(args[0].value.string);
        if (value != .undefined) return value;
        if (args.len == 2) return args[1].value;
        return if (std.mem.eql(u8, name, "config.require")) error.RequiredConfigurationMissing else .none;
    }
    if (std.mem.eql(u8, name, "config.persist_relation_docs") or std.mem.eql(u8, name, "config.persist_column_docs")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        if (context.parse_node != null) return .{ .boolean = false };
        const config = try @import("context_values.zig").config(allocator, context.node);
        const docs = config.attribute("persist_docs");
        if (docs != .object) return error.PersistDocsValueTypeError;
        const value = docs.attribute(if (std.mem.eql(u8, name, "config.persist_relation_docs")) "relation" else "columns");
        return if (value == .undefined) .{ .boolean = false } else value;
    }
    // The expression lexer resolves direct dotted calls through the host;
    // object methods bound by a macro therefore need their immutable callable
    // payload resolved before ordinary package namespace lookup.
    if (std.mem.startsWith(u8, name, "this.")) {
        const method = try resolveExpressionValue(context, name, allocator);
        if (method == .callable) return (try dbt_context.call(allocator, context.graph.adapter_type, method.callable, args)) orelse error.UnsupportedRelationMethod;
    }
    if (std.mem.indexOfScalar(u8, name, '.')) |dot| {
        var index = context.bindings.items.len;
        while (index > 0) {
            index -= 1;
            const binding = context.bindings.items[index];
            if (std.mem.eql(u8, binding.name, name[0..dot])) {
                const method = try resolveExpressionValue(context, name, allocator);
                if (method == .callable) {
                    if (try dbt_context.call(allocator, context.graph.adapter_type, method.callable, args)) |value| return value;
                    return try callExpressionValue(context, method.callable, args, allocator);
                }
                break;
            }
        }
    }
    if (context.parse_node == null) if (unitMacroOverride(context.graph, name)) |override| return try valueFromJson(allocator, override);
    if (std.mem.eql(u8, name, "__dxt_caller") or std.mem.eql(u8, name, "caller")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        return try resolveExpressionValue(context, "__dxt_caller_sql", allocator);
    }
    if (std.mem.eql(u8, name, "config")) {
        if (context.parse_node) |node| {
            var values: std.ArrayList(native_expr.Entry) = .empty;
            for (args) |arg| {
                if (arg.name) |key| {
                    try upsertConfigArgument(allocator, &values, key, arg.value);
                } else if (arg.value == .object) {
                    for (arg.value.object) |entry| {
                        const key = native_expr.entryKey(entry);
                        if (key != .string) return error.InvalidJinjaArguments;
                        try upsertConfigArgument(allocator, &values, key.string, entry.value);
                    }
                } else return error.InvalidJinjaArguments;
            }
            var raw: std.ArrayList(u8) = .empty;
            var count: usize = 0;
            for (values.items) |entry| {
                if (count != 0) try raw.appendSlice(allocator, ", ");
                try raw.appendSlice(allocator, entry.key);
                try raw.append(allocator, '=');
                const value = entry.value;
                if (value == .boolean) try raw.appendSlice(allocator, if (value.boolean) "true" else "false") else try raw.appendSlice(allocator, try native_expr.repr(value, allocator));
                count += 1;
            }
            try jinja.parseConfig(context.allocator, raw.items, node);
        }
        return .{ .string = "" };
    }
    if (std.mem.eql(u8, name, "is_incremental")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        // Loaded projects invoke the real macro and acquire relation metadata
        // only when the authored template calls it. Synthetic API graphs have
        // no bundled macros and retain their supplied execution state.
        if (resolve.findMacroIdForUnqualifiedNamespaceCall(context.graph, context.namespacePackage(), name) == null) return .{ .boolean = (context.execute_override orelse (context.parse_node == null)) and context.node.runtime_is_incremental };
    }
    if (std.mem.eql(u8, name, "var") or std.mem.eql(u8, name, "env_var")) {
        if (args.len < 1 or args.len > 2 or args[0].value != .string) return error.InvalidJinjaArguments;
        const key = args[0].value.string;
        if (context.parse_node == null) if (unitValueOverride(context.graph, if (std.mem.eql(u8, name, "var")) "vars" else "env_vars", key)) |override| {
            if (std.mem.startsWith(u8, key, "DBT_ENV_SECRET_") and std.mem.eql(u8, name, "env_var")) return error.SecretEnvironmentVariableForbidden;
            return try valueFromJson(allocator, override);
        };
        if (std.mem.eql(u8, name, "env_var")) {
            if (std.mem.startsWith(u8, key, "DBT_ENV_SECRET_")) return error.SecretEnvironmentVariableForbidden;
            if (context.graph.environment) |environment| {
                if (environment.get(key)) |value| return .{ .string = value };
            }
        } else if (findScopedGraphVar(context.graph, context.node.package_name, key)) |entry| {
            const value = if (entry.typed_value) |typed| try valueFromJson(allocator, typed) else native_expr.Value{ .string = entry.value };
            if (value != .string or (std.mem.indexOf(u8, value.string, "{{") == null and std.mem.indexOf(u8, value.string, "{%") == null)) return value;
            if (context.var_render_depth >= max_macro_render_depth) return error.JinjaExpressionDepthExceeded;
            context.var_render_depth += 1;
            defer context.var_render_depth -= 1;
            var rendered: std.ArrayList(u8) = .empty;
            defer rendered.deinit(context.allocator);
            try renderRange(context, value.string, 0, value.string.len, &rendered);
            return .{ .string = try allocator.dupe(u8, rendered.items) };
        }
        if (args.len == 2) return args[1].value;
        // Core ParseVar permits an unset model variable while discovering the
        // graph; the execution context still requires it during compilation.
        if (context.parse_node != null and std.mem.eql(u8, name, "var")) return .none;
        return if (std.mem.eql(u8, name, "var")) error.UnresolvedVar else error.EnvironmentVariableMissing;
    }
    if (std.mem.eql(u8, name, "return")) {
        if (args.len != 1 or context.macro_render_depth == 0) return error.InvalidJinjaArguments;
        context.returned = args[0].value;
        return .{ .string = "" };
    }
    if (context.parse_node != null and std.mem.eql(u8, name, "exceptions.warn")) {
        if (args.len != 1 or args[0].value != .string or (args[0].name != null and !std.mem.eql(u8, args[0].name.?, "msg"))) return error.InvalidJinjaArguments;
        if (context.graph.warning_registry) |registry| if (registry.runtime) |runtime| {
            try @import("jinja_warning.zig").emit(runtime, context.node, args[0].value.string, null, runtime.event_writer);
        };
        return .{ .string = "" };
    }
    if (std.mem.eql(u8, name, "exceptions.raise_compiler_error")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
        @import("compile_diagnostics.zig").capture(context.node.original_file_path, context.node.name, try args[0].value.text(allocator));
        return error.JinjaCompilerError;
    }
    if (std.mem.eql(u8, name, "exceptions.raise_contract_error") or std.mem.eql(u8, name, "exceptions.column_type_missing")) {
        @import("compile_diagnostics.zig").captureError(context.node.original_file_path, context.node.name, "Model contract does not match the SQL result columns.", error.ModelContractMismatch);
        return error.ModelContractMismatch;
    }
    if (std.mem.eql(u8, name, "render")) {
        if (args.len != 1 or args[0].value != .string) return error.InvalidJinjaArguments;
        var rendered: std.ArrayList(u8) = .empty;
        defer rendered.deinit(context.allocator);
        try renderRange(context, args[0].value.string, 0, args[0].value.string.len, &rendered);
        return .{ .string = try allocator.dupe(u8, rendered.items) };
    }
    if (std.mem.eql(u8, name, "tojson")) {
        if (args.len < 1 or args.len > 2) return error.InvalidJinjaArguments;
        return .{ .string = @import("context_json.zig").stringify(allocator, args[0].value) catch |err| switch (err) {
            error.JinjaCircularReference => return if (args.len == 2) args[1].value else .none,
            else => return err,
        } };
    }
    if (std.mem.eql(u8, name, "fromjson")) {
        if (args.len < 1 or args.len > 2 or args[0].value != .string) return error.InvalidJinjaArguments;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, args[0].value.string, .{}) catch return if (args.len == 2) args[1].value else .none;
        return try valueFromJson(allocator, parsed.value);
    }
    if (try @import("adapter_context.zig").credentialValue(allocator, context.graph, name, args)) |value| return value;
    if (context.parse_node != null and std.mem.eql(u8, name, "adapter.warn_once") and std.mem.eql(u8, context.graph.adapter_type, "duckdb")) {
        if (args.len != 1 or args[0].value != .string or (args[0].name != null and !std.mem.eql(u8, args[0].name.?, "msg"))) return error.InvalidJinjaArguments;
        if (context.graph.warning_registry) |registry| if (registry.runtime) |runtime| if (runtime.event_writer) |writer| {
            if (try registry.first(args[0].value.string)) try @import("concurrent_runner.zig").emitLogMessages(runtime, writer, context.node.unique_id, 0, &.{.{ .message = args[0].value.string, .level = "warn", .is_adapter_warning = true }});
        };
        return .{ .string = "" };
    }
    if (context.parse_node != null or context.execute_override == false) {
        if (try @import("adapter_context.zig").parseReplacement(allocator, name)) |value| return value;
        if (std.mem.eql(u8, name, "run_query") or std.mem.eql(u8, name, "load_result")) return .none;
        if (std.mem.eql(u8, name, "statement") or std.mem.eql(u8, name, "store_result") or std.mem.eql(u8, name, "log") or std.mem.eql(u8, name, "print")) return .{ .string = "" };
    }
    if (std.mem.eql(u8, name, "adapter.quote")) {
        if (args.len != 1 or args[0].value != .string) return error.InvalidJinjaArguments;
        return .{ .string = try quoteIdentifier(allocator, args[0].value.string) };
    }
    if (std.mem.eql(u8, name, "adapter.dispatch")) {
        if (args.len < 1 or args.len > 2 or args[0].value != .string or (args.len == 2 and args[1].value != .string)) return error.InvalidJinjaArguments;
        const prefixes = jinja.dispatchPrefixesForAdapter(context.graph.adapter_type);
        const macro_id = resolve.findMacroIdForAdapterDispatch(context.graph, context.current_macro_package orelse context.node.package_name, args[0].value.string, if (args.len == 2) args[1].value.string else null, prefixes.slice()) orelse return error.UnresolvedMacro;
        const macro = findMacroByUniqueId(context.graph, macro_id) orelse return error.UnresolvedMacro;
        return .{ .callable = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ macro.package_name, macro.name }) };
    }
    if (std.mem.eql(u8, name, "ref")) {
        const dep = try refFromArguments(context.allocator, args);
        if (context.parse_node) |node| {
            try node.refs.append(context.allocator, dep);
            return try relationValueForNode(allocator, context.graph, context.node, false);
        }
        const unique_id = try resolve.resolveRefDependency(context.graph, context.node.package_name, dep);
        try @import("ref_context.zig").validate(context.graph, context.node, unique_id, dep);
        if (!context.graph.unit_fixture_relations and !std.mem.eql(u8, context.node.resource_type, "sql_operation") and !std.mem.eql(u8, context.node.resource_type, "rpc_call")) try @import("group_access.zig").validateReference(context.graph, context.node.package_name, context.node.effective_config, unique_id);
        const target = findNodeByUniqueId(context.graph, unique_id) orelse return error.UnresolvedRef;
        return try relationValueForInputNode(allocator, context.graph, context.node, target);
    }
    if (std.mem.eql(u8, name, "source")) {
        if (args.len != 2 or args[0].name != null or args[1].name != null or args[0].value != .string or args[1].value != .string) return error.InvalidJinjaArguments;
        const dep = SourceDep{ .source_name = try context.allocator.dupe(u8, args[0].value.string), .table_name = try context.allocator.dupe(u8, args[1].value.string) };
        if (context.parse_node) |node| {
            try node.source_refs.append(context.allocator, dep);
            return try relationValueForNode(allocator, context.graph, context.node, false);
        }
        const unique_id = try resolve.resolveSourceDependency(context.graph, context.node.package_name, dep);
        const source = findSourceByUniqueId(context.graph, unique_id) orelse return error.UnresolvedSource;
        return try relationValueForSource(allocator, context.graph, context.node, source);
    }
    if (context.documentation) return error.UnresolvedMacro;
    var macro_id: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        macro_id = resolve.findMacroIdByPackageAndName(context.graph, name[0..dot], name[dot + 1 ..]);
    } else macro_id = resolve.findMacroIdForUnqualifiedNamespaceCall(context.graph, context.namespacePackage(), name);
    if (macro_id == null) {
        if (context.graph.execution_hooks) |hooks| {
            if (std.mem.eql(u8, name, "statement")) {
                var forwarded: std.ArrayList(native_expr.Argument) = .empty;
                var caller: ?native_expr.Value = null;
                for (args) |arg| {
                    if (arg.name != null and std.mem.eql(u8, arg.name.?, "caller")) {
                        if (caller != null) return error.InvalidJinjaArguments;
                        caller = arg.value;
                    } else try forwarded.append(allocator, arg);
                }
                const caller_sql = if (caller) |value|
                    try callExpressionValue(context, native_expr.callableName(value) orelse return error.JinjaTypeError, &.{}, allocator)
                else
                    try resolveExpressionValue(context, "__dxt_caller_sql", allocator);
                try forwarded.append(allocator, .{ .name = "caller_sql", .value = caller_sql });
                return try hooks.call(hooks.context, name, forwarded.items, allocator);
            }
            return hooks.call(hooks.context, name, args, allocator) catch |err| {
                if (err == error.UnresolvedMacro and context.capturesUndefined()) return try native_expr.callUndefined(try native_expr.captureUndefined(allocator, if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name[dot + 1 ..] else name));
                return err;
            };
        }
        if (context.capturesUndefined()) return try native_expr.callUndefined(try native_expr.captureUndefined(allocator, if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name[dot + 1 ..] else name));
        return error.UnresolvedMacro;
    }
    const macro = findMacroByUniqueId(context.graph, macro_id.?) orelse return error.UnresolvedMacro;
    try context.recordMacroDependency(macro.unique_id);
    // The pinned DuckDB helper leaves explicitly quoted column names unquoted
    // in the INSERT projection. Honor the authored quoting policy while
    // preserving project overrides and the bundled dependency identity.
    if (std.mem.eql(u8, macro.package_name, "dbt_duckdb") and std.mem.eql(u8, macro.name, "get_column_names") and @import("contracts.zig").enforced(context.node)) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        return @import("constraint_context.zig").columnNames(allocator, (try @import("context_values.zig").model(allocator, context.graph, context.node)).attribute("columns"));
    }
    return try renderMacroValue(context, macro, args);
}

fn unitValueOverride(graph: *const Graph, category: []const u8, key: []const u8) ?std.json.Value {
    const values = @import("config_value.zig");
    return values.get(values.get(graph.unit_overrides, category) orelse return null, key);
}
fn unitMacroOverride(graph: *const Graph, name: []const u8) ?std.json.Value {
    if (graph.unit_overrides != .object) return null;
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        if (std.mem.eql(u8, name[0..dot], "dbt")) if (unitValueOverride(graph, "macros", name[dot + 1 ..])) |value| return value;
        return unitValueOverride(graph, "macros", name);
    }
    if (unitValueOverride(graph, "macros", name)) |value| return value;
    const dbt_name = std.fmt.allocPrint(graph.allocator, "dbt.{s}", .{name}) catch return null;
    defer graph.allocator.free(dbt_name);
    if (resolve.findMacroIdByPackageAndName(graph, "dbt", name) != null or std.mem.eql(u8, name, "is_incremental")) return unitValueOverride(graph, "macros", dbt_name);
    return null;
}

fn refFromArguments(allocator: std.mem.Allocator, args: []const native_expr.Argument) !RefDep {
    var positional: [2][]const u8 = undefined;
    var count: usize = 0;
    var version: std.json.Value = .null;
    for (args) |arg| {
        if (arg.name) |key| {
            if ((!std.mem.eql(u8, key, "v") and !std.mem.eql(u8, key, "version")) or version != .null) return error.InvalidJinjaArguments;
            version = try @import("config_value.zig").fromExpression(allocator, arg.value);
            if (version != .null and version != .integer and version != .float and version != .string) return error.InvalidJinjaArguments;
        } else {
            if (arg.value != .string or count == 2) return error.InvalidJinjaArguments;
            positional[count] = arg.value.string;
            count += 1;
        }
    }
    if (count == 0) return error.InvalidJinjaArguments;
    return .{ .package = if (count == 2) try allocator.dupe(u8, positional[0]) else null, .name = try allocator.dupe(u8, positional[count - 1]), .version = version };
}

const MacroParameter = struct { name: []const u8, default: ?[]const u8 = null };

const CallerBlock = struct {
    sql: []const u8,
    body: MacroBodyRange,
    parameters: []const MacroParameter,
    bindings: []CompileContext.ValueBinding,
    vars: []const StaticVar,
    lists: []const StaticList,
    scope_depth: usize,
    macro_package: ?[]const u8,
    capture_undefined: bool,
};

fn macroParameters(allocator: std.mem.Allocator, declaration: []const u8) ![]const MacroParameter {
    var parameters: std.ArrayList(MacroParameter) = .empty;
    var saw_default = false;
    var offset: usize = 0;
    while (offset < declaration.len) {
        const finish = expressionBoundary(declaration, offset, declaration.len);
        const part = std.mem.trim(u8, declaration[offset..finish], " \t\r\n");
        if (part.len != 0) {
            const eq = std.mem.indexOfScalar(u8, part, '=');
            if (eq != null) saw_default = true else if (saw_default) return error.InvalidJinjaArguments;
            if (eq) |at| if (std.mem.trim(u8, part[at + 1 ..], " \t\r\n").len == 0) return error.InvalidJinjaArguments;
            const name = std.mem.trim(u8, if (eq) |at| part[0..at] else part, " \t\r\n");
            if (name.len == 0 or !jinja.isIdentStart(name[0])) return error.InvalidJinjaArguments;
            for (name) |char| if (!jinja.isIdentChar(char)) return error.InvalidJinjaArguments;
            for (parameters.items) |previous| if (std.mem.eql(u8, previous.name, name)) return error.InvalidJinjaArguments;
            try parameters.append(allocator, .{ .name = name, .default = if (eq) |at| std.mem.trim(u8, part[at + 1 ..], " \t\r\n") else null });
        } else if (finish < declaration.len) return error.InvalidJinjaArguments;
        offset = finish + 1;
    }
    return try parameters.toOwnedSlice(allocator);
}

const MacroSpecials = struct { caller: bool = false, kwargs: bool = false, varargs: bool = false };

/// Jinja collects extras only for undeclared special names loaded by the body.
/// Literal text, quoted strings, comments and declared local names do not opt in.
fn macroSpecials(sql: []const u8, body: MacroBodyRange) !MacroSpecials {
    var result: MacroSpecials = .{};
    var declared: MacroSpecials = .{};
    var index = body.start;
    while (index < body.end) {
        const start = std.mem.indexOfScalarPos(u8, sql, index, '{') orelse break;
        if (start + 1 >= body.end) break;
        const kind = sql[start + 1];
        const marker: []const u8 = switch (kind) {
            '{' => "}}",
            '%' => "%}",
            '#' => "#}",
            else => {
                index = start + 1;
                continue;
            },
        };
        const close = (if (kind == '{') jinja.findExpressionClose(sql, start + 2) else std.mem.indexOfPos(u8, sql, start + 2, marker)) orelse return error.UnsupportedJinja;
        if (close >= body.end) break;
        index = close + 2;
        if (kind == '#') continue;
        const span = tagContent(sql, start, close);
        if (kind == '%' and std.mem.eql(u8, span, "raw")) {
            const raw = try findCaptureBlock(sql, close + 2, body.end, "raw", "endraw");
            index = raw.close;
            continue;
        }
        var target_end: usize = 0;
        var target_start: usize = 0;
        if (kind == '%' and std.mem.startsWith(u8, span, "set ")) {
            target_start = 4;
            target_end = std.mem.indexOfScalar(u8, span, '=') orelse span.len;
        } else if (kind == '%' and std.mem.startsWith(u8, span, "for ")) {
            target_start = 4;
            target_end = std.mem.indexOf(u8, span, " in ") orelse 0;
        }
        var offset: usize = 0;
        while (offset < span.len) {
            if (span[offset] == '\'' or span[offset] == '"') {
                offset = jinja.skipQuotedSpan(span, offset) orelse span.len;
                continue;
            }
            if (!jinja.isIdentStart(span[offset])) {
                offset += 1;
                continue;
            }
            const begin = offset;
            offset += 1;
            while (offset < span.len and jinja.isIdentChar(span[offset])) offset += 1;
            const name = span[begin..offset];
            const stored = begin >= target_start and begin < target_end;
            const remainder = std.mem.trimStart(u8, span[offset..], " \t\r\n");
            const named_argument = std.mem.startsWith(u8, remainder, "=") and !std.mem.startsWith(u8, remainder, "==");
            const prefix = std.mem.trimEnd(u8, span[0..begin], " \t\r\n");
            const attribute = prefix.len != 0 and prefix[prefix.len - 1] == '.';
            inline for (.{ "caller", "kwargs", "varargs" }) |special| {
                if (std.mem.eql(u8, name, special)) {
                    if (stored) @field(declared, special) = true else if (!attribute and !named_argument and !@field(declared, special)) @field(result, special) = true;
                }
            }
        }
    }
    return result;
}

fn bindMacroArguments(context: *CompileContext, parameters: []const MacroParameter, args: []const native_expr.Argument, specials: MacroSpecials) !void {
    const allocator = context.value_arena.allocator();
    const assigned = try allocator.alloc(bool, parameters.len);
    @memset(assigned, false);
    var catch_kwargs = specials.kwargs;
    var catch_varargs = specials.varargs;
    var explicit_caller = false;
    for (parameters) |parameter| {
        if (std.mem.eql(u8, parameter.name, "kwargs")) catch_kwargs = false;
        if (std.mem.eql(u8, parameter.name, "varargs")) catch_varargs = false;
        if (std.mem.eql(u8, parameter.name, "caller")) {
            explicit_caller = true;
            if (specials.caller and parameter.default == null) return error.InvalidJinjaArguments;
        }
    }
    var extra_positional: std.ArrayList(native_expr.Value) = .empty;
    var extra_keywords: std.ArrayList(native_expr.Entry) = .empty;
    var position: usize = 0;
    // Positional arguments are consumed before keyword arguments in Jinja.
    for (args) |arg| {
        if (arg.name != null) continue;
        if (position < parameters.len) {
            assigned[position] = true;
            try context.setValue(parameters[position].name, arg.value);
        } else if (catch_varargs) try extra_positional.append(allocator, arg.value) else return error.InvalidJinjaArguments;
        position += 1;
    }
    var caller: ?native_expr.Value = null;
    for (args, 0..) |arg, argument_index| {
        const keyword = arg.name orelse continue;
        for (args[0..argument_index]) |previous| if (previous.name != null and std.mem.eql(u8, previous.name.?, keyword)) return error.InvalidJinjaArguments;
        var parameter_index: ?usize = null;
        for (parameters, 0..) |parameter, i| if (std.mem.eql(u8, parameter.name, keyword)) {
            parameter_index = i;
            break;
        };
        if (parameter_index) |i| {
            if (!assigned[i]) {
                assigned[i] = true;
                try context.setValue(parameters[i].name, arg.value);
                continue;
            }
        } else if (specials.caller and !explicit_caller and std.mem.eql(u8, keyword, "caller")) {
            caller = arg.value;
            continue;
        }
        if (!catch_kwargs) return error.InvalidJinjaArguments;
        try extra_keywords.append(allocator, .{ .key = keyword, .value = arg.value });
    }
    for (parameters, assigned) |parameter, present| {
        if (!present) try context.setValue(parameter.name, if (parameter.default) |default| try context.evaluate(default) else try missingMacroArgument(context, parameter.name, false));
    }
    if (specials.caller and !explicit_caller) try context.setValue("caller", if (caller != null and caller.? != .none) caller.? else try missingMacroArgument(context, "caller", true));
    if (catch_kwargs) {
        const entries = try native_expr.allocateEntries(allocator, extra_keywords.items.len);
        @memcpy(entries, extra_keywords.items);
        try context.setValue("kwargs", .{ .object = entries });
    }
    if (catch_varargs) try context.setValue("varargs", .{ .tuple = try extra_positional.toOwnedSlice(allocator) });
}

fn missingMacroArgument(context: *CompileContext, name: []const u8, caller: bool) !native_expr.Value {
    const allocator = context.value_arena.allocator();
    const value = if (context.capturesUndefined()) try native_expr.captureUndefined(allocator, name) else try native_expr.undefinedValue(allocator, name);
    const payload = if (value == .capture_undefined) value.capture_undefined else value.ordinary_undefined;
    payload.hint = if (caller) "No caller defined" else try std.fmt.allocPrint(allocator, "parameter '{s}' was not provided", .{name});
    return value;
}

fn renderCallerValue(context: *CompileContext, caller: *const CallerBlock, args: []const native_expr.Argument) anyerror!native_expr.Value {
    if (context.macro_render_depth >= max_macro_render_depth) return error.JinjaExpressionDepthExceeded;
    const previous_bindings = context.bindings;
    const previous_vars = context.vars;
    const previous_lists = context.lists;
    const previous_scope = context.scope_depth;
    const previous_package = context.current_macro_package;
    const previous_return = context.returned;
    const previous_loop_depth = context.loop_depth;
    const previous_capture = context.capture_undefined_override;
    context.bindings = .empty;
    context.vars = .empty;
    context.lists = .empty;
    context.scope_depth = caller.scope_depth;
    context.current_macro_package = caller.macro_package;
    context.returned = null;
    context.loop_depth = 0;
    context.capture_undefined_override = caller.capture_undefined;
    context.macro_render_depth += 1;
    defer {
        context.bindings.deinit(context.allocator);
        context.vars.deinit(context.allocator);
        context.lists.deinit(context.allocator);
        context.bindings = previous_bindings;
        context.vars = previous_vars;
        context.lists = previous_lists;
        context.scope_depth = previous_scope;
        context.current_macro_package = previous_package;
        context.returned = context.returned orelse previous_return;
        context.loop_depth = previous_loop_depth;
        context.capture_undefined_override = previous_capture;
        context.macro_render_depth -= 1;
    }
    try context.bindings.appendSlice(context.allocator, caller.bindings);
    try context.vars.appendSlice(context.allocator, caller.vars);
    try context.lists.appendSlice(context.allocator, caller.lists);
    context.pushScope();
    defer context.popScope();
    try bindMacroArguments(context, caller.parameters, args, try macroSpecials(caller.sql, caller.body));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(context.allocator);
    try renderRange(context, caller.sql, caller.body.start, caller.body.end, &out);
    // Mutation helpers replace immutable container payloads in aliases. Keep
    // those changes visible in suspended frames and repeated caller closures.
    for (caller.bindings, context.bindings.items[0..caller.bindings.len]) |original, current| {
        const changed = switch (original.value) {
            .list => |items| current.value != .list or items.ptr != current.value.list.ptr or items.len != current.value.list.len,
            .object => |entries| current.value != .object or entries.ptr != current.value.object.ptr or entries.len != current.value.object.len,
            else => false,
        };
        if (!changed) continue;
        for (previous_bindings.items) |*binding| try @import("container_methods.zig").replaceAliases(&binding.value, original.value, current.value, 0);
        for (context.caller_blocks.items) |block| for (block.bindings) |*binding| try @import("container_methods.zig").replaceAliases(&binding.value, original.value, current.value, 0);
    }
    return context.returned orelse .{ .string = try context.value_arena.allocator().dupe(u8, out.items) };
}

fn renderMacroValue(context: *CompileContext, macro: *const MacroDef, args: []const native_expr.Argument) anyerror!native_expr.Value {
    const timing = try @import("timing_profile.zig").start(context.graph.timing_profile, .{ .filename = @src().file, .line = @src().line, .function = "renderMacroValue" });
    defer timing.finish();
    if (context.macro_render_depth >= max_macro_render_depth) return error.JinjaExpressionDepthExceeded;
    const allocator = context.value_arena.allocator();
    const open_start = std.mem.indexOf(u8, macro.macro_sql, "{%") orelse return error.UnsupportedJinja;
    const open_end = std.mem.indexOfPos(u8, macro.macro_sql, open_start + 2, "%}") orelse return error.UnsupportedJinja;
    const declaration = std.mem.trim(u8, macro.macro_sql[open_start + 2 .. open_end], " \t\r\n-");
    const materialization = std.mem.startsWith(u8, declaration, "materialization ");
    const paren = if (materialization) declaration.len else std.mem.indexOfScalar(u8, declaration, '(') orelse return error.UnsupportedJinja;
    const close = if (materialization) declaration.len else findMatchingParen(declaration, paren) orelse return error.UnsupportedJinja;
    const parameters = if (materialization) &.{} else try macroParameters(allocator, declaration[paren + 1 .. close]);
    const previous_package = context.current_macro_package;
    const previous_return = context.returned;
    const previous_loop_depth = context.loop_depth;
    const previous_capture = context.capture_undefined_override;
    context.loop_depth = 0;
    // dbt's separately cached macro template uses the ordinary environment,
    // including when invoked by a model's capture-mode parser.
    context.capture_undefined_override = false;
    const binding_start = context.bindings.items.len;
    context.returned = null;
    context.current_macro_package = macro.package_name;
    context.macro_render_depth += 1;
    context.pushScope();
    defer {
        context.bindings.shrinkRetainingCapacity(binding_start);
        context.popScope();
        context.macro_render_depth -= 1;
        context.current_macro_package = previous_package;
        context.returned = previous_return;
        context.loop_depth = previous_loop_depth;
        context.capture_undefined_override = previous_capture;
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(context.allocator);
    const body_end = if (materialization)
        findEndGenericTestTag(macro.macro_sql, open_end + 2, "endmaterialization") orelse return error.UnsupportedJinja
    else if (std.mem.startsWith(u8, declaration, "data_test "))
        findEndGenericTestTag(macro.macro_sql, open_end + 2, "enddata_test") orelse return error.UnsupportedJinja
    else if (std.mem.startsWith(u8, declaration, "test "))
        findEndGenericTestTag(macro.macro_sql, open_end + 2, "endtest") orelse return error.UnsupportedJinja
    else
        findEndMacroTag(macro.macro_sql, open_end + 2) orelse return error.UnsupportedJinja;
    try bindMacroArguments(context, parameters, args, try macroSpecials(macro.macro_sql, .{ .start = open_end + 2, .end = body_end }));
    try renderRange(context, macro.macro_sql, afterTag(macro.macro_sql, open_end + 2, body_end), body_end, &out);
    return context.returned orelse .{ .string = try allocator.dupe(u8, out.items) };
}

test "macro argument collection and lexical caller callbacks" {
    const cases = [_]struct { macro: []const u8, template: []const u8, expected: []const u8 }{
        .{ .macro = "{% macro probe() %}{{ return('}}' ~ kwargs.label) }}{% endmacro %}", .template = "{{ probe(label='bound') }}", .expected = "}}bound" },
        .{ .macro = "{% macro probe(value) %}{{ return('prefix:' ~ value) }}{% endmacro %}", .template = "{{ probe() }}", .expected = "prefix:" },
        .{ .macro = "{% macro probe(value) %}{{ return(value|string ~ ':' ~ varargs|join(',') ~ ':' ~ kwargs.label) }}{% endmacro %}", .template = "{{ probe(1,2,3,label='ok') }}", .expected = "1:2,3:ok" },
        .{ .macro = "{% macro probe(value) %}{{ return(value|string ~ ':' ~ kwargs.value|string) }}{% endmacro %}", .template = "{{ probe(1,value=2) }}", .expected = "1:2" },
        .{ .macro = "{% macro probe() %}{% if false %}{{ caller() }}{% endif %}ok{% endmacro %}", .template = "{% call probe() %}{{ missing() }}{% endcall %}", .expected = "ok" },
        .{ .macro = "{% macro probe() %}{{ caller(1) }}|{{ caller(value=2,prefix='other') }}{% endmacro %}", .template = "{% call(value,prefix='row') probe() %}{{ prefix }}:{{ value }}{% endcall %}", .expected = "row:1|other:2" },
        .{ .macro = "{% macro probe() %}{% set label='inner' %}{{ caller(1) }}{% endmacro %}", .template = "{% set label='outer' %}{% call(value) probe() %}{{ label }}:{{ value }}{% endcall %}", .expected = "outer:1" },
        .{ .macro = "{% macro probe(value) %}[{{ caller(value) }}]{% endmacro %}", .template = "{% call(a) probe(1) %}{{ a }}{% call(b) probe(2) %}{{ a }}:{{ b }}{% endcall %}{% endcall %}", .expected = "[1[1:2]]" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var graph = Graph{ .allocator = allocator, .project_name = "demo" };
        defer graph.deinit();
        try graph.macros.append(allocator, .{ .package_name = "demo", .unique_id = "macro.demo.probe", .name = "probe", .path = "macros/probe.sql", .original_file_path = "macros/probe.sql", .macro_sql = case.macro });
        const node = Node{ .package_name = "demo", .unique_id = "model.demo.rendered", .name = "rendered", .path = "rendered.sql", .original_file_path = "models/rendered.sql", .raw_code = case.template };
        const rendered = try compileModel(allocator, &graph, &node);
        try std.testing.expectEqualStrings(case.expected, rendered);
    }
}

test "literal and local special names do not collect macro extras" {
    const cases = [_]struct { macro: []const u8, template: []const u8 }{
        .{ .macro = "{% macro probe(mapping) %}{{ mapping . kwargs }}{% endmacro %}", .template = "{{ probe({'kwargs':'value'},extra=2) }}" },
        .{ .macro = "{% macro probe() %}{{ return('kwargs varargs') }}{% endmacro %}", .template = "{{ probe(1,label='extra') }}" },
        .{ .macro = "{% macro probe() %}{# {{ kwargs }} #}ok{% endmacro %}", .template = "{{ probe(label='extra') }}" },
        .{ .macro = "{% macro probe() %}{% set kwargs={'label':'local'} %}{{ kwargs.label }}{% endmacro %}", .template = "{{ probe(label='extra') }}" },
        .{ .macro = "{% macro probe(value) %}{{ value }}{% endmacro %}", .template = "{{ probe(1,value=2) }}" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var graph = Graph{ .allocator = allocator, .project_name = "demo" };
        defer graph.deinit();
        try graph.macros.append(allocator, .{ .package_name = "demo", .unique_id = "macro.demo.probe", .name = "probe", .path = "macros/probe.sql", .original_file_path = "macros/probe.sql", .macro_sql = case.macro });
        const node = Node{ .package_name = "demo", .unique_id = "model.demo.rendered", .name = "rendered", .path = "rendered.sql", .original_file_path = "models/rendered.sql", .raw_code = case.template };
        try std.testing.expectError(error.InvalidJinjaArguments, compileModel(allocator, &graph, &node));
    }
}

fn expressionBoundary(text: []const u8, start: usize, end: usize) usize {
    var index = start;
    var depth: usize = 0;
    while (index < end) : (index += 1) {
        if (text[index] == '\'' or text[index] == '"') {
            index = (jinja.skipQuotedSpan(text, index) orelse return end) - 1;
            continue;
        }
        switch (text[index]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                if (depth > 0) depth -= 1;
            },
            ',' => if (depth == 0) {
                return index;
            },
            else => {},
        }
    }
    return end;
}

fn renderLegacyExpression(context: *CompileContext, span: []const u8) ![]const u8 {
    const allocator = context.allocator;
    const graph = context.graph;
    const node = context.node;
    if (context.getVar(span)) |value| return try allocator.dupe(u8, value);
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
        if (resolve.findMacroIdByPackageAndName(graph, package_name, call.name)) |macro_id| {
            const macro = findMacroByUniqueId(graph, macro_id) orelse return error.UnresolvedMacro;
            return try renderMacroCall(context, macro, args);
        }
        return error.UnsupportedJinja;
    }
    if (std.mem.eql(u8, call.name, "config")) {
        return try allocator.dupe(u8, "");
    }
    if (std.mem.eql(u8, call.name, "is_incremental")) {
        if (std.mem.trim(u8, args, " \t\r\n").len != 0) return error.UnsupportedJinja;
        return try allocator.dupe(u8, if (node.runtime_is_incremental) "True" else "False");
    }
    if (std.mem.eql(u8, call.name, "return")) {
        const inner = std.mem.trim(u8, args, " \t\r\n");
        return try renderExpression(context, inner);
    }
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
        if (std.mem.eql(u8, target.resource_type, "model") and std.mem.eql(u8, target.materialized, "ephemeral")) {
            return try ephemeralCteName(allocator, target);
        }
        return try relationNameForRefNode(allocator, graph, target);
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

fn findScopedGraphVar(graph: *const Graph, package: []const u8, name: []const u8) ?*const types.VarEntry {
    var found: ?*const types.VarEntry = null;
    for (graph.vars.items) |*entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        if (entry.package_name) |scope| if (!std.mem.eql(u8, scope, package)) continue;
        if (found == null or entry.priority >= found.?.priority) found = entry;
    }
    return found;
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
    try context.recordMacroDependency(macro.unique_id);
    if (context.parse_node == null) {
        const full_name = try std.fmt.allocPrint(context.allocator, "{s}.{s}", .{ macro.package_name, macro.name });
        defer context.allocator.free(full_name);
        if (unitMacroOverride(context.graph, full_name)) |override| return try context.allocator.dupe(u8, try (try valueFromJson(context.value_arena.allocator(), override)).text(context.value_arena.allocator()));
    }
    return try renderMacroCall(context, macro, span[arg_open + 1 .. arg_close]);
}

fn renderMacroCall(context: *CompileContext, macro: *const MacroDef, raw_args: []const u8) ![]const u8 {
    const args = try native_expr.evaluateArguments(context.value_arena.allocator(), raw_args, context.host());
    const value = try renderMacroValue(context, macro, args);
    return try context.allocator.dupe(u8, try value.text(context.value_arena.allocator()));
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

fn findCustomGenericTestMacro(graph: *const Graph, test_node: *const GenericTestNode) ?*const MacroDef {
    for (test_node.macro_depends_on.items) |macro_id| {
        const macro = findMacroByUniqueId(graph, macro_id) orelse continue;
        if (std.mem.startsWith(u8, macro.name, "test_") and macro.macro_sql.len != 0) return macro;
    }
    return null;
}

fn parseGenericTestMacroBlock(allocator: std.mem.Allocator, macro: *const MacroDef) !ParsedMacroBlock {
    if (!std.mem.startsWith(u8, macro.name, "test_")) return error.UnsupportedCustomGenericTest;
    const expected_name = macro.name["test_".len..];

    const open_start = std.mem.indexOf(u8, macro.macro_sql, "{%") orelse return error.UnsupportedCustomGenericTest;
    const open_close = std.mem.indexOfPos(u8, macro.macro_sql, open_start + 2, "%}") orelse return error.UnsupportedCustomGenericTest;
    const open_span = std.mem.trim(u8, macro.macro_sql[open_start + 2 .. open_close], " \t\r\n-");

    var open = try parseGenericTestOpenSpan(allocator, open_span, expected_name);
    errdefer open.params.deinit(allocator);
    const body_start = open_close + 2;
    const body_end = findEndGenericTestTag(macro.macro_sql, body_start, open.end_tag) orelse return error.UnsupportedCustomGenericTest;
    return .{ .body = .{ .start = body_start, .end = body_end }, .params = open.params };
}

const ParsedGenericTestOpen = struct {
    end_tag: []const u8,
    params: std.ArrayList([]const u8),
};

fn parseGenericTestOpenSpan(allocator: std.mem.Allocator, span: []const u8, expected_name: []const u8) !ParsedGenericTestOpen {
    if (try parseGenericTestOpenSpanForKeyword(allocator, span, "test", expected_name)) |parsed| return parsed;
    if (try parseGenericTestOpenSpanForKeyword(allocator, span, "data_test", expected_name)) |parsed| return parsed;
    return error.UnsupportedCustomGenericTest;
}

fn parseGenericTestOpenSpanForKeyword(allocator: std.mem.Allocator, span: []const u8, keyword: []const u8, expected_name: []const u8) !?ParsedGenericTestOpen {
    if (!std.mem.startsWith(u8, span, keyword)) return null;
    var index: usize = keyword.len;
    if (index < span.len and jinja.isIdentChar(span[index])) return null;
    index = jinja.skipWs(span, index);

    const name_start = index;
    if (index >= span.len or !jinja.isIdentStart(span[index])) return error.UnsupportedCustomGenericTest;
    index += 1;
    while (index < span.len and jinja.isIdentChar(span[index])) index += 1;
    if (!std.mem.eql(u8, span[name_start..index], expected_name)) return error.UnsupportedCustomGenericTest;

    index = jinja.skipWs(span, index);
    if (index >= span.len or span[index] != '(') return error.UnsupportedCustomGenericTest;
    const close = findMatchingParen(span, index) orelse return error.UnsupportedCustomGenericTest;
    if (std.mem.trim(u8, span[close + 1 ..], " \t\r\n").len != 0) return error.UnsupportedCustomGenericTest;

    const params = parseGenericTestParameters(allocator, span[index + 1 .. close]) catch |err| switch (err) {
        error.UnsupportedJinja => return error.UnsupportedCustomGenericTest,
        else => return err,
    };
    const end_tag: []const u8 = if (std.mem.eql(u8, keyword, "data_test")) "enddata_test" else "endtest";
    return .{ .end_tag = end_tag, .params = params };
}

fn parseGenericTestParameters(allocator: std.mem.Allocator, args: []const u8) !std.ArrayList([]const u8) {
    var params: std.ArrayList([]const u8) = .empty;
    errdefer params.deinit(allocator);
    var index: usize = 0;
    while (true) {
        index = jinja.skipWs(args, index);
        if (index >= args.len) break;
        if (args[index] == ',') return error.UnsupportedJinja;
        const param_start = index;
        if (!jinja.isIdentStart(args[index])) return error.UnsupportedJinja;
        index += 1;
        while (index < args.len and jinja.isIdentChar(args[index])) index += 1;
        try params.append(allocator, args[param_start..index]);
        index = jinja.skipWs(args, index);
        if (index >= args.len) break;
        if (args[index] != ',') return error.UnsupportedJinja;
        index += 1;
    }
    return params;
}

fn findEndGenericTestTag(sql: []const u8, start: usize, expected_tag: []const u8) ?usize {
    var index = start;
    while (index + 1 < sql.len) {
        if (sql[index] != '{' or sql[index + 1] != '%') {
            index += 1;
            continue;
        }
        const close = std.mem.indexOfPos(u8, sql, index + 2, "%}") orelse return null;
        const span = std.mem.trim(u8, sql[index + 2 .. close], " \t\r\n-");
        if (std.mem.eql(u8, span, expected_tag)) return index;
        index = close + 2;
    }
    return null;
}

fn renderCustomGenericTestBody(allocator: std.mem.Allocator, sql: []const u8, start: usize, end_index: usize, model_sql: []const u8, column_name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index = start;
    while (index < end_index) {
        if (index + 1 >= end_index or sql[index] != '{') {
            try out.append(allocator, sql[index]);
            index += 1;
            continue;
        }

        const tag_kind = sql[index + 1];
        if (tag_kind == '#') {
            const close = std.mem.indexOfPos(u8, sql, index + 2, "#}") orelse return error.UnsupportedCustomGenericTest;
            if (close + 2 > end_index) return error.UnsupportedCustomGenericTest;
            index = close + 2;
            continue;
        }
        if (tag_kind == '%') return error.UnsupportedCustomGenericTest;
        if (tag_kind != '{') {
            try out.append(allocator, sql[index]);
            index += 1;
            continue;
        }

        const close = jinja.findExpressionClose(sql, index + 2) orelse return error.UnsupportedCustomGenericTest;
        if (close + 2 > end_index) return error.UnsupportedCustomGenericTest;
        const span = std.mem.trim(u8, sql[index + 2 .. close], " \t\r\n-");
        if (std.mem.eql(u8, span, "model")) {
            try out.appendSlice(allocator, model_sql);
        } else if (std.mem.eql(u8, span, "column_name")) {
            try out.appendSlice(allocator, column_name);
        } else {
            return error.UnsupportedCustomGenericTest;
        }
        index = close + 2;
    }

    return try out.toOwnedSlice(allocator);
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
    if (std.mem.eql(u8, attribute, "database")) return try allocator.dupe(u8, relationDatabaseForNode(graph, node) orelse "");
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

test "profileless target database remains None for native naming context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph = Graph{ .allocator = a, .project_name = "demo" };
    defer graph.deinit();
    const node = Node{ .package_name = "demo", .unique_id = "model.demo.value", .name = "value", .path = "value.sql", .original_file_path = "models/value.sql", .raw_code = "select '{{ target.database is none }}' as no_catalog" };
    const compiled = try compileModel(a, &graph, &node);
    defer a.free(compiled);
    try std.testing.expectEqualStrings("select 'True' as no_catalog", compiled);
}

fn renderStatement(context: *CompileContext, span: []const u8) !void {
    if (span.len == 0) return;
    if (std.mem.eql(u8, span, "break") or std.mem.eql(u8, span, "continue")) {
        if (context.loop_depth == 0) return error.UnsupportedJinja;
        if (std.mem.eql(u8, span, "break")) context.loop_break = true else context.loop_continue = true;
        return;
    }
    if (std.mem.startsWith(u8, span, "set ")) {
        const assignment = std.mem.trim(u8, span[4..], " \t\r\n");
        const equals = std.mem.indexOfScalar(u8, assignment, '=') orelse return error.UnsupportedJinja;
        const name = std.mem.trim(u8, assignment[0..equals], " \t\r\n");
        try assignValue(context, name, try context.evaluate(assignment[equals + 1 ..]));
        return;
    }
    const call = if (std.mem.startsWith(u8, span, "do ")) span[3..] else span;
    _ = try context.evaluate(call);
}

fn assignValue(context: *CompileContext, target: []const u8, value: native_expr.Value) anyerror!void {
    const trimmed = std.mem.trim(u8, target, " \t\r\n");
    if (trimmed.len >= 2 and trimmed[0] == '(' and findMatchingParen(trimmed, 0) == trimmed.len - 1) return try assignValue(context, trimmed[1 .. trimmed.len - 1], value);
    if (expressionBoundary(trimmed, 0, trimmed.len) < trimmed.len) {
        const items = try native_expr.iterableValuesWithHost(context.value_arena.allocator(), value, context.host());
        var i: usize = 0;
        var start: usize = 0;
        while (start < trimmed.len) : (i += 1) {
            const finish = expressionBoundary(trimmed, start, trimmed.len);
            if (i >= items.len) return error.InvalidJinjaArguments;
            try assignValue(context, std.mem.trim(u8, trimmed[start..finish], " \t\r\n"), items[i]);
            start = finish + 1;
        }
        if (i != items.len) return error.InvalidJinjaArguments;
        return;
    }
    if (std.mem.lastIndexOfScalar(u8, target, '.')) |dot| {
        const object = try context.evaluate(target[0..dot]);
        if (object != .object) return error.JinjaTypeError;
        for (@constCast(object.object)) |*entry| if (std.mem.eql(u8, entry.key, target[dot + 1 ..])) {
            entry.value = value;
            return;
        };
        return error.UndefinedJinjaValue;
    }
    if (target.len == 0 or !jinja.isIdentStart(target[0])) return error.UnsupportedJinja;
    for (target) |c| if (!jinja.isIdentChar(c)) return error.UnsupportedJinja;
    try context.setValue(target, value);
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

fn parseIfBlock(context: *CompileContext, sql: []const u8, body_start: usize, span: []const u8) !IfBlock {
    var index = body_start;
    var depth: usize = 1;
    var branch_start = body_start;
    var branch_active = try parseStaticIfCondition(context, span);
    var selected_body_start: ?usize = null;
    var selected_body_end: usize = 0;
    var seen_else = false;

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
        const tag_span = std.mem.trim(u8, sql[index + 2 .. close], " \t\r\n-");
        if (isIfStatement(tag_span)) {
            depth += 1;
        } else if (isEndIfStatement(tag_span)) {
            depth -= 1;
            if (depth == 0) {
                if (branch_active and selected_body_start == null) {
                    selected_body_start = branch_start;
                    selected_body_end = index;
                }
                return .{
                    .selected_body_start = selected_body_start,
                    .selected_body_end = selected_body_end,
                    .end_tag_close = close + 2,
                };
            }
        } else if (depth == 1 and isElifStatement(tag_span)) {
            if (seen_else) return error.UnsupportedJinja;
            if (branch_active and selected_body_start == null) {
                selected_body_start = branch_start;
                selected_body_end = index;
            }
            branch_start = afterTag(sql, close + 2, sql.len);
            branch_active = if (selected_body_start == null)
                try parseStaticIfCondition(context, tag_span)
            else
                false;
        } else if (depth == 1 and isElseStatement(tag_span)) {
            if (seen_else) return error.UnsupportedJinja;
            seen_else = true;
            if (branch_active and selected_body_start == null) {
                selected_body_start = branch_start;
                selected_body_end = index;
            }
            branch_start = afterTag(sql, close + 2, sql.len);
            branch_active = selected_body_start == null;
        }
        index = close + 2;
    }
    return error.UnsupportedJinja;
}

fn parseStaticIfCondition(context: *CompileContext, span: []const u8) !bool {
    const keyword_len: usize = if (isIfStatement(span)) 2 else if (isElifStatement(span)) 4 else return error.UnsupportedJinja;
    return (try context.evaluate(controlExpression(span[keyword_len..]))).truthy();
}

fn controlExpression(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return std.mem.trimEnd(u8, if (std.mem.endsWith(u8, trimmed, ":")) trimmed[0 .. trimmed.len - 1] else trimmed, " \t\r\n");
}

fn parseStaticBooleanCondition(context: *const CompileContext, condition: []const u8) ?bool {
    if (std.mem.startsWith(u8, condition, "not ")) {
        const operand = std.mem.trim(u8, condition["not".len..], " \t\r\n");
        const value = parseStaticBooleanCondition(context, operand) orelse return null;
        return !value;
    }
    if (std.ascii.eqlIgnoreCase(condition, "true")) return true;
    if (std.ascii.eqlIgnoreCase(condition, "false")) return false;
    if (std.mem.eql(u8, condition, "execute")) return true;
    if (std.mem.eql(u8, condition, "is_incremental()")) return context.node.runtime_is_incremental;
    return null;
}

fn parseStaticConditionValue(context: *CompileContext, expression: []const u8) !StaticConditionValue {
    if (parseStaticBooleanCondition(context, expression)) |value| return .{ .boolean = value };
    if (expression[0] == '"' or expression[0] == '\'') {
        const parsed = try jinja.parseQuoted(context.allocator, expression, 0);
        errdefer context.allocator.free(parsed.value);
        if (std.mem.trim(u8, expression[parsed.next..], " \t\r\n").len != 0) return error.UnsupportedJinja;
        return .{ .string = parsed.value };
    }
    if (context.getVar(expression)) |value| return .{ .string = try context.allocator.dupe(u8, value) };
    if (std.mem.startsWith(u8, expression, "target.")) {
        const attribute = std.mem.trim(u8, expression["target.".len..], " \t\r\n");
        if (attribute.len == 0) return error.UnsupportedJinja;
        return .{ .string = try renderTargetAttribute(context.allocator, context.graph, attribute) };
    }
    if (std.mem.startsWith(u8, expression, "this.")) {
        const attribute = std.mem.trim(u8, expression["this.".len..], " \t\r\n");
        if (attribute.len == 0) return error.UnsupportedJinja;
        return .{ .string = try renderThisAttribute(context.allocator, context.graph, context.node, attribute) };
    }
    return error.UnsupportedJinja;
}

fn deinitStaticConditionValue(allocator: std.mem.Allocator, value: StaticConditionValue) void {
    switch (value) {
        .boolean => {},
        .string => |owned| allocator.free(owned),
    }
}

fn findStaticComparison(condition: []const u8) ?StaticComparison {
    var index: usize = 0;
    var paren_depth: usize = 0;
    var found: ?StaticComparison = null;
    while (index < condition.len) : (index += 1) {
        if (condition[index] == '"' or condition[index] == '\'') {
            index = (jinja.skipQuotedSpan(condition, index) orelse return null) - 1;
            continue;
        }
        if (condition[index] == '(') {
            paren_depth += 1;
            continue;
        }
        if (condition[index] == ')') {
            if (paren_depth == 0) return null;
            paren_depth -= 1;
            continue;
        }
        if (paren_depth != 0 or index + 1 >= condition.len) continue;
        const operator: ?StaticComparisonOperator = if (std.mem.eql(u8, condition[index .. index + 2], "=="))
            .equal
        else if (std.mem.eql(u8, condition[index .. index + 2], "!="))
            .not_equal
        else
            null;
        if (operator) |op| {
            if (found != null) return null;
            found = .{ .operator = op, .operator_start = index };
            index += 1;
        }
    }
    return found;
}

fn parseForBlock(sql: []const u8, body_start: usize, span: []const u8) !ForBlock {
    var index: usize = "for".len;
    index = jinja.skipWs(span, index);
    const variable_start = index;
    var depth: usize = 0;
    while (index < span.len) : (index += 1) {
        if (depth == 0 and index > variable_start and std.ascii.isWhitespace(span[index - 1]) and std.mem.startsWith(u8, span[index..], "in") and (index + 2 == span.len or !jinja.isIdentChar(span[index + 2]))) break;
        const byte = span[index];
        if (byte == '(') depth += 1 else if (byte == ')') {
            if (depth == 0) return error.UnsupportedJinja;
            depth -= 1;
        } else if (!jinja.isIdentChar(byte) and byte != ',' and !std.ascii.isWhitespace(byte)) return error.UnsupportedJinja;
    }
    if (depth != 0) return error.UnsupportedJinja;
    const variable_name = std.mem.trim(u8, span[variable_start..index], " \t\r\n");
    if (variable_name.len == 0) return error.UnsupportedJinja;
    index = jinja.skipWs(span, index);
    if (index + "in".len > span.len or !std.mem.eql(u8, span[index .. index + "in".len], "in")) return error.UnsupportedJinja;
    const before_ok = index == 0 or !jinja.isIdentChar(span[index - 1]);
    const after = index + "in".len;
    const after_ok = after >= span.len or !jinja.isIdentChar(span[after]);
    if (!before_ok or !after_ok) return error.UnsupportedJinja;
    index = jinja.skipWs(span, after);
    const expression = controlExpression(span[index..]);
    const filter_at = topLevelIf(expression);
    const list_name = std.mem.trim(u8, expression[0 .. filter_at orelse expression.len], " \t\r\n");
    if (list_name.len == 0) return error.UnsupportedJinja;

    const endfor = findMatchingEndFor(sql, body_start) orelse return error.UnsupportedJinja;
    return .{
        .variable_name = variable_name,
        .list_name = list_name,
        .filter_expression = if (filter_at) |at| std.mem.trim(u8, expression[at + 2 ..], " \t\r\n") else null,
        .body_start = body_start,
        .body_end = endfor.else_start orelse endfor.start,
        .else_body_start = if (endfor.else_close) |close| afterTag(sql, close, endfor.start) else null,
        .else_body_end = endfor.start,
        .end_tag_close = endfor.close,
    };
}

const EndForTag = struct {
    start: usize,
    close: usize,
    else_start: ?usize = null,
    else_close: ?usize = null,
};

fn topLevelIf(text: []const u8) ?usize {
    var depth: usize = 0;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte == '\'' or byte == '"') {
            index = (jinja.skipQuotedSpan(text, index) orelse return null) - 1;
        } else if (byte == '(' or byte == '[' or byte == '{') depth += 1 else if (byte == ')' or byte == ']' or byte == '}') {
            if (depth > 0) depth -= 1;
        } else if (depth == 0 and index > 0 and std.ascii.isWhitespace(text[index - 1]) and std.mem.startsWith(u8, text[index..], "if") and (index + 2 == text.len or !jinja.isIdentChar(text[index + 2]))) return index;
    }
    return null;
}

fn findMatchingEndFor(sql: []const u8, start: usize) ?EndForTag {
    var index = start;
    var depth: usize = 1;
    var if_depth: usize = 0;
    var else_start: ?usize = null;
    var else_close: ?usize = null;
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
        if (isIfStatement(span)) {
            if_depth += 1;
        } else if (isEndIfStatement(span) and if_depth > 0) {
            if_depth -= 1;
        } else if (if_depth != 0) {
            // Ignore loop-like tags inside nested if bodies while finding the
            // current loop boundary.
        } else if (isForStatement(span)) {
            depth += 1;
        } else if (isEndForStatement(span)) {
            depth -= 1;
            if (depth == 0) return .{ .start = index, .close = close + 2, .else_start = else_start, .else_close = else_close };
        } else if (depth == 1 and isElseStatement(span)) {
            if (else_start != null) return null;
            else_start = index;
            else_close = close + 2;
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
        return try relationNameForRefNode(allocator, graph, attached_node);
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
    return try relationNameForRefNode(allocator, graph, parent_node);
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
    if (node.resolved_identity) |identity| return try allocator.dupe(u8, identity.schema);
    if (node.snapshot_config) |config| {
        if (config.target_schema) |schema| return try allocator.dupe(u8, schema);
    }
    if (node.config_schema) |custom_schema| {
        const trimmed = std.mem.trim(u8, custom_schema, " \t\r\n");
        return try std.fmt.allocPrint(allocator, "{s}_{s}", .{ graph.target_schema, trimmed });
    }
    return try allocator.dupe(u8, graph.target_schema);
}

pub fn relationDatabaseForNode(graph: *const Graph, node: *const Node) ?[]const u8 {
    if (node.resolved_identity) |identity| return identity.database;
    const values = @import("config_value.zig");
    if (node.snapshot_config) |config| if (config.target_database) |database| return database;
    if (values.get(node.effective_config, "database")) |database| if (database == .string) return database.string;
    if (values.get(graph.target_context, "database")) |database| if (database == .string) return database.string;
    if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return null;
    const path = graph.database_path orelse return if (node.snapshot_config != null) "memory" else null;
    if (std.mem.eql(u8, path, ":memory:")) return "memory";
    const basename = std.fs.path.basename(path);
    if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot| {
        if (dot != 0) return basename[0..dot];
    }
    return basename;
}

pub fn relationIdentifierForNode(node: *const Node) []const u8 {
    if (node.resolved_identity) |identity| return identity.identifier;
    if (node.config_alias) |custom_alias| {
        const trimmed = std.mem.trim(u8, custom_alias, " \t\r\n");
        if (trimmed.len != 0) return trimmed;
    }
    return node.default_alias orelse node.name;
}

pub fn relationNameForSource(allocator: std.mem.Allocator, source: *const SourceDef) ![]const u8 {
    return renderRelation(allocator, .{
        .database = sourceDatabaseName(source),
        .schema = sourceSchemaName(source),
        .identifier = sourceIdentifier(source),
        .quoting = .{
            .database = source.quoting.database orelse true,
            .schema = source.quoting.schema orelse true,
            .identifier = source.quoting.identifier orelse true,
        },
    });
}

pub fn sourceDatabaseName(source: *const SourceDef) ?[]const u8 {
    if (source.database) |database| {
        const trimmed = std.mem.trim(u8, database, " \t\r\n");
        if (trimmed.len != 0) return trimmed;
    }
    return null;
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
    const schema = try renderRelationComponent(allocator, relation.schema, relation.quoting.schema);
    defer allocator.free(schema);
    const identifier = try renderRelationComponent(allocator, relation.identifier, relation.quoting.identifier);
    defer allocator.free(identifier);
    if (relation.database) |database_name| {
        const database = try renderRelationComponent(allocator, database_name, relation.quoting.database);
        defer allocator.free(database);
        return try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ database, schema, identifier });
    }
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ schema, identifier });
}

fn renderRelationComponent(allocator: std.mem.Allocator, value: []const u8, should_quote: bool) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (should_quote) return try quoteIdentifier(allocator, trimmed);
    return try allocator.dupe(u8, trimmed);
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

    try graph.nodes.items[1].depends_on.append(allocator, "model.demo.customers");

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

    try graph.singular_tests.items[0].depends_on.append(allocator, "model.demo.customers");

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

test "compileGenericTest renders root project custom generic test body" {
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
        .raw_code = "select 1 as amount",
        .materialized = "table",
    });
    try graph.macros.append(allocator, .{
        .package_name = "demo",
        .unique_id = "macro.demo.test_positive_amount",
        .name = "test_positive_amount",
        .path = "custom_tests.sql",
        .original_file_path = "macros/custom_tests.sql",
        .macro_sql =
        \\{% test positive_amount(model, column_name) %}
        \\select {{ column_name }} /* {{ model.identifier }} */
        \\from {{ model }}
        \\where {{ column_name }} < 0
        \\{% endtest %}
        ,
    });
    try graph.macros.append(allocator, .{ .package_name = "demo", .unique_id = "macro.demo.get_where_subquery", .name = "get_where_subquery", .path = "where.sql", .original_file_path = "macros/where.sql", .macro_sql = "{% macro get_where_subquery(relation) %}{{ return(relation) }}{% endmacro %}" });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.positive_amount_orders_amount.abc",
        .name = "positive_amount_orders_amount",
        .alias = "positive_amount_orders_amount",
        .path = "positive_amount_orders_amount.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_positive_amount(**_dbt_generic_test_kwargs) }}",
        .test_name = "positive_amount",
        .config = .{ .limit = 3 },
        .column_name = "amount",
        .attached_node = "model.demo.orders",
    });
    try graph.tests.items[0].depends_on.append(allocator, "model.demo.orders");
    try graph.tests.items[0].macro_depends_on.append(allocator, "macro.demo.test_positive_amount");

    const compiled = try compileGenericTest(allocator, &graph, &graph.tests.items[0]);
    defer allocator.free(compiled);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "select amount") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "from \"main\".\"orders\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "where amount < 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "/* orders */") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "limit") == null);
}

test "compileGenericTest renders package custom generic test body" {
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
        .raw_code = "select 1 as amount",
        .materialized = "table",
    });
    try graph.macros.append(allocator, .{
        .package_name = "util_pkg",
        .unique_id = "macro.util_pkg.test_positive_amount",
        .name = "test_positive_amount",
        .path = "custom_tests.sql",
        .original_file_path = "macros/custom_tests.sql",
        .macro_sql =
        \\{% data_test positive_amount(model, column_name) %}
        \\select {{ column_name }}
        \\from {{ model }}
        \\where {{ column_name }} < 0
        \\{% enddata_test %}
        ,
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.util_pkg_positive_amount_orders_amount.abc",
        .name = "util_pkg_positive_amount_orders_amount",
        .alias = "util_pkg_positive_amount_orders_amount",
        .path = "util_pkg_positive_amount_orders_amount.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ util_pkg.test_positive_amount(**_dbt_generic_test_kwargs) }}",
        .test_name = "positive_amount",
        .test_namespace = "util_pkg",
        .column_name = "amount",
        .attached_node = "model.demo.orders",
    });
    try graph.tests.items[0].depends_on.append(allocator, "model.demo.orders");
    try graph.tests.items[0].macro_depends_on.append(allocator, "macro.util_pkg.test_positive_amount");
    try graph.tests.items[0].macro_depends_on.append(allocator, "macro.dbt.get_where_subquery");

    const compiled = try compileGenericTest(allocator, &graph, &graph.tests.items[0]);
    defer allocator.free(compiled);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "select amount") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "from \"main\".\"orders\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "where amount < 0") != null);
}

test "compileGenericTest renders source custom generic test body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.sources.append(allocator, .{
        .package_name = "demo",
        .unique_id = "source.demo.raw.orders_src",
        .source_name = "raw",
        .table_name = "orders_src",
        .original_file_path = "models/schema.yml",
    });
    try graph.macros.append(allocator, .{
        .package_name = "demo",
        .unique_id = "macro.demo.test_positive_amount",
        .name = "test_positive_amount",
        .path = "custom_tests.sql",
        .original_file_path = "macros/custom_tests.sql",
        .macro_sql =
        \\{% test positive_amount(model, column_name) %}
        \\select {{ column_name }}
        \\from {{ model }}
        \\where {{ column_name }} < 0
        \\{% endtest %}
        ,
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.source_positive_amount_raw_orders_src_amount.abc",
        .name = "source_positive_amount_raw_orders_src_amount",
        .alias = "source_positive_amount_raw_orders_src_amount",
        .path = "source_positive_amount_raw_orders_src_amount.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_positive_amount(**_dbt_generic_test_kwargs) }}",
        .test_name = "positive_amount",
        .column_name = "amount",
        .attached_source = .{ .source_name = "raw", .table_name = "orders_src" },
        .attached_source_unique_id = "source.demo.raw.orders_src",
    });
    try graph.tests.items[0].depends_on.append(allocator, "source.demo.raw.orders_src");
    try graph.tests.items[0].macro_depends_on.append(allocator, "macro.demo.test_positive_amount");

    const compiled = try compileGenericTest(allocator, &graph, &graph.tests.items[0]);
    defer allocator.free(compiled);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "select amount") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "from \"raw\".\"orders_src\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "where amount < 0") != null);
}

test "compileGenericTest renders seed custom generic test body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.nodes.append(allocator, .{
        .resource_type = "seed",
        .package_name = "demo",
        .unique_id = "seed.demo.orders_seed",
        .name = "orders_seed",
        .path = "orders_seed.csv",
        .original_file_path = "seeds/orders_seed.csv",
        .raw_code = "",
    });
    try graph.macros.append(allocator, .{
        .package_name = "util_pkg",
        .unique_id = "macro.util_pkg.test_nonzero_amount",
        .name = "test_nonzero_amount",
        .path = "custom_tests.sql",
        .original_file_path = "macros/custom_tests.sql",
        .macro_sql =
        \\{% data_test nonzero_amount(model, column_name) %}
        \\select {{ column_name }}
        \\from {{ model }}
        \\where {{ column_name }} = 0
        \\{% enddata_test %}
        ,
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.util_pkg_nonzero_amount_orders_seed_amount.abc",
        .name = "util_pkg_nonzero_amount_orders_seed_amount",
        .alias = "util_pkg_nonzero_amount_orders_seed_amount",
        .path = "util_pkg_nonzero_amount_orders_seed_amount.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ util_pkg.test_nonzero_amount(**_dbt_generic_test_kwargs) }}",
        .test_name = "nonzero_amount",
        .test_namespace = "util_pkg",
        .column_name = "amount",
        .attached_node = "seed.demo.orders_seed",
    });
    try graph.tests.items[0].depends_on.append(allocator, "seed.demo.orders_seed");
    try graph.tests.items[0].macro_depends_on.append(allocator, "macro.util_pkg.test_nonzero_amount");
    try graph.tests.items[0].macro_depends_on.append(allocator, "macro.dbt.get_where_subquery");

    const compiled = try compileGenericTest(allocator, &graph, &graph.tests.items[0]);
    defer allocator.free(compiled);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "select amount") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "from \"main\".\"orders_seed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, compiled, "where amount = 0") != null);
}

test "compileGenericTest renders custom generic test control flow" {
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
        .raw_code = "select 1 as amount",
        .materialized = "table",
    });
    try graph.macros.append(allocator, .{
        .package_name = "demo",
        .unique_id = "macro.demo.test_positive_amount",
        .name = "test_positive_amount",
        .path = "custom_tests.sql",
        .original_file_path = "macros/custom_tests.sql",
        .macro_sql =
        \\{% data_test positive_amount(model, column_name, minimum=0) %}
        \\{% if minimum >= 2 %}
        \\select {{ column_name }} from {{ model }} where {{ column_name }} <= {{ minimum }}
        \\{% endif %}
        \\{% enddata_test %}
        ,
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.positive_amount_orders_amount.abc",
        .name = "positive_amount_orders_amount",
        .alias = "positive_amount_orders_amount",
        .path = "positive_amount_orders_amount.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_positive_amount(**_dbt_generic_test_kwargs) }}",
        .test_name = "positive_amount",
        .arguments = try std.json.parseFromSliceLeaky(std.json.Value, allocator, "{\"minimum\":2}", .{}),
        .column_name = "amount",
        .attached_node = "model.demo.orders",
    });
    try graph.tests.items[0].depends_on.append(allocator, "model.demo.orders");
    try graph.tests.items[0].macro_depends_on.append(allocator, "macro.demo.test_positive_amount");

    const compiled = try compileGenericTest(allocator, &graph, &graph.tests.items[0]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("\n\nselect amount from \"main\".\"orders\" where amount <= 2\n\n", compiled);
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

    try graph.nodes.items[1].depends_on.append(allocator, "model.demo.customers");

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

    try graph.nodes.items[0].depends_on.append(allocator, "model.demo.payments");

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

    try graph.nodes.items[2].depends_on.appendSlice(allocator, &.{ "model.demo.customers", "model.demo.orders" });

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

    try graph.nodes.items[2].depends_on.appendSlice(allocator, &.{ "model.pkg.pkg_customers", "model.pkg.pkg_orders" });

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

test "compileModel renders conditional statements inside macros" {
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

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[0]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("select subtotal as subtotal", compiled);
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

test "compileModel iterates ordinary Undefined as an empty list" {
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

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[0]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("", compiled);
}

test "compileModel accepts scalar set values" {
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

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[0]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("select 1", compiled);
}

test "compileModel permits an unused undefined list value" {
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

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[0]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("select 1", compiled);
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

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[0]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("", compiled);
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

test "compileModel renders for else when the iterator is empty" {
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

    try std.testing.expectEqualStrings("empty", try compileModel(allocator, &graph, &graph.nodes.items[0]));
}

test "compileModel consumes generators incrementally with deferred loop metadata" {
    const cases = [_]struct { template: []const u8, expected: []const u8 }{
        .{ .template = "{% set stream=zip([1,2,3],[4,5,6]) %}{% for x in stream %}{{ x }}{% break %}{% endfor %}|{{ stream|list }}", .expected = "(1, 4)|[(2, 5), (3, 6)]" },
        .{ .template = "{% set stream=zip([1,2,3],[4,5,6]) %}{% for x in stream %}{{ loop.last }}{% break %}{% endfor %}|{{ stream|list }}", .expected = "False|[(3, 6)]" },
        .{ .template = "{% set stream=zip([1,2],[3,4]) %}{% for x in stream %}{{ loop.index }}/{{ loop.length }}:{{ loop.last }};{% endfor %}|{{ stream|list }}", .expected = "1/2:False;2/2:True;|[]" },
        .{ .template = "{% set cutoff=3 %}{% for x in [1,2,3] if x<cutoff %}{% set cutoff=0 %}{{ x }}:{{ loop.last }};{% endfor %}", .expected = "1:False;2:True;" },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var graph = Graph{ .allocator = allocator, .project_name = "demo" };
        defer graph.deinit();
        const node = Node{ .unique_id = "model.demo.loop", .package_name = "demo", .name = "loop", .path = "loop.sql", .original_file_path = "models/loop.sql", .raw_code = case.template };
        try std.testing.expectEqualStrings(case.expected, try compileModel(allocator, &graph, &node));
    }
}

test "compileModel renders static if branches for render-only context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{
        .allocator = allocator,
        .project_name = "demo",
        .target_schema = "analytics",
        .target_name = "dev",
    };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select {% if false %}0{% else %}1{% endif %} as value, {% if execute %}'compile'{% else %}'parse'{% endif %} as mode, {% if not execute %}0{% else %}1{% endif %} as executes, {% if is_incremental() %}1{% else %}0{% endif %} as incremental, {% if false %}'wrong'{% elif target.name == 'dev' %}'dev'{% else %}'other'{% endif %} as target_name, {% if this.schema != 'analytics' %}'wrong'{% elif this.name == \"orders\" %}'orders'{% endif %} as this_name",
    });

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[0]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("select 1 as value, 'compile' as mode, 1 as executes, 0 as incremental, 'dev' as target_name, 'orders' as this_name", compiled);
}

test "compileModel renders static if comparisons against loop variables" {
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
        .raw_code = "{% set methods = ['card', 'cash'] %}{% for method in methods %}{% if method == 'card' %}card{% elif method != 'cash' %}bad{% else %}cash{% endif %}:{% endfor %}",
    });

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[0]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("card:cash:", compiled);
}

test "compileModel rejects unsupported reached if conditions" {
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
        .raw_code = "{% if false %}select 1{% elif var('enabled') %}select 2{% endif %}",
    });

    try std.testing.expectError(error.UnresolvedVar, compileModel(allocator, &graph, &graph.nodes.items[0]));
    try std.testing.expectError(error.UnresolvedVar, compileModel(allocator, &graph, &graph.nodes.items[1]));
}

test "compileModel skips expressions inside empty loops" {
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

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[0]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("select 1", compiled);
}

test "compileModel accepts escaped string list values" {
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

    const compiled = try compileModel(allocator, &graph, &graph.nodes.items[0]);
    defer allocator.free(compiled);
    try std.testing.expectEqualStrings("select 1", compiled);
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

test "compileModelWithInjectedCtes orders chained ephemeral parents before downstream SQL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.base",
        .name = "base",
        .path = "base.sql",
        .original_file_path = "models/base.sql",
        .raw_code = "select 1 as id;",
        .materialized = "ephemeral",
    });
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.mid",
        .name = "mid",
        .path = "mid.sql",
        .original_file_path = "models/mid.sql",
        .raw_code = "select id + 1 as id from {{ ref('base') }}",
        .materialized = "ephemeral",
    });
    try graph.nodes.items[1].depends_on.append(allocator, "model.demo.base");
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.final",
        .name = "final",
        .path = "final.sql",
        .original_file_path = "models/final.sql",
        .raw_code = "select * from {{ ref('mid') }}",
        .materialized = "table",
    });
    try graph.nodes.items[2].depends_on.append(allocator, "model.demo.mid");

    var compiled = try compileModelWithInjectedCtes(allocator, &graph, &graph.nodes.items[2]);
    defer compiled.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), compiled.extra_ctes.items.len);
    try std.testing.expectEqualStrings("model.demo.base", compiled.extra_ctes.items[0].id);
    try std.testing.expectEqualStrings("model.demo.mid", compiled.extra_ctes.items[1].id);
    try std.testing.expectEqualStrings(" __dbt__cte__base as (\nselect 1 as id;\n)", compiled.extra_ctes.items[0].sql);
    try std.testing.expectEqualStrings(" __dbt__cte__mid as (\nselect id + 1 as id from __dbt__cte__base\n)", compiled.extra_ctes.items[1].sql);
    try std.testing.expectEqualStrings(
        "with __dbt__cte__base as (\nselect 1 as id;\n),  __dbt__cte__mid as (\nselect id + 1 as id from __dbt__cte__base\n) select * from __dbt__cte__mid",
        compiled.compiled_code,
    );
}

test "compileModelWithInjectedCtes rejects ephemeral dependency cycles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.base",
        .name = "base",
        .path = "base.sql",
        .original_file_path = "models/base.sql",
        .raw_code = "select * from {{ ref('mid') }}",
        .materialized = "ephemeral",
    });
    try graph.nodes.items[0].depends_on.append(allocator, "model.demo.mid");
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.mid",
        .name = "mid",
        .path = "mid.sql",
        .original_file_path = "models/mid.sql",
        .raw_code = "select * from {{ ref('base') }}",
        .materialized = "ephemeral",
    });
    try graph.nodes.items[1].depends_on.append(allocator, "model.demo.base");
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.final",
        .name = "final",
        .path = "final.sql",
        .original_file_path = "models/final.sql",
        .raw_code = "select * from {{ ref('mid') }}",
        .materialized = "table",
    });
    try graph.nodes.items[2].depends_on.append(allocator, "model.demo.mid");

    try std.testing.expectError(error.CyclicModelDependency, compileModelWithInjectedCtes(allocator, &graph, &graph.nodes.items[2]));
}

test "relationNameForSource renders database and source quote policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = SourceDef{
        .package_name = "demo",
        .unique_id = "source.demo.raw.customers",
        .source_name = "raw",
        .table_name = "customers",
        .database = "raw_db",
        .schema_name = "RawSchema",
        .identifier = "RawCustomers",
        .quoting = .{
            .database = false,
            .schema = true,
            .identifier = false,
        },
        .original_file_path = "models/schema.yml",
    };

    const relation_name = try relationNameForSource(allocator, &source);
    try std.testing.expectEqualStrings("raw_db.\"RawSchema\".RawCustomers", relation_name);
}

test "compileModel uses warehouse supplied incremental context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.events",
        .name = "events",
        .path = "events.sql",
        .original_file_path = "models/events.sql",
        .materialized = "incremental",
        .raw_code = "select {% if is_incremental() %}1{% else %}0{% endif %} as incremental, {% if not is_incremental() %}1{% else %}0{% endif %} as initial, {{ is_incremental() }} as active",
    };
    const first = try compileModel(allocator, &graph, &node);
    try std.testing.expectEqualStrings("select 0 as incremental, 1 as initial, False as active", first);
    node.runtime_is_incremental = true;
    const repeated = try compileModel(allocator, &graph, &node);
    try std.testing.expectEqualStrings("select 1 as incremental, 0 as initial, True as active", repeated);
}

test "renderOperation binds typed keyword arguments and macro defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.macros.append(allocator, .{
        .package_name = "demo",
        .unique_id = "macro.demo.sum_values",
        .name = "sum_values",
        .path = "sum.sql",
        .original_file_path = "macros/sum.sql",
        .macro_sql = "{% macro sum_values(a, b=3) %}{{ return(a + b) }}discarded{% endmacro %}",
    });
    const kwargs = try std.json.parseFromSlice(std.json.Value, allocator, "{\"a\":2}", .{});
    defer kwargs.deinit();
    const output = try renderOperation(.{ .allocator = allocator, .io = std.testing.io }, &graph, "sum_values", kwargs.value);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("5", output);
}

test "static extraction fallback applies literal and macro hooks once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.macros.append(allocator, .{
        .unique_id = "macro.demo.configure",
        .package_name = "demo",
        .name = "configure",
        .path = "configure.sql",
        .original_file_path = "macros/configure.sql",
        .macro_sql = "{% macro configure() %}{{ config(post_hook=['select 2']) }}{% endmacro %}",
    });
    var node = Node{ .package_name = "demo", .unique_id = "model.demo.orders", .name = "orders", .path = "orders.sql", .original_file_path = "models/orders.sql", .raw_code = "" };
    defer types.deinitNode(allocator, &node);
    try scanDependencies(allocator, "{{ config(pre_hook=['select 1'], tags=['inline']) }} {{ configure() }} select 1", &node, &graph);
    const values = @import("config_value.zig");
    try std.testing.expectEqual(@as(usize, 1), values.get(node.inline_config, "pre-hook").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), values.get(node.inline_config, "post-hook").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 1), node.tags.items.len);
}

test "disabled static parser renders the same literal configs without scanner calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var profile = @import("timing_profile.zig").Registry.init(a, std.testing.io);
    defer profile.deinit();
    var graph: Graph = .{ .allocator = a, .project_name = "demo", .timing_profile = &profile };
    defer graph.deinit();
    var first: Node = .{ .package_name = "demo", .unique_id = "model.demo.first", .name = "first", .path = "first.sql", .original_file_path = "models/first.sql", .raw_code = "" };
    defer types.deinitNode(a, &first);
    const sql = "{{ config(tags=['daily'], materialized='table') }}select * from {{ ref('upstream') }}";
    try scanDependencies(a, sql, &first, &graph);
    try std.testing.expectEqual(@as(usize, 1), profile.entries.items.len);
    try std.testing.expectEqualStrings("scanSqlStatic", profile.entries.items[0].key.function);
    try std.testing.expectEqual(@as(u32, 1), profile.entries.items[0].counts.total);
    graph.command_options.static_parser = false;
    var second: Node = .{ .package_name = "demo", .unique_id = "model.demo.second", .name = "second", .path = "second.sql", .original_file_path = "models/second.sql", .raw_code = "" };
    defer types.deinitNode(a, &second);
    try scanDependencies(a, sql, &second, &graph);
    try std.testing.expectEqual(@as(u32, 1), profile.entries.items[0].counts.total);
    try std.testing.expectEqualStrings(first.materialized, second.materialized);
    try std.testing.expectEqualStrings(first.tags.items[0], second.tags.items[0]);
    try std.testing.expectEqualStrings(first.refs.items[0].name, second.refs.items[0].name);
}

test "source expressions render source this identity and package variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    try graph.vars.append(allocator, .{ .name = "minimum", .value = "2", .typed_value = .{ .integer = 2 } });
    const source = SourceDef{ .package_name = "demo", .unique_id = "source.demo.raw.events", .source_name = "raw", .table_name = "events", .original_file_path = "sources.yml", .database = "warehouse", .schema_name = "landing", .identifier = "event_rows", .quoting = .{ .identifier = false } };
    const result = try renderSourceExpression(allocator, &graph, &source, "select max(loaded_at) from {{ this }} where id > {{ var('minimum') }} and '{{ this.schema }}' = 'landing'");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("select max(loaded_at) from \"warehouse\".\"landing\".event_rows where id > 2 and 'landing' = 'landing'", result);
}

test "nested compiler frames restore the database host current resource" {
    const TestHost = struct {
        node: ?*const Node = null,
        graph: *const Graph,
        child: *const Node,
        fn setNode(raw: *anyopaque, pointer: ?*const anyopaque) ?*const anyopaque {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const previous = self.node;
            self.node = if (pointer) |node| @ptrCast(@alignCast(node)) else null;
            return previous;
        }
        fn resolveValue(_: *anyopaque, _: []const u8, _: std.mem.Allocator) anyerror!native_expr.Value {
            return .undefined;
        }
        fn call(raw: *anyopaque, name: []const u8, _: []const native_expr.Argument, allocator: std.mem.Allocator) anyerror!native_expr.Value {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (std.mem.eql(u8, name, "current_resource")) return .{ .string = self.node.?.name };
            if (std.mem.eql(u8, name, "nested_resource")) return .{ .string = try compileModel(allocator, self.graph, self.child) };
            return error.UnresolvedMacro;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    const child = Node{ .package_name = "demo", .unique_id = "model.demo.child", .name = "child", .path = "child.sql", .original_file_path = "models/child.sql", .raw_code = "{{ current_resource() }}" };
    const parent = Node{ .package_name = "demo", .unique_id = "model.demo.parent", .name = "parent", .path = "parent.sql", .original_file_path = "models/parent.sql", .raw_code = "{{ current_resource() }} {{ nested_resource() }} {{ current_resource() }}" };
    var host_state = TestHost{ .graph = &graph, .child = &child };
    graph.execution_hooks = .{ .context = &host_state, .resolve = TestHost.resolveValue, .call = TestHost.call, .set_node = TestHost.setNode };
    try std.testing.expectEqualStrings("parent child parent", try compileModel(allocator, &graph, &parent));
    try std.testing.expect(host_state.node == null);
}

test "compiler exposes configured nullable equality through flags and adapter behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    const node = Node{ .package_name = "demo", .unique_id = "model.demo.flags", .name = "flags", .path = "flags.sql", .original_file_path = "models/flags.sql", .raw_code = "{{ flags.ENABLE_TRUTHY_NULLS_EQUALS_MACRO }}:{{ adapter.behavior.enable_truthy_nulls_equals_macro.no_warn }}" };
    const ordinary = try compileModel(allocator, &graph, &node);
    try std.testing.expectEqualStrings("False:False", ordinary);
    graph.enable_truthy_nulls_equals_macro = true;
    const truthy = try compileModel(allocator, &graph, &node);
    try std.testing.expectEqualStrings("True:True", truthy);
}

test "typed generic parse rendering captures macro configs and dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.macros.append(allocator, .{ .unique_id = "macro.demo.test_positive", .package_name = "demo", .name = "test_positive", .path = "positive.sql", .original_file_path = "macros/positive.sql", .macro_sql = "{% test positive(model, threshold=2) %}{{ config(tags=['macro']) }}select * from {{ model }} where id < {{ threshold }} and id in (select id from {{ ref('parent') }}){% endtest %}" });
    var probe = Node{ .resource_type = "test", .package_name = "demo", .unique_id = "test.demo.positive", .name = "positive", .path = "positive.sql", .original_file_path = "schema.yml", .raw_code = "" };
    defer types.deinitNode(allocator, &probe);
    try scanMacroDependencies(allocator, &graph, &probe, "test_positive", &.{.{ .name = "model", .value = .{ .string = "fixture" } }});
    try std.testing.expectEqual(@as(usize, 1), probe.refs.items.len);
    try std.testing.expectEqualStrings("parent", probe.refs.items[0].name);
    try std.testing.expectEqualStrings("macro", @import("config_value.zig").get(probe.inline_config, "tags").?.array.items[0].string);
    try std.testing.expectEqualStrings("macro.demo.test_positive", probe.macro_depends_on.items[0]);
}

test "compiler calls aliases of typed regex class objects" {
    const allocator = std.testing.allocator;
    var graph = Graph{ .allocator = allocator, .project_name = "fixture" };
    defer graph.deinit();
    const node = Node{ .unique_id = "model.fixture.alias", .package_name = "fixture", .name = "alias", .path = "alias.sql", .original_file_path = "models/alias.sql", .raw_code = "{% set flag = modules.re.RegexFlag %}{% set err = modules.re.error %}select '{{ flag(10) }}|{{ err('bad') }}'" };
    const sql = try compileModel(allocator, &graph, &node);
    defer allocator.free(sql);
    try std.testing.expectEqualStrings("select 're.IGNORECASE|re.MULTILINE|bad'", sql);
}

test "compiler retains typed keys returned by a macro and iterated by a model" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "fixture" };
    defer graph.deinit();
    try @import("parse.zig").parseMacrosFromText(allocator, "{% macro typed_keys() %}{{ return({(1,2): 'tuple', 7: 'integer'}) }}{% endmacro %}", "keys.sql", "fixture", &graph);
    const node = Node{ .unique_id = "model.fixture.keys", .package_name = "fixture", .name = "keys", .path = "keys.sql", .original_file_path = "models/keys.sql", .raw_code = "{% set keys = typed_keys() %}{% for key in keys %}{{ key }}={{ keys[key] }};{% endfor %}" };
    try std.testing.expectEqualStrings("(1, 2)=tuple;7=integer;", try compileModel(allocator, &graph, &node));
}

test "compiler rejects positional config dictionaries with nonstring keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "fixture" };
    defer graph.deinit();
    try @import("parse.zig").parseMacrosFromText(allocator, "{% macro invalid_config() %}{{ config({1: 'table'}) }}{% endmacro %}", "invalid.sql", "fixture", &graph);
    var node = Node{ .unique_id = "model.fixture.keys", .package_name = "fixture", .name = "keys", .path = "keys.sql", .original_file_path = "models/keys.sql", .raw_code = "" };
    try std.testing.expectError(error.InvalidJinjaArguments, scanMacroDependencies(allocator, &graph, &node, "invalid_config", &.{}));
    try std.testing.expectError(error.InvalidJinjaArguments, scanDependencies(allocator, "{{ config ( {1: 'table'}) }}select 1", &node, &graph));
}

test "compiler parse context captures unknown calls and bound Undefined attributes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "fixture" };
    defer graph.deinit();
    var node = Node{ .unique_id = "model.fixture.capture", .package_name = "fixture", .name = "capture", .path = "capture.sql", .original_file_path = "models/capture.sql", .raw_code = "" };
    try scanDependencies(allocator, "{% set captured = missing %}{{ config(tags=[captured().next.name]) }}select 1", &node, &graph);
    try std.testing.expectEqualStrings("next", @import("config_value.zig").get(node.inline_config, "tags").?.array.items[0].string);
    node.raw_code = "{{ missing }}select 1";
    try std.testing.expectEqualStrings("select 1", try compileModel(allocator, &graph, &node));
    node.raw_code = "{% set captured = missing %}{{ captured.deep }}";
    try std.testing.expectError(error.UndefinedJinjaValue, compileModel(allocator, &graph, &node));
}

test "parse evaluates non-dependency output expressions and keeps literal calls static" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "missing + 1", "1 + missing", "+missing", "-missing", "missing < 1", "missing | int", "missing | float", "none | list" }) |body| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const allocator = arena.allocator();
        const sql = try std.fmt.allocPrint(allocator, "select {{{{ {s} }}}} as id", .{body});
        var node = Node{ .package_name = "demo", .unique_id = "model.demo.probe", .name = "probe", .path = "models/probe.sql", .original_file_path = "models/probe.sql", .raw_code = sql };
        defer types.deinitNode(allocator, &node);
        var graph = Graph{ .allocator = allocator, .project_name = "demo" };
        defer graph.deinit();
        const result = scanDependencies(allocator, sql, &node, &graph);
        if (result) |_| return error.TestExpectedError else |_| {}
    }
    try std.testing.expect(!requiresNativeRendering("{{ config(materialized='table') }} select * from {{ ref('base') }} join {{ source('raw','events') }} using(id)"));
    try std.testing.expect(requiresNativeRendering("select {{ ref('base') ~ missing + 1 }}"));
}

test "compiler delegates typed datetime constructors and preserves regex module aggregate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph = Graph{ .allocator = a, .project_name = "fixture" };
    defer graph.deinit();
    const node = Node{ .unique_id = "model.fixture.clock", .package_name = "fixture", .name = "clock", .path = "clock.sql", .original_file_path = "models/clock.sql", .raw_code = "{% set calendar = modules.datetime.datetime %}{{ calendar(2024,1,2,3,4,5).strftime('%Y-%m-%d %H:%M:%S') }}|{{ modules.re.sub('a','b','a') }}" };
    try std.testing.expectEqualStrings("2024-01-02 03:04:05|b", try compileModel(a, &graph, &node));
}
