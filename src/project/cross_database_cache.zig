//! Typed retained stages with explicit freshness/version policy. Payload and
//! manifest become ready in one native DuckDB transaction; hashes detect drift.
const std = @import("std");
const cross = @import("cross_database.zig");
const run = @import("cross_database_run.zig");
const read = @import("cross_database_read.zig");
const adapter = @import("adapter.zig");
const locks = @import("cross_database_lock.zig");

pub const Manifest = struct {
    key: []const u8,
    dataset: []const u8,
    logical_id: []const u8,
    source_connection: []const u8,
    stage_connection: []const u8,
    source_binding_hash: []const u8,
    query_hash: []const u8,
    mode: []const u8,
    version: ?[]const u8,
    sensitivity: []const u8,
    created_epoch: u64,
    expires_epoch: u64,
    rows: u64,
    bytes: u64,
    checksum: []const u8,
    schema_hash: []const u8,
    columns: []read.Column,
    created_by_run: []const u8 = "",
};

pub const Observation = struct {
    input: []const u8,
    logical_id: []const u8,
    location: []const u8,
    mode: []const u8,
    cache_hit: bool,
    query_hash: []const u8,
    rows: u64,
    bytes: u64,
    checksum: []const u8,
    sensitivity: []const u8,
    retention_until_epoch: ?u64,
    columns: []read.Column,
    source_columns: []read.Column,
    readiness: []const u8 = "ready",
    cleanup: []const u8 = "session scoped",
};

pub const Source = struct {
    arena: *std.heap.ArenaAllocator,
    owner: std.mem.Allocator,
    session: adapter.Session,
    lock: locks.Lock,
    query: []const u8,
    manifest: Manifest,
    hit: bool,

    pub fn deinit(self: *Source) void {
        self.session.deinit();
        self.lock.deinit();
        self.arena.deinit();
        self.owner.destroy(self.arena);
        self.* = undefined;
    }

    pub fn validate(self: *const Source, columns: []const read.Column, rows: u64, hash: []const u8) !void {
        if (rows != self.manifest.rows or !std.mem.eql(u8, hash, self.manifest.checksum)) return error.CrossDatabaseStageChecksumMismatch;
        if (columns.len != self.manifest.columns.len) return error.CrossDatabaseStageSchemaMismatch;
        for (columns, self.manifest.columns) |observed, expected| if (!std.mem.eql(u8, observed.name, expected.name) or observed.kind != expected.kind or !std.mem.eql(u8, observed.type_sql, expected.type_sql)) return error.CrossDatabaseStageSchemaMismatch;
        const observed_json = try std.json.Stringify.valueAlloc(self.arena.allocator(), columns, .{});
        const observed_hash = try cross.digest(self.arena.allocator(), observed_json);
        if (!std.mem.eql(u8, observed_hash, self.manifest.schema_hash)) return error.CrossDatabaseStageSchemaMismatch;
    }
};

