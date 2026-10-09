//! Native per-batch orchestration. Every batch owns a warehouse transaction;
//! completed batches remain committed when a later batch fails.
const std = @import("std");
const types = @import("types.zig");
const adapter = @import("adapter.zig");
const compiler = @import("compiler.zig");
const commands = @import("commands.zig");
const config = @import("incremental_config.zig");
const incremental = @import("incremental.zig");
const microbatch = @import("microbatch.zig");
const values = @import("config_value.zig");
const results = @import("run_results.zig");
const inputs = @import("input_relations.zig");
const dbt_context = @import("dbt_context.zig");
const expression = @import("expression.zig");

pub const BatchExecutor = *const fn (types.Runtime, *const types.Graph, *const types.Node, *adapter.Session) anyerror!void;

pub fn execute(runtime: types.Runtime, graph: *const types.Graph, node: *const types.Node, db_path: []const u8, custom_executor: ?BatchExecutor) !results.NodeResult {
    const batch_config = try microbatch.configuration(node);
    var owned_session: ?adapter.Session = null;
    defer if (owned_session) |*session| session.deinit();
    const session = runtime.adapter_session orelse blk: {
        owned_session = try adapter.openSession(runtime, graph, db_path);
        break :blk &owned_session.?;
    };
    const schema = try compiler.relationSchemaForNode(runtime.allocator, graph, node);
    defer runtime.allocator.free(schema);
    const kind = try session.relationTypeInDatabase(runtime.allocator, compiler.relationDatabaseForNode(graph, node), schema, compiler.relationIdentifierForNode(node));
    defer if (kind) |value| runtime.allocator.free(value);
    var incremental_batch = kind != null and std.mem.eql(u8, kind.?, "table") and !config.fullRefresh(graph, node);
    if (strategyMacro(graph, node) != null and !graph.require_batched_execution_for_custom_microbatch_strategy) {
        // Core retains legacy, unbatched user strategy execution unless the
        // project explicitly opts into its batched execution behavior.
        var unbatched = node.*;
        unbatched.runtime_is_incremental = incremental_batch;
        var compiled = try compiler.compileModelWithInjectedCtes(runtime.allocator, graph, &unbatched);
        errdefer compiled.deinit(runtime.allocator);
        unbatched.compiled_code = compiled.compiled_code;
        const executor = custom_executor orelse executeBatch;
        try executor(runtime, graph, &unbatched, session);
        return .{ .node = node, .compiled_code = compiled.compiled_code, .owns_compiled_code = true, .compiled_ctes = try compiled.extra_ctes.toOwnedSlice(runtime.allocator), .owns_compiled_ctes = true };
    }
    const previous = try previousBatches(runtime.allocator, graph.command_options, node.unique_id);
    defer if (previous) |prior| prior.deinit(runtime.allocator);
    const batches = if (previous) |prior| prior.failed else try microbatch.batches(runtime, graph, batch_config, incremental_batch);
    defer if (previous == null) runtime.allocator.free(batches);
    var successful: std.ArrayList(types.SampleWindow) = .empty;
    errdefer successful.deinit(runtime.allocator);
    var failed: std.ArrayList(types.SampleWindow) = .empty;
    errdefer failed.deinit(runtime.allocator);
    var compiled_ctes: std.ArrayList(types.ExtraCte) = .empty;
    errdefer deinitCtes(runtime.allocator, &compiled_ctes);
    var compiled_code: ?[]const u8 = null;
    errdefer if (compiled_code) |sql| runtime.allocator.free(sql);
    var skip_remaining = false;
    for (batches, 0..) |batch, index| {
        if (skip_remaining) {
            try failed.append(runtime.allocator, batch);
            continue;
        }
        var arena = std.heap.ArenaAllocator.init(runtime.allocator);
        defer arena.deinit();
        var batch_runtime = runtime;
        batch_runtime.allocator = arena.allocator();
        batch_runtime.adapter_session = session;
        var batch_graph = graph.*;
        var batch_node = node.*;
        batch_node.runtime_batch = batch;
        batch_node.runtime_batch_id = try microbatch.batchId(batch_runtime.allocator, batch.start, batch_config.batch_size);
        batch_node.runtime_is_incremental = incremental_batch;
        if (incremental_batch) {
            batch_graph.full_refresh = false;
            batch_graph.command_options.full_refresh = false;
            batch_node.incremental.full_refresh = false;
        }
        var output: std.Io.Writer.Allocating = .init(batch_runtime.allocator);
        var host = try commands.OperationHost.init(batch_runtime, &batch_graph, db_path, &output.writer);
        defer host.deinit();
        batch_graph.execution_hooks = host.host();
        const compiled = compiler.compileModelWithInjectedCtes(batch_runtime.allocator, &batch_graph, &batch_node) catch {
            try failed.append(runtime.allocator, batch);
            if (index == 0 or graph.command_options.fail_fast) skip_remaining = true;
            continue;
        };
        batch_node.compiled_code = compiled.compiled_code;
        batch_node.compiled = true;
        deinitCtes(runtime.allocator, &compiled_ctes);
        compiled_ctes = .empty;
        for (compiled.extra_ctes.items) |cte| try compiled_ctes.append(runtime.allocator, .{ .id = cte.id, .sql = try runtime.allocator.dupe(u8, cte.sql) });
        if (compiled_code) |sql| runtime.allocator.free(sql);
        compiled_code = try runtime.allocator.dupe(u8, compiled.compiled_code);
        host.commit() catch {
            try failed.append(runtime.allocator, batch);
            if (index == 0 or graph.command_options.fail_fast) skip_remaining = true;
            continue;
        };
        const executor = custom_executor orelse executeBatch;
        executor(batch_runtime, &batch_graph, &batch_node, session) catch {
            session.rollback() catch {};
            try failed.append(runtime.allocator, batch);
            if (index == 0 or graph.command_options.fail_fast) skip_remaining = true;
            continue;
        };
        try successful.append(runtime.allocator, batch);
        incremental_batch = true;
    }
    const status = if (failed.items.len == 0) "success" else if (successful.items.len == 0) "error" else "partial success";
    const message = if (failed.items.len == 0) try runtime.allocator.dupe(u8, "SUCCESS") else if (successful.items.len == 0) try runtime.allocator.dupe(u8, "ERROR") else try std.fmt.allocPrint(runtime.allocator, "PARTIAL SUCCESS ({d}/{d})", .{ successful.items.len, batches.len });
    if (previous) |prior| try successful.appendSlice(runtime.allocator, prior.successful);
    return .{ .node = node, .status = status, .message = message, .failures = 0, .compiled_code = compiled_code, .owns_compiled_code = compiled_code != null, .compiled_ctes = try compiled_ctes.toOwnedSlice(runtime.allocator), .owns_compiled_ctes = true, .batch_results = .{ .successful = try successful.toOwnedSlice(runtime.allocator), .failed = try failed.toOwnedSlice(runtime.allocator) }, .owns_batch_results = true };
}

