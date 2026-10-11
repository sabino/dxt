const std = @import("std");
const project_fs = @import("fs.zig");
const types = @import("types.zig");

const Runtime = types.Runtime;

pub const PriorManifestIndex = struct {
    unique_ids: []const []const u8 = &.{},
    parsed: ?std.json.Parsed(std.json.Value) = null,

    pub fn deinit(self: *PriorManifestIndex, allocator: std.mem.Allocator) void {
        for (self.unique_ids) |unique_id| allocator.free(unique_id);
        allocator.free(self.unique_ids);
        if (self.parsed) |*parsed| parsed.deinit();
        self.* = .{};
    }

    pub fn contains(self: *const PriorManifestIndex, unique_id: []const u8) bool {
        for (self.unique_ids) |candidate| {
            if (std.mem.eql(u8, candidate, unique_id)) return true;
        }
        return false;
    }

    pub fn resource(self: *const PriorManifestIndex, unique_id: []const u8) ?std.json.Value {
        const parsed = self.parsed orelse return null;
        for (resource_maps) |field| {
            const map = objectField(parsed.value, field) orelse continue;
            if (map.get(unique_id)) |value| return value;
        }
        return null;
    }

    pub fn macro(self: *const PriorManifestIndex, unique_id: []const u8) ?std.json.Value {
        const parsed = self.parsed orelse return null;
        const macros = objectField(parsed.value, "macros") orelse return null;
        return macros.get(unique_id);
    }

    pub fn matches(self: *const PriorManifestIndex, current: *const PriorManifestIndex, unique_id: []const u8, method: []const u8) bool {
        const old = self.resource(unique_id);
        if (std.mem.eql(u8, method, "new")) return !self.contains(unique_id);
        if (std.mem.eql(u8, method, "old")) return self.contains(unique_id);
        const new = current.resource(unique_id) orelse return false;
        const kind = stringField(new, "resource_type") orelse kindFromId(unique_id);
        if (std.mem.eql(u8, method, "modified.macros")) return self.macrosChanged(current, new, 0);
        if (std.mem.eql(u8, method, "modified.body")) {
            if (!isSqlKind(kind) and !std.mem.eql(u8, kind, "seed")) return false;
            return old == null or !sameBody(old.?, new, kind);
        }
        if (std.mem.eql(u8, method, "modified.configs")) {
            if (std.mem.eql(u8, kind, "unit_test")) return false;
            return old == null or !sameConfig(old.?, new, kind);
        }
        if (std.mem.eql(u8, method, "modified.relation")) {
            if (!isSqlKind(kind) and !std.mem.eql(u8, kind, "seed") and !std.mem.eql(u8, kind, "source")) return false;
            return old == null or !sameRelation(old.?, new, kind);
        }
        if (std.mem.eql(u8, method, "modified.persisted_descriptions")) {
            if (!isSqlKind(kind) and !std.mem.eql(u8, kind, "seed")) return false;
            return old == null or !samePersistedDescriptions(old.?, new);
        }
        if (std.mem.eql(u8, method, "modified.contract")) {
            if (!std.mem.eql(u8, kind, "model")) return false;
            return old == null or !sameContract(old.?, new);
        }
        const changed = if (old) |prior| !sameContents(prior, new, kind) or self.macrosChanged(current, new, 0) else !std.mem.eql(u8, kind, "source") and !std.mem.eql(u8, kind, "exposure");
        if (std.mem.eql(u8, method, "modified")) return changed;
        if (std.mem.eql(u8, method, "unmodified")) return !changed;
        return false;
    }

    fn macrosChanged(self: *const PriorManifestIndex, current: *const PriorManifestIndex, node: std.json.Value, depth: usize) bool {
        if (depth > 128) return false;
        const depends = valueField(node, "depends_on") orelse return false;
        const macros = valueField(depends, "macros") orelse return false;
        if (macros != .array) return false;
        for (macros.array.items) |id| {
            if (id != .string) continue;
            const prior = self.macro(id.string);
            const next = current.macro(id.string);
            // These standard tests are implemented natively, and therefore do
            // not have a user-editable macro node in dxt's current manifest.
            // An authored override has a current macro and is compared below.
            if (next == null and nativeBuiltinMacro(id.string)) continue;
            if (prior == null or next == null) return true;
            if (!equalFields(prior.?, next.?, "macro_sql")) return true;
            if (self.macrosChanged(current, next.?, depth + 1)) return true;
        }
        return false;
    }
};

