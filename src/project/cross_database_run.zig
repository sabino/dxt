const std = @import("std");
const types = @import("types.zig");
const adapter = @import("adapter.zig");
const cross = @import("cross_database.zig");
const read = @import("cross_database_read.zig");
const invocation = @import("invocation.zig");
const Runtime = types.Runtime;
const Dir = std.Io.Dir;

pub const Record = struct {
    model: []const u8,
    status: []const u8 = "pending",
    rows_moved: u64 = 0,
    bytes_moved: u64 = 0,
    output_rows: u64 = 0,
    egress_cost: f64 = 0,
    stages: []const []const u8 = &.{},
    cleanup: []const u8 = "pending",
    error_name: ?[]const u8 = null,
    affected_keys: u64 = 0,
    source_watermarks: []const @import("cross_database_incremental.zig").Watermark = &.{},
    watermarks_committed: bool = false,
    run_id: []const u8 = "",
    destination_version: ?[]const u8 = null,
    destination_capabilities: ?adapter.Capabilities = null,
    stage_artifacts: []const @import("cross_database_cache.zig").Observation = &.{},
};

pub fn execute(runtime: Runtime, arena_runtime: Runtime, root: []const u8, plan: *cross.Plan, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var metadata = invocation.Metadata.init(runtime.io, runtime.environment);
    const run_id = &metadata.id;
    const directory = try runDirectory(arena_runtime, root, run_id);
    const path = try std.fs.path.join(arena_runtime.allocator, &.{ directory, "state.json" });
    const records = try arena_runtime.allocator.alloc(Record, plan.models.len);
    for (records, plan.models) |*record, model| record.* = .{ .model = model.name, .run_id = run_id };
    try writeState(arena_runtime, path, run_id, plan.hash, plan.definition_hash, records);
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var pool = adapter.DuckDBPool.init(allocator, runtime.io, runtime.environment);
    defer pool.deinit();
    var failed = false;
    for (plan.models, records) |model, *record| {
        record.status = "running";
        const names = try arena_runtime.allocator.alloc([]const u8, model.inputs.len);
        for (model.inputs, 0..) |input, index| names[index] = try std.fmt.allocPrint(arena_runtime.allocator, "__dxt_{s}_{s}", .{ run_id[0..8], input.name });
        record.stages = names;
        try writeState(arena_runtime, path, run_id, plan.hash, plan.definition_hash, records);
        executeModel(.{ .allocator = allocator, .io = runtime.io, .environment = runtime.environment, .duckdb_pool = &pool }, arena_runtime, root, directory, run_id, plan, model, record) catch |err| {
            record.status = "error";
            record.error_name = @errorName(err);
            record.cleanup = "complete";
            failed = true;
            try stderr.print("error: cross-database model {s}: {s}; destination rolled back and temporary stages disconnected\n", .{ model.name, @errorName(err) });
        };
        try writeState(arena_runtime, path, run_id, plan.hash, plan.definition_hash, records);
        try stdout.print("{s}: {s}; moved {d} rows / {d} bytes; run {s}\n", .{ model.name, record.status, record.rows_moved, record.bytes_moved, run_id });
    }
    const spill = try std.fs.path.join(arena_runtime.allocator, &.{ directory, "spill" });
    Dir.cwd().deleteTree(runtime.io, spill) catch |err| {
        for (records) |*record| record.cleanup = "incomplete";
        try writeState(arena_runtime, path, run_id, plan.hash, plan.definition_hash, records);
        return err;
    };
    try @import("cross_database_catalog.zig").record(runtime, root, plan, run_id, records);
    if (failed) return error.CrossDatabaseExecutionFailed;
}

