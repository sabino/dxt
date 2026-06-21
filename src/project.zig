const std = @import("std");
const Io = std.Io;
const catalog = @import("project/catalog.zig");
const clean = @import("project/clean.zig");
const compiler = @import("project/compiler.zig");
const docs_serve = @import("project/docs_serve.zig");
const duckdb = @import("project/duckdb.zig");
const project_fs = @import("project/fs.zig");
const project_jinja = @import("project/jinja.zig");
const project_loader = @import("project/loader.zig");
const project_parse = @import("project/parse.zig");
const project_resolve = @import("project/resolve.zig");
const selector_config = @import("project/selector_config.zig");
const manifest = @import("project/manifest.zig");
const run_results = @import("project/run_results.zig");
const selector = @import("project/selector.zig");
const source_freshness = @import("project/source_freshness.zig");
const state_artifacts = @import("project/state.zig");
const types = @import("project/types.zig");
const util = @import("project/util.zig");

const execution_failure_message = "DuckDB execution failed";

pub const Runtime = types.Runtime;
pub const Options = types.Options;
pub const Output = types.Output;
pub const validateSelectorSyntax = selector.validateSelectorSyntax;

const ColumnDef = types.ColumnDef;
const GenericTestDef = types.GenericTestDef;
const DocBlock = types.DocBlock;
const ModelProperty = types.ModelProperty;
const Node = types.Node;
const GenericTestNode = types.GenericTestNode;
const SingularTestNode = types.SingularTestNode;
const UnitTestDef = types.UnitTestDef;
const SourceDef = types.SourceDef;
const SourceDep = types.SourceDep;
const Graph = types.Graph;
const deinitNode = types.deinitNode;
const deinitGenericTestNode = types.deinitGenericTestNode;
const deinitSingularTestNode = types.deinitSingularTestNode;
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
const applyGenericTestConfigValue = project_parse.applyGenericTestConfigValue;
const parseBool = project_parse.parseBool;
const parseExposuresFromText = project_parse.parseExposuresFromText;
const genericTestUniqueId = project_parse.genericTestUniqueId;
const genericTestUniqueIdForModelKwarg = project_parse.genericTestUniqueIdForModelKwarg;
const parseInlineGenericTestList = project_parse.parseInlineGenericTestList;
const parseMacroPropertiesFromText = project_parse.parseMacroPropertiesFromText;
const parseMacros = project_parse.parseMacros;
const parseSourcesFromText = project_parse.parseSourcesFromText;
const parseUnitTestsFromText = project_parse.parseUnitTestsFromText;
const refDepFromValue = project_parse.refDepFromValue;
const sourceDepFromValue = project_parse.sourceDepFromValue;
const synthesizeGenericTestNames = project_parse.synthesizeGenericTestNames;
const testNameFromYamlItem = project_parse.testNameFromYamlItem;
const findMatchingParen = project_jinja.findMatchingParen;
const parseLiteralArgs = project_jinja.parseLiteralArgs;
const skipWs = project_jinja.skipWs;
const appendUnique = util.appendUnique;
const sortStrings = util.sortStrings;
const countActiveExposures = project_resolve.countActiveExposures;
const countActiveNodes = project_resolve.countActiveNodes;
const countActiveAnalyses = project_resolve.countActiveAnalyses;
const countActiveSeeds = project_resolve.countActiveSeeds;
const findDoc = project_resolve.findDoc;
const findNodeIndexByResourceTypeAndName = project_resolve.findNodeIndexByResourceTypeAndName;
const resolveDependencies = project_resolve.resolveDependencies;
const findMacroIdByPackageAndName = project_resolve.findMacroIdByPackageAndName;
const resolveRefDependency = project_resolve.resolveRefDependency;
const resolveSourceDependency = project_resolve.resolveSourceDependency;

const loader_callbacks = project_loader.Callbacks{
    .parse_doc_blocks = parseDocBlocks,
    .parse_yaml_properties = parseYamlProperties,
    .parse_macros = parseMacros,
    .parse_model = parseModel,
    .parse_analysis = parseAnalysis,
    .parse_singular_test = parseSingularTest,
    .parse_seed = parseSeed,
    .apply_model_properties = applyModelProperties,
    .apply_singular_test_properties = applySingularTestProperties,
    .materialize_generic_tests = materializeGenericTests,
    .resolve_macro_dependencies = resolveMacroDependencies,
};

pub fn parse(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    if (options.selector != null) {
        var selection = try resolveSelection(runtime, options);
        defer selection.deinit(runtime.allocator);
    }
    try writeWarnings(stderr, &graph);
    const active_models = countActiveNodes(&graph);
    const active_analyses = countActiveAnalyses(&graph);
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
    try stdout.print("Parsed {d} model(s), {d} analysis(es), {d} seed(s), {d} source(s), {d} exposure(s), and {d} unit test(s) into {s}\n", .{
        active_models,
        active_analyses,
        active_seeds,
        graph.sources.items.len,
        countActiveExposures(&graph),
        graph.unit_tests.items.len,
        util.normalizeForDisplay(manifest_path),
    });
}

pub fn list(runtime: Runtime, options: Options, stdout: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var selection_state = try loadSelectionState(runtime, options, selection);
    defer selection_state.deinit(runtime.allocator);
    const resource_type = if (options.resource_type) |value| try runtime.allocator.dupe(u8, value) else null;
    const selected = try selector.selectResourcesWithContext(runtime.allocator, &graph, resource_type, selection.select, selection.exclude, selection_state.context());
    switch (options.output) {
        .json => try manifest.writeSelectedJsonWithKeys(stdout, selected, options.output_keys),
        .name => {
            for (selected) |item| {
                try stdout.print("{s}\n", .{item.search_name});
            }
        },
        .path => {
            for (selected) |item| {
                try stdout.print("{s}\n", .{item.original_file_path});
            }
        },
        .selector => {
            for (selected) |item| {
                try stdout.print("{s}\n", .{item.selector});
            }
        },
        .text => {
            for (selected) |item| {
                try stdout.print("{s}\n", .{item.unique_id});
            }
        },
    }
}

pub fn cleanProject(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    _ = stderr;
    try clean.run(runtime, options, stdout);
}

pub fn compile(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    try writeWarnings(stderr, &graph);

    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var selection_state = try loadSelectionState(runtime, options, selection);
    defer selection_state.deinit(runtime.allocator);
    const selected = try selector.selectResourcesWithContext(runtime.allocator, &graph, null, selection.select, selection.exclude, selection_state.context());

    const target_dir = try targetDir(runtime, options);
    const compile_result = try compileSelectedModels(runtime, &graph, selected, target_dir, true, true);
    if (selected.len != 0 and !compile_result.saw_model and !compile_result.saw_analysis and !compile_result.saw_generic_test and !compile_result.saw_singular_test) return error.UnsupportedCompileSelection;

    const manifest_path = try pathJoin(runtime.allocator, &.{ target_dir, "manifest.json" });
    const manifest_json = try manifest.renderManifest(runtime.allocator, &graph);
    try std.Io.Dir.cwd().createDirPath(runtime.io, target_dir);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = manifest_path, .data = manifest_json });
    if (compile_result.analysis_count == 0) {
        try stdout.print("Compiled {d} model(s) and {d} test(s) into {s}\n", .{
            compile_result.count,
            compile_result.test_count,
            util.normalizeForDisplay(compile_result.compiled_base),
        });
    } else {
        try stdout.print("Compiled {d} model(s), {d} analysis(es), and {d} test(s) into {s}\n", .{
            compile_result.count,
            compile_result.analysis_count,
            compile_result.test_count,
            util.normalizeForDisplay(compile_result.compiled_base),
        });
    }
}

pub fn docsGenerate(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    try writeWarnings(stderr, &graph);

    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var selection_state = try loadSelectionState(runtime, options, selection);
    defer selection_state.deinit(runtime.allocator);
    const selected = try selector.selectResourcesWithContext(runtime.allocator, &graph, null, selection.select, selection.exclude, selection_state.context());

    const target_dir = try targetDir(runtime, options);
    const compile_result = try compileSelectedModels(runtime, &graph, selected, target_dir, false, false);

    const manifest_path = try pathJoin(runtime.allocator, &.{ target_dir, "manifest.json" });
    const manifest_json = try manifest.renderManifest(runtime.allocator, &graph);
    try std.Io.Dir.cwd().createDirPath(runtime.io, target_dir);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = manifest_path, .data = manifest_json });

    var catalog_entries: catalog.CatalogEntries = .{};
    defer catalog.deinitCatalogEntries(runtime.allocator, &catalog_entries);
    if (duckdb.databasePath(runtime.allocator, target_dir, &graph)) |db_path| {
        defer runtime.allocator.free(db_path);
        catalog_entries = try duckdb.collectCatalogEntries(runtime, db_path, &graph, selected);
    } else |err| switch (err) {
        error.UnsupportedDuckDbPath => {},
        else => return err,
    }

    const catalog_path = try pathJoin(runtime.allocator, &.{ target_dir, "catalog.json" });
    const catalog_json = try catalog.renderCatalog(runtime.allocator, catalog_entries.nodes.items, catalog_entries.sources.items);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = catalog_path, .data = catalog_json });

    try stdout.print("Generated docs artifacts for {d} compiled model(s) into {s}\n", .{
        compile_result.count,
        util.normalizeForDisplay(target_dir),
    });
}

pub fn docsServe(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    _ = stderr;
    const target_dir = try targetDir(runtime, options);
    try docs_serve.serve(runtime, options, target_dir, stdout);
}

pub fn sourceFreshness(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    try writeWarnings(stderr, &graph);

    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var selection_state = try loadSelectionState(runtime, options, selection);
    defer selection_state.deinit(runtime.allocator);
    const selection_context = selection_state.context();
    const selected_sources = try selector.selectResourcesWithContext(runtime.allocator, &graph, "source", selection.select, selection.exclude, selection_context);
    if (selected_sources.len == 0 and selection.select != null) {
        const selected_any = try selector.selectResourcesWithContext(runtime.allocator, &graph, null, selection.select, selection.exclude, selection_context);
        if (selected_any.len != 0) return error.UnsupportedSourceFreshnessSelection;
    }

    const target_dir = try targetDir(runtime, options);
    const manifest_path = try writeManifest(runtime, &graph, target_dir);

    var results: std.ArrayList(source_freshness.CheckResult) = .empty;
    defer {
        source_freshness.deinitResults(runtime.allocator, results.items);
        results.deinit(runtime.allocator);
    }

    var runnable_count: usize = 0;
    var had_failure = false;
    for (graph.sources.items) |*source| {
        if (!selectionContains(selected_sources, source.unique_id)) continue;
        if (!source_freshness.isRunnableSource(source)) continue;
        runnable_count += 1;
    }

    if (runnable_count != 0) {
        if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedSourceFreshnessAdapter;
        const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
        defer runtime.allocator.free(db_path);

        for (graph.sources.items) |*source| {
            if (!selectionContains(selected_sources, source.unique_id)) continue;
            if (!source_freshness.isRunnableSource(source)) continue;
            if (source_freshness.unsupportedExecutionReason(source)) |message| {
                try appendSourceFreshnessRuntimeError(runtime.allocator, &results, source, message);
                had_failure = true;
                continue;
            }
            source_freshness.validateThreshold(source.freshness.?) catch {
                try appendSourceFreshnessRuntimeError(runtime.allocator, &results, source, "source freshness currently requires complete freshness thresholds");
                had_failure = true;
                continue;
            };
            if (source.loaded_at_field == null and source.loaded_at_query == null) {
                try appendSourceFreshnessRuntimeError(runtime.allocator, &results, source, source_freshness.unsupported_metadata_freshness_message);
                had_failure = true;
                continue;
            }
            const query_result = duckdb.querySourceFreshness(runtime, db_path, source) catch |err| switch (err) {
                error.DuckDbCliNotFound => return error.DuckDbCliNotFound,
                else => {
                    const message = try formatSourceFreshnessError(runtime.allocator, err);
                    try appendOwnedSourceFreshnessRuntimeError(runtime.allocator, &results, source, message);
                    had_failure = true;
                    continue;
                },
            };
            const status = try source_freshness.statusForAge(query_result.age_seconds, source.freshness.?);
            if (std.mem.eql(u8, status, "error")) had_failure = true;
            results.append(runtime.allocator, .{
                .source = source,
                .status = status,
                .max_loaded_at = query_result.max_loaded_at,
                .snapshotted_at = query_result.snapshotted_at,
                .age_seconds = query_result.age_seconds,
            }) catch |err| {
                duckdb.deinitFreshnessQueryResult(runtime.allocator, query_result);
                return err;
            };
        }
    }

    const sources_path = try pathJoin(runtime.allocator, &.{ target_dir, "sources.json" });
    const sources_json = try source_freshness.renderSources(runtime.allocator, results.items);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = sources_path, .data = sources_json });
    try stdout.print("Checked freshness for {d} source(s); wrote artifacts into {s}\n", .{
        results.items.len,
        util.normalizeForDisplay(manifest_path),
    });
    if (had_failure) return error.SourceFreshnessFailure;
}

pub fn runPreflight(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    try writeWarnings(stderr, &graph);

    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var selection_state = try loadSelectionState(runtime, options, selection);
    defer selection_state.deinit(runtime.allocator);
    const selection_context = selection_state.context();
    const selected_models = try selector.selectResourcesWithContext(runtime.allocator, &graph, "model", selection.select, selection.exclude, selection_context);
    if (selected_models.len == 0 and selection.select != null) {
        const selected_any = try selector.selectResourcesWithContext(runtime.allocator, &graph, null, selection.select, selection.exclude, selection_context);
        if (selected_any.len != 0) return error.UnsupportedRunSelection;
    }

    const execution_order = try selectedModelExecutionOrder(runtime, &graph, selected_models);
    defer runtime.allocator.free(execution_order);
    if (execution_order.len == 0) return error.UnsupportedRunSelection;
    try validateRunMaterializations(execution_order);

    const target_dir = try targetDir(runtime, options);
    const compile_result = try compileSelectedModels(runtime, &graph, selected_models, target_dir, false, false);
    const manifest_path = try writeManifest(runtime, &graph, target_dir);
    if (compile_result.count == 0) return error.UnsupportedRunSelection;
    if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedAdapterExecution;
    const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
    var executed: std.ArrayList(run_results.NodeResult) = .empty;
    defer {
        deinitRunResults(runtime.allocator, executed.items);
        executed.deinit(runtime.allocator);
    }
    var blocked: std.ArrayList([]const u8) = .empty;
    defer blocked.deinit(runtime.allocator);
    var had_failure = false;
    for (execution_order) |node| {
        if (try appendSkippedIfNodeDependsOnBlocked(runtime.allocator, &blocked, node, &executed)) {
            continue;
        }
        if (!try executeModelAppendingResult(runtime, db_path, &graph, node, &executed)) {
            try appendUniqueString(runtime.allocator, &blocked, node.unique_id);
            had_failure = true;
        }
    }
    if (had_failure) return failExecution(runtime, target_dir, manifest_path, db_path, executed.items, stdout, "Run");

    try writeRunResults(runtime, target_dir, executed.items);
    try stdout.print("Ran {d} model(s) into {s}; wrote artifacts into {s}\n", .{
        executed.items.len,
        util.normalizeForDisplay(db_path),
        util.normalizeForDisplay(manifest_path),
    });
}

pub fn seedPreflight(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    try writeWarnings(stderr, &graph);

    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var selection_state = try loadSelectionState(runtime, options, selection);
    defer selection_state.deinit(runtime.allocator);
    const selection_context = selection_state.context();
    const selected_seeds = try selector.selectResourcesWithContext(runtime.allocator, &graph, "seed", selection.select, selection.exclude, selection_context);
    if (selected_seeds.len == 0) {
        if (selection.select != null) {
            const selected_any = try selector.selectResourcesWithContext(runtime.allocator, &graph, null, selection.select, selection.exclude, selection_context);
            if (selected_any.len != 0) return error.UnsupportedSeedSelection;
        }
        return error.UnsupportedSeedSelection;
    }

    if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedSeedAdapterExecution;
    const seed_nodes = try selectedSeedExecutionOrder(runtime, &graph, selected_seeds);
    defer runtime.allocator.free(seed_nodes);
    try validateSeedExecution(&graph, seed_nodes);

    const target_dir = try targetDir(runtime, options);
    const manifest_path = try writeManifest(runtime, &graph, target_dir);
    const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
    var executed: std.ArrayList(run_results.NodeResult) = .empty;
    defer {
        deinitRunResults(runtime.allocator, executed.items);
        executed.deinit(runtime.allocator);
    }
    for (seed_nodes, 0..) |node, index| {
        if (!try executeSeedAppendingResult(runtime, db_path, options.project_dir, &graph, node, &executed)) {
            try appendSkippedAfterExecutionFailure(runtime.allocator, selected_seeds, seed_nodes[index + 1 ..], &.{}, node.unique_id, &executed);
            return failExecution(runtime, target_dir, manifest_path, db_path, executed.items, stdout, "Seed");
        }
    }

    try writeRunResults(runtime, target_dir, executed.items);
    try stdout.print("Seeded {d} seed(s) into {s}; wrote artifacts into {s}\n", .{
        executed.items.len,
        util.normalizeForDisplay(db_path),
        util.normalizeForDisplay(manifest_path),
    });
}

