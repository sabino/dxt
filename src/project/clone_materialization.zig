//! Clone state relations through the native adapter, retaining the main response.
const std = @import("std");
const adapter = @import("adapter.zig");
const compiler = @import("compiler.zig");
const postgres = @import("postgres_materialization.zig");
const results = @import("run_results.zig");
const types = @import("types.zig");
const selector = @import("selector.zig");

pub const Outcome = struct {
    message: []const u8 = "No-op",
    response: ?results.AdapterResponse = null,
    owns_response: bool = false,

    pub fn deinit(self: Outcome, allocator: std.mem.Allocator) void {
        if (self.owns_response) {
            allocator.free(self.message);
            if (self.response.?.code) |code| allocator.free(code);
        }
    }
};

// Core prepares selected destination schemas before running resource hooks,
// including resources that ultimately have no prior state relation to clone.
pub fn prepareSchemas(runtime: types.Runtime, graph: *const types.Graph, selected: []const selector.SelectedResource, db_path: []const u8) !void {
    const a = runtime.allocator;
    var any_chosen = false;
    for (graph.nodes.items) |*node| if (chosenNode(node, selected)) {
        any_chosen = true;
        break;
    };
    if (!any_chosen) return;
    if (std.mem.eql(u8, graph.adapter_type, "postgres")) {
        var current = try adapter.queryForGraph(runtime, graph, db_path, "select current_database()");
        defer current.deinit(a);
        const actual = current.firstScalar() orelse return error.InvalidAdapterIntrospection;
        // Reject all invalid catalogs before any destination schema is created.
        for (graph.nodes.items) |*node| {
            if (!chosenNode(node, selected)) continue;
            if (compiler.relationDatabaseForNode(graph, node)) |database| if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, database, "\""), actual)) return error.InvalidPostgresDatabaseReference;
        }
    }
    for (graph.nodes.items) |*node| {
        if (!chosenNode(node, selected)) continue;
        const schema = try compiler.relationSchemaForNode(a, graph, node);
        defer a.free(schema);
        const quoted = try adapter.quoteIdentifier(a, schema);
        defer a.free(quoted);
        const sql = try std.fmt.allocPrint(a, "create schema if not exists {s}", .{quoted});
        defer a.free(sql);
        try adapter.executeForGraph(runtime, graph, db_path, sql);
    }
}

fn chosenNode(node: *const types.Node, selected: []const selector.SelectedResource) bool {
    if (!node.enabled or std.mem.eql(u8, node.materialized, "ephemeral")) return false;
    for (selected) |resource| if (std.mem.eql(u8, resource.unique_id, node.unique_id)) return true;
    return false;
}

pub fn execute(runtime: types.Runtime, options: types.Options, graph: *const types.Graph, node: *types.Node, prior_value: ?std.json.Value, db_path: []const u8) !Outcome {
    const allocator = runtime.allocator;
    const schema = try compiler.relationSchemaForNode(allocator, graph, node);
    defer allocator.free(schema);
    const target = try compiler.relationNameForNode(allocator, graph, node);
    defer allocator.free(target);
    if (std.mem.eql(u8, node.resource_type, "model") or std.mem.eql(u8, node.resource_type, "snapshot")) {
        node.compiled = false;
        node.compiled_code = null;
        node.relation_name = if (compiler.relationDatabaseForNode(graph, node) != null)
            try allocator.dupe(u8, target)
        else blk: {
            const database = try compiler.quoteIdentifier(allocator, std.fs.path.stem(std.fs.path.basename(db_path)));
            defer allocator.free(database);
            break :blk try std.fmt.allocPrint(allocator, "{s}.{s}", .{ database, target });
        };
    }
    const prior = prior_value orelse return .{};
    if (prior != .object) return error.MalformedStateManifestArtifact;
    if (prior.object.get("relation_name")) |relation_value| if (relation_value == .null) return .{};
    const schema_value = prior.object.get("schema") orelse return error.MalformedStateManifestArtifact;
    const alias_value = prior.object.get("alias") orelse return error.MalformedStateManifestArtifact;
    if (schema_value != .string or alias_value != .string) return error.MalformedStateManifestArtifact;
    const database_value = prior.object.get("database") orelse .null;
    if (database_value != .null and database_value != .string) return error.MalformedStateManifestArtifact;
    if (std.mem.eql(u8, graph.adapter_type, "postgres")) {
        var current = try adapter.queryForGraph(runtime, graph, db_path, "select current_database()");
        defer current.deinit(allocator);
        const actual_database = current.firstScalar() orelse return error.InvalidAdapterIntrospection;
        if (compiler.relationDatabaseForNode(graph, node)) |database| {
            if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, database, "\""), actual_database)) return error.InvalidPostgresDatabaseReference;
        }
    }
    const physical_value = prior.object.get("relation_name") orelse .null;
    if (physical_value != .null and physical_value != .string) return error.MalformedStateManifestArtifact;
    const same_database = std.mem.eql(u8, graph.adapter_type, "postgres") or database_value == .null or
        std.mem.eql(u8, database_value.string, compiler.relationDatabaseForNode(graph, node) orelse std.fs.path.stem(std.fs.path.basename(db_path)));
    // A destination that is already the physical source requires no replacement.
    // Core uses relation_name for SQL, even when separate metadata differs.
    const target_schema = try compiler.quoteIdentifier(allocator, schema);
    defer allocator.free(target_schema);
    const target_identifier = try compiler.quoteIdentifier(allocator, compiler.relationIdentifierForNode(node));
    defer allocator.free(target_identifier);
    const unqualified_target = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ target_schema, target_identifier });
    defer allocator.free(unqualified_target);
    if ((physical_value == .string and (std.mem.eql(u8, physical_value.string, target) or (same_database and std.mem.eql(u8, physical_value.string, unqualified_target)))) or
        (physical_value == .null and same_database and std.mem.eql(u8, schema, schema_value.string) and std.mem.eql(u8, compiler.relationIdentifierForNode(node), alias_value.string))) return .{};
    const kind = try existingKind(runtime, graph, db_path, schema, compiler.relationIdentifierForNode(node), compiler.relationDatabaseForNode(graph, node));
    defer if (kind) |value| allocator.free(value);
    if (kind != null and !options.full_refresh) return .{};
    const prior_schema = try compiler.quoteIdentifier(allocator, schema_value.string);
    defer allocator.free(prior_schema);
    const prior_alias = try compiler.quoteIdentifier(allocator, alias_value.string);
    defer allocator.free(prior_alias);
    const source = if (physical_value == .string and physical_value.string.len != 0)
        try allocator.dupe(u8, physical_value.string)
    else if (database_value == .string) blk: {
        const database = try compiler.quoteIdentifier(allocator, database_value.string);
        defer allocator.free(database);
        break :blk try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ database, prior_schema, prior_alias });
    } else try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prior_schema, prior_alias });
    defer allocator.free(source);
    const sql = try std.fmt.allocPrint(allocator, "select * from {s}", .{source});
    defer allocator.free(sql);
    var body = CloneBody{ .sql = sql, .allocator = allocator };
    errdefer if (body.outcome) |outcome| outcome.deinit(allocator);
    try @import("materialization_runtime.zig").executeWithBody(runtime, db_path, graph, node, .{ .context = &body, .execute = CloneBody.execute, .materialized = "view" });
    return body.outcome orelse return error.InvalidAdapterResponse;
}

