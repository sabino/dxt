const std = @import("std");
const Io = std.Io;
const catalog = @import("project/catalog.zig");
const commands = @import("project/commands.zig");
const clean = @import("project/clean.zig");
const compiler = @import("project/compiler.zig");
const docs_serve = @import("project/docs_serve.zig");
const duckdb = @import("project/duckdb.zig");
const incremental = @import("project/incremental.zig");
const incremental_config = @import("project/incremental_config.zig");
const microbatch = @import("project/microbatch.zig");
const microbatch_run = @import("project/microbatch_run.zig");
const project_fs = @import("project/fs.zig");
const project_jinja = @import("project/jinja.zig");
const project_loader = @import("project/loader.zig");
const project_snapshot = @import("project/snapshot.zig");
const snapshot_yaml = @import("project/snapshot_yaml.zig");
const snapshot_runner = @import("project/snapshot_runner.zig");
const project_parse = @import("project/parse.zig");
const project_resolve = @import("project/resolve.zig");
const selector_config = @import("project/selector_config.zig");
const manifest = @import("project/manifest.zig");
const run_results = @import("project/run_results.zig");
const selector = @import("project/selector.zig");
const scheduler = @import("project/scheduler.zig");
const concurrent_runner = @import("project/concurrent_runner.zig");
const execution_clock = @import("project/execution_clock.zig");
const source_freshness = @import("project/source_freshness.zig");
const state_artifacts = @import("project/state.zig");
const project_defer = @import("project/defer.zig");
const types = @import("project/types.zig");
const workflow_engine = @import("project/workflow.zig");
const cli_options = @import("project/cli_options.zig");
const util = @import("project/util.zig");

const execution_failure_message = "DuckDB execution failed";

pub const Runtime = types.Runtime;
pub const Options = types.Options;
pub const Output = types.Output;
pub const debug = commands.debug;
pub const initProject = commands.initProject;
pub const validateSelectorSyntax = selector.validateSelectorSyntax;
pub const WorkflowOptions = workflow_engine.Options;

pub fn workflow(runtime: Runtime, command: []const u8, options: Options, workflow_options: WorkflowOptions, stdout: *Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(runtime.allocator);
    defer arena.deinit();
    var scoped = runtime;
    scoped.allocator = arena.allocator();
    var workflow_common = options;
    var workflow_vars: std.json.Value = .{ .object = .empty };
    if (options.vars) |raw| {
        var document = try @import("project/yaml.zig").parse(scoped.allocator, raw);
        defer document.deinit();
        if (document.value != .object) return error.InvalidVarsYaml;
        workflow_vars = try @import("project/config_value.zig").clone(scoped.allocator, document.value);
    }
    for ([_][]const u8{ "dxt_start", "dxt_end" }, [_][]const u8{ "__DXT_INTERVAL_START__", "__DXT_INTERVAL_END__" }) |name, marker| {
        if (workflow_vars.object.contains(name)) return error.WorkflowReservedVariable;
        try workflow_vars.object.put(scoped.allocator, name, .{ .string = marker });
    }
    workflow_common.vars = try std.json.Stringify.valueAlloc(scoped.allocator, workflow_vars, .{});
    var graph = try project_loader.loadGraph(scoped, workflow_common, loader_callbacks);
    defer graph.deinit();
    try resolveDependencies(&graph);
    workflow_engine.execute(scoped, &graph, workflow_common, workflow_options, try targetDir(scoped, options), command, stdout) catch |err| switch (err) {
        error.DuckDbExecutionFailed, error.PostgresExecutionFailed => return error.WorkflowExecutionFailure,
        else => return err,
    };
}

pub fn runOperation(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();
    try resolveDependencies(&graph);
    try writeWarnings(runtime, stderr, &graph);
    const target_dir = try targetDir(runtime, options);
    _ = try writeManifest(runtime, &graph, target_dir);
    try commands.operation(runtime, options, &graph, target_dir, stdout);
}

pub fn clone(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    if (options.state == null) return error.MissingCloneState;
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();
    try resolveDependencies(&graph);
    try writeWarnings(runtime, stderr, &graph);
    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var state = try loadSelectionState(runtime, options, selection, &graph);
    defer state.deinit(runtime.allocator);
    const selected = try selector.selectResourcesWithContext(runtime.allocator, &graph, null, selection.select, selection.exclude, state.context());
    const target_dir = try targetDir(runtime, options);
    commands.cloneRelations(runtime, options, &graph, selected, target_dir, stdout) catch |err| {
        if (err == error.ExecutionFailure) _ = try writeManifest(runtime, &graph, target_dir);
        return err;
    };
    _ = try writeManifest(runtime, &graph, target_dir);
}

pub fn retry(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    const target_dir = try targetDir(runtime, options);
    var plan = try commands.prepareRetry(runtime, options, target_dir);
    const supported = std.mem.eql(u8, plan.options.which, "run") or std.mem.eql(u8, plan.options.which, "seed") or std.mem.eql(u8, plan.options.which, "test") or std.mem.eql(u8, plan.options.which, "build") or std.mem.eql(u8, plan.options.which, "clone") or std.mem.eql(u8, plan.options.which, "run-operation") or std.mem.eql(u8, plan.options.which, "snapshot") or std.mem.eql(u8, plan.options.which, "compile") or std.mem.eql(u8, plan.options.which, "generate");
    if (!supported) return error.UnsupportedRetryCommand;
    var invocation = runtime;
    invocation.invocation_options = &plan.options;
    if (plan.count == 0) {
        try commands.writeResults(invocation, target_dir, &.{});
        try stdout.writeAll("Nothing to retry\n");
        return;
    }
    if (std.mem.eql(u8, plan.options.which, "run")) return runPreflight(invocation, plan.options, stdout, stderr);
    if (std.mem.eql(u8, plan.options.which, "seed")) return seedPreflight(invocation, plan.options, stdout, stderr);
    if (std.mem.eql(u8, plan.options.which, "test")) return testPreflight(invocation, plan.options, stdout, stderr);
    if (std.mem.eql(u8, plan.options.which, "build")) return buildPreflight(invocation, plan.options, stdout, stderr);
    if (std.mem.eql(u8, plan.options.which, "snapshot")) return snapshotRun(invocation, plan.options, stdout, stderr);
    if (std.mem.eql(u8, plan.options.which, "clone")) return clone(invocation, plan.options, stdout, stderr);
    if (std.mem.eql(u8, plan.options.which, "compile")) return compile(invocation, plan.options, stdout, stderr);
    if (std.mem.eql(u8, plan.options.which, "generate")) return docsGenerate(invocation, plan.options, stdout, stderr);
    return runOperation(invocation, plan.options, stdout, stderr);
}

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

pub fn metricQuery(runtime: Runtime, options: Options, query: @import("project/metric_plan.zig").Query, stdout: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();
    try resolveDependencies(&graph);
    try @import("project/metric_command.zig").execute(runtime, &graph, options, query, stdout);
}

