const std = @import("std");
const project_config = @import("config.zig");
const project_fs = @import("fs.zig");
const project_parse = @import("parse.zig");
const project_resolve = @import("resolve.zig");
const types = @import("types.zig");
const util = @import("util.zig");

const Runtime = types.Runtime;
const Graph = types.Graph;
const loadProjectConfig = project_config.loadProjectConfig;
const deinitProjectConfig = types.deinitProjectConfig;
const applyProjectModelPathConfigs = project_config.applyProjectModelPathConfigs;
const applyProjectSeedDocs = project_config.applyProjectSeedDocs;
const parseVarsText = project_config.parseVarsText;
const discoverChildDirectories = project_fs.discoverChildDirectories;
const discoverProjectFiles = project_fs.discoverProjectFiles;
const discoverSeedFiles = project_fs.discoverSeedFiles;
const discoverMacroFiles = project_fs.discoverMacroFiles;
const pathJoin = project_fs.pathJoin;
const sortStrings = util.sortStrings;
const applyMacroProperties = project_parse.applyMacroProperties;
const sortGraphResources = project_resolve.sortGraphResources;
const rejectDuplicateDocs = project_resolve.rejectDuplicateDocs;
const rejectDuplicateExposures = project_resolve.rejectDuplicateExposures;
const rejectDuplicateMacroProperties = project_resolve.rejectDuplicateMacroProperties;
const rejectDuplicateMacros = project_resolve.rejectDuplicateMacros;
const rejectDuplicateModels = project_resolve.rejectDuplicateModels;
const rejectDuplicateSeeds = project_resolve.rejectDuplicateSeeds;

pub const Callbacks = struct {
    parse_doc_blocks: *const fn (Runtime, []const u8, []const u8, []const u8, []const u8, *Graph) anyerror!void,
    parse_yaml_properties: *const fn (Runtime, []const u8, []const u8, []const u8, []const u8, *Graph) anyerror!void,
    parse_macros: *const fn (Runtime, []const u8, []const u8, []const u8, *Graph) anyerror!void,
    parse_model: *const fn (Runtime, []const u8, []const u8, []const u8, []const u8, *Graph) anyerror!void,
    parse_seed: *const fn (Runtime, []const u8, []const u8, []const u8, *Graph) anyerror!void,
    apply_model_properties: *const fn (*Graph, []const u8) anyerror!void,
    materialize_generic_tests: *const fn (*Graph) anyerror!void,
    resolve_macro_dependencies: *const fn (*Graph) anyerror!void,
};

pub fn graphDefaultTarget(runtime: Runtime, project_dir: []const u8) ![]const u8 {
    var config = try loadProjectConfig(runtime, project_dir);
    defer deinitProjectConfig(runtime.allocator, &config);
    return config.target_path;
}

pub fn loadGraph(runtime: Runtime, project_dir: []const u8, cli_vars: ?[]const u8, callbacks: Callbacks) !Graph {
    var config = try loadProjectConfig(runtime, project_dir);
    defer deinitProjectConfig(runtime.allocator, &config);

    var graph = Graph{ .allocator = runtime.allocator, .project_name = config.name };
    errdefer graph.deinit();
    try graph.vars.appendSlice(runtime.allocator, config.vars.items);
    if (cli_vars) |vars_text| {
        try parseVarsText(runtime.allocator, vars_text, &graph.vars);
    }

    try loadProjectMacros(runtime, project_dir, config.name, config.macro_paths.items, true, callbacks, &graph);
    try loadInstalledPackageMacros(runtime, project_dir, callbacks, &graph);
    try loadInstalledPackageResources(runtime, project_dir, callbacks, &graph);

    for (config.model_paths.items) |model_path| {
        var sql_files: std.ArrayList([]const u8) = .empty;
        defer sql_files.deinit(runtime.allocator);
        var yaml_files: std.ArrayList([]const u8) = .empty;
        defer yaml_files.deinit(runtime.allocator);
        var md_files: std.ArrayList([]const u8) = .empty;
        defer md_files.deinit(runtime.allocator);

        const root = try pathJoin(runtime.allocator, &.{ project_dir, model_path });
        discoverProjectFiles(runtime, root, model_path, &sql_files, &yaml_files, &md_files) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        sortStrings(sql_files.items);
        sortStrings(yaml_files.items);
        sortStrings(md_files.items);

        for (md_files.items) |md_path| {
            try callbacks.parse_doc_blocks(runtime, project_dir, model_path, md_path, config.name, &graph);
        }
        for (yaml_files.items) |yaml_path| {
            try callbacks.parse_yaml_properties(runtime, project_dir, model_path, yaml_path, config.name, &graph);
        }
        for (sql_files.items) |sql_path| {
            try callbacks.parse_model(runtime, project_dir, model_path, sql_path, config.name, &graph);
        }
    }

    try applyProjectModelPathConfigs(&graph, config.model_path_configs.items, true, null);

    for (config.seed_paths.items) |seed_path| {
        var seed_files: std.ArrayList([]const u8) = .empty;
        defer seed_files.deinit(runtime.allocator);

        const root = try pathJoin(runtime.allocator, &.{ project_dir, seed_path });
        discoverSeedFiles(runtime, root, seed_path, &seed_files) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        sortStrings(seed_files.items);

        for (seed_files.items) |relative_path| {
            try callbacks.parse_seed(runtime, seed_path, relative_path, config.name, &graph);
        }
    }
    applyProjectSeedDocs(&graph, config.name, config.seed_docs);

    try rejectDuplicateMacroProperties(&graph);
    try applyMacroProperties(&graph);
    try callbacks.apply_model_properties(&graph, config.name);
    try callbacks.materialize_generic_tests(&graph);
    sortGraphResources(&graph);
    try rejectDuplicateModels(&graph);
    try rejectDuplicateSeeds(&graph);
    try rejectDuplicateDocs(&graph);
    try rejectDuplicateExposures(&graph);
    try rejectDuplicateMacros(&graph);
    try callbacks.resolve_macro_dependencies(&graph);
    return graph;
}