fn executeModel(runtime: Runtime, arena_runtime: Runtime, root: []const u8, directory: []const u8, run_id: []const u8, plan: *cross.Plan, model: cross.Model, record: *Record) !void {
    const allocator = runtime.allocator;
    var target_lock = try @import("cross_database_lock.zig").acquire(runtime, root, plan.connections[model.destination], model.schema, model.identifier);
    defer target_lock.deinit();
    var destination = try open(runtime, root, plan.connections[model.destination]);
    defer destination.deinit();
    record.destination_version = try @import("cross_database_catalog.zig").version(arena_runtime.allocator, &destination);
    record.destination_capabilities = destination.capabilities();
    var embedded: ?adapter.Session = null;
    defer if (embedded) |*session| session.deinit();
    var workspace = &destination;
    if (model.execution_connection != model.destination) {
        embedded = try open(runtime, root, plan.connections[model.execution_connection]);
        workspace = &embedded.?;
    }
    const spill_path = try std.fs.path.join(allocator, &.{ directory, "spill" });
    defer allocator.free(spill_path);
    try configure(runtime, &destination, model.budget, spill_path);
    if (workspace != &destination) try configure(runtime, workspace, model.budget, spill_path);
    try destination.begin();
    var transaction = true;
    defer if (transaction) destination.rollback() catch {};
    try @import("cross_database_lock.zig").acquireDatabase(allocator, &destination, model.schema, model.identifier);
    var incremental: ?@import("cross_database_incremental.zig").State = null;
    defer if (incremental) |*state| state.deinit();
    var physical = model;
    if (std.mem.eql(u8, model.materialized, "incremental")) {
        incremental = try @import("cross_database_incremental.zig").State.prepare(runtime, root, plan, &destination, model, record, spill_path);
        physical = incremental.?.model;
        record.affected_keys = incremental.?.key_count;
        const progress = try arena_runtime.allocator.dupe(@import("cross_database_incremental.zig").Watermark, incremental.?.watermarks);
        for (progress) |*item| {
            item.input = try arena_runtime.allocator.dupe(u8, item.input);
            item.query_hash = try arena_runtime.allocator.dupe(u8, item.query_hash);
            if (item.value) |value| item.value = try arena_runtime.allocator.dupe(u8, value);
        }
        record.source_watermarks = progress;
    }
    try stageInputs(runtime, arena_runtime.allocator, root, plan, physical, record, workspace, spill_path);
    const query = try cross.renderSql(allocator, physical, record.stages);
    defer allocator.free(query);
    const schema = try adapter.quoteIdentifier(allocator, model.schema);
    defer allocator.free(schema);
    const target = try qualified(allocator, model.schema, model.identifier);
    defer allocator.free(target);
    const temporary_name = try std.fmt.allocPrint(allocator, "__dxt_{s}_output", .{run_id[0..8]});
    defer allocator.free(temporary_name);
    const temporary = try qualified(allocator, model.schema, temporary_name);
    defer allocator.free(temporary);
    const create_schema = try std.fmt.allocPrint(allocator, "create schema if not exists {s}", .{schema});
    defer allocator.free(create_schema);
    try destination.execute(create_schema);
    var timer = Timer.init(runtime, &destination, model.budget.max_query_seconds);
    try timer.start();
    defer timer.deinit();
    if (workspace == &destination) {
        const create = try std.fmt.allocPrint(allocator, "create table {s} as {s}", .{ temporary, query });
        defer allocator.free(create);
        try destination.execute(create);
    } else {
        var output_timer = Timer.init(runtime, workspace, model.budget.max_query_seconds);
        try output_timer.start();
        defer output_timer.deinit();
        var output_reader = try read.Reader.open(allocator, workspace, query, .{ .max_rows = model.budget.max_rows -| record.rows_moved, .max_bytes = model.budget.max_bytes -| record.bytes_moved, .max_memory_bytes = model.budget.max_memory_bytes }, model.budget.max_query_seconds);
        defer {
            output_timer.deinit();
            record.rows_moved +|= output_reader.guard.rows;
            record.bytes_moved +|= output_reader.guard.bytes;
            record.egress_cost += @as(f64, @floatFromInt(output_reader.guard.bytes)) / (1024 * 1024 * 1024) * plan.connections[model.execution_connection].egress_per_gib;
            output_reader.deinit();
        }
        try createTypedTable(allocator, &destination, temporary, output_reader.columns, false);
        while (try output_reader.next()) |result| {
            var batch = result;
            defer batch.deinit(allocator);
            if (output_timer.expired.load(.acquire)) return error.CrossDatabaseTimeBudgetExceeded;
            if (model.budget.max_cost) |cost| if (record.egress_cost + @as(f64, @floatFromInt(output_reader.guard.bytes)) / (1024 * 1024 * 1024) * plan.connections[model.execution_connection].egress_per_gib > cost) return error.CrossDatabaseCostBudgetExceeded;
            try loadBatchSql(allocator, &destination, temporary, &batch, "duckdb");
        }
    }
    if (timer.expired.load(.acquire)) return error.CrossDatabaseTimeBudgetExceeded;
    const count_sql = try std.fmt.allocPrint(allocator, "select count(*) from {s}", .{temporary});
    defer allocator.free(count_sql);
    var count = try destination.query(count_sql);
    defer count.deinit(allocator);
    record.output_rows = try std.fmt.parseUnsigned(u64, count.firstScalar() orelse return error.CrossDatabaseOutputValidationFailed, 10);
    const updated = if (incremental) |*state| try state.apply(runtime, &destination, temporary, target) else false;
    if (!updated) {
        const drop_target = try std.fmt.allocPrint(allocator, "drop table if exists {s}", .{target});
        defer allocator.free(drop_target);
        try destination.execute(drop_target);
        const target_name = try adapter.quoteIdentifier(allocator, model.identifier);
        defer allocator.free(target_name);
        const rename = try std.fmt.allocPrint(allocator, "alter table {s} rename to {s}", .{ temporary, target_name });
        defer allocator.free(rename);
        try destination.execute(rename);
    }
    if (incremental) |*state| {
        try state.commit(&destination, run_id);
        const count_target = try std.fmt.allocPrint(allocator, "select count(*) from {s}", .{target});
        defer allocator.free(count_target);
        var final_count = try destination.query(count_target);
        defer final_count.deinit(allocator);
        record.output_rows = try std.fmt.parseUnsigned(u64, final_count.firstScalar() orelse return error.CrossDatabaseOutputValidationFailed, 10);
    }
    // A destination-local commit marker resolves crashes between database
    // COMMIT and the filesystem run record. It contains no source payload.
    try destination.execute("create schema if not exists dxt_internal; create table if not exists dxt_internal.cross_commits (run_id text, model text, plan_hash text, output_rows bigint, primary key (run_id, model))");
    const id_literal = try adapter.quoteLiteral(allocator, run_id);
    defer allocator.free(id_literal);
    const model_literal = try adapter.quoteLiteral(allocator, model.name);
    defer allocator.free(model_literal);
    const hash_literal = try adapter.quoteLiteral(allocator, plan.hash);
    defer allocator.free(hash_literal);
    const marker = try std.fmt.allocPrint(allocator, "insert into dxt_internal.cross_commits values ({s},{s},{s},{d})", .{ id_literal, model_literal, hash_literal, record.output_rows });
    defer allocator.free(marker);
    try destination.execute(marker);
    for (model.inputs, record.stages) |input, stage| if (input.moved and workspace == &destination) {
        const stage_name = try adapter.quoteIdentifier(allocator, stage);
        defer allocator.free(stage_name);
        const drop = try std.fmt.allocPrint(allocator, "drop table {s}", .{stage_name});
        defer allocator.free(drop);
        try destination.execute(drop);
    };
    timer.deinit();
    if (timer.expired.load(.acquire)) return error.CrossDatabaseTimeBudgetExceeded;
    try destination.commit();
    transaction = false;
    record.status = "success";
    record.cleanup = "complete";
    record.watermarks_committed = incremental != null;
}

