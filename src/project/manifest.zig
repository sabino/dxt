const std = @import("std");
const Io = std.Io;
const compiler = @import("compiler.zig");
const json = @import("json.zig");
const selector = @import("selector.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const audits = @import("test_audits.zig");

const Graph = types.Graph;
const Node = types.Node;
const GenericTestNode = types.GenericTestNode;
const SingularTestNode = types.SingularTestNode;
const SourceDef = types.SourceDef;
const ExposureDef = types.ExposureDef;
const UnitTestDef = types.UnitTestDef;
const MacroDef = types.MacroDef;
const MacroArgument = types.MacroArgument;
const DocBlock = types.DocBlock;
const DocsConfig = types.DocsConfig;
const MetaEntry = types.MetaEntry;
const JsonScalar = types.JsonScalar;
const RefDep = types.RefDep;
const SourceDep = types.SourceDep;

const manifest_schema_version = "https://schemas.getdbt.com/dbt/manifest/v12.json";
const deterministic_dbt_version = "0.0.0";
const deterministic_generated_at = "1970-01-01T00:00:00Z";

pub fn writeSelectedJson(writer: *Io.Writer, selected: []selector.SelectedResource) !void {
    try writeSelectedJsonWithKeys(writer, selected, null);
}

pub fn writeSelectedJsonWithKeys(writer: *Io.Writer, selected: []selector.SelectedResource, output_keys: ?[]const []const u8) !void {
    try writer.writeAll("[");
    for (selected, 0..) |item, index| {
        if (index != 0) try writer.writeAll(",");
        if (output_keys) |keys| {
            try writeSelectedJsonObjectWithKeys(writer, item, keys);
        } else {
            try writeSelectedJsonObject(writer, item);
        }
    }
    try writer.writeAll("]\n");
}

/// Core's list JSON output is one object per line. Reading from the same
/// manifest node preserves typed config/dependency fields and permits every
/// authored top-level --output-keys field that Core exposes.
pub fn writeSelectedJsonLines(allocator: std.mem.Allocator, writer: *Io.Writer, graph: *const Graph, selected: []selector.SelectedResource, output_keys: ?[]const []const u8) !void {
    const rendered = try renderManifest(allocator, graph);
    defer allocator.free(rendered);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();
    const defaults = [_][]const u8{ "alias", "name", "package_name", "depends_on", "tags", "config", "resource_type", "source_name", "original_file_path", "unique_id" };
    const keys = output_keys orelse &defaults;
    for (selected) |item| {
        const collection = if (std.mem.eql(u8, item.resource_type, "source")) "sources" else if (std.mem.eql(u8, item.resource_type, "exposure")) "exposures" else if (std.mem.eql(u8, item.resource_type, "metric")) "metrics" else if (std.mem.eql(u8, item.resource_type, "semantic_model")) "semantic_models" else if (std.mem.eql(u8, item.resource_type, "saved_query")) "saved_queries" else if (std.mem.eql(u8, item.resource_type, "unit_test")) "unit_tests" else "nodes";
        const resources = parsed.value.object.get(collection) orelse return error.InvalidListResource;
        const node = resources.object.get(item.unique_id) orelse return error.InvalidListResource;
        var object: std.json.ObjectMap = .empty;
        defer object.deinit(allocator);
        for (keys) |key| if (node.object.get(key)) |value| try object.put(allocator, key, value);
        try std.json.Stringify.value(std.json.Value{ .object = object }, .{}, writer);
        try writer.writeByte('\n');
    }
}

fn writeSelectedJsonObject(writer: *Io.Writer, item: selector.SelectedResource) !void {
    try writer.writeAll("{\"unique_id\":");
    try json.string(writer, item.unique_id);
    try writer.writeAll(",\"resource_type\":");
    try json.string(writer, item.resource_type);
    try writer.writeAll(",\"name\":");
    try json.string(writer, item.name);
    try writer.writeAll("}");
}

fn writeSelectedJsonObjectWithKeys(writer: *Io.Writer, item: selector.SelectedResource, keys: []const []const u8) !void {
    try writer.writeAll("{");
    var wrote = false;
    for (keys, 0..) |key, index| {
        if (hasPriorKey(keys[0..index], key)) continue;
        if (std.mem.eql(u8, key, "unique_id")) {
            try writeSelectedJsonStringField(writer, "unique_id", item.unique_id, &wrote);
        } else if (std.mem.eql(u8, key, "resource_type")) {
            try writeSelectedJsonStringField(writer, "resource_type", item.resource_type, &wrote);
        } else if (std.mem.eql(u8, key, "name")) {
            try writeSelectedJsonStringField(writer, "name", item.name, &wrote);
        } else if (std.mem.eql(u8, key, "package_name")) {
            try writeSelectedJsonStringField(writer, "package_name", item.package_name, &wrote);
        } else if (std.mem.eql(u8, key, "source_name")) {
            if (item.source_name.len != 0) try writeSelectedJsonStringField(writer, "source_name", item.source_name, &wrote);
        } else if (std.mem.eql(u8, key, "path")) {
            try writeSelectedJsonStringField(writer, "path", util.normalizeForDisplay(item.path), &wrote);
        } else if (std.mem.eql(u8, key, "original_file_path")) {
            try writeSelectedJsonStringField(writer, "original_file_path", util.normalizeForDisplay(item.original_file_path), &wrote);
        } else if (std.mem.eql(u8, key, "selector")) {
            try writeSelectedJsonStringField(writer, "selector", item.selector, &wrote);
        } else if (std.mem.eql(u8, key, "alias")) {
            if (item.alias.len != 0) try writeSelectedJsonStringField(writer, "alias", item.alias, &wrote);
        } else if (std.mem.eql(u8, key, "identifier")) {
            if (item.identifier.len != 0) try writeSelectedJsonStringField(writer, "identifier", item.identifier, &wrote);
        } else if (std.mem.eql(u8, key, "tags")) {
            if (item.has_config_tags) try writeSelectedJsonStringArrayField(writer, "tags", item.config_tags, &wrote);
        } else if (std.mem.eql(u8, key, "config.materialized")) {
            if (item.config_materialized.len != 0) try writeSelectedJsonStringField(writer, "config.materialized", item.config_materialized, &wrote);
        } else if (std.mem.eql(u8, key, "config.tags")) {
            if (item.has_config_tags) try writeSelectedJsonStringArrayField(writer, "config.tags", item.config_tags, &wrote);
        } else if (std.mem.eql(u8, key, "config.enabled")) {
            if (item.has_config_enabled) try writeSelectedJsonBoolField(writer, "config.enabled", item.config_enabled, &wrote);
        } else if (std.mem.eql(u8, key, "config.docs.show")) {
            if (item.has_config_docs_show) try writeSelectedJsonBoolField(writer, "config.docs.show", item.config_docs_show, &wrote);
        } else if (std.mem.eql(u8, key, "depends_on.nodes")) {
            if (item.has_depends_on) try writeSelectedJsonStringArrayField(writer, "depends_on.nodes", item.depends_on_nodes, &wrote);
        } else if (std.mem.eql(u8, key, "depends_on.macros")) {
            if (item.has_depends_on) try writeSelectedJsonStringArrayField(writer, "depends_on.macros", item.depends_on_macros, &wrote);
        }
    }
    try writer.writeAll("}");
}

fn writeSelectedJsonStringField(writer: *Io.Writer, key: []const u8, value: []const u8, wrote: *bool) !void {
    try json.stringField(writer, key, value, wrote);
}

fn writeSelectedJsonStringArrayField(writer: *Io.Writer, key: []const u8, value: []const []const u8, wrote: *bool) !void {
    try json.stringArrayField(writer, key, value, wrote);
}

fn writeSelectedJsonBoolField(writer: *Io.Writer, key: []const u8, value: bool, wrote: *bool) !void {
    if (wrote.*) try writer.writeAll(",");
    wrote.* = true;
    try json.string(writer, key);
    try writer.writeAll(":");
    try json.boolValue(writer, value);
}

fn hasPriorKey(keys: []const []const u8, key: []const u8) bool {
    for (keys) |prior| {
        if (std.mem.eql(u8, prior, key)) return true;
    }
    return false;
}

pub fn renderManifest(allocator: std.mem.Allocator, graph: *const Graph) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\n  \"metadata\": ");
    try writeManifestMetadata(writer, graph);
    try writer.writeAll(",\n  \"nodes\": {");
    var node_index: usize = 0;
    for (graph.nodes.items) |node| {
        if (!node.enabled) continue;
        if (node_index != 0) try writer.writeAll(",");
        node_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, node.unique_id);
        try writer.writeAll(": ");
        try writeNode(allocator, writer, graph, node);
    }
    for (graph.tests.items) |test_node| {
        if (test_node.disabled) continue;
        if (node_index != 0) try writer.writeAll(",");
        node_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, test_node.unique_id);
        try writer.writeAll(": ");
        try writeGenericTestNode(allocator, writer, graph, test_node);
    }
    for (graph.singular_tests.items) |test_node| {
        if (!test_node.enabled) continue;
        if (node_index != 0) try writer.writeAll(",");
        node_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, test_node.unique_id);
        try writer.writeAll(": ");
        try writeSingularTestNode(allocator, writer, graph, test_node);
    }
    try writer.writeAll("\n  },\n  \"sources\": {");
    var source_index: usize = 0;
    for (graph.sources.items) |source| {
        if (!source.enabled) continue;
        if (source_index != 0) try writer.writeAll(",");
        source_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, source.unique_id);
        try writer.writeAll(": ");
        try writeSourceNode(allocator, writer, graph, source);
    }
    try writer.writeAll("\n  },\n  \"macros\": {");
    for (graph.macros.items, 0..) |macro, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try json.string(writer, macro.unique_id);
        try writer.writeAll(": ");
        try writeMacroNode(allocator, writer, macro);
    }
    try writer.writeAll("\n  },\n  \"docs\": {");
    for (graph.docs.items, 0..) |doc, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try json.string(writer, doc.unique_id);
        try writer.writeAll(": {\"unique_id\":");
        try json.string(writer, doc.unique_id);
        try writer.writeAll(",\"resource_type\":\"doc\",\"package_name\":");
        try json.string(writer, doc.package_name);
        try writer.writeAll(",\"name\":");
        try json.string(writer, doc.name);
        try writer.writeAll(",\"path\":");
        try json.string(writer, util.normalizeForDisplay(doc.path));
        try writer.writeAll(",\"original_file_path\":");
        try json.string(writer, util.normalizeForDisplay(doc.original_file_path));
        try writer.writeAll(",\"block_contents\":");
        try json.string(writer, doc.block_contents);
        try writer.writeAll("}");
    }
    try writer.writeAll("\n  },\n  \"exposures\": {");
    var exposure_index: usize = 0;
    for (graph.exposures.items) |exposure| {
        if (!exposure.enabled) continue;
        if (exposure_index != 0) try writer.writeAll(",");
        exposure_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, exposure.unique_id);
        try writer.writeAll(": ");
        try writeExposureNode(writer, exposure);
    }
    try writer.writeAll("\n  },\n");
    for ([_][]const u8{ "metrics", "saved_queries", "semantic_models" }, [_][]const u8{ "metric", "saved_query", "semantic_model" }) |key, kind| {
        try writer.print("  \"{s}\": {{", .{key});
        var semantic_first = true;
        for (graph.semantic_resources.items) |resource| {
            if (!resource.enabled or !std.mem.eql(u8, resource.resource_type, kind)) continue;
            if (!semantic_first) try writer.writeByte(',');
            semantic_first = false;
            try json.string(writer, resource.unique_id);
            try writer.writeByte(':');
            try std.json.Stringify.value(resource.data, .{}, writer);
        }
        try writer.writeAll("},\n");
    }
    try @import("group_access.zig").writeManifest(writer, graph);
    try writer.writeAll("  \"selectors\": {},\n  \"unit_tests\": {");
    var unit_test_index: usize = 0;
    for (graph.unit_tests.items) |unit_test| {
        if (!unit_test.enabled) continue;
        if (unit_test_index != 0) try writer.writeAll(",");
        unit_test_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, unit_test.unique_id);
        try writer.writeAll(": ");
        try writeUnitTestNode(writer, unit_test);
    }
    try writer.writeAll("\n  },\n  \"disabled\": {");
    var disabled_index: usize = 0;
    for (graph.nodes.items) |node| {
        if (node.enabled) continue;
        if (disabled_index != 0) try writer.writeAll(",");
        disabled_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, node.unique_id);
        try writer.writeAll(": [");
        try writeNode(allocator, writer, graph, node);
        try writer.writeAll("]");
    }
    for (graph.tests.items, 0..) |test_node, index| {
        if (!test_node.disabled) continue;
        var prior = false;
        for (graph.tests.items[0..index]) |other| if (other.disabled and std.mem.eql(u8, other.unique_id, test_node.unique_id)) {
            prior = true;
        };
        if (prior) continue;
        if (disabled_index != 0) try writer.writeByte(',');
        disabled_index += 1;
        try json.string(writer, test_node.unique_id);
        try writer.writeAll(":[");
        var wrote = false;
        for (graph.tests.items) |other| if (other.disabled and std.mem.eql(u8, other.unique_id, test_node.unique_id)) {
            if (wrote) try writer.writeByte(',');
            wrote = true;
            try writeGenericTestNode(allocator, writer, graph, other);
        };
        try writer.writeByte(']');
    }
    for (graph.unit_tests.items) |unit| {
        if (unit.enabled) continue;
        if (disabled_index != 0) try writer.writeByte(',');
        disabled_index += 1;
        try json.string(writer, unit.unique_id);
        try writer.writeAll(":[");
        try writeUnitTestNode(writer, unit);
        try writer.writeByte(']');
    }
    for (graph.singular_tests.items) |test_node| {
        if (test_node.enabled) continue;
        if (disabled_index != 0) try writer.writeAll(",");
        disabled_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, test_node.unique_id);
        try writer.writeAll(": [");
        try writeSingularTestNode(allocator, writer, graph, test_node);
        try writer.writeAll("]");
    }
    for (graph.semantic_resources.items) |resource| {
        if (resource.enabled) continue;
        if (disabled_index != 0) try writer.writeByte(',');
        disabled_index += 1;
        try json.string(writer, resource.unique_id);
        try writer.writeAll(":[");
        try std.json.Stringify.value(resource.data, .{}, writer);
        try writer.writeByte(']');
    }
    for (graph.sources.items) |source| {
        if (source.enabled) continue;
        if (disabled_index != 0) try writer.writeAll(",");
        disabled_index += 1;
        try json.string(writer, source.unique_id);
        try writer.writeAll(":[");
        try writeSourceNode(allocator, writer, graph, source);
        try writer.writeAll("]");
    }
    try writer.writeAll("\n  },\n  \"parent_map\": {");
    var parent_index: usize = 0;
    for (graph.sources.items) |source| {
        if (!source.enabled) continue;
        if (parent_index != 0) try writer.writeByte(',');
        parent_index += 1;
        try json.string(writer, source.unique_id);
        try writer.writeAll(":[]");
    }
    for (graph.nodes.items) |node| {
        if (!node.enabled) continue;
        if (parent_index != 0) try writer.writeAll(",");
        parent_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, node.unique_id);
        try writer.writeAll(": ");
        try writeSortedDependencies(allocator, writer, node.depends_on.items);
    }
    for (graph.tests.items) |test_node| {
        if (test_node.disabled) continue;
        if (parent_index != 0) try writer.writeAll(",");
        parent_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, test_node.unique_id);
        try writer.writeAll(": ");
        try writeSortedDependencies(allocator, writer, test_node.depends_on.items);
    }
    for (graph.singular_tests.items) |test_node| {
        if (!test_node.enabled) continue;
        if (parent_index != 0) try writer.writeAll(",");
        parent_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, test_node.unique_id);
        try writer.writeAll(": ");
        try writeSortedDependencies(allocator, writer, test_node.depends_on.items);
    }
    for (graph.exposures.items) |exposure| {
        if (!exposure.enabled) continue;
        if (parent_index != 0) try writer.writeAll(",");
        parent_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, exposure.unique_id);
        try writer.writeAll(": ");
        try writeSortedDependencies(allocator, writer, exposure.depends_on.items);
    }
    for (graph.unit_tests.items) |unit_test| {
        if (!unit_test.enabled) continue;
        if (parent_index != 0) try writer.writeAll(",");
        parent_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, unit_test.unique_id);
        try writer.writeAll(": ");
        try writeSortedDependencies(allocator, writer, unit_test.depends_on.items);
    }
    for (graph.semantic_resources.items) |resource| {
        if (!resource.enabled) continue;
        if (parent_index != 0) try writer.writeByte(',');
        parent_index += 1;
        try json.string(writer, resource.unique_id);
        try writer.writeByte(':');
        const dependencies = try allocator.dupe([]const u8, resource.depends_on.items);
        defer allocator.free(dependencies);
        util.sortStrings(dependencies);
        try json.stringArray(writer, dependencies);
    }
    try writer.writeAll("\n  },\n  \"child_map\": {");
    try writeChildMap(allocator, writer, graph);
    try writer.writeAll("\n  }\n}\n");
    return try out.toOwnedSlice();
}

