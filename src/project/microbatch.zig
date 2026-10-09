//! dbt Core 1.10.5 MicrobatchBuilder calendar and configuration contract.
const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");
const inputs = @import("input_relations.zig");
const calendar = @import("workflow_intervals.zig");
const clock = @import("execution_clock.zig");

pub const BatchSize = enum { hour, day, month, year };
pub const Config = struct {
    event_time: []const u8,
    begin: i96,
    batch_size: BatchSize,
    lookback: i64 = 1,
    concurrent_batches: ?bool = null,
};

pub fn enabled(node: *const types.Node) bool {
    return std.mem.eql(u8, node.materialized, "incremental") and std.mem.eql(u8, node.incremental.strategy orelse "", "microbatch");
}

pub fn configuration(node: *const types.Node) !Config {
    const raw = node.effective_config;
    const event_time = values.get(raw, "event_time") orelse return error.MissingMicrobatchEventTime;
    if (event_time != .string) return error.InvalidMicrobatchEventTime;
    const begin = values.get(raw, "begin") orelse return error.MissingMicrobatchBegin;
    if (begin != .string) return error.InvalidMicrobatchBegin;
    const batch_size = values.get(raw, "batch_size") orelse return error.MissingMicrobatchBatchSize;
    if (batch_size != .string) return error.InvalidMicrobatchBatchSize;
    var config = Config{
        .event_time = event_time.string,
        .begin = inputs.parseDate(begin.string, true) catch return error.InvalidMicrobatchBegin,
        .batch_size = std.meta.stringToEnum(BatchSize, batch_size.string) orelse return error.InvalidMicrobatchBatchSize,
    };
    if (values.get(raw, "lookback")) |lookback| {
        if (lookback != .integer) return error.InvalidMicrobatchLookback;
        config.lookback = lookback.integer;
    }
    if (values.get(raw, "concurrent_batches")) |concurrent| {
        if (concurrent != .null) {
            if (concurrent != .bool) return error.InvalidMicrobatchConcurrency;
            config.concurrent_batches = concurrent.bool;
        }
    }
    return config;
}

/// Preserve authored unrendered config while exposing Core's parsed defaults
/// and datetime serialization to manifest consumers and macro contexts.
pub fn normalizeConfig(a: std.mem.Allocator, node: *types.Node) !void {
    const parsed = try configuration(node);
    const begin = values.get(node.effective_config, "begin").?.string;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const timestamp = try @import("timestamp_context.zig").configuredValue(arena.allocator(), parsed.begin, begin);
    const normalized = (try @import("timestamp_context.zig").call(arena.allocator(), timestamp.attribute("isoformat").callable, &.{})).?.string;
    try values.put(a, &node.effective_config, "begin", .{ .string = normalized });
    if (values.get(node.effective_config, "lookback") == null) try values.put(a, &node.effective_config, "lookback", .{ .integer = 1 });
    if (values.get(node.effective_config, "concurrent_batches") == null) try values.put(a, &node.effective_config, "concurrent_batches", .null);
}

pub fn truncate(allocator: std.mem.Allocator, value: i96, size: BatchSize) !i96 {
    if (size == .hour or size == .day) {
        const duration = @as(i96, if (size == .hour) @as(i64, 3600) else 86400) * std.time.ns_per_s;
        return @divFloor(value, duration) * duration;
    }
    const label = try calendar.formatTimestamp(allocator, @intCast(@divFloor(value, std.time.ns_per_s)));
    defer allocator.free(label);
    const boundary = try std.fmt.allocPrint(allocator, "{s}-{s}-01", .{ label[0..4], if (size == .year) "01" else label[5..7] });
    defer allocator.free(boundary);
    return inputs.parseDate(boundary, false);
}

pub fn offset(allocator: std.mem.Allocator, value: i96, size: BatchSize, count: i64) !i96 {
    const floor = try truncate(allocator, value, size);
    if (size == .hour or size == .day) {
        const duration = @as(i96, if (size == .hour) @as(i64, 3600) else 86400) * std.time.ns_per_s;
        return std.math.add(i96, floor, std.math.mul(i96, count, duration) catch return error.InvalidMicrobatchRange) catch return error.InvalidMicrobatchRange;
    }
    const label = try calendar.formatTimestamp(allocator, @intCast(@divFloor(floor, std.time.ns_per_s)));
    defer allocator.free(label);
    const year = try std.fmt.parseInt(i64, label[0..4], 10);
    const month = try std.fmt.parseInt(i64, label[5..7], 10);
    const units = std.math.mul(i64, count, if (size == .year) @as(i64, 12) else 1) catch return error.InvalidMicrobatchRange;
    const index = std.math.add(i64, year * 12 + month - 1, units) catch return error.InvalidMicrobatchRange;
    const target_year = @divFloor(index, 12);
    if (target_year < 1 or target_year > 9999) return error.InvalidMicrobatchRange;
    const boundary = try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-01", .{ @as(u64, @intCast(target_year)), @as(u64, @intCast(@mod(index, 12) + 1)) });
    defer allocator.free(boundary);
    return inputs.parseDate(boundary, false);
}

