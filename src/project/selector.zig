const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");

const Graph = types.Graph;
const Node = types.Node;
const GenericTestNode = types.GenericTestNode;
const SingularTestNode = types.SingularTestNode;
const SourceDef = types.SourceDef;
const ExposureDef = types.ExposureDef;
const UnitTestDef = types.UnitTestDef;

pub const SelectedResource = struct {
    unique_id: []const u8,
    name: []const u8,
    resource_type: []const u8,
    package_name: []const u8 = "",
    source_name: []const u8 = "",
    search_name: []const u8 = "",
    path: []const u8 = "",
    original_file_path: []const u8 = "",
    selector: []const u8 = "",
    alias: []const u8 = "",
    identifier: []const u8 = "",
    config_materialized: []const u8 = "",
    config_tags: []const []const u8 = &.{},
    has_config_tags: bool = false,
};

const SelectorSpec = struct {
    active: bool = false,
    valid: bool = true,
    value: []const u8 = "",
    include_childrens_parents: bool = false,
    include_parents: bool = false,
    include_children: bool = false,
    parents_depth: ?usize = null,
    children_depth: ?usize = null,
};

pub fn selectResources(allocator: std.mem.Allocator, graph: *const Graph, resource_type: ?[]const u8, select: ?[]const u8, exclude: ?[]const u8) ![]SelectedResource {
    const select_spec = parseSelectorSpec(select);
    const exclude_spec = parseSelectorSpec(exclude);
    var selected: std.ArrayList(SelectedResource) = .empty;
    errdefer selected.deinit(allocator);
    for (graph.nodes.items) |*node| {
        if (!node.enabled) continue;
        if (matchesResourceType(resource_type, node.resource_type) and matchesSelector(graph, node, select_spec) and (!exclude_spec.active or !matchesSelector(graph, node, exclude_spec))) {
            try selected.append(allocator, .{
                .unique_id = node.unique_id,
                .name = node.name,
                .resource_type = node.resource_type,
                .package_name = node.package_name,
                .search_name = node.name,
                .path = node.path,
                .original_file_path = node.original_file_path,
                .selector = try pathBackedOutputSelector(allocator, node.package_name, node.path),
                .alias = node.config_alias orelse node.name,
                .config_materialized = node.materialized,
                .config_tags = node.tags.items,
                .has_config_tags = true,
            });
        }
    }
    for (graph.tests.items) |*test_node| {
        if (matchesResourceType(resource_type, "test") and matchesTestSelector(graph, test_node, select_spec) and (!exclude_spec.active or !matchesTestSelector(graph, test_node, exclude_spec))) {
            try selected.append(allocator, .{
                .unique_id = test_node.unique_id,
                .name = test_node.name,
                .resource_type = "test",
                .package_name = test_node.package_name,
                .search_name = test_node.name,
                .path = test_node.path,
                .original_file_path = test_node.original_file_path,
                .selector = try pathBackedOutputSelector(allocator, test_node.package_name, test_node.path),
                .alias = test_node.alias,
                .config_materialized = "test",
                .has_config_tags = true,
            });
        }
    }
    for (graph.singular_tests.items) |*test_node| {
        if (!test_node.enabled) continue;
        if (matchesResourceType(resource_type, "test") and matchesSingularTestSelector(graph, test_node, select_spec) and (!exclude_spec.active or !matchesSingularTestSelector(graph, test_node, exclude_spec))) {
            try selected.append(allocator, .{
                .unique_id = test_node.unique_id,
                .name = test_node.name,
                .resource_type = "test",
                .package_name = test_node.package_name,
                .search_name = test_node.name,
                .path = test_node.path,
                .original_file_path = test_node.original_file_path,
                .selector = try pathBackedOutputSelector(allocator, test_node.package_name, test_node.path),
                .alias = test_node.alias,
                .config_materialized = "test",
                .has_config_tags = true,
            });
        }
    }
    for (graph.sources.items) |*source| {
        if (matchesResourceType(resource_type, "source") and matchesSourceSelector(graph, source, select_spec) and (!exclude_spec.active or !matchesSourceSelector(graph, source, exclude_spec))) {
            try selected.append(allocator, .{
                .unique_id = source.unique_id,
                .name = source.table_name,
                .resource_type = "source",
                .package_name = source.package_name,
                .source_name = source.source_name,
                .search_name = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ source.source_name, source.table_name }),
                .path = source.original_file_path,
                .original_file_path = source.original_file_path,
                .selector = try std.fmt.allocPrint(allocator, "source:{s}.{s}.{s}", .{ source.package_name, source.source_name, source.table_name }),
                .identifier = source.identifier orelse source.table_name,
            });
        }
    }
    for (graph.exposures.items) |*exposure| {
        if (!exposure.enabled) continue;
        if (matchesResourceType(resource_type, "exposure") and matchesExposureSelector(graph, exposure, select_spec) and (!exclude_spec.active or !matchesExposureSelector(graph, exposure, exclude_spec))) {
            try selected.append(allocator, .{
                .unique_id = exposure.unique_id,
                .name = exposure.name,
                .resource_type = "exposure",
                .package_name = exposure.package_name,
                .search_name = exposure.name,
                .path = exposure.path,
                .original_file_path = exposure.original_file_path,
                .selector = try std.fmt.allocPrint(allocator, "exposure:{s}.{s}", .{ exposure.package_name, exposure.name }),
            });
        }
    }
    for (graph.unit_tests.items) |*unit_test| {
        if (!unit_test.enabled) continue;
        if (matchesResourceType(resource_type, "unit_test") and matchesUnitTestSelector(graph, unit_test, select_spec) and (!exclude_spec.active or !matchesUnitTestSelector(graph, unit_test, exclude_spec))) {
            try selected.append(allocator, .{
                .unique_id = unit_test.unique_id,
                .name = unit_test.name,
                .resource_type = "unit_test",
                .package_name = unit_test.package_name,
                .search_name = unit_test.name,
                .path = unit_test.path,
                .original_file_path = unit_test.original_file_path,
                .selector = try std.fmt.allocPrint(allocator, "unit_test:{s}.{s}", .{ unit_test.package_name, unit_test.name }),
                .config_tags = unit_test.tags.items,
                .has_config_tags = true,
            });
        }
    }
    std.mem.sort(SelectedResource, selected.items, {}, struct {
        fn lessThan(_: void, a: SelectedResource, b: SelectedResource) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
        }
    }.lessThan);
    return try selected.toOwnedSlice(allocator);
}

fn pathBackedOutputSelector(allocator: std.mem.Allocator, package_name: []const u8, path: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, package_name);
    try out.append(allocator, '.');
    const end = if (std.mem.endsWith(u8, path, ".sql") or std.mem.endsWith(u8, path, ".csv"))
        path.len - 4
    else
        path.len;
    for (path[0..end]) |byte| {
        try out.append(allocator, if (byte == '/' or byte == '\\') '.' else byte);
    }
    return try out.toOwnedSlice(allocator);
}