fn stageInputs(runtime: Runtime, observation_allocator: std.mem.Allocator, root: []const u8, plan: *cross.Plan, model: cross.Model, record: *Record, workspace: *adapter.Session, spill_path: []const u8) !void {
    const allocator = runtime.allocator;
    const cache = @import("cross_database_cache.zig");
    var observations: std.ArrayList(cache.Observation) = .empty;
    for (model.inputs, 0..) |input, index| {
        if (!input.moved) continue;
        var retained: ?cache.Source = if (input.stage_connection != null) try cache.source(runtime, root, plan, model, input, record, spill_path) else null;
        defer if (retained) |*value| value.deinit();
        var original: ?adapter.Session = null;
        defer if (original) |*value| value.deinit();
        const source = if (retained) |*value| &value.session else blk: {
            original = try open(runtime, root, plan.connections[input.connection]);
            break :blk &original.?;
        };
        const source_connection = plan.connections[input.stage_connection orelse input.connection];
        const source_query = if (retained) |value| value.query else input.query;
        try configure(runtime, source, model.budget, spill_path);
        var timer = Timer.init(runtime, source, model.budget.max_query_seconds);
        try timer.start();
        defer timer.deinit();
        var reader = try read.Reader.open(allocator, source, source_query, .{ .max_rows = model.budget.max_rows -| record.rows_moved, .max_bytes = model.budget.max_bytes -| record.bytes_moved, .max_memory_bytes = model.budget.max_memory_bytes }, model.budget.max_query_seconds);
        defer {
            timer.deinit();
            record.rows_moved +|= reader.guard.rows;
            record.bytes_moved +|= reader.guard.bytes;
            record.egress_cost += @as(f64, @floatFromInt(reader.guard.bytes)) / (1024 * 1024 * 1024) * source_connection.egress_per_gib;
            reader.deinit();
        }
        try createStage(allocator, workspace, record.stages[index], reader.columns);
        const decimal_shapes = try allocator.alloc(DecimalShape, reader.columns.len);
        defer allocator.free(decimal_shapes);
        @memset(decimal_shapes, .{});
        var row_hash: cache.RowHash = .{};
        while (try reader.next()) |result| {
            var batch = result;
            defer batch.deinit(allocator);
            if (timer.expired.load(.acquire)) return error.CrossDatabaseTimeBudgetExceeded;
            if (model.budget.max_cost) |cost| {
                const observed_cost = record.egress_cost + @as(f64, @floatFromInt(reader.guard.bytes)) / (1024 * 1024 * 1024) * source_connection.egress_per_gib;
                if (observed_cost > cost) return error.CrossDatabaseCostBudgetExceeded;
            }
            if (workspace.* == .duckdb) for (reader.columns, decimal_shapes, 0..) |column, *shape, c| {
                if (std.mem.eql(u8, column.type_sql, "numeric")) for (batch.rows) |row| if (row[c]) |text| try shape.observe(text);
            };
            try row_hash.batch(allocator, &batch, source_connection.adapter_type);
            try loadBatch(allocator, workspace, record.stages[index], &batch, source_connection.adapter_type);
        }
        const checksum = row_hash.finish();
        if (retained) |*value| try value.validate(reader.columns, reader.guard.rows, &checksum);
        if (workspace.* == .duckdb) try finishDecimals(allocator, workspace, record.stages[index], reader.columns, decimal_shapes);
        const location = if (retained) |value| try std.fmt.allocPrint(observation_allocator, "{s}.dxt_stage.{s}", .{ source_connection.name, value.manifest.dataset }) else record.stages[index];
        try observations.append(observation_allocator, try cache.observation(observation_allocator, .{ .input = input.name, .logical_id = input.logical_id, .location = location, .mode = input.stage_mode, .cache_hit = if (retained) |value| value.hit else false, .query_hash = if (retained) |value| value.manifest.query_hash else try cross.digest(observation_allocator, input.query), .rows = reader.guard.rows, .bytes = reader.guard.bytes, .checksum = &checksum, .sensitivity = input.sensitivity, .retention_until_epoch = if (retained) |value| value.manifest.expires_epoch else null, .columns = try physicalColumns(observation_allocator, workspace, reader.columns, decimal_shapes), .source_columns = reader.columns, .source_adapter = plan.connections[input.connection].adapter_type, .source_version = if (retained) |value| value.manifest.source_version else try @import("cross_database_catalog.zig").version(observation_allocator, source), .source_capabilities = if (retained) |value| value.manifest.source_capabilities else source.capabilities(), .data_as_of_epoch = if (retained) |value| value.manifest.created_epoch else @import("cross_database_catalog.zig").epoch(runtime.io), .cleanup = if (retained != null) "retained by declared policy" else "session scoped" }));
        record.stage_artifacts = observations.items;
    }
}

