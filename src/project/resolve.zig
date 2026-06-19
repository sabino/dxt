const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");

const DocBlock = types.DocBlock;
const ExposureDef = types.ExposureDef;
const GenericTestNode = types.GenericTestNode;
const Graph = types.Graph;
const MacroDef = types.MacroDef;
const Node = types.Node;
const RefDep = types.RefDep;
const SingularTestNode = types.SingularTestNode;
const SourceDep = types.SourceDep;
const SourceDef = types.SourceDef;
const UnitTestDef = types.UnitTestDef;

const appendUnique = util.appendUnique;
const sortStrings = util.sortStrings;

pub fn findDoc(graph: *const Graph, unique_id: []const u8) ?DocBlock {
    for (graph.docs.items) |doc| {
        if (std.mem.eql(u8, doc.unique_id, unique_id)) return doc;
    }
    return null;
}

pub fn findModelIndexByName(graph: *const Graph, package_name: []const u8, name: []const u8) ?usize {
    return findNodeIndexByResourceTypeAndName(graph, package_name, "model", name);
}

pub fn findNodeIndexByResourceTypeAndName(graph: *const Graph, package_name: []const u8, resource_type: []const u8, name: []const u8) ?usize {
    for (graph.nodes.items, 0..) |node, index| {
        if (std.mem.eql(u8, node.package_name, package_name) and std.mem.eql(u8, node.resource_type, resource_type) and std.mem.eql(u8, node.name, name)) return index;
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

fn hasMacro(graph: *const Graph, unique_id: []const u8) bool {
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

pub fn findMacroIdForUnqualifiedNamespaceCall(graph: *const Graph, package_name: []const u8, name: []const u8) ?[]const u8 {
    if (findMacroIdByPackageAndName(graph, package_name, name)) |macro_id| return macro_id;
    if (!std.mem.eql(u8, package_name, graph.project_name)) {
        if (findProjectMacroIdByName(graph, name)) |macro_id| return macro_id;
    }
    if (findMacroIdByPackageAndName(graph, "dbt", name)) |macro_id| return macro_id;
    return null;
}

pub fn findMacroIdForUnqualifiedMacroDependency(graph: *const Graph, package_name: []const u8, name: []const u8) ?[]const u8 {
    if (findMacroIdByPackageAndName(graph, package_name, name)) |macro_id| return macro_id;
    if (!std.mem.eql(u8, package_name, graph.project_name)) {
        if (findProjectMacroIdByName(graph, name)) |macro_id| return macro_id;
    }
    if (findNonInternalPackageMacroIdByName(graph, package_name, name)) |macro_id| return macro_id;
    if (findMacroIdByPackageAndName(graph, "dbt", name)) |macro_id| return macro_id;
    return null;
}

pub fn findMacroIdForAdapterDispatch(graph: *const Graph, current_package: []const u8, macro_name: []const u8, macro_namespace: ?[]const u8, adapter_prefixes: []const []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, macro_name, '.') != null) return null;

    const namespace = macro_namespace orelse "";
    if (namespace.len != 0) {
        if (findDispatchConfig(graph, namespace)) |config| {
            if (config.search_order.items.len != 0) {
                return findDispatchMacroIdInConfiguredOrder(graph, config.search_order.items, adapter_prefixes, macro_name);
            }
        }
    }

    const use_dependency_namespace = namespace.len != 0 and
        !std.mem.eql(u8, namespace, graph.project_name) and
        !std.mem.eql(u8, namespace, "dbt") and
        hasMacroPackage(graph, namespace);

    if (use_dependency_namespace) {
        for (adapter_prefixes) |prefix| {
            if (findDispatchMacroIdByPackageAndName(graph, graph.project_name, prefix, macro_name)) |macro_id| return macro_id;
        }
        for (adapter_prefixes) |prefix| {
            if (findDispatchMacroIdByPackageAndName(graph, namespace, prefix, macro_name)) |macro_id| return macro_id;
        }
        return null;
    }

    for (adapter_prefixes) |prefix| {
        if (findDispatchMacroIdInNamespace(graph, current_package, prefix, macro_name)) |macro_id| {
            return macro_id;
        }
    }
    return null;
}

pub fn findMacroIndexByPackageAndName(graph: *const Graph, package_name: []const u8, name: []const u8) ?usize {
    for (graph.macros.items, 0..) |macro, index| {
        if (std.mem.eql(u8, macro.package_name, package_name) and std.mem.eql(u8, macro.name, name)) return index;
    }
    return null;
}

pub fn packageNameFromMacroUniqueId(unique_id: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, unique_id, "macro.")) return null;
    const package_start = "macro.".len;
    const package_end = std.mem.indexOfPos(u8, unique_id, package_start, ".") orelse return null;
    return unique_id[package_start..package_end];
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

