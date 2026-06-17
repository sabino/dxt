const std = @import("std");
const jinja = @import("jinja.zig");
const resolve = @import("resolve.zig");
const types = @import("types.zig");

const Graph = types.Graph;
const Node = types.Node;
const RefDep = types.RefDep;
const SourceDep = types.SourceDep;
const SourceDef = types.SourceDef;

const Relation = struct {
    schema: []const u8,
    identifier: []const u8,
};

pub fn compileModel(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < node.raw_code.len) {
        if (index + 1 >= node.raw_code.len or node.raw_code[index] != '{') {
            try out.append(allocator, node.raw_code[index]);
            index += 1;
            continue;
        }

        const tag_kind = node.raw_code[index + 1];
        if (tag_kind == '#') {
            const end = std.mem.indexOfPos(u8, node.raw_code, index + 2, "#}") orelse return error.UnsupportedJinja;
            index = end + 2;
            continue;
        }

        const close_marker: []const u8 = if (tag_kind == '{')
            "}}"
        else if (tag_kind == '%')
            "%}"
        else {
            try out.append(allocator, node.raw_code[index]);
            index += 1;
            continue;
        };
        const end = std.mem.indexOfPos(u8, node.raw_code, index + 2, close_marker) orelse return error.UnsupportedJinja;
        const span = std.mem.trim(u8, node.raw_code[index + 2 .. end], " \t\r\n-");
        if (tag_kind == '{') {
            const rendered = try renderExpression(allocator, graph, node, span);
            defer allocator.free(rendered);
            try out.appendSlice(allocator, rendered);
        } else {
            try renderStatement(graph, span);
        }
        index = end + 2;
    }

    return try out.toOwnedSlice(allocator);
}

pub fn relationNameForNode(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node) ![]const u8 {
    const schema = try relationSchemaForNode(allocator, graph, node);
    defer allocator.free(schema);
    const identifier = relationIdentifierForNode(node);
    return renderRelation(allocator, .{ .schema = schema, .identifier = identifier });
}

fn renderExpression(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node, span: []const u8) ![]const u8 {
    if (std.mem.eql(u8, span, "this")) {
        return try relationNameForNode(allocator, graph, node);
    }
    if (std.mem.startsWith(u8, span, "this.")) {
        return try renderThisAttribute(allocator, graph, node, span["this.".len..]);
    }
    if (std.mem.startsWith(u8, span, "target.")) {
        return try renderTargetAttribute(allocator, graph, span["target.".len..]);
    }

    const call = try parseSingleCall(span);
    const args = span[call.open + 1 .. call.close];
    if (call.package_name != null) return error.UnsupportedJinja;
    if (std.mem.eql(u8, call.name, "config")) {
        return try allocator.dupe(u8, "");
    }
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
    return error.UnsupportedJinja;
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

fn renderStatement(graph: *const Graph, span: []const u8) !void {
    _ = graph;
    if (span.len == 0) return;
    const call = try parseSingleCall(span);
    if (call.package_name == null and std.mem.eql(u8, call.name, "config")) return;
    return error.UnsupportedJinja;
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
