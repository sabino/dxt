const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");

const Runtime = types.Runtime;
const ProjectConfig = types.ProjectConfig;
const ModelPathConfig = types.ModelPathConfig;
const DispatchConfig = types.DispatchConfig;
const DocsConfig = types.DocsConfig;
const Graph = types.Graph;
const VarEntry = types.VarEntry;
const deinitProjectConfig = types.deinitProjectConfig;
const KeyValue = util.KeyValue;
const appendUnique = util.appendUnique;
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

pub fn applyProjectModelPathConfigs(graph: *Graph, configs: []const ModelPathConfig, override_dependency_inline: bool, restrict_package_name: ?[]const u8) !void {
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

pub fn applyProjectSeedDocs(graph: *Graph, package_name: []const u8, docs: DocsConfig) void {
    if (!docs.configured) return;
    for (graph.nodes.items) |*node| {
        if (!std.mem.eql(u8, node.package_name, package_name)) continue;
        if (!std.mem.eql(u8, node.resource_type, "seed")) continue;
        node.docs = docs;
    }
}

pub fn appendOrReplaceVar(allocator: std.mem.Allocator, vars: *std.ArrayList(VarEntry), raw_name: []const u8, raw_value: []const u8) !void {
    const trimmed_name = std.mem.trim(u8, raw_name, " \t\r");
    const trimmed_value = std.mem.trim(u8, raw_value, " \t\r");
    if (trimmed_name.len == 0 or trimmed_value.len == 0) return error.UnsupportedYaml;
    if (trimmed_value[0] == '[' or trimmed_value[0] == '{') return error.UnsupportedYaml;

    const name = try dupTrimmedScalar(allocator, trimmed_name);
    const value = try dupTrimmedScalar(allocator, trimmed_value);
    if (name.len == 0 or value.len == 0) return error.UnsupportedYaml;
    for (vars.items) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            entry.value = value;
            return;
        }
    }
    try vars.append(allocator, .{ .name = name, .value = value });
}

pub fn parseVarsText(allocator: std.mem.Allocator, text: []const u8, vars: *std.ArrayList(VarEntry)) !void {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "{}")) return;
    if (trimmed[0] == '[') return error.UnsupportedYaml;
    if (trimmed[0] == '{') {
        if (trimmed[trimmed.len - 1] != '}') return error.UnsupportedYaml;
        var pieces = std.mem.splitScalar(u8, trimmed[1 .. trimmed.len - 1], ',');
        while (pieces.next()) |piece| {
            const item = std.mem.trim(u8, piece, " \t\r\n");
            if (item.len == 0) continue;
            const kv = splitKeyValue(item) orelse return error.UnsupportedYaml;
            try appendOrReplaceVar(allocator, vars, kv.key, kv.value);
        }
        sortVars(vars.items);
        return;
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    var saw_var = false;
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const line_trimmed = std.mem.trim(u8, line, " \t\r");
        if (line_trimmed.len == 0) continue;
        const kv = splitKeyValue(line_trimmed) orelse return error.UnsupportedYaml;
        try appendOrReplaceVar(allocator, vars, kv.key, kv.value);
        saw_var = true;
    }
    if (!saw_var) return error.UnsupportedYaml;
    sortVars(vars.items);
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
    var read_test_path_block = false;
    var read_analysis_path_block = false;
    var read_snapshot_path_block = false;
    var read_function_path_block = false;
    var read_clean_targets_block = false;
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
        if (read_test_path_block) {
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                try config.test_paths.append(allocator, try dupTrimmedScalar(allocator, trimmed[2..]));
                continue;
            }
            read_test_path_block = false;
        }
        if (read_analysis_path_block) {
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                try config.analysis_paths.append(allocator, try dupTrimmedScalar(allocator, trimmed[2..]));
                continue;
            }
            read_analysis_path_block = false;
        }
        if (read_snapshot_path_block) {
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                try config.snapshot_paths.append(allocator, try dupTrimmedScalar(allocator, trimmed[2..]));
                continue;
            }
            read_snapshot_path_block = false;
        }
        if (read_function_path_block) {
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                try config.function_paths.append(allocator, try dupTrimmedScalar(allocator, trimmed[2..]));
                continue;
            }
            read_function_path_block = false;
        }
        if (read_clean_targets_block) {
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                try config.clean_targets.append(allocator, try dupTrimmedScalar(allocator, trimmed[2..]));
                continue;
            }
            read_clean_targets_block = false;
        }

        if (splitKeyValue(trimmed)) |kv| {
            if (std.mem.eql(u8, kv.key, "name")) {
                config.name = try dupTrimmedScalar(allocator, kv.value);
            } else if (std.mem.eql(u8, kv.key, "profile")) {
                config.profile_name = try dupTrimmedScalar(allocator, kv.value);
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
            } else if (std.mem.eql(u8, kv.key, "test-paths")) {
                if (std.mem.trim(u8, kv.value, " \t").len == 0) {
                    read_test_path_block = true;
                } else {
                    try parseInlineStringList(allocator, kv.value, &config.test_paths);
                }
            } else if (std.mem.eql(u8, kv.key, "analysis-paths")) {
                if (std.mem.trim(u8, kv.value, " \t").len == 0) {
                    read_analysis_path_block = true;
                } else {
                    try parseInlineStringList(allocator, kv.value, &config.analysis_paths);
                }
            } else if (std.mem.eql(u8, kv.key, "snapshot-paths")) {
                if (std.mem.trim(u8, kv.value, " \t").len == 0) {
                    read_snapshot_path_block = true;
                } else {
                    try parseInlineStringList(allocator, kv.value, &config.snapshot_paths);
                }
            } else if (std.mem.eql(u8, kv.key, "function-paths")) {
                if (std.mem.trim(u8, kv.value, " \t").len == 0) {
                    read_function_path_block = true;
                } else {
                    try parseInlineStringList(allocator, kv.value, &config.function_paths);
                }
            } else if (std.mem.eql(u8, kv.key, "clean-targets")) {
                config.clean_targets_set = true;
                if (std.mem.trim(u8, kv.value, " \t").len == 0) {
                    read_clean_targets_block = true;
                } else {
                    try parseInlineStringList(allocator, kv.value, &config.clean_targets);
                }
            }
        }
    }

    if (config.name.len == 0) return error.InvalidProjectName;
    try parseProjectVars(allocator, text, &config.vars);
    try parseProjectFlags(text, &config);
    try parseProjectDispatchConfigs(allocator, text, &config.dispatch_configs);
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