pub fn source(runtime: cross.Runtime, root: []const u8, plan: *cross.Plan, model: cross.Model, input: cross.Input, record: *run.Record, spill: []const u8) !Source {
    const arena = try runtime.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(runtime.allocator);
    errdefer {
        arena.deinit();
        runtime.allocator.destroy(arena);
    }
    const allocator = arena.allocator();
    const retained = plan.connections[input.stage_connection.?];
    const origin = plan.connections[input.connection];
    const identity = try std.json.Stringify.valueAlloc(allocator, .{ origin.adapter_type, origin.identity.database_path, origin.identity.database_path_base, origin.identity.connection_info }, .{});
    const binding_hash = try cross.digest(allocator, identity);
    const query_hash = try cross.digest(allocator, input.query);
    var watermark: []const u8 = "";
    for (record.source_watermarks) |progress| if (std.mem.eql(u8, progress.input, input.name)) {
        watermark = progress.value orelse "";
    };
    const fingerprint = try std.json.Stringify.valueAlloc(allocator, .{ binding_hash, query_hash, input.logical_id, input.stage_mode, input.stage_version, watermark, input.sensitivity, origin.trust_domain, retained.trust_domain }, .{});
    const key = try cross.digest(allocator, fingerprint);
    const dataset = try std.fmt.allocPrint(allocator, "p_{s}", .{key});
    const lock_key = if (std.mem.eql(u8, input.stage_mode, "snapshot")) try cross.digest(allocator, try std.json.Stringify.valueAlloc(allocator, .{ input.logical_id, input.stage_version }, .{})) else key;
    var target_lock = try locks.acquire(runtime, root, retained, "dxt_stage", lock_key);
    errdefer target_lock.deinit();
    var cache = try run.open(runtime, root, retained);
    errdefer cache.deinit();
    try run.configure(runtime, &cache, model.budget, spill);
    try cache.execute("set threads=1; create schema if not exists dxt_stage; create table if not exists dxt_stage.catalog (key text primary key,mode text,created_epoch bigint,expires_epoch bigint,status text,manifest_json text)");
    if (std.mem.eql(u8, input.stage_mode, "snapshot")) {
        var snapshots = try cache.query("select manifest_json from dxt_stage.catalog where mode='snapshot'");
        defer snapshots.deinit(runtime.allocator);
        for (snapshots.rows) |row| {
            const prior = std.json.parseFromSlice(Manifest, allocator, row[0] orelse return error.InvalidCrossDatabaseStageManifest, .{}) catch return error.InvalidCrossDatabaseStageManifest;
            defer prior.deinit();
            if (std.mem.eql(u8, prior.value.logical_id, input.logical_id) and std.mem.eql(u8, prior.value.version orelse "", input.stage_version orelse "") and !std.mem.eql(u8, prior.value.key, key)) return error.CrossDatabaseSnapshotDefinitionChangedRequireNewVersion;
        }
    }
    const key_literal = try adapter.quoteLiteral(allocator, key);
    const lookup = try std.fmt.allocPrint(allocator, "select status,manifest_json,created_epoch,expires_epoch from dxt_stage.catalog where key={s}", .{key_literal});
    var previous = try cache.query(lookup);
    defer previous.deinit(runtime.allocator);
    const now = epoch(runtime.io);
    if (previous.rows.len != 0) {
        const parsed = std.json.parseFromSlice(Manifest, allocator, previous.rows[0][1] orelse return error.InvalidCrossDatabaseStageManifest, .{ .allocate = .alloc_always }) catch return error.InvalidCrossDatabaseStageManifest;
        defer parsed.deinit();
        const manifest = parsed.value;
        if (!std.mem.eql(u8, manifest.key, key) or !std.mem.eql(u8, manifest.dataset, dataset) or !std.mem.eql(u8, manifest.source_binding_hash, binding_hash) or !std.mem.eql(u8, manifest.query_hash, query_hash) or !std.mem.eql(u8, manifest.logical_id, input.logical_id)) return error.InvalidCrossDatabaseStageManifest;
        if (manifest.created_epoch != try std.fmt.parseUnsigned(u64, previous.rows[0][2] orelse "", 10) or manifest.expires_epoch != try std.fmt.parseUnsigned(u64, previous.rows[0][3] orelse "", 10) or !std.mem.eql(u8, manifest.mode, input.stage_mode) or !std.mem.eql(u8, manifest.version orelse "", input.stage_version orelse "") or !std.mem.eql(u8, manifest.sensitivity, input.sensitivity)) return error.InvalidCrossDatabaseStageManifest;
        const ready = std.mem.eql(u8, previous.rows[0][0] orelse "", "ready");
        const expiration = @min(manifest.expires_epoch, std.math.add(u64, manifest.created_epoch, input.stage_ttl_seconds) catch return error.InvalidCrossDatabaseStageFreshness);
        if (std.mem.eql(u8, input.stage_mode, "snapshot") and (!ready or now >= expiration)) return error.CrossDatabaseSnapshotExpiredRequireNewVersion;
        if (ready and now < expiration) {
            if (!try cache.relationExists(runtime.allocator, "dxt_stage", dataset)) return error.CrossDatabaseStagePayloadMissing;
            var owned = try cloneManifest(allocator, manifest);
            owned.expires_epoch = expiration;
            return .{ .arena = arena, .owner = runtime.allocator, .session = cache, .lock = target_lock, .query = try std.fmt.allocPrint(allocator, "select * from dxt_stage.\"{s}\"", .{dataset}), .manifest = owned, .hit = true };
        }
    }
    var existing = try cache.query("select count(*) from dxt_stage.catalog where status='ready'");
    defer existing.deinit(runtime.allocator);
    const objects = try std.fmt.parseUnsigned(u64, existing.firstScalar() orelse "0", 10);
    if (objects +| 4 > model.budget.max_objects) return error.CrossDatabaseObjectBudgetExceeded;
    var origin_session = try run.open(runtime, root, origin);
    defer origin_session.deinit();
    try run.configure(runtime, &origin_session, model.budget, spill);
    var timer = run.Timer.init(runtime, &origin_session, model.budget.max_query_seconds);
    try timer.start();
    defer timer.deinit();
    var reader = try read.Reader.open(runtime.allocator, &origin_session, input.query, .{ .max_rows = model.budget.max_rows -| record.rows_moved, .max_bytes = model.budget.max_bytes -| record.bytes_moved, .max_memory_bytes = model.budget.max_memory_bytes }, model.budget.max_query_seconds);
    defer {
        timer.deinit();
        record.rows_moved +|= reader.guard.rows;
        record.bytes_moved +|= reader.guard.bytes;
        record.egress_cost += @as(f64, @floatFromInt(reader.guard.bytes)) / (1024 * 1024 * 1024) * origin.egress_per_gib;
        reader.deinit();
    }
    try cache.begin();
    var transaction = true;
    defer if (transaction) cache.rollback() catch {};
    const relation = try std.fmt.allocPrint(allocator, "dxt_stage.\"{s}\"", .{dataset});
    const drop = try std.fmt.allocPrint(allocator, "drop table if exists {s}", .{relation});
    try cache.execute(drop);
    try run.createTypedTable(runtime.allocator, &cache, relation, reader.columns, false);
    const shapes = try allocator.alloc(run.DecimalShape, reader.columns.len);
    @memset(shapes, .{});
    var hash: RowHash = .{};
    while (try reader.next()) |result| {
        var batch = result;
        defer batch.deinit(runtime.allocator);
        if (timer.expired.load(.acquire)) return error.CrossDatabaseTimeBudgetExceeded;
        if (model.budget.max_cost) |cost| if (record.egress_cost + @as(f64, @floatFromInt(reader.guard.bytes)) / (1024 * 1024 * 1024) * origin.egress_per_gib > cost) return error.CrossDatabaseCostBudgetExceeded;
        try hash.batch(runtime.allocator, &batch, origin.adapter_type);
        for (reader.columns, shapes, 0..) |column, *shape, c| if (std.mem.eql(u8, column.type_sql, "numeric")) {
            for (batch.rows) |row| if (row[c]) |text| try shape.observe(text);
        };
        try run.loadBatchSql(runtime.allocator, &cache, relation, &batch, origin.adapter_type);
    }
    try run.finishDecimalsSql(runtime.allocator, &cache, relation, reader.columns, shapes);
    const columns = try allocator.dupe(read.Column, reader.columns);
    for (columns, shapes) |*column, shape| {
        column.name = try allocator.dupe(u8, column.name);
        column.type_sql = if (std.mem.eql(u8, column.type_sql, "numeric")) try std.fmt.allocPrint(allocator, "decimal({d},{d})", .{ @max(1, shape.integer_digits + shape.scale), shape.scale }) else try allocator.dupe(u8, column.type_sql);
    }
    const schema = try std.json.Stringify.valueAlloc(allocator, columns, .{});
    const manifest: Manifest = .{ .key = key, .dataset = dataset, .logical_id = input.logical_id, .source_connection = origin.name, .stage_connection = retained.name, .source_binding_hash = binding_hash, .query_hash = query_hash, .mode = input.stage_mode, .version = input.stage_version, .sensitivity = input.sensitivity, .created_epoch = now, .expires_epoch = std.math.add(u64, now, input.stage_ttl_seconds) catch return error.InvalidCrossDatabaseStageFreshness, .rows = reader.guard.rows, .bytes = reader.guard.bytes, .checksum = try allocator.dupe(u8, &hash.finish()), .schema_hash = try cross.digest(allocator, schema), .columns = columns, .created_by_run = record.run_id };
    const json = try std.json.Stringify.valueAlloc(allocator, manifest, .{});
    const clear = try std.fmt.allocPrint(allocator, "delete from dxt_stage.catalog where key={s}", .{key_literal});
    try cache.execute(clear);
    const insert = try std.fmt.allocPrint(allocator, "insert into dxt_stage.catalog values({s},{s},{d},{d},'ready',{s})", .{ key_literal, try adapter.quoteLiteral(allocator, input.stage_mode), now, manifest.expires_epoch, try adapter.quoteLiteral(allocator, json) });
    try cache.execute(insert);
    try cache.commit();
    transaction = false;
    return .{ .arena = arena, .owner = runtime.allocator, .session = cache, .lock = target_lock, .query = try std.fmt.allocPrint(allocator, "select * from {s}", .{relation}), .manifest = manifest, .hit = false };
}