fn nativeBuiltinMacro(id: []const u8) bool {
    for ([_][]const u8{ "macro.dbt.test_not_null", "macro.dbt.test_unique", "macro.dbt.test_accepted_values", "macro.dbt.test_relationships", "macro.dbt.get_where_subquery" }) |builtin| if (std.mem.eql(u8, id, builtin)) return true;
    return false;
}

const resource_maps = [_][]const u8{ "nodes", "sources", "exposures", "unit_tests", "metrics", "semantic_models", "saved_queries" };

pub fn loadPriorManifestIndex(runtime: Runtime, state_dir: []const u8) !PriorManifestIndex {
    const path = try project_fs.pathJoin(runtime.allocator, &.{ state_dir, "manifest.json" });
    defer runtime.allocator.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.MissingStateManifestArtifact,
        else => return err,
    };
    defer runtime.allocator.free(text);
    return try parsePriorManifestIndex(runtime.allocator, text);
}

pub fn parsePriorManifestIndex(allocator: std.mem.Allocator, text: []const u8) !PriorManifestIndex {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{ .allocate = .alloc_always }) catch return error.MalformedStateManifestArtifact;
    errdefer parsed.deinit();

    const root = if (parsed.value == .object) parsed.value.object else return error.MalformedStateManifestArtifact;
    const metadata_value = root.get("metadata") orelse return error.MalformedStateManifestArtifact;
    const metadata = if (metadata_value == .object) metadata_value.object else return error.MalformedStateManifestArtifact;
    const schema_value = metadata.get("dbt_schema_version") orelse return error.MalformedStateManifestArtifact;
    const schema_version = if (schema_value == .string) schema_value.string else return error.MalformedStateManifestArtifact;
    if (!std.mem.eql(u8, schema_version, "https://schemas.getdbt.com/dbt/manifest/v12.json")) return error.UnsupportedStateManifestSchemaVersion;

    var unique_ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (unique_ids.items) |unique_id| allocator.free(unique_id);
        unique_ids.deinit(allocator);
    }

    try appendManifestMapUniqueIds(allocator, &unique_ids, root, "nodes");
    try appendManifestMapUniqueIds(allocator, &unique_ids, root, "sources");
    try appendManifestMapUniqueIds(allocator, &unique_ids, root, "exposures");
    try appendManifestMapUniqueIds(allocator, &unique_ids, root, "unit_tests");

    for (resource_maps[4..]) |field| {
        if (root.contains(field)) try appendManifestMapUniqueIds(allocator, &unique_ids, root, field);
    }
    return .{ .unique_ids = try unique_ids.toOwnedSlice(allocator), .parsed = parsed };
}

pub fn isSupportedMethod(value: []const u8) bool {
    const methods = [_][]const u8{ "new", "old", "modified", "unmodified", "modified.body", "modified.configs", "modified.relation", "modified.macros", "modified.contract", "modified.persisted_descriptions" };
    for (methods) |method| if (std.mem.eql(u8, value, method)) return true;
    return false;
}

fn kindFromId(id: []const u8) []const u8 {
    return id[0 .. std.mem.indexOfScalar(u8, id, '.') orelse id.len];
}

fn isSqlKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "model") or std.mem.eql(u8, kind, "analysis") or std.mem.eql(u8, kind, "snapshot") or std.mem.eql(u8, kind, "test");
}

pub fn valueField(value: std.json.Value, key: []const u8) ?std.json.Value {
    return if (value == .object) value.object.get(key) else null;
}

fn objectField(value: std.json.Value, key: []const u8) ?std.json.ObjectMap {
    const field = valueField(value, key) orelse return null;
    return if (field == .object) field.object else null;
}

pub fn stringField(value: std.json.Value, key: []const u8) ?[]const u8 {
    const field = valueField(value, key) orelse return null;
    return if (field == .string) field.string else null;
}

