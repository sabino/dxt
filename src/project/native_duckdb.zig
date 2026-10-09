const std = @import("std");
const result = @import("adapter_result.zig");
pub const QueryResult = result.QueryResult;
const Handle = ?*anyopaque;
const CResult = extern struct {
    column_count: u64 = 0,
    row_count: u64 = 0,
    rows_changed: u64 = 0,
    columns: Handle = null,
    error_message: Handle = null,
    internal_data: Handle = null,
};

const Api = struct {
    duckdb_open_ext: *const fn ([*:0]const u8, *Handle, Handle, *?[*:0]u8) callconv(.c) c_uint,
    duckdb_close: *const fn (*Handle) callconv(.c) void,
    duckdb_connect: *const fn (Handle, *Handle) callconv(.c) c_uint,
    duckdb_disconnect: *const fn (*Handle) callconv(.c) void,
    duckdb_create_config: *const fn (*Handle) callconv(.c) c_uint,
    duckdb_set_config: *const fn (Handle, [*:0]const u8, [*:0]const u8) callconv(.c) c_uint,
    duckdb_destroy_config: *const fn (*Handle) callconv(.c) void,
    duckdb_extract_statements: *const fn (Handle, [*:0]const u8, *Handle) callconv(.c) u64,
    duckdb_extract_statements_error: *const fn (Handle) callconv(.c) ?[*:0]const u8,
    duckdb_destroy_extracted: *const fn (*Handle) callconv(.c) void,
    duckdb_prepare_extracted_statement: *const fn (Handle, Handle, u64, *Handle) callconv(.c) c_uint,
    duckdb_prepared_statement_type: *const fn (Handle) callconv(.c) c_uint,
    duckdb_destroy_prepare: *const fn (*Handle) callconv(.c) void,
    duckdb_execute_prepared: *const fn (Handle, *CResult) callconv(.c) c_uint,
    duckdb_result_error_type: *const fn (*CResult) callconv(.c) c_uint,
    duckdb_result_return_type: *const fn (CResult) callconv(.c) c_uint,
    duckdb_destroy_result: *const fn (*CResult) callconv(.c) void,
    duckdb_column_count: *const fn (*CResult) callconv(.c) u64,
    duckdb_row_count: *const fn (*CResult) callconv(.c) u64,
    duckdb_rows_changed: *const fn (*CResult) callconv(.c) u64,
    duckdb_column_name: *const fn (*CResult, u64) callconv(.c) ?[*:0]const u8,
    duckdb_column_type: *const fn (*CResult, u64) callconv(.c) c_uint,
    duckdb_value_varchar: *const fn (*CResult, u64, u64) callconv(.c) ?[*:0]u8,
    duckdb_value_is_null: *const fn (*CResult, u64, u64) callconv(.c) bool,
    duckdb_free: *const fn (?*anyopaque) callconv(.c) void,
    duckdb_interrupt: *const fn (Handle) callconv(.c) void,
    duckdb_library_version: *const fn () callconv(.c) [*:0]const u8,
};

const Library = struct {
    dyn: std.DynLib,
    api: Api,

    fn open(path: []const u8) !Library {
        var dyn = std.DynLib.open(path) catch return error.NativeDuckDbLibraryNotFound;
        errdefer dyn.close();
        var api: Api = undefined;
        inline for (std.meta.fields(Api)) |field| {
            @field(api, field.name) = dyn.lookup(field.type, field.name ++ "\x00") orelse return error.NativeDuckDbAbiMismatch;
        }
        return .{ .dyn = dyn, .api = api };
    }
};

const Database = struct { path: []const u8, handle: Handle, readonly: bool };