pub fn resolveDependencies(graph: *Graph) !void {
    for (graph.nodes.items) |*node| {
        if (!node.enabled) continue;
        for (node.macro_depends_on.items) |macro_dep| {
            if (!hasMacro(graph, macro_dep)) return error.UnresolvedMacro;
        }
        sortStrings(node.macro_depends_on.items);
        for (node.refs.items) |ref_dep| {
            try appendUnique(graph.allocator, &node.depends_on, try resolveRefDependency(graph, node.package_name, ref_dep));
        }
        for (node.source_refs.items) |source_dep| {
            try appendUnique(graph.allocator, &node.depends_on, try resolveSourceDependency(graph, node.package_name, source_dep));
        }
        sortStrings(node.depends_on.items);
    }
    for (graph.exposures.items) |*exposure| {
        if (!exposure.enabled) continue;
        for (exposure.refs.items) |ref_dep| {
            try appendUnique(graph.allocator, &exposure.depends_on, try resolveRefDependency(graph, exposure.package_name, ref_dep));
        }
        for (exposure.source_refs.items) |source_dep| {
            try appendUnique(graph.allocator, &exposure.depends_on, try resolveSourceDependency(graph, exposure.package_name, source_dep));
        }
        sortStrings(exposure.depends_on.items);
    }
    for (graph.singular_tests.items) |*test_node| {
        for (test_node.macro_depends_on.items) |macro_dep| {
            if (!hasMacro(graph, macro_dep)) return error.UnresolvedMacro;
        }
        sortStrings(test_node.macro_depends_on.items);
        for (test_node.refs.items) |ref_dep| {
            try appendUnique(graph.allocator, &test_node.depends_on, try resolveRefDependency(graph, test_node.package_name, ref_dep));
        }
        for (test_node.source_refs.items) |source_dep| {
            try appendUnique(graph.allocator, &test_node.depends_on, try resolveSourceDependency(graph, test_node.package_name, source_dep));
        }
        sortStrings(test_node.depends_on.items);
    }
    for (graph.unit_tests.items) |*unit_test| {
        if (!unit_test.enabled) continue;
        const model_unique_id = try std.fmt.allocPrint(graph.allocator, "model.{s}.{s}", .{ unit_test.package_name, unit_test.model });
        if (hasDisabledNode(graph, model_unique_id)) return error.DisabledRef;
        if (!hasNode(graph, model_unique_id)) return error.UnresolvedUnitTestModel;
        try appendUnique(graph.allocator, &unit_test.depends_on, model_unique_id);
        sortStrings(unit_test.depends_on.items);
    }
}

pub fn sortGraphResources(graph: *Graph) void {
    sortNodes(graph.nodes.items);
    sortTests(graph.tests.items);
    sortSingularTests(graph.singular_tests.items);
    sortSources(graph.sources.items);
    sortExposures(graph.exposures.items);
    sortUnitTests(graph.unit_tests.items);
    sortDocs(graph.docs.items);
    sortMacros(graph.macros.items);
}

pub fn rejectDuplicateModels(graph: *const Graph) !void {
    var i: usize = 0;
    while (i < graph.nodes.items.len) : (i += 1) {
        var j = i + 1;
        while (j < graph.nodes.items.len) : (j += 1) {
            if (std.mem.eql(u8, graph.nodes.items[i].resource_type, "model") and
                std.mem.eql(u8, graph.nodes.items[j].resource_type, "model") and
                std.mem.eql(u8, graph.nodes.items[i].unique_id, graph.nodes.items[j].unique_id))
            {
                return error.DuplicateModelName;
            }
        }
    }
}

pub fn rejectDuplicateSeeds(graph: *const Graph) !void {
    var i: usize = 0;
    while (i < graph.nodes.items.len) : (i += 1) {
        var j = i + 1;
        while (j < graph.nodes.items.len) : (j += 1) {
            if (std.mem.eql(u8, graph.nodes.items[i].resource_type, "seed") and
                std.mem.eql(u8, graph.nodes.items[j].resource_type, "seed") and
                std.mem.eql(u8, graph.nodes.items[i].unique_id, graph.nodes.items[j].unique_id))
            {
                return error.DuplicateSeedName;
            }
        }
    }
}

