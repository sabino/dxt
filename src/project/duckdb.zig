const std = @import("std");
const compiler = @import("compiler.zig");
const project_fs = @import("fs.zig");
const types = @import("types.zig");

const Runtime = types.Runtime;
const Graph = types.Graph;
const Node = types.Node;

pub fn databasePath(allocator: std.mem.Allocator, target_dir: []const u8, graph: *const Graph) ![]const u8 {
    if (graph.database_path) |configured_path| {
        if (isUnsupportedConnectionPath(configured_path)) return error.UnsupportedDuckDbPath;
        if (std.fs.path.isAbsolute(configured_path)) return try allocator.dupe(u8, configured_path);
        const base = graph.database_path_base orelse ".";
        return try project_fs.pathJoin(allocator, &.{ base, configured_path });
    }
    return try project_fs.pathJoin(allocator, &.{ target_dir, "dxt.duckdb" });
}

pub fn isSupportedMaterialization(value: []const u8) bool {
    return std.mem.eql(u8, value, "table") or std.mem.eql(u8, value, "view");
}

fn isUnsupportedConnectionPath(value: []const u8) bool {
    return std.mem.eql(u8, value, ":memory:") or
        std.mem.startsWith(u8, value, "md:") or
        std.mem.startsWith(u8, value, "motherduck:");
}

pub fn executeModel(runtime: Runtime, db_path: []const u8, graph: *const Graph, node: *const Node) !void {
    const sql = try renderModelSql(runtime.allocator, graph, node);
    defer runtime.allocator.free(sql);

    const result = std.process.run(runtime.allocator, runtime.io, .{
        .argv = &.{ "duckdb", db_path, "-batch", "-bail", "-c", sql },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| switch (err) {
        error.FileNotFound => return error.DuckDbCliNotFound,
        else => return err,
    };
    defer runtime.allocator.free(result.stdout);
    defer runtime.allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.DuckDbExecutionFailed;
}

pub fn renderModelSql(allocator: std.mem.Allocator, graph: *const Graph, node: *const Node) ![]const u8 {
    if (!isSupportedMaterialization(node.materialized)) {
        return error.UnsupportedModelMaterialization;
    }
    const compiled_code = node.compiled_code orelse return error.UnsupportedModelExecution;
    const schema_name = try compiler.relationSchemaForNode(allocator, graph, node);
    defer allocator.free(schema_name);
    const quoted_schema = try compiler.quoteIdentifier(allocator, schema_name);
    defer allocator.free(quoted_schema);
    const relation_name = node.relation_name orelse try compiler.relationNameForNode(allocator, graph, node);
    const should_free_relation = node.relation_name == null;
    defer if (should_free_relation) allocator.free(relation_name);

    const materialization_keyword: []const u8 = if (std.mem.eql(u8, node.materialized, "table")) "table" else "view";
    return try std.fmt.allocPrint(
        allocator,
        "create schema if not exists {s};\ncreate or replace {s} {s} as (\n{s}\n);\n",
        .{ quoted_schema, materialization_keyword, relation_name, compiled_code },
    );
}

test "renderModelSql creates table materialization SQL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo", .target_schema = "analytics" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select 1 as id",
        .materialized = "table",
        .compiled = true,
        .compiled_code = "select 1 as id",
        .relation_name = "\"analytics\".\"customers\"",
    });

    const sql = try renderModelSql(allocator, &graph, &graph.nodes.items[0]);
    try std.testing.expectEqualStrings(
        "create schema if not exists \"analytics\";\ncreate or replace table \"analytics\".\"customers\" as (\nselect 1 as id\n);\n",
        sql,
    );
}

test "renderModelSql rejects unsupported materialization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select 1 as id",
        .materialized = "incremental",
        .compiled = true,
        .compiled_code = "select 1 as id",
    });

    try std.testing.expectError(error.UnsupportedModelMaterialization, renderModelSql(allocator, &graph, &graph.nodes.items[0]));
}

test "databasePath resolves configured relative path from profile base" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{
        .allocator = allocator,
        .project_name = "demo",
        .database_path = "warehouse.duckdb",
        .database_path_base = "profiles",
    };
    defer graph.deinit();

    const resolved = try databasePath(allocator, "target", &graph);
    try std.testing.expectEqualStrings("profiles/warehouse.duckdb", resolved);
}

test "databasePath rejects unsupported connection strings for CLI backend" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{
        .allocator = allocator,
        .project_name = "demo",
        .database_path = ":memory:",
    };
    defer graph.deinit();

    try std.testing.expectError(error.UnsupportedDuckDbPath, databasePath(allocator, "target", &graph));
}
