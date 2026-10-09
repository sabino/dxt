//! Bounded native source batches. PostgreSQL cursors and DuckDB C results avoid
//! accumulating copied rows in the caller's invocation arena.
const std = @import("std");
const adapter = @import("adapter.zig");
const Handle = ?*anyopaque;
const RawDuckResult = extern struct { column_count: u64 = 0, row_count: u64 = 0, rows_changed: u64 = 0, columns: Handle = null, error_message: Handle = null, internal_data: Handle = null };
const DuckString = extern struct { first: u64, second: u64 };

pub const Column = struct { name: []const u8, kind: adapter.Kind, type_sql: []const u8 };
pub const Guard = struct {
    max_rows: u64,
    max_bytes: u64,
    max_memory_bytes: u64,
    rows: u64 = 0,
    bytes: u64 = 0,
    fn account(self: *Guard, bytes: u64) !void {
        self.bytes +|= bytes;
        if (self.bytes > self.max_bytes) return error.CrossDatabaseByteBudgetExceeded;
    }
};

pub const Reader = struct {
    allocator: std.mem.Allocator,
    session: *adapter.Session,
    columns: []Column = &.{},
    guard: Guard,
    duck_result: RawDuckResult = .{},
    duck_active: bool = false,
    duck_index: usize = 0,
    duck_chunk: Handle = null,
    pg_guarded: bool = false,
    transaction: bool = false,
    finished: bool = false,

    pub fn open(allocator: std.mem.Allocator, session: *adapter.Session, query: []const u8, guard: Guard, seconds: u64) !Reader {
        var self: Reader = .{ .allocator = allocator, .session = session, .guard = guard };
        errdefer self.deinit();
        switch (session.*) {
            .postgres => {
                try session.execute("begin transaction isolation level repeatable read read only");
                self.transaction = true;
                const settings = try std.fmt.allocPrint(allocator, "set local statement_timeout = '{d}ms'; set local timezone = 'UTC'", .{seconds * 1000});
                defer allocator.free(settings);
                try session.execute(settings);
                const declaration = try std.fmt.allocPrint(allocator, "declare __dxt_extract no scroll cursor for {s}", .{query});
                defer allocator.free(declaration);
                try session.execute(declaration);
                _ = try self.pgFetch(false);
                try session.execute("close __dxt_extract");
                const guarded = try boundedTextQuery(allocator, query, self.columns.len, guard, false);
                defer allocator.free(guarded);
                const guarded_declaration = try std.fmt.allocPrint(allocator, "declare __dxt_extract no scroll cursor for {s}", .{guarded});
                defer allocator.free(guarded_declaration);
                try session.execute(guarded_declaration);
                self.pg_guarded = true;
            },
            .duckdb => |*connection| {
                try session.execute("begin transaction read only");
                self.transaction = true;
                const bounded = try std.fmt.allocPrint(allocator, "select * from ({s}) as __dxt_extract limit {d}", .{ query, guard.max_rows +| 1 });
                defer allocator.free(bounded);
                const sql_z = try allocator.dupeZ(u8, bounded);
                defer allocator.free(sql_z);
                var extracted: Handle = null;
                const count = connection.api.duckdb_extract_statements(connection.handle, sql_z, &extracted);
                defer connection.api.duckdb_destroy_extracted(&extracted);
                if (count != 1 or connection.api.duckdb_extract_statements_error(extracted) != null) return error.InvalidCrossDatabaseQuery;
                var prepared: Handle = null;
                defer connection.api.duckdb_destroy_prepare(&prepared);
                if (connection.api.duckdb_prepare_extracted_statement(connection.handle, extracted, 0, &prepared) != 0) return error.DuckDbExecutionFailed;
                if (connection.api.duckdb_prepared_statement_type(prepared) != 1) return error.InvalidCrossDatabaseQuery;
                const countColumns = connection.pool.library.?.dyn.lookup(*const fn (Handle) callconv(.c) u64, "duckdb_prepared_statement_column_count") orelse return error.NativeDuckDbAbiMismatch;
                const columnName = connection.pool.library.?.dyn.lookup(*const fn (Handle, u64) callconv(.c) ?[*:0]u8, "duckdb_prepared_statement_column_name") orelse return error.NativeDuckDbAbiMismatch;
                const count_columns: usize = @intCast(countColumns(prepared));
                self.columns = try allocator.alloc(Column, count_columns);
                for (self.columns) |*column| column.* = .{ .name = "", .kind = .other, .type_sql = "" };
                const logicalType = connection.pool.library.?.dyn.lookup(*const fn (Handle, u64) callconv(.c) Handle, "duckdb_prepared_statement_column_logical_type") orelse return error.NativeDuckDbAbiMismatch;
                const typeId = connection.pool.library.?.dyn.lookup(*const fn (Handle) callconv(.c) c_uint, "duckdb_get_type_id") orelse return error.NativeDuckDbAbiMismatch;
                const decimalWidth = connection.pool.library.?.dyn.lookup(*const fn (Handle) callconv(.c) u8, "duckdb_decimal_width") orelse return error.NativeDuckDbAbiMismatch;
                const decimalScale = connection.pool.library.?.dyn.lookup(*const fn (Handle) callconv(.c) u8, "duckdb_decimal_scale") orelse return error.NativeDuckDbAbiMismatch;
                const destroyType = connection.pool.library.?.dyn.lookup(*const fn (*Handle) callconv(.c) void, "duckdb_destroy_logical_type") orelse return error.NativeDuckDbAbiMismatch;
                const getAlias = connection.pool.library.?.dyn.lookup(*const fn (Handle) callconv(.c) ?[*:0]u8, "duckdb_logical_type_get_alias") orelse return error.NativeDuckDbAbiMismatch;
                for (self.columns, 0..) |*column, index| {
                    var logical = logicalType(prepared, index);
                    defer destroyType(&logical);
                    const id = typeId(logical);
                    const alias = getAlias(logical);
                    defer if (alias) |value| connection.api.duckdb_free(value);
                    const mapped = if (id == 17 and alias != null and std.ascii.eqlIgnoreCase(std.mem.span(alias.?), "json")) try mappedType(allocator, .text, "json") else try duckType(allocator, id, if (id == 19) decimalWidth(logical) else 0, if (id == 19) decimalScale(logical) else 0);
                    const raw_name = columnName(prepared, index) orelse return error.NativeDuckDbAbiMismatch;
                    defer connection.api.duckdb_free(raw_name);
                    column.* = .{ .name = try allocator.dupe(u8, std.mem.span(raw_name)), .kind = mapped.kind, .type_sql = mapped.sql };
                }
                const guarded = try boundedTextQuery(allocator, query, self.columns.len, guard, true);
                defer allocator.free(guarded);
                const guarded_z = try allocator.dupeZ(u8, guarded);
                defer allocator.free(guarded_z);
                var stream_prepared: Handle = null;
                defer connection.api.duckdb_destroy_prepare(&stream_prepared);
                const prepare = connection.pool.library.?.dyn.lookup(*const fn (Handle, [*:0]const u8, *Handle) callconv(.c) c_uint, "duckdb_prepare") orelse return error.NativeDuckDbAbiMismatch;
                if (prepare(connection.handle, guarded_z, &stream_prepared) != 0) return error.DuckDbExecutionFailed;
                const executeStreaming = connection.pool.library.?.dyn.lookup(*const fn (Handle, *RawDuckResult) callconv(.c) c_uint, "duckdb_execute_prepared_streaming") orelse return error.NativeDuckDbAbiMismatch;
                self.duck_active = true;
                if (executeStreaming(stream_prepared, &self.duck_result) != 0) return self.duckError();
            },
        }
        return self;
    }

    pub fn deinit(self: *Reader) void {
        if (self.duck_active) {
            if (self.duck_chunk != null) {
                const destroy = self.session.duckdb.pool.library.?.dyn.lookup(*const fn (*Handle) callconv(.c) void, "duckdb_destroy_data_chunk").?;
                destroy(&self.duck_chunk);
            }
            self.session.duckdb.api.duckdb_destroy_result(@ptrCast(&self.duck_result));
            self.duck_active = false;
        }
        if (self.transaction) self.session.rollback() catch {};
        for (self.columns) |column| {
            if (column.name.len != 0) self.allocator.free(column.name);
            if (column.type_sql.len != 0) self.allocator.free(column.type_sql);
        }
        self.allocator.free(self.columns);
        self.columns = &.{};
        self.transaction = false;
    }

    pub fn next(self: *Reader) !?adapter.QueryResult {
        if (self.finished) return null;
        return switch (self.session.*) {
            .postgres => try self.pgFetch(true),
            .duckdb => try self.duckFetch(),
        };
    }

    fn freshResult(self: *Reader, rows: usize) !adapter.QueryResult {
        const overhead = (@as(u64, @intCast(rows)) * @as(u64, @intCast(self.columns.len)) * @sizeOf(?[]const u8)) + self.columns.len * @sizeOf(adapter.Column);
        if (overhead > self.guard.max_memory_bytes / 8) return error.CrossDatabaseMemoryBudgetExceeded;
        var output: adapter.QueryResult = .{ .owner_allocator = self.allocator };
        errdefer output.deinit(self.allocator);
        output.columns = try self.allocator.alloc(adapter.Column, self.columns.len);
        for (output.columns) |*column| column.* = .{ .name = "", .kind = .other };
        for (output.columns, self.columns) |*column, source| column.* = .{ .name = try self.allocator.dupe(u8, source.name), .kind = source.kind, .native_type = if (std.mem.eql(u8, source.type_sql, "timestamp_ns")) 22 else if (std.mem.eql(u8, source.type_sql, "time_ns")) 39 else 0 };
        output.rows = try self.allocator.alloc([]?[]const u8, rows);
        for (output.rows) |*row| row.* = &.{};
        return output;
    }

    fn duckFetch(self: *Reader) !?adapter.QueryResult {
        const connection = &self.session.duckdb;
        const dyn = &connection.pool.library.?.dyn;
        const fetch = dyn.lookup(*const fn (RawDuckResult) callconv(.c) Handle, "duckdb_fetch_chunk") orelse return error.NativeDuckDbAbiMismatch;
        const size = dyn.lookup(*const fn (Handle) callconv(.c) u64, "duckdb_data_chunk_get_size") orelse return error.NativeDuckDbAbiMismatch;
        const destroy = dyn.lookup(*const fn (*Handle) callconv(.c) void, "duckdb_destroy_data_chunk") orelse return error.NativeDuckDbAbiMismatch;
        const getVector = dyn.lookup(*const fn (Handle, u64) callconv(.c) Handle, "duckdb_data_chunk_get_vector") orelse return error.NativeDuckDbAbiMismatch;
        const getData = dyn.lookup(*const fn (Handle) callconv(.c) ?[*]DuckString, "duckdb_vector_get_data") orelse return error.NativeDuckDbAbiMismatch;
        const getValidity = dyn.lookup(*const fn (Handle) callconv(.c) ?[*]u64, "duckdb_vector_get_validity") orelse return error.NativeDuckDbAbiMismatch;
        const stringData = dyn.lookup(*const fn (*DuckString) callconv(.c) [*]const u8, "duckdb_string_t_data") orelse return error.NativeDuckDbAbiMismatch;
        if (self.duck_chunk == null or self.duck_index == size(self.duck_chunk)) {
            if (self.duck_chunk != null) destroy(&self.duck_chunk);
            self.duck_chunk = fetch(self.duck_result);
            self.duck_index = 0;
            if (self.duck_chunk == null) {
                if (connection.api.duckdb_result_error(@ptrCast(&self.duck_result)) != null) return self.duckError();
                self.finished = true;
                return null;
            }
        }
        const total: usize = @intCast(size(self.duck_chunk));
        const count = @min(128, total - self.duck_index);
        self.guard.rows +|= count;
        if (self.guard.rows > self.guard.max_rows) {
            connection.cancel();
            return error.CrossDatabaseRowBudgetExceeded;
        }
        var output = try self.freshResult(count);
        errdefer output.deinit(self.allocator);
        var batch_bytes: u64 = 0;
        for (output.rows, 0..) |*row, index| {
            const r = self.duck_index + index;
            const size_vector = getVector(self.duck_chunk, self.columns.len);
            var size_string = getData(size_vector).?[r];
            const size_length = std.mem.bytesToValue(u32, std.mem.asBytes(&size_string)[0..4]);
            const row_bytes = try std.fmt.parseUnsigned(u64, stringData(&size_string)[0..size_length], 10);
            if (row_bytes > rowLimit(self.guard, true)) {
                try self.guard.account(row_bytes);
                connection.cancel();
                return error.CrossDatabaseMemoryBudgetExceeded;
            }
            row.* = try self.allocator.alloc(?[]const u8, self.columns.len);
            @memset(row.*, null);
            for (row.*, 0..) |*cell, column| {
                const vector = getVector(self.duck_chunk, column);
                if (getValidity(vector)) |validity| if ((validity[r / 64] & (@as(u64, 1) << @intCast(r % 64))) == 0) continue;
                var string = getData(vector).?[r];
                const length = std.mem.bytesToValue(u32, std.mem.asBytes(&string)[0..4]);
                const text = stringData(&string)[0..length];
                self.guard.account(text.len) catch |err| {
                    connection.cancel();
                    return err;
                };
                batch_bytes += text.len;
                if (batch_bytes > self.guard.max_memory_bytes / 4) {
                    connection.cancel();
                    return error.CrossDatabaseMemoryBudgetExceeded;
                }
                cell.* = try self.allocator.dupe(u8, text);
            }
        }
        self.duck_index += count;
        return output;
    }

    fn pgFetch(self: *Reader, copy_rows: bool) !?adapter.QueryResult {
        const connection = &self.session.postgres;
        const query: [*:0]const u8 = if (copy_rows) "fetch forward 16 from __dxt_extract" else "fetch forward 0 from __dxt_extract";
        if (connection.api.PQsendQuery(connection.handle, query) != 1) return error.PostgresExecutionFailed;
        var output: ?adapter.QueryResult = null;
        errdefer if (output) |*result| result.deinit(self.allocator);
        var failed: ?anyerror = null;
        while (connection.api.PQgetResult(connection.handle)) |raw| {
            defer connection.api.PQclear(raw);
            if (connection.api.PQresultStatus(raw) != 2) {
                failed = error.PostgresExecutionFailed;
                continue;
            }
            const count_columns: usize = @intCast(connection.api.PQnfields(raw));
            const count_rows: usize = @intCast(connection.api.PQntuples(raw));
            if (!copy_rows) {
                self.columns = try self.allocator.alloc(Column, count_columns);
                for (self.columns) |*column| column.* = .{ .name = "", .kind = .other, .type_sql = "" };
                const modifier = connection.library.lookup(*const fn (Handle, c_int) callconv(.c) c_int, "PQfmod") orelse return error.NativePostgresAbiMismatch;
                for (self.columns, 0..) |*column, index| {
                    const mapped = pgType(self.allocator, connection.api.PQftype(raw, @intCast(index)), modifier(raw, @intCast(index))) catch |err| {
                        failed = err;
                        break;
                    };
                    column.* = .{ .name = try self.allocator.dupe(u8, std.mem.span(connection.api.PQfname(raw, @intCast(index)))), .kind = mapped.kind, .type_sql = mapped.sql };
                }
                continue;
            }
            if (count_rows == 0) {
                self.finished = true;
                continue;
            }
            self.guard.rows +|= count_rows;
            if (self.guard.rows > self.guard.max_rows) {
                failed = error.CrossDatabaseRowBudgetExceeded;
                continue;
            }
            output = try self.freshResult(count_rows);
            var batch_bytes: u64 = 0;
            for (output.?.rows, 0..) |*row, index| {
                if (!self.pg_guarded or count_columns != self.columns.len + 1) {
                    failed = error.NativePostgresAbiMismatch;
                    break;
                }
                const size_length: usize = @intCast(connection.api.PQgetlength(raw, @intCast(index), @intCast(self.columns.len)));
                const row_bytes = try std.fmt.parseUnsigned(u64, connection.api.PQgetvalue(raw, @intCast(index), @intCast(self.columns.len))[0..size_length], 10);
                if (row_bytes > rowLimit(self.guard, false)) {
                    self.guard.account(row_bytes) catch |err| {
                        failed = err;
                        break;
                    };
                    failed = error.CrossDatabaseMemoryBudgetExceeded;
                    break;
                }
                row.* = try self.allocator.alloc(?[]const u8, self.columns.len);
                @memset(row.*, null);
                for (row.*, 0..) |*cell, column| {
                    if (connection.api.PQgetisnull(raw, @intCast(index), @intCast(column)) != 0) continue;
                    const length: usize = @intCast(connection.api.PQgetlength(raw, @intCast(index), @intCast(column)));
                    self.guard.account(length) catch |err| {
                        failed = err;
                        break;
                    };
                    batch_bytes += length;
                    if (batch_bytes > self.guard.max_memory_bytes / 4) {
                        failed = error.CrossDatabaseMemoryBudgetExceeded;
                        break;
                    }
                    cell.* = try self.allocator.dupe(u8, connection.api.PQgetvalue(raw, @intCast(index), @intCast(column))[0..length]);
                }
                if (failed != null) break;
            }
        }
        if (failed) |err| {
            try self.session.cancel();
            return err;
        }
        return output;
    }

    fn duckError(self: *Reader) anyerror {
        const connection = &self.session.duckdb;
        const message = connection.api.duckdb_result_error(@ptrCast(&self.duck_result));
        if (message) |raw| if (std.mem.indexOf(u8, std.mem.span(raw), "max_temp_directory_size") != null) return error.CrossDatabaseSpillBudgetExceeded;
        return switch (connection.api.duckdb_result_error_type(@ptrCast(&self.duck_result))) {
            29 => error.CrossDatabaseTimeBudgetExceeded,
            33 => error.CrossDatabaseMemoryBudgetExceeded,
            else => error.DuckDbExecutionFailed,
        };
    }
};