pub fn rejectDuplicateDocs(graph: *const Graph) !void {
    var i: usize = 0;
    while (i < graph.docs.items.len) : (i += 1) {
        var j = i + 1;
        while (j < graph.docs.items.len) : (j += 1) {
            if (std.mem.eql(u8, graph.docs.items[i].unique_id, graph.docs.items[j].unique_id)) {
                return error.DuplicateDocName;
            }
        }
    }
}

pub fn rejectDuplicateExposures(graph: *const Graph) !void {
    var i: usize = 0;
    while (i < graph.exposures.items.len) : (i += 1) {
        var j = i + 1;
        while (j < graph.exposures.items.len) : (j += 1) {
            if (std.mem.eql(u8, graph.exposures.items[i].unique_id, graph.exposures.items[j].unique_id)) {
                return error.DuplicateExposureName;
            }
        }
    }
}

pub fn rejectDuplicateUnitTests(graph: *const Graph) !void {
    var i: usize = 0;
    while (i < graph.unit_tests.items.len) : (i += 1) {
        var j = i + 1;
        while (j < graph.unit_tests.items.len) : (j += 1) {
            if (std.mem.eql(u8, graph.unit_tests.items[i].unique_id, graph.unit_tests.items[j].unique_id)) {
                return error.DuplicateUnitTestName;
            }
        }
    }
}

pub fn rejectDuplicateSingularTests(graph: *const Graph) !void {
    var i: usize = 0;
    while (i < graph.singular_tests.items.len) : (i += 1) {
        var j = i + 1;
        while (j < graph.singular_tests.items.len) : (j += 1) {
            if (std.mem.eql(u8, graph.singular_tests.items[i].unique_id, graph.singular_tests.items[j].unique_id)) {
                return error.DuplicateSingularTestName;
            }
        }
    }
}

pub fn rejectDuplicateMacroProperties(graph: *const Graph) !void {
    var i: usize = 0;
    while (i < graph.macro_properties.items.len) : (i += 1) {
        var j = i + 1;
        while (j < graph.macro_properties.items.len) : (j += 1) {
            if (std.mem.eql(u8, graph.macro_properties.items[i].package_name, graph.macro_properties.items[j].package_name) and
                std.mem.eql(u8, graph.macro_properties.items[i].name, graph.macro_properties.items[j].name))
            {
                return error.DuplicateMacroProperty;
            }
        }
    }
}

pub fn rejectDuplicateMacros(graph: *const Graph) !void {
    var i: usize = 0;
    while (i < graph.macros.items.len) : (i += 1) {
        var j = i + 1;
        while (j < graph.macros.items.len) : (j += 1) {
            if (std.mem.eql(u8, graph.macros.items[i].unique_id, graph.macros.items[j].unique_id)) {
                return error.DuplicateMacroName;
            }
        }
    }
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

fn sortNodes(nodes: []Node) void {
    std.mem.sort(Node, nodes, {}, struct {
        fn lessThan(_: void, a: Node, b: Node) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
        }
    }.lessThan);
}

fn sortTests(tests: []GenericTestNode) void {
    std.mem.sort(GenericTestNode, tests, {}, struct {
        fn lessThan(_: void, a: GenericTestNode, b: GenericTestNode) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
        }
    }.lessThan);
}

fn sortSingularTests(tests: []SingularTestNode) void {
    std.mem.sort(SingularTestNode, tests, {}, struct {
        fn lessThan(_: void, a: SingularTestNode, b: SingularTestNode) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
        }
    }.lessThan);
}

fn sortSources(sources: []SourceDef) void {
    std.mem.sort(SourceDef, sources, {}, struct {
        fn lessThan(_: void, a: SourceDef, b: SourceDef) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
        }
    }.lessThan);
}

fn sortExposures(exposures: []ExposureDef) void {
    std.mem.sort(ExposureDef, exposures, {}, struct {
        fn lessThan(_: void, a: ExposureDef, b: ExposureDef) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
        }
    }.lessThan);
}

fn sortUnitTests(unit_tests: []UnitTestDef) void {
    std.mem.sort(UnitTestDef, unit_tests, {}, struct {
        fn lessThan(_: void, a: UnitTestDef, b: UnitTestDef) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
        }
    }.lessThan);
}

fn sortDocs(docs: []DocBlock) void {
    std.mem.sort(DocBlock, docs, {}, struct {
        fn lessThan(_: void, a: DocBlock, b: DocBlock) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
        }
    }.lessThan);
}

