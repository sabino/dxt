//! PostgreSQL model lifecycle matching dbt-core 1.10.5/dbt-postgres 1.9.1.
//! A replacement is built before the existing relation is renamed. All DDL,
//! index creation and cleanup share one transaction and one native connection.
const std = @import("std");
const adapter = @import("adapter.zig");
const compiler = @import("compiler.zig");
const config_value = @import("config_value.zig");
const types = @import("types.zig");

pub const ExecutionPolicy = struct {
    manage_transaction: bool = true,
    file_effects: ?*@import("materialization_journal.zig").Journal = null,
    // Owned by the caller, including when a later hook or commit fails.
    main_result: ?*?@import("materialization_result.zig").Result = null,
};

pub fn isSupported(value: []const u8) bool {
    return std.mem.eql(u8, value, "table") or std.mem.eql(u8, value, "view") or std.mem.eql(u8, value, "materialized_view");
}

pub fn execute(runtime: types.Runtime, graph: *const types.Graph, node: *const types.Node, sql: []const u8) !void {
    return executeWithPolicy(runtime, graph, node, sql, .{});
}

pub fn executeWithPolicy(runtime: types.Runtime, graph: *const types.Graph, node: *const types.Node, sql: []const u8, policy: ExecutionPolicy) !void {
    var result = try executeReturningWithPolicy(runtime, graph, node, sql, policy);
    result.deinit(runtime.allocator);
}

// The main statement response remains available to callers that emit adapter
// metadata; cleanup DDL must not replace its real server command tag.
pub fn executeReturningWithPolicy(runtime: types.Runtime, graph: *const types.Graph, node: *const types.Node, sql: []const u8, policy: ExecutionPolicy) !adapter.QueryResult {
    if (!std.mem.eql(u8, graph.adapter_type, "postgres") or !isSupported(node.materialized)) return error.UnsupportedModelMaterialization;
    if (!policy.manage_transaction and runtime.adapter_session == null) return error.NativeAdapterSessionRequired;
    var owned: ?adapter.Session = null;
    defer if (owned) |*session| session.deinit();
    const session = runtime.adapter_session orelse blk: {
        owned = try adapter.openSession(runtime, graph, ":memory:");
        break :blk &owned.?;
    };
    if (policy.manage_transaction) try session.begin();
    errdefer if (policy.manage_transaction) session.rollback() catch {};
    if (policy.main_result) |output| {
        if (output.*) |previous| previous.deinit(runtime.allocator);
        output.* = null;
    }
    var result = try executeInTransaction(runtime, session, graph, node, sql, policy.main_result);
    errdefer result.deinit(runtime.allocator);
    if (policy.main_result == null or policy.main_result.?.* == null) try @import("materialization_result.zig").captureQuery(runtime.allocator, policy.main_result, result);
    if (policy.manage_transaction) try session.commit();
    return result;
}

