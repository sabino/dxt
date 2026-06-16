const std = @import("std");
const Io = std.Io;
const project_config = @import("project/config.zig");
const project_fs = @import("project/fs.zig");
const project_jinja = @import("project/jinja.zig");
const project_parse = @import("project/parse.zig");
const project_resolve = @import("project/resolve.zig");
const manifest = @import("project/manifest.zig");
const selector = @import("project/selector.zig");
const types = @import("project/types.zig");
const util = @import("project/util.zig");

pub const Runtime = types.Runtime;
pub const Options = types.Options;
pub const Output = types.Output;

const SourceDef = types.SourceDef;
const ExposureDef = types.ExposureDef;
const MetaEntry = types.MetaEntry;
const JsonScalar = types.JsonScalar;
const SourceDep = types.SourceDep;
const ColumnDef = types.ColumnDef;
const GenericTestDef = types.GenericTestDef;
const DocBlock = types.DocBlock;
const MacroDef = types.MacroDef;
const MacroArgument = types.MacroArgument;
const ModelProperty = types.ModelProperty;
const MacroProperty = types.MacroProperty;
const Node = types.Node;
const GenericTestNode = types.GenericTestNode;
const Graph = types.Graph;
const deinitProjectConfig = types.deinitProjectConfig;
const deinitNode = types.deinitNode;
const deinitGenericTestNode = types.deinitGenericTestNode;
const applyProjectModelPathConfigs = project_config.applyProjectModelPathConfigs;
const applyProjectSeedDocs = project_config.applyProjectSeedDocs;
const loadProjectConfig = project_config.loadProjectConfig;
const discoverChildDirectories = project_fs.discoverChildDirectories;
const discoverProjectFiles = project_fs.discoverProjectFiles;
const discoverSeedFiles = project_fs.discoverSeedFiles;
const discoverMacroFiles = project_fs.discoverMacroFiles;
const modelNameFromPath = project_fs.modelNameFromPath;
const pathJoin = project_fs.pathJoin;
const relativeUnderResourcePath = project_fs.relativeUnderResourcePath;
const resourceNameFromPath = project_fs.resourceNameFromPath;
const stripYamlComment = util.stripYamlComment;
const leadingSpaces = util.leadingSpaces;
const splitKeyValue = util.splitKeyValue;
const parseInlineStringList = util.parseInlineStringList;
const dupTrimmedScalar = util.dupTrimmedScalar;
const sortStrings = util.sortStrings;
const appendGenericTestDef = project_parse.appendGenericTestDef;
const appendGenericTestDefClone = project_parse.appendGenericTestDefClone;
const parseBool = project_parse.parseBool;
const genericTestUniqueId = project_parse.genericTestUniqueId;
const parseInlineGenericTestList = project_parse.parseInlineGenericTestList;
const parseJsonScalar = project_parse.parseJsonScalar;
const refDepFromValue = project_parse.refDepFromValue;
const synthesizeGenericTestNames = project_parse.synthesizeGenericTestNames;
const testNameFromYamlItem = project_parse.testNameFromYamlItem;
const findMatchingParen = project_jinja.findMatchingParen;
const isIdentChar = project_jinja.isIdentChar;
const isIdentStart = project_jinja.isIdentStart;
const parseLiteralArgs = project_jinja.parseLiteralArgs;
const skipWs = project_jinja.skipWs;
const appendUnique = util.appendUnique;
const countActiveExposures = project_resolve.countActiveExposures;
const countActiveNodes = project_resolve.countActiveNodes;
const countActiveSeeds = project_resolve.countActiveSeeds;
const findDoc = project_resolve.findDoc;
const findMacroIndexByPackageAndName = project_resolve.findMacroIndexByPackageAndName;
const findModelIndexByName = project_resolve.findModelIndexByName;
const rejectDuplicateDocs = project_resolve.rejectDuplicateDocs;
const rejectDuplicateExposures = project_resolve.rejectDuplicateExposures;
const rejectDuplicateMacroProperties = project_resolve.rejectDuplicateMacroProperties;
const rejectDuplicateMacros = project_resolve.rejectDuplicateMacros;
const rejectDuplicateModels = project_resolve.rejectDuplicateModels;
const rejectDuplicateSeeds = project_resolve.rejectDuplicateSeeds;
const resolveDependencies = project_resolve.resolveDependencies;
const resolveRefDependency = project_resolve.resolveRefDependency;
const sortGraphResources = project_resolve.sortGraphResources;

