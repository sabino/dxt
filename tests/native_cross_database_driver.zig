//! Developer facade oracle; behavior comes directly from product Zig modules.
const std = @import("std");
const cross = @import("cross");
const Request = struct { sql: []const u8, bindings: []cross.RelationBinding, options: cross.QueryOptions };

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.File.Writer.init(.stderr(), init.io, &buffer);
        writer.interface.print("error: {s}\n", .{@errorName(err)}) catch {};
        writer.interface.flush() catch {};
        std.process.exit(1);
    };
}
fn run(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.MissingDriverArguments;
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, args[3], allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(text);
    const request = try std.json.parseFromSlice(Request, allocator, text, .{});
    defer request.deinit();
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.Writer.init(.stdout(), init.io, &buffer);
    const runtime: cross.Runtime = .{ .allocator = allocator, .io = init.io, .environment = init.environ_map };
    if (std.mem.eql(u8, args[1], "plan")) {
        var plan = try cross.planQuery(runtime, args[2], request.value.options, request.value.sql, request.value.bindings);
        defer plan.deinit();
        const json = try plan.json(allocator);
        defer allocator.free(json);
        try stdout.interface.writeAll(json);
    } else {
        var plan = try cross.planQuery(runtime, args[2], request.value.options, request.value.sql, request.value.bindings);
        defer plan.deinit();
        var outcome = try cross.executeQueryPlan(runtime, &plan);
        defer outcome.deinit(allocator);
        if (std.mem.eql(u8, args[1], "export")) {
            var pool = cross.DuckDBPool.init(allocator, init.io, init.environ_map);
            defer pool.deinit();
            var export_runtime = runtime;
            export_runtime.duckdb_pool = &pool;
            const model = plan.value.models[0];
            var destination = try cross.openConnection(export_runtime, plan.root, plan.value.connections[model.destination]);
            defer destination.deinit();
            try destination.begin();
            errdefer destination.rollback() catch {};
            try cross.materializeQueryResult(export_runtime, &destination, "\"public\".\"typed_metric_export\"", &outcome, plan.value.connections[model.execution_connection].adapter_type);
            try destination.commit();
        }
        const result = try outcome.result.json(allocator);
        defer allocator.free(result);
        try stdout.interface.print("{{\"result\":{s},\"movement_plan\":{s}}}\n", .{ result, outcome.movement_plan_json });
    }
    try stdout.interface.flush();
}
