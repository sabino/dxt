const std = @import("std");
const types = @import("types.zig");
const planner = @import("metric_plan.zig");
const sem = @import("semantic.zig");
const adapter = @import("adapter.zig");
const duckdb = @import("duckdb.zig");
const fs = @import("fs.zig");
const values = @import("config_value.zig");

pub const Parsed = struct { query: planner.Query, common: []const []const u8 };
pub fn parse(allocator: std.mem.Allocator, args: []const []const u8, explain: bool, export_saved: bool) !Parsed {
    var query = planner.Query{ .explain = explain, .export_saved_query = export_saved };
    var metrics: std.ArrayList([]const u8) = .empty;
    var groups: std.ArrayList([]const u8) = .empty;
    var filters: std.ArrayList([]const u8) = .empty;
    var orders: std.ArrayList([]const u8) = .empty;
    var common: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        var inline_value: ?[]const u8 = null;
        const name = if (std.mem.indexOfScalar(u8, arg, '=')) |at| blk: {
            inline_value = arg[at + 1 ..];
            break :blk arg[0..at];
        } else arg;
        var recognized = false;
        for ([_][]const u8{ "--metrics", "--group-by", "--where", "--order-by", "--limit", "--start-time", "--end-time", "--saved-query" }) |known| if (std.mem.eql(u8, name, known)) {
            recognized = true;
            break;
        };
        if (!recognized) {
            try common.append(allocator, arg);
            if (inline_value == null) {
                i += 1;
                if (i >= args.len) return error.InvalidOption;
                try common.append(allocator, args[i]);
            }
            continue;
        }
        var raw = inline_value;
        if (raw == null) {
            i += 1;
            if (i >= args.len) return error.InvalidOption;
            raw = args[i];
        }
        const value = raw.?;
        if (value.len == 0) return error.InvalidOption;
        if (std.mem.eql(u8, name, "--metrics") or std.mem.eql(u8, name, "--group-by") or std.mem.eql(u8, name, "--order-by")) {
            const target = if (std.mem.eql(u8, name, "--metrics")) &metrics else if (std.mem.eql(u8, name, "--group-by")) &groups else &orders;
            try splitNames(allocator, target, value);
            if (inline_value == null) while (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "--")) {
                i += 1;
                try splitNames(allocator, target, args[i]);
            };
        } else if (std.mem.eql(u8, name, "--where")) try filters.append(allocator, value) else if (std.mem.eql(u8, name, "--limit")) {
            query.limit = std.fmt.parseInt(u64, value, 10) catch return error.InvalidOption;
        } else if (std.mem.eql(u8, name, "--start-time")) {
            query.start_time = value;
        } else if (std.mem.eql(u8, name, "--end-time")) {
            query.end_time = value;
        } else {
            query.saved_query = value;
        }
    }
    query.metrics = metrics.items;
    query.group_by = groups.items;
    query.where = filters.items;
    query.order_by = orders.items;
    if (query.metrics.len == 0 and query.saved_query == null) return error.InvalidMetricQuery;
    if (export_saved and query.saved_query == null) return error.MissingSavedQuery;
    return .{ .query = query, .common = common.items };
}
fn splitNames(a: std.mem.Allocator, target: *std.ArrayList([]const u8), raw: []const u8) !void {
    var tokens = std.mem.tokenizeAny(u8, raw, ", \t\r\n");
    while (tokens.next()) |name| try target.append(a, name);
}
pub fn execute(runtime: types.Runtime, graph: *const types.Graph, options: types.Options, query: planner.Query, stdout: *std.Io.Writer) !void {
    var plan = try planner.build(runtime.allocator, graph, query);
    defer plan.deinit();
    const target_dir = options.target_path orelse "target";
    const target = if (std.fs.path.isAbsolute(target_dir)) target_dir else try fs.pathJoin(runtime.allocator, &.{ options.project_dir, target_dir });
    try std.Io.Dir.cwd().createDirPath(runtime.io, target);
    const plan_path = try fs.pathJoin(runtime.allocator, &.{ target, "metric_plan.json" });
    const plan_json = try plan.json(runtime.allocator);
    defer runtime.allocator.free(plan_json);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = plan_path, .data = plan_json });
    if (query.explain) {
        try stdout.print("{s}\n", .{plan_json});
        return;
    }
    const database = try duckdb.databasePath(runtime.allocator, target, graph);
    defer runtime.allocator.free(database);
    if (query.export_saved_query) {
        const resource = sem.find(graph, "saved_query", query.saved_query.?) orelse return error.MissingSavedQuery;
        const exports = sem.list(sem.field(resource.data, "exports"));
        if (exports.len == 0) return error.MissingSavedQueryExports;
        for (exports) |exported| {
            const config = sem.field(exported, "config");
            const schema = sem.string(sem.field(config, "schema_name")) orelse graph.target_schema;
            const alias = sem.string(sem.field(config, "alias")) orelse return error.InvalidMetricQuery;
            const kind = sem.string(sem.field(config, "export_as")) orelse return error.InvalidMetricQuery;
            const qs = try adapter.quoteIdentifier(runtime.allocator, schema);
            const qi = try adapter.quoteIdentifier(runtime.allocator, alias);
            const sql = try std.fmt.allocPrint(runtime.allocator, "BEGIN; CREATE SCHEMA IF NOT EXISTS {s}; CREATE OR REPLACE {s} {s}.{s} AS {s}; COMMIT;", .{ qs, kind, qs, qi, plan.sql });
            adapter.executeForGraph(runtime, graph, database, sql) catch return error.MetricExecutionFailure;
        }
        try stdout.print("Exported {d} saved query relation(s)\n", .{exports.len});
        return;
    }
    var result = adapter.queryForGraph(runtime, graph, database, plan.sql) catch return error.MetricExecutionFailure;
    defer result.deinit(runtime.allocator);
    const result_json = try result.json(runtime.allocator);
    defer runtime.allocator.free(result_json);
    const path = try fs.pathJoin(runtime.allocator, &.{ target, "metric_results.json" });
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = path, .data = result_json });
    try stdout.print("{s}\n", .{result_json});
}