pub fn parse(runtime: Runtime, options: Options, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var graph = try loadGraph(runtime, options.project_dir);
    defer graph.deinit();

    try resolveDependencies(&graph);
    try writeWarnings(stderr, &graph);
    const active_models = countActiveNodes(&graph);
    const active_seeds = countActiveSeeds(&graph);

    const target_path = options.target_path orelse graphDefaultTarget(runtime, options.project_dir) catch "target";
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
    var graph = try loadGraph(runtime, options.project_dir);
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

fn graphDefaultTarget(runtime: Runtime, project_dir: []const u8) ![]const u8 {
    var config = try loadProjectConfig(runtime, project_dir);
    defer deinitProjectConfig(runtime.allocator, &config);
    return config.target_path;
}

fn loadGraph(runtime: Runtime, project_dir: []const u8) !Graph {
    var config = try loadProjectConfig(runtime, project_dir);
    defer deinitProjectConfig(runtime.allocator, &config);

    var graph = Graph{ .allocator = runtime.allocator, .project_name = config.name };
    errdefer graph.deinit();

    try loadProjectMacros(runtime, project_dir, config.name, config.macro_paths.items, true, &graph);
    try loadInstalledPackageMacros(runtime, project_dir, &graph);
    try loadInstalledPackageResources(runtime, project_dir, &graph);

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
            try parseDocBlocks(runtime, project_dir, model_path, md_path, config.name, &graph);
        }
        for (yaml_files.items) |yaml_path| {
            try parseYamlProperties(runtime, project_dir, model_path, yaml_path, config.name, &graph);
        }
        for (sql_files.items) |sql_path| {
            try parseModel(runtime, project_dir, model_path, sql_path, config.name, &graph);
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
            try parseSeed(runtime, seed_path, relative_path, config.name, &graph);
        }
    }
    applyProjectSeedDocs(&graph, config.name, config.seed_docs);

    try rejectDuplicateMacroProperties(&graph);
    try applyMacroProperties(&graph);
    try applyModelProperties(&graph, config.name);
    try materializeGenericTests(&graph);
    sortGraphResources(&graph);
    try rejectDuplicateModels(&graph);
    try rejectDuplicateSeeds(&graph);
    try rejectDuplicateDocs(&graph);
    try rejectDuplicateExposures(&graph);
    try rejectDuplicateMacros(&graph);
    try resolveMacroDependencies(&graph);
    return graph;
}

fn loadProjectMacros(runtime: Runtime, project_dir: []const u8, package_name: []const u8, macro_paths: []const []const u8, parse_properties: bool, graph: *Graph) !void {
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
                try parseYamlProperties(runtime, project_dir, macro_path, yaml_path, package_name, graph);
            }
        }
        for (macro_files.items) |relative_path| {
            try parseMacros(runtime, project_dir, relative_path, package_name, graph);
        }
    }
}

fn loadInstalledPackageMacros(runtime: Runtime, project_dir: []const u8, graph: *Graph) !void {
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

        try loadProjectMacros(runtime, package_dir, package_config.name, package_config.macro_paths.items, true, graph);
    }
}

fn loadInstalledPackageResources(runtime: Runtime, project_dir: []const u8, graph: *Graph) !void {
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
                try parseDocBlocks(runtime, package_dir, model_path, md_path, package_config.name, graph);
            }
            for (yaml_files.items) |yaml_path| {
                try parseYamlProperties(runtime, package_dir, model_path, yaml_path, package_config.name, graph);
            }

            for (sql_files.items) |sql_path| {
                try parseModel(runtime, package_dir, model_path, sql_path, package_config.name, graph);
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
                try parseSeed(runtime, seed_path, relative_path, package_config.name, graph);
            }
        }
        try applyProjectModelPathConfigs(graph, package_config.model_path_configs.items, false, package_config.name);
        try applyModelProperties(graph, package_config.name);
        applyProjectSeedDocs(graph, package_config.name, package_config.seed_docs);
    }
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

