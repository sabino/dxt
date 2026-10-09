//! Invocation-owned native relation metadata cache, shared by worker sessions.
const std = @import("std");
const result = @import("adapter_result.zig");
const QueryResult = result.QueryResult;
const Value = std.json.Value;

pub const Request = struct { database: ?[]const u8, schema: []const u8 };
pub const Lookup = struct { found: bool = false, kind: ?[]const u8 = null, generation: u64 = 0 };
pub const Stats = struct { hits: u64 = 0, misses: u64 = 0, warm_queries: u64 = 0, invalidations: u64 = 0 };
const Event = struct { action: []const u8, stats: Stats };

pub const Cache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    warm_mutex: std.Io.Mutex = .init,
    relations: std.StringHashMap(?[]const u8),
    columns: std.StringHashMap(QueryResult),
    schemas: std.StringHashMap(void),
    warmed: std.StringHashMap(void),
    requests: std.ArrayList(Request) = .empty,
    events: std.ArrayList(Event) = .empty,
    log_events: bool = false,
    populate: bool = true,
    generation: u64 = 0,
    active_writes: usize = 0,
    stats: Stats = .{},

    pub fn init(a: std.mem.Allocator, io: std.Io) Cache {
        return .{ .allocator = a, .io = io, .relations = .init(a), .columns = .init(a), .schemas = .init(a), .warmed = .init(a) };
    }
    pub fn deinit(self: *Cache) void {
        self.clearMetadata();
        self.relations.deinit();
        self.columns.deinit();
        self.schemas.deinit();
        self.clearWarmed();
        self.warmed.deinit();
        for (self.requests.items) |request| {
            if (request.database) |database| self.allocator.free(database);
            self.allocator.free(request.schema);
        }
        self.requests.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }
    fn clearMetadata(self: *Cache) void {
        var relations = self.relations.iterator();
        while (relations.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |kind| self.allocator.free(kind);
        }
        self.relations.clearRetainingCapacity();
        var columns = self.columns.iterator();
        while (columns.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.columns.clearRetainingCapacity();
        var schemas = self.schemas.keyIterator();
        while (schemas.next()) |key| self.allocator.free(key.*);
        self.schemas.clearRetainingCapacity();
    }
    fn clearWarmed(self: *Cache) void {
        var keys = self.warmed.keyIterator();
        while (keys.next()) |key| self.allocator.free(key.*);
        self.warmed.clearRetainingCapacity();
    }
    fn event(self: *Cache, action: []const u8) void {
        if (self.log_events) self.events.append(self.allocator, .{ .action = action, .stats = self.stats }) catch {};
    }
    fn invalidateLocked(self: *Cache) void {
        self.generation +%= 1;
        self.stats.invalidations += 1;
        self.clearMetadata();
        self.event("invalidate");
    }
    pub fn beginWrite(self: *Cache) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.active_writes += 1;
        self.invalidateLocked();
    }
    pub fn endWrite(self: *Cache) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        std.debug.assert(self.active_writes != 0);
        self.active_writes -= 1;
        self.invalidateLocked();
    }
    pub fn epoch(self: *Cache) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.generation;
    }
    pub fn lookup(self: *Cache, a: std.mem.Allocator, scope: []const u8, database: ?[]const u8, schema: []const u8, relation: []const u8) !Lookup {
        const key = try relationKey(a, scope, database, schema, relation);
        defer a.free(key);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.active_writes == 0) {
            if (self.relations.getEntry(key)) |entry| {
                self.stats.hits += 1;
                self.event("hit");
                return .{ .found = true, .kind = if (entry.value_ptr.*) |kind| try a.dupe(u8, kind) else null, .generation = self.generation };
            }
            const schema_key = try schemaKey(a, scope, database, schema);
            defer a.free(schema_key);
            if (self.schemas.contains(schema_key)) {
                self.stats.hits += 1;
                self.event("hit");
                return .{ .found = true, .generation = self.generation };
            }
        }
        self.stats.misses += 1;
        self.event("miss");
        return .{ .generation = self.generation };
    }
    pub fn putRelation(self: *Cache, scope: []const u8, database: ?[]const u8, schema: []const u8, relation: []const u8, kind: ?[]const u8, generation: u64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.active_writes != 0 or self.generation != generation) return;
        const key = try relationKey(self.allocator, scope, database, schema, relation);
        if (self.relations.contains(key)) {
            self.allocator.free(key);
            return;
        }
        try self.relations.put(key, if (kind) |text| try self.allocator.dupe(u8, text) else null);
        self.event("add");
    }
    pub fn getColumns(self: *Cache, a: std.mem.Allocator, scope: []const u8, database: ?[]const u8, schema: []const u8, relation: []const u8) !?QueryResult {
        const key = try relationKey(a, scope, database, schema, relation);
        defer a.free(key);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.active_writes == 0) if (self.columns.get(key)) |columns| {
            self.stats.hits += 1;
            self.event("columns_hit");
            return try clone(a, columns);
        };
        self.stats.misses += 1;
        self.event("columns_miss");
        return null;
    }
    pub fn putColumns(self: *Cache, scope: []const u8, database: ?[]const u8, schema: []const u8, relation: []const u8, columns: QueryResult, generation: u64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.active_writes != 0 or self.generation != generation) return;
        const key = try relationKey(self.allocator, scope, database, schema, relation);
        if (self.columns.contains(key)) {
            self.allocator.free(key);
            return;
        }
        try self.columns.put(key, try clone(self.allocator, columns));
    }
    pub fn statistics(self: *Cache) Stats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.stats;
    }
};