fn rowLimit(guard: Guard, duck: bool) u64 {
    // Reserve space for the engine's native vector/cursor batch, owned copies,
    // UTF-8 escaping and INSERT construction before any payload reaches Zig.
    return @min(guard.max_memory_bytes / (if (duck) @as(u64, 2048 * 8) else 16 * 8), guard.max_bytes);
}

fn boundedTextQuery(allocator: std.mem.Allocator, query: []const u8, columns: usize, guard: Guard, duck: bool) ![]const u8 {
    if (columns == 0 or columns * (2048 * 16) > guard.max_memory_bytes / 4) return error.CrossDatabaseMemoryBudgetExceeded;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.writeAll("with __dxt_text as materialized (select ");
    for (0..columns) |c| {
        if (c != 0) try out.writer.writeByte(',');
        try out.writer.print("cast(c{d} as {s}) as c{d}", .{ c, if (duck) "varchar" else "text", c });
    }
    try out.writer.print(" from ({s}) __dxt_row (", .{query});
    for (0..columns) |c| {
        if (c != 0) try out.writer.writeByte(',');
        try out.writer.print("c{d}", .{c});
    }
    try out.writer.print(") limit {d}), __dxt_payload as (select *, ", .{guard.max_rows +| 1});
    for (0..columns) |c| {
        if (c != 0) try out.writer.writeByte('+');
        if (duck) try out.writer.print("octet_length(encode(coalesce(c{d},'')))", .{c}) else try out.writer.print("octet_length(coalesce(c{d},''))::bigint", .{c});
    }
    try out.writer.writeAll(" as __dxt_size from __dxt_text) select ");
    for (0..columns) |c| {
        if (c != 0) try out.writer.writeByte(',');
        try out.writer.print("case when __dxt_size>{d} then null else c{d} end as c{d}", .{ rowLimit(guard, duck), c, c });
    }
    try out.writer.print(",cast(__dxt_size as {s}) from __dxt_payload", .{if (duck) "varchar" else "text"});
    return out.toOwnedSlice();
}

