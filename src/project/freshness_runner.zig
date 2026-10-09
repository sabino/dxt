const std = @import("std");
const types = @import("types.zig");
const adapter = @import("adapter.zig");
const freshness = @import("source_freshness.zig");
const query_adapter = @import("freshness_adapter.zig");
const clock = @import("execution_clock.zig");
const runner = @import("concurrent_runner.zig");

const Shared = struct { mutex: std.Io.Mutex = .init, changed: std.Io.Condition = .init, next: usize = 0, stop: bool = false, fail_fast: bool = false };
const State = enum { pending, running, finished, done };

const Job = struct {
    runtime: types.Runtime,
    graph: *const types.Graph,
    source: *const types.SourceDef,
    database_path: []const u8,
    worker: u16,
    arena: std.heap.ArenaAllocator,
    shared: *Shared,
    active_session: ?*adapter.Session = null,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    state: State = .pending,
    started_event: bool = false,
    output: ?freshness.CheckResult = null,

    fn work(self: *Job) void {
        const timing = @import("timing_profile.zig").start(self.runtime.timing_profile, .{ .filename = @src().file, .line = @src().line, .function = "FreshnessJob.work" }) catch @import("timing_profile.zig").Span{};
        defer timing.finish();
        var runtime = self.runtime;
        runtime.allocator = self.arena.allocator();
        const started = clock.now(runtime.io);
        const monotonic = std.Io.Timestamp.now(runtime.io, .awake);
        var output = self.perform(runtime) catch |err| blk: {
            break :blk freshness.CheckResult{ .source = self.source, .status = "runtime error", .error_message = runtime.allocator.dupe(u8, if (err == error.AdapterQueryCancelled) "Database query cancelled" else "Source freshness query failed") catch null };
        };
        output.thread_number = self.worker;
        output.execution_started_at = started;
        output.execution_completed_at = clock.now(runtime.io);
        output.execution_time = @as(f64, @floatFromInt(monotonic.durationTo(std.Io.Timestamp.now(runtime.io, .awake)).nanoseconds)) / std.time.ns_per_s;
        self.output = output;
    }

    fn perform(self: *Job, base: types.Runtime) !freshness.CheckResult {
        const source = self.source;
        if (freshness.unsupportedExecutionReason(source)) |message| return self.failure(base, message);
        freshness.validateThreshold(source.freshness.?) catch return self.failure(base, "source freshness currently requires complete freshness thresholds");
        if (source.loaded_at_field == null and source.loaded_at_query == null) return self.failure(base, freshness.unsupported_metadata_freshness_message);
        var session = try adapter.openSession(base, self.graph, self.database_path);
        defer session.deinit();
        self.shared.mutex.lockUncancelable(base.io);
        self.active_session = &session;
        self.shared.mutex.unlock(base.io);
        defer {
            self.shared.mutex.lockUncancelable(base.io);
            self.active_session = null;
            self.shared.mutex.unlock(base.io);
        }
        session.setCancellationToken(&self.cancel_requested);
        if (self.cancel_requested.load(.acquire)) return error.AdapterQueryCancelled;
        try session.beginReadOnly();
        var runtime = base;
        runtime.adapter_session = &session;
        const output = try query_adapter.querySourceFreshness(runtime, self.graph, self.database_path, source);
        return .{ .source = source, .status = try freshness.statusForAge(output.age_seconds, source.freshness.?), .max_loaded_at = output.max_loaded_at, .snapshotted_at = output.snapshotted_at, .age_seconds = output.age_seconds };
    }

    fn failure(self: *Job, runtime: types.Runtime, message: []const u8) !freshness.CheckResult {
        return .{ .source = self.source, .status = "runtime error", .error_message = try runtime.allocator.dupe(u8, message) };
    }
};

const Worker = struct {
    runtime: types.Runtime,
    shared: *Shared,
    jobs: []Job,
    number: u16,
    thread: ?std.Thread = null,

    fn work(self: *Worker) void {
        while (true) {
            self.shared.mutex.lockUncancelable(self.runtime.io);
            if (self.shared.stop or self.shared.next == self.jobs.len) {
                self.shared.mutex.unlock(self.runtime.io);
                return;
            }
            const index = self.shared.next;
            self.shared.next += 1;
            const job = &self.jobs[index];
            job.worker = self.number;
            job.state = .running;
            self.shared.changed.signal(self.runtime.io);
            self.shared.mutex.unlock(self.runtime.io);
            job.work();
            self.shared.mutex.lockUncancelable(self.runtime.io);
            job.state = .finished;
            // Core's GraphRunnableTask checks status "error" for fail-fast.
            // Source SQL errors have status "runtime error" and continue.
            if (self.shared.fail_fast and std.mem.eql(u8, job.output.?.status, "error")) {
                self.shared.stop = true;
                cancelJobs(self.jobs);
            }
            self.shared.changed.signal(self.runtime.io);
            self.shared.mutex.unlock(self.runtime.io);
        }
    }
};

