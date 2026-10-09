//! Core 1.10.5 parser.base.RelationUpdate: package-specific generator first,
//! root/internal fallback, database/schema/alias order, then legacy snapshot
//! target overrides. Name generation never records model macro dependencies.
const std = @import("std");
const types = @import("types.zig");
const compiler = @import("compiler.zig");
const values = @import("config_value.zig");
const context = @import("context_values.zig");

pub fn finalize(runtime: types.Runtime, graph: *types.Graph) !void {
    for (graph.nodes.items) |*node| try nodeIdentity(runtime.allocator, graph, node);
    for (graph.tests.items) |*test_node| {
        var probe = testProbe(test_node.package_name, test_node.unique_id, test_node.name, test_node.path, test_node.original_file_path, test_node.raw_code, test_node.config, test_node.config_values);
        probe.enabled = test_node.enabled;
        probe.tags = test_node.tags;
        try nodeIdentityWithFqn(runtime.allocator, graph, &probe, if (test_node.fqn.items.len != 0) test_node.fqn.items else null);
        if (test_node.resolved_identity) |*prior| prior.deinit(runtime.allocator);
        test_node.resolved_identity = probe.resolved_identity;
    }
    for (graph.singular_tests.items) |*test_node| {
        var config = try @import("canonical_manifest_config.zig").testConfig(runtime.allocator, test_node.config, test_node.enabled, test_node.tags.items, test_node.config_values);
        defer values.deinit(runtime.allocator, &config);
        var probe = testProbe(test_node.package_name, test_node.unique_id, test_node.name, test_node.path, test_node.original_file_path, test_node.raw_code, test_node.config, config);
        probe.enabled = test_node.enabled;
        probe.tags = test_node.tags;
        try nodeIdentity(runtime.allocator, graph, &probe);
        if (test_node.resolved_identity) |*prior| prior.deinit(runtime.allocator);
        test_node.resolved_identity = probe.resolved_identity;
    }
    for (graph.semantic_resources.items) |*resource| {
        if (!equal(resource.resource_type, "saved_query")) continue;
        try savedQueryExports(runtime.allocator, graph, &resource.data);
    }
}

/// Core's SavedQueryParser passes an Export, not a graph node, to the same
/// generators. Its optional schema_name/alias are preserved when configured;
/// generated database overrides the configured database when truthy.
fn savedQueryExports(a: std.mem.Allocator, graph: *const types.Graph, data: *std.json.Value) !void {
    if (generator(graph, graph.project_name, "schema") == null) return;
    const exports = data.object.getPtr("exports") orelse return;
    if (exports.* != .array) return;
    const inherited = values.get(data.*, "config") orelse .null;
    for (exports.array.items) |*exported| {
        const raw = values.get(exported.*, "unrendered_config") orelse .null;
        var config: std.json.Value = .{ .object = .empty };
        defer values.deinit(a, &config);
        const existing = values.get(exported.*, "config") orelse .null;
        try values.put(a, &config, "export_as", values.get(existing, "export_as") orelse .null);
        const configured_schema = values.get(raw, "schema_name") orelse values.get(inherited, "schema_name") orelse .null;
        try values.put(a, &config, "schema_name", if (configured_schema != .null) configured_schema else values.get(raw, "schema") orelse values.get(inherited, "schema") orelse .null);
        for ([_][]const u8{ "alias", "database" }) |key| try values.put(a, &config, key, values.get(raw, key) orelse values.get(inherited, key) orelse .null);

        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        const temporary = scratch.allocator();
        var argument: std.json.Value = .{ .object = .empty };
        try values.put(temporary, &argument, "name", values.get(exported.*, "name") orelse .null);
        try values.put(temporary, &argument, "config", config);
        try values.put(temporary, &argument, "unrendered_config", raw);
        inline for (.{ "database", "schema", "alias" }) |component| {
            const macro = generator(graph, graph.project_name, component) orelse return error.UnresolvedMacro;
            const override = if (comptime equal(component, "schema")) std.json.Value.null else values.get(config, component) orelse .null;
            const arguments = [_]@import("expression.zig").Argument{
                .{ .value = try values.toExpression(temporary, override) },
                .{ .value = try values.toExpression(temporary, argument) },
            };
            const generated = try compiler.renderNamingMacro(temporary, graph, macro, &arguments);
            if (generated != .string and generated != .none) return error.JinjaCompilerError;
            try values.put(temporary, &argument, component, if (generated == .string) .{ .string = try @import("expression_unicode.zig").strip(generated.string, null, true, true) } else .null);
        }
        for ([_][2][]const u8{ .{ "database", "database" }, .{ "schema_name", "schema" }, .{ "alias", "alias" } }) |pair| {
            const configured = values.get(config, pair[0]).?;
            const generated = values.get(argument, pair[1]).?;
            const chosen = if (equal(pair[0], "database")) if ((try values.toExpression(temporary, generated)).truthy()) generated else configured else if ((try values.toExpression(temporary, configured)).truthy()) configured else generated;
            try values.put(a, &config, pair[0], chosen);
        }
        try values.put(a, exported, "config", config);
    }
}

