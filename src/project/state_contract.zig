//! Core 1.10.5 ModelNode.same_contract / same_contract_removed diagnostics.
//! Run once before command publication or execution, independently of boolean
//! predicates: body/config changes must never short-circuit a breaking change.
const std = @import("std");
const state = @import("state.zig");
const types = @import("types.zig");
const clock = @import("execution_clock.zig");
const field = state.valueField;
const text = state.stringField;
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

const ColumnTypeChange = struct { column_name: []const u8, previous_column_type: []const u8, current_column_type: []const u8 };
const ColumnConstraintChange = struct { column_name: []const u8, constraint_name: ?[]const u8, constraint_type: []const u8 };
const ModelConstraintChange = struct { constraint_name: ?[]const u8, constraint_type: []const u8, columns: []const []const u8 };
const ColumnConstraintData = struct { column_name: []const u8, constraint_name: []const u8, constraint_type: []const u8 };
const ModelConstraintData = struct { constraint_name: []const u8, constraint_type: []const u8, columns: []const []const u8 };
pub const Change = struct {
    contract_enforced_disabled: bool = false,
    columns_removed: std.ArrayList([]const u8) = .empty,
    column_type_changes: std.ArrayList(ColumnTypeChange) = .empty,
    enforced_column_constraint_removed: std.ArrayList(ColumnConstraintChange) = .empty,
    enforced_model_constraint_removed: std.ArrayList(ModelConstraintChange) = .empty,
    materialization_changed: ?[2][]const u8 = null,
    breaking_changes: std.ArrayList([]const u8) = .empty,

    pub fn breaking(self: Change) bool {
        return self.breaking_changes.items.len != 0;
    }
};

fn enforced(node: Value) bool {
    const contract = field(node, "contract") orelse field(field(node, "config") orelse .null, "contract") orelse .null;
    const setting = field(contract, "enforced") orelse return false;
    return setting == .bool and setting.bool;
}
fn config(node: Value) Value {
    return field(node, "config") orelse .null;
}
fn constraints(node: Value) []const Value {
    const value = field(node, "constraints") orelse return &.{};
    return if (value == .array) value.array.items else &.{};
}
fn containsConstraint(current: []const Value, previous: Value) bool {
    for (current) |candidate| if (state.equalValues(candidate, previous)) return true;
    return false;
}
fn materialized(node: Value) []const u8 {
    return text(config(node), "materialized") orelse "view";
}
fn materializationEnforces(node: Value) bool {
    const kind = materialized(node);
    return std.mem.eql(u8, kind, "table") or std.mem.eql(u8, kind, "incremental");
}
fn constraintEnforced(adapter: []const u8, kind: []const u8) bool {
    if (!std.mem.eql(u8, adapter, "duckdb") and !std.mem.eql(u8, adapter, "postgres")) return false;
    // Both pinned adapters declare exactly these five ENFORCED capabilities.
    // `custom` is absent upstream; do not invent a capability for raw DDL.
    for ([_][]const u8{ "check", "not_null", "unique", "primary_key", "foreign_key" }) |supported| if (std.mem.eql(u8, supported, kind)) return true;
    return false;
}
fn strings(allocator: Allocator, value: ?Value) ![]const []const u8 {
    const array = value orelse return &.{};
    if (array != .array) return &.{};
    var result: std.ArrayList([]const u8) = .empty;
    for (array.array.items) |item| if (item == .string) try result.append(allocator, item.string);
    return result.toOwnedSlice(allocator);
}
fn pastDeprecation(allocator: Allocator, node: Value, now_ns: i96) !bool {
    const date = text(node, "deprecation_date") orelse return false;
    const parsed = @import("datetime_parse.zig").iso(allocator, date, false) catch return false;
    return parsed.civil_ns - @as(i96, parsed.offset_us orelse 0) * std.time.ns_per_us < now_ns;
}
fn scalarText(allocator: Allocator, value: ?Value) ![]const u8 {
    const item = value orelse .null;
    if (item == .string) return item.string;
    if (item == .null) return "None";
    return std.json.Stringify.valueAlloc(allocator, item, .{});
}