fn deinitCtes(a: std.mem.Allocator, ctes: *std.ArrayList(types.ExtraCte)) void {
    for (ctes.items) |cte| a.free(cte.sql);
    ctes.deinit(a);
}

fn previousBatches(a: std.mem.Allocator, options: types.Options, id: []const u8) !?results.BatchResults {
    const mapping = options.microbatch_retry_results orelse return null;
    if (mapping != .object) return error.MalformedRunResultsArtifact;
    const previous = mapping.object.get(id) orelse return null;
    if (previous != .object) return error.MalformedRunResultsArtifact;
    var parsed: results.BatchResults = .{};
    errdefer parsed.deinit(a);
    inline for (.{ "successful", "failed" }) |key| {
        const raw = previous.object.get(key) orelse return error.MalformedRunResultsArtifact;
        if (raw != .array) return error.MalformedRunResultsArtifact;
        const intervals = try a.alloc(types.SampleWindow, raw.array.items.len);
        @field(parsed, key) = intervals;
        for (raw.array.items, intervals) |pair, *interval| {
            if (pair != .array or pair.array.items.len != 2 or pair.array.items[0] != .string or pair.array.items[1] != .string) return error.MalformedRunResultsArtifact;
            interval.* = .{ .start = inputs.parseDate(pair.array.items[0].string, true) catch return error.MalformedRunResultsArtifact, .end = inputs.parseDate(pair.array.items[1].string, true) catch return error.MalformedRunResultsArtifact };
        }
    }
    return parsed;
}