fn parseProjectFlags(text: []const u8, config: *ProjectConfig) !void {
    var in_flags = false;
    var flags_indent: usize = 0;
    var direct_child_indent: ?usize = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);

        if (in_flags and indent <= flags_indent and !std.mem.eql(u8, trimmed, "flags:")) {
            in_flags = false;
            direct_child_indent = null;
        }
        if (!in_flags) {
            const kv = splitKeyValue(trimmed) orelse continue;
            if (!std.mem.eql(u8, kv.key, "flags")) continue;
            const value = std.mem.trim(u8, kv.value, " \t\r");
            if (value.len == 0) {
                in_flags = true;
                flags_indent = indent;
                direct_child_indent = null;
            } else if (!std.mem.eql(u8, value, "{}")) {
                return error.UnsupportedYaml;
            }
            continue;
        }

        if (indent <= flags_indent) continue;
        if (direct_child_indent == null) direct_child_indent = indent;
        if (indent != direct_child_indent.?) continue;

        const kv = splitKeyValue(trimmed) orelse continue;
        if (std.mem.eql(u8, kv.key, "validate_macro_args")) {
            config.validate_macro_args = try parseStrictBool(kv.value);
        }
    }
}

fn parseStrictBool(value: []const u8) !bool {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (std.ascii.eqlIgnoreCase(trimmed, "true")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "false")) return false;
    return error.UnsupportedYaml;
}

fn parseProjectVars(allocator: std.mem.Allocator, text: []const u8, vars: *std.ArrayList(VarEntry)) !void {
    var in_vars = false;
    var vars_indent: usize = 0;
    var direct_child_indent: ?usize = null;
    var skip_nested_indent: ?usize = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);

        if (in_vars and indent <= vars_indent and !std.mem.eql(u8, trimmed, "vars:")) {
            in_vars = false;
            direct_child_indent = null;
            skip_nested_indent = null;
        }
        if (!in_vars) {
            const kv = splitKeyValue(trimmed) orelse continue;
            if (!std.mem.eql(u8, kv.key, "vars")) continue;
            const value = std.mem.trim(u8, kv.value, " \t\r");
            if (value.len == 0) {
                in_vars = true;
                vars_indent = indent;
                direct_child_indent = null;
                skip_nested_indent = null;
            } else {
                try parseVarsText(allocator, value, vars);
            }
            continue;
        }

        if (indent <= vars_indent) continue;
        if (skip_nested_indent) |skip_indent| {
            if (indent > skip_indent) continue;
            skip_nested_indent = null;
        }
        if (direct_child_indent == null) direct_child_indent = indent;
        if (indent != direct_child_indent.?) continue;

        const kv = splitKeyValue(trimmed) orelse continue;
        const value = std.mem.trim(u8, kv.value, " \t\r");
        if (value.len == 0) {
            skip_nested_indent = indent;
            continue;
        }
        try appendOrReplaceVar(allocator, vars, kv.key, value);
    }
    sortVars(vars.items);
}