/// Allocations belong to a caller's scratch arena. Records borrow manifest
/// strings; the comparison never mutates current or prior artifacts.
pub fn classify(allocator: Allocator, old: Value, new: ?Value, adapter: []const u8, now_ns: i96) !Change {
    var result: Change = .{};
    if (!enforced(old)) return result;
    if (new == null) {
        if (try pastDeprecation(allocator, old, now_ns)) return result;
        const enabled: Value = field(config(old), "enabled") orelse .{ .bool = true };
        const action = if (enabled == .bool and !enabled.bool) "disabled" else "deleted or renamed";
        try result.breaking_changes.append(allocator, try std.fmt.allocPrint(allocator, "Contracted model '{s}' was {s}.", .{ text(old, "unique_id") orelse text(old, "name") orelse "", action }));
        return result;
    }
    const current = new.?;
    if (state.sameContract(old, current)) return result;
    result.contract_enforced_disabled = !enforced(current);
    const old_columns = field(old, "columns") orelse .null;
    const new_columns = field(current, "columns") orelse .null;
    var keys: std.ArrayList([]const u8) = .empty;
    if (old_columns == .object) {
        var iter = old_columns.object.iterator();
        while (iter.next()) |entry| try keys.append(allocator, entry.key_ptr.*);
    }
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var column_constraints_exist = false;
    for (keys.items) |key| {
        const prior = field(old_columns, key).?;
        const next = field(new_columns, key);
        const name = text(prior, "name") orelse key;
        if (next == null) {
            try result.columns_removed.append(allocator, name);
        } else if (!state.equalValues(field(prior, "data_type") orelse .null, field(next.?, "data_type") orelse .null)) {
            try result.column_type_changes.append(allocator, .{ .column_name = name, .previous_column_type = try scalarText(allocator, field(prior, "data_type")), .current_column_type = try scalarText(allocator, field(next.?, "data_type")) });
        }
        column_constraints_exist = column_constraints_exist or constraints(prior).len != 0;
        if (next != null and materializationEnforces(old)) {
            for (constraints(prior)) |constraint| {
                const kind = text(constraint, "type") orelse continue;
                if (!containsConstraint(constraints(next.?), constraint) and constraintEnforced(adapter, kind)) {
                    try result.enforced_column_constraint_removed.append(allocator, .{ .column_name = key, .constraint_name = text(constraint, "name"), .constraint_type = kind });
                }
            }
        }
    }
    if (materializationEnforces(old)) {
        for (constraints(old)) |constraint| {
            const kind = text(constraint, "type") orelse continue;
            if (!containsConstraint(constraints(current), constraint) and constraintEnforced(adapter, kind)) {
                try result.enforced_model_constraint_removed.append(allocator, .{ .constraint_name = text(constraint, "name"), .constraint_type = kind, .columns = try strings(allocator, field(constraint, "columns")) });
            }
        }
        if (!materializationEnforces(current) and (constraints(old).len != 0 or column_constraints_exist)) result.materialization_changed = .{ materialized(old), materialized(current) };
    }
    try buildReasons(allocator, &result);
    return result;
}

