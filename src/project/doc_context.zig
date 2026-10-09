//! Core DocsRuntimeContext and Manifest._process_docs_for_*: render only after
//! all packages are discovered, preserving literal AST doc-call metadata.
const std = @import("std");
const types = @import("types.zig");
const expression = @import("expression.zig");
const jinja = @import("jinja.zig");
const values = @import("config_value.zig");

pub fn baseCallable(name: []const u8) bool {
    inline for (.{ "doc", "var", "env_var", "return", "fromjson", "tojson", "fromyaml", "toyaml", "set", "set_strict", "zip", "zip_strict", "log", "print", "diff_of_two_dicts", "local_md5" }) |function| {
        if (equal(name, function)) return true;
    }
    return false;
}

pub fn allowsCall(name: []const u8) bool {
    return baseCallable(name) or std.mem.startsWith(u8, name, "modules.") or std.mem.startsWith(u8, name, "__dxt_value.") or std.mem.startsWith(u8, name, "__dxt_regex_") or std.mem.startsWith(u8, name, "__dxt_datetime:");
}

pub fn lookup(graph: *const types.Graph, node_package: []const u8, package: ?[]const u8, name: []const u8) ?*const types.DocBlock {
    if (package) |explicit| return find(graph, explicit, name);
    if (find(graph, graph.project_name, name)) |doc| return doc;
    if (!equal(graph.project_name, node_package)) if (find(graph, node_package, name)) |doc| return doc;
    return find(graph, null, name);
}

fn find(graph: *const types.Graph, package: ?[]const u8, name: []const u8) ?*const types.DocBlock {
    for (graph.docs.items) |*doc| {
        if (!equal(doc.name, name)) continue;
        if (package) |scope| if (!equal(scope, doc.package_name)) continue;
        return doc;
    }
    return null;
}

pub fn call(allocator: std.mem.Allocator, graph: *const types.Graph, node_package: []const u8, name: []const u8, args: []const expression.Argument) !?expression.Value {
    if (!equal(name, "doc")) return null;
    if (args.len < 1 or args.len > 2) return error.InvalidDocArguments;
    for (args) |arg| if (arg.name != null or arg.value != .string) return error.InvalidDocArguments;
    const package = if (args.len == 2) args[0].value.string else null;
    const doc_name = args[args.len - 1].value.string;
    const doc = lookup(graph, node_package, package, doc_name) orelse return error.UnresolvedDoc;
    return .{ .string = try allocator.dupe(u8, doc.block_contents) };
}

/// Core 1.10 records direct doc() output calls, while filtered, concatenated
/// and conditional expressions render normally without a doc_blocks entry.
pub fn dependencies(allocator: std.mem.Allocator, graph: *const types.Graph, package: []const u8, text: []const u8, output: *std.ArrayList([]const u8)) !void {
    output.clearRetainingCapacity();
    var cursor: usize = 0;
    var raw = false;
    while (std.mem.indexOfPos(u8, text, cursor, "{")) |open| {
        if (open + 1 >= text.len) break;
        const marker = text[open + 1];
        if (marker != '{' and marker != '%' and marker != '#') {
            cursor = open + 1;
            continue;
        }
        const close_marker: []const u8 = if (marker == '{') "}}" else if (marker == '%') "%}" else "#}";
        const close = if (marker == '{') jinja.findExpressionClose(text, open + 2) else std.mem.indexOfPos(u8, text, open + 2, close_marker);
        const end = close orelse return error.UnsupportedJinja;
        var span = std.mem.trim(u8, text[open + 2 .. end], " \t\r\n-");
        cursor = end + 2;
        if (marker == '#') continue;
        if (marker == '%') {
            if (equal(span, "raw")) {
                raw = true;
                continue;
            }
            if (equal(span, "endraw")) {
                raw = false;
                continue;
            }
            if (!raw) return error.UnsupportedDynamicDoc;
        }
        if (raw) continue;
        while (span.len != 0 and span[0] == '(' and jinja.findMatchingParen(span, 0) == span.len - 1) span = std.mem.trim(u8, span[1 .. span.len - 1], " \t\r\n");
        if (!std.mem.startsWith(u8, span, "doc") or (span.len > 3 and identifier(span[3]))) continue;
        const paren = jinja.skipWs(span, 3);
        if (paren >= span.len or span[paren] != '(') continue;
        const end_call = jinja.findMatchingParen(span, paren) orelse return error.InvalidDocArguments;
        if (end_call + 1 != span.len) continue;
        var args = try jinja.parseLiteralArgs(allocator, span[paren + 1 .. end_call], error.InvalidDocArguments);
        defer {
            for (args.items) |arg| allocator.free(arg);
            args.deinit(allocator);
        }
        if (args.items.len < 1 or args.items.len > 2) continue;
        if (lookup(graph, package, if (args.items.len == 2) args.items[0] else null, args.items[args.items.len - 1])) |doc| try output.append(allocator, doc.unique_id);
    }
}

