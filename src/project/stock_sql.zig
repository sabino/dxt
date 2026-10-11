//! Stock materializers execute the same dispatched SQL helper that supplies
//! their run file; an artifact is never a separate, unexecuted reconstruction.
const std = @import("std");
const types = @import("types.zig");
const compiler = @import("compiler.zig");
const context = @import("dbt_context.zig");
const expression = @import("expression.zig");

pub fn create(allocator: std.mem.Allocator, graph: *const types.Graph, node: *const types.Node, definition: context.RelationDef, sql: []const u8, temporary: bool) ![]const u8 {
    const relation = try context.relationValue(allocator, definition);
    const value = if (std.mem.eql(u8, definition.relation_type orelse "table", "view"))
        try compiler.renderMacroForNode(allocator, graph, node, "get_create_view_as_sql", &.{ .{ .value = relation }, .{ .value = .{ .string = sql } } })
    else
        try compiler.renderMacroForNode(allocator, graph, node, "get_create_table_as_sql", &.{ .{ .value = .{ .boolean = temporary } }, .{ .value = relation }, .{ .value = .{ .string = sql } } });
    if (value != .string) return error.InvalidMaterializationResult;
    return value.string;
}

pub fn incremental(allocator: std.mem.Allocator, graph: *const types.Graph, node: *const types.Node, target: context.RelationDef, stage: context.RelationDef, columns: []const @import("incremental.zig").Column) ![]const u8 {
    const column_values = try allocator.alloc(expression.Value, columns.len);
    for (columns, column_values) |column, *value| value.* = try context.columnValue(allocator, .{ .adapter_type = graph.adapter_type, .column = column.column_name, .dtype = column.data_type });
    const predicates = try allocator.alloc(expression.Value, node.incremental.predicates.items.len);
    for (node.incremental.predicates.items, predicates) |predicate, *value| value.* = .{ .string = predicate };
    const key: expression.Value = if (node.incremental.unique_key) |unique| switch (unique) {
        .string => |text| .{ .string = text },
        .list => |names| blk: {
            const items = try allocator.alloc(expression.Value, names.items.len);
            for (names.items, items) |name, *item| item.* = .{ .string = name };
            break :blk .{ .list = items };
        },
    } else .none;
    const args: expression.Value = .{ .object = try allocator.dupe(expression.Entry, &.{
        .{ .key = "target_relation", .value = try context.relationValue(allocator, target) },
        .{ .key = "temp_relation", .value = try context.relationValue(allocator, stage) },
        .{ .key = "unique_key", .value = key },
        .{ .key = "dest_columns", .value = .{ .list = column_values } },
        .{ .key = "incremental_predicates", .value = .{ .list = predicates } },
    }) };
    const strategy = node.incremental.strategy orelse "default";
    const macro_name = try std.fmt.allocPrint(allocator, "get_incremental_{s}_sql", .{if (std.mem.eql(u8, strategy, "delete+insert")) "delete_insert" else strategy});
    const value = try compiler.renderMacroForNode(allocator, graph, node, macro_name, &.{.{ .value = args }});
    if (value != .string) return error.InvalidMaterializationResult;
    return value.string;
}

pub fn materializedView(a: std.mem.Allocator, graph: *const types.Graph, node: *const types.Node, target: context.RelationDef, existing: ?[]const u8, sql: []const u8) ![]const u8 {
    const relation = try context.relationValue(a, target);
    const value = if (existing) |kind| blk: {
        var old = target;
        old.relation_type = kind;
        break :blk try compiler.renderMacroForNode(a, graph, node, "get_replace_sql", &.{ .{ .value = try context.relationValue(a, old) }, .{ .value = relation }, .{ .value = .{ .string = sql } } });
    } else try compiler.renderMacroForNode(a, graph, node, "get_create_materialized_view_as_sql", &.{ .{ .value = relation }, .{ .value = .{ .string = sql } } });
    if (value != .string) return error.InvalidMaterializationResult;
    return value.string;
}

pub fn refreshMaterializedView(a: std.mem.Allocator, graph: *const types.Graph, node: *const types.Node, target: context.RelationDef) ![]const u8 {
    const value = try compiler.renderMacroForNode(a, graph, node, "refresh_materialized_view", &.{.{ .value = try context.relationValue(a, target) }});
    if (value != .string) return error.InvalidMaterializationResult;
    return value.string;
}

pub fn alterMaterializedView(a: std.mem.Allocator, graph: *const types.Graph, node: *const types.Node, target: context.RelationDef, changes: expression.Value) ![]const u8 {
    const relation = try context.relationValue(a, target);
    const collection: expression.Value = .{ .object = try a.dupe(expression.Entry, &.{
        .{ .key = "requires_full_refresh", .value = .{ .boolean = false } },
        .{ .key = "indexes", .value = changes },
    }) };
    const value = try compiler.renderMacroForNode(a, graph, node, "get_alter_materialized_view_as_sql", &.{ .{ .value = relation }, .{ .value = collection }, .{ .value = .{ .string = node.compiled_code orelse "" } }, .{ .value = relation }, .{ .value = .none }, .{ .value = .none } });
    if (value != .string) return error.InvalidMaterializationResult;
    return value.string;
}

test "stock SQL uses authored helpers and passes typed relation and column arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph = types.Graph{ .allocator = a, .project_name = "fixture" };
    const definitions = [_][2][]const u8{
        .{ "get_create_table_as_sql", "{% macro get_create_table_as_sql(temporary, relation, sql) %}{{ return('create table ' ~ relation.render() ~ ' as (' ~ sql ~ ')') }}{% endmacro %}" },
        .{ "get_incremental_delete_insert_sql", "{% macro get_incremental_delete_insert_sql(arg_dict) %}{{ return('insert into ' ~ arg_dict.target_relation.render() ~ ' select ' ~ arg_dict.dest_columns[0].quoted ~ ' from ' ~ arg_dict.temp_relation.render()) }}{% endmacro %}" },
    };
    for (definitions) |definition| try graph.macros.append(a, .{ .package_name = "fixture", .unique_id = try std.fmt.allocPrint(a, "macro.fixture.{s}", .{definition[0]}), .name = definition[0], .path = "macro.sql", .original_file_path = "macros/macro.sql", .macro_sql = definition[1] });
    const node = types.Node{ .package_name = "fixture", .unique_id = "model.fixture.m", .name = "m", .path = "m.sql", .original_file_path = "models/m.sql", .raw_code = "", .incremental = .{ .strategy = "delete+insert" } };
    const target = context.RelationDef{ .schema = "main", .identifier = "m", .relation_type = "table" };
    const stage = context.RelationDef{ .identifier = "m__dbt_tmp", .relation_type = "table" };
    try std.testing.expectEqualStrings("create table \"main\".\"m\" as (select 9 as id)", try create(a, &graph, &node, target, "select 9 as id", false));
    try std.testing.expectEqualStrings("insert into \"main\".\"m\" select \"id\" from \"m__dbt_tmp\"", try incremental(a, &graph, &node, target, stage, &.{.{ .column_name = "id", .data_type = "INTEGER" }}));
}
