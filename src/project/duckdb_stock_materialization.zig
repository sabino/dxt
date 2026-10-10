//! Stock DuckDB tables/views stage the main statement before swapping names.
const std = @import("std");
const adapter = @import("adapter.zig");
const compiler = @import("compiler.zig");
const context = @import("dbt_context.zig");
const types = @import("types.zig");
const artifacts = @import("stock_artifacts.zig");

pub fn execute(runtime: types.Runtime, graph: *const types.Graph, node: *const types.Node, session: *adapter.Session, policy: @import("postgres_materialization.zig").ExecutionPolicy) !void {
    var arena = std.heap.ArenaAllocator.init(runtime.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var target = try context.relationFromValue(a, try compiler.relationValueForNode(a, graph, node, false));
    target.relation_type = if (std.mem.eql(u8, node.materialized, "incremental")) "table" else node.materialized;
    var intermediate = target;
    intermediate.identifier = try std.fmt.allocPrint(a, "{s}__dbt_tmp", .{target.identifier.?});
    var backup = target;
    backup.identifier = try std.fmt.allocPrint(a, "{s}__dbt_backup", .{target.identifier.?});
    var namespace = target;
    namespace.identifier = null;
    if (policy.manage_transaction) try session.begin();
    errdefer if (policy.manage_transaction) session.rollback() catch {};
    try session.execute(try std.fmt.allocPrint(a, "create schema if not exists {s}", .{try context.renderRelation(a, namespace)}));
    const existing = try session.relationTypeInDatabase(a, target.database, target.schema.?, target.identifier.?);
    try dropExisting(a, session, intermediate);
    try dropExisting(a, session, backup);
    const sql = try @import("stock_sql.zig").create(a, graph, node, intermediate, @import("duckdb.zig").trimTrailingSqlTerminator(node.compiled_code orelse return error.UnsupportedModelExecution), false);
    try artifacts.write(policy.artifact_writer, node, sql);
    try session.execute(sql);
    if (existing) |kind| {
        var old = target;
        old.relation_type = kind;
        try rename(a, session, old, backup.identifier.?);
        backup.relation_type = kind;
    }
    try rename(a, session, intermediate, target.identifier.?);
    if (existing != null) try drop(a, session, backup);
    if (policy.manage_transaction) try session.commit();
}

fn rename(a: std.mem.Allocator, session: *adapter.Session, relation: context.RelationDef, identifier: []const u8) !void {
    try session.execute(try std.fmt.allocPrint(a, "alter {s} {s} rename to {s}", .{ relation.relation_type.?, try context.renderRelation(a, relation), try adapter.quoteIdentifier(a, identifier) }));
}
fn drop(a: std.mem.Allocator, session: *adapter.Session, relation: context.RelationDef) !void {
    try session.execute(try std.fmt.allocPrint(a, "drop {s} if exists {s}", .{ relation.relation_type.?, try context.renderRelation(a, relation) }));
}
fn dropExisting(a: std.mem.Allocator, session: *adapter.Session, relation: context.RelationDef) !void {
    if (try session.relationTypeInDatabase(a, relation.database, relation.schema.?, relation.identifier.?)) |kind| {
        var existing = relation;
        existing.relation_type = kind;
        try drop(a, session, existing);
    }
}
