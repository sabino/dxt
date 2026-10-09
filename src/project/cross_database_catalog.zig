//! Secret-free observed boundaries and append-preserved run evidence. Statistics
//! describe prior bounded reductions, never an unobserved source-table scan.
const std = @import("std");
const cross = @import("cross_database.zig");
const run = @import("cross_database_run.zig");
const read = @import("cross_database_read.zig");
const adapter = @import("adapter.zig");

pub const Statistic = struct {
    logical_id: []const u8,
    connection: []const u8,
    binding_hash: []const u8,
    query_hash: []const u8,
    observed_epoch: u64,
    data_as_of_epoch: u64,
    expires_epoch: u64,
    rows: u64,
    bytes: u64,
    schema_hash: []const u8,
    columns: []const read.Column,
    sensitivity: []const u8,
    source_adapter: []const u8,
    source_version: []const u8,
    run_id: []const u8,
    confidence: []const u8 = "observed_previous_run",
};
pub const ConnectionInfo = struct {
    name: []const u8,
    adapter: []const u8,
    role: []const u8,
    trust_domain: []const u8,
    allowed_destinations: []const []const u8,
    binding_hash: []const u8,
    version: ?[]const u8 = null,
    capabilities: ?adapter.Capabilities = null,
};
pub const ModelInfo = struct {
    name: []const u8,
    definition_hash: []const u8,
    destination: []const u8,
    schema: []const u8,
    identifier: []const u8,
    materialized: []const u8,
    inputs: []const []const u8,
    run_id: []const u8,
};
pub const Task = struct {
    model: []const u8,
    status: []const u8,
    strategy: []const u8,
    rows_moved: u64,
    bytes_moved: u64,
    output_rows: u64,
    egress_cost: f64,
    estimated_rows: u64,
    estimated_bytes: u64,
    estimated_cost: f64,
    error_name: ?[]const u8,
};
pub const Run = struct {
    run_id: []const u8,
    plan_hash: []const u8,
    definition_hash: []const u8,
    finished_epoch: u64,
    tasks: []const Task,
};
pub const Lineage = struct {
    model: []const u8,
    logical_id: []const u8,
    connection: []const u8,
    stage_connection: ?[]const u8,
    destination: []const u8,
    sensitivity: []const u8,
};
pub const Catalog = struct {
    schema_version: u32 = 1,
    generation: u64 = 0,
    connections: []const ConnectionInfo = &.{},
    models: []const ModelInfo = &.{},
    relation_stats: []const Statistic = &.{},
    runs: []const Run = &.{},
    lineage_edges: []const Lineage = &.{},
};
pub const Store = struct {
    arena: *std.heap.ArenaAllocator,
    owner: std.mem.Allocator,
    value: Catalog,
    pub fn deinit(self: *Store) void {
        self.arena.deinit();
        self.owner.destroy(self.arena);
        self.* = undefined;
    }
};

pub fn load(runtime: cross.Runtime, root: []const u8) !Store {
    const arena = try runtime.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(runtime.allocator);
    errdefer {
        arena.deinit();
        runtime.allocator.destroy(arena);
    }
    const allocator = arena.allocator();
    const path = try std.fs.path.join(allocator, &.{ root, ".dxt", "cross-catalog.json" });
    const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, allocator, .limited(16 * 1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return .{ .arena = arena, .owner = runtime.allocator, .value = .{} };
        return err;
    };
    const parsed = std.json.parseFromSlice(Catalog, allocator, text, .{ .allocate = .alloc_always }) catch return error.InvalidCrossDatabaseCatalog;
    if (parsed.value.schema_version != 1 or parsed.value.relation_stats.len > 4096 or parsed.value.runs.len > 128) return error.InvalidCrossDatabaseCatalog;
    return .{ .arena = arena, .owner = runtime.allocator, .value = parsed.value };
}

pub fn bindingHash(allocator: std.mem.Allocator, connection: cross.Connection) ![]const u8 {
    const identity = try std.json.Stringify.valueAlloc(allocator, .{ connection.adapter_type, connection.identity.database_path, connection.identity.database_path_base, connection.identity.connection_info }, .{});
    defer allocator.free(identity);
    return cross.digest(allocator, identity);
}

