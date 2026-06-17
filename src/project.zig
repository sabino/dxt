const std = @import("std");
const Io = std.Io;
const catalog = @import("project/catalog.zig");
const compiler = @import("project/compiler.zig");
const project_fs = @import("project/fs.zig");
const project_jinja = @import("project/jinja.zig");
const project_loader = @import("project/loader.zig");
const project_parse = @import("project/parse.zig");
const project_resolve = @import("project/resolve.zig");
const manifest = @import("project/manifest.zig");
const selector = @import("project/selector.zig");
const types = @import("project/types.zig");
const util = @import("project/util.zig");

pub const Runtime = types.Runtime;
pub const Options = types.Options;
pub const Output = types.Output;

const ColumnDef = types.ColumnDef;
const GenericTestDef = types.GenericTestDef;
const DocBlock = types.DocBlock;
const ModelProperty = types.ModelProperty;
const Node = types.Node;
const GenericTestNode = types.GenericTestNode;
const Graph = types.Graph;
const deinitNode = types.deinitNode;
const deinitGenericTestNode = types.deinitGenericTestNode;
const modelNameFromPath = project_fs.modelNameFromPath;
const pathJoin = project_fs.pathJoin;
const relativeUnderResourcePath = project_fs.relativeUnderResourcePath;
const resourceNameFromPath = project_fs.resourceNameFromPath;
const stripYamlComment = util.stripYamlComment;
const leadingSpaces = util.leadingSpaces;
const splitKeyValue = util.splitKeyValue;
const parseInlineStringList = util.parseInlineStringList;
const dupTrimmedScalar = util.dupTrimmedScalar;
const appendGenericTestDef = project_parse.appendGenericTestDef;
const appendGenericTestDefClone = project_parse.appendGenericTestDefClone;
const parseBool = project_parse.parseBool;
const parseExposuresFromText = project_parse.parseExposuresFromText;
const genericTestUniqueId = project_parse.genericTestUniqueId;
const parseInlineGenericTestList = project_parse.parseInlineGenericTestList;
const parseMacroPropertiesFromText = project_parse.parseMacroPropertiesFromText;
const parseMacros = project_parse.parseMacros;
const parseSourcesFromText = project_parse.parseSourcesFromText;
const refDepFromValue = project_parse.refDepFromValue;
const synthesizeGenericTestNames = project_parse.synthesizeGenericTestNames;
const testNameFromYamlItem = project_parse.testNameFromYamlItem;
const findMatchingParen = project_jinja.findMatchingParen;
const parseLiteralArgs = project_jinja.parseLiteralArgs;
const skipWs = project_jinja.skipWs;
const appendUnique = util.appendUnique;
const sortStrings = util.sortStrings;
const countActiveExposures = project_resolve.countActiveExposures;
const countActiveNodes = project_resolve.countActiveNodes;
const countActiveSeeds = project_resolve.countActiveSeeds;
const findDoc = project_resolve.findDoc;
const findModelIndexByName = project_resolve.findModelIndexByName;
const resolveDependencies = project_resolve.resolveDependencies;
const resolveRefDependency = project_resolve.resolveRefDependency;

const loader_callbacks = project_loader.Callbacks{
    .parse_doc_blocks = parseDocBlocks,
    .parse_yaml_properties = parseYamlProperties,
    .parse_macros = parseMacros,
    .parse_model = parseModel,
    .parse_seed = parseSeed,
    .apply_model_properties = applyModelProperties,
    .materialize_generic_tests = materializeGenericTests,
    .resolve_macro_dependencies = resolveMacroDependencies,
};

pub fn parse(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    try writeWarnings(stderr, &graph);
    const active_models = countActiveNodes(&graph);
    const active_seeds = countActiveSeeds(&graph);

    const target_path = options.target_path orelse project_loader.graphDefaultTarget(runtime, options.project_dir) catch "target";
    const target_dir = if (std.fs.path.isAbsolute(target_path))
        target_path
    else
        try pathJoin(runtime.allocator, &.{ options.project_dir, target_path });
    try std.Io.Dir.cwd().createDirPath(runtime.io, target_dir);
    const manifest_path = try pathJoin(runtime.allocator, &.{ target_dir, "manifest.json" });
    const manifest_json = try manifest.renderManifest(runtime.allocator, &graph);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = manifest_path, .data = manifest_json });
    try stdout.print("Parsed {d} model(s), {d} seed(s), {d} source(s), and {d} exposure(s) into {s}\n", .{
        active_models,
        active_seeds,
        graph.sources.items.len,
        countActiveExposures(&graph),
        util.normalizeForDisplay(manifest_path),
    });
}

