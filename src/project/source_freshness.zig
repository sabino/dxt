const std = @import("std");
const Io = std.Io;
const project_fs = @import("fs.zig");
const json = @import("json.zig");
const types = @import("types.zig");

const Runtime = types.Runtime;
const FreshnessThreshold = types.FreshnessThreshold;
const FreshnessTime = types.FreshnessTime;
const SourceDef = types.SourceDef;

pub const CheckResult = struct {
    source: *const SourceDef,
    status: []const u8,
    max_loaded_at: ?[]const u8 = null,
    snapshotted_at: ?[]const u8 = null,
    age_seconds: f64 = 0,
    error_message: ?[]const u8 = null,
};

pub const SourceStatusRow = struct {
    unique_id: []const u8,
    status: []const u8,
};

pub const SourceStatusIndex = struct {
    rows: []SourceStatusRow = &.{},

    pub fn deinit(self: *SourceStatusIndex, allocator: std.mem.Allocator) void {
        for (self.rows) |row| {
            allocator.free(row.unique_id);
            allocator.free(row.status);
        }
        allocator.free(self.rows);
        self.* = .{};
    }

    pub fn statusFor(self: *const SourceStatusIndex, unique_id: []const u8) ?[]const u8 {
        for (self.rows) |row| {
            if (std.mem.eql(u8, row.unique_id, unique_id)) return row.status;
        }
        return null;
    }
};

pub const unsupported_metadata_freshness_message = "source freshness requires loaded_at_field or loaded_at_query because the DuckDB adapter does not support metadata-based freshness";

pub fn deinitResults(allocator: std.mem.Allocator, results: []const CheckResult) void {
    for (results) |result| {
        if (result.max_loaded_at) |value| allocator.free(value);
        if (result.snapshotted_at) |value| allocator.free(value);
        if (result.error_message) |value| allocator.free(value);
    }
}

pub fn loadSourceStatusIndex(runtime: Runtime, state_dir: []const u8) !SourceStatusIndex {
    const path = try project_fs.pathJoin(runtime.allocator, &.{ state_dir, "sources.json" });
    defer runtime.allocator.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.MissingSourcesArtifact,
        else => return err,
    };
    defer runtime.allocator.free(text);
    return try parseSourceStatusIndex(runtime.allocator, text);
}

pub fn parseSourceStatusIndex(allocator: std.mem.Allocator, text: []const u8) !SourceStatusIndex {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return error.MalformedSourcesArtifact;
    defer parsed.deinit();

    const root = if (parsed.value == .object) parsed.value.object else return error.MalformedSourcesArtifact;
    const metadata_value = root.get("metadata") orelse return error.MalformedSourcesArtifact;
    const metadata = if (metadata_value == .object) metadata_value.object else return error.MalformedSourcesArtifact;
    const schema_value = metadata.get("dbt_schema_version") orelse return error.MalformedSourcesArtifact;
    const schema_version = if (schema_value == .string) schema_value.string else return error.MalformedSourcesArtifact;
    if (!std.mem.eql(u8, schema_version, "https://schemas.getdbt.com/dbt/sources/v3.json")) return error.UnsupportedSourcesSchemaVersion;

    const results_value = root.get("results") orelse return error.MalformedSourcesArtifact;
    const results = if (results_value == .array) results_value.array else return error.MalformedSourcesArtifact;

    var rows: std.ArrayList(SourceStatusRow) = .empty;
    errdefer {
        for (rows.items) |row| {
            allocator.free(row.unique_id);
            allocator.free(row.status);
        }
        rows.deinit(allocator);
    }

    for (results.items) |result_value| {
        const result = if (result_value == .object) result_value.object else return error.MalformedSourcesArtifact;
        const unique_id_value = result.get("unique_id") orelse return error.MalformedSourcesArtifact;
        const status_value = result.get("status") orelse return error.MalformedSourcesArtifact;
        const unique_id = if (unique_id_value == .string) unique_id_value.string else return error.MalformedSourcesArtifact;
        const status = if (status_value == .string) status_value.string else return error.MalformedSourcesArtifact;
        if (!isSupportedSourceStatus(status)) return error.MalformedSourcesArtifact;
        try rows.append(allocator, .{
            .unique_id = try allocator.dupe(u8, unique_id),
            .status = try allocator.dupe(u8, status),
        });
    }

    return .{ .rows = try rows.toOwnedSlice(allocator) };
}