pub fn testPreflight(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    try writeWarnings(stderr, &graph);

    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var selection_state = try loadSelectionState(runtime, options, selection);
    defer selection_state.deinit(runtime.allocator);
    const selection_context = selection_state.context();
    const selected = try selector.selectResourcesWithContext(runtime.allocator, &graph, "test", selection.select, selection.exclude, selection_context);
    const selected_unit_tests = try selector.selectResourcesWithContext(runtime.allocator, &graph, "unit_test", selection.select, selection.exclude, selection_context);
    if (selected.len == 0 and selected_unit_tests.len == 0) {
        if (selection.select != null) {
            const selected_any = try selector.selectResourcesWithContext(runtime.allocator, &graph, null, selection.select, selection.exclude, selection_context);
            if (selected_any.len != 0) return error.UnsupportedTestExecution;
        }
        return error.UnsupportedTestSelection;
    }

    if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedTestExecution;
    const test_nodes = try selectedDataTestExecutionOrder(runtime, &graph, selected);
    defer runtime.allocator.free(test_nodes);
    try validateDataTestExecution(test_nodes);
    const unit_test_nodes = try selectedUnitTestExecutionOrder(runtime, &graph, selected_unit_tests);
    defer runtime.allocator.free(unit_test_nodes);
    try validateUnitTestExecution(runtime, &graph, unit_test_nodes);

    const target_dir = try targetDir(runtime, options);
    const manifest_path = try writeManifest(runtime, &graph, target_dir);
    const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
    var executed: std.ArrayList(run_results.NodeResult) = .empty;
    defer {
        deinitRunResults(runtime.allocator, executed.items);
        executed.deinit(runtime.allocator);
    }
    const test_summary = try appendDataTestResults(runtime, db_path, &graph, test_nodes, &executed);
    const unit_test_summary = try appendUnitTestResults(runtime, db_path, &graph, unit_test_nodes, &executed);

    try writeRunResults(runtime, target_dir, executed.items);
    try stdout.print("Tested {d} test(s) against {s}; wrote artifacts into {s}\n", .{
        executed.items.len,
        util.normalizeForDisplay(db_path),
        util.normalizeForDisplay(manifest_path),
    });
    const failed_tests = test_summary.failed_tests + unit_test_summary.failed_tests;
    const total_failures = test_summary.total_failures + unit_test_summary.total_failures;
    if (failed_tests != 0) {
        try stdout.print("{d} test(s) failed with {d} failure row(s)\n", .{ failed_tests, total_failures });
        return error.TestFailure;
    }
}

pub fn buildPreflight(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    try writeWarnings(stderr, &graph);

    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var selection_state = try loadSelectionState(runtime, options, selection);
    defer selection_state.deinit(runtime.allocator);
    const selected = try selector.selectResourcesWithContext(runtime.allocator, &graph, null, selection.select, selection.exclude, selection_state.context());

    const target_dir = try targetDir(runtime, options);
    const compile_result = try compileSelectedModels(runtime, &graph, selected, target_dir, false, false);
    const manifest_path = try writeManifest(runtime, &graph, target_dir);
    const selected_kinds = classifyBuildSelection(selected);
    if (selected_kinds.total == 0) return error.UnsupportedBuildSelection;
    if (selected_kinds.seed == selected_kinds.total) {
        if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedSeedAdapterExecution;
        const seed_nodes = try selectedSeedExecutionOrder(runtime, &graph, selected);
        defer runtime.allocator.free(seed_nodes);
        try validateSeedExecution(&graph, seed_nodes);

        const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
        var executed: std.ArrayList(run_results.NodeResult) = .empty;
        defer {
            deinitRunResults(runtime.allocator, executed.items);
            executed.deinit(runtime.allocator);
        }
        var blocked: std.ArrayList([]const u8) = .empty;
        defer blocked.deinit(runtime.allocator);
        var had_failure = false;
        for (seed_nodes) |node| {
            if (try appendSkippedIfNodeDependsOnBlocked(runtime.allocator, &blocked, node, &executed)) continue;
            if (!try executeSeedAppendingResult(runtime, db_path, options.project_dir, &graph, node, &executed)) {
                try appendUniqueString(runtime.allocator, &blocked, node.unique_id);
                had_failure = true;
            }
        }
        if (had_failure) return failExecution(runtime, target_dir, manifest_path, db_path, executed.items, stdout, "Build");

        try writeRunResults(runtime, target_dir, executed.items);
        try stdout.print("Built {d} seed(s) into {s}; wrote artifacts into {s}\n", .{
            executed.items.len,
            util.normalizeForDisplay(db_path),
            util.normalizeForDisplay(manifest_path),
        });
        return;
    }
    if (selected_kinds.seed != 0 and selected_kinds.model == 0 and selected_kinds.seed + selected_kinds.test_resource == selected_kinds.total) {
        if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedBuildAdapterExecution;
        const seed_nodes = try selectedSeedExecutionOrder(runtime, &graph, selected);
        defer runtime.allocator.free(seed_nodes);
        try validateSeedExecution(&graph, seed_nodes);

        const test_nodes = try selectedDataTestExecutionOrder(runtime, &graph, selected);
        defer runtime.allocator.free(test_nodes);
        try validateDataTestExecution(test_nodes);
        try validateDataTestsAttachToSelectedNodes(test_nodes, selected);

        const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
        var executed: std.ArrayList(run_results.NodeResult) = .empty;
        defer {
            deinitRunResults(runtime.allocator, executed.items);
            executed.deinit(runtime.allocator);
        }
        var executed_node_ids: std.ArrayList([]const u8) = .empty;
        defer executed_node_ids.deinit(runtime.allocator);
        const executed_tests = try runtime.allocator.alloc(bool, test_nodes.len);
        defer runtime.allocator.free(executed_tests);
        @memset(executed_tests, false);
        var blocked: std.ArrayList([]const u8) = .empty;
        defer blocked.deinit(runtime.allocator);
        var had_execution_failure = false;
        var test_failures = GenericTestExecutionSummary{};
        for (seed_nodes) |node| {
            if (try appendSkippedIfNodeDependsOnBlocked(runtime.allocator, &blocked, node, &executed)) {
                try appendSkippedBlockedDataTests(runtime.allocator, selected, test_nodes, executed_tests, blocked.items, &executed);
                continue;
            }
            if (!try executeSeedAppendingResult(runtime, db_path, options.project_dir, &graph, node, &executed)) {
                try appendUniqueString(runtime.allocator, &blocked, node.unique_id);
                had_execution_failure = true;
                try appendSkippedBlockedDataTests(runtime.allocator, selected, test_nodes, executed_tests, blocked.items, &executed);
                continue;
            }
            try executed_node_ids.append(runtime.allocator, node.unique_id);
            var failed_test_blockers: std.ArrayList([]const u8) = .empty;
            defer failed_test_blockers.deinit(runtime.allocator);
            const test_summary = try appendReadyDataTestResults(runtime, db_path, &graph, test_nodes, executed_tests, executed_node_ids.items, &executed, &failed_test_blockers);
            if (test_summary.failed_tests != 0) {
                try appendBlockedRoots(runtime.allocator, &blocked, failed_test_blockers.items);
                test_failures.failed_tests += test_summary.failed_tests;
                test_failures.total_failures += test_summary.total_failures;
            }
        }
        try appendSkippedBlockedDataTests(runtime.allocator, selected, test_nodes, executed_tests, blocked.items, &executed);
        const test_summary = try appendRemainingReadyDataTestResults(runtime, db_path, &graph, test_nodes, executed_tests, executed_node_ids.items, &executed);
        test_failures.failed_tests += test_summary.failed_tests;
        test_failures.total_failures += test_summary.total_failures;
        if (had_execution_failure) return failExecution(runtime, target_dir, manifest_path, db_path, executed.items, stdout, "Build");

        try writeRunResults(runtime, target_dir, executed.items);
        try stdout.print("Built {d} seed(s) and {d} test(s) into {s}; wrote artifacts into {s}\n", .{
            seed_nodes.len,
            test_nodes.len,
            util.normalizeForDisplay(db_path),
            util.normalizeForDisplay(manifest_path),
        });
        if (test_failures.failed_tests != 0) {
            try stdout.print("{d} test(s) failed with {d} failure row(s)\n", .{ test_failures.failed_tests, test_failures.total_failures });
            return error.TestFailure;
        }
        return;
    }
    if (selected_kinds.test_resource + selected_kinds.unit_test == selected_kinds.total) {
        if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedTestExecution;
        const test_nodes = try selectedDataTestExecutionOrder(runtime, &graph, selected);
        defer runtime.allocator.free(test_nodes);
        try validateDataTestExecution(test_nodes);
        const unit_test_nodes = try selectedUnitTestExecutionOrder(runtime, &graph, selected);
        defer runtime.allocator.free(unit_test_nodes);
        try validateUnitTestExecution(runtime, &graph, unit_test_nodes);

        const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
        var executed: std.ArrayList(run_results.NodeResult) = .empty;
        defer {
            deinitRunResults(runtime.allocator, executed.items);
            executed.deinit(runtime.allocator);
        }
        const test_summary = try appendDataTestResults(runtime, db_path, &graph, test_nodes, &executed);
        const unit_test_summary = try appendUnitTestResults(runtime, db_path, &graph, unit_test_nodes, &executed);

        try writeRunResults(runtime, target_dir, executed.items);
        try stdout.print("Built {d} test(s) against {s}; wrote artifacts into {s}\n", .{
            executed.items.len,
            util.normalizeForDisplay(db_path),
            util.normalizeForDisplay(manifest_path),
        });
        const failed_tests = test_summary.failed_tests + unit_test_summary.failed_tests;
        const total_failures = test_summary.total_failures + unit_test_summary.total_failures;
        if (failed_tests != 0) {
            try stdout.print("{d} test(s) failed with {d} failure row(s)\n", .{ failed_tests, total_failures });
            return error.TestFailure;
        }
        return;
    }
    if (selected_kinds.source != 0 and selected_kinds.test_resource != 0 and selected_kinds.source + selected_kinds.test_resource == selected_kinds.total) {
        if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedTestExecution;
        const test_nodes = try selectedDataTestExecutionOrder(runtime, &graph, selected);
        defer runtime.allocator.free(test_nodes);
        try validateDataTestExecution(test_nodes);

        const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
        var executed: std.ArrayList(run_results.NodeResult) = .empty;
        defer {
            deinitRunResults(runtime.allocator, executed.items);
            executed.deinit(runtime.allocator);
        }
        const test_summary = try appendDataTestResults(runtime, db_path, &graph, test_nodes, &executed);

        try writeRunResults(runtime, target_dir, executed.items);
        try stdout.print("Built {d} source test(s) against {s}; wrote artifacts into {s}\n", .{
            executed.items.len,
            util.normalizeForDisplay(db_path),
            util.normalizeForDisplay(manifest_path),
        });
        if (test_summary.failed_tests != 0) {
            try stdout.print("{d} test(s) failed with {d} failure row(s)\n", .{ test_summary.failed_tests, test_summary.total_failures });
            return error.TestFailure;
        }
        return;
    }
    if (selected_kinds.model != 0 and selected_kinds.seed == 0 and selected_kinds.model + selected_kinds.test_resource == selected_kinds.total) {
        if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedBuildAdapterExecution;
        const execution_order = try selectedModelExecutionOrder(runtime, &graph, selected);
        defer runtime.allocator.free(execution_order);
        if (execution_order.len == 0) return error.UnsupportedBuildSelection;
        try validateBuildMaterializations(execution_order);

        const test_nodes = try selectedDataTestExecutionOrder(runtime, &graph, selected);
        defer runtime.allocator.free(test_nodes);
        try validateDataTestExecution(test_nodes);

        const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
        var executed: std.ArrayList(run_results.NodeResult) = .empty;
        defer {
            deinitRunResults(runtime.allocator, executed.items);
            executed.deinit(runtime.allocator);
        }
        var executed_node_ids: std.ArrayList([]const u8) = .empty;
        defer executed_node_ids.deinit(runtime.allocator);
        const executed_tests = try runtime.allocator.alloc(bool, test_nodes.len);
        defer runtime.allocator.free(executed_tests);
        @memset(executed_tests, false);
        var blocked: std.ArrayList([]const u8) = .empty;
        defer blocked.deinit(runtime.allocator);
        var had_execution_failure = false;
        var test_failures = GenericTestExecutionSummary{};
        for (execution_order) |node| {
            if (try appendSkippedIfNodeDependsOnBlocked(runtime.allocator, &blocked, node, &executed)) {
                try appendSkippedBlockedDataTests(runtime.allocator, selected, test_nodes, executed_tests, blocked.items, &executed);
                continue;
            }
            if (!try executeModelAppendingResult(runtime, db_path, &graph, node, &executed)) {
                try appendUniqueString(runtime.allocator, &blocked, node.unique_id);
                had_execution_failure = true;
                try appendSkippedBlockedDataTests(runtime.allocator, selected, test_nodes, executed_tests, blocked.items, &executed);
                continue;
            }
            try executed_node_ids.append(runtime.allocator, node.unique_id);
            var failed_test_blockers: std.ArrayList([]const u8) = .empty;
            defer failed_test_blockers.deinit(runtime.allocator);
            const test_summary = try appendReadyDataTestResults(runtime, db_path, &graph, test_nodes, executed_tests, executed_node_ids.items, &executed, &failed_test_blockers);
            if (test_summary.failed_tests != 0) {
                try appendBlockedRoots(runtime.allocator, &blocked, failed_test_blockers.items);
                test_failures.failed_tests += test_summary.failed_tests;
                test_failures.total_failures += test_summary.total_failures;
            }
        }
        try appendSkippedBlockedDataTests(runtime.allocator, selected, test_nodes, executed_tests, blocked.items, &executed);
        const test_summary = try appendRemainingReadyDataTestResults(runtime, db_path, &graph, test_nodes, executed_tests, executed_node_ids.items, &executed);
        test_failures.failed_tests += test_summary.failed_tests;
        test_failures.total_failures += test_summary.total_failures;
        if (had_execution_failure) return failExecution(runtime, target_dir, manifest_path, db_path, executed.items, stdout, "Build");

        try writeRunResults(runtime, target_dir, executed.items);
        try stdout.print("Built {d} model(s) and {d} test(s) into {s}; wrote artifacts into {s}\n", .{
            execution_order.len,
            test_nodes.len,
            util.normalizeForDisplay(db_path),
            util.normalizeForDisplay(manifest_path),
        });
        if (test_failures.failed_tests != 0) {
            try stdout.print("{d} test(s) failed with {d} failure row(s)\n", .{ test_failures.failed_tests, test_failures.total_failures });
            return error.TestFailure;
        }
        return;
    }
    if (selected_kinds.seed != 0 and selected_kinds.model != 0 and selected_kinds.seed + selected_kinds.model + selected_kinds.test_resource == selected_kinds.total) {
        if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedBuildAdapterExecution;
        const execution_order = try selectedSeedModelExecutionOrder(runtime, &graph, selected);
        defer runtime.allocator.free(execution_order);
        try validateSeedModelBuildExecution(&graph, execution_order);

        const test_nodes = try selectedDataTestExecutionOrder(runtime, &graph, selected);
        defer runtime.allocator.free(test_nodes);
        try validateDataTestExecution(test_nodes);
        try validateDataTestsAttachToSelectedNodes(test_nodes, selected);

        const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
        var executed: std.ArrayList(run_results.NodeResult) = .empty;
        defer {
            deinitRunResults(runtime.allocator, executed.items);
            executed.deinit(runtime.allocator);
        }
        var seed_count: usize = 0;
        var model_count: usize = 0;
        var executed_node_ids: std.ArrayList([]const u8) = .empty;
        defer executed_node_ids.deinit(runtime.allocator);
        const executed_tests = try runtime.allocator.alloc(bool, test_nodes.len);
        defer runtime.allocator.free(executed_tests);
        @memset(executed_tests, false);
        var blocked: std.ArrayList([]const u8) = .empty;
        defer blocked.deinit(runtime.allocator);
        var had_execution_failure = false;
        var test_failures = GenericTestExecutionSummary{};
        for (execution_order) |node| {
            if (try appendSkippedIfNodeDependsOnBlocked(runtime.allocator, &blocked, node, &executed)) {
                try appendSkippedBlockedDataTests(runtime.allocator, selected, test_nodes, executed_tests, blocked.items, &executed);
                continue;
            }
            if (std.mem.eql(u8, node.resource_type, "seed")) {
                if (!try executeSeedAppendingResult(runtime, db_path, options.project_dir, &graph, node, &executed)) {
                    try appendUniqueString(runtime.allocator, &blocked, node.unique_id);
                    had_execution_failure = true;
                    try appendSkippedBlockedDataTests(runtime.allocator, selected, test_nodes, executed_tests, blocked.items, &executed);
                    continue;
                }
                seed_count += 1;
            } else {
                if (!try executeModelAppendingResult(runtime, db_path, &graph, node, &executed)) {
                    try appendUniqueString(runtime.allocator, &blocked, node.unique_id);
                    had_execution_failure = true;
                    try appendSkippedBlockedDataTests(runtime.allocator, selected, test_nodes, executed_tests, blocked.items, &executed);
                    continue;
                }
                model_count += 1;
            }
            try executed_node_ids.append(runtime.allocator, node.unique_id);
            var failed_test_blockers: std.ArrayList([]const u8) = .empty;
            defer failed_test_blockers.deinit(runtime.allocator);
            const test_summary = try appendReadyDataTestResults(runtime, db_path, &graph, test_nodes, executed_tests, executed_node_ids.items, &executed, &failed_test_blockers);
            if (test_summary.failed_tests != 0) {
                try appendBlockedRoots(runtime.allocator, &blocked, failed_test_blockers.items);
                test_failures.failed_tests += test_summary.failed_tests;
                test_failures.total_failures += test_summary.total_failures;
            }
        }
        try appendSkippedBlockedDataTests(runtime.allocator, selected, test_nodes, executed_tests, blocked.items, &executed);
        const test_summary = try appendRemainingReadyDataTestResults(runtime, db_path, &graph, test_nodes, executed_tests, executed_node_ids.items, &executed);
        test_failures.failed_tests += test_summary.failed_tests;
        test_failures.total_failures += test_summary.total_failures;
        if (had_execution_failure) return failExecution(runtime, target_dir, manifest_path, db_path, executed.items, stdout, "Build");

        try writeRunResults(runtime, target_dir, executed.items);
        try stdout.print("Built {d} seed(s), {d} model(s), and {d} test(s) into {s}; wrote artifacts into {s}\n", .{
            seed_count,
            model_count,
            test_nodes.len,
            util.normalizeForDisplay(db_path),
            util.normalizeForDisplay(manifest_path),
        });
        if (test_failures.failed_tests != 0) {
            try stdout.print("{d} test(s) failed with {d} failure row(s)\n", .{ test_failures.failed_tests, test_failures.total_failures });
            return error.TestFailure;
        }
        return;
    }

    try stdout.print("Prepared {d} selected resource(s), including {d} compiled model(s), into {s}\n", .{
        selected.len,
        compile_result.count,
        util.normalizeForDisplay(manifest_path),
    });
    if (selected_kinds.seed != 0) return error.UnsupportedMixedBuildExecution;
    if (selected_kinds.model != 0) return error.UnsupportedModelExecution;
    if (selected_kinds.test_resource != 0) return error.UnsupportedTestExecution;
    return error.UnsupportedBuildSelection;
}