pub fn list(runtime: Runtime, options: Options, stdout: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    const select = if (options.select) |value| try runtime.allocator.dupe(u8, value) else null;
    const exclude = if (options.exclude) |value| try runtime.allocator.dupe(u8, value) else null;
    const resource_type = if (options.resource_type) |value| try runtime.allocator.dupe(u8, value) else null;
    const selected = try selector.selectResources(runtime.allocator, &graph, resource_type, select, exclude);
    if (options.output == .json) {
        try manifest.writeSelectedJson(stdout, selected);
    } else {
        for (selected) |item| {
            try stdout.print("{s}\n", .{item.unique_id});
        }
    }
}

pub fn compile(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    try writeWarnings(stderr, &graph);

    const select = if (options.select) |value| try runtime.allocator.dupe(u8, value) else null;
    const exclude = if (options.exclude) |value| try runtime.allocator.dupe(u8, value) else null;
    const selected = try selector.selectResources(runtime.allocator, &graph, null, select, exclude);

    const target_dir = try targetDir(runtime, options);
    const compile_result = try compileSelectedModels(runtime, &graph, selected, target_dir);
    if (selected.len != 0 and !compile_result.saw_model) return error.UnsupportedCompileSelection;

    const manifest_path = try pathJoin(runtime.allocator, &.{ target_dir, "manifest.json" });
    const manifest_json = try manifest.renderManifest(runtime.allocator, &graph);
    try std.Io.Dir.cwd().createDirPath(runtime.io, target_dir);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = manifest_path, .data = manifest_json });
    try stdout.print("Compiled {d} model(s) into {s}\n", .{
        compile_result.count,
        util.normalizeForDisplay(compile_result.compiled_base),
    });
}

pub fn docsGenerate(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    try writeWarnings(stderr, &graph);

    const select = if (options.select) |value| try runtime.allocator.dupe(u8, value) else null;
    const exclude = if (options.exclude) |value| try runtime.allocator.dupe(u8, value) else null;
    const selected = try selector.selectResources(runtime.allocator, &graph, null, select, exclude);

    const target_dir = try targetDir(runtime, options);
    const compile_result = try compileSelectedModels(runtime, &graph, selected, target_dir);

    const manifest_path = try pathJoin(runtime.allocator, &.{ target_dir, "manifest.json" });
    const manifest_json = try manifest.renderManifest(runtime.allocator, &graph);
    try std.Io.Dir.cwd().createDirPath(runtime.io, target_dir);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = manifest_path, .data = manifest_json });

    const catalog_path = try pathJoin(runtime.allocator, &.{ target_dir, "catalog.json" });
    const catalog_json = try catalog.renderCatalog(runtime.allocator);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = catalog_path, .data = catalog_json });

    try stdout.print("Generated docs artifacts for {d} compiled model(s) into {s}\n", .{
        compile_result.count,
        util.normalizeForDisplay(target_dir),
    });
}

pub fn runPreflight(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    try writeWarnings(stderr, &graph);

    const select = if (options.select) |value| try runtime.allocator.dupe(u8, value) else null;
    const exclude = if (options.exclude) |value| try runtime.allocator.dupe(u8, value) else null;
    const selected_models = try selector.selectResources(runtime.allocator, &graph, "model", select, exclude);
    if (selected_models.len == 0 and options.select != null) {
        const selected_any = try selector.selectResources(runtime.allocator, &graph, null, select, exclude);
        if (selected_any.len != 0) return error.UnsupportedRunSelection;
    }

    const target_dir = try targetDir(runtime, options);
    const compile_result = try compileSelectedModels(runtime, &graph, selected_models, target_dir);
    const manifest_path = try writeManifest(runtime, &graph, target_dir);
    try stdout.print("Prepared {d} model(s) for execution into {s}\n", .{
        compile_result.count,
        util.normalizeForDisplay(manifest_path),
    });
    if (compile_result.count == 0) return error.UnsupportedRunSelection;
    return error.UnsupportedModelExecution;
}

