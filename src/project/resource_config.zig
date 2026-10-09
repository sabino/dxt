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
            try mergeFieldWithMode(allocator, &config, normalizeKey(key), value, true);
        } else {
            if (args.len != 1 or arg.value != .object) return error.UnsupportedJinja;
            for (arg.value.object) |entry| {
                var value = values.fromExpression(allocator, entry.value) catch return error.UnsupportedJinja;
                defer values.deinit(allocator, &value);
                try mergeFieldWithMode(allocator, &config, normalizeKey(entry.key), value, true);
            }
        }
    }
    try applyParsedInline(allocator, config, node);
}

pub fn applyParsedInline(allocator: std.mem.Allocator, config: std.json.Value, node: *types.Node) !void {
    try mergeInline(allocator, &node.inline_config, config);
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

pub fn rebuild(allocator: std.mem.Allocator, node: *types.Node) !void {
    var effective: std.json.Value = .null;
    errdefer values.deinit(allocator, &effective);
    try merge(allocator, &effective, node.project_config);
    try merge(allocator, &effective, node.property_config);
    try merge(allocator, &effective, node.inline_config);
    try merge(allocator, &effective, node.root_override_config);
    values.deinit(allocator, &node.effective_config);
    node.effective_config = effective;
    var raw: std.json.Value = .null;
    try values.overlay(allocator, &raw, node.project_raw_config);
    try values.overlay(allocator, &raw, node.property_raw_config);
    try values.overlay(allocator, &raw, node.inline_config);
    try values.overlay(allocator, &raw, node.root_override_raw_config);
    values.deinit(allocator, &node.raw_config);
    node.raw_config = raw;
    try apply(allocator, node);
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
    return mergeFieldWithMode(allocator, target, key, value, false);
}

pub fn mergeAuthoredField(allocator: std.mem.Allocator, target: *std.json.Value, key: []const u8, value: std.json.Value) !void {
    return mergeFieldWithMode(allocator, target, key, value, true);
}

pub fn mergeAuthored(allocator: std.mem.Allocator, target: *std.json.Value, source: std.json.Value) !void {
    if (source == .null) return;
    if (source != .object) return error.InvalidConfiguration;
    var iterator = source.object.iterator();
    while (iterator.next()) |entry| try mergeFieldWithMode(allocator, target, normalizeKey(entry.key_ptr.*), entry.value_ptr.*, true);
}

const mergeInline = mergeAuthored;

fn mergeFieldWithMode(allocator: std.mem.Allocator, target: *std.json.Value, key: []const u8, value: std.json.Value, preserve_grant_prefix: bool) !void {
    if (std.mem.eql(u8, key, "tags") or std.mem.eql(u8, key, "pre-hook") or std.mem.eql(u8, key, "post-hook") or std.mem.eql(u8, key, "packages")) {
        var merged = std.json.Array.init(allocator);
        var result: std.json.Value = .{ .array = merged };
        defer values.deinit(allocator, &result);
        if (values.get(target.*, key)) |existing| try appendList(allocator, &merged, existing, std.mem.eql(u8, key, "tags"));
        try appendList(allocator, &merged, value, std.mem.eql(u8, key, "tags"));
        result.array = merged;
        try values.put(allocator, target, key, result);
    } else if (std.mem.eql(u8, key, "grants")) {
        if (value != .object) return error.InvalidConfiguration;
        var merged: std.json.Value = .{ .object = .empty };
        defer values.deinit(allocator, &merged);
        if (values.get(target.*, key)) |existing| {
            if (existing != .object) return error.InvalidConfiguration;
            var it = existing.object.iterator();
            while (it.next()) |entry| try putGrantList(allocator, &merged, entry.key_ptr.*, entry.value_ptr.*, false);
        }
        var it = value.object.iterator();
        while (it.next()) |entry| {
            const grant = entry.key_ptr.*;
            const append = std.mem.startsWith(u8, grant, "+");
            const base = std.mem.trimStart(u8, grant, "+");
            if (preserve_grant_prefix) {
                const prefixed = try std.fmt.allocPrint(allocator, "+{s}", .{base});
                defer allocator.free(prefixed);
                if (!append) {
                    if (merged.object.fetchOrderedRemove(prefixed)) |removed| {
                        var owned = removed.value;
                        allocator.free(removed.key);
                        values.deinit(allocator, &owned);
                    }
                    try putGrantList(allocator, &merged, base, entry.value_ptr.*, false);
                } else if (values.get(merged, base) != null) {
                    try putGrantList(allocator, &merged, base, entry.value_ptr.*, true);
                } else try putGrantList(allocator, &merged, prefixed, entry.value_ptr.*, true);
            } else try putGrantList(allocator, &merged, base, entry.value_ptr.*, append);
        }
        try values.put(allocator, target, key, merged);
    } else if (std.mem.eql(u8, key, "meta") or std.mem.eql(u8, key, "column_types") or std.mem.eql(u8, key, "quoting") or std.mem.eql(u8, key, "docs") or std.mem.eql(u8, key, "contract")) {
        if (value != .object) return error.InvalidConfiguration;
        var merged: std.json.Value = if (values.get(target.*, key)) |existing| try values.clone(allocator, existing) else .null;
        defer values.deinit(allocator, &merged);
        try values.overlay(allocator, &merged, value);
        try values.put(allocator, target, key, merged);
    } else try values.put(allocator, target, key, value);
}

fn putGrantList(allocator: std.mem.Allocator, target: *std.json.Value, key: []const u8, value: std.json.Value, append: bool) !void {
    var list: std.json.Value = .{ .array = std.json.Array.init(allocator) };
    defer values.deinit(allocator, &list);
    if (append) if (values.get(target.*, key)) |previous| {
        if (previous != .array) return error.InvalidConfiguration;
        for (previous.array.items) |item| try list.array.append(try values.clone(allocator, item));
    };
    if (value == .array) {
        for (value.array.items) |item| try list.array.append(try values.clone(allocator, item));
    } else try list.array.append(try values.clone(allocator, value));
    try values.put(allocator, target, key, list);
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
    if (values.get(config, "persist_docs")) |v| {
        if (v == .null) node.persist_docs = null else {
            if (v != .object) return error.InvalidConfiguration;
            var docs: types.PersistDocs = .{};
            if (values.get(v, "relation")) |value| docs.relation = try boolean(value);
            if (values.get(v, "columns")) |value| docs.columns = try boolean(value);
            node.persist_docs = docs;
        }
    }
    if (values.get(node.inline_config, "store_failures") != null) node.test_config.markConfigured(.store_failures);
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
    if (std.mem.eql(u8, node.resource_type, "test")) {
        inline for (.{ "store_failures_as", "schema", "alias", "database" }) |key| if (values.get(config, key)) |v| {
            @field(node.test_config, key) = try nullableString(v);
        };
        if (values.get(config, "fail_calc")) |v| node.test_config.fail_calc = try string(v);
    }
    if (values.get(config, "where")) |v| node.test_config.where = try nullableString(v);
    if (values.get(config, "limit")) |v| {
        if (v == .null) node.test_config.limit = null else if (v == .integer and v.integer >= 0) node.test_config.limit = @intCast(v.integer) else return error.InvalidConfiguration;
    }
    if (values.get(config, "severity")) |v| {
        const severity = try string(v);
        if (!std.ascii.eqlIgnoreCase(severity, "warn") and !std.ascii.eqlIgnoreCase(severity, "error")) return error.InvalidConfiguration;
        node.test_config.severity = severity;
    }
    if (values.get(config, "warn_if")) |v| node.test_config.warn_if = try string(v);
    if (values.get(config, "error_if")) |v| node.test_config.error_if = try string(v);
    inline for (std.meta.tags(types.GenericTestConfigField)) |key| {
        if (values.get(config, @tagName(key)) != null) node.test_config.markConfigured(key);
    }
    if (values.get(config, "quote_columns")) |v| node.quote_columns = if (v == .null) null else try boolean(v);
    if (values.get(config, "column_types")) |v| {
        if (v != .object) return error.InvalidConfiguration;
        node.seed_column_types.clearRetainingCapacity();
        var it = v.object.iterator();
        while (it.next()) |entry| try node.seed_column_types.append(allocator, .{ .name = entry.key_ptr.*, .data_type = try string(entry.value_ptr.*) });
    }
    if (node.snapshot_config != null) try @import("snapshot.zig").applyJsonConfig(allocator, config, node);
}

/// Scan nodes own the JSON values backing config strings. Copy before the
/// temporary scan node is destroyed and a singular test keeps its settings.
pub fn cloneTestConfig(allocator: std.mem.Allocator, source: types.GenericTestConfig) !types.GenericTestConfig {
    var result = source;
    if (source.where) |where| result.where = try allocator.dupe(u8, where);
    result.severity = try allocator.dupe(u8, source.severity);
    result.warn_if = try allocator.dupe(u8, source.warn_if);
    result.error_if = try allocator.dupe(u8, source.error_if);
    result.fail_calc = try allocator.dupe(u8, source.fail_calc);
    inline for (.{ "store_failures_as", "schema", "alias", "database" }) |key| if (@field(source, key)) |value| {
        @field(result, key) = try allocator.dupe(u8, value);
    };
    return result;
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

test "inline singular test config projects severity and failure conditions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var node = types.Node{ .package_name = "demo", .unique_id = "test.demo.warning", .name = "warning", .path = "warning.sql", .original_file_path = "tests/warning.sql", .raw_code = "", .resource_type = "test" };
    defer types.deinitNode(allocator, &node);
    try applyInline(allocator, "severity='warn', warn_if='> 2', error_if='> 5', where='id is not null', limit=7", &node);
    try std.testing.expectEqualStrings("warn", node.test_config.severity);
    try std.testing.expectEqualStrings("> 2", node.test_config.warn_if);
    try std.testing.expectEqualStrings("> 5", node.test_config.error_if);
    try std.testing.expectEqualStrings("id is not null", node.test_config.where.?);
    try std.testing.expectEqual(@as(u64, 7), node.test_config.limit.?);
    try std.testing.expect(node.test_config.configured.contains(.severity));
}
