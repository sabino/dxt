//! PostgreSQL and authored DuckDB catalog hooks use the existing dispatch chain
//! and held native query context. Stock DuckDB keeps its direct introspection.
const std = @import("std");
const types = @import("types.zig");
const catalog = @import("catalog.zig");
const compiler = @import("compiler.zig");
const expression = @import("expression.zig");
const commands = @import("commands.zig");
const selector = @import("selector.zig");
const contexts = @import("dbt_context.zig");
const sets = @import("set_context.zig");
const resolve = @import("resolve.zig");
const jinja = @import("jinja.zig");
const unicode = @import("expression_unicode.zig");

pub fn usesAuthoredDuckCatalog(graph: *const types.Graph) bool {
    if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return false;
    const entry = globalCatalogMacro(graph) orelse return true;
    if (!std.mem.eql(u8, entry.unique_id, "macro.dbt.get_catalog")) return true;
    const prefixes = jinja.dispatchPrefixesForAdapter(graph.adapter_type);
    const dispatched = resolve.findMacroIdForAdapterDispatch(graph, entry.package_name, "get_catalog", "dbt", prefixes.slice()) orelse return true;
    return !std.mem.eql(u8, dispatched, "macro.dbt_duckdb.duckdb__get_catalog");
}

fn globalCatalogMacro(graph: *const types.Graph) ?*const types.MacroDef {
    return macroById(graph, resolve.findMacroIdForGlobalMacroDependency(graph, "get_catalog") orelse return null);
}

fn macroById(graph: *const types.Graph, id: []const u8) ?*const types.MacroDef {
    for (graph.macros.items) |*macro| if (std.mem.eql(u8, macro.unique_id, id)) return macro;
    return null;
}

fn duckCatalogArguments(allocator: std.mem.Allocator, relations: []const expression.Value) ![2]expression.Argument {
    if (relations.len == 0) return error.InvalidCatalogResult;
    const method = expression.callableName(relations[0].attribute("information_schema_only")) orelse return error.InvalidRelation;
    const information_schema = (try contexts.call(allocator, "duckdb", method, &.{})) orelse return error.InvalidRelation;
    var schemas: std.ArrayList(expression.Value) = .empty;
    for (relations) |relation| {
        const definition = try contexts.relationFromValue(allocator, relation);
        try schemas.append(allocator, if (definition.schema) |schema| .{ .string = try unicode.convert(allocator, schema, .lower) } else .none);
    }
    return .{
        .{ .name = "information_schema", .value = information_schema },
        .{ .name = "schemas", .value = try sets.fromMembers(allocator, schemas.items) },
    };
}

fn renderDuckCatalog(allocator: std.mem.Allocator, graph: *const types.Graph, node: *const types.Node, relations: []const expression.Value) !expression.Value {
    const entry = globalCatalogMacro(graph) orelse return error.UnresolvedMacro;
    const name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ entry.package_name, entry.name });
    const args = try duckCatalogArguments(allocator, relations);
    return compiler.renderMacroForNode(allocator, graph, node, name, &args);
}