fn sortVars(vars: []VarEntry) void {
    std.mem.sort(VarEntry, vars, {}, struct {
        fn lessThan(_: void, a: VarEntry, b: VarEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}

const DispatchParseState = struct {
    config: DispatchConfig,
    has_macro_namespace: bool = false,
    has_search_order: bool = false,
    reading_search_order: bool = false,
    search_order_indent: usize = 0,
};

fn parseProjectDispatchConfigs(allocator: std.mem.Allocator, text: []const u8, configs: *std.ArrayList(DispatchConfig)) !void {
    var in_dispatch = false;
    var dispatch_indent: usize = 0;
    var entry: ?DispatchParseState = null;
    var saw_entry = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);

        if (in_dispatch and indent <= dispatch_indent and !std.mem.eql(u8, trimmed, "dispatch:")) {
            if (entry) |*current| try finishDispatchEntry(allocator, configs, current);
            entry = null;
            in_dispatch = false;
            saw_entry = false;
        }
        if (!in_dispatch) {
            const kv = splitKeyValue(trimmed) orelse continue;
            if (indent != 0) continue;
            if (!std.mem.eql(u8, kv.key, "dispatch")) continue;
            const value = std.mem.trim(u8, kv.value, " \t\r");
            if (value.len == 0) {
                in_dispatch = true;
                dispatch_indent = indent;
            } else if (!std.mem.eql(u8, value, "[]")) {
                return error.UnsupportedYaml;
            }
            continue;
        }

        if (indent <= dispatch_indent) continue;
        if (entry) |*current| {
            if (current.reading_search_order) {
                if (indent <= current.search_order_indent) {
                    current.reading_search_order = false;
                } else {
                    if (!std.mem.startsWith(u8, trimmed, "- ")) return error.UnsupportedYaml;
                    try current.config.search_order.append(allocator, try dupTrimmedScalar(allocator, trimmed[2..]));
                    current.has_search_order = true;
                    continue;
                }
            }
        }

        if (std.mem.startsWith(u8, trimmed, "- ")) {
            if (entry) |*current| try finishDispatchEntry(allocator, configs, current);
            entry = DispatchParseState{ .config = .{ .macro_namespace = "" } };
            saw_entry = true;
            const rest = std.mem.trim(u8, trimmed[2..], " \t\r");
            if (rest.len != 0) {
                const kv = splitKeyValue(rest) orelse return error.UnsupportedYaml;
                if (entry) |*current| try applyDispatchEntryKeyValue(allocator, current, kv, indent);
            }
            continue;
        }

        if (entry == null) return error.UnsupportedYaml;
        const kv = splitKeyValue(trimmed) orelse return error.UnsupportedYaml;
        if (entry) |*current| try applyDispatchEntryKeyValue(allocator, current, kv, indent);
    }

    if (in_dispatch) {
        if (entry) |*current| try finishDispatchEntry(allocator, configs, current);
        if (!saw_entry) return error.UnsupportedYaml;
    }
}

fn applyDispatchEntryKeyValue(allocator: std.mem.Allocator, state: *DispatchParseState, kv: KeyValue, indent: usize) !void {
    if (std.mem.eql(u8, kv.key, "macro_namespace")) {
        const value = try dupTrimmedScalar(allocator, kv.value);
        if (value.len == 0) return error.UnsupportedYaml;
        state.config.macro_namespace = value;
        state.has_macro_namespace = true;
        state.reading_search_order = false;
    } else if (std.mem.eql(u8, kv.key, "search_order")) {
        state.config.search_order.clearRetainingCapacity();
        state.has_search_order = false;
        const value = std.mem.trim(u8, kv.value, " \t\r");
        if (value.len == 0) {
            state.reading_search_order = true;
            state.search_order_indent = indent;
        } else {
            if (value[0] != '[') return error.UnsupportedYaml;
            try parseInlineStringList(allocator, value, &state.config.search_order);
            state.has_search_order = true;
            state.reading_search_order = false;
        }
    } else {
        return error.UnsupportedYaml;
    }
}

fn finishDispatchEntry(allocator: std.mem.Allocator, configs: *std.ArrayList(DispatchConfig), state: *DispatchParseState) !void {
    state.reading_search_order = false;
    if (!state.has_macro_namespace or !state.has_search_order) return error.UnsupportedYaml;
    try configs.append(allocator, state.config);
    state.config = .{ .macro_namespace = "" };
    state.has_macro_namespace = false;
    state.has_search_order = false;
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

test "project config parser applies defaults for omitted paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try parseProjectConfigText(allocator, "name: demo\n");
    defer deinitProjectConfig(allocator, &config);

    try std.testing.expectEqualStrings("demo", config.name);
    try std.testing.expect(config.profile_name == null);
    try std.testing.expectEqualStrings("target", config.target_path);
    try std.testing.expectEqual(@as(usize, 1), config.model_paths.items.len);
    try std.testing.expectEqualStrings("models", config.model_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 1), config.seed_paths.items.len);
    try std.testing.expectEqualStrings("seeds", config.seed_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 1), config.macro_paths.items.len);
    try std.testing.expectEqualStrings("macros", config.macro_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 0), config.test_paths.items.len);
    try std.testing.expectEqual(@as(usize, 0), config.analysis_paths.items.len);
    try std.testing.expectEqual(@as(usize, 0), config.snapshot_paths.items.len);
    try std.testing.expectEqual(@as(usize, 0), config.function_paths.items.len);
    try std.testing.expect(!config.clean_targets_set);
    try std.testing.expectEqual(@as(usize, 0), config.clean_targets.items.len);
    try std.testing.expect(!config.validate_macro_args);
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
        \\profile: analytics
        \\target-path: target-dxt
        \\model-paths: ["models", marts]
        \\seed-paths:
        \\  - data
        \\macro-paths:
        \\  - custom_macros
        \\test-paths: ["data_tests"]
        \\analysis-paths:
        \\  - analysis
        \\snapshot-paths: [snapshots]
        \\function-paths: [functions]
        \\clean-targets:
        \\  - target-dxt
        \\  - dbt_packages
        \\flags:
        \\  validate_macro_args: true
        \\vars:
        \\  orders_model: customers
        \\  package_scope:
        \\    ignored_nested: value
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
    try std.testing.expectEqualStrings("analytics", config.profile_name.?);
    try std.testing.expectEqualStrings("target-dxt", config.target_path);
    try std.testing.expectEqual(@as(usize, 2), config.model_paths.items.len);
    try std.testing.expectEqualStrings("models", config.model_paths.items[0]);
    try std.testing.expectEqualStrings("marts", config.model_paths.items[1]);
    try std.testing.expectEqual(@as(usize, 1), config.seed_paths.items.len);
    try std.testing.expectEqualStrings("data", config.seed_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 1), config.macro_paths.items.len);
    try std.testing.expectEqualStrings("custom_macros", config.macro_paths.items[0]);
    try std.testing.expect(config.macro_paths_set);
    try std.testing.expectEqual(@as(usize, 1), config.test_paths.items.len);
    try std.testing.expectEqualStrings("data_tests", config.test_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 1), config.analysis_paths.items.len);
    try std.testing.expectEqualStrings("analysis", config.analysis_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 1), config.snapshot_paths.items.len);
    try std.testing.expectEqualStrings("snapshots", config.snapshot_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 1), config.function_paths.items.len);
    try std.testing.expectEqualStrings("functions", config.function_paths.items[0]);
    try std.testing.expect(config.clean_targets_set);
    try std.testing.expectEqual(@as(usize, 2), config.clean_targets.items.len);
    try std.testing.expectEqualStrings("target-dxt", config.clean_targets.items[0]);
    try std.testing.expectEqualStrings("dbt_packages", config.clean_targets.items[1]);
    try std.testing.expect(config.validate_macro_args);
    try std.testing.expectEqual(@as(usize, 1), config.vars.items.len);
    try std.testing.expectEqualStrings("orders_model", config.vars.items[0].name);
    try std.testing.expectEqualStrings("customers", config.vars.items[0].value);

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

