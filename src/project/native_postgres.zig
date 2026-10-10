const std = @import("std");
const result = @import("adapter_result.zig");
const parameters = @import("query_parameters.zig");
pub const QueryResult = result.QueryResult;
const Handle = ?*anyopaque;
const NoticeProcessor = *const fn (Handle, [*:0]const u8) callconv(.c) void;
const Api = struct {
    PQconnectdb: *const fn ([*:0]const u8) callconv(.c) Handle,
    PQstatus: *const fn (Handle) callconv(.c) c_int,
    PQsetNoticeProcessor: *const fn (Handle, NoticeProcessor, Handle) callconv(.c) NoticeProcessor,
    PQfinish: *const fn (Handle) callconv(.c) void,
    PQsendQuery: *const fn (Handle, [*:0]const u8) callconv(.c) c_int,
    PQsendQueryParams: *const fn (Handle, [*:0]const u8, c_int, ?[*]const u32, ?[*]const ?[*:0]const u8, ?[*]const c_int, ?[*]const c_int, c_int) callconv(.c) c_int,
    PQescapeLiteral: *const fn (Handle, [*]const u8, usize) callconv(.c) ?[*:0]u8,
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
    PQfmod: *const fn (Handle, c_int) callconv(.c) c_int,
    PQfsize: *const fn (Handle, c_int) callconv(.c) c_int,
    PQgetisnull: *const fn (Handle, c_int, c_int) callconv(.c) c_int,
    PQgetvalue: *const fn (Handle, c_int, c_int) callconv(.c) [*:0]const u8,
    PQgetlength: *const fn (Handle, c_int, c_int) callconv(.c) c_int,
    PQcmdTuples: *const fn (Handle) callconv(.c) [*:0]const u8,
    PQcmdStatus: *const fn (Handle) callconv(.c) [*:0]const u8,
    PQresultErrorField: *const fn (Handle, c_int) callconv(.c) ?[*:0]const u8,
    PQserverVersion: *const fn (Handle) callconv(.c) c_int,
    PQtransactionStatus: *const fn (Handle) callconv(.c) c_int,
    PQgetCancel: *const fn (Handle) callconv(.c) Handle,
    PQcancel: *const fn (Handle, [*]u8, c_int) callconv(.c) c_int,
    PQfreeCancel: *const fn (Handle) callconv(.c) void,
};

