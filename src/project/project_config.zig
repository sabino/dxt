const std = @import("std");
const yaml = @import("yaml.zig");
const values = @import("config_value.zig");
const render = @import("config_render.zig");
const resource = @import("resource_config.zig");
const types = @import("types.zig");

pub fn parse(runtime: types.Runtime, text: []const u8, cli_vars: []const types.VarEntry) !types.ProjectConfig {
    return try parseWithTarget(runtime, text, cli_vars, .null);
}

pub fn parseWithTarget(runtime: types.Runtime, text: []const u8, cli_vars: []const types.VarEntry, target: std.json.Value) !types.ProjectConfig {
    const allocator = runtime.allocator;
    var document = try yaml.parse(allocator, text);
    defer document.deinit();
    if (document.value != .object) return error.InvalidProjectConfiguration;
    if (values.get(document.value, "flags")) |flags| if (flags != .object) return error.InvalidProjectConfiguration;
    var config = types.ProjectConfig{ .name = "" };
    std.crypto.hash.sha2.Sha256.hash(std.mem.trim(u8, text, " \t\r\n\x0b\x0c"), &config.file_checksum, .{});
    errdefer types.deinitProjectConfig(allocator, &config);
    config.raw_project = try values.clone(allocator, document.value);
    var context = render.Context{ .runtime = runtime, .vars = cli_vars, .target = target };
    var rendered: std.json.Value = .null;
    var it = document.value.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        var value = if (std.mem.eql(u8, key, "vars") or std.mem.eql(u8, key, "on-run-start") or std.mem.eql(u8, key, "on-run-end") or std.mem.eql(u8, key, "query-comment"))
            try values.clone(allocator, entry.value_ptr.*)
        else if (isResourceBlock(key))
            try renderResourceBlock(&context, entry.value_ptr.*)
        else
            try context.render(entry.value_ptr.*);
        defer values.deinit(allocator, &value);
        try values.put(allocator, &rendered, key, value);
    }
    config.rendered_project = rendered;
    try @import("version_requirements.zig").validateProject(allocator, rendered, if (runtime.global_options) |options| options.version_check else true);
    config.name = try duplicateString(allocator, values.get(rendered, "name") orelse return error.InvalidProjectName);
    if (config.name.len == 0) return error.InvalidProjectName;
    if (values.get(rendered, "profile")) |v| config.profile_name = try duplicateString(allocator, v);
    if (values.get(rendered, "target-path")) |v| config.target_path = try duplicateString(allocator, v);
    inline for (.{ .{ "model-paths", "model_paths", "models" }, .{ "seed-paths", "seed_paths", "seeds" }, .{ "macro-paths", "macro_paths", "macros" }, .{ "test-paths", "test_paths", "tests" }, .{ "analysis-paths", "analysis_paths", "analyses" }, .{ "snapshot-paths", "snapshot_paths", "snapshots" }, .{ "function-paths", "function_paths", "functions" } }) |path| {
        if (values.get(rendered, path[0])) |v| try stringList(allocator, v, &@field(config, path[1])) else try @field(config, path[1]).append(allocator, path[2]);
    }
    const docs_paths = values.get(rendered, "docs-paths") orelse .null;
    if (docs_paths != .null) {
        try stringList(allocator, docs_paths, &config.docs_paths);
    } else {
        for ([_][]const []const u8{ config.model_paths.items, config.seed_paths.items, config.snapshot_paths.items, config.analysis_paths.items, config.macro_paths.items, config.test_paths.items }) |paths| for (paths) |path| {
            try @import("util.zig").appendUnique(allocator, &config.docs_paths, std.mem.trimEnd(u8, path, "/"));
        };
    }
    config.macro_paths_set = values.get(rendered, "macro-paths") != null;
    config.test_paths_set = values.get(rendered, "test-paths") != null;
    config.snapshot_paths_set = values.get(rendered, "snapshot-paths") != null;
    if (values.get(rendered, "clean-targets")) |v| {
        try stringList(allocator, v, &config.clean_targets);
        config.clean_targets_set = true;
    }
    if (values.get(rendered, "vars")) |v| try appendVars(allocator, &config.vars, v, true);
    if (values.get(rendered, "flags")) |flags| if (values.get(flags, "require_generic_test_arguments_property")) |v| {
        config.require_generic_test_arguments_property = try resource.boolean(v);
    };
    if (values.get(rendered, "flags")) |flags| if (values.get(flags, "enable_truthy_nulls_equals_macro")) |v| {
        config.enable_truthy_nulls_equals_macro = try resource.boolean(v);
    };
    if (values.get(rendered, "flags")) |flags| if (values.get(flags, "validate_macro_args")) |v| {
        config.validate_macro_args = try resource.boolean(v);
    };
    if (values.get(rendered, "flags")) |flags| if (values.get(flags, "require_batched_execution_for_custom_microbatch_strategy")) |v| {
        config.require_batched_execution_for_custom_microbatch_strategy = try resource.boolean(v);
    };
    if (values.get(rendered, "dispatch")) |dispatch| {
        if (dispatch != .array) return error.UnsupportedYaml;
        for (dispatch.array.items) |entry| {
            const namespace = values.get(entry, "macro_namespace") orelse return error.UnsupportedYaml;
            const order = values.get(entry, "search_order") orelse return error.UnsupportedYaml;
            var list: std.ArrayList([]const u8) = .empty;
            try stringList(allocator, order, &list);
            try config.dispatch_configs.append(allocator, .{ .macro_namespace = try duplicateString(allocator, namespace), .search_order = list });
        }
    }
    inline for (.{ .{ "models", "model" }, .{ "seeds", "seed" }, .{ "analyses", "analysis" }, .{ "snapshots", "snapshot" }, .{ "tests", "test" }, .{ "data_tests", "test" } }) |pair| {
        if (values.get(rendered, pair[0])) |block| try walkPaths(allocator, block, values.get(document.value, pair[0]) orelse .null, pair[1], "", "", &config.model_path_configs);
    }
    if (values.get(rendered, "sources")) |block| try sourcePaths(allocator, block, "", null, null, &config.source_project_configs);
    return config;
}

