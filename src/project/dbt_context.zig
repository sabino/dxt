//! Typed, native dbt adapter values. Callable payloads own the immutable value
//! definition so nested macro returns never borrow a temporary registry.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const Argument = expression.Argument;

pub fn cloneValue(allocator: std.mem.Allocator, value: Value) anyerror!Value {
    return switch (value) {
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .callable => |name| .{ .callable = try allocator.dupe(u8, name) },
        .list => |items| blk: {
            const copied = try allocator.alloc(Value, items.len);
            for (items, copied) |item, *copy| copy.* = try cloneValue(allocator, item);
            break :blk .{ .list = copied };
        },
        .object => |entries| blk: {
            const copied = try allocator.alloc(expression.Entry, entries.len);
            for (entries, copied) |entry, *copy| copy.* = .{ .key = try allocator.dupe(u8, entry.key), .value = try cloneValue(allocator, entry.value) };
            break :blk .{ .object = copied };
        },
        else => value,
    };
}

pub const Policy = struct { database: bool = true, schema: bool = true, identifier: bool = true };
pub const RelationDef = struct {
    adapter_type: []const u8 = "duckdb",
    database: ?[]const u8 = null,
    schema: ?[]const u8 = null,
    identifier: ?[]const u8 = null,
    relation_type: ?[]const u8 = null,
    quote_policy: Policy = .{},
    include_policy: Policy = .{},
    dbt_created: bool = false,
    rendered_sql: ?[]const u8 = null,
    base_sql: ?[]const u8 = null,
    information_schema_relation: bool = false,
    information_schema_view: ?[]const u8 = null,
};

fn optional(value: ?[]const u8) Value {
    return if (value) |text| .{ .string = text } else .none;
}

fn policyValue(allocator: std.mem.Allocator, policy: Policy) !Value {
    return .{ .object = try allocator.dupe(expression.Entry, &.{
        .{ .key = "database", .value = .{ .boolean = policy.database } },
        .{ .key = "schema", .value = .{ .boolean = policy.schema } },
        .{ .key = "identifier", .value = .{ .boolean = policy.identifier } },
    }) };
}

pub fn renderRelation(allocator: std.mem.Allocator, definition: RelationDef) ![]const u8 {
    if (definition.base_sql) |text| return text;
    var out: std.ArrayList(u8) = .empty;
    inline for (.{ "database", "schema", "identifier" }) |key| {
        if (@field(definition.include_policy, key)) if (@field(definition, key)) |text| {
            if (out.items.len != 0) try out.append(allocator, '.');
            if (@field(definition.quote_policy, key)) try out.append(allocator, '"');
            for (text) |c| {
                try out.append(allocator, c);
                if (@field(definition.quote_policy, key) and c == '"') try out.append(allocator, '"');
            }
            if (@field(definition.quote_policy, key)) try out.append(allocator, '"');
        };
    }
    if (definition.information_schema_view) |view| {
        if (out.items.len != 0) try out.append(allocator, '.');
        try out.appendSlice(allocator, view);
    }
    return out.toOwnedSlice(allocator);
}

pub fn relationValue(allocator: std.mem.Allocator, definition: RelationDef) !Value {
    const serialized = try std.json.Stringify.valueAlloc(allocator, definition, .{});
    var entries: std.ArrayList(expression.Entry) = .empty;
    try entries.appendSlice(allocator, &.{
        .{ .key = "__dxt_relation", .value = .{ .string = serialized } },
        .{ .key = "__dxt_rendered", .value = .{ .string = definition.rendered_sql orelse try renderRelation(allocator, definition) } },
        .{ .key = "database", .value = optional(definition.database) },
        .{ .key = "schema", .value = optional(definition.schema) },
        .{ .key = "identifier", .value = optional(definition.identifier) },
        .{ .key = "name", .value = optional(definition.identifier) },
        .{ .key = "table", .value = optional(definition.identifier) },
        .{ .key = "type", .value = optional(definition.relation_type) },
        .{ .key = "quote_policy", .value = try policyValue(allocator, definition.quote_policy) },
        .{ .key = "include_policy", .value = try policyValue(allocator, definition.include_policy) },
        .{ .key = "path", .value = .{ .object = try allocator.dupe(expression.Entry, &.{
            .{ .key = "database", .value = optional(definition.database) },
            .{ .key = "schema", .value = optional(definition.schema) },
            .{ .key = "identifier", .value = optional(definition.identifier) },
        }) } },
    });
    inline for (.{ "table", "view", "cte", "materialized_view", "pointer" }) |kind| try entries.append(allocator, .{
        .key = "is_" ++ kind,
        .value = .{ .boolean = if (definition.relation_type) |actual| std.mem.eql(u8, actual, if (std.mem.eql(u8, kind, "pointer")) "pointer_table" else kind) else false },
    });
    if (definition.information_schema_relation) try entries.append(allocator, .{ .key = "information_schema_view", .value = optional(definition.information_schema_view) });
    const replaceable = !definition.information_schema_relation and std.mem.eql(u8, definition.adapter_type, "postgres") and definition.relation_type != null and (std.mem.eql(u8, definition.relation_type.?, "table") or std.mem.eql(u8, definition.relation_type.?, "view"));
    try entries.appendSlice(allocator, &.{
        .{ .key = "can_be_renamed", .value = .{ .boolean = replaceable } },
        .{ .key = "can_be_replaced", .value = .{ .boolean = replaceable } },
    });
    for ([_][]const u8{ "render", "quote", "include", "incorporate", "replace_path", "without_identifier", "matches", "information_schema", "information_schema_only" }) |method| try entries.append(allocator, .{
        .key = method,
        .value = .{ .callable = try std.fmt.allocPrint(allocator, "__dxt_relation:{s}:{s}", .{ method, serialized }) },
    });
    return .{ .object = try entries.toOwnedSlice(allocator) };
}