pub fn buildPreflight(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    try writeWarnings(stderr, &graph);

    const select = if (options.select) |value| try runtime.allocator.dupe(u8, value) else null;
    const exclude = if (options.exclude) |value| try runtime.allocator.dupe(u8, value) else null;
    const selected = try selector.selectResources(runtime.allocator, &graph, null, select, exclude);

    const target_dir = try targetDir(runtime, options);
    const compile_result = try compileSelectedModels(runtime, &graph, selected, target_dir);
    const manifest_path = try writeManifest(runtime, &graph, target_dir);
    const execution_kind = firstExecutionKind(selected) orelse return error.UnsupportedBuildSelection;
    try stdout.print("Prepared {d} selected resource(s), including {d} compiled model(s), into {s}\n", .{
        selected.len,
        compile_result.count,
        util.normalizeForDisplay(manifest_path),
    });
    return switch (execution_kind) {
        .seed => error.UnsupportedSeedExecution,
        .model => error.UnsupportedModelExecution,
        .test_resource => error.UnsupportedTestExecution,
    };
}

const CompileResult = struct {
    count: usize,
    saw_model: bool,
    compiled_base: []const u8,
};

const ExecutionKind = enum {
    seed,
    model,
    test_resource,
};

fn firstExecutionKind(selected: []const selector.SelectedResource) ?ExecutionKind {
    for (selected) |item| {
        if (std.mem.eql(u8, item.resource_type, "seed")) return .seed;
    }
    for (selected) |item| {
        if (std.mem.eql(u8, item.resource_type, "model")) return .model;
    }
    for (selected) |item| {
        if (std.mem.eql(u8, item.resource_type, "test")) return .test_resource;
    }
    return null;
}

fn targetDir(runtime: Runtime, options: Options) ![]const u8 {
    const target_path = options.target_path orelse project_loader.graphDefaultTarget(runtime, options.project_dir) catch "target";
    if (std.fs.path.isAbsolute(target_path)) return target_path;
    return try pathJoin(runtime.allocator, &.{ options.project_dir, target_path });
}

fn compileSelectedModels(runtime: Runtime, graph: *Graph, selected: []const selector.SelectedResource, target_dir: []const u8) !CompileResult {
    const compiled_base = try pathJoin(runtime.allocator, &.{ target_dir, "compiled" });
    try std.Io.Dir.cwd().createDirPath(runtime.io, compiled_base);

    var compiled_count: usize = 0;
    var saw_selected_model = false;
    for (graph.nodes.items) |*node| {
        if (!node.enabled or !std.mem.eql(u8, node.resource_type, "model")) continue;
        if (!selectionContains(selected, node.unique_id)) continue;
        saw_selected_model = true;

        const compiled_code = try compiler.compileModel(runtime.allocator, graph, node);
        const compiled_path = try pathJoin(runtime.allocator, &.{ compiled_base, node.package_name, node.original_file_path });
        if (std.fs.path.dirname(compiled_path)) |parent| {
            try std.Io.Dir.cwd().createDirPath(runtime.io, parent);
        }
        try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = compiled_path, .data = compiled_code });
        node.compiled = true;
        node.compiled_code = compiled_code;
        node.compiled_path = util.normalizeForDisplay(compiled_path);
        node.relation_name = try compiler.relationNameForNode(runtime.allocator, node);
        compiled_count += 1;
    }

    return .{ .count = compiled_count, .saw_model = saw_selected_model, .compiled_base = compiled_base };
}

fn writeManifest(runtime: Runtime, graph: *const Graph, target_dir: []const u8) ![]const u8 {
    const manifest_path = try pathJoin(runtime.allocator, &.{ target_dir, "manifest.json" });
    const manifest_json = try manifest.renderManifest(runtime.allocator, graph);
    try std.Io.Dir.cwd().createDirPath(runtime.io, target_dir);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = manifest_path, .data = manifest_json });
    return manifest_path;
}

fn selectionContains(selected: []const selector.SelectedResource, unique_id: []const u8) bool {
    for (selected) |item| {
        if (std.mem.eql(u8, item.unique_id, unique_id)) return true;
    }
    return false;
}

