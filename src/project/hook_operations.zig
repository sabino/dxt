//! Project hooks are graph operations, compiled normally and executed on the
//! main connection outside each resource's transaction.
const std = @import("std");
const types = @import("types.zig");
const compiler = @import("compiler.zig");
const commands = @import("commands.zig");
const adapter = @import("adapter.zig");
const values = @import("config_value.zig");
const results = @import("run_results.zig");
const clock = @import("execution_clock.zig");
const expression = @import("expression.zig");

pub fn load(runtime: types.Runtime, graph: *types.Graph) !void {
    for (graph.semantic_project_configs.items) |project| {
        if (std.mem.eql(u8, project.package_name, graph.project_name)) {
            if (values.get(project.raw, "flags")) |flags| {
                if (values.get(flags, "skip_nodes_if_on_run_start_fails")) |flag| {
                    if (flag != .bool) return error.InvalidProjectConfig;
                    graph.skip_nodes_if_on_run_start_fails = flag.bool;
                }
            }
        }
        for ([_][]const u8{ "on-run-start", "on-run-end" }) |stage| {
            const configured = values.get(project.rendered, stage) orelse continue;
            if (configured == .null) continue;
            const hooks: []const std.json.Value = if (configured == .array) configured.array.items else &.{configured};
            for (hooks, 0..) |hook, index| {
                if (hook != .string) return error.InvalidHookConfiguration;
                const a = runtime.allocator;
                const name = try std.fmt.allocPrint(a, "{s}-{s}-{d}", .{ project.package_name, stage, index });
                var node: types.Node = .{
                    .resource_type = "operation",
                    .package_name = project.package_name,
                    .unique_id = try std.fmt.allocPrint(a, "operation.{s}.{s}", .{ project.package_name, name }),
                    .name = name,
                    .path = try std.fmt.allocPrint(a, "hooks/{s}.sql", .{name}),
                    .original_file_path = "./dbt_project.yml",
                    .raw_code = try a.dupe(u8, hook.string),
                    .hook_index = index,
                    .hook_checksum = project.file_checksum,
                };
                errdefer types.deinitNode(a, &node);
                try node.tags.append(a, stage);
                try compiler.scanDependencies(a, node.raw_code, &node, graph);
                try graph.nodes.append(a, node);
            }
        }
    }
}

fn less(graph: *const types.Graph, left: *types.Node, right: *types.Node) bool {
    const root_package_lhs = std.mem.eql(u8, left.package_name, graph.project_name);
    const root_package_rhs = std.mem.eql(u8, right.package_name, graph.project_name);
    if (root_package_lhs != root_package_rhs) return !root_package_lhs;
    const package_order = std.mem.order(u8, left.package_name, right.package_name);
    if (package_order != .eq) return package_order == .lt;
    return left.hook_index.? < right.hook_index.?;
}

/// The caller owns the returned SQL. Core accepts a JSON hook dictionary as
/// well as ordinary SQL, even for project hooks whose execution is autocommit.
fn executableSql(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch return a.dupe(u8, text);
    defer parsed.deinit();
    if (parsed.value != .object) return a.dupe(u8, text);
    const sql = parsed.value.object.get("sql") orelse return error.InvalidHookConfiguration;
    if (sql != .string) return error.InvalidHookConfiguration;
    return a.dupe(u8, sql.string);
}

pub fn run(runtime: types.Runtime, graph: *types.Graph, session: *adapter.Session, db_path: []const u8, target_dir: []const u8, stage: []const u8, destination: *std.ArrayList(results.NodeResult), events: *std.Io.Writer, context_rows: ?[]const results.NodeResult) !bool {
    var hooks: std.ArrayList(*types.Node) = .empty;
    defer hooks.deinit(runtime.allocator);
    for (graph.nodes.items) |*node| {
        if (!node.enabled or node.hook_index == null) continue;
        for (node.tags.items) |tag| if (std.mem.eql(u8, tag, stage)) {
            try hooks.append(runtime.allocator, node);
            break;
        };
    }
    if (hooks.items.len == 0) return false;
    std.mem.sort(*types.Node, hooks.items, @as(*const types.Graph, graph), less);
    var extra: std.json.Value = .null;
    if (std.mem.eql(u8, stage, "on-run-end")) extra = try endContext(runtime.allocator, graph, context_rows orelse destination.items);
    defer values.deinit(runtime.allocator, &extra);
    var failed = false;
    for (hooks.items, 1..) |node, ordinal| {
        node.hook_index = ordinal;
        const label = try std.fmt.allocPrint(runtime.allocator, "{s}.{s}.{d}", .{ node.package_name, stage, ordinal - 1 });
        defer runtime.allocator.free(label);
        var row: results.NodeResult = .{ .node = node, .thread_name = "main", .failures = 1 };
        if (failed) {
            row.status = "skipped";
            row.message = try std.fmt.allocPrint(runtime.allocator, "{s} skipped", .{label});
            try destination.append(runtime.allocator, row);
            continue;
        }
        var held = runtime;
        held.adapter_session = session;
        var local_graph = graph.*;
        var host = try commands.OperationHost.initLazy(held, &local_graph, db_path, events);
        defer host.deinit();
        host.context_values = extra;
        local_graph.execution_hooks = host.host();
        const started = std.Io.Timestamp.now(runtime.io, .awake);
        row.compile_started_at = clock.now(runtime.io);
        const compiled = compiler.renderTextForNode(runtime.allocator, &local_graph, node, node.raw_code) catch |err| {
            row.status = "error";
            row.compiled_override = false;
            row.compile_completed_at = clock.now(runtime.io);
            row.message = try runtime.allocator.dupe(u8, @import("compile_diagnostics.zig").message(err) orelse @errorName(err));
            failed = true;
            try destination.append(runtime.allocator, row);
            continue;
        };
        row.compile_completed_at = clock.now(runtime.io);
        // A compile-time run_query may open a transaction. Project hook SQL
        // itself must execute outside it, as Core clear_transaction requires.
        try host.commit();
        node.compiled = true;
        node.compiled_code = compiled;
        node.compiled_path = try std.fs.path.join(runtime.allocator, &.{ target_dir, "compiled", node.package_name, node.original_file_path, node.path });
        if (std.fs.path.dirname(node.compiled_path.?)) |parent| try std.Io.Dir.cwd().createDirPath(runtime.io, parent);
        try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = node.compiled_path.?, .data = compiled });
        row.compiled_code = try runtime.allocator.dupe(u8, compiled);
        row.owns_compiled_code = true;
        row.execution_started_at = clock.now(runtime.io);
        const sql = try executableSql(runtime.allocator, compiled);
        defer runtime.allocator.free(sql);
        if (std.mem.trim(u8, sql, " \t\r\n").len != 0) session.execute(sql) catch |err| {
            row.status = "error";
            row.message = try std.fmt.allocPrint(runtime.allocator, "{s} failed, error:\n {s}", .{ label, session.lastError() orelse @errorName(err) });
            failed = true;
            // PostgreSQL may have been left in an explicit aborted transaction
            // by authored SQL. Release it before the remaining task lifecycle.
            session.rollback() catch {};
        };
        row.execution_completed_at = clock.now(runtime.io);
        row.execution_time = @as(f64, @floatFromInt(started.durationTo(std.Io.Timestamp.now(runtime.io, .awake)).nanoseconds)) / std.time.ns_per_s;
        if (!failed) {
            row.failures = 0;
            row.message = try std.fmt.allocPrint(runtime.allocator, "{s} passed", .{label});
        }
        try destination.append(runtime.allocator, row);
    }
    return failed;
}

