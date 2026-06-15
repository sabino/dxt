const std = @import("std");
const Io = std.Io;

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: Io,
};

pub const Options = struct {
    project_dir: []const u8 = ".",
    target_path: ?[]const u8 = null,
    select: ?[]const u8 = null,
    exclude: ?[]const u8 = null,
    resource_type: ?[]const u8 = null,
    output: Output = .text,
};

pub const Output = enum {
    text,
    json,
};

const ProjectConfig = struct {
    name: []const u8,
    model_paths: std.ArrayList([]const u8) = .empty,
    seed_paths: std.ArrayList([]const u8) = .empty,
    macro_paths: std.ArrayList([]const u8) = .empty,
    macro_paths_set: bool = false,
    target_path: []const u8 = "target",
};

const SourceDef = struct {
    unique_id: []const u8,
    source_name: []const u8,
    table_name: []const u8,
    original_file_path: []const u8,
};

const ExposureDef = struct {
    unique_id: []const u8,
    name: []const u8,
    exposure_type: []const u8 = "",
    enabled: bool = true,
    maturity: ?[]const u8 = null,
    url: ?[]const u8 = null,
    description: []const u8 = "",
    owner_name: []const u8 = "",
    owner_email: ?[]const u8 = null,
    path: []const u8,
    original_file_path: []const u8,
    tags: std.ArrayList([]const u8) = .empty,
    meta: std.ArrayList(MetaEntry) = .empty,
    refs: std.ArrayList(RefDep) = .empty,
    source_refs: std.ArrayList(SourceDep) = .empty,
    depends_on: std.ArrayList([]const u8) = .empty,
};

const MetaEntry = struct {
    key: []const u8,
    value: JsonScalar,
};

const JsonScalar = struct {
    text: []const u8,
    kind: enum {
        string,
        number,
        bool,
        null,
    } = .string,
};

const RefDep = struct {
    package: ?[]const u8,
    name: []const u8,
};

const SourceDep = struct {
    source_name: []const u8,
    table_name: []const u8,
};

const ColumnDef = struct {
    name: []const u8,
    description: []const u8 = "",
    doc_blocks: std.ArrayList([]const u8) = .empty,
    tests: std.ArrayList(GenericTestDef) = .empty,
};

const GenericTestDef = struct {
    name: []const u8,
    accepted_values: std.ArrayList([]const u8) = .empty,
    relationship_to: []const u8 = "",
    relationship_field: []const u8 = "",
};

const DocBlock = struct {
    unique_id: []const u8,
    name: []const u8,
    path: []const u8,
    original_file_path: []const u8,
    block_contents: []const u8,
};

const MacroDef = struct {
    unique_id: []const u8,
    name: []const u8,
    path: []const u8,
    original_file_path: []const u8,
    macro_sql: []const u8,
    patch_path: ?[]const u8 = null,
    description: []const u8 = "",
    arguments: std.ArrayList(MacroArgument) = .empty,
    macro_depends_on: std.ArrayList([]const u8) = .empty,
};

const MacroArgument = struct {
    name: []const u8,
    type: []const u8 = "",
    description: []const u8 = "",
};

const ModelProperty = struct {
    name: []const u8,
    patch_path: []const u8,
    description: []const u8 = "",
    materialized: []const u8 = "",
    tags: std.ArrayList([]const u8) = .empty,
    doc_blocks: std.ArrayList([]const u8) = .empty,
    tests: std.ArrayList(GenericTestDef) = .empty,
    columns: std.ArrayList(ColumnDef) = .empty,
    enabled: ?bool = null,
};

const UnmatchedModelProperty = struct {
    name: []const u8,
    patch_path: []const u8,
};

const MacroProperty = struct {
    name: []const u8,
    patch_path: []const u8,
    description: []const u8 = "",
    arguments: std.ArrayList(MacroArgument) = .empty,
};

const UnmatchedMacroProperty = struct {
    name: []const u8,
    patch_path: []const u8,
};

const Node = struct {
    resource_type: []const u8 = "model",
    unique_id: []const u8,
    name: []const u8,
    path: []const u8,
    original_file_path: []const u8,
    patch_path: ?[]const u8 = null,
    raw_code: []const u8,
    description: []const u8 = "",
    materialized: []const u8 = "view",
    enabled: bool = true,
    tags: std.ArrayList([]const u8) = .empty,
    doc_blocks: std.ArrayList([]const u8) = .empty,
    tests: std.ArrayList(GenericTestDef) = .empty,
    columns: std.ArrayList(ColumnDef) = .empty,
    refs: std.ArrayList(RefDep) = .empty,
    source_refs: std.ArrayList(SourceDep) = .empty,
    depends_on: std.ArrayList([]const u8) = .empty,
    macro_depends_on: std.ArrayList([]const u8) = .empty,
};

const GenericTestNode = struct {
    unique_id: []const u8,
    name: []const u8,
    alias: []const u8,
    path: []const u8,
    original_file_path: []const u8,
    raw_code: []const u8,
    test_name: []const u8,
    column_name: ?[]const u8 = null,
    accepted_values: std.ArrayList([]const u8) = .empty,
    relationship_to: []const u8 = "",
    relationship_field: []const u8 = "",
    attached_node: []const u8,
    depends_on: std.ArrayList([]const u8) = .empty,
    macro_depends_on: std.ArrayList([]const u8) = .empty,
};

const Graph = struct {
    allocator: std.mem.Allocator,
    project_name: []const u8,
    nodes: std.ArrayList(Node) = .empty,
    tests: std.ArrayList(GenericTestNode) = .empty,
    sources: std.ArrayList(SourceDef) = .empty,
    exposures: std.ArrayList(ExposureDef) = .empty,
    docs: std.ArrayList(DocBlock) = .empty,
    macros: std.ArrayList(MacroDef) = .empty,
    model_properties: std.ArrayList(ModelProperty) = .empty,
    macro_properties: std.ArrayList(MacroProperty) = .empty,
    unmatched_model_properties: std.ArrayList(UnmatchedModelProperty) = .empty,
    unmatched_macro_properties: std.ArrayList(UnmatchedMacroProperty) = .empty,

    fn deinit(self: *Graph) void {
        for (self.nodes.items) |*node| {
            deinitNode(self.allocator, node);
        }
        for (self.tests.items) |*test_node| {
            deinitGenericTestNode(self.allocator, test_node);
        }
        for (self.exposures.items) |*exposure| {
            deinitExposureDef(self.allocator, exposure);
        }
        for (self.model_properties.items) |*property| {
            deinitModelProperty(self.allocator, property);
        }
        for (self.macro_properties.items) |*property| {
            deinitMacroProperty(self.allocator, property);
        }
        for (self.macros.items) |*macro| {
            deinitMacro(self.allocator, macro);
        }
        self.nodes.deinit(self.allocator);
        self.tests.deinit(self.allocator);
        self.sources.deinit(self.allocator);
        self.exposures.deinit(self.allocator);
        self.docs.deinit(self.allocator);
        self.macros.deinit(self.allocator);
        self.model_properties.deinit(self.allocator);
        self.macro_properties.deinit(self.allocator);
        self.unmatched_model_properties.deinit(self.allocator);
        self.unmatched_macro_properties.deinit(self.allocator);
    }
};

fn deinitNode(allocator: std.mem.Allocator, node: *Node) void {
    node.tags.deinit(allocator);
    node.doc_blocks.deinit(allocator);
    deinitGenericTestDefs(allocator, &node.tests);
    for (node.columns.items) |*column| {
        column.doc_blocks.deinit(allocator);
        deinitGenericTestDefs(allocator, &column.tests);
    }
    node.columns.deinit(allocator);
    node.refs.deinit(allocator);
    node.source_refs.deinit(allocator);
    node.depends_on.deinit(allocator);
    node.macro_depends_on.deinit(allocator);
}

fn deinitGenericTestNode(allocator: std.mem.Allocator, test_node: *GenericTestNode) void {
    test_node.accepted_values.deinit(allocator);
    test_node.depends_on.deinit(allocator);
    test_node.macro_depends_on.deinit(allocator);
}

fn deinitExposureDef(allocator: std.mem.Allocator, exposure: *ExposureDef) void {
    exposure.tags.deinit(allocator);
    exposure.meta.deinit(allocator);
    exposure.refs.deinit(allocator);
    exposure.source_refs.deinit(allocator);
    exposure.depends_on.deinit(allocator);
}

fn deinitMacro(allocator: std.mem.Allocator, macro: *MacroDef) void {
    macro.arguments.deinit(allocator);
    macro.macro_depends_on.deinit(allocator);
}

fn deinitModelProperty(allocator: std.mem.Allocator, property: *ModelProperty) void {
    property.tags.deinit(allocator);
    property.doc_blocks.deinit(allocator);
    deinitGenericTestDefs(allocator, &property.tests);
    for (property.columns.items) |*column| {
        column.doc_blocks.deinit(allocator);
        deinitGenericTestDefs(allocator, &column.tests);
    }
    property.columns.deinit(allocator);
}

fn deinitMacroProperty(allocator: std.mem.Allocator, property: *MacroProperty) void {
    property.arguments.deinit(allocator);
}

fn deinitGenericTestDefs(allocator: std.mem.Allocator, tests: *std.ArrayList(GenericTestDef)) void {
    for (tests.items) |*test_def| {
        test_def.accepted_values.deinit(allocator);
    }
    tests.deinit(allocator);
}

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
    const manifest = try renderManifest(runtime.allocator, &graph);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = manifest_path, .data = manifest });
    try stdout.print("Parsed {d} model(s), {d} seed(s), {d} source(s), and {d} exposure(s) into {s}\n", .{
        active_models,
        active_seeds,
        graph.sources.items.len,
        countActiveExposures(&graph),
        normalizeForDisplay(manifest_path),
    });
}

