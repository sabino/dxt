//! Process-owned target locks: the kernel releases them after cancellation or
//! crashes. Files remain stable to avoid unlink/recreate lock races.
const std = @import("std");
const cross = @import("cross_database.zig");
const adapter = @import("adapter.zig");

pub const Lock = struct {
    file: std.Io.File,
    io: std.Io,
    pub fn deinit(self: *Lock) void {
        self.file.close(self.io);
        self.* = undefined;
    }
};

pub fn acquire(runtime: cross.Runtime, root: []const u8, connection: cross.Connection, schema: []const u8, name: []const u8) !Lock {
    const allocator = runtime.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const local: cross.Runtime = .{ .allocator = arena.allocator(), .io = runtime.io };
    const physical = if (connection.identity.database_path) |path| if (!std.mem.eql(u8, path, ":memory:")) try cross.projectPath(local, connection.identity.database_path_base orelse root, path) else root else root;
    const directory = if (connection.identity.database_path != null and !std.mem.eql(u8, physical, root)) try std.fmt.allocPrint(local.allocator, "{s}.dxt-locks", .{physical}) else try std.fs.path.join(local.allocator, &.{ root, ".dxt", "locks" });
    try std.Io.Dir.cwd().createDirPath(runtime.io, directory);
    const key = try std.fmt.allocPrint(local.allocator, "{s}.{s}", .{ schema, name });
    const hash = try cross.digest(local.allocator, key);
    const path = try std.fs.path.join(local.allocator, &.{ directory, hash });
    const file = std.Io.Dir.cwd().createFile(runtime.io, path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| return if (err == error.WouldBlock) error.CrossDatabaseTargetLocked else err;
    return .{ .file = file, .io = runtime.io };
}

pub fn acquireDatabase(allocator: std.mem.Allocator, destination: *adapter.Session, schema: []const u8, name: []const u8) !void {
    if (destination.* != .postgres) return;
    const target = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ schema, name });
    defer allocator.free(target);
    const literal = try adapter.quoteLiteral(allocator, target);
    defer allocator.free(literal);
    const sql = try std.fmt.allocPrint(allocator, "select pg_try_advisory_xact_lock(hashtextextended(current_database() || {s},0))", .{literal});
    defer allocator.free(sql);
    var result = try destination.query(sql);
    defer result.deinit(allocator);
    if (!std.mem.eql(u8, result.firstScalar() orelse "", "t")) return error.CrossDatabaseTargetLocked;
}