test "project config parser reads dispatch search order entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text =
        \\name: demo
        \\dispatch:
        \\  - macro_namespace: util_pkg
        \\    search_order: ["override_pkg", demo, util_pkg]
        \\  - macro_namespace: dbt
        \\    search_order:
        \\      - demo
        \\      - dbt
    ;

    var config = try parseProjectConfigText(allocator, text);
    defer deinitProjectConfig(allocator, &config);

    try std.testing.expectEqual(@as(usize, 2), config.dispatch_configs.items.len);
    try std.testing.expectEqualStrings("util_pkg", config.dispatch_configs.items[0].macro_namespace);
    try std.testing.expectEqual(@as(usize, 3), config.dispatch_configs.items[0].search_order.items.len);
    try std.testing.expectEqualStrings("override_pkg", config.dispatch_configs.items[0].search_order.items[0]);
    try std.testing.expectEqualStrings("demo", config.dispatch_configs.items[0].search_order.items[1]);
    try std.testing.expectEqualStrings("util_pkg", config.dispatch_configs.items[0].search_order.items[2]);
    try std.testing.expectEqualStrings("dbt", config.dispatch_configs.items[1].macro_namespace);
    try std.testing.expectEqual(@as(usize, 2), config.dispatch_configs.items[1].search_order.items.len);
    try std.testing.expectEqualStrings("demo", config.dispatch_configs.items[1].search_order.items[0]);
    try std.testing.expectEqualStrings("dbt", config.dispatch_configs.items[1].search_order.items[1]);
}

