const std = @import("std");
const result = @import("adapter_result.zig");
const parameters = @import("query_parameters.zig");
const vectors = @import("duckdb_vectors.zig");
const profile_config = @import("duckdb_profile.zig");
const config_values = @import("config_value.zig");
pub const QueryResult = result.QueryResult;
const Handle = ?*anyopaque;
const CResult = vectors.Result;
const HugeInt = vectors.HugeInt;
const Decimal = vectors.Decimal;
const Date = vectors.Date;
const Time = vectors.Time;
const Timestamp = vectors.Timestamp;

const Api = struct {
    vectors: vectors.Api,
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
    duckdb_nparams: *const fn (Handle) callconv(.c) u64,
    duckdb_bind_null: *const fn (Handle, u64) callconv(.c) c_uint,
    duckdb_bind_boolean: *const fn (Handle, u64, bool) callconv(.c) c_uint,
    duckdb_bind_int32: *const fn (Handle, u64, i32) callconv(.c) c_uint,
    duckdb_bind_int64: *const fn (Handle, u64, i64) callconv(.c) c_uint,
    duckdb_bind_uint64: *const fn (Handle, u64, u64) callconv(.c) c_uint,
    duckdb_bind_hugeint: *const fn (Handle, u64, HugeInt) callconv(.c) c_uint,
    duckdb_bind_decimal: *const fn (Handle, u64, Decimal) callconv(.c) c_uint,
    duckdb_bind_float: *const fn (Handle, u64, f32) callconv(.c) c_uint,
    duckdb_bind_double: *const fn (Handle, u64, f64) callconv(.c) c_uint,
    duckdb_bind_varchar_length: *const fn (Handle, u64, [*]const u8, u64) callconv(.c) c_uint,
    duckdb_bind_blob: *const fn (Handle, u64, ?*const anyopaque, u64) callconv(.c) c_uint,
    duckdb_bind_date: *const fn (Handle, u64, Date) callconv(.c) c_uint,
    duckdb_bind_time: *const fn (Handle, u64, Time) callconv(.c) c_uint,
    duckdb_bind_timestamp: *const fn (Handle, u64, Timestamp) callconv(.c) c_uint,
    duckdb_bind_timestamp_tz: *const fn (Handle, u64, Timestamp) callconv(.c) c_uint,
    duckdb_prepare_error: *const fn (Handle) callconv(.c) ?[*:0]const u8,
    duckdb_destroy_prepare: *const fn (*Handle) callconv(.c) void,
    duckdb_execute_prepared: *const fn (Handle, *CResult) callconv(.c) c_uint,
    duckdb_result_error_type: *const fn (*CResult) callconv(.c) c_uint,
    duckdb_result_error: *const fn (*CResult) callconv(.c) ?[*:0]const u8,
    duckdb_result_return_type: *const fn (CResult) callconv(.c) c_uint,
    duckdb_destroy_result: *const fn (*CResult) callconv(.c) void,
    duckdb_column_count: *const fn (*CResult) callconv(.c) u64,
    duckdb_rows_changed: *const fn (*CResult) callconv(.c) u64,
    duckdb_column_name: *const fn (*CResult, u64) callconv(.c) ?[*:0]const u8,
    duckdb_column_type: *const fn (*CResult, u64) callconv(.c) c_uint,
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
            if (comptime std.mem.eql(u8, field.name, "vectors")) {
                api.vectors = try vectors.Api.load(&dyn);
            } else {
                @field(api, field.name) = dyn.lookup(field.type, field.name ++ "\x00") orelse return error.NativeDuckDbAbiMismatch;
            }
        }
        return .{ .dyn = dyn, .api = api };
    }
};

fn exceptionName(error_type: u32) []const u8 {
    return switch (error_type) {
        1 => "OutOfRangeException",
        2 => "ConversionException",
        5 => "TypeMismatchException",
        8 => "InvalidTypeException",
        9 => "SerializationException",
        10 => "TransactionException",
        11 => "NotImplementedException",
        13 => "CatalogException",
        14 => "ParserException",
        18 => "ConstraintException",
        21 => "ConnectionException",
        22 => "SyntaxException",
        24 => "BinderException",
        28 => "IOException",
        29 => "InterruptException",
        30 => "FatalException",
        31 => "InternalException",
        32 => "InvalidInputException",
        33 => "OutOfMemoryException",
        34 => "PermissionException",
        37 => "DependencyException",
        38 => "HTTPException",
        41 => "SequenceException",
        else => "Error",
    };
}