fn sourcePaths(allocator: std.mem.Allocator, block: std.json.Value, package: []const u8, source: ?[]const u8, table: ?[]const u8, configs: *std.ArrayList(types.SourceProjectConfig)) anyerror!void {
    if (block == .null) return;
    if (block != .object) return error.InvalidProjectConfiguration;
    var config = types.SourceProjectConfig{ .package_name = try allocator.dupe(u8, package), .source_name = if (source) |name| try allocator.dupe(u8, name) else null, .table_name = if (table) |name| try allocator.dupe(u8, name) else null };
    var configured = false;
    var it = block.object.iterator();
    while (it.next()) |entry| {
        const key = std.mem.trimStart(u8, entry.key_ptr.*, "+ ");
        const value = entry.value_ptr.*;
        if (isSourceConfig(key)) {
            try values.put(allocator, &config.values, key, value);
            configured = true;
        }
        if (std.mem.eql(u8, key, "database")) {
            config.database = try ownedOptionalString(allocator, value);
            configured = true;
        }
        if (std.mem.eql(u8, key, "schema")) {
            config.schema_name = try ownedOptionalString(allocator, value);
            configured = true;
        }
        if (std.mem.eql(u8, key, "identifier")) {
            config.identifier = try ownedOptionalString(allocator, value);
            configured = true;
        }
        if (std.mem.eql(u8, key, "loaded_at_field")) {
            config.loaded_at_field = try ownedOptionalString(allocator, value);
            config.loaded_at_field_set = true;
            configured = true;
        }
        if (std.mem.eql(u8, key, "loaded_at_query")) {
            config.loaded_at_query = try ownedOptionalString(allocator, value);
            config.loaded_at_query_set = true;
            configured = true;
        }
        if (std.mem.eql(u8, key, "quoting")) {
            config.quoting = try quoting(value);
            configured = true;
        }
        if (std.mem.eql(u8, key, "freshness")) {
            config.freshness = try freshness(allocator, value);
            config.freshness_set = true;
            configured = true;
        }
    }
    if (config.loaded_at_field_set and config.loaded_at_query_set) return error.InvalidSourceConfiguration;
    if (configured) try configs.append(allocator, config);
    it = block.object.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.*[0] == '+' or isSourceConfig(entry.key_ptr.*)) continue;
        if (table != null) return error.InvalidProjectConfiguration;
        if (package.len == 0) try sourcePaths(allocator, entry.value_ptr.*, entry.key_ptr.*, null, null, configs) else if (source == null) try sourcePaths(allocator, entry.value_ptr.*, package, entry.key_ptr.*, null, configs) else try sourcePaths(allocator, entry.value_ptr.*, package, source, entry.key_ptr.*, configs);
    }
}

