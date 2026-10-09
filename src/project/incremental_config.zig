const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");

pub fn applyYaml(allocator: std.mem.Allocator, config: *types.IncrementalConfig, key: []const u8, value: []const u8) !bool {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (std.mem.eql(u8, key, "unique_key")) {
        if (config.unique_key) |*old| old.deinit(allocator);
        config.unique_key = null;
        config.configured.unique_key = true;
        if (std.mem.eql(u8, trimmed, "null") or std.mem.eql(u8, trimmed, "none") or std.mem.eql(u8, trimmed, "None")) return true;
        if (trimmed.len == 0 or trimmed[0] == '[') {
            var items: std.ArrayList([]const u8) = .empty;
            errdefer items.deinit(allocator);
            if (trimmed.len != 0) try util.parseInlineStringList(allocator, trimmed, &items);
            config.unique_key = .{ .list = items };
        } else config.unique_key = .{ .string = try util.dupTrimmedScalar(allocator, trimmed) };
    } else if (std.mem.eql(u8, key, "incremental_strategy")) {
        config.strategy = if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "null")) null else try util.dupTrimmedScalar(allocator, trimmed);
        config.configured.strategy = true;
    } else if (std.mem.eql(u8, key, "on_schema_change")) {
        config.on_schema_change = if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "null")) null else try util.dupTrimmedScalar(allocator, trimmed);
        config.configured.on_schema_change = true;
    } else if (std.mem.eql(u8, key, "full_refresh")) {
        config.full_refresh = if (std.ascii.eqlIgnoreCase(trimmed, "true")) true else if (std.ascii.eqlIgnoreCase(trimmed, "false")) false else if (std.mem.eql(u8, trimmed, "null")) null else return error.UnsupportedYaml;
        config.configured.full_refresh = true;
    } else if (std.mem.eql(u8, key, "incremental_predicates") or std.mem.eql(u8, key, "predicates")) {
        config.predicates.clearRetainingCapacity();
        config.configured.predicates = true;
        config.predicates_null = std.mem.eql(u8, trimmed, "null");
        if (trimmed.len != 0 and !config.predicates_null) try util.parseInlineStringList(allocator, trimmed, &config.predicates);
    } else return false;
    return true;
}

pub fn overlay(allocator: std.mem.Allocator, dest: *types.IncrementalConfig, source: types.IncrementalConfig, protected: types.IncrementalConfigMask) !void {
    if (source.configured.unique_key and !protected.unique_key) {
        if (dest.unique_key) |*old| old.deinit(allocator);
        dest.unique_key = if (source.unique_key) |key| switch (key) {
            .string => |value| .{ .string = value },
            .list => |values| blk: {
                var copied: std.ArrayList([]const u8) = .empty;
                try copied.appendSlice(allocator, values.items);
                break :blk .{ .list = copied };
            },
        } else null;
        dest.configured.unique_key = true;
    }
    if (source.configured.strategy and !protected.strategy) {
        dest.strategy = source.strategy;
        dest.configured.strategy = true;
    }
    if (source.configured.on_schema_change and !protected.on_schema_change) {
        dest.on_schema_change = source.on_schema_change;
        dest.configured.on_schema_change = true;
    }
    if (source.configured.full_refresh and !protected.full_refresh) {
        dest.full_refresh = source.full_refresh;
        dest.configured.full_refresh = true;
    }
    if (source.configured.predicates and !protected.predicates) {
        dest.predicates.clearRetainingCapacity();
        try dest.predicates.appendSlice(allocator, source.predicates.items);
        dest.configured.predicates = true;
        dest.predicates_null = source.predicates_null;
    }
}

pub fn fullRefresh(graph: *const types.Graph, node: *const types.Node) bool {
    return node.incremental.full_refresh orelse graph.full_refresh;
}

pub fn validate(config: types.IncrementalConfig) !void {
    return validateForAdapter("duckdb", config);
}

pub fn validateForAdapter(adapter_type: []const u8, config: types.IncrementalConfig) !void {
    const strategy = config.strategy orelse "default";
    if (std.mem.eql(u8, adapter_type, "postgres") and (std.mem.eql(u8, strategy, "merge") or std.mem.eql(u8, strategy, "microbatch"))) return;
    // dbt-duckdb 1.9.6 explicitly supports these strategies, excluding MERGE.
    if (!std.mem.eql(u8, strategy, "default") and !std.mem.eql(u8, strategy, "append") and !std.mem.eql(u8, strategy, "delete+insert")) return error.UnsupportedIncrementalStrategy;
}

pub fn schemaPolicy(config: types.IncrementalConfig) []const u8 {
    const policy = config.on_schema_change orelse "ignore";
    for ([_][]const u8{ "fail", "ignore", "append_new_columns", "sync_all_columns" }) |supported| {
        if (std.mem.eql(u8, policy, supported)) return supported;
    }
    // Core incremental_validate_on_schema_change falls back to ignore.
    return "ignore";
}

test "incremental config overlays preserve inline fields and nullable refresh override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var project: types.IncrementalConfig = .{};
    defer project.deinit(allocator);
    _ = try applyYaml(allocator, &project, "unique_key", "[id, tenant_id]");
    _ = try applyYaml(allocator, &project, "full_refresh", "true");
    _ = try applyYaml(allocator, &project, "on_schema_change", "sync_all_columns");
    var model: types.IncrementalConfig = .{ .full_refresh = false, .configured = .{ .full_refresh = true } };
    defer model.deinit(allocator);
    try overlay(allocator, &model, project, .{ .full_refresh = true });
    try std.testing.expectEqual(false, model.full_refresh.?);
    try std.testing.expectEqualStrings("sync_all_columns", schemaPolicy(model));
    try std.testing.expectEqual(@as(usize, 2), model.unique_key.?.list.items.len);
    var graph = types.Graph{ .allocator = allocator, .project_name = "demo", .full_refresh = true };
    defer graph.deinit();
    const node = types.Node{ .package_name = "demo", .unique_id = "model.demo.a", .name = "a", .path = "a.sql", .original_file_path = "models/a.sql", .raw_code = "", .incremental = model };
    try std.testing.expect(!fullRefresh(&graph, &node));
    try std.testing.expectError(error.UnsupportedIncrementalStrategy, validate(.{ .strategy = "merge" }));
}
