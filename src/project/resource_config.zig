const std = @import("std");
const expression = @import("expression.zig");
const values = @import("config_value.zig");
const types = @import("types.zig");

pub fn applyInline(allocator: std.mem.Allocator, args_text: []const u8, node: *types.Node) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const args = expression.evaluateArguments(arena.allocator(), args_text, null) catch return error.UnsupportedJinja;
    var config: std.json.Value = .null;
    defer values.deinit(allocator, &config);
    for (args) |arg| {
        if (arg.name) |key| {
            var value = values.fromExpression(allocator, arg.value) catch return error.UnsupportedJinja;
            defer values.deinit(allocator, &value);
            try mergeField(allocator, &config, normalizeKey(key), value);
        } else {
            if (args.len != 1 or arg.value != .object) return error.UnsupportedJinja;
            for (arg.value.object) |entry| {
                var value = values.fromExpression(allocator, entry.value) catch return error.UnsupportedJinja;
                defer values.deinit(allocator, &value);
                try mergeField(allocator, &config, normalizeKey(entry.key), value);
            }
        }
    }
    try merge(allocator, &node.inline_config, config);
    try merge(allocator, &node.raw_config, config);
    try merge(allocator, &node.effective_config, config);
    try apply(allocator, node);
    if (values.get(config, "materialized") != null) node.inline_materialized = true;
    if (values.get(config, "enabled") != null) node.inline_enabled = true;
    if (values.get(config, "tags") != null) node.inline_tags = true;
    if (values.get(config, "store_failures") != null) node.inline_store_failures = true;
    inline for (.{ .{ "unique_key", "unique_key" }, .{ "incremental_strategy", "strategy" }, .{ "on_schema_change", "on_schema_change" }, .{ "full_refresh", "full_refresh" }, .{ "incremental_predicates", "predicates" } }) |field| {
        if (values.get(config, field[0]) != null) @field(node.inline_incremental, field[1]) = true;
    }
}

pub fn normalizeKey(key: []const u8) []const u8 {
    if (std.mem.eql(u8, key, "pre_hook")) return "pre-hook";
    if (std.mem.eql(u8, key, "post_hook")) return "post-hook";
    if (std.mem.eql(u8, key, "predicates")) return "incremental_predicates";
    return key;
}

/// dbt appends hooks and tags while dict configs merge their keys. Remaining
/// fields use the nearest resource configuration, including explicit nulls.
pub fn merge(allocator: std.mem.Allocator, target: *std.json.Value, source: std.json.Value) !void {
    if (source == .null) return;
    if (source != .object) return error.InvalidConfiguration;
    var it = source.object.iterator();
    while (it.next()) |entry| try mergeField(allocator, target, normalizeKey(entry.key_ptr.*), entry.value_ptr.*);
}

pub fn mergeField(allocator: std.mem.Allocator, target: *std.json.Value, key: []const u8, value: std.json.Value) !void {
    if (std.mem.eql(u8, key, "tags") or std.mem.eql(u8, key, "pre-hook") or std.mem.eql(u8, key, "post-hook")) {
        var merged = std.json.Array.init(allocator);
        var result: std.json.Value = .{ .array = merged };
        defer values.deinit(allocator, &result);
        if (values.get(target.*, key)) |existing| try appendList(allocator, &merged, existing, std.mem.eql(u8, key, "tags"));
        try appendList(allocator, &merged, value, std.mem.eql(u8, key, "tags"));
        result.array = merged;
        try values.put(allocator, target, key, result);
    } else if (std.mem.eql(u8, key, "meta") or std.mem.eql(u8, key, "grants") or std.mem.eql(u8, key, "column_types") or std.mem.eql(u8, key, "persist_docs")) {
        var merged: std.json.Value = if (values.get(target.*, key)) |existing| try values.clone(allocator, existing) else .null;
        defer values.deinit(allocator, &merged);
        if (value == .null) try values.put(allocator, target, key, value) else {
            try values.overlay(allocator, &merged, value);
            try values.put(allocator, target, key, merged);
        }
    } else try values.put(allocator, target, key, value);
}

fn appendList(allocator: std.mem.Allocator, list: *std.json.Array, value: std.json.Value, unique: bool) !void {
    if (value == .null) return;
    if (value == .array) {
        for (value.array.items) |item| try appendList(allocator, list, item, unique);
    } else {
        if (unique and value == .string) for (list.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, value.string)) return;
        };
        try list.append(try values.clone(allocator, value));
    }
}