/// Read a physical query plan through session-local stages; this path never
/// creates a persistent output or commit marker. Returned rows own their memory.
pub const TypedQueryResult = struct { result: adapter.QueryResult, columns: []read.Column };

pub fn queryPlan(runtime: Runtime, arena_runtime: Runtime, root: []const u8, plan: *cross.Plan) !TypedQueryResult {
    const allocator = runtime.allocator;
    const model = plan.models[0];
    if (model.denied != null) return error.CrossDatabasePolicyDenied;
    var metadata = invocation.Metadata.init(runtime.io, runtime.environment);
    const directory = try runDirectory(arena_runtime, root, &metadata.id);
    const spill = try std.fs.path.join(arena_runtime.allocator, &.{ directory, "spill" });
    defer Dir.cwd().deleteTree(runtime.io, directory) catch {};
    var pool = adapter.DuckDBPool.init(allocator, runtime.io, runtime.environment);
    defer pool.deinit();
    const rt: Runtime = .{ .allocator = allocator, .io = runtime.io, .environment = runtime.environment, .duckdb_pool = &pool };
    var workspace = try open(rt, root, plan.connections[model.execution_connection]);
    defer workspace.deinit();
    try configure(rt, &workspace, model.budget, spill);
    var record: Record = .{ .model = model.name, .run_id = &metadata.id };
    const names = try arena_runtime.allocator.alloc([]const u8, model.inputs.len);
    for (model.inputs, 0..) |input, index| names[index] = try std.fmt.allocPrint(arena_runtime.allocator, "__dxt_{s}_{s}", .{ metadata.id[0..8], input.name });
    record.stages = names;
    try stageInputs(rt, arena_runtime.allocator, root, plan, model, &record, &workspace, spill);
    const sql = try cross.renderSql(allocator, model, names);
    defer allocator.free(sql);
    var timer = Timer.init(rt, &workspace, model.budget.max_query_seconds);
    try timer.start();
    defer timer.deinit();
    var reader = try read.Reader.open(allocator, &workspace, sql, .{ .max_rows = model.budget.max_rows -| record.rows_moved, .max_bytes = model.budget.max_bytes -| record.bytes_moved, .max_memory_bytes = model.budget.max_memory_bytes }, model.budget.max_query_seconds);
    defer {
        timer.deinit();
        reader.deinit();
    }
    var output: adapter.QueryResult = .{ .owner_allocator = allocator };
    errdefer output.deinit(allocator);
    output.columns = try allocator.alloc(adapter.Column, reader.columns.len);
    for (output.columns) |*column| column.* = .{ .name = "", .kind = .other };
    for (output.columns, reader.columns) |*column, source| column.* = .{ .name = try allocator.dupe(u8, source.name), .kind = source.kind, .native_type = if (std.mem.eql(u8, source.type_sql, "timestamp_ns")) 22 else if (std.mem.eql(u8, source.type_sql, "time_ns")) 39 else 0 };
    var rows: std.ArrayList([]?[]const u8) = .empty;
    errdefer {
        for (rows.items) |row| {
            for (row) |cell| if (cell) |text| allocator.free(text);
            allocator.free(row);
        }
        rows.deinit(allocator);
    }
    while (try reader.next()) |result| {
        var batch = result;
        defer batch.deinit(allocator);
        if (timer.expired.load(.acquire)) return error.CrossDatabaseTimeBudgetExceeded;
        const overhead = (rows.items.len + batch.rows.len) * (reader.columns.len * @sizeOf(?[]const u8) + @sizeOf([]?[]const u8));
        if (reader.guard.bytes +| overhead > model.budget.max_memory_bytes / 8) return error.CrossDatabaseMemoryBudgetExceeded;
        try rows.appendSlice(allocator, batch.rows);
        allocator.free(batch.rows);
        batch.rows = &.{};
    }
    if (timer.expired.load(.acquire)) return error.CrossDatabaseTimeBudgetExceeded;
    const columns = try allocator.alloc(read.Column, reader.columns.len);
    for (columns) |*column| column.* = .{ .name = "", .kind = .other, .type_sql = "" };
    errdefer {
        for (columns) |column| {
            allocator.free(column.name);
            allocator.free(column.type_sql);
        }
        allocator.free(columns);
    }
    for (columns, reader.columns) |*column, source| {
        column.name = try allocator.dupe(u8, source.name);
        column.kind = source.kind;
        column.type_sql = try allocator.dupe(u8, source.type_sql);
    }
    output.rows = try rows.toOwnedSlice(allocator);
    return .{ .result = output, .columns = columns };
}