pub fn list(runtime: Runtime, options: Options, stdout: *Io.Writer) !void {
    var graph = try loadGraph(runtime, options.project_dir);
    defer graph.deinit();

    try resolveDependencies(&graph);
    const select = if (options.select) |value| try runtime.allocator.dupe(u8, value) else null;
    const exclude = if (options.exclude) |value| try runtime.allocator.dupe(u8, value) else null;
    const resource_type = if (options.resource_type) |value| try runtime.allocator.dupe(u8, value) else null;
    const selected = try selectResources(runtime.allocator, &graph, resource_type, select, exclude);
    if (options.output == .json) {
        try writeSelectedJson(stdout, selected);
    } else {
        for (selected) |item| {
            try stdout.print("{s}\n", .{item.unique_id});
        }
    }
}

fn graphDefaultTarget(runtime: Runtime, project_dir: []const u8) ![]const u8 {
    var config = try loadProjectConfig(runtime, project_dir);
    defer config.model_paths.deinit(runtime.allocator);
    defer config.seed_paths.deinit(runtime.allocator);
    defer config.macro_paths.deinit(runtime.allocator);
    return config.target_path;
}

fn loadGraph(runtime: Runtime, project_dir: []const u8) !Graph {
    var config = try loadProjectConfig(runtime, project_dir);
    defer config.model_paths.deinit(runtime.allocator);
    defer config.seed_paths.deinit(runtime.allocator);
    defer config.macro_paths.deinit(runtime.allocator);

    var graph = Graph{ .allocator = runtime.allocator, .project_name = config.name };
    errdefer graph.deinit();

    for (config.macro_paths.items) |macro_path| {
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

        for (macro_yaml_files.items) |yaml_path| {
            try parseYamlProperties(runtime, project_dir, macro_path, yaml_path, config.name, &graph);
        }
        for (macro_files.items) |relative_path| {
            try parseMacros(runtime, project_dir, relative_path, config.name, &graph);
        }
    }

    for (config.model_paths.items) |model_path| {
        var sql_files: std.ArrayList([]const u8) = .empty;
        defer sql_files.deinit(runtime.allocator);
        var yaml_files: std.ArrayList([]const u8) = .empty;
        defer yaml_files.deinit(runtime.allocator);
        var md_files: std.ArrayList([]const u8) = .empty;
        defer md_files.deinit(runtime.allocator);

        const root = try pathJoin(runtime.allocator, &.{ project_dir, model_path });
        discoverFiles(runtime, root, model_path, &sql_files, &yaml_files, &md_files) catch |err| switch (err) {
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

    try rejectDuplicateMacroProperties(&graph);
    try applyMacroProperties(&graph);
    try applyModelProperties(&graph);
    try materializeGenericTests(&graph);
    sortNodes(graph.nodes.items);
    sortTests(graph.tests.items);
    sortSources(graph.sources.items);
    sortExposures(graph.exposures.items);
    sortDocs(graph.docs.items);
    sortMacros(graph.macros.items);
    try rejectDuplicateModels(&graph);
    try rejectDuplicateSeeds(&graph);
    try rejectDuplicateDocs(&graph);
    try rejectDuplicateExposures(&graph);
    try rejectDuplicateMacros(&graph);
    try resolveMacroDependencies(&graph);
    return graph;
}

fn loadProjectConfig(runtime: Runtime, project_dir: []const u8) !ProjectConfig {
    const path = try pathJoin(runtime.allocator, &.{ project_dir, "dbt_project.yml" });
    const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.MissingProjectFile,
        else => return err,
    };

    var config = ProjectConfig{ .name = "" };
    errdefer {
        config.model_paths.deinit(runtime.allocator);
        config.seed_paths.deinit(runtime.allocator);
        config.macro_paths.deinit(runtime.allocator);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    var read_model_path_block = false;
    var read_seed_path_block = false;
    var read_macro_path_block = false;
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (read_model_path_block) {
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                try config.model_paths.append(runtime.allocator, try dupTrimmedScalar(runtime.allocator, trimmed[2..]));
                continue;
            }
            read_model_path_block = false;
        }
        if (read_seed_path_block) {
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                try config.seed_paths.append(runtime.allocator, try dupTrimmedScalar(runtime.allocator, trimmed[2..]));
                continue;
            }
            read_seed_path_block = false;
        }
        if (read_macro_path_block) {
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                try config.macro_paths.append(runtime.allocator, try dupTrimmedScalar(runtime.allocator, trimmed[2..]));
                continue;
            }
            read_macro_path_block = false;
        }

        if (splitKeyValue(trimmed)) |kv| {
            if (std.mem.eql(u8, kv.key, "name")) {
                config.name = try dupTrimmedScalar(runtime.allocator, kv.value);
            } else if (std.mem.eql(u8, kv.key, "target-path")) {
                config.target_path = try dupTrimmedScalar(runtime.allocator, kv.value);
            } else if (std.mem.eql(u8, kv.key, "model-paths")) {
                if (std.mem.trim(u8, kv.value, " \t").len == 0) {
                    read_model_path_block = true;
                } else {
                    try parseInlineStringList(runtime.allocator, kv.value, &config.model_paths);
                }
            } else if (std.mem.eql(u8, kv.key, "seed-paths")) {
                if (std.mem.trim(u8, kv.value, " \t").len == 0) {
                    read_seed_path_block = true;
                } else {
                    try parseInlineStringList(runtime.allocator, kv.value, &config.seed_paths);
                }
            } else if (std.mem.eql(u8, kv.key, "macro-paths")) {
                config.macro_paths_set = true;
                if (std.mem.trim(u8, kv.value, " \t").len == 0) {
                    read_macro_path_block = true;
                } else {
                    try parseInlineStringList(runtime.allocator, kv.value, &config.macro_paths);
                }
            }
        }
    }

    if (config.name.len == 0) return error.InvalidProjectName;
    if (config.model_paths.items.len == 0) {
        try config.model_paths.append(runtime.allocator, "models");
    }
    if (config.seed_paths.items.len == 0) {
        try config.seed_paths.append(runtime.allocator, "seeds");
    }
    if (!config.macro_paths_set) {
        try config.macro_paths.append(runtime.allocator, "macros");
    }
    return config;
}

fn discoverFiles(runtime: Runtime, absolute_dir: []const u8, relative_dir: []const u8, sql_files: *std.ArrayList([]const u8), yaml_files: *std.ArrayList([]const u8), md_files: *std.ArrayList([]const u8)) !void {
    const fd = try openLinuxDirectory(runtime.allocator, absolute_dir);
    defer closeLinuxFd(fd);

    var buffer: [8192]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    var iter = LinuxDirReadState{ .fd = fd, .buffer = &buffer };
    while (try nextLinuxDirectoryEntry(&iter)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "target") or
            std.mem.eql(u8, entry.name, "dbt_packages") or
            std.mem.eql(u8, entry.name, ".zig-cache") or
            std.mem.eql(u8, entry.name, "zig-out"))
        {
            continue;
        }

        const child_abs = try pathJoin(runtime.allocator, &.{ absolute_dir, entry.name });
        const child_rel = try pathJoin(runtime.allocator, &.{ relative_dir, entry.name });
        if (entry.kind == .unknown and try linuxPathIsDirectory(runtime.allocator, child_abs)) {
            try discoverFiles(runtime, child_abs, child_rel, sql_files, yaml_files, md_files);
            continue;
        }
        switch (entry.kind) {
            .directory => try discoverFiles(runtime, child_abs, child_rel, sql_files, yaml_files, md_files),
            .file, .unknown => {
                if (std.mem.endsWith(u8, entry.name, ".sql")) {
                    try sql_files.append(runtime.allocator, child_rel);
                } else if (std.mem.endsWith(u8, entry.name, ".yml") or std.mem.endsWith(u8, entry.name, ".yaml")) {
                    try yaml_files.append(runtime.allocator, child_rel);
                } else if (std.mem.endsWith(u8, entry.name, ".md")) {
                    try md_files.append(runtime.allocator, child_rel);
                }
            },
            else => {},
        }
    }
}

fn discoverSeedFiles(runtime: Runtime, absolute_dir: []const u8, relative_dir: []const u8, seed_files: *std.ArrayList([]const u8)) !void {
    const fd = try openLinuxDirectory(runtime.allocator, absolute_dir);
    defer closeLinuxFd(fd);

    var buffer: [8192]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    var iter = LinuxDirReadState{ .fd = fd, .buffer = &buffer };
    while (try nextLinuxDirectoryEntry(&iter)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        const child_abs = try pathJoin(runtime.allocator, &.{ absolute_dir, entry.name });
        const child_rel = try pathJoin(runtime.allocator, &.{ relative_dir, entry.name });
        if (entry.kind == .unknown and try linuxPathIsDirectory(runtime.allocator, child_abs)) {
            try discoverSeedFiles(runtime, child_abs, child_rel, seed_files);
            continue;
        }
        switch (entry.kind) {
            .directory => try discoverSeedFiles(runtime, child_abs, child_rel, seed_files),
            .file, .unknown => {
                if (std.mem.endsWith(u8, entry.name, ".csv")) {
                    try seed_files.append(runtime.allocator, child_rel);
                }
            },
            else => {},
        }
    }
}

fn discoverSqlFiles(runtime: Runtime, absolute_dir: []const u8, relative_dir: []const u8, sql_files: *std.ArrayList([]const u8)) !void {
    const fd = try openLinuxDirectory(runtime.allocator, absolute_dir);
    defer closeLinuxFd(fd);

    var buffer: [8192]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    var iter = LinuxDirReadState{ .fd = fd, .buffer = &buffer };
    while (try nextLinuxDirectoryEntry(&iter)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "target") or
            std.mem.eql(u8, entry.name, "dbt_packages") or
            std.mem.eql(u8, entry.name, ".zig-cache") or
            std.mem.eql(u8, entry.name, "zig-out"))
        {
            continue;
        }

        const child_abs = try pathJoin(runtime.allocator, &.{ absolute_dir, entry.name });
        const child_rel = try pathJoin(runtime.allocator, &.{ relative_dir, entry.name });
        if (entry.kind == .unknown and try linuxPathIsDirectory(runtime.allocator, child_abs)) {
            try discoverSqlFiles(runtime, child_abs, child_rel, sql_files);
            continue;
        }
        switch (entry.kind) {
            .directory => try discoverSqlFiles(runtime, child_abs, child_rel, sql_files),
            .file, .unknown => {
                if (std.mem.endsWith(u8, entry.name, ".sql")) {
                    try sql_files.append(runtime.allocator, child_rel);
                }
            },
            else => {},
        }
    }
}

