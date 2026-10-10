//! Model contracts use Core's declared schema and constraint checksum.
const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");
const expression = @import("expression.zig");
const compiler = @import("compiler.zig");

pub fn enforced(node: *const types.Node) bool {
    const contract = values.get(node.effective_config, "contract") orelse return false;
    const setting = values.get(contract, "enforced") orelse return false;
    return setting == .bool and setting.bool;
}

pub fn normalize(allocator: std.mem.Allocator, input: std.json.Value, model: bool) !std.json.Value {
    var result: std.json.Value = .{ .array = std.json.Array.init(allocator) };
    errdefer values.deinit(allocator, &result);
    if (input == .null) return result;
    if (input != .array) return error.InvalidConstraintConfiguration;
    for (input.array.items) |constraint| {
        if (constraint != .object) return error.InvalidConstraintConfiguration;
        const kind = values.get(constraint, "type") orelse return error.InvalidConstraintConfiguration;
        if (kind != .string or !validType(kind.string)) return error.InvalidConstraintType;
        var normalized: std.json.Value = .{ .object = .empty };
        errdefer values.deinit(allocator, &normalized);
        inline for (.{ "type", "name", "expression", "warn_unenforced", "warn_unsupported", "to", "to_columns" }) |key| {
            const fallback: std.json.Value = if (std.mem.startsWith(u8, key, "warn_")) .{ .bool = true } else if (std.mem.eql(u8, key, "to_columns")) .{ .array = std.json.Array.init(allocator) } else .null;
            const field = values.get(constraint, key) orelse fallback;
            if (std.mem.startsWith(u8, key, "warn_")) {
                if (field != .bool) return error.InvalidConstraintConfiguration;
            } else if (std.mem.eql(u8, key, "to_columns")) {
                try validateStrings(field);
            } else if (field != .string and field != .null) return error.InvalidConstraintConfiguration;
            try values.put(allocator, &normalized, key, field);
        }
        if (model) {
            const columns = values.get(constraint, "columns") orelse std.json.Value{ .array = std.json.Array.init(allocator) };
            try validateStrings(columns);
            try values.put(allocator, &normalized, "columns", columns);
        }
        try result.array.append(normalized);
    }
    return result;
}

fn validateStrings(value: std.json.Value) !void {
    if (value != .array) return error.InvalidConstraintConfiguration;
    for (value.array.items) |item| if (item != .string) return error.InvalidConstraintConfiguration;
}

fn validType(kind: []const u8) bool {
    for ([_][]const u8{ "check", "not_null", "unique", "primary_key", "foreign_key", "custom" }) |supported| if (std.mem.eql(u8, kind, supported)) return true;
    return false;
}

pub fn modelConstraints(allocator: std.mem.Allocator, node: *const types.Node) !std.json.Value {
    return normalize(allocator, values.get(node.properties, "constraints") orelse .null, true);
}

/// Constraints contribute dependency edges even when the SQL has no ref.
pub fn finalize(runtime: types.Runtime, graph: *types.Graph) !void {
    for (graph.nodes.items) |*node| {
        if (!std.mem.eql(u8, node.resource_type, "model")) continue;
        var scratch = std.heap.ArenaAllocator.init(runtime.allocator);
        defer scratch.deinit();
        const allocator = scratch.allocator();
        const configured_contract = values.get(node.effective_config, "contract") orelse .null;
        if (configured_contract != .null and configured_contract != .object) return error.InvalidModelContract;
        if (values.get(configured_contract, "enforced")) |setting| if (setting != .bool) return error.InvalidModelContract;
        if (values.get(configured_contract, "alias_types")) |setting| if (setting != .bool) return error.InvalidModelContract;
        const model = try modelConstraints(allocator, node);
        var model_pk = false;
        var unsupported_warning = false;
        for (model.array.items) |constraint| {
            model_pk = model_pk or isType(constraint, "primary_key");
            unsupported_warning = unsupported_warning or constraint.object.get("warn_unsupported").?.bool;
            try captureReference(runtime.allocator, graph, node, constraint);
        }
        var column_pk: usize = 0;
        for (node.columns.items) |column| {
            const constraints = try normalize(allocator, values.get(column.properties, "constraints") orelse .null, false);
            for (constraints.array.items) |constraint| {
                if (isType(constraint, "primary_key")) column_pk += 1;
                unsupported_warning = unsupported_warning or constraint.object.get("warn_unsupported").?.bool;
                try captureReference(runtime.allocator, graph, node, constraint);
            }
        }
        if (column_pk > 1 or (column_pk != 0 and model_pk)) return error.InvalidPrimaryKeyConstraints;
        if (enforced(node)) {
            if (node.patch_path != null and unsupported_warning and !std.mem.eql(u8, node.materialized, "table") and !std.mem.eql(u8, node.materialized, "incremental")) {
                const message = try std.fmt.allocPrint(graph.allocator, "Constraint types are not supported for {s} materializations and will be ignored.  Set 'warn_unsupported: false' on this constraint to ignore this warning.", .{node.materialized});
                errdefer graph.allocator.free(message);
                try graph.constraint_warnings.append(graph.allocator, message);
            }
            if (node.patch_path != null and (!std.mem.eql(u8, node.language, "sql") or node.columns.items.len == 0)) return error.InvalidModelContract;
            if (std.mem.eql(u8, node.materialized, "incremental")) {
                const policy = node.incremental.on_schema_change orelse "ignore";
                if (!std.mem.eql(u8, policy, "fail") and !std.mem.eql(u8, policy, "append_new_columns")) return error.InvalidIncrementalContractSchemaPolicy;
            }
        }
    }
}

