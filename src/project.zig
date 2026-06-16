const std = @import("std");
const Io = std.Io;
const project_config = @import("project/config.zig");
const manifest = @import("project/manifest.zig");
const selector = @import("project/selector.zig");
const types = @import("project/types.zig");
const util = @import("project/util.zig");

pub const Runtime = types.Runtime;
pub const Options = types.Options;
pub const Output = types.Output;

const ModelPathConfig = types.ModelPathConfig;
const DocsConfig = types.DocsConfig;
const SourceDef = types.SourceDef;
const ExposureDef = types.ExposureDef;
const MetaEntry = types.MetaEntry;
const JsonScalar = types.JsonScalar;
const RefDep = types.RefDep;
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
const loadProjectConfig = project_config.loadProjectConfig;
const stripYamlComment = util.stripYamlComment;
const leadingSpaces = util.leadingSpaces;
const splitKeyValue = util.splitKeyValue;
const parseInlineStringList = util.parseInlineStringList;
const dupTrimmedScalar = util.dupTrimmedScalar;
const sortStrings = util.sortStrings;

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
    const fd = openLinuxDirectory(runtime.allocator, packages_dir) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer closeLinuxFd(fd);

    var package_dirs: std.ArrayList([]const u8) = .empty;
    defer package_dirs.deinit(runtime.allocator);

    var buffer: [8192]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    var iter = LinuxDirReadState{ .fd = fd, .buffer = &buffer };
    while (try nextLinuxDirectoryEntry(&iter)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const child_abs = try pathJoin(runtime.allocator, &.{ packages_dir, entry.name });
        const is_dir = if (entry.kind == .directory)
            true
        else if (entry.kind == .unknown)
            try linuxPathIsDirectory(runtime.allocator, child_abs)
        else
            false;
        if (is_dir) {
            try package_dirs.append(runtime.allocator, child_abs);
        }
    }
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
    const fd = openLinuxDirectory(runtime.allocator, packages_dir) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer closeLinuxFd(fd);

    var package_dirs: std.ArrayList([]const u8) = .empty;
    defer package_dirs.deinit(runtime.allocator);

    var buffer: [8192]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    var iter = LinuxDirReadState{ .fd = fd, .buffer = &buffer };
    while (try nextLinuxDirectoryEntry(&iter)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const child_abs = try pathJoin(runtime.allocator, &.{ packages_dir, entry.name });
        const is_dir = if (entry.kind == .directory)
            true
        else if (entry.kind == .unknown)
            try linuxPathIsDirectory(runtime.allocator, child_abs)
        else
            false;
        if (is_dir) {
            try package_dirs.append(runtime.allocator, child_abs);
        }
    }
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
            discoverFiles(runtime, root, model_path, &sql_files, &yaml_files, &md_files) catch |err| switch (err) {
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
    try scanSql(runtime.allocator, sql, &node, graph);
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

fn applyProjectModelPathConfigs(graph: *Graph, configs: []const ModelPathConfig, override_dependency_inline: bool, restrict_package_name: ?[]const u8) !void {
    for (graph.nodes.items) |*node| {
        if (!std.mem.eql(u8, node.resource_type, "model")) continue;

        var materialized_config: ?*const ModelPathConfig = null;
        var materialized_depth: usize = 0;
        var docs_config: ?*const ModelPathConfig = null;
        var docs_depth: usize = 0;
        for (configs) |*config| {
            if (restrict_package_name) |package_name| {
                if (!std.mem.eql(u8, config.package_name, package_name)) continue;
            }
            if (!std.mem.eql(u8, node.package_name, config.package_name)) continue;
            if (!modelPathConfigMatches(config.path, node.path)) continue;
            const depth = modelPathConfigDepth(config.path);
            if (config.materialized.len != 0 and (materialized_config == null or depth >= materialized_depth)) {
                materialized_config = config;
                materialized_depth = depth;
            }
            for (config.tags.items) |tag| {
                try appendUnique(graph.allocator, &node.tags, tag);
            }
            if (config.docs.configured and (docs_config == null or depth >= docs_depth)) {
                docs_config = config;
                docs_depth = depth;
            }
        }

        const can_override_materialized = !node.inline_materialized or (override_dependency_inline and !std.mem.eql(u8, node.package_name, graph.project_name));
        if (can_override_materialized) {
            if (materialized_config) |config| node.materialized = config.materialized;
        }
        if (docs_config) |config| node.docs = config.docs;
        sortStrings(node.tags.items);
    }
}

fn applyProjectSeedDocs(graph: *Graph, package_name: []const u8, docs: DocsConfig) void {
    if (!docs.configured) return;
    for (graph.nodes.items) |*node| {
        if (!std.mem.eql(u8, node.package_name, package_name)) continue;
        if (!std.mem.eql(u8, node.resource_type, "seed")) continue;
        node.docs = docs;
    }
}

fn modelPathConfigMatches(config_path: []const u8, model_path: []const u8) bool {
    if (config_path.len == 0) return true;
    if (!std.mem.startsWith(u8, model_path, config_path)) return false;
    if (model_path.len == config_path.len) return true;
    if (model_path[config_path.len] == '/') return true;
    return std.mem.eql(u8, model_path[config_path.len..], ".sql");
}

fn modelPathConfigDepth(config_path: []const u8) usize {
    if (config_path.len == 0) return 0;
    var depth: usize = 1;
    for (config_path) |ch| {
        if (ch == '/') depth += 1;
    }
    return depth;
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
            if (std.mem.eql(u8, graph.macro_properties.items[i].package_name, graph.macro_properties.items[j].package_name) and
                std.mem.eql(u8, graph.macro_properties.items[i].name, graph.macro_properties.items[j].name))
            {
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

fn resolveDependencies(graph: *Graph) !void {
    for (graph.nodes.items) |*node| {
        if (!node.enabled) continue;
        for (node.macro_depends_on.items) |macro_dep| {
            if (!hasMacro(graph, macro_dep)) return error.UnresolvedMacro;
        }
        sortStrings(node.macro_depends_on.items);
        for (node.refs.items) |ref_dep| {
            try appendUnique(graph.allocator, &node.depends_on, try resolveRefDependency(graph, node.package_name, ref_dep));
        }
        for (node.source_refs.items) |source_dep| {
            try appendUnique(graph.allocator, &node.depends_on, try resolveSourceDependency(graph, node.package_name, source_dep));
        }
        sortStrings(node.depends_on.items);
    }
    for (graph.exposures.items) |*exposure| {
        if (!exposure.enabled) continue;
        for (exposure.refs.items) |ref_dep| {
            try appendUnique(graph.allocator, &exposure.depends_on, try resolveRefDependency(graph, exposure.package_name, ref_dep));
        }
        for (exposure.source_refs.items) |source_dep| {
            try appendUnique(graph.allocator, &exposure.depends_on, try resolveSourceDependency(graph, exposure.package_name, source_dep));
        }
        sortStrings(exposure.depends_on.items);
    }
}

fn resolveRefDependency(graph: *const Graph, current_package: []const u8, ref_dep: RefDep) ![]const u8 {
    const package = ref_dep.package orelse current_package;
    if (try resolveRefInPackage(graph, package, ref_dep.name)) |unique_id| return unique_id;
    if (ref_dep.package != null) return error.UnresolvedRef;

    var found: ?[]const u8 = null;
    for (graph.nodes.items) |node| {
        if (!std.mem.eql(u8, node.name, ref_dep.name)) continue;
        if (!std.mem.eql(u8, node.resource_type, "model") and !std.mem.eql(u8, node.resource_type, "seed")) continue;
        if (!node.enabled) continue;
        if (found != null) return error.UnresolvedRef;
        found = node.unique_id;
    }
    return found orelse error.UnresolvedRef;
}

fn resolveRefInPackage(graph: *const Graph, package: []const u8, name: []const u8) !?[]const u8 {
    const model_id = try std.fmt.allocPrint(graph.allocator, "model.{s}.{s}", .{ package, name });
    if (hasDisabledNode(graph, model_id)) return error.DisabledRef;
    if (hasNode(graph, model_id)) return model_id;

    const seed_id = try std.fmt.allocPrint(graph.allocator, "seed.{s}.{s}", .{ package, name });
    if (hasDisabledNode(graph, seed_id)) return error.DisabledRef;
    if (hasNode(graph, seed_id)) return seed_id;
    return null;
}

fn resolveSourceDependency(graph: *const Graph, current_package: []const u8, source_dep: SourceDep) ![]const u8 {
    const unique_id = try std.fmt.allocPrint(graph.allocator, "source.{s}.{s}.{s}", .{ current_package, source_dep.source_name, source_dep.table_name });
    if (hasSource(graph, unique_id)) return unique_id;

    var found: ?[]const u8 = null;
    for (graph.sources.items) |source| {
        if (!std.mem.eql(u8, source.source_name, source_dep.source_name)) continue;
        if (!std.mem.eql(u8, source.table_name, source_dep.table_name)) continue;
        if (found != null) return error.UnresolvedSource;
        found = source.unique_id;
    }
    return found orelse error.UnresolvedSource;
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

const JinjaCall = struct {
    package_name: ?[]const u8,
    name: []const u8,
    open: usize,
    close: usize,
};

fn readJinjaCall(span: []const u8, first_ident: []const u8, first_ident_end: usize) !?JinjaCall {
    if (first_ident_end < span.len and span[first_ident_end] == '.') {
        const name_start = first_ident_end + 1;
        if (name_start >= span.len or !isIdentStart(span[name_start])) return error.UnsupportedJinja;
        var name_end = name_start + 1;
        while (name_end < span.len and isIdentChar(span[name_end])) name_end += 1;
        const call_pos = skipWs(span, name_end);
        if (call_pos >= span.len or span[call_pos] != '(') return null;
        const close = findMatchingParen(span, call_pos) orelse return error.UnsupportedJinja;
        return .{
            .package_name = first_ident,
            .name = span[name_start..name_end],
            .open = call_pos,
            .close = close,
        };
    }

    const call_pos = skipWs(span, first_ident_end);
    if (call_pos >= span.len or span[call_pos] != '(') return null;
    const close = findMatchingParen(span, call_pos) orelse return error.UnsupportedJinja;
    return .{
        .package_name = null,
        .name = first_ident,
        .open = call_pos,
        .close = close,
    };
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
        const call = (try readJinjaCall(span, ident, i)) orelse continue;
        const args = span[call.open + 1 .. call.close];

        if (call.package_name) |package_name| {
            if (graph) |known_graph| {
                if (findMacroIdByPackageAndName(known_graph, package_name, call.name)) |macro_id| {
                    try appendUnique(allocator, &node.macro_depends_on, macro_id);
                    i = call.close + 1;
                    continue;
                }
                if (hasMacroPackage(known_graph, package_name)) return error.UnresolvedMacro;
            }
            return error.UnsupportedJinja;
        } else if (std.mem.eql(u8, call.name, "ref")) {
            var strings = try parseLiteralArgs(allocator, args, error.UnsupportedDynamicRef);
            defer strings.deinit(allocator);
            if (!(strings.items.len == 1 or strings.items.len == 2)) return error.UnsupportedDynamicRef;
            try node.refs.append(allocator, .{
                .package = if (strings.items.len == 2) strings.items[0] else null,
                .name = if (strings.items.len == 2) strings.items[1] else strings.items[0],
            });
        } else if (std.mem.eql(u8, call.name, "source")) {
            var strings = try parseLiteralArgs(allocator, args, error.UnsupportedDynamicSource);
            defer strings.deinit(allocator);
            if (strings.items.len != 2) return error.UnsupportedDynamicSource;
            try node.source_refs.append(allocator, .{
                .source_name = strings.items[0],
                .table_name = strings.items[1],
            });
        } else if (std.mem.eql(u8, call.name, "config")) {
            try parseConfig(allocator, args, node);
        } else {
            if (graph) |known_graph| {
                if (findMacroIdForUnqualifiedCall(known_graph, node.package_name, call.name)) |macro_id| {
                    try appendUnique(allocator, &node.macro_depends_on, macro_id);
                    i = call.close + 1;
                    continue;
                }
            }
            return error.UnsupportedJinja;
        }
        i = call.close + 1;
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
    const current_package = packageNameFromMacroUniqueId(current_macro_id) orelse graph.project_name;
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
        const call = (readJinjaCall(span, ident, i) catch break) orelse continue;
        const macro_id = if (call.package_name) |package_name| blk: {
            const resolved = findMacroIdByPackageAndName(graph, package_name, call.name);
            if (resolved == null and hasMacroPackage(graph, package_name)) return error.UnresolvedMacro;
            break :blk resolved;
        } else findMacroIdForUnqualifiedCall(graph, current_package, call.name);
        if (macro_id) |resolved_macro_id| {
            if (std.mem.eql(u8, resolved_macro_id, current_macro_id)) {
                i = call.close + 1;
                continue;
            }
            try appendUnique(allocator, macro_depends_on, resolved_macro_id);
        }
        i = call.close + 1;
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
            node.inline_materialized = true;
        }
    }
    if (findKeyword(args, "tags")) |pos| {
        if (findValueStart(args, pos + "tags".len)) |value_pos| {
            try parseTagList(allocator, args[value_pos..], &node.tags);
            node.inline_tags = true;
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

fn refDepFromValue(allocator: std.mem.Allocator, value: []const u8) !RefDep {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (std.mem.startsWith(u8, trimmed, "ref(")) {
        const open = std.mem.indexOfScalar(u8, trimmed, '(') orelse return error.UnsupportedRef;
        const close = findMatchingParen(trimmed, open) orelse return error.UnsupportedRef;
        const args = std.mem.trim(u8, trimmed[open + 1 .. close], " \t\r");
        var strings = try parseLiteralArgs(allocator, args, error.UnsupportedRef);
        defer strings.deinit(allocator);
        if (!(strings.items.len == 1 or strings.items.len == 2)) return error.UnsupportedRef;
        return .{
            .package = if (strings.items.len == 2) strings.items[0] else null,
            .name = if (strings.items.len == 2) strings.items[1] else strings.items[0],
        };
    }
    return .{ .package = null, .name = try dupTrimmedScalar(allocator, trimmed) };
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

fn findModelIndexByName(graph: *const Graph, package_name: []const u8, name: []const u8) ?usize {
    for (graph.nodes.items, 0..) |node, index| {
        if (std.mem.eql(u8, node.package_name, package_name) and std.mem.eql(u8, node.resource_type, "model") and std.mem.eql(u8, node.name, name)) return index;
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

fn hasMacroPackage(graph: *const Graph, package_name: []const u8) bool {
    for (graph.macros.items) |macro| {
        if (std.mem.eql(u8, macro.package_name, package_name)) return true;
    }
    return false;
}

fn findMacroIdByPackageAndName(graph: *const Graph, package_name: []const u8, name: []const u8) ?[]const u8 {
    for (graph.macros.items) |macro| {
        if (std.mem.eql(u8, macro.package_name, package_name) and std.mem.eql(u8, macro.name, name)) return macro.unique_id;
    }
    return null;
}

fn findMacroIdForUnqualifiedCall(graph: *const Graph, package_name: []const u8, name: []const u8) ?[]const u8 {
    if (findMacroIdByPackageAndName(graph, package_name, name)) |macro_id| return macro_id;
    if (!std.mem.eql(u8, package_name, graph.project_name)) {
        return findProjectMacroIdByName(graph, name);
    }
    return null;
}

fn findProjectMacroIdByName(graph: *const Graph, name: []const u8) ?[]const u8 {
    return findMacroIdByPackageAndName(graph, graph.project_name, name);
}

fn packageNameFromMacroUniqueId(unique_id: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, unique_id, "macro.")) return null;
    const package_start = "macro.".len;
    const package_end = std.mem.indexOfPos(u8, unique_id, package_start, ".") orelse return null;
    return unique_id[package_start..package_end];
}

fn findProjectMacroIndexByName(graph: *const Graph, name: []const u8) ?usize {
    return findMacroIndexByPackageAndName(graph, graph.project_name, name);
}

fn findMacroIndexByPackageAndName(graph: *const Graph, package_name: []const u8, name: []const u8) ?usize {
    for (graph.macros.items, 0..) |macro, index| {
        if (std.mem.eql(u8, macro.package_name, package_name) and std.mem.eql(u8, macro.name, name)) return index;
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
    if (!util.containsString(values.items, value)) {
        try values.append(allocator, value);
    }
}

test "sql scanner extracts refs sources and config tags from jinja spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var node = Node{
        .package_name = "demo",
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