fn resolveSelection(runtime: Runtime, options: Options) !selector_config.ResolvedSelection {
    return try selector_config.resolveSelection(runtime, options.project_dir, options.select, options.exclude, options.selector);
}

const SelectionState = struct {
    source_status_index: ?source_freshness.SourceStatusIndex = null,
    result_status_index: ?run_results.ResultStatusIndex = null,
    prior_manifest_index: ?state_artifacts.PriorManifestIndex = null,

    fn deinit(self: *SelectionState, allocator: std.mem.Allocator) void {
        if (self.source_status_index) |*index| index.deinit(allocator);
        if (self.result_status_index) |*index| index.deinit(allocator);
        if (self.prior_manifest_index) |*index| index.deinit(allocator);
        self.* = .{};
    }

    fn context(self: *const SelectionState) selector.SelectionContext {
        var ctx: selector.SelectionContext = .{};
        if (self.source_status_index) |*index| ctx.source_status_index = index;
        if (self.result_status_index) |*index| ctx.result_status_index = index;
        if (self.prior_manifest_index) |*index| ctx.prior_manifest_index = index;
        return ctx;
    }
};

fn loadSelectionState(runtime: Runtime, options: Options, selection: selector_config.ResolvedSelection) !SelectionState {
    const needs_source_status = selector.usesSourceStatusSelector(selection.select, selection.exclude);
    const needs_result = selector.usesResultSelector(selection.select, selection.exclude);
    const needs_state = selector.usesStateSelector(selection.select, selection.exclude);
    if (!needs_source_status and !needs_result and !needs_state) return .{};

    const state_dir = options.state orelse {
        if (needs_state) return error.MissingStateManifestState;
        if (needs_result) return error.MissingResultState;
        return error.MissingSourceStatusState;
    };

    var state: SelectionState = .{};
    errdefer state.deinit(runtime.allocator);
    if (needs_state) state.prior_manifest_index = try state_artifacts.loadPriorManifestIndex(runtime, state_dir);
    if (needs_source_status) state.source_status_index = try source_freshness.loadSourceStatusIndex(runtime, state_dir);
    if (needs_result) state.result_status_index = try run_results.loadResultStatusIndex(runtime, state_dir);
    return state;
}

const CompileResult = struct {
    count: usize,
    analysis_count: usize = 0,
    test_count: usize = 0,
    saw_model: bool,
    saw_analysis: bool = false,
    saw_generic_test: bool = false,
    saw_singular_test: bool = false,
    compiled_base: []const u8,
};

const BuildSelectionKinds = struct {
    total: usize = 0,
    seed: usize = 0,
    model: usize = 0,
    source: usize = 0,
    test_resource: usize = 0,
    unit_test: usize = 0,
};

const DataTestRef = union(enum) {
    generic: *GenericTestNode,
    singular: *SingularTestNode,

    fn uniqueId(self: DataTestRef) []const u8 {
        return switch (self) {
            .generic => |test_node| test_node.unique_id,
            .singular => |test_node| test_node.unique_id,
        };
    }

    fn dependsOn(self: DataTestRef) []const []const u8 {
        return switch (self) {
            .generic => |test_node| test_node.depends_on.items,
            .singular => |test_node| test_node.depends_on.items,
        };
    }
};

fn classifyBuildSelection(selected: []const selector.SelectedResource) BuildSelectionKinds {
    var kinds = BuildSelectionKinds{ .total = selected.len };
    for (selected) |item| {
        if (std.mem.eql(u8, item.resource_type, "seed")) {
            kinds.seed += 1;
        } else if (std.mem.eql(u8, item.resource_type, "model")) {
            kinds.model += 1;
        } else if (std.mem.eql(u8, item.resource_type, "source")) {
            kinds.source += 1;
        } else if (std.mem.eql(u8, item.resource_type, "test")) {
            kinds.test_resource += 1;
        } else if (std.mem.eql(u8, item.resource_type, "unit_test")) {
            kinds.unit_test += 1;
        }
    }
    return kinds;
}

fn selectedModelExecutionOrder(runtime: Runtime, graph: *Graph, selected: []const selector.SelectedResource) ![]*Node {
    const selected_count = countSelectedGraphModels(graph, selected);
    var remaining = try runtime.allocator.alloc(bool, graph.nodes.items.len);
    defer runtime.allocator.free(remaining);
    @memset(remaining, false);
    for (graph.nodes.items, 0..) |*node, index| {
        remaining[index] = isExecutableModelNode(node) and selectionContains(selected, node.unique_id);
    }

    var ordered: std.ArrayList(*Node) = .empty;
    errdefer ordered.deinit(runtime.allocator);
    while (ordered.items.len < selected_count) {
        var progressed = false;
        for (graph.nodes.items, 0..) |*node, index| {
            if (!remaining[index]) continue;
            if (!selectedModelDependenciesExecuted(graph, selected, ordered.items, node)) continue;
            try ordered.append(runtime.allocator, node);
            remaining[index] = false;
            progressed = true;
        }
        if (!progressed) return error.CyclicModelDependency;
    }
    return try ordered.toOwnedSlice(runtime.allocator);
}

fn selectedSeedModelExecutionOrder(runtime: Runtime, graph: *Graph, selected: []const selector.SelectedResource) ![]*Node {
    const selected_count = countSelectedGraphSeeds(graph, selected) + countSelectedGraphModels(graph, selected);
    var remaining = try runtime.allocator.alloc(bool, graph.nodes.items.len);
    defer runtime.allocator.free(remaining);
    @memset(remaining, false);
    for (graph.nodes.items, 0..) |*node, index| {
        remaining[index] = node.enabled and
            (std.mem.eql(u8, node.resource_type, "seed") or isExecutableModelNode(node)) and
            selectionContains(selected, node.unique_id);
    }

    var ordered: std.ArrayList(*Node) = .empty;
    errdefer ordered.deinit(runtime.allocator);
    while (ordered.items.len < selected_count) {
        var progressed = false;
        for (graph.nodes.items, 0..) |*node, index| {
            if (!remaining[index]) continue;
            if (!selectedSeedModelDependenciesExecuted(graph, selected, ordered.items, node)) continue;
            try ordered.append(runtime.allocator, node);
            remaining[index] = false;
            progressed = true;
        }
        if (!progressed) return error.CyclicModelDependency;
    }
    return try ordered.toOwnedSlice(runtime.allocator);
}

fn validateRunMaterializations(nodes: []const *Node) !void {
    for (nodes) |node| {
        if (!duckdb.isSupportedMaterialization(node.materialized)) return error.UnsupportedModelMaterialization;
    }
}

fn validateBuildMaterializations(nodes: []const *Node) !void {
    for (nodes) |node| {
        if (!duckdb.isSupportedMaterialization(node.materialized)) return error.UnsupportedBuildModelMaterialization;
    }
}

fn selectedSeedExecutionOrder(runtime: Runtime, graph: *Graph, selected: []const selector.SelectedResource) ![]*Node {
    const selected_count = countSelectedGraphSeeds(graph, selected);
    var ordered = try runtime.allocator.alloc(*Node, selected_count);
    var index: usize = 0;
    for (graph.nodes.items) |*node| {
        if (!node.enabled or !std.mem.eql(u8, node.resource_type, "seed")) continue;
        if (!selectionContains(selected, node.unique_id)) continue;
        ordered[index] = node;
        index += 1;
    }
    return ordered;
}

fn validateSeedExecution(graph: *const Graph, nodes: []const *Node) !void {
    _ = graph;
    for (nodes) |node| {
        if (!std.mem.eql(u8, node.materialized, "seed")) return error.UnsupportedSeedExecution;
    }
}

fn validateSeedModelBuildExecution(graph: *const Graph, nodes: []const *Node) !void {
    _ = graph;
    for (nodes) |node| {
        if (std.mem.eql(u8, node.resource_type, "seed")) {
            if (!std.mem.eql(u8, node.materialized, "seed")) return error.UnsupportedSeedExecution;
        } else if (std.mem.eql(u8, node.resource_type, "model")) {
            if (!duckdb.isSupportedMaterialization(node.materialized)) return error.UnsupportedBuildModelMaterialization;
        } else {
            return error.UnsupportedBuildSelection;
        }
    }
}

fn selectedDataTestExecutionOrder(runtime: Runtime, graph: *Graph, selected: []const selector.SelectedResource) ![]DataTestRef {
    const selected_count = countSelectedDataTests(graph, selected);
    var ordered = try runtime.allocator.alloc(DataTestRef, selected_count);
    var index: usize = 0;
    for (graph.tests.items) |*test_node| {
        if (!selectionContains(selected, test_node.unique_id)) continue;
        ordered[index] = .{ .generic = test_node };
        index += 1;
    }
    for (graph.singular_tests.items) |*test_node| {
        if (!test_node.enabled or !selectionContains(selected, test_node.unique_id)) continue;
        ordered[index] = .{ .singular = test_node };
        index += 1;
    }
    std.mem.sort(DataTestRef, ordered, {}, struct {
        fn lessThan(_: void, a: DataTestRef, b: DataTestRef) bool {
            return std.mem.lessThan(u8, a.uniqueId(), b.uniqueId());
        }
    }.lessThan);
    return ordered;
}

fn selectedUnitTestExecutionOrder(runtime: Runtime, graph: *Graph, selected: []const selector.SelectedResource) ![]*UnitTestDef {
    const selected_count = countSelectedUnitTests(graph, selected);
    var ordered = try runtime.allocator.alloc(*UnitTestDef, selected_count);
    var index: usize = 0;
    for (graph.unit_tests.items) |*unit_test| {
        if (!unit_test.enabled or !selectionContains(selected, unit_test.unique_id)) continue;
        ordered[index] = unit_test;
        index += 1;
    }
    std.mem.sort(*UnitTestDef, ordered, {}, struct {
        fn lessThan(_: void, a: *UnitTestDef, b: *UnitTestDef) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
        }
    }.lessThan);
    return ordered;
}

fn validateDataTestExecution(nodes: []const DataTestRef) !void {
    for (nodes) |test_ref| switch (test_ref) {
        .generic => |test_node| try validateGenericTestExecution(test_node),
        .singular => {},
    };
}

fn validateUnitTestExecution(runtime: Runtime, graph: *const Graph, nodes: []const *UnitTestDef) !void {
    for (nodes) |unit_test| {
        try duckdb.validateUnitTestExecution(runtime.allocator, graph, unit_test);
    }
}

fn validateGenericTestExecution(test_node: *const GenericTestNode) !void {
    if (genericTestNodeColumnName(test_node) == null) return error.UnsupportedTestExecution;
    if (std.mem.eql(u8, test_node.test_name, "accepted_values")) {
        if (test_node.accepted_values.items.len == 0) return error.UnsupportedTestExecution;
        return;
    }
    if (std.mem.eql(u8, test_node.test_name, "relationships")) {
        if (test_node.relationship_to.len == 0 or test_node.relationship_field.len == 0) return error.UnsupportedTestExecution;
        return;
    }
    if (!std.mem.eql(u8, test_node.test_name, "not_null") and !std.mem.eql(u8, test_node.test_name, "unique")) {
        return;
    }
}

fn validateDataTestsAttachToSelectedNodes(nodes: []const DataTestRef, selected: []const selector.SelectedResource) !void {
    for (nodes) |test_ref| switch (test_ref) {
        .generic => |test_node| {
            const attached_node = test_node.attached_node orelse return error.UnsupportedTestExecution;
            if (!selectionContains(selected, attached_node)) return error.UnsupportedTestExecution;
        },
        .singular => |test_node| {
            for (test_node.depends_on.items) |dependency| {
                if ((std.mem.startsWith(u8, dependency, "model.") or std.mem.startsWith(u8, dependency, "seed.")) and !selectionContains(selected, dependency)) {
                    return error.UnsupportedTestExecution;
                }
            }
        },
    };
}

fn executeModelAppendingResult(runtime: Runtime, db_path: []const u8, graph: *const Graph, node: *const Node, executed: *std.ArrayList(run_results.NodeResult)) !bool {
    duckdb.executeModel(runtime, db_path, graph, node) catch |err| switch (err) {
        error.DuckDbExecutionFailed => {
            try appendExecutionErrorResult(runtime.allocator, executed, node);
            return false;
        },
        else => return err,
    };
    try executed.append(runtime.allocator, .{ .node = node });
    return true;
}

fn executeSeedAppendingResult(runtime: Runtime, db_path: []const u8, project_dir: []const u8, graph: *const Graph, node: *const Node, executed: *std.ArrayList(run_results.NodeResult)) !bool {
    duckdb.executeSeed(runtime, db_path, project_dir, graph, node) catch |err| switch (err) {
        error.DuckDbExecutionFailed => {
            try appendExecutionErrorResult(runtime.allocator, executed, node);
            return false;
        },
        else => return err,
    };
    try executed.append(runtime.allocator, .{ .node = node });
    return true;
}

fn appendExecutionErrorResult(allocator: std.mem.Allocator, executed: *std.ArrayList(run_results.NodeResult), node: *const Node) !void {
    const message = try allocator.dupe(u8, execution_failure_message);
    errdefer allocator.free(message);
    try executed.append(allocator, .{
        .node = node,
        .status = "error",
        .message = message,
    });
}

fn appendSkippedAfterExecutionFailure(
    allocator: std.mem.Allocator,
    selected: []const selector.SelectedResource,
    remaining_nodes: []const *Node,
    test_nodes: []const DataTestRef,
    failed_unique_id: []const u8,
    executed: *std.ArrayList(run_results.NodeResult),
) !void {
    var blocked: std.ArrayList([]const u8) = .empty;
    defer blocked.deinit(allocator);
    try blocked.append(allocator, failed_unique_id);

    for (remaining_nodes) |node| {
        if (!selectionContains(selected, node.unique_id)) continue;
        if (!dependsOnAnyBlocked(node.depends_on.items, blocked.items)) continue;
        try executed.append(allocator, .{
            .node = node,
            .status = "skipped",
        });
        try blocked.append(allocator, node.unique_id);
    }

    for (test_nodes) |test_node| {
        if (!selectionContains(selected, test_node.uniqueId())) continue;
        if (!testDependsOnAnyBlocked(test_node, blocked.items)) continue;
        switch (test_node) {
            .generic => |generic| try executed.append(allocator, .{ .test_node = generic, .status = "skipped" }),
            .singular => |singular| try executed.append(allocator, .{ .singular_test_node = singular, .status = "skipped" }),
        }
        try blocked.append(allocator, test_node.uniqueId());
    }
}

fn appendSkippedIfNodeDependsOnBlocked(
    allocator: std.mem.Allocator,
    blocked: *std.ArrayList([]const u8),
    node: *const Node,
    executed: *std.ArrayList(run_results.NodeResult),
) !bool {
    if (!dependsOnAnyBlocked(node.depends_on.items, blocked.items)) return false;
    try executed.append(allocator, .{
        .node = node,
        .status = "skipped",
    });
    try appendUniqueString(allocator, blocked, node.unique_id);
    return true;
}

fn appendSkippedAfterDataTestFailure(
    allocator: std.mem.Allocator,
    selected: []const selector.SelectedResource,
    remaining_nodes: []const *Node,
    test_nodes: []const DataTestRef,
    executed_tests: []const bool,
    blocked_roots: []const []const u8,
    executed: *std.ArrayList(run_results.NodeResult),
) !void {
    var blocked: std.ArrayList([]const u8) = .empty;
    defer blocked.deinit(allocator);
    for (blocked_roots) |blocked_root| {
        try appendUniqueString(allocator, &blocked, blocked_root);
    }

    for (remaining_nodes) |node| {
        if (!selectionContains(selected, node.unique_id)) continue;
        if (!dependsOnAnyBlocked(node.depends_on.items, blocked.items)) continue;
        try executed.append(allocator, .{
            .node = node,
            .status = "skipped",
        });
        try appendUniqueString(allocator, &blocked, node.unique_id);
    }

    for (test_nodes, 0..) |test_node, index| {
        if (executed_tests[index]) continue;
        if (!selectionContains(selected, test_node.uniqueId())) continue;
        if (!testDependsOnAnyBlocked(test_node, blocked.items)) continue;
        switch (test_node) {
            .generic => |generic| try executed.append(allocator, .{ .test_node = generic, .status = "skipped" }),
            .singular => |singular| try executed.append(allocator, .{ .singular_test_node = singular, .status = "skipped" }),
        }
        try appendUniqueString(allocator, &blocked, test_node.uniqueId());
    }
}

fn testDependsOnAnyBlocked(test_node: DataTestRef, blocked: []const []const u8) bool {
    if (dependsOnAnyBlocked(test_node.dependsOn(), blocked)) return true;
    switch (test_node) {
        .generic => |generic| {
            if (generic.attached_node) |attached_node| {
                if (containsUniqueId(blocked, attached_node)) return true;
            }
            if (generic.attached_source_unique_id) |attached_source| {
                if (containsUniqueId(blocked, attached_source)) return true;
            }
        },
        .singular => {},
    }
    return false;
}

fn dependsOnAnyBlocked(depends_on: []const []const u8, blocked: []const []const u8) bool {
    for (depends_on) |dependency| {
        if (containsUniqueId(blocked, dependency)) return true;
    }
    return false;
}

