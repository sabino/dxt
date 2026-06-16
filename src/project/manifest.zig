const std = @import("std");
const Io = std.Io;
const selector = @import("selector.zig");
const types = @import("types.zig");
const util = @import("util.zig");

const Graph = types.Graph;
const Node = types.Node;
const GenericTestNode = types.GenericTestNode;
const SourceDef = types.SourceDef;
const ExposureDef = types.ExposureDef;
const MacroDef = types.MacroDef;
const MacroArgument = types.MacroArgument;
const DocBlock = types.DocBlock;
const DocsConfig = types.DocsConfig;
const MetaEntry = types.MetaEntry;
const JsonScalar = types.JsonScalar;
const RefDep = types.RefDep;
const SourceDep = types.SourceDep;

pub fn writeSelectedJson(writer: *Io.Writer, selected: []selector.SelectedResource) !void {
    try writer.writeAll("[");
    for (selected, 0..) |item, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("{\"unique_id\":");
        try writeJsonString(writer, item.unique_id);
        try writer.writeAll(",\"resource_type\":");
        try writeJsonString(writer, item.resource_type);
        try writer.writeAll(",\"name\":");
        try writeJsonString(writer, item.name);
        try writer.writeAll("}");
    }
    try writer.writeAll("]\n");
}

pub fn renderManifest(allocator: std.mem.Allocator, graph: *const Graph) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\n  \"metadata\": {\"project_name\": ");
    try writeJsonString(writer, graph.project_name);
    try writer.writeAll("},\n  \"nodes\": {");
    var node_index: usize = 0;
    for (graph.nodes.items) |node| {
        if (!node.enabled) continue;
        if (node_index != 0) try writer.writeAll(",");
        node_index += 1;
        try writer.writeAll("\n    ");
        try writeJsonString(writer, node.unique_id);
        try writer.writeAll(": ");
        try writeNode(allocator, writer, node);
    }
    for (graph.tests.items) |test_node| {
        if (node_index != 0) try writer.writeAll(",");
        node_index += 1;
        try writer.writeAll("\n    ");
        try writeJsonString(writer, test_node.unique_id);
        try writer.writeAll(": ");
        try writeGenericTestNode(allocator, writer, test_node);
    }
    try writer.writeAll("\n  },\n  \"sources\": {");
    for (graph.sources.items, 0..) |source, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try writeJsonString(writer, source.unique_id);
        try writer.writeAll(": {\"unique_id\":");
        try writeJsonString(writer, source.unique_id);
        try writer.writeAll(",\"resource_type\":\"source\",\"package_name\":");
        try writeJsonString(writer, source.package_name);
        try writer.writeAll(",\"source_name\":");
        try writeJsonString(writer, source.source_name);
        try writer.writeAll(",\"name\":");
        try writeJsonString(writer, source.table_name);
        try writer.writeAll(",\"original_file_path\":");
        try writeJsonString(writer, util.normalizeForDisplay(source.original_file_path));
        try writer.writeAll("}");
    }
    try writer.writeAll("\n  },\n  \"macros\": {");
    for (graph.macros.items, 0..) |macro, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try writeJsonString(writer, macro.unique_id);
        try writer.writeAll(": ");
        try writeMacroNode(allocator, writer, macro);
    }
    try writer.writeAll("\n  },\n  \"docs\": {");
    for (graph.docs.items, 0..) |doc, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try writeJsonString(writer, doc.unique_id);
        try writer.writeAll(": {\"unique_id\":");
        try writeJsonString(writer, doc.unique_id);
        try writer.writeAll(",\"resource_type\":\"doc\",\"package_name\":");
        try writeJsonString(writer, doc.package_name);
        try writer.writeAll(",\"name\":");
        try writeJsonString(writer, doc.name);
        try writer.writeAll(",\"path\":");
        try writeJsonString(writer, util.normalizeForDisplay(doc.path));
        try writer.writeAll(",\"original_file_path\":");
        try writeJsonString(writer, util.normalizeForDisplay(doc.original_file_path));
        try writer.writeAll(",\"block_contents\":");
        try writeJsonString(writer, doc.block_contents);
        try writer.writeAll("}");
    }
    try writer.writeAll("\n  },\n  \"exposures\": {");
    var exposure_index: usize = 0;
    for (graph.exposures.items) |exposure| {
        if (!exposure.enabled) continue;
        if (exposure_index != 0) try writer.writeAll(",");
        exposure_index += 1;
        try writer.writeAll("\n    ");
        try writeJsonString(writer, exposure.unique_id);
        try writer.writeAll(": ");
        try writeExposureNode(writer, exposure);
    }
    try writer.writeAll("\n  },\n  \"metrics\": {},\n  \"groups\": {},\n  \"selectors\": {},\n  \"group_map\": {},\n  \"saved_queries\": {},\n  \"semantic_models\": {},\n  \"unit_tests\": {},\n  \"disabled\": {");
    var disabled_index: usize = 0;
    for (graph.nodes.items) |node| {
        if (node.enabled) continue;
        if (disabled_index != 0) try writer.writeAll(",");
        disabled_index += 1;
        try writer.writeAll("\n    ");
        try writeJsonString(writer, node.unique_id);
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
        try writeJsonString(writer, node.unique_id);
        try writer.writeAll(": ");
        try writeStringArray(writer, node.depends_on.items);
    }
    for (graph.tests.items) |test_node| {
        if (parent_index != 0) try writer.writeAll(",");
        parent_index += 1;
        try writer.writeAll("\n    ");
        try writeJsonString(writer, test_node.unique_id);
        try writer.writeAll(": ");
        try writeStringArray(writer, test_node.depends_on.items);
    }
    for (graph.exposures.items) |exposure| {
        if (!exposure.enabled) continue;
        if (parent_index != 0) try writer.writeAll(",");
        parent_index += 1;
        try writer.writeAll("\n    ");
        try writeJsonString(writer, exposure.unique_id);
        try writer.writeAll(": ");
        try writeStringArray(writer, exposure.depends_on.items);
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
    for (graph.sources.items) |candidate| {
        try writeChildMapEntry(writer, graph, candidate.unique_id, &first);
    }
    for (graph.exposures.items) |candidate| {
        if (!candidate.enabled) continue;
        try writeChildMapEntry(writer, graph, candidate.unique_id, &first);
    }
}