pub fn parse(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    if (options.selector != null) {
        var selection = try resolveSelection(runtime, options);
        defer selection.deinit(runtime.allocator);
    }
    try writeWarnings(runtime, stderr, &graph);
    const active_models = countActiveNodes(&graph);
    const active_analyses = countActiveAnalyses(&graph);
    const active_seeds = countActiveSeeds(&graph);
    var active_snapshots: usize = 0;
    for (graph.nodes.items) |node| {
        if (node.enabled and std.mem.eql(u8, node.resource_type, "snapshot")) active_snapshots += 1;
    }

    const target_path = options.target_path orelse project_loader.graphDefaultTarget(runtime, options.project_dir) catch "target";
    const target_dir = if (std.fs.path.isAbsolute(target_path))
        target_path
    else
        try pathJoin(runtime.allocator, &.{ options.project_dir, target_path });
    try std.Io.Dir.cwd().createDirPath(runtime.io, target_dir);
    const manifest_path = try writeManifest(runtime, &graph, target_dir);
    try stdout.print("Parsed {d} model(s), {d} analysis(es), {d} snapshot(s), {d} seed(s), {d} source(s), {d} exposure(s), and {d} unit test(s) into {s}\n", .{
        active_models,
        active_analyses,
        active_snapshots,
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
    var selection_state = try loadSelectionState(runtime, options, selection, &graph);
    defer selection_state.deinit(runtime.allocator);
    const resource_type = if (options.resource_type) |value| try runtime.allocator.dupe(u8, value) else null;
    const candidates = try selector.selectResourcesWithContext(runtime.allocator, &graph, resource_type, selection.select, selection.exclude, selection_state.context());
    var listed: std.ArrayList(selector.SelectedResource) = .empty;
    defer listed.deinit(runtime.allocator);
    for (candidates) |item| if (cli_options.resourceIncluded(options, item.resource_type)) try listed.append(runtime.allocator, item);
    const selected = listed.items;
    if (selected.len == 0 and try cli_options.warningIsError(runtime, "NoNodesSelected")) return error.NoNodesSelected;
    _ = try writeManifest(runtime, &graph, try targetDir(runtime, options));
    switch (options.output) {
        .json => try manifest.writeSelectedJsonLines(runtime.allocator, stdout, &graph, selected, options.output_keys),
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

pub fn show(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    return sqlOperation(runtime, options, stdout, stderr);
}

fn sqlOperation(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    const operations = @import("project/sql_operations.zig");
    var graph = if (options.inline_direct != null) try project_loader.loadConnectionGraph(runtime, options) else try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();
    if (options.inline_direct != null) return operations.showDirect(runtime, options, &graph, stdout);
    try resolveDependencies(&graph);
    try writeWarnings(runtime, stderr, &graph);
    const target_dir = try targetDir(runtime, options);
    _ = try writeManifest(runtime, &graph, target_dir);
    if (std.mem.eql(u8, options.which, "show") and options.select == null and (options.inline_sql == null or options.inline_sql.?.len == 0)) return error.MissingShowSelection;
    const original_nodes = graph.nodes.items.len;
    if (options.inline_sql) |sql| {
        operations.appendInline(runtime, &graph, sql) catch |err| {
            try stderr.print("error: Error parsing inline query: {s}\n", .{@errorName(err)});
            return error.InlineParseFailure;
        };
        resolveDependencies(&graph) catch |err| {
            try stderr.print("error: Error parsing inline query: {s}\n", .{@errorName(err)});
            return error.InlineParseFailure;
        };
    }
    defer if (graph.nodes.items.len > original_nodes) {
        types.deinitNode(runtime.allocator, &graph.nodes.items[original_nodes]);
        graph.nodes.shrinkRetainingCapacity(original_nodes);
    };
    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var selection_state = try loadSelectionState(runtime, options, selection, &graph);
    defer selection_state.deinit(runtime.allocator);
    try @import("project/selection_warnings.zig").check(runtime, &graph, selection.select, selection.exclude, selection_state.context(), stderr);
    const selected = if (options.inline_sql != null) try selector.selectExecutionResourcesWithContext(runtime.allocator, &graph, "sql_operation", selection.select, selection.exclude, selection_state.context()) else try commandSelection(runtime.allocator, try selector.selectExecutionResourcesWithContext(runtime.allocator, &graph, null, selection.select, selection.exclude, selection_state.context()), .compile);
    if (selected.len == 0) return finishEmptySelection(runtime, target_dir, stderr);
    try project_defer.apply(runtime, &graph, options, selected, target_dir);
    var rows: std.ArrayList(run_results.NodeResult) = .empty;
    defer {
        deinitRunResults(runtime.allocator, rows.items);
        rows.deinit(runtime.allocator);
    }
    _ = compileWithHost(runtime, options, &graph, selected, target_dir, &rows, stderr) catch |err| {
        if (err == error.OutOfMemory) return err;
        try reportCompilationFailure(runtime, rows.items, err, stderr);
        return error.SqlOperationFailure;
    };
    try writeRunResults(runtime, target_dir, rows.items);
    try operations.emit(runtime, options, rows.items, stdout);
    if (graph.nodes.items.len > original_nodes) {
        types.deinitNode(runtime.allocator, &graph.nodes.items[original_nodes]);
        graph.nodes.shrinkRetainingCapacity(original_nodes);
    }
    _ = try writeManifest(runtime, &graph, target_dir);
}

pub fn compile(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    if (options.inline_sql != null and options.inline_sql.?.len != 0) return sqlOperation(runtime, options, stdout, stderr);
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    try writeWarnings(runtime, stderr, &graph);

    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var selection_state = try loadSelectionState(runtime, options, selection, &graph);
    defer selection_state.deinit(runtime.allocator);
    const target_dir = try targetDir(runtime, options);
    _ = try writeManifest(runtime, &graph, target_dir);
    try @import("project/selection_warnings.zig").check(runtime, &graph, selection.select, selection.exclude, selection_state.context(), stderr);
    const candidates = try selector.selectExecutionResourcesWithContext(runtime.allocator, &graph, null, selection.select, selection.exclude, selection_state.context());
    const selected = try commandSelection(runtime.allocator, candidates, .compile);
    if (selected.len == 0) return finishEmptySelection(runtime, target_dir, stderr);

    try project_defer.apply(runtime, &graph, options, selected, target_dir);
    var compile_rows: std.ArrayList(run_results.NodeResult) = .empty;
    defer {
        deinitRunResults(runtime.allocator, compile_rows.items);
        compile_rows.deinit(runtime.allocator);
    }
    const compile_result = compileWithHost(runtime, options, &graph, selected, target_dir, &compile_rows, stderr) catch |err| {
        if (err == error.OutOfMemory) return err;
        try reportCompilationFailure(runtime, compile_rows.items, err, stderr);
        return error.SqlOperationFailure;
    };

    _ = try writeManifest(runtime, &graph, target_dir);
    try writeRunResults(runtime, target_dir, compile_rows.items);
    try @import("project/sql_operations.zig").emit(runtime, options, compile_rows.items, stdout);
    if (compile_result.snapshot_count != 0) {
        try stdout.print("Compiled {d} model(s), {d} snapshot(s), {d} analysis(es), and {d} test(s) into {s}\n", .{
            compile_result.count, compile_result.snapshot_count, compile_result.analysis_count, compile_result.test_count, util.normalizeForDisplay(compile_result.compiled_base),
        });
    } else if (compile_result.analysis_count == 0) {
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

pub fn analyze(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();
    try resolveDependencies(&graph);
    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var selection_state = try loadSelectionState(runtime, options, selection, &graph);
    defer selection_state.deinit(runtime.allocator);
    const candidates = try selector.selectResourcesWithContext(runtime.allocator, &graph, options.resource_type, selection.select, selection.exclude, selection_state.context());
    var included: std.ArrayList(selector.SelectedResource) = .empty;
    defer included.deinit(runtime.allocator);
    for (candidates) |item| if (cli_options.resourceIncluded(options, item.resource_type)) try included.append(runtime.allocator, item);
    const selected = included.items;
    const target_dir = try targetDir(runtime, options);
    try project_defer.apply(runtime, &graph, options, selected, target_dir);
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(runtime.allocator);
    for (graph.nodes.items) |node| {
        if (!node.enabled or (!std.mem.eql(u8, node.resource_type, "model") and !std.mem.eql(u8, node.resource_type, "analysis") and !std.mem.eql(u8, node.resource_type, "snapshot") and !std.mem.eql(u8, node.resource_type, "seed"))) continue;
        for (selected) |item| if (std.mem.eql(u8, item.unique_id, node.unique_id)) {
            try ids.append(runtime.allocator, node.unique_id);
            break;
        };
    }
    for (selected) |item| if (std.mem.startsWith(u8, item.unique_id, "test.")) try ids.append(runtime.allocator, item.unique_id);
    try @import("project/sql_analysis.zig").run(runtime, &graph, ids.items, target_dir, stdout, stderr, options.output == .json or std.mem.eql(u8, options.which, "explain"));
}

pub fn docsGenerate(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    try writeWarnings(runtime, stderr, &graph);

    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var selection_state = try loadSelectionState(runtime, options, selection, &graph);
    defer selection_state.deinit(runtime.allocator);
    const selected = try selector.selectExecutionResourcesWithContext(runtime.allocator, &graph, null, selection.select, selection.exclude, selection_state.context());

    const target_dir = try targetDir(runtime, options);
    try project_defer.apply(runtime, &graph, options, selected, target_dir);
    var compile_rows: std.ArrayList(run_results.NodeResult) = .empty;
    defer {
        deinitRunResults(runtime.allocator, compile_rows.items);
        compile_rows.deinit(runtime.allocator);
    }
    const compile_result = if (options.docs_compile) compileWithHost(runtime, options, &graph, selected, target_dir, &compile_rows, stderr) catch |err| {
        if (err == error.OutOfMemory) return err;
        try reportCompilationFailure(runtime, compile_rows.items, err, stderr);
        return error.SqlOperationFailure;
    } else CompileResult{ .count = 0, .saw_model = false, .compiled_base = "" };

    _ = try writeManifestWithPolicy(runtime, &graph, target_dir, cli_options.writeJson(runtime) or options.docs_compile);
    if (options.docs_compile) try writeRunResults(runtime, target_dir, compile_rows.items);

    var catalog_entries: catalog.CatalogEntries = .{};
    defer catalog.deinitCatalogEntries(runtime.allocator, &catalog_entries);
    if (!options.docs_empty_catalog) if (duckdb.databasePath(runtime.allocator, target_dir, &graph)) |db_path| {
        defer runtime.allocator.free(db_path);
        catalog_entries = if (std.mem.eql(u8, graph.adapter_type, "postgres"))
            try @import("project/postgres_catalog.zig").collect(runtime, db_path, &graph, selected, stdout)
        else
            try duckdb.collectCatalogEntries(runtime, db_path, &graph, selected);
    } else |err| switch (err) {
        error.UnsupportedDuckDbPath => {},
        else => return err,
    };

    const catalog_path = try pathJoin(runtime.allocator, &.{ target_dir, "catalog.json" });
    try std.Io.Dir.cwd().createDirPath(runtime.io, target_dir);
    const catalog_json = try catalog.renderCatalogWithInvocation(runtime.allocator, catalog_entries.nodes.items, catalog_entries.sources.items, runtime.invocation);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = catalog_path, .data = catalog_json });
    try docs_serve.writeIndex(runtime, target_dir, options.docs_static);

    try stdout.print("Generated docs artifacts for {d} compiled model(s) into {s}\n", .{
        compile_result.count,
        util.normalizeForDisplay(target_dir),
    });
}

fn reportCompilationFailure(runtime: Runtime, rows: []const run_results.NodeResult, err: anyerror, stderr: *Io.Writer) !void {
    var reported = false;
    for (rows) |row| if (std.mem.eql(u8, row.status, "error")) if (row.message) |message| {
        try @import("project/sql_operations.zig").emitError(runtime, message, stderr);
        reported = true;
    };
    if (!reported) try @import("project/sql_operations.zig").emitError(runtime, @errorName(err), stderr);
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
    try writeWarnings(runtime, stderr, &graph);

    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var selection_state = try loadSelectionState(runtime, options, selection, &graph);
    defer selection_state.deinit(runtime.allocator);
    const selection_context = selection_state.context();
    const selected_sources = try selector.selectExecutionResourcesWithContext(runtime.allocator, &graph, "source", selection.select, selection.exclude, selection_context);
    if (selected_sources.len == 0 and selection.select != null) {
        const selected_any = try selector.selectExecutionResourcesWithContext(runtime.allocator, &graph, null, selection.select, selection.exclude, selection_context);
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
        if (!std.mem.eql(u8, graph.adapter_type, "duckdb") and !std.mem.eql(u8, graph.adapter_type, "postgres")) return error.UnsupportedSourceFreshnessAdapter;
        const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
        defer runtime.allocator.free(db_path);

        if (try concurrent_runner.requested(runtime, options, &graph)) {
            var candidates: std.ArrayList(*const SourceDef) = .empty;
            defer candidates.deinit(runtime.allocator);
            for (graph.sources.items) |*source| if (source.enabled and selectionContains(selected_sources, source.unique_id) and source_freshness.isRunnableSource(source)) {
                try candidates.append(runtime.allocator, source);
            };
            had_failure = try @import("project/freshness_runner.zig").run(runtime, &graph, options, candidates.items, db_path, &results, stderr);
        } else {
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
                const started = execution_clock.now(runtime.io);
                const monotonic = std.Io.Timestamp.now(runtime.io, .awake);
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
                    .execution_started_at = started,
                    .execution_completed_at = execution_clock.now(runtime.io),
                    .execution_time = @as(f64, @floatFromInt(monotonic.durationTo(std.Io.Timestamp.now(runtime.io, .awake)).nanoseconds)) / std.time.ns_per_s,
                }) catch |err| {
                    duckdb.deinitFreshnessQueryResult(runtime.allocator, query_result);
                    return err;
                };
            }
        }
    }

    const sources_path = try pathJoin(runtime.allocator, &.{ target_dir, "sources.json" });
    const sources_json = try source_freshness.renderSourcesWithInvocation(runtime.allocator, results.items, runtime.invocation);
    if (cli_options.writeJson(runtime)) try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = sources_path, .data = sources_json });
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
    try writeWarnings(runtime, stderr, &graph);

    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var selection_state = try loadSelectionState(runtime, options, selection, &graph);
    defer selection_state.deinit(runtime.allocator);
    const target_dir = try targetDir(runtime, options);
    _ = try writeManifest(runtime, &graph, target_dir);
    try @import("project/selection_warnings.zig").check(runtime, &graph, selection.select, selection.exclude, selection_state.context(), stderr);
    const selection_context = selection_state.context();
    const selected_models = try selector.selectExecutionResourcesWithContext(runtime.allocator, &graph, "model", selection.select, selection.exclude, selection_context);
    if (selected_models.len == 0) return finishEmptySelection(runtime, target_dir, stderr);

    const execution_order = try selectedModelExecutionOrder(runtime, &graph, selected_models);
    defer runtime.allocator.free(execution_order);
    try validateRunMaterializations(&graph, execution_order);

    try project_defer.apply(runtime, &graph, options, selected_models, target_dir);
    if (execution_order.len == 0) return executeEphemeralSelection(runtime, options, &graph, selected_models, target_dir, stdout, stderr);
    if (try concurrent_runner.requested(runtime, options, &graph)) {
        const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
        defer runtime.allocator.free(db_path);
        const manifest_path = try writeManifest(runtime, &graph, target_dir);
        return executeConcurrentCommand(runtime, options, &graph, selected_models, target_dir, manifest_path, db_path, stdout, stderr, "Run");
    }
    _ = try compileSelectedModels(runtime, &graph, selected_models, target_dir, false, false);
    const manifest_path = try writeManifest(runtime, &graph, target_dir);
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
        if (try appendSkippedIfNodeDependsOnBlocked(runtime.allocator, &graph, &blocked, node, &executed)) {
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

pub fn snapshotRun(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();
    try resolveDependencies(&graph);
    try writeWarnings(runtime, stderr, &graph);
    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var selection_state = try loadSelectionState(runtime, options, selection, &graph);
    defer selection_state.deinit(runtime.allocator);
    const target_dir = try targetDir(runtime, options);
    _ = try writeManifest(runtime, &graph, target_dir);
    try @import("project/selection_warnings.zig").check(runtime, &graph, selection.select, selection.exclude, selection_state.context(), stderr);
    const selected = try selector.selectExecutionResourcesWithContext(runtime.allocator, &graph, "snapshot", selection.select, selection.exclude, selection_state.context());
    if (selected.len == 0) return finishEmptySelection(runtime, target_dir, stderr);
    const ordered = try selectedModelExecutionOrder(runtime, &graph, selected);
    defer runtime.allocator.free(ordered);
    for (ordered) |node| try snapshot_runner.validateExecution(&graph, node);
    if (try concurrent_runner.requested(runtime, options, &graph)) {
        const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
        defer runtime.allocator.free(db_path);
        const manifest_path = try writeManifest(runtime, &graph, target_dir);
        return executeConcurrentCommand(runtime, options, &graph, selected, target_dir, manifest_path, db_path, stdout, stderr, "Snapshot");
    }
    _ = try compileSelectedModels(runtime, &graph, selected, target_dir, false, false);
    const manifest_path = try writeManifest(runtime, &graph, target_dir);
    const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
    var results: std.ArrayList(run_results.NodeResult) = .empty;
    defer {
        deinitRunResults(runtime.allocator, results.items);
        results.deinit(runtime.allocator);
    }
    var blocked: std.ArrayList([]const u8) = .empty;
    defer blocked.deinit(runtime.allocator);
    var had_failure = false;
    for (ordered) |node| {
        if (try appendSkippedIfNodeDependsOnBlocked(runtime.allocator, &graph, &blocked, node, &results)) continue;
        if (!try executeModelAppendingResult(runtime, db_path, &graph, node, &results)) {
            try appendUniqueString(runtime.allocator, &blocked, node.unique_id);
            had_failure = true;
        }
    }
    if (had_failure) return failExecution(runtime, target_dir, manifest_path, db_path, results.items, stdout, "Snapshot");
    try writeRunResults(runtime, target_dir, results.items);
    try stdout.print("Snapshotted {d} snapshot(s) into {s}; wrote artifacts into {s}\n", .{ results.items.len, util.normalizeForDisplay(db_path), util.normalizeForDisplay(manifest_path) });
}

pub fn seedPreflight(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try project_loader.loadGraph(runtime, options, loader_callbacks);
    defer graph.deinit();

    try resolveDependencies(&graph);
    try writeWarnings(runtime, stderr, &graph);

    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var selection_state = try loadSelectionState(runtime, options, selection, &graph);
    defer selection_state.deinit(runtime.allocator);
    const target_dir = try targetDir(runtime, options);
    _ = try writeManifest(runtime, &graph, target_dir);
    try @import("project/selection_warnings.zig").check(runtime, &graph, selection.select, selection.exclude, selection_state.context(), stderr);
    const selection_context = selection_state.context();
    const selected_seeds = try selector.selectExecutionResourcesWithContext(runtime.allocator, &graph, "seed", selection.select, selection.exclude, selection_context);
    if (selected_seeds.len == 0) return finishEmptySelection(runtime, target_dir, stderr);

    if (!std.mem.eql(u8, graph.adapter_type, "duckdb") and !std.mem.eql(u8, graph.adapter_type, "postgres")) return error.UnsupportedSeedAdapterExecution;
    const seed_nodes = try selectedSeedExecutionOrder(runtime, &graph, selected_seeds);
    defer runtime.allocator.free(seed_nodes);
    try validateSeedExecution(&graph, seed_nodes);

    const manifest_path = try writeManifest(runtime, &graph, target_dir);
    const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
    if (try concurrent_runner.requested(runtime, options, &graph)) {
        return executeConcurrentCommand(runtime, options, &graph, selected_seeds, target_dir, manifest_path, db_path, stdout, stderr, "Seed");
    }
    var executed: std.ArrayList(run_results.NodeResult) = .empty;
    defer {
        deinitRunResults(runtime.allocator, executed.items);
        executed.deinit(runtime.allocator);
    }
    for (seed_nodes, 0..) |node, index| {
        if (!try executeSeedAppendingResult(runtime, db_path, options.project_dir, &graph, node, &executed)) {
            try appendSkippedAfterExecutionFailure(runtime.allocator, &graph, selected_seeds, seed_nodes[index + 1 ..], &.{}, node.unique_id, &executed);
            return failExecution(runtime, target_dir, manifest_path, db_path, executed.items, stdout, "Seed");
        }
    }

    try @import("project/seed_preview.zig").write(runtime, &graph, options, executed.items, stdout);
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
    try writeWarnings(runtime, stderr, &graph);

    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var selection_state = try loadSelectionState(runtime, options, selection, &graph);
    defer selection_state.deinit(runtime.allocator);
    const target_dir = try targetDir(runtime, options);
    _ = try writeManifest(runtime, &graph, target_dir);
    try @import("project/selection_warnings.zig").check(runtime, &graph, selection.select, selection.exclude, selection_state.context(), stderr);
    const selection_context = selection_state.context();
    const selected = try selector.selectExecutionResourcesWithContext(runtime.allocator, &graph, "test", selection.select, selection.exclude, selection_context);
    const selected_unit_tests = try selector.selectExecutionResourcesWithContext(runtime.allocator, &graph, "unit_test", selection.select, selection.exclude, selection_context);
    if (selected.len == 0 and selected_unit_tests.len == 0) return finishEmptySelection(runtime, target_dir, stderr);

    if (!std.mem.eql(u8, graph.adapter_type, "duckdb") and !std.mem.eql(u8, graph.adapter_type, "postgres")) return error.UnsupportedTestExecution;
    const test_nodes = try selectedDataTestExecutionOrder(runtime, &graph, selected);
    defer runtime.allocator.free(test_nodes);
    try validateDataTestExecution(test_nodes);
    const unit_test_nodes = try selectedUnitTestExecutionOrder(runtime, &graph, selected_unit_tests);
    defer runtime.allocator.free(unit_test_nodes);
    try validateUnitTestExecution(runtime, &graph, unit_test_nodes);

    const manifest_path = try writeManifest(runtime, &graph, target_dir);
    const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
    if (try concurrent_runner.requested(runtime, options, &graph)) {
        const combined = try runtime.allocator.alloc(selector.SelectedResource, selected.len + selected_unit_tests.len);
        defer runtime.allocator.free(combined);
        @memcpy(combined[0..selected.len], selected);
        @memcpy(combined[selected.len..], selected_unit_tests);
        return executeConcurrentCommand(runtime, options, &graph, combined, target_dir, manifest_path, db_path, stdout, stderr, "Test");
    }
    var executed: std.ArrayList(run_results.NodeResult) = .empty;
    defer {
        deinitRunResults(runtime.allocator, executed.items);
        executed.deinit(runtime.allocator);
    }
    try project_defer.apply(runtime, &graph, options, selected, target_dir);
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
    try writeWarnings(runtime, stderr, &graph);

    var selection = try resolveSelection(runtime, options);
    defer selection.deinit(runtime.allocator);
    var selection_state = try loadSelectionState(runtime, options, selection, &graph);
    defer selection_state.deinit(runtime.allocator);
    const target_dir = try targetDir(runtime, options);
    _ = try writeManifest(runtime, &graph, target_dir);
    try @import("project/selection_warnings.zig").check(runtime, &graph, selection.select, selection.exclude, selection_state.context(), stderr);
    // Core BuildTask evaluates the full graph, the graph without unit tests,
    // and its final queue independently; each evaluates explicit criteria.
    try @import("project/selection_warnings.zig").check(runtime, &graph, selection.select, selection.exclude, selection_state.context(), stderr);
    try @import("project/selection_warnings.zig").check(runtime, &graph, selection.select, selection.exclude, selection_state.context(), stderr);
    const candidates = try selector.selectExecutionResourcesWithContext(runtime.allocator, &graph, null, selection.select, selection.exclude, selection_state.context());
    const selected = try commandSelection(runtime.allocator, candidates, .build);
    if (selected.len == 0) return finishEmptySelection(runtime, target_dir, stderr);

    for (graph.nodes.items) |node| {
        if (node.enabled and std.mem.eql(u8, node.language, "python") and selectionContains(selected, node.unique_id)) return error.UnsupportedPythonModelExecution;
    }

    try project_defer.apply(runtime, &graph, options, selected, target_dir);
    if (try concurrent_runner.requested(runtime, options, &graph)) {
        const db_path = try duckdb.databasePath(runtime.allocator, target_dir, &graph);
        defer runtime.allocator.free(db_path);
        const manifest_path = try writeManifest(runtime, &graph, target_dir);
        return executeConcurrentCommand(runtime, options, &graph, selected, target_dir, manifest_path, db_path, stdout, stderr, "Build");
    }
    const compile_result = try compileSelectedModels(runtime, &graph, selected, target_dir, false, false);
    const manifest_path = try writeManifest(runtime, &graph, target_dir);
    const selected_kinds = classifyBuildSelection(selected);
    if (selected_kinds.total == 0) return error.UnsupportedBuildSelection;
    if (selected_kinds.unit_test != 0 and selected_kinds.test_resource + selected_kinds.unit_test != selected_kinds.total and
        selected_kinds.seed + selected_kinds.model + selected_kinds.source + selected_kinds.test_resource + selected_kinds.unit_test == selected_kinds.total)
    {
        return buildWithUnitTests(runtime, options, &graph, selected, target_dir, manifest_path, stdout);
    }
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
            if (try appendSkippedIfNodeDependsOnBlocked(runtime.allocator, &graph, &blocked, node, &executed)) continue;
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
            if (try appendSkippedIfNodeDependsOnBlocked(runtime.allocator, &graph, &blocked, node, &executed)) {
                try appendSkippedBlockedDataTests(runtime.allocator, &graph, selected, test_nodes, executed_tests, blocked.items, &executed);
                continue;
            }
            if (!try executeSeedAppendingResult(runtime, db_path, options.project_dir, &graph, node, &executed)) {
                try appendUniqueString(runtime.allocator, &blocked, node.unique_id);
                had_execution_failure = true;
                try appendSkippedBlockedDataTests(runtime.allocator, &graph, selected, test_nodes, executed_tests, blocked.items, &executed);
                continue;
            }
            try executed_node_ids.append(runtime.allocator, node.unique_id);
            var failed_test_blockers: std.ArrayList([]const u8) = .empty;
            defer failed_test_blockers.deinit(runtime.allocator);
            const test_summary = try appendReadyDataTestResults(runtime, db_path, &graph, selected, test_nodes, executed_tests, executed_node_ids.items, &executed, &failed_test_blockers);
            if (test_summary.failed_tests != 0) {
                try appendBlockedRoots(runtime.allocator, &blocked, failed_test_blockers.items);
                test_failures.failed_tests += test_summary.failed_tests;
                test_failures.total_failures += test_summary.total_failures;
            }
        }
        try appendSkippedBlockedDataTests(runtime.allocator, &graph, selected, test_nodes, executed_tests, blocked.items, &executed);
        const test_summary = try appendRemainingReadyDataTestResults(runtime, db_path, &graph, selected, test_nodes, executed_tests, executed_node_ids.items, &executed);
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
        try project_defer.apply(runtime, &graph, options, selected, target_dir);
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
        try project_defer.apply(runtime, &graph, options, selected, target_dir);
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
        try validateBuildMaterializations(&graph, execution_order);

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
            if (try appendSkippedIfNodeDependsOnBlocked(runtime.allocator, &graph, &blocked, node, &executed)) {
                try appendSkippedBlockedDataTests(runtime.allocator, &graph, selected, test_nodes, executed_tests, blocked.items, &executed);
                continue;
            }
            if (!try executeModelAppendingResult(runtime, db_path, &graph, node, &executed)) {
                try appendUniqueString(runtime.allocator, &blocked, node.unique_id);
                had_execution_failure = true;
                try appendSkippedBlockedDataTests(runtime.allocator, &graph, selected, test_nodes, executed_tests, blocked.items, &executed);
                continue;
            }
            try executed_node_ids.append(runtime.allocator, node.unique_id);
            var failed_test_blockers: std.ArrayList([]const u8) = .empty;
            defer failed_test_blockers.deinit(runtime.allocator);
            const test_summary = try appendReadyDataTestResults(runtime, db_path, &graph, selected, test_nodes, executed_tests, executed_node_ids.items, &executed, &failed_test_blockers);
            if (test_summary.failed_tests != 0) {
                try appendBlockedRoots(runtime.allocator, &blocked, failed_test_blockers.items);
                test_failures.failed_tests += test_summary.failed_tests;
                test_failures.total_failures += test_summary.total_failures;
            }
        }
        try appendSkippedBlockedDataTests(runtime.allocator, &graph, selected, test_nodes, executed_tests, blocked.items, &executed);
        const test_summary = try appendRemainingReadyDataTestResults(runtime, db_path, &graph, selected, test_nodes, executed_tests, executed_node_ids.items, &executed);
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
            if (try appendSkippedIfNodeDependsOnBlocked(runtime.allocator, &graph, &blocked, node, &executed)) {
                try appendSkippedBlockedDataTests(runtime.allocator, &graph, selected, test_nodes, executed_tests, blocked.items, &executed);
                continue;
            }
            if (std.mem.eql(u8, node.resource_type, "seed")) {
                if (!try executeSeedAppendingResult(runtime, db_path, options.project_dir, &graph, node, &executed)) {
                    try appendUniqueString(runtime.allocator, &blocked, node.unique_id);
                    had_execution_failure = true;
                    try appendSkippedBlockedDataTests(runtime.allocator, &graph, selected, test_nodes, executed_tests, blocked.items, &executed);
                    continue;
                }
                seed_count += 1;
            } else {
                if (!try executeModelAppendingResult(runtime, db_path, &graph, node, &executed)) {
                    try appendUniqueString(runtime.allocator, &blocked, node.unique_id);
                    had_execution_failure = true;
                    try appendSkippedBlockedDataTests(runtime.allocator, &graph, selected, test_nodes, executed_tests, blocked.items, &executed);
                    continue;
                }
                model_count += 1;
            }
            try executed_node_ids.append(runtime.allocator, node.unique_id);
            var failed_test_blockers: std.ArrayList([]const u8) = .empty;
            defer failed_test_blockers.deinit(runtime.allocator);
            const test_summary = try appendReadyDataTestResults(runtime, db_path, &graph, selected, test_nodes, executed_tests, executed_node_ids.items, &executed, &failed_test_blockers);
            if (test_summary.failed_tests != 0) {
                try appendBlockedRoots(runtime.allocator, &blocked, failed_test_blockers.items);
                test_failures.failed_tests += test_summary.failed_tests;
                test_failures.total_failures += test_summary.total_failures;
            }
        }
        try appendSkippedBlockedDataTests(runtime.allocator, &graph, selected, test_nodes, executed_tests, blocked.items, &executed);
        const test_summary = try appendRemainingReadyDataTestResults(runtime, db_path, &graph, selected, test_nodes, executed_tests, executed_node_ids.items, &executed);
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