pub const Context = struct {
    cache: *Cache,
    scope: [64]u8,
    transaction_open: bool = false,
    write_transaction: bool = false,

    pub fn usable(self: *const Context) bool {
        return !self.transaction_open;
    }
    pub fn before(self: *Context, sql: []const u8) Change {
        const change = classify(sql);
        if (change.write and !self.write_transaction) self.cache.beginWrite();
        return change;
    }
    pub fn after(self: *Context, change: Change, success: bool) void {
        const final_transaction = if (success and change.ends) false else self.transaction_open or change.begins;
        self.afterTransaction(change, final_transaction);
    }
    /// Native drivers with transaction status report the server's state, also
    /// after errors and COMMIT/ROLLBACK AND CHAIN scripts.
    pub fn afterTransaction(self: *Context, change: Change, final_transaction: bool) void {
        if (change.write and !self.write_transaction) {
            if (final_transaction) self.write_transaction = true else self.cache.endWrite();
        }
        if (self.write_transaction and !final_transaction) {
            self.cache.endWrite();
            self.write_transaction = false;
        }
        self.transaction_open = final_transaction;
    }
    pub fn close(self: *Context) void {
        if (self.write_transaction) self.cache.endWrite();
        self.write_transaction = false;
    }
};

pub const Change = struct { write: bool = false, begins: bool = false, ends: bool = false };
/// Only proven read statements retain metadata. Comments, quoted strings and
/// dollar-quoted blocks cannot hide subsequent statements from this scanner.
pub fn classify(sql: []const u8) Change {
    var result_change: Change = .{};
    var index: usize = 0;
    var at_start = true;
    var select_statement = false;
    while (index < sql.len) {
        const ch = sql[index];
        if (std.ascii.isWhitespace(ch)) {
            index += 1;
            continue;
        }
        if (ch == '-' and index + 1 < sql.len and sql[index + 1] == '-') {
            index = std.mem.indexOfScalarPos(u8, sql, index + 2, '\n') orelse sql.len;
            continue;
        }
        if (ch == '/' and index + 1 < sql.len and sql[index + 1] == '*') {
            var depth: usize = 1;
            index += 2;
            while (index < sql.len and depth != 0) {
                if (index + 1 < sql.len and sql[index] == '/' and sql[index + 1] == '*') {
                    depth += 1;
                    index += 2;
                } else if (index + 1 < sql.len and sql[index] == '*' and sql[index + 1] == '/') {
                    depth -= 1;
                    index += 2;
                } else index += 1;
            }
            continue;
        }
        if (at_start) {
            const start = index;
            while (index < sql.len and (std.ascii.isAlphabetic(sql[index]) or sql[index] == '_')) index += 1;
            const word = sql[start..index];
            select_statement = equal(word, "select");
            if (equal(word, "begin") or equal(word, "start")) {
                result_change.begins = true;
                result_change.ends = false;
            } else if (equal(word, "commit") or equal(word, "end")) {
                result_change.ends = true;
            } else if (equal(word, "rollback")) {
                var tail = std.mem.trimStart(u8, sql[index..], " \t\r\n");
                if (std.ascii.startsWithIgnoreCase(tail, "work")) tail = std.mem.trimStart(u8, tail[4..], " \t\r\n");
                if (!std.ascii.startsWithIgnoreCase(tail, "to ")) result_change.ends = true;
            } else if (!equal(word, "select") and !equal(word, "show") and !equal(word, "describe") and !equal(word, "desc") and !equal(word, "savepoint") and !equal(word, "release")) result_change.write = true;
            at_start = false;
            if (index == start) index += 1;
            continue;
        }
        if (ch == '\'' or ch == '"') {
            const quote = ch;
            index += 1;
            while (index < sql.len) {
                if (sql[index] == quote) {
                    index += 1;
                    if (index < sql.len and sql[index] == quote) {
                        index += 1;
                        continue;
                    }
                    break;
                }
                if (sql[index] == '\\' and index + 1 < sql.len) index += 1;
                index += 1;
            }
            if (quote == '"' and select_statement) {
                const next = nextCode(sql, index);
                if (next < sql.len and sql[next] == '(') result_change.write = true;
            }
        } else if (ch == '$') {
            const start = index;
            index += 1;
            while (index < sql.len and (std.ascii.isAlphanumeric(sql[index]) or sql[index] == '_')) index += 1;
            if (index < sql.len and sql[index] == '$') {
                index += 1;
                const marker = sql[start..index];
                if (std.mem.indexOfPos(u8, sql, index, marker)) |end| index = end + marker.len else index = sql.len;
            }
        } else if (std.ascii.isAlphabetic(ch) or ch == '_') {
            const start = index;
            while (index < sql.len and (std.ascii.isAlphanumeric(sql[index]) or sql[index] == '_')) index += 1;
            const next = nextCode(sql, index);
            // PostgreSQL SELECT functions can perform DDL. Retain the cache
            // only for known pure builtins used by native introspection.
            if (select_statement and next < sql.len and sql[next] == '(' and !pureCall(sql[start..index])) result_change.write = true;
            if (select_statement and equal(sql[start..index], "into")) result_change.write = true;
        } else {
            index += 1;
            if (ch == ';') at_start = true;
        }
    }
    return result_change;
}
fn nextCode(sql: []const u8, offset: usize) usize {
    var index = offset;
    while (index < sql.len) {
        if (std.ascii.isWhitespace(sql[index])) {
            index += 1;
        } else if (std.mem.startsWith(u8, sql[index..], "--")) {
            index = std.mem.indexOfScalarPos(u8, sql, index + 2, '\n') orelse sql.len;
        } else if (std.mem.startsWith(u8, sql[index..], "/*")) {
            var depth: usize = 1;
            index += 2;
            while (index < sql.len and depth != 0) {
                if (std.mem.startsWith(u8, sql[index..], "/*")) {
                    depth += 1;
                    index += 2;
                } else if (std.mem.startsWith(u8, sql[index..], "*/")) {
                    depth -= 1;
                    index += 2;
                } else index += 1;
            }
        } else break;
    }
    return index;
}
fn pureCall(name: []const u8) bool {
    for ([_][]const u8{ "current_database", "format_type", "cast", "count", "sum", "min", "max", "avg", "coalesce", "nullif", "lower", "upper", "trim", "substring", "length", "concat", "typeof", "pg_typeof", "in", "where", "on", "and", "or", "not", "when", "exists", "over", "filter" }) |known| if (equal(name, known)) return true;
    return false;
}
fn equal(l: []const u8, r: []const u8) bool {
    return std.ascii.eqlIgnoreCase(l, r);
}
fn schemaKey(a: std.mem.Allocator, scope: []const u8, database: ?[]const u8, schema: []const u8) ![]const u8 {
    const name: []const u8 = database orelse "";
    return std.fmt.allocPrint(a, "{s}:{c}{d}:{s}:{d}:{s}", .{ scope, @as(u8, if (database == null) 'n' else 'd'), name.len, name, schema.len, schema });
}
fn relationKey(a: std.mem.Allocator, scope: []const u8, database: ?[]const u8, schema: []const u8, relation: []const u8) ![]const u8 {
    const schema_key = try schemaKey(a, scope, database, schema);
    defer a.free(schema_key);
    return std.fmt.allocPrint(a, "{s}:{d}:{s}", .{ schema_key, relation.len, relation });
}
fn clone(a: std.mem.Allocator, source: QueryResult) !QueryResult {
    var copy: QueryResult = .{ .owner_allocator = a, .rows_changed = source.rows_changed };
    errdefer copy.deinit(a);
    var columns: std.ArrayList(result.Column) = .empty;
    for (source.columns) |column| {
        var owned = column;
        owned.name = try a.dupe(u8, column.name);
        try columns.append(a, owned);
    }
    copy.columns = try columns.toOwnedSlice(a);
    var rows: std.ArrayList([]?[]const u8) = .empty;
    for (source.rows) |row| {
        const owned = try a.alloc(?[]const u8, row.len);
        for (row, owned) |cell, *target| target.* = if (cell) |text| try a.dupe(u8, text) else null;
        try rows.append(a, owned);
    }
    copy.rows = try rows.toOwnedSlice(a);
    return copy;
}