fn matchesResourceType(requested: ?[]const u8, actual: []const u8) bool {
    if (requested) |value| return std.mem.eql(u8, value, actual);
    return true;
}

fn matchesSelector(graph: *const Graph, node: *const Node, spec: SelectorSpec) bool {
    if (!spec.active) return true;
    if (spec.value.len == 0) return true;
    return matchesNodeSelectorExpression(graph, node, spec.value);
}

fn matchesNodeSelectorExpression(graph: *const Graph, node: *const Node, value: []const u8) bool {
    var expressions = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (expressions.next()) |expression| {
        if (matchesNodeSelectorIntersection(graph, node, expression)) return true;
    }
    return false;
}

fn matchesNodeSelectorIntersection(graph: *const Graph, node: *const Node, value: []const u8) bool {
    var raw_terms = std.mem.splitScalar(u8, value, ',');
    var matched_any = false;
    while (raw_terms.next()) |raw_term| {
        const term = parseSelectorTerm(raw_term);
        if (!term.valid) return false;
        if (term.value.len == 0) return false;
        if (!matchesNodeSelectorTerm(graph, node, term.value) and !matchesGraphExpansion(graph, node.unique_id, term)) return false;
        matched_any = true;
    }
    return matched_any;
}

fn matchesNodeSelectorTerm(graph: *const Graph, node: *const Node, value: []const u8) bool {
    if (matchesSelectorPattern(value, node.name) or std.mem.eql(u8, value, node.unique_id) or matchesNodeFqnPattern(value, node)) return true;
    if (std.mem.startsWith(u8, value, "resource_type:")) {
        const resource_type = value["resource_type:".len..];
        return std.mem.eql(u8, resource_type, node.resource_type);
    }
    if (std.mem.startsWith(u8, value, "test_type:")) {
        return false;
    }
    if (std.mem.startsWith(u8, value, "package:")) {
        return matchesUniqueIdPackage(graph, node.unique_id, value["package:".len..]);
    }
    if (std.mem.startsWith(u8, value, "tag:")) {
        const tag = value["tag:".len..];
        for (node.tags.items) |node_tag| {
            if (matchesSelectorPattern(tag, node_tag)) return true;
        }
    }
    if (std.mem.startsWith(u8, value, "path:")) {
        const path = value["path:".len..];
        return matchesNodePathSelector(path, node);
    }
    if (std.mem.startsWith(u8, value, "file:")) {
        const file = value["file:".len..];
        return matchesFileSelector(file, node.original_file_path);
    }
    if (std.mem.startsWith(u8, value, "source:")) {
        return false;
    }
    if (std.mem.startsWith(u8, value, "config.materialized:")) {
        const materialized = value["config.materialized:".len..];
        return (std.mem.eql(u8, node.resource_type, "model") or std.mem.eql(u8, node.resource_type, "analysis")) and std.mem.eql(u8, materialized, node.materialized);
    }
    return false;
}

fn matchesTestSelector(graph: *const Graph, test_node: *const GenericTestNode, spec: SelectorSpec) bool {
    if (!spec.active) return true;
    if (spec.value.len == 0) return true;
    return matchesTestSelectorExpression(graph, test_node, spec.value);
}

fn matchesTestSelectorExpression(graph: *const Graph, test_node: *const GenericTestNode, value: []const u8) bool {
    var expressions = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (expressions.next()) |expression| {
        if (matchesTestSelectorIntersection(graph, test_node, expression)) return true;
    }
    return false;
}

fn matchesTestSelectorIntersection(graph: *const Graph, test_node: *const GenericTestNode, value: []const u8) bool {
    var raw_terms = std.mem.splitScalar(u8, value, ',');
    var matched_any = false;
    while (raw_terms.next()) |raw_term| {
        const term = parseSelectorTerm(raw_term);
        if (!term.valid) return false;
        if (term.value.len == 0) return false;
        if (!matchesTestSelectorTerm(graph, test_node, term.value) and !matchesGraphExpansion(graph, test_node.unique_id, term)) return false;
        matched_any = true;
    }
    return matched_any;
}

fn matchesTestSelectorTerm(graph: *const Graph, test_node: *const GenericTestNode, value: []const u8) bool {
    if (matchesSelectorPattern(value, test_node.name) or std.mem.eql(u8, value, test_node.unique_id) or matchesGenericTestFqnPattern(value, test_node)) return true;
    if (matchesAttachedNodeNameOrFqnSelector(graph, test_node, value)) return true;
    if (std.mem.startsWith(u8, value, "resource_type:")) {
        const resource_type = value["resource_type:".len..];
        return std.mem.eql(u8, resource_type, "test");
    }
    if (std.mem.startsWith(u8, value, "test_type:")) {
        const test_type = value["test_type:".len..];
        return std.mem.eql(u8, test_type, "generic") or std.mem.eql(u8, test_type, "data");
    }
    if (std.mem.startsWith(u8, value, "package:")) {
        return matchesUniqueIdPackage(graph, test_node.unique_id, value["package:".len..]);
    }
    if (std.mem.startsWith(u8, value, "path:")) {
        const path = value["path:".len..];
        return matchesPathSelector(path, test_node.original_file_path);
    }
    if (std.mem.startsWith(u8, value, "file:")) {
        const file = value["file:".len..];
        return matchesFileSelector(file, test_node.original_file_path);
    }
    return false;
}

fn matchesSingularTestSelector(graph: *const Graph, test_node: *const SingularTestNode, spec: SelectorSpec) bool {
    if (!spec.active) return true;
    if (spec.value.len == 0) return true;
    return matchesSingularTestSelectorExpression(graph, test_node, spec.value);
}

fn matchesSingularTestSelectorExpression(graph: *const Graph, test_node: *const SingularTestNode, value: []const u8) bool {
    var expressions = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (expressions.next()) |expression| {
        if (matchesSingularTestSelectorIntersection(graph, test_node, expression)) return true;
    }
    return false;
}

fn matchesSingularTestSelectorIntersection(graph: *const Graph, test_node: *const SingularTestNode, value: []const u8) bool {
    var raw_terms = std.mem.splitScalar(u8, value, ',');
    var matched_any = false;
    while (raw_terms.next()) |raw_term| {
        const term = parseSelectorTerm(raw_term);
        if (!term.valid) return false;
        if (term.value.len == 0) return false;
        if (!matchesSingularTestSelectorTerm(graph, test_node, term.value) and !matchesGraphExpansion(graph, test_node.unique_id, term)) return false;
        matched_any = true;
    }
    return matched_any;
}