/// A bounded pool continuously claims independent freshness checks. Every
/// check owns its native read-only connection and result arena.
pub fn run(runtime: types.Runtime, graph: *const types.Graph, options: types.Options, sources: []const *const types.SourceDef, database_path: []const u8, destination: *std.ArrayList(freshness.CheckResult), events: *std.Io.Writer) !bool {
    const threads = try runner.threadCount(options, graph);
    const jobs = try runtime.allocator.alloc(Job, sources.len);
    defer runtime.allocator.free(jobs);
    var shared: Shared = .{ .fail_fast = options.fail_fast };
    for (sources, jobs) |source, *job| job.* = .{ .runtime = runtime, .graph = graph, .source = source, .database_path = database_path, .worker = 0, .arena = .init(std.heap.smp_allocator), .shared = &shared };
    defer for (jobs) |*job| job.arena.deinit();
    const workers = try runtime.allocator.alloc(Worker, if (options.single_threaded) 0 else @min(threads, jobs.len));
    defer runtime.allocator.free(workers);
    for (workers, 0..) |*worker, index| worker.* = .{ .runtime = runtime, .shared = &shared, .jobs = jobs, .number = @intCast(index + 1) };
    defer {
        shared.mutex.lockUncancelable(runtime.io);
        shared.stop = true;
        cancelJobs(jobs);
        shared.mutex.unlock(runtime.io);
        for (workers) |*worker| if (worker.thread) |thread| thread.join();
    }
    for (workers) |*worker| worker.thread = try std.Thread.spawn(.{}, Worker.work, .{worker});
    if (options.single_threaded) for (jobs) |*job| {
        if (shared.stop) break;
        job.state = .running;
        job.started_event = true;
        try runner.emitEvent(runtime, options, events, "NodeStart", job.source.unique_id, "started", 0, 0);
        job.work();
        job.state = .finished;
        if (shared.fail_fast and std.mem.eql(u8, job.output.?.status, "error")) shared.stop = true;
    };
    var failure = false;
    var completed: usize = 0;
    shared.mutex.lockUncancelable(runtime.io);
    defer shared.mutex.unlock(runtime.io);
    while (completed < jobs.len) {
        var changed = false;
        for (jobs) |*job| {
            if (job.state == .pending and shared.stop) {
                try runner.emitEvent(runtime, options, events, "NodeFinished", job.source.unique_id, "skipped", if (options.single_threaded) 0 else 1, 0);
                job.state = .done;
                completed += 1;
                changed = true;
            }
            if (job.state == .pending or job.state == .done) continue;
            if (!job.started_event) {
                try runner.emitEvent(runtime, options, events, "NodeStart", job.source.unique_id, "started", job.worker, 0);
                job.started_event = true;
            }
            if (job.state != .finished) continue;
            const result = job.output.?;
            // Core omits cancelled and unstarted source checks from sources.
            // Events retain their completion and measured cancellation time.
            if (!job.cancel_requested.load(.acquire)) {
                const owned_result = try transferResult(runtime.allocator, result);
                destination.append(runtime.allocator, owned_result) catch |err| {
                    freshness.deinitResults(runtime.allocator, &.{owned_result});
                    return err;
                };
            }
            try runner.emitEvent(runtime, options, events, "NodeFinished", job.source.unique_id, result.status, job.worker, result.execution_time);
            if (std.mem.eql(u8, result.status, "error") or std.mem.eql(u8, result.status, "runtime error")) failure = true;
            job.state = .done;
            completed += 1;
            changed = true;
        }
        if (completed != jobs.len and !changed) {
            if (shared.stop) {
                cancelJobs(jobs);
                shared.mutex.unlock(runtime.io);
                const pause = std.Io.sleep(runtime.io, .fromMilliseconds(10), .awake);
                shared.mutex.lockUncancelable(runtime.io);
                try pause;
            } else try shared.changed.wait(runtime.io, &shared.mutex);
        }
    }
    return failure;
}

fn cancelJobs(jobs: []Job) void {
    for (jobs) |*job| {
        if (job.state != .running) continue;
        job.cancel_requested.store(true, .release);
        if (job.active_session) |session| session.cancel() catch {};
    }
}

fn transferResult(allocator: std.mem.Allocator, source: freshness.CheckResult) !freshness.CheckResult {
    var result = source;
    result.max_loaded_at = null;
    result.snapshotted_at = null;
    result.error_message = null;
    errdefer freshness.deinitResults(allocator, &.{result});
    if (source.max_loaded_at) |value| result.max_loaded_at = try allocator.dupe(u8, value);
    if (source.snapshotted_at) |value| result.snapshotted_at = try allocator.dupe(u8, value);
    if (source.error_message) |value| result.error_message = try allocator.dupe(u8, value);
    return result;
}