/// Unit tests gate their model, whereas data tests gate its descendants after
/// materialization. Keep both gates in the same ordered physical resource loop.
fn buildWithUnitTests(runtime: Runtime, options: Options, graph: *Graph, selected: []const selector.SelectedResource, target_dir: []const u8, manifest_path: []const u8, stdout: *Io.Writer) !void {
    if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedBuildAdapterExecution;
    const nodes = try scheduler.orderNodes(runtime.allocator, graph, selected, true);
    defer runtime.allocator.free(nodes);
    try validateSeedModelBuildExecution(graph, nodes);
    const data_tests = try selectedDataTestExecutionOrder(runtime, graph, selected);
    defer runtime.allocator.free(data_tests);
    try validateDataTestExecution(data_tests);
    const unit_tests = try selectedUnitTestExecutionOrder(runtime, graph, selected);
    defer runtime.allocator.free(unit_tests);
    try validateUnitTestExecution(runtime, graph, unit_tests);

    const db_path = try duckdb.databasePath(runtime.allocator, target_dir, graph);
    var results: std.ArrayList(run_results.NodeResult) = .empty;
    defer {
        deinitRunResults(runtime.allocator, results.items);
        results.deinit(runtime.allocator);
    }
    var completed: std.ArrayList([]const u8) = .empty;
    defer completed.deinit(runtime.allocator);
    var blocked: std.ArrayList([]const u8) = .empty;
    defer blocked.deinit(runtime.allocator);
    const done_data = try runtime.allocator.alloc(bool, data_tests.len);
    defer runtime.allocator.free(done_data);
    @memset(done_data, false);
    const done_units = try runtime.allocator.alloc(bool, unit_tests.len);
    defer runtime.allocator.free(done_units);
    @memset(done_units, false);

    var failed_tests = GenericTestExecutionSummary{};
    var had_execution_failure = false;
    // An explicitly selected unit can gate downstream models even when its
    // own model uses an existing relation and is outside the selection.
    for (unit_tests, 0..) |unit_test, index| {
        for (graph.nodes.items) |*target_node| {
            if (!scheduler.unitTargetsNode(unit_test, target_node)) continue;
            if (selectionContains(selected, target_node.unique_id)) break;
            if (containsUniqueId(blocked.items, target_node.unique_id) or
                try scheduler.blockedBy(runtime.allocator, graph, target_node.depends_on.items, blocked.items))
            {
                try results.append(runtime.allocator, .{ .unit_test_node = unit_test, .status = "skipped" });
            } else {
                const summary = try appendOneUnitTestResult(runtime, db_path, graph, unit_test, &results);
                failed_tests.failed_tests += summary.failed_tests;
                failed_tests.total_failures += summary.total_failures;
                if (summary.failed_tests != 0) try appendUniqueString(runtime.allocator, &blocked, target_node.unique_id);
            }
            done_units[index] = true;
            break;
        }
    }
    for (nodes) |node| {
        const node_blocked = containsUniqueId(blocked.items, node.unique_id) or
            try scheduler.blockedBy(runtime.allocator, graph, node.depends_on.items, blocked.items);
        for (unit_tests, 0..) |unit_test, index| {
            if (done_units[index] or !scheduler.unitTargetsNode(unit_test, node)) continue;
            if (node_blocked or containsUniqueId(blocked.items, node.unique_id)) {
                try results.append(runtime.allocator, .{ .unit_test_node = unit_test, .status = "skipped" });
            } else {
                const summary = try appendOneUnitTestResult(runtime, db_path, graph, unit_test, &results);
                failed_tests.failed_tests += summary.failed_tests;
                failed_tests.total_failures += summary.total_failures;
                if (summary.failed_tests != 0) try appendUniqueString(runtime.allocator, &blocked, node.unique_id);
            }
            done_units[index] = true;
        }

        if (node_blocked or containsUniqueId(blocked.items, node.unique_id)) {
            try results.append(runtime.allocator, .{ .node = node, .status = "skipped" });
            try appendUniqueString(runtime.allocator, &blocked, node.unique_id);
        } else {
            const success = if (std.mem.eql(u8, node.resource_type, "seed"))
                try executeSeedAppendingResult(runtime, db_path, options.project_dir, graph, node, &results)
            else
                try executeModelAppendingResult(runtime, db_path, graph, node, &results);
            if (success) {
                try completed.append(runtime.allocator, node.unique_id);
            } else {
                try appendUniqueString(runtime.allocator, &blocked, node.unique_id);
                had_execution_failure = true;
            }
        }
        try appendSkippedBlockedDataTests(runtime.allocator, graph, selected, data_tests, done_data, blocked.items, &results);
        var failed_roots: std.ArrayList([]const u8) = .empty;
        defer failed_roots.deinit(runtime.allocator);
        const data_summary = try appendReadyDataTestResults(runtime, db_path, graph, selected, data_tests, done_data, completed.items, &results, &failed_roots);
        failed_tests.failed_tests += data_summary.failed_tests;
        failed_tests.total_failures += data_summary.total_failures;
        try appendBlockedRoots(runtime.allocator, &blocked, failed_roots.items);
    }
    // Explicitly selected units whose target model is not selected still run
    // against fixtures, independent of whether its target relation exists.
    for (unit_tests, 0..) |unit_test, index| {
        if (done_units[index]) continue;
        if (try scheduler.blockedBy(runtime.allocator, graph, unit_test.depends_on.items, blocked.items)) {
            try results.append(runtime.allocator, .{ .unit_test_node = unit_test, .status = "skipped" });
        } else {
            const summary = try appendOneUnitTestResult(runtime, db_path, graph, unit_test, &results);
            failed_tests.failed_tests += summary.failed_tests;
            failed_tests.total_failures += summary.total_failures;
        }
        done_units[index] = true;
    }
    try appendSkippedBlockedDataTests(runtime.allocator, graph, selected, data_tests, done_data, blocked.items, &results);
    const remaining = try appendRemainingReadyDataTestResults(runtime, db_path, graph, selected, data_tests, done_data, completed.items, &results);
    failed_tests.failed_tests += remaining.failed_tests;
    failed_tests.total_failures += remaining.total_failures;

    if (had_execution_failure) return failExecution(runtime, target_dir, manifest_path, db_path, results.items, stdout, "Build");
    try writeRunResults(runtime, target_dir, results.items);
    try stdout.print("Built {d} resource(s) against {s}; wrote artifacts into {s}\n", .{ results.items.len, util.normalizeForDisplay(db_path), util.normalizeForDisplay(manifest_path) });
    if (failed_tests.failed_tests != 0) {
        try stdout.print("{d} test(s) failed with {d} failure row(s)\n", .{ failed_tests.failed_tests, failed_tests.total_failures });
        return error.TestFailure;
    }
}

