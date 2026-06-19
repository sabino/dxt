const std = @import("std");
const Io = std.Io;
const compiler = @import("compiler.zig");
const json = @import("json.zig");
const selector = @import("selector.zig");
const types = @import("types.zig");
const util = @import("util.zig");

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
        }
    }
    try writer.writeAll("}");
}

fn writeSelectedJsonStringField(writer: *Io.Writer, key: []const u8, value: []const u8, wrote: *bool) !void {
    try json.stringField(writer, key, value, wrote);
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

    try writer.writeAll("{\n  \"metadata\": {\"project_name\": ");
    try json.string(writer, graph.project_name);
    try writer.writeAll(",\"adapter_type\":");
    try json.string(writer, graph.adapter_type);
    try writer.writeAll("},\n  \"nodes\": {");
    var node_index: usize = 0;
    for (graph.nodes.items) |node| {
        if (!node.enabled) continue;
        if (node_index != 0) try writer.writeAll(",");
        node_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, node.unique_id);
        try writer.writeAll(": ");
        try writeNode(allocator, writer, node);
    }
    for (graph.tests.items) |test_node| {
        if (node_index != 0) try writer.writeAll(",");
        node_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, test_node.unique_id);
        try writer.writeAll(": ");
        try writeGenericTestNode(allocator, writer, test_node);
    }
    for (graph.singular_tests.items) |test_node| {
        if (node_index != 0) try writer.writeAll(",");
        node_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, test_node.unique_id);
        try writer.writeAll(": ");
        try writeSingularTestNode(writer, test_node);
    }
    try writer.writeAll("\n  },\n  \"sources\": {");
    for (graph.sources.items, 0..) |source, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try json.string(writer, source.unique_id);
        try writer.writeAll(": ");
        try writeSourceNode(allocator, writer, source);
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
    try writer.writeAll("\n  },\n  \"metrics\": {},\n  \"groups\": {},\n  \"selectors\": {},\n  \"group_map\": {},\n  \"saved_queries\": {},\n  \"semantic_models\": {},\n  \"unit_tests\": {");
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
        try writeNode(allocator, writer, node);
        try writer.writeAll("]");
    }
    try writer.writeAll("\n  },\n  \"parent_map\": {");
    var parent_index: usize = 0;
    for (graph.nodes.items) |node| {
        if (!node.enabled) continue;
        if (parent_index != 0) try writer.writeAll(",");
        parent_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, node.unique_id);
        try writer.writeAll(": ");
        try json.stringArray(writer, node.depends_on.items);
    }
    for (graph.tests.items) |test_node| {
        if (parent_index != 0) try writer.writeAll(",");
        parent_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, test_node.unique_id);
        try writer.writeAll(": ");
        try json.stringArray(writer, test_node.depends_on.items);
    }
    for (graph.singular_tests.items) |test_node| {
        if (parent_index != 0) try writer.writeAll(",");
        parent_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, test_node.unique_id);
        try writer.writeAll(": ");
        try json.stringArray(writer, test_node.depends_on.items);
    }
    for (graph.exposures.items) |exposure| {
        if (!exposure.enabled) continue;
        if (parent_index != 0) try writer.writeAll(",");
        parent_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, exposure.unique_id);
        try writer.writeAll(": ");
        try json.stringArray(writer, exposure.depends_on.items);
    }
    for (graph.unit_tests.items) |unit_test| {
        if (!unit_test.enabled) continue;
        if (parent_index != 0) try writer.writeAll(",");
        parent_index += 1;
        try writer.writeAll("\n    ");
        try json.string(writer, unit_test.unique_id);
        try writer.writeAll(": ");
        try json.stringArray(writer, unit_test.depends_on.items);
    }
    try writer.writeAll("\n  },\n  \"child_map\": {");
    try writeChildMap(writer, graph);
    try writer.writeAll("\n  }\n}\n");
    return try out.toOwnedSlice();
}