fn discoverMacroFiles(runtime: Runtime, absolute_dir: []const u8, relative_dir: []const u8, sql_files: *std.ArrayList([]const u8), yaml_files: *std.ArrayList([]const u8)) !void {
    const fd = try openLinuxDirectory(runtime.allocator, absolute_dir);
    defer closeLinuxFd(fd);

    var buffer: [8192]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    var iter = LinuxDirReadState{ .fd = fd, .buffer = &buffer };
    while (try nextLinuxDirectoryEntry(&iter)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "target") or
            std.mem.eql(u8, entry.name, "dbt_packages") or
            std.mem.eql(u8, entry.name, ".zig-cache") or
            std.mem.eql(u8, entry.name, "zig-out"))
        {
            continue;
        }

        const child_abs = try pathJoin(runtime.allocator, &.{ absolute_dir, entry.name });
        const child_rel = try pathJoin(runtime.allocator, &.{ relative_dir, entry.name });
        if (entry.kind == .unknown and try linuxPathIsDirectory(runtime.allocator, child_abs)) {
            try discoverMacroFiles(runtime, child_abs, child_rel, sql_files, yaml_files);
            continue;
        }
        switch (entry.kind) {
            .directory => try discoverMacroFiles(runtime, child_abs, child_rel, sql_files, yaml_files),
            .file, .unknown => {
                if (std.mem.endsWith(u8, entry.name, ".sql")) {
                    try sql_files.append(runtime.allocator, child_rel);
                } else if (std.mem.endsWith(u8, entry.name, ".yml") or std.mem.endsWith(u8, entry.name, ".yaml")) {
                    try yaml_files.append(runtime.allocator, child_rel);
                }
            },
            else => {},
        }
    }
}

const LinuxDirEntry = struct {
    name: [:0]const u8,
    kind: std.Io.File.Kind,
};

const LinuxDirReadState = struct {
    fd: std.os.linux.fd_t,
    buffer: []u8,
    index: usize = 0,
    end: usize = 0,
};

// Keep discovery synchronous and deterministic on mounts that report DT_UNKNOWN
// or behave poorly with the experimental std.Io directory iterator.
fn openLinuxDirectory(allocator: std.mem.Allocator, path: []const u8) !std.os.linux.fd_t {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const rc = std.os.linux.openat(std.os.linux.AT.FDCWD, path_z.ptr, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .ACCES => error.AccessDenied,
        else => error.Unexpected,
    };
}

fn closeLinuxFd(fd: std.os.linux.fd_t) void {
    _ = std.os.linux.close(fd);
}

fn linuxPathIsDirectory(allocator: std.mem.Allocator, path: []const u8) !bool {
    const fd = openLinuxDirectory(allocator, path) catch |err| switch (err) {
        error.NotDir => return false,
        error.FileNotFound => return false,
        else => return err,
    };
    closeLinuxFd(fd);
    return true;
}

