const std = @import("std");
const types = @import("types.zig");
const results = @import("adapter_result.zig");
pub const DuckDBPool = @import("native_duckdb.zig").Pool;
pub const DuckDBConnection = @import("native_duckdb.zig").Connection;
pub const PostgresConnection = @import("native_postgres.zig").Connection;
pub const QueryResult = results.QueryResult;
pub const Parameter = @import("query_parameters.zig").Parameter;
pub const RelationCache = @import("relation_cache.zig").Cache;
pub const warmRelationsCache = @import("relation_cache.zig").warmSession;
pub const Column = results.Column;
pub const Kind = results.Kind;
pub const Capabilities = results.Capabilities;
pub const quoteIdentifier = results.quoteIdentifier;
pub const quoteLiteral = results.quoteLiteral;
pub const Runtime = types.Runtime;
pub const Graph = types.Graph;
pub const profile = @import("profile.zig");
pub const ProjectConfig = types.ProjectConfig;
pub const OperationHost = @import("commands.zig").OperationHost;

pub const Session = union(enum) {
    duckdb: DuckDBConnection,
    postgres: PostgresConnection,

    pub fn cacheContext(self: *Session) ?*@import("relation_cache.zig").Context {
        return switch (self.*) {
            inline else => |*connection| if (connection.cache_context) |*context| context else null,
        };
    }

    pub fn setCancellationToken(self: *Session, token: *const std.atomic.Value(bool)) void {
        switch (self.*) {
            inline else => |*connection| connection.cancellation_token = token,
        }
    }
    pub fn deinit(self: *Session) void {
        switch (self.*) {
            inline else => |*connection| connection.deinit(),
        }
    }
    pub fn queryTyped(self: *Session, sql: []const u8) !QueryResult {
        return switch (self.*) {
            inline else => |*connection| try connection.queryTyped(sql),
        };
    }
    pub fn queryParametersTyped(self: *Session, sql: []const u8, bindings: []const Parameter) !QueryResult {
        return switch (self.*) {
            inline else => |*connection| try connection.queryParametersTyped(sql, bindings),
        };
    }
    pub fn query(self: *Session, sql: []const u8) !QueryResult {
        return switch (self.*) {
            inline else => |*connection| try connection.query(sql),
        };
    }
    pub fn queryParameters(self: *Session, sql: []const u8, bindings: []const Parameter) !QueryResult {
        return switch (self.*) {
            inline else => |*connection| try connection.queryParameters(sql, bindings),
        };
    }
    pub fn execute(self: *Session, sql: []const u8) !void {
        switch (self.*) {
            inline else => |*connection| try connection.execute(sql),
        }
    }
    pub fn beginReadOnly(self: *Session) !void {
        switch (self.*) {
            .duckdb => |*connection| try connection.enterReadOnlySession(),
            .postgres => |*connection| try connection.execute("begin transaction read only"),
        }
    }
    pub fn begin(self: *Session) !void {
        switch (self.*) {
            inline else => |*connection| try connection.begin(),
        }
    }
    pub fn commit(self: *Session) !void {
        switch (self.*) {
            inline else => |*connection| try connection.commit(),
        }
    }
    pub fn rollback(self: *Session) !void {
        switch (self.*) {
            inline else => |*connection| try connection.rollback(),
        }
    }
    pub fn cancel(self: *Session) !void {
        switch (self.*) {
            .duckdb => |*connection| connection.cancel(),
            .postgres => |*connection| try connection.cancel(),
        }
    }
    pub fn lastError(self: *const Session) ?[]const u8 {
        return switch (self.*) {
            .duckdb => |*connection| connection.last_error,
            .postgres => |*connection| connection.last_error,
        };
    }
    pub fn capabilities(self: *const Session) Capabilities {
        return switch (self.*) {
            .duckdb => @import("native_duckdb.zig").capabilities,
            .postgres => |*connection| connection.capabilities(),
        };
    }
    pub fn columns(self: *Session, allocator: std.mem.Allocator, schema: []const u8, relation: []const u8) !QueryResult {
        return self.columnsInDatabase(allocator, null, schema, relation);
    }
    pub fn columnsInDatabase(self: *Session, allocator: std.mem.Allocator, database: ?[]const u8, schema: []const u8, relation: []const u8) !QueryResult {
        const context = self.cacheContext();
        if (context) |cache| if (cache.usable()) if (try cache.cache.getColumns(allocator, &cache.scope, database, schema, relation)) |cached_columns| return cached_columns;
        const generation = if (context) |cache| cache.cache.epoch() else 0;
        const schema_literal = try quoteLiteral(allocator, schema);
        defer allocator.free(schema_literal);
        const relation_literal = try quoteLiteral(allocator, relation);
        defer allocator.free(relation_literal);
        const database_expression = if (database) |name| try quoteLiteral(allocator, name) else try allocator.dupe(u8, "current_database()");
        defer allocator.free(database_expression);
        const sql = switch (self.*) {
            .duckdb => try std.fmt.allocPrint(allocator, "select column_name, data_type, is_nullable, ordinal_position from information_schema.columns where table_catalog = {s} and table_schema = {s} and table_name = {s} order by ordinal_position", .{ database_expression, schema_literal, relation_literal }),
            .postgres => try std.fmt.allocPrint(allocator, "select a.attname as column_name, pg_catalog.format_type(a.atttypid, a.atttypmod) as data_type, case when a.attnotnull then 'NO' else 'YES' end as is_nullable, a.attnum as ordinal_position from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace join pg_catalog.pg_attribute a on a.attrelid = c.oid where current_database() = {s} and n.nspname = {s} and c.relname = {s} and a.attnum > 0 and not a.attisdropped order by a.attnum", .{ database_expression, schema_literal, relation_literal }),
        };
        defer allocator.free(sql);
        var column_result = try self.query(sql);
        errdefer column_result.deinit(allocator);
        if (context) |cache| if (cache.usable()) try cache.cache.putColumns(&cache.scope, database, schema, relation, column_result, generation);
        return column_result;
    }
    pub fn relationExists(self: *Session, allocator: std.mem.Allocator, schema: []const u8, relation: []const u8) !bool {
        return self.relationExistsInDatabase(allocator, null, schema, relation);
    }
    pub fn relationExistsInDatabase(self: *Session, allocator: std.mem.Allocator, database: ?[]const u8, schema: []const u8, relation: []const u8) !bool {
        const kind = try self.relationTypeInDatabase(allocator, database, schema, relation);
        defer if (kind) |value| allocator.free(value);
        return kind != null;
    }
    /// Returns an owned dbt relation type: table, view or materialized_view.
    pub fn relationTypeInDatabase(self: *Session, allocator: std.mem.Allocator, database: ?[]const u8, schema: []const u8, relation: []const u8) !?[]const u8 {
        const context = self.cacheContext();
        const lookup = if (context) |cache| if (cache.usable()) try cache.cache.lookup(allocator, &cache.scope, database, schema, relation) else @import("relation_cache.zig").Lookup{} else @import("relation_cache.zig").Lookup{};
        if (lookup.found) return lookup.kind;
        const schema_literal = try quoteLiteral(allocator, schema);
        defer allocator.free(schema_literal);
        const relation_literal = try quoteLiteral(allocator, relation);
        defer allocator.free(relation_literal);
        const database_expression = if (database) |name| try quoteLiteral(allocator, name) else try allocator.dupe(u8, "current_database()");
        defer allocator.free(database_expression);
        const sql = switch (self.*) {
            .duckdb => try std.fmt.allocPrint(allocator, "select case when table_type = 'VIEW' then 'view' else 'table' end as relation_type from information_schema.tables where table_catalog = {s} and table_schema = {s} and table_name = {s}", .{ database_expression, schema_literal, relation_literal }),
            .postgres => try std.fmt.allocPrint(allocator, "select case c.relkind when 'v' then 'view' when 'm' then 'materialized_view' else 'table' end as relation_type from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace where current_database() = {s} and n.nspname = {s} and c.relname = {s} and c.relkind in ('r', 'p', 'v', 'm', 'f')", .{ database_expression, schema_literal, relation_literal }),
        };
        defer allocator.free(sql);
        var result = try self.query(sql);
        defer result.deinit(allocator);
        if (result.rows.len == 0) {
            if (context) |cache| if (cache.usable()) try cache.cache.putRelation(&cache.scope, database, schema, relation, null, lookup.generation);
            return null;
        }
        if (result.rows.len != 1 or result.rows[0].len != 1 or result.rows[0][0] == null) return error.InvalidAdapterIntrospection;
        if (context) |cache| if (cache.usable()) try cache.cache.putRelation(&cache.scope, database, schema, relation, result.rows[0][0].?, lookup.generation);
        return try allocator.dupe(u8, result.rows[0][0].?);
    }
};

