const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");

const Runtime = types.Runtime;
const ProjectConfig = types.ProjectConfig;
const ModelPathConfig = types.ModelPathConfig;
const DocsConfig = types.DocsConfig;
const deinitProjectConfig = types.deinitProjectConfig;
const KeyValue = util.KeyValue;
const stripYamlComment = util.stripYamlComment;
const leadingSpaces = util.leadingSpaces;
const splitKeyValue = util.splitKeyValue;
const parseInlineStringList = util.parseInlineStringList;
const dupTrimmedScalar = util.dupTrimmedScalar;
const sortStrings = util.sortStrings;

pub fn loadProjectConfig(runtime: Runtime, project_dir: []const u8) !ProjectConfig {
    const path = try std.fs.path.join(runtime.allocator, &.{ project_dir, "dbt_project.yml" });
    const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.MissingProjectFile,
        else => return err,
    };
    return try parseProjectConfigText(runtime.allocator, text);
}

fn parseProjectConfigText(allocator: std.mem.Allocator, text: []const u8) !ProjectConfig {
    var config = ProjectConfig{ .name = "" };
    errdefer {
        deinitProjectConfig(allocator, &config);
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
                try config.model_paths.append(allocator, try dupTrimmedScalar(allocator, trimmed[2..]));
                continue;
            }
            read_model_path_block = false;
        }
        if (read_seed_path_block) {
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                try config.seed_paths.append(allocator, try dupTrimmedScalar(allocator, trimmed[2..]));
                continue;
            }
            read_seed_path_block = false;
        }
        if (read_macro_path_block) {
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                try config.macro_paths.append(allocator, try dupTrimmedScalar(allocator, trimmed[2..]));
                continue;
            }
            read_macro_path_block = false;
        }

        if (splitKeyValue(trimmed)) |kv| {
            if (std.mem.eql(u8, kv.key, "name")) {
                config.name = try dupTrimmedScalar(allocator, kv.value);
            } else if (std.mem.eql(u8, kv.key, "target-path")) {
                config.target_path = try dupTrimmedScalar(allocator, kv.value);
            } else if (std.mem.eql(u8, kv.key, "model-paths")) {
                if (std.mem.trim(u8, kv.value, " \t").len == 0) {
                    read_model_path_block = true;
                } else {
                    try parseInlineStringList(allocator, kv.value, &config.model_paths);
                }
            } else if (std.mem.eql(u8, kv.key, "seed-paths")) {
                if (std.mem.trim(u8, kv.value, " \t").len == 0) {
                    read_seed_path_block = true;
                } else {
                    try parseInlineStringList(allocator, kv.value, &config.seed_paths);
                }
            } else if (std.mem.eql(u8, kv.key, "macro-paths")) {
                config.macro_paths_set = true;
                if (std.mem.trim(u8, kv.value, " \t").len == 0) {
                    read_macro_path_block = true;
                } else {
                    try parseInlineStringList(allocator, kv.value, &config.macro_paths);
                }
            }
        }
    }

    if (config.name.len == 0) return error.InvalidProjectName;
    try parseProjectModelPathConfigs(allocator, text, &config.model_path_configs);
    try parseProjectSeedDocs(allocator, text, &config.seed_docs);
    if (config.model_paths.items.len == 0) {
        try config.model_paths.append(allocator, "models");
    }
    if (config.seed_paths.items.len == 0) {
        try config.seed_paths.append(allocator, "seeds");
    }
    if (!config.macro_paths_set) {
        try config.macro_paths.append(allocator, "macros");
    }
    return config;
}

const PathStackEntry = struct {
    indent: usize,
    name: []const u8,
};