const CloneBody = struct {
    sql: []const u8,
    allocator: std.mem.Allocator,
    outcome: ?Outcome = null,

    fn execute(raw: *anyopaque, runtime: types.Runtime, graph: *const types.Graph, node: *const types.Node, db_path: []const u8, policy: @import("duckdb.zig").ExecutionPolicy) anyerror!void {
        const self: *CloneBody = @ptrCast(@alignCast(raw));
        // The artifact keeps its uncompiled state node while only the physical
        // body uses the prior relation as a view query.
        var view = node.*;
        view.materialized = "view";
        view.compiled_code = self.sql;
        if (std.mem.eql(u8, graph.adapter_type, "postgres")) {
            var response = try postgres.executeReturningWithPolicy(runtime, graph, &view, self.sql, policy);
            defer response.deinit(runtime.allocator);
            self.outcome = try postgresOutcome(self.allocator, &response);
        } else {
            try @import("duckdb.zig").executeModelWithPolicy(runtime, db_path, graph, &view, policy);
            self.outcome = .{ .message = "OK", .response = .{ .message = "OK" } };
        }
    }
};

fn existingKind(runtime: types.Runtime, graph: *const types.Graph, db_path: []const u8, schema: []const u8, identifier: []const u8, database: ?[]const u8) !?[]const u8 {
    const allocator = runtime.allocator;
    if (std.mem.eql(u8, graph.adapter_type, "postgres")) {
        var owned: ?adapter.Session = null;
        defer if (owned) |*session| session.deinit();
        const session = runtime.adapter_session orelse blk: {
            owned = try adapter.openSession(runtime, graph, db_path);
            break :blk &owned.?;
        };
        return session.relationTypeInDatabase(allocator, database, schema, identifier);
    }
    const schema_literal = try adapter.quoteLiteral(allocator, schema);
    defer allocator.free(schema_literal);
    const identifier_literal = try adapter.quoteLiteral(allocator, identifier);
    defer allocator.free(identifier_literal);
    const lookup = try std.fmt.allocPrint(allocator, "select table_type from information_schema.tables where table_schema={s} and table_name={s}", .{ schema_literal, identifier_literal });
    defer allocator.free(lookup);
    var result = try adapter.queryForGraph(runtime, graph, db_path, lookup);
    defer result.deinit(allocator);
    const kind = result.firstScalar() orelse return null;
    return try allocator.dupe(u8, if (std.mem.eql(u8, kind, "VIEW")) "view" else "table");
}

fn postgresOutcome(allocator: std.mem.Allocator, response: *const adapter.QueryResult) !Outcome {
    const tag = response.command_tag orelse return error.InvalidAdapterResponse;
    const message = try allocator.dupe(u8, tag);
    errdefer allocator.free(message);
    var tokens = std.mem.tokenizeScalar(u8, tag, ' ');
    var code: std.ArrayList(u8) = .empty;
    defer code.deinit(allocator);
    var counted = false;
    while (tokens.next()) |token| {
        if (std.fmt.parseInt(u64, token, 10)) |_| {
            counted = true;
            continue;
        } else |_| {}
        if (code.items.len != 0) try code.append(allocator, ' ');
        try code.appendSlice(allocator, token);
    }
    return .{ .message = message, .response = .{ .message = message, .code = try code.toOwnedSlice(allocator), .rows_affected = if (counted) @intCast(response.rows_changed) else -1 }, .owns_response = true };
}