pub fn nativeDuckDbQuery(runtime: Runtime, path: []const u8, sql: []const u8, readonly: bool) !?QueryResult {
    if (!readonly) {
        if (runtime.adapter_session) |session| switch (session.*) {
            .duckdb => |*connection| if (connection.memory == std.mem.eql(u8, path, ":memory:")) return try connection.query(sql),
            else => {},
        };
    }
    if (readonly and std.mem.eql(u8, path, ":memory:")) if (runtime.adapter_session) |session| switch (session.*) {
        .duckdb => |*held| if (held.shared_memory_scope) |scope| {
            var connection = (try held.pool.acquireSharedMemory(scope, true)) orelse return error.NativeDuckDbLibraryNotFound;
            defer connection.deinit();
            return try connection.query(sql);
        },
        else => {},
    };
    var temporary_pool = DuckDBPool.init(runtime.allocator, runtime.io, runtime.environment);
    defer temporary_pool.deinit();
    const pool = runtime.duckdb_pool orelse &temporary_pool;
    var connection = (try pool.acquire(path, readonly)) orelse return null;
    defer connection.deinit();
    return try connection.query(sql);
}

pub fn openSession(runtime: Runtime, graph: *const Graph, db_path: []const u8) !Session {
    var session = try openSessionUncached(runtime, graph, db_path);
    if (graph.relation_cache) |cache| {
        var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
        hash.update(graph.adapter_type);
        hash.update("\x00");
        hash.update(db_path);
        hash.update("\x00");
        if (graph.connection_info) |conninfo| hash.update(conninfo);
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        const context = @import("relation_cache.zig").Context{ .cache = cache, .scope = std.fmt.bytesToHex(digest, .lower) };
        switch (session) {
            inline else => |*connection| connection.cache_context = context,
        }
        errdefer session.deinit();
        try @import("relation_cache.zig").warmSession(&session, false);
    }
    return session;
}