fn isSourceConfig(key: []const u8) bool {
    for ([_][]const u8{ "database", "schema", "identifier", "loaded_at_field", "loaded_at_query", "quoting", "freshness", "enabled", "tags", "meta", "docs" }) |known| if (std.mem.eql(u8, key, known)) return true;
    return false;
}

fn ownedOptionalString(allocator: std.mem.Allocator, value: std.json.Value) !?[]const u8 {
    return if (value == .null) null else try duplicateString(allocator, value);
}

pub fn quoting(value: std.json.Value) !types.SourceQuoting {
    if (value == .null) return .{};
    if (value != .object) return error.InvalidSourceConfiguration;
    var result = types.SourceQuoting{};
    inline for (.{ "database", "schema", "identifier", "column" }) |key| if (values.get(value, key)) |item| {
        @field(result, key) = if (item == .null) null else try resource.boolean(item);
    };
    return result;
}

pub fn freshness(allocator: std.mem.Allocator, value: std.json.Value) !?types.FreshnessThreshold {
    if (value == .null) return null;
    if (value != .object) return error.InvalidSourceConfiguration;
    var result = types.FreshnessThreshold{};
    if (values.get(value, "filter")) |filter| result.filter = try ownedOptionalString(allocator, filter);
    inline for (.{ "warn_after", "error_after" }) |key| if (values.get(value, key)) |item| {
        if (item != .null) {
            const count = values.get(item, "count") orelse return error.InvalidSourceConfiguration;
            const period = values.get(item, "period") orelse return error.InvalidSourceConfiguration;
            if (count != .integer or count.integer < 0) return error.InvalidSourceConfiguration;
            const text = try resource.string(period);
            if (!std.mem.eql(u8, text, "minute") and !std.mem.eql(u8, text, "hour") and !std.mem.eql(u8, text, "day")) return error.InvalidSourceConfiguration;
            @field(result, key) = .{ .count = @intCast(count.integer), .period = try allocator.dupe(u8, text) };
        }
    };
    return result;
}