fn sortMacros(macros: []MacroDef) void {
    std.mem.sort(MacroDef, macros, {}, struct {
        fn lessThan(_: void, a: MacroDef, b: MacroDef) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
        }
    }.lessThan);
}

fn findProjectMacroIdByName(graph: *const Graph, name: []const u8) ?[]const u8 {
    return findMacroIdByPackageAndName(graph, graph.project_name, name);
}

fn findNonInternalPackageMacroIdByName(graph: *const Graph, current_package: []const u8, name: []const u8) ?[]const u8 {
    for (graph.macros.items) |macro| {
        if (!std.mem.eql(u8, macro.name, name)) continue;
        if (std.mem.eql(u8, macro.package_name, current_package)) continue;
        if (std.mem.eql(u8, macro.package_name, graph.project_name)) continue;
        if (std.mem.eql(u8, macro.package_name, "dbt")) continue;
        return macro.unique_id;
    }
    return null;
}

fn findDispatchConfig(graph: *const Graph, macro_namespace: []const u8) ?*const types.DispatchConfig {
    for (graph.dispatch_configs.items) |*config| {
        if (std.mem.eql(u8, config.macro_namespace, macro_namespace)) return config;
    }
    return null;
}

fn findDispatchMacroIdInConfiguredOrder(graph: *const Graph, search_order: []const []const u8, adapter_prefixes: []const []const u8, macro_name: []const u8) ?[]const u8 {
    for (search_order) |package_name| {
        for (adapter_prefixes) |prefix| {
            if (findDispatchMacroIdByPackageAndName(graph, package_name, prefix, macro_name)) |macro_id| return macro_id;
        }
    }
    return null;
}

fn findDispatchMacroIdInNamespace(graph: *const Graph, package_name: []const u8, prefix: []const u8, macro_name: []const u8) ?[]const u8 {
    if (findDispatchMacroIdByPackageAndName(graph, package_name, prefix, macro_name)) |macro_id| return macro_id;
    if (!std.mem.eql(u8, package_name, graph.project_name)) {
        if (findDispatchMacroIdByPackageAndName(graph, graph.project_name, prefix, macro_name)) |macro_id| return macro_id;
    }
    if (findDispatchMacroIdByPackageAndName(graph, "dbt", prefix, macro_name)) |macro_id| return macro_id;
    return null;
}

fn findDispatchMacroIdByPackageAndName(graph: *const Graph, package_name: []const u8, prefix: []const u8, macro_name: []const u8) ?[]const u8 {
    for (graph.macros.items) |macro| {
        if (!std.mem.eql(u8, macro.package_name, package_name)) continue;
        if (dispatchMacroNameMatches(macro.name, prefix, macro_name)) return macro.unique_id;
    }
    return null;
}