fn openSessionUncached(runtime: Runtime, graph: *const Graph, db_path: []const u8) !Session {
    if (std.mem.eql(u8, graph.adapter_type, "duckdb")) {
        const pool = runtime.duckdb_pool orelse return error.NativeDuckDbPoolRequired;
        const connection = if (std.mem.eql(u8, db_path, ":memory:")) try pool.acquireSharedMemoryWithProfile(if (runtime.invocation) |invocation| &invocation.id else graph.project_name, false, graph.duckdb_credentials) else try pool.acquireWithProfile(db_path, false, graph.duckdb_credentials);
        return .{ .duckdb = connection orelse return error.NativeDuckDbLibraryNotFound };
    }
    if (std.mem.eql(u8, graph.adapter_type, "postgres")) {
        const conninfo = graph.connection_info orelse return error.MissingPostgresConnection;
        const library = if (runtime.environment) |environment| environment.get("DXT_POSTGRES_LIBRARY") else null;
        return .{ .postgres = try PostgresConnection.openWithEnvironment(runtime.allocator, conninfo, library, runtime.environment) };
    }
    return error.UnsupportedAdapterExecution;
}

pub fn openUnitSession(runtime: Runtime, graph: *const Graph) !Session {
    if (std.mem.eql(u8, graph.adapter_type, "duckdb")) {
        const pool = runtime.duckdb_pool orelse return error.NativeDuckDbPoolRequired;
        return .{ .duckdb = (try pool.acquireWithProfile(":memory:", false, graph.duckdb_credentials)) orelse return error.NativeDuckDbLibraryNotFound };
    }
    return openSessionUncached(runtime, graph, ":memory:");
}

pub fn queryForGraph(runtime: Runtime, graph: *const Graph, db_path: []const u8, sql: []const u8) !QueryResult {
    if (runtime.adapter_session) |session| return try session.query(sql);
    if (std.mem.eql(u8, graph.adapter_type, "duckdb")) {
        var temporary_pool = DuckDBPool.init(runtime.allocator, runtime.io, runtime.environment);
        defer temporary_pool.deinit();
        var configured_runtime = runtime;
        if (configured_runtime.duckdb_pool == null) configured_runtime.duckdb_pool = &temporary_pool;
        var session = try openSession(configured_runtime, graph, db_path);
        defer session.deinit();
        return try session.query(sql);
    }
    var session = try openSession(runtime, graph, db_path);
    defer session.deinit();
    return try session.query(sql);
}

pub fn executeForGraph(runtime: Runtime, graph: *const Graph, db_path: []const u8, sql: []const u8) !void {
    var output = try queryForGraph(runtime, graph, db_path, sql);
    output.deinit(runtime.allocator);
}

pub fn queryJson(runtime: Runtime, db_path: []const u8, sql: []const u8, readonly: bool) ![]const u8 {
    var output = if (try nativeDuckDbQuery(runtime, db_path, sql, readonly)) |native| native else try cliDuckDbQuery(runtime, db_path, sql, readonly);
    defer output.deinit(runtime.allocator);
    return try output.json(runtime.allocator);
}

