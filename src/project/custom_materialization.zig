//! Core Manifest materialization specificity precedes package locality.
//! Authored macros own their SQL transactions and lifecycle hooks.
const std = @import("std");
const types = @import("types.zig");
const compiler = @import("compiler.zig");
const commands = @import("commands.zig");
const adapter = @import("adapter.zig");
const expression = @import("expression.zig");
const values = @import("config_value.zig");
const Result = @import("materialization_result.zig").Result;

fn corePackage(name: []const u8) bool {
    return std.mem.eql(u8, name, "dbt") or std.mem.eql(u8, name, "dbt_duckdb") or std.mem.eql(u8, name, "dbt_postgres");
}

fn explicitOverrides(graph: *const types.Graph) bool {
    for (graph.semantic_project_configs.items) |config| {
        if (!std.mem.eql(u8, config.package_name, graph.project_name)) continue;
        const flags = values.get(config.rendered, "flags") orelse continue;
        const value = values.get(flags, "require_explicit_package_overrides_for_builtin_materializations") orelse continue;
        if (value == .bool) return value.bool;
    }
    return true;
}

const Candidate = struct { macro: *const types.MacroDef, specificity: u8, locality: u8 };

fn candidate(graph: *const types.Graph, node: *const types.Node, macro: *const types.MacroDef) ?Candidate {
    const prefix = "materialization_";
    if (!std.mem.startsWith(u8, macro.name, prefix)) return null;
    const remaining = macro.name[prefix.len..];
    if (!std.mem.startsWith(u8, remaining, node.materialized)) return null;
    if (remaining.len <= node.materialized.len or remaining[node.materialized.len] != '_') return null;
    const adapter_name = remaining[node.materialized.len + 1 ..];
    const specificity: u8 = if (std.mem.eql(u8, adapter_name, graph.adapter_type)) 0 else if (std.mem.eql(u8, adapter_name, "default")) 1 else return null;
    return .{ .macro = macro, .specificity = specificity, .locality = if (std.mem.eql(u8, macro.package_name, graph.project_name)) 3 else if (corePackage(macro.package_name)) 1 else 2 };
}

pub fn selected(graph: *const types.Graph, node: *const types.Node) !?*const types.MacroDef {
    var has_core = false;
    for (graph.macros.items) |*macro| if (candidate(graph, node, macro)) |found| {
        if (found.locality == 1) has_core = true;
    };
    const restrict_imports = has_core and explicitOverrides(graph);
    var best: ?Candidate = null;
    for (graph.macros.items) |*macro| {
        const found = candidate(graph, node, macro) orelse continue;
        if (restrict_imports and found.locality == 2) continue;
        if (best) |previous| {
            if (found.specificity == previous.specificity and found.locality == previous.locality) return error.DuplicateMaterializationName;
            if (found.specificity > previous.specificity or (found.specificity == previous.specificity and found.locality < previous.locality)) continue;
        }
        best = found;
    }
    const chosen = best orelse return null;
    if (chosen.macro.has_supported_languages) {
        for (chosen.macro.supported_languages.items) |language| if (std.mem.eql(u8, language, node.language)) return chosen.macro;
        const detail = try std.fmt.allocPrint(graph.allocator, "Materialization \"{s}\" does not support language \"{s}\"", .{ chosen.macro.name, node.language });
        defer graph.allocator.free(detail);
        @import("compile_diagnostics.zig").captureError(node.original_file_path, node.name, detail, error.UnsupportedMaterializationLanguage);
        return error.UnsupportedMaterializationLanguage;
    }
    return chosen.macro;
}

pub fn custom(graph: *const types.Graph, node: *const types.Node) !?*const types.MacroDef {
    const macro = try selected(graph, node) orelse return null;
    return if (corePackage(macro.package_name)) null else macro;
}

pub fn supports(graph: *const types.Graph, node: *const types.Node) !bool {
    const macro = selected(graph, node) catch |err| switch (err) {
        // A registered materialization's language validation is a resource
        // execution error. Independent ready resources must still execute.
        error.UnsupportedMaterializationLanguage => return true,
        else => return err,
    };
    if (macro != null) return true;
    return @import("duckdb.zig").isSupportedMaterializationForAdapter(graph.adapter_type, node.materialized);
}

pub fn execute(runtime: types.Runtime, db_path: []const u8, graph: *const types.Graph, node: *const types.Node, macro: *const types.MacroDef) !Result {
    return executeWithArtifacts(runtime, db_path, graph, node, macro, null);
}