fn dispatchMacroNameMatches(candidate: []const u8, prefix: []const u8, macro_name: []const u8) bool {
    if (candidate.len != prefix.len + "__".len + macro_name.len) return false;
    if (!std.mem.startsWith(u8, candidate, prefix)) return false;
    if (!std.mem.eql(u8, candidate[prefix.len .. prefix.len + "__".len], "__")) return false;
    return std.mem.eql(u8, candidate[prefix.len + "__".len ..], macro_name);
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

fn appendDispatchConfig(graph: *Graph, macro_namespace: []const u8, search_order: []const []const u8) !void {
    var order: std.ArrayList([]const u8) = .empty;
    errdefer order.deinit(graph.allocator);
    try order.appendSlice(graph.allocator, search_order);
    try graph.dispatch_configs.append(graph.allocator, .{
        .macro_namespace = macro_namespace,
        .search_order = order,
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

test "unqualified macro namespace lookup prefers current package root then dbt internal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var graph = Graph{ .allocator = arena.allocator(), .project_name = "demo" };
    defer graph.deinit();

    try appendMacro(&graph, "demo", "format_id");
    try appendMacro(&graph, "pkg", "format_id");
    try appendMacro(&graph, "demo", "project_only");
    try appendMacro(&graph, "other_pkg", "package_only");
    try appendMacro(&graph, "dbt", "internal_only");
    try appendMacro(&graph, "dbt", "project_only");
    try appendMacro(&graph, "dbt", "format_id");

    try std.testing.expectEqualStrings("macro.pkg.format_id", findMacroIdForUnqualifiedNamespaceCall(&graph, "pkg", "format_id").?);
    try std.testing.expectEqualStrings("macro.demo.project_only", findMacroIdForUnqualifiedNamespaceCall(&graph, "pkg", "project_only").?);
    try std.testing.expectEqualStrings("macro.dbt.internal_only", findMacroIdForUnqualifiedNamespaceCall(&graph, "pkg", "internal_only").?);
    try std.testing.expectEqualStrings("macro.demo.format_id", findMacroIdForUnqualifiedNamespaceCall(&graph, "demo", "format_id").?);
    try std.testing.expect(findMacroIdForUnqualifiedNamespaceCall(&graph, "pkg", "package_only") == null);
    try std.testing.expect(findMacroIdForUnqualifiedNamespaceCall(&graph, "demo", "missing") == null);
    try std.testing.expect(hasMacroPackage(&graph, "pkg"));
    try std.testing.expect(!hasMacroPackage(&graph, "other"));
}

test "unqualified macro dependency lookup falls back to other packages before dbt internal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var graph = Graph{ .allocator = arena.allocator(), .project_name = "demo" };
    defer graph.deinit();

    try appendMacro(&graph, "demo", "root_only");
    try appendMacro(&graph, "pkg", "local_only");
    try appendMacro(&graph, "other_pkg", "package_only");
    try appendMacro(&graph, "other_pkg", "internal_shadow");
    try appendMacro(&graph, "dbt", "internal_only");
    try appendMacro(&graph, "dbt", "internal_shadow");

    try std.testing.expectEqualStrings("macro.pkg.local_only", findMacroIdForUnqualifiedMacroDependency(&graph, "pkg", "local_only").?);
    try std.testing.expectEqualStrings("macro.demo.root_only", findMacroIdForUnqualifiedMacroDependency(&graph, "pkg", "root_only").?);
    try std.testing.expectEqualStrings("macro.other_pkg.package_only", findMacroIdForUnqualifiedMacroDependency(&graph, "pkg", "package_only").?);
    try std.testing.expectEqualStrings("macro.other_pkg.internal_shadow", findMacroIdForUnqualifiedMacroDependency(&graph, "pkg", "internal_shadow").?);
    try std.testing.expectEqualStrings("macro.dbt.internal_only", findMacroIdForUnqualifiedMacroDependency(&graph, "pkg", "internal_only").?);
}

test "adapter dispatch lookup follows prefixes and package search order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var graph = Graph{ .allocator = arena.allocator(), .project_name = "demo" };
    defer graph.deinit();

    try appendMacro(&graph, "demo", "default__render");
    try appendMacro(&graph, "demo", "duckdb__root_only");
    try appendMacro(&graph, "demo", "default__namespace_order");
    try appendMacro(&graph, "pkg", "duckdb__render");
    try appendMacro(&graph, "pkg", "default__render");
    try appendMacro(&graph, "pkg", "default__package_only");
    try appendMacro(&graph, "pkg", "duckdb__namespace_order");
    try appendMacro(&graph, "dbt", "default__internal_only");

    const prefixes = &[_][]const u8{ "duckdb", "default" };

    try std.testing.expectEqualStrings("macro.pkg.duckdb__render", findMacroIdForAdapterDispatch(&graph, "pkg", "render", null, prefixes).?);
    try std.testing.expectEqualStrings("macro.demo.default__render", findMacroIdForAdapterDispatch(&graph, "pkg", "render", "pkg", prefixes).?);
    try std.testing.expectEqualStrings("macro.pkg.default__package_only", findMacroIdForAdapterDispatch(&graph, "pkg", "package_only", "pkg", prefixes).?);
    try std.testing.expectEqualStrings("macro.demo.duckdb__root_only", findMacroIdForAdapterDispatch(&graph, "pkg", "root_only", "pkg", prefixes).?);
    try std.testing.expectEqualStrings("macro.demo.default__namespace_order", findMacroIdForAdapterDispatch(&graph, "pkg", "namespace_order", "pkg", prefixes).?);
    try std.testing.expectEqualStrings("macro.dbt.default__internal_only", findMacroIdForAdapterDispatch(&graph, "pkg", "internal_only", "dbt", prefixes).?);
    try std.testing.expect(findMacroIdForAdapterDispatch(&graph, "pkg", "pkg.render", null, prefixes) == null);
    try std.testing.expect(findMacroIdForAdapterDispatch(&graph, "pkg", "missing", "pkg", prefixes) == null);
}

test "adapter dispatch configured search order overrides dependency fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var graph = Graph{ .allocator = arena.allocator(), .project_name = "demo" };
    defer graph.deinit();

    try appendMacro(&graph, "demo", "duckdb__render");
    try appendMacro(&graph, "demo", "default__project_default");
    try appendMacro(&graph, "override_pkg", "duckdb__render");
    try appendMacro(&graph, "override_pkg", "default__project_default");
    try appendMacro(&graph, "util_pkg", "duckdb__render");
    try appendMacro(&graph, "util_pkg", "default__project_default");
    try appendMacro(&graph, "dbt", "default__dispatchable");
    try appendDispatchConfig(&graph, "util_pkg", &[_][]const u8{ "override_pkg", "util_pkg" });
    try appendDispatchConfig(&graph, "dbt", &[_][]const u8{ "demo", "dbt" });

    const prefixes = &[_][]const u8{ "duckdb", "default" };

    try std.testing.expectEqualStrings("macro.override_pkg.duckdb__render", findMacroIdForAdapterDispatch(&graph, "util_pkg", "render", "util_pkg", prefixes).?);
    try std.testing.expectEqualStrings("macro.override_pkg.default__project_default", findMacroIdForAdapterDispatch(&graph, "util_pkg", "project_default", "util_pkg", prefixes).?);
    try std.testing.expectEqualStrings("macro.dbt.default__dispatchable", findMacroIdForAdapterDispatch(&graph, "demo", "dispatchable", "dbt", prefixes).?);
    try std.testing.expect(findMacroIdForAdapterDispatch(&graph, "util_pkg", "missing", "util_pkg", prefixes) == null);
}