pub fn batches(runtime: types.Runtime, graph: *const types.Graph, config: Config, is_incremental: bool) ![]types.SampleWindow {
    const options = graph.command_options;
    const default_end = if (runtime.invocation) |invocation| try inputs.parseDate(&invocation.started_at, true) else clock.now(runtime.io);
    const raw_end = if (options.sample_window) |sample| sample.end else if (options.event_time_end) |end| try inputs.parseDate(end, false) else default_end;
    const end_floor = try truncate(runtime.allocator, raw_end, config.batch_size);
    const end = if (raw_end == end_floor) raw_end else try offset(runtime.allocator, raw_end, config.batch_size, 1);
    const start = if (options.sample_window) |sample| try truncate(runtime.allocator, sample.start, config.batch_size) else if (options.event_time_start) |begin| try truncate(runtime.allocator, try inputs.parseDate(begin, false), config.batch_size) else if (!is_incremental) try truncate(runtime.allocator, config.begin, config.batch_size) else blk: {
        // Core passes the end timestamp as checkpoint. An exact ceiling adds one
        // lookback batch, including the most recently closed batch.
        const lookback = std.math.add(i64, config.lookback, 1) catch return error.InvalidMicrobatchRange;
        break :blk try offset(runtime.allocator, end, config.batch_size, std.math.negate(lookback) catch return error.InvalidMicrobatchRange);
    };
    var result: std.ArrayList(types.SampleWindow) = .empty;
    errdefer result.deinit(runtime.allocator);
    var current = start;
    var next = try offset(runtime.allocator, current, config.batch_size, 1);
    try result.append(runtime.allocator, .{ .start = current, .end = next });
    while (next < end) {
        current = next;
        next = try offset(runtime.allocator, current, config.batch_size, 1);
        try result.append(runtime.allocator, .{ .start = current, .end = next });
    }
    result.items[result.items.len - 1].end = end;
    return result.toOwnedSlice(runtime.allocator);
}

pub fn batchLabel(allocator: std.mem.Allocator, start: i96, size: BatchSize) ![]const u8 {
    const timestamp = try inputs.formatSampleTimestamp(allocator, start);
    defer allocator.free(timestamp);
    const length: usize = switch (size) {
        .hour => 13,
        .day => 10,
        .month => 7,
        .year => 4,
    };
    const label = try allocator.dupe(u8, timestamp[0..length]);
    if (size == .hour) label[10] = 'T';
    return label;
}

pub fn batchId(allocator: std.mem.Allocator, start: i96, size: BatchSize) ![]const u8 {
    const label = try batchLabel(allocator, start, size);
    defer allocator.free(label);
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (label) |character| if (character != '-') try result.append(allocator, character);
    return result.toOwnedSlice(allocator);
}

test "Core microbatch calendar ceiling and repeated lookback preserve actual batch boundaries" {
    const a = std.testing.allocator;
    const runtime = types.Runtime{ .allocator = a, .io = std.testing.io };
    var graph = types.Graph{ .allocator = a, .project_name = "example", .command_options = .{ .event_time_end = "2024-03-01 12:34:56" } };
    const config = Config{ .event_time = "event_time", .begin = try inputs.parseDate("2024-02-28", false), .batch_size = .day };
    const first = try batches(runtime, &graph, config, false);
    defer a.free(first);
    try std.testing.expectEqual(@as(usize, 3), first.len);
    try std.testing.expectEqual(try inputs.parseDate("2024-03-02", false), first[2].end);
    const repeated = try batches(runtime, &graph, config, true);
    defer a.free(repeated);
    try std.testing.expectEqual(@as(usize, 2), repeated.len);
    try std.testing.expectEqual(try inputs.parseDate("2024-02-29", false), repeated[0].start);
    try std.testing.expectEqual(try inputs.parseDate("2024-03-01", false), try offset(a, try inputs.parseDate("2024-02-29 16:00:00", false), .month, 1));
    const id = try batchId(a, try inputs.parseDate("2024-02-29 16:00:00", false), .hour);
    defer a.free(id);
    try std.testing.expectEqualStrings("20240229T16", id);
}