fn writeChildMapEntry(writer: *Io.Writer, graph: *const Graph, unique_id: []const u8, first: *bool) !void {
    if (!first.*) try writer.writeAll(",");
    first.* = false;
    try writer.writeAll("\n    ");
    try writeJsonString(writer, unique_id);
    try writer.writeAll(": [");
    var child_first = true;
    for (graph.nodes.items) |node| {
        if (!node.enabled) continue;
        if (util.containsString(node.depends_on.items, unique_id)) {
            if (!child_first) try writer.writeAll(",");
            child_first = false;
            try writeJsonString(writer, node.unique_id);
        }
    }
    for (graph.tests.items) |test_node| {
        if (util.containsString(test_node.depends_on.items, unique_id)) {
            if (!child_first) try writer.writeAll(",");
            child_first = false;
            try writeJsonString(writer, test_node.unique_id);
        }
    }
    for (graph.exposures.items) |exposure| {
        if (!exposure.enabled) continue;
        if (util.containsString(exposure.depends_on.items, unique_id)) {
            if (!child_first) try writer.writeAll(",");
            child_first = false;
            try writeJsonString(writer, exposure.unique_id);
        }
    }
    try writer.writeAll("]");
}

fn writeNode(allocator: std.mem.Allocator, writer: *Io.Writer, node: Node) !void {
    if (std.mem.eql(u8, node.resource_type, "seed")) {
        try writeSeedNode(writer, node);
    } else {
        try writeModelNode(allocator, writer, node);
    }
}