test "structured project parser preserves anchors paths and typed package variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var config = try parse(.{ .allocator = allocator, .io = std.testing.io },
        \\name: demo
        \\version: '1.0'
        \\model-paths: [models, extra]
        \\vars: {options: {enabled: true, label: 'false'}, package: {value: [1, 2]}}
        \\models:
        \\  +tags: [global]
        \\  demo:
        \\    +materialized: table
        \\    marts: {+enabled: false, +meta: {nested: [1, true]}}
        \\sources: {demo: {raw: {+schema: landing, +quoting: {identifier: true}}}}
    , &.{});
    defer types.deinitProjectConfig(allocator, &config);
    try std.testing.expectEqual(@as(usize, 2), config.model_paths.items.len);
    try std.testing.expectEqual(@as(usize, 3), config.model_path_configs.items.len);
    try std.testing.expect(!values.get(config.model_path_configs.items[2].values, "enabled").?.bool);
    try std.testing.expectEqualStrings("marts", config.model_path_configs.items[2].path);
    try std.testing.expectEqual(@as(usize, 1), config.source_project_configs.items.len);
    try std.testing.expectEqualStrings("landing", config.source_project_configs.items[0].schema_name.?);
    var scoped_found = false;
    for (config.vars.items) |entry| if (entry.package_name != null and std.mem.eql(u8, entry.package_name.?, "package") and std.mem.eql(u8, entry.name, "value")) {
        scoped_found = true;
        try std.testing.expectEqual(@as(u8, 90), entry.priority);
    };
    try std.testing.expect(scoped_found);
}

fn isResourceBlock(key: []const u8) bool {
    for ([_][]const u8{ "models", "seeds", "snapshots", "tests", "data_tests", "analyses", "sources", "unit_tests" }) |candidate| if (std.mem.eql(u8, key, candidate)) return true;
    return false;
}

fn renderResourceBlock(context: *render.Context, value: std.json.Value) anyerror!std.json.Value {
    if (value != .object) return context.render(value) catch |err| {
        if (context.target == .null and value == .string and std.mem.indexOf(u8, value.string, "target.") != null) return try values.clone(context.runtime.allocator, value);
        return err;
    };
    var output: std.json.Value = .null;
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const key = std.mem.trimStart(u8, entry.key_ptr.*, "+ ");
        var item = if (std.mem.eql(u8, key, "pre-hook") or std.mem.eql(u8, key, "post-hook") or std.mem.eql(u8, key, "pre_hook") or std.mem.eql(u8, key, "post_hook") or std.mem.eql(u8, key, "vars") or std.mem.eql(u8, key, "loaded_at_query")) try values.clone(context.runtime.allocator, entry.value_ptr.*) else try renderResourceBlock(context, entry.value_ptr.*);
        defer values.deinit(context.runtime.allocator, &item);
        try values.put(context.runtime.allocator, &output, entry.key_ptr.*, item);
    }
    return output;
}

fn walkPaths(allocator: std.mem.Allocator, block: std.json.Value, raw_block: std.json.Value, resource_type: []const u8, package: []const u8, path: []const u8, configs: *std.ArrayList(types.ModelPathConfig)) anyerror!void {
    if (block == .null) return;
    if (block != .object) return error.InvalidProjectConfiguration;
    var config: std.json.Value = .null;
    defer values.deinit(allocator, &config);
    var raw_config: std.json.Value = .null;
    defer values.deinit(allocator, &raw_config);
    var it = block.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key.len == 0) return error.InvalidProjectConfiguration;
        if (key[0] == '+' or isConfigKey(key)) {
            const config_key = resource.normalizeKey(if (key[0] == '+') key[1..] else key);
            try resource.mergeAuthoredField(allocator, &config, config_key, entry.value_ptr.*);
            try resource.mergeAuthoredField(allocator, &raw_config, config_key, values.get(raw_block, key) orelse entry.value_ptr.*);
        }
    }
    if (config != .null) {
        var node = types.Node{ .package_name = package, .unique_id = "", .name = "", .path = "", .original_file_path = "", .raw_code = "", .effective_config = try values.clone(allocator, config) };
        defer types.deinitNode(allocator, &node);
        resource.apply(allocator, &node) catch |err| {
            if (!containsTargetTemplate(config)) return err;
        };
        try configs.append(allocator, .{ .package_name = try allocator.dupe(u8, package), .path = try allocator.dupe(u8, path), .resource_type = resource_type, .values = node.effective_config, .raw_values = try values.clone(allocator, raw_config), .materialized = if (values.get(config, "materialized") != null) node.materialized else "", .incremental = node.incremental, .tags = node.tags, .docs = node.docs });
        node.effective_config = .null;
        node.incremental = .{};
        node.tags = .empty;
    }
    it = block.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (key[0] == '+' or isConfigKey(key)) continue;
        if (entry.value_ptr.* != .object and entry.value_ptr.* != .null) return error.InvalidProjectConfiguration;
        if (package.len == 0 and path.len == 0) try walkPaths(allocator, entry.value_ptr.*, values.get(raw_block, key) orelse .null, resource_type, key, "", configs) else {
            const next_path = if (path.len == 0) key else try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, key });
            try walkPaths(allocator, entry.value_ptr.*, values.get(raw_block, key) orelse .null, resource_type, package, next_path, configs);
        }
    }
}