fn writeSortedDependencies(allocator: std.mem.Allocator, writer: *Io.Writer, dependencies: []const []const u8) !void {
    const sorted = try allocator.dupe([]const u8, dependencies);
    defer allocator.free(sorted);
    util.sortStrings(sorted);
    try json.stringArray(writer, sorted);
}

fn writeManifestMetadata(writer: *Io.Writer, graph: *const Graph) !void {
    try writer.writeAll("{");
    try @import("invocation.zig").writeFields(writer, manifest_schema_version, graph.invocation);
    try writer.writeAll(",\"project_name\":");
    try json.string(writer, graph.project_name);
    try writer.writeAll(",\"adapter_type\":");
    try json.string(writer, graph.adapter_type);
    try writer.writeAll("}");
}

fn writeChildMap(allocator: std.mem.Allocator, writer: *Io.Writer, graph: *const Graph) !void {
    var first = true;
    for (graph.nodes.items) |candidate| {
        if (!candidate.enabled) continue;
        try writeChildMapEntry(allocator, writer, graph, candidate.unique_id, &first);
    }
    for (graph.tests.items) |candidate| {
        if (candidate.disabled) continue;
        try writeChildMapEntry(allocator, writer, graph, candidate.unique_id, &first);
    }
    for (graph.singular_tests.items) |candidate| {
        if (!candidate.enabled) continue;
        try writeChildMapEntry(allocator, writer, graph, candidate.unique_id, &first);
    }
    for (graph.sources.items) |candidate| {
        if (!candidate.enabled) continue;
        try writeChildMapEntry(allocator, writer, graph, candidate.unique_id, &first);
    }
    for (graph.exposures.items) |candidate| {
        if (!candidate.enabled) continue;
        try writeChildMapEntry(allocator, writer, graph, candidate.unique_id, &first);
    }
    for (graph.unit_tests.items) |candidate| {
        if (!candidate.enabled) continue;
        try writeChildMapEntry(allocator, writer, graph, candidate.unique_id, &first);
    }
    for (graph.semantic_resources.items) |resource| {
        if (!resource.enabled) continue;
        try writeChildMapEntry(allocator, writer, graph, resource.unique_id, &first);
    }
}

fn writeChildMapEntry(allocator: std.mem.Allocator, writer: *Io.Writer, graph: *const Graph, unique_id: []const u8, first: *bool) !void {
    if (!first.*) try writer.writeAll(",");
    first.* = false;
    try writer.writeAll("\n    ");
    try json.string(writer, unique_id);
    try writer.writeAll(": ");
    var children: std.ArrayList([]const u8) = .empty;
    defer children.deinit(allocator);
    for (graph.nodes.items) |node| {
        if (!node.enabled) continue;
        if (util.containsString(node.depends_on.items, unique_id)) {
            try children.append(allocator, node.unique_id);
        }
    }
    for (graph.tests.items) |test_node| {
        if (test_node.disabled) continue;
        if (util.containsString(test_node.depends_on.items, unique_id)) {
            try children.append(allocator, test_node.unique_id);
        }
    }
    for (graph.singular_tests.items) |test_node| {
        if (!test_node.enabled) continue;
        if (util.containsString(test_node.depends_on.items, unique_id)) {
            try children.append(allocator, test_node.unique_id);
        }
    }
    for (graph.exposures.items) |exposure| {
        if (!exposure.enabled) continue;
        if (util.containsString(exposure.depends_on.items, unique_id)) {
            try children.append(allocator, exposure.unique_id);
        }
    }
    for (graph.unit_tests.items) |unit_test| {
        if (!unit_test.enabled) continue;
        if (util.containsString(unit_test.depends_on.items, unique_id)) {
            try children.append(allocator, unit_test.unique_id);
        }
    }
    for (graph.semantic_resources.items) |resource| {
        if (!resource.enabled or !util.containsString(resource.depends_on.items, unique_id)) continue;
        try children.append(allocator, resource.unique_id);
    }
    util.sortStrings(children.items);
    try json.stringArray(writer, children.items);
}

fn writeNode(allocator: std.mem.Allocator, writer: *Io.Writer, graph: *const Graph, node: Node) !void {
    if (std.mem.eql(u8, node.resource_type, "seed")) {
        try writeSeedNode(allocator, writer, graph, node);
    } else {
        try writeModelNode(allocator, writer, graph, node);
    }
}

fn writeNodeIdentityFields(allocator: std.mem.Allocator, writer: *Io.Writer, graph: *const Graph, node: *const Node) !void {
    const schema_name = try compiler.relationSchemaForNode(allocator, graph, node);
    defer allocator.free(schema_name);
    const alias = compiler.relationIdentifierForNode(node);

    try writer.writeAll(",\"database\":");
    const snapshot_config = node.snapshot_config;
    try writeNullableString(writer, if (node.resolved_identity) |identity| identity.database else compiler.relationDatabaseForNode(graph, node) orelse databaseNameForGraph(graph));
    try writer.writeAll(",\"schema\":");
    try json.string(writer, if (node.resolved_identity != null) schema_name else if (snapshot_config) |config| config.target_schema orelse schema_name else schema_name);
    try writer.writeAll(",\"alias\":");
    try json.string(writer, alias);
    try writer.writeAll(",\"relation_name\":");
    const relational = std.mem.eql(u8, node.resource_type, "model") or std.mem.eql(u8, node.resource_type, "seed") or std.mem.eql(u8, node.resource_type, "snapshot");
    if (relational and !std.mem.eql(u8, node.materialized, "ephemeral")) {
        if (node.relation_name) |relation| try json.string(writer, relation) else {
            const relation = try compiler.relationNameForNode(allocator, graph, node);
            defer allocator.free(relation);
            try json.string(writer, relation);
        }
    } else try writer.writeAll("null");
    try writer.writeAll(",\"fqn\":");
    if (node.version != .null) {
        const version = try @import("config_value.zig").scalarText(allocator, node.version);
        defer allocator.free(version);
        const logical_path = try std.fmt.allocPrint(allocator, "{s}{s}{s}.sql", .{ std.fs.path.dirname(node.path) orelse "", if (std.fs.path.dirname(node.path) != null) "/" else "", node.name });
        defer allocator.free(logical_path);
        const version_part = try std.fmt.allocPrint(allocator, "v{s}", .{version});
        defer allocator.free(version_part);
        try writeFqnFromPath(writer, node.package_name, logical_path, node.name, version_part);
    } else try writeFqnFromPath(writer, node.package_name, node.snapshot_fqn_path orelse node.path, node.name, if (snapshot_config != null and !node.snapshot_yaml_definition) node.name else null);
    try writer.writeAll(",\"checksum\":");
    if (node.hook_checksum) |digest| {
        var hex: [64]u8 = undefined;
        _ = try std.fmt.bufPrint(&hex, "{x}", .{&digest});
        try writer.writeAll("{\"name\":\"sha256\",\"checksum\":");
        try json.string(writer, &hex);
        try writer.writeAll("}");
    } else try writeSha256Checksum(writer, if (node.snapshot_file_code) |file_code| std.mem.trim(u8, file_code, " \t\r\n\x0b\x0c") else node.raw_code);
    try writer.writeAll(",\"tags\":");
    try json.stringArray(writer, node.tags.items);
    try writer.writeAll(",\"build_path\":");
    try writeNullableString(writer, node.build_path);
    if (!std.mem.eql(u8, node.resource_type, "seed")) {
        try writer.writeAll(",\"compiled_path\":");
        if (node.compiled_path) |path| try json.string(writer, util.normalizeForDisplay(path)) else try writer.writeAll("null");
    }
}

fn writeTestNodeIdentityFields(
    allocator: std.mem.Allocator,
    writer: *Io.Writer,
    graph: *const Graph,
    package_name: []const u8,
    path: []const u8,
    name: []const u8,
    raw_code: ?[]const u8,
    config: types.GenericTestConfig,
    fqn: ?[]const []const u8,
    identity: ?types.ResolvedIdentity,
    alias: []const u8,
) !void {
    var audit_node = audits.auditNode(config, alias, package_name);
    audit_node.resolved_identity = identity;
    const schema_name = try compiler.relationSchemaForNode(allocator, graph, &audit_node);
    defer allocator.free(schema_name);

    try writer.writeAll(",\"database\":");
    try writeNullableString(writer, if (identity) |resolved| resolved.database else config.database orelse compiler.relationDatabaseForNode(graph, &audit_node) orelse databaseNameForGraph(graph));
    try writer.writeAll(",\"schema\":");
    try json.string(writer, schema_name);
    try writer.writeAll(",\"relation_name\":");
    if (audits.shouldStore(config, graph.command_options)) {
        const relation = try audits.relationNameWithIdentity(allocator, graph, config, alias, package_name, identity);
        defer allocator.free(relation);
        try json.string(writer, relation);
    } else try writer.writeAll("null");
    try writer.writeAll(",\"fqn\":");
    if (fqn) |parts| try json.stringArray(writer, parts) else try writeFqnFromPath(writer, package_name, path, name, null);
    try writer.writeAll(",\"checksum\":");
    if (raw_code) |code| {
        try writeSha256Checksum(writer, code);
    } else {
        try writeNoneChecksum(writer);
    }
}

fn databaseNameForGraph(graph: *const Graph) ?[]const u8 {
    if (@import("config_value.zig").get(graph.target_context, "database")) |database| if (database == .string) return database.string;
    if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return null;
    const configured_path = graph.database_path orelse return "memory";
    const trimmed = std.mem.trim(u8, configured_path, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, ":memory:")) return "memory";
    const basename = std.fs.path.basename(trimmed);
    if (basename.len == 0) return "memory";
    if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot| {
        if (dot != 0) return basename[0..dot];
    }
    return basename;
}

fn writeFqnFromPath(writer: *Io.Writer, package_name: []const u8, path: []const u8, fallback_name: []const u8, append_name: ?[]const u8) !void {
    try writer.writeAll("[");
    try json.string(writer, package_name);

    const normalized_path = util.normalizeForDisplay(path);
    const stem_path = stemFromPath(normalized_path);
    var wrote_path_part = false;
    var parts = std.mem.splitScalar(u8, stem_path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        try writer.writeAll(",");
        try json.string(writer, part);
        wrote_path_part = true;
    }

    if (append_name) |name| {
        try writer.writeAll(",");
        try json.string(writer, name);
    }
    if (!wrote_path_part) {
        try writer.writeAll(",");
        try json.string(writer, fallback_name);
    }
    try writer.writeAll("]");
}

fn stemFromPath(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
        if (dot != 0 and dot > slash) return path[0..dot];
    }
    return path;
}

fn writeSha256Checksum(writer: *Io.Writer, raw_code: []const u8) !void {
    const checksum_input = std.mem.trim(u8, raw_code, " \t\r\n\x0b\x0c");
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(checksum_input, &digest, .{});
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;
    try writer.writeAll("{\"name\":\"sha256\",\"checksum\":");
    try json.string(writer, hex[0..]);
    try writer.writeAll("}");
}

fn writeNoneChecksum(writer: *Io.Writer) !void {
    try writer.writeAll("{\"name\":\"none\",\"checksum\":\"\"}");
}

fn writeMacroNode(allocator: std.mem.Allocator, writer: *Io.Writer, macro: MacroDef) !void {
    try writer.writeAll("{\"unique_id\":");
    try json.string(writer, macro.unique_id);
    try writer.writeAll(",\"resource_type\":\"macro\",\"package_name\":");
    try json.string(writer, macro.package_name);
    try writer.writeAll(",\"name\":");
    try json.string(writer, macro.name);
    try writer.writeAll(",\"path\":");
    try json.string(writer, util.normalizeForDisplay(macro.path));
    try writer.writeAll(",\"original_file_path\":");
    try json.string(writer, util.normalizeForDisplay(macro.original_file_path));
    try writer.writeAll(",\"macro_sql\":");
    try json.string(writer, macro.macro_sql);
    try writer.writeAll(",\"depends_on\":{\"macros\":");
    try json.stringArray(writer, macro.macro_depends_on.items);
    try writer.writeAll("},\"description\":");
    try json.string(writer, macro.description);
    try writer.writeAll(",\"meta\":");
    try writeMetaObject(writer, macro.meta.items);
    try writer.writeAll(",\"docs\":");
    try writeDocsConfig(writer, macro.docs);
    try writer.writeAll(",\"patch_path\":");
    if (macro.patch_path) |patch_path| {
        const dbt_patch_path = try std.fmt.allocPrint(allocator, "{s}://{s}", .{ macro.package_name, util.normalizeForDisplay(patch_path) });
        defer allocator.free(dbt_patch_path);
        try json.string(writer, dbt_patch_path);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"arguments\":");
    try writeMacroArguments(writer, macro.arguments.items);
    try writer.writeAll(",\"supported_languages\":");
    if (macro.has_supported_languages) {
        try json.stringArray(writer, macro.supported_languages.items);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}");
}

