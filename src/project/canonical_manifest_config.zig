//! The complete serialized resource config contract of dbt Core 1.10.5.
//! Authored extension fields remain typed, while structured defaults are shared
//! by artifacts and the native macro context.
const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");
const Json = std.json.Value;

const node_defaults =
    \\{"enabled":true,"alias":null,"schema":null,"database":null,"tags":[],"meta":{},"group":null,"materialized":"view","incremental_strategy":null,"batch_size":null,"lookback":1,"begin":null,"persist_docs":{},"post-hook":[],"pre-hook":[],"quoting":{},"column_types":{},"full_refresh":null,"unique_key":null,"on_schema_change":"ignore","on_configuration_change":"apply","grants":{},"packages":[],"docs":{"show":true,"node_color":null},"contract":{"enforced":false,"alias_types":true},"event_time":null,"concurrent_batches":null}
;
const test_defaults =
    \\{"enabled":true,"alias":null,"schema":"dbt_test__audit","database":null,"tags":[],"meta":{},"group":null,"materialized":"test","severity":"ERROR","store_failures":null,"store_failures_as":null,"where":null,"limit":null,"fail_calc":"count(*)","warn_if":"!= 0","error_if":"!= 0"}
;

pub fn defaults(allocator: std.mem.Allocator, resource: []const u8) !Json {
    const parsed = try std.json.parseFromSlice(Json, allocator, if (std.mem.eql(u8, resource, "test")) test_defaults else node_defaults, .{});
    defer parsed.deinit();
    var result = try values.clone(allocator, parsed.value);
    errdefer values.deinit(allocator, &result);
    if (std.mem.eql(u8, resource, "model")) {
        try values.put(allocator, &result, "access", .{ .string = "protected" });
        try values.put(allocator, &result, "freshness", .null);
    } else if (std.mem.eql(u8, resource, "seed")) {
        try values.put(allocator, &result, "materialized", .{ .string = "seed" });
        try values.put(allocator, &result, "delimiter", .{ .string = "," });
        try values.put(allocator, &result, "quote_columns", .null);
    } else if (std.mem.eql(u8, resource, "snapshot")) {
        try values.put(allocator, &result, "materialized", .{ .string = "snapshot" });
        inline for (.{ "strategy", "target_schema", "target_database", "updated_at", "check_cols", "dbt_valid_to_current" }) |key| try values.put(allocator, &result, key, .null);
        var names: Json = .{ .object = .empty };
        defer values.deinit(allocator, &names);
        inline for (.{ "dbt_valid_to", "dbt_valid_from", "dbt_scd_id", "dbt_updated_at", "dbt_is_deleted" }) |key| try values.put(allocator, &names, key, .null);
        try values.put(allocator, &result, "snapshot_meta_column_names", names);
    }
    return result;
}

fn strings(allocator: std.mem.Allocator, items: []const []const u8) !Json {
    var result: Json = .{ .array = std.json.Array.init(allocator) };
    errdefer values.deinit(allocator, &result);
    for (items) |item| try result.array.append(try values.clone(allocator, .{ .string = item }));
    return result;
}

fn columns(allocator: std.mem.Allocator, selection: ?types.SnapshotColumns) !Json {
    return if (selection) |selected| switch (selected) {
        .string => |text| try values.clone(allocator, .{ .string = text }),
        .list => |items| try strings(allocator, items.items),
    } else .null;
}

fn nullableString(allocator: std.mem.Allocator, result: *Json, key: []const u8, text: ?[]const u8) !void {
    try values.put(allocator, result, key, if (text) |item| .{ .string = item } else .null);
}