pub fn finalize(runtime: types.Runtime, graph: *types.Graph) !void {
    const a = runtime.allocator;
    for (graph.nodes.items) |*node| if (node.enabled) {
        try render(a, graph, node.package_name, node.unique_id, node.original_file_path, &node.description, &node.doc_blocks);
        try columns(a, graph, node.package_name, node.unique_id, node.original_file_path, node.columns.items);
    };
    for (graph.singular_tests.items) |*node| if (node.enabled) try render(a, graph, node.package_name, node.unique_id, node.original_file_path, &node.description, &node.doc_blocks);
    for (graph.tests.items) |*node| if (!node.disabled) try render(a, graph, node.package_name, node.unique_id, node.original_file_path, &node.description, &node.doc_blocks);
    for (graph.sources.items) |*node| if (node.enabled) {
        try render(a, graph, node.package_name, node.unique_id, node.original_file_path, &node.description, &node.doc_blocks);
        try render(a, graph, node.package_name, node.unique_id, node.original_file_path, &node.source_description, null);
        try columns(a, graph, node.package_name, node.unique_id, node.original_file_path, node.columns.items);
    };
    for (graph.macros.items) |*node| {
        try render(a, graph, node.package_name, node.unique_id, node.original_file_path, &node.description, null);
        for (node.arguments.items) |*argument| try render(a, graph, node.package_name, node.unique_id, node.original_file_path, &argument.description, null);
    }
    for (graph.exposures.items) |*node| if (node.enabled) try render(a, graph, node.package_name, node.unique_id, node.original_file_path, &node.description, null);
    for (graph.semantic_resources.items) |*node| if (node.enabled) {
        try jsonDescription(a, graph, node.package_name, node.unique_id, node.original_file_path, &node.data);
        inline for (.{ "dimensions", "measures", "entities" }) |key| if (values.get(node.data, key)) |array| if (array == .array) {
            for (array.array.items) |*item| try jsonDescription(a, graph, node.package_name, node.unique_id, node.original_file_path, item);
        };
    };
}

fn render(a: std.mem.Allocator, graph: *const types.Graph, package: []const u8, id: []const u8, path: []const u8, description: *[]const u8, deps: ?*std.ArrayList([]const u8)) !void {
    if (deps) |list| dependencies(a, graph, package, description.*, list) catch |err| {
        const detail = try std.fmt.allocPrint(a, "{s} processing documentation: {s}", .{ @errorName(err), description.* });
        defer a.free(detail);
        @import("compile_diagnostics.zig").captureError(path, id, detail, err);
        return err;
    };
    if (std.mem.indexOf(u8, description.*, "{{") == null and std.mem.indexOf(u8, description.*, "{%") == null and std.mem.indexOf(u8, description.*, "{#") == null) return;
    description.* = try @import("compiler.zig").renderDocumentation(a, graph, package, id, path, description.*);
}
fn columns(a: std.mem.Allocator, graph: *const types.Graph, package: []const u8, id: []const u8, path: []const u8, items: []types.ColumnDef) !void {
    for (items) |*column| try render(a, graph, package, id, path, &column.description, &column.doc_blocks);
}
fn jsonDescription(a: std.mem.Allocator, graph: *const types.Graph, package: []const u8, id: []const u8, path: []const u8, object: *std.json.Value) !void {
    if (values.get(object.*, "description")) |description| if (description == .string) {
        var text = description.string;
        try render(a, graph, package, id, path, &text, null);
        if (text.ptr != description.string.ptr) {
            defer a.free(text);
            try values.put(a, object, "description", .{ .string = text });
        }
    };
}
fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
fn identifier(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

test "documentation lookup follows explicit root local and installed package order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph = types.Graph{ .allocator = a, .project_name = "root" };
    defer graph.deinit();
    for ([_][]const u8{ "dependency", "root" }) |package| try graph.docs.append(a, .{ .package_name = package, .unique_id = try std.fmt.allocPrint(a, "doc.{s}.shared", .{package}), .name = "shared", .path = "models/docs.md", .original_file_path = "models/docs.md", .block_contents = package });
    try std.testing.expectEqualStrings("root", lookup(&graph, "dependency", null, "shared").?.block_contents);
    try std.testing.expectEqualStrings("dependency", lookup(&graph, "root", "dependency", "shared").?.block_contents);
    var deps: std.ArrayList([]const u8) = .empty;
    defer deps.deinit(a);
    try dependencies(a, &graph, "dependency", "doc('shared') {{ doc('shared') }} {{ doc('dependency','shared') }} {{ doc('shared') | upper }} {{ doc('dependency','shared') if false else '' }} {{ \"doc('shared')\" }}", &deps);
    try std.testing.expectEqual(@as(usize, 2), deps.items.len);
    try std.testing.expectEqualStrings("doc.root.shared", deps.items[0]);
    try std.testing.expectEqualStrings("doc.dependency.shared", deps.items[1]);
}