fn writeChildMap(writer: *Io.Writer, graph: *const Graph) !void {
    var first = true;
    for (graph.nodes.items) |candidate| {
        if (!candidate.enabled) continue;
        try writeChildMapEntry(writer, graph, candidate.unique_id, &first);
    }
    for (graph.tests.items) |candidate| {
        try writeChildMapEntry(writer, graph, candidate.unique_id, &first);
    }
    for (graph.singular_tests.items) |candidate| {
        try writeChildMapEntry(writer, graph, candidate.unique_id, &first);
    }
    for (graph.sources.items) |candidate| {
        try writeChildMapEntry(writer, graph, candidate.unique_id, &first);
    }
    for (graph.exposures.items) |candidate| {
        if (!candidate.enabled) continue;
        try writeChildMapEntry(writer, graph, candidate.unique_id, &first);
    }
    for (graph.unit_tests.items) |candidate| {
        if (!candidate.enabled) continue;
        try writeChildMapEntry(writer, graph, candidate.unique_id, &first);
    }
}

fn writeChildMapEntry(writer: *Io.Writer, graph: *const Graph, unique_id: []const u8, first: *bool) !void {
    if (!first.*) try writer.writeAll(",");
    first.* = false;
    try writer.writeAll("\n    ");
    try json.string(writer, unique_id);
    try writer.writeAll(": [");
    var child_first = true;
    for (graph.nodes.items) |node| {
        if (!node.enabled) continue;
        if (util.containsString(node.depends_on.items, unique_id)) {
            if (!child_first) try writer.writeAll(",");
            child_first = false;
            try json.string(writer, node.unique_id);
        }
    }
    for (graph.tests.items) |test_node| {
        if (util.containsString(test_node.depends_on.items, unique_id)) {
            if (!child_first) try writer.writeAll(",");
            child_first = false;
            try json.string(writer, test_node.unique_id);
        }
    }
    for (graph.singular_tests.items) |test_node| {
        if (util.containsString(test_node.depends_on.items, unique_id)) {
            if (!child_first) try writer.writeAll(",");
            child_first = false;
            try json.string(writer, test_node.unique_id);
        }
    }
    for (graph.exposures.items) |exposure| {
        if (!exposure.enabled) continue;
        if (util.containsString(exposure.depends_on.items, unique_id)) {
            if (!child_first) try writer.writeAll(",");
            child_first = false;
            try json.string(writer, exposure.unique_id);
        }
    }
    for (graph.unit_tests.items) |unit_test| {
        if (!unit_test.enabled) continue;
        if (util.containsString(unit_test.depends_on.items, unique_id)) {
            if (!child_first) try writer.writeAll(",");
            child_first = false;
            try json.string(writer, unit_test.unique_id);
        }
    }
    try writer.writeAll("]");
}