/// One database instance per file; workers acquire independent connections to
/// that instance, rather than opening conflicting external writer processes.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environment: ?*const std.process.Environ.Map,
    mutex: std.Io.Mutex = .init,
    library: ?Library = null,
    attempted: bool = false,
    load_error: ?anyerror = null,
    databases: std.ArrayList(*Database) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environment: ?*const std.process.Environ.Map) Pool {
        return .{ .allocator = allocator, .io = io, .environment = environment };
    }

    pub fn deinit(self: *Pool) void {
        if (self.library) |*library| {
            for (self.databases.items) |database| {
                library.api.duckdb_close(&database.handle);
                self.allocator.free(database.path);
                self.allocator.destroy(database);
            }
            library.dyn.close();
        }
        self.databases.deinit(self.allocator);
        self.databases = .empty;
        self.library = null;
        self.attempted = false;
        self.load_error = null;
    }

    fn load(self: *Pool) anyerror!bool {
        if (self.library != null) return true;
        if (self.load_error) |err| return err;
        if (self.attempted) return false;
        self.attempted = true;
        return self.loadUncached() catch |err| {
            self.load_error = err;
            return err;
        };
    }

    fn loadUncached(self: *Pool) !bool {
        if (self.environment) |environment| {
            if (environment.get("DXT_DUCKDB_BACKEND")) |backend| {
                if (std.mem.eql(u8, backend, "cli")) return false;
                if (!std.mem.eql(u8, backend, "native") and !std.mem.eql(u8, backend, "auto")) return error.InvalidDuckDbBackend;
            }
            if (environment.get("DXT_DUCKDB_LIBRARY")) |path| {
                self.library = try Library.open(path);
                return true;
            }
        }
        for ([_][]const u8{ "libduckdb.so", "libduckdb.dylib", "duckdb.dll" }) |candidate| {
            self.library = Library.open(candidate) catch |err| switch (err) {
                error.NativeDuckDbLibraryNotFound => continue,
                else => return err,
            };
            return true;
        }
        if (self.environment) |environment| if (environment.get("DXT_DUCKDB_BACKEND")) |backend| {
            if (std.mem.eql(u8, backend, "native")) return error.NativeDuckDbLibraryNotFound;
        };
        return false;
    }

    pub fn acquire(self: *Pool, path: []const u8, readonly: bool) !?Connection {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (!try self.load()) return null;
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.UnsupportedDuckDbPath;
        const canonical_path = try self.canonicalPath(path);
        defer self.allocator.free(canonical_path);
        const api = &self.library.?.api;
        var database: ?*Database = null;
        // Fresh memory instances ensure fixtures cannot affect another unit.
        if (!std.mem.eql(u8, path, ":memory:")) {
            for (self.databases.items) |candidate| {
                if (!std.mem.eql(u8, candidate.path, canonical_path)) continue;
                if (candidate.readonly and !readonly) return error.NativeDuckDbReadOnlyConnection;
                database = candidate;
                break;
            }
        }
        if (database == null) {
            const path_z = try self.allocator.dupeZ(u8, canonical_path);
            defer self.allocator.free(path_z);
            var config: Handle = null;
            defer api.duckdb_destroy_config(&config);
            if (api.duckdb_create_config(&config) != 0) return error.NativeDuckDbConnectionFailed;
            if (readonly and api.duckdb_set_config(config, "access_mode", "READ_ONLY") != 0) return error.NativeDuckDbConnectionFailed;
            var handle: Handle = null;
            var message: ?[*:0]u8 = null;
            const status = api.duckdb_open_ext(path_z, &handle, config, &message);
            if (message) |text| api.duckdb_free(text);
            if (status != 0) return error.NativeDuckDbConnectionFailed;
            errdefer api.duckdb_close(&handle);
            const created = try self.allocator.create(Database);
            errdefer self.allocator.destroy(created);
            const owned_path = try self.allocator.dupe(u8, canonical_path);
            errdefer self.allocator.free(owned_path);
            created.* = .{ .path = owned_path, .handle = handle, .readonly = readonly };
            try self.databases.append(self.allocator, created);
            database = created;
        }
        var connection: Handle = null;
        if (api.duckdb_connect(database.?.handle, &connection) != 0) return error.NativeDuckDbConnectionFailed;
        return .{ .api = api, .handle = connection, .allocator = self.allocator, .readonly = readonly, .database_to_close = if (std.mem.eql(u8, path, ":memory:")) database else null };
    }

    fn canonicalPath(self: *Pool, path: []const u8) ![]const u8 {
        if (std.mem.eql(u8, path, ":memory:")) return try self.allocator.dupe(u8, path);
        if (std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator)) |resolved| {
            defer self.allocator.free(resolved);
            return try self.allocator.dupe(u8, resolved);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        const parent = std.fs.path.dirname(path) orelse ".";
        const resolved_parent = try std.Io.Dir.cwd().realPathFileAlloc(self.io, parent, self.allocator);
        defer self.allocator.free(resolved_parent);
        return try std.fs.path.resolve(self.allocator, &.{ resolved_parent, std.fs.path.basename(path) });
    }
};

