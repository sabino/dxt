//! Core 1.10.5 BaseRelation.__str__/RuntimeResolver input limits and sampling.
//! Explicit Relation.render() returns the base relation; this wrapper is only
//! the relation's implicit SQL value.
const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");
const yaml = @import("yaml.zig");
const calendar = @import("workflow_intervals.zig");
const clock = @import("execution_clock.zig");

pub fn render(allocator: std.mem.Allocator, graph: *const types.Graph, current: *const types.Node, target_config: std.json.Value, target_name: []const u8, base_relation: []const u8) ![]const u8 {
    var result = try allocator.dupe(u8, base_relation);
    errdefer allocator.free(result);
    // Core unit fixture resolvers deliberately ignore input limits/sampling.
    if (graph.unit_fixture_relations) return result;
    if (graph.command_options.empty) {
        const alias = try subqueryAlias(allocator, graph, "limit", target_name);
        defer allocator.free(alias);
        const replacement = try std.fmt.allocPrint(allocator, "(select * from {s} where false limit 0){s}", .{ result, alias });
        allocator.free(result);
        result = replacement;
    }
    if (!std.mem.eql(u8, current.resource_type, "model") and !std.mem.eql(u8, current.resource_type, "snapshot")) return result;
    const field = values.get(target_config, "event_time") orelse return result;
    if (field == .null) return result;
    if (field != .string) return error.InvalidEventTimeConfiguration;
    var window = current.runtime_batch orelse graph.command_options.sample_window orelse return result;
    if (current.runtime_batch != null) if (graph.command_options.sample_window) |sample| {
        window.start = @max(window.start, sample.start);
        window.end = @min(window.end, sample.end);
    };
    const start = try formatSampleTimestamp(allocator, window.start);
    defer allocator.free(start);
    const end = try formatSampleTimestamp(allocator, window.end);
    defer allocator.free(end);
    const alias = try subqueryAlias(allocator, graph, "et_filter", target_name);
    defer allocator.free(alias);
    const replacement = try std.fmt.allocPrint(allocator, "(select * from {s} where {s} >= '{s}+00:00' and {s} < '{s}+00:00'){s}", .{ result, field.string, start, field.string, end, alias });
    allocator.free(result);
    return replacement;
}

fn subqueryAlias(allocator: std.mem.Allocator, graph: *const types.Graph, namespace: []const u8, target_name: []const u8) ![]const u8 {
    // dbt-duckdb 1.9.6 DuckDBRelation.require_alias=false; PostgreSQL inherits
    // BaseRelation.require_alias=true and its deterministic namespace alias.
    if (std.mem.eql(u8, graph.adapter_type, "duckdb")) return allocator.dupe(u8, "");
    return std.fmt.allocPrint(allocator, " _dbt_{s}_subq_{s}", .{ namespace, target_name });
}

