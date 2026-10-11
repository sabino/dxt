const std = @import("std");
const types = @import("types.zig");
const state = @import("state.zig");
const compiler = @import("compiler.zig");
const duckdb = @import("duckdb.zig");
const selector = @import("selector.zig");
const adapter = @import("adapter.zig");

// Deferral affects ref() relation resolution after selection; sources always use
// the current manifest, as in Core's RuntimeSourceResolver.
pub fn apply(runtime: types.Runtime, graph: *types.Graph, options: types.Options, selected: []const selector.SelectedResource, target_dir: []const u8) !void {
    if (!options.defer_enabled) return;
    const state_dir = options.defer_state orelse options.state orelse return error.MissingDeferState;
    var previous = try state.loadPriorManifestIndex(runtime, state_dir);
    defer previous.deinit(runtime.allocator);
    const db_path = try duckdb.databasePath(runtime.allocator, target_dir, graph);
    defer runtime.allocator.free(db_path);
    for (graph.nodes.items) |*node| {
        if (!node.enabled or std.mem.eql(u8, node.materialized, "ephemeral")) continue;
        if (!std.mem.eql(u8, node.resource_type, "model") and !std.mem.eql(u8, node.resource_type, "seed") and !std.mem.eql(u8, node.resource_type, "snapshot")) continue;
        // Selected resources always retain their current relation identity.
        if (selectionContains(selected, node.unique_id)) continue;
        const prior = previous.resource(node.unique_id) orelse continue;
        const prior_config = state.valueField(prior, "config") orelse .null;
        if (state.stringField(prior_config, "materialized")) |materialized| {
            if (std.mem.eql(u8, materialized, "ephemeral")) continue;
        }
        if (!options.favor_state) {
            if (try currentRelationExists(runtime, db_path, graph, node)) continue;
        }
        const relation_name = try relationFromArtifact(runtime.allocator, prior);
        errdefer runtime.allocator.free(relation_name);
        const unique_id = try runtime.allocator.dupe(u8, node.unique_id);
        errdefer runtime.allocator.free(unique_id);
        try graph.deferred_relations.append(runtime.allocator, .{ .unique_id = unique_id, .relation_name = relation_name });
    }
}

fn selectionContains(selected: []const selector.SelectedResource, unique_id: []const u8) bool {
    for (selected) |item| if (std.mem.eql(u8, item.unique_id, unique_id)) return true;
    return false;
}

pub fn relationFromArtifact(allocator: std.mem.Allocator, resource: std.json.Value) ![]const u8 {
    if (state.stringField(resource, "relation_name")) |name| {
        if (name.len != 0) return try allocator.dupe(u8, name);
    }
    const schema = state.stringField(resource, "schema") orelse return error.MalformedDeferRelation;
    const alias = state.stringField(resource, "alias") orelse return error.MalformedDeferRelation;
    const quoted_schema = try quoteIdentifier(allocator, schema);
    defer allocator.free(quoted_schema);
    const quoted_alias = try quoteIdentifier(allocator, alias);
    defer allocator.free(quoted_alias);
    if (state.stringField(resource, "database")) |database| {
        const quoted_database = try quoteIdentifier(allocator, database);
        defer allocator.free(quoted_database);
        return try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ quoted_database, quoted_schema, quoted_alias });
    }
    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ quoted_schema, quoted_alias });
}

fn quoteIdentifier(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const escaped = try std.mem.replaceOwned(u8, allocator, value, "\"", "\"\"");
    defer allocator.free(escaped);
    return try std.fmt.allocPrint(allocator, "\"{s}\"", .{escaped});
}

fn currentRelationExists(runtime: types.Runtime, db_path: []const u8, graph: *const types.Graph, node: *const types.Node) !bool {
    if (std.mem.eql(u8, graph.adapter_type, "duckdb")) {
        const file = std.Io.Dir.cwd().openFile(runtime.io, db_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        file.close(runtime.io);
    }
    const schema = try compiler.relationSchemaForNode(runtime.allocator, graph, node);
    defer runtime.allocator.free(schema);
    const schema_literal = try adapter.quoteLiteral(runtime.allocator, schema);
    defer runtime.allocator.free(schema_literal);
    const identifier_literal = try adapter.quoteLiteral(runtime.allocator, compiler.relationIdentifierForNode(node));
    defer runtime.allocator.free(identifier_literal);
    const sql = try std.fmt.allocPrint(runtime.allocator, "select count(*) from information_schema.tables where table_schema = {s} and table_name = {s}", .{ schema_literal, identifier_literal });
    defer runtime.allocator.free(sql);
    var result = try adapter.queryForGraph(runtime, graph, db_path, sql);
    defer result.deinit(runtime.allocator);
    const count = std.fmt.parseInt(u64, result.firstScalar() orelse return error.DeferRelationLookupFailed, 10) catch return error.DeferRelationLookupFailed;
    return count != 0;
}

test "defer relation preserves artifact identity and quoted fallback" {
    const allocator = std.testing.allocator;
    var resource = try std.json.parseFromSlice(std.json.Value, allocator, "{\"database\":\"prod\",\"schema\":\"history\",\"alias\":\"a\\\"b\"}", .{});
    defer resource.deinit();
    const name = try relationFromArtifact(allocator, resource.value);
    defer allocator.free(name);
    try std.testing.expectEqualStrings("\"prod\".\"history\".\"a\"\"b\"", name);
}