fn messageErrorType(message: []const u8) u32 {
    inline for (.{
        .{ "IO Error", 28 },                 .{ "Binder Error", 24 },     .{ "Catalog Error", 13 },
        .{ "Parser Error", 14 },             .{ "Conversion Error", 2 },  .{ "Invalid Input Error", 32 },
        .{ "TransactionContext Error", 10 }, .{ "Constraint Error", 18 },
    }) |entry| if (std.mem.startsWith(u8, message, entry[0])) return entry[1];
    return 0;
}

const Database = struct {
    path: []const u8,
    handle: Handle,
    readonly: bool,
    references: usize = 0,
    profile: std.json.Value = .null,
    global_initialized: bool = false,
};

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
    last_open_error_type: u32 = 0,
    databases: std.ArrayList(*Database) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environment: ?*const std.process.Environ.Map) Pool {
        return .{ .allocator = allocator, .io = io, .environment = environment };
    }

    pub fn deinit(self: *Pool) void {
        if (self.library) |*library| {
            for (self.databases.items) |database| {
                library.api.duckdb_close(&database.handle);
                self.allocator.free(database.path);
                config_values.deinit(self.allocator, &database.profile);
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

    pub fn available(self: *Pool) !bool {
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        return try self.load();
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
        return self.acquireConfigured(path, readonly, null, false);
    }

    pub fn acquireWithProfile(self: *Pool, path: []const u8, readonly: bool, profile: std.json.Value) !?Connection {
        return self.acquireConfigured(path, readonly, profile, false);
    }

    pub fn acquireSharedMemory(self: *Pool, scope: []const u8, readonly: bool) !?Connection {
        return self.acquireConfigured(scope, readonly, null, true);
    }

    pub fn acquireSharedMemoryWithProfile(self: *Pool, scope: []const u8, readonly: bool, profile: std.json.Value) !?Connection {
        return self.acquireConfigured(scope, readonly, profile, true);
    }

    fn acquireConfigured(self: *Pool, path: []const u8, readonly: bool, requested_profile: ?std.json.Value, shared_memory: bool) !?Connection {
        if (requested_profile) |profile| try profile_config.validate(profile);
        try self.mutex.lock(self.io);
        defer self.mutex.unlock(self.io);
        if (!try self.load()) return null;
        if (std.mem.indexOfScalar(u8, path, 0) != null) return error.UnsupportedDuckDbPath;
        const canonical_path = if (shared_memory) try std.fmt.allocPrint(self.allocator, "memory:{s}", .{path}) else try self.canonicalPath(path);
        defer self.allocator.free(canonical_path);
        const api = &self.library.?.api;
        var database: ?*Database = null;
        // Fresh memory instances ensure fixtures cannot affect another unit.
        if (shared_memory or !std.mem.eql(u8, path, ":memory:")) {
            for (self.databases.items) |candidate| {
                if (!std.mem.eql(u8, candidate.path, canonical_path)) continue;
                if (requested_profile) |profile| {
                    const boot = try profile_config.digest(self.allocator, profile, false);
                    const existing_boot = try profile_config.digest(self.allocator, candidate.profile, false);
                    const global = try profile_config.digest(self.allocator, profile, true);
                    const existing_global = try profile_config.digest(self.allocator, candidate.profile, true);
                    if (!std.mem.eql(u8, &boot, &existing_boot) or !std.mem.eql(u8, &global, &existing_global)) return error.NativeDuckDbProfileConflict;
                }
                if (candidate.readonly and !readonly and !shared_memory) {
                    if (candidate.references != 0) return error.NativeDuckDbReadOnlyConnection;
                    // Compiler introspection may have opened the file before
                    // execution. Promote only after all readers disconnect.
                    api.duckdb_close(&candidate.handle);
                    candidate.global_initialized = false;
                    candidate.handle = try self.openHandle(canonical_path, false, candidate.profile);
                    candidate.readonly = false;
                }
                if (candidate.handle == null) {
                    candidate.global_initialized = false;
                    candidate.handle = try self.openHandle(if (shared_memory) ":memory:" else canonical_path, if (shared_memory) false else readonly, candidate.profile);
                }
                database = candidate;
                break;
            }
        }
        if (database == null) {
            const profile = requested_profile orelse .null;
            var handle = try self.openHandle(if (shared_memory) ":memory:" else canonical_path, if (shared_memory) false else readonly, profile);
            errdefer api.duckdb_close(&handle);
            const created = try self.allocator.create(Database);
            errdefer self.allocator.destroy(created);
            const owned_path = try self.allocator.dupe(u8, canonical_path);
            errdefer self.allocator.free(owned_path);
            var owned_profile = try config_values.clone(self.allocator, profile);
            errdefer config_values.deinit(self.allocator, &owned_profile);
            created.* = .{ .path = owned_path, .handle = handle, .readonly = if (shared_memory) false else readonly, .profile = owned_profile };
            try self.databases.append(self.allocator, created);
            database = created;
        }
        var connection: Handle = null;
        if (api.duckdb_connect(database.?.handle, &connection) != 0) return error.NativeDuckDbConnectionFailed;
        database.?.references += 1;
        var initialized = Connection{ .api = api, .handle = connection, .allocator = self.allocator, .readonly = readonly, .pool = self, .database = database.?, .memory = shared_memory or std.mem.eql(u8, path, ":memory:"), .isolated_memory = !shared_memory and std.mem.eql(u8, path, ":memory:"), .shared_memory_scope = if (shared_memory) path else null };
        errdefer {
            initialized.clearError();
            api.duckdb_disconnect(&initialized.handle);
            database.?.references -= 1;
            if (!database.?.global_initialized and database.?.references == 0) api.duckdb_close(&database.?.handle);
        }
        // Database effects are serialized under the pool lock. Cursor settings
        // are repeated for every connection, including compiler/unit readers.
        initialized.readonly = false;
        if (!database.?.global_initialized) {
            try profile_config.initializeGlobal(&initialized, database.?.profile);
            database.?.global_initialized = true;
        }
        try profile_config.initializeCursor(&initialized, requested_profile orelse database.?.profile);
        initialized.readonly = readonly;
        initialized.disable_transactions = profile_config.disableTransactions(requested_profile orelse database.?.profile);
        initialized.retry_profile = requested_profile orelse database.?.profile;
        return initialized;
    }

    fn openHandle(self: *Pool, path: []const u8, readonly: bool, profile: std.json.Value) !Handle {
        const count = profile_config.attempts(profile, true);
        for (0..count) |attempt| {
            self.last_open_error_type = 0;
            return self.openHandleOnce(path, readonly, profile) catch |err| {
                if (!profile_config.retryable(profile, exceptionName(self.last_open_error_type))) return err;
                try self.pauseRetry(attempt, null);
                if (attempt + 1 == count) return err;
                continue;
            };
        }
        return error.NativeDuckDbConnectionFailed;
    }

    fn pauseRetry(self: *Pool, attempt: usize, token: ?*const std.atomic.Value(bool)) !void {
        // Capped individual sleeps avoid overflow; repeated cancellation-safe
        // waits retain the pinned adapter's exponential retry interval.
        var seconds = std.math.shl(u64, 1, @min(attempt, 62));
        while (seconds != 0) {
            const interval = @min(seconds, 30);
            for (0..interval * 10) |_| {
                if (token) |cancelled| if (cancelled.load(.acquire)) return error.AdapterQueryCancelled;
                try std.Io.sleep(self.io, .fromMilliseconds(100), .awake);
            }
            seconds -= interval;
        }
    }

    fn openHandleOnce(self: *Pool, path: []const u8, readonly: bool, profile: std.json.Value) !Handle {
        const api = &self.library.?.api;
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);
        var config: Handle = null;
        defer api.duckdb_destroy_config(&config);
        if (api.duckdb_create_config(&config) != 0) return error.NativeDuckDbConnectionFailed;
        const options = profile_config.configuration(profile);
        if (options == .object) {
            var it = options.object.iterator();
            while (it.next()) |entry| {
                if (std.mem.indexOfScalar(u8, entry.key_ptr.*, 0) != null) return error.InvalidDuckDbConfiguration;
                const key = try self.allocator.dupeZ(u8, entry.key_ptr.*);
                defer self.allocator.free(key);
                const text = try config_values.scalarText(self.allocator, entry.value_ptr.*);
                defer self.allocator.free(text);
                if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidDuckDbConfiguration;
                const value = try self.allocator.dupeZ(u8, text);
                defer self.allocator.free(value);
                if (api.duckdb_set_config(config, key, value) != 0) return error.InvalidDuckDbConfiguration;
            }
        }
        if (readonly and !std.mem.eql(u8, path, ":memory:") and api.duckdb_set_config(config, "access_mode", "READ_ONLY") != 0) return error.NativeDuckDbConnectionFailed;
        var handle: Handle = null;
        var message: ?[*:0]u8 = null;
        const status = api.duckdb_open_ext(path_z, &handle, config, &message);
        if (message) |text| {
            self.last_open_error_type = messageErrorType(std.mem.span(text));
            api.duckdb_free(text);
        }
        if (status != 0) {
            api.duckdb_close(&handle);
            return error.NativeDuckDbConnectionFailed;
        }
        return handle;
    }

    fn release(self: *Pool, database: *Database, memory: bool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        database.references -= 1;
        if (database.references == 0 and (memory or (!std.mem.startsWith(u8, database.path, "memory:") and !profile_config.keepOpen(database.profile)))) self.library.?.api.duckdb_close(&database.handle);
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
    cursor_types: bool = false,
    cache_context: ?@import("relation_cache.zig").Context = null,
    api: *const Api,
    handle: Handle,
    allocator: std.mem.Allocator,
    readonly: bool,
    pool: *Pool,
    database: *Database,
    memory: bool,
    isolated_memory: bool = false,
    shared_memory_scope: ?[]const u8 = null,
    binding_readonly: bool = false,
    disable_transactions: bool = false,
    retry_profile: std.json.Value = .null,
    last_error_type: u32 = 0,
    // Raw SQL diagnostics remain bounded and memory-only. Retain declared
    // secret values atomically for the existing publication projector.
    last_error: ?[]const u8 = null,
    cancellation_token: ?*const std.atomic.Value(bool) = null,

    pub fn deinit(self: *Connection) void {
        if (self.cache_context) |*context| context.close();
        self.clearError();
        if (self.handle == null) return;
        self.api.duckdb_disconnect(&self.handle);
        self.pool.release(self.database, self.isolated_memory);
    }

    pub fn cancel(self: *Connection) void {
        self.api.duckdb_interrupt(self.handle);
    }

    pub fn version(self: *const Connection) []const u8 {
        return std.mem.span(self.api.duckdb_library_version());
    }

    /// Preserve native driver values only for authored held-cursor queries.
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
        return self.queryBound(sql, null);
    }

    pub fn queryParameters(self: *Connection, sql: []const u8, bindings: []const parameters.Parameter) !QueryResult {
        const nested = @import("duckdb_bindings.zig");
        if (nested.needed(bindings)) {
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();
            const expanded = try nested.expand(scratch.allocator(), sql, bindings);
            return self.queryBound(expanded.sql, expanded.bindings);
        }
        return self.queryBound(sql, bindings);
    }

    fn queryBound(self: *Connection, sql: []const u8, bindings: ?[]const parameters.Parameter) !QueryResult {
        const count = profile_config.attempts(self.retry_profile, false);
        for (0..count) |attempt| {
            return self.queryOnce(sql, bindings) catch |err| {
                if (err != error.DuckDbExecutionFailed or !profile_config.queryRetries(self.retry_profile) or !profile_config.retryable(self.retry_profile, exceptionName(self.last_error_type))) return err;
                if (self.cancellation_token) |token| if (token.load(.acquire)) return error.AdapterQueryCancelled;
                try self.pool.pauseRetry(attempt, self.cancellation_token);
                if (attempt + 1 == count) return err;
                continue;
            };
        }
        return error.DuckDbExecutionFailed;
    }

    fn queryOnce(self: *Connection, sql: []const u8, bindings: ?[]const parameters.Parameter) !QueryResult {
        if (self.cancellation_token) |token| if (token.load(.acquire)) return error.AdapterQueryCancelled;
        self.clearError();
        const cache_change = if (self.cache_context) |*context| context.before(sql) else null;
        var cache_success = false;
        defer if (cache_change) |change| if (self.cache_context) |*context| context.after(change, cache_success);
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
        const output = try self.queryStatementsBound(sql, self.readonly, bindings);
        cache_success = true;
        return output;
    }

    fn queryStatements(self: *Connection, sql: []const u8, readonly: bool) !QueryResult {
        return self.queryStatementsBound(sql, readonly, null);
    }

    fn queryStatementsBound(self: *Connection, sql: []const u8, readonly: bool, bindings: ?[]const parameters.Parameter) !QueryResult {
        if (std.mem.indexOfScalar(u8, sql, 0) != null) return error.InvalidSqlText;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        var extracted: Handle = null;
        const count = self.api.duckdb_extract_statements(self.handle, sql_z, &extracted);
        defer self.api.duckdb_destroy_extracted(&extracted);
        if (self.api.duckdb_extract_statements_error(extracted)) |message| {
            self.captureError(message);
            return error.DuckDbExecutionFailed;
        }
        var output: QueryResult = .{ .owner_allocator = self.allocator };
        errdefer output.deinit(self.allocator);
        for (0..count) |index| {
            if (self.cancellation_token) |token| if (token.load(.acquire)) return error.AdapterQueryCancelled;
            var prepared: Handle = null;
            defer self.api.duckdb_destroy_prepare(&prepared);
            if (self.api.duckdb_prepare_extracted_statement(self.handle, extracted, index, &prepared) != 0) {
                self.captureError(self.api.duckdb_prepare_error(prepared));
                return error.DuckDbExecutionFailed;
            }
            if (bindings) |values| {
                const expected = self.api.duckdb_nparams(prepared);
                if (index + 1 != count) {
                    if (expected != 0) return error.QueryParametersRequireLastStatement;
                } else {
                    if (expected != values.len) return error.QueryParameterCountMismatch;
                    for (values, 1..) |value, slot| try self.bind(prepared, slot, value);
                }
            }
            const statement_type = self.api.duckdb_prepared_statement_type(prepared);
            if (self.binding_readonly and (statement_type == 10 or statement_type == 25 or statement_type == 26)) return error.NativeDuckDbReadOnlyConnection;
            if (readonly and statement_type != 1 and statement_type != 4) return error.NativeDuckDbReadOnlyConnection;
            if (self.cancellation_token) |token| if (token.load(.acquire)) return error.AdapterQueryCancelled;
            var raw: CResult = .{};
            defer self.api.duckdb_destroy_result(&raw);
            if (self.api.duckdb_execute_prepared(prepared, &raw) != 0) {
                self.captureError(self.api.duckdb_result_error(&raw));
                self.last_error_type = self.api.duckdb_result_error_type(&raw);
                if (self.api.duckdb_result_error_type(&raw) == 29) return error.AdapterQueryCancelled;
                return error.DuckDbExecutionFailed;
            }
            // Transaction and DDL statements also expose an empty synthetic
            // result column in the C API. Preserve the last SELECT across the
            // ROLLBACK that closes an isolated unit-test fixture transaction.
            if (self.cursor_types or self.api.duckdb_result_return_type(raw) == 3) {
                output.deinit(self.allocator);
                output = try self.copyResult(&raw);
                if (output.rows_changed == 0 and (statement_type == 2 or statement_type == 3 or statement_type == 5)) output.rows_changed = output.rows.len;
            } else {
                output.rows_changed += self.api.duckdb_rows_changed(&raw);
            }
        }
        return output;
    }

    fn bind(self: *Connection, statement: Handle, slot: u64, value: parameters.Parameter) !void {
        const status = switch (value) {
            .none => self.api.duckdb_bind_null(statement, slot),
            .boolean => |v| self.api.duckdb_bind_boolean(statement, slot, v),
            .integer => |v| blk: {
                if (std.fmt.parseInt(i32, v, 10)) |integer| break :blk self.api.duckdb_bind_int32(statement, slot, integer) else |_| {}
                if (std.fmt.parseInt(i64, v, 10)) |integer| break :blk self.api.duckdb_bind_int64(statement, slot, integer) else |_| {}
                if (std.fmt.parseInt(u64, v, 10)) |integer| break :blk self.api.duckdb_bind_uint64(statement, slot, integer) else |_| {}
                // Stock Python int adaptation tries signed then unsigned
                // 64-bit storage and promotes wider inputs to DOUBLE.
                break :blk self.api.duckdb_bind_double(statement, slot, std.fmt.parseFloat(f64, v) catch return error.InvalidQueryParameter);
            },
            .decimal => |v| blk: {
                // The pinned stock Python driver stores non-finite Decimal
                // inputs as FLOAT, including its positive infinity adaptation
                // for a negative Decimal infinity.
                if (std.mem.indexOf(u8, v, "NaN") != null) break :blk self.api.duckdb_bind_float(statement, slot, std.math.nan(f32));
                if (std.mem.indexOf(u8, v, "Infinity") != null) break :blk self.api.duckdb_bind_float(statement, slot, std.math.inf(f32));
                const parsed = try parameters.decimal(self.allocator, v);
                if (parsed) |d| break :blk self.api.duckdb_bind_decimal(statement, slot, .{ .width = d.width, .scale = d.scale, .value = hugeInt(d.coefficient) });
                break :blk self.api.duckdb_bind_double(statement, slot, std.fmt.parseFloat(f64, v) catch return error.InvalidQueryParameter);
            },
            .floating => |v| self.api.duckdb_bind_double(statement, slot, v),
            .text => |v| self.api.duckdb_bind_varchar_length(statement, slot, v.ptr, v.len),
            .binary => |v| self.api.duckdb_bind_blob(statement, slot, v.ptr, v.len),
            .date => |v| self.api.duckdb_bind_date(statement, slot, .{ .days = v }),
            .time => |v| self.api.duckdb_bind_time(statement, slot, .{ .micros = v }),
            .timestamp => |v| self.api.duckdb_bind_timestamp(statement, slot, .{ .micros = v }),
            .timestamp_tz => |v| self.api.duckdb_bind_timestamp_tz(statement, slot, .{ .micros = v }),
            .time_tz, .interval, .uuid, .list, .tuple, .object, .range => return error.InvalidQueryParameter,
        };
        if (status != 0) {
            self.captureError(self.api.duckdb_prepare_error(statement));
            return error.DuckDbExecutionFailed;
        }
    }

    pub fn execute(self: *Connection, sql: []const u8) !void {
        var output = try self.query(sql);
        output.deinit(self.allocator);
    }

    pub fn begin(self: *Connection) !void {
        if (self.binding_readonly) return error.NativeDuckDbReadOnlyConnection;
        if (self.disable_transactions) return;
        try self.execute("begin transaction");
    }
    pub fn commit(self: *Connection) !void {
        if (self.binding_readonly) return error.NativeDuckDbReadOnlyConnection;
        if (self.disable_transactions) return;
        try self.execute("commit");
    }
    pub fn rollback(self: *Connection) !void {
        if (self.binding_readonly) return error.NativeDuckDbReadOnlyConnection;
        if (self.disable_transactions) return;
        try self.execute("rollback");
    }

    /// Temp views/tables remain visible across binder queries. The database
    /// enforces READ ONLY while the driver rejects transaction escapes.
    pub fn enterReadOnlySession(self: *Connection) !void {
        if (self.binding_readonly) return error.NativeDuckDbReadOnlyConnection;
        var output = try self.queryStatements("begin transaction read only", false);
        output.deinit(self.allocator);
        self.readonly = false;
        self.binding_readonly = true;
    }

    fn clearError(self: *Connection) void {
        if (self.last_error) |owned| self.allocator.free(owned);
        self.last_error = null;
        self.last_error_type = 0;
    }

    fn captureError(self: *Connection, message: ?[*:0]const u8) void {
        self.clearError();
        if (message) |text| {
            const value = std.mem.span(text);
            self.last_error_type = messageErrorType(value);
            var bounded: [64 * 1024]u8 = undefined;
            const used = @import("secret_projection.zig").writeBounded(&bounded, self.pool.environment, &.{value});
            self.last_error = self.allocator.dupe(u8, bounded[0..used]) catch null;
        }
    }

    fn copyResult(self: *Connection, raw: *CResult) anyerror!QueryResult {
        const n_columns = self.api.duckdb_column_count(raw);
        if (n_columns > 65536) return error.AdapterResultTooLarge;
        var output: QueryResult = .{ .owner_allocator = self.allocator, .rows_changed = self.api.duckdb_rows_changed(raw) };
        errdefer output.deinit(self.allocator);
        const logical_types = try self.allocator.alloc(Handle, n_columns);
        @memset(logical_types, null);
        defer self.allocator.free(logical_types);
        defer for (logical_types) |*logical| if (logical.* != null) self.api.vectors.duckdb_destroy_logical_type(logical);
        output.columns = try self.allocator.alloc(result.Column, n_columns);
        for (output.columns) |*column| column.* = .{ .name = "", .kind = .other };
        for (output.columns, 0..) |*column, index| {
            const type_id = self.api.duckdb_column_type(raw, index);
            logical_types[index] = self.api.vectors.duckdb_column_logical_type(raw, index);
            column.* = .{ .name = try self.allocator.dupe(u8, std.mem.span(self.api.duckdb_column_name(raw, index).?)), .kind = duckdbKind(type_id), .native_type = type_id };
            if (self.cursor_types) {
                column.native_type_name = try vectors.typeName(self.allocator, &self.api.vectors, logical_types[index]);
                column.native_type_description = try vectors.typeDescription(self.allocator, &self.api.vectors, logical_types[index]);
            }
        }
        var rows: std.ArrayList([]?[]const u8) = .empty;
        errdefer {
            for (rows.items) |row| {
                for (row) |cell| if (cell) |text| self.allocator.free(text);
                self.allocator.free(row);
            }
            rows.deinit(self.allocator);
        }
        var native_rows: std.ArrayList([]result.Cell) = .empty;
        errdefer {
            for (native_rows.items) |row| {
                for (row) |*cell| cell.deinit(self.allocator);
                self.allocator.free(row);
            }
            native_rows.deinit(self.allocator);
        }
        while (self.api.vectors.duckdb_fetch_chunk(raw.*)) |fetched| {
            var chunk: Handle = fetched;
            defer self.api.vectors.duckdb_destroy_data_chunk(&chunk);
            const count = self.api.vectors.duckdb_data_chunk_get_size(chunk);
            if (rows.items.len + count > 10_000_000 or n_columns * (rows.items.len + count) > 10_000_000) return error.AdapterResultTooLarge;
            for (0..count) |r| {
                const row = try self.allocator.alloc(?[]const u8, n_columns);
                @memset(row, null);
                rows.append(self.allocator, row) catch |err| {
                    self.allocator.free(row);
                    return err;
                };
                for (row, logical_types, 0..) |*cell, logical, c| cell.* = try vectors.text(self.allocator, &self.api.vectors, logical, self.api.vectors.duckdb_data_chunk_get_vector(chunk, c), r);
                if (self.cursor_types) {
                    const cells = try self.allocator.alloc(result.Cell, n_columns);
                    @memset(cells, .none);
                    native_rows.append(self.allocator, cells) catch |err| {
                        self.allocator.free(cells);
                        return err;
                    };
                    for (cells, logical_types, 0..) |*cell, logical, c| cell.* = try vectors.native(self.allocator, &self.api.vectors, logical, self.api.vectors.duckdb_data_chunk_get_vector(chunk, c), r);
                }
            }
        }
        if (self.api.duckdb_result_error(raw) != null) return error.DuckDbExecutionFailed;
        output.rows = try rows.toOwnedSlice(self.allocator);
        if (self.cursor_types) output.cursor_rows = try native_rows.toOwnedSlice(self.allocator);
        const n_rows = output.rows.len;
        // The signed microseconds were copied from the chunk. Let the held
        // connection render its actual timezone in bounded read-only batches.
        for (output.columns, 0..) |column, c| if (column.native_type == 31 and n_rows != 0) {
            var start: usize = 0;
            while (start < n_rows) {
                const end = @min(start + 1000, n_rows);
                var sql: std.Io.Writer.Allocating = .init(self.allocator);
                defer sql.deinit();
                try sql.writer.writeAll("select stamp::varchar from (values ");
                for (start..end) |r| {
                    if (r != start) try sql.writer.writeByte(',');
                    if (output.rows[r][c]) |micros| {
                        const infinite = std.mem.eql(u8, micros, "9223372036854775807") or std.mem.eql(u8, micros, "-9223372036854775807");
                        if (infinite) try sql.writer.print("({d},'{s}'::timestamptz)", .{ r, if (micros[0] == '-') "-infinity" else "infinity" }) else try sql.writer.print("({d},make_timestamptz({s}))", .{ r, micros });
                    } else try sql.writer.print("({d},null::timestamptz)", .{r});
                }
                try sql.writer.writeAll(") as timestamp_values(position,stamp) order by position");
                const previous_types = self.cursor_types;
                self.cursor_types = false;
                defer self.cursor_types = previous_types;
                var values = try self.queryStatements(sql.written(), self.readonly);
                defer values.deinit(self.allocator);
                if (values.rows.len != end - start) return error.DuckDbExecutionFailed;
                for (values.rows, start..) |row, r| if (row[0]) |value| {
                    const replacement = try self.allocator.dupe(u8, value);
                    if (output.rows[r][c]) |micros| self.allocator.free(micros);
                    output.rows[r][c] = replacement;
                };
                start = end;
            }
        };
        if (output.cursor_rows) |cells| {
            const previous_types = self.cursor_types;
            self.cursor_types = false;
            defer self.cursor_types = previous_types;
            var timezone = try self.queryStatements("select current_setting('TimeZone')", self.readonly);
            defer timezone.deinit(self.allocator);
            const name = timezone.firstScalar() orelse return error.DuckDbExecutionFailed;
            for (cells) |row| for (row) |*cell| try cell.setTimezone(self.allocator, name);
        }
        return output;
    }
};

fn hugeInt(value: i128) HugeInt {
    return .{ .lower = @truncate(@as(u128, @bitCast(value))), .upper = @intCast(value >> 64) };
}

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

test "DuckDB raw diagnostic capture bounds complete secrets before publication and remains safe under OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, diagnosticCaptureProof, .{});
}