fn writeSourceNode(allocator: std.mem.Allocator, writer: *Io.Writer, graph: *const Graph, source: SourceDef) !void {
    const database_name = compiler.sourceDatabaseName(&source) orelse databaseNameForGraph(graph);
    const schema_name = compiler.sourceSchemaName(&source);
    const relation_name = try compiler.relationNameForSource(allocator, &source);
    defer allocator.free(relation_name);

    try writer.writeAll("{\"unique_id\":");
    try json.string(writer, source.unique_id);
    try writer.writeAll(",\"resource_type\":\"source\",\"package_name\":");
    try json.string(writer, source.package_name);
    try writer.writeAll(",\"source_name\":");
    try json.string(writer, source.source_name);
    try writer.writeAll(",\"name\":");
    try json.string(writer, source.table_name);
    try writer.writeAll(",\"database\":");
    try writeNullableString(writer, database_name);
    try writer.writeAll(",\"schema\":");
    try json.string(writer, schema_name);
    try writer.writeAll(",\"identifier\":");
    try json.string(writer, compiler.sourceIdentifier(&source));
    try writer.writeAll(",\"relation_name\":");
    try json.string(writer, relation_name);
    try writer.writeAll(",\"quoting\":");
    try writeSourceQuoting(writer, source.quoting);
    try writer.writeAll(",\"path\":");
    try json.string(writer, util.normalizeForDisplay(source.original_file_path));
    try writer.writeAll(",\"original_file_path\":");
    try json.string(writer, util.normalizeForDisplay(source.original_file_path));
    try writer.writeAll(",\"fqn\":[");
    try json.string(writer, source.package_name);
    try writer.writeAll(",");
    try json.string(writer, source.source_name);
    try writer.writeAll(",");
    try json.string(writer, source.table_name);
    try writer.writeAll("],\"description\":");
    try json.string(writer, source.description);
    try writer.writeAll(",\"source_description\":");
    try json.string(writer, source.source_description);
    try writer.writeAll(",\"doc_blocks\":");
    try json.stringArray(writer, source.doc_blocks.items);
    try writer.writeAll(",\"loader\":");
    try json.string(writer, source.loader);
    try writer.writeAll(",\"loaded_at_field\":");
    try writeNullableString(writer, source.loaded_at_field);
    try writer.writeAll(",\"loaded_at_query\":");
    try writeNullableString(writer, source.loaded_at_query);
    try writer.writeAll(",\"freshness\":");
    if (source.freshness == null and source.freshness_set) try writer.writeAll("null") else try writeSourceFreshnessThreshold(writer, source.freshness orelse .{});
    try writer.writeAll(",\"columns\":");
    try writeColumns(writer, source.columns.items);
    const fields = @import("config_value.zig");
    try writer.writeAll(",\"meta\":");
    try std.json.Stringify.value(fields.get(source.effective_config, "meta") orelse @as(std.json.Value, .{ .object = .empty }), .{}, writer);
    try writer.writeAll(",\"tags\":");
    try std.json.Stringify.value(fields.get(source.effective_config, "tags") orelse @as(std.json.Value, .{ .array = std.json.Array.init(std.heap.page_allocator) }), .{}, writer);
    try writer.writeAll(",\"config\":");
    try writeSourceConfig(writer, source, false);
    try writer.writeAll(",\"unrendered_config\":");
    try writeSourceConfig(writer, source, true);
    try writer.writeAll("}");
}

fn writeSourceConfig(writer: *Io.Writer, source: SourceDef, raw: bool) !void {
    const fields = @import("config_value.zig");
    const config = if (raw) source.raw_config else source.effective_config;
    try writer.writeAll("{");
    var wrote = false;
    if (!raw) {
        try writer.writeAll("\"enabled\":");
        try writer.writeAll(if (source.enabled) "true" else "false");
        try writer.writeAll(",\"event_time\":");
        try std.json.Stringify.value(fields.get(config, "event_time") orelse .null, .{}, writer);
        wrote = true;
    }
    inline for (.{ "loaded_at_field", "loaded_at_query", "meta", "tags" }) |key| {
        if (wrote) try writer.writeAll(",");
        wrote = true;
        try json.string(writer, key);
        try writer.writeAll(":");
        const fallback: std.json.Value = if (std.mem.eql(u8, key, "meta")) .{ .object = .empty } else if (std.mem.eql(u8, key, "tags")) .{ .array = std.json.Array.init(std.heap.page_allocator) } else if (std.mem.eql(u8, key, "loaded_at_field") and source.loaded_at_field != null) .{ .string = source.loaded_at_field.? } else if (std.mem.eql(u8, key, "loaded_at_query") and source.loaded_at_query != null) .{ .string = source.loaded_at_query.? } else .null;
        const value = fields.get(config, key) orelse fallback;
        try std.json.Stringify.value(value, .{}, writer);
    }
    if (!raw or fields.get(config, "freshness") != null or (source.freshness != null and source.properties == .null)) {
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"freshness\":");
        if (source.freshness == null and source.freshness_set) try writer.writeAll("null") else try writeSourceFreshnessThreshold(writer, source.freshness orelse .{});
    }
    if (config == .object) {
        var it = config.object.iterator();
        while (it.next()) |entry| {
            var known = false;
            for ([_][]const u8{ "loaded_at_field", "loaded_at_query", "meta", "tags", "freshness" }) |key| if (std.mem.eql(u8, key, entry.key_ptr.*)) {
                known = true;
            };
            if (!raw and (std.mem.eql(u8, entry.key_ptr.*, "enabled") or std.mem.eql(u8, entry.key_ptr.*, "event_time"))) known = true;
            if (known) continue;
            try writer.writeAll(",");
            try json.string(writer, entry.key_ptr.*);
            try writer.writeAll(":");
            try std.json.Stringify.value(entry.value_ptr.*, .{}, writer);
        }
    }
    try writer.writeAll("}");
}

fn writeSourceQuoting(writer: *Io.Writer, quoting: types.SourceQuoting) !void {
    try writer.writeAll("{\"database\":");
    try writeNullableBool(writer, quoting.database);
    try writer.writeAll(",\"schema\":");
    try writeNullableBool(writer, quoting.schema);
    try writer.writeAll(",\"identifier\":");
    try writeNullableBool(writer, quoting.identifier);
    try writer.writeAll(",\"column\":");
    try writeNullableBool(writer, quoting.column);
    try writer.writeAll("}");
}

fn writeExposureNode(writer: *Io.Writer, exposure: ExposureDef) !void {
    try writer.writeAll("{\"unique_id\":");
    try json.string(writer, exposure.unique_id);
    try writer.writeAll(",\"resource_type\":\"exposure\",\"package_name\":");
    try json.string(writer, exposure.package_name);
    try writer.writeAll(",\"name\":");
    try json.string(writer, exposure.name);
    try writer.writeAll(",\"path\":");
    try json.string(writer, util.normalizeForDisplay(exposure.path));
    try writer.writeAll(",\"original_file_path\":");
    try json.string(writer, util.normalizeForDisplay(exposure.original_file_path));
    try writer.writeAll(",\"fqn\":[");
    try json.string(writer, exposure.package_name);
    try writer.writeAll(",");
    try json.string(writer, exposure.name);
    try writer.writeAll("],\"label\":null,\"type\":");
    try json.string(writer, exposure.exposure_type);
    try writer.writeAll(",\"maturity\":");
    try writeNullableString(writer, exposure.maturity);
    try writer.writeAll(",\"url\":");
    try writeNullableString(writer, exposure.url);
    try writer.writeAll(",\"description\":");
    try json.string(writer, exposure.description);
    try writer.writeAll(",\"depends_on\":{\"macros\":[],\"nodes\":");
    try writeExposureDependsOnNodes(writer, exposure.depends_on.items);
    try writer.writeAll("},\"refs\":");
    try writeRefDeps(writer, exposure.refs.items);
    try writer.writeAll(",\"sources\":");
    try writeSourceDeps(writer, exposure.source_refs.items);
    try writer.writeAll(",\"metrics\":[],\"owner\":{\"email\":");
    try writeNullableString(writer, exposure.owner_email);
    try writer.writeAll(",\"name\":");
    if (exposure.owner_name.len == 0) {
        try writer.writeAll("null");
    } else {
        try json.string(writer, exposure.owner_name);
    }
    try writer.writeAll("},\"tags\":");
    try json.stringArray(writer, exposure.tags.items);
    try writer.writeAll(",\"meta\":");
    try writeMetaObject(writer, exposure.meta.items);
    try writer.writeAll(",\"config\":{\"enabled\":");
    try writer.writeAll(if (exposure.enabled) "true" else "false");
    try writer.writeAll(",\"tags\":");
    try json.stringArray(writer, exposure.tags.items);
    try writer.writeAll(",\"meta\":");
    try writeMetaObject(writer, exposure.meta.items);
    try writer.writeAll("},\"unrendered_config\":{},\"created_at\":0.0}");
}

fn writeUnitTestNode(writer: *Io.Writer, unit_test: UnitTestDef) !void {
    try writer.writeAll("{\"model\":");
    try json.string(writer, unit_test.model);
    try writer.writeAll(",\"given\":");
    try writeUnitTestGivenFixtures(writer, unit_test.given.items);
    try writer.writeAll(",\"expect\":");
    try writeUnitTestOutputFixture(writer, unit_test.expect);
    try writer.writeAll(",\"name\":");
    try json.string(writer, unit_test.name);
    try writer.writeAll(",\"resource_type\":\"unit_test\",\"package_name\":");
    try json.string(writer, unit_test.package_name);
    try writer.writeAll(",\"path\":");
    try json.string(writer, util.normalizeForDisplay(unit_test.path));
    try writer.writeAll(",\"original_file_path\":");
    try json.string(writer, util.normalizeForDisplay(unit_test.original_file_path));
    try writer.writeAll(",\"unique_id\":");
    try json.string(writer, unit_test.unique_id);
    try writer.writeAll(",\"fqn\":");
    try json.stringArray(writer, if (unit_test.fqn.items.len != 0) unit_test.fqn.items else &.{ unit_test.package_name, unit_test.model, unit_test.name });
    try writer.writeAll(",\"description\":");
    try json.string(writer, unit_test.description);
    try writer.writeAll(",\"overrides\":");
    try std.json.Stringify.value(unit_test.overrides, .{}, writer);
    try writer.writeAll(",\"depends_on\":{\"macros\":[],\"nodes\":");
    try json.stringArray(writer, unit_test.depends_on.items);
    try writer.writeAll("},\"config\":");
    if (unit_test.config_values == .object) try std.json.Stringify.value(unit_test.config_values, .{}, writer) else {
        try writer.writeAll("{\"tags\":");
        try json.stringArray(writer, unit_test.tags.items);
        try writer.writeAll(",\"meta\":");
        try writeMetaObject(writer, unit_test.meta.items);
        try writer.writeAll(",\"enabled\":");
        try writer.writeAll(if (unit_test.enabled) "true" else "false");
        try writer.writeAll(",\"static_analysis\":null}");
    }
    try writer.writeAll(",\"checksum\":");
    if (unit_test.checksum) |checksum| try json.string(writer, checksum) else try writer.writeAll("null");
    try writer.writeAll(",\"schema\":");
    if (unit_test.schema) |schema| try json.string(writer, schema) else try writer.writeAll("null");
    try writer.writeAll(",\"created_at\":0.0,\"versions\":");
    try std.json.Stringify.value(unit_test.versions, .{}, writer);
    try writer.writeAll(",\"version\":");
    try std.json.Stringify.value(unit_test.version, .{}, writer);
    try writer.writeAll("}");
}

