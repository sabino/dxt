const std = @import("std");
const Io = std.Io;
const catalog = @import("project/catalog.zig");
const compiler = @import("project/compiler.zig");
const duckdb = @import("project/duckdb.zig");
const project_fs = @import("project/fs.zig");
const project_jinja = @import("project/jinja.zig");
const project_loader = @import("project/loader.zig");
const project_parse = @import("project/parse.zig");
const project_resolve = @import("project/resolve.zig");
const manifest = @import("project/manifest.zig");
const run_results = @import("project/run_results.zig");
const selector = @import("project/selector.zig");
const source_freshness = @import("project/source_freshness.zig");
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
const SourceDef = types.SourceDef;
const SourceDep = types.SourceDep;
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
const countActiveSeeds = project_resolve.countActiveSeeds;
const findDoc = project_resolve.findDoc;
const findNodeIndexByResourceTypeAndName = project_resolve.findNodeIndexByResourceTypeAndName;
const resolveDependencies = project_resolve.resolveDependencies;
const resolveRefDependency = project_resolve.resolveRefDependency;
const resolveSourceDependency = project_resolve.resolveSourceDependency;

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
    try stdout.print("Parsed {d} model(s), {d} seed(s), {d} source(s), {d} exposure(s), and {d} unit test(s) into {s}\n", .{
        active_models,
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
    const select = if (options.select) |value| try runtime.allocator.dupe(u8, value) else null;
    const exclude = if (options.exclude) |value| try runtime.allocator.dupe(u8, value) else null;
    const resource_type = if (options.resource_type) |value| try runtime.allocator.dupe(u8, value) else null;
    const selected = try selector.selectResources(runtime.allocator, &graph, resource_type, select, exclude);
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

pub fn sourceFreshness(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    try writeWarnings(stderr, &graph);

    const select = if (options.select) |value| try runtime.allocator.dupe(u8, value) else null;
    const exclude = if (options.exclude) |value| try runtime.allocator.dupe(u8, value) else null;
    const selected_sources = try selector.selectResources(runtime.allocator, &graph, "source", select, exclude);
    if (selected_sources.len == 0 and options.select != null) {
        const selected_any = try selector.selectResources(runtime.allocator, &graph, null, select, exclude);
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
                try appendSourceFreshnessRuntimeError(runtime.allocator, &results, source, "source freshness currently requires loaded_at_field or loaded_at_query");
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

    const select = if (options.select) |value| try runtime.allocator.dupe(u8, value) else null;
    const exclude = if (options.exclude) |value| try runtime.allocator.dupe(u8, value) else null;
    const selected_models = try selector.selectResources(runtime.allocator, &graph, "model", select, exclude);
    if (selected_models.len == 0 and options.select != null) {
        const selected_any = try selector.selectResources(runtime.allocator, &graph, null, select, exclude);
        if (selected_any.len != 0) return error.UnsupportedRunSelection;
    }

    const execution_order = try selectedModelExecutionOrder(runtime, &graph, selected_models);
    defer runtime.allocator.free(execution_order);
    if (execution_order.len == 0) return error.UnsupportedRunSelection;
    try validateRunMaterializations(execution_order);

    const target_dir = try targetDir(runtime, options);
    const compile_result = try compileSelectedModels(runtime, &graph, selected_models, target_dir);
    const manifest_path = try writeManifest(runtime, &graph, target_dir);
    if (compile_result.count == 0) return error.UnsupportedRunSelection;
    if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedAdapterExecution;
    const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
    var executed: std.ArrayList(run_results.NodeResult) = .empty;
    defer executed.deinit(runtime.allocator);
    for (execution_order) |node| {
        try duckdb.executeModel(runtime, db_path, &graph, node);
        try executed.append(runtime.allocator, .{ .node = node });
    }

    const run_results_path = try pathJoin(runtime.allocator, &.{ target_dir, "run_results.json" });
    const run_results_json = try run_results.renderRunResults(runtime.allocator, executed.items);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = run_results_path, .data = run_results_json });
    try stdout.print("Ran {d} model(s) into {s}; wrote artifacts into {s}\n", .{
        executed.items.len,
        util.normalizeForDisplay(db_path),
        util.normalizeForDisplay(manifest_path),
    });
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
    const selected_kinds = classifyBuildSelection(selected);
    if (selected_kinds.total == 0) return error.UnsupportedBuildSelection;
    if (selected_kinds.seed == selected_kinds.total) {
        if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedSeedAdapterExecution;
        const seed_nodes = try selectedSeedExecutionOrder(runtime, &graph, selected);
        defer runtime.allocator.free(seed_nodes);
        try validateSeedExecution(&graph, seed_nodes);

        const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
        var executed: std.ArrayList(run_results.NodeResult) = .empty;
        defer executed.deinit(runtime.allocator);
        for (seed_nodes) |node| {
            try duckdb.executeSeed(runtime, db_path, options.project_dir, &graph, node);
            try executed.append(runtime.allocator, .{ .node = node });
        }

        const run_results_path = try pathJoin(runtime.allocator, &.{ target_dir, "run_results.json" });
        const run_results_json = try run_results.renderRunResults(runtime.allocator, executed.items);
        try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = run_results_path, .data = run_results_json });
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

        const test_nodes = try selectedGenericTestExecutionOrder(runtime, &graph, selected);
        defer runtime.allocator.free(test_nodes);
        try validateGenericTestExecution(test_nodes);
        try validateGenericTestsAttachToSelectedNodes(test_nodes, selected);

        const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
        var executed: std.ArrayList(run_results.NodeResult) = .empty;
        defer {
            deinitRunResults(runtime.allocator, executed.items);
            executed.deinit(runtime.allocator);
        }
        for (seed_nodes) |node| {
            try duckdb.executeSeed(runtime, db_path, options.project_dir, &graph, node);
            try executed.append(runtime.allocator, .{ .node = node });
        }
        const test_summary = try appendGenericTestResults(runtime, db_path, &graph, test_nodes, &executed);

        const run_results_path = try pathJoin(runtime.allocator, &.{ target_dir, "run_results.json" });
        const run_results_json = try run_results.renderRunResults(runtime.allocator, executed.items);
        try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = run_results_path, .data = run_results_json });
        try stdout.print("Built {d} seed(s) and {d} generic test(s) into {s}; wrote artifacts into {s}\n", .{
            seed_nodes.len,
            test_nodes.len,
            util.normalizeForDisplay(db_path),
            util.normalizeForDisplay(manifest_path),
        });
        if (test_summary.failed_tests != 0) {
            try stdout.print("{d} generic test(s) failed with {d} failure row(s)\n", .{ test_summary.failed_tests, test_summary.total_failures });
            return error.TestFailure;
        }
        return;
    }
    if (selected_kinds.test_resource == selected_kinds.total) {
        if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedTestExecution;
        const test_nodes = try selectedGenericTestExecutionOrder(runtime, &graph, selected);
        defer runtime.allocator.free(test_nodes);
        try validateGenericTestExecution(test_nodes);

        const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
        var executed: std.ArrayList(run_results.NodeResult) = .empty;
        defer {
            deinitRunResults(runtime.allocator, executed.items);
            executed.deinit(runtime.allocator);
        }
        const test_summary = try appendGenericTestResults(runtime, db_path, &graph, test_nodes, &executed);

        const run_results_path = try pathJoin(runtime.allocator, &.{ target_dir, "run_results.json" });
        const run_results_json = try run_results.renderRunResults(runtime.allocator, executed.items);
        try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = run_results_path, .data = run_results_json });
        try stdout.print("Built {d} generic test(s) against {s}; wrote artifacts into {s}\n", .{
            executed.items.len,
            util.normalizeForDisplay(db_path),
            util.normalizeForDisplay(manifest_path),
        });
        if (test_summary.failed_tests != 0) {
            try stdout.print("{d} generic test(s) failed with {d} failure row(s)\n", .{ test_summary.failed_tests, test_summary.total_failures });
            return error.TestFailure;
        }
        return;
    }
    if (selected_kinds.source != 0 and selected_kinds.test_resource != 0 and selected_kinds.source + selected_kinds.test_resource == selected_kinds.total) {
        if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedTestExecution;
        const test_nodes = try selectedGenericTestExecutionOrder(runtime, &graph, selected);
        defer runtime.allocator.free(test_nodes);
        try validateGenericTestExecution(test_nodes);

        const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
        var executed: std.ArrayList(run_results.NodeResult) = .empty;
        defer {
            deinitRunResults(runtime.allocator, executed.items);
            executed.deinit(runtime.allocator);
        }
        const test_summary = try appendGenericTestResults(runtime, db_path, &graph, test_nodes, &executed);

        const run_results_path = try pathJoin(runtime.allocator, &.{ target_dir, "run_results.json" });
        const run_results_json = try run_results.renderRunResults(runtime.allocator, executed.items);
        try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = run_results_path, .data = run_results_json });
        try stdout.print("Built {d} source generic test(s) against {s}; wrote artifacts into {s}\n", .{
            executed.items.len,
            util.normalizeForDisplay(db_path),
            util.normalizeForDisplay(manifest_path),
        });
        if (test_summary.failed_tests != 0) {
            try stdout.print("{d} generic test(s) failed with {d} failure row(s)\n", .{ test_summary.failed_tests, test_summary.total_failures });
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

        const test_nodes = try selectedGenericTestExecutionOrder(runtime, &graph, selected);
        defer runtime.allocator.free(test_nodes);
        try validateGenericTestExecution(test_nodes);

        const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
        var executed: std.ArrayList(run_results.NodeResult) = .empty;
        defer {
            deinitRunResults(runtime.allocator, executed.items);
            executed.deinit(runtime.allocator);
        }
        for (execution_order) |node| {
            try duckdb.executeModel(runtime, db_path, &graph, node);
            try executed.append(runtime.allocator, .{ .node = node });
        }
        const test_summary = try appendGenericTestResults(runtime, db_path, &graph, test_nodes, &executed);

        const run_results_path = try pathJoin(runtime.allocator, &.{ target_dir, "run_results.json" });
        const run_results_json = try run_results.renderRunResults(runtime.allocator, executed.items);
        try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = run_results_path, .data = run_results_json });
        try stdout.print("Built {d} model(s) and {d} generic test(s) into {s}; wrote artifacts into {s}\n", .{
            execution_order.len,
            test_nodes.len,
            util.normalizeForDisplay(db_path),
            util.normalizeForDisplay(manifest_path),
        });
        if (test_summary.failed_tests != 0) {
            try stdout.print("{d} generic test(s) failed with {d} failure row(s)\n", .{ test_summary.failed_tests, test_summary.total_failures });
            return error.TestFailure;
        }
        return;
    }
    if (selected_kinds.seed != 0 and selected_kinds.model != 0 and selected_kinds.seed + selected_kinds.model + selected_kinds.test_resource == selected_kinds.total) {
        if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedBuildAdapterExecution;
        const execution_order = try selectedSeedModelExecutionOrder(runtime, &graph, selected);
        defer runtime.allocator.free(execution_order);
        try validateSeedModelBuildExecution(&graph, execution_order);

        const test_nodes = try selectedGenericTestExecutionOrder(runtime, &graph, selected);
        defer runtime.allocator.free(test_nodes);
        try validateGenericTestExecution(test_nodes);
        try validateGenericTestsAttachToSelectedNodes(test_nodes, selected);

        const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
        var executed: std.ArrayList(run_results.NodeResult) = .empty;
        defer {
            deinitRunResults(runtime.allocator, executed.items);
            executed.deinit(runtime.allocator);
        }
        var seed_count: usize = 0;
        var model_count: usize = 0;
        for (execution_order) |node| {
            if (std.mem.eql(u8, node.resource_type, "seed")) {
                try duckdb.executeSeed(runtime, db_path, options.project_dir, &graph, node);
                seed_count += 1;
            } else {
                try duckdb.executeModel(runtime, db_path, &graph, node);
                model_count += 1;
            }
            try executed.append(runtime.allocator, .{ .node = node });
        }
        const test_summary = try appendGenericTestResults(runtime, db_path, &graph, test_nodes, &executed);

        const run_results_path = try pathJoin(runtime.allocator, &.{ target_dir, "run_results.json" });
        const run_results_json = try run_results.renderRunResults(runtime.allocator, executed.items);
        try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = run_results_path, .data = run_results_json });
        try stdout.print("Built {d} seed(s), {d} model(s), and {d} generic test(s) into {s}; wrote artifacts into {s}\n", .{
            seed_count,
            model_count,
            test_nodes.len,
            util.normalizeForDisplay(db_path),
            util.normalizeForDisplay(manifest_path),
        });
        if (test_summary.failed_tests != 0) {
            try stdout.print("{d} generic test(s) failed with {d} failure row(s)\n", .{ test_summary.failed_tests, test_summary.total_failures });
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

const CompileResult = struct {
    count: usize,
    saw_model: bool,
    compiled_base: []const u8,
};

const BuildSelectionKinds = struct {
    total: usize = 0,
    seed: usize = 0,
    model: usize = 0,
    source: usize = 0,
    test_resource: usize = 0,
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
        remaining[index] = node.enabled and std.mem.eql(u8, node.resource_type, "model") and selectionContains(selected, node.unique_id);
    }

    var ordered: std.ArrayList(*Node) = .empty;
    errdefer ordered.deinit(runtime.allocator);
    while (ordered.items.len < selected_count) {
        var progressed = false;
        for (graph.nodes.items, 0..) |*node, index| {
            if (!remaining[index]) continue;
            if (!selectedModelDependenciesExecuted(selected, ordered.items, node)) continue;
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
            (std.mem.eql(u8, node.resource_type, "seed") or std.mem.eql(u8, node.resource_type, "model")) and
            selectionContains(selected, node.unique_id);
    }

    var ordered: std.ArrayList(*Node) = .empty;
    errdefer ordered.deinit(runtime.allocator);
    while (ordered.items.len < selected_count) {
        var progressed = false;
        for (graph.nodes.items, 0..) |*node, index| {
            if (!remaining[index]) continue;
            if (!selectedSeedModelDependenciesExecuted(selected, ordered.items, node)) continue;
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
    for (nodes) |node| {
        if (!std.mem.eql(u8, node.package_name, graph.project_name)) return error.UnsupportedSeedExecution;
        if (!std.mem.eql(u8, node.materialized, "seed")) return error.UnsupportedSeedExecution;
    }
}

fn validateSeedModelBuildExecution(graph: *const Graph, nodes: []const *Node) !void {
    for (nodes) |node| {
        if (std.mem.eql(u8, node.resource_type, "seed")) {
            if (!std.mem.eql(u8, node.package_name, graph.project_name)) return error.UnsupportedSeedExecution;
            if (!std.mem.eql(u8, node.materialized, "seed")) return error.UnsupportedSeedExecution;
        } else if (std.mem.eql(u8, node.resource_type, "model")) {
            if (!duckdb.isSupportedMaterialization(node.materialized)) return error.UnsupportedBuildModelMaterialization;
        } else {
            return error.UnsupportedBuildSelection;
        }
    }
}

fn selectedGenericTestExecutionOrder(runtime: Runtime, graph: *Graph, selected: []const selector.SelectedResource) ![]*GenericTestNode {
    const selected_count = countSelectedGenericTests(graph, selected);
    var ordered = try runtime.allocator.alloc(*GenericTestNode, selected_count);
    var index: usize = 0;
    for (graph.tests.items) |*test_node| {
        if (!selectionContains(selected, test_node.unique_id)) continue;
        ordered[index] = test_node;
        index += 1;
    }
    return ordered;
}

fn validateGenericTestExecution(nodes: []const *GenericTestNode) !void {
    for (nodes) |test_node| {
        if (genericTestNodeColumnName(test_node) == null) return error.UnsupportedTestExecution;
        if (std.mem.eql(u8, test_node.test_name, "accepted_values")) {
            if (test_node.accepted_values.items.len == 0) return error.UnsupportedTestExecution;
            continue;
        }
        if (std.mem.eql(u8, test_node.test_name, "relationships")) {
            if (test_node.relationship_to.len == 0 or test_node.relationship_field.len == 0) return error.UnsupportedTestExecution;
            continue;
        }
        if (!std.mem.eql(u8, test_node.test_name, "not_null") and !std.mem.eql(u8, test_node.test_name, "unique")) {
            return error.UnsupportedTestExecution;
        }
    }
}

fn validateGenericTestsAttachToSelectedNodes(nodes: []const *GenericTestNode, selected: []const selector.SelectedResource) !void {
    for (nodes) |test_node| {
        const attached_node = test_node.attached_node orelse return error.UnsupportedTestExecution;
        if (!selectionContains(selected, attached_node)) return error.UnsupportedTestExecution;
    }
}

const GenericTestExecutionSummary = struct {
    failed_tests: usize = 0,
    total_failures: u64 = 0,
};

fn appendGenericTestResults(runtime: Runtime, db_path: []const u8, graph: *const Graph, test_nodes: []const *GenericTestNode, executed: *std.ArrayList(run_results.NodeResult)) !GenericTestExecutionSummary {
    var summary: GenericTestExecutionSummary = .{};
    for (test_nodes) |test_node| {
        const execution = try duckdb.executeGenericTest(runtime, db_path, graph, test_node);
        const failed = execution.failures != 0;
        if (failed) {
            summary.failed_tests += 1;
            summary.total_failures += execution.failures;
        }
        const message = if (failed) try formatTestFailureMessage(runtime.allocator, execution.failures) else null;
        try executed.append(runtime.allocator, .{
            .test_node = test_node,
            .status = if (failed) "fail" else "pass",
            .message = message,
            .failures = execution.failures,
            .compiled_code = execution.compiled_code,
            .owns_compiled_code = true,
        });
    }
    return summary;
}

fn deinitRunResults(allocator: std.mem.Allocator, results: []const run_results.NodeResult) void {
    for (results) |result| {
        if (result.owns_compiled_code) {
            if (result.compiled_code) |compiled_code| allocator.free(compiled_code);
        }
        if (result.message) |message| allocator.free(message);
    }
}

fn countSelectedGraphModels(graph: *const Graph, selected: []const selector.SelectedResource) usize {
    var count: usize = 0;
    for (graph.nodes.items) |node| {
        if (!node.enabled or !std.mem.eql(u8, node.resource_type, "model")) continue;
        if (selectionContains(selected, node.unique_id)) count += 1;
    }
    return count;
}

fn countSelectedGraphSeeds(graph: *const Graph, selected: []const selector.SelectedResource) usize {
    var count: usize = 0;
    for (graph.nodes.items) |node| {
        if (!node.enabled or !std.mem.eql(u8, node.resource_type, "seed")) continue;
        if (selectionContains(selected, node.unique_id)) count += 1;
    }
    return count;
}

fn countSelectedGenericTests(graph: *const Graph, selected: []const selector.SelectedResource) usize {
    var count: usize = 0;
    for (graph.tests.items) |test_node| {
        if (selectionContains(selected, test_node.unique_id)) count += 1;
    }
    return count;
}

fn selectedModelDependenciesExecuted(selected: []const selector.SelectedResource, executed: []const *Node, node: *const Node) bool {
    for (node.depends_on.items) |dependency| {
        if (!std.mem.startsWith(u8, dependency, "model.")) continue;
        if (!selectionContains(selected, dependency)) continue;
        if (!executedContains(executed, dependency)) return false;
    }
    return true;
}

fn selectedSeedModelDependenciesExecuted(selected: []const selector.SelectedResource, executed: []const *Node, node: *const Node) bool {
    for (node.depends_on.items) |dependency| {
        if (!std.mem.startsWith(u8, dependency, "model.") and !std.mem.startsWith(u8, dependency, "seed.")) continue;
        if (!selectionContains(selected, dependency)) continue;
        if (!executedContains(executed, dependency)) return false;
    }
    return true;
}

fn executedContains(executed: []const *Node, unique_id: []const u8) bool {
    for (executed) |node| {
        if (std.mem.eql(u8, node.unique_id, unique_id)) return true;
    }
    return false;
}

fn formatTestFailureMessage(allocator: std.mem.Allocator, failures: u64) ![]const u8 {
    return try std.fmt.allocPrint(
        allocator,
        "Got {d} {s}, configured to fail if != 0",
        .{ failures, if (failures == 1) "result" else "results" },
    );
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
        node.relation_name = try compiler.relationNameForNode(runtime.allocator, graph, node);
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
    var active_resource_type: []const u8 = "model";
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

        if (std.mem.eql(u8, trimmed, "models:") or std.mem.eql(u8, trimmed, "seeds:")) {
            in_models = true;
            in_columns = false;
            in_config = false;
            active_resource_type = if (std.mem.eql(u8, trimmed, "seeds:")) "seed" else "model";
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
        if (indent <= models_indent and !std.mem.eql(u8, trimmed, "models:") and !std.mem.eql(u8, trimmed, "seeds:")) {
            in_models = false;
            in_columns = false;
            in_config = false;
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
                    try graph.model_properties.append(allocator, .{ .package_name = package_name, .resource_type = active_resource_type, .name = name, .patch_path = relative_path });
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
        const node_index = findNodeIndexByResourceTypeAndName(graph, property.package_name, property.resource_type, property.name) orelse {
            try graph.unmatched_model_properties.append(graph.allocator, .{ .resource_type = property.resource_type, .name = property.name, .patch_path = property.patch_path });
            continue;
        };
        var node = &graph.nodes.items[node_index];
        node.patch_path = property.patch_path;
        if (property.description.len != 0) node.description = try resolveDocDescription(graph, property.package_name, property.description, &node.doc_blocks);
        if (std.mem.eql(u8, node.resource_type, "model") and property.materialized.len != 0 and !node.inline_materialized) node.materialized = property.materialized;
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
        .argument_column_name = effective_column_name,
        .accepted_values_quote = test_def.accepted_values_quote,
        .relationship_to = test_def.relationship_to,
        .relationship_field = test_def.relationship_field,
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
    try test_node.macro_depends_on.append(graph.allocator, try std.fmt.allocPrint(graph.allocator, "macro.dbt.test_{s}", .{test_def.name}));
    if (!std.mem.eql(u8, test_def.name, "not_null") and !std.mem.eql(u8, test_def.name, "unique")) {
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
        .column_name = test_def.column_name,
        .accepted_values = test_def.accepted_values,
        .accepted_values_quote = test_def.accepted_values_quote,
        .relationship_to = test_def.relationship_to,
        .relationship_field = test_def.relationship_field,
    };
    const names = try synthesizeGenericTestNames(graph.allocator, source_test_def, source_target_name, effective_column_name);
    const unique_id = try genericTestUniqueIdForModelKwarg(graph.allocator, source.package_name, names.full, test_def, source_model_kwarg, effective_column_name);
    for (graph.tests.items) |existing| {
        if (std.mem.eql(u8, existing.unique_id, unique_id)) return;
    }

    const raw_code = if (std.mem.eql(u8, names.compiled, names.full))
        try std.fmt.allocPrint(graph.allocator, "{{{{ test_{s}(**_dbt_generic_test_kwargs) }}}}", .{test_def.name})
    else
        try std.fmt.allocPrint(graph.allocator, "{{{{ test_{s}(**_dbt_generic_test_kwargs) }}}}{{{{ config(alias=\"{s}\") }}}}", .{ test_def.name, names.compiled });
    var test_node = GenericTestNode{
        .package_name = source.package_name,
        .unique_id = unique_id,
        .name = names.full,
        .alias = names.compiled,
        .path = try std.fmt.allocPrint(graph.allocator, "{s}.sql", .{names.compiled}),
        .original_file_path = source.original_file_path,
        .raw_code = raw_code,
        .test_name = test_def.name,
        .column_name = column_name,
        .argument_column_name = effective_column_name,
        .accepted_values_quote = test_def.accepted_values_quote,
        .relationship_to = test_def.relationship_to,
        .relationship_field = test_def.relationship_field,
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
    try test_node.macro_depends_on.append(graph.allocator, try std.fmt.allocPrint(graph.allocator, "macro.dbt.test_{s}", .{test_def.name}));
    if (!std.mem.eql(u8, test_def.name, "not_null") and !std.mem.eql(u8, test_def.name, "unique")) {
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