test "adapter dispatch empty configured search order follows dbt core dependency fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var graph = Graph{ .allocator = arena.allocator(), .project_name = "demo" };
    defer graph.deinit();

    try appendMacro(&graph, "demo", "default__render");
    try appendMacro(&graph, "util_pkg", "duckdb__render");
    try appendDispatchConfig(&graph, "util_pkg", &[_][]const u8{});

    const prefixes = &[_][]const u8{ "duckdb", "default" };

    try std.testing.expectEqualStrings("macro.demo.default__render", findMacroIdForAdapterDispatch(&graph, "util_pkg", "render", "util_pkg", prefixes).?);
}

test "macro unique id package extraction accepts only macro ids" {
    try std.testing.expectEqualStrings("pkg", packageNameFromMacroUniqueId("macro.pkg.some_macro").?);
    try std.testing.expect(packageNameFromMacroUniqueId("model.pkg.some_macro") == null);
    try std.testing.expect(packageNameFromMacroUniqueId("macro.") == null);
    try std.testing.expect(packageNameFromMacroUniqueId("macro.pkg") == null);
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

test "duplicate validation rejects duplicate model and seed unique ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var graph = Graph{ .allocator = arena.allocator(), .project_name = "demo" };
    defer graph.deinit();

    try appendNode(&graph, "model", "demo", "model.demo.customers", "customers", true);
    try appendNode(&graph, "model", "demo", "model.demo.customers", "customers", true);
    try appendNode(&graph, "seed", "demo", "seed.demo.raw_customers", "raw_customers", true);
    try appendNode(&graph, "seed", "demo", "seed.demo.raw_customers", "raw_customers", true);

    try std.testing.expectError(error.DuplicateModelName, rejectDuplicateModels(&graph));
    try std.testing.expectError(error.DuplicateSeedName, rejectDuplicateSeeds(&graph));
}

test "duplicate validation rejects docs exposures unit tests macros and macro properties" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var graph = Graph{ .allocator = arena.allocator(), .project_name = "demo" };
    defer graph.deinit();

    try graph.docs.append(graph.allocator, .{ .package_name = "demo", .unique_id = "doc.demo.orders", .name = "orders", .path = "", .original_file_path = "", .block_contents = "" });
    try graph.docs.append(graph.allocator, .{ .package_name = "demo", .unique_id = "doc.demo.orders", .name = "orders", .path = "", .original_file_path = "", .block_contents = "" });
    try graph.exposures.append(graph.allocator, .{ .package_name = "demo", .unique_id = "exposure.demo.weekly_kpis", .name = "weekly_kpis", .path = "", .original_file_path = "" });
    try graph.exposures.append(graph.allocator, .{ .package_name = "demo", .unique_id = "exposure.demo.weekly_kpis", .name = "weekly_kpis", .path = "", .original_file_path = "" });
    try graph.unit_tests.append(graph.allocator, .{ .package_name = "demo", .unique_id = "unit_test.demo.orders.assert_orders", .name = "assert_orders", .model = "orders", .path = "", .original_file_path = "" });
    try graph.unit_tests.append(graph.allocator, .{ .package_name = "demo", .unique_id = "unit_test.demo.orders.assert_orders", .name = "assert_orders", .model = "orders", .path = "", .original_file_path = "" });
    try appendMacro(&graph, "demo", "format_id");
    try appendMacro(&graph, "demo", "format_id");
    try graph.macro_properties.append(graph.allocator, .{ .package_name = "demo", .name = "format_id", .patch_path = "macros/schema.yml" });
    try graph.macro_properties.append(graph.allocator, .{ .package_name = "demo", .name = "format_id", .patch_path = "macros/schema.yml" });

    try std.testing.expectError(error.DuplicateDocName, rejectDuplicateDocs(&graph));
    try std.testing.expectError(error.DuplicateExposureName, rejectDuplicateExposures(&graph));
    try std.testing.expectError(error.DuplicateUnitTestName, rejectDuplicateUnitTests(&graph));
    try std.testing.expectError(error.DuplicateMacroName, rejectDuplicateMacros(&graph));
    try std.testing.expectError(error.DuplicateMacroProperty, rejectDuplicateMacroProperties(&graph));
}

