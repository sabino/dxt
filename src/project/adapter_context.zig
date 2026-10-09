//! dbt adapter methods delegate to the same project-dispatched SQL macros used
//! by Core. The caller supplies a held native SQL host and current model frame.
const std = @import("std");
const expression = @import("expression.zig");
const contexts = @import("dbt_context.zig");
const types = @import("types.zig");
const Value = expression.Value;
const Argument = expression.Argument;

pub const Executor = struct {
    context: *anyopaque,
    render: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const Argument) anyerror!Value,
};

pub const State = struct {
    added: std.ArrayList(Value) = .empty,
    dropped: std.ArrayList(contexts.RelationDef) = .empty,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.added.deinit(allocator);
        self.dropped.deinit(allocator);
    }
};

fn is(name: []const u8, method: []const u8) bool {
    return std.mem.startsWith(u8, name, "adapter.") and std.mem.eql(u8, name[8..], method);
}

pub fn parseReplacement(allocator: std.mem.Allocator, name: []const u8) !?Value {
    for ([_][]const u8{ "get_columns_in_relation", "get_missing_columns" }) |method| if (is(name, method)) return .{ .list = try expression.allocateValues(allocator, 0) };
    for ([_][]const u8{ "get_relation", "drop_relation", "truncate_relation", "rename_relation", "create_schema", "drop_schema", "expand_target_column_types" }) |method| if (is(name, method)) return .none;
    if (is(name, "check_schema_exists")) return .{ .boolean = false };
    return null;
}

pub fn call(allocator: std.mem.Allocator, graph: *const types.Graph, state: *State, executor: Executor, name: []const u8, args: []const Argument) !?Value {
    if (is(name, "get_columns_in_relation")) {
        const relation = try relationArg(args, "relation", 0);
        return try executor.render(executor.context, allocator, "get_columns_in_relation", &.{.{ .name = "relation", .value = relation }});
    }
    if (is(name, "get_missing_columns")) {
        const from = try relationArg(args, "from_relation", 0);
        const to = try relationArg(args, "to_relation", 1);
        const source = try executor.render(executor.context, allocator, "get_columns_in_relation", &.{.{ .name = "relation", .value = from }});
        const target = try executor.render(executor.context, allocator, "get_columns_in_relation", &.{.{ .name = "relation", .value = to }});
        if (source != .list or target != .list) return error.InvalidAdapterIntrospection;
        var missing: std.ArrayList(Value) = .empty;
        for (source.list) |column| {
            const column_name = column.attribute("name");
            if (column_name != .string) return error.InvalidAdapterIntrospection;
            var found = false;
            for (target.list) |other| {
                const other_name = other.attribute("name");
                if (other_name == .string and std.mem.eql(u8, column_name.string, other_name.string)) found = true;
            }
            if (!found) try missing.append(allocator, column);
        }
        return .{ .list = if (missing.items.len == 0) try expression.allocateValues(allocator, 0) else try missing.toOwnedSlice(allocator) };
    }
    if (is(name, "get_relation")) {
        const database = try optionalString(argument(args, "database", 0));
        const schema = try optionalString(argument(args, "schema", 1));
        const identifier = try optionalString(argument(args, "identifier", 2));
        const search = contexts.RelationDef{ .adapter_type = graph.adapter_type, .database = database, .schema = schema, .identifier = identifier };
        for (state.added.items) |relation| if (same(try contexts.relationFromValue(allocator, relation), search)) return relation;
        for (state.dropped.items) |dropped| if (same(dropped, search)) return .none;
        const schema_relation = try contexts.relationValue(allocator, .{ .adapter_type = graph.adapter_type, .database = database, .schema = schema, .identifier = "", .include_policy = .{ .identifier = false } });
        const table = try executor.render(executor.context, allocator, "list_relations_without_caching", &.{.{ .name = "schema_relation", .value = schema_relation }});
        const rows = expression.sequence(table) orelse return error.InvalidAdapterIntrospection;
        var result: Value = .none;
        for (rows) |row| {
            const fields = expression.sequence(row) orelse return error.InvalidAdapterIntrospection;
            if (fields.len < 4) return error.InvalidAdapterIntrospection;
            const definition = contexts.RelationDef{ .adapter_type = graph.adapter_type, .database = try optionalString(fields[0]), .identifier = try optionalString(fields[1]), .schema = try optionalString(fields[2]), .relation_type = try optionalString(fields[3]), .dbt_created = true };
            if (same(definition, search)) {
                if (result != .none) return error.MultipleMatchingRelations;
                result = try contexts.relationValue(allocator, definition);
            }
        }
        return result;
    }
    if (is(name, "list_schemas")) {
        const database = argument(args, "database", 0);
        const table = try executor.render(executor.context, allocator, "list_schemas", &.{.{ .name = "database", .value = database }});
        const rows = expression.sequence(table) orelse return error.InvalidAdapterIntrospection;
        const schemas = try expression.allocateValues(allocator, rows.len);
        for (rows, schemas) |row, *schema| {
            const cells = expression.sequence(row) orelse return error.InvalidAdapterIntrospection;
            if (cells.len < 1) return error.InvalidAdapterIntrospection;
            schema.* = cells[0];
        }
        return .{ .list = schemas };
    }
    if (is(name, "check_schema_exists")) {
        const database = try optionalString(argument(args, "database", 0));
        const schema = try optionalString(argument(args, "schema", 1));
        const information_schema = try contexts.relationValue(allocator, .{ .adapter_type = graph.adapter_type, .database = database, .schema = schema, .identifier = "INFORMATION_SCHEMA" });
        const result = try executor.render(executor.context, allocator, "check_schema_exists", &.{ .{ .name = "information_schema", .value = information_schema }, .{ .name = "schema", .value = if (schema) |text| .{ .string = text } else .none } });
        const rows = expression.sequence(result) orelse return error.InvalidAdapterIntrospection;
        if (rows.len < 1) return error.InvalidAdapterIntrospection;
        const cells = expression.sequence(rows[0]) orelse return error.InvalidAdapterIntrospection;
        if (cells.len < 1 or cells[0] != .number) return error.InvalidAdapterIntrospection;
        return .{ .boolean = cells[0].number > 0 };
    }
    if (is(name, "cache_added") or is(name, "cache_dropped") or is(name, "drop_relation")) {
        const relation = try relationArg(args, "relation", 0);
        const definition = try contexts.relationFromValue(allocator, relation);
        if (is(name, "drop_relation")) {
            if (definition.relation_type == null) return error.RelationTypeRequired;
            _ = try executor.render(executor.context, allocator, "drop_relation", &.{.{ .name = "relation", .value = relation }});
        }
        removeCached(state, allocator, definition);
        if (is(name, "cache_added")) try state.added.append(allocator, try contexts.cloneValue(allocator, relation)) else try state.dropped.append(allocator, definition);
        return if (is(name, "drop_relation")) Value.none else Value{ .string = "" };
    }
    if (is(name, "cache_renamed") or is(name, "rename_relation")) {
        const from = try relationArg(args, "from_relation", 0);
        const to = try relationArg(args, "to_relation", 1);
        if (is(name, "rename_relation")) _ = try executor.render(executor.context, allocator, "rename_relation", &.{ .{ .name = "from_relation", .value = from }, .{ .name = "to_relation", .value = to } });
        const from_def = try contexts.relationFromValue(allocator, from);
        const to_def = try contexts.relationFromValue(allocator, to);
        removeCached(state, allocator, from_def);
        removeCached(state, allocator, to_def);
        try state.dropped.append(allocator, from_def);
        try state.added.append(allocator, try contexts.cloneValue(allocator, to));
        return if (is(name, "rename_relation")) Value.none else Value{ .string = "" };
    }
    for ([_][]const u8{ "truncate_relation", "create_schema", "drop_schema" }) |method| if (is(name, method)) {
        var relation = try relationArg(args, "relation", 0);
        if (!std.mem.eql(u8, method, "truncate_relation")) {
            var definition = try contexts.relationFromValue(allocator, relation);
            definition.identifier = null;
            relation = try contexts.relationValue(allocator, definition);
        }
        _ = try executor.render(executor.context, allocator, method, &.{.{ .name = "relation", .value = relation }});
        if (std.mem.eql(u8, method, "create_schema") or std.mem.eql(u8, method, "drop_schema")) _ = try executor.render(executor.context, allocator, "adapter.commit", &.{});
        return .none;
    };
    return null;
}