/// Configure warmup without opening a connection. Offline compilation stays
/// offline until its first native database callback requests a session.
pub fn configure(runtime: @import("types.zig").Runtime, graph: *const @import("types.zig").Graph, selected_ids: ?[]const []const u8) !void {
    const cache = graph.relation_cache orelse return;
    try cache.warm_mutex.lock(runtime.io);
    defer cache.warm_mutex.unlock(runtime.io);
    for (cache.requests.items) |request| {
        if (request.database) |database| cache.allocator.free(database);
        cache.allocator.free(request.schema);
    }
    cache.requests.clearRetainingCapacity();
    cache.clearWarmed();
    cache.populate = graph.command_options.populate_cache;
    cache.log_events = graph.command_options.log_cache_events;
    if (!cache.populate) return;
    const compiler = @import("compiler.zig");
    for (graph.nodes.items) |*node| {
        if (!node.enabled or equal(node.materialized, "ephemeral") or equal(node.resource_type, "analysis")) continue;
        if (graph.command_options.cache_selected_only and selected_ids != null and !contains(selected_ids.?, node.unique_id)) continue;
        const schema = try compiler.relationSchemaForNode(runtime.allocator, graph, node);
        defer runtime.allocator.free(schema);
        try addRequest(cache, compiler.relationDatabaseForNode(graph, node), schema);
    }
    // With selected-only caching, freshness's required schemas are its source
    // schemas. Default warmup follows Core's physical manifest node schemas.
    for (graph.sources.items) |*source| {
        if (!source.enabled) continue;
        if (!graph.command_options.cache_selected_only or selected_ids == null or !contains(selected_ids.?, source.unique_id)) continue;
        try addRequest(cache, compiler.sourceDatabaseName(source), compiler.sourceSchemaName(source));
    }
}
fn contains(ids: []const []const u8, id: []const u8) bool {
    for (ids) |item| if (std.mem.eql(u8, item, id)) return true;
    return false;
}
fn addRequest(cache: *Cache, database: ?[]const u8, schema: []const u8) !void {
    for (cache.requests.items) |request| if (optionalEqual(request.database, database) and std.mem.eql(u8, request.schema, schema)) return;
    try cache.requests.append(cache.allocator, .{ .database = if (database) |value| try cache.allocator.dupe(u8, value) else null, .schema = try cache.allocator.dupe(u8, schema) });
}
fn optionalEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left == null or right == null) return left == null and right == null;
    return std.mem.eql(u8, left.?, right.?);
}