fn parseDocBlocks(runtime: Runtime, project_dir: []const u8, model_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    const path = try pathJoin(runtime.allocator, &.{ project_dir, relative_path });
    const text = try std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(4 * 1024 * 1024));
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, text, index, "{%")) |open| {
        const close = std.mem.indexOfPos(u8, text, open + 2, "%}") orelse return error.MalformedDocsBlock;
        const tag = std.mem.trim(u8, text[open + 2 .. close], " \t\r\n-");
        if (!std.mem.startsWith(u8, tag, "docs")) {
            index = close + 2;
            continue;
        }
        if (tag.len <= "docs".len or !std.ascii.isWhitespace(tag["docs".len])) return error.MalformedDocsBlock;
        const raw_name = std.mem.trim(u8, tag["docs".len..], " \t\r\n");
        if (raw_name.len == 0 or std.mem.indexOfAny(u8, raw_name, " \t\r\n(){}") != null) return error.MalformedDocsBlock;

        const end_open = std.mem.indexOfPos(u8, text, close + 2, "{%") orelse return error.MalformedDocsBlock;
        const end_close = std.mem.indexOfPos(u8, text, end_open + 2, "%}") orelse return error.MalformedDocsBlock;
        const end_tag = std.mem.trim(u8, text[end_open + 2 .. end_close], " \t\r\n-");
        if (!std.mem.eql(u8, end_tag, "enddocs")) return error.MalformedDocsBlock;

        const block_contents = std.mem.trim(u8, text[close + 2 .. end_open], " \t\r\n");
        const unique_id = try std.fmt.allocPrint(runtime.allocator, "doc.{s}.{s}", .{ package_name, raw_name });
        try graph.docs.append(runtime.allocator, .{
            .package_name = package_name,
            .unique_id = unique_id,
            .name = try runtime.allocator.dupe(u8, raw_name),
            .path = relativeUnderResourcePath(relative_path, model_root),
            .original_file_path = relative_path,
            .block_contents = try runtime.allocator.dupe(u8, block_contents),
        });
        index = end_close + 2;
    }
}

fn parseYamlProperties(runtime: Runtime, project_dir: []const u8, resource_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    const path = try pathJoin(runtime.allocator, &.{ project_dir, relative_path });
    const text = try std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(4 * 1024 * 1024));

    try parseSourcesFromText(runtime.allocator, text, relative_path, package_name, graph);
    try parseExposuresFromText(runtime.allocator, text, resource_root, relative_path, package_name, graph);
    try parseModelPropertiesFromText(runtime.allocator, text, relative_path, package_name, graph);
    try parseMacroPropertiesFromText(runtime.allocator, text, relative_path, package_name, graph);
}

const TestTarget = enum {
    none,
    model,
    column,
};