fn parseMacros(runtime: Runtime, project_dir: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    const path = try pathJoin(runtime.allocator, &.{ project_dir, relative_path });
    const text = try std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(4 * 1024 * 1024));
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, text, index, "{%")) |open| {
        const close = std.mem.indexOfPos(u8, text, open + 2, "%}") orelse return error.MalformedMacroBlock;
        const tag = std.mem.trim(u8, text[open + 2 .. close], " \t\r\n-");
        if (!isMacroOpenTag(tag)) {
            index = close + 2;
            continue;
        }
        const name_start = skipWs(tag, "macro".len);
        if (name_start >= tag.len or !isIdentStart(tag[name_start])) return error.MalformedMacroBlock;
        var name_end = name_start + 1;
        while (name_end < tag.len and isIdentChar(tag[name_end])) name_end += 1;
        const macro_name = tag[name_start..name_end];
        const call_pos = skipWs(tag, name_end);
        if (call_pos >= tag.len or tag[call_pos] != '(') return error.MalformedMacroBlock;
        _ = findMatchingParen(tag, call_pos) orelse return error.MalformedMacroBlock;

        const end = try findEndMacroTag(text, close + 2);

        const macro_sql = std.mem.trim(u8, text[open .. end.close + 2], " \t\r\n");
        const unique_id = try std.fmt.allocPrint(runtime.allocator, "macro.{s}.{s}", .{ package_name, macro_name });
        try graph.macros.append(runtime.allocator, .{
            .unique_id = unique_id,
            .package_name = package_name,
            .name = try runtime.allocator.dupe(u8, macro_name),
            .path = relative_path,
            .original_file_path = relative_path,
            .macro_sql = try runtime.allocator.dupe(u8, macro_sql),
        });
        index = end.close + 2;
    }
}

const MacroEndTag = struct {
    close: usize,
};

fn isMacroOpenTag(tag: []const u8) bool {
    return std.mem.startsWith(u8, tag, "macro") and tag.len > "macro".len and std.ascii.isWhitespace(tag["macro".len]);
}

fn findEndMacroTag(text: []const u8, start: usize) !MacroEndTag {
    var index = start;
    while (std.mem.indexOfPos(u8, text, index, "{%")) |open| {
        const close = std.mem.indexOfPos(u8, text, open + 2, "%}") orelse return error.MalformedMacroBlock;
        const tag = std.mem.trim(u8, text[open + 2 .. close], " \t\r\n-");
        if (std.mem.eql(u8, tag, "endmacro")) return .{ .close = close };
        index = close + 2;
    }
    return error.MalformedMacroBlock;
}

fn parseYamlProperties(runtime: Runtime, project_dir: []const u8, resource_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    const path = try pathJoin(runtime.allocator, &.{ project_dir, relative_path });
    const text = try std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(4 * 1024 * 1024));

    try parseSourcesFromText(runtime.allocator, text, relative_path, package_name, graph);
    try parseExposuresFromText(runtime.allocator, text, resource_root, relative_path, package_name, graph);
    try parseModelPropertiesFromText(runtime.allocator, text, relative_path, package_name, graph);
    try parseMacroPropertiesFromText(runtime.allocator, text, relative_path, package_name, graph);
}

fn parseSourcesFromText(allocator: std.mem.Allocator, text: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    var in_sources = false;
    var in_tables = false;
    var sources_indent: usize = 0;
    var source_item_indent: ?usize = null;
    var table_item_indent: ?usize = null;
    var current_source: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);

        if (std.mem.eql(u8, trimmed, "sources:")) {
            in_sources = true;
            in_tables = false;
            sources_indent = indent;
            source_item_indent = null;
            table_item_indent = null;
            continue;
        }
        if (!in_sources) continue;
        if (indent <= sources_indent and !std.mem.eql(u8, trimmed, "sources:")) {
            in_sources = false;
            in_tables = false;
            current_source = null;
            continue;
        }

        if (std.mem.eql(u8, trimmed, "tables:")) {
            in_tables = true;
            table_item_indent = null;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "- name:")) {
            const name = try dupTrimmedScalar(allocator, trimmed["- name:".len..]);
            if (source_item_indent == null or indent == source_item_indent.?) {
                source_item_indent = indent;
                current_source = name;
                in_tables = false;
                table_item_indent = null;
            } else if (in_tables and (table_item_indent == null or indent == table_item_indent.?)) {
                table_item_indent = indent;
                const source_name = current_source orelse return error.UnsupportedYaml;
                const unique_id = try std.fmt.allocPrint(allocator, "source.{s}.{s}.{s}", .{ package_name, source_name, name });
                try graph.sources.append(allocator, .{
                    .package_name = package_name,
                    .unique_id = unique_id,
                    .source_name = source_name,
                    .table_name = name,
                    .original_file_path = relative_path,
                });
            }
        }
    }
}