fn containsUniqueId(values: []const []const u8, unique_id: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, unique_id)) return true;
    }
    return false;
}

fn failExecution(runtime: Runtime, target_dir: []const u8, manifest_path: []const u8, db_path: []const u8, executed: []const run_results.NodeResult, stdout: *Io.Writer, verb: []const u8) !void {
    try writeRunResults(runtime, target_dir, executed);
    try stdout.print("{s} failed after {d} result(s) against {s}; wrote artifacts into {s}\n", .{
        verb,
        executed.len,
        util.normalizeForDisplay(db_path),
        util.normalizeForDisplay(manifest_path),
    });
    return error.ExecutionFailure;
}

const GenericTestExecutionSummary = struct {
    failed_tests: usize = 0,
    total_failures: u64 = 0,
};

fn appendDataTestResults(runtime: Runtime, db_path: []const u8, graph: *const Graph, test_nodes: []const DataTestRef, executed: *std.ArrayList(run_results.NodeResult)) !GenericTestExecutionSummary {
    var summary: GenericTestExecutionSummary = .{};
    for (test_nodes) |test_ref| {
        const result = try appendOneDataTestResult(runtime, db_path, graph, test_ref, executed);
        summary.failed_tests += result.failed_tests;
        summary.total_failures += result.total_failures;
    }
    return summary;
}

fn appendUnitTestResults(runtime: Runtime, db_path: []const u8, graph: *const Graph, unit_test_nodes: []const *UnitTestDef, executed: *std.ArrayList(run_results.NodeResult)) !GenericTestExecutionSummary {
    var summary: GenericTestExecutionSummary = .{};
    for (unit_test_nodes) |unit_test| {
        const result = try appendOneUnitTestResult(runtime, db_path, graph, unit_test, executed);
        summary.failed_tests += result.failed_tests;
        summary.total_failures += result.total_failures;
    }
    return summary;
}

fn appendReadyDataTestResults(
    runtime: Runtime,
    db_path: []const u8,
    graph: *const Graph,
    test_nodes: []const DataTestRef,
    executed_tests: []bool,
    completed_nodes: []const []const u8,
    executed: *std.ArrayList(run_results.NodeResult),
    failed_blockers: *std.ArrayList([]const u8),
) !GenericTestExecutionSummary {
    var summary: GenericTestExecutionSummary = .{};
    for (test_nodes, 0..) |test_ref, index| {
        if (executed_tests[index]) continue;
        if (!dataTestDependenciesCompleted(test_ref, completed_nodes)) continue;
        const result = try appendOneDataTestResult(runtime, db_path, graph, test_ref, executed);
        executed_tests[index] = true;
        if (result.failed_tests != 0) {
            try appendDataTestBlockedRoots(runtime.allocator, failed_blockers, test_ref);
        }
        summary.failed_tests += result.failed_tests;
        summary.total_failures += result.total_failures;
    }
    return summary;
}

fn appendRemainingReadyDataTestResults(
    runtime: Runtime,
    db_path: []const u8,
    graph: *const Graph,
    test_nodes: []const DataTestRef,
    executed_tests: []bool,
    completed_nodes: []const []const u8,
    executed: *std.ArrayList(run_results.NodeResult),
) !GenericTestExecutionSummary {
    var summary: GenericTestExecutionSummary = .{};
    for (test_nodes, 0..) |test_ref, index| {
        if (executed_tests[index]) continue;
        if (!dataTestDependenciesCompleted(test_ref, completed_nodes)) continue;
        const result = try appendOneDataTestResult(runtime, db_path, graph, test_ref, executed);
        executed_tests[index] = true;
        summary.failed_tests += result.failed_tests;
        summary.total_failures += result.total_failures;
    }
    return summary;
}

fn appendOneDataTestResult(runtime: Runtime, db_path: []const u8, graph: *const Graph, test_ref: DataTestRef, executed: *std.ArrayList(run_results.NodeResult)) !GenericTestExecutionSummary {
    const execution = switch (test_ref) {
        .generic => |test_node| try duckdb.executeGenericTest(runtime, db_path, graph, test_node),
        .singular => |test_node| try duckdb.executeSingularTest(runtime, db_path, graph, test_node),
    };
    errdefer {
        runtime.allocator.free(execution.compiled_code);
        if (execution.relation_name) |relation_name| runtime.allocator.free(relation_name);
    }
    if (execution.execution_error) {
        const message = try runtime.allocator.dupe(u8, execution_failure_message);
        errdefer runtime.allocator.free(message);
        switch (test_ref) {
            .generic => |test_node| try executed.append(runtime.allocator, .{
                .test_node = test_node,
                .status = "error",
                .message = message,
                .compiled_code = execution.compiled_code,
                .owns_compiled_code = true,
                .relation_name = execution.relation_name,
                .owns_relation_name = execution.relation_name != null,
            }),
            .singular => |test_node| try executed.append(runtime.allocator, .{
                .singular_test_node = test_node,
                .status = "error",
                .message = message,
                .compiled_code = execution.compiled_code,
                .owns_compiled_code = true,
                .relation_name = execution.relation_name,
                .owns_relation_name = execution.relation_name != null,
            }),
        }
        return .{ .failed_tests = 1 };
    }
    const classification = switch (test_ref) {
        .generic => |test_node| try classifyGenericTestResult(execution.failures, test_node.config),
        .singular => |test_node| try classifyGenericTestResult(execution.failures, test_node.config),
    };
    const message = if (classification.message_kind) |kind|
        try formatTestThresholdMessage(runtime.allocator, execution.failures, kind, classification.condition orelse "!= 0")
    else
        null;
    switch (test_ref) {
        .generic => |test_node| try executed.append(runtime.allocator, .{
            .test_node = test_node,
            .status = classification.status,
            .message = message,
            .failures = execution.failures,
            .compiled_code = execution.compiled_code,
            .owns_compiled_code = true,
            .relation_name = execution.relation_name,
            .owns_relation_name = execution.relation_name != null,
        }),
        .singular => |test_node| try executed.append(runtime.allocator, .{
            .singular_test_node = test_node,
            .status = classification.status,
            .message = message,
            .failures = execution.failures,
            .compiled_code = execution.compiled_code,
            .owns_compiled_code = true,
            .relation_name = execution.relation_name,
            .owns_relation_name = execution.relation_name != null,
        }),
    }
    return .{
        .failed_tests = if (classification.fails_command) 1 else 0,
        .total_failures = if (classification.fails_command) execution.failures else 0,
    };
}

fn appendOneUnitTestResult(runtime: Runtime, db_path: []const u8, graph: *const Graph, unit_test: *const UnitTestDef, executed: *std.ArrayList(run_results.NodeResult)) !GenericTestExecutionSummary {
    const execution = try duckdb.executeUnitTest(runtime, db_path, graph, unit_test);
    errdefer runtime.allocator.free(execution.compiled_code);
    const classification = classifyDefaultTestResult(execution.failures);
    const message = if (classification.message_kind) |kind|
        try formatTestThresholdMessage(runtime.allocator, execution.failures, kind, classification.condition orelse "!= 0")
    else
        null;
    try executed.append(runtime.allocator, .{
        .unit_test_node = unit_test,
        .status = classification.status,
        .message = message,
        .failures = execution.failures,
        .compiled_code = execution.compiled_code,
        .owns_compiled_code = true,
    });
    return .{
        .failed_tests = if (classification.fails_command) 1 else 0,
        .total_failures = if (classification.fails_command) execution.failures else 0,
    };
}

const TestResultClassification = struct {
    status: []const u8,
    fails_command: bool = false,
    message_kind: ?[]const u8 = null,
    condition: ?[]const u8 = null,
};

fn classifyDefaultTestResult(failures: u64) TestResultClassification {
    if (failures == 0) return .{ .status = "pass" };
    return .{ .status = "fail", .fails_command = true, .message_kind = "fail", .condition = "!= 0" };
}

fn classifyGenericTestResult(failures: u64, config: types.GenericTestConfig) !TestResultClassification {
    if (std.ascii.eqlIgnoreCase(config.severity, "warn")) {
        if (try evaluateTestThreshold(failures, config.warn_if)) {
            return .{ .status = "warn", .message_kind = "warn", .condition = config.warn_if };
        }
        return .{ .status = "pass" };
    }
    if (!std.ascii.eqlIgnoreCase(config.severity, "error")) return error.UnsupportedTestExecution;
    if (try evaluateTestThreshold(failures, config.error_if)) {
        return .{ .status = "fail", .fails_command = true, .message_kind = "fail", .condition = config.error_if };
    }
    if (try evaluateTestThreshold(failures, config.warn_if)) {
        return .{ .status = "warn", .message_kind = "warn", .condition = config.warn_if };
    }
    return .{ .status = "pass" };
}

fn evaluateTestThreshold(failures: u64, condition: []const u8) !bool {
    const trimmed = std.mem.trim(u8, condition, " \t\r\n");
    const operators = [_][]const u8{ ">=", "<=", "!=", "==", ">", "<", "=" };
    for (operators) |operator| {
        if (!std.mem.startsWith(u8, trimmed, operator)) continue;
        const rhs = std.mem.trim(u8, trimmed[operator.len..], " \t\r\n");
        if (rhs.len == 0) return error.UnsupportedTestExecution;
        const threshold = std.fmt.parseUnsigned(u64, rhs, 10) catch return error.UnsupportedTestExecution;
        if (std.mem.eql(u8, operator, ">=")) return failures >= threshold;
        if (std.mem.eql(u8, operator, "<=")) return failures <= threshold;
        if (std.mem.eql(u8, operator, "!=")) return failures != threshold;
        if (std.mem.eql(u8, operator, "==")) return failures == threshold;
        if (std.mem.eql(u8, operator, ">")) return failures > threshold;
        if (std.mem.eql(u8, operator, "<")) return failures < threshold;
        if (std.mem.eql(u8, operator, "=")) return failures == threshold;
    }
    return error.UnsupportedTestExecution;
}

fn dataTestDependenciesCompleted(test_ref: DataTestRef, completed_nodes: []const []const u8) bool {
    for (test_ref.dependsOn()) |dependency| {
        if (!std.mem.startsWith(u8, dependency, "model.") and !std.mem.startsWith(u8, dependency, "seed.")) continue;
        if (!containsUniqueId(completed_nodes, dependency)) return false;
    }
    return true;
}

fn appendDataTestBlockedRoots(allocator: std.mem.Allocator, blocked_roots: *std.ArrayList([]const u8), test_ref: DataTestRef) !void {
    switch (test_ref) {
        .generic => |generic| {
            if (generic.attached_node) |attached_node| {
                try appendUniqueString(allocator, blocked_roots, attached_node);
                return;
            }
            if (generic.attached_source_unique_id) |attached_source| {
                try appendUniqueString(allocator, blocked_roots, attached_source);
                return;
            }
        },
        .singular => {},
    }
    for (test_ref.dependsOn()) |dependency| {
        if (std.mem.startsWith(u8, dependency, "model.") or std.mem.startsWith(u8, dependency, "seed.")) {
            try appendUniqueString(allocator, blocked_roots, dependency);
        }
    }
}

fn appendBlockedRoots(allocator: std.mem.Allocator, blocked: *std.ArrayList([]const u8), roots: []const []const u8) !void {
    for (roots) |root| {
        try appendUniqueString(allocator, blocked, root);
    }
}

fn appendSkippedBlockedDataTests(
    allocator: std.mem.Allocator,
    selected: []const selector.SelectedResource,
    test_nodes: []const DataTestRef,
    executed_tests: []bool,
    blocked: []const []const u8,
    executed: *std.ArrayList(run_results.NodeResult),
) !void {
    for (test_nodes, 0..) |test_node, index| {
        if (executed_tests[index]) continue;
        if (!selectionContains(selected, test_node.uniqueId())) continue;
        if (!testDependsOnAnyBlocked(test_node, blocked)) continue;
        switch (test_node) {
            .generic => |generic| try executed.append(allocator, .{ .test_node = generic, .status = "skipped" }),
            .singular => |singular| try executed.append(allocator, .{ .singular_test_node = singular, .status = "skipped" }),
        }
        executed_tests[index] = true;
    }
}

fn appendUniqueString(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8), value: []const u8) !void {
    if (containsUniqueId(values.items, value)) return;
    try values.append(allocator, value);
}

fn writeRunResults(runtime: Runtime, target_dir: []const u8, results: []const run_results.NodeResult) !void {
    const run_results_path = try pathJoin(runtime.allocator, &.{ target_dir, "run_results.json" });
    const run_results_json = try run_results.renderRunResults(runtime.allocator, results);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = run_results_path, .data = run_results_json });
}

fn deinitRunResults(allocator: std.mem.Allocator, results: []const run_results.NodeResult) void {
    for (results) |result| {
        if (result.owns_compiled_code) {
            if (result.compiled_code) |compiled_code| allocator.free(compiled_code);
        }
        if (result.owns_relation_name) {
            if (result.relation_name) |relation_name| allocator.free(relation_name);
        }
        if (result.message) |message| allocator.free(message);
    }
}

fn countSelectedGraphModels(graph: *const Graph, selected: []const selector.SelectedResource) usize {
    var count: usize = 0;
    for (graph.nodes.items) |*node| {
        if (!isExecutableModelNode(node)) continue;
        if (selectionContains(selected, node.unique_id)) count += 1;
    }
    return count;
}

fn isExecutableModelNode(node: *const Node) bool {
    return node.enabled and std.mem.eql(u8, node.resource_type, "model") and !std.mem.eql(u8, node.materialized, "ephemeral");
}

fn countSelectedGraphSeeds(graph: *const Graph, selected: []const selector.SelectedResource) usize {
    var count: usize = 0;
    for (graph.nodes.items) |node| {
        if (!node.enabled or !std.mem.eql(u8, node.resource_type, "seed")) continue;
        if (selectionContains(selected, node.unique_id)) count += 1;
    }
    return count;
}

fn countSelectedDataTests(graph: *const Graph, selected: []const selector.SelectedResource) usize {
    var count: usize = 0;
    for (graph.tests.items) |test_node| {
        if (selectionContains(selected, test_node.unique_id)) count += 1;
    }
    for (graph.singular_tests.items) |test_node| {
        if (test_node.enabled and selectionContains(selected, test_node.unique_id)) count += 1;
    }
    return count;
}

fn countSelectedUnitTests(graph: *const Graph, selected: []const selector.SelectedResource) usize {
    var count: usize = 0;
    for (graph.unit_tests.items) |unit_test| {
        if (unit_test.enabled and selectionContains(selected, unit_test.unique_id)) count += 1;
    }
    return count;
}

fn selectedModelDependenciesExecuted(graph: *const Graph, selected: []const selector.SelectedResource, executed: []const *Node, node: *const Node) bool {
    for (node.depends_on.items) |dependency| {
        if (!std.mem.startsWith(u8, dependency, "model.")) continue;
        if (!selectionContains(selected, dependency)) continue;
        if (findGraphNodeByUniqueId(graph, dependency)) |dependency_node| {
            if (std.mem.eql(u8, dependency_node.materialized, "ephemeral")) continue;
        }
        if (!executedContains(executed, dependency)) return false;
    }
    return true;
}

fn selectedSeedModelDependenciesExecuted(graph: *const Graph, selected: []const selector.SelectedResource, executed: []const *Node, node: *const Node) bool {
    for (node.depends_on.items) |dependency| {
        if (!std.mem.startsWith(u8, dependency, "model.") and !std.mem.startsWith(u8, dependency, "seed.")) continue;
        if (!selectionContains(selected, dependency)) continue;
        if (findGraphNodeByUniqueId(graph, dependency)) |dependency_node| {
            if (std.mem.eql(u8, dependency_node.resource_type, "model") and std.mem.eql(u8, dependency_node.materialized, "ephemeral")) continue;
        }
        if (!executedContains(executed, dependency)) return false;
    }
    return true;
}

fn findGraphNodeByUniqueId(graph: *const Graph, unique_id: []const u8) ?*const Node {
    for (graph.nodes.items) |*node| {
        if (std.mem.eql(u8, node.unique_id, unique_id)) return node;
    }
    return null;
}

fn executedContains(executed: []const *Node, unique_id: []const u8) bool {
    for (executed) |node| {
        if (std.mem.eql(u8, node.unique_id, unique_id)) return true;
    }
    return false;
}

fn formatTestThresholdMessage(allocator: std.mem.Allocator, failures: u64, kind: []const u8, condition: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(
        allocator,
        "Got {d} {s}, configured to {s} if {s}",
        .{ failures, if (failures == 1) "result" else "results", kind, condition },
    );
}

test "classifyGenericTestResult follows severity and threshold config" {
    const warn_config = types.GenericTestConfig{ .severity = "warn", .warn_if = "> 0", .error_if = "> 0" };
    const warn_result = try classifyGenericTestResult(1, warn_config);
    try std.testing.expectEqualStrings("warn", warn_result.status);
    try std.testing.expect(!warn_result.fails_command);
    try std.testing.expectEqualStrings("warn", warn_result.message_kind.?);

    const fail_config = types.GenericTestConfig{ .severity = "ERROR", .warn_if = "> 0", .error_if = "> 1" };
    const fail_result = try classifyGenericTestResult(2, fail_config);
    try std.testing.expectEqualStrings("fail", fail_result.status);
    try std.testing.expect(fail_result.fails_command);
    try std.testing.expectEqualStrings("fail", fail_result.message_kind.?);

    const downgraded_result = try classifyGenericTestResult(1, fail_config);
    try std.testing.expectEqualStrings("warn", downgraded_result.status);
    try std.testing.expect(!downgraded_result.fails_command);

    const pass_result = try classifyGenericTestResult(0, fail_config);
    try std.testing.expectEqualStrings("pass", pass_result.status);
    try std.testing.expect(!pass_result.fails_command);

    try std.testing.expect(try evaluateTestThreshold(3, ">= 3"));
    try std.testing.expect(try evaluateTestThreshold(3, "= 3"));
    try std.testing.expect(!try evaluateTestThreshold(3, "< 3"));
}

