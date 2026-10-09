const std = @import("std");
const types = @import("types.zig");
const runner = @import("concurrent_runner.zig");
const compiler = @import("compiler.zig");
const commands = @import("commands.zig");
const selector = @import("selector.zig");
const results = @import("run_results.zig");
const clock = @import("execution_clock.zig");
const duckdb = @import("duckdb.zig");
const incremental = @import("incremental.zig");
const incremental_config = @import("incremental_config.zig");

pub const Counts = struct {
    models: usize = 0,
    snapshots: usize = 0,
    analyses: usize = 0,
    tests: usize = 0,
    compiled_base: []const u8,
};

pub fn compile(runtime: types.Runtime, graph: *types.Graph, options: types.Options, selected: []const selector.SelectedResource, target_dir: []const u8, destination: *std.ArrayList(results.NodeResult), events: *std.Io.Writer) !Counts {
    const cache_ids = try runtime.allocator.alloc([]const u8, selected.len);
    defer runtime.allocator.free(cache_ids);
    for (selected, cache_ids) |item, *id| id.* = item.unique_id;
    try @import("relation_cache.zig").configure(runtime, graph, cache_ids);
    defer @import("relation_cache.zig").writeEvents(runtime, graph, events) catch {};
    var resources: std.ArrayList(runner.Resource) = .empty;
    defer resources.deinit(runtime.allocator);
    for (graph.nodes.items) |*node| {
        if (!node.enabled or !contains(selected, node.unique_id)) continue;
        if (std.mem.eql(u8, node.resource_type, "model") or std.mem.eql(u8, node.resource_type, "snapshot") or std.mem.eql(u8, node.resource_type, "analysis") or std.mem.eql(u8, node.resource_type, "operation") or std.mem.eql(u8, node.resource_type, "seed") or std.mem.eql(u8, node.resource_type, "sql_operation")) try resources.append(runtime.allocator, .{ .node = node });
    }
    for (graph.tests.items) |*node| if (node.enabled and contains(selected, node.unique_id)) {
        try resources.append(runtime.allocator, .{ .generic = node });
    };
    for (graph.singular_tests.items) |*node| if (node.enabled and contains(selected, node.unique_id)) {
        try resources.append(runtime.allocator, .{ .singular = node });
    };
    const database_path = duckdb.databasePath(runtime.allocator, target_dir, graph) catch |err| switch (err) {
        error.UnsupportedDuckDbPath => try runtime.allocator.dupe(u8, graph.database_path orelse return err),
        else => return err,
    };
    defer runtime.allocator.free(database_path);
    // Core warms relational schemas before the compilation queue. With no
    // physical schemas or --no-populate-cache, pure compilation stays offline.
    if (options.populate_cache) if (graph.relation_cache) |cache| if (cache.requests.items.len != 0) {
        var session = try @import("adapter.zig").openSession(runtime, graph, database_path);
        session.deinit();
    };
    try std.Io.Dir.cwd().createDirPath(runtime.io, target_dir);
    const summary = try runner.runCompilation(runtime, graph, options, resources.items, database_path, compileResource, events);
    defer runtime.allocator.free(summary.rows);
    var counts: Counts = .{ .compiled_base = try std.fs.path.join(runtime.allocator, &.{ target_dir, "compiled" }) };
    if (options.inject_ephemeral_ctes) try retainEphemeralArtifacts(runtime, graph, counts.compiled_base, summary.rows);
    var transferred: usize = 0;
    defer for (summary.rows[transferred..]) |row| freeResult(runtime.allocator, row);
    for (summary.rows, 0..) |row, index| {
        if (row.compiled_code) |sql| {
            const package, const path = if (row.node) |node| .{ node.package_name, if (std.mem.eql(u8, node.resource_type, "analysis") or std.mem.eql(u8, node.resource_type, "sql_operation")) node.path else node.original_file_path } else if (row.test_node) |node| .{ node.package_name, node.path } else if (row.singular_test_node) |node| .{ node.package_name, node.original_file_path } else unreachable;
            const artifact = if (row.node != null and row.node.?.hook_index != null) try std.fs.path.join(runtime.allocator, &.{ path, row.node.?.path }) else if (row.node != null and std.mem.eql(u8, row.node.?.resource_type, "sql_operation")) try std.fs.path.join(runtime.allocator, &.{ row.node.?.original_file_path, path }) else if (row.node != null and row.node.?.snapshot_yaml_definition) try std.fmt.allocPrint(runtime.allocator, "{s}/{s}.sql", .{ path, row.node.?.name }) else path;
            defer if (row.node != null and (row.node.?.hook_index != null or row.node.?.snapshot_yaml_definition or std.mem.eql(u8, row.node.?.resource_type, "sql_operation"))) runtime.allocator.free(artifact);
            const compiled_path = try std.fs.path.join(runtime.allocator, &.{ counts.compiled_base, package, artifact });
            if (std.fs.path.dirname(compiled_path)) |parent| try std.Io.Dir.cwd().createDirPath(runtime.io, parent);
            try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = compiled_path, .data = row.compiled_artifact_code orelse sql });
            if (row.node) |original| {
                const node = @constCast(original);
                node.compiled = true;
                node.compiled_code = try runtime.allocator.dupe(u8, sql);
                node.compiled_path = compiled_path;
                try compiler.recordPythonScaffoldDependency(runtime.allocator, graph, node);
                if (row.relation_name) |relation| node.relation_name = try runtime.allocator.dupe(u8, relation);
                for (row.compiled_ctes) |cte| try node.extra_ctes.append(runtime.allocator, .{ .id = cte.id, .sql = try runtime.allocator.dupe(u8, cte.sql) });
                if (std.mem.eql(u8, node.resource_type, "analysis")) counts.analyses += 1 else if (std.mem.eql(u8, node.resource_type, "snapshot")) counts.snapshots += 1 else if (node.hook_index == null and !std.mem.eql(u8, node.materialized, "ephemeral")) counts.models += 1;
            } else if (row.test_node) |original| {
                const node = @constCast(original);
                node.compiled = true;
                node.compiled_code = try runtime.allocator.dupe(u8, sql);
                node.compiled_path = compiled_path;
                counts.tests += 1;
            } else if (row.singular_test_node) |original| {
                const node = @constCast(original);
                node.compiled = true;
                node.compiled_code = try runtime.allocator.dupe(u8, sql);
                node.compiled_path = compiled_path;
                counts.tests += 1;
            }
        }
        // Core CompileTask retains ephemeral rows only for an explicit CLI
        // selection. Default compilation and DocsGenerateTask still compile
        // those nodes, but omit them from run_results.
        if (row.node != null and std.mem.eql(u8, row.node.?.materialized, "ephemeral") and
            (!std.mem.eql(u8, options.which, "show") and (!std.mem.eql(u8, options.which, "compile") or options.select == null)))
        {
            freeResult(runtime.allocator, row);
            transferred = index + 1;
            continue;
        }
        try destination.append(runtime.allocator, row);
        transferred = index + 1;
    }
    if (summary.had_execution_error) return error.ExecutionFailure;
    return counts;
}