fn nextLinuxDirectoryEntry(state: *LinuxDirReadState) !?LinuxDirEntry {
    while (true) {
        if (state.index >= state.end) {
            const rc = std.os.linux.getdents64(state.fd, state.buffer.ptr, state.buffer.len);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.Unexpected,
            }
            if (rc == 0) return null;
            state.index = 0;
            state.end = rc;
        }

        const linux_entry: *align(1) std.os.linux.dirent64 = @ptrCast(&state.buffer[state.index]);
        state.index += linux_entry.reclen;

        const name_ptr: [*]u8 = &linux_entry.name;
        const padded_name = name_ptr[0 .. linux_entry.reclen - @offsetOf(std.os.linux.dirent64, "name")];
        const name_len = std.mem.findScalar(u8, padded_name, 0).?;
        const name = name_ptr[0..name_len :0];
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        return .{
            .name = name,
            .kind = switch (linux_entry.type) {
                std.os.linux.DT.DIR => .directory,
                std.os.linux.DT.REG => .file,
                std.os.linux.DT.LNK => .sym_link,
                else => .unknown,
            },
        };
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
    try parseModelPropertiesFromText(runtime.allocator, text, relative_path, graph);
    try parseMacroPropertiesFromText(runtime.allocator, text, relative_path, graph);
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

fn parseModelPropertiesFromText(allocator: std.mem.Allocator, text: []const u8, relative_path: []const u8, graph: *Graph) !void {
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
                    try graph.model_properties.append(allocator, .{ .name = name, .patch_path = relative_path });
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

fn parseMacroPropertiesFromText(allocator: std.mem.Allocator, text: []const u8, relative_path: []const u8, graph: *Graph) !void {
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
                try graph.macro_properties.append(allocator, .{ .name = name, .patch_path = relative_path });
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
        .unique_id = unique_id,
        .name = model_name,
        .path = model_path,
        .original_file_path = relative_path,
        .raw_code = sql,
    };
    errdefer {
        deinitNode(runtime.allocator, &node);
    }
    try scanSql(runtime.allocator, sql, &node, graph);
    try graph.nodes.append(runtime.allocator, node);
}

fn parseSeed(runtime: Runtime, seed_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    const seed_name = try resourceNameFromPath(runtime.allocator, relative_path, ".csv");
    const unique_id = try std.fmt.allocPrint(runtime.allocator, "seed.{s}.{s}", .{ package_name, seed_name });
    const seed_path = relativeUnderResourcePath(relative_path, seed_root);

    var node = Node{
        .resource_type = "seed",
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
        const macro_index = findMacroIndexByName(graph, property.name) orelse {
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

fn applyModelProperties(graph: *Graph) !void {
    for (graph.model_properties.items) |property| {
        const node_index = findModelIndexByName(graph, property.name) orelse {
            try graph.unmatched_model_properties.append(graph.allocator, .{ .name = property.name, .patch_path = property.patch_path });
            continue;
        };
        var node = &graph.nodes.items[node_index];
        node.patch_path = property.patch_path;
        if (property.description.len != 0) node.description = try resolveDocDescription(graph, property.description, &node.doc_blocks);
        if (property.materialized.len != 0) node.materialized = property.materialized;
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
            try appendColumnClone(graph, &node.columns, column);
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
    const unique_id = try genericTestUniqueId(graph.allocator, graph.project_name, names.full, test_def, node.name, column_name);
    for (graph.tests.items) |existing| {
        if (std.mem.eql(u8, existing.unique_id, unique_id)) return;
    }

    const raw_code = if (std.mem.eql(u8, names.compiled, names.full))
        try std.fmt.allocPrint(graph.allocator, "{{{{ test_{s}(**_dbt_generic_test_kwargs) }}}}", .{test_def.name})
    else
        try std.fmt.allocPrint(graph.allocator, "{{{{ test_{s}(**_dbt_generic_test_kwargs) }}}}{{{{ config(alias=\"{s}\") }}}}", .{ test_def.name, names.compiled });
    var test_node = GenericTestNode{
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
        const target_name = try refTargetName(graph.allocator, test_def.relationship_to);
        const target_unique_id = try std.fmt.allocPrint(graph.allocator, "model.{s}.{s}", .{ graph.project_name, target_name });
        if (!hasNode(graph, target_unique_id)) return error.UnresolvedRef;
        try test_node.depends_on.append(graph.allocator, target_unique_id);
    }
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
        try stderr.print("warning: did not find matching node for model property `{s}` in {s}\n", .{ property.name, normalizeForDisplay(property.patch_path) });
    }
    for (graph.unmatched_macro_properties.items) |property| {
        try stderr.print("warning: did not find matching macro for macro property `{s}` in {s}\n", .{ property.name, normalizeForDisplay(property.patch_path) });
    }
}

fn appendColumnClone(graph: *Graph, columns: *std.ArrayList(ColumnDef), source: ColumnDef) !void {
    for (columns.items) |*existing| {
        if (std.mem.eql(u8, existing.name, source.name)) {
            if (source.description.len != 0) existing.description = try resolveDocDescription(graph, source.description, &existing.doc_blocks);
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
    if (source.description.len != 0) column.description = try resolveDocDescription(graph, source.description, &column.doc_blocks);
    for (source.tests.items) |test_def| {
        try appendGenericTestDefClone(graph, &column.tests, test_def);
    }
    sortGenericTestDefs(column.tests.items);
    try columns.append(graph.allocator, column);
}

fn rejectDuplicateModels(graph: *const Graph) !void {
    var i: usize = 0;
    while (i < graph.nodes.items.len) : (i += 1) {
        var j = i + 1;
        while (j < graph.nodes.items.len) : (j += 1) {
            if (std.mem.eql(u8, graph.nodes.items[i].resource_type, "model") and
                std.mem.eql(u8, graph.nodes.items[j].resource_type, "model") and
                std.mem.eql(u8, graph.nodes.items[i].unique_id, graph.nodes.items[j].unique_id))
            {
                return error.DuplicateModelName;
            }
        }
    }
}

fn rejectDuplicateSeeds(graph: *const Graph) !void {
    var i: usize = 0;
    while (i < graph.nodes.items.len) : (i += 1) {
        var j = i + 1;
        while (j < graph.nodes.items.len) : (j += 1) {
            if (std.mem.eql(u8, graph.nodes.items[i].resource_type, "seed") and
                std.mem.eql(u8, graph.nodes.items[j].resource_type, "seed") and
                std.mem.eql(u8, graph.nodes.items[i].unique_id, graph.nodes.items[j].unique_id))
            {
                return error.DuplicateSeedName;
            }
        }
    }
}

fn rejectDuplicateDocs(graph: *const Graph) !void {
    var i: usize = 0;
    while (i < graph.docs.items.len) : (i += 1) {
        var j = i + 1;
        while (j < graph.docs.items.len) : (j += 1) {
            if (std.mem.eql(u8, graph.docs.items[i].unique_id, graph.docs.items[j].unique_id)) {
                return error.DuplicateDocName;
            }
        }
    }
}

fn rejectDuplicateExposures(graph: *const Graph) !void {
    var i: usize = 0;
    while (i < graph.exposures.items.len) : (i += 1) {
        var j = i + 1;
        while (j < graph.exposures.items.len) : (j += 1) {
            if (std.mem.eql(u8, graph.exposures.items[i].unique_id, graph.exposures.items[j].unique_id)) {
                return error.DuplicateExposureName;
            }
        }
    }
}

fn rejectDuplicateMacroProperties(graph: *const Graph) !void {
    var i: usize = 0;
    while (i < graph.macro_properties.items.len) : (i += 1) {
        var j = i + 1;
        while (j < graph.macro_properties.items.len) : (j += 1) {
            if (std.mem.eql(u8, graph.macro_properties.items[i].name, graph.macro_properties.items[j].name)) {
                return error.DuplicateMacroProperty;
            }
        }
    }
}

fn rejectDuplicateMacros(graph: *const Graph) !void {
    var i: usize = 0;
    while (i < graph.macros.items.len) : (i += 1) {
        var j = i + 1;
        while (j < graph.macros.items.len) : (j += 1) {
            if (std.mem.eql(u8, graph.macros.items[i].unique_id, graph.macros.items[j].unique_id)) {
                return error.DuplicateMacroName;
            }
        }
    }
}

fn resolveMacroDependencies(graph: *Graph) !void {
    for (graph.macros.items) |*macro| {
        try scanMacroSqlForKnownMacroCalls(graph.allocator, macro.macro_sql, graph, macro.unique_id, &macro.macro_depends_on);
        sortStrings(macro.macro_depends_on.items);
    }
}

fn resolveDocDescription(graph: *Graph, description: []const u8, doc_blocks: *std.ArrayList([]const u8)) ![]const u8 {
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

    const unique_id = try std.fmt.allocPrint(graph.allocator, "doc.{s}.{s}", .{ graph.project_name, strings.items[0] });
    const doc = findDoc(graph, unique_id) orelse return error.UnresolvedDoc;
    try appendUnique(graph.allocator, doc_blocks, doc.unique_id);
    sortStrings(doc_blocks.items);
    return doc.block_contents;
}

fn resolveDependencies(graph: *Graph) !void {
    for (graph.nodes.items) |*node| {
        if (!node.enabled) continue;
        for (node.macro_depends_on.items) |macro_dep| {
            if (!hasMacro(graph, macro_dep)) return error.UnresolvedMacro;
        }
        sortStrings(node.macro_depends_on.items);
        for (node.refs.items) |ref_dep| {
            const package = ref_dep.package orelse graph.project_name;
            const model_id = try std.fmt.allocPrint(graph.allocator, "model.{s}.{s}", .{ package, ref_dep.name });
            if (hasDisabledNode(graph, model_id)) return error.DisabledRef;
            if (hasNode(graph, model_id)) {
                try appendUnique(graph.allocator, &node.depends_on, model_id);
                continue;
            }
            const seed_id = try std.fmt.allocPrint(graph.allocator, "seed.{s}.{s}", .{ package, ref_dep.name });
            if (!hasNode(graph, seed_id)) return error.UnresolvedRef;
            try appendUnique(graph.allocator, &node.depends_on, seed_id);
        }
        for (node.source_refs.items) |source_dep| {
            const unique_id = try std.fmt.allocPrint(graph.allocator, "source.{s}.{s}.{s}", .{ graph.project_name, source_dep.source_name, source_dep.table_name });
            if (!hasSource(graph, unique_id)) return error.UnresolvedSource;
            try appendUnique(graph.allocator, &node.depends_on, unique_id);
        }
        sortStrings(node.depends_on.items);
    }
    for (graph.exposures.items) |*exposure| {
        if (!exposure.enabled) continue;
        for (exposure.refs.items) |ref_dep| {
            const package = ref_dep.package orelse graph.project_name;
            const model_id = try std.fmt.allocPrint(graph.allocator, "model.{s}.{s}", .{ package, ref_dep.name });
            if (hasDisabledNode(graph, model_id)) return error.DisabledRef;
            if (hasNode(graph, model_id)) {
                try appendUnique(graph.allocator, &exposure.depends_on, model_id);
                continue;
            }
            const seed_id = try std.fmt.allocPrint(graph.allocator, "seed.{s}.{s}", .{ package, ref_dep.name });
            if (!hasNode(graph, seed_id)) return error.UnresolvedRef;
            try appendUnique(graph.allocator, &exposure.depends_on, seed_id);
        }
        for (exposure.source_refs.items) |source_dep| {
            const unique_id = try std.fmt.allocPrint(graph.allocator, "source.{s}.{s}.{s}", .{ graph.project_name, source_dep.source_name, source_dep.table_name });
            if (!hasSource(graph, unique_id)) return error.UnresolvedSource;
            try appendUnique(graph.allocator, &exposure.depends_on, unique_id);
        }
        sortStrings(exposure.depends_on.items);
    }
}

fn scanSql(allocator: std.mem.Allocator, sql: []const u8, node: *Node, graph: ?*const Graph) !void {
    var index: usize = 0;
    while (index + 1 < sql.len) {
        if (sql[index] != '{') {
            index += 1;
            continue;
        }
        if (sql[index + 1] == '#') {
            const end = std.mem.indexOfPos(u8, sql, index + 2, "#}") orelse return error.UnsupportedJinja;
            index = end + 2;
            continue;
        }
        const close = if (sql[index + 1] == '{')
            std.mem.indexOfPos(u8, sql, index + 2, "}}")
        else if (sql[index + 1] == '%')
            std.mem.indexOfPos(u8, sql, index + 2, "%}")
        else
            null;
        if (close) |end| {
            try scanJinjaSpan(allocator, sql[index + 2 .. end], node, graph);
            index = end + 2;
            continue;
        }
        index += 1;
    }
}

fn scanJinjaSpan(allocator: std.mem.Allocator, span: []const u8, node: *Node, graph: ?*const Graph) !void {
    var i: usize = 0;
    while (i < span.len) {
        if (span[i] == '"' or span[i] == '\'') {
            i = skipQuotedSpan(span, i) orelse return error.UnsupportedJinja;
            continue;
        }
        if (!isIdentStart(span[i])) {
            i += 1;
            continue;
        }
        const start = i;
        i += 1;
        while (i < span.len and isIdentChar(span[i])) i += 1;
        const ident = span[start..i];
        const call_pos = skipWs(span, i);
        if (call_pos >= span.len or span[call_pos] != '(') continue;
        const close = findMatchingParen(span, call_pos) orelse return error.UnsupportedJinja;
        const args = span[call_pos + 1 .. close];

        if (std.mem.eql(u8, ident, "ref")) {
            var strings = try parseLiteralArgs(allocator, args, error.UnsupportedDynamicRef);
            defer strings.deinit(allocator);
            if (!(strings.items.len == 1 or strings.items.len == 2)) return error.UnsupportedDynamicRef;
            try node.refs.append(allocator, .{
                .package = if (strings.items.len == 2) strings.items[0] else null,
                .name = if (strings.items.len == 2) strings.items[1] else strings.items[0],
            });
        } else if (std.mem.eql(u8, ident, "source")) {
            var strings = try parseLiteralArgs(allocator, args, error.UnsupportedDynamicSource);
            defer strings.deinit(allocator);
            if (strings.items.len != 2) return error.UnsupportedDynamicSource;
            try node.source_refs.append(allocator, .{
                .source_name = strings.items[0],
                .table_name = strings.items[1],
            });
        } else if (std.mem.eql(u8, ident, "config")) {
            try parseConfig(allocator, args, node);
        } else {
            if (graph) |known_graph| {
                if (findProjectMacroIdByName(known_graph, ident)) |macro_id| {
                    try appendUnique(allocator, &node.macro_depends_on, macro_id);
                    i = close + 1;
                    continue;
                }
            }
            return error.UnsupportedJinja;
        }
        i = close + 1;
    }
}

fn scanMacroSqlForKnownMacroCalls(allocator: std.mem.Allocator, sql: []const u8, graph: *const Graph, current_macro_id: []const u8, macro_depends_on: *std.ArrayList([]const u8)) !void {
    var index: usize = 0;
    while (index + 1 < sql.len) {
        if (sql[index] != '{') {
            index += 1;
            continue;
        }
        if (sql[index + 1] == '#') {
            const end = std.mem.indexOfPos(u8, sql, index + 2, "#}") orelse break;
            index = end + 2;
            continue;
        }
        const close = if (sql[index + 1] == '{')
            std.mem.indexOfPos(u8, sql, index + 2, "}}")
        else if (sql[index + 1] == '%')
            std.mem.indexOfPos(u8, sql, index + 2, "%}")
        else
            null;
        if (close) |end| {
            try scanMacroSpanForKnownMacroCalls(allocator, sql[index + 2 .. end], graph, current_macro_id, macro_depends_on);
            index = end + 2;
            continue;
        }
        index += 1;
    }
}

fn scanMacroSpanForKnownMacroCalls(allocator: std.mem.Allocator, span: []const u8, graph: *const Graph, current_macro_id: []const u8, macro_depends_on: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i < span.len) {
        if (span[i] == '"' or span[i] == '\'') {
            i = skipQuotedSpan(span, i) orelse break;
            continue;
        }
        if (!isIdentStart(span[i])) {
            i += 1;
            continue;
        }
        const start = i;
        i += 1;
        while (i < span.len and isIdentChar(span[i])) i += 1;
        const ident = span[start..i];
        const call_pos = skipWs(span, i);
        if (call_pos >= span.len or span[call_pos] != '(') continue;
        const close = findMatchingParen(span, call_pos) orelse break;
        if (findProjectMacroIdByName(graph, ident)) |macro_id| {
            if (std.mem.eql(u8, macro_id, current_macro_id)) {
                i = close + 1;
                continue;
            }
            try appendUnique(allocator, macro_depends_on, macro_id);
        }
        i = close + 1;
    }
}

fn parseLiteralArgs(allocator: std.mem.Allocator, args: []const u8, unsupported_error: anyerror) !std.ArrayList([]const u8) {
    var strings: std.ArrayList([]const u8) = .empty;
    errdefer strings.deinit(allocator);

    var i: usize = 0;
    var saw_literal = false;
    while (i < args.len) {
        i = skipWs(args, i);
        if (i >= args.len) break;
        if (args[i] == ',') {
            i += 1;
            continue;
        }
        if (args[i] != '"' and args[i] != '\'') return unsupported_error;
        const parsed = try parseQuoted(allocator, args, i);
        try strings.append(allocator, parsed.value);
        saw_literal = true;
        i = skipWs(args, parsed.next);
        if (i < args.len and args[i] != ',') return unsupported_error;
    }
    if (!saw_literal) return unsupported_error;
    return strings;
}

fn parseConfig(allocator: std.mem.Allocator, args: []const u8, node: *Node) !void {
    if (findKeyword(args, "materialized")) |pos| {
        if (findValueStart(args, pos + "materialized".len)) |value_pos| {
            if (args[value_pos] != '"' and args[value_pos] != '\'') return error.UnsupportedJinja;
            const parsed = try parseQuoted(allocator, args, value_pos);
            node.materialized = parsed.value;
        }
    }
    if (findKeyword(args, "tags")) |pos| {
        if (findValueStart(args, pos + "tags".len)) |value_pos| {
            try parseTagList(allocator, args[value_pos..], &node.tags);
            sortStrings(node.tags.items);
        }
    }
}

fn parseTagList(allocator: std.mem.Allocator, text: []const u8, tags: *std.ArrayList([]const u8)) !void {
    var i = skipWs(text, 0);
    if (i >= text.len) return;
    if (text[i] == '"' or text[i] == '\'') {
        const parsed = try parseQuoted(allocator, text, i);
        try appendUnique(allocator, tags, parsed.value);
        return;
    }
    if (text[i] != '[') return error.UnsupportedJinja;
    i += 1;
    while (i < text.len) {
        i = skipWs(text, i);
        if (i >= text.len or text[i] == ']') break;
        if (text[i] == ',') {
            i += 1;
            continue;
        }
        if (text[i] != '"' and text[i] != '\'') return error.UnsupportedJinja;
        const parsed = try parseQuoted(allocator, text, i);
        try appendUnique(allocator, tags, parsed.value);
        i = parsed.next;
    }
}

const ParsedString = struct {
    value: []const u8,
    next: usize,
};

fn parseQuoted(allocator: std.mem.Allocator, text: []const u8, start: usize) !ParsedString {
    const quote = text[start];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == quote) {
            return .{ .value = try out.toOwnedSlice(allocator), .next = i + 1 };
        }
        if (ch == '\\' and i + 1 < text.len) {
            i += 1;
            try out.append(allocator, text[i]);
        } else {
            try out.append(allocator, ch);
        }
    }
    return error.UnsupportedJinja;
}

fn skipQuotedSpan(text: []const u8, start: usize) ?usize {
    const quote = text[start];
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len) {
            i += 1;
            continue;
        }
        if (text[i] == quote) return i + 1;
    }
    return null;
}

const SelectedResource = struct {
    unique_id: []const u8,
    name: []const u8,
    resource_type: []const u8,
};

const SelectorSpec = struct {
    active: bool = false,
    value: []const u8 = "",
    include_parents: bool = false,
    include_children: bool = false,
};

fn selectResources(allocator: std.mem.Allocator, graph: *const Graph, resource_type: ?[]const u8, select: ?[]const u8, exclude: ?[]const u8) ![]SelectedResource {
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
    if (matchesNodeSelectorDirect(node, spec.value)) return true;
    return matchesGraphExpansion(graph, node.unique_id, spec);
}

fn matchesNodeSelectorDirect(node: *const Node, value: []const u8) bool {
    if (std.mem.eql(u8, value, node.name) or std.mem.eql(u8, value, node.unique_id)) return true;
    if (std.mem.startsWith(u8, value, "tag:")) {
        const tag = value["tag:".len..];
        for (node.tags.items) |node_tag| {
            if (std.mem.eql(u8, tag, node_tag)) return true;
        }
    }
    if (std.mem.startsWith(u8, value, "path:")) {
        const path = value["path:".len..];
        return std.mem.indexOf(u8, node.original_file_path, path) != null;
    }
    if (std.mem.startsWith(u8, value, "source:")) {
        return false;
    }
    return false;
}

fn matchesTestSelector(graph: *const Graph, test_node: *const GenericTestNode, spec: SelectorSpec) bool {
    if (!spec.active) return true;
    if (spec.value.len == 0) return true;
    if (matchesTestSelectorDirect(test_node, spec.value)) return true;
    return matchesGraphExpansion(graph, test_node.unique_id, spec);
}

fn matchesTestSelectorDirect(test_node: *const GenericTestNode, value: []const u8) bool {
    if (std.mem.eql(u8, value, test_node.name) or std.mem.eql(u8, value, test_node.unique_id)) return true;
    if (std.mem.startsWith(u8, value, "path:")) {
        const path = value["path:".len..];
        return std.mem.indexOf(u8, test_node.original_file_path, path) != null;
    }
    return false;
}

fn matchesSourceSelector(graph: *const Graph, source: *const SourceDef, spec: SelectorSpec) bool {
    if (!spec.active) return true;
    if (spec.value.len == 0) return true;
    if (matchesSourceSelectorDirect(source, spec.value)) return true;
    return matchesGraphExpansion(graph, source.unique_id, spec);
}

fn matchesSourceSelectorDirect(source: *const SourceDef, value: []const u8) bool {
    if (std.mem.eql(u8, value, source.unique_id) or std.mem.eql(u8, value, source.table_name)) return true;
    if (std.mem.startsWith(u8, value, "source:")) {
        const source_value = value["source:".len..];
        if (std.mem.eql(u8, source_value, source.source_name) or std.mem.eql(u8, source_value, source.unique_id)) return true;
        if (std.mem.indexOfScalar(u8, source_value, '.')) |dot| {
            return std.mem.eql(u8, source_value[0..dot], source.source_name) and std.mem.eql(u8, source_value[dot + 1 ..], source.table_name);
        }
    }
    return false;
}

fn matchesExposureSelector(graph: *const Graph, exposure: *const ExposureDef, spec: SelectorSpec) bool {
    if (!spec.active) return true;
    if (spec.value.len == 0) return true;
    const direct = matchesExposureSelectorDirect(exposure, spec.value);
    if (direct) return true;
    return matchesGraphExpansion(graph, exposure.unique_id, spec);
}

fn matchesExposureSelectorDirect(exposure: *const ExposureDef, value: []const u8) bool {
    if (std.mem.eql(u8, value, exposure.name) or std.mem.eql(u8, value, exposure.unique_id)) return true;
    if (std.mem.startsWith(u8, value, "exposure:")) {
        const exposure_value = value["exposure:".len..];
        return std.mem.eql(u8, exposure_value, exposure.name) or std.mem.eql(u8, exposure_value, exposure.unique_id);
    }
    if (std.mem.startsWith(u8, value, "tag:")) {
        const tag = value["tag:".len..];
        for (exposure.tags.items) |exposure_tag| {
            if (std.mem.eql(u8, tag, exposure_tag)) return true;
        }
    }
    if (std.mem.startsWith(u8, value, "path:")) {
        const path = value["path:".len..];
        return std.mem.indexOf(u8, exposure.original_file_path, path) != null;
    }
    return false;
}

fn parseSelectorSpec(selector: ?[]const u8) SelectorSpec {
    const raw = selector orelse return .{};
    return .{
        .active = true,
        .value = trimPlus(raw),
        .include_parents = std.mem.startsWith(u8, raw, "+"),
        .include_children = std.mem.endsWith(u8, raw, "+"),
    };
}

fn matchesGraphExpansion(graph: *const Graph, candidate_unique_id: []const u8, spec: SelectorSpec) bool {
    if (!spec.include_parents and !spec.include_children) return false;
    for (graph.nodes.items) |*target| {
        if (!target.enabled or !matchesNodeSelectorDirect(target, spec.value)) continue;
        if (spec.include_parents and resourceDependsOn(graph, target.unique_id, candidate_unique_id)) return true;
        if (spec.include_children and resourceDependsOn(graph, candidate_unique_id, target.unique_id)) return true;
    }
    for (graph.tests.items) |*target| {
        if (!matchesTestSelectorDirect(target, spec.value)) continue;
        if (spec.include_parents and resourceDependsOn(graph, target.unique_id, candidate_unique_id)) return true;
        if (spec.include_children and resourceDependsOn(graph, candidate_unique_id, target.unique_id)) return true;
    }
    for (graph.sources.items) |*target| {
        if (!matchesSourceSelectorDirect(target, spec.value)) continue;
        if (spec.include_children and resourceDependsOn(graph, candidate_unique_id, target.unique_id)) return true;
    }
    for (graph.exposures.items) |*target| {
        if (!target.enabled) continue;
        if (!matchesExposureSelectorDirect(target, spec.value)) continue;
        if (spec.include_parents and resourceDependsOn(graph, target.unique_id, candidate_unique_id)) return true;
        if (spec.include_children and resourceDependsOn(graph, candidate_unique_id, target.unique_id)) return true;
    }
    return false;
}

fn resourceDependsOn(graph: *const Graph, resource_unique_id: []const u8, dependency_unique_id: []const u8) bool {
    return resourceDependsOnWithin(graph, resource_unique_id, dependency_unique_id, graph.nodes.items.len + graph.tests.items.len + graph.sources.items.len + graph.exposures.items.len + 1);
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

fn writeSelectedJson(writer: *Io.Writer, selected: []SelectedResource) !void {
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

fn renderManifest(allocator: std.mem.Allocator, graph: *const Graph) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\n  \"metadata\": {\"dbt_schema_version\": null, \"dbt_version\": null, \"project_name\": ");
    try writeJsonString(writer, graph.project_name);
    try writer.writeAll(", \"generated_by\": \"dxt\"},\n  \"nodes\": {");
    var node_index: usize = 0;
    for (graph.nodes.items) |node| {
        if (!node.enabled) continue;
        if (node_index != 0) try writer.writeAll(",");
        node_index += 1;
        try writer.writeAll("\n    ");
        try writeJsonString(writer, node.unique_id);
        try writer.writeAll(": ");
        try writeNode(allocator, writer, graph.project_name, node);
    }
    for (graph.tests.items) |test_node| {
        if (node_index != 0) try writer.writeAll(",");
        node_index += 1;
        try writer.writeAll("\n    ");
        try writeJsonString(writer, test_node.unique_id);
        try writer.writeAll(": ");
        try writeGenericTestNode(allocator, writer, graph.project_name, test_node);
    }
    try writer.writeAll("\n  },\n  \"sources\": {");
    for (graph.sources.items, 0..) |source, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try writeJsonString(writer, source.unique_id);
        try writer.writeAll(": {\"unique_id\":");
        try writeJsonString(writer, source.unique_id);
        try writer.writeAll(",\"resource_type\":\"source\",\"package_name\":");
        try writeJsonString(writer, graph.project_name);
        try writer.writeAll(",\"source_name\":");
        try writeJsonString(writer, source.source_name);
        try writer.writeAll(",\"name\":");
        try writeJsonString(writer, source.table_name);
        try writer.writeAll(",\"original_file_path\":");
        try writeJsonString(writer, normalizeForDisplay(source.original_file_path));
        try writer.writeAll("}");
    }
    try writer.writeAll("\n  },\n  \"macros\": {");
    for (graph.macros.items, 0..) |macro, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try writeJsonString(writer, macro.unique_id);
        try writer.writeAll(": ");
        try writeMacroNode(allocator, writer, graph.project_name, macro);
    }
    try writer.writeAll("\n  },\n  \"docs\": {");
    for (graph.docs.items, 0..) |doc, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try writeJsonString(writer, doc.unique_id);
        try writer.writeAll(": {\"unique_id\":");
        try writeJsonString(writer, doc.unique_id);
        try writer.writeAll(",\"resource_type\":\"doc\",\"package_name\":");
        try writeJsonString(writer, graph.project_name);
        try writer.writeAll(",\"name\":");
        try writeJsonString(writer, doc.name);
        try writer.writeAll(",\"path\":");
        try writeJsonString(writer, normalizeForDisplay(doc.path));
        try writer.writeAll(",\"original_file_path\":");
        try writeJsonString(writer, normalizeForDisplay(doc.original_file_path));
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
        try writeExposureNode(writer, graph.project_name, exposure);
    }
    try writer.writeAll("\n  },\n  \"metrics\": {},\n  \"groups\": {},\n  \"selectors\": {},\n  \"disabled\": {");
    var disabled_index: usize = 0;
    for (graph.nodes.items) |node| {
        if (node.enabled) continue;
        if (disabled_index != 0) try writer.writeAll(",");
        disabled_index += 1;
        try writer.writeAll("\n    ");
        try writeJsonString(writer, node.unique_id);
        try writer.writeAll(": [");
        try writeNode(allocator, writer, graph.project_name, node);
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
        if (containsString(node.depends_on.items, unique_id)) {
            if (!child_first) try writer.writeAll(",");
            child_first = false;
            try writeJsonString(writer, node.unique_id);
        }
    }
    for (graph.tests.items) |test_node| {
        if (containsString(test_node.depends_on.items, unique_id)) {
            if (!child_first) try writer.writeAll(",");
            child_first = false;
            try writeJsonString(writer, test_node.unique_id);
        }
    }
    for (graph.exposures.items) |exposure| {
        if (!exposure.enabled) continue;
        if (containsString(exposure.depends_on.items, unique_id)) {
            if (!child_first) try writer.writeAll(",");
            child_first = false;
            try writeJsonString(writer, exposure.unique_id);
        }
    }
    try writer.writeAll("]");
}

