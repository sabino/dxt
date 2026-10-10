//! PostgreSQL catalog execution uses the authored dispatch chain and bundled
//! adapter macros, with the same held native query context as model compilation.
const std = @import("std");
const types = @import("types.zig");
const catalog = @import("catalog.zig");
const compiler = @import("compiler.zig");
const expression = @import("expression.zig");
const commands = @import("commands.zig");
const selector = @import("selector.zig");
const contexts = @import("dbt_context.zig");
const sets = @import("set_context.zig");

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
        const information_schema = try contexts.relationValue(allocator, .{ .adapter_type = "postgres", .database = database, .schema = "information_schema", .include_policy = .{ .identifier = false } });
        const table = try compiler.renderMacroForNode(allocator, &contextual_graph, &catalog_node, "get_catalog_relations", &.{
            .{ .name = "information_schema", .value = information_schema },
            .{ .name = "relations", .value = try sets.fromMembers(allocator, database_relations.items) },
        });
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