/// Create/load an output inside the caller's destination-local transaction.
/// relation is already SQL-quoted; the typed metadata comes from the final
/// native reader, rather than inferred text or a lossy JSON conversion.
pub fn materializeQueryResult(runtime: Runtime, destination: *adapter.Session, relation: []const u8, outcome: *const cross.QueryOutcome, source_adapter: []const u8) !void {
    const allocator = runtime.allocator;
    try createTypedTable(allocator, destination, relation, outcome.columns, false);
    const shapes = try allocator.alloc(DecimalShape, outcome.columns.len);
    defer allocator.free(shapes);
    @memset(shapes, .{});
    if (destination.* == .duckdb) for (outcome.columns, shapes, 0..) |column, *shape, c| {
        if (std.mem.eql(u8, column.type_sql, "numeric")) for (outcome.result.rows) |row| if (row[c]) |text| try shape.observe(text);
    };
    try loadBatchSql(allocator, destination, relation, &outcome.result, source_adapter);
    if (destination.* == .duckdb) try finishDecimalsSql(allocator, destination, relation, outcome.columns, shapes);
}

pub fn open(runtime: Runtime, root: []const u8, connection: cross.Connection) !adapter.Session {
    if (std.mem.eql(u8, connection.adapter_type, "duckdb")) {
        const configured = connection.identity.database_path orelse ":memory:";
        const path = if (std.mem.eql(u8, configured, ":memory:")) configured else try cross.projectPath(runtime, connection.identity.database_path_base orelse root, configured);
        defer if (path.ptr != configured.ptr) runtime.allocator.free(path);
        return .{ .duckdb = (try runtime.duckdb_pool.?.acquire(path, false)) orelse return error.NativeDuckDbLibraryNotFound };
    }
    const library = if (runtime.environment) |env| env.get("DXT_POSTGRES_LIBRARY") else null;
    return .{ .postgres = try adapter.PostgresConnection.open(runtime.allocator, connection.identity.connection_info orelse return error.MissingPostgresConnection, library) };
}

pub fn configure(runtime: Runtime, session: *adapter.Session, budget: cross.Budget, spill: []const u8) !void {
    const allocator = runtime.allocator;
    if (session.* == .duckdb) {
        try Dir.cwd().createDirPath(runtime.io, spill);
        const spill_literal = try adapter.quoteLiteral(allocator, spill);
        defer allocator.free(spill_literal);
        const settings = try std.fmt.allocPrint(allocator, "set memory_limit = '{d}B'; set max_temp_directory_size = '{d}B'; set temp_directory = {s}; set timezone = 'UTC'", .{ budget.max_memory_bytes / 4, budget.max_spill_bytes, spill_literal });
        defer allocator.free(settings);
        try session.execute(settings);
    } else {
        const settings = try std.fmt.allocPrint(allocator, "set statement_timeout = '{d}ms'; set timezone = 'UTC'", .{budget.max_query_seconds * 1000});
        defer allocator.free(settings);
        try session.execute(settings);
    }
}

fn createStage(allocator: std.mem.Allocator, destination: *adapter.Session, name: []const u8, columns: []const read.Column) !void {
    const quoted = try adapter.quoteIdentifier(allocator, name);
    defer allocator.free(quoted);
    return createTypedTable(allocator, destination, quoted, columns, true);
}

pub fn createTypedTable(allocator: std.mem.Allocator, destination: *adapter.Session, relation: []const u8, columns: []const read.Column, temporary: bool) !void {
    if (columns.len == 0) return error.CrossDatabaseOutputValidationFailed;
    var sql: std.Io.Writer.Allocating = .init(allocator);
    defer sql.deinit();
    try sql.writer.print("create {s}table {s} (", .{ if (temporary) "temporary " else "", relation });
    for (columns, 0..) |column, index| {
        if (index != 0) try sql.writer.writeByte(',');
        const identifier = try adapter.quoteIdentifier(allocator, column.name);
        defer allocator.free(identifier);
        const type_sql = destinationTypeSql(destination, column);
        try sql.writer.print("{s} {s}", .{ identifier, type_sql });
    }
    try sql.writer.writeByte(')');
    try destination.execute(sql.written());
}