test "dependency resolution populates sorted unique node exposure and unit test dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var graph = Graph{ .allocator = arena.allocator(), .project_name = "demo" };
    defer graph.deinit();

    try appendNode(&graph, "model", "demo", "model.demo.customers", "customers", true);
    try appendNode(&graph, "model", "demo", "model.demo.orders", "orders", true);
    try appendSource(&graph, "demo", "raw", "customers");
    try appendMacro(&graph, "demo", "format_id");

    try graph.nodes.items[1].refs.append(graph.allocator, .{ .package = null, .name = "customers" });
    try graph.nodes.items[1].refs.append(graph.allocator, .{ .package = null, .name = "customers" });
    try graph.nodes.items[1].source_refs.append(graph.allocator, .{ .source_name = "raw", .table_name = "customers" });
    try graph.nodes.items[1].macro_depends_on.append(graph.allocator, "macro.demo.format_id");

    try graph.exposures.append(graph.allocator, .{
        .package_name = "demo",
        .unique_id = "exposure.demo.weekly_kpis",
        .name = "weekly_kpis",
        .path = "",
        .original_file_path = "",
        .enabled = true,
    });
    try graph.exposures.items[0].refs.append(graph.allocator, .{ .package = null, .name = "orders" });
    try graph.exposures.items[0].source_refs.append(graph.allocator, .{ .source_name = "raw", .table_name = "customers" });
    try graph.unit_tests.append(graph.allocator, .{
        .package_name = "demo",
        .unique_id = "unit_test.demo.orders.assert_orders",
        .name = "assert_orders",
        .model = "orders",
        .path = "",
        .original_file_path = "",
    });

    try resolveDependencies(&graph);

    try std.testing.expectEqual(@as(usize, 2), graph.nodes.items[1].depends_on.items.len);
    try std.testing.expectEqualStrings("model.demo.customers", graph.nodes.items[1].depends_on.items[0]);
    try std.testing.expectEqualStrings("source.demo.raw.customers", graph.nodes.items[1].depends_on.items[1]);
    try std.testing.expectEqual(@as(usize, 1), graph.nodes.items[1].macro_depends_on.items.len);
    try std.testing.expectEqualStrings("macro.demo.format_id", graph.nodes.items[1].macro_depends_on.items[0]);
    try std.testing.expectEqual(@as(usize, 2), graph.exposures.items[0].depends_on.items.len);
    try std.testing.expectEqualStrings("model.demo.orders", graph.exposures.items[0].depends_on.items[0]);
    try std.testing.expectEqualStrings("source.demo.raw.customers", graph.exposures.items[0].depends_on.items[1]);
    try std.testing.expectEqual(@as(usize, 1), graph.unit_tests.items[0].depends_on.items.len);
    try std.testing.expectEqualStrings("model.demo.orders", graph.unit_tests.items[0].depends_on.items[0]);
}

test "dependency resolution rejects unresolved macro dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var graph = Graph{ .allocator = arena.allocator(), .project_name = "demo" };
    defer graph.deinit();

    try appendNode(&graph, "model", "demo", "model.demo.customers", "customers", true);
    try graph.nodes.items[0].macro_depends_on.append(graph.allocator, "macro.demo.missing");

    try std.testing.expectError(error.UnresolvedMacro, resolveDependencies(&graph));
}