fn matchesSingularTestSelectorTerm(graph: *const Graph, test_node: *const SingularTestNode, value: []const u8) bool {
    if (matchesSelectorPattern(value, test_node.name) or std.mem.eql(u8, value, test_node.unique_id) or matchesSingularTestFqnPattern(value, test_node)) return true;
    if (matchesSingularDependencyNameOrFqnSelector(graph, test_node, value)) return true;
    if (std.mem.startsWith(u8, value, "resource_type:")) {
        const resource_type = value["resource_type:".len..];
        return std.mem.eql(u8, resource_type, "test");
    }
    if (std.mem.startsWith(u8, value, "test_type:")) {
        const test_type = value["test_type:".len..];
        return std.mem.eql(u8, test_type, "singular") or std.mem.eql(u8, test_type, "data");
    }
    if (std.mem.startsWith(u8, value, "package:")) {
        return matchesUniqueIdPackage(graph, test_node.unique_id, value["package:".len..]);
    }
    if (std.mem.startsWith(u8, value, "path:")) {
        const path = value["path:".len..];
        return matchesPathSelector(path, test_node.original_file_path);
    }
    if (std.mem.startsWith(u8, value, "file:")) {
        const file = value["file:".len..];
        return matchesFileSelector(file, test_node.original_file_path);
    }
    return false;
}

fn matchesAttachedNodeNameOrFqnSelector(graph: *const Graph, test_node: *const GenericTestNode, value: []const u8) bool {
    const attached_node = test_node.attached_node orelse return false;
    for (graph.nodes.items) |*node| {
        if (!node.enabled or !std.mem.eql(u8, node.unique_id, attached_node)) continue;
        if (std.mem.startsWith(u8, value, "tag:")) {
            const tag = value["tag:".len..];
            for (node.tags.items) |node_tag| {
                if (matchesSelectorPattern(tag, node_tag)) return true;
            }
            return false;
        }
        return matchesSelectorPattern(value, node.name) or matchesNodeFqnPattern(value, node);
    }
    return false;
}

fn matchesSingularDependencyNameOrFqnSelector(graph: *const Graph, test_node: *const SingularTestNode, value: []const u8) bool {
    for (graph.nodes.items) |*node| {
        if (!node.enabled or !util.containsString(test_node.depends_on.items, node.unique_id)) continue;
        if (std.mem.startsWith(u8, value, "tag:")) {
            const tag = value["tag:".len..];
            for (node.tags.items) |node_tag| {
                if (matchesSelectorPattern(tag, node_tag)) return true;
            }
            continue;
        }
        if (matchesSelectorPattern(value, node.name) or matchesNodeFqnPattern(value, node)) return true;
    }
    return false;
}

fn matchesSourceSelector(graph: *const Graph, source: *const SourceDef, spec: SelectorSpec) bool {
    if (!spec.active) return true;
    if (spec.value.len == 0) return true;
    return matchesSourceSelectorExpression(graph, source, spec.value);
}

fn matchesSourceSelectorExpression(graph: *const Graph, source: *const SourceDef, value: []const u8) bool {
    var expressions = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (expressions.next()) |expression| {
        if (matchesSourceSelectorIntersection(graph, source, expression)) return true;
    }
    return false;
}

fn matchesSourceSelectorIntersection(graph: *const Graph, source: *const SourceDef, value: []const u8) bool {
    var raw_terms = std.mem.splitScalar(u8, value, ',');
    var matched_any = false;
    while (raw_terms.next()) |raw_term| {
        const term = parseSelectorTerm(raw_term);
        if (!term.valid) return false;
        if (term.value.len == 0) return false;
        if (!matchesSourceSelectorTerm(graph, source, term.value) and !matchesGraphExpansion(graph, source.unique_id, term)) return false;
        matched_any = true;
    }
    return matched_any;
}

fn matchesSourceSelectorTerm(graph: *const Graph, source: *const SourceDef, value: []const u8) bool {
    if (std.mem.startsWith(u8, value, "resource_type:")) {
        const resource_type = value["resource_type:".len..];
        return std.mem.eql(u8, resource_type, "source");
    }
    if (std.mem.startsWith(u8, value, "test_type:")) {
        return false;
    }
    if (std.mem.startsWith(u8, value, "package:")) {
        return matchesUniqueIdPackage(graph, source.unique_id, value["package:".len..]);
    }
    if (std.mem.startsWith(u8, value, "source:")) {
        const source_value = value["source:".len..];
        if (matchesSelectorPattern(source_value, source.source_name)) return true;
        if (std.mem.indexOfScalar(u8, source_value, '.')) |dot| {
            if (std.mem.indexOfScalar(u8, source_value[dot + 1 ..], '.')) |relative_second_dot| {
                const second_dot = dot + 1 + relative_second_dot;
                return matchesSelectorPattern(source_value[0..dot], source.package_name) and
                    matchesSelectorPattern(source_value[dot + 1 .. second_dot], source.source_name) and
                    matchesSelectorPattern(source_value[second_dot + 1 ..], source.table_name);
            }
            return matchesSelectorPattern(source_value[0..dot], source.source_name) and matchesSelectorPattern(source_value[dot + 1 ..], source.table_name);
        }
    }
    if (std.mem.startsWith(u8, value, "path:")) {
        const path = value["path:".len..];
        return matchesPathSelector(path, source.original_file_path);
    }
    if (std.mem.startsWith(u8, value, "file:")) {
        const file = value["file:".len..];
        return matchesFileSelector(file, source.original_file_path);
    }
    return false;
}

fn matchesExposureSelector(graph: *const Graph, exposure: *const ExposureDef, spec: SelectorSpec) bool {
    if (!spec.active) return true;
    if (spec.value.len == 0) return true;
    return matchesExposureSelectorExpression(graph, exposure, spec.value);
}

fn matchesExposureSelectorExpression(graph: *const Graph, exposure: *const ExposureDef, value: []const u8) bool {
    var expressions = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (expressions.next()) |expression| {
        if (matchesExposureSelectorIntersection(graph, exposure, expression)) return true;
    }
    return false;
}

fn matchesExposureSelectorIntersection(graph: *const Graph, exposure: *const ExposureDef, value: []const u8) bool {
    var raw_terms = std.mem.splitScalar(u8, value, ',');
    var matched_any = false;
    while (raw_terms.next()) |raw_term| {
        const term = parseSelectorTerm(raw_term);
        if (!term.valid) return false;
        if (term.value.len == 0) return false;
        if (!matchesExposureSelectorTerm(graph, exposure, term.value) and !matchesGraphExpansion(graph, exposure.unique_id, term)) return false;
        matched_any = true;
    }
    return matched_any;
}