fn writeNode(allocator: std.mem.Allocator, writer: *Io.Writer, project_name: []const u8, node: Node) !void {
    if (std.mem.eql(u8, node.resource_type, "seed")) {
        try writeSeedNode(writer, project_name, node);
    } else {
        try writeModelNode(allocator, writer, project_name, node);
    }
}

fn writeMacroNode(allocator: std.mem.Allocator, writer: *Io.Writer, project_name: []const u8, macro: MacroDef) !void {
    try writer.writeAll("{\"unique_id\":");
    try writeJsonString(writer, macro.unique_id);
    try writer.writeAll(",\"resource_type\":\"macro\",\"package_name\":");
    try writeJsonString(writer, project_name);
    try writer.writeAll(",\"name\":");
    try writeJsonString(writer, macro.name);
    try writer.writeAll(",\"path\":");
    try writeJsonString(writer, normalizeForDisplay(macro.path));
    try writer.writeAll(",\"original_file_path\":");
    try writeJsonString(writer, normalizeForDisplay(macro.original_file_path));
    try writer.writeAll(",\"macro_sql\":");
    try writeJsonString(writer, macro.macro_sql);
    try writer.writeAll(",\"depends_on\":{\"macros\":");
    try writeStringArray(writer, macro.macro_depends_on.items);
    try writer.writeAll("},\"description\":");
    try writeJsonString(writer, macro.description);
    try writer.writeAll(",\"meta\":{},\"docs\":{\"show\":true,\"node_color\":null},\"patch_path\":");
    if (macro.patch_path) |patch_path| {
        const dbt_patch_path = try std.fmt.allocPrint(allocator, "{s}://{s}", .{ project_name, normalizeForDisplay(patch_path) });
        defer allocator.free(dbt_patch_path);
        try writeJsonString(writer, dbt_patch_path);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"arguments\":");
    try writeMacroArguments(writer, macro.arguments.items);
    try writer.writeAll(",\"supported_languages\":null}");
}