fn parseExposuresFromText(allocator: std.mem.Allocator, text: []const u8, resource_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    var in_exposures = false;
    var in_depends_on = false;
    var in_owner = false;
    var in_config = false;
    var in_meta = false;
    var exposures_indent: usize = 0;
    var exposure_item_indent: ?usize = null;
    var depends_on_indent: usize = 0;
    var owner_indent: usize = 0;
    var config_indent: usize = 0;
    var meta_indent: usize = 0;
    var current_exposure: ?usize = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);

        if (std.mem.eql(u8, trimmed, "exposures:")) {
            in_exposures = true;
            in_depends_on = false;
            in_owner = false;
            in_config = false;
            in_meta = false;
            exposures_indent = indent;
            exposure_item_indent = null;
            current_exposure = null;
            continue;
        }
        if (!in_exposures) continue;
        if (indent <= exposures_indent and !std.mem.eql(u8, trimmed, "exposures:")) {
            in_exposures = false;
            in_depends_on = false;
            in_owner = false;
            in_config = false;
            in_meta = false;
            current_exposure = null;
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "- name:")) {
            if (exposure_item_indent == null or indent == exposure_item_indent.?) {
                exposure_item_indent = indent;
                in_depends_on = false;
                in_owner = false;
                in_config = false;
                in_meta = false;
                const name = try dupTrimmedScalar(allocator, trimmed["- name:".len..]);
                const unique_id = try std.fmt.allocPrint(allocator, "exposure.{s}.{s}", .{ package_name, name });
                try graph.exposures.append(allocator, .{
                    .package_name = package_name,
                    .unique_id = unique_id,
                    .name = name,
                    .path = relativeUnderResourcePath(relative_path, resource_root),
                    .original_file_path = relative_path,
                });
                current_exposure = graph.exposures.items.len - 1;
                continue;
            }
        }

        const exposure_index = current_exposure orelse continue;
        if (exposure_item_indent) |item_indent| {
            if (indent <= item_indent and !std.mem.startsWith(u8, trimmed, "- name:")) {
                in_depends_on = false;
                in_owner = false;
                in_config = false;
                in_meta = false;
            }
        }

        if (std.mem.eql(u8, trimmed, "depends_on:")) {
            in_depends_on = true;
            in_owner = false;
            in_config = false;
            in_meta = false;
            depends_on_indent = indent;
            continue;
        }
        if (std.mem.eql(u8, trimmed, "owner:")) {
            in_owner = true;
            in_depends_on = false;
            in_config = false;
            in_meta = false;
            owner_indent = indent;
            continue;
        }
        if (std.mem.eql(u8, trimmed, "config:")) {
            in_config = true;
            in_depends_on = false;
            in_owner = false;
            in_meta = false;
            config_indent = indent;
            continue;
        }
        if (std.mem.eql(u8, trimmed, "meta:")) {
            in_meta = true;
            in_depends_on = false;
            in_owner = false;
            meta_indent = indent;
            continue;
        }
        if (in_depends_on and indent <= depends_on_indent) in_depends_on = false;
        if (in_owner and indent <= owner_indent) in_owner = false;
        if (in_config and indent <= config_indent) in_config = false;
        if (in_meta and indent <= meta_indent) in_meta = false;

        if (in_depends_on and std.mem.startsWith(u8, trimmed, "- ")) {
            try parseExposureDependency(allocator, trimmed[2..], &graph.exposures.items[exposure_index]);
            continue;
        }

        if (splitKeyValue(trimmed)) |kv| {
            const value = try dupTrimmedScalar(allocator, kv.value);
            if (in_meta) {
                try appendMetaEntry(allocator, &graph.exposures.items[exposure_index].meta, kv.key, try parseJsonScalar(allocator, kv.value));
                continue;
            }
            if (in_owner) {
                if (std.mem.eql(u8, kv.key, "name")) {
                    graph.exposures.items[exposure_index].owner_name = value;
                } else if (std.mem.eql(u8, kv.key, "email")) {
                    graph.exposures.items[exposure_index].owner_email = value;
                }
                continue;
            }
            if (in_config) {
                if (std.mem.eql(u8, kv.key, "enabled")) {
                    graph.exposures.items[exposure_index].enabled = try parseBool(kv.value);
                } else if (std.mem.eql(u8, kv.key, "tags")) {
                    try parseInlineStringList(allocator, kv.value, &graph.exposures.items[exposure_index].tags);
                    sortStrings(graph.exposures.items[exposure_index].tags.items);
                } else if (std.mem.eql(u8, kv.key, "meta") and std.mem.trim(u8, kv.value, " \t").len == 0) {
                    in_meta = true;
                    meta_indent = indent;
                }
                continue;
            }
            if (std.mem.eql(u8, kv.key, "type")) {
                graph.exposures.items[exposure_index].exposure_type = value;
            } else if (std.mem.eql(u8, kv.key, "maturity")) {
                graph.exposures.items[exposure_index].maturity = value;
            } else if (std.mem.eql(u8, kv.key, "url")) {
                graph.exposures.items[exposure_index].url = value;
            } else if (std.mem.eql(u8, kv.key, "description")) {
                graph.exposures.items[exposure_index].description = value;
            } else if (std.mem.eql(u8, kv.key, "tags")) {
                try parseInlineStringList(allocator, kv.value, &graph.exposures.items[exposure_index].tags);
                sortStrings(graph.exposures.items[exposure_index].tags.items);
            }
        }
    }
}

