const std = @import("std");
const Io = std.Io;

const dxt = @import("dxt");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), init.io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    var pool = dxt.DuckDBPool.init(arena, init.io, init.environ_map);
    const invocation = dxt.Invocation.init(init.io, init.environ_map);
    var pool_live = true;
    defer if (pool_live) pool.deinit();
    const code = try dxt.run(args, stdout, stderr, .{
        .allocator = arena,
        .io = init.io,
        .environment = init.environ_map,
        .invocation = &invocation,
        .duckdb_pool = &pool,
    });
    try stdout.flush();
    try stderr.flush();
    pool.deinit();
    pool_live = false;
    std.process.exit(@intFromEnum(code));
}