test "validateGenericTestExecution allows custom column tests and rejects missing columns" {
    const custom = GenericTestNode{
        .package_name = "demo",
        .unique_id = "test.demo.positive_amount_orders_amount.abc",
        .name = "positive_amount_orders_amount",
        .alias = "positive_amount_orders_amount",
        .path = "positive_amount_orders_amount.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_positive_amount(**_dbt_generic_test_kwargs) }}",
        .test_name = "positive_amount",
        .column_name = "amount",
        .attached_node = "model.demo.orders",
    };
    try validateGenericTestExecution(&custom);

    const table_level_custom = GenericTestNode{
        .package_name = "demo",
        .unique_id = "test.demo.positive_amount_orders.abc",
        .name = "positive_amount_orders",
        .alias = "positive_amount_orders",
        .path = "positive_amount_orders.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_positive_amount(**_dbt_generic_test_kwargs) }}",
        .test_name = "positive_amount",
        .attached_node = "model.demo.orders",
    };
    try std.testing.expectError(error.UnsupportedTestExecution, validateGenericTestExecution(&table_level_custom));
}

fn appendSourceFreshnessRuntimeError(allocator: std.mem.Allocator, results: *std.ArrayList(source_freshness.CheckResult), source: *const SourceDef, message: []const u8) !void {
    try appendOwnedSourceFreshnessRuntimeError(allocator, results, source, try allocator.dupe(u8, message));
}

fn appendOwnedSourceFreshnessRuntimeError(allocator: std.mem.Allocator, results: *std.ArrayList(source_freshness.CheckResult), source: *const SourceDef, message: []const u8) !void {
    results.append(allocator, .{
        .source = source,
        .status = "runtime error",
        .error_message = message,
    }) catch |err| {
        allocator.free(message);
        return err;
    };
}

fn formatSourceFreshnessError(allocator: std.mem.Allocator, err: anyerror) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "source freshness query failed: {s}", .{@errorName(err)});
}

fn targetDir(runtime: Runtime, options: Options) ![]const u8 {
    const target_path = options.target_path orelse project_loader.graphDefaultTarget(runtime, options.project_dir) catch "target";
    if (std.fs.path.isAbsolute(target_path)) return target_path;
    return try pathJoin(runtime.allocator, &.{ options.project_dir, target_path });
}

fn compileSelectedModels(runtime: Runtime, graph: *Graph, selected: []const selector.SelectedResource, target_dir: []const u8, include_singular_tests: bool, include_analyses: bool) !CompileResult {
    const compiled_base = try pathJoin(runtime.allocator, &.{ target_dir, "compiled" });
    try std.Io.Dir.cwd().createDirPath(runtime.io, compiled_base);

    var compiled_count: usize = 0;
    var compiled_analysis_count: usize = 0;
    var compiled_test_count: usize = 0;
    var saw_selected_model = false;
    var saw_selected_analysis = false;
    var saw_selected_generic_test = false;
    var saw_selected_singular_test = false;
    for (graph.nodes.items) |*node| {
        if (!node.enabled or !std.mem.eql(u8, node.resource_type, "model")) continue;
        if (!selectionContains(selected, node.unique_id)) continue;
        saw_selected_model = true;
        if (std.mem.eql(u8, node.materialized, "ephemeral")) continue;

        var compiled_model = try compiler.compileModelWithInjectedCtes(runtime.allocator, graph, node);
        errdefer compiled_model.deinit(runtime.allocator);
        const compiled_path = try pathJoin(runtime.allocator, &.{ compiled_base, node.package_name, node.original_file_path });
        if (std.fs.path.dirname(compiled_path)) |parent| {
            try std.Io.Dir.cwd().createDirPath(runtime.io, parent);
        }
        try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = compiled_path, .data = compiled_model.compiled_code });
        const relation_name = try compiler.relationNameForNode(runtime.allocator, graph, node);
        node.compiled = true;
        node.compiled_code = compiled_model.compiled_code;
        node.extra_ctes = compiled_model.extra_ctes;
        compiled_model.compiled_code = "";
        compiled_model.extra_ctes = .empty;
        node.compiled_path = util.normalizeForDisplay(compiled_path);
        node.relation_name = relation_name;
        compiled_count += 1;
    }

    if (include_analyses) {
        for (graph.nodes.items) |*node| {
            if (!node.enabled or !std.mem.eql(u8, node.resource_type, "analysis")) continue;
            if (!selectionContains(selected, node.unique_id)) continue;
            saw_selected_analysis = true;

            const compiled_code = try compiler.compileModel(runtime.allocator, graph, node);
            const compiled_path = try pathJoin(runtime.allocator, &.{ compiled_base, node.package_name, node.path });
            if (std.fs.path.dirname(compiled_path)) |parent| {
                try std.Io.Dir.cwd().createDirPath(runtime.io, parent);
            }
            try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = compiled_path, .data = compiled_code });
            node.compiled = true;
            node.compiled_code = compiled_code;
            node.compiled_path = util.normalizeForDisplay(compiled_path);
            compiled_analysis_count += 1;
        }
    }

    if (include_singular_tests) {
        for (graph.tests.items) |*test_node| {
            if (!selectionContains(selected, test_node.unique_id)) continue;
            saw_selected_generic_test = true;
            if (isBuiltInGenericTestName(test_node.test_name)) {
                validateGenericTestExecution(test_node) catch return error.UnsupportedCompileSelection;
            }

            const compiled_code = compiler.compileGenericTest(runtime.allocator, graph, test_node) catch |err| switch (err) {
                error.UnsupportedTestExecution => return error.UnsupportedCompileSelection,
                else => return err,
            };
            const compiled_path = try pathJoin(runtime.allocator, &.{ compiled_base, test_node.package_name, test_node.path });
            if (std.fs.path.dirname(compiled_path)) |parent| {
                try std.Io.Dir.cwd().createDirPath(runtime.io, parent);
            }
            try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = compiled_path, .data = compiled_code });
            test_node.compiled = true;
            test_node.compiled_code = compiled_code;
            test_node.compiled_path = util.normalizeForDisplay(compiled_path);
            compiled_test_count += 1;
        }
        for (graph.singular_tests.items) |*test_node| {
            if (!test_node.enabled or !selectionContains(selected, test_node.unique_id)) continue;
            saw_selected_singular_test = true;

            const compiled_code = try compiler.compileSingularTest(runtime.allocator, graph, test_node);
            const compiled_path = try pathJoin(runtime.allocator, &.{ compiled_base, test_node.package_name, test_node.original_file_path });
            if (std.fs.path.dirname(compiled_path)) |parent| {
                try std.Io.Dir.cwd().createDirPath(runtime.io, parent);
            }
            try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = compiled_path, .data = compiled_code });
            test_node.compiled = true;
            test_node.compiled_code = compiled_code;
            test_node.compiled_path = util.normalizeForDisplay(compiled_path);
            compiled_test_count += 1;
        }
    }

    return .{
        .count = compiled_count,
        .analysis_count = compiled_analysis_count,
        .test_count = compiled_test_count,
        .saw_model = saw_selected_model,
        .saw_analysis = saw_selected_analysis,
        .saw_generic_test = saw_selected_generic_test,
        .saw_singular_test = saw_selected_singular_test,
        .compiled_base = compiled_base,
    };
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

test "selected model execution order skips selected ephemeral parents" {
    const allocator = std.testing.allocator;
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.ephemeral_parent",
        .name = "ephemeral_parent",
        .path = "ephemeral_parent.sql",
        .original_file_path = "models/ephemeral_parent.sql",
        .raw_code = "select 1 as id",
        .materialized = "ephemeral",
    });
    var downstream = Node{
        .package_name = "demo",
        .unique_id = "model.demo.downstream",
        .name = "downstream",
        .path = "downstream.sql",
        .original_file_path = "models/downstream.sql",
        .raw_code = "select * from {{ ref('ephemeral_parent') }}",
        .materialized = "table",
    };
    try downstream.depends_on.append(allocator, "model.demo.ephemeral_parent");
    try graph.nodes.append(allocator, downstream);

    const selected = [_]selector.SelectedResource{
        .{ .unique_id = "model.demo.ephemeral_parent", .name = "ephemeral_parent", .resource_type = "model" },
        .{ .unique_id = "model.demo.downstream", .name = "downstream", .resource_type = "model" },
    };
    const runtime = Runtime{ .allocator = allocator, .io = undefined };
    const ordered = try selectedModelExecutionOrder(runtime, &graph, &selected);
    defer allocator.free(ordered);

    try std.testing.expectEqual(@as(usize, 1), ordered.len);
    try std.testing.expectEqualStrings("model.demo.downstream", ordered[0].unique_id);
}

test "selected seed-model build order waits for selected seed dependencies" {
    const allocator = std.testing.allocator;
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    var model = Node{
        .package_name = "demo",
        .unique_id = "model.demo.stg_customers",
        .name = "stg_customers",
        .path = "stg_customers.sql",
        .original_file_path = "models/stg_customers.sql",
        .raw_code = "select * from {{ ref(\"raw_customers\") }}",
    };
    try model.depends_on.append(allocator, "seed.demo.raw_customers");
    try graph.nodes.append(allocator, model);
    try graph.nodes.append(allocator, .{
        .resource_type = "seed",
        .package_name = "demo",
        .unique_id = "seed.demo.raw_customers",
        .name = "raw_customers",
        .path = "raw_customers.csv",
        .original_file_path = "seeds/raw_customers.csv",
        .raw_code = "",
        .materialized = "seed",
    });

    const selected = [_]selector.SelectedResource{
        .{ .unique_id = "model.demo.stg_customers", .name = "stg_customers", .resource_type = "model" },
        .{ .unique_id = "seed.demo.raw_customers", .name = "raw_customers", .resource_type = "seed" },
    };
    const runtime = Runtime{ .allocator = allocator, .io = undefined };
    const ordered = try selectedSeedModelExecutionOrder(runtime, &graph, &selected);
    defer allocator.free(ordered);

    try std.testing.expectEqual(@as(usize, 2), ordered.len);
    try std.testing.expectEqualStrings("seed.demo.raw_customers", ordered[0].unique_id);
    try std.testing.expectEqualStrings("model.demo.stg_customers", ordered[1].unique_id);
}

test "appendSkippedAfterExecutionFailure records selected blocked descendants only" {
    const allocator = std.testing.allocator;
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select * from missing_relation",
    });
    var orders = Node{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select * from {{ ref('customers') }}",
    };
    try orders.depends_on.append(allocator, "model.demo.customers");
    try graph.nodes.append(allocator, orders);
    var payments = Node{
        .package_name = "demo",
        .unique_id = "model.demo.payments",
        .name = "payments",
        .path = "payments.sql",
        .original_file_path = "models/payments.sql",
        .raw_code = "select * from {{ ref('orders') }}",
    };
    try payments.depends_on.append(allocator, "model.demo.orders");
    try graph.nodes.append(allocator, payments);
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.independent",
        .name = "independent",
        .path = "independent.sql",
        .original_file_path = "models/independent.sql",
        .raw_code = "select 1",
    });

    var test_node = GenericTestNode{
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
    };
    try test_node.depends_on.append(allocator, "model.demo.orders");
    try graph.tests.append(allocator, test_node);

    const selected = [_]selector.SelectedResource{
        .{ .unique_id = "model.demo.customers", .name = "customers", .resource_type = "model" },
        .{ .unique_id = "model.demo.orders", .name = "orders", .resource_type = "model" },
        .{ .unique_id = "model.demo.payments", .name = "payments", .resource_type = "model" },
        .{ .unique_id = "model.demo.independent", .name = "independent", .resource_type = "model" },
        .{ .unique_id = "test.demo.not_null_orders_order_id.abc", .name = "not_null_orders_order_id", .resource_type = "test" },
    };
    const remaining = [_]*Node{ &graph.nodes.items[1], &graph.nodes.items[2], &graph.nodes.items[3] };
    const tests = [_]DataTestRef{.{ .generic = &graph.tests.items[0] }};

    var executed: std.ArrayList(run_results.NodeResult) = .empty;
    defer executed.deinit(allocator);
    try appendSkippedAfterExecutionFailure(allocator, &selected, &remaining, &tests, "model.demo.customers", &executed);

    try std.testing.expectEqual(@as(usize, 3), executed.items.len);
    try std.testing.expectEqualStrings("model.demo.orders", executed.items[0].node.?.unique_id);
    try std.testing.expectEqualStrings("skipped", executed.items[0].status);
    try std.testing.expectEqualStrings("model.demo.payments", executed.items[1].node.?.unique_id);
    try std.testing.expectEqualStrings("test.demo.not_null_orders_order_id.abc", executed.items[2].test_node.?.unique_id);
}

test "appendSkippedAfterExecutionFailure honors post-exclude selected set" {
    const allocator = std.testing.allocator;
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select * from missing_relation",
    });
    var orders = Node{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select * from {{ ref('customers') }}",
    };
    try orders.depends_on.append(allocator, "model.demo.customers");
    try graph.nodes.append(allocator, orders);

    const selected = [_]selector.SelectedResource{
        .{ .unique_id = "model.demo.customers", .name = "customers", .resource_type = "model" },
    };
    const remaining = [_]*Node{&graph.nodes.items[1]};

    var executed: std.ArrayList(run_results.NodeResult) = .empty;
    defer executed.deinit(allocator);
    try appendSkippedAfterExecutionFailure(allocator, &selected, &remaining, &.{}, "model.demo.customers", &executed);

    try std.testing.expectEqual(@as(usize, 0), executed.items.len);
}

test "appendSkippedIfNodeDependsOnBlocked records one blocked model" {
    const allocator = std.testing.allocator;
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select * from missing_relation",
    });
    var orders = Node{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select * from {{ ref('customers') }}",
    };
    try orders.depends_on.append(allocator, "model.demo.customers");
    try graph.nodes.append(allocator, orders);
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.independent",
        .name = "independent",
        .path = "independent.sql",
        .original_file_path = "models/independent.sql",
        .raw_code = "select 1",
    });

    var blocked: std.ArrayList([]const u8) = .empty;
    defer blocked.deinit(allocator);
    try blocked.append(allocator, "model.demo.customers");
    var executed: std.ArrayList(run_results.NodeResult) = .empty;
    defer executed.deinit(allocator);

    try std.testing.expect(try appendSkippedIfNodeDependsOnBlocked(allocator, &blocked, &graph.nodes.items[1], &executed));
    try std.testing.expect(!try appendSkippedIfNodeDependsOnBlocked(allocator, &blocked, &graph.nodes.items[2], &executed));
    try std.testing.expectEqual(@as(usize, 1), executed.items.len);
    try std.testing.expectEqualStrings("model.demo.orders", executed.items[0].node.?.unique_id);
    try std.testing.expectEqualStrings("skipped", executed.items[0].status);
    try std.testing.expect(containsUniqueId(blocked.items, "model.demo.orders"));
}

test "appendSkippedBlockedDataTests records selected tests blocked by skipped nodes" {
    const allocator = std.testing.allocator;
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    var orders_test = GenericTestNode{
        .package_name = "demo",
        .unique_id = "test.demo.not_null_orders_order_id.def",
        .name = "not_null_orders_order_id",
        .alias = "not_null_orders_order_id",
        .path = "not_null_orders_order_id.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_not_null(**_dbt_generic_test_kwargs) }}",
        .test_name = "not_null",
        .column_name = "order_id",
        .attached_node = "model.demo.orders",
    };
    try orders_test.depends_on.append(allocator, "model.demo.orders");
    try graph.tests.append(allocator, orders_test);
    var independent_test = GenericTestNode{
        .package_name = "demo",
        .unique_id = "test.demo.not_null_independent_id.ghi",
        .name = "not_null_independent_id",
        .alias = "not_null_independent_id",
        .path = "not_null_independent_id.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_not_null(**_dbt_generic_test_kwargs) }}",
        .test_name = "not_null",
        .column_name = "id",
        .attached_node = "model.demo.independent",
    };
    try independent_test.depends_on.append(allocator, "model.demo.independent");
    try graph.tests.append(allocator, independent_test);

    const selected = [_]selector.SelectedResource{
        .{ .unique_id = "test.demo.not_null_orders_order_id.def", .name = "not_null_orders_order_id", .resource_type = "test" },
        .{ .unique_id = "test.demo.not_null_independent_id.ghi", .name = "not_null_independent_id", .resource_type = "test" },
    };
    const tests = [_]DataTestRef{
        .{ .generic = &graph.tests.items[0] },
        .{ .generic = &graph.tests.items[1] },
    };
    var executed_tests = [_]bool{ false, false };
    const blocked = [_][]const u8{"model.demo.orders"};

    var executed: std.ArrayList(run_results.NodeResult) = .empty;
    defer executed.deinit(allocator);
    try appendSkippedBlockedDataTests(allocator, &selected, &tests, &executed_tests, &blocked, &executed);

    try std.testing.expectEqual(@as(usize, 1), executed.items.len);
    try std.testing.expectEqualStrings("test.demo.not_null_orders_order_id.def", executed.items[0].test_node.?.unique_id);
    try std.testing.expectEqualStrings("skipped", executed.items[0].status);
    try std.testing.expect(executed_tests[0]);
    try std.testing.expect(!executed_tests[1]);
}