fn isType(constraint: std.json.Value, kind: []const u8) bool {
    const name = values.get(constraint, "type") orelse return false;
    return name == .string and std.mem.eql(u8, name.string, kind);
}

fn captureReference(allocator: std.mem.Allocator, graph: *const types.Graph, node: *types.Node, constraint: std.json.Value) !void {
    const target = values.get(constraint, "to") orelse return;
    if (!isType(constraint, "foreign_key") or target == .null) return;
    const text = std.mem.trim(u8, target.string, " \t\r\n");
    if ((!std.mem.startsWith(u8, text, "ref(") and !std.mem.startsWith(u8, text, "source(")) or !std.mem.endsWith(u8, text, ")")) return error.InvalidForeignKeyConstraintReference;
    const sql = try std.fmt.allocPrint(allocator, "{{{{ {s} }}}}", .{text});
    defer allocator.free(sql);
    @import("jinja.zig").scanSql(allocator, sql, node, graph) catch return error.InvalidForeignKeyConstraintReference;
}

pub fn metadata(allocator: std.mem.Allocator, node: *const types.Node) !std.json.Value {
    const contract = values.get(node.effective_config, "contract") orelse .null;
    const aliases = values.get(contract, "alias_types") orelse std.json.Value{ .bool = true };
    if (aliases != .bool) return error.InvalidModelContract;
    var result: std.json.Value = .{ .object = .empty };
    errdefer values.deinit(allocator, &result);
    try values.put(allocator, &result, "enforced", .{ .bool = enforced(node) });
    try values.put(allocator, &result, "alias_types", aliases);
    const digest = if (enforced(node) and node.patch_path != null) try checksum(allocator, node) else null;
    defer if (digest) |text| allocator.free(text);
    try values.put(allocator, &result, "checksum", if (digest) |text| .{ .string = text } else .null);
    return result;
}

fn checksum(allocator: std.mem.Allocator, node: *const types.Node) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var output: std.Io.Writer.Allocating = .init(scratch);
    const columns = try scratch.dupe(types.ColumnDef, node.columns.items);
    std.mem.sort(types.ColumnDef, columns, {}, struct {
        fn less(_: void, a: types.ColumnDef, b: types.ColumnDef) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.less);
    for (columns) |column| {
        try output.writer.print("|{s}{s}", .{ column.name, column.data_type orelse "None" });
        try constraintRepr(scratch, &output.writer, try normalize(scratch, values.get(column.properties, "constraints") orelse .null, false), false);
    }
    if (std.mem.eql(u8, node.materialized, "table") or std.mem.eql(u8, node.materialized, "incremental")) {
        try output.writer.writeAll(node.materialized);
        try constraintRepr(scratch, &output.writer, try modelConstraints(scratch, node), true);
    }
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output.written(), &hash, .{});
    return allocator.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}

fn constraintRepr(allocator: std.mem.Allocator, writer: *std.Io.Writer, constraints: std.json.Value, model: bool) !void {
    try writer.writeByte('[');
    for (constraints.array.items, 0..) |constraint, index| {
        if (index != 0) try writer.writeAll(", ");
        const kind = values.get(constraint, "type").?.string;
        try writer.print("{s}LevelConstraint(type=<ConstraintType.{s}: '{s}'>", .{ if (model) "Model" else "Column", kind, kind });
        inline for (.{ "name", "expression", "warn_unenforced", "warn_unsupported", "to", "to_columns" }) |key| {
            try writer.print(", {s}={s}", .{ key, try expression.repr(try values.toExpression(allocator, values.get(constraint, key).?), allocator) });
        }
        if (model) try writer.print(", columns={s}", .{try expression.repr(try values.toExpression(allocator, values.get(constraint, "columns").?), allocator)});
        try writer.writeByte(')');
    }
    try writer.writeByte(']');
}