pub fn isSupportedSourceStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "pass") or
        std.mem.eql(u8, status, "warn") or
        std.mem.eql(u8, status, "error") or
        std.mem.eql(u8, status, "runtime error");
}

pub fn isRunnableSource(source: *const SourceDef) bool {
    return source.freshness != null;
}

pub fn validateThreshold(threshold: FreshnessThreshold) !void {
    if (threshold.warn_after) |time| try validateTime(time);
    if (threshold.error_after) |time| try validateTime(time);
}

pub fn unsupportedExecutionReason(source: *const SourceDef) ?[]const u8 {
    if (source.freshness != null and source.loaded_at_field == null and source.loaded_at_query == null) {
        return unsupported_metadata_freshness_message;
    }
    return null;
}

fn validateTime(time: FreshnessTime) !void {
    if (time.count == null or time.period == null) return error.UnsupportedSourceFreshness;
    _ = try periodSeconds(time.period.?);
}

pub fn statusForAge(age_seconds: f64, threshold: FreshnessThreshold) ![]const u8 {
    if (threshold.error_after) |time| {
        const count = time.count orelse return error.UnsupportedSourceFreshness;
        const period = time.period orelse return error.UnsupportedSourceFreshness;
        if (age_seconds > @as(f64, @floatFromInt(count)) * @as(f64, @floatFromInt(try periodSeconds(period)))) return "error";
    }
    if (threshold.warn_after) |time| {
        const count = time.count orelse return error.UnsupportedSourceFreshness;
        const period = time.period orelse return error.UnsupportedSourceFreshness;
        if (age_seconds > @as(f64, @floatFromInt(count)) * @as(f64, @floatFromInt(try periodSeconds(period)))) return "warn";
    }
    return "pass";
}

fn periodSeconds(period: []const u8) !u64 {
    if (std.mem.eql(u8, period, "minute")) return 60;
    if (std.mem.eql(u8, period, "hour")) return 60 * 60;
    if (std.mem.eql(u8, period, "day")) return 24 * 60 * 60;
    return error.UnsupportedSourceFreshness;
}

pub fn renderSources(allocator: std.mem.Allocator, results: []const CheckResult) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\n  \"metadata\": {\"dbt_schema_version\": ");
    try json.string(writer, "https://schemas.getdbt.com/dbt/sources/v3.json");
    try writer.writeAll(", \"dbt_version\": ");
    try json.string(writer, "0.0.0");
    try writer.writeAll(", \"generated_at\": ");
    try json.string(writer, "1970-01-01T00:00:00Z");
    try writer.writeAll(", \"invocation_id\": null, \"invocation_started_at\": null, \"env\": {}},\n");
    try writer.writeAll("  \"results\": [");
    for (results, 0..) |result, index| {
        if (index != 0) try writer.writeAll(",");
        try writeResult(writer, result);
    }
    try writer.writeAll("\n  ],\n  \"elapsed_time\": 0.0\n}\n");
    return try out.toOwnedSlice();
}