pub fn equalValues(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => a.bool == b.bool,
        .integer => a.integer == b.integer,
        .float => a.float == b.float,
        .number_string => std.mem.eql(u8, a.number_string, b.number_string),
        .string => std.mem.eql(u8, a.string, b.string),
        .array => blk: {
            if (a.array.items.len != b.array.items.len) break :blk false;
            for (a.array.items, b.array.items) |av, bv| if (!equalValues(av, bv)) break :blk false;
            break :blk true;
        },
        .object => blk: {
            if (a.object.count() != b.object.count()) break :blk false;
            var iter = a.object.iterator();
            while (iter.next()) |entry| {
                const bv = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!equalValues(entry.value_ptr.*, bv)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn equalOptional(a: ?std.json.Value, b: ?std.json.Value) bool {
    return equalValues(a orelse .null, b orelse .null);
}

fn equalFields(a: std.json.Value, b: std.json.Value, key: []const u8) bool {
    return equalOptional(valueField(a, key), valueField(b, key));
}

fn sameBody(old: std.json.Value, new: std.json.Value, kind: []const u8) bool {
    if (std.mem.eql(u8, kind, "seed")) return equalFields(old, new, "checksum");
    if (std.mem.eql(u8, kind, "snapshot")) return equalFields(old, new, "raw_code");
    const a = stringField(old, "raw_code") orelse "";
    const b = stringField(new, "raw_code") orelse "";
    return std.mem.eql(u8, std.mem.trim(u8, a, " \t\r\n\x0b\x0c"), std.mem.trim(u8, b, " \t\r\n\x0b\x0c"));
}

fn configOf(node: std.json.Value) std.json.Value {
    return valueField(node, "unrendered_config") orelse valueField(node, "config") orelse .null;
}

fn excludedConfig(key: []const u8) bool {
    for ([_][]const u8{ "alias", "schema", "database", "tags", "group" }) |excluded| if (std.mem.eql(u8, key, excluded)) return true;
    return false;
}

fn sameConfig(old: std.json.Value, new: std.json.Value, kind: []const u8) bool {
    const a = configOf(old);
    const b = configOf(new);
    if (a != .object or b != .object) return equalValues(a, b);
    if (std.mem.eql(u8, kind, "test")) {
        for ([_][]const u8{ "severity", "where", "limit", "fail_calc", "warn_if", "error_if", "store_failures", "store_failures_as" }) |key| {
            if (!sameConfigField(a, b, key)) return false;
        }
        return true;
    }
    for ([_]std.json.ObjectMap{ a.object, b.object }) |map| {
        var iter = map.iterator();
        while (iter.next()) |entry| {
            if ((isSqlKind(kind) or std.mem.eql(u8, kind, "seed")) and excludedConfig(entry.key_ptr.*)) continue;
            if (!sameConfigField(a, b, entry.key_ptr.*)) return false;
        }
    }
    return true;
}

fn sameConfigField(a: std.json.Value, b: std.json.Value, key: []const u8) bool {
    if (a.object.contains(key) != b.object.contains(key)) return false;
    return equalFields(a, b, key);
}

fn sameRelation(old: std.json.Value, new: std.json.Value, kind: []const u8) bool {
    if (std.mem.eql(u8, kind, "source")) {
        for ([_][]const u8{ "database", "schema", "identifier" }) |key| if (!equalFields(old, new, key)) return false;
        return true;
    }
    const a = configOf(old);
    const b = configOf(new);
    for ([_][]const u8{ "database", "schema", "alias" }) |key| if (!equalFields(a, b, key)) return false;
    return true;
}

fn configBool(node: std.json.Value, object_key: []const u8, key: []const u8) bool {
    const config = valueField(node, "config") orelse return false;
    const object = valueField(config, object_key) orelse return false;
    const value = valueField(object, key) orelse return false;
    return value == .bool and value.bool;
}

fn samePersistedDescriptions(old: std.json.Value, new: std.json.Value) bool {
    if (configBool(new, "persist_docs", "relation") and !equalFields(old, new, "description")) return false;
    if (configBool(new, "persist_docs", "columns")) {
        const a = objectField(old, "columns") orelse std.json.ObjectMap{};
        const b = objectField(new, "columns") orelse std.json.ObjectMap{};
        if (a.count() != b.count()) return false;
        var iter = b.iterator();
        while (iter.next()) |entry| {
            const prior = a.get(entry.key_ptr.*) orelse return false;
            if (!equalFields(prior, entry.value_ptr.*, "description")) return false;
        }
    }
    return true;
}

fn sameContract(old: std.json.Value, new: std.json.Value) bool {
    const a = valueField(old, "contract") orelse valueField(configOf(old), "contract") orelse .null;
    const b = valueField(new, "contract") orelse valueField(configOf(new), "contract") orelse .null;
    const av: std.json.Value = valueField(a, "enforced") orelse .{ .bool = false };
    const bv: std.json.Value = valueField(b, "enforced") orelse .{ .bool = false };
    if (av == .bool and bv == .bool and !av.bool and !bv.bool) return true;
    return equalValues(av, bv) and equalFields(a, b, "checksum");
}

fn sameContents(old: std.json.Value, new: std.json.Value, kind: []const u8) bool {
    if (std.mem.eql(u8, kind, "test") and valueField(new, "test_metadata") != null) return sameConfig(old, new, kind) and equalFields(old, new, "fqn");
    if (isSqlKind(kind) or std.mem.eql(u8, kind, "seed")) return sameBody(old, new, kind) and sameConfig(old, new, kind) and sameRelation(old, new, kind) and samePersistedDescriptions(old, new) and equalFields(old, new, "fqn") and (!std.mem.eql(u8, kind, "model") or sameContract(old, new));
    if (std.mem.eql(u8, kind, "source")) {
        for ([_][]const u8{ "fqn", "quoting", "freshness", "loaded_at_field", "external" }) |key| if (!equalFields(old, new, key)) return false;
        return sameRelation(old, new, kind) and sameConfig(old, new, kind);
    }
    if (std.mem.eql(u8, kind, "exposure")) {
        for ([_][]const u8{ "fqn", "type", "owner", "maturity", "url", "description", "label", "depends_on" }) |key| if (!equalFields(old, new, key)) return false;
        return sameConfig(old, new, kind);
    }
    if (std.mem.eql(u8, kind, "unit_test")) {
        // Core hashes these fixture fields. Comparing the structured inputs also
        // supports manifests whose unit-test checksum has not been populated.
        for ([_][]const u8{ "model", "versions", "given", "expect", "overrides" }) |key| if (!equalFields(old, new, key)) return false;
        return true;
    }
    return sameConfig(old, new, kind);
}

fn appendManifestMapUniqueIds(allocator: std.mem.Allocator, unique_ids: *std.ArrayList([]const u8), root: std.json.ObjectMap, field: []const u8) !void {
    const value = root.get(field) orelse return error.MalformedStateManifestArtifact;
    const object = if (value == .object) value.object else return error.MalformedStateManifestArtifact;
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const resource = if (entry.value_ptr.* == .object) entry.value_ptr.*.object else return error.MalformedStateManifestArtifact;
        const unique_id_value = resource.get("unique_id") orelse return error.MalformedStateManifestArtifact;
        const unique_id = if (unique_id_value == .string) unique_id_value.string else return error.MalformedStateManifestArtifact;
        if (!std.mem.eql(u8, entry.key_ptr.*, unique_id)) return error.MalformedStateManifestArtifact;
        if (!containsString(unique_ids.items, unique_id)) try unique_ids.append(allocator, try allocator.dupe(u8, unique_id));
    }
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

test "prior manifest index reads supported resource maps" {
    const text =
        \\{
        \\  "metadata": {"dbt_schema_version": "https://schemas.getdbt.com/dbt/manifest/v12.json"},
        \\  "nodes": {
        \\    "model.demo.customers": {"unique_id": "model.demo.customers"},
        \\    "test.demo.not_null_customers.abc": {"unique_id": "test.demo.not_null_customers.abc"}
        \\  },
        \\  "sources": {"source.demo.raw.customers": {"unique_id": "source.demo.raw.customers"}},
        \\  "exposures": {"exposure.demo.dashboard": {"unique_id": "exposure.demo.dashboard"}},
        \\  "unit_tests": {"unit_test.demo.customers.assert_rows": {"unique_id": "unit_test.demo.customers.assert_rows"}}
        \\}
    ;
    var index = try parsePriorManifestIndex(std.testing.allocator, text);
    defer index.deinit(std.testing.allocator);

    try std.testing.expect(index.contains("model.demo.customers"));
    try std.testing.expect(index.contains("test.demo.not_null_customers.abc"));
    try std.testing.expect(index.contains("source.demo.raw.customers"));
    try std.testing.expect(index.contains("exposure.demo.dashboard"));
    try std.testing.expect(index.contains("unit_test.demo.customers.assert_rows"));
    try std.testing.expect(!index.contains("model.demo.orders"));
}

test "prior manifest index rejects malformed and unsupported manifests" {
    try std.testing.expectError(error.MalformedStateManifestArtifact, parsePriorManifestIndex(std.testing.allocator, "{}"));
    try std.testing.expectError(
        error.UnsupportedStateManifestSchemaVersion,
        parsePriorManifestIndex(std.testing.allocator,
            \\{"metadata":{"dbt_schema_version":"https://schemas.getdbt.com/dbt/manifest/v11.json"},"nodes":{},"sources":{},"exposures":{},"unit_tests":{}}
        ),
    );
    try std.testing.expectError(
        error.MalformedStateManifestArtifact,
        parsePriorManifestIndex(std.testing.allocator,
            \\{"metadata":{"dbt_schema_version":"https://schemas.getdbt.com/dbt/manifest/v12.json"},"nodes":{"model.demo.customers":{}},"sources":{},"exposures":{},"unit_tests":{}}
        ),
    );
}

test "state comparisons ignore rendered target identity and tags but retain configured relation and body" {
    const allocator = std.testing.allocator;
    var old = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"raw_code":"select 1", "database":"prod", "schema":"prod", "fqn":["demo","a"], "unrendered_config":{"materialized":"table","tags":["old"]}, "config":{}}
    , .{});
    defer old.deinit();
    var current = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"raw_code":"select 1\n", "database":"dev", "schema":"dev", "fqn":["demo","a"], "unrendered_config":{"materialized":"table","tags":["new"]}, "config":{}}
    , .{});
    defer current.deinit();
    try std.testing.expect(sameContents(old.value, current.value, "model"));
    try current.value.object.getPtr("unrendered_config").?.object.put(allocator, "alias", .{ .string = "different" });
    try std.testing.expect(sameConfig(old.value, current.value, "model"));
    try std.testing.expect(!sameRelation(old.value, current.value, "model"));
}