fn executeConcurrentCommand(runtime: Runtime, options: Options, graph: *Graph, selected: []const selector.SelectedResource, target_dir: []const u8, manifest_path: []const u8, db_path: []const u8, stdout: *Io.Writer, stderr: *Io.Writer, label: []const u8) !void {
    var resources: std.ArrayList(concurrent_runner.Resource) = .empty;
    defer resources.deinit(runtime.allocator);
    for (graph.nodes.items) |*node| {
        if (!node.enabled or !selectionContains(selected, node.unique_id) or std.mem.eql(u8, node.materialized, "ephemeral")) continue;
        if (!std.mem.eql(u8, node.resource_type, "model") and !std.mem.eql(u8, node.resource_type, "seed") and !std.mem.eql(u8, node.resource_type, "snapshot")) return error.UnsupportedBuildSelection;
        if (!std.mem.eql(u8, node.resource_type, "seed") and node.relation_name == null) node.relation_name = try compiler.relationNameForNode(runtime.allocator, graph, node);
        try resources.append(runtime.allocator, .{ .node = node });
    }
    for (graph.tests.items) |*node| if (node.enabled and selectionContains(selected, node.unique_id)) {
        try resources.append(runtime.allocator, .{ .generic = node });
    };
    for (graph.singular_tests.items) |*node| if (node.enabled and selectionContains(selected, node.unique_id)) {
        try resources.append(runtime.allocator, .{ .singular = node });
    };
    for (graph.unit_tests.items) |*node| if (node.enabled and selectionContains(selected, node.unique_id)) {
        try resources.append(runtime.allocator, .{ .unit = node });
    };
    if (resources.items.len == 0) return executeEphemeralSelection(runtime, options, graph, selected, target_dir, stdout, stderr);
    try validateConcurrentResources(runtime, graph, resources.items, label);
    const cache_ids = try runtime.allocator.alloc([]const u8, selected.len);
    defer runtime.allocator.free(cache_ids);
    for (selected, cache_ids) |item, *id| id.* = item.unique_id;
    try @import("project/relation_cache.zig").configure(runtime, graph, cache_ids);
    defer @import("project/relation_cache.zig").writeEvents(runtime, graph, stderr) catch {};
    // Core creates all selected model and persisted-test schemas before jobs.
    // Serial preparation avoids DuckDB catalog conflicts between audit jobs.
    var preparation = try @import("project/adapter.zig").openSession(runtime, graph, db_path);
    defer preparation.deinit();
    for (resources.items) |resource| {
        const config = switch (resource) {
            .generic => |node| node.config,
            .singular => |node| node.config,
            else => null,
        };
        const node: ?Node = switch (resource) {
            .node => |value| value.*,
            .generic => |value| if (@import("project/test_audits.zig").shouldStore(config.?, options)) @import("project/test_audits.zig").auditNodeWithIdentity(config.?, value.alias, value.package_name, value.resolved_identity) else null,
            .singular => |value| if (@import("project/test_audits.zig").shouldStore(config.?, options)) @import("project/test_audits.zig").auditNodeWithIdentity(config.?, value.alias, value.package_name, value.resolved_identity) else null,
            else => null,
        };
        if (node) |value| {
            const schema = try compiler.relationSchemaForNode(runtime.allocator, graph, &value);
            defer runtime.allocator.free(schema);
            const quoted = try compiler.quoteIdentifier(runtime.allocator, schema);
            defer runtime.allocator.free(quoted);
            const sql = try std.fmt.allocPrint(runtime.allocator, "create schema if not exists {s}", .{quoted});
            defer runtime.allocator.free(sql);
            try preparation.execute(sql);
        }
    }
    try @import("project/relation_cache.zig").warmSession(&preparation, true);
    var task_rows: std.ArrayList(run_results.NodeResult) = .empty;
    defer task_rows.deinit(runtime.allocator);
    defer deinitRunResults(runtime.allocator, task_rows.items);
    const start_failed = try @import("project/hook_operations.zig").run(runtime, graph, &preparation, db_path, target_dir, "on-run-start", &task_rows, stderr, null);
    var summary = if (start_failed and graph.skip_nodes_if_on_run_start_fails) blk: {
        const rows = try runtime.allocator.alloc(run_results.NodeResult, resources.items.len);
        for (resources.items, rows) |resource, *row| {
            row.* = resource.result("skipped");
            row.thread_name = "MainThread";
        }
        break :blk concurrent_runner.Summary{ .rows = rows, .had_execution_error = true };
    } else try concurrent_runner.run(runtime, graph, options, resources.items, db_path, executeConcurrentResource, stderr);
    const job_rows = summary.rows;
    defer runtime.allocator.free(job_rows);
    var transferred = false;
    defer if (!transferred) deinitRunResults(runtime.allocator, job_rows);
    try task_rows.appendSlice(runtime.allocator, summary.rows);
    transferred = true;
    // Publish each job's final compilation only after its arena has transferred
    // ownership. Skipped nodes keep their parsed relation identity.
    for (summary.rows) |row| {
        if (row.node) |original| {
            const node = @constCast(original);
            if (row.compiled_code) |sql| {
                node.compiled_code = try runtime.allocator.dupe(u8, sql);
                node.compiled = true;
                const artifact_path = if (node.snapshot_yaml_definition) try std.fmt.allocPrint(runtime.allocator, "{s}/{s}.sql", .{ node.original_file_path, node.name }) else node.original_file_path;
                defer if (node.snapshot_yaml_definition) runtime.allocator.free(artifact_path);
                const compiled_path = try pathJoin(runtime.allocator, &.{ target_dir, "compiled", node.package_name, artifact_path });
                node.compiled_path = compiled_path;
                if (std.fs.path.dirname(compiled_path)) |parent| try Io.Dir.cwd().createDirPath(runtime.io, parent);
                try Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = compiled_path, .data = sql });
            }
            if (row.relation_name) |relation| {
                if (node.relation_name) |old| runtime.allocator.free(old);
                node.relation_name = try runtime.allocator.dupe(u8, relation);
            }
            for (row.compiled_ctes) |cte| try node.extra_ctes.append(runtime.allocator, .{ .id = cte.id, .sql = try runtime.allocator.dupe(u8, cte.sql) });
        }
    }
    const end_failed = @import("project/hook_operations.zig").run(runtime, graph, &preparation, db_path, target_dir, "on-run-end", &task_rows, stderr, if (start_failed and graph.skip_nodes_if_on_run_start_fails) &.{} else null) catch |err| {
        _ = try writeManifest(runtime, graph, target_dir);
        try writeRunResults(runtime, target_dir, task_rows.items);
        return err;
    };
    summary.had_execution_error = summary.had_execution_error or start_failed or end_failed;
    summary.rows = task_rows.items;
    _ = try writeManifest(runtime, graph, target_dir);
    try @import("project/seed_preview.zig").write(runtime, graph, options, summary.rows, stdout);
    try writeRunResults(runtime, target_dir, summary.rows);
    if (summary.had_execution_error) {
        if (summary.failed_tests != 0) try stdout.print("{d} test(s) failed with {d} failure row(s)\n", .{ summary.failed_tests, summary.total_failures });
        return failExecution(runtime, target_dir, manifest_path, db_path, summary.rows, stdout, label);
    }
    try printConcurrentSummary(stdout, summary.rows, label);
    try stdout.print(" against {s}; wrote artifacts into {s}\n", .{ util.normalizeForDisplay(db_path), util.normalizeForDisplay(manifest_path) });
    if (summary.failed_tests != 0) {
        try stdout.print("{d} test(s) failed with {d} failure row(s)\n", .{ summary.failed_tests, summary.total_failures });
        return error.TestFailure;
    }
}

fn validateConcurrentResources(runtime: Runtime, graph: *const Graph, resources: []const concurrent_runner.Resource, label: []const u8) !void {
    for (resources) |resource| switch (resource) {
        .node => |node| {
            if (std.mem.eql(u8, node.resource_type, "seed")) {
                if (!std.mem.eql(u8, node.materialized, "seed")) return error.UnsupportedSeedExecution;
            } else if (std.mem.eql(u8, node.resource_type, "snapshot")) {
                try snapshot_runner.validateExecution(graph, node);
            } else {
                if (!duckdb.isSupportedMaterializationForAdapter(graph.adapter_type, node.materialized)) {
                    if (std.mem.eql(u8, label, "Build")) return error.UnsupportedBuildModelMaterialization;
                    return error.UnsupportedModelMaterialization;
                }
                if (std.mem.eql(u8, node.materialized, "incremental")) try incremental_config.validateForAdapter(graph.adapter_type, node.incremental);
            }
        },
        .generic => |node| try validateGenericTestExecution(node),
        .unit => |node| try duckdb.validateUnitTestExecution(runtime.allocator, graph, node),
        .singular => {},
    };
}

fn printConcurrentSummary(stdout: *Io.Writer, rows: []const run_results.NodeResult, label: []const u8) !void {
    var models: usize = 0;
    var seeds: usize = 0;
    var tests: usize = 0;
    var source_tests = true;
    for (rows) |row| {
        if (std.mem.eql(u8, row.status, "skipped")) continue;
        if (row.node) |node| {
            if (node.hook_index != null) continue;
            if (std.mem.eql(u8, node.resource_type, "seed")) seeds += 1 else models += 1;
        } else if (row.test_node) |node| {
            tests += 1;
            if (node.attached_source_unique_id == null) source_tests = false;
        } else {
            tests += 1;
            source_tests = false;
        }
    }
    if (std.mem.eql(u8, label, "Run")) return stdout.print("Ran {d} model(s)", .{models});
    if (std.mem.eql(u8, label, "Seed")) return stdout.print("Seeded {d} seed(s)", .{seeds});
    if (std.mem.eql(u8, label, "Test")) return stdout.print("Tested {d} test(s)", .{tests});
    if (std.mem.eql(u8, label, "Snapshot")) return stdout.print("Snapshotted {d} snapshot(s)", .{models});
    if (seeds != 0 and models != 0) return stdout.print("Built {d} seed(s), {d} model(s), and {d} test(s)", .{ seeds, models, tests });
    if (models != 0) return stdout.print("Built {d} model(s) and {d} test(s)", .{ models, tests });
    if (seeds != 0) {
        if (tests != 0) return stdout.print("Built {d} seed(s) and {d} test(s)", .{ seeds, tests });
        return stdout.print("Built {d} seed(s)", .{seeds});
    }
    return stdout.print("Built {d} {s}test(s)", .{ tests, if (source_tests) "source " else "" });
}

fn executeConcurrentResource(runtime: Runtime, graph_readonly: *const Graph, resource: concurrent_runner.Resource, db_path: []const u8, project_dir: []const u8) !run_results.NodeResult {
    var graph = graph_readonly.*;
    var output: Io.Writer.Allocating = .init(runtime.allocator);
    defer output.deinit();
    var host = try commands.OperationHost.init(runtime, &graph, db_path, &output.writer);
    defer host.deinit();
    var log_events: std.ArrayList(run_results.LogMessage) = .empty;
    defer log_events.deinit(runtime.allocator);
    host.log_events = &log_events;
    graph.log_collector = &log_events;
    graph.execution_hooks = host.host();
    var rows: std.ArrayList(run_results.NodeResult) = .empty;
    defer rows.deinit(runtime.allocator);
    if (resource == .node) {
        const original = resource.node;
        var node = original.*;
        const compilation_started = execution_clock.now(runtime.io);
        compileConcurrentNode(runtime, &graph, &node, db_path) catch |err| {
            var row = resource.result("error");
            row.message = try runtime.allocator.dupe(u8, if (err == error.AdapterQueryCancelled) "Database query cancelled" else "Resource compilation failed");
            row.compile_started_at = compilation_started;
            row.compile_completed_at = execution_clock.now(runtime.io);
            try captureResourceLogs(runtime.allocator, &row, output.written(), &log_events);
            return row;
        };
        const compilation_completed = execution_clock.now(runtime.io);
        try host.commit();
        const execution = if (std.mem.eql(u8, node.resource_type, "seed")) executeSeedAppendingResult(runtime, db_path, project_dir, &graph, &node, &rows) else executeModelAppendingResult(runtime, db_path, &graph, &node, &rows);
        _ = execution catch |err| blk: {
            var row = resource.result("error");
            row.message = try runtime.allocator.dupe(u8, if (err == error.AdapterQueryCancelled) "Database query cancelled" else "Resource execution failed");
            try rows.append(runtime.allocator, row);
            break :blk false;
        };
        var row = rows.items[0];
        row.node = original;
        if (row.compiled_code == null) {
            row.compiled_code = node.compiled_code;
            row.owns_compiled_code = node.compiled_code != null;
        }
        row.relation_name = node.relation_name;
        row.owns_relation_name = node.relation_name != null;
        row.compile_started_at = compilation_started;
        row.compile_completed_at = compilation_completed;
        if (!row.owns_compiled_ctes) row.compiled_ctes = node.extra_ctes.items;
        try captureResourceLogs(runtime.allocator, &row, output.written(), &log_events);
        return row;
    }
    const compilation_started = execution_clock.now(runtime.io);
    _ = (switch (resource) {
        .generic => |node| appendOneDataTestResult(runtime, db_path, &graph, .{ .generic = @constCast(node) }, &rows),
        .singular => |node| appendOneDataTestResult(runtime, db_path, &graph, .{ .singular = @constCast(node) }, &rows),
        .unit => |node| appendOneUnitTestResult(runtime, db_path, &graph, node, &rows),
        .node => unreachable,
    }) catch |err| blk: {
        var failure = resource.result("error");
        failure.message = if (@import("project/compile_diagnostics.zig").message(err)) |message| try runtime.allocator.dupe(u8, message) else try std.fmt.allocPrint(runtime.allocator, "Test compilation failed: {s}", .{@errorName(err)});
        failure.compile_started_at = compilation_started;
        failure.compile_completed_at = execution_clock.now(runtime.io);
        if (resource != .unit) failure.compiled_override = false;
        try rows.append(runtime.allocator, failure);
        break :blk GenericTestExecutionSummary{ .failed_tests = 1 };
    };
    var row = rows.items[0];
    try captureResourceLogs(runtime.allocator, &row, output.written(), &log_events);
    return row;
}

fn captureResourceLogs(allocator: std.mem.Allocator, row: *run_results.NodeResult, messages: []const u8, events: *std.ArrayList(run_results.LogMessage)) !void {
    if (messages.len != 0) {
        row.log_output = try allocator.dupe(u8, messages);
        row.owns_log_output = true;
    }
    row.log_events = try events.toOwnedSlice(allocator);
    row.owns_log_events = true;
}

fn compileConcurrentNode(runtime: Runtime, graph: *const Graph, node: *Node, db_path: []const u8) !void {
    if (std.mem.eql(u8, node.resource_type, "seed")) return;
    if (microbatch.enabled(node)) {
        node.relation_name = try compiler.relationNameForNode(runtime.allocator, graph, node);
        return;
    }
    if (std.mem.eql(u8, node.materialized, "incremental")) node.runtime_is_incremental = try incremental.isIncremental(runtime, db_path, graph, node);
    const compiled = try compiler.compileModelWithInjectedCtes(runtime.allocator, graph, node);
    node.compiled = true;
    node.compiled_code = compiled.compiled_code;
    node.extra_ctes = compiled.extra_ctes;
    node.relation_name = try compiler.relationNameForNode(runtime.allocator, graph, node);
}

fn resolveSelection(runtime: Runtime, options: Options) !selector_config.ResolvedSelection {
    if (options.execution_select) |selection| return .{ .select = try runtime.allocator.dupe(u8, selection) };
    return try selector_config.resolveSelection(runtime, options.project_dir, options.select, options.exclude, options.selector);
}