fn writeUnitTestGivenFixtures(writer: *Io.Writer, fixtures: []const types.UnitTestFixture) !void {
    try writer.writeAll("[");
    for (fixtures, 0..) |fixture, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("{\"input\":");
        try json.string(writer, fixture.input orelse "");
        try writer.writeAll(",\"rows\":");
        try writeUnitTestRows(writer, fixture);
        try writer.writeAll(",\"format\":");
        try json.string(writer, fixture.format);
        try writer.writeAll(",\"fixture\":");
        try writeNullableString(writer, fixture.fixture);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeUnitTestOutputFixture(writer: *Io.Writer, fixture: types.UnitTestFixture) !void {
    try writer.writeAll("{\"rows\":");
    try writeUnitTestRows(writer, fixture);
    try writer.writeAll(",\"format\":");
    try json.string(writer, fixture.format);
    try writer.writeAll(",\"fixture\":");
    try writeNullableString(writer, fixture.fixture);
    try writer.writeAll("}");
}

fn writeUnitTestRows(writer: *Io.Writer, fixture: types.UnitTestFixture) !void {
    if (!fixture.rows_set) {
        try writer.writeAll("null");
        return;
    }
    if (fixture.rows_string) |rows_string| {
        try json.string(writer, rows_string);
        return;
    }
    try writer.writeAll("[");
    for (fixture.rows.items, 0..) |row, row_index| {
        if (row_index != 0) try writer.writeAll(",");
        try writer.writeAll("{");
        for (row.entries.items, 0..) |entry, entry_index| {
            if (entry_index != 0) try writer.writeAll(",");
            try json.string(writer, entry.key);
            try writer.writeAll(":");
            try writeJsonScalar(writer, entry.value);
        }
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeModelNode(allocator: std.mem.Allocator, writer: *Io.Writer, graph: *const Graph, node: Node) !void {
    try writer.writeAll("{\"unique_id\":");
    try json.string(writer, node.unique_id);
    try writer.writeAll(",\"resource_type\":");
    try json.string(writer, node.resource_type);
    try writer.writeAll(",\"package_name\":");
    try json.string(writer, node.package_name);
    try writer.writeAll(",\"name\":");
    try json.string(writer, node.name);
    if (node.hook_index) |index| {
        try writer.print(",\"index\":{d},\"contract\":{{\"enforced\":false,\"alias_types\":true,\"checksum\":null}}", .{index});
    }
    if (std.mem.eql(u8, node.resource_type, "model")) {
        try writer.writeAll(",\"contract\":");
        var contract = try @import("contracts.zig").metadata(allocator, &node);
        defer @import("config_value.zig").deinit(allocator, &contract);
        try std.json.Stringify.value(contract, .{}, writer);
        try writer.writeAll(",\"constraints\":");
        var constraints = try @import("contracts.zig").artifactConstraints(allocator, graph, &node, @import("config_value.zig").get(node.properties, "constraints") orelse .null, true);
        defer @import("config_value.zig").deinit(allocator, &constraints);
        try std.json.Stringify.value(constraints, .{}, writer);
        try writer.writeAll(",\"access\":");
        try json.string(writer, @import("group_access.zig").access(&node));
        try writer.writeAll(",\"version\":");
        try std.json.Stringify.value(node.version, .{}, writer);
        try writer.writeAll(",\"latest_version\":");
        try std.json.Stringify.value(node.latest_version, .{}, writer);
    }
    try writeUnrenderedNodeConfig(writer, graph, &node);
    try writeNodeIdentityFields(allocator, writer, graph, &node);
    try writer.writeAll(",\"path\":");
    try json.string(writer, util.normalizeForDisplay(node.path));
    try writer.writeAll(",\"original_file_path\":");
    try json.string(writer, util.normalizeForDisplay(node.original_file_path));
    try writer.writeAll(",\"patch_path\":");
    if (node.patch_path) |patch_path| {
        const dbt_patch_path = try std.fmt.allocPrint(allocator, "{s}://{s}", .{ node.package_name, util.normalizeForDisplay(patch_path) });
        defer allocator.free(dbt_patch_path);
        try json.string(writer, dbt_patch_path);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"language\":");
    try json.string(writer, node.language);
    try writer.writeAll(",\"raw_code\":");
    try json.string(writer, node.raw_code);
    try writer.writeAll(",\"description\":");
    try json.string(writer, node.description);
    try writer.writeAll(",\"doc_blocks\":");
    try json.stringArray(writer, node.doc_blocks.items);
    try writer.writeAll(",\"docs\":");
    try writeDocsConfig(writer, node.docs);
    try writer.writeAll(",\"columns\":");
    if (std.mem.eql(u8, node.resource_type, "model")) try writeModelColumns(allocator, writer, graph, &node) else try writeColumns(writer, node.columns.items);
    try writer.writeAll(",\"config\":");
    var canonical_config = try @import("canonical_manifest_config.zig").node(allocator, &node);
    defer @import("config_value.zig").deinit(allocator, &canonical_config);
    try std.json.Stringify.value(canonical_config, .{}, writer);
    try writer.writeAll(",\"depends_on\":{\"macros\":");
    try json.stringArray(writer, node.macro_depends_on.items);
    try writer.writeAll(",\"nodes\":");
    try json.stringArray(writer, node.depends_on.items);
    try writer.writeAll("},\"refs\":");
    try writeRefDeps(writer, node.refs.items);
    try writer.writeAll(",\"sources\":");
    try writeSourceDeps(writer, node.source_refs.items);
    if (node.compiled) {
        try writer.writeAll(",\"compiled\":true,\"compiled_code\":");
        try json.string(writer, node.compiled_code orelse "");
        try writer.writeAll(",\"extra_ctes\":");
        try writeExtraCtes(writer, node.extra_ctes.items, graph.command_options.inject_ephemeral_ctes);
        try writer.writeAll(",\"extra_ctes_injected\":");
        try writer.writeAll(if (graph.command_options.inject_ephemeral_ctes) "true" else "false");
    }
    try writer.writeAll(",\"meta\":");
    if (@import("config_value.zig").get(node.effective_config, "meta")) |meta| try std.json.Stringify.value(meta, .{}, writer) else if (node.snapshot_meta_json) |meta| try writeJsonValue(writer, meta) else try writeMetaObject(writer, node.meta.items);
    try writer.writeAll("}");
}

fn writePersistDocs(writer: *Io.Writer, docs: types.PersistDocs) !void {
    try writer.writeAll("{");
    var wrote = false;
    if (docs.relation) |value| {
        try writer.writeAll("\"relation\":");
        try json.boolValue(writer, value);
        wrote = true;
    }
    if (docs.columns) |value| {
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"columns\":");
        try json.boolValue(writer, value);
    }
    try writer.writeAll("}");
}

fn writeUnrenderedNodeConfig(writer: *Io.Writer, graph: *const Graph, node: *const Node) !void {
    if (node.raw_config == .object) {
        try writer.writeAll(",\"unrendered_config\":");
        try std.json.Stringify.value(node.raw_config, .{}, writer);
        return;
    }
    try writer.writeAll(",\"unrendered_config\":{");
    var wrote = false;
    var configured_materialized = node.inline_materialized;
    var configured_enabled = node.inline_enabled;
    for (graph.model_properties.items) |property| {
        if (!std.mem.eql(u8, property.package_name, node.package_name) or !std.mem.eql(u8, property.resource_type, node.resource_type) or !std.mem.eql(u8, property.name, node.name)) continue;
        configured_materialized = configured_materialized or property.materialized.len != 0;
        configured_enabled = configured_enabled or property.enabled != null;
    }
    if (configured_materialized or (std.mem.eql(u8, node.resource_type, "model") and !std.mem.eql(u8, node.materialized, "view"))) try json.stringField(writer, "materialized", node.materialized, &wrote);
    if (configured_enabled) {
        if (wrote) try writer.writeAll(",");
        wrote = true;
        try writer.writeAll("\"enabled\":");
        try json.boolValue(writer, node.enabled);
    }
    if (node.snapshot_config) |config| {
        if (!wrote) {
            try writer.writeAll("\"strategy\":");
            try writeNullableString(writer, config.strategy);
        } else {
            try writer.writeAll(",\"strategy\":");
            try writeNullableString(writer, config.strategy);
        }
        wrote = true;
        try writer.writeAll(",\"unique_key\":");
        try writeSnapshotColumns(writer, config.unique_key);
        if (config.target_schema) |value| try json.stringField(writer, "target_schema", value, &wrote);
        if (config.target_database) |value| try json.stringField(writer, "target_database", value, &wrote);
        if (config.updated_at) |value| try json.stringField(writer, "updated_at", value, &wrote);
        if (config.check_cols != null) {
            try writer.writeAll(",\"check_cols\":");
            try writeSnapshotColumns(writer, config.check_cols);
        }
        if (config.invalidate_hard_deletes) |value| {
            try writer.writeAll(",\"invalidate_hard_deletes\":");
            try json.boolValue(writer, value);
        }
    }
    if (node.config_schema) |value| try json.stringField(writer, "schema", value, &wrote);
    if (node.config_alias) |value| try json.stringField(writer, "alias", value, &wrote);
    if (node.persist_docs) |docs| {
        if (wrote) try writer.writeAll(",");
        wrote = true;
        try writer.writeAll("\"persist_docs\":");
        try writePersistDocs(writer, docs);
    }
    if (node.docs.configured) {
        if (wrote) try writer.writeAll(",");
        wrote = true;
        try writer.writeAll("\"docs\":");
        try writeDocsConfig(writer, node.docs);
    }
    if (node.quote_columns) |quote_columns| {
        if (wrote) try writer.writeAll(",");
        wrote = true;
        try writer.writeAll("\"quote_columns\":");
        try json.boolValue(writer, quote_columns);
    }
    if (node.seed_column_types.items.len != 0) {
        if (wrote) try writer.writeAll(",");
        try writer.writeAll("\"column_types\":");
        try writeSeedColumnTypes(writer, node.seed_column_types.items);
    }
    try writer.writeAll("}");
}

fn writeExtraCtes(writer: *Io.Writer, extra_ctes: []const types.ExtraCte, injected: bool) !void {
    try writer.writeAll("[");
    for (extra_ctes, 0..) |extra_cte, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("{\"id\":");
        try json.string(writer, extra_cte.id);
        try writer.writeAll(",\"sql\":");
        if (injected) try json.string(writer, extra_cte.sql) else try writer.writeAll("null");
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeSeedNode(allocator: std.mem.Allocator, writer: *Io.Writer, graph: *const Graph, node: Node) !void {
    try writer.writeAll("{\"unique_id\":");
    try json.string(writer, node.unique_id);
    try writer.writeAll(",\"resource_type\":\"seed\",\"package_name\":");
    try json.string(writer, node.package_name);
    try writer.writeAll(",\"name\":");
    try json.string(writer, node.name);
    try writeUnrenderedNodeConfig(writer, graph, &node);
    try writeNodeIdentityFields(allocator, writer, graph, &node);
    try writer.writeAll(",\"path\":");
    try json.string(writer, util.normalizeForDisplay(node.path));
    try writer.writeAll(",\"original_file_path\":");
    try json.string(writer, util.normalizeForDisplay(node.original_file_path));
    try writer.writeAll(",\"patch_path\":");
    if (node.patch_path) |patch_path| {
        const dbt_patch_path = try std.fmt.allocPrint(allocator, "{s}://{s}", .{ node.package_name, util.normalizeForDisplay(patch_path) });
        defer allocator.free(dbt_patch_path);
        try json.string(writer, dbt_patch_path);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"description\":");
    try json.string(writer, node.description);
    try writer.writeAll(",\"doc_blocks\":");
    try json.stringArray(writer, node.doc_blocks.items);
    try writer.writeAll(",\"columns\":");
    try writeColumns(writer, node.columns.items);
    try writer.writeAll(",\"config\":");
    var canonical_config = try @import("canonical_manifest_config.zig").node(allocator, &node);
    defer @import("config_value.zig").deinit(allocator, &canonical_config);
    try std.json.Stringify.value(canonical_config, .{}, writer);
    try writer.writeAll(",\"docs\":");
    try writeDocsConfig(writer, node.docs);
    try writer.writeAll(",\"raw_code\":\"\"");
    try writer.writeAll(",\"depends_on\":{\"macros\":");
    try json.stringArray(writer, node.macro_depends_on.items);
    try writer.writeAll("}}");
}

fn writeSeedColumnTypes(writer: *Io.Writer, column_types: []const types.SeedColumnType) !void {
    try writer.writeAll("{");
    for (column_types, 0..) |column_type, index| {
        if (index != 0) try writer.writeAll(",");
        try json.string(writer, column_type.name);
        try writer.writeAll(":");
        try json.string(writer, column_type.data_type);
    }
    try writer.writeAll("}");
}

fn writeModelColumns(allocator: std.mem.Allocator, writer: *Io.Writer, graph: *const Graph, node: *const Node) !void {
    if (!node.compiled) return writeColumns(writer, node.columns.items);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const columns = try scratch.dupe(types.ColumnDef, node.columns.items);
    for (columns) |*column| {
        if (column.properties != .object) continue;
        column.properties = try @import("config_value.zig").clone(scratch, column.properties);
        const constraints = try @import("contracts.zig").artifactConstraints(scratch, graph, node, @import("config_value.zig").get(column.properties, "constraints") orelse .null, false);
        try @import("config_value.zig").put(scratch, &column.properties, "constraints", constraints);
    }
    return writeColumns(writer, columns);
}

fn writeColumns(writer: *Io.Writer, columns: []const types.ColumnDef) !void {
    try writer.writeAll("{");
    for (columns, 0..) |column, index| {
        if (index != 0) try writer.writeAll(",");
        try json.string(writer, column.name);
        try writer.writeAll(":{\"name\":");
        try json.string(writer, column.name);
        try writer.writeAll(",\"description\":");
        try json.string(writer, column.description);
        if (column.properties == .null) {
            try writer.writeAll(",\"meta\":");
            if (column.meta_json) |value| try writeJsonValue(writer, value) else try writer.writeAll("{}");
            try writer.writeAll(",\"data_type\":");
            try writeNullableString(writer, column.data_type);
            try writer.writeAll(",\"quote\":");
            if (column.quote) |value| try writer.writeAll(if (value) "true" else "false") else try writer.writeAll("null");
            try writer.writeAll(",\"tags\":");
            try json.stringArray(writer, column.tags.items);
            try writer.writeAll(",\"config\":");
            if (column.config_json) |value| try writeJsonValue(writer, value) else try writer.writeAll("{}");
            try writer.writeAll(",\"constraints\":[],\"granularity\":null");
        } else {
            const fields = @import("config_value.zig");
            const config = fields.get(column.properties, "config") orelse @as(std.json.Value, .{ .object = .empty });
            const meta = fields.get(column.properties, "meta") orelse @as(std.json.Value, .{ .object = .empty });
            const tags = fields.get(column.properties, "tags") orelse @as(std.json.Value, .{ .array = std.json.Array.init(std.heap.page_allocator) });
            try writer.writeAll(",\"meta\":");
            try std.json.Stringify.value(meta, .{}, writer);
            try writer.writeAll(",\"data_type\":");
            try std.json.Stringify.value(fields.get(column.properties, "data_type") orelse .null, .{}, writer);
            try writer.writeAll(",\"quote\":");
            try std.json.Stringify.value(fields.get(column.properties, "quote") orelse .null, .{}, writer);
            try writer.writeAll(",\"tags\":");
            try std.json.Stringify.value(tags, .{}, writer);
            try writer.writeAll(",\"config\":");
            try writer.writeAll("{\"meta\":");
            try std.json.Stringify.value(fields.get(config, "meta") orelse @as(std.json.Value, .{ .object = .empty }), .{}, writer);
            try writer.writeAll(",\"tags\":");
            try std.json.Stringify.value(fields.get(config, "tags") orelse @as(std.json.Value, .{ .array = std.json.Array.init(std.heap.page_allocator) }), .{}, writer);
            if (config == .object) {
                var it = config.object.iterator();
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.key_ptr.*, "meta") or std.mem.eql(u8, entry.key_ptr.*, "tags")) continue;
                    try writer.writeAll(",");
                    try json.string(writer, entry.key_ptr.*);
                    try writer.writeAll(":");
                    try std.json.Stringify.value(entry.value_ptr.*, .{}, writer);
                }
            }
            try writer.writeAll("}");
            try writer.writeAll(",\"constraints\":");
            try writeConstraints(writer, fields.get(column.properties, "constraints") orelse .null);
            try writer.writeAll(",\"granularity\":");
            try std.json.Stringify.value(fields.get(column.properties, "granularity") orelse .null, .{}, writer);
        }
        try writer.writeAll(",\"doc_blocks\":");
        try json.stringArray(writer, column.doc_blocks.items);
        try writer.writeAll("}");
    }
    try writer.writeAll("}");
}

fn writeConstraints(writer: *Io.Writer, constraints: std.json.Value) !void {
    const fields = @import("config_value.zig");
    try writer.writeAll("[");
    if (constraints == .array) for (constraints.array.items, 0..) |constraint, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("{");
        inline for (.{ "type", "name", "expression", "warn_unenforced", "warn_unsupported", "to", "to_columns" }, 0..) |key, field_index| {
            if (field_index != 0) try writer.writeAll(",");
            try json.string(writer, key);
            try writer.writeAll(":");
            const fallback: std.json.Value = if (std.mem.startsWith(u8, key, "warn_")) .{ .bool = true } else if (std.mem.eql(u8, key, "to_columns")) .{ .array = std.json.Array.init(std.heap.page_allocator) } else .null;
            try std.json.Stringify.value(fields.get(constraint, key) orelse fallback, .{}, writer);
        }
        try writer.writeAll("}");
    };
    try writer.writeAll("]");
}

/// Runtime test providers expose the same resource metadata as artifacts.
/// Worker-owned compilation fields override the read-only parsed graph node.
pub fn testContextNode(allocator: std.mem.Allocator, graph: *const Graph, runtime_node: *const Node) !?std.json.Value {
    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    for (graph.tests.items) |original| if (std.mem.eql(u8, original.unique_id, runtime_node.unique_id)) {
        var node = original;
        node.build_path = runtime_node.build_path orelse node.build_path;
        node.compiled = runtime_node.compiled;
        node.compiled_code = runtime_node.compiled_code;
        node.compiled_path = runtime_node.compiled_path;
        node.extra_ctes = runtime_node.extra_ctes;
        try writeGenericTestNode(allocator, &output.writer, graph, node);
        break;
    };
    if (output.written().len == 0) for (graph.singular_tests.items) |original| if (std.mem.eql(u8, original.unique_id, runtime_node.unique_id)) {
        var node = original;
        node.build_path = runtime_node.build_path orelse node.build_path;
        node.compiled = runtime_node.compiled;
        node.compiled_code = runtime_node.compiled_code;
        node.compiled_path = runtime_node.compiled_path;
        node.extra_ctes = runtime_node.extra_ctes;
        try writeSingularTestNode(allocator, &output.writer, graph, node);
        break;
    };
    if (output.written().len == 0) return null;
    var document = try std.json.parseFromSlice(std.json.Value, allocator, output.written(), .{});
    defer document.deinit();
    return try @import("config_value.zig").clone(allocator, document.value);
}

