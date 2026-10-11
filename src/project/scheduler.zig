const std = @import("std");
const types = @import("types.zig");
const selector = @import("selector.zig");

const Graph = types.Graph;
const Node = types.Node;
const SelectedResource = selector.SelectedResource;

/// Physical dependencies retain unselected ancestors behind ephemeral nodes:
/// an ephemeral node has no completion event of its own.
pub fn physicalDependencies(allocator: std.mem.Allocator, graph: *const Graph, dependencies: []const []const u8) ![][]const u8 {
    return collectDependencies(allocator, graph, dependencies, false);
}

fn collectDependencies(allocator: std.mem.Allocator, graph: *const Graph, dependencies: []const []const u8, all_ancestors: bool) ![][]const u8 {
    const marks = try allocator.alloc(Mark, graph.nodes.items.len);
    defer allocator.free(marks);
    @memset(marks, .unseen);
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer ids.deinit(allocator);
    for (dependencies) |dependency| try collectOne(allocator, graph, dependency, marks, &ids, all_ancestors);
    return try ids.toOwnedSlice(allocator);
}

const Mark = enum { unseen, visiting, done };

fn collectOne(allocator: std.mem.Allocator, graph: *const Graph, id: []const u8, marks: []Mark, ids: *std.ArrayList([]const u8), all_ancestors: bool) anyerror!void {
    for (graph.nodes.items, 0..) |*node, index| {
        if (!std.mem.eql(u8, node.unique_id, id)) continue;
        const ephemeral = std.mem.eql(u8, node.resource_type, "model") and std.mem.eql(u8, node.materialized, "ephemeral");
        if (!ephemeral) try appendUnique(allocator, ids, id);
        if (!ephemeral and !all_ancestors) return;
        switch (marks[index]) {
            .visiting => return error.CyclicModelDependency,
            .done => return,
            .unseen => {},
        }
        marks[index] = .visiting;
        // Keep ephemeral IDs in the ancestry view so explicit blockers work.
        if (all_ancestors and ephemeral) try appendUnique(allocator, ids, id);
        for (node.depends_on.items) |dependency| try collectOne(allocator, graph, dependency, marks, ids, all_ancestors);
        marks[index] = .done;
        return;
    }
    try appendUnique(allocator, ids, id);
}

pub fn blockedBy(allocator: std.mem.Allocator, graph: *const Graph, dependencies: []const []const u8, blocked: []const []const u8) !bool {
    if (blocked.len == 0) return false;
    const ancestors = try collectDependencies(allocator, graph, dependencies, true);
    defer allocator.free(ancestors);
    for (ancestors) |ancestor| if (contains(blocked, ancestor)) return true;
    return false;
}

pub fn dependenciesCompleted(allocator: std.mem.Allocator, graph: *const Graph, dependencies: []const []const u8, selected: ?[]const SelectedResource, completed: []const []const u8) !bool {
    const physical = try physicalDependencies(allocator, graph, dependencies);
    defer allocator.free(physical);
    for (physical) |dependency| {
        if (!std.mem.startsWith(u8, dependency, "model.") and !std.mem.startsWith(u8, dependency, "seed.") and !std.mem.startsWith(u8, dependency, "snapshot.")) continue;
        if (selected) |resources| {
            if (!selectedContains(resources, dependency)) continue;
        }
        if (!contains(completed, dependency)) return false;
    }
    return true;
}

/// Emit a blocked test after its selected blocked physical parents have their
/// terminal rows, keeping dependency order even when failure crosses CTEs.
pub fn blockedParentPending(allocator: std.mem.Allocator, graph: *const Graph, dependencies: []const []const u8, selected: []const SelectedResource, blocked: []const []const u8) !bool {
    const physical = try physicalDependencies(allocator, graph, dependencies);
    defer allocator.free(physical);
    for (physical) |dependency| {
        if (!selectedContains(selected, dependency) or contains(blocked, dependency)) continue;
        if (try blockedBy(allocator, graph, &.{dependency}, blocked)) return true;
    }
    return false;
}

pub fn orderNodes(allocator: std.mem.Allocator, graph: *Graph, selected: []const SelectedResource, include_seeds: bool) ![]*Node {
    var ordered: std.ArrayList(*Node) = .empty;
    errdefer ordered.deinit(allocator);
    var completed: std.ArrayList([]const u8) = .empty;
    defer completed.deinit(allocator);
    const remaining = try allocator.alloc(bool, graph.nodes.items.len);
    defer allocator.free(remaining);
    var count: usize = 0;
    for (graph.nodes.items, 0..) |*node, index| {
        remaining[index] = node.enabled and selectedContains(selected, node.unique_id) and
            ((std.mem.eql(u8, node.resource_type, "model") and !std.mem.eql(u8, node.materialized, "ephemeral")) or
                std.mem.eql(u8, node.resource_type, "snapshot") or
                (include_seeds and std.mem.eql(u8, node.resource_type, "seed")));
        if (remaining[index]) count += 1;
    }
    while (ordered.items.len < count) {
        var progressed = false;
        for (graph.nodes.items, 0..) |*node, index| {
            if (!remaining[index]) continue;
            // `run` filters seeds out of selection, so only scheduled resources
            // can contribute completion events.
            if (!try dependenciesCompleted(allocator, graph, node.depends_on.items, selected, completed.items)) continue;
            try ordered.append(allocator, node);
            try completed.append(allocator, node.unique_id);
            remaining[index] = false;
            progressed = true;
        }
        if (!progressed) return error.CyclicModelDependency;
    }
    return try ordered.toOwnedSlice(allocator);
}