const SelectionState = struct {
    allowed_ids: ?[]const []const u8 = null,
    source_status_index: ?source_freshness.SourceStatusIndex = null,
    result_status_index: ?run_results.ResultStatusIndex = null,
    prior_manifest_index: ?state_artifacts.PriorManifestIndex = null,
    current_manifest_index: ?state_artifacts.PriorManifestIndex = null,
    current_source_status_index: ?source_freshness.SourceStatusIndex = null,
    indirect_selection: []const u8 = "eager",
    expression: ?*const selector.SelectionExpression = null,

    fn deinit(self: *SelectionState, allocator: std.mem.Allocator) void {
        if (self.source_status_index) |*index| index.deinit(allocator);
        if (self.result_status_index) |*index| index.deinit(allocator);
        if (self.prior_manifest_index) |*index| index.deinit(allocator);
        if (self.current_manifest_index) |*index| index.deinit(allocator);
        if (self.current_source_status_index) |*index| index.deinit(allocator);
        self.* = .{};
    }

    fn context(self: *const SelectionState) selector.SelectionContext {
        var ctx: selector.SelectionContext = .{};
        ctx.allowed_ids = self.allowed_ids;
        if (self.source_status_index) |*index| ctx.source_status_index = index;
        if (self.result_status_index) |*index| ctx.result_status_index = index;
        if (self.prior_manifest_index) |*index| ctx.prior_manifest_index = index;
        if (self.current_manifest_index) |*index| ctx.current_manifest_index = index;
        if (self.current_source_status_index) |*index| ctx.current_source_status_index = index;
        ctx.indirect_selection = self.indirect_selection;
        ctx.expression = self.expression;
        return ctx;
    }
};

fn loadSelectionState(runtime: Runtime, options: Options, selection: selector_config.ResolvedSelection, graph: *const Graph) !SelectionState {
    const needs_source_status = selector.usesSourceStatusSelector(selection.select, selection.exclude);
    const needs_result = selector.usesResultSelector(selection.select, selection.exclude);
    const needs_state = selector.usesStateSelector(selection.select, selection.exclude);
    if (!needs_source_status and !needs_result and !needs_state) return .{ .allowed_ids = options.execution_ids, .indirect_selection = options.indirect_selection, .expression = selection.expression };

    const state_dir = options.state orelse {
        if (needs_state) return error.MissingStateManifestState;
        if (needs_result) return error.MissingResultState;
        return error.MissingSourceStatusState;
    };

    var state: SelectionState = .{ .allowed_ids = options.execution_ids, .indirect_selection = options.indirect_selection, .expression = selection.expression };
    errdefer state.deinit(runtime.allocator);
    if (needs_state) {
        state.prior_manifest_index = try state_artifacts.loadPriorManifestIndex(runtime, state_dir);
        const current_json = try manifest.renderManifest(runtime.allocator, graph);
        defer runtime.allocator.free(current_json);
        state.current_manifest_index = try state_artifacts.parsePriorManifestIndex(runtime.allocator, current_json);
    }
    if (needs_source_status) state.source_status_index = try source_freshness.loadSourceStatusIndex(runtime, state_dir);
    if (selector.usesFresherSelector(selection.select, selection.exclude)) {
        const current_dir = try targetDir(runtime, options);
        defer runtime.allocator.free(current_dir);
        state.current_source_status_index = source_freshness.loadSourceStatusIndex(runtime, current_dir) catch |err| switch (err) {
            error.MissingSourcesArtifact => return error.MissingCurrentSourcesArtifact,
            else => return err,
        };
    }
    if (needs_result) state.result_status_index = try run_results.loadResultStatusIndex(runtime, state_dir);
    return state;
}

const CompileResult = struct {
    count: usize,
    analysis_count: usize = 0,
    test_count: usize = 0,
    saw_model: bool,
    saw_analysis: bool = false,
    saw_snapshot: bool = false,
    snapshot_count: usize = 0,
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
        } else if (std.mem.eql(u8, item.resource_type, "model") or std.mem.eql(u8, item.resource_type, "snapshot")) {
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
    return try scheduler.orderNodes(runtime.allocator, graph, selected, false);
}

fn selectedSeedModelExecutionOrder(runtime: Runtime, graph: *Graph, selected: []const selector.SelectedResource) ![]*Node {
    return try scheduler.orderNodes(runtime.allocator, graph, selected, true);
}

fn validateRunMaterializations(graph: *const Graph, nodes: []const *Node) !void {
    for (nodes) |node| {
        if (std.mem.eql(u8, node.language, "python")) return error.UnsupportedPythonModelExecution;
        if (std.mem.eql(u8, node.resource_type, "snapshot")) continue;
        if (!duckdb.isSupportedMaterializationForAdapter(graph.adapter_type, node.materialized)) return error.UnsupportedModelMaterialization;
    }
}

fn validateBuildMaterializations(graph: *const Graph, nodes: []const *Node) !void {
    for (nodes) |node| {
        if (std.mem.eql(u8, node.language, "python")) return error.UnsupportedPythonModelExecution;
        if (std.mem.eql(u8, node.resource_type, "snapshot")) continue;
        if (!duckdb.isSupportedMaterializationForAdapter(graph.adapter_type, node.materialized)) return error.UnsupportedBuildModelMaterialization;
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
    for (nodes) |node| {
        if (std.mem.eql(u8, node.resource_type, "seed")) {
            if (!std.mem.eql(u8, node.materialized, "seed")) return error.UnsupportedSeedExecution;
        } else if (std.mem.eql(u8, node.resource_type, "snapshot")) {
            try snapshot_runner.validateExecution(graph, node);
        } else if (std.mem.eql(u8, node.resource_type, "model")) {
            if (std.mem.eql(u8, node.language, "python")) return error.UnsupportedPythonModelExecution;
            if (!duckdb.isSupportedMaterializationForAdapter(graph.adapter_type, node.materialized)) return error.UnsupportedBuildModelMaterialization;
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
        if (!test_node.enabled) continue;
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
    if (!isBuiltInGenericTestNode(test_node)) return;
    if (isBuiltInGenericTestNode(test_node) and genericTestNodeColumnName(test_node) == null) return error.UnsupportedTestExecution;
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
                if ((std.mem.startsWith(u8, dependency, "model.") or std.mem.startsWith(u8, dependency, "seed.") or std.mem.startsWith(u8, dependency, "snapshot.")) and !selectionContains(selected, dependency)) {
                    return error.UnsupportedTestExecution;
                }
            }
        },
    };
}

fn executeModelAppendingResult(runtime: Runtime, db_path: []const u8, graph: *const Graph, node: *const Node, executed: *std.ArrayList(run_results.NodeResult)) !bool {
    if (microbatch.enabled(node)) {
        const row = try microbatch_run.execute(runtime, graph, node, db_path, null);
        try executed.append(runtime.allocator, row);
        return std.mem.eql(u8, row.status, "success");
    }
    const execution = @import("project/materialization_runtime.zig").execute(runtime, db_path, graph, node);
    execution catch |err| switch (err) {
        error.ModelContractMismatch, error.ContractColumnTypeMissing => {
            const message = if (@import("project/compile_diagnostics.zig").message(err)) |text| try runtime.allocator.dupe(u8, text) else try std.fmt.allocPrint(runtime.allocator, "Model contract failed: {s}", .{@errorName(err)});
            errdefer runtime.allocator.free(message);
            try executed.append(runtime.allocator, .{ .node = node, .status = "error", .message = message });
            return false;
        },
        error.DuckDbExecutionFailed, error.PostgresExecutionFailed => {
            try appendExecutionErrorResult(runtime.allocator, executed, node);
            return false;
        },
        else => return err,
    };
    try executed.append(runtime.allocator, .{ .node = node });
    return true;
}

fn executeSeedAppendingResult(runtime: Runtime, db_path: []const u8, project_dir: []const u8, graph: *const Graph, node: *const Node, executed: *std.ArrayList(run_results.NodeResult)) !bool {
    _ = project_dir;
    @import("project/materialization_runtime.zig").execute(runtime, db_path, graph, node) catch |err| switch (err) {
        error.DuckDbExecutionFailed, error.PostgresExecutionFailed, error.CannotSeedView => {
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
    graph: *const Graph,
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
        if (!try scheduler.blockedBy(allocator, graph, node.depends_on.items, blocked.items)) continue;
        try executed.append(allocator, .{
            .node = node,
            .status = "skipped",
        });
        try blocked.append(allocator, node.unique_id);
    }

    for (test_nodes) |test_node| {
        if (!selectionContains(selected, test_node.uniqueId())) continue;
        if (!try testDependsOnAnyBlocked(allocator, graph, test_node, blocked.items)) continue;
        switch (test_node) {
            .generic => |generic| try executed.append(allocator, .{ .test_node = generic, .status = "skipped" }),
            .singular => |singular| try executed.append(allocator, .{ .singular_test_node = singular, .status = "skipped" }),
        }
        try blocked.append(allocator, test_node.uniqueId());
    }
}

fn appendSkippedIfNodeDependsOnBlocked(
    allocator: std.mem.Allocator,
    graph: *const Graph,
    blocked: *std.ArrayList([]const u8),
    node: *const Node,
    executed: *std.ArrayList(run_results.NodeResult),
) !bool {
    if (!try scheduler.blockedBy(allocator, graph, node.depends_on.items, blocked.items)) return false;
    try executed.append(allocator, .{
        .node = node,
        .status = "skipped",
    });
    try appendUniqueString(allocator, blocked, node.unique_id);
    return true;
}

fn appendSkippedAfterDataTestFailure(
    allocator: std.mem.Allocator,
    graph: *const Graph,
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
        if (!try scheduler.blockedBy(allocator, graph, node.depends_on.items, blocked.items)) continue;
        try executed.append(allocator, .{
            .node = node,
            .status = "skipped",
        });
        try appendUniqueString(allocator, &blocked, node.unique_id);
    }

    for (test_nodes, 0..) |test_node, index| {
        if (executed_tests[index]) continue;
        if (!selectionContains(selected, test_node.uniqueId())) continue;
        if (!try testDependsOnAnyBlocked(allocator, graph, test_node, blocked.items)) continue;
        switch (test_node) {
            .generic => |generic| try executed.append(allocator, .{ .test_node = generic, .status = "skipped" }),
            .singular => |singular| try executed.append(allocator, .{ .singular_test_node = singular, .status = "skipped" }),
        }
        try appendUniqueString(allocator, &blocked, test_node.uniqueId());
    }
}

fn testDependsOnAnyBlocked(allocator: std.mem.Allocator, graph: *const Graph, test_node: DataTestRef, blocked: []const []const u8) !bool {
    if (try scheduler.blockedBy(allocator, graph, test_node.dependsOn(), blocked)) return true;
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
    total_failures: i64 = 0,
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
    selected: []const selector.SelectedResource,
    test_nodes: []const DataTestRef,
    executed_tests: []bool,
    completed_nodes: []const []const u8,
    executed: *std.ArrayList(run_results.NodeResult),
    failed_blockers: *std.ArrayList([]const u8),
) !GenericTestExecutionSummary {
    var summary: GenericTestExecutionSummary = .{};
    for (test_nodes, 0..) |test_ref, index| {
        if (executed_tests[index]) continue;
        if (!try scheduler.dependenciesCompleted(runtime.allocator, graph, test_ref.dependsOn(), selected, completed_nodes)) continue;
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
    selected: []const selector.SelectedResource,
    test_nodes: []const DataTestRef,
    executed_tests: []bool,
    completed_nodes: []const []const u8,
    executed: *std.ArrayList(run_results.NodeResult),
) !GenericTestExecutionSummary {
    var summary: GenericTestExecutionSummary = .{};
    for (test_nodes, 0..) |test_ref, index| {
        if (executed_tests[index]) continue;
        if (!try scheduler.dependenciesCompleted(runtime.allocator, graph, test_ref.dependsOn(), selected, completed_nodes)) continue;
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
        for (execution.compiled_ctes) |cte| runtime.allocator.free(cte.sql);
        runtime.allocator.free(execution.compiled_ctes);
        if (execution.relation_name) |relation_name| runtime.allocator.free(relation_name);
    }
    if (execution.execution_error) {
        const message = try runtime.allocator.dupe(u8, if (execution.execution_cancelled) "Database query cancelled" else execution_failure_message);
        errdefer runtime.allocator.free(message);
        switch (test_ref) {
            .generic => |test_node| try executed.append(runtime.allocator, .{
                .test_node = test_node,
                .status = "error",
                .message = message,
                .compiled_code = execution.compiled_code,
                .owns_compiled_code = true,
                .compiled_ctes = execution.compiled_ctes,
                .owns_compiled_ctes = execution.compiled_ctes.len != 0,
                .compile_started_at = execution.compile_started_at,
                .compile_completed_at = execution.compile_completed_at,
                .relation_name = execution.relation_name,
                .owns_relation_name = execution.relation_name != null,
            }),
            .singular => |test_node| try executed.append(runtime.allocator, .{
                .singular_test_node = test_node,
                .status = "error",
                .message = message,
                .compiled_code = execution.compiled_code,
                .owns_compiled_code = true,
                .compiled_ctes = execution.compiled_ctes,
                .owns_compiled_ctes = execution.compiled_ctes.len != 0,
                .compile_started_at = execution.compile_started_at,
                .compile_completed_at = execution.compile_completed_at,
                .relation_name = execution.relation_name,
                .owns_relation_name = execution.relation_name != null,
            }),
        }
        return .{ .failed_tests = 1 };
    }
    var classification = switch (test_ref) {
        .generic => |test_node| try classifyExecutedTestResult(execution.should_warn, execution.should_error, test_node.config),
        .singular => |test_node| try classifyExecutedTestResult(execution.should_warn, execution.should_error, test_node.config),
    };
    if (std.mem.eql(u8, classification.status, "warn") and try cli_options.warningIsError(runtime, "LogTestResult")) {
        classification.status = "fail";
        classification.fails_command = true;
        classification.message_kind = "fail";
    }
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
            .compiled_ctes = execution.compiled_ctes,
            .owns_compiled_ctes = execution.compiled_ctes.len != 0,
            .compile_started_at = execution.compile_started_at,
            .compile_completed_at = execution.compile_completed_at,
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
            .compiled_ctes = execution.compiled_ctes,
            .owns_compiled_ctes = execution.compiled_ctes.len != 0,
            .compile_started_at = execution.compile_started_at,
            .compile_completed_at = execution.compile_completed_at,
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
    return appendUnitTestExecutionResult(runtime.allocator, unit_test, execution, executed);
}

fn appendUnitTestExecutionResult(allocator: std.mem.Allocator, unit_test: *const UnitTestDef, execution: duckdb.UnitTestExecutionResult, executed: *std.ArrayList(run_results.NodeResult)) !GenericTestExecutionSummary {
    errdefer allocator.free(execution.compiled_code);
    if (execution.execution_error) {
        const message = try allocator.dupe(u8, if (execution.execution_cancelled) "Database query cancelled" else execution_failure_message);
        errdefer allocator.free(message);
        try executed.append(allocator, .{
            .unit_test_node = unit_test,
            .compile_started_at = execution.compile_started_at,
            .compile_completed_at = execution.compile_completed_at,
            .status = "error",
            .message = message,
        });
        allocator.free(execution.compiled_code);
        return .{ .failed_tests = 1 };
    }
    const classification = classifyDefaultTestResult(execution.failures);
    const message = if (execution.failure_message) |difference| difference else if (classification.message_kind) |kind|
        try formatTestThresholdMessage(allocator, @intCast(execution.failures), kind, classification.condition orelse "!= 0")
    else
        null;
    errdefer if (message) |owned_message| allocator.free(owned_message);
    try executed.append(allocator, .{
        .unit_test_node = unit_test,
        .status = classification.status,
        .message = message,
        .failures = @intCast(execution.failures),
        .compiled_code = execution.compiled_code,
        .owns_compiled_code = true,
        .compile_started_at = execution.compile_started_at,
        .compile_completed_at = execution.compile_completed_at,
    });
    return .{
        .failed_tests = if (classification.fails_command) 1 else 0,
        .total_failures = if (classification.fails_command) @as(i64, @intCast(execution.failures)) else 0,
    };
}

test "unit execution errors retain prior rows and contain only sanitized metadata" {
    const allocator = std.testing.allocator;
    const unit_test = UnitTestDef{
        .package_name = "demo",
        .unique_id = "unit_test.demo.orders.invalid_cast",
        .name = "invalid_cast",
        .model = "orders",
        .path = "schema.yml",
        .original_file_path = "models/schema.yml",
    };
    var executed: std.ArrayList(run_results.NodeResult) = .empty;
    defer {
        deinitRunResults(allocator, executed.items);
        executed.deinit(allocator);
    }
    try executed.append(allocator, .{ .unit_test_node = &unit_test, .status = "pass", .failures = 0 });
    const summary = try appendUnitTestExecutionResult(allocator, &unit_test, .{
        .compiled_code = try allocator.dupe(u8, "select cast('private input' as integer)"),
        .failures = 0,
        .execution_error = true,
    }, &executed);
    try std.testing.expectEqual(@as(usize, 1), summary.failed_tests);
    try std.testing.expectEqual(@as(i64, 0), summary.total_failures);
    try std.testing.expectEqual(@as(usize, 2), executed.items.len);
    try std.testing.expectEqualStrings("pass", executed.items[0].status);
    const error_row = executed.items[1];
    try std.testing.expectEqualStrings("error", error_row.status);
    try std.testing.expectEqualStrings(execution_failure_message, error_row.message.?);
    try std.testing.expect(error_row.failures == null);
    try std.testing.expect(error_row.compiled_code == null);
    const rendered = try run_results.renderRunResults(allocator, executed.items);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "private input") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"compiled\": null") != null);
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