/// Core normalizes hook strings into hook objects. JSON encoded hook
/// dictionaries (before_begin/after_commit) retain their transaction setting.
fn normalizeHooks(allocator: std.mem.Allocator, source: Json) !Json {
    var result: Json = .{ .array = std.json.Array.init(allocator) };
    errdefer values.deinit(allocator, &result);
    const items: []const Json = if (source == .array) source.array.items else &.{source};
    for (items) |item| {
        var hook: Json = .{ .object = .empty };
        errdefer values.deinit(allocator, &hook);
        var parsed: ?std.json.Parsed(Json) = null;
        defer if (parsed) |*document| document.deinit();
        var input = item;
        if (item == .string) {
            parsed = std.json.parseFromSlice(Json, allocator, item.string, .{}) catch null;
            if (parsed) |document| if (document.value == .object) {
                input = document.value;
            };
        }
        if (input == .string) {
            try values.put(allocator, &hook, "sql", input);
        } else if (input == .object and values.get(input, "sql") != null) {
            try values.overlay(allocator, &hook, input);
        } else return error.InvalidHookConfiguration;
        if (values.get(hook, "transaction") == null) try values.put(allocator, &hook, "transaction", .{ .bool = true });
        if (values.get(hook, "index") == null) try values.put(allocator, &hook, "index", .null);
        try result.array.append(hook);
    }
    return result;
}

pub fn node(allocator: std.mem.Allocator, resource: *const types.Node) !Json {
    var result = try defaults(allocator, resource.resource_type);
    errdefer values.deinit(allocator, &result);
    try values.put(allocator, &result, "enabled", .{ .bool = resource.enabled });
    try values.put(allocator, &result, "materialized", .{ .string = resource.materialized });
    const tags = try strings(allocator, if (resource.hook_index != null) &.{} else resource.tags.items);
    defer {
        var owned = tags;
        values.deinit(allocator, &owned);
    }
    try values.put(allocator, &result, "tags", tags);
    try nullableString(allocator, &result, "alias", resource.config_alias);
    try nullableString(allocator, &result, "schema", resource.config_schema);
    var docs: Json = .{ .object = .empty };
    defer values.deinit(allocator, &docs);
    try values.put(allocator, &docs, "show", .{ .bool = resource.docs.show });
    try nullableString(allocator, &docs, "node_color", resource.docs.node_color);
    try values.put(allocator, &result, "docs", docs);
    if (resource.persist_docs) |persist| {
        var data: Json = .{ .object = .empty };
        defer values.deinit(allocator, &data);
        if (persist.relation) |v| try values.put(allocator, &data, "relation", .{ .bool = v });
        if (persist.columns) |v| try values.put(allocator, &data, "columns", .{ .bool = v });
        try values.put(allocator, &result, "persist_docs", data);
    }
    if (std.mem.eql(u8, resource.resource_type, "seed")) {
        try values.put(allocator, &result, "quote_columns", if (resource.quote_columns) |v| .{ .bool = v } else .null);
        var data: Json = .{ .object = .empty };
        defer values.deinit(allocator, &data);
        for (resource.seed_column_types.items) |column| try values.put(allocator, &data, column.name, .{ .string = column.data_type });
        try values.put(allocator, &result, "column_types", data);
    }
    if (std.mem.eql(u8, resource.materialized, "incremental")) {
        const keys = try columns(allocator, resource.incremental.unique_key);
        defer {
            var owned = keys;
            values.deinit(allocator, &owned);
        }
        try values.put(allocator, &result, "unique_key", keys);
        try nullableString(allocator, &result, "incremental_strategy", resource.incremental.strategy);
        try values.put(allocator, &result, "on_schema_change", .{ .string = resource.incremental.on_schema_change orelse "ignore" });
        try values.put(allocator, &result, "full_refresh", if (resource.incremental.full_refresh) |v| .{ .bool = v } else .null);
        if (resource.incremental.configured.predicates) {
            var predicates: Json = if (resource.incremental.predicates_null) .null else try strings(allocator, resource.incremental.predicates.items);
            defer values.deinit(allocator, &predicates);
            try values.put(allocator, &result, "incremental_predicates", predicates);
        }
    }
    if (resource.snapshot_config) |snapshot| {
        inline for (.{ "strategy", "target_schema", "target_database", "updated_at", "hard_deletes", "dbt_valid_to_current" }) |key| {
            const text = @field(snapshot, key);
            if (text != null or !std.mem.eql(u8, key, "hard_deletes")) try nullableString(allocator, &result, key, text);
        }
        inline for (.{ "unique_key", "check_cols" }) |key| {
            var data = try columns(allocator, @field(snapshot, key));
            defer values.deinit(allocator, &data);
            try values.put(allocator, &result, key, data);
        }
        if (snapshot.invalidate_hard_deletes) |v| try values.put(allocator, &result, "invalidate_hard_deletes", .{ .bool = v });
        var names = try values.clone(allocator, result.object.get("snapshot_meta_column_names").?);
        defer values.deinit(allocator, &names);
        inline for (.{ "dbt_scd_id", "dbt_updated_at", "dbt_valid_from", "dbt_valid_to", "dbt_is_deleted" }, 0..) |key, index| {
            if (snapshot.meta_columns_fields & (@as(u5, 1) << index) != 0) try values.put(allocator, &names, key, .{ .string = @field(snapshot.meta_columns, key) });
        }
        try values.put(allocator, &result, "snapshot_meta_column_names", names);
        if (resource.snapshot_meta_json) |meta| try values.put(allocator, &result, "meta", meta);
    }
    // Structured defaults survive partial authored mappings; extension keys
    // remain present without flattening their JSON types.
    if (resource.effective_config == .object) {
        var iterator = resource.effective_config.object.iterator();
        while (iterator.next()) |entry| {
            const key = entry.key_ptr.*;
            var structured = false;
            inline for (.{ "docs", "contract", "snapshot_meta_column_names" }) |name| if (std.mem.eql(u8, key, name) and entry.value_ptr.* == .object) {
                structured = true;
            };
            if (structured) {
                var mapping = try values.clone(allocator, values.get(result, key) orelse .{ .object = .empty });
                defer values.deinit(allocator, &mapping);
                try values.overlay(allocator, &mapping, entry.value_ptr.*);
                try values.put(allocator, &result, key, mapping);
            } else try values.put(allocator, &result, key, entry.value_ptr.*);
        }
    }
    inline for (.{ "pre-hook", "post-hook" }) |key| {
        var hooks = try normalizeHooks(allocator, result.object.get(key).?);
        defer values.deinit(allocator, &hooks);
        try values.put(allocator, &result, key, hooks);
    }
    return result;
}