pub fn relationFromValue(allocator: std.mem.Allocator, value: Value) !RelationDef {
    const data = value.attribute("__dxt_relation");
    if (data != .string) return error.InvalidRelation;
    return (try std.json.parseFromSlice(RelationDef, allocator, data.string, .{})).value;
}

fn named(args: []const Argument, name: []const u8, position: usize) Value {
    var index: usize = 0;
    for (args) |arg| {
        if (arg.name) |key| {
            if (std.mem.eql(u8, key, name)) return arg.value;
        } else {
            if (index == position) return arg.value;
            index += 1;
        }
    }
    return .undefined;
}

fn stringOrNull(value: Value) !?[]const u8 {
    return switch (value) {
        .none, .undefined => null,
        .string => |text| text,
        else => error.InvalidJinjaArguments,
    };
}

fn applyPolicy(policy: *Policy, value: Value) !void {
    if (value == .undefined or value == .none) return;
    if (value != .object) return error.InvalidJinjaArguments;
    inline for (.{ "database", "schema", "identifier" }) |key| {
        const field = value.attribute(key);
        if (field != .undefined and field != .none) {
            if (field != .boolean) return error.InvalidJinjaArguments;
            @field(policy, key) = field.boolean;
        }
    }
}

fn argsPolicy(allocator: std.mem.Allocator, args: []const Argument) !Value {
    var entries: std.ArrayList(expression.Entry) = .empty;
    inline for (.{ "database", "schema", "identifier" }, 0..) |key, position| {
        const field = named(args, key, position);
        if (field != .undefined) try entries.append(allocator, .{ .key = key, .value = field });
    }
    return .{ .object = try entries.toOwnedSlice(allocator) };
}

fn refreshImplicitSql(allocator: std.mem.Allocator, original: RelationDef, changed: *RelationDef) !void {
    if (original.rendered_sql) |rendered| {
        const before = try renderRelation(allocator, original);
        const after = try renderRelation(allocator, changed.*);
        if (std.mem.eql(u8, before, after)) return;
        if (std.mem.indexOf(u8, rendered, before)) |at| changed.rendered_sql = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ rendered[0..at], after, rendered[at + before.len ..] }) else changed.rendered_sql = after;
    }
}