pub fn warmSession(session: *@import("adapter.zig").Session, force: bool) !void {
    const context = session.cacheContext() orelse return;
    const cache = context.cache;
    if (!cache.populate or !context.usable()) return;
    try cache.warm_mutex.lock(cache.io);
    defer cache.warm_mutex.unlock(cache.io);
    if (!force and cache.warmed.contains(&context.scope)) return;
    const a = cache.allocator;
    const generation = cache.epoch();
    for (cache.requests.items) |request| {
        const database = if (request.database) |name| try result.quoteLiteral(a, name) else try a.dupe(u8, "current_database()");
        defer a.free(database);
        const schema = try result.quoteLiteral(a, request.schema);
        defer a.free(schema);
        const sql = switch (session.*) {
            .duckdb => try std.fmt.allocPrint(a, "select table_name as identifier, case when table_type = 'VIEW' then 'view' else 'table' end as relation_type from information_schema.tables where table_catalog = {s} and table_schema = {s}", .{ database, schema }),
            .postgres => try std.fmt.allocPrint(a, "select c.relname as identifier, case c.relkind when 'v' then 'view' when 'm' then 'materialized_view' else 'table' end as relation_type from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace where current_database() = {s} and n.nspname = {s} and c.relkind in ('r','p','v','m','f')", .{ database, schema }),
        };
        defer a.free(sql);
        var listing = try session.query(sql);
        defer listing.deinit(a);
        cache.mutex.lockUncancelable(cache.io);
        cache.stats.warm_queries += 1;
        cache.event("populate");
        cache.mutex.unlock(cache.io);
        for (listing.rows) |row| {
            if (row.len != 2 or row[0] == null or row[1] == null) return error.InvalidAdapterIntrospection;
            try cache.putRelation(&context.scope, request.database, request.schema, row[0].?, row[1].?, generation);
        }
        cache.mutex.lockUncancelable(cache.io);
        defer cache.mutex.unlock(cache.io);
        if (cache.active_writes == 0 and cache.generation == generation) {
            const key = try schemaKey(a, &context.scope, request.database, request.schema);
            if (cache.schemas.contains(key)) a.free(key) else try cache.schemas.put(key, {});
        }
    }
    if (!cache.warmed.contains(&context.scope)) try cache.warmed.put(try a.dupe(u8, &context.scope), {});
}