pub const Connection = struct {
    cursor_types: bool = false,
    cache_context: ?@import("relation_cache.zig").Context = null,
    cancellation_token: ?*const std.atomic.Value(bool) = null,
    allocator: std.mem.Allocator,
    library: std.DynLib,
    api: Api,
    handle: Handle,
    cancellation: Handle,
    last_error: ?[]const u8 = null,
    last_error_position: ?usize = null,

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
        if (self.cache_context) |*context| context.close();
        self.clearError();
        self.api.PQfreeCancel(self.cancellation);
        self.api.PQfinish(self.handle);
        self.library.close();
        self.handle = null;
    }

    pub fn queryTyped(self: *Connection, sql: []const u8) !QueryResult {
        const previous = self.cursor_types;
        self.cursor_types = true;
        defer self.cursor_types = previous;
        return self.query(sql);
    }

    pub fn queryParametersTyped(self: *Connection, sql: []const u8, bindings: []const parameters.Parameter) !QueryResult {
        const previous = self.cursor_types;
        self.cursor_types = true;
        defer self.cursor_types = previous;
        return self.queryParameters(sql, bindings);
    }

    pub fn query(self: *Connection, sql: []const u8) !QueryResult {
        if (self.cancellation_token) |token| if (token.load(.acquire)) return error.AdapterQueryCancelled;
        self.clearError();
        const cache_change = if (self.cache_context) |*context| context.before(sql) else null;
        defer if (cache_change) |change| if (self.cache_context) |*context| context.afterTransaction(change, self.api.PQtransactionStatus(self.handle) != 0);
        if (std.mem.indexOfScalar(u8, sql, 0) != null) return error.InvalidSqlText;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (self.api.PQsendQuery(self.handle, sql_z) == 0) return error.PostgresExecutionFailed;
        return self.drainResults();
    }

    pub fn queryParameters(self: *Connection, sql: []const u8, bindings: []const parameters.Parameter) !QueryResult {
        if (self.cancellation_token) |token| if (token.load(.acquire)) return error.AdapterQueryCancelled;
        self.clearError();
        const cache_change = if (self.cache_context) |*context| context.before(sql) else null;
        defer if (cache_change) |change| if (self.cache_context) |*context| context.afterTransaction(change, self.api.PQtransactionStatus(self.handle) != 0);
        if (std.mem.indexOfScalar(u8, sql, 0) != null) return error.InvalidSqlText;
        // psycopg2 adapts values client-side and accepts multi-statement SQL
        // and batches beyond libpq's 16-bit extended-protocol parameter limit.
        if (bindings.len > 65535 or parameters.needsClientAdaptation(sql)) return self.queryAdapted(sql, bindings);
        // Unknown NULL/text literals keep psycopg2's context-dependent type.
        // An unspecified extended-protocol parameter is not equivalent in
        // polymorphic expressions such as pg_typeof(NULL).
        for (bindings) |binding| if (binding == .none or binding == .text or binding.recursive() or binding == .uuid or (binding == .decimal and std.mem.indexOf(u8, binding.decimal, "Infinity") != null)) return self.queryAdapted(sql, bindings);
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const translated = try parameters.postgresSql(a, sql, bindings.len);
        const sql_z = try a.dupeZ(u8, translated);
        const values = try a.alloc(?[*:0]const u8, bindings.len);
        const types = try a.alloc(u32, bindings.len);
        for (bindings, values, types) |binding, *value, *type_id| {
            value.* = if (try binding.postgresText(a)) |text| text.ptr else null;
            type_id.* = binding.postgresType();
        }
        if (self.api.PQsendQueryParams(self.handle, sql_z, @intCast(bindings.len), types.ptr, values.ptr, null, null, 0) == 0) return error.PostgresExecutionFailed;
        return self.drainResults();
    }

    fn queryAdapted(self: *Connection, sql: []const u8, bindings: []const parameters.Parameter) !QueryResult {
        var scratch = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        const literals = try a.alloc([]const u8, bindings.len);
        for (bindings, literals) |binding, *literal| literal.* = try @import("postgres_parameters.zig").literal(a, binding, self, quoteParameter);
        const adapted = try parameters.postgresAdaptedSql(a, sql, literals);
        return self.query(adapted);
    }

    fn quoteParameter(a: std.mem.Allocator, context: ?*anyopaque, text: []const u8) anyerror![]const u8 {
        const self: *Connection = @ptrCast(@alignCast(context orelse return error.InvalidQueryParameter));
        if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidQueryParameter;
        const quoted = self.api.PQescapeLiteral(self.handle, text.ptr, text.len) orelse return error.InvalidQueryParameter;
        defer self.api.PQfreemem(quoted);
        return a.dupe(u8, std.mem.span(quoted));
    }

    fn drainResults(self: *Connection) !QueryResult {
        var output: QueryResult = .{ .owner_allocator = self.allocator };
        errdefer output.deinit(self.allocator);
        var failed: ?anyerror = null;
        // Drain the protocol even on an error, so rollback and subsequent
        // queries remain possible on the same connection.
        while (self.api.PQgetResult(self.handle)) |raw| {
            defer self.api.PQclear(raw);
            switch (self.api.PQresultStatus(raw)) {
                1 => {
                    output.deinit(self.allocator);
                    output = .{ .owner_allocator = self.allocator, .rows_changed = std.fmt.parseUnsigned(u64, std.mem.span(self.api.PQcmdTuples(raw)), 10) catch 0, .command_tag = try self.allocator.dupe(u8, std.mem.span(self.api.PQcmdStatus(raw))) };
                },
                2 => {
                    output.deinit(self.allocator);
                    output = self.copyResult(raw) catch |err| {
                        failed = err;
                        continue;
                    };
                    output.rows_changed = std.fmt.parseUnsigned(u64, std.mem.span(self.api.PQcmdTuples(raw)), 10) catch 0;
                    output.command_tag = try self.allocator.dupe(u8, std.mem.span(self.api.PQcmdStatus(raw)));
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
                    if (self.last_error == null) if (self.api.PQresultErrorField(raw, 'M')) |message| {
                        const raw_message = std.mem.span(message);
                        self.last_error = self.allocator.dupe(u8, raw_message[0..@min(raw_message.len, 64 * 1024)]) catch null;
                    };
                    if (self.api.PQresultErrorField(raw, 'P')) |position| self.last_error_position = std.fmt.parseUnsigned(usize, std.mem.span(position), 10) catch null;
                    const state = self.api.PQresultErrorField(raw, 'C');
                    if (failed == null) failed = classifySqlState(if (state) |code| std.mem.span(code) else null);
                },
            }
        }
        if (failed) |err| return err;
        return output;
    }

    fn clearError(self: *Connection) void {
        if (self.last_error) |message| self.allocator.free(message);
        self.last_error = null;
        self.last_error_position = null;
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
            column.* = .{ .name = try self.allocator.dupe(u8, std.mem.span(self.api.PQfname(raw, @intCast(index)))), .kind = postgresKind(type_id), .native_type = type_id, .native_type_modifier = self.api.PQfmod(raw, @intCast(index)), .native_type_size = self.api.PQfsize(raw, @intCast(index)) };
        }
        if (self.cursor_types) {
            output.cursor_rows = try self.allocator.alloc([]result.Cell, n_rows);
            for (output.cursor_rows.?) |*row| row.* = &.{};
            for (output.cursor_rows.?) |*row| {
                row.* = try self.allocator.alloc(result.Cell, n_columns);
                @memset(row.*, .none);
            }
        }
        output.rows = try self.allocator.alloc([]?[]const u8, n_rows);
        for (output.rows) |*row| row.* = &.{};
        for (output.rows, 0..) |*row, r| {
            row.* = try self.allocator.alloc(?[]const u8, n_columns);
            @memset(row.*, null);
            for (row.*, 0..) |*cell, c| {
                if (self.api.PQgetisnull(raw, @intCast(r), @intCast(c)) != 0) continue;
                const length: usize = @intCast(self.api.PQgetlength(raw, @intCast(r), @intCast(c)));
                const text = self.api.PQgetvalue(raw, @intCast(r), @intCast(c))[0..length];
                cell.* = try self.allocator.dupe(u8, text);
                if (output.cursor_rows) |rows| rows[r][c] = try @import("postgres_cursor.zig").cell(self.allocator, output.columns[c].native_type, text);
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

/// Only server-confirmed SQLSTATEs are eligible for caller retry policy.
/// Disconnects and uncertain commits retain the generic execution error.
pub fn classifySqlState(state: ?[]const u8) anyerror {
    const code = state orelse return error.PostgresExecutionFailed;
    if (std.mem.eql(u8, code, "57014")) return error.AdapterQueryCancelled;
    if (std.mem.eql(u8, code, "40001")) return error.PostgresSerializationFailure;
    if (std.mem.eql(u8, code, "40P01")) return error.PostgresDeadlockDetected;
    if (std.mem.eql(u8, code, "55P03")) return error.PostgresLockNotAvailable;
    return error.PostgresExecutionFailed;
}

test "SQLSTATE retry classification requires a known server rejection" {
    try std.testing.expectEqual(error.PostgresSerializationFailure, classifySqlState("40001"));
    try std.testing.expectEqual(error.PostgresDeadlockDetected, classifySqlState("40P01"));
    try std.testing.expectEqual(error.PostgresLockNotAvailable, classifySqlState("55P03"));
    try std.testing.expectEqual(error.AdapterQueryCancelled, classifySqlState("57014"));
    try std.testing.expectEqual(error.PostgresExecutionFailed, classifySqlState("08006"));
    try std.testing.expectEqual(error.PostgresExecutionFailed, classifySqlState(null));
}