fn parseModelPropertiesFromText(allocator: std.mem.Allocator, text: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    var in_models = false;
    var in_columns = false;
    var in_config = false;
    var test_target: TestTarget = .none;
    var active_test_target: TestTarget = .none;
    var active_values_target: TestTarget = .none;
    var models_indent: usize = 0;
    var model_item_indent: ?usize = null;
    var column_item_indent: ?usize = null;
    var config_indent: usize = 0;
    var tests_indent: usize = 0;
    var active_test_indent: usize = 0;
    var active_values_indent: usize = 0;
    var current_model: ?usize = null;
    var current_column: ?usize = null;
    var active_test_index: ?usize = null;
    var active_values_index: ?usize = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);

        if (std.mem.eql(u8, trimmed, "models:")) {
            in_models = true;
            in_columns = false;
            in_config = false;
            test_target = .none;
            active_test_target = .none;
            active_values_target = .none;
            models_indent = indent;
            model_item_indent = null;
            column_item_indent = null;
            current_model = null;
            current_column = null;
            active_test_index = null;
            active_values_index = null;
            continue;
        }
        if (!in_models) continue;
        if (indent <= models_indent and !std.mem.eql(u8, trimmed, "models:")) break;

        if (test_target != .none and indent <= tests_indent and !std.mem.startsWith(u8, trimmed, "- ")) {
            test_target = .none;
        }
        if (active_test_index != null and indent <= active_test_indent) {
            active_test_target = .none;
            active_test_index = null;
        }
        if (active_values_index != null and indent <= active_values_indent) {
            active_values_target = .none;
            active_values_index = null;
        }
        if (in_config and indent <= config_indent and !std.mem.eql(u8, trimmed, "config:")) {
            in_config = false;
        }
        if (in_columns and current_model != null and indent <= (model_item_indent orelse 0) and !std.mem.startsWith(u8, trimmed, "- name:")) {
            in_columns = false;
            current_column = null;
            column_item_indent = null;
            active_test_target = .none;
            active_test_index = null;
            active_values_target = .none;
            active_values_index = null;
        }

        if (std.mem.startsWith(u8, trimmed, "- ")) {
            if (active_values_index != null and indent > active_values_indent) {
                const test_def = try currentGenericTestDef(graph, current_model orelse return error.UnsupportedYaml, current_column, active_values_target, active_values_index.?);
                try test_def.accepted_values.append(allocator, try dupTrimmedScalar(allocator, trimmed[2..]));
                continue;
            }
            if (test_target != .none and indent > tests_indent) {
                const test_name = try testNameFromYamlItem(allocator, trimmed[2..]);
                if (test_target == .model) {
                    const model_index = current_model orelse return error.UnsupportedYaml;
                    active_test_index = try appendGenericTestDef(allocator, &graph.model_properties.items[model_index].tests, test_name);
                } else {
                    const model_index = current_model orelse return error.UnsupportedYaml;
                    const column_index = current_column orelse return error.UnsupportedYaml;
                    active_test_index = try appendGenericTestDef(allocator, &graph.model_properties.items[model_index].columns.items[column_index].tests, test_name);
                }
                active_test_target = test_target;
                active_test_indent = indent;
                if (std.mem.indexOfScalar(u8, std.mem.trim(u8, trimmed[2..], " \t\r"), ':') == null) {
                    active_test_target = .none;
                    active_test_index = null;
                }
                continue;
            }

            if (std.mem.startsWith(u8, trimmed, "- name:")) {
                const name = try dupTrimmedScalar(allocator, trimmed["- name:".len..]);
                if (in_columns and current_model != null and indent > (model_item_indent orelse 0)) {
                    const model_index = current_model.?;
                    try graph.model_properties.items[model_index].columns.append(allocator, .{ .name = name });
                    current_column = graph.model_properties.items[model_index].columns.items.len - 1;
                    column_item_indent = indent;
                    test_target = .none;
                    active_test_target = .none;
                    active_test_index = null;
                    active_values_target = .none;
                    active_values_index = null;
                    in_config = false;
                } else {
                    try graph.model_properties.append(allocator, .{ .package_name = package_name, .name = name, .patch_path = relative_path });
                    current_model = graph.model_properties.items.len - 1;
                    current_column = null;
                    model_item_indent = indent;
                    column_item_indent = null;
                    in_columns = false;
                    in_config = false;
                    test_target = .none;
                    active_test_target = .none;
                    active_test_index = null;
                    active_values_target = .none;
                    active_values_index = null;
                }
            }
            continue;
        }

        const model_index = current_model orelse continue;
        if (splitKeyValue(trimmed)) |kv| {
            if (active_test_index != null and indent > active_test_indent) {
                if (std.mem.eql(u8, kv.key, "arguments")) {
                    if (std.mem.trim(u8, kv.value, " \t").len != 0) return error.UnsupportedYaml;
                    continue;
                }

                const test_def = try currentGenericTestDef(graph, model_index, current_column, active_test_target, active_test_index.?);
                if (std.mem.eql(u8, kv.key, "values")) {
                    if (std.mem.trim(u8, kv.value, " \t").len == 0) {
                        active_values_target = active_test_target;
                        active_values_index = active_test_index;
                        active_values_indent = indent;
                    } else {
                        try parseInlineStringList(allocator, kv.value, &test_def.accepted_values);
                    }
                    continue;
                } else if (std.mem.eql(u8, kv.key, "to")) {
                    test_def.relationship_to = try dupTrimmedScalar(allocator, kv.value);
                    continue;
                } else if (std.mem.eql(u8, kv.key, "field")) {
                    test_def.relationship_field = try dupTrimmedScalar(allocator, kv.value);
                    continue;
                }
            }

            if (in_config and indent > config_indent) {
                if (std.mem.eql(u8, kv.key, "enabled")) {
                    graph.model_properties.items[model_index].enabled = try parseBool(kv.value);
                } else if (std.mem.eql(u8, kv.key, "materialized")) {
                    graph.model_properties.items[model_index].materialized = try dupTrimmedScalar(allocator, kv.value);
                } else if (std.mem.eql(u8, kv.key, "tags")) {
                    try parseInlineStringList(allocator, kv.value, &graph.model_properties.items[model_index].tags);
                    sortStrings(graph.model_properties.items[model_index].tags.items);
                }
                continue;
            }

            if (std.mem.eql(u8, kv.key, "description")) {
                if (in_columns and current_column != null and indent > (column_item_indent orelse 0)) {
                    graph.model_properties.items[model_index].columns.items[current_column.?].description = try dupTrimmedScalar(allocator, kv.value);
                } else {
                    graph.model_properties.items[model_index].description = try dupTrimmedScalar(allocator, kv.value);
                }
            } else if (std.mem.eql(u8, kv.key, "tags")) {
                try parseInlineStringList(allocator, kv.value, &graph.model_properties.items[model_index].tags);
                sortStrings(graph.model_properties.items[model_index].tags.items);
            } else if (std.mem.eql(u8, kv.key, "columns")) {
                if (std.mem.trim(u8, kv.value, " \t").len != 0) return error.UnsupportedYaml;
                in_columns = true;
                current_column = null;
                column_item_indent = null;
                test_target = .none;
                active_test_target = .none;
                active_test_index = null;
                active_values_target = .none;
                active_values_index = null;
            } else if (std.mem.eql(u8, kv.key, "tests") or std.mem.eql(u8, kv.key, "data_tests")) {
                if (std.mem.trim(u8, kv.value, " \t").len != 0) {
                    if (in_columns and current_column != null) {
                        try parseInlineGenericTestList(allocator, kv.value, &graph.model_properties.items[model_index].columns.items[current_column.?].tests);
                    } else {
                        try parseInlineGenericTestList(allocator, kv.value, &graph.model_properties.items[model_index].tests);
                    }
                } else {
                    test_target = if (in_columns and current_column != null) .column else .model;
                    tests_indent = indent;
                    active_test_target = .none;
                    active_test_index = null;
                    active_values_target = .none;
                    active_values_index = null;
                }
            } else if (std.mem.eql(u8, kv.key, "config")) {
                if (std.mem.trim(u8, kv.value, " \t").len != 0) return error.UnsupportedYaml;
                in_config = true;
                config_indent = indent;
            }
        }
    }
}