fn writeNode(allocator: std.mem.Allocator, writer: *Io.Writer, node: Node) !void {
    if (std.mem.eql(u8, node.resource_type, "seed")) {
        try writeSeedNode(allocator, writer, node);
    } else {
        try writeModelNode(allocator, writer, node);
    }
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

fn writeSourceNode(allocator: std.mem.Allocator, writer: *Io.Writer, source: SourceDef) !void {
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
    try writer.writeAll(",\"database\":null,\"schema\":");
    try json.string(writer, schema_name);
    try writer.writeAll(",\"identifier\":");
    try json.string(writer, compiler.sourceIdentifier(&source));
    try writer.writeAll(",\"relation_name\":");
    try json.string(writer, relation_name);
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
    try writer.writeAll("],\"source_description\":\"\",\"loader\":\"\",\"loaded_at_field\":");
    try writeNullableString(writer, source.loaded_at_field);
    try writer.writeAll(",\"loaded_at_query\":");
    try writeNullableString(writer, source.loaded_at_query);
    try writer.writeAll(",\"freshness\":");
    try writeFreshnessThreshold(writer, source.freshness);
    try writer.writeAll(",\"columns\":");
    try writeColumns(writer, source.columns.items);
    try writer.writeAll(",\"config\":{\"enabled\":true,\"freshness\":");
    try writeFreshnessThreshold(writer, source.freshness);
    try writer.writeAll(",\"loaded_at_field\":");
    try writeNullableString(writer, source.loaded_at_field);
    try writer.writeAll(",\"loaded_at_query\":");
    try writeNullableString(writer, source.loaded_at_query);
    try writer.writeAll(",\"meta\":{},\"tags\":[]}}");
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
    try writer.writeAll(",\"fqn\":[");
    try json.string(writer, unit_test.package_name);
    try writer.writeAll(",");
    try json.string(writer, unit_test.model);
    try writer.writeAll(",");
    try json.string(writer, unit_test.name);
    try writer.writeAll("],\"description\":");
    try json.string(writer, unit_test.description);
    try writer.writeAll(",\"overrides\":null,\"depends_on\":{\"macros\":[],\"nodes\":");
    try json.stringArray(writer, unit_test.depends_on.items);
    try writer.writeAll("},\"config\":{\"tags\":");
    try json.stringArray(writer, unit_test.tags.items);
    try writer.writeAll(",\"meta\":");
    try writeMetaObject(writer, unit_test.meta.items);
    try writer.writeAll(",\"enabled\":");
    try writer.writeAll(if (unit_test.enabled) "true" else "false");
    try writer.writeAll(",\"static_analysis\":null},\"checksum\":null,\"schema\":null,\"created_at\":0.0,\"versions\":null,\"version\":null}");
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

fn writeModelNode(allocator: std.mem.Allocator, writer: *Io.Writer, node: Node) !void {
    try writer.writeAll("{\"unique_id\":");
    try json.string(writer, node.unique_id);
    try writer.writeAll(",\"resource_type\":\"model\",\"package_name\":");
    try json.string(writer, node.package_name);
    try writer.writeAll(",\"name\":");
    try json.string(writer, node.name);
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
    try writer.writeAll(",\"language\":\"sql\",\"raw_code\":");
    try json.string(writer, node.raw_code);
    try writer.writeAll(",\"description\":");
    try json.string(writer, node.description);
    try writer.writeAll(",\"doc_blocks\":");
    try json.stringArray(writer, node.doc_blocks.items);
    try writer.writeAll(",\"docs\":");
    try writeDocsConfig(writer, node.docs);
    try writer.writeAll(",\"columns\":");
    try writeColumns(writer, node.columns.items);
    try writer.writeAll(",\"config\":{\"enabled\":");
    try writer.writeAll(if (node.enabled) "true" else "false");
    try writer.writeAll(",\"materialized\":");
    try json.string(writer, node.materialized);
    try writer.writeAll(",\"tags\":");
    try json.stringArray(writer, node.tags.items);
    try writer.writeAll(",\"docs\":");
    try writeDocsConfig(writer, node.docs);
    try writer.writeAll("},\"depends_on\":{\"macros\":");
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
        try writer.writeAll(",\"compiled_path\":");
        try json.string(writer, util.normalizeForDisplay(node.compiled_path orelse ""));
        try writer.writeAll(",\"relation_name\":");
        try json.string(writer, node.relation_name orelse "");
        try writer.writeAll(",\"extra_ctes\":[],\"extra_ctes_injected\":false");
    }
    try writer.writeAll("}");
}

fn writeSeedNode(allocator: std.mem.Allocator, writer: *Io.Writer, node: Node) !void {
    try writer.writeAll("{\"unique_id\":");
    try json.string(writer, node.unique_id);
    try writer.writeAll(",\"resource_type\":\"seed\",\"package_name\":");
    try json.string(writer, node.package_name);
    try writer.writeAll(",\"name\":");
    try json.string(writer, node.name);
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
    try writer.writeAll(",\"config\":{\"enabled\":");
    try writer.writeAll(if (node.enabled) "true" else "false");
    try writer.writeAll(",\"materialized\":\"seed\",\"tags\":");
    try json.stringArray(writer, node.tags.items);
    try writer.writeAll(",\"docs\":");
    try writeDocsConfig(writer, node.docs);
    try writer.writeAll("},\"docs\":");
    try writeDocsConfig(writer, node.docs);
    try writer.writeAll(",\"depends_on\":{\"macros\":[],\"nodes\":");
    try json.stringArray(writer, node.depends_on.items);
    try writer.writeAll("}}");
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
        try writer.writeAll(",\"meta\":{},\"data_type\":null,\"quote\":null,\"tags\":[],\"config\":{},\"doc_blocks\":");
        try json.stringArray(writer, column.doc_blocks.items);
        try writer.writeAll("}");
    }
    try writer.writeAll("}");
}