/// Ephemeral parents compiled inside a dependent node also appear in Core's
/// manifest and compiled directory, without gaining independent result rows.
fn retainEphemeralArtifacts(runtime: types.Runtime, graph: *types.Graph, base: []const u8, rows: []const results.NodeResult) !void {
    const a = runtime.allocator;
    for (rows) |row| for (row.compiled_ctes) |cte| {
        var original: ?*types.Node = null;
        for (graph.nodes.items) |*node| if (std.mem.eql(u8, node.unique_id, cte.id)) {
            original = node;
            break;
        };
        const node = original orelse continue;
        if (node.compiled) continue;
        var directly_selected = false;
        for (rows) |candidate| if (candidate.node) |resource| if (std.mem.eql(u8, resource.unique_id, cte.id)) {
            directly_selected = true;
            break;
        };
        if (directly_selected) continue;
        const open = std.mem.indexOf(u8, cte.sql, " as (\n") orelse continue;
        if (!std.mem.endsWith(u8, cte.sql, "\n)")) continue;
        const body = cte.sql[open + " as (\n".len .. cte.sql.len - 2];
        var parents: std.ArrayList(types.ExtraCte) = .empty;
        defer parents.deinit(a);
        for (row.compiled_ctes) |parent| {
            if (std.mem.eql(u8, parent.id, cte.id)) break;
            if (hasAncestor(graph, node, parent.id, 0)) try parents.append(a, parent);
        }
        node.compiled = true;
        node.compiled_code = if (parents.items.len != 0) try compiler.injectExtraCtes(a, body, parents.items) else try a.dupe(u8, body);
        node.compiled_path = try std.fs.path.join(a, &.{ base, node.package_name, node.original_file_path });
        for (parents.items) |parent| try node.extra_ctes.append(a, .{ .id = parent.id, .sql = try a.dupe(u8, parent.sql) });
        if (std.fs.path.dirname(node.compiled_path.?)) |directory| try std.Io.Dir.cwd().createDirPath(runtime.io, directory);
        try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = node.compiled_path.?, .data = node.compiled_code.? });
    };
}
fn hasAncestor(graph: *const types.Graph, node: *const types.Node, id: []const u8, depth: usize) bool {
    if (depth > graph.nodes.items.len) return false;
    for (node.depends_on.items) |dependency| {
        if (std.mem.eql(u8, dependency, id)) return true;
        for (graph.nodes.items) |*parent| if (std.mem.eql(u8, parent.unique_id, dependency) and hasAncestor(graph, parent, id, depth + 1)) return true;
    }
    return false;
}