pub fn executeWithArtifacts(runtime: types.Runtime, db_path: []const u8, graph: *const types.Graph, node: *const types.Node, macro: *const types.MacroDef, build_path: ?*?[]const u8) !Result {
    if (!corePackage(macro.package_name) and !std.mem.eql(u8, macro.package_name, graph.project_name) and !explicitOverrides(graph)) {
        for (graph.macros.items) |*builtin| if (candidate(graph, node, builtin)) |found| {
            if (found.locality == 1) {
                try @import("deprecation_events.zig").packageMaterializationOverride(runtime, graph, node, macro.package_name);
                break;
            }
        };
    }
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
    errdefer @import("resource_artifacts.zig").capture(runtime.allocator, build_path, host.writtenPathForResource(node.unique_id)) catch {};
    host.log_events = graph.log_collector;
    runtime_graph.execution_hooks = host.host();
    // Preserve an actual server error before host teardown rolls back the
    // connection, which can clear the adapter's last diagnostic.
    errdefer |err| if (err == error.DuckDbExecutionFailed or err == error.PostgresExecutionFailed or @import("compile_diagnostics.zig").message(err) == null) {
        if (host.lastError()) |message| @import("compile_diagnostics.zig").captureError(node.original_file_path, node.name, message, err);
    };
    var scratch = std.heap.ArenaAllocator.init(runtime.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const name = try std.fmt.allocPrint(a, "{s}.{s}", .{ macro.package_name, macro.name });
    const returned = try compiler.renderMacroForNode(a, &runtime_graph, node, name, &.{});
    const relations = returned.attribute("relations");
    if (returned != .object or relations != .list) {
        @import("compile_diagnostics.zig").captureError(node.original_file_path, node.name, "Invalid return value from materialization, expected a dict with a list named relations", error.InvalidMaterializationReturn);
        return error.InvalidMaterializationReturn;
    }
    for (relations.list) |relation| {
        var definition = @import("dbt_context.zig").relationFromValue(a, relation) catch {
            @import("compile_diagnostics.zig").captureError(node.original_file_path, node.name, "Invalid return value from materialization, relations contains non-Relation", error.InvalidMaterializationReturn);
            return error.InvalidMaterializationReturn;
        };
        definition.dbt_created = true;
        _ = try runtime_graph.execution_hooks.?.call(runtime_graph.execution_hooks.?.context, "adapter.cache_added", &.{.{ .name = "relation", .value = try @import("dbt_context.zig").relationValue(a, definition) }}, a);
    }
    const main = host.result("main") orelse {
        @import("compile_diagnostics.zig").captureError(node.original_file_path, node.name, "main is not being called during running model", error.MissingMaterializationMain);
        return error.MissingMaterializationMain;
    };
    try @import("resource_artifacts.zig").capture(runtime.allocator, build_path, host.writtenPathForResource(node.unique_id));
    return try @import("materialization_result.zig").fromValue(runtime.allocator, main.attribute("response"));
}

test "materialization specificity precedes package locality and builtin override policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph = types.Graph{ .allocator = a, .project_name = "root" };
    var node = types.Node{ .package_name = "root", .unique_id = "model.root.m", .name = "m", .path = "m.sql", .original_file_path = "models/m.sql", .raw_code = "", .materialized = "table" };
    inline for (.{ .{ "dbt", "default" }, .{ "root", "default" }, .{ "dbt_duckdb", "duckdb" }, .{ "dependency", "duckdb" } }) |item| try graph.macros.append(a, .{ .unique_id = item[0], .package_name = item[0], .name = try std.fmt.allocPrint(a, "materialization_table_{s}", .{item[1]}), .path = "mat.sql", .original_file_path = "macros/mat.sql", .macro_sql = "" });
    try std.testing.expectEqualStrings("dbt_duckdb", (try selected(&graph, &node)).?.package_name);
    var project: std.json.Value = .null;
    var flags: std.json.Value = .null;
    try values.put(a, &flags, "require_explicit_package_overrides_for_builtin_materializations", .{ .bool = false });
    try values.put(a, &project, "flags", flags);
    try graph.semantic_project_configs.append(a, .{ .package_name = "root", .raw = .null, .rendered = project });
    try std.testing.expectEqualStrings("dependency", (try selected(&graph, &node)).?.package_name);
    graph.adapter_type = "postgres";
    try std.testing.expectEqualStrings("root", (try selected(&graph, &node)).?.package_name);
    node.materialized = "missing";
    try std.testing.expect((try selected(&graph, &node)) == null);
}