fn diagnosticCaptureProof(allocator: std.mem.Allocator) !void {
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    const secret = "private_engine_error";
    try environment.put("DBT_ENV_SECRET_ENGINE", secret);
    var pool = Pool.init(std.testing.allocator, std.testing.io, &environment);
    defer pool.deinit();
    // Capture uses no driver calls; no native library is needed for this seam.
    var connection: Connection = .{ .api = undefined, .handle = null, .allocator = allocator, .readonly = false, .pool = &pool, .database = undefined, .memory = true };
    defer connection.clearError();
    const prefix = "Invalid Input Error: ";
    var message: [prefix.len + 100000:0]u8 = undefined;
    @memcpy(message[0..prefix.len], prefix);
    for (0..5000) |index| @memcpy(message[prefix.len + index * secret.len ..][0..secret.len], secret);
    message[message.len] = 0;
    connection.captureError(&message);
    try std.testing.expectEqual(@as(u32, 32), connection.last_error_type);
    const raw = connection.last_error orelse return error.OutOfMemory;
    const safe_length = prefix.len + (65536 - prefix.len) / secret.len * secret.len;
    try std.testing.expectEqual(@as(usize, safe_length), raw.len);
    try std.testing.expectEqualStrings(message[0..safe_length], raw);
    const published = try @import("secret_projection.zig").text(allocator, &environment, raw);
    defer allocator.free(published);
    try std.testing.expectEqual(@as(usize, prefix.len + (safe_length - prefix.len) / secret.len * 5), published.len);
    try std.testing.expect(std.mem.startsWith(u8, published, prefix));
    for (published[prefix.len..]) |byte| try std.testing.expectEqual(@as(u8, '*'), byte);
    try std.testing.expect(std.unicode.utf8ValidateSlice(published));
    for (0..5000) |index| try std.testing.expectEqualStrings(secret, message[prefix.len + index * secret.len ..][0..secret.len]);
    connection.captureError(null);
    try std.testing.expect(connection.last_error == null);
    try std.testing.expectEqual(@as(u32, 0), connection.last_error_type);
}
