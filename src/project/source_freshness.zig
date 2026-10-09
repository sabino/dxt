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
    max_loaded_at: ?[]const u8 = null,
};

pub const SourceStatusIndex = struct {
    rows: []SourceStatusRow = &.{},

    pub fn deinit(self: *SourceStatusIndex, allocator: std.mem.Allocator) void {
        for (self.rows) |row| {
            allocator.free(row.unique_id);
            allocator.free(row.status);
            if (row.max_loaded_at) |value| allocator.free(value);
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

    pub fn isFresherThan(self: *const SourceStatusIndex, previous: *const SourceStatusIndex, unique_id: []const u8) bool {
        for (self.rows) |current| {
            if (!std.mem.eql(u8, current.unique_id, unique_id) or std.mem.eql(u8, current.status, "runtime error")) continue;
            const current_time = parseFreshnessTimestamp(current.max_loaded_at orelse return false) catch return false;
            for (previous.rows) |prior| {
                if (!std.mem.eql(u8, prior.unique_id, unique_id)) continue;
                if (prior.max_loaded_at == null or std.mem.eql(u8, prior.status, "runtime error")) return true;
                const prior_time = parseFreshnessTimestamp(prior.max_loaded_at.?) catch return false;
                return current_time > prior_time;
            }
            return true;
        }
        return false;
    }
};

pub const unsupported_metadata_freshness_message = "source freshness requires loaded_at_field or loaded_at_query because the DuckDB adapter does not support metadata-based freshness";

pub fn parseFreshnessTimestamp(text: []const u8) !i128 {
    if (text.len < 19 or text[4] != '-' or text[7] != '-' or (text[10] != 'T' and text[10] != ' ') or text[13] != ':' or text[16] != ':') return error.MalformedSourcesArtifact;
    const year = std.fmt.parseInt(i64, text[0..4], 10) catch return error.MalformedSourcesArtifact;
    const month = std.fmt.parseInt(usize, text[5..7], 10) catch return error.MalformedSourcesArtifact;
    const day = std.fmt.parseInt(i64, text[8..10], 10) catch return error.MalformedSourcesArtifact;
    const hour = std.fmt.parseInt(i64, text[11..13], 10) catch return error.MalformedSourcesArtifact;
    const minute = std.fmt.parseInt(i64, text[14..16], 10) catch return error.MalformedSourcesArtifact;
    const second = std.fmt.parseInt(i64, text[17..19], 10) catch return error.MalformedSourcesArtifact;
    if (year < 1 or month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59 or hour < 0 or minute < 0 or second < 0) return error.MalformedSourcesArtifact;
    var months = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) months[1] = 29;
    if (day < 1 or day > months[month - 1]) return error.MalformedSourcesArtifact;
    const prior_year = year - 1;
    var days = prior_year * 365 + @divFloor(prior_year, 4) - @divFloor(prior_year, 100) + @divFloor(prior_year, 400) + day - 1;
    for (months[0 .. month - 1]) |count| days += count;
    var nanos: i128 = @as(i128, days * 86400 + hour * 3600 + minute * 60 + second) * 1_000_000_000;
    var position: usize = 19;
    if (position < text.len and text[position] == '.') {
        position += 1;
        const start = position;
        var scale: i128 = 100_000_000;
        while (position < text.len and std.ascii.isDigit(text[position])) : (position += 1) {
            // Core's datetime artifacts retain microsecond precision.
            if (position - start < 6) nanos += @as(i128, text[position] - '0') * scale;
            scale = @divTrunc(scale, 10);
        }
        if (position == start) return error.MalformedSourcesArtifact;
    }
    if (position == text.len) return nanos;
    if (std.mem.eql(u8, text[position..], "Z")) return nanos;
    const offset = text[position..];
    if (offset.len != 6 or (offset[0] != '+' and offset[0] != '-') or offset[3] != ':') return error.MalformedSourcesArtifact;
    const offset_hour = std.fmt.parseInt(i64, offset[1..3], 10) catch return error.MalformedSourcesArtifact;
    const offset_minute = std.fmt.parseInt(i64, offset[4..6], 10) catch return error.MalformedSourcesArtifact;
    if (offset_hour < 0 or offset_hour > 23 or offset_minute < 0 or offset_minute > 59) return error.MalformedSourcesArtifact;
    const offset_nanos: i128 = @as(i128, offset_hour * 3600 + offset_minute * 60) * 1_000_000_000;
    return if (offset[0] == '+') nanos - offset_nanos else nanos + offset_nanos;
}

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
            if (row.max_loaded_at) |value| allocator.free(value);
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
        const timestamp = if (result.get("max_loaded_at")) |value| switch (value) {
            .string => blk: {
                _ = try parseFreshnessTimestamp(value.string);
                break :blk value.string;
            },
            .null => null,
            else => return error.MalformedSourcesArtifact,
        } else null;
        const owned_id = try allocator.dupe(u8, unique_id);
        errdefer allocator.free(owned_id);
        const owned_status = try allocator.dupe(u8, status);
        errdefer allocator.free(owned_status);
        const owned_timestamp = if (timestamp) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_timestamp) |value| allocator.free(value);
        try rows.append(allocator, .{ .unique_id = owned_id, .status = owned_status, .max_loaded_at = owned_timestamp });
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
    return renderSourcesWithInvocation(allocator, results, null);
}

pub fn renderSourcesWithInvocation(allocator: std.mem.Allocator, results: []const CheckResult, metadata: ?*const @import("invocation.zig").Metadata) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\n  \"metadata\": {");
    try @import("invocation.zig").writeFields(writer, "https://schemas.getdbt.com/dbt/sources/v3.json", metadata);
    try writer.writeAll("},\n");
    try writer.writeAll("  \"results\": [");
    for (results, 0..) |result, index| {
        if (index != 0) try writer.writeAll(",");
        try writeResult(writer, result);
    }
    try writer.print("\n  ],\n  \"elapsed_time\": {d}\n}}\n", .{if (metadata) |value| value.elapsed() else @as(f64, 0)});
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

test "freshness timestamp comparison respects offsets and fractional seconds" {
    try std.testing.expectEqual(try parseFreshnessTimestamp("2026-01-01T00:00:00Z"), try parseFreshnessTimestamp("2025-12-31T21:00:00-03:00"));
    try std.testing.expect((try parseFreshnessTimestamp("2026-01-01T00:00:00.000001Z")) > (try parseFreshnessTimestamp("2026-01-01T00:00:00Z")));
    try std.testing.expectEqual(try parseFreshnessTimestamp("2026-01-01T00:00:00Z"), try parseFreshnessTimestamp("2026-01-01T00:00:00.0000001Z"));
    try std.testing.expectError(error.MalformedSourcesArtifact, parseFreshnessTimestamp("2026-02-29T00:00:00Z"));
    try std.testing.expectError(error.MalformedSourcesArtifact, parseFreshnessTimestamp("invalid"));
}