test "persisted description and contract comparisons are conditional on enforcement" {
    const allocator = std.testing.allocator;
    var old = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"description":"before", "columns":{"id":{"description":"before"}}, "contract":{"enforced":false}, "config":{"persist_docs":{"relation":false,"columns":false}}}
    , .{});
    defer old.deinit();
    var current = try std.json.parseFromSlice(std.json.Value, allocator,
        \\{"description":"after", "columns":{"id":{"description":"after"}}, "contract":{"enforced":false}, "config":{"persist_docs":{"relation":false,"columns":false}}}
    , .{});
    defer current.deinit();
    try std.testing.expect(samePersistedDescriptions(old.value, current.value));
    try std.testing.expect(sameContract(old.value, current.value));
    try current.value.object.getPtr("config").?.object.getPtr("persist_docs").?.object.put(allocator, "columns", .{ .bool = true });
    try std.testing.expect(!samePersistedDescriptions(old.value, current.value));
    try current.value.object.getPtr("contract").?.object.put(allocator, "enforced", .{ .bool = true });
    try std.testing.expect(!sameContract(old.value, current.value));
}

test "state manifest retains artifact strings after the input buffer is released" {
    const allocator = std.testing.allocator;
    const input = try allocator.dupe(u8,
        \\{"metadata":{"dbt_schema_version":"https://schemas.getdbt.com/dbt/manifest/v12.json"},"nodes":{"model.demo.a":{"unique_id":"model.demo.a","raw_code":"select 1"}},"sources":{},"exposures":{},"unit_tests":{}}
    );
    var index = try parsePriorManifestIndex(allocator, input);
    allocator.free(input);
    defer index.deinit(allocator);
    try std.testing.expectEqualStrings("select 1", stringField(index.resource("model.demo.a").?, "raw_code").?);
    try std.testing.expect(index.matches(&index, "model.demo.a", "old"));
    try std.testing.expect(!index.matches(&index, "model.demo.a", "modified.body"));
}