fn parseModel(runtime: Runtime, project_dir: []const u8, model_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    const full_path = try pathJoin(runtime.allocator, &.{ project_dir, relative_path });
    const sql = try std.Io.Dir.cwd().readFileAlloc(runtime.io, full_path, runtime.allocator, .limited(16 * 1024 * 1024));
    const model_name = try modelNameFromPath(runtime.allocator, relative_path);
    const unique_id = try std.fmt.allocPrint(runtime.allocator, "model.{s}.{s}", .{ package_name, model_name });
    const model_path = relativeUnderResourcePath(relative_path, model_root);

    var node = Node{
        .package_name = package_name,
        .unique_id = unique_id,
        .name = model_name,
        .path = model_path,
        .original_file_path = relative_path,
        .raw_code = sql,
    };
    errdefer {
        deinitNode(runtime.allocator, &node);
    }
    try project_jinja.scanSql(runtime.allocator, sql, &node, graph);
    try graph.nodes.append(runtime.allocator, node);
}

fn parseSeed(runtime: Runtime, seed_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    const seed_name = try resourceNameFromPath(runtime.allocator, relative_path, ".csv");
    const unique_id = try std.fmt.allocPrint(runtime.allocator, "seed.{s}.{s}", .{ package_name, seed_name });
    const seed_path = relativeUnderResourcePath(relative_path, seed_root);

    var node = Node{
        .resource_type = "seed",
        .package_name = package_name,
        .unique_id = unique_id,
        .name = seed_name,
        .path = seed_path,
        .original_file_path = relative_path,
        .raw_code = "",
        .materialized = "seed",
    };
    errdefer {
        deinitNode(runtime.allocator, &node);
    }
    try graph.nodes.append(runtime.allocator, node);
}

fn applyModelProperties(graph: *Graph, package_name: []const u8) !void {
    for (graph.model_properties.items) |property| {
        if (!std.mem.eql(u8, property.package_name, package_name)) continue;
        const node_index = findModelIndexByName(graph, property.package_name, property.name) orelse {
            try graph.unmatched_model_properties.append(graph.allocator, .{ .name = property.name, .patch_path = property.patch_path });
            continue;
        };
        var node = &graph.nodes.items[node_index];
        node.patch_path = property.patch_path;
        if (property.description.len != 0) node.description = try resolveDocDescription(graph, property.package_name, property.description, &node.doc_blocks);
        if (property.materialized.len != 0 and !node.inline_materialized) node.materialized = property.materialized;
        if (property.enabled) |enabled| node.enabled = enabled;
        for (property.tags.items) |tag| {
            try appendUnique(graph.allocator, &node.tags, tag);
        }
        sortStrings(node.tags.items);
        for (property.tests.items) |test_def| {
            try appendGenericTestDefClone(graph, &node.tests, test_def);
        }
        sortGenericTestDefs(node.tests.items);
        for (property.columns.items) |column| {
            try appendColumnClone(graph, property.package_name, &node.columns, column);
        }
        sortColumns(node.columns.items);
    }
}