test "appendSkippedAfterDataTestFailure skips selected downstream nodes and unexecuted tests" {
    const allocator = std.testing.allocator;
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select null as customer_id",
    });
    var orders = Node{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select * from {{ ref('customers') }}",
    };
    try orders.depends_on.append(allocator, "model.demo.customers");
    try graph.nodes.append(allocator, orders);

    var customers_test = GenericTestNode{
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
    };
    try customers_test.depends_on.append(allocator, "model.demo.customers");
    try graph.tests.append(allocator, customers_test);
    var orders_test = GenericTestNode{
        .package_name = "demo",
        .unique_id = "test.demo.not_null_orders_order_id.def",
        .name = "not_null_orders_order_id",
        .alias = "not_null_orders_order_id",
        .path = "not_null_orders_order_id.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_not_null(**_dbt_generic_test_kwargs) }}",
        .test_name = "not_null",
        .column_name = "order_id",
        .attached_node = "model.demo.orders",
    };
    try orders_test.depends_on.append(allocator, "model.demo.orders");
    try graph.tests.append(allocator, orders_test);

    const selected = [_]selector.SelectedResource{
        .{ .unique_id = "model.demo.customers", .name = "customers", .resource_type = "model" },
        .{ .unique_id = "model.demo.orders", .name = "orders", .resource_type = "model" },
        .{ .unique_id = "test.demo.not_null_customers_customer_id.abc", .name = "not_null_customers_customer_id", .resource_type = "test" },
        .{ .unique_id = "test.demo.not_null_orders_order_id.def", .name = "not_null_orders_order_id", .resource_type = "test" },
    };
    const remaining = [_]*Node{&graph.nodes.items[1]};
    const tests = [_]DataTestRef{
        .{ .generic = &graph.tests.items[0] },
        .{ .generic = &graph.tests.items[1] },
    };
    const executed_tests = [_]bool{ true, false };
    const blocked_roots = [_][]const u8{"model.demo.customers"};

    var executed: std.ArrayList(run_results.NodeResult) = .empty;
    defer executed.deinit(allocator);
    try appendSkippedAfterDataTestFailure(allocator, &selected, &remaining, &tests, &executed_tests, &blocked_roots, &executed);

    try std.testing.expectEqual(@as(usize, 2), executed.items.len);
    try std.testing.expectEqualStrings("model.demo.orders", executed.items[0].node.?.unique_id);
    try std.testing.expectEqualStrings("skipped", executed.items[0].status);
    try std.testing.expectEqualStrings("test.demo.not_null_orders_order_id.def", executed.items[1].test_node.?.unique_id);
    try std.testing.expectEqualStrings("skipped", executed.items[1].status);
}

test "dataTestDependenciesCompleted waits for selected seed and model dependencies" {
    const allocator = std.testing.allocator;
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    var test_node = SingularTestNode{
        .package_name = "demo",
        .unique_id = "test.demo.assert_orders",
        .name = "assert_orders",
        .alias = "assert_orders",
        .path = "assert_orders.sql",
        .original_file_path = "tests/assert_orders.sql",
        .raw_code = "select * from {{ ref('orders') }}",
    };
    try test_node.depends_on.append(allocator, "seed.demo.raw_orders");
    try test_node.depends_on.append(allocator, "model.demo.orders");
    try graph.singular_tests.append(allocator, test_node);

    const test_ref = DataTestRef{ .singular = &graph.singular_tests.items[0] };
    const only_seed_done = [_][]const u8{"seed.demo.raw_orders"};
    const all_done = [_][]const u8{ "seed.demo.raw_orders", "model.demo.orders" };

    try std.testing.expect(!dataTestDependenciesCompleted(test_ref, &only_seed_done));
    try std.testing.expect(dataTestDependenciesCompleted(test_ref, &all_done));
}

test "parseModelPropertiesFromText records accepted_values quote false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    const yaml =
        \\version: 2
        \\models:
        \\  - name: customers
        \\    columns:
        \\      - name: customer_id
        \\        tests:
        \\          - accepted_values:
        \\              arguments:
        \\                values: [1, 2]
        \\                quote: false
    ;

    try parseModelPropertiesFromText(allocator, yaml, "models/schema.yml", "demo", &graph);

    try std.testing.expectEqual(@as(usize, 1), graph.model_properties.items.len);
    const column = graph.model_properties.items[0].columns.items[0];
    try std.testing.expectEqualStrings("customer_id", column.name);
    try std.testing.expectEqual(@as(usize, 1), column.tests.items.len);
    const accepted = column.tests.items[0];
    try std.testing.expectEqualStrings("accepted_values", accepted.name);
    try std.testing.expectEqual(@as(usize, 2), accepted.accepted_values.items.len);
    try std.testing.expectEqualStrings("1", accepted.accepted_values.items[0]);
    try std.testing.expectEqualStrings("2", accepted.accepted_values.items[1]);
    try std.testing.expectEqual(false, accepted.accepted_values_quote.?);
}

test "parseModelPropertiesFromText records seed column generic tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    const yaml =
        \\version: 2
        \\seeds:
        \\  - name: raw_customers
        \\    columns:
        \\      - name: customer_id
        \\        tests:
        \\          - not_null
        \\          - accepted_values:
        \\              arguments:
        \\                values: [1, 2]
        \\                quote: false
    ;

    try parseModelPropertiesFromText(allocator, yaml, "models/schema.yml", "demo", &graph);

    try std.testing.expectEqual(@as(usize, 1), graph.model_properties.items.len);
    const property = graph.model_properties.items[0];
    try std.testing.expectEqualStrings("seed", property.resource_type);
    try std.testing.expectEqualStrings("raw_customers", property.name);
    const column = property.columns.items[0];
    try std.testing.expectEqualStrings("customer_id", column.name);
    try std.testing.expectEqual(@as(usize, 2), column.tests.items.len);
    try std.testing.expectEqualStrings("not_null", column.tests.items[0].name);
    try std.testing.expectEqualStrings("accepted_values", column.tests.items[1].name);
    try std.testing.expectEqual(false, column.tests.items[1].accepted_values_quote.?);
}

test "parseModelPropertiesFromText records seed quote columns and column types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    const yaml =
        \\version: 2
        \\seeds:
        \\  - name: raw_customers
        \\    config:
        \\      quote_columns: false
        \\      column_types:
        \\        amount: decimal(10,2)
        \\        customer_id: integer
    ;

    try parseModelPropertiesFromText(allocator, yaml, "seeds/schema.yml", "demo", &graph);

    try std.testing.expectEqual(@as(usize, 1), graph.model_properties.items.len);
    const property = graph.model_properties.items[0];
    try std.testing.expectEqualStrings("seed", property.resource_type);
    try std.testing.expectEqual(false, property.quote_columns.?);
    try std.testing.expectEqual(@as(usize, 2), property.seed_column_types.items.len);
    try std.testing.expectEqualStrings("amount", property.seed_column_types.items[0].name);
    try std.testing.expectEqualStrings("decimal(10,2)", property.seed_column_types.items[0].data_type);
    try std.testing.expectEqualStrings("customer_id", property.seed_column_types.items[1].name);
    try std.testing.expectEqualStrings("integer", property.seed_column_types.items[1].data_type);
}

test "parseModelPropertiesFromText records table-level generic test column_name arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    const yaml =
        \\version: 2
        \\models:
        \\  - name: customers
        \\    data_tests:
        \\      - not_null:
        \\          arguments:
        \\            column_name: customer_id
        \\seeds:
        \\  - name: raw_customers
        \\    tests:
        \\      - accepted_values:
        \\          arguments:
        \\            column_name: customer_id
        \\            values: [1, 2]
        \\            quote: false
    ;

    try parseModelPropertiesFromText(allocator, yaml, "models/schema.yml", "demo", &graph);

    try std.testing.expectEqual(@as(usize, 2), graph.model_properties.items.len);
    try std.testing.expectEqualStrings("model", graph.model_properties.items[0].resource_type);
    try std.testing.expectEqualStrings("customers", graph.model_properties.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), graph.model_properties.items[0].tests.items.len);
    try std.testing.expectEqualStrings("not_null", graph.model_properties.items[0].tests.items[0].name);
    try std.testing.expectEqualStrings("customer_id", graph.model_properties.items[0].tests.items[0].column_name.?);
    try std.testing.expectEqualStrings("seed", graph.model_properties.items[1].resource_type);
    const seed_test = graph.model_properties.items[1].tests.items[0];
    try std.testing.expectEqualStrings("accepted_values", seed_test.name);
    try std.testing.expectEqualStrings("customer_id", seed_test.column_name.?);
    try std.testing.expectEqual(@as(usize, 2), seed_test.accepted_values.items.len);
    try std.testing.expectEqual(false, seed_test.accepted_values_quote.?);
}

test "parseSingularTestPropertiesFromText records top-level patches and ignores nested generic tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    const yaml =
        \\version: 2
        \\models:
        \\  - name: customers
        \\    columns:
        \\      - name: customer_id
        \\        data_tests:
        \\          - not_null
        \\data_tests:
        \\  - name: assert_customers
        \\    description: "patched singular test"
        \\    config:
        \\      enabled: false
        \\      tags: [nightly, singular]
        \\      where: "status = 'checked'"
        \\      limit: 2
        \\      severity: warn
        \\      warn_if: "> 0"
        \\      error_if: "> 10"
        \\      store_failures: true
    ;

    try parseSingularTestPropertiesFromText(allocator, yaml, "tests/schema.yml", "demo", &graph);

    try std.testing.expectEqual(@as(usize, 1), graph.singular_test_properties.items.len);
    const property = graph.singular_test_properties.items[0];
    try std.testing.expectEqualStrings("assert_customers", property.name);
    try std.testing.expectEqualStrings("tests/schema.yml", property.patch_path);
    try std.testing.expectEqualStrings("patched singular test", property.description);
    try std.testing.expectEqual(false, property.enabled.?);
    try std.testing.expectEqualStrings("status = 'checked'", property.config.where.?);
    try std.testing.expectEqual(@as(u64, 2), property.config.limit.?);
    try std.testing.expectEqualStrings("Warn", property.config.severity);
    try std.testing.expectEqualStrings("> 0", property.config.warn_if);
    try std.testing.expectEqualStrings("> 10", property.config.error_if);
    try std.testing.expectEqual(true, property.config.store_failures.?);
    try std.testing.expectEqual(@as(usize, 2), property.tags.items.len);
    try std.testing.expectEqualStrings("nightly", property.tags.items[0]);
    try std.testing.expectEqualStrings("singular", property.tags.items[1]);
}