fn containsTargetTemplate(value: std.json.Value) bool {
    if (value == .string) return std.mem.indexOf(u8, value.string, "target.") != null;
    if (value == .array) for (value.array.items) |item| {
        if (containsTargetTemplate(item)) return true;
    };
    if (value == .object) {
        var it = value.object.iterator();
        while (it.next()) |entry| if (containsTargetTemplate(entry.value_ptr.*)) return true;
    }
    return false;
}

fn isConfigKey(key: []const u8) bool {
    for ([_][]const u8{ "materialized", "enabled", "tags", "meta", "docs", "schema", "database", "alias", "group", "access", "contract", "unique_key", "incremental_strategy", "incremental_predicates", "predicates", "on_schema_change", "full_refresh", "pre-hook", "post-hook", "pre_hook", "post_hook", "grants", "persist_docs", "quoting", "column_types", "quote_columns", "severity", "where", "limit", "warn_if", "error_if", "store_failures" }) |candidate| if (std.mem.eql(u8, key, candidate)) return true;
    return false;
}

pub fn appendVars(allocator: std.mem.Allocator, vars: *std.ArrayList(types.VarEntry), object: std.json.Value, packages: bool) !void {
    if (object == .null) return;
    if (object != .object) return error.UnsupportedYaml;
    var it = object.object.iterator();
    while (it.next()) |entry| {
        try putVar(allocator, vars, null, entry.key_ptr.*, entry.value_ptr.*, if (packages) 80 else 100);
        if (packages and entry.value_ptr.* == .object) {
            var scoped = entry.value_ptr.object.iterator();
            while (scoped.next()) |child| try putVar(allocator, vars, entry.key_ptr.*, child.key_ptr.*, child.value_ptr.*, 90);
        }
    }
}

fn putVar(allocator: std.mem.Allocator, vars: *std.ArrayList(types.VarEntry), package: ?[]const u8, name: []const u8, value: std.json.Value, priority: u8) !void {
    const text = try values.scalarText(allocator, value);
    const copy = try values.clone(allocator, value);
    for (vars.items) |*entry| {
        const same_package = if (package) |p| if (entry.package_name) |other| std.mem.eql(u8, p, other) else false else entry.package_name == null;
        if (same_package and std.mem.eql(u8, entry.name, name)) {
            if (entry.priority > priority) {
                allocator.free(text);
                var discarded = copy;
                values.deinit(allocator, &discarded);
                return;
            }
            if (entry.typed_value) |*old| values.deinit(allocator, old);
            entry.value = text;
            entry.typed_value = copy;
            entry.priority = priority;
            return;
        }
    }
    try vars.append(allocator, .{ .name = try allocator.dupe(u8, name), .value = text, .typed_value = copy, .package_name = if (package) |p| try allocator.dupe(u8, p) else null, .priority = priority });
}

pub fn stringList(allocator: std.mem.Allocator, value: std.json.Value, list: *std.ArrayList([]const u8)) !void {
    if (value != .array) return error.UnsupportedYaml;
    for (value.array.items) |item| try list.append(allocator, try duplicateString(allocator, item));
}

fn duplicateString(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return try allocator.dupe(u8, try resource.string(value));
}