fn writeExposureNode(writer: *Io.Writer, project_name: []const u8, exposure: ExposureDef) !void {
    try writer.writeAll("{\"unique_id\":");
    try writeJsonString(writer, exposure.unique_id);
    try writer.writeAll(",\"resource_type\":\"exposure\",\"package_name\":");
    try writeJsonString(writer, project_name);
    try writer.writeAll(",\"name\":");
    try writeJsonString(writer, exposure.name);
    try writer.writeAll(",\"path\":");
    try writeJsonString(writer, normalizeForDisplay(exposure.path));
    try writer.writeAll(",\"original_file_path\":");
    try writeJsonString(writer, normalizeForDisplay(exposure.original_file_path));
    try writer.writeAll(",\"fqn\":[");
    try writeJsonString(writer, project_name);
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

fn writeModelNode(allocator: std.mem.Allocator, writer: *Io.Writer, project_name: []const u8, node: Node) !void {
    try writer.writeAll("{\"unique_id\":");
    try writeJsonString(writer, node.unique_id);
    try writer.writeAll(",\"resource_type\":\"model\",\"package_name\":");
    try writeJsonString(writer, project_name);
    try writer.writeAll(",\"name\":");
    try writeJsonString(writer, node.name);
    try writer.writeAll(",\"path\":");
    try writeJsonString(writer, normalizeForDisplay(node.path));
    try writer.writeAll(",\"original_file_path\":");
    try writeJsonString(writer, normalizeForDisplay(node.original_file_path));
    try writer.writeAll(",\"patch_path\":");
    if (node.patch_path) |patch_path| {
        const dbt_patch_path = try std.fmt.allocPrint(allocator, "{s}://{s}", .{ project_name, normalizeForDisplay(patch_path) });
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
    try writer.writeAll("},\"depends_on\":{\"macros\":");
    try writeStringArray(writer, node.macro_depends_on.items);
    try writer.writeAll(",\"nodes\":");
    try writeStringArray(writer, node.depends_on.items);
    try writer.writeAll("}}");
}

fn writeSeedNode(writer: *Io.Writer, project_name: []const u8, node: Node) !void {
    try writer.writeAll("{\"unique_id\":");
    try writeJsonString(writer, node.unique_id);
    try writer.writeAll(",\"resource_type\":\"seed\",\"package_name\":");
    try writeJsonString(writer, project_name);
    try writer.writeAll(",\"name\":");
    try writeJsonString(writer, node.name);
    try writer.writeAll(",\"path\":");
    try writeJsonString(writer, normalizeForDisplay(node.path));
    try writer.writeAll(",\"original_file_path\":");
    try writeJsonString(writer, normalizeForDisplay(node.original_file_path));
    try writer.writeAll(",\"config\":{\"enabled\":");
    try writer.writeAll(if (node.enabled) "true" else "false");
    try writer.writeAll(",\"materialized\":\"seed\"},\"depends_on\":{\"macros\":[],\"nodes\":");
    try writeStringArray(writer, node.depends_on.items);
    try writer.writeAll("}}");
}

fn writeGenericTestNode(allocator: std.mem.Allocator, writer: *Io.Writer, project_name: []const u8, test_node: GenericTestNode) !void {
    try writer.writeAll("{\"unique_id\":");
    try writeJsonString(writer, test_node.unique_id);
    try writer.writeAll(",\"resource_type\":\"test\",\"package_name\":");
    try writeJsonString(writer, project_name);
    try writer.writeAll(",\"name\":");
    try writeJsonString(writer, test_node.name);
    try writer.writeAll(",\"alias\":");
    try writeJsonString(writer, test_node.alias);
    try writer.writeAll(",\"path\":");
    try writeJsonString(writer, normalizeForDisplay(test_node.path));
    try writer.writeAll(",\"original_file_path\":");
    try writeJsonString(writer, normalizeForDisplay(test_node.original_file_path));
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
    try writer.writeAll("}}");
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

fn stripYamlComment(line: []const u8) []const u8 {
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (quote) |q| {
            if (ch == q) quote = null;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (ch == '#') return line[0..i];
    }
    return line;
}

fn leadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') count += 1;
    return count;
}

const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

fn splitKeyValue(line: []const u8) ?KeyValue {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    return .{
        .key = std.mem.trim(u8, line[0..colon], " \t"),
        .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
    };
}

fn parseInlineStringList(allocator: std.mem.Allocator, value: []const u8, out: *std.ArrayList([]const u8)) !void {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
        try out.append(allocator, try dupTrimmedScalar(allocator, trimmed));
        return;
    }
    var pieces = std.mem.splitScalar(u8, trimmed[1 .. trimmed.len - 1], ',');
    while (pieces.next()) |piece| {
        const item = std.mem.trim(u8, piece, " \t");
        if (item.len != 0) try out.append(allocator, try dupTrimmedScalar(allocator, item));
    }
}

fn parseInlineGenericTestList(allocator: std.mem.Allocator, value: []const u8, out: *std.ArrayList(GenericTestDef)) !void {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
        _ = try appendGenericTestDef(allocator, out, try dupTrimmedScalar(allocator, trimmed));
        return;
    }
    var pieces = std.mem.splitScalar(u8, trimmed[1 .. trimmed.len - 1], ',');
    while (pieces.next()) |piece| {
        const item = std.mem.trim(u8, piece, " \t");
        if (item.len != 0) _ = try appendGenericTestDef(allocator, out, try dupTrimmedScalar(allocator, item));
    }
}