pub fn collect(runtime: types.Runtime, db_path: []const u8, graph: *const types.Graph, selected: []const selector.SelectedResource, stdout: *std.Io.Writer) !catalog.CatalogEntries {
    var arena = std.heap.ArenaAllocator.init(runtime.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var contextual_graph = graph.*;
    contextual_graph.allocator = allocator;
    var host = try commands.OperationHost.initLazy(runtime, &contextual_graph, db_path, stdout);
    defer host.deinit();
    contextual_graph.execution_hooks = host.host();
    const catalog_node = types.Node{ .package_name = graph.project_name, .unique_id = "operation.catalog", .name = "catalog", .resource_type = "operation", .path = "", .original_file_path = "", .raw_code = "" };
    var relations: std.ArrayList(expression.Value) = .empty;
    for (graph.nodes.items) |*node| {
        if (!contains(selected, node.unique_id) or !node.enabled) continue;
        if (!std.mem.eql(u8, node.resource_type, "model") and !std.mem.eql(u8, node.resource_type, "seed") and !std.mem.eql(u8, node.resource_type, "snapshot")) continue;
        if (std.mem.eql(u8, node.materialized, "ephemeral")) continue;
        try relations.append(allocator, try compiler.relationValueForNode(allocator, graph, node, false));
    }
    for (graph.sources.items) |*source| {
        if (source.enabled and contains(selected, source.unique_id)) try relations.append(allocator, try compiler.relationValueForSource(allocator, graph, &catalog_node, source));
    }
    var entries: catalog.CatalogEntries = .{};
    errdefer catalog.deinitCatalogEntries(runtime.allocator, &entries);
    if (relations.items.len == 0) return entries;
    var databases: std.ArrayList([]const u8) = .empty;
    var all_rows: std.ArrayList(expression.Value) = .empty;
    for (relations.items) |relation| {
        const database = (try contexts.relationFromValue(allocator, relation)).database orelse continue;
        var found = false;
        for (databases.items) |existing| if (std.mem.eql(u8, existing, database)) {
            found = true;
        };
        if (!found) try databases.append(allocator, database);
    }
    for (databases.items) |database| {
        var database_relations: std.ArrayList(expression.Value) = .empty;
        for (relations.items) |relation| {
            const definition = try contexts.relationFromValue(allocator, relation);
            if (definition.database != null and std.mem.eql(u8, definition.database.?, database)) try database_relations.append(allocator, relation);
        }
        const table = if (std.mem.eql(u8, graph.adapter_type, "duckdb"))
            try renderDuckCatalog(allocator, &contextual_graph, &catalog_node, database_relations.items)
        else blk: {
            const information_schema = try contexts.relationValue(allocator, .{ .adapter_type = "postgres", .database = database, .schema = "information_schema", .include_policy = .{ .identifier = false } });
            break :blk try compiler.renderMacroForNode(allocator, &contextual_graph, &catalog_node, "get_catalog_relations", &.{
                .{ .name = "information_schema", .value = information_schema },
                .{ .name = "relations", .value = try sets.fromMembers(allocator, database_relations.items) },
            });
        };
        try all_rows.appendSlice(allocator, expression.sequence(table) orelse return error.InvalidCatalogResult);
    }
    const rows = all_rows.items;
    for (graph.nodes.items) |*resource| {
        if (!contains(selected, resource.unique_id) or !resource.enabled) continue;
        if (!std.mem.eql(u8, resource.resource_type, "model") and !std.mem.eql(u8, resource.resource_type, "seed") and !std.mem.eql(u8, resource.resource_type, "snapshot")) continue;
        if (std.mem.eql(u8, resource.materialized, "ephemeral")) continue;
        const relation = try contexts.relationFromValue(allocator, try compiler.relationValueForNode(allocator, graph, resource, false));
        if (try entryForRelation(runtime.allocator, resource.unique_id, relation, rows)) |entry| try appendOwned(runtime.allocator, &entries.nodes, entry);
    }
    for (graph.sources.items) |*source| {
        if (!source.enabled or !contains(selected, source.unique_id)) continue;
        const relation = try contexts.relationFromValue(allocator, try compiler.relationValueForSource(allocator, graph, &catalog_node, source));
        if (try entryForRelation(runtime.allocator, source.unique_id, relation, rows)) |entry| try appendOwned(runtime.allocator, &entries.sources, entry);
    }
    return entries;
}

fn appendOwned(allocator: std.mem.Allocator, entries: *std.ArrayList(catalog.CatalogEntry), entry: catalog.CatalogEntry) !void {
    entries.append(allocator, entry) catch |err| {
        var owned = entry;
        deinitEntry(allocator, &owned);
        return err;
    };
}

fn entryForRelation(allocator: std.mem.Allocator, unique_id: []const u8, relation: contexts.RelationDef, rows: []const expression.Value) !?catalog.CatalogEntry {
    var result: ?catalog.CatalogEntry = null;
    errdefer if (result) |*entry| deinitEntry(allocator, entry);
    for (rows) |row| {
        const database = try string(row, "table_database");
        const schema = try string(row, "table_schema");
        const name = try string(row, "table_name");
        if (!std.ascii.eqlIgnoreCase(relation.database orelse "", database) or !std.ascii.eqlIgnoreCase(relation.schema orelse "", schema) or !std.ascii.eqlIgnoreCase(relation.identifier orelse "", name)) continue;
        if (result == null) {
            const id = try allocator.dupe(u8, unique_id);
            errdefer allocator.free(id);
            const db = try allocator.dupe(u8, database);
            errdefer allocator.free(db);
            const sch = try allocator.dupe(u8, schema);
            errdefer allocator.free(sch);
            const identifier = try allocator.dupe(u8, name);
            errdefer allocator.free(identifier);
            const kind = try allocator.dupe(u8, try string(row, "table_type"));
            errdefer allocator.free(kind);
            const comment = try optionalString(allocator, row.attribute("table_comment"));
            errdefer if (comment) |value| allocator.free(value);
            const owner = try optionalString(allocator, row.attribute("table_owner"));
            result = .{ .unique_id = id, .database = db, .schema = sch, .name = identifier, .relation_type = kind, .comment = comment, .owner = owner };
        }
        const column_name = try allocator.dupe(u8, try string(row, "column_name"));
        errdefer allocator.free(column_name);
        const column_type = try allocator.dupe(u8, try string(row, "column_type"));
        errdefer allocator.free(column_type);
        const comment = try optionalString(allocator, row.attribute("column_comment"));
        errdefer if (comment) |value| allocator.free(value);
        const ordinal = row.attribute("column_index");
        const index = expression.integerIndex(ordinal) catch return error.InvalidCatalogResult;
        if (index < 1) return error.InvalidCatalogResult;
        try result.?.columns.append(allocator, .{ .name = column_name, .data_type = column_type, .index = @intCast(index), .comment = comment });
    }
    return result;
}

fn optionalString(allocator: std.mem.Allocator, value: expression.Value) !?[]const u8 {
    if (value == .none or value == .undefined) return null;
    if (value != .string) return error.InvalidCatalogResult;
    return try allocator.dupe(u8, value.string);
}

fn string(row: expression.Value, key: []const u8) ![]const u8 {
    const value = row.attribute(key);
    if (value != .string) return error.InvalidCatalogResult;
    return value.string;
}

fn deinitEntry(allocator: std.mem.Allocator, entry: *catalog.CatalogEntry) void {
    allocator.free(entry.unique_id);
    if (entry.database) |value| allocator.free(value);
    allocator.free(entry.schema);
    allocator.free(entry.name);
    allocator.free(entry.relation_type);
    if (entry.comment) |value| allocator.free(value);
    if (entry.owner) |value| allocator.free(value);
    for (entry.columns.items) |column| {
        allocator.free(column.name);
        allocator.free(column.data_type);
        if (column.comment) |value| allocator.free(value);
    }
    entry.columns.deinit(allocator);
}

fn contains(selected: []const selector.SelectedResource, id: []const u8) bool {
    for (selected) |resource| if (std.mem.eql(u8, id, resource.unique_id)) return true;
    return false;
}

test "authored Duck catalog hooks receive the Core InformationSchema and lowercase set prototype" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = types.Graph{ .allocator = allocator, .project_name = "demo", .adapter_type = "duckdb" };
    defer graph.deinit();
    try @import("bundled_macros.zig").load(allocator, &graph);
    try std.testing.expect(!usesAuthoredDuckCatalog(&graph));
    var postgres = graph;
    postgres.adapter_type = "postgres";
    try std.testing.expect(!usesAuthoredDuckCatalog(&postgres));
    try graph.macros.append(allocator, .{
        .unique_id = "macro.demo.duckdb__get_catalog",
        .package_name = "demo",
        .name = "duckdb__get_catalog",
        .path = "catalog.sql",
        .original_file_path = "macros/catalog.sql",
        .macro_sql =
        \\{% macro duckdb__get_catalog(information_schema, schemas) %}
        \\{{ return({'database': information_schema.database, 'schema': information_schema.schema,
        \\ 'identifier': information_schema.identifier, 'type': information_schema.type,
        \\ 'class': information_schema.get('metadata').type, 'rendered': information_schema|string,
        \\ 'schemas': schemas|list|sort, 'mapping': schemas is mapping,
        \\ 'sequence': schemas is sequence, 'iterable': schemas is iterable}) }}
        \\{% endmacro %}
        ,
    });
    try std.testing.expect(usesAuthoredDuckCatalog(&graph));
    const relations = [_]expression.Value{
        try contexts.relationValue(allocator, .{ .adapter_type = "duckdb", .database = "warehouse", .schema = "MAIN", .identifier = "first" }),
        try contexts.relationValue(allocator, .{ .adapter_type = "duckdb", .database = "warehouse", .schema = "main", .identifier = "second" }),
        try contexts.relationValue(allocator, .{ .adapter_type = "duckdb", .database = "warehouse", .schema = "Straße", .identifier = "third" }),
        try contexts.relationValue(allocator, .{ .adapter_type = "duckdb", .database = "warehouse", .schema = "STRASSE", .identifier = "fourth" }),
    };
    const node = types.Node{ .package_name = "demo", .unique_id = "operation.catalog", .name = "catalog", .resource_type = "operation", .path = "", .original_file_path = "", .raw_code = "" };
    const result = try renderDuckCatalog(allocator, &graph, &node, &relations);
    try std.testing.expectEqualStrings("warehouse", result.attribute("database").string);
    try std.testing.expect(result.attribute("schema") == .none);
    try std.testing.expectEqualStrings("INFORMATION_SCHEMA", result.attribute("identifier").string);
    try std.testing.expectEqualStrings("view", result.attribute("type").string);
    try std.testing.expectEqualStrings("InformationSchema", result.attribute("class").string);
    try std.testing.expectEqualStrings("\"warehouse\".INFORMATION_SCHEMA", result.attribute("rendered").string);
    try std.testing.expect(!result.attribute("mapping").boolean);
    try std.testing.expect(!result.attribute("sequence").boolean);
    try std.testing.expect(result.attribute("iterable").boolean);
    const schemas = result.attribute("schemas").list;
    try std.testing.expectEqual(@as(usize, 3), schemas.len);
    for ([_][]const u8{ "main", "strasse", "straße" }, schemas) |expected, actual| try std.testing.expectEqualStrings(expected, actual.string);

    var config = types.DispatchConfig{ .macro_namespace = "dbt" };
    try config.search_order.append(allocator, "dbt");
    try graph.dispatch_configs.append(allocator, config);
    // An explicit bundled search order keeps stock introspection even when an
    // unrelated authored candidate exists. Missing configured hooks must fail.
    try std.testing.expect(!usesAuthoredDuckCatalog(&graph));
    graph.dispatch_configs.items[0].search_order.items[0] = "missing";
    try std.testing.expect(usesAuthoredDuckCatalog(&graph));
    try std.testing.expectError(error.UnresolvedMacro, renderDuckCatalog(allocator, &graph, &node, &relations));
    graph.dispatch_configs.items[0].search_order.items[0] = "dbt";
    for (graph.macros.items, 0..) |macro, index| {
        if (std.mem.eql(u8, macro.unique_id, "macro.dbt_duckdb.duckdb__get_catalog")) {
            _ = graph.macros.orderedRemove(index);
            break;
        }
    }
    // A selected bundled default is an actual unsupported-hook error, not
    // permission to bypass dispatch and produce a successful direct catalog.
    try std.testing.expect(usesAuthoredDuckCatalog(&graph));
    try std.testing.expectError(error.JinjaCompilerError, renderDuckCatalog(allocator, &graph, &node, &relations));
}