const Mapped = struct { kind: adapter.Kind, sql: []const u8 };
fn mappedType(allocator: std.mem.Allocator, kind: adapter.Kind, sql: []const u8) !Mapped {
    return .{ .kind = kind, .sql = try allocator.dupe(u8, sql) };
}
fn decimal(allocator: std.mem.Allocator, width: usize, scale: usize) !Mapped {
    if (width == 0 or width > 38 or scale > width) return error.UnsupportedCrossDatabaseType;
    return .{ .kind = .decimal, .sql = try std.fmt.allocPrint(allocator, "decimal({d},{d})", .{ width, scale }) };
}
fn duckType(allocator: std.mem.Allocator, id: c_uint, width: u8, scale: u8) !Mapped {
    return switch (id) {
        1 => mappedType(allocator, .boolean, "boolean"),
        2, 3, 4, 5 => mappedType(allocator, .integer, "bigint"),
        6, 7, 8 => mappedType(allocator, .integer, "bigint"),
        9 => decimal(allocator, 20, 0),
        16 => mappedType(allocator, .integer, "hugeint"),
        32 => mappedType(allocator, .integer, "uhugeint"),
        10 => mappedType(allocator, .floating, "real"),
        11 => mappedType(allocator, .floating, "double precision"),
        12, 20, 21 => mappedType(allocator, .timestamp, "timestamp"),
        22 => mappedType(allocator, .timestamp, "timestamp_ns"),
        39 => mappedType(allocator, .time, "time_ns"),
        13 => mappedType(allocator, .date, "date"),
        14 => mappedType(allocator, .time, "time"),
        17 => mappedType(allocator, .text, "text"),
        27 => mappedType(allocator, .text, "uuid"),
        18 => mappedType(allocator, .binary, "blob"),
        19 => decimal(allocator, width, scale),
        30 => mappedType(allocator, .time, "time with time zone"),
        31 => mappedType(allocator, .timestamp, "timestamp with time zone"),
        else => error.UnsupportedCrossDatabaseType,
    };
}
fn pgType(allocator: std.mem.Allocator, id: u32, modifier: c_int) !Mapped {
    return switch (id) {
        16 => mappedType(allocator, .boolean, "boolean"),
        20, 21, 23, 26 => mappedType(allocator, .integer, "bigint"),
        700 => mappedType(allocator, .floating, "real"),
        701 => mappedType(allocator, .floating, "double precision"),
        1700 => if (modifier >= 4) decimal(allocator, @intCast((modifier - 4) >> 16), @intCast((modifier - 4) & 0x7ff)) else mappedType(allocator, .decimal, "numeric"),
        1082 => mappedType(allocator, .date, "date"),
        1083 => mappedType(allocator, .time, "time"),
        1266 => mappedType(allocator, .time, "time with time zone"),
        1114 => mappedType(allocator, .timestamp, "timestamp"),
        1184 => mappedType(allocator, .timestamp, "timestamp with time zone"),
        17 => mappedType(allocator, .binary, "blob"),
        2950 => mappedType(allocator, .text, "uuid"),
        114, 3802 => mappedType(allocator, .text, "json"),
        18, 19, 25, 1042, 1043 => mappedType(allocator, .text, "text"),
        else => error.UnsupportedCrossDatabaseType,
    };
}