fn writeGenericTestNode(allocator: std.mem.Allocator, writer: *Io.Writer, graph: *const Graph, test_node: GenericTestNode) !void {
    const argument_column_name = genericTestNodeColumnName(&test_node);
    try writer.writeAll("{\"unique_id\":");
    try json.string(writer, test_node.unique_id);
    try writer.writeAll(",\"resource_type\":\"test\",\"package_name\":");
    try json.string(writer, test_node.package_name);
    try writer.writeAll(",\"name\":");
    try json.string(writer, test_node.name);
    if (test_node.unrendered_config == .object) {
        try writer.writeAll(",\"unrendered_config\":");
        try std.json.Stringify.value(test_node.unrendered_config, .{}, writer);
    } else try writeUnrenderedTestConfig(writer, test_node.config);
    try writer.writeAll(",\"alias\":");
    try json.string(writer, if (test_node.resolved_identity) |identity| identity.identifier else test_node.config.alias orelse test_node.alias);
    try writeTestNodeIdentityFields(allocator, writer, graph, test_node.package_name, test_node.path, test_node.name, null, test_node.config, if (test_node.fqn.items.len != 0) test_node.fqn.items else null, test_node.resolved_identity, test_node.alias);
    try writer.writeAll(",\"path\":");
    try json.string(writer, util.normalizeForDisplay(test_node.path));
    try writer.writeAll(",\"original_file_path\":");
    try json.string(writer, util.normalizeForDisplay(test_node.original_file_path));
    try writer.writeAll(",\"patch_path\":null,\"language\":\"sql\",\"raw_code\":");
    const raw_code = try genericTestRawCode(allocator, test_node);
    defer allocator.free(raw_code);
    try json.string(writer, raw_code);
    try writer.writeAll(",\"description\":");
    try json.string(writer, test_node.description);
    try writer.writeAll(",\"doc_blocks\":");
    try json.stringArray(writer, test_node.doc_blocks.items);
    try writer.writeAll(",\"tags\":");
    try json.stringArray(writer, test_node.tags.items);
    try writer.writeAll(",\"meta\":");
    try std.json.Stringify.value(@import("config_value.zig").get(test_node.config_values, "meta") orelse @as(std.json.Value, .{ .object = .empty }), .{}, writer);
    try writer.writeAll(",\"group\":");
    try writeNullableString(writer, @import("group_access.zig").genericGroup(graph, &test_node));
    try @import("test_provenance.zig").writeInherited(writer, test_node.config_values, test_node.created_at, test_node.build_path);
    if (!test_node.compiled) try writer.writeAll(",\"compiled_path\":null");
    try writer.writeAll(",\"file_key_name\":");
    const file_key = try @import("test_provenance.zig").fileKeyName(allocator, graph, &test_node);
    defer if (file_key) |key| allocator.free(key);
    try writeNullableString(writer, file_key);
    try writer.writeAll(",\"attached_node\":");
    if (test_node.attached_node) |attached_node| {
        try json.string(writer, attached_node);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"column_name\":");
    if (test_node.column_name) |column_name| {
        try json.string(writer, column_name);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"test_metadata\":{\"name\":");
    try json.string(writer, test_node.test_name);
    try writer.writeAll(",\"kwargs\":{\"model\":");
    const model_kwarg = if (test_node.unattached_model_kwarg) |kwarg| try allocator.dupe(u8, kwarg) else if (test_node.attached_node) |attached_node| blk: {
        for (graph.nodes.items) |*model| if (std.mem.eql(u8, model.unique_id, attached_node)) break :blk try @import("model_versions.zig").modelKwarg(allocator, model);
        const model_name = modelNameFromUniqueId(attached_node);
        break :blk try std.fmt.allocPrint(allocator, "{{{{ get_where_subquery(ref('{s}')) }}}}", .{model_name});
    } else blk: {
        const source_ref = test_node.attached_source orelse if (test_node.source_refs.items.len == 1) test_node.source_refs.items[0] else return error.UnsupportedManifest;
        break :blk try std.fmt.allocPrint(allocator, "{{{{ get_where_subquery(source('{s}', '{s}')) }}}}", .{ source_ref.source_name, source_ref.table_name });
    };
    defer allocator.free(model_kwarg);
    try json.string(writer, model_kwarg);
    if (argument_column_name) |column_name| {
        try writer.writeAll(",\"column_name\":");
        try json.string(writer, column_name);
    }
    if (test_node.arguments == .object) {
        var iterator = test_node.arguments.object.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "model") or std.mem.eql(u8, entry.key_ptr.*, "column_name")) continue;
            try writer.writeAll(",");
            try json.string(writer, entry.key_ptr.*);
            try writer.writeAll(":");
            try std.json.Stringify.value(entry.value_ptr.*, .{}, writer);
        }
    }
    if (test_node.arguments != .object and test_node.accepted_values.items.len != 0) {
        try writer.writeAll(",\"values\":");
        try json.stringArray(writer, test_node.accepted_values.items);
    }
    if (if (test_node.arguments == .object) null else test_node.accepted_values_quote) |quote| {
        try writer.writeAll(",\"quote\":");
        try writer.writeAll(if (quote) "true" else "false");
    }
    if (test_node.arguments != .object and test_node.relationship_to.len != 0) {
        try writer.writeAll(",\"to\":");
        try json.string(writer, test_node.relationship_to);
    }
    if (test_node.arguments != .object and test_node.relationship_field.len != 0) {
        try writer.writeAll(",\"field\":");
        try json.string(writer, test_node.relationship_field);
    }
    try writer.writeAll("},\"namespace\":");
    if (test_node.test_namespace) |namespace| {
        try json.string(writer, namespace);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("},\"config\":");
    var canonical_config = try @import("canonical_manifest_config.zig").testConfig(allocator, test_node.config, test_node.enabled, &.{}, test_node.config_values);
    defer @import("config_value.zig").deinit(allocator, &canonical_config);
    try std.json.Stringify.value(canonical_config, .{}, writer);
    try writer.writeAll(",\"depends_on\":{\"macros\":");
    try json.stringArray(writer, test_node.macro_depends_on.items);
    try writer.writeAll(",\"nodes\":");
    try json.stringArray(writer, test_node.depends_on.items);
    try writer.writeAll("},\"refs\":");
    try writeRefDeps(writer, test_node.refs.items);
    try writer.writeAll(",\"sources\":");
    try writeSourceDeps(writer, test_node.source_refs.items);
    if (test_node.compiled) {
        try writer.writeAll(",\"compiled\":true,\"compiled_code\":");
        try json.string(writer, test_node.compiled_code orelse "");
        try writer.writeAll(",\"compiled_path\":");
        try json.string(writer, util.normalizeForDisplay(test_node.compiled_path orelse ""));
        try writer.writeAll(",\"extra_ctes\":");
        try writeExtraCtes(writer, test_node.extra_ctes.items, graph.command_options.inject_ephemeral_ctes);
        try writer.writeAll(",\"extra_ctes_injected\":");
        try writer.writeAll(if (graph.command_options.inject_ephemeral_ctes) "true" else "false");
    }
    try writer.writeAll("}");
}

fn writeSingularTestNode(allocator: std.mem.Allocator, writer: *Io.Writer, graph: *const Graph, test_node: SingularTestNode) !void {
    try writer.writeAll("{\"unique_id\":");
    try json.string(writer, test_node.unique_id);
    try writer.writeAll(",\"resource_type\":\"test\",\"package_name\":");
    try json.string(writer, test_node.package_name);
    try writer.writeAll(",\"name\":");
    try json.string(writer, test_node.name);
    try writeUnrenderedTestConfigWithValues(writer, test_node.config, test_node.config_values);
    try writer.writeAll(",\"alias\":");
    try json.string(writer, if (test_node.resolved_identity) |identity| identity.identifier else test_node.config.alias orelse test_node.alias);
    try writeTestNodeIdentityFields(allocator, writer, graph, test_node.package_name, test_node.path, test_node.name, test_node.raw_code, test_node.config, null, test_node.resolved_identity, test_node.alias);
    try writer.writeAll(",\"path\":");
    try json.string(writer, util.normalizeForDisplay(test_node.path));
    try writer.writeAll(",\"original_file_path\":");
    try json.string(writer, util.normalizeForDisplay(test_node.original_file_path));
    try writer.writeAll(",\"patch_path\":");
    if (test_node.patch_path) |patch_path| {
        const dbt_patch_path = try std.fmt.allocPrint(allocator, "{s}://{s}", .{ test_node.package_name, util.normalizeForDisplay(patch_path) });
        defer allocator.free(dbt_patch_path);
        try json.string(writer, dbt_patch_path);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"language\":\"sql\",\"raw_code\":");
    try json.string(writer, test_node.raw_code);
    try writer.writeAll(",\"description\":");
    try json.string(writer, test_node.description);
    try writer.writeAll(",\"doc_blocks\":");
    try json.stringArray(writer, test_node.doc_blocks.items);
    try writer.writeAll(",\"tags\":");
    try json.stringArray(writer, test_node.tags.items);
    try writer.writeAll(",\"config\":");
    var canonical_config = try @import("canonical_manifest_config.zig").testConfig(allocator, test_node.config, test_node.enabled, test_node.tags.items, test_node.config_values);
    defer @import("config_value.zig").deinit(allocator, &canonical_config);
    try std.json.Stringify.value(canonical_config, .{}, writer);
    try @import("test_provenance.zig").writeInherited(writer, canonical_config, test_node.created_at, test_node.build_path);
    if (!test_node.compiled) try writer.writeAll(",\"compiled_path\":null");
    try writer.writeAll(",\"meta\":");
    try std.json.Stringify.value(@import("config_value.zig").get(canonical_config, "meta") orelse @as(std.json.Value, .{ .object = .empty }), .{}, writer);
    try writer.writeAll(",\"group\":");
    try std.json.Stringify.value(@import("config_value.zig").get(canonical_config, "group") orelse @as(std.json.Value, .null), .{}, writer);
    try writer.writeAll(",\"depends_on\":{\"macros\":");
    try json.stringArray(writer, test_node.macro_depends_on.items);
    try writer.writeAll(",\"nodes\":");
    try json.stringArray(writer, test_node.depends_on.items);
    try writer.writeAll("},\"refs\":");
    try writeRefDeps(writer, test_node.refs.items);
    try writer.writeAll(",\"sources\":");
    try writeSourceDeps(writer, test_node.source_refs.items);
    if (test_node.compiled) {
        try writer.writeAll(",\"compiled\":true,\"compiled_code\":");
        try json.string(writer, test_node.compiled_code orelse "");
        try writer.writeAll(",\"compiled_path\":");
        try json.string(writer, util.normalizeForDisplay(test_node.compiled_path orelse ""));
        try writer.writeAll(",\"extra_ctes\":");
        try writeExtraCtes(writer, test_node.extra_ctes.items, graph.command_options.inject_ephemeral_ctes);
        try writer.writeAll(",\"extra_ctes_injected\":");
        try writer.writeAll(if (graph.command_options.inject_ephemeral_ctes) "true" else "false");
    }
    try writer.writeAll("}");
}

fn genericTestRawCode(allocator: std.mem.Allocator, node: GenericTestNode) ![]const u8 {
    if (node.builder_config == .object or node.config.configured_order_len == 0) return try allocator.dupe(u8, node.raw_code);
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    const config_start = std.mem.indexOf(u8, node.raw_code, "{{ config(");
    try writer.writeAll(if (config_start) |index| node.raw_code[0..index] else node.raw_code);
    try writer.writeAll("{{ config(");
    for (node.config.configured_order[0..node.config.configured_order_len], 0..) |key, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll(@tagName(key));
        try writer.writeAll("=");
        switch (key) {
            .where => try writeGenericConfigString(writer, node.config.where orelse ""),
            .severity => try writeGenericConfigString(writer, node.config.severity),
            .warn_if => try writeGenericConfigString(writer, node.config.warn_if),
            .error_if => try writeGenericConfigString(writer, node.config.error_if),
            .limit => if (node.config.limit) |limit| try writer.print("{d}", .{limit}) else try writer.writeAll("None"),
            .store_failures => if (node.config.store_failures) |value| try writer.writeAll(if (value) "True" else "False") else try writer.writeAll("None"),
            .store_failures_as => if (node.config.store_failures_as) |value| try writeGenericConfigString(writer, value) else try writer.writeAll("None"),
            .schema => if (node.config.schema) |value| try writeGenericConfigString(writer, value) else try writer.writeAll("None"),
            .alias => if (node.config.alias) |value| try writeGenericConfigString(writer, value) else try writer.writeAll("None"),
            .database => if (node.config.database) |value| try writeGenericConfigString(writer, value) else try writer.writeAll("None"),
            .fail_calc => try writeGenericConfigString(writer, node.config.fail_calc),
        }
    }
    if (config_start) |start| {
        const args_start = start + "{{ config(".len;
        const args_end = std.mem.indexOfPos(u8, node.raw_code, args_start, ") }}") orelse return error.UnsupportedManifest;
        if (args_end > args_start) {
            try writer.writeAll(",");
            try writer.writeAll(node.raw_code[args_start..args_end]);
        }
    }
    try writer.writeAll(") }}");
    return try out.toOwnedSlice();
}

fn writeGenericConfigString(writer: *Io.Writer, value: []const u8) !void {
    try writer.writeAll("\"");
    for (value) |byte| {
        if (byte == '"') try writer.writeAll("\\");
        try writer.writeByte(byte);
    }
    try writer.writeAll("\"");
}

fn writeUnrenderedTestConfig(writer: *Io.Writer, config: types.GenericTestConfig) !void {
    return writeUnrenderedTestConfigWithValues(writer, config, .null);
}