pub fn unitTargetsNode(unit_test: *const types.UnitTestDef, node: *const Node) bool {
    return std.mem.eql(u8, unit_test.package_name, node.package_name) and std.mem.eql(u8, unit_test.model, node.name) and
        ((unit_test.version == .null and node.version == .null) or
            (unit_test.version != .null and node.version != .null and (@import("model_versions.zig").equal(std.heap.page_allocator, unit_test.version, node.version) catch false)));
}

fn selectedContains(selected: []const SelectedResource, id: []const u8) bool {
    for (selected) |resource| if (std.mem.eql(u8, resource.unique_id, id)) return true;
    return false;
}

fn contains(ids: []const []const u8, id: []const u8) bool {
    for (ids) |candidate| if (std.mem.eql(u8, candidate, id)) return true;
    return false;
}

fn appendUnique(allocator: std.mem.Allocator, ids: *std.ArrayList([]const u8), id: []const u8) !void {
    if (!contains(ids.items, id)) try ids.append(allocator, id);
}

fn addNode(graph: *Graph, name: []const u8, id: []const u8, materialized: []const u8, dependencies: []const []const u8) !void {
    var node = Node{ .package_name = "demo", .unique_id = id, .name = name, .path = "", .original_file_path = "", .raw_code = "", .materialized = materialized };
    try node.depends_on.appendSlice(graph.allocator, dependencies);
    try graph.nodes.append(graph.allocator, node);
}

test "physical readiness and blockers traverse arbitrary unselected ephemeral ancestry" {
    const allocator = std.testing.allocator;
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try addNode(&graph, "a_final", "model.demo.a_final", "table", &.{"model.demo.e1"});
    try addNode(&graph, "e1", "model.demo.e1", "ephemeral", &.{"model.demo.e2"});
    try addNode(&graph, "e2", "model.demo.e2", "ephemeral", &.{"model.demo.z_parent"});
    try addNode(&graph, "z_parent", "model.demo.z_parent", "table", &.{});
    const selected = [_]SelectedResource{
        .{ .unique_id = "model.demo.a_final", .name = "a_final", .resource_type = "model" },
        .{ .unique_id = "model.demo.z_parent", .name = "z_parent", .resource_type = "model" },
    };
    const ordered = try orderNodes(allocator, &graph, &selected, false);
    defer allocator.free(ordered);
    try std.testing.expectEqualStrings("model.demo.z_parent", ordered[0].unique_id);
    try std.testing.expectEqualStrings("model.demo.a_final", ordered[1].unique_id);
    try std.testing.expect(try blockedBy(allocator, &graph, graph.nodes.items[0].depends_on.items, &.{"model.demo.z_parent"}));
    try std.testing.expect(!try blockedBy(allocator, &graph, graph.nodes.items[3].depends_on.items, &.{"model.demo.a_final"}));
    try std.testing.expect(try blockedParentPending(allocator, &graph, &.{"model.demo.a_final"}, &selected, &.{"model.demo.z_parent"}));
    try std.testing.expect(!try blockedParentPending(allocator, &graph, &.{"model.demo.a_final"}, &selected, &.{ "model.demo.z_parent", "model.demo.a_final" }));
}

test "ephemeral dependency traversal deduplicates diamonds and rejects cycles" {
    const allocator = std.testing.allocator;
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try addNode(&graph, "e1", "model.demo.e1", "ephemeral", &.{"model.demo.e2"});
    try addNode(&graph, "e2", "model.demo.e2", "ephemeral", &.{"seed.demo.raw"});
    const physical = try physicalDependencies(allocator, &graph, &.{ "model.demo.e1", "model.demo.e2" });
    defer allocator.free(physical);
    try std.testing.expectEqual(@as(usize, 1), physical.len);
    try std.testing.expectEqualStrings("seed.demo.raw", physical[0]);
    try graph.nodes.items[1].depends_on.append(allocator, "model.demo.e1");
    try std.testing.expectError(error.CyclicModelDependency, physicalDependencies(allocator, &graph, &.{"model.demo.e1"}));
    try std.testing.expectError(error.CyclicModelDependency, blockedBy(allocator, &graph, &.{"model.demo.e1"}, &.{"seed.demo.raw"}));
}