fn loadProjectMacros(runtime: Runtime, project_dir: []const u8, package_name: []const u8, macro_paths: []const []const u8, parse_properties: bool, callbacks: Callbacks, graph: *Graph) !void {
    for (macro_paths) |macro_path| {
        var macro_files: std.ArrayList([]const u8) = .empty;
        defer macro_files.deinit(runtime.allocator);
        var macro_yaml_files: std.ArrayList([]const u8) = .empty;
        defer macro_yaml_files.deinit(runtime.allocator);

        const root = try pathJoin(runtime.allocator, &.{ project_dir, macro_path });
        discoverMacroFiles(runtime, root, macro_path, &macro_files, &macro_yaml_files) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        sortStrings(macro_files.items);
        sortStrings(macro_yaml_files.items);

        if (parse_properties) {
            for (macro_yaml_files.items) |yaml_path| {
                try callbacks.parse_yaml_properties(runtime, project_dir, macro_path, yaml_path, package_name, graph);
            }
        }
        for (macro_files.items) |relative_path| {
            try callbacks.parse_macros(runtime, project_dir, relative_path, package_name, graph);
        }
    }
}

fn loadInstalledPackageMacros(runtime: Runtime, project_dir: []const u8, callbacks: Callbacks, graph: *Graph) !void {
    const packages_dir = try pathJoin(runtime.allocator, &.{ project_dir, "dbt_packages" });
    var package_dirs: std.ArrayList([]const u8) = .empty;
    defer package_dirs.deinit(runtime.allocator);

    discoverChildDirectories(runtime, packages_dir, &package_dirs) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    sortStrings(package_dirs.items);

    for (package_dirs.items) |package_dir| {
        var package_config = loadProjectConfig(runtime, package_dir) catch |err| switch (err) {
            error.MissingProjectFile => continue,
            else => return err,
        };
        defer deinitProjectConfig(runtime.allocator, &package_config);

        try loadProjectMacros(runtime, package_dir, package_config.name, package_config.macro_paths.items, true, callbacks, graph);
    }
}

fn loadInstalledPackageResources(runtime: Runtime, project_dir: []const u8, callbacks: Callbacks, graph: *Graph) !void {
    const packages_dir = try pathJoin(runtime.allocator, &.{ project_dir, "dbt_packages" });
    var package_dirs: std.ArrayList([]const u8) = .empty;
    defer package_dirs.deinit(runtime.allocator);

    discoverChildDirectories(runtime, packages_dir, &package_dirs) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    sortStrings(package_dirs.items);

    for (package_dirs.items) |package_dir| {
        var package_config = loadProjectConfig(runtime, package_dir) catch |err| switch (err) {
            error.MissingProjectFile => continue,
            else => return err,
        };
        defer deinitProjectConfig(runtime.allocator, &package_config);

        for (package_config.model_paths.items) |model_path| {
            var sql_files: std.ArrayList([]const u8) = .empty;
            defer sql_files.deinit(runtime.allocator);
            var yaml_files: std.ArrayList([]const u8) = .empty;
            defer yaml_files.deinit(runtime.allocator);
            var md_files: std.ArrayList([]const u8) = .empty;
            defer md_files.deinit(runtime.allocator);

            const root = try pathJoin(runtime.allocator, &.{ package_dir, model_path });
            discoverProjectFiles(runtime, root, model_path, &sql_files, &yaml_files, &md_files) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            sortStrings(sql_files.items);
            sortStrings(yaml_files.items);
            sortStrings(md_files.items);

            for (md_files.items) |md_path| {
                try callbacks.parse_doc_blocks(runtime, package_dir, model_path, md_path, package_config.name, graph);
            }
            for (yaml_files.items) |yaml_path| {
                try callbacks.parse_yaml_properties(runtime, package_dir, model_path, yaml_path, package_config.name, graph);
            }

            for (sql_files.items) |sql_path| {
                try callbacks.parse_model(runtime, package_dir, model_path, sql_path, package_config.name, graph);
            }
        }

        for (package_config.seed_paths.items) |seed_path| {
            var seed_files: std.ArrayList([]const u8) = .empty;
            defer seed_files.deinit(runtime.allocator);

            const root = try pathJoin(runtime.allocator, &.{ package_dir, seed_path });
            discoverSeedFiles(runtime, root, seed_path, &seed_files) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            sortStrings(seed_files.items);

            for (seed_files.items) |relative_path| {
                try callbacks.parse_seed(runtime, seed_path, relative_path, package_config.name, graph);
            }
        }
        try applyProjectModelPathConfigs(graph, package_config.model_path_configs.items, false, package_config.name);
        try callbacks.apply_model_properties(graph, package_config.name);
        applyProjectSeedDocs(graph, package_config.name, package_config.seed_docs);
    }
}