fn parseProjectModelPathConfigs(allocator: std.mem.Allocator, text: []const u8, configs: *std.ArrayList(ModelPathConfig)) !void {
    var in_models = false;
    var in_package = false;
    var in_docs = false;
    var models_indent: usize = 0;
    var package_indent: usize = 0;
    var docs_indent: usize = 0;
    var package_name: []const u8 = "";
    var docs_path: []const u8 = "";
    var path_stack: std.ArrayList(PathStackEntry) = .empty;
    defer path_stack.deinit(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);

        if (std.mem.eql(u8, trimmed, "models:")) {
            in_models = true;
            in_package = false;
            models_indent = indent;
            package_name = "";
            path_stack.clearRetainingCapacity();
            continue;
        }
        if (!in_models) continue;
        if (indent <= models_indent and !std.mem.eql(u8, trimmed, "models:")) {
            in_models = false;
            in_package = false;
            package_name = "";
            path_stack.clearRetainingCapacity();
            continue;
        }

        const kv = splitKeyValue(trimmed) orelse continue;

        if (in_docs) {
            if (indent <= docs_indent) {
                in_docs = false;
            } else {
                const path_config = try getOrCreateModelPathConfig(allocator, configs, package_name, docs_path);
                try applyDocsConfigKeyValue(allocator, &path_config.docs, kv);
                continue;
            }
        }

        if (!in_package) {
            if (indent > models_indent and !std.mem.startsWith(u8, kv.key, "+") and std.mem.trim(u8, kv.value, " \t").len == 0) {
                in_package = true;
                package_indent = indent;
                package_name = try dupTrimmedScalar(allocator, kv.key);
                path_stack.clearRetainingCapacity();
            }
            continue;
        }

        if (indent <= package_indent) {
            in_package = false;
            package_name = "";
            path_stack.clearRetainingCapacity();
            if (indent > models_indent and !std.mem.startsWith(u8, kv.key, "+") and std.mem.trim(u8, kv.value, " \t").len == 0) {
                in_package = true;
                package_indent = indent;
                package_name = try dupTrimmedScalar(allocator, kv.key);
            }
            continue;
        }

        while (path_stack.items.len != 0 and indent <= path_stack.items[path_stack.items.len - 1].indent) {
            _ = path_stack.pop();
        }

        if (std.mem.startsWith(u8, kv.key, "+")) {
            const path = try joinPathStack(allocator, path_stack.items);
            if (std.mem.eql(u8, kv.key, "+materialized")) {
                const path_config = try getOrCreateModelPathConfig(allocator, configs, package_name, path);
                path_config.materialized = try dupTrimmedScalar(allocator, kv.value);
            } else if (std.mem.eql(u8, kv.key, "+tags")) {
                const path_config = try getOrCreateModelPathConfig(allocator, configs, package_name, path);
                path_config.tags.clearRetainingCapacity();
                try parseInlineStringList(allocator, kv.value, &path_config.tags);
                sortStrings(path_config.tags.items);
            } else if (std.mem.eql(u8, kv.key, "+docs") and std.mem.trim(u8, kv.value, " \t").len == 0) {
                const path_config = try getOrCreateModelPathConfig(allocator, configs, package_name, path);
                path_config.docs.configured = true;
                in_docs = true;
                docs_indent = indent;
                docs_path = path_config.path;
            }
            continue;
        }

        if (std.mem.trim(u8, kv.value, " \t").len == 0) {
            try path_stack.append(allocator, .{ .indent = indent, .name = try dupTrimmedScalar(allocator, kv.key) });
        }
    }
}

fn parseProjectSeedDocs(allocator: std.mem.Allocator, text: []const u8, docs: *DocsConfig) !void {
    var in_seeds = false;
    var in_docs = false;
    var seeds_indent: usize = 0;
    var docs_indent: usize = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);

        if (std.mem.eql(u8, trimmed, "seeds:")) {
            in_seeds = true;
            in_docs = false;
            seeds_indent = indent;
            continue;
        }
        if (!in_seeds) continue;
        if (indent <= seeds_indent and !std.mem.eql(u8, trimmed, "seeds:")) {
            in_seeds = false;
            in_docs = false;
            continue;
        }

        const kv = splitKeyValue(trimmed) orelse continue;
        if (in_docs) {
            if (indent <= docs_indent) {
                in_docs = false;
            } else {
                try applyDocsConfigKeyValue(allocator, docs, kv);
                continue;
            }
        }

        if (std.mem.eql(u8, kv.key, "+docs") and std.mem.trim(u8, kv.value, " \t").len == 0) {
            docs.configured = true;
            in_docs = true;
            docs_indent = indent;
        }
    }
}

fn applyDocsConfigKeyValue(allocator: std.mem.Allocator, docs: *DocsConfig, kv: KeyValue) !void {
    if (std.mem.eql(u8, kv.key, "node_color")) {
        docs.configured = true;
        docs.node_color = try dupTrimmedScalar(allocator, kv.value);
    } else if (std.mem.eql(u8, kv.key, "show")) {
        docs.configured = true;
        docs.show = !std.mem.eql(u8, std.mem.trim(u8, kv.value, " \t\r"), "false");
    }
}