fn buildReasons(allocator: Allocator, result: *Change) !void {
    if (result.contract_enforced_disabled) try result.breaking_changes.append(allocator, "Contract enforcement was removed: Previously, this model had an enforced contract. It is no longer configured to enforce its contract, and this is a breaking change.");
    var out: std.Io.Writer.Allocating = .init(allocator);
    if (result.columns_removed.items.len != 0) {
        try out.writer.writeAll("Columns were removed: ");
        for (result.columns_removed.items) |name| try out.writer.print("\n    - {s}", .{name});
        try result.breaking_changes.append(allocator, try out.toOwnedSlice());
    }
    if (result.column_type_changes.items.len != 0) {
        try out.writer.writeAll("Columns with data_type changes: ");
        for (result.column_type_changes.items) |change| try out.writer.print("\n    - {s} ({s} -> {s})", .{ change.column_name, change.previous_column_type, change.current_column_type });
        try result.breaking_changes.append(allocator, try out.toOwnedSlice());
    }
    if (result.enforced_column_constraint_removed.items.len != 0) {
        try out.writer.writeAll("Enforced column level constraints were removed: ");
        for (result.enforced_column_constraint_removed.items) |change| {
            // Core's unnamed constraint display uses the enum's Python str.
            const label = change.constraint_name orelse try std.fmt.allocPrint(allocator, "ConstraintType.{s}", .{change.constraint_type});
            try out.writer.print("\n    - '{s}' constraint on column {s}", .{ label, change.column_name });
        }
        try result.breaking_changes.append(allocator, try out.toOwnedSlice());
    }
    if (result.enforced_model_constraint_removed.items.len != 0) {
        try out.writer.writeAll("Enforced model level constraints were removed: ");
        for (result.enforced_model_constraint_removed.items) |change| {
            const label = change.constraint_name orelse try std.fmt.allocPrint(allocator, "ConstraintType.{s}", .{change.constraint_type});
            try out.writer.print("\n    - '{s}' constraint on columns [", .{label});
            for (change.columns, 0..) |column, index| {
                if (index != 0) try out.writer.writeAll(", ");
                // Core formats a Python string list; repr preserves quotes and escapes.
                try out.writer.writeAll(try @import("expression.zig").repr(.{ .string = column }, allocator));
            }
            try out.writer.writeByte(']');
        }
        try result.breaking_changes.append(allocator, try out.toOwnedSlice());
    }
    if (result.materialization_changed) |change| {
        try result.breaking_changes.append(allocator, try std.fmt.allocPrint(allocator, "Materialization changed with enforced constraints: \n    - {s} -> {s}", .{ change[0], change[1] }));
    }
}

fn report(runtime: types.Runtime, old: Value, new: ?Value, adapter: []const u8, now_ns: i96, writer: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(runtime.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const change = try classify(allocator, old, new, adapter, now_ns);
    if (!change.breaking()) return;
    const node = new orelse old;
    const name = text(node, "name") orelse "";
    const path = text(node, "original_file_path") orelse "";
    var out: std.Io.Writer.Allocating = .init(allocator);
    const version = field(node, "version") orelse .null;
    if (version == .null) {
        try out.writer.print("Breaking change to contracted, unversioned model {s} ({s})\nWhile comparing to previous project state, dbt detected a breaking change to an unversioned model.", .{ name, path });
        for (change.breaking_changes.items) |reason| try out.writer.print("\n  - {s}", .{reason});
        try out.writer.writeByte('\n');
        // Core's protobuf event converts optional constraint names to empty
        // strings. Preserve null internally for its enum-label reason text.
        const column_data = try allocator.alloc(ColumnConstraintData, change.enforced_column_constraint_removed.items.len);
        for (column_data, change.enforced_column_constraint_removed.items) |*data, item| data.* = .{ .column_name = item.column_name, .constraint_name = item.constraint_name orelse "", .constraint_type = item.constraint_type };
        const model_data = try allocator.alloc(ModelConstraintData, change.enforced_model_constraint_removed.items.len);
        for (model_data, change.enforced_model_constraint_removed.items) |*data, item| data.* = .{ .constraint_name = item.constraint_name orelse "", .constraint_type = item.constraint_type, .columns = item.columns };
        try @import("selection_warnings.zig").warningWithData(runtime, writer, "UnversionedBreakingChange", "I071", out.written(), .{
            .contract_enforced_disabled = change.contract_enforced_disabled,
            .columns_removed = change.columns_removed.items,
            .column_type_changes = change.column_type_changes.items,
            .enforced_column_constraint_removed = column_data,
            .enforced_model_constraint_removed = model_data,
            .breaking_changes = change.breaking_changes.items,
            .model_name = name,
            .model_file_path = path,
        });
    } else {
        try out.writer.writeAll("While comparing to previous project state, dbt detected a breaking change to an enforced contract.");
        for (change.breaking_changes.items) |reason| try out.writer.print("\n  - {s}", .{reason});
        try out.writer.writeAll("\nConsider making an additive (non-breaking) change instead, if possible.\nOtherwise, create a new model version: https://docs.getdbt.com/docs/collaborate/govern/model-versions");
        @import("compile_diagnostics.zig").captureError(path, name, out.written(), error.ContractBreakingChange);
        return error.ContractBreakingChange;
    }
}

pub fn check(runtime: types.Runtime, prior: *const state.PriorManifestIndex, current: *const state.PriorManifestIndex, adapter: []const u8, writer: *std.Io.Writer) !void {
    const previous_root = if (prior.parsed) |parsed| parsed.value else return;
    const current_root = if (current.parsed) |parsed| parsed.value else return;
    const nodes = field(previous_root, "nodes") orelse return;
    if (nodes != .object) return;
    const disabled = field(current_root, "disabled") orelse .null;
    const now_ns = clock.now(runtime.io);
    var iter = nodes.object.iterator();
    while (iter.next()) |entry| {
        if (!std.mem.eql(u8, text(entry.value_ptr.*, "resource_type") orelse "", "model")) continue;
        if (current.resource(entry.key_ptr.*)) |next| {
            try report(runtime, entry.value_ptr.*, next, adapter, now_ns, writer);
        } else {
            // Core compares the current disabled definition when one exists;
            // otherwise the deleted/renamed model is the previous definition.
            const removed = if (field(disabled, entry.key_ptr.*)) |values| if (values == .array and values.array.items.len != 0) values.array.items[0] else entry.value_ptr.* else entry.value_ptr.*;
            try report(runtime, removed, null, adapter, now_ns, writer);
        }
    }
}

test "state contracts classify enforcement columns and additive changes independently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prior = try std.json.parseFromSlice(Value, a, "{\"contract\":{\"enforced\":true,\"checksum\":\"old\"},\"columns\":{\"z\":{\"name\":\"z\",\"data_type\":\"int\"},\"a\":{\"name\":\"a\",\"data_type\":\"int\"}}}", .{});
    const changed = try std.json.parseFromSlice(Value, a, "{\"contract\":{\"enforced\":false},\"raw_code\":\"changed\",\"columns\":{\"z\":{\"name\":\"z\",\"data_type\":\"bigint\"}}}", .{});
    const result = try classify(a, prior.value, changed.value, "duckdb", 0);
    try std.testing.expect(result.contract_enforced_disabled);
    try std.testing.expectEqualStrings("a", result.columns_removed.items[0]);
    try std.testing.expectEqualStrings("z", result.column_type_changes.items[0].column_name);
    try std.testing.expectEqual(@as(usize, 3), result.breaking_changes.items.len);
    const added = try std.json.parseFromSlice(Value, a, "{\"contract\":{\"enforced\":true,\"checksum\":\"new\"},\"columns\":{\"a\":{\"name\":\"a\",\"data_type\":\"int\"},\"z\":{\"name\":\"z\",\"data_type\":\"int\"},\"b\":{\"name\":\"b\",\"data_type\":\"int\"}}}", .{});
    try std.testing.expect(!(try classify(a, prior.value, added.value, "duckdb", 0)).breaking());
    try std.testing.expect(!(try classify(a, changed.value, prior.value, "duckdb", 0)).breaking());
}