fn writeGenericTestNode(allocator: std.mem.Allocator, writer: *Io.Writer, test_node: GenericTestNode) !void {
    const argument_column_name = genericTestNodeColumnName(&test_node);
    try writer.writeAll("{\"unique_id\":");
    try json.string(writer, test_node.unique_id);
    try writer.writeAll(",\"resource_type\":\"test\",\"package_name\":");
    try json.string(writer, test_node.package_name);
    try writer.writeAll(",\"name\":");
    try json.string(writer, test_node.name);
    try writer.writeAll(",\"alias\":");
    try json.string(writer, test_node.alias);
    try writer.writeAll(",\"path\":");
    try json.string(writer, util.normalizeForDisplay(test_node.path));
    try writer.writeAll(",\"original_file_path\":");
    try json.string(writer, util.normalizeForDisplay(test_node.original_file_path));
    try writer.writeAll(",\"patch_path\":null,\"language\":\"sql\",\"raw_code\":");
    try json.string(writer, test_node.raw_code);
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
    const model_kwarg = if (test_node.attached_node) |attached_node| blk: {
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
    if (test_node.accepted_values.items.len != 0) {
        try writer.writeAll(",\"values\":");
        try json.stringArray(writer, test_node.accepted_values.items);
    }
    if (test_node.accepted_values_quote) |quote| {
        try writer.writeAll(",\"quote\":");
        try writer.writeAll(if (quote) "true" else "false");
    }
    if (test_node.relationship_to.len != 0) {
        try writer.writeAll(",\"to\":");
        try json.string(writer, test_node.relationship_to);
    }
    if (test_node.relationship_field.len != 0) {
        try writer.writeAll(",\"field\":");
        try json.string(writer, test_node.relationship_field);
    }
    try writer.writeAll("},\"namespace\":null},\"config\":{\"enabled\":true,\"materialized\":\"test\",\"severity\":\"ERROR\",\"fail_calc\":\"count(*)\",\"warn_if\":\"!= 0\",\"error_if\":\"!= 0\",\"schema\":\"dbt_test__audit\",\"tags\":[],\"meta\":{}},\"depends_on\":{\"macros\":");
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
        try writer.writeAll(",\"extra_ctes\":[],\"extra_ctes_injected\":false");
    }
    try writer.writeAll("}");
}

