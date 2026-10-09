//! Resource hooks run on the same native connection as the materialization.
//! Transactional hook failures roll back the replacement and all inner hooks.
const std = @import("std");
const types = @import("types.zig");
const adapter = @import("adapter.zig");
const commands = @import("commands.zig");
const compiler = @import("compiler.zig");
const duckdb = @import("duckdb.zig");
const values = @import("config_value.zig");

pub const BodyExecutor = struct {
    context: *anyopaque,
    execute: *const fn (*anyopaque, types.Runtime, *const types.Graph, *const types.Node, []const u8, duckdb.ExecutionPolicy) anyerror!void,
    materialized: ?[]const u8 = null,
};

pub fn execute(runtime: types.Runtime, db_path: []const u8, graph: *const types.Graph, node: *const types.Node) !void {
    if (try executeReturning(runtime, db_path, graph, node)) |result| result.deinit(runtime.allocator);
}

pub fn executeReturning(runtime: types.Runtime, db_path: []const u8, graph: *const types.Graph, node: *const types.Node) !?@import("materialization_result.zig").Result {
    if (try @import("custom_materialization.zig").custom(graph, node)) |macro| return try @import("custom_materialization.zig").execute(runtime, db_path, graph, node, macro);
    var marker: u8 = 0;
    try executeWithBody(runtime, db_path, graph, node, .{ .context = &marker, .execute = stockBody });
    return null;
}

pub fn executeWithBody(runtime: types.Runtime, db_path: []const u8, graph: *const types.Graph, node: *const types.Node, body: BodyExecutor) !void {
    var owned: ?adapter.Session = null;
    defer if (owned) |*session| session.deinit();
    var held_runtime = runtime;
    if (held_runtime.adapter_session == null) {
        owned = try adapter.openSession(runtime, graph, db_path);
        held_runtime.adapter_session = &owned.?;
    }
    var runtime_graph = graph.*;
    var output: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer output.deinit();
    var host = try commands.OperationHost.init(held_runtime, &runtime_graph, db_path, &output.writer);
    defer host.deinit();
    var journal = @import("materialization_journal.zig").Journal.init(runtime.allocator, runtime.io);
    defer journal.deinit();
    errdefer switch (held_runtime.adapter_session.?.*) {
        .duckdb => |connection| if (connection.disable_transactions) journal.autocommitFailure() catch {},
        else => {},
    };
    host.log_events = graph.log_collector;
    runtime_graph.execution_hooks = host.host();
    var scratch = std.heap.ArenaAllocator.init(runtime.allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    const config = try @import("canonical_manifest_config.zig").node(allocator, node);
    const materialized = body.materialized orelse if (std.mem.eql(u8, node.resource_type, "seed") or std.mem.eql(u8, node.resource_type, "snapshot")) "table" else node.materialized;
    var target = try @import("dbt_context.zig").relationFromValue(allocator, try compiler.relationValueForNode(allocator, graph, node, false));
    target.relation_type = if (std.mem.eql(u8, materialized, "view") or std.mem.eql(u8, materialized, "materialized_view")) materialized else if (std.mem.eql(u8, materialized, "external") or std.mem.eql(u8, materialized, "table_function")) "view" else "table";
    const existing_type = try held_runtime.adapter_session.?.relationTypeInDatabase(allocator, target.database, target.schema.?, target.identifier.?);
    var existing: @import("expression.zig").Value = .none;
    if (existing_type) |kind| {
        var definition = target;
        definition.relation_type = kind;
        existing = try @import("dbt_context.zig").relationValue(allocator, definition);
    }
    try runHooks(allocator, &runtime_graph, node, config, "pre-hook", false);
    try host.begin();
    errdefer host.rollback() catch {};
    try runHooks(allocator, &runtime_graph, node, config, "pre-hook", true);
    if (@import("contracts.zig").enforced(node)) _ = try compiler.renderMacroForNode(allocator, &runtime_graph, node, "get_assert_columns_equivalent", &.{.{ .name = "sql", .value = .{ .string = duckdb.trimTrailingSqlTerminator(node.compiled_code orelse return error.UnsupportedModelExecution) } }});
    try body.execute(body.context, held_runtime, &runtime_graph, node, db_path, .{ .manage_transaction = false, .file_effects = &journal });
    const post_hooks_first = std.mem.eql(u8, node.resource_type, "model") and std.mem.eql(u8, materialized, "table");
    if (post_hooks_first) try runHooks(allocator, &runtime_graph, node, config, "post-hook", true);
    try applyRelationConfig(allocator, &runtime_graph, node, config, target, existing, materialized);
    if (!post_hooks_first) try runHooks(allocator, &runtime_graph, node, config, "post-hook", true);
    try journal.publish();
    try host.commit();
    try journal.finalize();
    try runHooks(allocator, &runtime_graph, node, config, "post-hook", false);
}

fn applyRelationConfig(allocator: std.mem.Allocator, graph: *const types.Graph, node: *const types.Node, config: std.json.Value, target: @import("dbt_context.zig").RelationDef, existing: @import("expression.zig").Value, materialized: []const u8) !void {
    const expression = @import("expression.zig");
    const relation = try @import("dbt_context.zig").relationValue(allocator, target);
    const replacing: expression.Value = if (std.mem.eql(u8, node.resource_type, "snapshot")) .{ .boolean = false } else if (std.mem.eql(u8, materialized, "table") and std.mem.eql(u8, node.resource_type, "model") or std.mem.eql(u8, materialized, "view") or std.mem.eql(u8, materialized, "materialized_view")) .{ .boolean = true } else try compiler.renderMacroForNode(allocator, graph, node, "should_full_refresh", &.{});
    const revoke = try compiler.renderMacroForNode(allocator, graph, node, "should_revoke", &.{ .{ .name = "existing_relation", .value = existing }, .{ .name = "full_refresh_mode", .value = replacing } });
    _ = try compiler.renderMacroForNode(allocator, graph, node, "apply_grants", &.{
        .{ .name = "relation", .value = relation },
        .{ .name = "grant_config", .value = try values.toExpression(allocator, values.get(config, "grants") orelse .null) },
        .{ .name = "should_revoke", .value = revoke },
    });
    _ = try compiler.renderMacroForNode(allocator, graph, node, "persist_docs", &.{ .{ .name = "relation", .value = relation }, .{ .name = "model", .value = try @import("context_values.zig").model(allocator, graph, node) } });
}

fn runHooks(allocator: std.mem.Allocator, graph: *const types.Graph, node: *const types.Node, config: std.json.Value, name: []const u8, inside: bool) !void {
    const hooks = values.get(config, name) orelse return;
    const args = [_]@import("expression.zig").Argument{
        .{ .name = "hooks", .value = try values.toExpression(allocator, hooks) },
        .{ .name = "inside_transaction", .value = .{ .boolean = inside } },
    };
    _ = try compiler.renderMacroForNode(allocator, graph, node, "run_hooks", &args);
}

fn stockBody(_: *anyopaque, runtime: types.Runtime, graph: *const types.Graph, node: *const types.Node, db_path: []const u8, policy: duckdb.ExecutionPolicy) anyerror!void {
    if (std.mem.eql(u8, node.resource_type, "seed")) return duckdb.executeSeedWithPolicy(runtime, db_path, graph.command_options.project_dir, graph, node, policy);
    if (std.mem.eql(u8, node.resource_type, "snapshot")) return @import("snapshot_runner.zig").executeWithPolicy(runtime, db_path, graph, node, policy);
    return duckdb.executeModelWithPolicy(runtime, db_path, graph, node, policy);
}