fn matchesExposureSelectorTerm(graph: *const Graph, exposure: *const ExposureDef, value: []const u8) bool {
    if (matchesSelectorPattern(value, exposure.name) or matchesUniqueIdFqnPattern(value, exposure.unique_id)) return true;
    if (std.mem.startsWith(u8, value, "resource_type:")) {
        const resource_type = value["resource_type:".len..];
        return std.mem.eql(u8, resource_type, "exposure");
    }
    if (std.mem.startsWith(u8, value, "test_type:")) {
        return false;
    }
    if (std.mem.startsWith(u8, value, "package:")) {
        return matchesUniqueIdPackage(graph, exposure.unique_id, value["package:".len..]);
    }
    if (std.mem.startsWith(u8, value, "exposure:")) {
        const exposure_value = value["exposure:".len..];
        return matchesSelectorPattern(exposure_value, exposure.name) or matchesUniqueIdFqnPattern(exposure_value, exposure.unique_id);
    }
    if (std.mem.startsWith(u8, value, "tag:")) {
        const tag = value["tag:".len..];
        for (exposure.tags.items) |exposure_tag| {
            if (matchesSelectorPattern(tag, exposure_tag)) return true;
        }
    }
    if (std.mem.startsWith(u8, value, "path:")) {
        const path = value["path:".len..];
        return matchesPathSelector(path, exposure.original_file_path);
    }
    if (std.mem.startsWith(u8, value, "file:")) {
        const file = value["file:".len..];
        return matchesFileSelector(file, exposure.original_file_path);
    }
    return false;
}

fn matchesUnitTestSelector(graph: *const Graph, unit_test: *const UnitTestDef, spec: SelectorSpec) bool {
    if (!spec.active) return true;
    if (spec.value.len == 0) return true;
    return matchesUnitTestSelectorExpression(graph, unit_test, spec.value);
}

fn matchesUnitTestSelectorExpression(graph: *const Graph, unit_test: *const UnitTestDef, value: []const u8) bool {
    var expressions = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (expressions.next()) |expression| {
        if (matchesUnitTestSelectorIntersection(graph, unit_test, expression)) return true;
    }
    return false;
}

fn matchesUnitTestSelectorIntersection(graph: *const Graph, unit_test: *const UnitTestDef, value: []const u8) bool {
    var raw_terms = std.mem.splitScalar(u8, value, ',');
    var matched_any = false;
    while (raw_terms.next()) |raw_term| {
        const term = parseSelectorTerm(raw_term);
        if (!term.valid) return false;
        if (term.value.len == 0) return false;
        if (!matchesUnitTestSelectorTerm(graph, unit_test, term.value) and !matchesGraphExpansion(graph, unit_test.unique_id, term)) return false;
        matched_any = true;
    }
    return matched_any;
}

fn matchesUnitTestSelectorTerm(graph: *const Graph, unit_test: *const UnitTestDef, value: []const u8) bool {
    if (matchesSelectorPattern(value, unit_test.name) or
        std.mem.eql(u8, value, unit_test.unique_id) or
        matchesUnitTestFqnPattern(value, unit_test))
    {
        return true;
    }
    if (std.mem.startsWith(u8, value, "resource_type:")) {
        const resource_type = value["resource_type:".len..];
        return std.mem.eql(u8, resource_type, "unit_test");
    }
    if (std.mem.startsWith(u8, value, "test_type:")) {
        const test_type = value["test_type:".len..];
        return std.mem.eql(u8, test_type, "unit");
    }
    if (std.mem.startsWith(u8, value, "package:")) {
        return matchesUniqueIdPackage(graph, unit_test.unique_id, value["package:".len..]);
    }
    if (std.mem.startsWith(u8, value, "unit_test:")) {
        const unit_value = value["unit_test:".len..];
        if (matchesSelectorPattern(unit_value, unit_test.name)) return true;
        if (std.mem.indexOfScalar(u8, unit_value, '.')) |first_dot| {
            if (std.mem.indexOfScalar(u8, unit_value[first_dot + 1 ..], '.')) |relative_second_dot| {
                const second_dot = first_dot + 1 + relative_second_dot;
                return matchesSelectorPattern(unit_value[0..first_dot], unit_test.package_name) and
                    matchesSelectorPattern(unit_value[first_dot + 1 .. second_dot], unit_test.model) and
                    matchesSelectorPattern(unit_value[second_dot + 1 ..], unit_test.name);
            }
            return (matchesSelectorPattern(unit_value[0..first_dot], unit_test.package_name) or
                matchesSelectorPattern(unit_value[0..first_dot], unit_test.model)) and
                matchesSelectorPattern(unit_value[first_dot + 1 ..], unit_test.name);
        }
        return false;
    }
    if (std.mem.startsWith(u8, value, "tag:")) {
        const tag = value["tag:".len..];
        for (unit_test.tags.items) |unit_tag| {
            if (matchesSelectorPattern(tag, unit_tag)) return true;
        }
    }
    if (std.mem.startsWith(u8, value, "path:")) {
        const path = value["path:".len..];
        return matchesPathSelector(path, unit_test.original_file_path);
    }
    if (std.mem.startsWith(u8, value, "file:")) {
        const file = value["file:".len..];
        return matchesFileSelector(file, unit_test.original_file_path);
    }
    return false;
}

fn matchesPathSelector(pattern: []const u8, path: []const u8) bool {
    if (selectorPatternHasWildcard(pattern)) {
        if (wildcardMatchesPath(pattern, path)) return true;
        return wildcardMatchesPathParent(pattern, path);
    }
    return std.mem.indexOf(u8, path, pattern) != null;
}

fn matchesNodePathSelector(pattern: []const u8, node: *const Node) bool {
    if (matchesPathSelector(pattern, node.original_file_path)) return true;
    if (node.patch_path) |patch_path| return matchesPathSelector(pattern, patch_path);
    return false;
}

fn matchesFileSelector(pattern: []const u8, path: []const u8) bool {
    const file_name = pathBasename(path);
    if (matchesSelectorPattern(pattern, file_name)) return true;
    return matchesSelectorPattern(pattern, fileStem(file_name));
}

fn pathBasename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfAny(u8, path, "/\\")) |slash| return path[slash + 1 ..];
    return path;
}

fn fileStem(file_name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, file_name, '.')) |dot| return file_name[0..dot];
    return file_name;
}

fn wildcardMatchesPathParent(pattern: []const u8, path: []const u8) bool {
    var index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, index, '/')) |slash| {
        if (wildcardMatchesPath(pattern, path[0..slash])) return true;
        index = slash + 1;
    }
    return false;
}

fn matchesSelectorPattern(pattern: []const u8, value: []const u8) bool {
    if (selectorPatternHasWildcard(pattern)) return wildcardMatches(pattern, value);
    return std.mem.eql(u8, pattern, value);
}

fn matchesUniqueIdFqnPattern(pattern: []const u8, unique_id: []const u8) bool {
    const prefix_end = std.mem.indexOfScalar(u8, unique_id, '.') orelse return false;
    return matchesSelectorPattern(pattern, unique_id[prefix_end + 1 ..]);
}

fn matchesNodeFqnPattern(pattern: []const u8, node: *const Node) bool {
    return matchesPathBackedFqnPattern(pattern, node.package_name, node.path);
}