/// Click's SAMPLE type accepts a YAML object or N hour/day/month/year(s).
/// Core reinterprets serialized input dates in UTC, even with a zone suffix.
pub fn parseSample(runtime: types.Runtime, text: []const u8) !types.SampleWindow {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidSampleWindow;
    if (trimmed[0] == '{') {
        var document = yaml.parse(runtime.allocator, trimmed) catch return error.InvalidSampleWindow;
        defer document.deinit();
        if (document.value != .object) return error.InvalidSampleWindow;
        const start = document.value.object.get("start") orelse return error.InvalidSampleWindow;
        const end = document.value.object.get("end") orelse return error.InvalidSampleWindow;
        if (start != .string or end != .string) return error.InvalidSampleWindow;
        return .{ .start = try parseDate(start.string, true), .end = try parseDate(end.string, true) };
    }
    const separator = std.mem.indexOfScalar(u8, trimmed, ' ') orelse return error.InvalidSampleWindow;
    if (std.mem.indexOfScalar(u8, trimmed[separator + 1 ..], ' ') != null) return error.InvalidSampleWindow;
    const lookback = std.fmt.parseInt(i64, trimmed[0..separator], 10) catch return error.InvalidSampleWindow;
    const lower = try runtime.allocator.dupe(u8, trimmed[separator + 1 ..]);
    defer runtime.allocator.free(lower);
    for (lower) |*character| character.* = std.ascii.toLower(character.*);
    const unit = std.mem.trimEnd(u8, lower, "s");
    const end = @divFloor(clock.now(runtime.io), 1000) * 1000;
    if (std.mem.eql(u8, unit, "hour") or std.mem.eql(u8, unit, "day")) {
        const seconds: i64 = if (std.mem.eql(u8, unit, "hour")) 3600 else 86400;
        const delta = std.math.mul(i96, lookback, @as(i96, seconds) * std.time.ns_per_s) catch return error.InvalidSampleWindow;
        return .{ .start = std.math.sub(i96, end, delta) catch return error.InvalidSampleWindow, .end = end };
    }
    if (!std.mem.eql(u8, unit, "month") and !std.mem.eql(u8, unit, "year")) return error.InvalidSampleWindow;
    const end_text = try calendar.formatTimestamp(runtime.allocator, @intCast(@divFloor(end, std.time.ns_per_s)));
    defer runtime.allocator.free(end_text);
    const year = try std.fmt.parseInt(i64, end_text[0..4], 10);
    const month = try std.fmt.parseInt(i64, end_text[5..7], 10);
    const offset = std.math.mul(i64, lookback, if (std.mem.eql(u8, unit, "year")) 12 else 1) catch return error.InvalidSampleWindow;
    const month_index = std.math.sub(i64, year * 12 + month - 1, offset) catch return error.InvalidSampleWindow;
    const target_year = @divFloor(month_index, 12);
    if (target_year < 1 or target_year > 9999) return error.InvalidSampleWindow;
    const target_month = @mod(month_index, 12) + 1;
    var day = try std.fmt.parseInt(u32, end_text[8..10], 10);
    while (day > 0) : (day -= 1) {
        const candidate = try std.fmt.allocPrint(runtime.allocator, "{d:0>4}-{d:0>2}-{d:0>2}{s}", .{ @as(u64, @intCast(target_year)), @as(u64, @intCast(target_month)), day, end_text[10..] });
        defer runtime.allocator.free(candidate);
        if (calendar.parseTimestamp(candidate)) |start| return .{ .start = @as(i96, start) * std.time.ns_per_s + @mod(end, std.time.ns_per_s), .end = end } else |_| {}
    }
    return error.InvalidSampleWindow;
}

pub fn parseDate(text: []const u8, serialized: bool) !i96 {
    // SAMPLE serialization accepts ISO fractions/zones; Click event-time dates
    // only accept YYYY-MM-DD[THH:MM:SS] or the space-separated equivalent.
    if (!serialized) {
        if (text.len != 10 and text.len != 19) return error.InvalidEventTime;
        return @as(i96, calendar.parseTimestamp(text) catch return error.InvalidEventTime) * std.time.ns_per_s;
    }
    if (text.len == 10) return @as(i96, calendar.parseTimestamp(text) catch return error.InvalidSampleWindow) * std.time.ns_per_s;
    if (text.len < 19) return error.InvalidSampleWindow;
    var cursor: usize = 19;
    var fraction: i96 = 0;
    if (cursor < text.len and text[cursor] == '.') {
        cursor += 1;
        const start = cursor;
        while (cursor < text.len and std.ascii.isDigit(text[cursor])) : (cursor += 1) {}
        if (start == cursor) return error.InvalidSampleWindow;
        const digits = @min(cursor - start, 6);
        fraction = std.fmt.parseInt(i96, text[start .. start + digits], 10) catch return error.InvalidSampleWindow;
        for (digits..9) |_| fraction *= 10;
    }
    if (cursor < text.len) {
        const suffix = text[cursor..];
        if (!std.mem.eql(u8, suffix, "Z")) {
            if (suffix.len != 6 or (suffix[0] != '+' and suffix[0] != '-') or suffix[3] != ':') return error.InvalidSampleWindow;
            const hour = std.fmt.parseUnsigned(u8, suffix[1..3], 10) catch return error.InvalidSampleWindow;
            const minute = std.fmt.parseUnsigned(u8, suffix[4..6], 10) catch return error.InvalidSampleWindow;
            if (hour > 23 or minute > 59) return error.InvalidSampleWindow;
        }
    }
    return @as(i96, calendar.parseTimestamp(text[0..19]) catch return error.InvalidSampleWindow) * std.time.ns_per_s + fraction;
}