test "project config parser reads inline clean targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try parseProjectConfigText(allocator,
        \\name: demo
        \\target-path: target-dxt
        \\clean-targets: [target-dxt, dbt_packages]
    );
    defer deinitProjectConfig(allocator, &config);

    try std.testing.expect(config.clean_targets_set);
    try std.testing.expectEqual(@as(usize, 2), config.clean_targets.items.len);
    try std.testing.expectEqualStrings("target-dxt", config.clean_targets.items[0]);
    try std.testing.expectEqualStrings("dbt_packages", config.clean_targets.items[1]);
}

test "project config parser rejects malformed dispatch entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.UnsupportedYaml, parseProjectConfigText(allocator,
        \\name: demo
        \\dispatch:
        \\  - search_order: [demo]
    ));
    try std.testing.expectError(error.UnsupportedYaml, parseProjectConfigText(allocator,
        \\name: demo
        \\dispatch:
        \\  - macro_namespace: util_pkg
    ));
    try std.testing.expectError(error.UnsupportedYaml, parseProjectConfigText(allocator,
        \\name: demo
        \\dispatch:
        \\  - macro_namespace: util_pkg
        \\    search_order: demo
    ));
    try std.testing.expectError(error.UnsupportedYaml, parseProjectConfigText(allocator,
        \\name: demo
        \\dispatch:
        \\  - macro_namespace: util_pkg
        \\    search_order:
    ));
}

test "project config parser ignores nested keys named dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var config = try parseProjectConfigText(allocator,
        \\name: demo
        \\vars:
        \\  dispatch: value
    );
    defer deinitProjectConfig(allocator, &config);

    try std.testing.expectEqual(@as(usize, 0), config.dispatch_configs.items.len);
    try std.testing.expectEqual(@as(usize, 1), config.vars.items.len);
    try std.testing.expectEqualStrings("dispatch", config.vars.items[0].name);
    try std.testing.expectEqualStrings("value", config.vars.items[0].value);
}

test "vars parser accepts inline and multiline scalar maps with later override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var vars: std.ArrayList(VarEntry) = .empty;
    defer vars.deinit(allocator);

    try parseVarsText(allocator, "{orders_model: customers, raw_table: payments}", &vars);
    try parseVarsText(allocator,
        \\orders_model: alt_customers
        \\source_name: raw
    , &vars);

    try std.testing.expectEqual(@as(usize, 3), vars.items.len);
    try std.testing.expectEqualStrings("orders_model", vars.items[0].name);
    try std.testing.expectEqualStrings("alt_customers", vars.items[0].value);
    try std.testing.expectEqualStrings("raw_table", vars.items[1].name);
    try std.testing.expectEqualStrings("payments", vars.items[1].value);
    try std.testing.expectEqualStrings("source_name", vars.items[2].name);
    try std.testing.expectEqualStrings("raw", vars.items[2].value);
}

test "vars parser rejects nested CLI values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var vars: std.ArrayList(VarEntry) = .empty;
    defer vars.deinit(allocator);

    try std.testing.expectError(error.UnsupportedYaml, parseVarsText(allocator, "{orders_model: [customers]}", &vars));
}