fn destinationTypeSql(destination: *const adapter.Session, column: read.Column) []const u8 {
    return if (std.mem.eql(u8, column.type_sql, "timestamp_ns") and destination.* == .postgres) "timestamp" else if (std.mem.eql(u8, column.type_sql, "time_ns") and destination.* == .postgres) "time" else if (column.kind == .binary and destination.* == .postgres) "bytea" else if (std.mem.eql(u8, column.type_sql, "numeric") and destination.* == .duckdb) "varchar" else if ((std.mem.eql(u8, column.type_sql, "hugeint") or std.mem.eql(u8, column.type_sql, "uhugeint")) and destination.* == .postgres) "numeric(39,0)" else column.type_sql;
}

fn physicalColumns(allocator: std.mem.Allocator, destination: *const adapter.Session, columns: []const read.Column, shapes: []const DecimalShape) ![]read.Column {
    const result = try allocator.dupe(read.Column, columns);
    for (result, shapes) |*column, shape| column.type_sql = if (destination.* == .duckdb and std.mem.eql(u8, column.type_sql, "numeric")) try std.fmt.allocPrint(allocator, "decimal({d},{d})", .{ @max(1, shape.integer_digits + shape.scale), shape.scale }) else destinationTypeSql(destination, column.*);
    return result;
}

fn loadBatch(allocator: std.mem.Allocator, destination: *adapter.Session, name: []const u8, batch: *const adapter.QueryResult, source_adapter: []const u8) !void {
    const quoted = try adapter.quoteIdentifier(allocator, name);
    defer allocator.free(quoted);
    return loadBatchSql(allocator, destination, quoted, batch, source_adapter);
}

pub const DecimalShape = struct {
    integer_digits: usize = 0,
    scale: usize = 0,
    pub fn observe(self: *DecimalShape, text: []const u8) !void {
        const value = if (text.len != 0 and (text[0] == '-' or text[0] == '+')) text[1..] else text;
        if (value.len == 0) return error.UnsupportedCrossDatabaseDecimal;
        const dot = std.mem.indexOfScalar(u8, value, '.') orelse value.len;
        var leading: usize = 0;
        while (leading < dot and value[leading] == '0') leading += 1;
        for (value, 0..) |char, at| if (!std.ascii.isDigit(char) and !(at == dot and char == '.')) return error.UnsupportedCrossDatabaseDecimal;
        self.integer_digits = @max(self.integer_digits, dot - leading);
        self.scale = @max(self.scale, if (dot == value.len) 0 else value.len - dot - 1);
        if (self.integer_digits + self.scale > 38) return error.CrossDatabaseDecimalPrecisionExceeded;
    }
};

fn finishDecimals(allocator: std.mem.Allocator, destination: *adapter.Session, stage: []const u8, columns: []const read.Column, shapes: []const DecimalShape) !void {
    const relation = try adapter.quoteIdentifier(allocator, stage);
    defer allocator.free(relation);
    try finishDecimalsSql(allocator, destination, relation, columns, shapes);
}

pub fn finishDecimalsSql(allocator: std.mem.Allocator, destination: *adapter.Session, relation: []const u8, columns: []const read.Column, shapes: []const DecimalShape) !void {
    for (columns, shapes) |column, shape| {
        if (!std.mem.eql(u8, column.type_sql, "numeric")) continue;
        const name = try adapter.quoteIdentifier(allocator, column.name);
        defer allocator.free(name);
        const precision = @max(1, shape.integer_digits + shape.scale);
        const sql = try std.fmt.allocPrint(allocator, "alter table {s} alter column {s} type decimal({d},{d}) using cast({s} as decimal({d},{d}))", .{ relation, name, precision, shape.scale, name, precision, shape.scale });
        defer allocator.free(sql);
        try destination.execute(sql);
    }
}

pub fn loadBatchSql(allocator: std.mem.Allocator, destination: *adapter.Session, relation: []const u8, batch: *const adapter.QueryResult, source_adapter: []const u8) !void {
    if (batch.rows.len == 0) return;
    var sql: std.Io.Writer.Allocating = .init(allocator);
    defer sql.deinit();
    try sql.writer.print("insert into {s} values ", .{relation});
    for (batch.rows, 0..) |row, index| {
        if (index != 0) try sql.writer.writeByte(',');
        try sql.writer.writeByte('(');
        for (row, batch.columns, 0..) |cell, column, c| {
            if (c != 0) try sql.writer.writeByte(',');
            if (cell) |text| {
                if (destination.* == .postgres and (column.native_type == 22 or column.native_type == 39)) {
                    if (std.mem.indexOfScalar(u8, text, '.')) |dot| {
                        var end = dot + 1;
                        while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {
                            if (end > dot + 6 and text[end] != '0') return error.CrossDatabaseTimestampPrecisionExceeded;
                        }
                    }
                }
                if (column.kind == .binary) {
                    const hex = try binaryHex(allocator, text, source_adapter);
                    defer allocator.free(hex);
                    if (destination.* == .postgres) try sql.writer.print("decode('{s}','hex')", .{hex}) else try sql.writer.print("from_hex('{s}')", .{hex});
                } else if (std.mem.indexOfScalar(u8, text, 0) != null and destination.* == .duckdb) {
                    const hex = try allocator.alloc(u8, text.len * 2);
                    defer allocator.free(hex);
                    const alphabet = "0123456789abcdef";
                    for (text, 0..) |byte, at| {
                        hex[at * 2] = alphabet[byte >> 4];
                        hex[at * 2 + 1] = alphabet[byte & 15];
                    }
                    try sql.writer.print("decode(from_hex('{s}'))", .{hex});
                } else {
                    const literal = try adapter.quoteLiteral(allocator, text);
                    defer allocator.free(literal);
                    try sql.writer.writeAll(literal);
                }
            } else try sql.writer.writeAll("null");
        }
        try sql.writer.writeByte(')');
    }
    try destination.execute(sql.written());
}