fn appendGenericTestDef(allocator: std.mem.Allocator, tests: *std.ArrayList(GenericTestDef), test_name: []const u8) !usize {
    try tests.append(allocator, .{ .name = test_name });
    return tests.items.len - 1;
}

fn appendGenericTestDefClone(graph: *Graph, tests: *std.ArrayList(GenericTestDef), source: GenericTestDef) !void {
    var cloned = GenericTestDef{
        .name = source.name,
        .relationship_to = source.relationship_to,
        .relationship_field = source.relationship_field,
    };
    errdefer cloned.accepted_values.deinit(graph.allocator);
    for (source.accepted_values.items) |value| {
        try cloned.accepted_values.append(graph.allocator, value);
    }
    try tests.append(graph.allocator, cloned);
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

fn parseJsonScalar(allocator: std.mem.Allocator, value: []const u8) !JsonScalar {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    const unquoted = try dupTrimmedScalar(allocator, trimmed);
    if (std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "false")) return .{ .text = unquoted, .kind = .bool };
    if (std.mem.eql(u8, trimmed, "null")) return .{ .text = unquoted, .kind = .null };
    if (isJsonNumber(trimmed)) return .{ .text = unquoted, .kind = .number };
    return .{ .text = unquoted, .kind = .string };
}

fn currentGenericTestDef(graph: *Graph, model_index: usize, current_column: ?usize, target: TestTarget, test_index: usize) !*GenericTestDef {
    if (target == .model) return &graph.model_properties.items[model_index].tests.items[test_index];
    if (target == .column) {
        const column_index = current_column orelse return error.UnsupportedYaml;
        return &graph.model_properties.items[model_index].columns.items[column_index].tests.items[test_index];
    }
    return error.UnsupportedYaml;
}

fn dupTrimmedScalar(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (trimmed.len >= 2 and ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))) {
        return try allocator.dupe(u8, trimmed[1 .. trimmed.len - 1]);
    }
    return try allocator.dupe(u8, trimmed);
}

const GenericTestNames = struct {
    full: []const u8,
    compiled: []const u8,
};

fn synthesizeGenericTestNames(allocator: std.mem.Allocator, test_def: GenericTestDef, model_name: []const u8, column_name: ?[]const u8) !GenericTestNames {
    var clean_args: std.ArrayList([]const u8) = .empty;
    defer {
        for (clean_args.items) |arg| allocator.free(arg);
        clean_args.deinit(allocator);
    }

    if (column_name) |column| try clean_args.append(allocator, try cleanTestNamePart(allocator, column));
    if (std.mem.eql(u8, test_def.name, "relationships")) {
        try clean_args.append(allocator, try cleanTestNamePart(allocator, test_def.relationship_field));
        try clean_args.append(allocator, try cleanTestNamePart(allocator, test_def.relationship_to));
    } else if (std.mem.eql(u8, test_def.name, "accepted_values")) {
        for (test_def.accepted_values.items) |value| {
            try clean_args.append(allocator, try cleanTestNamePart(allocator, value));
        }
    }

    const test_identifier = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ test_def.name, model_name });
    const unique = try joinStrings(allocator, clean_args.items, "__");
    defer allocator.free(unique);

    const full = if (unique.len == 0)
        try std.fmt.allocPrint(allocator, "{s}_", .{test_identifier})
    else
        try std.fmt.allocPrint(allocator, "{s}_{s}", .{ test_identifier, unique });
    if (full.len < 64) return .{ .full = full, .compiled = full };

    const label = genericTestHashFull(full);
    const prefix_len = @min(test_identifier.len, 30);
    const compiled = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ test_identifier[0..prefix_len], label });
    return .{ .full = full, .compiled = compiled };
}

fn genericTestUniqueId(allocator: std.mem.Allocator, package_name: []const u8, name: []const u8, test_def: GenericTestDef, model_name: []const u8, column_name: ?[]const u8) ![]const u8 {
    const model_kwarg = try std.fmt.allocPrint(allocator, "{{{{ get_where_subquery(ref('{s}')) }}}}", .{model_name});
    defer allocator.free(model_kwarg);
    const metadata = try genericTestMetadataRepr(allocator, test_def, model_kwarg, column_name);
    defer allocator.free(metadata);

    const hash_input = try std.fmt.allocPrint(allocator, "{s}{s}", .{ name, metadata });
    defer allocator.free(hash_input);
    const suffix = genericTestHashSuffix(hash_input);
    return try std.fmt.allocPrint(allocator, "test.{s}.{s}.{s}", .{ package_name, name, suffix });
}

fn genericTestMetadataRepr(allocator: std.mem.Allocator, test_def: GenericTestDef, model_kwarg: []const u8, column_name: ?[]const u8) ![]const u8 {
    if (std.mem.eql(u8, test_def.name, "accepted_values")) {
        const values = try pythonReprStringList(allocator, test_def.accepted_values.items);
        defer allocator.free(values);
        if (column_name) |column| {
            return try std.fmt.allocPrint(allocator, "{{'kwargs': {{'column_name': '{s}', 'model': \"{s}\", 'values': {s}}}, 'name': '{s}', 'namespace': 'None'}}", .{ column, model_kwarg, values, test_def.name });
        }
    }
    if (std.mem.eql(u8, test_def.name, "relationships")) {
        if (column_name) |column| {
            return try std.fmt.allocPrint(allocator, "{{'kwargs': {{'column_name': '{s}', 'field': '{s}', 'model': \"{s}\", 'to': \"{s}\"}}, 'name': '{s}', 'namespace': 'None'}}", .{ column, test_def.relationship_field, model_kwarg, test_def.relationship_to, test_def.name });
        }
    }
    if (column_name) |column| {
        return try std.fmt.allocPrint(allocator, "{{'kwargs': {{'column_name': '{s}', 'model': \"{s}\"}}, 'name': '{s}', 'namespace': 'None'}}", .{ column, model_kwarg, test_def.name });
    }
    return try std.fmt.allocPrint(allocator, "{{'kwargs': {{'model': \"{s}\"}}, 'name': '{s}', 'namespace': 'None'}}", .{ model_kwarg, test_def.name });
}

fn genericTestHashSuffix(input: []const u8) [10]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(input, &digest, .{});
    var hex: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;
    var suffix: [10]u8 = undefined;
    @memcpy(&suffix, hex[22..32]);
    return suffix;
}

fn genericTestHashFull(input: []const u8) [32]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(input, &digest, .{});
    var hex: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;
    return hex;
}

fn pythonReprStringList(allocator: std.mem.Allocator, values: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (values, 0..) |value, index| {
        if (index != 0) try out.appendSlice(allocator, ", ");
        const repr = try pythonReprString(allocator, value);
        defer allocator.free(repr);
        try out.appendSlice(allocator, repr);
    }
    try out.append(allocator, ']');
    return try out.toOwnedSlice(allocator);
}

fn pythonReprString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const has_single = std.mem.indexOfScalar(u8, value, '\'') != null;
    const has_double = std.mem.indexOfScalar(u8, value, '"') != null;
    const quote: u8 = if (has_single and !has_double) '"' else '\'';

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, quote);
    for (value) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (ch == quote) try out.append(allocator, '\\');
                try out.append(allocator, ch);
            },
        }
    }
    try out.append(allocator, quote);
    return try out.toOwnedSlice(allocator);
}

fn joinStrings(allocator: std.mem.Allocator, values: []const []const u8, separator: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (values, 0..) |value, index| {
        if (index != 0) try out.appendSlice(allocator, separator);
        try out.appendSlice(allocator, value);
    }
    return try out.toOwnedSlice(allocator);
}

fn cleanTestNamePart(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var previous_was_replacement = false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            try out.append(allocator, ch);
            previous_was_replacement = false;
        } else {
            if (previous_was_replacement) continue;
            try out.append(allocator, '_');
            previous_was_replacement = true;
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn modelNameFromUniqueId(unique_id: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, unique_id, '.')) |index| {
        return unique_id[index + 1 ..];
    }
    return unique_id;
}

fn refTargetName(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (std.mem.startsWith(u8, trimmed, "ref(")) {
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return error.UnsupportedRef;
        const close = findMatchingParen(trimmed, open) orelse return error.UnsupportedRef;
        const args = std.mem.trim(u8, trimmed[open + 1 .. close], " \t\r");
        var pieces = std.mem.splitScalar(u8, args, ',');
        const first = pieces.next() orelse return error.UnsupportedRef;
        return try dupTrimmedScalar(allocator, first);
    }
    return try dupTrimmedScalar(allocator, trimmed);
}

fn modelNameFromPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return resourceNameFromPath(allocator, path, ".sql");
}

fn resourceNameFromPath(allocator: std.mem.Allocator, path: []const u8, suffix: []const u8) ![]const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, suffix)) {
        return try allocator.dupe(u8, base[0 .. base.len - suffix.len]);
    }
    return try allocator.dupe(u8, base);
}