fn writeSingularTestNode(writer: *Io.Writer, test_node: SingularTestNode) !void {
    try writer.writeAll("{\"unique_id\":");
    try json.string(writer, test_node.unique_id);
    try writer.writeAll(",\"resource_type\":\"test\",\"package_name\":");
    try json.string(writer, test_node.package_name);
    try writer.writeAll(",\"name\":");
    try json.string(writer, test_node.name);
    try writer.writeAll(",\"alias\":");
    try json.string(writer, test_node.alias);
    try writer.writeAll(",\"path\":");
    try json.string(writer, util.normalizeForDisplay(test_node.path));
    try writer.writeAll(",\"original_file_path\":");
    try json.string(writer, util.normalizeForDisplay(test_node.original_file_path));
    try writer.writeAll(",\"patch_path\":null,\"language\":\"sql\",\"raw_code\":");
    try json.string(writer, test_node.raw_code);
    try writer.writeAll(",\"config\":{\"enabled\":true,\"materialized\":\"test\",\"severity\":\"ERROR\",\"fail_calc\":\"count(*)\",\"warn_if\":\"!= 0\",\"error_if\":\"!= 0\",\"schema\":\"dbt_test__audit\",\"tags\":[],\"meta\":{}},\"depends_on\":{\"macros\":");
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
        try writer.writeAll(",\"extra_ctes\":[],\"extra_ctes_injected\":false");
    }
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

fn writeFreshnessThreshold(writer: *Io.Writer, value: ?types.FreshnessThreshold) !void {
    const threshold = value orelse {
        try writer.writeAll("null");
        return;
    };
    try writer.writeAll("{\"warn_after\":");
    try writeFreshnessTime(writer, threshold.warn_after);
    try writer.writeAll(",\"error_after\":");
    try writeFreshnessTime(writer, threshold.error_after);
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
        .number, .bool, .null => try writer.writeAll(value.text),
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
        try writer.writeAll(",\"version\":null}");
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
        if (argument.type.len == 0) {
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
        },
    };
    const keys = [_][]const u8{ "name", "package_name", "source_name", "config.materialized", "missing", "path", "original_file_path", "selector", "unique_id", "name" };

    const rendered = try renderSelectedJsonWithKeysForTest(std.testing.allocator, selected[0..], keys[0..]);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "[{\"name\":\"customers\",\"package_name\":\"demo\",\"path\":\"customers.sql\",\"original_file_path\":\"models/customers.sql\",\"selector\":\"demo.customers\",\"unique_id\":\"model.demo.customers\"},{\"name\":\"customers\",\"package_name\":\"demo\",\"source_name\":\"raw\",\"path\":\"models/schema.yml\",\"original_file_path\":\"models/schema.yml\",\"selector\":\"source:demo.raw.customers\",\"unique_id\":\"source.demo.raw.customers\"}]\n",
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
        .original_file_path = "models/schema.yml",
        .schema_name = "analytics_raw",
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
    try std.testing.expectEqualStrings("analytics_raw", source_node.get("schema").?.string);
    try std.testing.expectEqualStrings("raw_customers", source_node.get("identifier").?.string);
    try std.testing.expectEqualStrings("\"analytics_raw\".\"raw_customers\"", source_node.get("relation_name").?.string);
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
    try std.testing.expect(!test_node.get("extra_ctes_injected").?.bool);
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
        .raw_code = "select * from {{ ref('customers') }} where customer_id is null",
        .compiled = true,
        .compiled_code = "select * from \"main\".\"customers\" where customer_id is null",
        .compiled_path = "target/compiled/demo/tests/assert_customers.sql",
    });
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
    try std.testing.expect(!test_node.get("extra_ctes_injected").?.bool);
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

    const disabled = root.get("disabled").?.object;
    try std.testing.expect(disabled.get("model.demo.disabled") != null);

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

    const child_map = root.get("child_map").?.object;
    const source_children = child_map.get("source.demo.raw.customers").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), source_children.len);
    try std.testing.expectEqualStrings("model.demo.customers", source_children[0].string);
    try std.testing.expectEqualStrings("exposure.demo.weekly_kpis", source_children[1].string);
    const model_children = child_map.get("model.demo.customers").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), model_children.len);
    try std.testing.expectEqualStrings("exposure.demo.weekly_kpis", model_children[0].string);
    try std.testing.expectEqualStrings("unit_test.demo.customers.assert_customers", model_children[1].string);
    try std.testing.expect(child_map.get("model.demo.disabled") == null);
    try std.testing.expect(child_map.get("exposure.demo.hidden") == null);
}