fn classifyExecutedTestResult(should_warn: bool, should_error: bool, config: types.GenericTestConfig) !TestResultClassification {
    if (!std.ascii.eqlIgnoreCase(config.severity, "warn") and !std.ascii.eqlIgnoreCase(config.severity, "error")) return error.UnsupportedTestExecution;
    if (std.ascii.eqlIgnoreCase(config.severity, "error") and should_error) return .{ .status = "fail", .fails_command = true, .message_kind = "fail", .condition = config.error_if };
    if (should_warn) return .{ .status = "warn", .message_kind = "warn", .condition = config.warn_if };
    return .{ .status = "pass" };
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
        if (std.mem.startsWith(u8, dependency, "model.") or std.mem.startsWith(u8, dependency, "seed.") or std.mem.startsWith(u8, dependency, "snapshot.")) {
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
    graph: *const Graph,
    selected: []const selector.SelectedResource,
    test_nodes: []const DataTestRef,
    executed_tests: []bool,
    blocked: []const []const u8,
    executed: *std.ArrayList(run_results.NodeResult),
) !void {
    for (test_nodes, 0..) |test_node, index| {
        if (executed_tests[index]) continue;
        if (!selectionContains(selected, test_node.uniqueId())) continue;
        if (!try testDependsOnAnyBlocked(allocator, graph, test_node, blocked)) continue;
        if (try scheduler.blockedParentPending(allocator, graph, test_node.dependsOn(), selected, blocked)) continue;
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
    if (!cli_options.writeJson(runtime)) return;
    const run_results_path = try pathJoin(runtime.allocator, &.{ target_dir, "run_results.json" });
    const run_results_json = try run_results.renderRunResultsForRuntime(runtime, results);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = run_results_path, .data = run_results_json });
}

fn finishEmptySelection(runtime: Runtime, target_dir: []const u8, stderr: *Io.Writer) !void {
    try @import("project/selection_warnings.zig").nothingToDo(runtime, stderr);
    if (!cli_options.writeJson(runtime)) return;
    const path = try pathJoin(runtime.allocator, &.{ target_dir, "run_results.json" });
    defer runtime.allocator.free(path);
    const artifact = try run_results.renderEmptyRunResultsForRuntime(runtime);
    defer runtime.allocator.free(artifact);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = path, .data = artifact });
}

fn commandSelection(allocator: std.mem.Allocator, candidates: []const selector.SelectedResource, command: enum { build, compile }) ![]selector.SelectedResource {
    var selected: std.ArrayList(selector.SelectedResource) = .empty;
    errdefer selected.deinit(allocator);
    for (candidates) |item| {
        const kind = item.resource_type;
        if (std.mem.eql(u8, kind, "model") or std.mem.eql(u8, kind, "seed") or std.mem.eql(u8, kind, "snapshot") or std.mem.eql(u8, kind, "test") or
            (command == .compile and (std.mem.eql(u8, kind, "analysis") or std.mem.eql(u8, kind, "operation"))) or
            (command == .build and (std.mem.eql(u8, kind, "unit_test") or std.mem.eql(u8, kind, "exposure") or std.mem.eql(u8, kind, "saved_query")))) try selected.append(allocator, item);
    }
    return selected.toOwnedSlice(allocator);
}

/// Selecting an ephemeral model is real work in Core: compile it and open the
/// execution connection, but never record a materialization result or emit the
/// warning reserved for an empty graph queue.
fn executeEphemeralSelection(runtime: Runtime, options: Options, graph: *Graph, selected: []const selector.SelectedResource, target_dir: []const u8, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    const db_path = try duckdb.databasePath(runtime.allocator, target_dir, graph);
    defer runtime.allocator.free(db_path);
    var session = try @import("project/adapter.zig").openSession(runtime, graph, db_path);
    defer session.deinit();
    var rows: std.ArrayList(run_results.NodeResult) = .empty;
    defer {
        deinitRunResults(runtime.allocator, rows.items);
        rows.deinit(runtime.allocator);
    }
    const start_failed = try @import("project/hook_operations.zig").run(runtime, graph, &session, db_path, target_dir, "on-run-start", &rows, stderr, null);
    if (!start_failed or !graph.skip_nodes_if_on_run_start_fails) _ = compileWithHost(runtime, options, graph, selected, target_dir, &rows, stderr) catch |err| {
        _ = try writeManifest(runtime, graph, target_dir);
        try writeRunResults(runtime, target_dir, rows.items);
        return err;
    };
    const end_failed = @import("project/hook_operations.zig").run(runtime, graph, &session, db_path, target_dir, "on-run-end", &rows, stderr, if (start_failed and graph.skip_nodes_if_on_run_start_fails) &.{} else null) catch |err| {
        _ = try writeManifest(runtime, graph, target_dir);
        try writeRunResults(runtime, target_dir, rows.items);
        return err;
    };
    _ = try writeManifest(runtime, graph, target_dir);
    try writeRunResults(runtime, target_dir, rows.items);
    if (start_failed or end_failed) return error.ExecutionFailure;
    try stdout.writeAll("Completed selected ephemeral model compilation\n");
}

fn deinitRunResults(allocator: std.mem.Allocator, results: []const run_results.NodeResult) void {
    for (results) |result| {
        if (result.owns_batch_results) if (result.batch_results) |batches| batches.deinit(allocator);
        if (result.owns_compiled_ctes) {
            for (result.compiled_ctes) |cte| allocator.free(cte.sql);
            allocator.free(result.compiled_ctes);
        }
        if (result.owns_compiled_code) {
            if (result.compiled_code) |compiled_code| allocator.free(compiled_code);
        }
        if (result.owns_relation_name) {
            if (result.relation_name) |relation_name| allocator.free(relation_name);
        }
        if (result.message) |message| allocator.free(message);
        if (result.owns_compiled_artifact_code) if (result.compiled_artifact_code) |sql| allocator.free(sql);
        if (result.owns_preview) if (result.preview) |preview| allocator.free(preview);
        if (result.owns_adapter_response) if (result.adapter_response) |response| {
            if (response.message) |message| allocator.free(message);
            if (response.code) |code| allocator.free(code);
        };
        if (result.owns_log_output) if (result.log_output) |messages| allocator.free(messages);
        if (result.owns_log_events) {
            for (result.log_events) |entry| allocator.free(entry.message);
            allocator.free(result.log_events);
        }
    }
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
        if (!test_node.enabled) continue;
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

fn formatTestThresholdMessage(allocator: std.mem.Allocator, failures: i64, kind: []const u8, condition: []const u8) ![]const u8 {
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

test "validateGenericTestExecution allows custom column and table tests" {
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
    try validateGenericTestExecution(&table_level_custom);
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

fn compileWithHost(runtime: Runtime, options: Options, graph: *Graph, selected: []const selector.SelectedResource, target_dir: []const u8, rows: *std.ArrayList(run_results.NodeResult), stdout: *Io.Writer) !CompileResult {
    const parallel = try @import("project/concurrent_compiler.zig").compile(runtime, graph, options, selected, target_dir, rows, stdout);
    return .{ .count = parallel.models, .snapshot_count = parallel.snapshots, .analysis_count = parallel.analyses, .test_count = parallel.tests, .saw_model = parallel.models != 0, .compiled_base = parallel.compiled_base };
}

fn compileSelectedModels(runtime: Runtime, graph: *Graph, selected: []const selector.SelectedResource, target_dir: []const u8, include_singular_tests: bool, include_analyses: bool) !CompileResult {
    return compileSelectedModelsWithResults(runtime, graph, selected, target_dir, include_singular_tests, include_analyses, null);
}

fn recordCompilation(runtime: Runtime, rows: ?*std.ArrayList(run_results.NodeResult), started: i96, result: run_results.NodeResult) !void {
    const destination = rows orelse return;
    const clock = @import("project/execution_clock.zig");
    const compiled = clock.now(runtime.io);
    var row = result;
    row.compile_started_at = started;
    row.compile_completed_at = compiled;
    if (std.mem.eql(u8, row.status, "success")) {
        row.execution_started_at = compiled;
        row.execution_completed_at = clock.now(runtime.io);
    }
    row.execution_time = @as(f64, @floatFromInt(@max(0, (row.execution_completed_at orelse compiled) - started))) / std.time.ns_per_s;
    try destination.append(runtime.allocator, row);
}

fn recordCompileError(runtime: Runtime, rows: ?*std.ArrayList(run_results.NodeResult), started: i96, result: run_results.NodeResult, err: anyerror) !void {
    if (rows == null) return;
    var row = result;
    row.status = "error";
    row.compiled_override = false;
    row.message = if (@import("project/compile_diagnostics.zig").message(err)) |message| try runtime.allocator.dupe(u8, message) else try std.fmt.allocPrint(runtime.allocator, "Compilation failed: {s}", .{@errorName(err)});
    try recordCompilation(runtime, rows, started, row);
}

fn compileSelectedModelsWithResults(runtime: Runtime, graph: *Graph, selected: []const selector.SelectedResource, target_dir: []const u8, include_singular_tests: bool, include_analyses: bool, compile_rows: ?*std.ArrayList(run_results.NodeResult)) !CompileResult {
    const clock = @import("project/execution_clock.zig");
    if (graph.database_path == null and std.mem.eql(u8, graph.adapter_type, "duckdb")) {
        for (graph.nodes.items) |node| {
            if (node.enabled and std.mem.eql(u8, node.resource_type, "snapshot")) {
                graph.database_path = try duckdb.databasePath(runtime.allocator, target_dir, graph);
                break;
            }
        }
    }
    const compiled_base = try pathJoin(runtime.allocator, &.{ target_dir, "compiled" });
    try std.Io.Dir.cwd().createDirPath(runtime.io, compiled_base);

    var compiled_count: usize = 0;
    var compiled_snapshot_count: usize = 0;
    var compiled_analysis_count: usize = 0;
    var compiled_test_count: usize = 0;
    var saw_selected_model = false;
    var saw_selected_snapshot = false;
    var saw_selected_analysis = false;
    var saw_selected_generic_test = false;
    var saw_selected_singular_test = false;
    for (graph.nodes.items) |*node| {
        if (node.enabled and std.mem.eql(u8, node.resource_type, "seed") and selectionContains(selected, node.unique_id)) {
            try recordCompilation(runtime, compile_rows, clock.now(runtime.io), .{ .node = node });
            continue;
        }
        if (!node.enabled or (!std.mem.eql(u8, node.resource_type, "model") and !std.mem.eql(u8, node.resource_type, "snapshot"))) continue;
        if (!selectionContains(selected, node.unique_id)) continue;
        if (std.mem.eql(u8, node.resource_type, "snapshot")) saw_selected_snapshot = true else saw_selected_model = true;
        if (std.mem.eql(u8, node.materialized, "ephemeral") and compile_rows == null) continue;

        if (std.mem.eql(u8, node.materialized, "incremental")) {
            try incremental_config.validateForAdapter(graph.adapter_type, node.incremental);
            const incremental_db_path = try duckdb.databasePath(runtime.allocator, target_dir, graph);
            defer runtime.allocator.free(incremental_db_path);
            node.runtime_is_incremental = try incremental.isIncremental(runtime, incremental_db_path, graph, node);
        }
        const started = clock.now(runtime.io);
        var compiled_model = compiler.compileModelWithInjectedCtes(runtime.allocator, graph, node) catch |err| {
            try recordCompileError(runtime, compile_rows, started, .{ .node = node }, err);
            return err;
        };
        errdefer compiled_model.deinit(runtime.allocator);
        const artifact_path = if (node.snapshot_yaml_definition) try std.fmt.allocPrint(runtime.allocator, "{s}/{s}.sql", .{ node.original_file_path, node.name }) else node.original_file_path;
        const compiled_path = try pathJoin(runtime.allocator, &.{ compiled_base, node.package_name, artifact_path });
        if (std.fs.path.dirname(compiled_path)) |parent| {
            try std.Io.Dir.cwd().createDirPath(runtime.io, parent);
        }
        try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = compiled_path, .data = compiled_model.compiled_code });
        const relation_name = if (std.mem.eql(u8, node.materialized, "ephemeral")) null else try compiler.relationNameForNode(runtime.allocator, graph, node);
        node.compiled = true;
        node.compiled_code = compiled_model.compiled_code;
        node.extra_ctes = compiled_model.extra_ctes;
        compiled_model.compiled_code = "";
        compiled_model.extra_ctes = .empty;
        node.compiled_path = util.normalizeForDisplay(compiled_path);
        try compiler.recordPythonScaffoldDependency(runtime.allocator, graph, node);
        node.relation_name = relation_name;
        if (!std.mem.eql(u8, node.materialized, "ephemeral")) try recordCompilation(runtime, compile_rows, started, .{ .node = node });
        if (std.mem.eql(u8, node.resource_type, "snapshot")) compiled_snapshot_count += 1 else compiled_count += 1;
    }

    if (include_analyses) {
        for (graph.nodes.items) |*node| {
            if (!node.enabled or !std.mem.eql(u8, node.resource_type, "analysis")) continue;
            if (!selectionContains(selected, node.unique_id)) continue;
            saw_selected_analysis = true;

            const started = clock.now(runtime.io);
            const compiled_code = compiler.compileModel(runtime.allocator, graph, node) catch |err| {
                try recordCompileError(runtime, compile_rows, started, .{ .node = node }, err);
                return err;
            };
            const compiled_path = try pathJoin(runtime.allocator, &.{ compiled_base, node.package_name, node.path });
            if (std.fs.path.dirname(compiled_path)) |parent| {
                try std.Io.Dir.cwd().createDirPath(runtime.io, parent);
            }
            try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = compiled_path, .data = compiled_code });
            node.compiled = true;
            node.compiled_code = compiled_code;
            node.compiled_path = util.normalizeForDisplay(compiled_path);
            try recordCompilation(runtime, compile_rows, started, .{ .node = node, .compiled_code = compiled_code });
            compiled_analysis_count += 1;
        }
    }

    if (include_singular_tests) {
        for (graph.tests.items) |*test_node| {
            if (!test_node.enabled) continue;
            if (!selectionContains(selected, test_node.unique_id)) continue;
            saw_selected_generic_test = true;
            if (isBuiltInGenericTestNode(test_node)) {
                validateGenericTestExecution(test_node) catch return error.UnsupportedCompileSelection;
            }

            const started = clock.now(runtime.io);
            const compiled = compiler.compileGenericTestWithInjectedCtes(runtime.allocator, graph, test_node) catch |err| {
                try recordCompileError(runtime, compile_rows, started, .{ .test_node = test_node }, err);
                return if (err == error.UnsupportedTestExecution) error.UnsupportedCompileSelection else err;
            };
            const compiled_code = compiled.compiled_code;
            const compiled_path = try pathJoin(runtime.allocator, &.{ compiled_base, test_node.package_name, test_node.path });
            if (std.fs.path.dirname(compiled_path)) |parent| {
                try std.Io.Dir.cwd().createDirPath(runtime.io, parent);
            }
            try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = compiled_path, .data = compiled_code });
            test_node.compiled = true;
            test_node.compiled_code = compiled_code;
            test_node.compiled_path = util.normalizeForDisplay(compiled_path);
            test_node.extra_ctes = compiled.extra_ctes;
            try compiler.recordGenericCompilationDependency(runtime.allocator, graph, test_node);
            try recordCompilation(runtime, compile_rows, started, .{ .test_node = test_node, .compiled_code = compiled_code });
            compiled_test_count += 1;
        }
        for (graph.singular_tests.items) |*test_node| {
            if (!test_node.enabled or !selectionContains(selected, test_node.unique_id)) continue;
            saw_selected_singular_test = true;

            const started = clock.now(runtime.io);
            const compiled = compiler.compileSingularTestWithInjectedCtes(runtime.allocator, graph, test_node) catch |err| {
                try recordCompileError(runtime, compile_rows, started, .{ .singular_test_node = test_node }, err);
                return err;
            };
            const compiled_code = compiled.compiled_code;
            const compiled_path = try pathJoin(runtime.allocator, &.{ compiled_base, test_node.package_name, test_node.original_file_path });
            if (std.fs.path.dirname(compiled_path)) |parent| {
                try std.Io.Dir.cwd().createDirPath(runtime.io, parent);
            }
            try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = compiled_path, .data = compiled_code });
            test_node.compiled = true;
            test_node.compiled_code = compiled_code;
            test_node.compiled_path = util.normalizeForDisplay(compiled_path);
            test_node.extra_ctes = compiled.extra_ctes;
            try recordCompilation(runtime, compile_rows, started, .{ .singular_test_node = test_node, .compiled_code = compiled_code });
            compiled_test_count += 1;
        }
    }

    return .{
        .count = compiled_count,
        .analysis_count = compiled_analysis_count,
        .test_count = compiled_test_count,
        .saw_model = saw_selected_model,
        .saw_snapshot = saw_selected_snapshot,
        .snapshot_count = compiled_snapshot_count,
        .saw_analysis = saw_selected_analysis,
        .saw_generic_test = saw_selected_generic_test,
        .saw_singular_test = saw_selected_singular_test,
        .compiled_base = compiled_base,
    };
}