pub fn binaryHex(allocator: std.mem.Allocator, text: []const u8, source_adapter: []const u8) ![]const u8 {
    if (std.mem.eql(u8, source_adapter, "postgres")) {
        if (!std.mem.startsWith(u8, text, "\\x") or text.len % 2 != 0) return error.UnsupportedCrossDatabaseBinary;
        for (text[2..]) |char| if (!std.ascii.isHex(char)) return error.UnsupportedCrossDatabaseBinary;
        return try allocator.dupe(u8, text[2..]);
    }
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '\\' and index + 3 < text.len and text[index + 1] == 'x') {
            try bytes.append(allocator, std.fmt.parseInt(u8, text[index + 2 .. index + 4], 16) catch return error.UnsupportedCrossDatabaseBinary);
            index += 4;
        } else {
            try bytes.append(allocator, text[index]);
            index += 1;
        }
    }
    const result = try allocator.alloc(u8, bytes.items.len * 2);
    const alphabet = "0123456789abcdef";
    for (bytes.items, 0..) |byte, i| {
        result[i * 2] = alphabet[byte >> 4];
        result[i * 2 + 1] = alphabet[byte & 15];
    }
    return result;
}

pub fn recover(runtime: Runtime, arena_runtime: Runtime, root: []const u8, options: cross.Options, plan: *cross.Plan, stdout: *std.Io.Writer) !void {
    const id = options.run_id.?;
    const directory = try runDirectory(arena_runtime, root, id);
    const path = try std.fs.path.join(arena_runtime.allocator, &.{ directory, "state.json" });
    const text = try Dir.cwd().readFileAlloc(runtime.io, path, arena_runtime.allocator, .limited(16 * 1024 * 1024));
    const parsed = try std.json.parseFromSlice(std.json.Value, arena_runtime.allocator, text, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidCrossDatabaseRunState;
    const old_hash = parsed.value.object.get("plan_hash") orelse return error.InvalidCrossDatabaseRunState;
    const old_definition = parsed.value.object.get("definition_hash") orelse old_hash;
    if (old_hash != .string or old_definition != .string or !std.mem.eql(u8, old_definition.string, plan.definition_hash)) return error.CrossDatabasePlanChanged;
    const recorded_id = parsed.value.object.get("run_id") orelse return error.InvalidCrossDatabaseRunState;
    if (recorded_id != .string or !std.mem.eql(u8, recorded_id.string, id)) return error.InvalidCrossDatabaseRunState;
    const previous = try std.json.parseFromValue([]Record, arena_runtime.allocator, parsed.value.object.get("models") orelse return error.InvalidCrossDatabaseRunState, .{});
    defer previous.deinit();
    if (previous.value.len != plan.models.len) return error.InvalidCrossDatabaseRunState;
    const records = try arena_runtime.allocator.alloc(Record, plan.models.len);
    var pool = adapter.DuckDBPool.init(runtime.allocator, runtime.io, runtime.environment);
    defer pool.deinit();
    const rt: Runtime = .{ .allocator = runtime.allocator, .io = runtime.io, .environment = runtime.environment, .duckdb_pool = &pool };
    for (plan.models, records) |model, *record| {
        var found: ?Record = null;
        for (previous.value) |old| if (std.mem.eql(u8, old.model, model.name)) {
            if (found != null) return error.InvalidCrossDatabaseRunState;
            found = old;
        };
        record.* = found orelse return error.InvalidCrossDatabaseRunState;
        record.status = "rolled_back";
        record.cleanup = "complete";
        var destination = try open(rt, root, plan.connections[model.destination]);
        defer destination.deinit();
        if (try destination.relationExists(runtime.allocator, "dxt_internal", "cross_commits")) {
            const id_literal = try adapter.quoteLiteral(runtime.allocator, id);
            defer runtime.allocator.free(id_literal);
            const model_literal = try adapter.quoteLiteral(runtime.allocator, model.name);
            defer runtime.allocator.free(model_literal);
            const query = try std.fmt.allocPrint(runtime.allocator, "select output_rows, plan_hash from dxt_internal.cross_commits where run_id={s} and model={s}", .{ id_literal, model_literal });
            defer runtime.allocator.free(query);
            var result = try destination.query(query);
            defer result.deinit(runtime.allocator);
            if (result.rows.len != 0) {
                if (result.rows[0][1] == null or !std.mem.eql(u8, result.rows[0][1].?, old_hash.string)) return error.CrossDatabasePlanChanged;
                record.status = "success";
                record.error_name = null;
                record.watermarks_committed = std.mem.eql(u8, model.materialized, "incremental");
                record.output_rows = try std.fmt.parseUnsigned(u64, result.rows[0][0].?, 10);
                if (record.watermarks_committed and try destination.relationExists(runtime.allocator, "dxt_internal", "cross_watermark_history")) {
                    const target_key = try std.fmt.allocPrint(arena_runtime.allocator, "{s}.{s}", .{ model.schema, model.identifier });
                    const target_literal = try adapter.quoteLiteral(arena_runtime.allocator, target_key);
                    const history_sql = try std.fmt.allocPrint(arena_runtime.allocator, "select input,query_hash,watermark from dxt_internal.cross_watermark_history where run_id={s} and model={s} order by input", .{ id_literal, target_literal });
                    var history = try destination.query(history_sql);
                    defer history.deinit(runtime.allocator);
                    const watermarks = try arena_runtime.allocator.alloc(@import("cross_database_incremental.zig").Watermark, history.rows.len);
                    for (watermarks, history.rows) |*watermark, row| watermark.* = .{ .input = try arena_runtime.allocator.dupe(u8, row[0] orelse return error.InvalidCrossDatabaseRunState), .query_hash = try arena_runtime.allocator.dupe(u8, row[1] orelse return error.InvalidCrossDatabaseRunState), .value = if (row[2]) |value| try arena_runtime.allocator.dupe(u8, value) else null };
                    record.source_watermarks = watermarks;
                }
            }
        }
    }
    const spill = try std.fs.path.join(arena_runtime.allocator, &.{ directory, "spill" });
    try Dir.cwd().deleteTree(runtime.io, spill);
    try writeState(arena_runtime, path, id, old_hash.string, plan.definition_hash, records);
    try stdout.print("Recovered run {s}; temporary sessions were disconnected, destination commit markers verified, local stages cleaned\n", .{id});
}

fn runDirectory(runtime: Runtime, root: []const u8, id: []const u8) ![]const u8 {
    if (!cross.validRunId(id)) return error.InvalidCrossDatabaseRunId;
    return std.fs.path.join(runtime.allocator, &.{ root, ".dxt", "cross-runs", id });
}
fn qualified(allocator: std.mem.Allocator, schema: []const u8, name: []const u8) ![]const u8 {
    const a = try adapter.quoteIdentifier(allocator, schema);
    defer allocator.free(a);
    const b = try adapter.quoteIdentifier(allocator, name);
    defer allocator.free(b);
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ a, b });
}
fn writeState(runtime: Runtime, path: []const u8, id: []const u8, hash: []const u8, definition_hash: []const u8, records: []const Record) !void {
    var out: std.Io.Writer.Allocating = .init(runtime.allocator);
    try std.json.Stringify.value(.{ .schema_version = 1, .run_id = id, .plan_hash = hash, .definition_hash = definition_hash, .models = records }, .{}, &out.writer);
    try cross.writeAtomic(runtime, path, out.written());
}