fn writeUnrenderedTestConfigWithValues(writer: *Io.Writer, config: types.GenericTestConfig, extra: std.json.Value) !void {
    try writer.writeAll(",\"unrendered_config\":{");
    var wrote = false;
    inline for (std.meta.fields(types.GenericTestConfigField)) |field| {
        const key = @field(types.GenericTestConfigField, field.name);
        const non_default = switch (key) {
            .where => config.where != null,
            .limit => config.limit != null,
            .severity => !std.mem.eql(u8, config.severity, "ERROR"),
            .warn_if => !std.mem.eql(u8, config.warn_if, "!= 0"),
            .error_if => !std.mem.eql(u8, config.error_if, "!= 0"),
            .store_failures => config.store_failures != null,
            .store_failures_as => config.store_failures_as != null,
            .schema => config.schema != null,
            .alias => config.alias != null,
            .database => config.database != null,
            .fail_calc => !std.mem.eql(u8, config.fail_calc, "count(*)"),
        };
        if (config.configured.contains(key) or non_default) {
            if (wrote) try writer.writeAll(",");
            wrote = true;
            try json.string(writer, field.name);
            try writer.writeAll(":");
            switch (key) {
                .where => try writeNullableString(writer, config.where),
                .limit => if (config.limit) |limit| try writer.print("{d}", .{limit}) else try writer.writeAll("null"),
                .severity => try json.string(writer, config.severity),
                .warn_if => try json.string(writer, config.warn_if),
                .error_if => try json.string(writer, config.error_if),
                .store_failures => try writeNullableBool(writer, config.store_failures),
                .store_failures_as => try writeNullableString(writer, config.store_failures_as),
                .schema => try writeNullableString(writer, config.schema),
                .alias => try writeNullableString(writer, config.alias),
                .database => try writeNullableString(writer, config.database),
                .fail_calc => try json.string(writer, config.fail_calc),
            }
        }
    }
    if (extra == .object) for (extra.object.keys(), extra.object.values()) |key, value| {
        if (std.meta.stringToEnum(types.GenericTestConfigField, key) != null) continue;
        if (wrote) try writer.writeAll(",");
        wrote = true;
        try json.string(writer, key);
        try writer.writeAll(":");
        try std.json.Stringify.value(value, .{}, writer);
    };
    try writer.writeAll("}");
}

fn genericTestNodeColumnName(test_node: *const GenericTestNode) ?[]const u8 {
    return test_node.argument_column_name orelse test_node.column_name;
}

fn writeExposureDependsOnNodes(writer: *Io.Writer, values: []const []const u8) !void {
    try writer.writeAll("[");
    var first = true;
    for (values) |value| {
        if (!std.mem.startsWith(u8, value, "source.")) continue;
        if (!first) try writer.writeAll(",");
        first = false;
        try json.string(writer, value);
    }
    for (values) |value| {
        if (std.mem.startsWith(u8, value, "source.")) continue;
        if (!first) try writer.writeAll(",");
        first = false;
        try json.string(writer, value);
    }
    try writer.writeAll("]");
}

fn writeNullableString(writer: *Io.Writer, value: ?[]const u8) !void {
    try json.nullableString(writer, value);
}

fn writeNullableBool(writer: *Io.Writer, value: ?bool) !void {
    if (value) |flag| {
        try writer.writeAll(if (flag) "true" else "false");
    } else {
        try writer.writeAll("null");
    }
}

fn writeSourceFreshnessThreshold(writer: *Io.Writer, threshold: types.FreshnessThreshold) !void {
    try writer.writeAll("{\"warn_after\":");
    if (threshold.warn_after) |time| try writeFreshnessTime(writer, time) else try writer.writeAll("{\"count\":null,\"period\":null}");
    try writer.writeAll(",\"error_after\":");
    if (threshold.error_after) |time| try writeFreshnessTime(writer, time) else try writer.writeAll("{\"count\":null,\"period\":null}");
    try writer.writeAll(",\"filter\":");
    try writeNullableString(writer, threshold.filter);
    try writer.writeAll("}");
}

fn writeFreshnessTime(writer: *Io.Writer, value: ?types.FreshnessTime) !void {
    const time = value orelse {
        try writer.writeAll("null");
        return;
    };
    try writer.writeAll("{\"count\":");
    if (time.count) |count| {
        try writer.print("{d}", .{count});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"period\":");
    try writeNullableString(writer, time.period);
    try writer.writeAll("}");
}

fn writeMetaObject(writer: *Io.Writer, entries: []const MetaEntry) !void {
    try writer.writeAll("{");
    for (entries, 0..) |entry, index| {
        if (index != 0) try writer.writeAll(",");
        try json.string(writer, entry.key);
        try writer.writeAll(":");
        try writeJsonScalar(writer, entry.value);
    }
    try writer.writeAll("}");
}

fn writeDocsConfig(writer: *Io.Writer, docs: DocsConfig) !void {
    try writer.writeAll("{\"show\":");
    try json.boolValue(writer, docs.show);
    try writer.writeAll(",\"node_color\":");
    try writeNullableString(writer, docs.node_color);
    try writer.writeAll("}");
}

fn writeJsonScalar(writer: *Io.Writer, value: JsonScalar) !void {
    switch (value.kind) {
        .string => try json.string(writer, value.text),
        .number, .bool, .null, .json => try writer.writeAll(value.text),
    }
}

fn writeRefDeps(writer: *Io.Writer, refs: []const RefDep) !void {
    try writer.writeAll("[");
    for (refs, 0..) |ref_dep, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("{\"name\":");
        try json.string(writer, ref_dep.name);
        try writer.writeAll(",\"package\":");
        try writeNullableString(writer, ref_dep.package);
        try writer.writeAll(",\"version\":");
        try std.json.Stringify.value(ref_dep.version, .{}, writer);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeSourceDeps(writer: *Io.Writer, sources: []const SourceDep) !void {
    try writer.writeAll("[");
    for (sources, 0..) |source_dep, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("[");
        try json.string(writer, source_dep.source_name);
        try writer.writeAll(",");
        try json.string(writer, source_dep.table_name);
        try writer.writeAll("]");
    }
    try writer.writeAll("]");
}

fn writeMacroArguments(writer: *Io.Writer, arguments: []const MacroArgument) !void {
    try writer.writeAll("[");
    for (arguments, 0..) |argument, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("{\"name\":");
        try json.string(writer, argument.name);
        try writer.writeAll(",\"type\":");
        if (argument.type.len == 0 and !argument.has_type) {
            try writer.writeAll("null");
        } else {
            try json.string(writer, argument.type);
        }
        try writer.writeAll(",\"description\":");
        try json.string(writer, argument.description);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn modelNameFromUniqueId(unique_id: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, unique_id, '.')) |index| {
        return unique_id[index + 1 ..];
    }
    return unique_id;
}

fn renderSelectedJsonForTest(allocator: std.mem.Allocator, selected: []selector.SelectedResource) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeSelectedJson(&out.writer, selected);
    return try out.toOwnedSlice();
}

fn renderSelectedJsonWithKeysForTest(allocator: std.mem.Allocator, selected: []selector.SelectedResource, keys: []const []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeSelectedJsonWithKeys(&out.writer, selected, keys);
    return try out.toOwnedSlice();
}

fn renderJsonStringForTest(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try json.string(&out.writer, value);
    return try out.toOwnedSlice();
}

fn renderExposureDependsOnForTest(allocator: std.mem.Allocator, values: []const []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeExposureDependsOnNodes(&out.writer, values);
    return try out.toOwnedSlice();
}

test "selected resource JSON writer preserves order and shape" {
    var selected = [_]selector.SelectedResource{
        .{ .unique_id = "model.demo.customers", .resource_type = "model", .name = "customers" },
        .{ .unique_id = "source.demo.raw.customers", .resource_type = "source", .name = "customers" },
    };

    const rendered = try renderSelectedJsonForTest(std.testing.allocator, selected[0..]);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "[{\"unique_id\":\"model.demo.customers\",\"resource_type\":\"model\",\"name\":\"customers\"},{\"unique_id\":\"source.demo.raw.customers\",\"resource_type\":\"source\",\"name\":\"customers\"}]\n",
        rendered,
    );
}

test "selected resource JSON writer filters output keys in requested order" {
    var selected = [_]selector.SelectedResource{
        .{
            .unique_id = "model.demo.customers",
            .resource_type = "model",
            .name = "customers",
            .package_name = "demo",
            .path = "customers.sql",
            .original_file_path = "models/customers.sql",
            .selector = "demo.customers",
            .alias = "customer_facts",
            .config_materialized = "table",
            .config_tags = &.{ "finance", "nightly" },
            .has_config_tags = true,
            .config_enabled = true,
            .has_config_enabled = true,
            .config_docs_show = true,
            .has_config_docs_show = true,
            .depends_on_nodes = &.{ "source.demo.raw.customers", "model.demo.stg_customers" },
            .depends_on_macros = &.{"macro.demo.cents_to_dollars"},
            .has_depends_on = true,
        },
        .{
            .unique_id = "source.demo.raw.customers",
            .resource_type = "source",
            .name = "customers",
            .package_name = "demo",
            .source_name = "raw",
            .path = "models/schema.yml",
            .original_file_path = "models/schema.yml",
            .selector = "source:demo.raw.customers",
            .identifier = "raw_customers",
        },
        .{
            .unique_id = "model.demo.orders",
            .resource_type = "model",
            .name = "orders",
            .package_name = "demo",
            .path = "orders.sql",
            .original_file_path = "models/orders.sql",
            .selector = "demo.orders",
            .config_materialized = "view",
            .has_config_tags = true,
            .config_enabled = true,
            .has_config_enabled = true,
            .config_docs_show = false,
            .has_config_docs_show = true,
            .depends_on_nodes = &.{},
            .depends_on_macros = &.{},
            .has_depends_on = true,
        },
    };
    const keys = [_][]const u8{ "name", "package_name", "source_name", "alias", "identifier", "tags", "config.materialized", "config.tags", "config.enabled", "config.docs.show", "depends_on.nodes", "depends_on.macros", "missing", "path", "original_file_path", "selector", "unique_id", "name" };

    const rendered = try renderSelectedJsonWithKeysForTest(std.testing.allocator, selected[0..], keys[0..]);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "[{\"name\":\"customers\",\"package_name\":\"demo\",\"alias\":\"customer_facts\",\"tags\":[\"finance\",\"nightly\"],\"config.materialized\":\"table\",\"config.tags\":[\"finance\",\"nightly\"],\"config.enabled\":true,\"config.docs.show\":true,\"depends_on.nodes\":[\"source.demo.raw.customers\",\"model.demo.stg_customers\"],\"depends_on.macros\":[\"macro.demo.cents_to_dollars\"],\"path\":\"customers.sql\",\"original_file_path\":\"models/customers.sql\",\"selector\":\"demo.customers\",\"unique_id\":\"model.demo.customers\"},{\"name\":\"customers\",\"package_name\":\"demo\",\"source_name\":\"raw\",\"identifier\":\"raw_customers\",\"path\":\"models/schema.yml\",\"original_file_path\":\"models/schema.yml\",\"selector\":\"source:demo.raw.customers\",\"unique_id\":\"source.demo.raw.customers\"},{\"name\":\"orders\",\"package_name\":\"demo\",\"tags\":[],\"config.materialized\":\"view\",\"config.tags\":[],\"config.enabled\":true,\"config.docs.show\":false,\"depends_on.nodes\":[],\"depends_on.macros\":[],\"path\":\"orders.sql\",\"original_file_path\":\"models/orders.sql\",\"selector\":\"demo.orders\",\"unique_id\":\"model.demo.orders\"}]\n",
        rendered,
    );
}

test "JSON string writer escapes special characters" {
    const rendered = try renderJsonStringForTest(std.testing.allocator, "quote\" slash\\ line\n");
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings("\"quote\\\" slash\\\\ line\\n\"", rendered);
}

test "exposure dependency writer emits sources before other nodes" {
    const values = [_][]const u8{
        "model.demo.orders",
        "source.demo.raw.customers",
        "model.demo.customers",
    };

    const rendered = try renderExposureDependsOnForTest(std.testing.allocator, &values);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "[\"source.demo.raw.customers\",\"model.demo.orders\",\"model.demo.customers\"]",
        rendered,
    );
}

test "manifest writer emits model extra_ctes and injection flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select * from {{ ref('ephemeral_orders') }}",
        .materialized = "table",
        .compiled = true,
        .compiled_code = "with __dbt__cte__ephemeral_orders as (\nselect 1 as order_id\n)\nselect * from __dbt__cte__ephemeral_orders",
        .compiled_path = "target/compiled/demo/models/orders.sql",
        .relation_name = "\"main\".\"orders\"",
    });
    try graph.nodes.items[0].extra_ctes.append(allocator, .{
        .id = "model.demo.ephemeral_orders",
        .sql = try allocator.dupe(u8, "__dbt__cte__ephemeral_orders as (\nselect 1 as order_id\n)"),
    });

    const rendered = try renderManifest(allocator, &graph);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const node = parsed.value.object.get("nodes").?.object.get("model.demo.orders").?.object;
    try std.testing.expect(node.get("extra_ctes_injected").?.bool);
    const extra_ctes = node.get("extra_ctes").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), extra_ctes.len);
    try std.testing.expectEqualStrings("model.demo.ephemeral_orders", extra_ctes[0].object.get("id").?.string);
    try std.testing.expectEqualStrings("__dbt__cte__ephemeral_orders as (\nselect 1 as order_id\n)", extra_ctes[0].object.get("sql").?.string);
}