fn writeMacroNode(allocator: std.mem.Allocator, writer: *Io.Writer, macro: MacroDef) !void {
    try writer.writeAll("{\"unique_id\":");
    try writeJsonString(writer, macro.unique_id);
    try writer.writeAll(",\"resource_type\":\"macro\",\"package_name\":");
    try writeJsonString(writer, macro.package_name);
    try writer.writeAll(",\"name\":");
    try writeJsonString(writer, macro.name);
    try writer.writeAll(",\"path\":");
    try writeJsonString(writer, util.normalizeForDisplay(macro.path));
    try writer.writeAll(",\"original_file_path\":");
    try writeJsonString(writer, util.normalizeForDisplay(macro.original_file_path));
    try writer.writeAll(",\"macro_sql\":");
    try writeJsonString(writer, macro.macro_sql);
    try writer.writeAll(",\"depends_on\":{\"macros\":");
    try writeStringArray(writer, macro.macro_depends_on.items);
    try writer.writeAll("},\"description\":");
    try writeJsonString(writer, macro.description);
    try writer.writeAll(",\"meta\":");
    try writeMetaObject(writer, macro.meta.items);
    try writer.writeAll(",\"docs\":");
    try writeDocsConfig(writer, macro.docs);
    try writer.writeAll(",\"patch_path\":");
    if (macro.patch_path) |patch_path| {
        const dbt_patch_path = try std.fmt.allocPrint(allocator, "{s}://{s}", .{ macro.package_name, util.normalizeForDisplay(patch_path) });
        defer allocator.free(dbt_patch_path);
        try writeJsonString(writer, dbt_patch_path);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"arguments\":");
    try writeMacroArguments(writer, macro.arguments.items);
    try writer.writeAll(",\"supported_languages\":");
    if (macro.has_supported_languages) {
        try writeStringArray(writer, macro.supported_languages.items);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}");
}

fn writeExposureNode(writer: *Io.Writer, exposure: ExposureDef) !void {
    try writer.writeAll("{\"unique_id\":");
    try writeJsonString(writer, exposure.unique_id);
    try writer.writeAll(",\"resource_type\":\"exposure\",\"package_name\":");
    try writeJsonString(writer, exposure.package_name);
    try writer.writeAll(",\"name\":");
    try writeJsonString(writer, exposure.name);
    try writer.writeAll(",\"path\":");
    try writeJsonString(writer, util.normalizeForDisplay(exposure.path));
    try writer.writeAll(",\"original_file_path\":");
    try writeJsonString(writer, util.normalizeForDisplay(exposure.original_file_path));
    try writer.writeAll(",\"fqn\":[");
    try writeJsonString(writer, exposure.package_name);
    try writer.writeAll(",");
    try writeJsonString(writer, exposure.name);
    try writer.writeAll("],\"label\":null,\"type\":");
    try writeJsonString(writer, exposure.exposure_type);
    try writer.writeAll(",\"maturity\":");
    try writeNullableString(writer, exposure.maturity);
    try writer.writeAll(",\"url\":");
    try writeNullableString(writer, exposure.url);
    try writer.writeAll(",\"description\":");
    try writeJsonString(writer, exposure.description);
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
        try writeJsonString(writer, exposure.owner_name);
    }
    try writer.writeAll("},\"tags\":");
    try writeStringArray(writer, exposure.tags.items);
    try writer.writeAll(",\"meta\":");
    try writeMetaObject(writer, exposure.meta.items);
    try writer.writeAll(",\"config\":{\"enabled\":");
    try writer.writeAll(if (exposure.enabled) "true" else "false");
    try writer.writeAll(",\"tags\":");
    try writeStringArray(writer, exposure.tags.items);
    try writer.writeAll(",\"meta\":");
    try writeMetaObject(writer, exposure.meta.items);
    try writer.writeAll("},\"unrendered_config\":{},\"created_at\":0.0}");
}