pub fn testConfig(allocator: std.mem.Allocator, configured: types.GenericTestConfig, enabled: bool, tags: []const []const u8, extra: Json) !Json {
    var result = try defaults(allocator, "test");
    errdefer values.deinit(allocator, &result);
    try values.overlay(allocator, &result, extra);
    try values.put(allocator, &result, "enabled", .{ .bool = enabled });
    inline for (.{ "severity", "fail_calc", "warn_if", "error_if" }) |key| try values.put(allocator, &result, key, .{ .string = @field(configured, key) });
    inline for (.{ "alias", "database", "where" }) |key| try nullableString(allocator, &result, key, @field(configured, key));
    try values.put(allocator, &result, "schema", if (configured.schema) |schema| .{ .string = schema } else if (configured.configured.contains(.schema)) .null else .{ .string = "dbt_test__audit" });
    try values.put(allocator, &result, "limit", if (configured.limit) |limit| .{ .integer = @intCast(limit) } else .null);
    const audits = @import("test_audits.zig");
    try values.put(allocator, &result, "store_failures", if (audits.configuredStore(configured)) |v| .{ .bool = v } else .null);
    try nullableString(allocator, &result, "store_failures_as", audits.configuredKind(configured));
    if (tags.len != 0 or values.get(extra, "tags") == null) {
        var list = try strings(allocator, tags);
        defer values.deinit(allocator, &list);
        try values.put(allocator, &result, "tags", list);
    }
    return result;
}

test "resource config defaults distinguish models seeds snapshots and tests" {
    const allocator = std.testing.allocator;
    inline for (.{ "model", "seed", "snapshot", "test" }) |kind| {
        var result = try defaults(allocator, kind);
        defer values.deinit(allocator, &result);
        try std.testing.expect(result.object.contains("group"));
        try std.testing.expectEqual(std.mem.eql(u8, kind, "model"), result.object.contains("access"));
        try std.testing.expectEqual(std.mem.eql(u8, kind, "seed"), result.object.contains("delimiter"));
        try std.testing.expectEqual(!std.mem.eql(u8, kind, "test"), result.object.contains("contract"));
    }
}