pub fn writeEvents(runtime: @import("types.zig").Runtime, graph: *const @import("types.zig").Graph, writer: *std.Io.Writer) !void {
    const cache = graph.relation_cache orelse return;
    if (!cache.log_events) return;
    cache.mutex.lockUncancelable(cache.io);
    defer cache.mutex.unlock(cache.io);
    for (cache.events.items) |entry| {
        try writer.writeAll("{\"data\":{\"action\":");
        try std.json.Stringify.value(entry.action, .{}, writer);
        try writer.writeAll(",\"cache\":");
        try std.json.Stringify.value(entry.stats, .{}, writer);
        try writer.writeAll("},\"info\":{\"name\":\"CacheAction\",\"level\":\"debug\",\"thread\":\"MainThread\",\"ts\":");
        try @import("execution_clock.zig").writeTimestamp(writer, @import("execution_clock.zig").now(runtime.io));
        try writer.writeAll(",\"invocation_id\":");
        if (runtime.invocation) |invocation| try std.json.Stringify.value(&invocation.id, .{}, writer) else try writer.writeAll("null");
        try writer.writeAll("}}\n");
    }
    cache.events.clearRetainingCapacity();
}

test "cache invalidation guards metadata across transactions and concurrent writers" {
    var cache: Cache = .init(std.testing.allocator, std.testing.io);
    defer cache.deinit();
    const a = std.testing.allocator;
    const scope = [_]u8{'x'} ** 64;
    try cache.putRelation(&scope, "db", "main", "rows", "table", cache.epoch());
    var hit = try cache.lookup(a, &scope, "db", "main", "rows");
    try std.testing.expect(hit.found);
    if (hit.kind) |kind| a.free(kind);
    var context: Context = .{ .cache = &cache, .scope = scope };
    context.after(context.before("begin"), true);
    context.after(context.before("alter table rows rename to renamed"), true);
    try std.testing.expect(!context.usable());
    hit = try cache.lookup(a, &scope, "db", "main", "renamed");
    try std.testing.expect(!hit.found);
    try cache.putRelation(&scope, "db", "main", "renamed", "table", hit.generation);
    context.after(context.before("rollback"), true);
    try std.testing.expect(context.usable());
    try std.testing.expectEqual(@as(usize, 0), cache.active_writes);
    try std.testing.expect(!(try cache.lookup(a, &scope, "db", "main", "renamed")).found);
    try std.testing.expect(classify("select ';create' /* nested /* ; */ */; drop table rows").write);
    try std.testing.expect(!classify("select $$; create table fake$$; select 'drop'").write);
    try std.testing.expect(!classify("select 1 -- ;drop\n").write);
    try std.testing.expect(classify("select mutate_catalog()").write);
    try std.testing.expect(classify("select mutate_catalog /* query */ ()").write);
    try std.testing.expect(classify("select \"mutate_catalog\"()").write);
    try std.testing.expect(classify("select 1 into new_table").write);
    try std.testing.expect(!classify("select pg_catalog.format_type(a.atttypid, a.atttypmod), current_database()").write);
    try std.testing.expect(!classify("rollback to savepoint test").ends);
}