fn executeInTransaction(runtime: types.Runtime, session: *adapter.Session, graph: *const types.Graph, node: *const types.Node, sql: []const u8, main_result: ?*?@import("materialization_result.zig").Result) !adapter.QueryResult {
    const allocator = runtime.allocator;
    if (compiler.relationDatabaseForNode(graph, node)) |database| {
        var current = try session.query("select current_database()");
        defer current.deinit(allocator);
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, database, "\""), current.firstScalar() orelse return error.InvalidAdapterIntrospection)) return error.InvalidPostgresDatabaseReference;
    }
    const schema = try compiler.relationSchemaForNode(allocator, graph, node);
    defer allocator.free(schema);
    const identifier = compiler.relationIdentifierForNode(node);
    if (identifier.len > 63) return error.InvalidPostgresRelationName;
    const target = try qualified(allocator, schema, identifier);
    defer allocator.free(target);
    const quoted_schema = try adapter.quoteIdentifier(allocator, schema);
    defer allocator.free(quoted_schema);
    const create_schema = try std.fmt.allocPrint(allocator, "create schema if not exists {s}", .{quoted_schema});
    defer allocator.free(create_schema);
    try session.execute(create_schema);
    const existing = try session.relationTypeInDatabase(allocator, compiler.relationDatabaseForNode(graph, node), schema, identifier);
    defer if (existing) |kind| allocator.free(kind);
    const indexes = if (std.mem.eql(u8, node.materialized, "view")) try allocator.alloc(Index, 0) else try parseIndexes(allocator, node);
    defer allocator.free(indexes);
    if (std.mem.eql(u8, node.materialized, "materialized_view") and existing != null and std.mem.eql(u8, existing.?, "materialized_view") and !@import("incremental_config.zig").fullRefresh(graph, node)) {
        return updateMaterializedView(runtime, session, graph, schema, identifier, target, indexes, node, main_result);
    }
    const intermediate_id = try suffixedIdentifier(allocator, identifier, "__dbt_tmp");
    defer allocator.free(intermediate_id);
    const backup_id = try suffixedIdentifier(allocator, identifier, "__dbt_backup");
    defer allocator.free(backup_id);
    const intermediate = try qualified(allocator, schema, intermediate_id);
    defer allocator.free(intermediate);
    const backup = try qualified(allocator, schema, backup_id);
    defer allocator.free(backup);
    try dropIfExists(allocator, session, schema, intermediate_id, intermediate);
    try dropIfExists(allocator, session, schema, backup_id, backup);
    const creation = if (@import("contracts.zig").enforced(node)) try @import("contracts.zig").renderCreation(allocator, graph, node, intermediate, sql, node.materialized) else try renderCreate(allocator, node, intermediate, sql);
    defer allocator.free(creation);
    var result = try session.query(creation);
    errdefer result.deinit(allocator);
    if (!std.mem.eql(u8, node.materialized, "view")) for (indexes) |index| {
        if (std.mem.eql(u8, node.materialized, "materialized_view")) {
            const index_response = try createIndexReturning(allocator, session, intermediate, index);
            result.deinit(allocator);
            result = index_response;
        } else try createIndex(allocator, session, intermediate, index);
    };
    if (existing) |kind| try rename(allocator, session, kind, target, backup_id);
    try rename(allocator, session, node.materialized, intermediate, identifier);
    if (existing) |kind| try drop(allocator, session, kind, backup);
    return result;
}

pub fn renderCreate(allocator: std.mem.Allocator, node: *const types.Node, relation: []const u8, sql: []const u8) ![]const u8 {
    if (!isSupported(node.materialized)) return error.UnsupportedModelMaterialization;
    const header_value = config_value.get(node.effective_config, "sql_header") orelse .null;
    const header = if (header_value == .null) "" else if (header_value == .string) header_value.string else return error.InvalidPostgresMaterializationConfig;
    const unlogged_value = config_value.get(node.effective_config, "unlogged") orelse .null;
    const unlogged = if (unlogged_value == .null) false else if (unlogged_value == .bool) unlogged_value.bool else return error.InvalidPostgresMaterializationConfig;
    const kind = if (std.mem.eql(u8, node.materialized, "materialized_view")) "materialized view" else node.materialized;
    return std.fmt.allocPrint(allocator, "{s}\ncreate {s}{s} {s} as (\n{s}\n);", .{ header, if (unlogged and std.mem.eql(u8, kind, "table")) "unlogged " else "", kind, relation, sql });
}

fn relationKind(kind: []const u8) []const u8 {
    return if (std.mem.eql(u8, kind, "materialized_view")) "materialized view" else kind;
}
fn drop(allocator: std.mem.Allocator, session: *adapter.Session, kind: []const u8, relation: []const u8) !void {
    const sql = try std.fmt.allocPrint(allocator, "drop {s} if exists {s} cascade", .{ relationKind(kind), relation });
    defer allocator.free(sql);
    try session.execute(sql);
}
fn dropIfExists(allocator: std.mem.Allocator, session: *adapter.Session, schema: []const u8, identifier: []const u8, relation: []const u8) !void {
    const kind = try session.relationTypeInDatabase(allocator, null, schema, identifier);
    defer if (kind) |value| allocator.free(value);
    if (kind) |value| try drop(allocator, session, value, relation);
}
fn rename(allocator: std.mem.Allocator, session: *adapter.Session, kind: []const u8, relation: []const u8, name: []const u8) !void {
    const quoted = try adapter.quoteIdentifier(allocator, name);
    defer allocator.free(quoted);
    const sql = try std.fmt.allocPrint(allocator, "alter {s} {s} rename to {s}", .{ relationKind(kind), relation, quoted });
    defer allocator.free(sql);
    try session.execute(sql);
}
fn qualified(allocator: std.mem.Allocator, schema: []const u8, identifier: []const u8) ![]const u8 {
    const left = try adapter.quoteIdentifier(allocator, schema);
    defer allocator.free(left);
    const right = try adapter.quoteIdentifier(allocator, identifier);
    defer allocator.free(right);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ left, right });
}
fn suffixedIdentifier(allocator: std.mem.Allocator, identifier: []const u8, suffix: []const u8) ![]const u8 {
    var end = @min(identifier.len, 63 - suffix.len);
    while (end > 0 and end < identifier.len and identifier[end] & 0xc0 == 0x80) end -= 1;
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ identifier[0..end], suffix });
}