pub fn match(store: *const Store, connection: []const u8, logical_id: []const u8, binding_hash: []const u8, query_hash: []const u8, now: u64, max_age: u64) ?Statistic {
    for (store.value.relation_stats) |stat| {
        if (!std.mem.eql(u8, stat.connection, connection) or !std.mem.eql(u8, stat.logical_id, logical_id) or !std.mem.eql(u8, stat.binding_hash, binding_hash) or !std.mem.eql(u8, stat.query_hash, query_hash)) continue;
        if (stat.observed_epoch > now or now >= stat.expires_epoch or now - stat.observed_epoch > max_age) continue;
        return stat;
    }
    return null;
}

pub fn epoch(io: std.Io) u64 {
    return @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
}

pub fn version(allocator: std.mem.Allocator, session: *adapter.Session) ![]const u8 {
    return switch (session.*) {
        .duckdb => |*connection| blk: {
            const get = connection.pool.library.?.dyn.lookup(*const fn () callconv(.c) [*:0]const u8, "duckdb_library_version") orelse return error.NativeDuckDbAbiMismatch;
            break :blk allocator.dupe(u8, std.mem.span(get()));
        },
        .postgres => |*connection| blk: {
            const get = connection.library.lookup(*const fn (?*anyopaque) callconv(.c) c_int, "PQserverVersion") orelse return error.NativePostgresAbiMismatch;
            const value = get(connection.handle);
            break :blk std.fmt.allocPrint(allocator, "{d}.{d}", .{ @divTrunc(value, 10000), @mod(value, 10000) });
        },
    };
}