fn matchesGenericTestFqnPattern(pattern: []const u8, test_node: *const GenericTestNode) bool {
    return matchesPathBackedFqnPattern(pattern, test_node.package_name, test_node.path);
}

fn matchesSingularTestFqnPattern(pattern: []const u8, test_node: *const SingularTestNode) bool {
    return matchesPathBackedFqnPattern(pattern, test_node.package_name, test_node.path);
}

fn matchesUnitTestFqnPattern(pattern: []const u8, unit_test: *const UnitTestDef) bool {
    var buffer: [4096]u8 = undefined;
    var len: usize = 0;
    if (!appendFqnSlice(&buffer, &len, unit_test.package_name)) return false;
    if (!appendFqnByte(&buffer, &len, '.')) return false;
    const model_start = len;
    if (!appendFqnSlice(&buffer, &len, unit_test.model)) return false;
    if (!appendFqnByte(&buffer, &len, '.')) return false;
    if (!appendFqnSlice(&buffer, &len, unit_test.name)) return false;
    const scoped = buffer[0..len];
    const model_scoped = buffer[model_start..len];
    return matchesFqnCandidate(pattern, scoped) or matchesFqnCandidate(pattern, model_scoped);
}

fn matchesPathBackedFqnPattern(pattern: []const u8, package_name: []const u8, path: []const u8) bool {
    var buffer: [4096]u8 = undefined;
    var len: usize = 0;
    if (!appendFqnSlice(&buffer, &len, package_name)) return false;
    if (!appendFqnByte(&buffer, &len, '.')) return false;
    const unscoped_start = len;
    if (!appendFqnPath(&buffer, &len, path)) return false;
    const scoped = buffer[0..len];
    const unscoped = buffer[unscoped_start..len];
    return matchesFqnCandidate(pattern, scoped) or matchesFqnCandidate(pattern, unscoped);
}

fn matchesFqnCandidate(pattern: []const u8, candidate: []const u8) bool {
    if (selectorPatternHasWildcard(pattern)) return wildcardMatches(pattern, candidate);
    if (std.mem.eql(u8, pattern, candidate)) return true;
    return candidate.len > pattern.len and std.mem.startsWith(u8, candidate, pattern) and candidate[pattern.len] == '.';
}

fn appendFqnPath(buffer: []u8, len: *usize, path: []const u8) bool {
    const end = if (std.mem.endsWith(u8, path, ".sql") or std.mem.endsWith(u8, path, ".csv"))
        path.len - 4
    else
        path.len;
    for (path[0..end]) |byte| {
        if (!appendFqnByte(buffer, len, if (byte == '/' or byte == '\\') '.' else byte)) return false;
    }
    return true;
}

fn appendFqnSlice(buffer: []u8, len: *usize, value: []const u8) bool {
    for (value) |byte| {
        if (!appendFqnByte(buffer, len, byte)) return false;
    }
    return true;
}

fn appendFqnByte(buffer: []u8, len: *usize, byte: u8) bool {
    if (len.* >= buffer.len) return false;
    buffer[len.*] = byte;
    len.* += 1;
    return true;
}

fn selectorPatternHasWildcard(pattern: []const u8) bool {
    return std.mem.indexOfAny(u8, pattern, "*?[") != null;
}

fn wildcardMatches(pattern: []const u8, value: []const u8) bool {
    return wildcardMatchesWithSlashMode(pattern, value, true);
}

fn wildcardMatchesPath(pattern: []const u8, value: []const u8) bool {
    return wildcardMatchesWithSlashMode(pattern, value, false);
}

fn wildcardMatchesWithSlashMode(pattern: []const u8, value: []const u8, star_matches_slash: bool) bool {
    var pattern_index: usize = 0;
    var value_index: usize = 0;
    var star_index: ?usize = null;
    var star_value_index: usize = 0;

    while (value_index < value.len) {
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            pattern_index += 1;
            star_value_index = value_index;
            continue;
        }
        if (pattern_index < pattern.len) {
            if (matchWildcardToken(pattern, pattern_index, value[value_index], star_matches_slash)) |next_pattern_index| {
                pattern_index = next_pattern_index;
                value_index += 1;
                continue;
            }
        }
        if (star_index) |index| {
            if (!star_matches_slash and value[star_value_index] == '/') return false;
            pattern_index = index + 1;
            star_value_index += 1;
            value_index = star_value_index;
        } else {
            return false;
        }
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
        pattern_index += 1;
    }
    return pattern_index == pattern.len;
}

fn matchWildcardToken(pattern: []const u8, pattern_index: usize, value: u8, star_matches_slash: bool) ?usize {
    const token = pattern[pattern_index];
    if (token == '?') {
        if (!star_matches_slash and value == '/') return null;
        return pattern_index + 1;
    }
    if (token == '[') {
        if (matchesCharacterClass(pattern, pattern_index, value)) |class| {
            if (!star_matches_slash and value == '/') return null;
            return if (class.matches) class.end + 1 else null;
        }
    }
    return if (token == value) pattern_index + 1 else null;
}

const CharacterClassMatch = struct {
    end: usize,
    matches: bool,
};

fn matchesCharacterClass(pattern: []const u8, start: usize, value: u8) ?CharacterClassMatch {
    var index = start + 1;
    if (index >= pattern.len) return null;
    const negated = pattern[index] == '!';
    if (negated) index += 1;
    if (index >= pattern.len) return null;
    const class_start = index;
    var close = index;
    while (close < pattern.len and pattern[close] != ']') close += 1;
    if (close >= pattern.len or close == class_start) return null;

    var matched = false;
    index = class_start;
    while (index < close) {
        if (index + 2 < close and pattern[index + 1] == '-') {
            const first = pattern[index];
            const last = pattern[index + 2];
            if (first <= last and value >= first and value <= last) matched = true;
            index += 3;
        } else {
            if (value == pattern[index]) matched = true;
            index += 1;
        }
    }
    return .{
        .end = close,
        .matches = if (negated) !matched else matched,
    };
}

fn matchesUniqueIdPackage(graph: *const Graph, unique_id: []const u8, package_name: []const u8) bool {
    const expected_package = if (std.mem.eql(u8, package_name, "this")) graph.project_name else package_name;
    const prefix_end = std.mem.indexOfScalar(u8, unique_id, '.') orelse return false;
    const package_start = prefix_end + 1;
    const package_end = std.mem.indexOfPos(u8, unique_id, package_start, ".") orelse return false;
    return std.mem.eql(u8, expected_package, unique_id[package_start..package_end]);
}

fn parseSelectorSpec(selector: ?[]const u8) SelectorSpec {
    const raw = selector orelse return .{};
    return .{
        .active = true,
        .value = raw,
    };
}