fn parseExposureDependency(allocator: std.mem.Allocator, raw_value: []const u8, exposure: *ExposureDef) !void {
    const value = std.mem.trim(u8, raw_value, " \t\r");
    if (std.mem.startsWith(u8, value, "ref(")) {
        const args_start = std.mem.indexOfScalar(u8, value, '(') orelse return error.UnsupportedDynamicRef;
        const args_end = findMatchingParen(value, args_start) orelse return error.UnsupportedDynamicRef;
        var strings = try parseLiteralArgs(allocator, value[args_start + 1 .. args_end], error.UnsupportedDynamicRef);
        defer strings.deinit(allocator);
        if (strings.items.len == 1) {
            try exposure.refs.append(allocator, .{ .package = null, .name = strings.items[0] });
        } else if (strings.items.len == 2) {
            try exposure.refs.append(allocator, .{ .package = strings.items[0], .name = strings.items[1] });
        } else {
            return error.UnsupportedDynamicRef;
        }
        return;
    }
    if (std.mem.startsWith(u8, value, "source(")) {
        const args_start = std.mem.indexOfScalar(u8, value, '(') orelse return error.UnsupportedDynamicSource;
        const args_end = findMatchingParen(value, args_start) orelse return error.UnsupportedDynamicSource;
        var strings = try parseLiteralArgs(allocator, value[args_start + 1 .. args_end], error.UnsupportedDynamicSource);
        defer strings.deinit(allocator);
        if (strings.items.len != 2) return error.UnsupportedDynamicSource;
        try exposure.source_refs.append(allocator, .{ .source_name = strings.items[0], .table_name = strings.items[1] });
        return;
    }
    return error.UnsupportedYaml;
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

fn parseMacroPropertiesFromText(allocator: std.mem.Allocator, text: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    var in_macros = false;
    var in_arguments = false;
    var macros_indent: usize = 0;
    var macro_item_indent: ?usize = null;
    var arguments_indent: usize = 0;
    var argument_item_indent: ?usize = null;
    var current_macro: ?usize = null;
    var current_argument: ?usize = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);

        if (std.mem.eql(u8, trimmed, "macros:")) {
            in_macros = true;
            in_arguments = false;
            macros_indent = indent;
            macro_item_indent = null;
            argument_item_indent = null;
            current_macro = null;
            current_argument = null;
            continue;
        }
        if (!in_macros) continue;
        if (indent <= macros_indent and !std.mem.eql(u8, trimmed, "macros:")) break;

        if (in_arguments and indent <= arguments_indent and !std.mem.eql(u8, trimmed, "arguments:")) {
            in_arguments = false;
            argument_item_indent = null;
            current_argument = null;
        }

        if (std.mem.startsWith(u8, trimmed, "- name:")) {
            const name = try dupTrimmedScalar(allocator, trimmed["- name:".len..]);
            if (in_arguments and current_macro != null and indent > (macro_item_indent orelse 0)) {
                const macro_index = current_macro.?;
                try graph.macro_properties.items[macro_index].arguments.append(allocator, .{ .name = name });
                current_argument = graph.macro_properties.items[macro_index].arguments.items.len - 1;
                argument_item_indent = indent;
            } else {
                try graph.macro_properties.append(allocator, .{ .package_name = package_name, .name = name, .patch_path = relative_path });
                current_macro = graph.macro_properties.items.len - 1;
                macro_item_indent = indent;
                in_arguments = false;
                argument_item_indent = null;
                current_argument = null;
            }
            continue;
        }

        const macro_index = current_macro orelse continue;
        if (splitKeyValue(trimmed)) |kv| {
            if (in_arguments and current_argument != null and indent > (argument_item_indent orelse 0)) {
                var argument = &graph.macro_properties.items[macro_index].arguments.items[current_argument.?];
                if (std.mem.eql(u8, kv.key, "type")) {
                    argument.type = try dupTrimmedScalar(allocator, kv.value);
                } else if (std.mem.eql(u8, kv.key, "description")) {
                    argument.description = try dupTrimmedScalar(allocator, kv.value);
                } else {
                    return error.UnsupportedYaml;
                }
                continue;
            }

            if (std.mem.eql(u8, kv.key, "description")) {
                graph.macro_properties.items[macro_index].description = try dupTrimmedScalar(allocator, kv.value);
            } else if (std.mem.eql(u8, kv.key, "arguments")) {
                if (std.mem.trim(u8, kv.value, " \t").len != 0) return error.UnsupportedYaml;
                in_arguments = true;
                arguments_indent = indent;
                argument_item_indent = null;
                current_argument = null;
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

fn applyMacroProperties(graph: *Graph) !void {
    for (graph.macro_properties.items) |property| {
        const macro_index = findMacroIndexByPackageAndName(graph, property.package_name, property.name) orelse {
            try graph.unmatched_macro_properties.append(graph.allocator, .{ .name = property.name, .patch_path = property.patch_path });
            continue;
        };
        var macro = &graph.macros.items[macro_index];
        macro.patch_path = property.patch_path;
        if (property.description.len != 0) macro.description = property.description;
        for (property.arguments.items) |argument| {
            try appendMacroArgumentClone(graph, &macro.arguments, argument);
        }
    }
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

fn appendMacroArgumentClone(graph: *Graph, arguments: *std.ArrayList(MacroArgument), source: MacroArgument) !void {
    for (arguments.items) |*existing| {
        if (std.mem.eql(u8, existing.name, source.name)) {
            if (source.type.len != 0) existing.type = source.type;
            if (source.description.len != 0) existing.description = source.description;
            return;
        }
    }
    try arguments.append(graph.allocator, source);
}

fn appendMetaEntry(allocator: std.mem.Allocator, entries: *std.ArrayList(MetaEntry), key: []const u8, value: JsonScalar) !void {
    for (entries.items) |*existing| {
        if (std.mem.eql(u8, existing.key, key)) {
            existing.value = value;
            return;
        }
    }
    try entries.append(allocator, .{ .key = try allocator.dupe(u8, key), .value = value });
    sortMetaEntries(entries.items);
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

fn sortMetaEntries(entries: []MetaEntry) void {
    std.mem.sort(MetaEntry, entries, {}, struct {
        fn lessThan(_: void, a: MetaEntry, b: MetaEntry) bool {
            return std.mem.lessThan(u8, a.key, b.key);
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