pub fn apply(allocator: std.mem.Allocator, node: *types.Node) !void {
    const config = node.effective_config;
    if (values.get(config, "materialized")) |v| node.materialized = try string(v);
    if (values.get(config, "enabled")) |v| node.enabled = try boolean(v);
    if (values.get(config, "schema")) |v| node.config_schema = try nullableString(v);
    if (values.get(config, "alias")) |v| node.config_alias = try nullableString(v);
    if (values.get(config, "tags")) |v| {
        node.tags.clearRetainingCapacity();
        if (v == .string) {
            try node.tags.append(allocator, v.string);
        } else if (v == .array) {
            for (v.array.items) |tag| try node.tags.append(allocator, try string(tag));
        } else if (v != .null) return error.InvalidConfiguration;
    }
    if (values.get(config, "docs")) |v| {
        if (v != .object) return error.InvalidConfiguration;
        node.docs.configured = true;
        if (values.get(v, "show")) |show| node.docs.show = try boolean(show);
        if (values.get(v, "node_color")) |color| node.docs.node_color = try nullableString(color);
    }
    if (values.get(config, "unique_key")) |v| {
        if (node.incremental.unique_key) |*old| old.deinit(allocator);
        node.incremental.unique_key = null;
        if (v == .string) node.incremental.unique_key = .{ .string = v.string } else if (v == .array) {
            var keys: std.ArrayList([]const u8) = .empty;
            for (v.array.items) |key| try keys.append(allocator, try string(key));
            node.incremental.unique_key = .{ .list = keys };
        } else if (v != .null) return error.InvalidConfiguration;
        node.incremental.configured.unique_key = true;
    }
    if (values.get(config, "incremental_strategy")) |v| {
        node.incremental.strategy = try nullableString(v);
        node.incremental.configured.strategy = true;
    }
    if (values.get(config, "on_schema_change")) |v| {
        node.incremental.on_schema_change = try nullableString(v);
        node.incremental.configured.on_schema_change = true;
    }
    if (values.get(config, "full_refresh")) |v| {
        node.incremental.full_refresh = if (v == .null) null else try boolean(v);
        node.incremental.configured.full_refresh = true;
    }
    if (values.get(config, "incremental_predicates")) |v| {
        node.incremental.predicates.clearRetainingCapacity();
        node.incremental.predicates_null = v == .null;
        if (v == .array) {
            for (v.array.items) |p| try node.incremental.predicates.append(allocator, try string(p));
        } else if (v == .string) {
            try node.incremental.predicates.append(allocator, v.string);
        } else if (v != .null) return error.InvalidConfiguration;
        node.incremental.configured.predicates = true;
    }
    if (values.get(config, "store_failures")) |v| node.test_config.store_failures = if (v == .null) null else try boolean(v);
    if (values.get(config, "quote_columns")) |v| node.quote_columns = if (v == .null) null else try boolean(v);
    if (values.get(config, "column_types")) |v| {
        if (v != .object) return error.InvalidConfiguration;
        node.seed_column_types.clearRetainingCapacity();
        var it = v.object.iterator();
        while (it.next()) |entry| try node.seed_column_types.append(allocator, .{ .name = entry.key_ptr.*, .data_type = try string(entry.value_ptr.*) });
    }
}

pub fn string(value: std.json.Value) ![]const u8 {
    return if (value == .string) value.string else error.InvalidConfiguration;
}
pub fn nullableString(value: std.json.Value) !?[]const u8 {
    return if (value == .null) null else try string(value);
}
pub fn boolean(value: std.json.Value) !bool {
    return if (value == .bool) value.bool else error.InvalidConfiguration;
}

test "typed inline configs accept dictionaries and preserve nested metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var node = types.Node{ .package_name = "demo", .unique_id = "model.demo.orders", .name = "orders", .path = "orders.sql", .original_file_path = "models/orders.sql", .raw_code = "" };
    defer types.deinitNode(allocator, &node);
    try applyInline(allocator, "{'materialized': 'incremental', 'unique_key': ['id', 'tenant'], 'meta': {'nested': [True, None, 3]}, 'enabled': False}", &node);
    try std.testing.expect(!node.enabled);
    try std.testing.expectEqual(@as(usize, 2), node.incremental.unique_key.?.list.items.len);
    try std.testing.expect(values.get(values.get(node.effective_config, "meta").?, "nested").?.array.items[0].bool);
}