fn cloneManifest(allocator: std.mem.Allocator, value: Manifest) !Manifest {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    const parsed = try std.json.parseFromSlice(Manifest, allocator, json, .{ .allocate = .alloc_always });
    // The arena owns all allocations until Source.deinit.
    return parsed.value;
}

pub const RowHash = struct {
    state: std.crypto.hash.sha2.Sha256 = .init(.{}),
    pub fn batch(self: *RowHash, allocator: std.mem.Allocator, result: *const adapter.QueryResult, source_adapter: []const u8) !void {
        for (result.rows) |row| {
            self.state.update("row");
            for (row, result.columns) |cell, column| {
                self.state.update(&.{@intCast(@intFromEnum(column.kind))});
                if (cell) |text| {
                    const canonical = try canonicalValue(allocator, text, column.kind, source_adapter);
                    defer allocator.free(canonical);
                    const length: u64 = canonical.len;
                    var length_bytes: [8]u8 = undefined;
                    std.mem.writeInt(u64, &length_bytes, length, .little);
                    self.state.update("value");
                    self.state.update(&length_bytes);
                    self.state.update(canonical);
                } else self.state.update("null");
            }
        }
    }
    pub fn finish(self: *RowHash) [64]u8 {
        var output: [32]u8 = undefined;
        self.state.final(&output);
        return std.fmt.bytesToHex(output, .lower);
    }
};

