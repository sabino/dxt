//! Core seeds/helpers.sql: existing views fail; normal runs truncate/reload;
//! full-refresh recreates the table using native CSV inference and overrides.
const std = @import("std");
const types = @import("types.zig");
const adapter = @import("adapter.zig");
const compiler = @import("compiler.zig");
const expression = @import("expression.zig");
const commands = @import("commands.zig");
const values = @import("config_value.zig");

pub fn execute(runtime: types.Runtime, graph: *const types.Graph, path: []const u8, node: *const types.Node) !void {
    return executeWithPolicy(runtime, graph, path, node, .{});
}

pub fn executeWithPolicy(runtime: types.Runtime, graph: *const types.Graph, path: []const u8, node: *const types.Node, policy: @import("postgres_materialization.zig").ExecutionPolicy) !void {
    if (!policy.manage_transaction and runtime.adapter_session == null) return error.NativeAdapterSessionRequired;
    var owned: ?adapter.Session = null;
    defer if (owned) |*session| session.deinit();
    const session = runtime.adapter_session orelse blk: {
        owned = try adapter.openSession(runtime, graph, path);
        break :blk &owned.?;
    };
    const a = runtime.allocator;
    const schema = try compiler.relationSchemaForNode(a, graph, node);
    defer a.free(schema);
    const identifier = compiler.relationIdentifierForNode(node);
    const quoted_schema = try adapter.quoteIdentifier(a, schema);
    defer a.free(quoted_schema);
    const schema_lit = try adapter.quoteLiteral(a, schema);
    defer a.free(schema_lit);
    const identifier_lit = try adapter.quoteLiteral(a, identifier);
    defer a.free(identifier_lit);
    const lookup = try std.fmt.allocPrint(a, "select table_type from information_schema.tables where table_schema={s} and table_name={s}", .{ schema_lit, identifier_lit });
    defer a.free(lookup);
    var existing = try session.query(lookup);
    defer existing.deinit(a);
    const old_kind = existing.firstScalar();
    if (old_kind) |kind| if (std.mem.eql(u8, kind, "VIEW")) return error.CannotSeedView;
    var full_refresh = graph.command_options.full_refresh or graph.full_refresh;
    if (values.get(node.effective_config, "full_refresh")) |flag| if (flag == .bool) {
        full_refresh = flag.bool;
    };
    if (policy.manage_transaction) try session.begin();
    errdefer if (policy.manage_transaction) session.rollback() catch {};
    var held_runtime = runtime;
    held_runtime.adapter_session = session;
    var runtime_graph = graph.*;
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var local_host: ?commands.OperationHost = null;
    defer if (local_host) |*host| host.deinit();
    if (runtime_graph.execution_hooks == null) {
        local_host = try commands.OperationHost.initBorrowedTransaction(held_runtime, &runtime_graph, path, &output.writer);
        runtime_graph.execution_hooks = local_host.?.host();
    }
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    const temporary = scratch.allocator();
    const create_schema = try std.fmt.allocPrint(temporary, "create schema if not exists {s}", .{quoted_schema});
    try session.execute(create_schema);
    const model = try @import("context_values.zig").model(temporary, &runtime_graph, node);
    const table = try compiler.renderMacroForNode(temporary, &runtime_graph, node, "load_agate_table", &.{});
    const create_sql = if (old_kind == null)
        try compiler.renderMacroForNode(temporary, &runtime_graph, node, "create_csv_table", &.{ .{ .name = "model", .value = model }, .{ .name = "agate_table", .value = table } })
    else blk: {
        var old = try @import("dbt_context.zig").relationFromValue(temporary, try compiler.relationValueForNode(temporary, &runtime_graph, node, false));
        old.relation_type = "table";
        break :blk try compiler.renderMacroForNode(temporary, &runtime_graph, node, "reset_csv_table", &.{ .{ .name = "model", .value = model }, .{ .name = "full_refresh", .value = .{ .boolean = full_refresh } }, .{ .name = "old_relation", .value = try @import("dbt_context.zig").relationValue(temporary, old) }, .{ .name = "agate_table", .value = table } });
    };
    const insert_sql = try compiler.renderMacroForNode(temporary, &runtime_graph, node, "load_csv_rows", &.{ .{ .name = "model", .value = model }, .{ .name = "agate_table", .value = table } });
    const sql = try compiler.renderMacroForNode(temporary, &runtime_graph, node, "get_csv_sql", &.{ .{ .name = "create_or_truncate_sql", .value = create_sql }, .{ .name = "insert_sql", .value = insert_sql } });
    if (sql != .string) return error.InvalidSeedSql;
    const rows = expression.sequence(table.attribute("rows")) orelse return error.InvalidAgateTable;
    try @import("materialization_result.zig").captureSeed(a, policy.main_result, full_refresh, rows.len);
    // Core noop_statement('main') writes only after the actual load succeeds.
    try @import("stock_artifacts.zig").write(policy.artifact_writer, node, sql.string);
    if (policy.manage_transaction) try session.commit();
}
