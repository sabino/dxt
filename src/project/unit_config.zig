//! Unit definitions use their own FQN hierarchy, independent of model config.
const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");
const Value = std.json.Value;

pub fn apply(a: std.mem.Allocator, runtime: ?types.Runtime, graph: *const types.Graph, unit: *types.UnitTestDef, patch: Value) !void {
    try unit.fqn.append(a, unit.package_name);
    // Core removes the first path segment and the YAML basename. A configured
    // resource root can span multiple segments, so use original_file_path.
    var segments = std.mem.tokenizeAny(u8, unit.original_file_path, "/\\");
    _ = segments.next();
    while (segments.next()) |part| if (segments.peek() != null) {
        try unit.fqn.append(a, part);
    };
    try unit.fqn.append(a, unit.model);
    try unit.fqn.append(a, unit.name);
    var config: Value = .{ .object = .empty };
    errdefer values.deinit(a, &config);
    try values.put(a, &config, "tags", .{ .array = std.json.Array.init(a) });
    try values.put(a, &config, "meta", .{ .object = .empty });
    try values.put(a, &config, "enabled", .{ .bool = true });
    // The graph already owns project documents for each installed package.
    // Reuse those documents rather than retaining another profile/config copy.
    for (graph.semantic_project_configs.items) |project| {
        if (equal(project.package_name, unit.package_name)) try hierarchy(a, &config, values.get(if (project.rendered == .null) project.raw else project.rendered, "unit_tests") orelse .null, unit.fqn.items);
    }
    try merge(a, &config, patch);
    if (!equal(unit.package_name, graph.project_name)) for (graph.semantic_project_configs.items) |project| {
        if (equal(project.package_name, graph.project_name)) try hierarchy(a, &config, values.get(if (project.rendered == .null) project.raw else project.rendered, "unit_tests") orelse .null, unit.fqn.items);
    };
    if (runtime) |rt| {
        var context = @import("config_render.zig").Context{ .runtime = rt, .vars = graph.vars.items, .target = graph.target_context, .package_name = unit.package_name };
        const rendered = try context.render(config);
        values.deinit(a, &config);
        config = rendered;
    }
    const enabled = values.get(config, "enabled") orelse return error.InvalidUnitTestConfiguration;
    const meta = values.get(config, "meta") orelse return error.InvalidUnitTestConfiguration;
    const tags = values.get(config, "tags") orelse return error.InvalidUnitTestConfiguration;
    if (enabled != .bool or meta != .object or tags != .array) return error.InvalidUnitTestConfiguration;
    for (tags.array.items) |tag| {
        if (tag != .string) return error.InvalidUnitTestConfiguration;
        try unit.tags.append(a, tag.string);
    }
    unit.enabled = enabled.bool;
    unit.config_values = config;
}

fn hierarchy(a: std.mem.Allocator, config: *Value, block: Value, fqn: []const []const u8) !void {
    var current = block;
    try level(a, config, current);
    for (fqn) |part| {
        current = values.get(current, part) orelse return;
        try level(a, config, current);
    }
}
fn level(a: std.mem.Allocator, config: *Value, block: Value) !void {
    if (block == .null) return;
    if (block != .object) return error.InvalidUnitTestConfiguration;
    var fields: Value = .{ .object = .empty };
    defer values.deinit(a, &fields);
    var it = block.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.startsWith(u8, key, "+")) {
            try values.put(a, &fields, std.mem.trim(u8, key[1..], " \t\r\n"), entry.value_ptr.*);
        } else if (entry.value_ptr.* != .object) try values.put(a, &fields, key, entry.value_ptr.*);
    }
    try merge(a, config, fields);
}
fn merge(a: std.mem.Allocator, config: *Value, patch: Value) !void {
    if (patch == .null) return;
    if (patch != .object) return error.InvalidUnitTestConfiguration;
    var it = patch.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (equal(key, "tags")) {
            var tags = try values.clone(a, values.get(config.*, key) orelse .{ .array = std.json.Array.init(a) });
            defer values.deinit(a, &tags);
            if (tags != .array) return error.InvalidUnitTestConfiguration;
            if (entry.value_ptr.* == .string) try tags.array.append(try values.clone(a, entry.value_ptr.*)) else if (entry.value_ptr.* == .array) {
                for (entry.value_ptr.array.items) |tag| try tags.array.append(try values.clone(a, tag));
            } else return error.InvalidUnitTestConfiguration;
            try values.put(a, config, key, tags);
        } else if (equal(key, "meta")) {
            if (entry.value_ptr.* != .object) return error.InvalidUnitTestConfiguration;
            var meta = try values.clone(a, values.get(config.*, key) orelse .{ .object = .empty });
            defer values.deinit(a, &meta);
            try values.overlay(a, &meta, entry.value_ptr.*);
            try values.put(a, config, key, meta);
        } else try values.put(a, config, key, entry.value_ptr.*);
    }
}
fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

test "unit config follows YAML FQN and root overrides dependency patches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph: types.Graph = .{ .allocator = a, .project_name = "root" };
    defer graph.deinit();
    var dependency = try std.json.parseFromSlice(Value, a, "{\"unit_tests\":{\"+tags\":[\"global\"],\"pkg\":{\"sub\":{\"final\":{\"+tags\":\"model\",\"check\":{\"+meta\":{\"owner\":\"dependency\"}}}}}}}", .{});
    defer dependency.deinit();
    var root = try std.json.parseFromSlice(Value, a, "{\"unit_tests\":{\"pkg\":{\"sub\":{\"final\":{\"check\":{\"+tags\":\"root\",\"+meta\":{\"owner\":\"root\"},\"+enabled\":false}}}}}}", .{});
    defer root.deinit();
    try graph.semantic_project_configs.append(a, .{ .package_name = try a.dupe(u8, "pkg"), .raw = try values.clone(a, dependency.value), .rendered = .null });
    try graph.semantic_project_configs.append(a, .{ .package_name = try a.dupe(u8, "root"), .raw = try values.clone(a, root.value), .rendered = .null });
    var unit: types.UnitTestDef = .{ .package_name = "pkg", .name = "check", .model = "final", .path = "sub/schema.yml", .original_file_path = "models/sub/schema.yml" };
    defer types.deinitUnitTestDef(a, &unit);
    var patch = try std.json.parseFromSlice(Value, a, "{\"tags\":[\"patch\"],\"meta\":{\"owner\":\"patch\",\"nested\":{\"value\":1}}}", .{});
    defer patch.deinit();
    try apply(a, null, &graph, &unit, patch.value);
    try std.testing.expectEqual(@as(usize, 4), unit.fqn.items.len);
    try std.testing.expectEqualStrings("sub", unit.fqn.items[1]);
    try std.testing.expectEqualStrings("global", unit.tags.items[0]);
    try std.testing.expectEqualStrings("model", unit.tags.items[1]);
    try std.testing.expectEqualStrings("patch", unit.tags.items[2]);
    try std.testing.expectEqualStrings("root", unit.tags.items[3]);
    try std.testing.expect(!unit.enabled);
    try std.testing.expectEqualStrings("root", values.get(values.get(unit.config_values, "meta").?, "owner").?.string);
    try std.testing.expectEqual(@as(i64, 1), values.get(values.get(values.get(unit.config_values, "meta").?, "nested").?, "value").?.integer);
}