test "model path config matching preserves dbt path prefix semantics" {
    try std.testing.expect(modelPathConfigMatches("", "marts/orders.sql"));
    try std.testing.expect(modelPathConfigMatches("marts", "marts/orders.sql"));
    try std.testing.expect(modelPathConfigMatches("marts/orders", "marts/orders.sql"));
    try std.testing.expect(!modelPathConfigMatches("mart", "marts/orders.sql"));

    try std.testing.expectEqual(@as(usize, 0), modelPathConfigDepth(""));
    try std.testing.expectEqual(@as(usize, 1), modelPathConfigDepth("marts"));
    try std.testing.expectEqual(@as(usize, 2), modelPathConfigDepth("marts/core"));
}

test "project model path config application preserves depth package and inline precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "marts/orders.sql",
        .original_file_path = "models/marts/orders.sql",
        .raw_code = "",
    });
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.inline_orders",
        .name = "inline_orders",
        .path = "marts/inline_orders.sql",
        .original_file_path = "models/marts/inline_orders.sql",
        .raw_code = "",
        .materialized = "incremental",
        .inline_materialized = true,
    });
    try graph.nodes.append(allocator, .{
        .package_name = "pkg",
        .unique_id = "model.pkg.orders",
        .name = "orders",
        .path = "marts/orders.sql",
        .original_file_path = "dbt_packages/pkg/models/marts/orders.sql",
        .raw_code = "",
    });

    var configs: std.ArrayList(ModelPathConfig) = .empty;
    defer {
        for (configs.items) |*config| {
            config.tags.deinit(allocator);
        }
        configs.deinit(allocator);
    }
    try configs.append(allocator, .{ .package_name = "demo", .path = "", .materialized = "view" });
    try configs.append(allocator, .{ .package_name = "demo", .path = "marts", .materialized = "table", .docs = .{ .configured = true, .node_color = "#112233" } });
    try configs.items[1].tags.append(allocator, "nightly");
    try configs.items[1].tags.append(allocator, "core");
    try configs.append(allocator, .{ .package_name = "pkg", .path = "marts", .materialized = "table" });

    try applyProjectModelPathConfigs(&graph, configs.items, false, "demo");

    try std.testing.expectEqualStrings("table", graph.nodes.items[0].materialized);
    try std.testing.expect(graph.nodes.items[0].docs.configured);
    try std.testing.expectEqualStrings("#112233", graph.nodes.items[0].docs.node_color.?);
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.items[0].tags.items.len);
    try std.testing.expectEqualStrings("core", graph.nodes.items[0].tags.items[0]);
    try std.testing.expectEqualStrings("nightly", graph.nodes.items[0].tags.items[1]);
    try std.testing.expectEqualStrings("incremental", graph.nodes.items[1].materialized);
    try std.testing.expectEqualStrings("view", graph.nodes.items[2].materialized);

    try applyProjectModelPathConfigs(&graph, configs.items, true, null);
    try std.testing.expectEqualStrings("table", graph.nodes.items[2].materialized);
}

test "project seed docs application targets package seeds only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();

    try graph.nodes.append(allocator, .{
        .resource_type = "seed",
        .package_name = "demo",
        .unique_id = "seed.demo.raw_orders",
        .name = "raw_orders",
        .path = "raw_orders.csv",
        .original_file_path = "seeds/raw_orders.csv",
        .raw_code = "",
        .materialized = "seed",
    });
    try graph.nodes.append(allocator, .{
        .resource_type = "seed",
        .package_name = "pkg",
        .unique_id = "seed.pkg.raw_orders",
        .name = "raw_orders",
        .path = "raw_orders.csv",
        .original_file_path = "dbt_packages/pkg/seeds/raw_orders.csv",
        .raw_code = "",
        .materialized = "seed",
    });
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "",
    });

    applyProjectSeedDocs(&graph, "demo", .{ .configured = true, .show = false, .node_color = "#445566" });

    try std.testing.expect(graph.nodes.items[0].docs.configured);
    try std.testing.expect(!graph.nodes.items[0].docs.show);
    try std.testing.expectEqualStrings("#445566", graph.nodes.items[0].docs.node_color.?);
    try std.testing.expect(!graph.nodes.items[1].docs.configured);
    try std.testing.expect(!graph.nodes.items[2].docs.configured);
}
