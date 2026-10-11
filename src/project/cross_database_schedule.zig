//! Native task DAG, resource reservations, known-abort retries and adaptive
//! connection backpressure. Uncertain connection/commit failures never retry.
const std = @import("std");
const cross = @import("cross_database.zig");
const run = @import("cross_database_run.zig");
const catalog = @import("cross_database_catalog.zig");

pub const Settings = struct {
    max_concurrent_tasks: u16 = 1,
    max_retries: u8 = 2,
    retry_delay_ms: u64 = 50,
    max_memory_bytes: u64 = 512 * 1024 * 1024,
};
pub const Limits = struct { max_queries: u16 = 1, max_streaming_readers: u16 = 1, max_loaders: u16 = 1 };
pub const Attempt = struct { number: u8, started_epoch: u64, finished_epoch: u64, status: []const u8, error_name: ?[]const u8, rows_moved: u64, bytes_moved: u64 };
const Reservation = struct { group: usize, reader: bool, loader: bool };
const Bucket = struct { limits: Limits, effective_queries: u16, queries: u16 = 0, readers: u16 = 0, loaders: u16 = 0 };
const Shared = struct { mutex: std.Io.Mutex = .init, changed: std.Io.Condition = .init, buckets: []Bucket, group_indices: []const usize, connections: []const cross.Connection };
const State = enum { pending, running, finished, done };
const Job = struct {
    runtime: cross.Runtime,
    root: []const u8,
    directory: []const u8,
    run_id: []const u8,
    plan: *cross.Plan,
    model: cross.Model,
    record: run.Record,
    arena: std.heap.ArenaAllocator,
    shared: *Shared,
    reservations: []const Reservation,
    state: State = .pending,
    thread: ?std.Thread = null,
    failure: ?anyerror = null,

    fn work(self: *Job) void {
        defer {
            self.shared.mutex.lockUncancelable(self.runtime.io);
            self.state = .finished;
            self.shared.changed.signal(self.runtime.io);
            self.shared.mutex.unlock(self.runtime.io);
        }
        const local: cross.Runtime = .{ .allocator = self.arena.allocator(), .io = self.runtime.io, .environment = self.runtime.environment };
        var attempts: std.ArrayList(Attempt) = .empty;
        var number: u8 = 0;
        while (true) {
            number += 1;
            self.record.status = "running";
            self.record.error_name = null;
            self.record.source_watermarks = &.{};
            self.record.watermarks_committed = false;
            self.record.stage_artifacts = &.{};
            self.record.attempt_count = number;
            run.writeTask(local, self.root, &self.record) catch |err| {
                self.failure = err;
                return;
            };
            const started = catalog.epoch(self.runtime.io);
            const before_rows = self.record.rows_moved;
            const before_bytes = self.record.bytes_moved;
            var failure: ?anyerror = null;
            run.executeModel(self.runtime, local, self.root, self.directory, self.run_id, self.plan, self.model, &self.record) catch |err| {
                failure = err;
            };
            attempts.append(local.allocator, .{ .number = number, .started_epoch = started, .finished_epoch = catalog.epoch(self.runtime.io), .status = if (failure == null) "success" else "error", .error_name = if (failure) |err| @errorName(err) else null, .rows_moved = self.record.rows_moved -| before_rows, .bytes_moved = self.record.bytes_moved -| before_bytes }) catch |err| {
                self.failure = err;
                return;
            };
            self.record.attempts = attempts.items;
            if (failure == null) {
                run.writeTask(local, self.root, &self.record) catch |err| {
                    self.failure = err;
                };
                return;
            }
            const err = failure.?;
            self.record.error_name = @errorName(err);
            self.record.status = "error";
            self.record.cleanup = "complete";
            if (!retryable(err) or number > self.plan.scheduler.max_retries) {
                run.writeTask(local, self.root, &self.record) catch {};
                self.failure = err;
                return;
            }
            self.record.status = "retrying";
            self.shared.mutex.lockUncancelable(self.runtime.io);
            for (self.shared.connections, self.shared.group_indices) |connection, group| if (self.record.active_connection == null or std.mem.eql(u8, self.record.active_connection.?, connection.name)) {
                const bucket = &self.shared.buckets[group];
                bucket.effective_queries = @max(1, bucket.effective_queries / 2);
                self.record.throttled_connection = connection.name;
            };
            self.shared.changed.signal(self.runtime.io);
            self.shared.mutex.unlock(self.runtime.io);
            run.writeTask(local, self.root, &self.record) catch |write_error| {
                self.failure = write_error;
                return;
            };
            const delay = @min(5000, self.plan.scheduler.retry_delay_ms *| (@as(u64, 1) << @intCast(number - 1)));
            std.Io.sleep(self.runtime.io, .fromMilliseconds(@intCast(delay)), .awake) catch |sleep_error| {
                self.failure = sleep_error;
                self.record.status = "error";
                self.record.error_name = @errorName(sleep_error);
                return;
            };
        }
    }
};

