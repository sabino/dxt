const std = @import("std");
const project_fs = @import("fs.zig");
const types = @import("types.zig");

const Runtime = types.Runtime;

pub const PriorManifestIndex = struct {
    unique_ids: []const []const u8 = &.{},

    pub fn deinit(self: *PriorManifestIndex, allocator: std.mem.Allocator) void {
        for (self.unique_ids) |unique_id| allocator.free(unique_id);
        allocator.free(self.unique_ids);
        self.* = .{};
    }

    pub fn contains(self: *const PriorManifestIndex, unique_id: []const u8) bool {
        for (self.unique_ids) |candidate| {
            if (std.mem.eql(u8, candidate, unique_id)) return true;
        }
        return false;
    }
};

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
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return error.MalformedStateManifestArtifact;
    defer parsed.deinit();

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

    return .{ .unique_ids = try unique_ids.toOwnedSlice(allocator) };
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