fn writeModelNode(allocator: std.mem.Allocator, writer: *Io.Writer, node: Node) !void {
    try writer.writeAll("{\"unique_id\":");
    try writeJsonString(writer, node.unique_id);
    try writer.writeAll(",\"resource_type\":\"model\",\"package_name\":");
    try writeJsonString(writer, node.package_name);
    try writer.writeAll(",\"name\":");
    try writeJsonString(writer, node.name);
    try writer.writeAll(",\"path\":");
    try writeJsonString(writer, util.normalizeForDisplay(node.path));
    try writer.writeAll(",\"original_file_path\":");
    try writeJsonString(writer, util.normalizeForDisplay(node.original_file_path));
    try writer.writeAll(",\"patch_path\":");
    if (node.patch_path) |patch_path| {
        const dbt_patch_path = try std.fmt.allocPrint(allocator, "{s}://{s}", .{ node.package_name, util.normalizeForDisplay(patch_path) });
        defer allocator.free(dbt_patch_path);
        try writeJsonString(writer, dbt_patch_path);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"language\":\"sql\",\"raw_code\":");
    try writeJsonString(writer, node.raw_code);
    try writer.writeAll(",\"description\":");
    try writeJsonString(writer, node.description);
    try writer.writeAll(",\"doc_blocks\":");
    try writeStringArray(writer, node.doc_blocks.items);
    try writer.writeAll(",\"docs\":");
    try writeDocsConfig(writer, node.docs);
    try writer.writeAll(",\"columns\":{");
    for (node.columns.items, 0..) |column, index| {
        if (index != 0) try writer.writeAll(",");
        try writeJsonString(writer, column.name);
        try writer.writeAll(":{\"name\":");
        try writeJsonString(writer, column.name);
        try writer.writeAll(",\"description\":");
        try writeJsonString(writer, column.description);
        try writer.writeAll(",\"meta\":{},\"data_type\":null,\"quote\":null,\"tags\":[],\"config\":{},\"doc_blocks\":");
        try writeStringArray(writer, column.doc_blocks.items);
        try writer.writeAll("}");
    }
    try writer.writeAll("},\"config\":{\"enabled\":");
    try writer.writeAll(if (node.enabled) "true" else "false");
    try writer.writeAll(",\"materialized\":");
    try writeJsonString(writer, node.materialized);
    try writer.writeAll(",\"tags\":");
    try writeStringArray(writer, node.tags.items);
    try writer.writeAll(",\"docs\":");
    try writeDocsConfig(writer, node.docs);
    try writer.writeAll("},\"depends_on\":{\"macros\":");
    try writeStringArray(writer, node.macro_depends_on.items);
    try writer.writeAll(",\"nodes\":");
    try writeStringArray(writer, node.depends_on.items);
    try writer.writeAll("},\"refs\":");
    try writeRefDeps(writer, node.refs.items);
    try writer.writeAll(",\"sources\":");
    try writeSourceDeps(writer, node.source_refs.items);
    if (node.compiled) {
        try writer.writeAll(",\"compiled\":true,\"compiled_code\":");
        try writeJsonString(writer, node.compiled_code orelse "");
        try writer.writeAll(",\"compiled_path\":");
        try writeJsonString(writer, util.normalizeForDisplay(node.compiled_path orelse ""));
        try writer.writeAll(",\"relation_name\":");
        try writeJsonString(writer, node.relation_name orelse "");
        try writer.writeAll(",\"extra_ctes\":[],\"extra_ctes_injected\":false");
    }
    try writer.writeAll("}");
}

fn writeSeedNode(writer: *Io.Writer, node: Node) !void {
    try writer.writeAll("{\"unique_id\":");
    try writeJsonString(writer, node.unique_id);
    try writer.writeAll(",\"resource_type\":\"seed\",\"package_name\":");
    try writeJsonString(writer, node.package_name);
    try writer.writeAll(",\"name\":");
    try writeJsonString(writer, node.name);
    try writer.writeAll(",\"path\":");
    try writeJsonString(writer, util.normalizeForDisplay(node.path));
    try writer.writeAll(",\"original_file_path\":");
    try writeJsonString(writer, util.normalizeForDisplay(node.original_file_path));
    try writer.writeAll(",\"config\":{\"enabled\":");
    try writer.writeAll(if (node.enabled) "true" else "false");
    try writer.writeAll(",\"materialized\":\"seed\",\"docs\":");
    try writeDocsConfig(writer, node.docs);
    try writer.writeAll("},\"docs\":");
    try writeDocsConfig(writer, node.docs);
    try writer.writeAll(",\"depends_on\":{\"macros\":[],\"nodes\":");
    try writeStringArray(writer, node.depends_on.items);
    try writer.writeAll("}}");
}