pub fn effectiveLimits(connection: cross.Connection) Limits {
    var limits = connection.limits;
    // Metadata/DDL writes serialize per physical destination. Independent
    // source streams and different destination engines can still overlap.
    limits.max_loaders = 1;
    if (std.mem.eql(u8, connection.adapter_type, "duckdb") and !std.mem.eql(u8, connection.identity.database_path orelse "", ":memory:")) limits = .{};
    return limits;
}

pub fn retryable(err: anyerror) bool {
    return err == error.CrossDatabaseTargetLocked or err == error.PostgresSerializationFailure or err == error.PostgresDeadlockDetected or err == error.PostgresLockNotAvailable;
}

pub fn validate(allocator: std.mem.Allocator, models: []const cross.Model) !void {
    const done = try allocator.alloc(bool, models.len);
    defer allocator.free(done);
    @memset(done, false);
    var completed: usize = 0;
    while (completed < models.len) {
        var progress = false;
        for (models, 0..) |model, index| {
            if (done[index]) continue;
            var ready = true;
            for (model.depends_on) |dependency| {
                const parent = modelIndex(models, dependency) orelse return error.MissingCrossDatabaseModelDependency;
                if (!done[parent]) ready = false;
            }
            if (ready) {
                done[index] = true;
                completed += 1;
                progress = true;
            }
        }
        if (!progress) return error.CyclicCrossDatabaseModelDependency;
    }
}

