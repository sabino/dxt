//! Native adapter rendering of Core column/model constraint records.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const Argument = expression.Argument;

pub fn columnNames(a: std.mem.Allocator, columns: Value) !Value {
    if (columns != .object) return error.InvalidConstraintConfiguration;
    var names: std.ArrayList([]const u8) = .empty;
    for (columns.object) |entry| {
        const column = entry.value;
        const name = column.attribute("name");
        if (name != .string) return error.InvalidConstraintConfiguration;
        try names.append(a, if (column.attribute("quote").truthy()) try @import("adapter.zig").quoteIdentifier(a, name.string) else name.string);
    }
    return .{ .string = try std.fmt.allocPrint(a, "({s})", .{try std.mem.join(a, ", ", names.items)}) };
}

pub fn call(a: std.mem.Allocator, adapter_type: []const u8, name: []const u8, args: []const Argument, host: expression.Host) !?Value {
    const columns = std.mem.eql(u8, name, "adapter.render_raw_columns_constraints");
    if (!columns and !std.mem.eql(u8, name, "adapter.render_raw_model_constraints")) return null;
    if (args.len != 1) return error.InvalidJinjaArguments;
    var rendered: std.ArrayList(Value) = .empty;
    if (columns) {
        if (args[0].value != .object) return error.InvalidConstraintConfiguration;
        for (args[0].value.object) |entry| {
            const column = entry.value;
            const dtype = column.attribute("data_type");
            const name_value = column.attribute("name");
            if (dtype != .string or name_value != .string) return error.ContractColumnTypeMissing;
            const column_name = if (column.attribute("quote").truthy()) try @import("adapter.zig").quoteIdentifier(a, name_value.string) else name_value.string;
            var sql: std.ArrayList(u8) = .empty;
            try sql.appendSlice(a, column_name);
            try sql.append(a, ' ');
            try sql.appendSlice(a, dtype.string);
            const constraints = column.attribute("constraints");
            if (constraints != .undefined and constraints != .none) for (try expression.iterableValues(a, constraints)) |constraint| {
                if (try render(a, adapter_type, constraint, false, host)) |clause| {
                    try sql.append(a, ' ');
                    try sql.appendSlice(a, clause);
                }
            };
            try rendered.append(a, .{ .string = try sql.toOwnedSlice(a) });
        }
    } else {
        for (try expression.iterableValues(a, args[0].value)) |constraint| if (try render(a, adapter_type, constraint, true, host)) |clause| try rendered.append(a, .{ .string = clause });
    }
    return .{ .list = if (rendered.items.len == 0) try expression.allocateValues(a, 0) else try rendered.toOwnedSlice(a) };
}

fn optional(value: Value) ![]const u8 {
    return switch (value) {
        .string => value.string,
        .none, .undefined => "",
        else => error.InvalidConstraintConfiguration,
    };
}

fn joined(a: std.mem.Allocator, value: Value) ![]const u8 {
    if (value == .undefined or value == .none) return "";
    const items = try expression.iterableValues(a, value);
    const strings = try a.alloc([]const u8, items.len);
    for (items, strings) |item, *text| {
        if (item != .string) return error.InvalidConstraintConfiguration;
        text.* = item.string;
    }
    return std.mem.join(a, ", ", strings);
}

fn render(a: std.mem.Allocator, adapter_type: []const u8, constraint: Value, model: bool, host: expression.Host) !?[]const u8 {
    if (constraint != .object) return error.InvalidConstraintConfiguration;
    const type_value = constraint.attribute("type");
    if (type_value != .string) return error.InvalidConstraintConfiguration;
    const kind = type_value.string;
    const extra = try optional(constraint.attribute("expression"));
    const name = try optional(constraint.attribute("name"));
    const prefix = if (model and name.len != 0) try std.fmt.allocPrint(a, "constraint {s} ", .{name}) else "";
    var columns: []const u8 = "";
    if (model) columns = try joined(a, constraint.attribute("columns"));
    if (std.mem.eql(u8, kind, "check")) return if (extra.len == 0) null else try std.fmt.allocPrint(a, "{s}check ({s})", .{ prefix, extra });
    if (std.mem.eql(u8, kind, "not_null")) return if (model) null else try std.fmt.allocPrint(a, "not null{s}{s}", .{ if (extra.len == 0) "" else " ", extra });
    if (std.mem.eql(u8, kind, "unique") or std.mem.eql(u8, kind, "primary_key")) {
        const keyword = if (std.mem.eql(u8, kind, "unique")) "unique" else "primary key";
        return if (model) try std.fmt.allocPrint(a, "{s}{s}{s}{s} ({s})", .{ prefix, keyword, if (extra.len == 0) "" else " ", extra, columns }) else try std.fmt.allocPrint(a, "{s}{s}{s}", .{ keyword, if (extra.len == 0) "" else " ", extra });
    }
    if (std.mem.eql(u8, kind, "foreign_key")) {
        const target = try optional(constraint.attribute("to"));
        const target_columns = try joined(a, constraint.attribute("to_columns"));
        const reference = if (target.len != 0 and target_columns.len != 0) blk: {
            const relation = try expression.evaluate(a, target, host);
            var definition = try @import("dbt_context.zig").relationFromValue(a, relation);
            definition.rendered_sql = null;
            break :blk try std.fmt.allocPrint(a, "{s} ({s})", .{ try @import("dbt_context.zig").renderRelation(a, definition), target_columns });
        } else extra;
        if (reference.len == 0) return null;
        return if (model) try std.fmt.allocPrint(a, "{s}foreign key ({s}) references {s}", .{ prefix, columns, reference }) else try std.fmt.allocPrint(a, "references {s}", .{reference});
    }
    if (std.mem.eql(u8, kind, "custom")) return if (extra.len == 0) null else try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, extra });
    _ = adapter_type; // Both supported native adapters enforce all six kinds.
    return error.InvalidConstraintType;
}
