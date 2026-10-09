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
    for ([_][]const u8{ "get_columns_in_relation", "get_missing_columns", "get_column_schema_from_query" }) |method| if (is(name, method)) return .{ .list = try expression.allocateValues(allocator, 0) };
    for ([_][]const u8{ "get_relation", "drop_relation", "truncate_relation", "rename_relation", "create_schema", "drop_schema", "expand_target_column_types" }) |method| if (is(name, method)) return .none;
    if (is(name, "check_schema_exists")) return .{ .boolean = false };
    return null;
}

pub fn call(allocator: std.mem.Allocator, graph: *const types.Graph, state: *State, executor: Executor, name: []const u8, args: []const Argument) !?Value {
    if (try credentialValue(allocator, graph, name, args)) |value| return value;
    if (is(name, "verify_database") and std.mem.eql(u8, graph.adapter_type, "postgres")) {
        const database = argument(args, "database", 0);
        const expected = @import("config_value.zig").get(graph.target_context, "database") orelse return error.MissingPostgresDatabase;
        if (database != .string or expected != .string) return error.InvalidJinjaArguments;
        const unquoted = if (std.mem.startsWith(u8, database.string, "\"")) std.mem.trim(u8, database.string, "\"") else database.string;
        if (!std.ascii.eqlIgnoreCase(unquoted, expected.string)) return error.UnexpectedDatabaseReference;
        return .{ .string = "" };
    }
    if (is(name, "get_columns_in_relation")) {
        const relation = try relationArg(args, "relation", 0);
        return try executor.render(executor.context, allocator, "get_columns_in_relation", &.{.{ .name = "relation", .value = relation }});
    }
    if (is(name, "expand_target_column_types")) {
        const from = try relationArg(args, "from_relation", 0);
        const to = try relationArg(args, "to_relation", 1);
        const source = try executor.render(executor.context, allocator, "get_columns_in_relation", &.{.{ .name = "relation", .value = from }});
        const target = try executor.render(executor.context, allocator, "get_columns_in_relation", &.{.{ .name = "relation", .value = to }});
        if (source != .list or target != .list) return error.InvalidAdapterIntrospection;
        for (source.list) |reference| {
            const column_name = reference.attribute("name");
            if (column_name != .string) return error.InvalidAdapterIntrospection;
            for (target.list) |column| {
                const target_name = column.attribute("name");
                if (target_name != .string or !std.mem.eql(u8, column_name.string, target_name.string)) continue;
                const method = column.attribute("can_expand_to");
                if (method != .callable) return error.InvalidAdapterIntrospection;
                const expand = (try contexts.call(allocator, graph.adapter_type, method.callable, &.{.{ .value = reference }})) orelse return error.InvalidAdapterIntrospection;
                if (!expand.truthy()) continue;
                const size_method = reference.attribute("string_size");
                const size = (try contexts.call(allocator, graph.adapter_type, size_method.callable, &.{})).?;
                const new_type = try std.fmt.allocPrint(allocator, "character varying({s})", .{try size.text(allocator)});
                _ = try executor.render(executor.context, allocator, "alter_column_type", &.{ .{ .name = "relation", .value = to }, .{ .name = "column_name", .value = column_name }, .{ .name = "new_column_type", .value = .{ .string = new_type } } });
            }
        }
        return .none;
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
        if (cells.len < 1) return error.InvalidAdapterIntrospection;
        return .{ .boolean = (expression.integerIndex(cells[0]) catch return error.InvalidAdapterIntrospection) > 0 };
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

/// These adapter methods use rendered credentials and never open a connection.
pub fn credentialValue(allocator: std.mem.Allocator, graph: *const types.Graph, name: []const u8, args: []const Argument) !?Value {
    if (is(name, "is_motherduck") and std.mem.eql(u8, graph.adapter_type, "duckdb")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        const path = @import("config_value.zig").get(graph.target_context, "path") orelse return Value{ .boolean = false };
        if (path != .string) return error.InvalidJinjaArguments;
        return .{ .boolean = std.mem.startsWith(u8, path.string, "md:") or std.mem.startsWith(u8, path.string, "motherduck:") };
    }
    if (!is(name, "is_ducklake") or !std.mem.eql(u8, graph.adapter_type, "duckdb")) return null;
    if (args.len != 1) return error.InvalidJinjaArguments;
    if (args[0].value == .none) return .{ .boolean = false };
    const relation = try contexts.relationFromValue(allocator, args[0].value);
    const database = relation.database orelse return Value{ .boolean = false };
    const json = @import("config_value.zig");
    const target_database = json.get(graph.target_context, "database");
    if (isDucklakeConfig(graph.target_context) and target_database != null and target_database.? == .string and std.mem.eql(u8, database, target_database.?.string)) return .{ .boolean = true };
    if (json.get(graph.target_context, "attach")) |attachments| if (attachments == .array) {
        for (attachments.array.items) |attachment| {
            if (!isDucklakeConfig(attachment)) continue;
            const path = json.get(attachment, "path") orelse continue;
            const alias = json.get(attachment, "alias");
            const identifier = if (alias != null and alias.? == .string and alias.?.string.len != 0) alias.?.string else if (path == .string) std.fs.path.stem(path.string) else continue;
            if (std.mem.eql(u8, database, identifier)) return .{ .boolean = true };
        }
    };
    return .{ .boolean = false };
}

fn isDucklakeConfig(config: std.json.Value) bool {
    const json = @import("config_value.zig");
    if (json.get(config, "is_ducklake")) |flag| if (flag == .bool and flag.bool) return true;
    if (json.get(config, "path")) |path| if (path == .string) {
        var index: usize = 0;
        while (index + "ducklake:".len <= path.string.len) : (index += 1) if (std.ascii.eqlIgnoreCase(path.string[index .. index + "ducklake:".len], "ducklake:")) return true;
    };
    return false;
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