pub fn execute(runtime: cross.Runtime, arena_runtime: cross.Runtime, root: []const u8, directory: []const u8, run_id: []const u8, path: []const u8, plan: *cross.Plan, records: []run.Record, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !bool {
    var scratch = std.heap.ArenaAllocator.init(runtime.allocator);
    defer scratch.deinit();
    const allocator = scratch.allocator();
    const groups = try allocator.alloc(usize, plan.connections.len);
    var buckets: std.ArrayList(Bucket) = .empty;
    var identities: std.ArrayList([]const u8) = .empty;
    for (plan.connections, groups) |connection, *group| {
        const identity = try physicalIdentity(.{ .allocator = allocator, .io = runtime.io }, root, connection);
        var found: ?usize = null;
        for (identities.items, 0..) |previous, index| if (std.mem.eql(u8, previous, identity)) {
            found = index;
            break;
        };
        const limits = effectiveLimits(connection);
        if (found) |index| {
            group.* = index;
            const bucket = &buckets.items[index];
            bucket.limits.max_queries = @min(bucket.limits.max_queries, limits.max_queries);
            bucket.limits.max_streaming_readers = @min(bucket.limits.max_streaming_readers, limits.max_streaming_readers);
            bucket.limits.max_loaders = @min(bucket.limits.max_loaders, limits.max_loaders);
            bucket.effective_queries = bucket.limits.max_queries;
        } else {
            group.* = buckets.items.len;
            try identities.append(allocator, identity);
            try buckets.append(allocator, .{ .limits = limits, .effective_queries = limits.max_queries });
        }
    }
    var shared: Shared = .{ .buckets = buckets.items, .group_indices = groups, .connections = plan.connections };
    const jobs = try allocator.alloc(Job, plan.models.len);
    for (jobs, plan.models, records) |*job, model, record| {
        const reads = try allocator.alloc(bool, buckets.items.len);
        const loads = try allocator.alloc(bool, buckets.items.len);
        const used = try allocator.alloc(bool, buckets.items.len);
        @memset(reads, false);
        @memset(loads, false);
        @memset(used, false);
        used[groups[model.destination]] = true;
        loads[groups[model.destination]] = true;
        used[groups[model.execution_connection]] = true;
        loads[groups[model.execution_connection]] = true;
        for (model.inputs) |input| if (input.moved) {
            used[groups[input.connection]] = true;
            reads[groups[input.connection]] = true;
            if (input.stage_connection) |index| {
                used[groups[index]] = true;
                reads[groups[index]] = true;
                loads[groups[index]] = true;
            }
        };
        var reservations: std.ArrayList(Reservation) = .empty;
        for (used, 0..) |include, index| if (include) try reservations.append(allocator, .{ .group = index, .reader = reads[index], .loader = loads[index] });
        job.* = .{ .runtime = runtime, .root = root, .directory = directory, .run_id = run_id, .plan = plan, .model = model, .record = record, .arena = std.heap.ArenaAllocator.init(runtime.allocator), .shared = &shared, .reservations = reservations.items };
    }
    defer for (jobs) |*job| {
        if (job.thread) |thread| thread.join();
        job.arena.deinit();
    };
    var active: usize = 0;
    var completed: usize = 0;
    var memory: u64 = 0;
    var failed = false;
    shared.mutex.lockUncancelable(runtime.io);
    defer shared.mutex.unlock(runtime.io);
    // Joining always occurs with the publication mutex released on errors.
    errdefer {
        shared.mutex.unlock(runtime.io);
        for (jobs) |*job| if (job.thread) |thread| {
            thread.join();
            job.thread = null;
        };
        shared.mutex.lockUncancelable(runtime.io);
    }
    while (completed < jobs.len) {
        var changed = false;
        for (jobs, records) |*job, *record| if (job.state == .finished) {
            job.thread.?.join();
            job.thread = null;
            for (job.reservations) |reservation| release(&shared.buckets[reservation.group], reservation);
            active -= 1;
            memory -|= job.model.budget.max_memory_bytes;
            completed += 1;
            job.state = .done;
            const json = try std.json.Stringify.valueAlloc(arena_runtime.allocator, job.record, .{});
            const owned = try std.json.parseFromSlice(run.Record, arena_runtime.allocator, json, .{ .allocate = .alloc_always });
            record.* = owned.value;
            if (job.failure) |err| {
                failed = true;
                if (std.mem.eql(u8, record.status, "success")) try stderr.print("error: cross-database model {s}: {s}; output committed, task metadata incomplete\n", .{ job.model.name, @errorName(err) }) else try stderr.print("error: cross-database model {s}: {s}; destination rolled back and temporary stages disconnected\n", .{ job.model.name, @errorName(err) });
            }
            try run.writeState(arena_runtime, path, run_id, plan.hash, plan.definition_hash, records);
            try stdout.print("{s}: {s}; moved {d} rows / {d} bytes; {d} attempt(s); run {s}\n", .{ job.model.name, record.status, record.rows_moved, record.bytes_moved, record.attempt_count, run_id });
            changed = true;
        };
        for (jobs, records) |*job, *record| if (job.state == .pending) {
            var ready = true;
            var blocked = false;
            for (job.model.depends_on) |dependency| {
                const index = modelIndex(plan.models, dependency).?;
                if (jobs[index].state != .done) ready = false else if (!std.mem.eql(u8, records[index].status, "success")) blocked = true;
            }
            if (!ready) continue;
            if (blocked) {
                record.status = "skipped";
                record.cleanup = "complete";
                record.error_name = "CrossDatabaseUpstreamFailed";
                job.state = .done;
                completed += 1;
                failed = true;
                changed = true;
                try run.writeState(arena_runtime, path, run_id, plan.hash, plan.definition_hash, records);
                continue;
            }
            if (active >= plan.scheduler.max_concurrent_tasks or memory +| job.model.budget.max_memory_bytes > plan.scheduler.max_memory_bytes) continue;
            var available = true;
            for (job.reservations) |reservation| if (!fits(shared.buckets[reservation.group], reservation)) {
                available = false;
            };
            if (!available) continue;
            for (job.reservations) |reservation| reserve(&shared.buckets[reservation.group], reservation);
            memory +|= job.model.budget.max_memory_bytes;
            active += 1;
            record.status = "running";
            record.target_lock = "requested";
            job.record.target_lock = "requested";
            job.state = .running;
            try run.writeState(arena_runtime, path, run_id, plan.hash, plan.definition_hash, records);
            job.thread = std.Thread.spawn(.{}, Job.work, .{job}) catch |err| {
                for (job.reservations) |reservation| release(&shared.buckets[reservation.group], reservation);
                active -= 1;
                memory -|= job.model.budget.max_memory_bytes;
                job.state = .pending;
                return err;
            };
            changed = true;
        };
        if (completed == jobs.len) break;
        if (active == 0 and !changed) return error.CrossDatabaseSchedulingDeadlock;
        if (!changed) try shared.changed.wait(runtime.io, &shared.mutex);
    }
    return failed;
}

fn fits(bucket: Bucket, reservation: Reservation) bool {
    return bucket.queries < bucket.effective_queries and (!reservation.reader or bucket.readers < bucket.limits.max_streaming_readers) and (!reservation.loader or bucket.loaders < bucket.limits.max_loaders);
}
fn reserve(bucket: *Bucket, reservation: Reservation) void {
    bucket.queries += 1;
    if (reservation.reader) bucket.readers += 1;
    if (reservation.loader) bucket.loaders += 1;
}
fn release(bucket: *Bucket, reservation: Reservation) void {
    bucket.queries -= 1;
    if (reservation.reader) bucket.readers -= 1;
    if (reservation.loader) bucket.loaders -= 1;
}
fn modelIndex(models: []const cross.Model, name: []const u8) ?usize {
    for (models, 0..) |model, index| if (std.mem.eql(u8, model.name, name)) return index;
    return null;
}
fn physicalIdentity(runtime: cross.Runtime, root: []const u8, connection: cross.Connection) ![]const u8 {
    if (connection.identity.database_path) |path| {
        if (std.mem.eql(u8, path, ":memory:")) return std.fmt.allocPrint(runtime.allocator, "memory:{s}", .{connection.name});
        const absolute = try cross.projectPath(runtime, connection.identity.database_path_base orelse root, path);
        return std.Io.Dir.cwd().realPathFileAlloc(runtime.io, absolute, runtime.allocator) catch |err| {
            if (err != error.FileNotFound) return err;
            return std.fs.path.resolve(runtime.allocator, &.{absolute});
        };
    }
    return catalog.bindingHash(runtime.allocator, connection);
}

test "adaptive retries exclude cancellation and uncertain commit failures" {
    try std.testing.expect(retryable(error.PostgresSerializationFailure));
    try std.testing.expect(retryable(error.CrossDatabaseTargetLocked));
    try std.testing.expect(!retryable(error.PostgresExecutionFailed));
    try std.testing.expect(!retryable(error.AdapterQueryCancelled));
    var bucket: Bucket = .{ .limits = .{ .max_queries = 2 }, .effective_queries = 2 };
    const reservation: Reservation = .{ .group = 0, .reader = true, .loader = false };
    try std.testing.expect(fits(bucket, reservation));
    reserve(&bucket, reservation);
    try std.testing.expect(!fits(bucket, reservation));
    release(&bucket, reservation);
    try std.testing.expect(fits(bucket, reservation));
}