const Index = struct { columns: []std.json.Value, unique: bool = false, method: []const u8 = "btree" };
fn parseIndexes(allocator: std.mem.Allocator, node: *const types.Node) ![]Index {
    const raw = config_value.get(node.effective_config, "indexes") orelse .null;
    if (raw == .null) return allocator.alloc(Index, 0);
    if (raw != .array) return error.InvalidPostgresMaterializationConfig;
    const indexes = try allocator.alloc(Index, raw.array.items.len);
    errdefer allocator.free(indexes);
    for (raw.array.items, indexes) |value, *index| {
        const columns = config_value.get(value, "columns") orelse return error.InvalidPostgresMaterializationConfig;
        if (columns != .array or columns.array.items.len == 0) return error.InvalidPostgresMaterializationConfig;
        for (columns.array.items) |column| if (column != .string or column.string.len == 0) return error.InvalidPostgresMaterializationConfig;
        const unique: std.json.Value = config_value.get(value, "unique") orelse .{ .bool = false };
        const method = config_value.get(value, "type") orelse .null;
        if (unique != .bool or (method != .null and method != .string)) return error.InvalidPostgresMaterializationConfig;
        const method_name = if (method == .string) method.string else "btree";
        var allowed = false;
        for ([_][]const u8{ "btree", "hash", "gist", "spgist", "gin", "brin" }) |candidate| if (std.mem.eql(u8, method_name, candidate)) {
            allowed = true;
        };
        if (!allowed) return error.InvalidPostgresMaterializationConfig;
        index.* = .{ .columns = columns.array.items, .unique = unique.bool, .method = method_name };
    }
    return indexes;
}

pub fn createConfiguredIndexes(allocator: std.mem.Allocator, session: *adapter.Session, node: *const types.Node, relation: []const u8) !void {
    const indexes = try parseIndexes(allocator, node);
    defer allocator.free(indexes);
    for (indexes) |index| try createIndex(allocator, session, relation, index);
}

fn createIndex(allocator: std.mem.Allocator, session: *adapter.Session, relation: []const u8, index: Index) !void {
    var response = try createIndexReturning(allocator, session, relation, index);
    defer response.deinit(allocator);
}