fn writeManifest(runtime: Runtime, graph: *const Graph, target_dir: []const u8) ![]const u8 {
    return writeManifestWithPolicy(runtime, graph, target_dir, cli_options.writeJson(runtime));
}

fn writeManifestWithPolicy(runtime: Runtime, graph: *const Graph, target_dir: []const u8, should_write: bool) ![]const u8 {
    const manifest_path = try pathJoin(runtime.allocator, &.{ target_dir, "manifest.json" });
    if (!should_write) return manifest_path;
    const manifest_json = try manifest.renderManifest(runtime.allocator, graph);
    try std.Io.Dir.cwd().createDirPath(runtime.io, target_dir);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = manifest_path, .data = manifest_json });
    const semantic_path = try pathJoin(runtime.allocator, &.{ target_dir, "semantic_manifest.json" });
    defer runtime.allocator.free(semantic_path);
    const semantic_json = try @import("project/semantic.zig").renderManifest(runtime.allocator, graph);
    defer runtime.allocator.free(semantic_json);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = semantic_path, .data = semantic_json });
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
    try appendSkippedAfterExecutionFailure(allocator, &graph, &selected, &remaining, &tests, "model.demo.customers", &executed);

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
    try appendSkippedAfterExecutionFailure(allocator, &graph, &selected, &remaining, &.{}, "model.demo.customers", &executed);

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

    try std.testing.expect(try appendSkippedIfNodeDependsOnBlocked(allocator, &graph, &blocked, &graph.nodes.items[1], &executed));
    try std.testing.expect(!try appendSkippedIfNodeDependsOnBlocked(allocator, &graph, &blocked, &graph.nodes.items[2], &executed));
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
    try appendSkippedBlockedDataTests(allocator, &graph, &selected, &tests, &executed_tests, &blocked, &executed);

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
    try appendSkippedAfterDataTestFailure(allocator, &graph, &selected, &remaining, &tests, &executed_tests, &blocked_roots, &executed);

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

    try std.testing.expect(!try scheduler.dependenciesCompleted(allocator, &graph, test_ref.dependsOn(), null, &only_seed_done));
    try std.testing.expect(try scheduler.dependenciesCompleted(allocator, &graph, test_ref.dependsOn(), null, &all_done));
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
    try std.testing.expectEqual(@as(i64, 2), property.config.limit.?);
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
    try std.testing.expectEqual(@as(i64, 1), patched.config.limit.?);
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

    try @import("project/semantic.zig").parseProperties(runtime, text, resource_root, relative_path, package_name, graph);
    try snapshot_yaml.parseProperties(runtime, text, resource_root, relative_path, package_name, graph);
    try parseExposuresFromText(runtime.allocator, text, resource_root, relative_path, package_name, graph);
    try @import("project/unit_yaml.zig").parseWithRuntime(runtime, text, resource_root, relative_path, package_name, graph);
    var properties_document = try @import("project/yaml.zig").parse(runtime.allocator, text);
    defer properties_document.deinit();
    try @import("project/group_access.zig").parse(runtime, properties_document.value, resource_root, relative_path, package_name, graph);
    try @import("project/source_properties.zig").parse(runtime, properties_document.value, relative_path, package_name, graph);
    try @import("project/properties.zig").parseModels(runtime, properties_document.value, relative_path, package_name, graph);
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
    var persist_docs_indent: ?usize = null;
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

    var incremental_list_key: ?[]const u8 = null;
    var incremental_list_indent: usize = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);
        if (incremental_list_key) |key| {
            if (indent > incremental_list_indent and std.mem.startsWith(u8, trimmed, "- ")) {
                const property = &graph.model_properties.items[current_model orelse return error.UnsupportedYaml];
                const value = try dupTrimmedScalar(allocator, trimmed[2..]);
                if (std.mem.eql(u8, key, "unique_key")) {
                    try property.incremental.unique_key.?.list.append(allocator, value);
                } else try property.incremental.predicates.append(allocator, value);
                continue;
            }
            incremental_list_key = null;
        }

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

            if (persist_docs_indent) |docs_indent| {
                if (indent > docs_indent) {
                    var docs = graph.model_properties.items[model_index].persist_docs orelse types.PersistDocs{};
                    if (std.mem.eql(u8, kv.key, "relation")) docs.relation = try parseBool(kv.value) else if (std.mem.eql(u8, kv.key, "columns")) docs.columns = try parseBool(kv.value) else return error.UnsupportedYaml;
                    graph.model_properties.items[model_index].persist_docs = docs;
                    continue;
                }
                persist_docs_indent = null;
            }
            if (in_config and indent > config_indent) {
                if (std.mem.eql(u8, active_resource_type, "snapshot") and in_columns and current_column != null) continue;
                if (std.mem.eql(u8, active_resource_type, "model") and try incremental_config.applyYaml(allocator, &graph.model_properties.items[model_index].incremental, kv.key, kv.value)) {
                    if (std.mem.trim(u8, kv.value, " \t").len == 0 and (std.mem.eql(u8, kv.key, "unique_key") or std.mem.eql(u8, kv.key, "predicates") or std.mem.eql(u8, kv.key, "incremental_predicates"))) {
                        incremental_list_key = kv.key;
                        incremental_list_indent = indent;
                    }
                    continue;
                }

                if (std.mem.eql(u8, kv.key, "persist_docs")) {
                    if (std.mem.trim(u8, kv.value, " \t").len != 0) return error.UnsupportedYaml;
                    persist_docs_indent = indent;
                    graph.model_properties.items[model_index].persist_docs = .{};
                    continue;
                }
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
                if (std.mem.eql(u8, active_resource_type, "snapshot") and in_columns and current_column != null) continue;
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
        property.config.markConfigured(.where);
        property.config.where = try dupTrimmedScalar(allocator, value);
        return true;
    }
    if (std.mem.eql(u8, key, "limit")) {
        const limit_text = try dupTrimmedScalar(allocator, value);
        defer allocator.free(limit_text);
        property.config.markConfigured(.limit);
        property.config.limit = std.fmt.parseInt(i64, limit_text, 10) catch return error.UnsupportedYaml;
        return true;
    }
    if (std.mem.eql(u8, key, "severity")) {
        property.config.markConfigured(.severity);
        property.config.severity = try dupNormalizedSingularTestSeverity(allocator, value);
        return true;
    }
    if (std.mem.eql(u8, key, "warn_if")) {
        property.config.markConfigured(.warn_if);
        property.config.warn_if = try dupTrimmedScalar(allocator, value);
        return true;
    }
    if (std.mem.eql(u8, key, "error_if")) {
        property.config.markConfigured(.error_if);
        property.config.error_if = try dupTrimmedScalar(allocator, value);
        return true;
    }
    if (std.mem.eql(u8, key, "store_failures")) {
        property.config.markConfigured(.store_failures);
        property.config.store_failures = try parseBool(value);
        return true;
    }
    inline for (.{ "store_failures_as", "schema", "alias", "database", "fail_calc" }) |name| {
        if (std.mem.eql(u8, key, name)) {
            var document = try @import("project/yaml.zig").parse(allocator, value);
            defer document.deinit();
            property.config.markConfigured(@field(types.GenericTestConfigField, name));
            if (comptime std.mem.eql(u8, name, "fail_calc")) {
                if (document.value != .string) return error.InvalidGenericTestConfiguration;
                property.config.fail_calc = try allocator.dupe(u8, document.value.string);
            } else {
                @field(property.config, name) = if (document.value == .null) null else if (document.value == .string) try allocator.dupe(u8, document.value.string) else return error.InvalidGenericTestConfiguration;
            }
            return true;
        }
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

// dbt parser/read_files.py strips source contents before storing raw_code and
// computing checksums. Preserve inner whitespace while dropping file padding.
fn readSourceCode(runtime: Runtime, path: []const u8) ![]const u8 {
    const contents = try std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(16 * 1024 * 1024));
    defer runtime.allocator.free(contents);
    return try runtime.allocator.dupe(u8, std.mem.trim(u8, contents, " \t\r\n\x0b\x0c"));
}

fn parseModel(runtime: Runtime, project_dir: []const u8, model_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    const full_path = try pathJoin(runtime.allocator, &.{ project_dir, relative_path });
    const sql = try readSourceCode(runtime, full_path);
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
        .language = if (std.mem.endsWith(u8, relative_path, ".py")) "python" else "sql",
    };
    errdefer {
        deinitNode(runtime.allocator, &node);
    }
    if (std.mem.eql(u8, node.language, "python")) {
        node.raw_code = std.mem.trim(u8, sql, " \t\r\n");
        try @import("project/python_model.zig").scan(runtime.allocator, node.raw_code, &node);
    } else try compiler.scanDependencies(runtime.allocator, sql, &node, graph);
    try graph.nodes.append(runtime.allocator, node);
}

fn parseAnalysis(runtime: Runtime, project_dir: []const u8, analysis_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    const full_path = try pathJoin(runtime.allocator, &.{ project_dir, relative_path });
    const sql = try readSourceCode(runtime, full_path);
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
    };
    errdefer deinitNode(runtime.allocator, &node);
    try compiler.scanDependencies(runtime.allocator, sql, &node, graph);
    try graph.nodes.append(runtime.allocator, node);
}