fn cliDuckDbQuery(runtime: Runtime, db_path: []const u8, sql: []const u8, readonly: bool) !QueryResult {
    if (std.mem.indexOfScalar(u8, sql, 0) != null) return error.InvalidSqlText;
    const argv: []const []const u8 = if (readonly)
        &.{ "duckdb", "-readonly", db_path, "-json", "-batch", "-bail", "-c", sql }
    else
        &.{ "duckdb", db_path, "-json", "-batch", "-bail", "-c", sql };
    const process = std.process.run(runtime.allocator, runtime.io, .{ .argv = argv, .stdout_limit = .limited(64 * 1024 * 1024), .stderr_limit = .limited(64 * 1024) }) catch |err| switch (err) {
        error.FileNotFound => return error.DuckDbCliNotFound,
        error.StreamTooLong => return error.AdapterResultTooLarge,
        else => return err,
    };
    defer runtime.allocator.free(process.stdout);
    defer runtime.allocator.free(process.stderr);
    switch (process.term) {
        .exited => |code| if (code != 0) return error.DuckDbExecutionFailed,
        else => return error.DuckDbExecutionFailed,
    }
    if (std.mem.trim(u8, process.stdout, " \r\n\t").len == 0) return .{};
    var last: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, process.stdout, index, "\n[")) |next| {
        last = next + 1;
        index = next + 2;
    }
    return try parseJson(runtime.allocator, process.stdout[last..]);
}

pub fn parseJson(allocator: std.mem.Allocator, text: []const u8) !QueryResult {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.DuckDbExecutionFailed;
    if (parsed.value.array.items.len == 0) return .{ .owner_allocator = allocator };
    const first = parsed.value.array.items[0];
    if (first != .object) return error.DuckDbExecutionFailed;
    var output: QueryResult = .{ .owner_allocator = allocator };
    errdefer output.deinit(allocator);
    output.columns = try allocator.alloc(Column, first.object.count());
    for (output.columns) |*column| column.* = .{ .name = "", .kind = .other };
    var keys = first.object.iterator();
    for (output.columns) |*column| {
        const entry = keys.next().?;
        column.* = .{ .name = try allocator.dupe(u8, entry.key_ptr.*), .kind = jsonKind(entry.value_ptr.*) };
    }
    output.rows = try allocator.alloc([]?[]const u8, parsed.value.array.items.len);
    for (output.rows) |*row| row.* = &.{};
    for (parsed.value.array.items, output.rows) |value, *row| {
        if (value != .object) return error.DuckDbExecutionFailed;
        row.* = try allocator.alloc(?[]const u8, output.columns.len);
        @memset(row.*, null);
        for (output.columns, row.*) |*column, *cell| {
            const field = value.object.get(column.name) orelse return error.DuckDbExecutionFailed;
            if (field == .null) continue;
            if (column.kind == .other) column.kind = jsonKind(field);
            cell.* = switch (field) {
                .string => |string| try allocator.dupe(u8, string),
                .integer => |integer| try std.fmt.allocPrint(allocator, "{d}", .{integer}),
                .float => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
                .number_string => |number| try allocator.dupe(u8, number),
                .bool => |boolean| try allocator.dupe(u8, if (boolean) "true" else "false"),
                else => try std.json.Stringify.valueAlloc(allocator, field, .{}),
            };
        }
    }
    return output;
}

fn jsonKind(value: std.json.Value) Kind {
    return switch (value) {
        .integer => .integer,
        .number_string => .decimal,
        .float => .floating,
        .bool => .boolean,
        .string => .text,
        else => .other,
    };
}

test "parsed query result retains its owner across independent caller cleanup" {
    var owner: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expectEqual(.ok, owner.deinit()) catch @panic("parsed query owner leaked");
    var caller: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expectEqual(.ok, caller.deinit()) catch @panic("parsed query caller leaked");
    var output = try parseJson(owner.allocator(), "[{\"number\":17,\"text\":\"held\",\"missing\":null}]");
    try std.testing.expect(output.owner_allocator != null);
    try std.testing.expectEqualStrings("17", output.firstScalar().?);
    output.deinit(caller.allocator());
    var empty = try parseJson(owner.allocator(), "[]");
    try std.testing.expect(empty.owner_allocator != null);
    empty.deinit(caller.allocator());
}

test "parsed query result cleans every partially allocated result" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseResultAllocationFailures, .{});
}

fn parseResultAllocationFailures(a: std.mem.Allocator) !void {
    var output = try parseJson(a, "[{\"number\":17,\"text\":\"held\",\"missing\":null},{\"number\":18,\"text\":\"other\",\"missing\":null}]");
    defer output.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), output.rows.len);
}