test "manifest writer emits node identity fields and deterministic checksums" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{
        .allocator = allocator,
        .project_name = "demo",
        .target_schema = "analytics",
        .database_path = "warehouse.duckdb",
    };
    defer graph.deinit();

    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "marts/orders.sql",
        .original_file_path = "models/marts/orders.sql",
        .raw_code = "select * from {{ ref('customers') }}\n",
        .config_schema = "mart",
        .config_alias = "order_facts",
    });
    try graph.nodes.append(allocator, .{
        .resource_type = "analysis",
        .package_name = "demo",
        .unique_id = "analysis.demo.customer_report",
        .name = "customer_report",
        .path = "analysis/customer_report.sql",
        .original_file_path = "analyses/customer_report.sql",
        .raw_code = "select 1\n",
        .materialized = "analysis",
    });
    try graph.nodes.append(allocator, .{
        .resource_type = "seed",
        .package_name = "demo",
        .unique_id = "seed.demo.raw_customers",
        .name = "raw_customers",
        .path = "raw_customers.csv",
        .original_file_path = "seeds/raw_customers.csv",
        .raw_code = "id,name\n1,Ada\n",
        .materialized = "seed",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.not_null_orders_order_id.abc",
        .name = "not_null_orders_order_id",
        .alias = "not_null_orders_order_id",
        .path = "not_null_orders_order_id.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_not_null(**_dbt_generic_test_kwargs) }}",
        .test_name = "not_null",
        .column_name = "order_id",
        .attached_node = "model.demo.orders",
    });
    try graph.singular_tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.assert_orders",
        .name = "assert_orders",
        .alias = "assert_orders",
        .path = "assert_orders.sql",
        .original_file_path = "tests/assert_orders.sql",
        .raw_code = "select * from {{ ref('orders') }} where order_id is null\n",
    });

    const rendered = try renderManifest(std.testing.allocator, &graph);
    defer std.testing.allocator.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();

    const nodes = parsed.value.object.get("nodes").?.object;
    const model = nodes.get("model.demo.orders").?.object;
    try std.testing.expectEqualStrings("warehouse", model.get("database").?.string);
    try std.testing.expectEqualStrings("analytics_mart", model.get("schema").?.string);
    try std.testing.expectEqualStrings("order_facts", model.get("alias").?.string);
    try std.testing.expectEqualStrings("demo", model.get("fqn").?.array.items[0].string);
    try std.testing.expectEqualStrings("marts", model.get("fqn").?.array.items[1].string);
    try std.testing.expectEqualStrings("orders", model.get("fqn").?.array.items[2].string);
    try std.testing.expectEqualStrings("sha256", model.get("checksum").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("85302a290e52a84ebe6d9b408ba8819fbc322fa5dc12e18b05b36e84c61964e1", model.get("checksum").?.object.get("checksum").?.string);

    const analysis = nodes.get("analysis.demo.customer_report").?.object;
    try std.testing.expectEqualStrings("analytics", analysis.get("schema").?.string);
    try std.testing.expectEqualStrings("customer_report", analysis.get("alias").?.string);
    try std.testing.expectEqualStrings("analysis", analysis.get("fqn").?.array.items[1].string);
    try std.testing.expectEqualStrings("customer_report", analysis.get("fqn").?.array.items[2].string);

    const seed = nodes.get("seed.demo.raw_customers").?.object;
    try std.testing.expectEqualStrings("raw_customers", seed.get("alias").?.string);
    try std.testing.expect(!seed.contains("compiled_path"));
    try std.testing.expectEqualStrings("55c71c9b41468b359a456098ac08d1c1680c00793c36fe8d0bab95ff678e6921", seed.get("checksum").?.object.get("checksum").?.string);

    const generic_test = nodes.get("test.demo.not_null_orders_order_id.abc").?.object;
    try std.testing.expectEqualStrings("analytics_dbt_test__audit", generic_test.get("schema").?.string);
    try std.testing.expectEqualStrings("none", generic_test.get("checksum").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("", generic_test.get("checksum").?.object.get("checksum").?.string);

    const singular_test = nodes.get("test.demo.assert_orders").?.object;
    try std.testing.expectEqualStrings("analytics_dbt_test__audit", singular_test.get("schema").?.string);
    try std.testing.expectEqualStrings("assert_orders", singular_test.get("fqn").?.array.items[1].string);
    try std.testing.expectEqualStrings("8bdadb531b4ad2aadfba0bb1503616889457b490daec830109910b2994536962", singular_test.get("checksum").?.object.get("checksum").?.string);
}

test "manifest writer emits source generic tests with null attached node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.sources.append(allocator, .{
        .package_name = "demo",
        .unique_id = "source.demo.raw.customers",
        .source_name = "raw",
        .table_name = "customers",
        .identifier = "raw_customers",
        .database = "raw_db",
        .original_file_path = "models/schema.yml",
        .schema_name = "analytics_raw",
        .quoting = .{ .database = false, .schema = true, .identifier = true },
        .loaded_at_field = "loaded_at",
        .freshness = .{
            .warn_after = .{ .count = 12, .period = "hour" },
            .error_after = .{ .count = 1, .period = "day" },
            .filter = "customer_id > 0",
        },
    });
    try graph.sources.items[0].columns.append(allocator, .{
        .name = "customer_id",
        .description = "Customer identifier.",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.source_not_null_raw_customers_customer_id.abc",
        .name = "source_not_null_raw_customers_customer_id",
        .alias = "source_not_null_raw_customers_customer_id",
        .path = "source_not_null_raw_customers_customer_id.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_not_null(**_dbt_generic_test_kwargs) }}",
        .test_name = "not_null",
        .column_name = "customer_id",
        .compiled = true,
        .compiled_code = "select \"customer_id\" from \"analytics_raw\".\"raw_customers\" where \"customer_id\" is null",
        .compiled_path = "target/compiled/demo/source_not_null_raw_customers_customer_id.sql",
    });
    try graph.tests.items[0].source_refs.append(allocator, .{ .source_name = "raw", .table_name = "customers" });
    try graph.tests.items[0].depends_on.append(allocator, "source.demo.raw.customers");
    try graph.tests.items[0].macro_depends_on.append(allocator, "macro.dbt.test_not_null");

    const rendered = try renderManifest(std.testing.allocator, &graph);
    defer std.testing.allocator.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const source_node = root.get("sources").?.object.get("source.demo.raw.customers").?.object;
    try std.testing.expectEqualStrings("raw_db", source_node.get("database").?.string);
    try std.testing.expectEqualStrings("analytics_raw", source_node.get("schema").?.string);
    try std.testing.expectEqualStrings("raw_customers", source_node.get("identifier").?.string);
    try std.testing.expectEqualStrings("raw_db.\"analytics_raw\".\"raw_customers\"", source_node.get("relation_name").?.string);
    const source_quoting = source_node.get("quoting").?.object;
    try std.testing.expectEqual(false, source_quoting.get("database").?.bool);
    try std.testing.expectEqual(true, source_quoting.get("schema").?.bool);
    try std.testing.expectEqual(true, source_quoting.get("identifier").?.bool);
    try std.testing.expect(source_quoting.get("column").? == .null);
    try std.testing.expectEqualStrings("loaded_at", source_node.get("loaded_at_field").?.string);
    try std.testing.expect(source_node.get("loaded_at_query").? == .null);
    const freshness = source_node.get("freshness").?.object;
    try std.testing.expectEqual(@as(i64, 12), freshness.get("warn_after").?.object.get("count").?.integer);
    try std.testing.expectEqualStrings("hour", freshness.get("warn_after").?.object.get("period").?.string);
    try std.testing.expectEqual(@as(i64, 1), freshness.get("error_after").?.object.get("count").?.integer);
    try std.testing.expectEqualStrings("customer_id > 0", freshness.get("filter").?.string);
    const source_config = source_node.get("config").?.object;
    try std.testing.expect(source_config.get("enabled").?.bool);
    try std.testing.expectEqualStrings("loaded_at", source_config.get("loaded_at_field").?.string);
    const source_columns = source_node.get("columns").?.object;
    const source_column = source_columns.get("customer_id").?.object;
    try std.testing.expectEqualStrings("customer_id", source_column.get("name").?.string);
    try std.testing.expectEqualStrings("Customer identifier.", source_column.get("description").?.string);
    const test_node = root.get("nodes").?.object.get("test.demo.source_not_null_raw_customers_customer_id.abc").?.object;
    try std.testing.expect(test_node.get("attached_node").? == .null);
    const test_metadata = test_node.get("test_metadata").?.object;
    const kwargs = test_metadata.get("kwargs").?.object;
    try std.testing.expectEqualStrings("not_null", test_metadata.get("name").?.string);
    try std.testing.expectEqualStrings("{{ get_where_subquery(source('raw', 'customers')) }}", kwargs.get("model").?.string);
    try std.testing.expectEqualStrings("customer_id", kwargs.get("column_name").?.string);
    try std.testing.expect(test_node.get("compiled").?.bool);
    try std.testing.expectEqualStrings(
        "select \"customer_id\" from \"analytics_raw\".\"raw_customers\" where \"customer_id\" is null",
        test_node.get("compiled_code").?.string,
    );
    try std.testing.expectEqualStrings(
        "target/compiled/demo/source_not_null_raw_customers_customer_id.sql",
        test_node.get("compiled_path").?.string,
    );
    try std.testing.expectEqual(@as(usize, 0), test_node.get("extra_ctes").?.array.items.len);
    try std.testing.expect(test_node.get("extra_ctes_injected").?.bool);
    const sources = test_node.get("sources").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), sources.len);
    try std.testing.expectEqualStrings("raw", sources[0].array.items[0].string);
    try std.testing.expectEqualStrings("customers", sources[0].array.items[1].string);
    const parent_map = root.get("parent_map").?.object;
    try std.testing.expectEqualStrings(
        "source.demo.raw.customers",
        parent_map.get("test.demo.source_not_null_raw_customers_customer_id.abc").?.array.items[0].string,
    );
    const child_map = root.get("child_map").?.object;
    try std.testing.expectEqualStrings(
        "test.demo.source_not_null_raw_customers_customer_id.abc",
        child_map.get("source.demo.raw.customers").?.array.items[0].string,
    );
}

test "manifest writer emits source relationship tests with source and ref deps" {
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
        .raw_code = "select 1 as customer_id",
    });
    try graph.sources.append(allocator, .{
        .package_name = "demo",
        .unique_id = "source.demo.raw.orders",
        .source_name = "raw",
        .table_name = "orders",
        .identifier = "raw_orders",
        .original_file_path = "models/schema.yml",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.source_relationships_raw_orders_customer_id__customer_id__ref_customers_.abc",
        .name = "source_relationships_raw_orders_customer_id__customer_id__ref_customers_",
        .alias = "source_relationships_raw_orders_customer_id__customer_id__ref_customers_",
        .path = "source_relationships_raw_orders_customer_id__customer_id__ref_customers_.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_relationships(**_dbt_generic_test_kwargs) }}",
        .test_name = "relationships",
        .column_name = "customer_id",
        .relationship_to = "ref('customers')",
        .relationship_field = "customer_id",
    });
    try graph.tests.items[0].refs.append(allocator, .{ .package = null, .name = "customers" });
    try graph.tests.items[0].source_refs.append(allocator, .{ .source_name = "raw", .table_name = "orders" });
    try graph.tests.items[0].depends_on.append(allocator, "source.demo.raw.orders");
    try graph.tests.items[0].depends_on.append(allocator, "model.demo.customers");
    try graph.tests.items[0].macro_depends_on.append(allocator, "macro.dbt.test_relationships");
    try graph.tests.items[0].macro_depends_on.append(allocator, "macro.dbt.get_where_subquery");

    const rendered = try renderManifest(std.testing.allocator, &graph);
    defer std.testing.allocator.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const test_node = root.get("nodes").?.object.get("test.demo.source_relationships_raw_orders_customer_id__customer_id__ref_customers_.abc").?.object;
    try std.testing.expect(test_node.get("attached_node").? == .null);
    const refs = test_node.get("refs").?.array.items;
    try std.testing.expectEqualStrings("customers", refs[0].object.get("name").?.string);
    const sources = test_node.get("sources").?.array.items;
    try std.testing.expectEqualStrings("raw", sources[0].array.items[0].string);
    try std.testing.expectEqualStrings("orders", sources[0].array.items[1].string);
    const depends_on_nodes = test_node.get("depends_on").?.object.get("nodes").?.array.items;
    try std.testing.expectEqualStrings("source.demo.raw.orders", depends_on_nodes[0].string);
    try std.testing.expectEqualStrings("model.demo.customers", depends_on_nodes[1].string);
    const kwargs = test_node.get("test_metadata").?.object.get("kwargs").?.object;
    try std.testing.expectEqualStrings("{{ get_where_subquery(source('raw', 'orders')) }}", kwargs.get("model").?.string);
    try std.testing.expectEqualStrings("customer_id", kwargs.get("column_name").?.string);
    try std.testing.expectEqualStrings("ref('customers')", kwargs.get("to").?.string);
    try std.testing.expectEqualStrings("customer_id", kwargs.get("field").?.string);
}

test "manifest writer emits generic test config overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.not_null_customers_customer_id.abc",
        .name = "not_null_customers_customer_id",
        .alias = "not_null_customers_customer_id",
        .path = "not_null_customers_customer_id.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_not_null(**_dbt_generic_test_kwargs) }}",
        .test_name = "not_null",
        .column_name = "customer_id",
        .attached_node = "model.demo.customers",
        .config = .{
            .where = "customer_id > 0",
            .limit = 2,
            .severity = "warn",
            .warn_if = "> 0",
            .error_if = "> 10",
            .store_failures = true,
        },
    });
    try graph.tests.items[0].macro_depends_on.append(allocator, "macro.dbt.test_not_null");
    try graph.tests.items[0].depends_on.append(allocator, "model.demo.customers");
    try graph.tests.items[0].refs.append(allocator, .{ .package = null, .name = "customers" });

    const rendered = try renderManifest(std.testing.allocator, &graph);
    defer std.testing.allocator.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();

    const config = parsed.value.object.get("nodes").?.object.get("test.demo.not_null_customers_customer_id.abc").?.object.get("config").?.object;
    try std.testing.expectEqualStrings("warn", config.get("severity").?.string);
    try std.testing.expectEqualStrings("> 0", config.get("warn_if").?.string);
    try std.testing.expectEqualStrings("> 10", config.get("error_if").?.string);
    try std.testing.expectEqualStrings("customer_id > 0", config.get("where").?.string);
    try std.testing.expectEqual(@as(i64, 2), config.get("limit").?.integer);
    try std.testing.expect(config.get("store_failures").?.bool);
}

test "manifest writer emits source relationship tests with source target deps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.sources.append(allocator, .{
        .package_name = "demo",
        .unique_id = "source.demo.raw.orders",
        .source_name = "raw",
        .table_name = "orders",
        .identifier = "raw_orders",
        .original_file_path = "models/schema.yml",
    });
    try graph.sources.append(allocator, .{
        .package_name = "demo",
        .unique_id = "source.demo.raw.customers",
        .source_name = "raw",
        .table_name = "customers",
        .identifier = "raw_customers",
        .original_file_path = "models/schema.yml",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.source_relationships_raw_orders_customer_id__customer_id__source_raw_customers_.abc",
        .name = "source_relationships_raw_orders_customer_id__customer_id__source_raw_customers_",
        .alias = "source_relationships_raw_orders_customer_id__customer_id__source_raw_customers_",
        .path = "source_relationships_raw_orders_customer_id__customer_id__source_raw_customers_.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_relationships(**_dbt_generic_test_kwargs) }}",
        .test_name = "relationships",
        .column_name = "customer_id",
        .relationship_to = "source('raw', 'customers')",
        .relationship_field = "customer_id",
        .attached_source = .{ .source_name = "raw", .table_name = "orders" },
        .relationship_source_to = .{ .source_name = "raw", .table_name = "customers" },
    });
    try graph.tests.items[0].source_refs.append(allocator, .{ .source_name = "raw", .table_name = "customers" });
    try graph.tests.items[0].source_refs.append(allocator, .{ .source_name = "raw", .table_name = "orders" });
    try graph.tests.items[0].depends_on.append(allocator, "source.demo.raw.customers");
    try graph.tests.items[0].depends_on.append(allocator, "source.demo.raw.orders");
    try graph.tests.items[0].macro_depends_on.append(allocator, "macro.dbt.test_relationships");
    try graph.tests.items[0].macro_depends_on.append(allocator, "macro.dbt.get_where_subquery");

    const rendered = try renderManifest(std.testing.allocator, &graph);
    defer std.testing.allocator.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const test_node = root.get("nodes").?.object.get("test.demo.source_relationships_raw_orders_customer_id__customer_id__source_raw_customers_.abc").?.object;
    try std.testing.expect(test_node.get("attached_node").? == .null);
    try std.testing.expectEqual(@as(usize, 0), test_node.get("refs").?.array.items.len);
    const sources = test_node.get("sources").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), sources.len);
    try std.testing.expectEqualStrings("raw", sources[0].array.items[0].string);
    try std.testing.expectEqualStrings("customers", sources[0].array.items[1].string);
    try std.testing.expectEqualStrings("raw", sources[1].array.items[0].string);
    try std.testing.expectEqualStrings("orders", sources[1].array.items[1].string);
    const depends_on_nodes = test_node.get("depends_on").?.object.get("nodes").?.array.items;
    try std.testing.expectEqualStrings("source.demo.raw.customers", depends_on_nodes[0].string);
    try std.testing.expectEqualStrings("source.demo.raw.orders", depends_on_nodes[1].string);
    const kwargs = test_node.get("test_metadata").?.object.get("kwargs").?.object;
    try std.testing.expectEqualStrings("{{ get_where_subquery(source('raw', 'orders')) }}", kwargs.get("model").?.string);
    try std.testing.expectEqualStrings("customer_id", kwargs.get("column_name").?.string);
    try std.testing.expectEqualStrings("source('raw', 'customers')", kwargs.get("to").?.string);
    try std.testing.expectEqualStrings("customer_id", kwargs.get("field").?.string);
}