fn materializeGenericTests(graph: *Graph) !void {
    for (graph.nodes.items) |*node| {
        if (!node.enabled or !std.mem.eql(u8, node.resource_type, "model")) continue;
        for (node.tests.items) |test_def| {
            if (isSupportedGenericTest(test_def)) {
                try appendGenericTestNode(graph, node, test_def, null);
            }
        }
        for (node.columns.items) |column| {
            for (column.tests.items) |test_def| {
                if (isSupportedGenericTest(test_def)) {
                    try appendGenericTestNode(graph, node, test_def, column.name);
                }
            }
        }
    }
}

fn appendGenericTestNode(graph: *Graph, node: *const Node, test_def: GenericTestDef, column_name: ?[]const u8) !void {
    const names = try synthesizeGenericTestNames(graph.allocator, test_def, node.name, column_name);
    const unique_id = try genericTestUniqueId(graph.allocator, node.package_name, names.full, test_def, node.name, column_name);
    for (graph.tests.items) |existing| {
        if (std.mem.eql(u8, existing.unique_id, unique_id)) return;
    }

    const raw_code = if (std.mem.eql(u8, names.compiled, names.full))
        try std.fmt.allocPrint(graph.allocator, "{{{{ test_{s}(**_dbt_generic_test_kwargs) }}}}", .{test_def.name})
    else
        try std.fmt.allocPrint(graph.allocator, "{{{{ test_{s}(**_dbt_generic_test_kwargs) }}}}{{{{ config(alias=\"{s}\") }}}}", .{ test_def.name, names.compiled });
    var test_node = GenericTestNode{
        .package_name = node.package_name,
        .unique_id = unique_id,
        .name = names.full,
        .alias = names.compiled,
        .path = try std.fmt.allocPrint(graph.allocator, "{s}.sql", .{names.compiled}),
        .original_file_path = node.patch_path orelse node.original_file_path,
        .raw_code = raw_code,
        .test_name = test_def.name,
        .column_name = column_name,
        .relationship_to = test_def.relationship_to,
        .relationship_field = test_def.relationship_field,
        .attached_node = node.unique_id,
    };
    errdefer deinitGenericTestNode(graph.allocator, &test_node);

    for (test_def.accepted_values.items) |value| {
        try test_node.accepted_values.append(graph.allocator, value);
    }
    if (std.mem.eql(u8, test_def.name, "relationships")) {
        const target_ref = try refDepFromValue(graph.allocator, test_def.relationship_to);
        try test_node.refs.append(graph.allocator, target_ref);
        const target_unique_id = try resolveRefDependency(graph, node.package_name, target_ref);
        try test_node.depends_on.append(graph.allocator, target_unique_id);
    }
    try test_node.refs.append(graph.allocator, .{ .package = null, .name = node.name });
    try test_node.depends_on.append(graph.allocator, node.unique_id);
    try test_node.macro_depends_on.append(graph.allocator, try std.fmt.allocPrint(graph.allocator, "macro.dbt.test_{s}", .{test_def.name}));
    if (!std.mem.eql(u8, test_def.name, "not_null") and !std.mem.eql(u8, test_def.name, "unique")) {
        try test_node.macro_depends_on.append(graph.allocator, "macro.dbt.get_where_subquery");
    }
    try graph.tests.append(graph.allocator, test_node);
}

fn isSupportedGenericTest(test_def: GenericTestDef) bool {
    return std.mem.eql(u8, test_def.name, "not_null") or
        std.mem.eql(u8, test_def.name, "unique") or
        (std.mem.eql(u8, test_def.name, "accepted_values") and test_def.accepted_values.items.len != 0) or
        (std.mem.eql(u8, test_def.name, "relationships") and test_def.relationship_to.len != 0 and test_def.relationship_field.len != 0);
}