pub fn record(runtime: cross.Runtime, root: []const u8, plan: *const cross.Plan, run_id: []const u8, records: []const run.Record) !void {
    var scratch = std.heap.ArenaAllocator.init(runtime.allocator);
    defer scratch.deinit();
    const rt: cross.Runtime = .{ .allocator = scratch.allocator(), .io = runtime.io, .environment = runtime.environment };
    const allocator = rt.allocator;
    const directory = try std.fs.path.join(allocator, &.{ root, ".dxt" });
    try std.Io.Dir.cwd().createDirPath(runtime.io, directory);
    const lock_path = try std.fs.path.join(allocator, &.{ directory, "cross-catalog.lock" });
    const lock = try std.Io.Dir.cwd().createFile(runtime.io, lock_path, .{ .truncate = false, .lock = .exclusive });
    defer lock.close(runtime.io);
    var store = try load(rt, root);
    defer store.deinit();
    var stats: std.ArrayList(Statistic) = .empty;
    try stats.appendSlice(allocator, store.value.relation_stats);
    var models: std.ArrayList(ModelInfo) = .empty;
    for (store.value.models) |previous| {
        var selected = false;
        for (plan.models) |model| if (std.mem.eql(u8, model.name, previous.name)) {
            selected = true;
        };
        if (!selected) try models.append(allocator, previous);
    }
    var lineage: std.ArrayList(Lineage) = .empty;
    for (store.value.lineage_edges) |previous| {
        var selected = false;
        for (plan.models) |model| if (std.mem.eql(u8, model.name, previous.model)) {
            selected = true;
        };
        if (!selected) try lineage.append(allocator, previous);
    }
    const tasks = try allocator.alloc(Task, records.len);
    const now = epoch(runtime.io);
    for (plan.models, records, tasks) |model, completed, *task| {
        task.* = .{ .model = model.name, .status = completed.status, .strategy = model.strategy, .rows_moved = completed.rows_moved, .bytes_moved = completed.bytes_moved, .output_rows = completed.output_rows, .egress_cost = completed.egress_cost, .estimated_rows = model.estimated_rows, .estimated_bytes = model.estimated_bytes, .estimated_cost = model.estimated_cost, .error_name = completed.error_name };
        const input_ids = try allocator.alloc([]const u8, model.inputs.len);
        for (model.inputs, input_ids) |input, *id| {
            id.* = input.logical_id;
            try lineage.append(allocator, .{ .model = model.name, .logical_id = input.logical_id, .connection = plan.connections[input.connection].name, .stage_connection = if (input.stage_connection) |index| plan.connections[index].name else null, .destination = plan.connections[model.destination].name, .sensitivity = input.sensitivity });
        }
        try models.append(allocator, .{ .name = model.name, .definition_hash = plan.definition_hash, .destination = plan.connections[model.destination].name, .schema = model.schema, .identifier = model.identifier, .materialized = model.materialized, .inputs = input_ids, .run_id = run_id });
        for (completed.stage_artifacts) |observed| {
            for (model.inputs) |input| {
                if (!std.mem.eql(u8, input.name, observed.input) or !std.mem.eql(u8, input.query_hash, observed.query_hash)) continue;
                const connection = plan.connections[input.connection];
                const hash = try bindingHash(allocator, connection);
                const schema = try std.json.Stringify.valueAlloc(allocator, observed.source_columns, .{});
                const stat: Statistic = .{ .logical_id = input.logical_id, .connection = connection.name, .binding_hash = hash, .query_hash = observed.query_hash, .observed_epoch = now, .data_as_of_epoch = observed.data_as_of_epoch, .expires_epoch = observed.retention_until_epoch orelse now +| 86400, .rows = observed.rows, .bytes = observed.bytes, .schema_hash = try cross.digest(allocator, schema), .columns = observed.source_columns, .sensitivity = observed.sensitivity, .source_adapter = observed.source_adapter, .source_version = observed.source_version, .run_id = run_id };
                var found = false;
                for (stats.items) |*old| if (std.mem.eql(u8, old.logical_id, stat.logical_id) and std.mem.eql(u8, old.connection, stat.connection) and std.mem.eql(u8, old.binding_hash, stat.binding_hash) and std.mem.eql(u8, old.query_hash, stat.query_hash)) {
                    old.* = stat;
                    found = true;
                    break;
                };
                if (!found) {
                    if (stats.items.len == 4096) return error.CrossDatabaseCatalogObjectBudgetExceeded;
                    try stats.append(allocator, stat);
                }
            }
        }
    }
    var runs: std.ArrayList(Run) = .empty;
    for (store.value.runs) |previous| if (!std.mem.eql(u8, previous.run_id, run_id)) try runs.append(allocator, previous);
    if (runs.items.len >= 128) _ = runs.orderedRemove(0);
    try runs.append(allocator, .{ .run_id = run_id, .plan_hash = plan.hash, .definition_hash = plan.definition_hash, .finished_epoch = now, .tasks = tasks });
    const connections = try allocator.alloc(ConnectionInfo, plan.connections.len);
    for (connections, plan.connections, 0..) |*info, connection, index| {
        info.* = .{ .name = connection.name, .adapter = connection.adapter_type, .role = connection.role, .trust_domain = connection.trust_domain, .allowed_destinations = connection.allowed_destinations, .binding_hash = try bindingHash(allocator, connection) };
        for (store.value.connections) |previous| if (std.mem.eql(u8, previous.name, info.name) and std.mem.eql(u8, previous.binding_hash, info.binding_hash)) {
            info.version = previous.version;
            info.capabilities = previous.capabilities;
        };
        for (plan.models, records) |model, completed| {
            if (model.destination == index and completed.destination_version != null) {
                info.version = completed.destination_version;
                info.capabilities = completed.destination_capabilities;
            }
            for (completed.stage_artifacts) |observed| for (model.inputs) |input| if (input.connection == index and std.mem.eql(u8, input.name, observed.input)) {
                info.version = observed.source_version;
                info.capabilities = observed.source_capabilities;
            };
        }
    }
    const next: Catalog = .{ .generation = store.value.generation +| 1, .connections = connections, .models = models.items, .relation_stats = stats.items, .runs = runs.items, .lineage_edges = lineage.items };
    const json = try std.json.Stringify.valueAlloc(allocator, next, .{});
    if (json.len > 16 * 1024 * 1024) return error.CrossDatabaseCatalogSizeBudgetExceeded;
    try cross.writeAtomic(rt, try std.fs.path.join(allocator, &.{ directory, "cross-catalog.json" }), json);
}

test "observed catalog estimates require an unchanged fresh physical boundary" {
    const stat: Statistic = .{ .logical_id = "source.p.orders", .connection = "warehouse", .binding_hash = "bound", .query_hash = "query", .observed_epoch = 100, .data_as_of_epoch = 95, .expires_epoch = 200, .rows = 7, .bytes = 80, .schema_hash = "schema", .columns = &.{}, .sensitivity = "public", .source_adapter = "duckdb", .source_version = "v1.4.2", .run_id = "run" };
    const store: Store = .{ .arena = undefined, .owner = std.testing.allocator, .value = .{ .relation_stats = &.{stat} } };
    try std.testing.expectEqual(@as(u64, 7), match(&store, "warehouse", "source.p.orders", "bound", "query", 110, 60).?.rows);
    try std.testing.expect(match(&store, "warehouse", "source.p.orders", "other", "query", 110, 60) == null);
    try std.testing.expect(match(&store, "warehouse", "source.p.orders", "bound", "query", 201, 60) == null);
    try std.testing.expect(match(&store, "warehouse", "source.p.orders", "bound", "query", 150, 10) == null);
}