test "manifest writer emits singular tests without generic-only fields" {
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
        .raw_code = "select 1 as customer_id",
    });
    try graph.singular_tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.assert_customers",
        .name = "assert_customers",
        .alias = "assert_customers",
        .path = "assert_customers.sql",
        .original_file_path = "tests/assert_customers.sql",
        .patch_path = "tests/schema.yml",
        .raw_code = "select * from {{ ref('customers') }} where customer_id is null",
        .description = "patched singular test",
        .config = .{
            .where = "status = 'checked'",
            .limit = 1,
            .severity = "Warn",
            .warn_if = "> 0",
            .error_if = "> 10",
            .store_failures = true,
        },
        .compiled = true,
        .compiled_code = "select * from \"main\".\"customers\" where customer_id is null",
        .compiled_path = "target/compiled/demo/tests/assert_customers.sql",
    });
    try graph.singular_tests.items[0].tags.append(allocator, "singular");
    try graph.singular_tests.items[0].refs.append(allocator, .{ .package = null, .name = "customers" });
    try graph.singular_tests.items[0].depends_on.append(allocator, "model.demo.customers");

    const rendered = try renderManifest(std.testing.allocator, &graph);
    defer std.testing.allocator.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const test_node = root.get("nodes").?.object.get("test.demo.assert_customers").?.object;
    try std.testing.expectEqualStrings("test", test_node.get("resource_type").?.string);
    try std.testing.expectEqualStrings("assert_customers", test_node.get("name").?.string);
    try std.testing.expectEqualStrings("demo://tests/schema.yml", test_node.get("patch_path").?.string);
    try std.testing.expectEqualStrings("patched singular test", test_node.get("description").?.string);
    try std.testing.expectEqualStrings("singular", test_node.get("tags").?.array.items[0].string);
    const config = test_node.get("config").?.object;
    try std.testing.expectEqualStrings("Warn", config.get("severity").?.string);
    try std.testing.expectEqualStrings("> 0", config.get("warn_if").?.string);
    try std.testing.expectEqualStrings("> 10", config.get("error_if").?.string);
    try std.testing.expectEqualStrings("status = 'checked'", config.get("where").?.string);
    try std.testing.expectEqual(@as(i64, 1), config.get("limit").?.integer);
    try std.testing.expect(config.get("store_failures").?.bool);
    try std.testing.expectEqualStrings("singular", config.get("tags").?.array.items[0].string);
    try std.testing.expect(test_node.get("test_metadata") == null);
    try std.testing.expect(test_node.get("column_name") == null);
    try std.testing.expect(test_node.get("attached_node") == null);
    try std.testing.expect(test_node.get("compiled").?.bool);
    try std.testing.expectEqualStrings(
        "select * from \"main\".\"customers\" where customer_id is null",
        test_node.get("compiled_code").?.string,
    );
    try std.testing.expectEqualStrings(
        "target/compiled/demo/tests/assert_customers.sql",
        test_node.get("compiled_path").?.string,
    );
    try std.testing.expectEqual(@as(usize, 0), test_node.get("extra_ctes").?.array.items.len);
    try std.testing.expect(test_node.get("extra_ctes_injected").?.bool);
    try std.testing.expectEqualStrings("customers", test_node.get("refs").?.array.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings(
        "model.demo.customers",
        root.get("parent_map").?.object.get("test.demo.assert_customers").?.array.items[0].string,
    );
    try std.testing.expectEqualStrings(
        "test.demo.assert_customers",
        root.get("child_map").?.object.get("model.demo.customers").?.array.items[0].string,
    );
}

test "manifest writer keeps table-level explicit column tests detached from top-level column" {
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
        .raw_code = "select 1 as customer_id",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.not_null_customers_customer_id.abc",
        .name = "not_null_customers_customer_id",
        .alias = "not_null_customers_customer_id",
        .path = "not_null_customers_customer_id.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_not_null(**_dbt_generic_test_kwargs) }}",
        .test_name = "not_null",
        .argument_column_name = "customer_id",
        .attached_node = "model.demo.customers",
    });
    try graph.tests.items[0].refs.append(allocator, .{ .package = null, .name = "customers" });
    try graph.tests.items[0].depends_on.append(allocator, "model.demo.customers");
    try graph.tests.items[0].macro_depends_on.append(allocator, "macro.dbt.test_not_null");

    const rendered = try renderManifest(std.testing.allocator, &graph);
    defer std.testing.allocator.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();

    const test_node = parsed.value.object.get("nodes").?.object.get("test.demo.not_null_customers_customer_id.abc").?.object;
    try std.testing.expect(test_node.get("column_name").? == .null);
    const kwargs = test_node.get("test_metadata").?.object.get("kwargs").?.object;
    try std.testing.expectEqualStrings("customer_id", kwargs.get("column_name").?.string);
}

test "manifest writer emits deterministic v12 metadata fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo \"warehouse\"", .adapter_type = "duck\\db" };
    defer graph.deinit();

    const rendered = try renderManifest(std.testing.allocator, &graph);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "demo \\\"warehouse\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "duck\\\\db") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();
    const metadata = parsed.value.object.get("metadata").?.object;
    try std.testing.expectEqualStrings(manifest_schema_version, metadata.get("dbt_schema_version").?.string);
    try std.testing.expectEqualStrings(deterministic_dbt_version, metadata.get("dbt_version").?.string);
    try std.testing.expectEqualStrings(deterministic_generated_at, metadata.get("generated_at").?.string);
    try std.testing.expect(metadata.get("invocation_id").? == .null);
    try std.testing.expect(metadata.get("invocation_started_at").? == .null);
    try std.testing.expectEqual(@as(usize, 0), metadata.get("env").?.object.count());
    try std.testing.expectEqualStrings("demo \"warehouse\"", metadata.get("project_name").?.string);
    try std.testing.expectEqualStrings("duck\\db", metadata.get("adapter_type").?.string);
}

test "manifest writer filters disabled resources and writes graph maps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.sources.append(allocator, .{
        .package_name = "demo",
        .unique_id = "source.demo.raw.customers",
        .source_name = "raw",
        .table_name = "customers",
        .original_file_path = "models/schema.yml",
    });
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select \"customer_id\" from {{ source('raw', 'customers') }}",
        .description = "Customer \"model\"",
    });
    try graph.nodes.items[0].depends_on.append(allocator, "source.demo.raw.customers");
    try graph.nodes.items[0].source_refs.append(allocator, .{ .source_name = "raw", .table_name = "customers" });
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.disabled",
        .name = "disabled",
        .path = "disabled.sql",
        .original_file_path = "models/disabled.sql",
        .raw_code = "select 1",
        .enabled = false,
    });
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
    try graph.singular_tests.items[0].depends_on.append(allocator, "model.demo.customers");
    try graph.exposures.append(allocator, .{
        .package_name = "demo",
        .unique_id = "exposure.demo.weekly_kpis",
        .name = "weekly_kpis",
        .exposure_type = "dashboard",
        .path = "schema.yml",
        .original_file_path = "models/schema.yml",
        .owner_name = "Analytics",
    });
    try graph.exposures.items[0].depends_on.append(allocator, "model.demo.customers");
    try graph.exposures.items[0].depends_on.append(allocator, "source.demo.raw.customers");
    try graph.unit_tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "unit_test.demo.customers.assert_customers",
        .name = "assert_customers",
        .model = "customers",
        .path = "schema.yml",
        .original_file_path = "models/schema.yml",
        .description = "Customer unit test",
    });
    try graph.unit_tests.items[0].given.append(allocator, .{ .input = "ref('customers')" });
    try graph.unit_tests.items[0].expect.rows.append(allocator, .{});
    graph.unit_tests.items[0].expect.rows_set = true;
    try graph.unit_tests.items[0].depends_on.append(allocator, "model.demo.customers");
    try graph.exposures.append(allocator, .{
        .package_name = "demo",
        .unique_id = "exposure.demo.hidden",
        .name = "hidden",
        .path = "schema.yml",
        .original_file_path = "models/schema.yml",
        .enabled = false,
    });

    const rendered = try renderManifest(std.testing.allocator, &graph);
    defer std.testing.allocator.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const metadata = root.get("metadata").?.object;
    try std.testing.expectEqualStrings("duckdb", metadata.get("adapter_type").?.string);

    const nodes = root.get("nodes").?.object;
    try std.testing.expect(nodes.get("model.demo.customers") != null);
    try std.testing.expect(nodes.get("model.demo.disabled") == null);
    try std.testing.expect(nodes.get("test.demo.disabled_assert_customers") == null);

    const disabled = root.get("disabled").?.object;
    try std.testing.expect(disabled.get("model.demo.disabled") != null);
    const disabled_test = disabled.get("test.demo.disabled_assert_customers").?.array.items[0].object;
    try std.testing.expect(!disabled_test.get("config").?.object.get("enabled").?.bool);

    const exposures = root.get("exposures").?.object;
    try std.testing.expect(exposures.get("exposure.demo.weekly_kpis") != null);
    try std.testing.expect(exposures.get("exposure.demo.hidden") == null);
    const exposure = exposures.get("exposure.demo.weekly_kpis").?.object;
    const exposure_depends_on = exposure.get("depends_on").?.object;
    const exposure_depends_on_nodes = exposure_depends_on.get("nodes").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), exposure_depends_on_nodes.len);
    try std.testing.expectEqualStrings("source.demo.raw.customers", exposure_depends_on_nodes[0].string);
    try std.testing.expectEqualStrings("model.demo.customers", exposure_depends_on_nodes[1].string);
    const unit_tests = root.get("unit_tests").?.object;
    const unit_test = unit_tests.get("unit_test.demo.customers.assert_customers").?.object;
    try std.testing.expectEqualStrings("unit_test", unit_test.get("resource_type").?.string);
    try std.testing.expectEqualStrings("customers", unit_test.get("model").?.string);
    try std.testing.expectEqualStrings("Customer unit test", unit_test.get("description").?.string);
    try std.testing.expectEqualStrings("ref('customers')", unit_test.get("given").?.array.items[0].object.get("input").?.string);

    const parent_map = root.get("parent_map").?.object;
    const model_parents = parent_map.get("model.demo.customers").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), model_parents.len);
    try std.testing.expectEqualStrings("source.demo.raw.customers", model_parents[0].string);
    const exposure_parents = parent_map.get("exposure.demo.weekly_kpis").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), exposure_parents.len);
    try std.testing.expectEqualStrings("model.demo.customers", exposure_parents[0].string);
    try std.testing.expectEqualStrings("source.demo.raw.customers", exposure_parents[1].string);
    const unit_test_parents = parent_map.get("unit_test.demo.customers.assert_customers").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), unit_test_parents.len);
    try std.testing.expectEqualStrings("model.demo.customers", unit_test_parents[0].string);
    try std.testing.expect(parent_map.get("exposure.demo.hidden") == null);
    try std.testing.expect(parent_map.get("test.demo.disabled_assert_customers") == null);

    const child_map = root.get("child_map").?.object;
    const source_children = child_map.get("source.demo.raw.customers").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), source_children.len);
    try std.testing.expectEqualStrings("exposure.demo.weekly_kpis", source_children[0].string);
    try std.testing.expectEqualStrings("model.demo.customers", source_children[1].string);
    const model_children = child_map.get("model.demo.customers").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), model_children.len);
    try std.testing.expectEqualStrings("exposure.demo.weekly_kpis", model_children[0].string);
    try std.testing.expectEqualStrings("unit_test.demo.customers.assert_customers", model_children[1].string);
    try std.testing.expect(child_map.get("model.demo.disabled") == null);
    try std.testing.expect(child_map.get("test.demo.disabled_assert_customers") == null);
    try std.testing.expect(child_map.get("exposure.demo.hidden") == null);
}

fn writeSnapshotColumns(writer: *Io.Writer, columns: ?types.SnapshotColumns) !void {
    if (columns) |value| {
        switch (value) {
            .string => |text| try json.string(writer, text),
            .list => |list| try json.stringArray(writer, list.items),
        }
    } else try writer.writeAll("null");
}

test "snapshot manifest identity retains file checksum and block FQN" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    const sql = " \x0b\n{% snapshot history %}\n{{ config(strategy='timestamp', unique_key='id', updated_at='ts', target_schema='archive', target_database='warehouse') }}\nselect 1\n{% endsnapshot %}\n{% snapshot off %}{{ config(enabled=false) }}{% endsnapshot %}\x0c ";
    try @import("snapshot.zig").parseBlocks(allocator, sql, "snapshots", "snapshots/nested/many.sql", "demo", &graph);
    const rendered = try renderManifest(allocator, &graph);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();
    const node = parsed.value.object.get("nodes").?.object.get("snapshot.demo.history").?.object;
    const disabled = parsed.value.object.get("disabled").?.object.get("snapshot.demo.off").?.array.items[0].object;
    try std.testing.expectEqualStrings("warehouse", node.get("database").?.string);
    try std.testing.expectEqualStrings("archive", node.get("schema").?.string);
    try std.testing.expectEqual(@as(usize, 4), node.get("fqn").?.array.items.len);
    try std.testing.expectEqualStrings("many", node.get("fqn").?.array.items[2].string);
    try std.testing.expectEqualStrings("history", node.get("fqn").?.array.items[3].string);
    try std.testing.expectEqualStrings(node.get("checksum").?.object.get("checksum").?.string, disabled.get("checksum").?.object.get("checksum").?.string);
    try std.testing.expectEqualStrings("097ad32ce920143de83bc07e2bdd8a3825c89545a9edf0bab98c93500b1518e9", node.get("checksum").?.object.get("checksum").?.string);
    try std.testing.expectEqualStrings("timestamp", node.get("config").?.object.get("strategy").?.string);
    try std.testing.expect(!disabled.get("config").?.object.get("enabled").?.bool);
}

fn writeJsonValue(writer: *Io.Writer, value: std.json.Value) anyerror!void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => try writer.writeAll(if (value.bool) "true" else "false"),
        .string => try json.string(writer, value.string),
        .integer => try writer.print("{d}", .{value.integer}),
        .float => try writer.print("{d}", .{value.float}),
        .number_string => try writer.writeAll(value.number_string),
        .array => {
            try writer.writeAll("[");
            for (value.array.items, 0..) |item, index| {
                if (index != 0) try writer.writeAll(",");
                try writeJsonValue(writer, item);
            }
            try writer.writeAll("]");
        },
        .object => {
            try writer.writeAll("{");
            var entries = value.object.iterator();
            var count: usize = 0;
            while (entries.next()) |entry| {
                if (count != 0) try writer.writeAll(",");
                try json.string(writer, entry.key_ptr.*);
                try writer.writeAll(":");
                try writeJsonValue(writer, entry.value_ptr.*);
                count += 1;
            }
            try writer.writeAll("}");
        },
    }
}