test "cross native type declarations retain exact decimal and time semantics" {
    const allocator = std.testing.allocator;
    const numeric = try pgType(allocator, 1700, 4 + (20 << 16) + 4);
    defer allocator.free(numeric.sql);
    try std.testing.expectEqualStrings("decimal(20,4)", numeric.sql);
    const timezone = try duckType(allocator, 31, 0, 0);
    defer allocator.free(timezone.sql);
    try std.testing.expectEqualStrings("timestamp with time zone", timezone.sql);
    const unbounded = try pgType(allocator, 1700, -1);
    defer allocator.free(unbounded.sql);
    try std.testing.expectEqualStrings("numeric", unbounded.sql);
    try std.testing.expectError(error.UnsupportedCrossDatabaseType, pgType(allocator, 1700, 4 + (50 << 16)));
    try std.testing.expectError(error.UnsupportedCrossDatabaseType, duckType(allocator, 24, 0, 0));
}

test "cross byte guard records observed overrun and suppresses native oversized payloads" {
    var guard: Guard = .{ .max_rows = 5, .max_bytes = 10, .max_memory_bytes = 1048576 };
    try guard.account(8);
    try std.testing.expectError(error.CrossDatabaseByteBudgetExceeded, guard.account(5));
    try std.testing.expectEqual(@as(u64, 13), guard.bytes);
    const sql = try boundedTextQuery(std.testing.allocator, "select id from customer", 1, guard, false);
    defer std.testing.allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "limit 6") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "case when __dxt_size>10 then null") != null);
}