fn parseSingularTest(runtime: Runtime, project_dir: []const u8, test_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    const full_path = try pathJoin(runtime.allocator, &.{ project_dir, relative_path });
    const sql = try readSourceCode(runtime, full_path);
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
    try compiler.scanDependencies(runtime.allocator, sql, &scan_node, graph);

    var test_node = SingularTestNode{
        .package_name = package_name,
        .unique_id = unique_id,
        .name = test_name,
        .alias = test_name,
        .path = test_path,
        .original_file_path = relative_path,
        .raw_code = sql,
        .config = try @import("project/resource_config.zig").cloneTestConfig(runtime.allocator, scan_node.test_config),
        .config_values = try @import("project/config_value.zig").clone(runtime.allocator, scan_node.effective_config),
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

fn findNodeIndexByUniqueId(graph: *const Graph, unique_id: []const u8) ?usize {
    for (graph.nodes.items, 0..) |node, index| if (std.mem.eql(u8, node.unique_id, unique_id)) return index;
    return null;
}

fn applyModelProperties(graph: *Graph, package_name: []const u8) !void {
    for (graph.model_properties.items) |property| {
        if (!std.mem.eql(u8, property.package_name, package_name)) continue;
        const node_index = (if (property.assigned_unique_id) |unique_id| findNodeIndexByUniqueId(graph, unique_id) else findNodeIndexByResourceTypeAndName(graph, property.package_name, property.resource_type, property.name)) orelse {
            try graph.unmatched_model_properties.append(graph.allocator, .{ .resource_type = property.resource_type, .name = property.name, .patch_path = property.patch_path });
            continue;
        };
        var node = &graph.nodes.items[node_index];
        node.patch_path = property.patch_path;
        if (property.persist_docs) |docs| {
            var current = node.persist_docs orelse types.PersistDocs{};
            current.relation = current.relation orelse docs.relation;
            current.columns = current.columns orelse docs.columns;
            node.persist_docs = current;
        }
        if (property.properties != .null) {
            @import("project/config_value.zig").deinit(graph.allocator, &node.properties);
            node.properties = try @import("project/config_value.zig").clone(graph.allocator, property.properties);
        }
        if (property.config_values != .null) {
            try @import("project/resource_config.zig").mergeAuthored(graph.allocator, &node.property_config, property.config_values);
            const raw_config = @import("project/config_value.zig").get(property.properties, "config") orelse .null;
            try @import("project/config_value.zig").overlay(graph.allocator, &node.property_raw_config, raw_config);
            for ([_][]const u8{ "meta", "docs", "tags", "group", "access", "contract" }) |key| if (@import("project/config_value.zig").get(property.properties, key)) |value| {
                try @import("project/config_value.zig").put(graph.allocator, &node.property_raw_config, key, value);
            };
            try @import("project/resource_config.zig").rebuild(graph.allocator, node);
        }
        if (property.description.len != 0) node.description = try resolveDocDescription(graph, property.package_name, property.description, &node.doc_blocks);
        if (std.mem.eql(u8, node.resource_type, "model") and property.materialized.len != 0 and !node.inline_materialized) node.materialized = property.materialized;
        if (std.mem.eql(u8, node.resource_type, "model")) try incremental_config.overlay(graph.allocator, &node.incremental, property.incremental, node.inline_incremental);
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
        if (property.properties == .null) sortStrings(node.tags.items);
        for (property.tests.items) |test_def| {
            try appendGenericTestDefClone(graph, &node.tests, test_def);
        }
        sortGenericTestDefs(node.tests.items);
        for (property.columns.items) |column| {
            try appendColumnClone(graph, property.package_name, &node.columns, column);
        }
        // Core preserves YAML column order for model contracts and the
        // generated INSERT projection. Legacy line-reader fixtures retain
        // their previous deterministic sorting.
        if (property.properties == .null) sortColumns(node.columns.items);
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
        inline for (std.meta.fields(types.GenericTestConfigField)) |field| {
            const key = @field(types.GenericTestConfigField, field.name);
            if (property.config.configured.contains(key) and !test_node.config.configured.contains(key)) {
                @field(test_node.config, field.name) = @field(property.config, field.name);
                test_node.config.markConfigured(key);
            }
        }
        if (test_node.config.alias) |alias| test_node.alias = alias;
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
        if (!std.mem.eql(u8, node.resource_type, "model") and !std.mem.eql(u8, node.resource_type, "seed") and !std.mem.eql(u8, node.resource_type, "snapshot")) continue;
        for (node.tests.items) |test_def| {
            if (isSupportedGenericTest(test_def, null)) {
                try appendGenericTestNode(graph, node, test_def, null);
            } else if (try nodeColumnCustomGenericTestDef(graph, node, test_def, null)) |custom_test_def| {
                try appendGenericTestNode(graph, node, custom_test_def, null);
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
            if (isSupportedSourceGenericTest(test_def, null)) {
                try appendSourceGenericTestNode(graph, source, test_def, null);
            } else if (try sourceColumnCustomGenericTestDef(graph, source, test_def, null)) |custom_test_def| {
                try appendSourceGenericTestNode(graph, source, custom_test_def, null);
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
    const names = try synthesizeGenericTestNames(graph.allocator, test_def, if (node.version == .null) node.name else node.default_alias orelse node.name, effective_column_name);
    const model_kwarg = try @import("project/model_versions.zig").modelKwarg(graph.allocator, node);
    defer graph.allocator.free(model_kwarg);
    const unique_id = try genericTestUniqueIdForModelKwarg(graph.allocator, node.package_name, names.full, test_def, model_kwarg, effective_column_name);
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
        .alias = test_def.config.alias orelse names.compiled,
        .path = try std.fmt.allocPrint(graph.allocator, "{s}.sql", .{names.compiled}),
        .original_file_path = node.patch_path orelse node.original_file_path,
        .raw_code = raw_code,
        .test_name = test_def.name,
        .arguments = try @import("project/config_value.zig").clone(graph.allocator, test_def.arguments),
        .builder_config = try @import("project/config_value.zig").clone(graph.allocator, test_def.config_values),
        .description = test_def.description,
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
    try appendGenericTestMacroDependency(graph, &test_node, test_def);
    if (isBuiltInGenericTestNode(&test_node) and std.mem.eql(u8, test_def.name, "relationships")) {
        if (isSourceRelationshipTarget(test_def.relationship_to)) {
            const target_source = try sourceDepFromValue(graph.allocator, test_def.relationship_to);
            test_node.relationship_source_to = target_source;
            try appendSourceDepUnique(graph.allocator, &test_node.source_refs, target_source);
        } else {
            const target_ref = try refDepFromValue(graph.allocator, test_def.relationship_to);
            try test_node.refs.append(graph.allocator, target_ref);
        }
    }
    try test_node.refs.append(graph.allocator, .{ .package = null, .name = node.name, .version = try @import("project/config_value.zig").clone(graph.allocator, node.version) });
    try appendUnique(graph.allocator, &test_node.depends_on, node.unique_id);
    if (isBuiltInGenericTestNode(&test_node) and (node.version != .null or (!std.mem.eql(u8, test_def.name, "not_null") and !std.mem.eql(u8, test_def.name, "unique")))) {
        try test_node.macro_depends_on.append(graph.allocator, "macro.dbt.get_where_subquery");
    }
    if (column_name) |name| for (node.columns.items) |column| if (std.mem.eql(u8, column.name, name)) {
        try test_node.tags.appendSlice(graph.allocator, column.tags.items);
    };
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
        .arguments = test_def.arguments,
        .config_values = test_def.config_values,
        .custom_name = test_def.custom_name,
        .description = test_def.description,
        .namespace = test_def.namespace,
        .column_name = test_def.column_name,
        .accepted_values = test_def.accepted_values,
        .accepted_values_quote = test_def.accepted_values_quote,
        .relationship_to = test_def.relationship_to,
        .relationship_field = test_def.relationship_field,
        .config = test_def.config,
    };
    const names = try synthesizeGenericTestNames(graph.allocator, source_test_def, source_target_name, effective_column_name);
    // Source prefixes belong to node names; dbt hashes the original test metadata.
    const unique_id = try genericTestUniqueIdForModelKwarg(graph.allocator, source.package_name, names.full, test_def, source_model_kwarg, effective_column_name);
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
        .alias = test_def.config.alias orelse names.compiled,
        .path = try std.fmt.allocPrint(graph.allocator, "{s}.sql", .{names.compiled}),
        .original_file_path = source.original_file_path,
        .raw_code = raw_code,
        .test_name = test_def.name,
        .arguments = try @import("project/config_value.zig").clone(graph.allocator, test_def.arguments),
        .builder_config = try @import("project/config_value.zig").clone(graph.allocator, test_def.config_values),
        .description = test_def.description,
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
    try appendGenericTestMacroDependency(graph, &test_node, test_def);
    if (isBuiltInGenericTestNode(&test_node) and std.mem.eql(u8, test_def.name, "relationships")) {
        if (isSourceRelationshipTarget(test_def.relationship_to)) {
            const target_source = try sourceDepFromValue(graph.allocator, test_def.relationship_to);
            test_node.relationship_source_to = target_source;
            try appendSourceDepUnique(graph.allocator, &test_node.source_refs, target_source);
            try appendSourceDepUnique(graph.allocator, &test_node.source_refs, attached_source_dep);
            try appendUnique(graph.allocator, &test_node.depends_on, source.unique_id);
        } else {
            try appendSourceDepUnique(graph.allocator, &test_node.source_refs, attached_source_dep);
            try appendUnique(graph.allocator, &test_node.depends_on, source.unique_id);
            const target_ref = try refDepFromValue(graph.allocator, test_def.relationship_to);
            try test_node.refs.append(graph.allocator, target_ref);
        }
    } else {
        try appendSourceDepUnique(graph.allocator, &test_node.source_refs, attached_source_dep);
        try appendUnique(graph.allocator, &test_node.depends_on, source.unique_id);
    }
    if (isBuiltInGenericTestNode(&test_node) and !std.mem.eql(u8, test_def.name, "not_null") and !std.mem.eql(u8, test_def.name, "unique")) {
        try test_node.macro_depends_on.append(graph.allocator, "macro.dbt.get_where_subquery");
    }
    if (column_name) |name| for (source.columns.items) |column| if (std.mem.eql(u8, column.name, name)) {
        try test_node.tags.appendSlice(graph.allocator, column.tags.items);
    };
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

fn isBuiltInGenericTestNode(test_node: *const GenericTestNode) bool {
    if (!isBuiltInGenericTestName(test_node.test_name)) return false;
    for (test_node.macro_depends_on.items) |macro| {
        const dot = std.mem.lastIndexOfScalar(u8, macro, '.') orelse continue;
        if (std.mem.startsWith(u8, macro[dot + 1 ..], "test_") and !std.mem.startsWith(u8, macro, "macro.dbt.")) return false;
    }
    return true;
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
    _ = column_name;
    if (isBuiltInGenericTestName(test_def.name)) return error.InvalidGenericTestConfiguration;
    if (!std.mem.eql(u8, node.resource_type, "model") and !std.mem.eql(u8, node.resource_type, "seed") and !std.mem.eql(u8, node.resource_type, "snapshot")) return null;

    return try columnCustomGenericTestDef(graph, node.package_name, test_def);
}

fn sourceColumnCustomGenericTestDef(graph: *const Graph, source: *const SourceDef, test_def: GenericTestDef, column_name: ?[]const u8) !?GenericTestDef {
    _ = column_name;
    if (isBuiltInGenericTestName(test_def.name)) return error.InvalidGenericTestConfiguration;

    return try columnCustomGenericTestDef(graph, source.package_name, test_def);
}

fn columnCustomGenericTestDef(graph: *const Graph, package_name: []const u8, test_def: GenericTestDef) !?GenericTestDef {
    const namespace_parts = try splitGenericTestNamespace(test_def.name);
    const macro_package = if (namespace_parts) |parts| parts.namespace else package_name;
    const macro_test_name = if (namespace_parts) |parts| parts.name else test_def.name;

    const macro_name = try std.fmt.allocPrint(graph.allocator, "test_{s}", .{macro_test_name});
    defer graph.allocator.free(macro_name);
    const macro_id = if (namespace_parts != null) findMacroIdByPackageAndName(graph, macro_package, macro_name) else project_resolve.findMacroIdForUnqualifiedNamespaceCall(graph, package_name, macro_name);
    if (macro_id == null and !(std.mem.eql(u8, macro_package, "dbt") and isBuiltInGenericTestName(macro_test_name))) return error.UnresolvedMacro;

    return GenericTestDef{
        .name = macro_test_name,
        .arguments = test_def.arguments,
        .config_values = test_def.config_values,
        .custom_name = test_def.custom_name,
        .description = test_def.description,
        .accepted_values = test_def.accepted_values,
        .namespace = if (namespace_parts) |parts| parts.namespace else null,
        .column_name = test_def.column_name,
        .accepted_values_quote = test_def.accepted_values_quote,
        .relationship_to = test_def.relationship_to,
        .relationship_field = test_def.relationship_field,
        .config = test_def.config,
    };
}

fn appendGenericTestMacroDependency(graph: *Graph, test_node: *GenericTestNode, test_def: GenericTestDef) !void {
    const macro_name = try std.fmt.allocPrint(graph.allocator, "test_{s}", .{test_def.name});
    defer graph.allocator.free(macro_name);
    const macro_id = if (test_def.namespace) |package|
        findMacroIdByPackageAndName(graph, package, macro_name)
    else
        project_resolve.findMacroIdForUnqualifiedNamespaceCall(graph, test_node.package_name, macro_name);
    if (macro_id) |resolved| {
        try test_node.macro_depends_on.append(graph.allocator, resolved);
        if (!std.mem.startsWith(u8, resolved, "macro.dbt.")) try test_node.macro_depends_on.append(graph.allocator, "macro.dbt.get_where_subquery");
    } else if (isBuiltInGenericTestName(test_def.name) and (test_def.namespace == null or std.mem.eql(u8, test_def.namespace.?, "dbt"))) {
        try test_node.macro_depends_on.append(graph.allocator, try std.fmt.allocPrint(graph.allocator, "macro.dbt.test_{s}", .{test_def.name}));
    } else return error.UnresolvedMacro;
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

fn writeWarnings(runtime: Runtime, stderr: *Io.Writer, graph: *const Graph) !void {
    for (graph.tests.items) |test_node| for (test_node.reference_warnings.items) |warning| try @import("project/selection_warnings.zig").warning(runtime, stderr, "NodeNotFoundOrDisabled", "I060", warning, null);
    if (graph.command_options.debug or graph.command_options.log_level == .debug) {
        try stderr.writeAll("{\"data\":{\"hit\":");
        try std.json.Stringify.value(graph.parser_cache_hit, .{}, stderr);
        try stderr.writeAll(",\"reason\":");
        try std.json.Stringify.value(graph.parser_cache_reason, .{}, stderr);
        try stderr.print(",\"changed_files\":{d},\"reused_files\":{d}}},\"info\":{{\"name\":\"NativeParseCache\",\"level\":\"debug\",\"thread\":\"MainThread\",\"ts\":", .{ graph.parser_cache_changes, graph.parser_cache_reused_files });
        try execution_clock.writeTimestamp(stderr, execution_clock.now(runtime.io));
        try stderr.writeAll("}}\n");
    }
    if (graph.unmatched_model_properties.items.len != 0 and try cli_options.warningIsError(runtime, "NoNodeForYamlKey")) return error.ParsingWarningAsError;
    if (graph.unmatched_macro_properties.items.len != 0 and try cli_options.warningIsError(runtime, "MacroNotFoundForPatch")) return error.ParsingWarningAsError;
    if (graph.macro_argument_warnings.items.len != 0 and try cli_options.warningIsError(runtime, "InvalidMacroAnnotation")) return error.ParsingWarningAsError;
    if (graph.constraint_warnings.items.len != 0 and try cli_options.warningIsError(runtime, "UnsupportedConstraintMaterialization")) return error.ParsingWarningAsError;
    for (graph.unmatched_model_properties.items) |property| {
        if (!try cli_options.warningIsSilenced(runtime, "NoNodeForYamlKey")) try stderr.print("warning: did not find matching {s} node for property `{s}` in {s}\n", .{ property.resource_type, property.name, util.normalizeForDisplay(property.patch_path) });
    }
    for (graph.unmatched_macro_properties.items) |property| {
        if (!try cli_options.warningIsSilenced(runtime, "MacroNotFoundForPatch")) try stderr.print("warning: did not find matching macro for macro property `{s}` in {s}\n", .{ property.name, util.normalizeForDisplay(property.patch_path) });
    }
    for (graph.macro_argument_warnings.items) |warning| {
        if (!try cli_options.warningIsSilenced(runtime, "InvalidMacroAnnotation")) try stderr.print("warning: {s}\n", .{warning});
    }
    for (graph.constraint_warnings.items) |warning| {
        if (!try cli_options.warningIsSilenced(runtime, "UnsupportedConstraintMaterialization")) try stderr.print("warning: {s}\n", .{warning});
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
            if (source.properties != .null) {
                @import("project/config_value.zig").deinit(graph.allocator, &existing.properties);
                existing.properties = try @import("project/config_value.zig").clone(graph.allocator, source.properties);
                existing.data_type = source.data_type;
                existing.quote = source.quote;
                existing.description = "";
                existing.doc_blocks.clearRetainingCapacity();
                existing.tags.clearRetainingCapacity();
                try existing.tags.appendSlice(graph.allocator, source.tags.items);
            }
            if (source.description.len != 0) existing.description = try resolveDocDescription(graph, package_name, source.description, &existing.doc_blocks);
            for (source.tests.items) |test_def| {
                try appendGenericTestDefClone(graph, &existing.tests, test_def);
            }
            sortGenericTestDefs(existing.tests.items);
            return;
        }
    }

    var column = ColumnDef{ .name = source.name, .data_type = source.data_type, .quote = source.quote, .properties = try @import("project/config_value.zig").clone(graph.allocator, source.properties) };
    try column.tags.appendSlice(graph.allocator, source.tags.items);
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