test "dependency resolution rejects unit tests for missing models" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var graph = Graph{ .allocator = arena.allocator(), .project_name = "demo" };
    defer graph.deinit();

    try graph.unit_tests.append(graph.allocator, .{
        .package_name = "demo",
        .unique_id = "unit_test.demo.missing.assert_missing",
        .name = "assert_missing",
        .model = "missing",
        .path = "",
        .original_file_path = "",
    });

    try std.testing.expectError(error.UnresolvedUnitTestModel, resolveDependencies(&graph));
}

test "graph resource sorting preserves deterministic unique id order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var graph = Graph{ .allocator = arena.allocator(), .project_name = "demo" };
    defer graph.deinit();

    try appendNode(&graph, "model", "demo", "model.demo.z_orders", "z_orders", true);
    try appendNode(&graph, "model", "demo", "model.demo.a_customers", "a_customers", true);
    try graph.tests.append(graph.allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.z_test.2222222222",
        .name = "z_test",
        .alias = "z_test",
        .path = "",
        .original_file_path = "",
        .raw_code = "",
        .test_name = "unique",
        .attached_node = "model.demo.z_orders",
    });
    try graph.tests.append(graph.allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.a_test.1111111111",
        .name = "a_test",
        .alias = "a_test",
        .path = "",
        .original_file_path = "",
        .raw_code = "",
        .test_name = "not_null",
        .attached_node = "model.demo.a_customers",
    });
    try appendSource(&graph, "demo", "raw", "z_orders");
    try appendSource(&graph, "demo", "raw", "a_customers");
    try graph.exposures.append(graph.allocator, .{ .package_name = "demo", .unique_id = "exposure.demo.z_dashboard", .name = "z_dashboard", .path = "", .original_file_path = "" });
    try graph.exposures.append(graph.allocator, .{ .package_name = "demo", .unique_id = "exposure.demo.a_dashboard", .name = "a_dashboard", .path = "", .original_file_path = "" });
    try graph.unit_tests.append(graph.allocator, .{ .package_name = "demo", .unique_id = "unit_test.demo.z_orders.z_assert", .name = "z_assert", .model = "z_orders", .path = "", .original_file_path = "" });
    try graph.unit_tests.append(graph.allocator, .{ .package_name = "demo", .unique_id = "unit_test.demo.a_customers.a_assert", .name = "a_assert", .model = "a_customers", .path = "", .original_file_path = "" });
    try graph.docs.append(graph.allocator, .{ .package_name = "demo", .unique_id = "doc.demo.z_doc", .name = "z_doc", .path = "", .original_file_path = "", .block_contents = "" });
    try graph.docs.append(graph.allocator, .{ .package_name = "demo", .unique_id = "doc.demo.a_doc", .name = "a_doc", .path = "", .original_file_path = "", .block_contents = "" });
    try appendMacro(&graph, "demo", "z_macro");
    try appendMacro(&graph, "demo", "a_macro");

    sortGraphResources(&graph);

    try std.testing.expectEqualStrings("model.demo.a_customers", graph.nodes.items[0].unique_id);
    try std.testing.expectEqualStrings("model.demo.z_orders", graph.nodes.items[1].unique_id);
    try std.testing.expectEqualStrings("test.demo.a_test.1111111111", graph.tests.items[0].unique_id);
    try std.testing.expectEqualStrings("test.demo.z_test.2222222222", graph.tests.items[1].unique_id);
    try std.testing.expectEqualStrings("source.demo.raw.a_customers", graph.sources.items[0].unique_id);
    try std.testing.expectEqualStrings("source.demo.raw.z_orders", graph.sources.items[1].unique_id);
    try std.testing.expectEqualStrings("exposure.demo.a_dashboard", graph.exposures.items[0].unique_id);
    try std.testing.expectEqualStrings("exposure.demo.z_dashboard", graph.exposures.items[1].unique_id);
    try std.testing.expectEqualStrings("unit_test.demo.a_customers.a_assert", graph.unit_tests.items[0].unique_id);
    try std.testing.expectEqualStrings("unit_test.demo.z_orders.z_assert", graph.unit_tests.items[1].unique_id);
    try std.testing.expectEqualStrings("doc.demo.a_doc", graph.docs.items[0].unique_id);
    try std.testing.expectEqualStrings("doc.demo.z_doc", graph.docs.items[1].unique_id);
    try std.testing.expectEqualStrings("macro.demo.a_macro", graph.macros.items[0].unique_id);
    try std.testing.expectEqualStrings("macro.demo.z_macro", graph.macros.items[1].unique_id);
}