test "global Duck catalog overrides retain selected package precedence and missing errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = types.Graph{ .allocator = allocator, .project_name = "demo", .adapter_type = "duckdb" };
    defer graph.deinit();
    const node = types.Node{ .package_name = "demo", .unique_id = "operation.catalog", .name = "catalog", .resource_type = "operation", .path = "", .original_file_path = "", .raw_code = "" };
    const relations = [_]expression.Value{try contexts.relationValue(allocator, .{ .adapter_type = "duckdb", .database = "warehouse", .schema = "main", .identifier = "first" })};
    try std.testing.expect(usesAuthoredDuckCatalog(&graph));
    try std.testing.expectError(error.UnresolvedMacro, renderDuckCatalog(allocator, &graph, &node, &relations));
    try @import("bundled_macros.zig").load(allocator, &graph);
    try graph.macros.append(allocator, .{
        .unique_id = "macro.dependency.get_catalog",
        .package_name = "dependency",
        .name = "get_catalog",
        .path = "catalog.sql",
        .original_file_path = "macros/catalog.sql",
        .macro_sql = "{% macro get_catalog(information_schema, schemas) %}{{ return('dependency') }}{% endmacro %}",
    });
    try std.testing.expect(usesAuthoredDuckCatalog(&graph));
    const dependency = try renderDuckCatalog(allocator, &graph, &node, &relations);
    try std.testing.expectEqualStrings("dependency", dependency.string);
    try graph.macros.append(allocator, .{
        .unique_id = "macro.demo.get_catalog",
        .package_name = "demo",
        .name = "get_catalog",
        .path = "catalog.sql",
        .original_file_path = "macros/catalog.sql",
        .macro_sql = "{% macro get_catalog(information_schema, schemas) %}{{ return('root') }}{% endmacro %}",
    });
    const root = try renderDuckCatalog(allocator, &graph, &node, &relations);
    try std.testing.expectEqualStrings("root", root.string);
}