fn writeResult(writer: *Io.Writer, result: CheckResult) !void {
    if (std.mem.eql(u8, result.status, "runtime error")) {
        try writer.writeAll("\n    {\"unique_id\": ");
        try json.string(writer, result.source.unique_id);
        try writer.writeAll(", \"error\": ");
        if (result.error_message) |message| {
            try json.string(writer, message);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(", \"status\": \"runtime error\"}");
        return;
    }

    const freshness = result.source.freshness orelse return error.UnsupportedSourceFreshness;
    try writer.writeAll("\n    {\"unique_id\": ");
    try json.string(writer, result.source.unique_id);
    try writer.writeAll(", \"max_loaded_at\": ");
    try json.string(writer, result.max_loaded_at orelse return error.UnsupportedSourceFreshness);
    try writer.writeAll(", \"snapshotted_at\": ");
    try json.string(writer, result.snapshotted_at orelse return error.UnsupportedSourceFreshness);
    try writer.writeAll(", \"max_loaded_at_time_ago_in_s\": ");
    try writer.print("{d}", .{result.age_seconds});
    try writer.writeAll(", \"status\": ");
    try json.string(writer, result.status);
    try writer.writeAll(", \"criteria\": ");
    try writeCriteria(writer, freshness);
    try writer.writeAll(", \"adapter_response\": {}, \"timing\": [{\"name\": \"execute\", \"started_at\": null, \"completed_at\": null}], \"thread_id\": \"Thread-1\", \"execution_time\": 0.0}");
}

fn writeCriteria(writer: *Io.Writer, threshold: FreshnessThreshold) !void {
    try writer.writeAll("{\"warn_after\": ");
    try writeTimeOrNull(writer, threshold.warn_after);
    try writer.writeAll(", \"error_after\": ");
    try writeTimeOrNull(writer, threshold.error_after);
    try writer.writeAll(", \"filter\": ");
    if (threshold.filter) |filter| {
        try json.string(writer, filter);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll("}");
}

fn writeTimeOrNull(writer: *Io.Writer, maybe_time: ?FreshnessTime) !void {
    if (maybe_time) |time| {
        const count = time.count orelse return error.UnsupportedSourceFreshness;
        const period = time.period orelse return error.UnsupportedSourceFreshness;
        try writer.writeAll("{\"count\": ");
        try writer.print("{d}", .{count});
        try writer.writeAll(", \"period\": ");
        try json.string(writer, period);
        try writer.writeAll("}");
    } else {
        try writer.writeAll("null");
    }
}

test "source freshness status follows error warn pass threshold order" {
    const threshold = FreshnessThreshold{
        .warn_after = .{ .count = 1, .period = "hour" },
        .error_after = .{ .count = 1, .period = "day" },
    };
    try std.testing.expectEqualStrings("pass", try statusForAge(3599, threshold));
    try std.testing.expectEqualStrings("warn", try statusForAge(7200, threshold));
    try std.testing.expectEqualStrings("error", try statusForAge(90000, threshold));
}

test "source freshness validation rejects partial thresholds at command boundary" {
    try std.testing.expectError(error.UnsupportedSourceFreshness, validateThreshold(.{ .warn_after = .{ .period = "hour" } }));
    try std.testing.expectError(error.UnsupportedSourceFreshness, validateThreshold(.{ .warn_after = .{ .count = 1 } }));
    try validateThreshold(.{ .warn_after = .{ .count = 1, .period = "hour" }, .filter = "customer_id > 0" });
}

test "source freshness allows loaded_at_query to take precedence over inherited loaded_at_field" {
    const source = SourceDef{
        .package_name = "demo",
        .unique_id = "source.demo.raw.orders",
        .source_name = "raw",
        .table_name = "orders",
        .original_file_path = "models/schema.yml",
        .loaded_at_field = "loaded_at",
        .loaded_at_query = "select max(loaded_at) from raw.orders",
        .freshness = .{},
    };

    try std.testing.expect(unsupportedExecutionReason(&source) == null);
}

test "source freshness reports unsupported DuckDB metadata freshness reason" {
    const source = SourceDef{
        .package_name = "demo",
        .unique_id = "source.demo.raw.orders",
        .source_name = "raw",
        .table_name = "orders",
        .original_file_path = "models/schema.yml",
        .freshness = .{
            .warn_after = .{ .count = 1, .period = "hour" },
            .error_after = .{ .count = 1, .period = "day" },
        },
    };

    const reason = unsupportedExecutionReason(&source).?;
    try std.testing.expectEqualStrings(unsupported_metadata_freshness_message, reason);

    const rendered = try renderSources(std.testing.allocator, &.{.{
        .source = &source,
        .status = "runtime error",
        .error_message = reason,
    }});
    defer std.testing.allocator.free(rendered);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("source.demo.raw.orders", result.get("unique_id").?.string);
    try std.testing.expectEqualStrings("runtime error", result.get("status").?.string);
    try std.testing.expectEqualStrings(unsupported_metadata_freshness_message, result.get("error").?.string);
    try std.testing.expect(result.get("criteria") == null);
}

test "sources writer emits dbt v3 success shape" {
    const source = SourceDef{
        .package_name = "demo",
        .unique_id = "source.demo.raw.orders",
        .source_name = "raw",
        .table_name = "orders",
        .original_file_path = "models/schema.yml",
        .loaded_at_field = "loaded_at",
        .freshness = .{
            .warn_after = .{ .count = 1, .period = "hour" },
            .error_after = .{ .count = 1, .period = "day" },
        },
    };
    const rendered = try renderSources(std.testing.allocator, &.{.{
        .source = &source,
        .status = "warn",
        .max_loaded_at = "2026-06-17T12:00:00Z",
        .snapshotted_at = "2026-06-17T14:00:00Z",
        .age_seconds = 7200,
    }});
    defer std.testing.allocator.free(rendered);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("https://schemas.getdbt.com/dbt/sources/v3.json", root.get("metadata").?.object.get("dbt_schema_version").?.string);
    const result = root.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("source.demo.raw.orders", result.get("unique_id").?.string);
    try std.testing.expectEqualStrings("warn", result.get("status").?.string);
    try std.testing.expectEqualStrings("hour", result.get("criteria").?.object.get("warn_after").?.object.get("period").?.string);
}

test "sources writer emits dbt v3 runtime error shape" {
    const source = SourceDef{
        .package_name = "demo",
        .unique_id = "source.demo.raw.orders",
        .source_name = "raw",
        .table_name = "orders",
        .original_file_path = "models/schema.yml",
        .freshness = .{},
    };
    const rendered = try renderSources(std.testing.allocator, &.{.{
        .source = &source,
        .status = "runtime error",
        .error_message = "DuckDB execution failed",
    }});
    defer std.testing.allocator.free(rendered);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("source.demo.raw.orders", result.get("unique_id").?.string);
    try std.testing.expectEqualStrings("runtime error", result.get("status").?.string);
    try std.testing.expectEqualStrings("DuckDB execution failed", result.get("error").?.string);
    try std.testing.expect(result.get("criteria") == null);
}

test "sources v3 status loader indexes freshness statuses" {
    var index = try parseSourceStatusIndex(std.testing.allocator,
        \\{
        \\  "metadata": {"dbt_schema_version": "https://schemas.getdbt.com/dbt/sources/v3.json"},
        \\  "results": [
        \\    {"unique_id": "source.demo.raw.customers", "status": "pass"},
        \\    {"unique_id": "source.demo.raw.orders", "status": "warn"},
        \\    {"unique_id": "source.demo.raw.payments", "status": "error"}
        \\  ],
        \\  "elapsed_time": 0.0
        \\}
    );
    defer index.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("pass", index.statusFor("source.demo.raw.customers").?);
    try std.testing.expectEqualStrings("warn", index.statusFor("source.demo.raw.orders").?);
    try std.testing.expectEqualStrings("error", index.statusFor("source.demo.raw.payments").?);
    try std.testing.expect(index.statusFor("source.demo.raw.missing") == null);
}

test "sources v3 status loader rejects malformed and version mismatched artifacts" {
    try std.testing.expectError(error.MalformedSourcesArtifact, parseSourceStatusIndex(std.testing.allocator, "{\"metadata\":{},\"results\":[]}"));
    try std.testing.expectError(error.UnsupportedSourcesSchemaVersion, parseSourceStatusIndex(std.testing.allocator,
        \\{
        \\  "metadata": {"dbt_schema_version": "https://schemas.getdbt.com/dbt/sources/v2.json"},
        \\  "results": []
        \\}
    ));
    try std.testing.expectError(error.MalformedSourcesArtifact, parseSourceStatusIndex(std.testing.allocator,
        \\{
        \\  "metadata": {"dbt_schema_version": "https://schemas.getdbt.com/dbt/sources/v3.json"},
        \\  "results": [{"unique_id": "source.demo.raw.orders"}]
        \\}
    ));
}