test "applySingularTestProperties applies config and preserves inline enabled precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.singular_tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.assert_customers",
        .name = "assert_customers",
        .alias = "assert_customers",
        .path = "assert_customers.sql",
        .original_file_path = "tests/assert_customers.sql",
        .raw_code = "select 1",
    });
    try graph.singular_tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.inline_disabled",
        .name = "inline_disabled",
        .alias = "inline_disabled",
        .path = "inline_disabled.sql",
        .original_file_path = "tests/inline_disabled.sql",
        .raw_code = "{{ config(enabled=false) }} select 1",
        .enabled = false,
        .inline_enabled = true,
    });

    const yaml =
        \\version: 2
        \\tests:
        \\  - name: assert_customers
        \\    description: "patched singular test"
        \\    config:
        \\      enabled: false
        \\      tags: [singular]
        \\      where: "status = 'checked'"
        \\      limit: 1
        \\      severity: warn
        \\      warn_if: "> 0"
        \\      error_if: "> 10"
        \\      store_failures: true
        \\  - name: inline_disabled
        \\    config:
        \\      enabled: true
    ;
    try parseSingularTestPropertiesFromText(allocator, yaml, "tests/schema.yml", "demo", &graph);
    try applySingularTestProperties(&graph, "demo");

    const patched = graph.singular_tests.items[0];
    try std.testing.expect(!patched.enabled);
    try std.testing.expectEqualStrings("tests/schema.yml", patched.patch_path.?);
    try std.testing.expectEqualStrings("patched singular test", patched.description);
    try std.testing.expectEqualStrings("status = 'checked'", patched.config.where.?);
    try std.testing.expectEqual(@as(u64, 1), patched.config.limit.?);
    try std.testing.expectEqualStrings("Warn", patched.config.severity);
    try std.testing.expectEqualStrings("> 0", patched.config.warn_if);
    try std.testing.expectEqualStrings("> 10", patched.config.error_if);
    try std.testing.expectEqual(true, patched.config.store_failures.?);
    try std.testing.expectEqual(@as(usize, 1), patched.tags.items.len);
    try std.testing.expectEqualStrings("singular", patched.tags.items[0]);

    try std.testing.expect(!graph.singular_tests.items[1].enabled);
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
    try parseUnitTestsFromText(runtime.allocator, text, resource_root, relative_path, package_name, graph);
    try parseModelPropertiesFromText(runtime.allocator, text, relative_path, package_name, graph);
    try parseSingularTestPropertiesFromText(runtime.allocator, text, relative_path, package_name, graph);
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
    var in_seed_column_types = false;
    var active_resource_type: []const u8 = "model";
    var test_target: TestTarget = .none;
    var active_test_target: TestTarget = .none;
    var active_values_target: TestTarget = .none;
    var models_indent: usize = 0;
    var model_item_indent: ?usize = null;
    var column_item_indent: ?usize = null;
    var config_indent: usize = 0;
    var seed_column_types_indent: usize = 0;
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

        if (std.mem.eql(u8, trimmed, "models:") or std.mem.eql(u8, trimmed, "seeds:") or std.mem.eql(u8, trimmed, "analyses:")) {
            in_models = true;
            in_columns = false;
            in_config = false;
            in_seed_column_types = false;
            active_resource_type = if (std.mem.eql(u8, trimmed, "seeds:")) "seed" else if (std.mem.eql(u8, trimmed, "analyses:")) "analysis" else "model";
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
        if (indent <= models_indent and !std.mem.eql(u8, trimmed, "models:") and !std.mem.eql(u8, trimmed, "seeds:") and !std.mem.eql(u8, trimmed, "analyses:")) {
            in_models = false;
            in_columns = false;
            in_config = false;
            in_seed_column_types = false;
            test_target = .none;
            active_test_target = .none;
            active_values_target = .none;
            current_model = null;
            current_column = null;
            active_test_index = null;
            active_values_index = null;
            continue;
        }

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
            in_seed_column_types = false;
        }
        if (in_seed_column_types and indent <= seed_column_types_indent) {
            in_seed_column_types = false;
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
                    in_seed_column_types = false;
                } else {
                    try graph.model_properties.append(allocator, .{ .package_name = package_name, .resource_type = active_resource_type, .name = name, .patch_path = relative_path });
                    current_model = graph.model_properties.items.len - 1;
                    current_column = null;
                    model_item_indent = indent;
                    column_item_indent = null;
                    in_columns = false;
                    in_config = false;
                    in_seed_column_types = false;
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
            if (in_seed_column_types and indent > seed_column_types_indent) {
                try appendSeedColumnType(allocator, &graph.model_properties.items[model_index], kv.key, kv.value);
                continue;
            }

            if (active_test_index != null and indent > active_test_indent) {
                if (std.mem.eql(u8, kv.key, "arguments")) {
                    if (std.mem.trim(u8, kv.value, " \t").len != 0) return error.UnsupportedYaml;
                    continue;
                }
                if (std.mem.eql(u8, kv.key, "config")) {
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
                } else if (std.mem.eql(u8, kv.key, "quote")) {
                    if (std.mem.eql(u8, test_def.name, "accepted_values")) {
                        test_def.accepted_values_quote = try parseBool(kv.value);
                    }
                    continue;
                } else if (std.mem.eql(u8, kv.key, "column_name")) {
                    test_def.column_name = try dupTrimmedScalar(allocator, kv.value);
                    continue;
                } else if (std.mem.eql(u8, kv.key, "to")) {
                    test_def.relationship_to = try dupTrimmedScalar(allocator, kv.value);
                    continue;
                } else if (std.mem.eql(u8, kv.key, "field")) {
                    test_def.relationship_field = try dupTrimmedScalar(allocator, kv.value);
                    continue;
                }
                if (try applyGenericTestConfigValue(allocator, test_def, kv.key, kv.value)) continue;
            }

            if (in_config and indent > config_indent) {
                if (std.mem.eql(u8, kv.key, "enabled")) {
                    graph.model_properties.items[model_index].enabled = try parseBool(kv.value);
                } else if (std.mem.eql(u8, kv.key, "materialized")) {
                    graph.model_properties.items[model_index].materialized = try dupTrimmedScalar(allocator, kv.value);
                } else if (std.mem.eql(u8, kv.key, "tags")) {
                    try parseInlineStringList(allocator, kv.value, &graph.model_properties.items[model_index].tags);
                    sortStrings(graph.model_properties.items[model_index].tags.items);
                } else if (std.mem.eql(u8, active_resource_type, "seed") and std.mem.eql(u8, kv.key, "quote_columns")) {
                    graph.model_properties.items[model_index].quote_columns = try parseBool(kv.value);
                } else if (std.mem.eql(u8, active_resource_type, "seed") and std.mem.eql(u8, kv.key, "column_types")) {
                    if (std.mem.trim(u8, kv.value, " \t").len != 0) return error.UnsupportedYaml;
                    in_seed_column_types = true;
                    seed_column_types_indent = indent;
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

fn parseSingularTestPropertiesFromText(allocator: std.mem.Allocator, text: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    var in_data_tests = false;
    var in_config = false;
    var data_tests_indent: usize = 0;
    var test_item_indent: usize = 0;
    var config_indent: usize = 0;
    var current_test: ?usize = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);

        if (indent == 0 and (std.mem.eql(u8, trimmed, "data_tests:") or std.mem.eql(u8, trimmed, "tests:"))) {
            in_data_tests = true;
            in_config = false;
            data_tests_indent = indent;
            current_test = null;
            continue;
        }
        if (!in_data_tests) continue;
        if (indent <= data_tests_indent and !std.mem.eql(u8, trimmed, "data_tests:")) {
            in_data_tests = false;
            in_config = false;
            current_test = null;
            continue;
        }
        if (in_config and indent <= config_indent and !std.mem.eql(u8, trimmed, "config:")) {
            in_config = false;
        }

        if (std.mem.startsWith(u8, trimmed, "- ")) {
            if (in_config and indent > config_indent) return error.UnsupportedYaml;
            if (!std.mem.startsWith(u8, trimmed, "- name:")) return error.UnsupportedYaml;
            const name = try dupTrimmedScalar(allocator, trimmed["- name:".len..]);
            try graph.singular_test_properties.append(allocator, .{
                .package_name = package_name,
                .name = name,
                .patch_path = relative_path,
            });
            current_test = graph.singular_test_properties.items.len - 1;
            test_item_indent = indent;
            in_config = false;
            continue;
        }

        const test_index = current_test orelse continue;
        if (indent <= test_item_indent) continue;
        if (splitKeyValue(trimmed)) |kv| {
            if (in_config and indent > config_indent) {
                var property = &graph.singular_test_properties.items[test_index];
                if (std.mem.eql(u8, kv.key, "enabled")) {
                    property.enabled = try parseBool(kv.value);
                } else if (std.mem.eql(u8, kv.key, "tags")) {
                    try parseInlineStringList(allocator, kv.value, &property.tags);
                } else if (try applySingularTestConfigValue(allocator, property, kv.key, kv.value)) {
                    continue;
                } else if (std.mem.eql(u8, kv.key, "store_failures") or std.mem.eql(u8, kv.key, "store_failures_as")) {
                    return error.UnsupportedYaml;
                } else {
                    return error.UnsupportedYaml;
                }
                continue;
            }
            if (std.mem.eql(u8, kv.key, "description")) {
                graph.singular_test_properties.items[test_index].description = try dupTrimmedScalar(allocator, kv.value);
            } else if (std.mem.eql(u8, kv.key, "config")) {
                if (std.mem.trim(u8, kv.value, " \t").len != 0) return error.UnsupportedYaml;
                in_config = true;
                config_indent = indent;
            }
        }
    }
}

fn applySingularTestConfigValue(allocator: std.mem.Allocator, property: *types.SingularTestProperty, key: []const u8, value: []const u8) !bool {
    if (std.mem.eql(u8, key, "where")) {
        property.config.where = try dupTrimmedScalar(allocator, value);
        return true;
    }
    if (std.mem.eql(u8, key, "limit")) {
        const limit_text = try dupTrimmedScalar(allocator, value);
        defer allocator.free(limit_text);
        property.config.limit = std.fmt.parseUnsigned(u64, limit_text, 10) catch return error.UnsupportedYaml;
        return true;
    }
    if (std.mem.eql(u8, key, "severity")) {
        property.config.severity = try dupNormalizedSingularTestSeverity(allocator, value);
        return true;
    }
    if (std.mem.eql(u8, key, "warn_if")) {
        property.config.warn_if = try dupTrimmedScalar(allocator, value);
        return true;
    }
    if (std.mem.eql(u8, key, "error_if")) {
        property.config.error_if = try dupTrimmedScalar(allocator, value);
        return true;
    }
    if (std.mem.eql(u8, key, "store_failures")) {
        property.config.store_failures = try parseBool(value);
        return true;
    }
    return false;
}

fn dupNormalizedSingularTestSeverity(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const severity = try dupTrimmedScalar(allocator, value);
    defer allocator.free(severity);
    if (std.ascii.eqlIgnoreCase(severity, "warn")) return try allocator.dupe(u8, "Warn");
    if (std.ascii.eqlIgnoreCase(severity, "error")) return try allocator.dupe(u8, "Error");
    return error.UnsupportedYaml;
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

fn parseAnalysis(runtime: Runtime, project_dir: []const u8, analysis_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    const full_path = try pathJoin(runtime.allocator, &.{ project_dir, relative_path });
    const sql = try std.Io.Dir.cwd().readFileAlloc(runtime.io, full_path, runtime.allocator, .limited(16 * 1024 * 1024));
    const analysis_name = try modelNameFromPath(runtime.allocator, relative_path);
    const unique_id = try std.fmt.allocPrint(runtime.allocator, "analysis.{s}.{s}", .{ package_name, analysis_name });
    const relative_analysis_path = relativeUnderResourcePath(relative_path, analysis_root);
    const analysis_path = try pathJoin(runtime.allocator, &.{ "analysis", relative_analysis_path });

    var node = Node{
        .resource_type = "analysis",
        .package_name = package_name,
        .unique_id = unique_id,
        .name = analysis_name,
        .path = analysis_path,
        .original_file_path = relative_path,
        .raw_code = sql,
        .materialized = "analysis",
    };
    errdefer deinitNode(runtime.allocator, &node);
    try project_jinja.scanSql(runtime.allocator, sql, &node, graph);
    node.materialized = "analysis";
    node.inline_materialized = false;
    try graph.nodes.append(runtime.allocator, node);
}

fn parseSingularTest(runtime: Runtime, project_dir: []const u8, test_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    const full_path = try pathJoin(runtime.allocator, &.{ project_dir, relative_path });
    const sql = try std.Io.Dir.cwd().readFileAlloc(runtime.io, full_path, runtime.allocator, .limited(16 * 1024 * 1024));
    const test_name = try resourceNameFromPath(runtime.allocator, relative_path, ".sql");
    const unique_id = try std.fmt.allocPrint(runtime.allocator, "test.{s}.{s}", .{ package_name, test_name });
    const test_path = relativeUnderResourcePath(relative_path, test_root);

    var scan_node = Node{
        .resource_type = "test",
        .package_name = package_name,
        .unique_id = unique_id,
        .name = test_name,
        .path = test_path,
        .original_file_path = relative_path,
        .raw_code = sql,
        .materialized = "test",
    };
    defer deinitNode(runtime.allocator, &scan_node);
    try project_jinja.scanSql(runtime.allocator, sql, &scan_node, graph);

    var test_node = SingularTestNode{
        .package_name = package_name,
        .unique_id = unique_id,
        .name = test_name,
        .alias = test_name,
        .path = test_path,
        .original_file_path = relative_path,
        .raw_code = sql,
        .config = scan_node.test_config,
        .enabled = scan_node.enabled,
        .inline_enabled = scan_node.inline_enabled,
        .inline_store_failures = scan_node.inline_store_failures,
        .refs = scan_node.refs,
        .source_refs = scan_node.source_refs,
        .macro_depends_on = scan_node.macro_depends_on,
    };
    scan_node.refs = .empty;
    scan_node.source_refs = .empty;
    scan_node.macro_depends_on = .empty;
    errdefer deinitSingularTestNode(runtime.allocator, &test_node);
    try graph.singular_tests.append(runtime.allocator, test_node);
}

fn parseSeed(runtime: Runtime, project_root: []const u8, seed_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    const full_path = try pathJoin(runtime.allocator, &.{ project_root, relative_path });
    defer runtime.allocator.free(full_path);
    const raw_csv = try std.Io.Dir.cwd().readFileAlloc(runtime.io, full_path, runtime.allocator, .limited(16 * 1024 * 1024));
    const seed_name = try resourceNameFromPath(runtime.allocator, relative_path, ".csv");
    const unique_id = try std.fmt.allocPrint(runtime.allocator, "seed.{s}.{s}", .{ package_name, seed_name });
    const seed_path = relativeUnderResourcePath(relative_path, seed_root);

    var node = Node{
        .resource_type = "seed",
        .package_name = package_name,
        .unique_id = unique_id,
        .name = seed_name,
        .project_root = try runtime.allocator.dupe(u8, project_root),
        .path = seed_path,
        .original_file_path = relative_path,
        .raw_code = raw_csv,
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
        const node_index = findNodeIndexByResourceTypeAndName(graph, property.package_name, property.resource_type, property.name) orelse {
            try graph.unmatched_model_properties.append(graph.allocator, .{ .resource_type = property.resource_type, .name = property.name, .patch_path = property.patch_path });
            continue;
        };
        var node = &graph.nodes.items[node_index];
        node.patch_path = property.patch_path;
        if (property.description.len != 0) node.description = try resolveDocDescription(graph, property.package_name, property.description, &node.doc_blocks);
        if (std.mem.eql(u8, node.resource_type, "model") and property.materialized.len != 0 and !node.inline_materialized) node.materialized = property.materialized;
        if (std.mem.eql(u8, node.resource_type, "seed")) {
            if (property.quote_columns) |quote_columns| node.quote_columns = quote_columns;
            if (property.seed_column_types.items.len != 0) {
                node.seed_column_types.clearRetainingCapacity();
                for (property.seed_column_types.items) |column_type| {
                    try node.seed_column_types.append(graph.allocator, column_type);
                }
                sortSeedColumnTypes(node.seed_column_types.items);
            }
        }
        if (property.enabled) |enabled| {
            if (!node.inline_enabled) node.enabled = enabled;
        }
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

fn applySingularTestProperties(graph: *Graph, package_name: []const u8) !void {
    for (graph.singular_test_properties.items) |property| {
        if (!std.mem.eql(u8, property.package_name, package_name)) continue;
        const test_index = findSingularTestIndexByPackageAndName(graph, property.package_name, property.name) orelse continue;
        var test_node = &graph.singular_tests.items[test_index];
        test_node.patch_path = property.patch_path;
        if (property.description.len != 0) test_node.description = try resolveDocDescription(graph, property.package_name, property.description, &test_node.doc_blocks);
        if (property.enabled) |enabled| {
            if (!test_node.inline_enabled) test_node.enabled = enabled;
        }
        if (property.config.where) |where_sql| test_node.config.where = where_sql;
        if (property.config.limit) |limit| test_node.config.limit = limit;
        test_node.config.severity = property.config.severity;
        test_node.config.warn_if = property.config.warn_if;
        test_node.config.error_if = property.config.error_if;
        if (!test_node.inline_store_failures) test_node.config.store_failures = property.config.store_failures;
        for (property.tags.items) |tag| {
            try appendUnique(graph.allocator, &test_node.tags, tag);
        }
    }
}

fn findSingularTestIndexByPackageAndName(graph: *const Graph, package_name: []const u8, name: []const u8) ?usize {
    for (graph.singular_tests.items, 0..) |test_node, index| {
        if (std.mem.eql(u8, test_node.package_name, package_name) and std.mem.eql(u8, test_node.name, name)) return index;
    }
    return null;
}

fn materializeGenericTests(graph: *Graph) !void {
    for (graph.nodes.items) |*node| {
        if (!node.enabled or (!std.mem.eql(u8, node.resource_type, "model") and !std.mem.eql(u8, node.resource_type, "seed"))) continue;
        for (node.tests.items) |test_def| {
            if (isSupportedGenericTest(test_def, null)) {
                try appendGenericTestNode(graph, node, test_def, null);
            }
        }
        for (node.columns.items) |column| {
            for (column.tests.items) |test_def| {
                if (isSupportedGenericTest(test_def, column.name)) {
                    try appendGenericTestNode(graph, node, test_def, column.name);
                } else if (try nodeColumnCustomGenericTestDef(graph, node, test_def, column.name)) |custom_test_def| {
                    try appendGenericTestNode(graph, node, custom_test_def, column.name);
                }
            }
        }
    }
    for (graph.sources.items) |*source| {
        for (source.tests.items) |test_def| {
            if (isSupportedSourceGenericTest(test_def, null) and genericTestColumnName(test_def, null) != null) {
                try appendSourceGenericTestNode(graph, source, test_def, null);
            }
        }
        for (source.columns.items) |column| {
            for (column.tests.items) |test_def| {
                if (isSupportedSourceGenericTest(test_def, column.name)) {
                    try appendSourceGenericTestNode(graph, source, test_def, column.name);
                } else if (try sourceColumnCustomGenericTestDef(graph, source, test_def, column.name)) |custom_test_def| {
                    try appendSourceGenericTestNode(graph, source, custom_test_def, column.name);
                }
            }
        }
    }
}

fn appendGenericTestNode(graph: *Graph, node: *const Node, test_def: GenericTestDef, column_name: ?[]const u8) !void {
    const effective_column_name = genericTestColumnName(test_def, column_name);
    const names = try synthesizeGenericTestNames(graph.allocator, test_def, node.name, effective_column_name);
    const unique_id = try genericTestUniqueId(graph.allocator, node.package_name, names.full, test_def, node.name, effective_column_name);
    for (graph.tests.items) |existing| {
        if (std.mem.eql(u8, existing.unique_id, unique_id)) return;
    }

    const macro_call = if (test_def.namespace) |namespace|
        try std.fmt.allocPrint(graph.allocator, "{s}.test_{s}", .{ namespace, test_def.name })
    else
        try std.fmt.allocPrint(graph.allocator, "test_{s}", .{test_def.name});
    defer graph.allocator.free(macro_call);
    const raw_code = if (std.mem.eql(u8, names.compiled, names.full))
        try std.fmt.allocPrint(graph.allocator, "{{{{ {s}(**_dbt_generic_test_kwargs) }}}}", .{macro_call})
    else
        try std.fmt.allocPrint(graph.allocator, "{{{{ {s}(**_dbt_generic_test_kwargs) }}}}{{{{ config(alias=\"{s}\") }}}}", .{ macro_call, names.compiled });
    var test_node = GenericTestNode{
        .package_name = node.package_name,
        .unique_id = unique_id,
        .name = names.full,
        .alias = names.compiled,
        .path = try std.fmt.allocPrint(graph.allocator, "{s}.sql", .{names.compiled}),
        .original_file_path = node.patch_path orelse node.original_file_path,
        .raw_code = raw_code,
        .test_name = test_def.name,
        .test_namespace = test_def.namespace,
        .column_name = column_name,
        .argument_column_name = effective_column_name,
        .accepted_values_quote = test_def.accepted_values_quote,
        .relationship_to = test_def.relationship_to,
        .relationship_field = test_def.relationship_field,
        .config = test_def.config,
        .attached_node = node.unique_id,
    };
    errdefer deinitGenericTestNode(graph.allocator, &test_node);

    for (test_def.accepted_values.items) |value| {
        try test_node.accepted_values.append(graph.allocator, value);
    }
    if (std.mem.eql(u8, test_def.name, "relationships")) {
        if (isSourceRelationshipTarget(test_def.relationship_to)) {
            const target_source = try sourceDepFromValue(graph.allocator, test_def.relationship_to);
            test_node.relationship_source_to = target_source;
            try appendSourceDepUnique(graph.allocator, &test_node.source_refs, target_source);
            const target_unique_id = try resolveSourceDependency(graph, node.package_name, target_source);
            test_node.relationship_source_to_unique_id = target_unique_id;
            try appendUnique(graph.allocator, &test_node.depends_on, target_unique_id);
        } else {
            const target_ref = try refDepFromValue(graph.allocator, test_def.relationship_to);
            try test_node.refs.append(graph.allocator, target_ref);
            const target_unique_id = try resolveRefDependency(graph, node.package_name, target_ref);
            try appendUnique(graph.allocator, &test_node.depends_on, target_unique_id);
        }
    }
    try test_node.refs.append(graph.allocator, .{ .package = null, .name = node.name });
    try appendUnique(graph.allocator, &test_node.depends_on, node.unique_id);
    try appendGenericTestMacroDependency(graph, &test_node, test_def);
    if (isBuiltInGenericTestName(test_def.name) and !std.mem.eql(u8, test_def.name, "not_null") and !std.mem.eql(u8, test_def.name, "unique")) {
        try test_node.macro_depends_on.append(graph.allocator, "macro.dbt.get_where_subquery");
    }
    try graph.tests.append(graph.allocator, test_node);
}

fn appendSourceGenericTestNode(graph: *Graph, source: *const SourceDef, test_def: GenericTestDef, column_name: ?[]const u8) !void {
    const effective_column_name = genericTestColumnName(test_def, column_name);
    const source_target_name = try std.fmt.allocPrint(graph.allocator, "{s}_{s}", .{ source.source_name, source.table_name });
    defer graph.allocator.free(source_target_name);
    const source_test_name = try std.fmt.allocPrint(graph.allocator, "source_{s}", .{test_def.name});
    defer graph.allocator.free(source_test_name);
    const source_model_kwarg = try std.fmt.allocPrint(graph.allocator, "{{{{ get_where_subquery(source('{s}', '{s}')) }}}}", .{ source.source_name, source.table_name });
    defer graph.allocator.free(source_model_kwarg);
    const source_test_def = GenericTestDef{
        .name = source_test_name,
        .namespace = test_def.namespace,
        .column_name = test_def.column_name,
        .accepted_values = test_def.accepted_values,
        .accepted_values_quote = test_def.accepted_values_quote,
        .relationship_to = test_def.relationship_to,
        .relationship_field = test_def.relationship_field,
        .config = test_def.config,
    };
    const names = try synthesizeGenericTestNames(graph.allocator, source_test_def, source_target_name, effective_column_name);
    const unique_id_metadata = if (isBuiltInGenericTestName(test_def.name)) source_test_def else test_def;
    const unique_id = try genericTestUniqueIdForModelKwarg(graph.allocator, source.package_name, names.full, unique_id_metadata, source_model_kwarg, effective_column_name);
    for (graph.tests.items) |existing| {
        if (std.mem.eql(u8, existing.unique_id, unique_id)) return;
    }

    const macro_call = if (test_def.namespace) |namespace|
        try std.fmt.allocPrint(graph.allocator, "{s}.test_{s}", .{ namespace, test_def.name })
    else
        try std.fmt.allocPrint(graph.allocator, "test_{s}", .{test_def.name});
    defer graph.allocator.free(macro_call);
    const raw_code = if (std.mem.eql(u8, names.compiled, names.full))
        try std.fmt.allocPrint(graph.allocator, "{{{{ {s}(**_dbt_generic_test_kwargs) }}}}", .{macro_call})
    else
        try std.fmt.allocPrint(graph.allocator, "{{{{ {s}(**_dbt_generic_test_kwargs) }}}}{{{{ config(alias=\"{s}\") }}}}", .{ macro_call, names.compiled });
    var test_node = GenericTestNode{
        .package_name = source.package_name,
        .unique_id = unique_id,
        .name = names.full,
        .alias = names.compiled,
        .path = try std.fmt.allocPrint(graph.allocator, "{s}.sql", .{names.compiled}),
        .original_file_path = source.original_file_path,
        .raw_code = raw_code,
        .test_name = test_def.name,
        .test_namespace = test_def.namespace,
        .column_name = column_name,
        .argument_column_name = effective_column_name,
        .accepted_values_quote = test_def.accepted_values_quote,
        .relationship_to = test_def.relationship_to,
        .relationship_field = test_def.relationship_field,
        .config = test_def.config,
        .attached_node = null,
        .attached_source = .{ .source_name = source.source_name, .table_name = source.table_name },
        .attached_source_unique_id = source.unique_id,
    };
    errdefer deinitGenericTestNode(graph.allocator, &test_node);

    for (test_def.accepted_values.items) |value| {
        try test_node.accepted_values.append(graph.allocator, value);
    }
    const attached_source_dep = SourceDep{ .source_name = source.source_name, .table_name = source.table_name };
    if (std.mem.eql(u8, test_def.name, "relationships")) {
        if (isSourceRelationshipTarget(test_def.relationship_to)) {
            const target_source = try sourceDepFromValue(graph.allocator, test_def.relationship_to);
            test_node.relationship_source_to = target_source;
            try appendSourceDepUnique(graph.allocator, &test_node.source_refs, target_source);
            const target_unique_id = try resolveSourceDependency(graph, source.package_name, target_source);
            test_node.relationship_source_to_unique_id = target_unique_id;
            try appendUnique(graph.allocator, &test_node.depends_on, target_unique_id);
            try appendSourceDepUnique(graph.allocator, &test_node.source_refs, attached_source_dep);
            try appendUnique(graph.allocator, &test_node.depends_on, source.unique_id);
        } else {
            try appendSourceDepUnique(graph.allocator, &test_node.source_refs, attached_source_dep);
            try appendUnique(graph.allocator, &test_node.depends_on, source.unique_id);
            const target_ref = try refDepFromValue(graph.allocator, test_def.relationship_to);
            try test_node.refs.append(graph.allocator, target_ref);
            const target_unique_id = try resolveRefDependency(graph, source.package_name, target_ref);
            try appendUnique(graph.allocator, &test_node.depends_on, target_unique_id);
        }
    } else {
        try appendSourceDepUnique(graph.allocator, &test_node.source_refs, attached_source_dep);
        try appendUnique(graph.allocator, &test_node.depends_on, source.unique_id);
    }
    try appendGenericTestMacroDependency(graph, &test_node, test_def);
    if (isBuiltInGenericTestName(test_def.name) and !std.mem.eql(u8, test_def.name, "not_null") and !std.mem.eql(u8, test_def.name, "unique")) {
        try test_node.macro_depends_on.append(graph.allocator, "macro.dbt.get_where_subquery");
    }
    try graph.tests.append(graph.allocator, test_node);
}

fn genericTestColumnName(test_def: GenericTestDef, fallback: ?[]const u8) ?[]const u8 {
    return fallback orelse test_def.column_name;
}

fn genericTestNodeColumnName(test_node: *const GenericTestNode) ?[]const u8 {
    return test_node.argument_column_name orelse test_node.column_name;
}

fn isSourceRelationshipTarget(value: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trim(u8, value, " \t\r"), "source(");
}

fn appendSourceDepUnique(allocator: std.mem.Allocator, values: *std.ArrayList(SourceDep), source_dep: SourceDep) !void {
    for (values.items) |existing| {
        if (std.mem.eql(u8, existing.source_name, source_dep.source_name) and std.mem.eql(u8, existing.table_name, source_dep.table_name)) return;
    }
    try values.append(allocator, source_dep);
}

fn isSupportedGenericTest(test_def: GenericTestDef, column_name: ?[]const u8) bool {
    _ = column_name;
    return std.mem.eql(u8, test_def.name, "not_null") or
        std.mem.eql(u8, test_def.name, "unique") or
        (std.mem.eql(u8, test_def.name, "accepted_values") and test_def.accepted_values.items.len != 0) or
        (std.mem.eql(u8, test_def.name, "relationships") and test_def.relationship_to.len != 0 and test_def.relationship_field.len != 0);
}

fn isSupportedSourceGenericTest(test_def: GenericTestDef, column_name: ?[]const u8) bool {
    _ = column_name;
    return std.mem.eql(u8, test_def.name, "not_null") or
        std.mem.eql(u8, test_def.name, "unique") or
        (std.mem.eql(u8, test_def.name, "accepted_values") and test_def.accepted_values.items.len != 0) or
        (std.mem.eql(u8, test_def.name, "relationships") and test_def.relationship_to.len != 0 and test_def.relationship_field.len != 0);
}

fn isBuiltInGenericTestName(test_name: []const u8) bool {
    return std.mem.eql(u8, test_name, "not_null") or
        std.mem.eql(u8, test_name, "unique") or
        std.mem.eql(u8, test_name, "accepted_values") or
        std.mem.eql(u8, test_name, "relationships");
}

const GenericTestNamespace = struct {
    namespace: []const u8,
    name: []const u8,
};

fn splitGenericTestNamespace(test_name: []const u8) !?GenericTestNamespace {
    const first_dot = std.mem.indexOfScalar(u8, test_name, '.') orelse return null;
    if (std.mem.indexOfScalar(u8, test_name[first_dot + 1 ..], '.') != null) return error.UnsupportedCustomGenericTest;
    if (first_dot == 0 or first_dot + 1 >= test_name.len) return error.UnsupportedCustomGenericTest;
    return .{ .namespace = test_name[0..first_dot], .name = test_name[first_dot + 1 ..] };
}

fn nodeColumnCustomGenericTestDef(graph: *const Graph, node: *const Node, test_def: GenericTestDef, column_name: ?[]const u8) !?GenericTestDef {
    if (column_name == null) return null;
    if (isBuiltInGenericTestName(test_def.name)) return null;
    if (!std.mem.eql(u8, node.resource_type, "model") and !std.mem.eql(u8, node.resource_type, "seed")) return null;

    return try columnCustomGenericTestDef(graph, node.package_name, test_def);
}

fn sourceColumnCustomGenericTestDef(graph: *const Graph, source: *const SourceDef, test_def: GenericTestDef, column_name: ?[]const u8) !?GenericTestDef {
    if (column_name == null) return null;
    if (isBuiltInGenericTestName(test_def.name)) return null;

    return try columnCustomGenericTestDef(graph, source.package_name, test_def);
}

fn columnCustomGenericTestDef(graph: *const Graph, package_name: []const u8, test_def: GenericTestDef) !?GenericTestDef {
    const namespace_parts = try splitGenericTestNamespace(test_def.name);
    const macro_package = if (namespace_parts) |parts| parts.namespace else graph.project_name;
    const macro_test_name = if (namespace_parts) |parts| parts.name else test_def.name;
    if (namespace_parts == null and !std.mem.eql(u8, package_name, graph.project_name)) return null;
    if (std.mem.eql(u8, macro_package, "dbt")) return error.UnsupportedCustomGenericTest;

    const macro_name = try std.fmt.allocPrint(graph.allocator, "test_{s}", .{macro_test_name});
    defer graph.allocator.free(macro_name);
    if (findMacroIdByPackageAndName(graph, macro_package, macro_name) == null) {
        if (namespace_parts != null) return error.UnresolvedMacro;
        return null;
    }

    return GenericTestDef{
        .name = macro_test_name,
        .namespace = if (namespace_parts) |parts| parts.namespace else null,
        .column_name = test_def.column_name,
        .accepted_values_quote = test_def.accepted_values_quote,
        .relationship_to = test_def.relationship_to,
        .relationship_field = test_def.relationship_field,
        .config = test_def.config,
    };
}

fn appendGenericTestMacroDependency(graph: *Graph, test_node: *GenericTestNode, test_def: GenericTestDef) !void {
    if (isBuiltInGenericTestName(test_def.name)) {
        try test_node.macro_depends_on.append(graph.allocator, try std.fmt.allocPrint(graph.allocator, "macro.dbt.test_{s}", .{test_def.name}));
        return;
    }

    const macro_name = try std.fmt.allocPrint(graph.allocator, "test_{s}", .{test_def.name});
    defer graph.allocator.free(macro_name);
    const macro_package = test_def.namespace orelse graph.project_name;
    const macro_id = findMacroIdByPackageAndName(graph, macro_package, macro_name) orelse return error.UnresolvedMacro;
    try test_node.macro_depends_on.append(graph.allocator, macro_id);
    try test_node.macro_depends_on.append(graph.allocator, "macro.dbt.get_where_subquery");
}

test "materializeGenericTests activates root project model column custom generic tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .patch_path = "models/schema.yml",
        .raw_code = "select 1 as amount",
    };
    var column = ColumnDef{ .name = "amount" };
    try column.tests.append(allocator, .{ .name = "positive_amount" });
    try node.columns.append(allocator, column);
    try graph.nodes.append(allocator, node);
    try graph.macros.append(allocator, .{
        .package_name = "demo",
        .unique_id = "macro.demo.test_positive_amount",
        .name = "test_positive_amount",
        .path = "custom_tests.sql",
        .original_file_path = "macros/custom_tests.sql",
        .macro_sql = "{% test positive_amount(model, column_name) %}select {{ column_name }} from {{ model }}{% endtest %}",
    });

    try materializeGenericTests(&graph);

    try std.testing.expectEqual(@as(usize, 1), graph.tests.items.len);
    const test_node = graph.tests.items[0];
    try std.testing.expectEqualStrings("positive_amount", test_node.test_name);
    try std.testing.expectEqualStrings("amount", test_node.column_name.?);
    try std.testing.expectEqualStrings("amount", test_node.argument_column_name.?);
    try std.testing.expectEqualStrings("model.demo.orders", test_node.attached_node.?);
    try std.testing.expectEqualStrings("{{ test_positive_amount(**_dbt_generic_test_kwargs) }}", test_node.raw_code);
    try std.testing.expectEqual(@as(usize, 1), test_node.depends_on.items.len);
    try std.testing.expectEqualStrings("model.demo.orders", test_node.depends_on.items[0]);
    try std.testing.expectEqual(@as(usize, 2), test_node.macro_depends_on.items.len);
    try std.testing.expectEqualStrings("macro.demo.test_positive_amount", test_node.macro_depends_on.items[0]);
    try std.testing.expectEqualStrings("macro.dbt.get_where_subquery", test_node.macro_depends_on.items[1]);
}

test "materializeGenericTests activates package model column custom generic tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .patch_path = "models/schema.yml",
        .raw_code = "select 1 as amount",
    };
    var column = ColumnDef{ .name = "amount" };
    try column.tests.append(allocator, .{ .name = "util_pkg.positive_amount" });
    try node.columns.append(allocator, column);
    try graph.nodes.append(allocator, node);
    try graph.macros.append(allocator, .{
        .package_name = "util_pkg",
        .unique_id = "macro.util_pkg.test_positive_amount",
        .name = "test_positive_amount",
        .path = "custom_tests.sql",
        .original_file_path = "macros/custom_tests.sql",
        .macro_sql = "{% data_test positive_amount(model, column_name) %}select {{ column_name }} from {{ model }}{% enddata_test %}",
    });

    try materializeGenericTests(&graph);

    try std.testing.expectEqual(@as(usize, 1), graph.tests.items.len);
    const test_node = graph.tests.items[0];
    try std.testing.expectEqualStrings("positive_amount", test_node.test_name);
    try std.testing.expectEqualStrings("util_pkg", test_node.test_namespace.?);
    try std.testing.expectEqualStrings("util_pkg_positive_amount_orders_amount", test_node.name);
    try std.testing.expectEqualStrings("{{ util_pkg.test_positive_amount(**_dbt_generic_test_kwargs) }}", test_node.raw_code);
    try std.testing.expectEqual(@as(usize, 2), test_node.macro_depends_on.items.len);
    try std.testing.expectEqualStrings("macro.util_pkg.test_positive_amount", test_node.macro_depends_on.items[0]);
    try std.testing.expectEqualStrings("macro.dbt.get_where_subquery", test_node.macro_depends_on.items[1]);
}

