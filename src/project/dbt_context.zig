//! Typed, native dbt adapter values. Callable payloads own the immutable value
//! definition so nested macro returns never borrow a temporary registry.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const Argument = expression.Argument;

pub fn cloneValue(allocator: std.mem.Allocator, value: Value) anyerror!Value {
    return cloneValueWithHost(allocator, value, null);
}

pub fn cloneValueWithHost(allocator: std.mem.Allocator, value: Value, host: ?expression.Host) anyerror!Value {
    return @import("value_clone.zig").clone(allocator, value, host);
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

pub const ColumnDef = struct {
    adapter_type: []const u8 = "duckdb",
    column: []const u8,
    dtype: []const u8,
    char_size: ?u64 = null,
    numeric_precision: std.json.Value = .null,
    numeric_scale: std.json.Value = .null,
};

fn isString(dtype: []const u8) bool {
    for ([_][]const u8{ "text", "character varying", "character", "varchar" }) |kind| if (std.ascii.eqlIgnoreCase(dtype, kind)) return true;
    return false;
}

fn isNumeric(dtype: []const u8) bool {
    return std.ascii.eqlIgnoreCase(dtype, "numeric") or std.ascii.eqlIgnoreCase(dtype, "decimal");
}

fn columnStringSize(definition: ColumnDef) !u64 {
    if (!isString(definition.dtype)) return error.InvalidColumnStringSize;
    return if (std.mem.eql(u8, definition.dtype, "text")) 256 else definition.char_size orelse 256;
}

fn columnDataType(allocator: std.mem.Allocator, definition: ColumnDef) ![]const u8 {
    if (std.mem.eql(u8, definition.adapter_type, "postgres") and
        (std.ascii.eqlIgnoreCase(definition.dtype, "text") or
            (std.ascii.eqlIgnoreCase(definition.dtype, "character varying") and definition.char_size == null))) return definition.dtype;
    if (isString(definition.dtype)) return try std.fmt.allocPrint(allocator, "character varying({d})", .{try columnStringSize(definition)});
    if (isNumeric(definition.dtype) and definition.numeric_precision != .null and definition.numeric_scale != .null) return try std.fmt.allocPrint(allocator, "{s}({s},{s})", .{ definition.dtype, try (try @import("config_value.zig").toExpression(allocator, definition.numeric_precision)).text(allocator), try (try @import("config_value.zig").toExpression(allocator, definition.numeric_scale)).text(allocator) });
    return definition.dtype;
}

pub fn columnValue(allocator: std.mem.Allocator, definition: ColumnDef) !Value {
    const serialized = try std.json.Stringify.valueAlloc(allocator, definition, .{});
    var entries: std.ArrayList(expression.Entry) = .empty;
    try entries.appendSlice(allocator, &.{
        .{ .key = "__dxt_column", .value = .{ .string = serialized } },
        .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
        .{ .key = "__dxt_rendered", .value = .{ .string = try std.fmt.allocPrint(allocator, "<Column {s} ({s})>", .{ definition.column, try columnDataType(allocator, definition) }) } },
        .{ .key = "column", .value = .{ .string = definition.column } },
        .{ .key = "name", .value = .{ .string = definition.column } },
        .{ .key = "dtype", .value = .{ .string = definition.dtype } },
        .{ .key = "data_type", .value = .{ .string = try columnDataType(allocator, definition) } },
        .{ .key = "quoted", .value = .{ .string = try std.fmt.allocPrint(allocator, "\"{s}\"", .{definition.column}) } },
        .{ .key = "char_size", .value = if (definition.char_size) |size| try expression.integerValue(allocator, size) else .none },
        .{ .key = "numeric_precision", .value = try @import("config_value.zig").toExpression(allocator, definition.numeric_precision) },
        .{ .key = "numeric_scale", .value = try @import("config_value.zig").toExpression(allocator, definition.numeric_scale) },
    });
    try entries.append(allocator, .{ .key = "fields", .value = .{ .list = try structFields(allocator, definition) } });
    for ([_][]const u8{ "is_string", "is_numeric", "is_integer", "is_float", "is_number", "is_struct", "flatten", "string_size", "can_expand_to", "literal" }) |method| try entries.append(allocator, .{
        .key = method,
        .value = .{ .callable = try std.fmt.allocPrint(allocator, "__dxt_column:{s}:{s}", .{ method, serialized }) },
    });
    return .{ .object = try entries.toOwnedSlice(allocator) };
}

fn callColumn(allocator: std.mem.Allocator, adapter_type: []const u8, name: []const u8, args: []const Argument) !?Value {
    const create = std.mem.eql(u8, name, "api.Column.create") or std.mem.eql(u8, name, "adapter.Column.create");
    if (create or std.mem.eql(u8, name, "api.Column") or std.mem.eql(u8, name, "adapter.Column")) {
        const column = named(args, if (create) "name" else "column", 0);
        const dtype = named(args, if (create) "label_or_dtype" else "dtype", 1);
        if (column != .string or dtype != .string) return error.InvalidJinjaArguments;
        var definition = ColumnDef{ .adapter_type = adapter_type, .column = column.string, .dtype = if (create and std.ascii.eqlIgnoreCase(dtype.string, "string")) "TEXT" else dtype.string };
        if (!create) {
            const size = named(args, "char_size", 2);
            if (size != .none and size != .undefined) {
                const count = expression.integerIndex(size) catch return error.InvalidJinjaArguments;
                if (count < 0) return error.InvalidJinjaArguments;
                definition.char_size = @intCast(count);
            }
            const precision = named(args, "numeric_precision", 3);
            const scale = named(args, "numeric_scale", 4);
            if (precision != .undefined) definition.numeric_precision = try @import("config_value.zig").fromExpression(allocator, precision);
            if (scale != .undefined) definition.numeric_scale = try @import("config_value.zig").fromExpression(allocator, scale);
        }
        return try columnValue(allocator, definition);
    }
    const prefix = "__dxt_column:";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    const boundary = std.mem.indexOfScalarPos(u8, name, prefix.len, ':') orelse return error.InvalidColumn;
    const method = name[prefix.len..boundary];
    const definition = (try std.json.parseFromSlice(ColumnDef, allocator, name[boundary + 1 ..], .{})).value;
    if (std.mem.eql(u8, method, "is_struct")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        return .{ .boolean = isStruct(definition) };
    }
    if (std.mem.eql(u8, method, "flatten")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        return try flattenColumn(allocator, definition);
    }
    if (std.mem.eql(u8, method, "is_number")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        const number_methods = [_][]const u8{ "is_integer", "is_numeric", "is_float" };
        for (number_methods) |numeric| {
            const callable = try std.fmt.allocPrint(allocator, "__dxt_column:{s}:{s}", .{ numeric, name[boundary + 1 ..] });
            if ((try callColumn(allocator, adapter_type, callable, &.{})).?.truthy()) return .{ .boolean = true };
        }
        return .{ .boolean = false };
    }
    if (std.mem.eql(u8, method, "literal")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
        return .{ .string = try std.fmt.allocPrint(allocator, "{s}::{s}", .{ try args[0].value.text(allocator), try columnDataType(allocator, definition) }) };
    }
    if (std.mem.eql(u8, method, "can_expand_to")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
        const other = args[0].value.attribute("__dxt_column");
        if (other != .string) return error.InvalidColumn;
        const other_definition = (try std.json.parseFromSlice(ColumnDef, allocator, other.string, .{})).value;
        return .{ .boolean = isString(definition.dtype) and isString(other_definition.dtype) and try columnStringSize(other_definition) > try columnStringSize(definition) };
    }
    if (args.len != 0) return error.InvalidJinjaArguments;
    if (std.mem.eql(u8, method, "string_size")) return try expression.integerValue(allocator, try columnStringSize(definition));
    if (std.mem.eql(u8, method, "is_string")) return .{ .boolean = isString(definition.dtype) };
    if (std.mem.eql(u8, method, "is_numeric")) return .{ .boolean = isNumeric(definition.dtype) };
    if (std.mem.eql(u8, method, "is_float")) {
        for ([_][]const u8{ "real", "float", "float4", "float8", "double", "double precision" }) |dtype| {
            if (std.mem.eql(u8, adapter_type, "duckdb") and std.mem.eql(u8, dtype, "double precision")) continue;
            if (std.ascii.eqlIgnoreCase(dtype, definition.dtype)) return .{ .boolean = true };
        }
        return .{ .boolean = false };
    }
    if (std.mem.eql(u8, method, "is_integer")) {
        const candidates: []const []const u8 = if (std.mem.eql(u8, adapter_type, "duckdb")) &.{ "tinyint", "smallint", "integer", "bigint", "hugeint", "utinyint", "usmallint", "uinteger", "ubigint", "int1", "int2", "int4", "int8", "short", "int", "signed", "long" } else &.{ "smallint", "integer", "bigint", "smallserial", "serial", "bigserial", "int2", "int4", "int8", "serial2", "serial4", "serial8" };
        for (candidates) |dtype| if (std.ascii.eqlIgnoreCase(dtype, definition.dtype)) return .{ .boolean = true };
        return .{ .boolean = false };
    }
    return error.UnsupportedColumnMethod;
}

fn isStruct(definition: ColumnDef) bool {
    return std.mem.eql(u8, definition.adapter_type, "duckdb") and definition.dtype.len >= 6 and std.ascii.eqlIgnoreCase(definition.dtype[0..6], "struct");
}

fn structFields(allocator: std.mem.Allocator, definition: ColumnDef) anyerror![]Value {
    if (!isStruct(definition) or definition.dtype.len < 8 or definition.dtype[6] != '(' or !std.mem.endsWith(u8, definition.dtype, ")")) return try expression.allocateValues(allocator, 0);
    const text = definition.dtype[7 .. definition.dtype.len - 1];
    var fields: std.ArrayList(Value) = .empty;
    var depth: usize = 0;
    var start: usize = 0;
    for (text, 0..) |byte, index| {
        if (byte == '(') depth += 1;
        if (byte == ')') {
            if (depth == 0) return error.InvalidColumn;
            depth -= 1;
        }
        if (byte == ',' and depth == 0) {
            try fields.append(allocator, try structField(allocator, text[start..index]));
            start = index + 1;
        }
    }
    if (depth != 0) return error.InvalidColumn;
    if (text.len != 0) try fields.append(allocator, try structField(allocator, text[start..]));
    return if (fields.items.len == 0) try expression.allocateValues(allocator, 0) else try fields.toOwnedSlice(allocator);
}

fn structField(allocator: std.mem.Allocator, raw: []const u8) !Value {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    const boundary = std.mem.indexOfScalar(u8, text, ' ') orelse return error.InvalidColumn;
    return try columnValue(allocator, .{ .column = text[0..boundary], .dtype = text[boundary + 1 ..] });
}

pub fn flattenColumn(allocator: std.mem.Allocator, definition: ColumnDef) anyerror!Value {
    if (!isStruct(definition)) return .{ .list = try allocator.dupe(Value, &.{try columnValue(allocator, definition)}) };
    var columns: std.ArrayList(Value) = .empty;
    for (try structFields(allocator, definition)) |field| {
        const serialized = field.attribute("__dxt_column");
        const child = (try std.json.parseFromSlice(ColumnDef, allocator, serialized.string, .{})).value;
        const flattened = try flattenColumn(allocator, child);
        for (flattened.list) |column| {
            const payload = column.attribute("__dxt_column");
            var leaf = (try std.json.parseFromSlice(ColumnDef, allocator, payload.string, .{})).value;
            leaf.column = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ definition.column, leaf.column });
            try columns.append(allocator, try columnValue(allocator, leaf));
        }
    }
    return .{ .list = if (columns.items.len == 0) try expression.allocateValues(allocator, 0) else try columns.toOwnedSlice(allocator) };
}

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
    const rendered = try renderRelation(allocator, definition);
    const class_name = if (definition.information_schema_relation) "InformationSchema" else if (std.mem.eql(u8, definition.adapter_type, "postgres")) "PostgresRelation" else "DuckDBRelation";
    var entries: std.ArrayList(expression.Entry) = .empty;
    try entries.appendSlice(allocator, &.{
        .{ .key = "__dxt_relation", .value = .{ .string = serialized } },
        .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
        .{ .key = "__dxt_relation_mapping", .value = .{ .callable = "__dxt_relation_mapping" } },
        .{ .key = "__dxt_rendered", .value = .{ .string = definition.rendered_sql orelse rendered } },
        .{ .key = "__dxt_repr", .value = .{ .string = try std.fmt.allocPrint(allocator, "<{s} {s}>", .{ class_name, rendered }) } },
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
    for ([_][]const u8{ "get", "render", "quote", "include", "incorporate", "replace_path", "without_identifier", "matches", "information_schema", "information_schema_only", "keys", "values", "items" }) |method| try entries.append(allocator, .{
        .key = method,
        .value = .{ .callable = try std.fmt.allocPrint(allocator, "__dxt_relation:{s}:{s}", .{ method, serialized }) },
    });
    if (!definition.information_schema_relation and std.mem.eql(u8, definition.adapter_type, "postgres")) try entries.append(allocator, .{
        .key = "relation_max_name_length",
        .value = .{ .callable = try std.fmt.allocPrint(allocator, "__dxt_relation:relation_max_name_length:{s}", .{serialized}) },
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
    if (try @import("postgres_index_context.zig").call(allocator, adapter_type, name, args)) |value| return value;
    if (try @import("regex_context.zig").call(allocator, name, args, null)) |value| return value;
    if (try @import("timestamp_context.zig").call(allocator, name, args)) |value| return value;
    if (try callColumn(allocator, adapter_type, name, args)) |value| return value;
    if (std.mem.eql(u8, name, "api.Relation.add_ephemeral_prefix") or std.mem.eql(u8, name, "adapter.Relation.add_ephemeral_prefix")) {
        if (args.len != 1 or args[0].value != .string) return error.InvalidJinjaArguments;
        return .{ .string = try std.fmt.allocPrint(allocator, "__dbt__cte__{s}", .{args[0].value.string}) };
    }
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
    if (std.mem.eql(u8, method, "relation_max_name_length")) {
        if (args.len != 0 or !std.mem.eql(u8, definition.adapter_type, "postgres") or definition.information_schema_relation) return error.InvalidJinjaArguments;
        return try expression.integerValue(allocator, 63);
    } else if (std.mem.eql(u8, method, "get")) {
        const key = named(args, "key", 0);
        if (key != .string or args.len > 2) return error.InvalidJinjaArguments;
        if (std.mem.eql(u8, key.string, "metadata")) return .{ .object = try allocator.dupe(expression.Entry, &.{.{ .key = "type", .value = .{ .string = if (definition.information_schema_relation) "InformationSchema" else if (std.mem.eql(u8, definition.adapter_type, "postgres")) "PostgresRelation" else "DuckDBRelation" } }}) };
        const value = try expression.checkedAttribute(try relationValue(allocator, definition), key.string);
        const fallback = named(args, "default", 1);
        return if (value == .undefined) (if (fallback == .undefined) Value.none else fallback) else value;
    } else if (std.mem.eql(u8, method, "keys") or std.mem.eql(u8, method, "values") or std.mem.eql(u8, method, "items")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        const view = try @import("expression_sequence.zig").view(allocator, try relationValue(allocator, definition), method);
        const entries = try expression.allocateEntries(allocator, view.object.len + 1);
        @memcpy(entries[0..view.object.len], view.object);
        entries[view.object.len] = .{ .key = "__dxt_len", .value = .{ .callable = try std.fmt.allocPrint(allocator, "__dxt_relation:mapping_length:{s}", .{name[boundary + 1 ..]}) } };
        return .{ .object = entries };
    } else if (std.mem.eql(u8, method, "mapping_length")) {
        return error.JinjaTypeError;
    } else if (std.mem.eql(u8, method, "render")) {
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
    try std.testing.expectEqualStrings("<DuckDBRelation \"warehouse\".\"main\".\"events\">", try expression.repr(relation, allocator));
}

test "Postgres relations expose the adapter name limit with Core arity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const postgres = try relationValue(a, .{ .adapter_type = "postgres", .identifier = "m" });
    const method = postgres.attribute("relation_max_name_length").callable;
    const maximum = (try call(a, "postgres", method, &.{})).?;
    try std.testing.expectEqual(@as(i64, 63), try expression.integerIndex(maximum));
    try std.testing.expectError(error.InvalidJinjaArguments, call(a, "postgres", method, &.{.{ .value = .none }}));
    const duckdb = try relationValue(a, .{ .identifier = "m" });
    try std.testing.expect(duckdb.attribute("relation_max_name_length") == .undefined);
}

test "macro value cloning preserves tuple keys and NaN key identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tuple: Value = .{ .tuple = try allocator.dupe(Value, &.{ .{ .integer = "1" }, .{ .string = "key" } }) };
    const nan = try expression.floatValue(allocator, std.math.nan(f64));
    var entries: std.ArrayList(expression.Entry) = .empty;
    try expression.mappingPut(allocator, &entries, tuple, .{ .string = "tuple" });
    try expression.mappingPut(allocator, &entries, nan, .{ .string = "nan" });
    const original: Value = .{ .object = try entries.toOwnedSlice(allocator) };
    const copied = try cloneValue(allocator, original);
    try std.testing.expectEqualStrings("tuple", (try expression.mappingGet(copied, tuple)).string);
    try std.testing.expectEqualStrings("nan", (try expression.mappingGet(copied, nan)).string);
    const another_nan = try expression.floatValue(allocator, std.math.nan(f64));
    try std.testing.expect((try expression.mappingGet(copied, another_nan)) == .undefined);
}

test "capture Undefined cloning owns payload and preserves scalar identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const original = try expression.captureUndefined(allocator, "missing");
    original.capture_undefined.hint = "context";
    const copied = try cloneValue(allocator, original);
    try std.testing.expect(copied.capture_undefined != original.capture_undefined);
    try std.testing.expectEqual(original.capture_undefined.identity, copied.capture_undefined.identity);
    try std.testing.expectEqualStrings("missing", copied.capture_undefined.name.?);
    try std.testing.expectEqualStrings("context", copied.capture_undefined.hint.?);
    try std.testing.expectError(error.JinjaTypeError, @import("context_json.zig").stringify(allocator, copied));
    const missing = try expression.undefinedValue(allocator, "missing");
    const duplicate = try cloneValue(allocator, missing);
    try std.testing.expect(duplicate == .ordinary_undefined);
    try std.testing.expectEqual(missing.ordinary_undefined.identity, duplicate.ordinary_undefined.identity);
    try std.testing.expectError(error.JinjaTypeError, @import("context_json.zig").stringify(allocator, duplicate));
}

test "Relation Mapping preserves provider methods and rejects dictionary consumers" {
    const Fixture = struct {
        relation: Value,
        fn resolve(raw: *anyopaque, name: []const u8, _: std.mem.Allocator) !Value {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return if (std.mem.eql(u8, name, "r")) self.relation else .undefined;
        }
        fn invoke(_: *anyopaque, name: []const u8, args: []const Argument, a: std.mem.Allocator) !Value {
            return (try call(a, "postgres", name, args)) orelse error.UnresolvedMacro;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture: Fixture = .{ .relation = try relationValue(a, .{ .adapter_type = "postgres", .database = "db", .schema = "main", .identifier = "events" }) };
    const host = expression.Host{ .context = &fixture, .resolve = Fixture.resolve, .call = Fixture.invoke };
    const methods = @import("builtin_bound_method.zig");
    try std.testing.expect(methods.isMapping(fixture.relation));
    try std.testing.expect(!methods.isDictionary(fixture.relation));
    try std.testing.expect((try expression.evaluate(a, "r is mapping", host)).boolean);
    try std.testing.expect(!(try expression.evaluate(a, "r is sequence", host)).boolean);
    try std.testing.expectEqualStrings("PostgresRelation", (try expression.evaluate(a, "r.get('metadata').type", host)).string);
    try std.testing.expectEqualStrings("fallback", (try expression.evaluate(a, "r.get('__dxt_relation_mapping', 'fallback')", host)).string);
    try std.testing.expect((try expression.evaluate(a, "'database' in r", host)).boolean);
    try std.testing.expect(!(try expression.evaluate(a, "'metadata' in r", host)).boolean);
    try std.testing.expect((try expression.evaluate(a, "r.keys() is iterable", host)).boolean);
    try std.testing.expectEqualStrings("KeysView(<PostgresRelation \"db\".\"main\".\"events\">)", (try expression.evaluate(a, "r.keys()|string", host)).string);
    try std.testing.expectError(error.JinjaTypeError, expression.evaluate(a, "r is iterable", host));
    try std.testing.expectError(error.JinjaTypeError, expression.evaluate(a, "r.keys()|list", host));
    try std.testing.expectError(error.JinjaTypeError, expression.evaluate(a, "dict(**r)", host));
    try std.testing.expectError(error.JinjaTypeError, @import("context_json.zig").stringify(a, fixture.relation));
    try std.testing.expectError(error.JinjaTypeError, @import("expression_json.zig").render(a, fixture.relation, null));
    try std.testing.expectError(error.InvalidConfiguration, @import("config_value.zig").fromExpression(a, fixture.relation));
    try std.testing.expect((try @import("container_methods.zig").call(a, "__dxt_value.clear", &.{.{ .value = fixture.relation }})) == null);
    const ordinary = try expression.evaluate(a, "{'__dxt_context_object':true,'__dxt_relation_mapping':['ordinary']}", null);
    try std.testing.expect(methods.isDictionary(ordinary));
    try std.testing.expectEqual(@as(usize, 2), (try methods.mappingEntries(ordinary)).len);
}