fn createIndexReturning(allocator: std.mem.Allocator, session: *adapter.Session, relation: []const u8, index: Index) !adapter.QueryResult {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    // PostgreSQL generates a collision-free name. Core's names also vary per
    // transaction; reusing a stable name would skip creation on every other run.
    try out.writer.print("create {s}index on {s} using {s} (", .{ if (index.unique) "unique " else "", relation, index.method });
    for (index.columns, 0..) |column, i| {
        if (i != 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(column.string);
    }
    try out.writer.writeAll(")");
    return session.query(out.written());
}

const IndexDifference = struct {
    actual: adapter.QueryResult,
    matches: []bool,
    keep: []bool,
    changed: bool,

    fn deinit(self: *IndexDifference, allocator: std.mem.Allocator) void {
        self.actual.deinit(allocator);
        allocator.free(self.matches);
        allocator.free(self.keep);
    }
};

fn inspectIndexes(allocator: std.mem.Allocator, session: *adapter.Session, schema: []const u8, identifier: []const u8, desired: []const Index) !IndexDifference {
    const schema_literal = try adapter.quoteLiteral(allocator, schema);
    defer allocator.free(schema_literal);
    const name_literal = try adapter.quoteLiteral(allocator, identifier);
    defer allocator.free(name_literal);
    const inspection = try std.fmt.allocPrint(allocator, "select i.relname,m.amname,ix.indisunique,array_to_json(array_agg(a.attname order by a.attname))::text from pg_index ix join pg_class i on i.oid=ix.indexrelid join pg_am m on m.oid=i.relam join pg_class t on t.oid=ix.indrelid join pg_namespace n on n.oid=t.relnamespace join pg_attribute a on a.attrelid=t.oid and a.attnum=any(ix.indkey) where t.relname={s} and n.nspname={s} group by 1,2,3 order by 1", .{ name_literal, schema_literal });
    defer allocator.free(inspection);
    var actual = try session.query(inspection);
    errdefer actual.deinit(allocator);
    const matches = try allocator.alloc(bool, desired.len);
    errdefer allocator.free(matches);
    @memset(matches, false);
    const keep = try allocator.alloc(bool, actual.rows.len);
    errdefer allocator.free(keep);
    @memset(keep, false);
    for (actual.rows, 0..) |row, i| {
        if (row.len != 4) return error.InvalidAdapterIntrospection;
        const parsed = try std.json.parseFromSlice([][]const u8, allocator, row[3] orelse "[]", .{});
        defer parsed.deinit();
        for (desired, 0..) |index, j| {
            if (std.mem.eql(u8, row[1] orelse "", index.method) and (std.mem.eql(u8, row[2] orelse "", "t") or std.mem.eql(u8, row[2] orelse "", "true")) == index.unique and sameColumns(index.columns, parsed.value)) {
                matches[j] = true;
                keep[i] = true;
            }
        }
    }
    var changed = false;
    for (matches) |matched| if (!matched) {
        changed = true;
    };
    for (keep) |matched| if (!matched) {
        changed = true;
    };
    return .{ .actual = actual, .matches = matches, .keep = keep, .changed = changed };
}

/// Core determines a no-op before entering the transactional hook lifecycle.
pub fn skipsInnerLifecycle(runtime: types.Runtime, graph: *const types.Graph, node: *const types.Node, existing_kind: ?[]const u8) !bool {
    if (!std.mem.eql(u8, graph.adapter_type, "postgres") or !std.mem.eql(u8, node.materialized, "materialized_view") or @import("incremental_config.zig").fullRefresh(graph, node)) return false;
    if (existing_kind == null or !std.mem.eql(u8, existing_kind.?, "materialized_view")) return false;
    const policy = config_value.get(node.effective_config, "on_configuration_change") orelse return false;
    if (policy != .string or !std.mem.eql(u8, policy.string, "continue")) return false;
    const session = runtime.adapter_session orelse return error.NativeAdapterSessionRequired;
    const schema = try compiler.relationSchemaForNode(runtime.allocator, graph, node);
    defer runtime.allocator.free(schema);
    const indexes = try parseIndexes(runtime.allocator, node);
    defer runtime.allocator.free(indexes);
    var difference = try inspectIndexes(runtime.allocator, session, schema, compiler.relationIdentifierForNode(node), indexes);
    defer difference.deinit(runtime.allocator);
    return difference.changed;
}

fn updateMaterializedView(runtime: types.Runtime, session: *adapter.Session, graph: *const types.Graph, schema: []const u8, identifier: []const u8, target: []const u8, desired: []const Index, node: *const types.Node, main_result: ?*?@import("materialization_result.zig").Result) !adapter.QueryResult {
    const allocator = runtime.allocator;
    var difference = try inspectIndexes(allocator, session, schema, identifier, desired);
    defer difference.deinit(allocator);
    const actual = difference.actual;
    const matches = difference.matches;
    const keep = difference.keep;
    if (!difference.changed) {
        const refresh = try std.fmt.allocPrint(allocator, "refresh materialized view {s}", .{target});
        defer allocator.free(refresh);
        return session.query(refresh);
    }
    const policy_value: std.json.Value = config_value.get(node.effective_config, "on_configuration_change") orelse .{ .string = "apply" };
    if (policy_value != .string) return error.InvalidPostgresMaterializationConfig;
    const policy = policy_value.string;
    if (std.mem.eql(u8, policy, "continue")) {
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        const rendered_target = try (try compiler.relationValueForNode(scratch.allocator(), graph, node, false)).text(scratch.allocator());
        const message = try std.fmt.allocPrint(allocator, "Configuration changes were identified and `on_configuration_change` was set to `continue` for `{s}`", .{rendered_target});
        defer allocator.free(message);
        try @import("jinja_warning.zig").emit(runtime, node, message, graph.log_collector, runtime.event_writer);
        try @import("materialization_result.zig").captureSkip(allocator, main_result, rendered_target);
        return .{};
    }
    if (std.mem.eql(u8, policy, "fail")) return error.PostgresMaterializedViewConfigurationChanged;
    if (!std.mem.eql(u8, policy, "apply")) return error.InvalidPostgresMaterializationConfig;
    var response: ?adapter.QueryResult = null;
    errdefer if (response) |*previous| previous.deinit(allocator);
    for (actual.rows, keep) |row, matched| if (!matched) {
        const name = try qualified(allocator, schema, row[0] orelse return error.InvalidAdapterIntrospection);
        defer allocator.free(name);
        const deletion = try std.fmt.allocPrint(allocator, "drop index if exists {s}", .{name});
        defer allocator.free(deletion);
        const deletion_response = try session.query(deletion);
        if (response) |*previous| previous.deinit(allocator);
        response = deletion_response;
    };
    for (desired, matches) |index, matched| if (!matched) {
        const index_response = try createIndexReturning(allocator, session, target, index);
        if (response) |*previous| previous.deinit(allocator);
        response = index_response;
    };
    // Core's index-only configuration update does not refresh the data.
    return response orelse error.InvalidPostgresMaterializationConfig;
}
fn sameColumns(desired: []const std.json.Value, actual: []const []const u8) bool {
    if (desired.len != actual.len) return false;
    for (desired) |column| {
        var found = false;
        for (actual) |name| if (std.ascii.eqlIgnoreCase(column.string, name)) {
            found = true;
        };
        if (!found) return false;
    }
    return true;
}

test "PostgreSQL creation preserves materialization, unlogged and SQL header" {
    const allocator = std.testing.allocator;
    const config = try std.json.parseFromSlice(std.json.Value, allocator, "{\"unlogged\":true,\"sql_header\":\"set local statement_timeout=1000;\"}", .{});
    defer config.deinit();
    var node: types.Node = undefined;
    node.materialized = "table";
    node.effective_config = config.value;
    const sql = try renderCreate(allocator, &node, "\"schema\".\"target\"", "select 1 id");
    defer allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "create unlogged table") != null);
    try std.testing.expect(std.mem.startsWith(u8, sql, "set local statement_timeout"));
    node.materialized = "materialized_view";
    const mv = try renderCreate(allocator, &node, "m", "select 1");
    defer allocator.free(mv);
    try std.testing.expect(std.mem.indexOf(u8, mv, "create materialized view m") != null);
}

