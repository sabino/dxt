//! Native, versioned capability evidence. Source-role probes use read-only
//! transactions; writable-role probes roll back their typed temporary objects.
const std = @import("std");
const cross = @import("cross_database.zig");
const run = @import("cross_database_run.zig");
const adapter = @import("adapter.zig");
const catalog = @import("cross_database_catalog.zig");
const invocation = @import("invocation.zig");

pub const Result = struct {
    connection: []const u8,
    adapter: []const u8,
    role: []const u8,
    version: ?[]const u8 = null,
    capabilities: ?adapter.Capabilities = null,
    read_only_transaction: bool = false,
    typed_temporary_table: ?bool = null,
    transactional_ddl: ?bool = null,
    binary_roundtrip: ?bool = null,
    cancellation: ?bool = null,
    status: []const u8 = "pending",
    error_name: ?[]const u8 = null,
};

pub fn execute(runtime: cross.Runtime, arena_runtime: cross.Runtime, root: []const u8, plan: *const cross.Plan, options: cross.Options, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var pool = adapter.DuckDBPool.init(runtime.allocator, runtime.io, runtime.environment);
    defer pool.deinit();
    const rt: cross.Runtime = .{ .allocator = runtime.allocator, .io = runtime.io, .environment = runtime.environment, .duckdb_pool = &pool };
    const results = try arena_runtime.allocator.alloc(Result, plan.connections.len);
    var failed = false;
    for (plan.connections, results) |connection, *result| {
        result.* = .{ .connection = connection.name, .adapter = connection.adapter_type, .role = connection.role };
        probe(rt, arena_runtime.allocator, root, connection, options.probe_cancellation, result) catch |err| {
            result.status = "error";
            result.error_name = @errorName(err);
            failed = true;
            try stderr.print("error: cross-database connection {s}: {s}\n", .{ connection.name, @errorName(err) });
        };
        try stdout.print("{s}: {s}\n", .{ connection.name, result.status });
    }
    const json = try std.json.Stringify.valueAlloc(arena_runtime.allocator, .{ .schema_version = 1, .connections = results }, .{});
    try cross.writeAtomic(arena_runtime, try cross.projectPath(arena_runtime, root, options.output orelse "target/dxt_capabilities.json"), json);
    if (failed) return error.CrossDatabaseCapabilityProbeFailed;
}

fn probe(runtime: cross.Runtime, allocator: std.mem.Allocator, root: []const u8, connection: cross.Connection, check_cancellation: bool, result: *Result) !void {
    var session = try run.open(runtime, root, connection);
    defer session.deinit();
    result.version = try catalog.version(allocator, &session);
    result.capabilities = session.capabilities();
    if (session == .duckdb) try session.execute("set threads=1");
    try session.execute("begin transaction read only");
    var transaction = true;
    defer if (transaction) session.rollback() catch {};
    var scalar = try session.query("select 1::bigint");
    defer scalar.deinit(runtime.allocator);
    if (!std.mem.eql(u8, scalar.firstScalar() orelse "", "1")) return error.CrossDatabaseCapabilityProbeMismatch;
    try session.rollback();
    transaction = false;
    result.read_only_transaction = true;
    if (!std.mem.eql(u8, connection.role, "source")) {
        var metadata = invocation.Metadata.init(runtime.io, runtime.environment);
        const name = try std.fmt.allocPrint(allocator, "__dxt_probe_{s}", .{metadata.id[0..8]});
        try session.begin();
        transaction = true;
        const create = try std.fmt.allocPrint(allocator, "create temporary table \"{s}\" (id bigint,payload {s})", .{ name, if (session == .duckdb) "blob" else "bytea" });
        try session.execute(create);
        const insert = try std.fmt.allocPrint(allocator, "insert into \"{s}\" values(9223372036854775807,{s})", .{ name, if (session == .duckdb) "from_hex('00ff275c')" else "decode('00ff275c','hex')" });
        try session.execute(insert);
        const sql = try std.fmt.allocPrint(allocator, "select id,{s} from \"{s}\"", .{ if (session == .duckdb) "hex(payload)" else "encode(payload,'hex')", name });
        var typed = try session.query(sql);
        defer typed.deinit(runtime.allocator);
        if (typed.rows.len != 1 or !std.mem.eql(u8, typed.rows[0][0] orelse "", "9223372036854775807") or !std.ascii.eqlIgnoreCase(typed.rows[0][1] orelse "", "00ff275c")) return error.CrossDatabaseCapabilityProbeMismatch;
        result.typed_temporary_table = true;
        result.binary_roundtrip = true;
        try session.rollback();
        transaction = false;
        const absence = try std.fmt.allocPrint(allocator, "select count(*) from information_schema.tables where table_name='{s}'", .{name});
        var tables = try session.query(absence);
        defer tables.deinit(runtime.allocator);
        if (!std.mem.eql(u8, tables.firstScalar() orelse "", "0")) return error.CrossDatabaseTransactionalDdlProbeFailed;
        result.transactional_ddl = true;
    }
    if (check_cancellation) {
        try session.execute("begin transaction read only");
        transaction = true;
        var timer = run.Timer.init(runtime, &session, 1);
        try timer.start();
        defer timer.deinit();
        const sql = if (session == .duckdb) "select sum(sin(i)) from range(1000000000000) t(i)" else "select pg_sleep(10)";
        session.execute(sql) catch {};
        const cancelled = timer.expired.load(.acquire);
        timer.deinit();
        try session.rollback();
        transaction = false;
        if (!cancelled) return error.CrossDatabaseCancellationProbeFailed;
        result.cancellation = true;
    }
    result.status = "success";
}