fn parseSelectorTerm(raw: []const u8) SelectorSpec {
    const trimmed = std.mem.trim(u8, raw, " \t\r");
    var start: usize = 0;
    var end: usize = trimmed.len;
    var include_childrens_parents = false;
    var include_parents = false;
    var include_children = false;
    var parents_depth: ?usize = null;
    var children_depth: ?usize = null;

    if (start < end and trimmed[start] == '@') {
        include_childrens_parents = true;
        start += 1;
    }

    if (start < end) {
        if (trimmed[start] == '+') {
            include_parents = true;
            start += 1;
        } else {
            var digit_end = start;
            while (digit_end < end and isSelectorDigit(trimmed[digit_end])) digit_end += 1;
            if (digit_end > start and digit_end < end and trimmed[digit_end] == '+') {
                include_parents = true;
                parents_depth = parseSelectorDepth(trimmed[start..digit_end]) catch return .{ .active = true, .valid = false };
                start = digit_end + 1;
            }
        }
    }

    if (start < end) {
        if (trimmed[end - 1] == '+') {
            include_children = true;
            end -= 1;
        } else {
            var digit_start = end;
            while (digit_start > start and isSelectorDigit(trimmed[digit_start - 1])) digit_start -= 1;
            if (digit_start < end and digit_start > start and trimmed[digit_start - 1] == '+') {
                include_children = true;
                children_depth = parseSelectorDepth(trimmed[digit_start..end]) catch return .{ .active = true, .valid = false };
                end = digit_start - 1;
            }
        }
    }

    if (include_childrens_parents and (include_parents or include_children)) return .{ .active = true, .valid = false };

    return .{
        .active = true,
        .value = if (start <= end) trimmed[start..end] else "",
        .include_childrens_parents = include_childrens_parents,
        .include_parents = include_parents,
        .include_children = include_children,
        .parents_depth = parents_depth,
        .children_depth = children_depth,
    };
}

fn parseSelectorDepth(value: []const u8) !?usize {
    if (value.len == 0) return null;
    return try std.fmt.parseInt(usize, value, 10);
}

fn isSelectorDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn matchesGraphExpansion(graph: *const Graph, candidate_unique_id: []const u8, spec: SelectorSpec) bool {
    if (!spec.include_childrens_parents and !spec.include_parents and !spec.include_children) return false;
    for (graph.nodes.items) |*target| {
        if (!target.enabled or !matchesNodeSelectorTerm(graph, target, spec.value)) continue;
        if (spec.include_childrens_parents and resourceInChildrensParentsSelection(graph, target.unique_id, candidate_unique_id)) return true;
        if (spec.include_parents and resourceDependsOnDepth(graph, target.unique_id, candidate_unique_id, spec.parents_depth)) return true;
        if (spec.include_children and resourceDependsOnDepth(graph, candidate_unique_id, target.unique_id, spec.children_depth)) return true;
    }
    for (graph.tests.items) |*target| {
        if (!matchesTestSelectorTerm(graph, target, spec.value)) continue;
        if (spec.include_childrens_parents and resourceInChildrensParentsSelection(graph, target.unique_id, candidate_unique_id)) return true;
        if (spec.include_parents and resourceDependsOnDepth(graph, target.unique_id, candidate_unique_id, spec.parents_depth)) return true;
        if (spec.include_children and resourceDependsOnDepth(graph, candidate_unique_id, target.unique_id, spec.children_depth)) return true;
    }
    for (graph.singular_tests.items) |*target| {
        if (!target.enabled) continue;
        if (!matchesSingularTestSelectorTerm(graph, target, spec.value)) continue;
        if (spec.include_childrens_parents and resourceInChildrensParentsSelection(graph, target.unique_id, candidate_unique_id)) return true;
        if (spec.include_parents and resourceDependsOnDepth(graph, target.unique_id, candidate_unique_id, spec.parents_depth)) return true;
        if (spec.include_children and resourceDependsOnDepth(graph, candidate_unique_id, target.unique_id, spec.children_depth)) return true;
    }
    for (graph.sources.items) |*target| {
        if (!matchesSourceSelectorTerm(graph, target, spec.value)) continue;
        if (spec.include_childrens_parents and resourceInChildrensParentsSelection(graph, target.unique_id, candidate_unique_id)) return true;
        if (spec.include_children and resourceDependsOnDepth(graph, candidate_unique_id, target.unique_id, spec.children_depth)) return true;
    }
    for (graph.exposures.items) |*target| {
        if (!target.enabled) continue;
        if (!matchesExposureSelectorTerm(graph, target, spec.value)) continue;
        if (spec.include_childrens_parents and resourceInChildrensParentsSelection(graph, target.unique_id, candidate_unique_id)) return true;
        if (spec.include_parents and resourceDependsOnDepth(graph, target.unique_id, candidate_unique_id, spec.parents_depth)) return true;
        if (spec.include_children and resourceDependsOnDepth(graph, candidate_unique_id, target.unique_id, spec.children_depth)) return true;
    }
    for (graph.unit_tests.items) |*target| {
        if (!target.enabled) continue;
        if (!matchesUnitTestSelectorTerm(graph, target, spec.value)) continue;
        if (spec.include_childrens_parents and resourceInChildrensParentsSelection(graph, target.unique_id, candidate_unique_id)) return true;
        if (spec.include_parents and resourceDependsOnDepth(graph, target.unique_id, candidate_unique_id, spec.parents_depth)) return true;
        if (spec.include_children and resourceDependsOnDepth(graph, candidate_unique_id, target.unique_id, spec.children_depth)) return true;
    }
    return false;
}

fn resourceInChildrensParentsSelection(graph: *const Graph, selected_unique_id: []const u8, candidate_unique_id: []const u8) bool {
    if (std.mem.eql(u8, selected_unique_id, candidate_unique_id)) return true;
    if (resourceDependsOn(graph, candidate_unique_id, selected_unique_id)) return true;
    if (resourceDependsOn(graph, selected_unique_id, candidate_unique_id)) return true;

    for (graph.nodes.items) |*resource| {
        if (!resource.enabled) continue;
        if (resourceDependsOn(graph, resource.unique_id, selected_unique_id) and resourceDependsOn(graph, resource.unique_id, candidate_unique_id)) return true;
    }
    for (graph.tests.items) |*resource| {
        if (resourceDependsOn(graph, resource.unique_id, selected_unique_id) and resourceDependsOn(graph, resource.unique_id, candidate_unique_id)) return true;
    }
    for (graph.singular_tests.items) |*resource| {
        if (!resource.enabled) continue;
        if (resourceDependsOn(graph, resource.unique_id, selected_unique_id) and resourceDependsOn(graph, resource.unique_id, candidate_unique_id)) return true;
    }
    for (graph.exposures.items) |*resource| {
        if (!resource.enabled) continue;
        if (resourceDependsOn(graph, resource.unique_id, selected_unique_id) and resourceDependsOn(graph, resource.unique_id, candidate_unique_id)) return true;
    }
    for (graph.unit_tests.items) |*resource| {
        if (!resource.enabled) continue;
        if (resourceDependsOn(graph, resource.unique_id, selected_unique_id) and resourceDependsOn(graph, resource.unique_id, candidate_unique_id)) return true;
    }
    return false;
}

