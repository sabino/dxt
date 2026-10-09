const std = @import("std");
const types = @import("types.zig");
const results = @import("adapter_result.zig");
pub const DuckDBPool = @import("native_duckdb.zig").Pool;
pub const DuckDBConnection = @import("native_duckdb.zig").Connection;
pub const PostgresConnection = @import("native_postgres.zig").Connection;
pub const QueryResult = results.QueryResult;
pub const Column = results.Column;
pub const Kind = results.Kind;
pub const Capabilities = results.Capabilities;
pub const quoteIdentifier = results.quoteIdentifier;
pub const quoteLiteral = results.quoteLiteral;
pub const Runtime = types.Runtime;
pub const Graph = types.Graph;
pub const profile = @import("profile.zig");
pub const ProjectConfig = types.ProjectConfig;

pub const Session = union(enum) {
    duckdb: DuckDBConnection,
    postgres: PostgresConnection,

    pub fn deinit(self: *Session) void {
        switch (self.*) {
            inline else => |*connection| connection.deinit(),
        }
    }
    pub fn query(self: *Session, sql: []const u8) !QueryResult {
        return switch (self.*) {
            inline else => |*connection| try connection.query(sql),
        };
    }
    pub fn execute(self: *Session, sql: []const u8) !void {
        switch (self.*) {
            inline else => |*connection| try connection.execute(sql),
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
    pub fn capabilities(self: *const Session) Capabilities {
        return switch (self.*) {
            .duckdb => @import("native_duckdb.zig").capabilities,
            .postgres => |*connection| connection.capabilities(),
        };
    }
    pub fn columns(self: *Session, allocator: std.mem.Allocator, schema: []const u8, relation: []const u8) !QueryResult {
        const schema_literal = try quoteLiteral(allocator, schema);
        defer allocator.free(schema_literal);
        const relation_literal = try quoteLiteral(allocator, relation);
        defer allocator.free(relation_literal);
        const sql = try std.fmt.allocPrint(allocator, "select column_name, data_type, is_nullable, ordinal_position from information_schema.columns where table_schema = {s} and table_name = {s} order by ordinal_position", .{ schema_literal, relation_literal });
        defer allocator.free(sql);
        return try self.query(sql);
    }
    pub fn relationExists(self: *Session, allocator: std.mem.Allocator, schema: []const u8, relation: []const u8) !bool {
        var columns_result = try self.columns(allocator, schema, relation);
        defer columns_result.deinit(allocator);
        return columns_result.rows.len != 0;
    }
};

pub fn nativeDuckDbQuery(runtime: Runtime, path: []const u8, sql: []const u8, readonly: bool) !?QueryResult {
    if (!readonly and !std.mem.eql(u8, path, ":memory:")) {
        if (runtime.adapter_session) |session| switch (session.*) {
            .duckdb => |*connection| return try connection.query(sql),
            else => {},
        };
    }
    var temporary_pool = DuckDBPool.init(runtime.allocator, runtime.io, runtime.environment);
    defer temporary_pool.deinit();
    const pool = runtime.duckdb_pool orelse &temporary_pool;
    var connection = (try pool.acquire(path, readonly)) orelse return null;
    defer connection.deinit();
    return try connection.query(sql);
}

pub fn openSession(runtime: Runtime, graph: *const Graph, db_path: []const u8) !Session {
    if (std.mem.eql(u8, graph.adapter_type, "duckdb")) {
        const pool = runtime.duckdb_pool orelse return error.NativeDuckDbPoolRequired;
        return .{ .duckdb = (try pool.acquire(db_path, false)) orelse return error.NativeDuckDbLibraryNotFound };
    }
    if (std.mem.eql(u8, graph.adapter_type, "postgres")) {
        const conninfo = graph.connection_info orelse return error.MissingPostgresConnection;
        const library = if (runtime.environment) |environment| environment.get("DXT_POSTGRES_LIBRARY") else null;
        return .{ .postgres = try PostgresConnection.open(runtime.allocator, conninfo, library) };
    }
    return error.UnsupportedAdapterExecution;
}

pub fn queryForGraph(runtime: Runtime, graph: *const Graph, db_path: []const u8, sql: []const u8) !QueryResult {
    if (runtime.adapter_session) |session| return try session.query(sql);
    if (std.mem.eql(u8, graph.adapter_type, "duckdb")) {
        if (try nativeDuckDbQuery(runtime, db_path, sql, false)) |native| return native;
        return try cliDuckDbQuery(runtime, db_path, sql, false);
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
    if (parsed.value.array.items.len == 0) return .{};
    const first = parsed.value.array.items[0];
    if (first != .object) return error.DuckDbExecutionFailed;
    var output: QueryResult = .{};
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