fn testProbe(package: []const u8, id: []const u8, name: []const u8, path: []const u8, original: []const u8, code: []const u8, config: types.GenericTestConfig, effective: std.json.Value) types.Node {
    return .{ .resource_type = "test", .materialized = "test", .package_name = package, .unique_id = id, .name = name, .path = path, .original_file_path = original, .raw_code = code, .config_schema = config.schema orelse "dbt_test__audit", .config_alias = config.alias, .test_config = config, .effective_config = effective };
}

pub fn generator(graph: *const types.Graph, package: []const u8, component: []const u8) ?*const types.MacroDef {
    var name_buffer: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buffer, "generate_{s}_name", .{component}) catch return null;
    if (!equal(package, graph.project_name) and !equal(package, "dbt") and !equal(package, "dbt_duckdb") and !equal(package, "dbt_postgres")) {
        for (graph.macros.items) |*macro| if (equal(macro.package_name, package) and equal(macro.name, name)) return macro;
    }
    for (graph.macros.items) |*macro| if (equal(macro.package_name, graph.project_name) and equal(macro.name, name)) return macro;
    const adapter_package = if (equal(graph.adapter_type, "postgres")) "dbt_postgres" else "dbt_duckdb";
    for (graph.macros.items) |*macro| if (equal(macro.package_name, adapter_package) and equal(macro.name, name)) return macro;
    for (graph.macros.items) |*macro| if (equal(macro.package_name, "dbt") and equal(macro.name, name)) return macro;
    return null;
}

pub fn nodeIdentity(a: std.mem.Allocator, graph: *const types.Graph, node: *types.Node) !void {
    return nodeIdentityWithFqn(a, graph, node, null);
}

fn nodeIdentityWithFqn(a: std.mem.Allocator, graph: *const types.Graph, node: *types.Node, fqn: ?[]const []const u8) !void {
    // Native helper fixtures may deliberately omit bundled macros. Their
    // existing default relation contract remains available without a loader.
    if (generator(graph, node.package_name, "schema") == null) return;
    if (node.resolved_identity) |*prior| prior.deinit(a);
    node.resolved_identity = null;
    var initial = node.*;
    initial.config_schema = null;
    initial.config_alias = null;
    initial.snapshot_config = null;
    initial.effective_config = .null;
    const database = compiler.relationDatabaseForNode(graph, &initial);
    node.resolved_identity = .{ .database = if (database) |value| try a.dupe(u8, value) else null, .schema = try a.dupe(u8, graph.target_schema), .identifier = try a.dupe(u8, node.name) };
    errdefer {
        node.resolved_identity.?.deinit(a);
        node.resolved_identity = null;
    }
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const temporary = scratch.allocator();
    inline for (.{ "database", "schema", "alias" }) |component| {
        const macro = generator(graph, node.package_name, component) orelse return error.UnresolvedMacro;
        const override = if (equal(component, "schema")) if (node.config_schema) |value| std.json.Value{ .string = value } else std.json.Value.null else if (equal(component, "alias")) if (node.config_alias) |value| std.json.Value{ .string = value } else std.json.Value.null else values.get(node.effective_config, "database") orelse std.json.Value.null;
        const model = try context.model(temporary, graph, node);
        if (fqn) |parts| {
            const items = try @import("expression.zig").allocateValues(temporary, parts.len);
            for (parts, items) |part, *item| item.* = .{ .string = part };
            for (@constCast(model.object)) |*entry| if (equal(entry.key, "fqn")) {
                entry.value = .{ .list = items };
                break;
            };
        }
        const arguments = [_]@import("expression.zig").Argument{
            .{ .value = try values.toExpression(temporary, override) },
            .{ .value = model },
        };
        const generated = try compiler.renderNamingMacro(temporary, graph, macro, &arguments);
        if (generated != .string and !(equal(component, "database") and generated == .none)) {
            @import("compile_diagnostics.zig").capture(node.original_file_path, node.name, "naming macro returned an unsupported relation component type");
            return error.JinjaCompilerError;
        }
        const text: ?[]const u8 = if (generated == .string) try a.dupe(u8, try @import("expression_unicode.zig").strip(generated.string, null, true, true)) else null;
        if (comptime equal(component, "database")) {
            if (node.resolved_identity.?.database) |prior| a.free(prior);
            node.resolved_identity.?.database = text;
        } else if (comptime equal(component, "schema")) {
            a.free(node.resolved_identity.?.schema);
            node.resolved_identity.?.schema = text.?;
        } else {
            a.free(node.resolved_identity.?.identifier);
            node.resolved_identity.?.identifier = text.?;
        }
    }
    if (node.snapshot_config) |snapshot| {
        if (snapshot.target_database) |target| if (target.len != 0) {
            if (node.resolved_identity.?.database) |prior| a.free(prior);
            node.resolved_identity.?.database = try a.dupe(u8, target);
        };
        if (snapshot.target_schema) |target| if (target.len != 0) {
            a.free(node.resolved_identity.?.schema);
            node.resolved_identity.?.schema = try a.dupe(u8, target);
        };
    }
}

fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

test "naming generator ignores unrelated packages and honors resource package overrides" {
    const a = std.testing.allocator;
    var graph = types.Graph{ .allocator = a, .project_name = "root" };
    defer graph.deinit();
    for ([_][]const u8{ "other", "root", "pkg", "dbt" }) |package| try graph.macros.append(a, .{ .package_name = package, .unique_id = package, .name = "generate_schema_name", .path = "", .original_file_path = "", .macro_sql = "" });
    try std.testing.expectEqualStrings("root", generator(&graph, "root", "schema").?.package_name);
    try std.testing.expectEqualStrings("pkg", generator(&graph, "pkg", "schema").?.package_name);
    try std.testing.expectEqualStrings("root", generator(&graph, "new_package", "schema").?.package_name);
}

fn fixtureMacros(a: std.mem.Allocator, graph: *types.Graph, database: []const u8, schema: []const u8, alias: []const u8) !void {
    for ([_][]const u8{ database, schema, alias }, [_][]const u8{ "database", "schema", "alias" }) |body, component| {
        const name = try std.fmt.allocPrint(a, "generate_{s}_name", .{component});
        const sql = try std.fmt.allocPrint(a, "{{% macro {s}(custom, node) %}}{s}{{% endmacro %}}", .{ name, body });
        try graph.macros.append(a, .{ .package_name = "root", .unique_id = name, .name = name, .path = "", .original_file_path = "", .macro_sql = sql });
    }
}

test "name generation freezes ordered components and legacy snapshot targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph = types.Graph{ .allocator = a, .project_name = "root" };
    defer graph.deinit();
    try fixtureMacros(a, &graph, "{{ return(' catalog ') }}", "{{ return(node.database ~ '_schema') }}", "{% if execute %}{{ exceptions.raise_compiler_error('parse only') }}{% endif %}{{ return(node.schema ~ '_alias') }}");
    var node = types.Node{ .package_name = "root", .unique_id = "snapshot.root.history", .name = "history", .path = "history.sql", .original_file_path = "snapshots/history.sql", .raw_code = "", .resource_type = "snapshot", .snapshot_config = .{ .target_schema = "legacy", .target_database = "legacy_database" } };
    try nodeIdentity(a, &graph, &node);
    try std.testing.expectEqualStrings("catalog_schema_alias", node.resolved_identity.?.identifier);
    try std.testing.expectEqualStrings("legacy", node.resolved_identity.?.schema);
    try std.testing.expectEqualStrings("legacy_database", node.resolved_identity.?.database.?);
    try std.testing.expectEqual(@as(usize, 0), node.macro_depends_on.items.len);
    node.snapshot_config = null;
    try nodeIdentity(a, &graph, &node);
    try std.testing.expectEqualStrings("catalog_schema", node.resolved_identity.?.schema);
}

test "optional export names preserve configured identity while generated database wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph = types.Graph{ .allocator = a, .project_name = "root" };
    defer graph.deinit();
    try fixtureMacros(a, &graph, "{{ return('generated_db') }}", "{{ return('generated_schema') }}", "{{ return(node.name ~ '_generated') }}");
    var parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"config\":{\"schema\":\"inherited\"},\"exports\":[{\"name\":\"value\",\"config\":{\"export_as\":\"table\"},\"unrendered_config\":{\"alias\":\"kept\",\"database\":\"authored\"}}]}", .{});
    defer parsed.deinit();
    var data = try values.clone(a, parsed.value);
    defer values.deinit(a, &data);
    try savedQueryExports(a, &graph, &data);
    const config = data.object.get("exports").?.array.items[0].object.get("config").?;
    try std.testing.expectEqualStrings("generated_db", config.object.get("database").?.string);
    try std.testing.expectEqualStrings("inherited", config.object.get("schema_name").?.string);
    try std.testing.expectEqualStrings("kept", config.object.get("alias").?.string);
}