fn writeGenericTestNode(allocator: std.mem.Allocator, writer: *Io.Writer, test_node: GenericTestNode) !void {
    try writer.writeAll("{\"unique_id\":");
    try writeJsonString(writer, test_node.unique_id);
    try writer.writeAll(",\"resource_type\":\"test\",\"package_name\":");
    try writeJsonString(writer, test_node.package_name);
    try writer.writeAll(",\"name\":");
    try writeJsonString(writer, test_node.name);
    try writer.writeAll(",\"alias\":");
    try writeJsonString(writer, test_node.alias);
    try writer.writeAll(",\"path\":");
    try writeJsonString(writer, util.normalizeForDisplay(test_node.path));
    try writer.writeAll(",\"original_file_path\":");
    try writeJsonString(writer, util.normalizeForDisplay(test_node.original_file_path));
    try writer.writeAll(",\"patch_path\":null,\"language\":\"sql\",\"raw_code\":");
    try writeJsonString(writer, test_node.raw_code);
    try writer.writeAll(",\"attached_node\":");
    try writeJsonString(writer, test_node.attached_node);
    try writer.writeAll(",\"column_name\":");
    if (test_node.column_name) |column_name| {
        try writeJsonString(writer, column_name);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"test_metadata\":{\"name\":");
    try writeJsonString(writer, test_node.test_name);
    try writer.writeAll(",\"kwargs\":{\"model\":");
    const model_name = modelNameFromUniqueId(test_node.attached_node);
    const model_kwarg = try std.fmt.allocPrint(allocator, "{{{{ get_where_subquery(ref('{s}')) }}}}", .{model_name});
    defer allocator.free(model_kwarg);
    try writeJsonString(writer, model_kwarg);
    if (test_node.column_name) |column_name| {
        try writer.writeAll(",\"column_name\":");
        try writeJsonString(writer, column_name);
    }
    if (test_node.accepted_values.items.len != 0) {
        try writer.writeAll(",\"values\":");
        try writeStringArray(writer, test_node.accepted_values.items);
    }
    if (test_node.relationship_to.len != 0) {
        try writer.writeAll(",\"to\":");
        try writeJsonString(writer, test_node.relationship_to);
    }
    if (test_node.relationship_field.len != 0) {
        try writer.writeAll(",\"field\":");
        try writeJsonString(writer, test_node.relationship_field);
    }
    try writer.writeAll("},\"namespace\":null},\"config\":{\"enabled\":true,\"materialized\":\"test\",\"severity\":\"ERROR\",\"fail_calc\":\"count(*)\",\"warn_if\":\"!= 0\",\"error_if\":\"!= 0\",\"schema\":\"dbt_test__audit\",\"tags\":[],\"meta\":{}},\"depends_on\":{\"macros\":");
    try writeStringArray(writer, test_node.macro_depends_on.items);
    try writer.writeAll(",\"nodes\":");
    try writeStringArray(writer, test_node.depends_on.items);
    try writer.writeAll("},\"refs\":");
    try writeRefDeps(writer, test_node.refs.items);
    try writer.writeAll(",\"sources\":");
    try writeSourceDeps(writer, test_node.source_refs.items);
    try writer.writeAll("}");
}

fn writeStringArray(writer: *Io.Writer, values: []const []const u8) !void {
    try writer.writeAll("[");
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(",");
        try writeJsonString(writer, value);
    }
    try writer.writeAll("]");
}

