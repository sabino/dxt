const std = @import("std");
const result = @import("adapter_result.zig");
pub const QueryResult = result.QueryResult;
const Handle = ?*anyopaque;
const NoticeProcessor = *const fn (Handle, [*:0]const u8) callconv(.c) void;
const Api = struct {
    PQconnectdb: *const fn ([*:0]const u8) callconv(.c) Handle,
    PQstatus: *const fn (Handle) callconv(.c) c_int,
    PQsetNoticeProcessor: *const fn (Handle, NoticeProcessor, Handle) callconv(.c) NoticeProcessor,
    PQfinish: *const fn (Handle) callconv(.c) void,
    PQsendQuery: *const fn (Handle, [*:0]const u8) callconv(.c) c_int,
    PQgetResult: *const fn (Handle) callconv(.c) Handle,
    PQputCopyEnd: *const fn (Handle, [*:0]const u8) callconv(.c) c_int,
    PQgetCopyData: *const fn (Handle, *?[*]u8, c_int) callconv(.c) c_int,
    PQfreemem: *const fn (?*anyopaque) callconv(.c) void,
    PQresultStatus: *const fn (Handle) callconv(.c) c_int,
    PQclear: *const fn (Handle) callconv(.c) void,
    PQntuples: *const fn (Handle) callconv(.c) c_int,
    PQnfields: *const fn (Handle) callconv(.c) c_int,
    PQfname: *const fn (Handle, c_int) callconv(.c) [*:0]const u8,
    PQftype: *const fn (Handle, c_int) callconv(.c) u32,
    PQgetisnull: *const fn (Handle, c_int, c_int) callconv(.c) c_int,
    PQgetvalue: *const fn (Handle, c_int, c_int) callconv(.c) [*:0]const u8,
    PQgetlength: *const fn (Handle, c_int, c_int) callconv(.c) c_int,
    PQcmdTuples: *const fn (Handle) callconv(.c) [*:0]const u8,
    PQresultErrorField: *const fn (Handle, c_int) callconv(.c) ?[*:0]const u8,
    PQserverVersion: *const fn (Handle) callconv(.c) c_int,
    PQgetCancel: *const fn (Handle) callconv(.c) Handle,
    PQcancel: *const fn (Handle, [*]u8, c_int) callconv(.c) c_int,
    PQfreeCancel: *const fn (Handle) callconv(.c) void,
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    library: std.DynLib,
    api: Api,
    handle: Handle,
    cancellation: Handle,

    /// conninfo stays in memory; server diagnostic text is never published.
    pub fn open(allocator: std.mem.Allocator, conninfo: []const u8, library_path: ?[]const u8) !Connection {
        if (std.mem.indexOfScalar(u8, conninfo, 0) != null) return error.InvalidPostgresConnection;
        var library = std.DynLib.open(library_path orelse "libpq.so.5") catch return error.NativePostgresLibraryNotFound;
        errdefer library.close();
        var api: Api = undefined;
        inline for (std.meta.fields(Api)) |field| {
            @field(api, field.name) = library.lookup(field.type, field.name ++ "\x00") orelse return error.NativePostgresAbiMismatch;
        }
        const conninfo_z = try allocator.dupeZ(u8, conninfo);
        defer allocator.free(conninfo_z);
        const handle = api.PQconnectdb(conninfo_z);
        if (handle == null) return error.PostgresConnectionFailed;
        errdefer api.PQfinish(handle);
        if (api.PQstatus(handle) != 0) return error.PostgresConnectionFailed;
        _ = api.PQsetNoticeProcessor(handle, ignoreNotice, null);
        const cancellation = api.PQgetCancel(handle) orelse return error.PostgresCancellationFailed;
        return .{ .allocator = allocator, .library = library, .api = api, .handle = handle, .cancellation = cancellation };
    }

    pub fn deinit(self: *Connection) void {
        self.api.PQfreeCancel(self.cancellation);
        self.api.PQfinish(self.handle);
        self.library.close();
        self.handle = null;
    }

    pub fn query(self: *Connection, sql: []const u8) !QueryResult {
        if (std.mem.indexOfScalar(u8, sql, 0) != null) return error.InvalidSqlText;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (self.api.PQsendQuery(self.handle, sql_z) == 0) return error.PostgresExecutionFailed;
        var output: QueryResult = .{ .owner_allocator = self.allocator };
        errdefer output.deinit(self.allocator);
        var failed: ?anyerror = null;
        // Drain the protocol even on an error, so rollback and subsequent
        // queries remain possible on the same connection.
        while (self.api.PQgetResult(self.handle)) |raw| {
            defer self.api.PQclear(raw);
            switch (self.api.PQresultStatus(raw)) {
                1 => output.rows_changed = std.fmt.parseUnsigned(u64, std.mem.span(self.api.PQcmdTuples(raw)), 10) catch 0,
                2 => {
                    output.deinit(self.allocator);
                    output = self.copyResult(raw) catch |err| {
                        failed = err;
                        continue;
                    };
                    output.rows_changed = std.fmt.parseUnsigned(u64, std.mem.span(self.api.PQcmdTuples(raw)), 10) catch 0;
                },
                3 => {
                    // COPY streams require a dedicated protocol API. Consume
                    // output before failing so this connection can recover.
                    failed = error.UnsupportedCopyStreaming;
                    while (true) {
                        var buffer: ?[*]u8 = null;
                        const length = self.api.PQgetCopyData(self.handle, &buffer, 0);
                        if (buffer) |data| self.api.PQfreemem(data);
                        if (length < 0) break;
                    }
                },
                4 => {
                    failed = error.UnsupportedCopyStreaming;
                    if (self.api.PQputCopyEnd(self.handle, "COPY streaming requires a dedicated adapter operation") != 1) return error.PostgresExecutionFailed;
                },
                else => {
                    const state = self.api.PQresultErrorField(raw, 'C');
                    if (failed == null) failed = if (state != null and std.mem.eql(u8, std.mem.span(state.?), "57014")) error.AdapterQueryCancelled else error.PostgresExecutionFailed;
                },
            }
        }
        if (failed) |err| return err;
        return output;
    }

    pub fn execute(self: *Connection, sql: []const u8) !void {
        var output = try self.query(sql);
        output.deinit(self.allocator);
    }
    pub fn begin(self: *Connection) !void {
        try self.execute("begin");
    }
    pub fn commit(self: *Connection) !void {
        try self.execute("commit");
    }
    pub fn rollback(self: *Connection) !void {
        try self.execute("rollback");
    }

    pub fn cancel(self: *Connection) !void {
        var buffer: [256]u8 = undefined;
        if (self.api.PQcancel(self.cancellation, &buffer, buffer.len) != 1) return error.PostgresCancellationFailed;
    }

    pub fn capabilities(self: *const Connection) result.Capabilities {
        return .{ .savepoints = true, .catalogs = false, .merge = self.api.PQserverVersion(self.handle) >= 150000, .replace_table = false, .materialized_views = true };
    }

    fn copyResult(self: *Connection, raw: Handle) !QueryResult {
        const n_columns: usize = @intCast(self.api.PQnfields(raw));
        const n_rows: usize = @intCast(self.api.PQntuples(raw));
        if (n_columns > 65536 or n_rows > 10_000_000 or n_columns * n_rows > 10_000_000) return error.AdapterResultTooLarge;
        var output: QueryResult = .{ .owner_allocator = self.allocator };
        errdefer output.deinit(self.allocator);
        output.columns = try self.allocator.alloc(result.Column, n_columns);
        for (output.columns) |*column| column.* = .{ .name = "", .kind = .other };
        for (output.columns, 0..) |*column, index| {
            const type_id = self.api.PQftype(raw, @intCast(index));
            column.* = .{ .name = try self.allocator.dupe(u8, std.mem.span(self.api.PQfname(raw, @intCast(index)))), .kind = postgresKind(type_id), .native_type = type_id };
        }
        output.rows = try self.allocator.alloc([]?[]const u8, n_rows);
        for (output.rows) |*row| row.* = &.{};
        for (output.rows, 0..) |*row, r| {
            row.* = try self.allocator.alloc(?[]const u8, n_columns);
            @memset(row.*, null);
            for (row.*, 0..) |*cell, c| {
                if (self.api.PQgetisnull(raw, @intCast(r), @intCast(c)) != 0) continue;
                const length: usize = @intCast(self.api.PQgetlength(raw, @intCast(r), @intCast(c)));
                cell.* = try self.allocator.dupe(u8, self.api.PQgetvalue(raw, @intCast(r), @intCast(c))[0..length]);
            }
        }
        return output;
    }
};

fn ignoreNotice(_: Handle, _: [*:0]const u8) callconv(.c) void {}

fn postgresKind(type_id: u32) result.Kind {
    return switch (type_id) {
        16 => .boolean,
        20, 21, 23, 26 => .integer,
        700, 701 => .floating,
        1700 => .decimal,
        1082 => .date,
        1083, 1266 => .time,
        1114, 1184 => .timestamp,
        17 => .binary,
        18, 19, 25, 1042, 1043, 2950, 114, 3802 => .text,
        else => .other,
    };
}