pub fn call(allocator: std.mem.Allocator, adapter_type: []const u8, name: []const u8, args: []const Argument) !?Value {
    if (std.mem.eql(u8, name, "api.Relation.create") or std.mem.eql(u8, name, "adapter.Relation.create")) {
        var definition = RelationDef{ .adapter_type = adapter_type };
        inline for (.{ "database", "schema", "identifier" }, 0..) |key, position| @field(definition, key) = try stringOrNull(named(args, key, position));
        definition.relation_type = try stringOrNull(named(args, "type", 3));
        try applyPolicy(&definition.quote_policy, named(args, "quote_policy", std.math.maxInt(usize)));
        try applyPolicy(&definition.include_policy, named(args, "include_policy", std.math.maxInt(usize)));
        return try relationValue(allocator, definition);
    }
    const prefix = "__dxt_relation:";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const boundary = std.mem.indexOfScalarPos(u8, name, prefix.len, ':') orelse return error.InvalidRelation;
    const method = name[prefix.len..boundary];
    const original = (try std.json.parseFromSlice(RelationDef, allocator, name[boundary + 1 ..], .{})).value;
    var definition = original;
    if (std.mem.eql(u8, method, "render")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        return .{ .string = try renderRelation(allocator, definition) };
    } else if (std.mem.eql(u8, method, "quote")) {
        try applyPolicy(&definition.quote_policy, try argsPolicy(allocator, args));
        definition.base_sql = null;
    } else if (std.mem.eql(u8, method, "include")) {
        try applyPolicy(&definition.include_policy, try argsPolicy(allocator, args));
        definition.base_sql = null;
    } else if (std.mem.eql(u8, method, "incorporate")) {
        const path = named(args, "path", std.math.maxInt(usize));
        if (path != .undefined) {
            if (path != .object) return error.InvalidJinjaArguments;
            inline for (.{ "database", "schema", "identifier" }) |key| {
                const field = path.attribute(key);
                if (field != .undefined) @field(definition, key) = try stringOrNull(field);
            }
            definition.base_sql = null;
        }
        const kind = named(args, "type", std.math.maxInt(usize));
        if (kind != .undefined) definition.relation_type = try stringOrNull(kind);
        try applyPolicy(&definition.quote_policy, named(args, "quote_policy", std.math.maxInt(usize)));
        try applyPolicy(&definition.include_policy, named(args, "include_policy", std.math.maxInt(usize)));
    } else if (std.mem.eql(u8, method, "replace_path")) {
        inline for (.{ "database", "schema", "identifier" }, 0..) |key, position| {
            const field = named(args, key, position);
            if (field != .undefined) @field(definition, key) = try stringOrNull(field);
        }
        definition.base_sql = null;
    } else if (std.mem.eql(u8, method, "without_identifier")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        definition.identifier = null;
        definition.include_policy.identifier = false;
        definition.base_sql = null;
    } else if (std.mem.eql(u8, method, "matches")) {
        var matched: usize = 0;
        var exact = true;
        var approximate = true;
        inline for (.{ "database", "schema", "identifier" }, 0..) |key, position| {
            const field = named(args, key, position);
            if (field != .undefined and field != .none) {
                const text = (try stringOrNull(field)).?;
                matched += 1;
                const actual = @field(definition, key) orelse "";
                const insensitive = definition.dbt_created and !@field(definition.quote_policy, key);
                if (!(if (insensitive) std.ascii.eqlIgnoreCase(actual, text) else std.mem.eql(u8, actual, text))) exact = false;
                if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, actual, "\""), std.mem.trim(u8, text, "\""))) approximate = false;
            }
        }
        if (matched == 0) return error.InvalidRelationMatch;
        if (approximate and !exact) return error.ApproximateRelationMatch;
        return .{ .boolean = exact };
    } else if (std.mem.eql(u8, method, "information_schema") or std.mem.eql(u8, method, "information_schema_only")) {
        definition.schema = null;
        const view = named(args, "view_name", 0);
        definition.identifier = "INFORMATION_SCHEMA";
        definition.information_schema_relation = true;
        definition.information_schema_view = if (view == .string) view.string else null;
        definition.include_policy.database = definition.database != null;
        definition.include_policy.schema = false;
        definition.include_policy.identifier = true;
        definition.quote_policy.identifier = false;
        definition.relation_type = "view";
        definition.base_sql = null;
        definition.rendered_sql = null;
    } else return error.UnsupportedRelationMethod;
    try refreshImplicitSql(allocator, original, &definition);
    return try relationValue(allocator, definition);
}

test "typed relations retain methods across immutable transformations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const relation = try relationValue(allocator, .{ .database = "warehouse", .schema = "main", .identifier = "events", .rendered_sql = "(select * from \"warehouse\".\"main\".\"events\" where false limit 0)" });
    const rendered = (try call(allocator, "duckdb", relation.attribute("render").callable, &.{})).?;
    try std.testing.expectEqualStrings("\"warehouse\".\"main\".\"events\"", rendered.string);
    const changed = (try call(allocator, "duckdb", relation.attribute("include").callable, &.{.{ .name = "database", .value = .{ .boolean = false } }})).?;
    try std.testing.expectEqualStrings("(select * from \"main\".\"events\" where false limit 0)", try changed.text(allocator));
    try std.testing.expectEqualStrings("events", changed.attribute("identifier").string);
}
