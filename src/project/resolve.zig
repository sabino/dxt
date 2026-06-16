const std = @import("std");
const types = @import("types.zig");

const DocBlock = types.DocBlock;
const Graph = types.Graph;
const RefDep = types.RefDep;
const SourceDep = types.SourceDep;

pub fn findDoc(graph: *const Graph, unique_id: []const u8) ?DocBlock {
    for (graph.docs.items) |doc| {
        if (std.mem.eql(u8, doc.unique_id, unique_id)) return doc;
    }
    return null;
}

pub fn findModelIndexByName(graph: *const Graph, package_name: []const u8, name: []const u8) ?usize {
    for (graph.nodes.items, 0..) |node, index| {
        if (std.mem.eql(u8, node.package_name, package_name) and std.mem.eql(u8, node.resource_type, "model") and std.mem.eql(u8, node.name, name)) return index;
    }
    return null;
}

pub fn countActiveNodes(graph: *const Graph) usize {
    var count: usize = 0;
    for (graph.nodes.items) |node| {
        if (node.enabled and std.mem.eql(u8, node.resource_type, "model")) count += 1;
    }
    return count;
}

pub fn countActiveSeeds(graph: *const Graph) usize {
    var count: usize = 0;
    for (graph.nodes.items) |node| {
        if (node.enabled and std.mem.eql(u8, node.resource_type, "seed")) count += 1;
    }
    return count;
}

pub fn countActiveExposures(graph: *const Graph) usize {
    var count: usize = 0;
    for (graph.exposures.items) |exposure| {
        if (exposure.enabled) count += 1;
    }
    return count;
}

pub fn hasMacro(graph: *const Graph, unique_id: []const u8) bool {
    for (graph.macros.items) |macro| {
        if (std.mem.eql(u8, macro.unique_id, unique_id)) return true;
    }
    return false;
}

pub fn hasMacroPackage(graph: *const Graph, package_name: []const u8) bool {
    for (graph.macros.items) |macro| {
        if (std.mem.eql(u8, macro.package_name, package_name)) return true;
    }
    return false;
}

pub fn findMacroIdByPackageAndName(graph: *const Graph, package_name: []const u8, name: []const u8) ?[]const u8 {
    for (graph.macros.items) |macro| {
        if (std.mem.eql(u8, macro.package_name, package_name) and std.mem.eql(u8, macro.name, name)) return macro.unique_id;
    }
    return null;
}

pub fn findMacroIdForUnqualifiedCall(graph: *const Graph, package_name: []const u8, name: []const u8) ?[]const u8 {
    if (findMacroIdByPackageAndName(graph, package_name, name)) |macro_id| return macro_id;
    if (!std.mem.eql(u8, package_name, graph.project_name)) {
        return findProjectMacroIdByName(graph, name);
    }
    return null;
}

pub fn findMacroIndexByPackageAndName(graph: *const Graph, package_name: []const u8, name: []const u8) ?usize {
    for (graph.macros.items, 0..) |macro, index| {
        if (std.mem.eql(u8, macro.package_name, package_name) and std.mem.eql(u8, macro.name, name)) return index;
    }
    return null;
}

pub fn resolveRefDependency(graph: *const Graph, current_package: []const u8, ref_dep: RefDep) ![]const u8 {
    const package = ref_dep.package orelse current_package;
    if (try resolveRefInPackage(graph, package, ref_dep.name)) |unique_id| return unique_id;
    if (ref_dep.package != null) return error.UnresolvedRef;

    var found: ?[]const u8 = null;
    for (graph.nodes.items) |node| {
        if (!std.mem.eql(u8, node.name, ref_dep.name)) continue;
        if (!std.mem.eql(u8, node.resource_type, "model") and !std.mem.eql(u8, node.resource_type, "seed")) continue;
        if (!node.enabled) continue;
        if (found != null) return error.UnresolvedRef;
        found = node.unique_id;
    }
    return found orelse error.UnresolvedRef;
}

pub fn resolveSourceDependency(graph: *const Graph, current_package: []const u8, source_dep: SourceDep) ![]const u8 {
    const unique_id = try std.fmt.allocPrint(graph.allocator, "source.{s}.{s}.{s}", .{ current_package, source_dep.source_name, source_dep.table_name });
    if (hasSource(graph, unique_id)) return unique_id;

    var found: ?[]const u8 = null;
    for (graph.sources.items) |source| {
        if (!std.mem.eql(u8, source.source_name, source_dep.source_name)) continue;
        if (!std.mem.eql(u8, source.table_name, source_dep.table_name)) continue;
        if (found != null) return error.UnresolvedSource;
        found = source.unique_id;
    }
    return found orelse error.UnresolvedSource;
}