test "materializeGenericTests activates root project source column custom generic tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    var source = SourceDef{
        .package_name = "demo",
        .unique_id = "source.demo.raw.orders_src",
        .source_name = "raw",
        .table_name = "orders_src",
        .original_file_path = "models/schema.yml",
    };
    var column = ColumnDef{ .name = "amount" };
    try column.tests.append(allocator, .{ .name = "positive_amount" });
    try source.columns.append(allocator, column);
    try graph.sources.append(allocator, source);
    try graph.macros.append(allocator, .{
        .package_name = "demo",
        .unique_id = "macro.demo.test_positive_amount",
        .name = "test_positive_amount",
        .path = "custom_tests.sql",
        .original_file_path = "macros/custom_tests.sql",
        .macro_sql = "{% test positive_amount(model, column_name) %}select {{ column_name }} from {{ model }}{% endtest %}",
    });

    try materializeGenericTests(&graph);

    try std.testing.expectEqual(@as(usize, 1), graph.tests.items.len);
    const test_node = graph.tests.items[0];
    try std.testing.expectEqualStrings("positive_amount", test_node.test_name);
    try std.testing.expectEqualStrings("source_positive_amount_raw_orders_src_amount", test_node.name);
    try std.testing.expectEqualStrings("amount", test_node.column_name.?);
    try std.testing.expect(test_node.attached_node == null);
    try std.testing.expectEqualStrings("source.demo.raw.orders_src", test_node.attached_source_unique_id.?);
    try std.testing.expectEqualStrings("{{ test_positive_amount(**_dbt_generic_test_kwargs) }}", test_node.raw_code);
    try std.testing.expectEqual(@as(usize, 1), test_node.depends_on.items.len);
    try std.testing.expectEqualStrings("source.demo.raw.orders_src", test_node.depends_on.items[0]);
    try std.testing.expectEqual(@as(usize, 2), test_node.macro_depends_on.items.len);
    try std.testing.expectEqualStrings("macro.demo.test_positive_amount", test_node.macro_depends_on.items[0]);
    try std.testing.expectEqualStrings("macro.dbt.get_where_subquery", test_node.macro_depends_on.items[1]);
}

test "materializeGenericTests activates package seed column custom generic tests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    var node = Node{
        .resource_type = "seed",
        .package_name = "demo",
        .unique_id = "seed.demo.orders_seed",
        .name = "orders_seed",
        .path = "orders_seed.csv",
        .original_file_path = "seeds/orders_seed.csv",
        .patch_path = "models/schema.yml",
        .raw_code = "",
    };
    var column = ColumnDef{ .name = "amount" };
    try column.tests.append(allocator, .{ .name = "util_pkg.nonzero_amount" });
    try node.columns.append(allocator, column);
    try graph.nodes.append(allocator, node);
    try graph.macros.append(allocator, .{
        .package_name = "util_pkg",
        .unique_id = "macro.util_pkg.test_nonzero_amount",
        .name = "test_nonzero_amount",
        .path = "custom_tests.sql",
        .original_file_path = "macros/custom_tests.sql",
        .macro_sql = "{% data_test nonzero_amount(model, column_name) %}select {{ column_name }} from {{ model }}{% enddata_test %}",
    });

    try materializeGenericTests(&graph);

    try std.testing.expectEqual(@as(usize, 1), graph.tests.items.len);
    const test_node = graph.tests.items[0];
    try std.testing.expectEqualStrings("nonzero_amount", test_node.test_name);
    try std.testing.expectEqualStrings("util_pkg", test_node.test_namespace.?);
    try std.testing.expectEqualStrings("util_pkg_nonzero_amount_orders_seed_amount", test_node.name);
    try std.testing.expectEqualStrings("seed.demo.orders_seed", test_node.attached_node.?);
    try std.testing.expectEqualStrings("{{ util_pkg.test_nonzero_amount(**_dbt_generic_test_kwargs) }}", test_node.raw_code);
    try std.testing.expectEqual(@as(usize, 1), test_node.depends_on.items.len);
    try std.testing.expectEqualStrings("seed.demo.orders_seed", test_node.depends_on.items[0]);
    try std.testing.expectEqual(@as(usize, 2), test_node.macro_depends_on.items.len);
    try std.testing.expectEqualStrings("macro.util_pkg.test_nonzero_amount", test_node.macro_depends_on.items[0]);
    try std.testing.expectEqualStrings("macro.dbt.get_where_subquery", test_node.macro_depends_on.items[1]);
}

test "materializeGenericTests rejects missing package custom generic test macro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    var node = Node{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .patch_path = "models/schema.yml",
        .raw_code = "select 1 as amount",
    };
    var column = ColumnDef{ .name = "amount" };
    try column.tests.append(allocator, .{ .name = "util_pkg.positive_amount" });
    try node.columns.append(allocator, column);
    try graph.nodes.append(allocator, node);

    try std.testing.expectError(error.UnresolvedMacro, materializeGenericTests(&graph));
}

fn writeWarnings(stderr: *Io.Writer, graph: *const Graph) !void {
    for (graph.unmatched_model_properties.items) |property| {
        try stderr.print("warning: did not find matching {s} node for property `{s}` in {s}\n", .{ property.resource_type, property.name, util.normalizeForDisplay(property.patch_path) });
    }
    for (graph.unmatched_macro_properties.items) |property| {
        try stderr.print("warning: did not find matching macro for macro property `{s}` in {s}\n", .{ property.name, util.normalizeForDisplay(property.patch_path) });
    }
    for (graph.macro_argument_warnings.items) |warning| {
        try stderr.print("warning: {s}\n", .{warning});
    }
}

fn appendSeedColumnType(allocator: std.mem.Allocator, property: *types.ModelProperty, raw_name: []const u8, raw_type: []const u8) !void {
    const name = try dupTrimmedScalar(allocator, raw_name);
    const data_type = try dupTrimmedScalar(allocator, raw_type);
    if (name.len == 0 or data_type.len == 0) return error.UnsupportedYaml;
    for (property.seed_column_types.items) |*existing| {
        if (std.mem.eql(u8, existing.name, name)) {
            existing.data_type = data_type;
            return;
        }
    }
    try property.seed_column_types.append(allocator, .{ .name = name, .data_type = data_type });
    sortSeedColumnTypes(property.seed_column_types.items);
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

fn sortSeedColumnTypes(column_types: []types.SeedColumnType) void {
    std.mem.sort(types.SeedColumnType, column_types, {}, struct {
        fn lessThan(_: void, a: types.SeedColumnType, b: types.SeedColumnType) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}