pub fn formatSampleTimestamp(allocator: std.mem.Allocator, value: i96) ![]const u8 {
    const base = try calendar.formatTimestamp(allocator, @intCast(@divFloor(value, std.time.ns_per_s)));
    const fraction = @divFloor(@mod(value, std.time.ns_per_s), 1000);
    if (fraction == 0) return base;
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}.{d:0>6}", .{ base, @as(u32, @intCast(fraction)) });
}

test "Core input limits wrap sampling outside the empty relation and ignore unit fixtures" {
    const allocator = std.testing.allocator;
    var graph = types.Graph{ .allocator = allocator, .project_name = "example", .adapter_type = "postgres", .command_options = .{ .empty = true, .sample_window = .{ .start = try parseDate("2024-01-01", false), .end = try parseDate("2024-01-02", false) } } };
    var node = types.Node{ .package_name = "example", .unique_id = "model.example.b", .name = "b", .path = "b.sql", .original_file_path = "models/b.sql", .raw_code = "" };
    var config = try std.json.parseFromSlice(std.json.Value, allocator, "{\"event_time\":\"occurred_at\"}", .{});
    defer config.deinit();
    const result = try render(allocator, &graph, &node, config.value, "a", "\"dev\".\"a\"");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("(select * from (select * from \"dev\".\"a\" where false limit 0) _dbt_limit_subq_a where occurred_at >= '2024-01-01 00:00:00+00:00' and occurred_at < '2024-01-02 00:00:00+00:00') _dbt_et_filter_subq_a", result);
    graph.unit_fixture_relations = true;
    const fixture = try render(allocator, &graph, &node, config.value, "a", "\"dev\".\"a\"");
    defer allocator.free(fixture);
    try std.testing.expectEqualStrings("\"dev\".\"a\"", fixture);
    graph.unit_fixture_relations = false;
    graph.command_options.empty = false;
    node.runtime_batch = .{ .start = try parseDate("2024-01-01 12:00:00", false), .end = try parseDate("2024-01-03", false) };
    const batch = try render(allocator, &graph, &node, config.value, "a", "\"dev\".\"a\"");
    defer allocator.free(batch);
    try std.testing.expectEqualStrings("(select * from \"dev\".\"a\" where occurred_at >= '2024-01-01 12:00:00+00:00' and occurred_at < '2024-01-02 00:00:00+00:00') _dbt_et_filter_subq_a", batch);
}

test "Core sample date parsing preserves microseconds and relative UTC durations" {
    const allocator = std.testing.allocator;
    const runtime: types.Runtime = .{ .allocator = allocator, .io = std.testing.io };
    const parsed = try parseSample(runtime, "{start: '2024-01-01T01:02:03.123456+05:00', end: '2024-01-02T00:00:00Z'}");
    const label = try formatSampleTimestamp(allocator, parsed.start);
    defer allocator.free(label);
    try std.testing.expectEqualStrings("2024-01-01 01:02:03.123456", label);
    const relative = try parseSample(runtime, "2 DAYS");
    try std.testing.expectEqual(@as(i96, 172800) * std.time.ns_per_s, relative.end - relative.start);
    try std.testing.expectError(error.InvalidSampleWindow, parseSample(runtime, "2 weeks"));
    try std.testing.expectError(error.InvalidEventTime, parseDate("2024-01-01T00:00:00Z", false));
}