fn writeExposureDependsOnNodes(writer: *Io.Writer, values: []const []const u8) !void {
    try writer.writeAll("[");
    var first = true;
    for (values) |value| {
        if (!std.mem.startsWith(u8, value, "source.")) continue;
        if (!first) try writer.writeAll(",");
        first = false;
        try writeJsonString(writer, value);
    }
    for (values) |value| {
        if (std.mem.startsWith(u8, value, "source.")) continue;
        if (!first) try writer.writeAll(",");
        first = false;
        try writeJsonString(writer, value);
    }
    try writer.writeAll("]");
}

fn writeNullableString(writer: *Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try writeJsonString(writer, text);
    } else {
        try writer.writeAll("null");
    }
}

fn writeMetaObject(writer: *Io.Writer, entries: []const MetaEntry) !void {
    try writer.writeAll("{");
    for (entries, 0..) |entry, index| {
        if (index != 0) try writer.writeAll(",");
        try writeJsonString(writer, entry.key);
        try writer.writeAll(":");
        try writeJsonScalar(writer, entry.value);
    }
    try writer.writeAll("}");
}

fn writeDocsConfig(writer: *Io.Writer, docs: DocsConfig) !void {
    try writer.writeAll("{\"show\":");
    try writer.writeAll(if (docs.show) "true" else "false");
    try writer.writeAll(",\"node_color\":");
    try writeNullableString(writer, docs.node_color);
    try writer.writeAll("}");
}

fn writeJsonScalar(writer: *Io.Writer, value: JsonScalar) !void {
    switch (value.kind) {
        .string => try writeJsonString(writer, value.text),
        .number, .bool, .null => try writer.writeAll(value.text),
    }
}

fn writeRefDeps(writer: *Io.Writer, refs: []const RefDep) !void {
    try writer.writeAll("[");
    for (refs, 0..) |ref_dep, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("{\"name\":");
        try writeJsonString(writer, ref_dep.name);
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
        try writeJsonString(writer, source_dep.source_name);
        try writer.writeAll(",");
        try writeJsonString(writer, source_dep.table_name);
        try writer.writeAll("]");
    }
    try writer.writeAll("]");
}

fn writeMacroArguments(writer: *Io.Writer, arguments: []const MacroArgument) !void {
    try writer.writeAll("[");
    for (arguments, 0..) |argument, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("{\"name\":");
        try writeJsonString(writer, argument.name);
        try writer.writeAll(",\"type\":");
        if (argument.type.len == 0) {
            try writer.writeAll("null");
        } else {
            try writeJsonString(writer, argument.type);
        }
        try writer.writeAll(",\"description\":");
        try writeJsonString(writer, argument.description);
        try writer.writeAll("}");
    }
    try writer.writeAll("]");
}

fn writeJsonString(writer: *Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
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

fn renderJsonStringForTest(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeJsonString(&out.writer, value);
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

    const parent_map = root.get("parent_map").?.object;
    const model_parents = parent_map.get("model.demo.customers").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), model_parents.len);
    try std.testing.expectEqualStrings("source.demo.raw.customers", model_parents[0].string);
    const exposure_parents = parent_map.get("exposure.demo.weekly_kpis").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), exposure_parents.len);
    try std.testing.expectEqualStrings("model.demo.customers", exposure_parents[0].string);
    try std.testing.expectEqualStrings("source.demo.raw.customers", exposure_parents[1].string);
    try std.testing.expect(parent_map.get("exposure.demo.hidden") == null);

    const child_map = root.get("child_map").?.object;
    const source_children = child_map.get("source.demo.raw.customers").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), source_children.len);
    try std.testing.expectEqualStrings("model.demo.customers", source_children[0].string);
    try std.testing.expectEqualStrings("exposure.demo.weekly_kpis", source_children[1].string);
    const model_children = child_map.get("model.demo.customers").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), model_children.len);
    try std.testing.expectEqualStrings("exposure.demo.weekly_kpis", model_children[0].string);
    try std.testing.expect(child_map.get("model.demo.disabled") == null);
    try std.testing.expect(child_map.get("exposure.demo.hidden") == null);
}