test "state contracts capability filtering compares full records and materialization boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "duckdb", "postgres" }) |adapter| {
        for ([_][]const u8{ "check", "not_null", "unique", "primary_key", "foreign_key", "custom" }) |kind| {
            const source = try std.fmt.allocPrint(a, "{{\"contract\":{{\"enforced\":true,\"checksum\":\"old\"}},\"config\":{{\"materialized\":\"table\"}},\"constraints\":[{{\"type\":\"{s}\",\"columns\":[\"id\"]}}],\"columns\":{{\"id\":{{\"data_type\":\"int\",\"constraints\":[{{\"type\":\"{s}\",\"name\":\"named\"}}]}}}}}}", .{ kind, kind });
            const prior = try std.json.parseFromSlice(Value, a, source, .{});
            const current = try std.json.parseFromSlice(Value, a, "{\"contract\":{\"enforced\":true,\"checksum\":\"new\"},\"config\":{\"materialized\":\"incremental\"},\"columns\":{\"id\":{\"data_type\":\"int\"}}}", .{});
            const result = try classify(a, prior.value, current.value, adapter, 0);
            const expected: usize = if (std.mem.eql(u8, kind, "custom")) 0 else 1;
            try std.testing.expectEqual(expected, result.enforced_column_constraint_removed.items.len);
            try std.testing.expectEqual(expected, result.enforced_model_constraint_removed.items.len);
            try std.testing.expect(result.materialization_changed == null);
            const view = try std.json.parseFromSlice(Value, a, "{\"contract\":{\"enforced\":true,\"checksum\":\"new\"},\"config\":{\"materialized\":\"view\"},\"columns\":{\"id\":{\"data_type\":\"int\"}}}", .{});
            const transition = try classify(a, prior.value, view.value, adapter, 0);
            try std.testing.expectEqualStrings("table", transition.materialization_changed.?[0]);
            try std.testing.expectEqualStrings("view", transition.materialization_changed.?[1]);
            try prior.value.object.getPtr("config").?.object.put(a, "materialized", .{ .string = "view" });
            try std.testing.expect(!(try classify(a, prior.value, current.value, adapter, 0)).breaking());
        }
    }
}