fn relativeUnderResourcePath(relative_path: []const u8, resource_root: []const u8) []const u8 {
    if (std.mem.startsWith(u8, relative_path, resource_root) and relative_path.len > resource_root.len and relative_path[resource_root.len] == '/') {
        return relative_path[resource_root.len + 1 ..];
    }
    return relative_path;
}

fn pathJoin(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return try std.fs.path.join(allocator, parts);
}

fn normalizeForDisplay(path: []const u8) []const u8 {
    return path;
}

fn sortStrings(values: [][]const u8) void {
    std.mem.sort([]const u8, values, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
}

fn sortGenericTestDefs(tests: []GenericTestDef) void {
    std.mem.sort(GenericTestDef, tests, {}, struct {
        fn lessThan(_: void, a: GenericTestDef, b: GenericTestDef) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}

fn sortNodes(nodes: []Node) void {
    std.mem.sort(Node, nodes, {}, struct {
        fn lessThan(_: void, a: Node, b: Node) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
        }
    }.lessThan);
}

fn sortTests(tests: []GenericTestNode) void {
    std.mem.sort(GenericTestNode, tests, {}, struct {
        fn lessThan(_: void, a: GenericTestNode, b: GenericTestNode) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
        }
    }.lessThan);
}

fn sortSources(sources: []SourceDef) void {
    std.mem.sort(SourceDef, sources, {}, struct {
        fn lessThan(_: void, a: SourceDef, b: SourceDef) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
        }
    }.lessThan);
}

fn sortExposures(exposures: []ExposureDef) void {
    std.mem.sort(ExposureDef, exposures, {}, struct {
        fn lessThan(_: void, a: ExposureDef, b: ExposureDef) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
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

fn sortDocs(docs: []DocBlock) void {
    std.mem.sort(DocBlock, docs, {}, struct {
        fn lessThan(_: void, a: DocBlock, b: DocBlock) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
        }
    }.lessThan);
}

fn sortMacros(macros: []MacroDef) void {
    std.mem.sort(MacroDef, macros, {}, struct {
        fn lessThan(_: void, a: MacroDef, b: MacroDef) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
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

fn skipWs(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\r' or text[i] == '\n')) i += 1;
    return i;
}

fn findMatchingParen(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var quote: ?u8 = null;
    var i = open;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (quote) |q| {
            if (ch == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (ch == q) quote = null;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
        } else if (ch == '(') {
            depth += 1;
        } else if (ch == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn isIdentStart(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
}

fn isIdentChar(ch: u8) bool {
    return isIdentStart(ch) or (ch >= '0' and ch <= '9');
}

fn findKeyword(text: []const u8, keyword: []const u8) ?usize {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, keyword)) |pos| {
        const before_ok = pos == 0 or !isIdentChar(text[pos - 1]);
        const after = pos + keyword.len;
        const after_ok = after >= text.len or !isIdentChar(text[after]);
        if (before_ok and after_ok) return pos;
        i = after;
    }
    return null;
}

fn findValueStart(text: []const u8, start: usize) ?usize {
    var i = skipWs(text, start);
    if (i >= text.len or text[i] != '=') return null;
    i = skipWs(text, i + 1);
    if (i >= text.len) return null;
    return i;
}

fn hasNode(graph: *const Graph, unique_id: []const u8) bool {
    for (graph.nodes.items) |node| {
        if (node.enabled and std.mem.eql(u8, node.unique_id, unique_id)) return true;
    }
    return false;
}

fn hasDisabledNode(graph: *const Graph, unique_id: []const u8) bool {
    for (graph.nodes.items) |node| {
        if (!node.enabled and std.mem.eql(u8, node.unique_id, unique_id)) return true;
    }
    return false;
}

fn findDoc(graph: *const Graph, unique_id: []const u8) ?DocBlock {
    for (graph.docs.items) |doc| {
        if (std.mem.eql(u8, doc.unique_id, unique_id)) return doc;
    }
    return null;
}

fn findModelIndexByName(graph: *const Graph, name: []const u8) ?usize {
    for (graph.nodes.items, 0..) |node, index| {
        if (std.mem.eql(u8, node.resource_type, "model") and std.mem.eql(u8, node.name, name)) return index;
    }
    return null;
}

fn countActiveNodes(graph: *const Graph) usize {
    var count: usize = 0;
    for (graph.nodes.items) |node| {
        if (node.enabled and std.mem.eql(u8, node.resource_type, "model")) count += 1;
    }
    return count;
}

fn countActiveSeeds(graph: *const Graph) usize {
    var count: usize = 0;
    for (graph.nodes.items) |node| {
        if (node.enabled and std.mem.eql(u8, node.resource_type, "seed")) count += 1;
    }
    return count;
}

fn countActiveExposures(graph: *const Graph) usize {
    var count: usize = 0;
    for (graph.exposures.items) |exposure| {
        if (exposure.enabled) count += 1;
    }
    return count;
}

fn hasSource(graph: *const Graph, unique_id: []const u8) bool {
    for (graph.sources.items) |source| {
        if (std.mem.eql(u8, source.unique_id, unique_id)) return true;
    }
    return false;
}

fn hasMacro(graph: *const Graph, unique_id: []const u8) bool {
    for (graph.macros.items) |macro| {
        if (std.mem.eql(u8, macro.unique_id, unique_id)) return true;
    }
    return false;
}

fn findProjectMacroIdByName(graph: *const Graph, name: []const u8) ?[]const u8 {
    for (graph.macros.items) |macro| {
        if (std.mem.eql(u8, macro.name, name)) return macro.unique_id;
    }
    return null;
}

fn findMacroIndexByName(graph: *const Graph, name: []const u8) ?usize {
    for (graph.macros.items, 0..) |macro, index| {
        if (std.mem.eql(u8, macro.name, name)) return index;
    }
    return null;
}

fn parseBool(value: []const u8) !bool {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (std.ascii.eqlIgnoreCase(trimmed, "true")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "false")) return false;
    return error.UnsupportedYaml;
}

fn isJsonNumber(value: []const u8) bool {
    if (value.len == 0) return false;
    var i: usize = 0;
    if (value[i] == '-') {
        i += 1;
        if (i == value.len) return false;
    }
    if (value[i] == '0') {
        i += 1;
        if (i < value.len and std.ascii.isDigit(value[i])) return false;
    } else if (value[i] >= '1' and value[i] <= '9') {
        i += 1;
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {}
    } else {
        return false;
    }
    if (i < value.len and value[i] == '.') {
        i += 1;
        var frac_digits: usize = 0;
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {
            frac_digits += 1;
        }
        if (frac_digits == 0) return false;
    }
    if (i < value.len and (value[i] == 'e' or value[i] == 'E')) {
        i += 1;
        if (i < value.len and (value[i] == '+' or value[i] == '-')) i += 1;
        var exp_digits: usize = 0;
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {
            exp_digits += 1;
        }
        if (exp_digits == 0) return false;
    }
    return i == value.len;
}

test "json number parser rejects invalid leading zero forms" {
    try std.testing.expect(isJsonNumber("0"));
    try std.testing.expect(isJsonNumber("-12.5e+3"));
    try std.testing.expect(!isJsonNumber("007"));
    try std.testing.expect(!isJsonNumber("-01"));
    try std.testing.expect(!isJsonNumber("1."));
}

fn testNameFromYamlItem(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (trimmed.len == 0) return error.UnsupportedYaml;
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse trimmed.len;
    return try dupTrimmedScalar(allocator, trimmed[0..colon]);
}

fn appendUnique(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8), value: []const u8) !void {
    if (!containsString(values.items, value)) {
        try values.append(allocator, value);
    }
}

fn containsString(values: []const []const u8, value: []const u8) bool {
    for (values) |candidate| {
        if (std.mem.eql(u8, candidate, value)) return true;
    }
    return false;
}

fn trimPlus(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, "+");
}

test "project yaml parser reads dbt name and inline model paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "name: demo\nmodel-paths: [\"models\", marts]\ntarget-path: target-dxt\n";
    var parsed_paths: std.ArrayList([]const u8) = .empty;
    defer parsed_paths.deinit(allocator);
    var lines = std.mem.splitScalar(u8, input, '\n');
    var project_name: []const u8 = "";
    while (lines.next()) |line| {
        if (splitKeyValue(stripYamlComment(line))) |kv| {
            if (std.mem.eql(u8, kv.key, "name")) project_name = try dupTrimmedScalar(allocator, kv.value);
            if (std.mem.eql(u8, kv.key, "model-paths")) try parseInlineStringList(allocator, kv.value, &parsed_paths);
        }
    }

    try std.testing.expectEqualStrings("demo", project_name);
    try std.testing.expectEqual(@as(usize, 2), parsed_paths.items.len);
    try std.testing.expectEqualStrings("models", parsed_paths.items[0]);
    try std.testing.expectEqualStrings("marts", parsed_paths.items[1]);
}

test "sql scanner extracts refs sources and config tags from jinja spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var node = Node{
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "",
    };
    defer {
        node.tags.deinit(allocator);
        node.refs.deinit(allocator);
        node.source_refs.deinit(allocator);
        node.depends_on.deinit(allocator);
        node.macro_depends_on.deinit(allocator);
    }

    try scanSql(allocator,
        \\{{ config(materialized="table", tags=["nightly", 'core']) }}
        \\select * from {{ ref("stg_customers") }}
        \\union all select * from {{ source('raw', "customers") }}
        \\select {{ "ref('not_a_dependency')" }} as literal_ref
        \\{# {{ ref("ignored") }} #}
    , &node, null);

    try std.testing.expectEqual(@as(usize, 1), node.refs.items.len);
    try std.testing.expectEqualStrings("stg_customers", node.refs.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), node.source_refs.items.len);
    try std.testing.expectEqualStrings("raw", node.source_refs.items[0].source_name);
    try std.testing.expectEqualStrings("customers", node.source_refs.items[0].table_name);
    try std.testing.expectEqualStrings("table", node.materialized);
    try std.testing.expectEqual(@as(usize, 2), node.tags.items.len);
}