pub fn executeBatch(runtime: types.Runtime, graph: *const types.Graph, node: *const types.Node, session: *adapter.Session) !void {
    const a = runtime.allocator;
    const schema = try compiler.relationSchemaForNode(a, graph, node);
    const quoted_schema = try compiler.quoteIdentifier(a, schema);
    const target = try compiler.relationNameForNode(a, graph, node);
    const compiled = std.mem.trimEnd(u8, node.compiled_code orelse return error.UnsupportedModelExecution, " \t\r\n;");
    try session.begin();
    errdefer session.rollback() catch {};
    try session.execute(try std.fmt.allocPrint(a, "create schema if not exists {s}", .{quoted_schema}));
    if (!node.runtime_is_incremental) {
        const kind = try session.relationTypeInDatabase(a, compiler.relationDatabaseForNode(graph, node), schema, compiler.relationIdentifierForNode(node));
        if (kind) |value| {
            const drop = if (std.mem.eql(u8, value, "view")) "view" else if (std.mem.eql(u8, value, "materialized_view")) "materialized view" else "table";
            try session.execute(try std.fmt.allocPrint(a, "drop {s} {s}", .{ drop, target }));
        }
        try session.execute(try std.fmt.allocPrint(a, "create table {s} as ({s})", .{ target, compiled }));
        try session.commit();
        return;
    }
    if (std.mem.eql(u8, graph.adapter_type, "duckdb") and strategyMacro(graph, node) != null and !(graph.adapter_require_batched_execution_for_custom_microbatch_strategy orelse graph.require_batched_execution_for_custom_microbatch_strategy)) return error.UnsupportedIncrementalStrategy;
    const stage = "\"__dxt_microbatch_stage\"";
    try session.execute(try std.fmt.allocPrint(a, "create temporary table {s} as ({s})", .{ stage, compiled }));
    const source_columns = try columns(a, graph.adapter_type, session, true, schema, compiler.relationIdentifierForNode(node));
    const target_columns = try columns(a, graph.adapter_type, session, false, schema, compiler.relationIdentifierForNode(node));
    var native_config = node.incremental;
    native_config.strategy = "append";
    const update = try incremental.renderUpdateSql(a, target, stage, source_columns, target_columns, native_config, false);
    const insert_at = std.mem.indexOf(u8, update, "insert into ") orelse return error.InvalidMicrobatchSql;
    const custom = strategyMacro(graph, node);
    if (insert_at != 0 and (custom != null or std.mem.eql(u8, graph.adapter_type, "postgres"))) try session.execute(update[0..insert_at]);
    const destination = if (std.mem.eql(u8, config.schemaPolicy(native_config), "ignore")) target_columns else source_columns;
    if (custom) |macro_name| {
        const dest = try a.alloc(expression.Value, destination.len);
        for (destination, dest) |column, *item| item.* = try dbt_context.columnValue(a, .{ .adapter_type = graph.adapter_type, .column = column.column_name, .dtype = column.data_type });
        const arg_dict: expression.Value = .{ .object = try a.dupe(expression.Entry, &.{
            .{ .key = "target_relation", .value = try dbt_context.relationValue(a, .{ .adapter_type = graph.adapter_type, .database = compiler.relationDatabaseForNode(graph, node), .schema = schema, .identifier = compiler.relationIdentifierForNode(node), .relation_type = "table" }) },
            .{ .key = "temp_relation", .value = try dbt_context.relationValue(a, .{ .adapter_type = graph.adapter_type, .identifier = "__dxt_microbatch_stage", .relation_type = "table" }) },
            .{ .key = "unique_key", .value = try values.toExpression(a, values.get(node.effective_config, "unique_key") orelse .null) },
            .{ .key = "incremental_predicates", .value = try values.toExpression(a, values.get(node.effective_config, "predicates") orelse values.get(node.effective_config, "incremental_predicates") orelse .null) },
            .{ .key = "dest_columns", .value = .{ .list = dest } },
        }) };
        const rendered = try compiler.renderMacroForNode(a, graph, node, macro_name, &.{.{ .name = "arg_dict", .value = arg_dict }});
        try session.execute(try rendered.text(a));
    } else if (std.mem.eql(u8, graph.adapter_type, "postgres")) {
        const key = node.incremental.unique_key orelse return error.MicrobatchRequiresUniqueKey;
        switch (key) {
            .string => |name| if (name.len == 0) return error.MicrobatchRequiresUniqueKey,
            .list => |keys| if (keys.items.len == 0) return error.MicrobatchRequiresUniqueKey,
        }
        try session.execute(try @import("postgres_incremental.zig").renderMergeSql(a, graph, node, target, stage, destination));
    } else {
        native_config.strategy = "delete+insert";
        const sql = try incremental.renderUpdateSql(a, target, stage, source_columns, target_columns, native_config, false);
        // Its native incremental helper includes stage cleanup and COMMIT. The
        // microbatch owner commits exactly once after strategy SQL succeeds.
        const body = std.mem.trimEnd(u8, sql, " \t\r\n");
        if (!std.mem.endsWith(u8, body, "commit;")) return error.InvalidMicrobatchSql;
        try session.execute(body[0 .. body.len - "commit;".len]);
        try session.commit();
        return;
    }
    try session.execute(try std.fmt.allocPrint(a, "drop table {s}", .{stage}));
    try session.commit();
}