fn compileResource(runtime: types.Runtime, graph_readonly: *const types.Graph, resource: runner.Resource, database_path: []const u8, _: []const u8) !results.NodeResult {
    var graph = graph_readonly.*;
    var messages: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer messages.deinit();
    var host = try commands.OperationHost.initLazy(runtime, &graph, database_path, &messages.writer);
    defer host.deinit();
    var log_events: std.ArrayList(results.LogMessage) = .empty;
    defer log_events.deinit(runtime.allocator);
    host.log_events = &log_events;
    graph.execution_hooks = host.host();
    const started = clock.now(runtime.io);
    var row = resource.result("success");
    render(runtime, &graph, resource, database_path, &row) catch |err| {
        row.status = "error";
        row.compiled_override = false;
        row.message = if (@import("compile_diagnostics.zig").message(err)) |message| try runtime.allocator.dupe(u8, message) else try std.fmt.allocPrint(runtime.allocator, "Compilation failed: {s}", .{@errorName(err)});
    };
    row.compile_started_at = started;
    row.compile_completed_at = clock.now(runtime.io);
    if (std.mem.eql(u8, graph.command_options.which, "show") and std.mem.eql(u8, row.status, "success")) {
        @import("sql_operations.zig").preview(runtime, &graph, resource, &row, &host, database_path) catch |err| {
            row.status = "error";
            row.message = if (@import("compile_diagnostics.zig").message(err)) |message| try runtime.allocator.dupe(u8, message) else try std.fmt.allocPrint(runtime.allocator, "Preview query failed: {s}", .{@errorName(err)});
        };
    }
    if (messages.written().len != 0) {
        row.log_output = try runtime.allocator.dupe(u8, messages.written());
        row.owns_log_output = true;
    }
    row.log_events = try log_events.toOwnedSlice(runtime.allocator);
    row.owns_log_events = true;
    // Compilation statements share one transaction. Disconnecting the host
    // rolls it back, including when a later statement raises an error.
    return row;
}

fn render(runtime: types.Runtime, graph: *const types.Graph, resource: runner.Resource, database_path: []const u8, row: *results.NodeResult) !void {
    switch (resource) {
        .node => |original| {
            if (std.mem.eql(u8, original.resource_type, "seed")) return;
            var node = original.*;
            if (std.mem.eql(u8, node.materialized, "incremental")) {
                try incremental_config.validateForAdapter(graph.adapter_type, node.incremental);
                node.runtime_is_incremental = try incremental.isIncremental(runtime, database_path, graph, &node);
            }
            const compiled = try compiler.compileModelWithInjectedCtes(runtime.allocator, graph, &node);
            row.compiled_code = compiled.compiled_code;
            row.owns_compiled_code = true;
            row.compiled_ctes = compiled.extra_ctes.items;
            if (node.hook_index == null and !std.mem.eql(u8, node.materialized, "ephemeral") and !std.mem.eql(u8, node.resource_type, "analysis") and !std.mem.eql(u8, node.resource_type, "sql_operation")) {
                row.relation_name = try compiler.relationNameForNode(runtime.allocator, graph, &node);
                row.owns_relation_name = true;
            }
        },
        .generic => |node| {
            row.compiled_code = try compiler.compileGenericTest(runtime.allocator, graph, node);
            row.owns_compiled_code = true;
        },
        .singular => |node| {
            row.compiled_code = try compiler.compileSingularTest(runtime.allocator, graph, node);
            row.owns_compiled_code = true;
        },
        .unit => unreachable,
    }
}

fn contains(selected: []const selector.SelectedResource, id: []const u8) bool {
    for (selected) |resource| if (std.mem.eql(u8, resource.unique_id, id)) return true;
    return false;
}
fn freeResult(allocator: std.mem.Allocator, row: results.NodeResult) void {
    if (row.owns_compiled_artifact_code) if (row.compiled_artifact_code) |sql| allocator.free(sql);
    if (row.owns_preview) if (row.preview) |preview| allocator.free(preview);
    if (row.owns_adapter_response) if (row.adapter_response) |response| {
        if (response.message) |message| allocator.free(message);
        if (response.code) |code| allocator.free(code);
    };
    if (row.owns_compiled_code) if (row.compiled_code) |sql| allocator.free(sql);
    if (row.owns_relation_name) if (row.relation_name) |relation| allocator.free(relation);
    if (row.message) |message| allocator.free(message);
    if (row.owns_log_output) if (row.log_output) |messages| allocator.free(messages);
    if (row.owns_log_events) {
        for (row.log_events) |entry| allocator.free(entry.message);
        allocator.free(row.log_events);
    }
    if (row.owns_compiled_ctes) {
        for (row.compiled_ctes) |cte| allocator.free(cte.sql);
        allocator.free(row.compiled_ctes);
    }
}