fn endContext(a: std.mem.Allocator, graph: *const types.Graph, rows: []const results.NodeResult) !std.json.Value {
    const text = try results.renderRunResults(a, rows);
    defer a.free(text);
    const document = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer document.deinit();
    const manifest_text = try @import("manifest.zig").renderManifest(a, graph);
    defer a.free(manifest_text);
    const manifest = try std.json.parseFromSlice(std.json.Value, a, manifest_text, .{});
    defer manifest.deinit();
    var context: std.json.Value = .{ .object = .empty };
    errdefer values.deinit(a, &context);
    var projected: std.json.Value = .{ .array = std.json.Array.init(a) };
    var schemas: std.json.Value = .{ .array = std.json.Array.init(a) };
    var database_schemas: std.json.Value = .{ .array = std.json.Array.init(a) };
    defer values.deinit(a, &projected);
    defer values.deinit(a, &schemas);
    defer values.deinit(a, &database_schemas);
    for (rows, document.value.object.get("results").?.array.items) |row, serialized| {
        const operation = row.node != null and row.node.?.hook_index != null;
        if (!operation or std.mem.eql(u8, row.status, "error")) {
            var result = try values.clone(a, serialized);
            const id = serialized.object.get("unique_id").?.string;
            if (manifest.value.object.get("nodes").?.object.get(id)) |node| try values.put(a, &result, "node", node);
            try projected.array.append(result);
        }
        if (operation or row.node == null or !std.mem.eql(u8, row.status, "success") or std.mem.eql(u8, row.node.?.materialized, "ephemeral")) continue;
        const node = row.node.?;
        const schema = try compiler.relationSchemaForNode(a, graph, node);
        defer a.free(schema);
        var found = false;
        for (schemas.array.items) |item| if (std.mem.eql(u8, item.string, schema)) {
            found = true;
            break;
        };
        if (!found) try schemas.array.append(try values.clone(a, .{ .string = schema }));
        const database = compiler.relationDatabaseForNode(graph, node) orelse if (values.get(graph.target_context, "database")) |name| name.string else "";
        found = false;
        for (database_schemas.array.items) |item| if (std.mem.eql(u8, item.array.items[0].string, database) and std.mem.eql(u8, item.array.items[1].string, schema)) {
            found = true;
            break;
        };
        if (!found) {
            var pair: std.json.Value = .{ .array = std.json.Array.init(a) };
            try pair.array.append(try values.clone(a, .{ .string = database }));
            try pair.array.append(try values.clone(a, .{ .string = schema }));
            try database_schemas.array.append(pair);
        }
    }
    try values.put(a, &context, "results", projected);
    try values.put(a, &context, "schemas", schemas);
    try values.put(a, &context, "database_schemas", database_schemas);
    return context;
}

pub fn resolve(a: std.mem.Allocator, context: std.json.Value, path: []const u8) !expression.Value {
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const base = path[0 .. dot orelse path.len];
    const json_value = values.get(context, base) orelse return .undefined;
    var value = try values.toExpression(a, json_value);
    if (std.mem.eql(u8, base, "database_schemas") and value == .list) {
        for (@constCast(value.list)) |*pair| pair.* = .{ .tuple = pair.list };
    }
    if (dot) |position| {
        var attributes = std.mem.splitScalar(u8, path[position + 1 ..], '.');
        while (attributes.next()) |attribute| value = value.attribute(attribute);
    }
    return value;
}
