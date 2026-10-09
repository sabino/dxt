//! Core expands each unit definition over included versions of its model.
const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");

pub fn assign(graph: *types.Graph) !void {
    var expanded: std.ArrayList(types.UnitTestDef) = .empty;
    errdefer {
        for (expanded.items) |*unit| types.deinitUnitTestDef(graph.allocator, unit);
        expanded.deinit(graph.allocator);
    }
    for (graph.unit_tests.items) |*unit| {
        var has_versions = false;
        const first_expanded = expanded.items.len;
        for (graph.nodes.items) |node| {
            if (!std.mem.eql(u8, node.resource_type, "model") or !std.mem.eql(u8, node.package_name, unit.package_name) or !std.mem.eql(u8, node.name, unit.model) or node.version == .null) continue;
            has_versions = true;
            if (!try included(graph.allocator, unit.versions, node.version)) continue;
            var copy = try clone(graph.allocator, unit);
            errdefer types.deinitUnitTestDef(graph.allocator, &copy);
            copy.version = try values.clone(graph.allocator, node.version);
            const v = try values.scalarText(graph.allocator, node.version);
            defer graph.allocator.free(v);
            copy.unique_id = try std.fmt.allocPrint(graph.allocator, "unit_test.{s}.{s}.{s}_v{s}", .{ unit.package_name, unit.model, unit.name, v });
            try expanded.append(graph.allocator, copy);
        }
        if (!has_versions) {
            if (values.get(unit.versions, "include")) |include| if (include != .null and (include != .array or include.array.items.len != 0)) return error.InvalidUnitTestVersions;
            if (values.get(unit.versions, "exclude")) |exclude| if (exclude != .null and (exclude != .array or exclude.array.items.len != 0)) return error.InvalidUnitTestVersions;
            try expanded.append(graph.allocator, try clone(graph.allocator, unit));
        } else if (expanded.items.len == first_expanded) return error.UnitTestVersionNotFound;
    }
    for (graph.unit_tests.items) |*unit| types.deinitUnitTestDef(graph.allocator, unit);
    graph.unit_tests.deinit(graph.allocator);
    graph.unit_tests = expanded;
}
fn included(_: std.mem.Allocator, rule: std.json.Value, version: std.json.Value) !bool {
    if (rule == .null) return true;
    if (rule != .object) return error.InvalidUnitTestVersions;
    const include = values.get(rule, "include") orelse .null;
    const exclude = values.get(rule, "exclude") orelse .null;
    if (include != .null and include != .array) return error.InvalidUnitTestVersions;
    if (exclude != .null and exclude != .array) return error.InvalidUnitTestVersions;
    if (exclude == .array and exclude.array.items.len != 0) {
        for (exclude.array.items) |v| if (versionEqual(v, version)) return false;
        return true;
    }
    if (include == .array and include.array.items.len != 0) {
        for (include.array.items) |v| if (versionEqual(v, version)) return true;
        return false;
    }
    return false;
}
fn versionEqual(left: std.json.Value, right: std.json.Value) bool {
    if (left == .string and right == .string) return std.mem.eql(u8, left.string, right.string);
    const l: f64 = switch (left) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => return false,
    };
    const r: f64 = switch (right) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        else => return false,
    };
    return l == r;
}

fn clone(a: std.mem.Allocator, unit: *const types.UnitTestDef) !types.UnitTestDef {
    var result = unit.*;
    result.given = .empty;
    result.expect = .{};
    result.tags = .empty;
    result.meta = .empty;
    result.depends_on = .empty;
    result.overrides = .null;
    result.versions = .null;
    result.version = .null;
    result.config_values = .null;
    errdefer types.deinitUnitTestDef(a, &result);
    result.overrides = try values.clone(a, unit.overrides);
    result.versions = try values.clone(a, unit.versions);
    result.config_values = try values.clone(a, unit.config_values);
    for (unit.given.items) |fixture| try result.given.append(a, try cloneFixture(a, fixture));
    result.expect = try cloneFixture(a, unit.expect);
    try result.tags.appendSlice(a, unit.tags.items);
    try result.meta.appendSlice(a, unit.meta.items);
    return result;
}
fn cloneFixture(a: std.mem.Allocator, fixture: types.UnitTestFixture) !types.UnitTestFixture {
    var result = fixture;
    result.rows = .empty;
    for (fixture.rows.items) |row| {
        var copy: types.UnitTestRow = .{};
        try copy.entries.appendSlice(a, row.entries.items);
        try result.rows.append(a, copy);
    }
    return result;
}

test "unit version inclusion uses Core typed membership and rejects an empty match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rule: std.json.Value = .{ .object = .empty };
    var include: std.json.Value = .{ .array = std.json.Array.init(a) };
    try include.array.append(.{ .integer = 2 });
    try values.put(a, &rule, "include", include);
    try std.testing.expect(try included(a, rule, .{ .integer = 2 }));
    try std.testing.expect(!try included(a, rule, .{ .string = "2" }));
    try std.testing.expect(!try included(a, rule, .{ .integer = 1 }));
    try std.testing.expect(!try included(a, .{ .object = .empty }, .{ .integer = 1 }));
}