fn removeCached(state: *State, allocator: std.mem.Allocator, definition: contexts.RelationDef) void {
    var index: usize = 0;
    while (index < state.added.items.len) {
        const existing = contexts.relationFromValue(allocator, state.added.items[index]) catch {
            index += 1;
            continue;
        };
        if (same(existing, definition)) _ = state.added.orderedRemove(index) else index += 1;
    }
    index = 0;
    while (index < state.dropped.items.len) {
        if (same(state.dropped.items[index], definition)) _ = state.dropped.orderedRemove(index) else index += 1;
    }
}

fn same(left: contexts.RelationDef, right: contexts.RelationDef) bool {
    inline for (.{ "database", "schema", "identifier" }) |key| {
        const a = @field(left, key);
        const b = @field(right, key);
        if (a != null and b != null) {
            if (!std.mem.eql(u8, a.?, b.?)) return false;
        } else if (a != null or b != null) return false;
    }
    return true;
}

fn relationArg(args: []const Argument, name: []const u8, index: usize) !Value {
    const value = argument(args, name, index);
    if (value.attribute("__dxt_relation") != .string) return error.InvalidRelation;
    return value;
}

fn optionalString(value: Value) !?[]const u8 {
    return switch (value) {
        .none => null,
        .string => value.string,
        else => error.InvalidJinjaArguments,
    };
}

fn argument(args: []const Argument, name: []const u8, index: usize) Value {
    for (args) |arg| if (arg.name) |key| if (std.mem.eql(u8, key, name)) return arg.value;
    var position: usize = 0;
    for (args) |arg| if (arg.name == null) {
        if (position == index) return arg.value;
        position += 1;
    };
    return .none;
}