fn canonicalValue(allocator: std.mem.Allocator, text: []const u8, kind: adapter.Kind, source_adapter: []const u8) ![]const u8 {
    if (kind == .binary) return run.binaryHex(allocator, text, source_adapter);
    if (kind == .boolean) return allocator.dupe(u8, if (std.mem.eql(u8, text, "t") or std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1")) "true" else "false");
    if (kind == .floating) {
        const value = if (std.ascii.eqlIgnoreCase(text, "infinity")) std.math.inf(f64) else if (std.ascii.eqlIgnoreCase(text, "-infinity")) -std.math.inf(f64) else std.fmt.parseFloat(f64, text) catch return error.UnsupportedCrossDatabaseType;
        if (!std.math.isFinite(value)) return allocator.dupe(u8, if (std.math.isNan(value)) "nan" else if (value < 0) "-inf" else "inf");
        return std.json.Stringify.valueAlloc(allocator, value, .{});
    }
    if (kind == .decimal or kind == .integer) {
        const negative = text.len != 0 and text[0] == '-';
        const unsigned = if (text.len != 0 and (text[0] == '-' or text[0] == '+')) text[1..] else text;
        const dot = std.mem.indexOfScalar(u8, unsigned, '.') orelse unsigned.len;
        var first: usize = 0;
        while (first < dot and unsigned[first] == '0') first += 1;
        var end = unsigned.len;
        if (dot < end) {
            while (end > dot + 1 and unsigned[end - 1] == '0') end -= 1;
            if (end == dot + 1) end = dot;
        }
        const integer = if (first == dot) "0" else unsigned[first..dot];
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ if (negative and (!std.mem.eql(u8, integer, "0") or end > dot)) "-" else "", integer, if (end > dot) unsigned[dot..end] else "" });
    }
    if (kind == .time or kind == .timestamp) {
        const dot = std.mem.indexOfScalar(u8, text, '.') orelse return allocator.dupe(u8, text);
        var fraction_end = dot + 1;
        while (fraction_end < text.len and std.ascii.isDigit(text[fraction_end])) fraction_end += 1;
        var significant = fraction_end;
        while (significant > dot + 1 and text[significant - 1] == '0') significant -= 1;
        if (significant == dot + 1) significant = dot;
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ text[0..significant], text[fraction_end..] });
    }
    return allocator.dupe(u8, text);
}