fn resourceDependsOn(graph: *const Graph, resource_unique_id: []const u8, dependency_unique_id: []const u8) bool {
    return resourceDependsOnDepth(graph, resource_unique_id, dependency_unique_id, null);
}

fn resourceDependsOnDepth(graph: *const Graph, resource_unique_id: []const u8, dependency_unique_id: []const u8, max_depth: ?usize) bool {
    const depth = max_depth orelse graphDepthLimit(graph);
    return resourceDependsOnWithin(graph, resource_unique_id, dependency_unique_id, depth);
}

fn graphDepthLimit(graph: *const Graph) usize {
    return graph.nodes.items.len + graph.tests.items.len + graph.singular_tests.items.len + graph.sources.items.len + graph.exposures.items.len + graph.unit_tests.items.len + 1;
}

fn resourceDependsOnWithin(graph: *const Graph, resource_unique_id: []const u8, dependency_unique_id: []const u8, remaining_depth: usize) bool {
    if (std.mem.eql(u8, resource_unique_id, dependency_unique_id)) return true;
    if (remaining_depth == 0) return false;
    for (graph.nodes.items) |node| {
        if (!node.enabled or !std.mem.eql(u8, node.unique_id, resource_unique_id)) continue;
        return dependencyListContainsTransitive(graph, node.depends_on.items, dependency_unique_id, remaining_depth - 1);
    }
    for (graph.tests.items) |test_node| {
        if (!std.mem.eql(u8, test_node.unique_id, resource_unique_id)) continue;
        return dependencyListContainsTransitive(graph, test_node.depends_on.items, dependency_unique_id, remaining_depth - 1);
    }
    for (graph.singular_tests.items) |test_node| {
        if (!test_node.enabled or !std.mem.eql(u8, test_node.unique_id, resource_unique_id)) continue;
        return dependencyListContainsTransitive(graph, test_node.depends_on.items, dependency_unique_id, remaining_depth - 1);
    }
    for (graph.exposures.items) |exposure| {
        if (!exposure.enabled) continue;
        if (!std.mem.eql(u8, exposure.unique_id, resource_unique_id)) continue;
        return dependencyListContainsTransitive(graph, exposure.depends_on.items, dependency_unique_id, remaining_depth - 1);
    }
    for (graph.unit_tests.items) |unit_test| {
        if (!unit_test.enabled) continue;
        if (!std.mem.eql(u8, unit_test.unique_id, resource_unique_id)) continue;
        return dependencyListContainsTransitive(graph, unit_test.depends_on.items, dependency_unique_id, remaining_depth - 1);
    }
    return false;
}

fn dependencyListContainsTransitive(graph: *const Graph, dependencies: []const []const u8, dependency_unique_id: []const u8, remaining_depth: usize) bool {
    for (dependencies) |direct| {
        if (std.mem.eql(u8, direct, dependency_unique_id)) return true;
        if (resourceDependsOnWithin(graph, direct, dependency_unique_id, remaining_depth)) return true;
    }
    return false;
}

test "selector wildcard patterns match full resource values" {
    const node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "marts/orders.sql",
        .original_file_path = "models/marts/orders.sql",
        .raw_code = "",
    };
    try std.testing.expect(matchesSelectorPattern("stg_*", "stg_customers"));
    try std.testing.expect(matchesSelectorPattern("*customers", "stg_customers"));
    try std.testing.expect(matchesNodeFqnPattern("demo.marts.*", &node));
    try std.testing.expect(matchesNodeFqnPattern("marts.*", &node));
    try std.testing.expect(matchesNodeFqnPattern("demo.marts", &node));
    try std.testing.expect(!matchesNodeFqnPattern("model.demo.marts.*", &node));
    try std.testing.expect(!matchesSelectorPattern("stg_*", "customers"));
    try std.testing.expect(!matchesSelectorPattern("customers", "stg_customers"));
}

test "selector wildcard patterns support fnmatch character classes" {
    try std.testing.expect(matchesSelectorPattern("ord[ea]rs", "orders"));
    try std.testing.expect(matchesSelectorPattern("ord[a-z]rs", "orders"));
    try std.testing.expect(!matchesSelectorPattern("ord[z-a]rs", "orders"));
    try std.testing.expect(matchesSelectorPattern("ord[!a]rs", "orders"));
    try std.testing.expect(!matchesSelectorPattern("ord[!e]rs", "orders"));
    try std.testing.expect(matchesSelectorPattern("ord[!z-a]rs", "orders"));
    try std.testing.expect(matchesSelectorPattern("ord[[]rs", "ord[rs"));
    try std.testing.expect(matchesSelectorPattern("ord[rs", "ord[rs"));
    try std.testing.expect(!matchesSelectorPattern("*a*a*a*a*a*a*a*a*a*a*b", "aaaaaaaaaa"));
    try std.testing.expect(matchesPathSelector("models/[os]*.sql", "models/orders.sql"));
    try std.testing.expect(!matchesPathSelector("models/[os]*.sql", "models/marts/orders.sql"));
}

test "path selectors keep substring behavior unless wildcarded" {
    try std.testing.expect(matchesPathSelector("models", "models/stg_customers.sql"));
    try std.testing.expect(matchesPathSelector("models/*", "models/marts/orders.sql"));
    try std.testing.expect(matchesPathSelector("models/stg_*", "models/stg_customers.sql"));
    try std.testing.expect(matchesPathSelector("models/marts/*orders.sql", "models/marts/orders.sql"));
    try std.testing.expect(matchesPathSelector("models/stg?customers.sql", "models/stg_customers.sql"));
    try std.testing.expect(!matchesPathSelector("*orders.sql", "models/orders.sql"));
    try std.testing.expect(!matchesPathSelector("models/stg_*", "models/marts/stg_customers.sql"));
    try std.testing.expect(!matchesPathSelector("models?stg_customers.sql", "models/stg_customers.sql"));
}

test "file selectors match only basename or stem" {
    try std.testing.expect(matchesFileSelector("orders.sql", "models/marts/orders.sql"));
    try std.testing.expect(matchesFileSelector("orders", "models/marts/orders.sql"));
    try std.testing.expect(matchesFileSelector("*orders.sql", "models/marts/orders.sql"));
    try std.testing.expect(matchesFileSelector("*orders", "models/marts/orders.sql"));
    try std.testing.expect(matchesFileSelector("ord[ea]rs.sql", "models/marts/orders.sql"));
    try std.testing.expect(matchesFileSelector("ord[a-z]rs", "models/marts/orders.sql"));
    try std.testing.expect(!matchesFileSelector("ord[!e]rs.sql", "models/marts/orders.sql"));
    try std.testing.expect(matchesFileSelector("schema.yml", "models/schema.yml"));
    try std.testing.expect(matchesFileSelector("schema", "models/schema.yml"));
    try std.testing.expect(!matchesFileSelector("models/marts/orders.sql", "models/marts/orders.sql"));
    try std.testing.expect(!matchesFileSelector("marts/orders.sql", "models/marts/orders.sql"));
    try std.testing.expect(!matchesFileSelector("customers.sql", "models/marts/orders.sql"));
}