pub const Timer = struct {
    runtime: Runtime,
    session: *adapter.Session,
    seconds: u64,
    done: std.atomic.Value(bool) = .init(false),
    expired: std.atomic.Value(bool) = .init(false),
    worker: ?std.Thread = null,
    pub fn init(runtime: Runtime, session: *adapter.Session, seconds: u64) Timer {
        return .{ .runtime = runtime, .session = session, .seconds = seconds };
    }
    pub fn start(self: *Timer) !void {
        self.worker = try std.Thread.spawn(.{}, watch, .{self});
    }
    pub fn deinit(self: *Timer) void {
        self.done.store(true, .release);
        if (self.worker) |thread| {
            thread.join();
            self.worker = null;
        }
    }
    fn watch(self: *Timer) void {
        const started = std.Io.Timestamp.now(self.runtime.io, .awake);
        while (!self.done.load(.acquire)) {
            std.Io.sleep(self.runtime.io, .fromMilliseconds(25), .awake) catch return;
            if (self.done.load(.acquire)) return;
            if (started.durationTo(std.Io.Timestamp.now(self.runtime.io, .awake)).nanoseconds >= @as(i128, self.seconds) * std.time.ns_per_s) {
                self.expired.store(true, .release);
                self.session.cancel() catch {};
                return;
            }
        }
    }
};

test "binary transfer preserves octets through adapter text representations" {
    const allocator = std.testing.allocator;
    const pg = try binaryHex(allocator, "\\x00ff275c", "postgres");
    defer allocator.free(pg);
    const duck = try binaryHex(allocator, "\\x00\\xFF'\\x5C", "duckdb");
    defer allocator.free(duck);
    try std.testing.expectEqualStrings("00ff275c", pg);
    try std.testing.expectEqualStrings(pg, duck);
    try std.testing.expectError(error.UnsupportedCrossDatabaseBinary, binaryHex(allocator, "\\x0z", "postgres"));
}
