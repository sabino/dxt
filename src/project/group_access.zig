//! Core 1.10 group ownership and model reference visibility.
const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");
const Value = std.json.Value;

fn field(value: Value, key: []const u8) Value {
    return values.get(value, key) orelse .null;
}
fn text(value: Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}
pub fn group(config: Value) ?[]const u8 {
    return text(field(config, "group"));
}
pub fn access(node: *const types.Node) []const u8 {
    return text(field(node.effective_config, "access")) orelse "protected";
}

pub fn parse(runtime: types.Runtime, document: Value, root: []const u8, path: []const u8, package: []const u8, graph: *types.Graph) !void {
    const definitions = field(document, "groups");
    if (definitions == .null) return;
    if (definitions != .array) return error.InvalidGroupDefinition;
    var context = @import("config_render.zig").Context{ .runtime = runtime, .vars = graph.vars.items, .target = graph.target_context, .package_name = package };
    for (definitions.array.items) |definition| {
        if (definition != .object) return error.InvalidGroupDefinition;
        var rendered: Value = .{ .object = .empty };
        var fields = definition.object.iterator();
        while (fields.next()) |entry| {
            var value = if (std.mem.eql(u8, entry.key_ptr.*, "description")) try values.clone(runtime.allocator, entry.value_ptr.*) else try context.render(entry.value_ptr.*);
            defer values.deinit(runtime.allocator, &value);
            try values.put(runtime.allocator, &rendered, entry.key_ptr.*, value);
        }
        defer values.deinit(runtime.allocator, &rendered);
        const name = text(field(rendered, "name")) orelse return error.InvalidGroupDefinition;
        const owner = field(rendered, "owner");
        if (owner != .object or (field(owner, "name") == .null and field(owner, "email") == .null)) return error.InvalidGroupOwner;
        const owner_name = field(owner, "name");
        if (owner_name != .null and owner_name != .string) return error.InvalidGroupOwner;
        const email = field(owner, "email");
        if (email != .null and email != .string and email != .array) return error.InvalidGroupOwner;
        if (email == .array) for (email.array.items) |item| {
            if (item != .string) return error.InvalidGroupOwner;
        };
        const id = try std.fmt.allocPrint(runtime.allocator, "group.{s}.{s}", .{ package, name });
        defer runtime.allocator.free(id);
        for (graph.groups.items) |existing| if (std.mem.eql(u8, text(field(existing, "unique_id")).?, id)) return error.DuplicateGroupDefinition;
        var data: Value = .{ .object = .empty };
        errdefer values.deinit(runtime.allocator, &data);
        inline for (.{ .{ "name", name }, .{ "unique_id", id }, .{ "package_name", package }, .{ "resource_type", "group" }, .{ "original_file_path", path } }) |entry| try values.put(runtime.allocator, &data, entry[0], .{ .string = entry[1] });
        const relative = if (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/') path[root.len + 1 ..] else path;
        try values.put(runtime.allocator, &data, "path", .{ .string = relative });
        const description = field(rendered, "description");
        if (description != .null and description != .string) return error.InvalidGroupDefinition;
        try values.put(runtime.allocator, &data, "description", description);
        var normalized_owner: Value = .{ .object = .empty };
        defer values.deinit(runtime.allocator, &normalized_owner);
        try values.put(runtime.allocator, &normalized_owner, "name", .null);
        try values.put(runtime.allocator, &normalized_owner, "email", .null);
        try values.overlay(runtime.allocator, &normalized_owner, owner);
        try values.put(runtime.allocator, &data, "owner", normalized_owner);
        var config: Value = .{ .object = .empty };
        defer values.deinit(runtime.allocator, &config);
        try values.put(runtime.allocator, &config, "meta", .{ .object = .empty });
        try values.overlay(runtime.allocator, &config, field(rendered, "config"));
        if (field(config, "meta") != .object) return error.InvalidGroupDefinition;
        try values.put(runtime.allocator, &data, "config", config);
        try graph.groups.append(runtime.allocator, data);
    }
}

fn validateGroup(graph: *const types.Graph, config: Value) !void {
    const value = field(config, "group");
    if (value == .null) return;
    const name = text(value) orelse return error.InvalidResourceGroup;
    if (name.len == 0) return;
    for (graph.groups.items) |definition| if (std.mem.eql(u8, text(field(definition, "name")).?, name)) return;
    return error.UnknownResourceGroup;
}
fn restricted(graph: *const types.Graph, package: []const u8) bool {
    for (graph.semantic_project_configs.items) |project| if (std.mem.eql(u8, project.package_name, package)) {
        const flag = field(project.rendered, "restrict-access");
        return flag == .bool and flag.bool;
    };
    return false;
}
fn validateRefs(graph: *const types.Graph, package: []const u8, config: Value, dependencies: []const []const u8) !void {
    for (dependencies) |dependency| for (graph.nodes.items) |target| {
        if (!std.mem.eql(u8, target.resource_type, "model") or !std.mem.eql(u8, dependency, target.unique_id)) continue;
        const outside = !std.mem.eql(u8, package, target.package_name) and restricted(graph, target.package_name);
        if (std.mem.eql(u8, access(&target), "private")) {
            const consumer_group = group(config) orelse return error.PrivateModelReference;
            const target_group = group(target.effective_config) orelse return error.PrivateModelReference;
            if (consumer_group.len == 0 or !std.mem.eql(u8, consumer_group, target_group) or outside) return error.PrivateModelReference;
        } else if (std.mem.eql(u8, access(&target), "protected") and outside) return error.ProtectedModelReference;
    };
}
pub fn validateReference(graph: *const types.Graph, package: []const u8, config: Value, unique_id: []const u8) !void {
    try validateRefs(graph, package, config, &.{unique_id});
}

pub fn validate(graph: *const types.Graph) !void {
    for (graph.nodes.items) |node| {
        if (!node.enabled) continue;
        try validateGroup(graph, node.effective_config);
        if (std.mem.eql(u8, node.resource_type, "model")) {
            const visibility = field(node.effective_config, "access");
            if (visibility != .null and visibility != .string) return error.InvalidModelAccess;
            const level = access(&node);
            if (!std.mem.eql(u8, level, "public") and !std.mem.eql(u8, level, "private") and !std.mem.eql(u8, level, "protected")) return error.InvalidModelAccess;
            if (std.mem.eql(u8, level, "public") and std.mem.eql(u8, node.materialized, "ephemeral")) return error.PublicEphemeralModel;
        }
        try validateRefs(graph, node.package_name, node.effective_config, node.depends_on.items);
    }
    for (graph.semantic_resources.items) |resource| {
        if (!resource.enabled) continue;
        const config = field(resource.data, "config");
        try validateGroup(graph, config);
        try validateRefs(graph, resource.package_name, config, resource.depends_on.items);
    }
    for (graph.exposures.items) |exposure| if (exposure.enabled) try validateRefs(graph, exposure.package_name, .null, exposure.depends_on.items);
    for (graph.singular_tests.items) |test_node| if (test_node.enabled) try validateRefs(graph, test_node.package_name, test_node.config_values, test_node.depends_on.items);
    // Core generic tests inherit the attached model's group.
    for (graph.tests.items) |test_node| {
        if (!test_node.enabled) continue;
        var config: Value = test_node.config_values;
        for (graph.nodes.items) |node| if (std.mem.eql(u8, node.unique_id, test_node.attached_node orelse "")) {
            config = node.effective_config;
        };
        try validateRefs(graph, test_node.package_name, config, test_node.depends_on.items);
    }
}

pub fn writeManifest(writer: *std.Io.Writer, graph: *const types.Graph) !void {
    try writer.writeAll("  \"groups\": {");
    for (graph.groups.items, 0..) |definition, index| {
        if (index != 0) try writer.writeByte(',');
        try std.json.Stringify.value(field(definition, "unique_id"), .{}, writer);
        try writer.writeByte(':');
        try std.json.Stringify.value(definition, .{}, writer);
    }
    try writer.writeAll("},\n  \"group_map\": {");
    var first = true;
    for (graph.groups.items, 0..) |definition, index| {
        const name = text(field(definition, "name")).?;
        var duplicate = false;
        for (graph.groups.items[0..index]) |prior| if (std.mem.eql(u8, text(field(prior, "name")).?, name)) {
            duplicate = true;
        };
        if (duplicate) continue;
        if (!first) try writer.writeByte(',');
        first = false;
        try std.json.Stringify.value(name, .{}, writer);
        try writer.writeAll(":[");
        var member_first = true;
        for (graph.nodes.items) |node| if (node.enabled) if (group(node.effective_config)) |assigned| if (std.mem.eql(u8, name, assigned)) {
            if (!member_first) try writer.writeByte(',');
            member_first = false;
            try std.json.Stringify.value(node.unique_id, .{}, writer);
        };
        for (graph.tests.items) |test_node| if (!test_node.disabled) if (genericGroup(graph, &test_node)) |assigned| if (std.mem.eql(u8, name, assigned)) {
            if (!member_first) try writer.writeByte(',');
            member_first = false;
            try std.json.Stringify.value(test_node.unique_id, .{}, writer);
        };
        for (graph.semantic_resources.items) |resource| if (resource.enabled) if (group(field(resource.data, "config"))) |assigned| if (std.mem.eql(u8, name, assigned)) {
            if (!member_first) try writer.writeByte(',');
            member_first = false;
            try std.json.Stringify.value(resource.unique_id, .{}, writer);
        };
        try writer.writeByte(']');
    }
    try writer.writeAll("},\n");
}

pub fn genericGroup(graph: *const types.Graph, test_node: *const types.GenericTestNode) ?[]const u8 {
    if (test_node.attached_node) |attached| {
        for (graph.nodes.items) |node| if (std.mem.eql(u8, attached, node.unique_id)) return group(node.effective_config);
    }
    return group(test_node.config_values);
}

test "private access requires a shared group and respects package restrictions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph = types.Graph{ .allocator = a, .project_name = "demo" };
    const config = (try std.json.parseFromSlice(Value, a, "{\"group\":\"finance\",\"access\":\"private\"}", .{})).value;
    try graph.nodes.append(a, .{ .package_name = "demo", .unique_id = "model.demo.base", .name = "base", .path = "base.sql", .original_file_path = "models/base.sql", .raw_code = "", .effective_config = config });
    try validateRefs(&graph, "demo", config, &.{"model.demo.base"});
    try std.testing.expectError(error.PrivateModelReference, validateRefs(&graph, "demo", .null, &.{"model.demo.base"}));
    const rendered = (try std.json.parseFromSlice(Value, a, "{\"restrict-access\":true}", .{})).value;
    try graph.semantic_project_configs.append(a, .{ .package_name = "demo", .raw = .null, .rendered = rendered });
    try std.testing.expectError(error.PrivateModelReference, validateRefs(&graph, "consumer", config, &.{"model.demo.base"}));
}