fn writeWarnings(stderr: *Io.Writer, graph: *const Graph) !void {
    for (graph.unmatched_model_properties.items) |property| {
        try stderr.print("warning: did not find matching node for model property `{s}` in {s}\n", .{ property.name, util.normalizeForDisplay(property.patch_path) });
    }
    for (graph.unmatched_macro_properties.items) |property| {
        try stderr.print("warning: did not find matching macro for macro property `{s}` in {s}\n", .{ property.name, util.normalizeForDisplay(property.patch_path) });
    }
    for (graph.macro_argument_warnings.items) |warning| {
        try stderr.print("warning: {s}\n", .{warning});
    }
}

fn appendColumnClone(graph: *Graph, package_name: []const u8, columns: *std.ArrayList(ColumnDef), source: ColumnDef) !void {
    for (columns.items) |*existing| {
        if (std.mem.eql(u8, existing.name, source.name)) {
            if (source.description.len != 0) existing.description = try resolveDocDescription(graph, package_name, source.description, &existing.doc_blocks);
            for (source.tests.items) |test_def| {
                try appendGenericTestDefClone(graph, &existing.tests, test_def);
            }
            sortGenericTestDefs(existing.tests.items);
            return;
        }
    }

    var column = ColumnDef{ .name = source.name };
    errdefer {
        column.doc_blocks.deinit(graph.allocator);
        column.tests.deinit(graph.allocator);
    }
    if (source.description.len != 0) column.description = try resolveDocDescription(graph, package_name, source.description, &column.doc_blocks);
    for (source.tests.items) |test_def| {
        try appendGenericTestDefClone(graph, &column.tests, test_def);
    }
    sortGenericTestDefs(column.tests.items);
    try columns.append(graph.allocator, column);
}

fn resolveMacroDependencies(graph: *Graph) !void {
    for (graph.macros.items) |*macro| {
        try project_jinja.scanMacroSqlForKnownMacroCalls(graph.allocator, macro.macro_sql, graph, macro.unique_id, &macro.macro_depends_on);
        sortStrings(macro.macro_depends_on.items);
    }
}

fn resolveDocDescription(graph: *Graph, package_name: []const u8, description: []const u8, doc_blocks: *std.ArrayList([]const u8)) ![]const u8 {
    const trimmed = std.mem.trim(u8, description, " \t\r\n");
    if (std.mem.indexOf(u8, trimmed, "{{") == null) return description;
    if (!std.mem.startsWith(u8, trimmed, "{{") or !std.mem.endsWith(u8, trimmed, "}}")) return error.UnsupportedDynamicDoc;

    const span = std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t\r\n-");
    if (!std.mem.startsWith(u8, span, "doc")) return error.UnsupportedDynamicDoc;
    const call_pos = skipWs(span, "doc".len);
    if (call_pos >= span.len or span[call_pos] != '(') return error.UnsupportedDynamicDoc;
    const close = findMatchingParen(span, call_pos) orelse return error.UnsupportedDynamicDoc;
    if (std.mem.trim(u8, span[close + 1 ..], " \t\r\n").len != 0) return error.UnsupportedDynamicDoc;
    var strings = try parseLiteralArgs(graph.allocator, span[call_pos + 1 .. close], error.UnsupportedDynamicDoc);
    defer strings.deinit(graph.allocator);
    if (strings.items.len != 1) return error.UnsupportedDynamicDoc;

    const unique_id = try std.fmt.allocPrint(graph.allocator, "doc.{s}.{s}", .{ package_name, strings.items[0] });
    const doc = findDoc(graph, unique_id) orelse return error.UnresolvedDoc;
    try appendUnique(graph.allocator, doc_blocks, doc.unique_id);
    sortStrings(doc_blocks.items);
    return doc.block_contents;
}

fn currentGenericTestDef(graph: *Graph, model_index: usize, current_column: ?usize, target: TestTarget, test_index: usize) !*GenericTestDef {
    if (target == .model) return &graph.model_properties.items[model_index].tests.items[test_index];
    if (target == .column) {
        const column_index = current_column orelse return error.UnsupportedYaml;
        return &graph.model_properties.items[model_index].columns.items[column_index].tests.items[test_index];
    }
    return error.UnsupportedYaml;
}

fn sortGenericTestDefs(tests: []GenericTestDef) void {
    std.mem.sort(GenericTestDef, tests, {}, struct {
        fn lessThan(_: void, a: GenericTestDef, b: GenericTestDef) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}

fn sortColumns(columns: []ColumnDef) void {
    std.mem.sort(ColumnDef, columns, {}, struct {
        fn lessThan(_: void, a: ColumnDef, b: ColumnDef) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}