test "singular test selectors match type path file and graph expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "",
    });
    try graph.singular_tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.assert_customers",
        .name = "assert_customers",
        .alias = "assert_customers",
        .path = "assert_customers.sql",
        .original_file_path = "tests/assert_customers.sql",
        .raw_code = "select * from {{ ref('customers') }} where customer_id is null",
    });
    try graph.singular_tests.items[0].depends_on.append(allocator, "model.demo.customers");
    try graph.singular_tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.disabled_assert_customers",
        .name = "disabled_assert_customers",
        .alias = "disabled_assert_customers",
        .path = "disabled_assert_customers.sql",
        .original_file_path = "tests/disabled_assert_customers.sql",
        .raw_code = "{{ config(enabled=false) }} select 1",
        .enabled = false,
    });
    try graph.singular_tests.items[1].depends_on.append(allocator, "model.demo.customers");

    const by_singular_type = try selectResources(allocator, &graph, "test", "test_type:singular", null);
    try std.testing.expectEqual(@as(usize, 1), by_singular_type.len);
    try std.testing.expectEqualStrings("test.demo.assert_customers", by_singular_type[0].unique_id);

    const by_data_type = try selectResources(allocator, &graph, "test", "test_type:data", null);
    try std.testing.expectEqual(@as(usize, 1), by_data_type.len);

    const by_file = try selectResources(allocator, &graph, "test", "file:assert_customers", null);
    try std.testing.expectEqual(@as(usize, 1), by_file.len);

    const by_path = try selectResources(allocator, &graph, "test", "path:tests", null);
    try std.testing.expectEqual(@as(usize, 1), by_path.len);

    const by_child_expansion = try selectResources(allocator, &graph, "test", "customers+", null);
    try std.testing.expectEqual(@as(usize, 1), by_child_expansion.len);

    const by_dependency_name = try selectResources(allocator, &graph, "test", "customers", null);
    try std.testing.expectEqual(@as(usize, 1), by_dependency_name.len);
}

test "unit test selectors match resource type name package and graph expansion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "marts/orders.sql",
        .original_file_path = "models/marts/orders.sql",
        .raw_code = "",
    });
    try graph.unit_tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "unit_test.demo.orders.assert_order_flags",
        .name = "assert_order_flags",
        .model = "orders",
        .path = "marts/orders.yml",
        .original_file_path = "models/marts/orders.yml",
    });
    try graph.unit_tests.items[0].depends_on.append(allocator, "model.demo.orders");

    const by_resource_type = try selectResources(allocator, &graph, "unit_test", null, null);
    try std.testing.expectEqual(@as(usize, 1), by_resource_type.len);
    try std.testing.expectEqualStrings("unit_test.demo.orders.assert_order_flags", by_resource_type[0].unique_id);
    try std.testing.expectEqualStrings("unit_test:demo.assert_order_flags", by_resource_type[0].selector);

    const by_selector = try selectResources(allocator, &graph, null, "resource_type:unit_test", null);
    try std.testing.expectEqual(@as(usize, 1), by_selector.len);

    const by_unit_selector = try selectResources(allocator, &graph, null, "unit_test:demo.orders.assert_order_flags", null);
    try std.testing.expectEqual(@as(usize, 1), by_unit_selector.len);

    const by_test_type = try selectResources(allocator, &graph, null, "test_type:unit", null);
    try std.testing.expectEqual(@as(usize, 1), by_test_type.len);

    const by_child_expansion = try selectResources(allocator, &graph, "unit_test", "orders+", null);
    try std.testing.expectEqual(@as(usize, 1), by_child_expansion.len);
}

test "selector terms parse dbt plus depth operators" {
    const parent_limited = parseSelectorTerm("1+orders");
    try std.testing.expect(parent_limited.valid);
    try std.testing.expect(!parent_limited.include_childrens_parents);
    try std.testing.expect(parent_limited.include_parents);
    try std.testing.expect(!parent_limited.include_children);
    try std.testing.expectEqual(@as(?usize, 1), parent_limited.parents_depth);
    try std.testing.expectEqual(@as(?usize, null), parent_limited.children_depth);
    try std.testing.expectEqualStrings("orders", parent_limited.value);

    const child_limited = parseSelectorTerm("orders+2");
    try std.testing.expect(child_limited.valid);
    try std.testing.expect(!child_limited.include_parents);
    try std.testing.expect(child_limited.include_children);
    try std.testing.expectEqual(@as(?usize, null), child_limited.parents_depth);
    try std.testing.expectEqual(@as(?usize, 2), child_limited.children_depth);
    try std.testing.expectEqualStrings("orders", child_limited.value);

    const both_limited = parseSelectorTerm("1+orders+2");
    try std.testing.expect(both_limited.valid);
    try std.testing.expect(both_limited.include_parents);
    try std.testing.expect(both_limited.include_children);
    try std.testing.expectEqual(@as(?usize, 1), both_limited.parents_depth);
    try std.testing.expectEqual(@as(?usize, 2), both_limited.children_depth);
    try std.testing.expectEqualStrings("orders", both_limited.value);

    const unlimited = parseSelectorTerm("+orders+");
    try std.testing.expect(unlimited.valid);
    try std.testing.expect(unlimited.include_parents);
    try std.testing.expect(unlimited.include_children);
    try std.testing.expectEqual(@as(?usize, null), unlimited.parents_depth);
    try std.testing.expectEqual(@as(?usize, null), unlimited.children_depth);
    try std.testing.expectEqualStrings("orders", unlimited.value);

    const childrens_parents = parseSelectorTerm("@orders");
    try std.testing.expect(childrens_parents.valid);
    try std.testing.expect(childrens_parents.include_childrens_parents);
    try std.testing.expect(!childrens_parents.include_parents);
    try std.testing.expect(!childrens_parents.include_children);
    try std.testing.expectEqualStrings("orders", childrens_parents.value);

    try std.testing.expect(!parseSelectorTerm("@orders+").valid);
    try std.testing.expect(!parseSelectorTerm("@orders+1").valid);
    try std.testing.expect(!parseSelectorTerm("@+orders").valid);
    try std.testing.expect(!parseSelectorTerm("@1+orders").valid);

    const invalid_depth = parseSelectorTerm("999999999999999999999999999999+orders");
    try std.testing.expect(!invalid_depth.valid);
}
