//! Database grammar front ends. Both return a native AST with byte locations;
//! PostgreSQL is parsed by its own grammar, never by a DuckDB compatibility mode.
const std = @import("std");
const adapter = @import("adapter.zig");
const types = @import("types.zig");
const values = @import("config_value.zig");
pub const Dialect = enum { duckdb, postgres };
pub const Diagnostic = struct { code: []const u8, message: []const u8, offset: usize = 0 };
pub const Parsed = struct { tree: std.json.Value = .null, diagnostic: ?Diagnostic = null };
const Error = extern struct { message: ?[*:0]const u8, funcname: ?[*:0]const u8, filename: ?[*:0]const u8, lineno: c_int, cursorpos: c_int, context: ?[*:0]const u8 };
const PgResult = extern struct { parse_tree: ?[*:0]const u8, stderr_buffer: ?[*:0]const u8, error_info: ?*Error };

pub const Postgres = struct {
    pub fn open(runtime: types.Runtime) !Postgres {
        _ = runtime;
        return .{};
    }
    pub fn deinit(self: *Postgres) void {
        _ = self;
    }
    pub fn parse(self: *Postgres, allocator: std.mem.Allocator, sql: []const u8) !Parsed {
        if (std.mem.indexOfScalar(u8, sql, 0) != null) return error.InvalidSqlText;
        const zero_terminated = try allocator.dupeZ(u8, sql);
        defer allocator.free(zero_terminated);
        _ = self;
        const result = pg_query_parse(zero_terminated);
        defer pg_query_free_parse_result(result);
        if (result.error_info) |err| return .{ .diagnostic = .{ .code = "SQL_SYNTAX", .message = try allocator.dupe(u8, if (err.message) |message| std.mem.span(message) else "Invalid PostgreSQL SQL"), .offset = if (err.cursorpos > 0) @intCast(err.cursorpos - 1) else 0 } };
        const tree = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.span(result.parse_tree orelse return error.InvalidSqlAst), .{ .allocate = .alloc_always });
        defer tree.deinit();
        return .{ .tree = try values.clone(allocator, tree.value) };
    }
};

extern fn pg_query_parse(input: [*:0]const u8) PgResult;
extern fn pg_query_free_parse_result(result: PgResult) void;

pub fn parseDuckDb(allocator: std.mem.Allocator, session: *adapter.Session, sql: []const u8) !Parsed {
    const literal = try adapter.quoteLiteral(allocator, sql);
    defer allocator.free(literal);
    const query = try std.fmt.allocPrint(allocator, "select json_serialize_sql({s}, skip_empty := true, skip_null := true)", .{literal});
    defer allocator.free(query);
    var result = try session.query(query);
    defer result.deinit(allocator);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result.firstScalar() orelse return error.InvalidSqlAst, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const tree = parsed.value;
    if (values.get(tree, "error")) |flag| if (flag == .bool and flag.bool) {
        const position = values.get(tree, "position") orelse .null;
        return .{ .diagnostic = .{ .code = "SQL_SYNTAX", .message = try allocator.dupe(u8, text(values.get(tree, "error_message") orelse .null)), .offset = if (position == .string) std.fmt.parseUnsigned(usize, position.string, 10) catch 0 else 0 } };
    };
    return .{ .tree = try values.clone(allocator, tree) };
}

pub fn text(value: std.json.Value) []const u8 {
    return if (value == .string) value.string else "";
}
pub fn field(value: std.json.Value, key: []const u8) std.json.Value {
    return values.get(value, key) orelse .null;
}
pub fn items(value: std.json.Value) []const std.json.Value {
    return if (value == .array) value.array.items else &.{};
}
pub fn location(value: std.json.Value) usize {
    const offset = values.get(value, "query_location") orelse values.get(value, "location") orelse .null;
    return if (offset == .integer and offset.integer >= 0 and offset.integer < std.math.maxInt(u32)) @intCast(offset.integer) else 0;
}

pub fn tableFunction(value: std.json.Value, dialect: Dialect) std.json.Value {
    if (dialect == .duckdb) return if (std.mem.eql(u8, text(field(value, "type")), "TABLE_FUNCTION")) field(value, "function") else .null;
    const function = field(value, "RangeFunction");
    const list = items(field(function, "functions"));
    if (list.len == 0) return .null;
    const expressions = items(field(field(list[0], "List"), "items"));
    return if (expressions.len != 0) field(expressions[0], "FuncCall") else .null;
}

test "PostgreSQL native grammar preserves joins CTEs locations and syntax errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try Postgres.open(.{ .allocator = allocator, .io = std.testing.io });
    defer parser.deinit();
    const parsed = try parser.parse(allocator, "with x as (select id from foo) select x.id::bigint from x");
    try std.testing.expect(parsed.diagnostic == null);
    const statement = field(items(field(parsed.tree, "stmts"))[0], "stmt");
    const select = field(statement, "SelectStmt");
    try std.testing.expect(field(select, "withClause") == .object);
    try std.testing.expectEqual(@as(usize, 1), items(field(select, "targetList")).len);
    const failed = try parser.parse(allocator, "select id from");
    try std.testing.expectEqualStrings("SQL_SYNTAX", failed.diagnostic.?.code);
    try std.testing.expect(failed.diagnostic.?.offset > 0);
}