test "state contracts removed nodes honor disabled definition and strict deprecation boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prior = try std.json.parseFromSlice(Value, a, "{\"unique_id\":\"model.p.a\",\"contract\":{\"enforced\":true},\"config\":{\"enabled\":false},\"deprecation_date\":\"1970-01-01T01:00:00+01:00\"}", .{});
    const equal = try classify(a, prior.value, null, "duckdb", 0);
    try std.testing.expectEqualStrings("Contracted model 'model.p.a' was disabled.", equal.breaking_changes.items[0]);
    try std.testing.expect(!(try classify(a, prior.value, null, "duckdb", 1)).breaking());
    try prior.value.object.put(a, "deprecation_date", .null);
    try prior.value.object.getPtr("config").?.object.put(a, "enabled", .{ .bool = true });
    try std.testing.expectEqualStrings("Contracted model 'model.p.a' was deleted or renamed.", (try classify(a, prior.value, null, "postgres", 1)).breaking_changes.items[0]);
}

test "state contracts compare constraint membership rather than order and retain full record changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = "{\"contract\":{\"enforced\":true,\"checksum\":\"old\"},\"config\":{\"materialized\":\"incremental\"},\"constraints\":[{\"type\":\"check\",\"name\":\"positive\",\"expression\":\"id > 0\",\"warn_unenforced\":true},{\"type\":\"unique\",\"columns\":[\"id\"]}]}";
    const prior = try std.json.parseFromSlice(Value, a, source, .{});
    const reordered = try std.json.parseFromSlice(Value, a, "{\"contract\":{\"enforced\":true,\"checksum\":\"new\"},\"config\":{\"materialized\":\"table\"},\"constraints\":[{\"type\":\"unique\",\"columns\":[\"id\"]},{\"type\":\"check\",\"name\":\"positive\",\"expression\":\"id > 0\",\"warn_unenforced\":true}]}", .{});
    try std.testing.expect(!(try classify(a, prior.value, reordered.value, "postgres", 0)).breaking());
    try reordered.value.object.getPtr("constraints").?.array.items[1].object.put(a, "warn_unenforced", .{ .bool = false });
    const changed = try classify(a, prior.value, reordered.value, "postgres", 0);
    try std.testing.expectEqual(@as(usize, 1), changed.enforced_model_constraint_removed.items.len);
    try std.testing.expectEqualStrings("positive", changed.enforced_model_constraint_removed.items[0].constraint_name.?);
}

test "state contracts trust unchanged checksum and sort removed columns without deprecation exemptions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prior = try std.json.parseFromSlice(Value, a, "{\"contract\":{\"enforced\":true,\"checksum\":\"same\"},\"deprecation_date\":\"1970-01-01T00:00:00Z\",\"columns\":{\"z\":{\"name\":\"z\"},\"b\":{\"name\":\"b\"},\"a\":{\"name\":\"a\"}}}", .{});
    const current = try std.json.parseFromSlice(Value, a, "{\"contract\":{\"enforced\":true,\"checksum\":\"same\"},\"columns\":{}}", .{});
    try std.testing.expect(!(try classify(a, prior.value, current.value, "duckdb", 1)).breaking());
    try current.value.object.getPtr("contract").?.object.put(a, "checksum", .{ .string = "changed" });
    const changed = try classify(a, prior.value, current.value, "duckdb", 1);
    try std.testing.expectEqualStrings("Columns were removed: \n    - a\n    - b\n    - z", changed.breaking_changes.items[0]);
}