test "PostgreSQL temporary identifiers retain suffix within server length" {
    const id = try suffixedIdentifier(std.testing.allocator, "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijk", "__dbt_backup");
    defer std.testing.allocator.free(id);
    try std.testing.expectEqual(@as(usize, 63), id.len);
    try std.testing.expect(std.mem.endsWith(u8, id, "__dbt_backup"));
}

test "PostgreSQL indexes validate typed configuration and compare as sets" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"indexes\":[{\"columns\":[\"B\",\"a\"],\"unique\":true,\"type\":\"hash\"}]}", .{});
    defer parsed.deinit();
    var node: types.Node = undefined;
    node.effective_config = parsed.value;
    const indexes = try parseIndexes(allocator, &node);
    defer allocator.free(indexes);
    try std.testing.expect(indexes[0].unique);
    try std.testing.expectEqualStrings("hash", indexes[0].method);
    try std.testing.expect(sameColumns(indexes[0].columns, &.{ "a", "b" }));
    const invalid = try std.json.parseFromSlice(std.json.Value, allocator, "{\"indexes\":[{\"columns\":[]}]}", .{});
    defer invalid.deinit();
    node.effective_config = invalid.value;
    try std.testing.expectError(error.InvalidPostgresMaterializationConfig, parseIndexes(allocator, &node));
}