fn hasNode(graph: *const Graph, unique_id: []const u8) bool {
    for (graph.nodes.items) |node| {
        if (node.enabled and std.mem.eql(u8, node.unique_id, unique_id)) return true;
    }
    return false;
}

fn hasDisabledNode(graph: *const Graph, unique_id: []const u8) bool {
    for (graph.nodes.items) |node| {
        if (!node.enabled and std.mem.eql(u8, node.unique_id, unique_id)) return true;
    }
    return false;
}

fn hasSource(graph: *const Graph, unique_id: []const u8) bool {
    for (graph.sources.items) |source| {
        if (std.mem.eql(u8, source.unique_id, unique_id)) return true;
    }
    return false;
}

fn resolveRefInPackage(graph: *const Graph, package: []const u8, name: []const u8) !?[]const u8 {
    const model_id = try std.fmt.allocPrint(graph.allocator, "model.{s}.{s}", .{ package, name });
    if (hasDisabledNode(graph, model_id)) return error.DisabledRef;
    if (hasNode(graph, model_id)) return model_id;

    const seed_id = try std.fmt.allocPrint(graph.allocator, "seed.{s}.{s}", .{ package, name });
    if (hasDisabledNode(graph, seed_id)) return error.DisabledRef;
    if (hasNode(graph, seed_id)) return seed_id;
    return null;
}

fn findProjectMacroIdByName(graph: *const Graph, name: []const u8) ?[]const u8 {
    return findMacroIdByPackageAndName(graph, graph.project_name, name);
}

fn findProjectMacroIndexByName(graph: *const Graph, name: []const u8) ?usize {
    return findMacroIndexByPackageAndName(graph, graph.project_name, name);
}

fn appendNode(graph: *Graph, resource_type: []const u8, package_name: []const u8, unique_id: []const u8, name: []const u8, enabled: bool) !void {
    try graph.nodes.append(graph.allocator, .{
        .resource_type = resource_type,
        .package_name = package_name,
        .unique_id = unique_id,
        .name = name,
        .path = "",
        .original_file_path = "",
        .raw_code = "",
        .enabled = enabled,
    });
}

fn appendSource(graph: *Graph, package_name: []const u8, source_name: []const u8, table_name: []const u8) !void {
    try graph.sources.append(graph.allocator, .{
        .package_name = package_name,
        .unique_id = try std.fmt.allocPrint(graph.allocator, "source.{s}.{s}.{s}", .{ package_name, source_name, table_name }),
        .source_name = source_name,
        .table_name = table_name,
        .original_file_path = "",
    });
}

fn appendMacro(graph: *Graph, package_name: []const u8, name: []const u8) !void {
    try graph.macros.append(graph.allocator, .{
        .unique_id = try std.fmt.allocPrint(graph.allocator, "macro.{s}.{s}", .{ package_name, name }),
        .package_name = package_name,
        .name = name,
        .path = "",
        .original_file_path = "",
        .macro_sql = "",
    });
}

test "graph counts active models seeds and exposures only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var graph = Graph{ .allocator = arena.allocator(), .project_name = "demo" };
    defer graph.deinit();

    try appendNode(&graph, "model", "demo", "model.demo.active", "active", true);
    try appendNode(&graph, "model", "demo", "model.demo.disabled", "disabled", false);
    try appendNode(&graph, "seed", "demo", "seed.demo.raw_customers", "raw_customers", true);
    try graph.exposures.append(graph.allocator, .{ .package_name = "demo", .unique_id = "exposure.demo.active", .name = "active", .path = "", .original_file_path = "", .enabled = true });
    try graph.exposures.append(graph.allocator, .{ .package_name = "demo", .unique_id = "exposure.demo.disabled", .name = "disabled", .path = "", .original_file_path = "", .enabled = false });

    try std.testing.expectEqual(@as(usize, 1), countActiveNodes(&graph));
    try std.testing.expectEqual(@as(usize, 1), countActiveSeeds(&graph));
    try std.testing.expectEqual(@as(usize, 1), countActiveExposures(&graph));
}