fn joinPathStack(allocator: std.mem.Allocator, stack: []const PathStackEntry) ![]const u8 {
    if (stack.len == 0) return "";
    var total: usize = 0;
    for (stack) |entry| {
        total += entry.name.len;
    }
    total += stack.len - 1;
    var out = try allocator.alloc(u8, total);
    var index: usize = 0;
    for (stack, 0..) |entry, entry_index| {
        if (entry_index != 0) {
            out[index] = '/';
            index += 1;
        }
        @memcpy(out[index .. index + entry.name.len], entry.name);
        index += entry.name.len;
    }
    return out;
}

fn getOrCreateModelPathConfig(allocator: std.mem.Allocator, configs: *std.ArrayList(ModelPathConfig), package_name: []const u8, path: []const u8) !*ModelPathConfig {
    for (configs.items) |*config| {
        if (std.mem.eql(u8, config.package_name, package_name) and std.mem.eql(u8, config.path, path)) return config;
    }
    try configs.append(allocator, .{ .package_name = package_name, .path = path });
    return &configs.items[configs.items.len - 1];
}

test "project config parser applies defaults for omitted paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try parseProjectConfigText(allocator, "name: demo\n");
    defer deinitProjectConfig(allocator, &config);

    try std.testing.expectEqualStrings("demo", config.name);
    try std.testing.expectEqualStrings("target", config.target_path);
    try std.testing.expectEqual(@as(usize, 1), config.model_paths.items.len);
    try std.testing.expectEqualStrings("models", config.model_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 1), config.seed_paths.items.len);
    try std.testing.expectEqualStrings("seeds", config.seed_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 1), config.macro_paths.items.len);
    try std.testing.expectEqualStrings("macros", config.macro_paths.items[0]);
}

test "project config parser rejects missing project name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.InvalidProjectName, parseProjectConfigText(allocator, "model-paths: [models]\n"));
}

test "project config parser reads paths and nested docs configs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text =
        \\name: demo
        \\target-path: target-dxt
        \\model-paths: ["models", marts]
        \\seed-paths:
        \\  - data
        \\macro-paths:
        \\  - custom_macros
        \\models:
        \\  demo:
        \\    marts:
        \\      +materialized: table
        \\      +tags: ["nightly", core]
        \\      +docs:
        \\        node_color: "#336699"
        \\seeds:
        \\  +docs:
        \\    show: false
    ;

    var config = try parseProjectConfigText(allocator, text);
    defer deinitProjectConfig(allocator, &config);

    try std.testing.expectEqualStrings("demo", config.name);
    try std.testing.expectEqualStrings("target-dxt", config.target_path);
    try std.testing.expectEqual(@as(usize, 2), config.model_paths.items.len);
    try std.testing.expectEqualStrings("models", config.model_paths.items[0]);
    try std.testing.expectEqualStrings("marts", config.model_paths.items[1]);
    try std.testing.expectEqual(@as(usize, 1), config.seed_paths.items.len);
    try std.testing.expectEqualStrings("data", config.seed_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 1), config.macro_paths.items.len);
    try std.testing.expectEqualStrings("custom_macros", config.macro_paths.items[0]);
    try std.testing.expect(config.macro_paths_set);

    try std.testing.expectEqual(@as(usize, 1), config.model_path_configs.items.len);
    const model_config = config.model_path_configs.items[0];
    try std.testing.expectEqualStrings("demo", model_config.package_name);
    try std.testing.expectEqualStrings("marts", model_config.path);
    try std.testing.expectEqualStrings("table", model_config.materialized);
    try std.testing.expectEqual(@as(usize, 2), model_config.tags.items.len);
    try std.testing.expectEqualStrings("core", model_config.tags.items[0]);
    try std.testing.expectEqualStrings("nightly", model_config.tags.items[1]);
    try std.testing.expect(model_config.docs.configured);
    try std.testing.expectEqualStrings("#336699", model_config.docs.node_color.?);
    try std.testing.expect(config.seed_docs.configured);
    try std.testing.expect(!config.seed_docs.show);
}