fn strategyMacro(graph: *const types.Graph, node: *const types.Node) ?[]const u8 {
    // Root-project overrides precede package-local and installed dependency macros.
    for ([_][]const u8{ graph.project_name, node.package_name }) |package| for (graph.macros.items) |macro| {
        if (std.mem.eql(u8, macro.package_name, package) and std.mem.eql(u8, macro.name, "get_incremental_microbatch_sql")) return macro.name;
    };
    for (graph.macros.items) |macro| {
        if (std.mem.eql(u8, macro.name, "get_incremental_microbatch_sql") and !std.mem.eql(u8, macro.package_name, "dbt") and !std.mem.eql(u8, macro.package_name, "dbt_postgres") and !std.mem.eql(u8, macro.package_name, "dbt_duckdb")) return macro.name;
    }
    return null;
}

fn columns(a: std.mem.Allocator, dialect: []const u8, session: *adapter.Session, stage: bool, schema: []const u8, identifier: []const u8) ![]incremental.Column {
    var result = if (stage and std.mem.eql(u8, dialect, "duckdb")) try session.query("describe select * from \"__dxt_microbatch_stage\"") else if (stage) try session.query("select a.attname,pg_catalog.format_type(a.atttypid,a.atttypmod) from pg_catalog.pg_attribute a where a.attrelid=pg_catalog.to_regclass('\"__dxt_microbatch_stage\"') and a.attnum>0 and not a.attisdropped order by a.attnum") else try session.columns(a, schema, identifier);
    defer result.deinit(a);
    const output = try a.alloc(incremental.Column, result.rows.len);
    for (result.rows, output) |row, *column| {
        if (row.len < 2 or row[0] == null or row[1] == null) return error.InvalidAdapterIntrospection;
        column.* = .{ .column_name = try a.dupe(u8, row[0].?), .data_type = try a.dupe(u8, row[1].?) };
    }
    return output;
}