test "model and macro index helpers preserve package lookup semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var graph = Graph{ .allocator = arena.allocator(), .project_name = "demo" };
    defer graph.deinit();

    try appendNode(&graph, "model", "demo", "model.demo.customers", "customers", true);
    try appendMacro(&graph, "demo", "format_id");
    try appendMacro(&graph, "pkg", "format_id");

    try std.testing.expectEqual(@as(?usize, 0), findModelIndexByName(&graph, "demo", "customers"));
    try std.testing.expect(findModelIndexByName(&graph, "pkg", "customers") == null);
    try std.testing.expectEqual(@as(?usize, 0), findMacroIndexByPackageAndName(&graph, "demo", "format_id"));
    try std.testing.expectEqual(@as(?usize, 1), findMacroIndexByPackageAndName(&graph, "pkg", "format_id"));
    try std.testing.expectEqual(@as(?usize, 0), findProjectMacroIndexByName(&graph, "format_id"));
}

test "unqualified macro lookup prefers current package then project package" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var graph = Graph{ .allocator = arena.allocator(), .project_name = "demo" };
    defer graph.deinit();

    try appendMacro(&graph, "demo", "format_id");
    try appendMacro(&graph, "pkg", "format_id");
    try appendMacro(&graph, "demo", "project_only");

    try std.testing.expectEqualStrings("macro.pkg.format_id", findMacroIdForUnqualifiedCall(&graph, "pkg", "format_id").?);
    try std.testing.expectEqualStrings("macro.demo.project_only", findMacroIdForUnqualifiedCall(&graph, "pkg", "project_only").?);
    try std.testing.expect(findMacroIdForUnqualifiedCall(&graph, "demo", "missing") == null);
    try std.testing.expect(hasMacroPackage(&graph, "pkg"));
    try std.testing.expect(!hasMacroPackage(&graph, "other"));
}

test "ref resolution handles package refs seed refs disabled refs fallback and ambiguity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var graph = Graph{ .allocator = arena.allocator(), .project_name = "demo" };
    defer graph.deinit();

    try appendNode(&graph, "model", "demo", "model.demo.customers", "customers", true);
    try appendNode(&graph, "seed", "pkg", "seed.pkg.raw_customers", "raw_customers", true);
    try appendNode(&graph, "model", "demo", "model.demo.disabled_model", "disabled_model", false);
    try appendNode(&graph, "model", "pkg", "model.pkg.shared", "shared", true);
    try appendNode(&graph, "model", "other", "model.other.shared", "shared", true);

    try std.testing.expectEqualStrings("model.demo.customers", try resolveRefDependency(&graph, "demo", .{ .package = null, .name = "customers" }));
    try std.testing.expectEqualStrings("seed.pkg.raw_customers", try resolveRefDependency(&graph, "demo", .{ .package = "pkg", .name = "raw_customers" }));
    try std.testing.expectError(error.DisabledRef, resolveRefDependency(&graph, "demo", .{ .package = null, .name = "disabled_model" }));
    try std.testing.expectEqualStrings("seed.pkg.raw_customers", try resolveRefDependency(&graph, "other", .{ .package = null, .name = "raw_customers" }));
    try std.testing.expectError(error.UnresolvedRef, resolveRefDependency(&graph, "demo", .{ .package = null, .name = "shared" }));
}

test "source resolution prefers current package and errors on ambiguous fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var graph = Graph{ .allocator = arena.allocator(), .project_name = "demo" };
    defer graph.deinit();

    try appendSource(&graph, "demo", "raw", "customers");
    try appendSource(&graph, "pkg", "raw", "orders");
    try appendSource(&graph, "other", "raw", "orders");

    try std.testing.expectEqualStrings("source.demo.raw.customers", try resolveSourceDependency(&graph, "demo", .{ .source_name = "raw", .table_name = "customers" }));
    try std.testing.expectEqualStrings("source.pkg.raw.orders", try resolveSourceDependency(&graph, "pkg", .{ .source_name = "raw", .table_name = "orders" }));
    try std.testing.expectError(error.UnresolvedSource, resolveSourceDependency(&graph, "demo", .{ .source_name = "raw", .table_name = "orders" }));
    try std.testing.expectError(error.UnresolvedSource, resolveSourceDependency(&graph, "demo", .{ .source_name = "raw", .table_name = "missing" }));
}