pub fn cleanup(runtime: cross.Runtime, arena_runtime: cross.Runtime, root: []const u8, options: cross.Options, plan: *cross.Plan, stdout: *std.Io.Writer) !void {
    var pool = adapter.DuckDBPool.init(runtime.allocator, runtime.io, runtime.environment);
    defer pool.deinit();
    const rt: cross.Runtime = .{ .allocator = runtime.allocator, .io = runtime.io, .environment = runtime.environment, .duckdb_pool = &pool };
    const selected = try arena_runtime.allocator.alloc(bool, plan.connections.len);
    @memset(selected, false);
    for (plan.connections, 0..) |connection, i| if (std.mem.eql(u8, connection.role, "stage")) {
        selected[i] = true;
    };
    for (plan.models) |model| for (model.inputs) |input| if (input.stage_connection) |index| {
        selected[index] = true;
    };
    var removed: u64 = 0;
    const now = epoch(runtime.io);
    for (plan.connections, selected) |connection, include| {
        if (!include) continue;
        var session = try run.open(rt, root, connection);
        defer session.deinit();
        if (!try session.relationExists(runtime.allocator, "dxt_stage", "catalog")) continue;
        const sql = if (options.older_than_seconds) |age| try std.fmt.allocPrint(arena_runtime.allocator, "select key,manifest_json from dxt_stage.catalog where status='ready' and created_epoch <= {d}", .{now -| age}) else try std.fmt.allocPrint(arena_runtime.allocator, "select key,manifest_json from dxt_stage.catalog where status='ready' and expires_epoch <= {d}", .{now});
        var datasets = try session.query(sql);
        defer datasets.deinit(runtime.allocator);
        for (datasets.rows) |row| {
            const parsed = try std.json.parseFromSlice(Manifest, arena_runtime.allocator, row[1] orelse return error.InvalidCrossDatabaseStageManifest, .{});
            defer parsed.deinit();
            const manifest = parsed.value;
            if (!std.mem.eql(u8, manifest.key, row[0] orelse "")) return error.InvalidCrossDatabaseStageManifest;
            if (manifest.key.len != 64 or manifest.dataset.len != 66 or !std.mem.startsWith(u8, manifest.dataset, "p_") or !std.mem.eql(u8, manifest.dataset[2..], manifest.key)) return error.InvalidCrossDatabaseStageManifest;
            for (manifest.key) |char| if (!std.ascii.isHex(char)) return error.InvalidCrossDatabaseStageManifest;
            const lock_key = if (std.mem.eql(u8, manifest.mode, "snapshot")) try cross.digest(arena_runtime.allocator, try std.json.Stringify.valueAlloc(arena_runtime.allocator, .{ manifest.logical_id, manifest.version }, .{})) else manifest.key;
            var target_lock = locks.acquire(rt, root, connection, "dxt_stage", lock_key) catch |err| {
                if (err == error.CrossDatabaseTargetLocked) continue;
                return err;
            };
            defer target_lock.deinit();
            const quoted = try adapter.quoteIdentifier(arena_runtime.allocator, manifest.dataset);
            const drop = try std.fmt.allocPrint(arena_runtime.allocator, "drop table if exists dxt_stage.{s}", .{quoted});
            try session.begin();
            var transaction = true;
            defer if (transaction) session.rollback() catch {};
            try session.execute(drop);
            const expire = try std.fmt.allocPrint(arena_runtime.allocator, "update dxt_stage.catalog set status='expired' where key={s}", .{try adapter.quoteLiteral(arena_runtime.allocator, manifest.key)});
            try session.execute(expire);
            try session.commit();
            transaction = false;
            removed += 1;
        }
    }
    try stdout.print("Cleaned {d} retained stages; snapshot version tombstones retained\n", .{removed});
}

pub fn observation(allocator: std.mem.Allocator, value: Observation) !Observation {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    const parsed = try std.json.parseFromSlice(Observation, allocator, json, .{ .allocate = .alloc_always });
    return parsed.value;
}

fn epoch(io: std.Io) u64 {
    return @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

test "retained stage checksum normalizes exact decimals and binary across adapters" {
    const allocator = std.testing.allocator;
    const number = try canonicalValue(allocator, "-0002.0100", .decimal, "postgres");
    defer allocator.free(number);
    try std.testing.expectEqualStrings("-2.01", number);
    const zero = try canonicalValue(allocator, "-0.0000", .decimal, "duckdb");
    defer allocator.free(zero);
    try std.testing.expectEqualStrings("0", zero);
    const binary = try canonicalValue(allocator, "\\x00ff275c", .binary, "postgres");
    defer allocator.free(binary);
    try std.testing.expectEqualStrings("00ff275c", binary);
}
