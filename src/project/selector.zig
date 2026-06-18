const std = @import("std");
const types = @import("types.zig");

const Graph = types.Graph;
const Node = types.Node;
const GenericTestNode = types.GenericTestNode;
const SourceDef = types.SourceDef;
const ExposureDef = types.ExposureDef;

pub const SelectedResource = struct {
    unique_id: []const u8,
    name: []const u8,
    resource_type: []const u8,
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
            try selected.append(allocator, .{ .unique_id = node.unique_id, .name = node.name, .resource_type = node.resource_type });
        }
    }
    for (graph.tests.items) |*test_node| {
        if (matchesResourceType(resource_type, "test") and matchesTestSelector(graph, test_node, select_spec) and (!exclude_spec.active or !matchesTestSelector(graph, test_node, exclude_spec))) {
            try selected.append(allocator, .{ .unique_id = test_node.unique_id, .name = test_node.name, .resource_type = "test" });
        }
    }
    for (graph.sources.items) |*source| {
        if (matchesResourceType(resource_type, "source") and matchesSourceSelector(graph, source, select_spec) and (!exclude_spec.active or !matchesSourceSelector(graph, source, exclude_spec))) {
            try selected.append(allocator, .{ .unique_id = source.unique_id, .name = source.table_name, .resource_type = "source" });
        }
    }
    for (graph.exposures.items) |*exposure| {
        if (!exposure.enabled) continue;
        if (matchesResourceType(resource_type, "exposure") and matchesExposureSelector(graph, exposure, select_spec) and (!exclude_spec.active or !matchesExposureSelector(graph, exposure, exclude_spec))) {
            try selected.append(allocator, .{ .unique_id = exposure.unique_id, .name = exposure.name, .resource_type = "exposure" });
        }
    }
    std.mem.sort(SelectedResource, selected.items, {}, struct {
        fn lessThan(_: void, a: SelectedResource, b: SelectedResource) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
        }
    }.lessThan);
    return try selected.toOwnedSlice(allocator);
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
        return std.mem.eql(u8, node.resource_type, "model") and std.mem.eql(u8, materialized, node.materialized);
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
        return std.mem.eql(u8, test_type, "generic");
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
    return std.mem.indexOfAny(u8, pattern, "*?") != null;
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
        if (pattern_index < pattern.len and pattern[pattern_index] == '?') {
            if (!star_matches_slash and value[value_index] == '/') return false;
            pattern_index += 1;
            value_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == value[value_index]) {
            pattern_index += 1;
            value_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            pattern_index += 1;
            star_value_index = value_index;
        } else if (star_index) |index| {
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
    for (graph.exposures.items) |*resource| {
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
    return graph.nodes.items.len + graph.tests.items.len + graph.sources.items.len + graph.exposures.items.len + 1;
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
    for (graph.exposures.items) |exposure| {
        if (!exposure.enabled) continue;
        if (!std.mem.eql(u8, exposure.unique_id, resource_unique_id)) continue;
        return dependencyListContainsTransitive(graph, exposure.depends_on.items, dependency_unique_id, remaining_depth - 1);
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
    try std.testing.expect(matchesFileSelector("schema.yml", "models/schema.yml"));
    try std.testing.expect(matchesFileSelector("schema", "models/schema.yml"));
    try std.testing.expect(!matchesFileSelector("models/marts/orders.sql", "models/marts/orders.sql"));
    try std.testing.expect(!matchesFileSelector("marts/orders.sql", "models/marts/orders.sql"));
    try std.testing.expect(!matchesFileSelector("customers.sql", "models/marts/orders.sql"));
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