pub fn renderCreation(allocator: std.mem.Allocator, graph: *const types.Graph, node: *const types.Node, relation_sql: []const u8, sql: []const u8, kind: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    var definition = try @import("dbt_context.zig").relationFromValue(scratch, try compiler.relationValueForNode(scratch, graph, node, false));
    definition.relation_type = kind;
    definition.base_sql = relation_sql;
    const relation = try @import("dbt_context.zig").relationValue(scratch, definition);
    const args = if (std.mem.eql(u8, kind, "table")) &[_]expression.Argument{
        .{ .name = "temporary", .value = .{ .boolean = false } }, .{ .name = "relation", .value = relation }, .{ .name = "compiled_code", .value = .{ .string = sql } },
    } else &[_]expression.Argument{ .{ .name = "relation", .value = relation }, .{ .name = "sql", .value = .{ .string = sql } } };
    const rendered = try compiler.renderMacroForNode(scratch, graph, node, if (std.mem.eql(u8, kind, "table")) "create_table_as" else "get_create_view_as_sql", args);
    return allocator.dupe(u8, try rendered.text(scratch));
}

/// The artifact retains authored constraints during parse and contains resolved
/// relation names after compilation. The checksum always uses authored values.
pub fn artifactConstraints(allocator: std.mem.Allocator, graph: *const types.Graph, node: *const types.Node, raw: std.json.Value, model: bool) !std.json.Value {
    var result = try normalize(allocator, raw, model);
    errdefer values.deinit(allocator, &result);
    if (!node.compiled) return result;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    for (result.array.items) |*constraint| {
        if (!isType(constraint.*, "foreign_key")) continue;
        const target = values.get(constraint.*, "to") orelse continue;
        if (target == .null or target.string.len == 0) continue;
        const rendered = try compiler.renderGenericArgumentValue(scratch, graph, node, target);
        var definition = try @import("dbt_context.zig").relationFromValue(scratch, rendered);
        definition.rendered_sql = null;
        const sql = try @import("dbt_context.zig").renderRelation(scratch, definition);
        try values.put(allocator, constraint, "to", .{ .string = sql });
    }
    return result;
}

test "normalized constraints own defaults and reject invalid records" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "[{\"type\":\"not_null\"}]", .{});
    defer parsed.deinit();
    var normalized = try normalize(allocator, parsed.value, false);
    defer values.deinit(allocator, &normalized);
    try std.testing.expectEqual(true, normalized.array.items[0].object.get("warn_unenforced").?.bool);
    try std.testing.expectEqual(@as(usize, 0), normalized.array.items[0].object.get("to_columns").?.array.items.len);
    const invalid = try std.json.parseFromSlice(std.json.Value, allocator, "[{\"type\":\"check\",\"warn_unsupported\":\"yes\"}]", .{});
    defer invalid.deinit();
    try std.testing.expectError(error.InvalidConstraintConfiguration, normalize(allocator, invalid.value, false));
}

test "contract checksum matches the pinned Core declared constraint preimage" {
    const allocator = std.testing.allocator;
    const config = try std.json.parseFromSlice(std.json.Value, allocator, "{\"contract\":{\"enforced\":true}}", .{});
    defer config.deinit();
    const model = try std.json.parseFromSlice(std.json.Value, allocator, "{\"constraints\":[{\"type\":\"primary_key\",\"columns\":[\"id\"]},{\"type\":\"unique\",\"columns\":[\"label\"],\"name\":\"unique_label\"}]}", .{});
    defer model.deinit();
    const column = try std.json.parseFromSlice(std.json.Value, allocator, "{\"constraints\":[{\"type\":\"not_null\"},{\"type\":\"check\",\"expression\":\"id > 0\"}]}", .{});
    defer column.deinit();
    var node = types.Node{ .unique_id = "model.fixture.rendered", .package_name = "fixture", .name = "rendered", .path = "rendered.sql", .original_file_path = "models/rendered.sql", .raw_code = "select 1", .materialized = "table", .effective_config = config.value, .properties = model.value };
    try node.columns.append(allocator, .{ .name = "label", .data_type = "string" });
    try node.columns.append(allocator, .{ .name = "id", .data_type = "integer", .properties = column.value });
    defer node.columns.deinit(allocator);
    const digest = try checksum(allocator, &node);
    defer allocator.free(digest);
    try std.testing.expectEqualStrings("1eb6de7c679935b1b56f14a807bd0f784718464d5992e5365df82b3f3dc2d4a2", digest);
}