pub const Connection = struct {
    api: *const Api,
    handle: Handle,
    allocator: std.mem.Allocator,
    readonly: bool,
    database_to_close: ?*Database = null,

    pub fn deinit(self: *Connection) void {
        self.api.duckdb_disconnect(&self.handle);
        if (self.database_to_close) |database| self.api.duckdb_close(&database.handle);
        self.database_to_close = null;
    }

    pub fn cancel(self: *Connection) void {
        self.api.duckdb_interrupt(self.handle);
    }

    pub fn version(self: *const Connection) []const u8 {
        return std.mem.span(self.api.duckdb_library_version());
    }

    pub fn query(self: *Connection, sql: []const u8) !QueryResult {
        if (self.readonly) {
            var begin_result = try self.queryStatements("begin transaction read only", false);
            begin_result.deinit(self.allocator);
        }
        defer {
            if (self.readonly) {
                var rollback_result = self.queryStatements("rollback", false) catch null;
                if (rollback_result) |*owned| owned.deinit(self.allocator);
            }
        }
        return self.queryStatements(sql, self.readonly);
    }

    fn queryStatements(self: *Connection, sql: []const u8, readonly: bool) !QueryResult {
        if (std.mem.indexOfScalar(u8, sql, 0) != null) return error.InvalidSqlText;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        var extracted: Handle = null;
        const count = self.api.duckdb_extract_statements(self.handle, sql_z, &extracted);
        defer self.api.duckdb_destroy_extracted(&extracted);
        if (self.api.duckdb_extract_statements_error(extracted) != null) return error.DuckDbExecutionFailed;
        var output: QueryResult = .{};
        errdefer output.deinit(self.allocator);
        for (0..count) |index| {
            var prepared: Handle = null;
            defer self.api.duckdb_destroy_prepare(&prepared);
            if (self.api.duckdb_prepare_extracted_statement(self.handle, extracted, index, &prepared) != 0) return error.DuckDbExecutionFailed;
            const statement_type = self.api.duckdb_prepared_statement_type(prepared);
            if (readonly and statement_type != 1 and statement_type != 4) return error.NativeDuckDbReadOnlyConnection;
            var raw: CResult = .{};
            defer self.api.duckdb_destroy_result(&raw);
            if (self.api.duckdb_execute_prepared(prepared, &raw) != 0) {
                if (self.api.duckdb_result_error_type(&raw) == 29) return error.AdapterQueryCancelled;
                return error.DuckDbExecutionFailed;
            }
            // Transaction and DDL statements also expose an empty synthetic
            // result column in the C API. Preserve the last SELECT across the
            // ROLLBACK that closes an isolated unit-test fixture transaction.
            if (self.api.duckdb_result_return_type(raw) == 3) {
                output.deinit(self.allocator);
                output = try self.copyResult(&raw);
                if (output.rows_changed == 0 and (statement_type == 2 or statement_type == 3 or statement_type == 5)) output.rows_changed = output.rows.len;
            } else {
                output.rows_changed += self.api.duckdb_rows_changed(&raw);
            }
        }
        return output;
    }

    pub fn execute(self: *Connection, sql: []const u8) !void {
        var output = try self.query(sql);
        output.deinit(self.allocator);
    }

    pub fn begin(self: *Connection) !void {
        try self.execute("begin transaction");
    }
    pub fn commit(self: *Connection) !void {
        try self.execute("commit");
    }
    pub fn rollback(self: *Connection) !void {
        try self.execute("rollback");
    }

    fn copyResult(self: *Connection, raw: *CResult) !QueryResult {
        const n_columns = self.api.duckdb_column_count(raw);
        const n_rows = self.api.duckdb_row_count(raw);
        if (n_columns > 65536 or n_rows > 10_000_000 or n_columns * n_rows > 10_000_000) return error.AdapterResultTooLarge;
        var output: QueryResult = .{ .rows_changed = self.api.duckdb_rows_changed(raw) };
        errdefer output.deinit(self.allocator);
        output.columns = try self.allocator.alloc(result.Column, n_columns);
        for (output.columns) |*column| column.* = .{ .name = "", .kind = .other };
        for (output.columns, 0..) |*column, index| {
            const type_id = self.api.duckdb_column_type(raw, index);
            column.* = .{ .name = try self.allocator.dupe(u8, std.mem.span(self.api.duckdb_column_name(raw, index).?)), .kind = duckdbKind(type_id), .native_type = type_id };
        }
        output.rows = try self.allocator.alloc([]?[]const u8, n_rows);
        for (output.rows) |*row| row.* = &.{};
        for (output.rows, 0..) |*row, r| {
            row.* = try self.allocator.alloc(?[]const u8, n_columns);
            @memset(row.*, null);
            for (row.*, 0..) |*cell, c| {
                if (self.api.duckdb_value_is_null(raw, c, r)) continue;
                const value = self.api.duckdb_value_varchar(raw, c, r) orelse return error.DuckDbExecutionFailed;
                defer self.api.duckdb_free(value);
                cell.* = try self.allocator.dupe(u8, std.mem.span(value));
            }
        }
        return output;
    }
};

pub const capabilities: result.Capabilities = .{ .savepoints = false, .catalogs = true, .merge = true, .replace_table = true, .materialized_views = false };

fn duckdbKind(type_id: u32) result.Kind {
    return switch (type_id) {
        1 => .boolean,
        2...9, 16, 32 => .integer,
        10, 11 => .floating,
        12, 20, 21, 22, 31 => .timestamp,
        13 => .date,
        14, 30 => .time,
        18 => .binary,
        19 => .decimal,
        17, 27 => .text,
        else => .other,
    };
}
