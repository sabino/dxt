const std = @import("std");
const adapter = @import("adapter.zig");
const clock = @import("execution_clock.zig");
const scheduler = @import("scheduler.zig");
const results = @import("run_results.zig");
const types = @import("types.zig");

pub const Resource = union(enum) {
    node: *const types.Node,
    generic: *const types.GenericTestNode,
    singular: *const types.SingularTestNode,
    unit: *const types.UnitTestDef,

    pub fn id(self: Resource) []const u8 {
        return switch (self) {
            inline else => |value| value.unique_id,
        };
    }
    pub fn dependencies(self: Resource) []const []const u8 {
        return switch (self) {
            inline else => |value| value.depends_on.items,
        };
    }
    pub fn result(self: Resource, status: []const u8) results.NodeResult {
        return switch (self) {
            .node => |value| .{ .node = value, .status = status },
            .generic => |value| .{ .test_node = value, .status = status },
            .singular => |value| .{ .singular_test_node = value, .status = status },
            .unit => |value| .{ .unit_test_node = value, .status = status },
        };
    }
    fn unitTarget(self: Resource, graph: *const types.Graph) ?[]const u8 {
        if (self != .unit) return null;
        for (graph.nodes.items) |*node| if (scheduler.unitTargetsNode(self.unit, node)) return node.unique_id;
        return null;
    }
    fn isDataTest(self: Resource) bool {
        return self == .generic or self == .singular;
    }
};

pub const Execute = *const fn (types.Runtime, *const types.Graph, Resource, []const u8, []const u8) anyerror!results.NodeResult;
pub const Summary = struct {
    rows: []results.NodeResult,
    had_execution_error: bool = false,
    failed_tests: usize = 0,
    total_failures: i64 = 0,
};

const Mode = enum { execute, compile };

const State = enum { pending, running, finished, done };
const Shared = struct { mutex: std.Io.Mutex = .init, changed: std.Io.Condition = .init };
const Job = struct {
    resource: Resource,
    prerequisites: std.ArrayList(usize) = .empty,
    state: State = .pending,
    thread: ?std.Thread = null,
    worker_number: u16 = 0,
    arena: std.heap.ArenaAllocator,
    output: ?results.NodeResult = null,
    active_session: ?*adapter.Session = null,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    shared: *Shared,
    runtime: types.Runtime,
    graph: *const types.Graph,
    execute: Execute,
    project_dir: []const u8,
    database_path: []const u8,
    mode: Mode,
    single_threaded: bool,

    fn work(self: *Job) void {
        const timing = @import("timing_profile.zig").start(self.runtime.timing_profile, .{ .filename = @src().file, .line = @src().line, .function = "Job.work" }) catch @import("timing_profile.zig").Span{};
        defer timing.finish();
        const start = clock.now(self.runtime.io);
        const monotonic_start = std.Io.Clock.awake.now(self.runtime.io);
        var runtime = self.runtime;
        runtime.allocator = self.arena.allocator();
        var graph = self.graph.*;
        graph.allocator = runtime.allocator;
        var output = self.perform(runtime, &graph) catch |err| blk: {
            var failure = self.resource.result("error");
            failure.message = runtime.allocator.dupe(u8, @import("compile_diagnostics.zig").message(err) orelse if (err == error.AdapterQueryCancelled) "Database query cancelled" else "Resource execution failed") catch null;
            break :blk failure;
        };
        output.thread_number = if (self.single_threaded) 0 else self.worker_number;
        output.execution_started_at = output.compile_completed_at orelse start;
        output.execution_completed_at = clock.now(runtime.io);
        output.execution_time = @as(f64, @floatFromInt(monotonic_start.durationTo(std.Io.Clock.awake.now(runtime.io)).nanoseconds)) / std.time.ns_per_s;
        self.shared.mutex.lockUncancelable(runtime.io);
        defer self.shared.mutex.unlock(runtime.io);
        self.output = output;
        self.state = .finished;
        self.shared.changed.signal(runtime.io);
    }

    fn sessionChanged(raw: *anyopaque, session: ?*adapter.Session) void {
        const self: *Job = @ptrCast(@alignCast(raw));
        self.shared.mutex.lockUncancelable(self.runtime.io);
        defer self.shared.mutex.unlock(self.runtime.io);
        self.active_session = session;
        if (self.cancel_requested.load(.acquire)) if (session) |active| active.cancel() catch {};
    }

    fn perform(self: *Job, runtime_base: types.Runtime, graph: *types.Graph) !results.NodeResult {
        if (self.mode == .compile) {
            var runtime = runtime_base;
            runtime.adapter_session = null;
            runtime.cancellation_token = &self.cancel_requested;
            runtime.session_observer = .{ .context = self, .changed = sessionChanged };
            if (self.cancel_requested.load(.acquire)) return error.AdapterQueryCancelled;
            return self.execute(runtime, graph, self.resource, self.database_path, self.project_dir);
        }
        var session = if (self.resource == .unit) try adapter.openUnitSession(runtime_base, graph) else try adapter.openSession(runtime_base, graph, self.database_path);
        defer session.deinit();
        self.shared.mutex.lockUncancelable(runtime_base.io);
        const cancel_requested = self.cancel_requested.load(.acquire);
        if (!cancel_requested) self.active_session = &session;
        self.shared.mutex.unlock(runtime_base.io);
        if (cancel_requested) return error.AdapterQueryCancelled;
        defer {
            // Cancellation holds this mutex, so closing a connection can
            // never race with the supervisor using its cancellation handle.
            self.shared.mutex.lockUncancelable(runtime_base.io);
            self.active_session = null;
            self.shared.mutex.unlock(runtime_base.io);
        }
        session.setCancellationToken(&self.cancel_requested);
        var runtime = runtime_base;
        runtime.adapter_session = &session;
        return try self.execute(runtime, graph, self.resource, self.database_path, self.project_dir);
    }
};

pub fn threadCount(options: types.Options, graph: *const types.Graph) !u16 {
    if (options.threads) |value| return try parseThreadCount(value);
    if (graph.target_threads == 0 or graph.target_threads > 256) return error.InvalidThreadCount;
    return graph.target_threads;
}

pub fn parseThreadCount(value: []const u8) !u16 {
    const count = std.fmt.parseUnsigned(u16, value, 10) catch return error.InvalidThreadCount;
    if (count == 0 or count > 256) return error.InvalidThreadCount;
    return count;
}

pub fn requested(runtime: types.Runtime, options: types.Options, graph: *const types.Graph) !bool {
    if (try threadCount(options, graph) > 1 or options.single_threaded or options.fail_fast or options.log_format == .json or std.mem.eql(u8, graph.adapter_type, "postgres") or (graph.database_path != null and std.mem.eql(u8, graph.database_path.?, ":memory:"))) return true;
    return if (runtime.duckdb_pool) |pool| try pool.available() else false;
}

pub fn run(runtime: types.Runtime, graph: *const types.Graph, options: types.Options, resources: []const Resource, database_path: []const u8, execute: Execute, events: *std.Io.Writer) !Summary {
    return runMode(runtime, graph, options, resources, database_path, execute, events, .execute);
}

pub fn runCompilation(runtime: types.Runtime, graph: *const types.Graph, options: types.Options, resources: []const Resource, database_path: []const u8, execute: Execute, events: *std.Io.Writer) !Summary {
    return runMode(runtime, graph, options, resources, database_path, execute, events, .compile);
}

fn runMode(runtime: types.Runtime, graph: *const types.Graph, options: types.Options, resources: []const Resource, database_path: []const u8, execute: Execute, events: *std.Io.Writer, mode: Mode) !Summary {
    const configured_count = try threadCount(options, graph);
    const count: u16 = if (options.single_threaded) 1 else configured_count;
    if (mode == .execute and std.mem.eql(u8, graph.adapter_type, "duckdb")) {
        const pool = runtime.duckdb_pool orelse return error.NativeDuckDbPoolRequired;
        if (!try pool.available()) return error.NativeDuckDbLibraryNotFound;
    }
    var shared: Shared = .{};
    const jobs = try runtime.allocator.alloc(Job, resources.len);
    defer runtime.allocator.free(jobs);
    for (resources, jobs) |resource, *job| job.* = .{ .resource = resource, .arena = .init(std.heap.smp_allocator), .shared = &shared, .runtime = runtime, .graph = graph, .execute = execute, .project_dir = options.project_dir, .database_path = database_path, .mode = mode, .single_threaded = options.single_threaded };
    defer for (jobs) |*job| {
        job.prerequisites.deinit(runtime.allocator);
        job.arena.deinit();
    };
    try wirePrerequisites(runtime.allocator, graph, jobs, mode);
    var rows: std.ArrayList(results.NodeResult) = .empty;
    errdefer {
        for (rows.items) |row| freeResult(runtime.allocator, row);
        rows.deinit(runtime.allocator);
    }
    var blocked: std.ArrayList([]const u8) = .empty;
    defer blocked.deinit(runtime.allocator);
    const occupied = try runtime.allocator.alloc(bool, count);
    defer runtime.allocator.free(occupied);
    @memset(occupied, false);
    var summary: Summary = .{ .rows = &.{} };
    var active: usize = 0;
    var completed: usize = 0;
    var stop = false;
    shared.mutex.lockUncancelable(runtime.io);
    defer shared.mutex.unlock(runtime.io);
    // Every exit joins workers before their arena, session or graph is freed.
    defer {
        cancelJobs(runtime.io, jobs);
        shared.mutex.unlock(runtime.io);
        for (jobs) |*job| if (job.thread) |thread| thread.join();
        shared.mutex.lockUncancelable(runtime.io);
    }
    while (completed < jobs.len) {
        var changed = false;
        for (jobs) |*job| {
            if (job.state != .finished) continue;
            if (job.thread) |thread| thread.join();
            job.thread = null;
            occupied[job.worker_number - 1] = false;
            active -= 1;
            completed += 1;
            job.state = .done;
            const output = try transferResult(runtime.allocator, job.output.?);
            rows.append(runtime.allocator, output) catch |err| {
                freeResult(runtime.allocator, output);
                return err;
            };
            try emitEvent(runtime, options, events, "NodeFinished", job.resource.id(), output.status, output.thread_number, output.execution_time);
            if (output.log_output) |messages| try emitMessages(runtime, options, events, job.resource.id(), output.thread_number, messages);
            try emitLogMessages(runtime, events, job.resource.id(), output.thread_number, output.log_events);
            if (failed(output)) {
                if (mode == .compile or job.resource == .node) summary.had_execution_error = true else {
                    summary.failed_tests += 1;
                    summary.total_failures += output.failures orelse 0;
                }
                if (mode == .execute) try addBlockers(runtime.allocator, graph, job.resource, &blocked) else try appendUnique(runtime.allocator, &blocked, job.resource.id());
                if (options.fail_fast and !stop) {
                    stop = true;
                    cancelJobs(runtime.io, jobs);
                }
            }
            changed = true;
        }
        for (jobs) |*job| {
            if (job.state != .pending) continue;
            if (!prerequisitesDone(jobs, job.prerequisites.items)) continue;
            if (!stop and !try jobBlocked(runtime.allocator, graph, job, jobs, blocked.items)) continue;
            var output = job.resource.result("skipped");
            if (options.single_threaded) output.thread_number = 0;
            try rows.append(runtime.allocator, output);
            try emitEvent(runtime, options, events, "NodeFinished", job.resource.id(), "skipped", output.thread_number, 0);
            job.output = output;
            job.state = .done;
            completed += 1;
            changed = true;
            try appendUnique(runtime.allocator, &blocked, job.resource.id());
        }
        if (!stop) for (jobs) |*job| {
            if (active >= count) break;
            if (job.state != .pending or !prerequisitesDone(jobs, job.prerequisites.items)) continue;
            if (try jobBlocked(runtime.allocator, graph, job, jobs, blocked.items)) continue;
            for (occupied, 0..) |used, index| if (!used) {
                job.worker_number = @intCast(index + 1);
                occupied[index] = true;
                break;
            };
            try emitEvent(runtime, options, events, "NodeStart", job.resource.id(), "started", if (options.single_threaded) 0 else job.worker_number, 0);
            job.state = .running;
            active += 1;
            if (options.single_threaded) {
                // Core invokes the runner directly on MainThread. Releasing
                // the supervisor lock allows session observation and completion
                // to use the same path as worker-thread execution.
                shared.mutex.unlock(runtime.io);
                job.work();
                shared.mutex.lockUncancelable(runtime.io);
            } else job.thread = try std.Thread.spawn(.{}, Job.work, .{job});
            changed = true;
        };
        if (completed == jobs.len) break;
        if (active == 0 and !changed) return error.CyclicModelDependency;
        if (!changed) {
            if (stop) {
                // An interrupt issued between native statements can be reset
                // by the next statement. Tokens prevent future work, while a
                // short retry closes the prepare/execute cancellation race.
                cancelJobs(runtime.io, jobs);
                shared.mutex.unlock(runtime.io);
                const pause = std.Io.sleep(runtime.io, .fromMilliseconds(10), .awake);
                shared.mutex.lockUncancelable(runtime.io);
                try pause;
            } else try shared.changed.wait(runtime.io, &shared.mutex);
        }
    }
    summary.rows = try rows.toOwnedSlice(runtime.allocator);
    return summary;
}

fn cancelJobs(io: std.Io, jobs: []Job) void {
    for (jobs) |*job| {
        if (job.state != .running) continue;
        job.cancel_requested.store(true, .release);
        if (job.active_session) |session| session.cancel() catch {};
    }
    _ = io;
}

fn failed(output: results.NodeResult) bool {
    return std.mem.eql(u8, output.status, "error") or std.mem.eql(u8, output.status, "fail") or std.mem.eql(u8, output.status, "partial success");
}
fn prerequisitesDone(jobs: []const Job, prerequisites: []const usize) bool {
    for (prerequisites) |index| if (jobs[index].state != .done) return false;
    return true;
}

fn jobBlocked(allocator: std.mem.Allocator, graph: *const types.Graph, job: *const Job, jobs: []const Job, blocked: []const []const u8) !bool {
    // Tests that share a successful model remain independent. A failed test
    // gates descendant models, while sibling data/unit tests still execute.
    if (job.resource != .node) {
        if (job.resource == .unit and try resourceBlocked(allocator, graph, job.resource, blocked)) return true;
        for (job.prerequisites.items) |index| {
            const parent = jobs[index];
            if (parent.resource != .node or parent.output == null) continue;
            if (failed(parent.output.?) or std.mem.eql(u8, parent.output.?.status, "skipped")) return true;
        }
        return false;
    }
    return try resourceBlocked(allocator, graph, job.resource, blocked);
}

fn resourceBlocked(allocator: std.mem.Allocator, graph: *const types.Graph, resource: Resource, blocked: []const []const u8) !bool {
    for (blocked) |id| if (std.mem.eql(u8, id, resource.id())) return true;
    if (resource.unitTarget(graph)) |target| {
        for (blocked) |id| if (std.mem.eql(u8, id, target)) return true;
        for (graph.nodes.items) |node| if (std.mem.eql(u8, node.unique_id, target) and try scheduler.blockedBy(allocator, graph, node.depends_on.items, blocked)) return true;
    }
    return try scheduler.blockedBy(allocator, graph, resource.dependencies(), blocked);
}

fn addBlockers(allocator: std.mem.Allocator, graph: *const types.Graph, resource: Resource, blocked: *std.ArrayList([]const u8)) !void {
    if (resource.unitTarget(graph)) |target| return try appendUnique(allocator, blocked, target);
    if (resource == .generic) {
        if (resource.generic.attached_node) |target| return try appendUnique(allocator, blocked, target);
        if (resource.generic.attached_source_unique_id) |target| return try appendUnique(allocator, blocked, target);
    }
    if (resource == .singular) {
        for (resource.dependencies()) |dependency| try appendUnique(allocator, blocked, dependency);
        return;
    }
    try appendUnique(allocator, blocked, resource.id());
}

fn wirePrerequisites(allocator: std.mem.Allocator, graph: *const types.Graph, jobs: []Job, mode: Mode) !void {
    for (jobs, 0..) |*job, index| {
        const physical = try scheduler.physicalDependencies(allocator, graph, job.resource.dependencies());
        defer allocator.free(physical);
        const target = job.resource.unitTarget(graph);
        for (physical) |dependency| {
            if (target) |id| if (std.mem.eql(u8, dependency, id)) continue;
            for (jobs, 0..) |other, other_index| if (other_index != index and std.mem.eql(u8, dependency, other.resource.id())) try appendEdge(allocator, &job.prerequisites, other_index);
        }
        if (target) |target_id| for (graph.nodes.items) |node| {
            if (!std.mem.eql(u8, node.unique_id, target_id)) continue;
            const ancestors = try scheduler.physicalDependencies(allocator, graph, node.depends_on.items);
            defer allocator.free(ancestors);
            for (ancestors) |dependency| for (jobs, 0..) |other, other_index| {
                if (other_index != index and std.mem.eql(u8, dependency, other.resource.id())) try appendEdge(allocator, &job.prerequisites, other_index);
            };
        };
        if (mode == .compile) continue;
        for (jobs, 0..) |other, other_index| {
            if (other_index == index) continue;
            if (other.resource.unitTarget(graph)) |unit_target| {
                if (job.resource == .node and (std.mem.eql(u8, job.resource.id(), unit_target) or try scheduler.blockedBy(allocator, graph, job.resource.dependencies(), &.{unit_target}))) try appendEdge(allocator, &job.prerequisites, other_index);
                if (target) |id| if (std.mem.eql(u8, unit_target, id) and other_index < index) try appendEdge(allocator, &job.prerequisites, other_index);
            }
            if (job.resource != .node or !other.resource.isDataTest()) continue;
            if (!try scheduler.blockedBy(allocator, graph, job.resource.dependencies(), other.resource.dependencies())) continue;
            // A multi-parent test that needs this node or its descendants
            // cannot gate this node; it will gate later descendants instead.
            var would_cycle = false;
            for (other.resource.dependencies()) |dependency| {
                if (std.mem.eql(u8, dependency, job.resource.id())) {
                    would_cycle = true;
                    break;
                }
                for (graph.nodes.items) |node| if (std.mem.eql(u8, node.unique_id, dependency) and try scheduler.blockedBy(allocator, graph, node.depends_on.items, &.{job.resource.id()})) {
                    would_cycle = true;
                    break;
                };
            }
            if (!would_cycle) try appendEdge(allocator, &job.prerequisites, other_index);
        }
    }
}

fn appendUnique(allocator: std.mem.Allocator, ids: *std.ArrayList([]const u8), id: []const u8) !void {
    for (ids.items) |existing| if (std.mem.eql(u8, existing, id)) return;
    try ids.append(allocator, id);
}
fn appendEdge(allocator: std.mem.Allocator, edges: *std.ArrayList(usize), index: usize) !void {
    for (edges.items) |existing| if (existing == index) return;
    try edges.append(allocator, index);
}

fn transferResult(allocator: std.mem.Allocator, source: results.NodeResult) !results.NodeResult {
    var output = source;
    output.message = null;
    output.compiled_artifact_code = null;
    output.owns_compiled_artifact_code = false;
    output.preview = null;
    output.owns_preview = false;
    output.owns_adapter_response = false;
    output.owns_compiled_code = false;
    output.owns_relation_name = false;
    output.compiled_ctes = &.{};
    output.owns_compiled_ctes = false;
    output.log_output = null;
    output.owns_log_output = false;
    output.log_events = &.{};
    output.owns_log_events = false;
    output.batch_results = null;
    output.owns_batch_results = false;
    errdefer freeResult(allocator, output);
    if (source.message) |value| output.message = try allocator.dupe(u8, value);
    if (source.compiled_artifact_code) |value| {
        output.compiled_artifact_code = try allocator.dupe(u8, value);
        output.owns_compiled_artifact_code = true;
    }
    if (source.preview) |value| {
        output.preview = try allocator.dupe(u8, value);
        output.owns_preview = true;
    }
    if (source.adapter_response) |response| if (source.owns_adapter_response) {
        output.adapter_response = .{ .include_nulls = response.include_nulls, .include_query_id = response.include_query_id };
        output.owns_adapter_response = true;
        if (response.message) |message| output.adapter_response.?.message = try allocator.dupe(u8, message);
        if (response.code) |code| output.adapter_response.?.code = try allocator.dupe(u8, code);
        output.adapter_response.?.rows_affected = response.rows_affected;
    };
    if (source.batch_results) |batches| {
        output.batch_results = .{};
        output.owns_batch_results = true;
        output.batch_results.?.successful = try allocator.dupe(types.SampleWindow, batches.successful);
        output.batch_results.?.failed = try allocator.dupe(types.SampleWindow, batches.failed);
    }
    if (source.log_output) |value| {
        output.log_output = try allocator.dupe(u8, value);
        output.owns_log_output = true;
    }
    if (source.log_events.len != 0) {
        const entries = try allocator.alloc(results.LogMessage, source.log_events.len);
        for (entries) |*entry| entry.* = .{ .message = "", .level = "info" };
        output.log_events = entries;
        output.owns_log_events = true;
        for (source.log_events, entries) |original, *entry| {
            entry.level = original.level;
            entry.is_print = original.is_print;
            entry.is_adapter_warning = original.is_adapter_warning;
            entry.message = try allocator.dupe(u8, original.message);
        }
    }
    if (source.owns_compiled_code) if (source.compiled_code) |value| {
        output.compiled_code = try allocator.dupe(u8, value);
        output.owns_compiled_code = true;
    };
    if (source.owns_relation_name) if (source.relation_name) |value| {
        output.relation_name = try allocator.dupe(u8, value);
        output.owns_relation_name = true;
    };
    if (source.compiled_ctes.len != 0) {
        const ctes = try allocator.alloc(types.ExtraCte, source.compiled_ctes.len);
        for (ctes) |*cte| cte.* = .{ .id = "", .sql = "" };
        output.compiled_ctes = ctes;
        output.owns_compiled_ctes = true;
        for (source.compiled_ctes, ctes) |original, *cte| {
            cte.id = original.id;
            cte.sql = try allocator.dupe(u8, original.sql);
        }
    }
    return output;
}
fn freeResult(allocator: std.mem.Allocator, output: results.NodeResult) void {
    if (output.owns_compiled_artifact_code) if (output.compiled_artifact_code) |sql| allocator.free(sql);
    if (output.owns_preview) if (output.preview) |preview| allocator.free(preview);
    if (output.owns_adapter_response) if (output.adapter_response) |response| {
        if (response.message) |message| allocator.free(message);
        if (response.code) |code| allocator.free(code);
    };
    if (output.owns_batch_results) if (output.batch_results) |batches| batches.deinit(allocator);
    if (output.owns_compiled_ctes) {
        for (output.compiled_ctes) |cte| if (cte.sql.len != 0) allocator.free(cte.sql);
        allocator.free(output.compiled_ctes);
    }
    if (output.message) |value| allocator.free(value);
    if (output.owns_compiled_code) if (output.compiled_code) |value| allocator.free(value);
    if (output.owns_relation_name) if (output.relation_name) |value| allocator.free(value);
    if (output.owns_log_output) if (output.log_output) |value| allocator.free(value);
    if (output.owns_log_events) {
        for (output.log_events) |entry| if (entry.message.len != 0) allocator.free(entry.message);
        allocator.free(output.log_events);
    }
}

pub fn emitLogMessages(runtime: types.Runtime, writer: *std.Io.Writer, id: []const u8, worker: u16, messages: []const results.LogMessage) !void {
    for (messages) |entry| {
        const displayed = if (entry.is_adapter_warning) try std.fmt.allocPrint(runtime.allocator, "DuckDB adapter: {s}", .{entry.message}) else entry.message;
        defer if (entry.is_adapter_warning) runtime.allocator.free(displayed);
        try writer.writeAll("{\"data\":{\"unique_id\":");
        try std.json.Stringify.value(id, .{}, writer);
        try writer.writeAll(",\"msg\":");
        try std.json.Stringify.value(displayed, .{}, writer);
        if (entry.is_adapter_warning) {
            try writer.writeAll(",\"name\":\"DuckDB\",\"args\":[],\"base_msg\":");
            try std.json.Stringify.value(entry.message, .{}, writer);
        }
        try writer.writeAll("},\"info\":{\"name\":");
        try std.json.Stringify.value(if (entry.is_adapter_warning) "AdapterEventWarning" else if (entry.is_print) "PrintEvent" else if (std.mem.eql(u8, entry.level, "debug")) "JinjaLogDebug" else "JinjaLogInfo", .{}, writer);
        if (entry.is_adapter_warning) {
            try writer.writeAll(",\"msg\":");
            try std.json.Stringify.value(displayed, .{}, writer);
        }
        try writer.writeAll(",\"level\":");
        try std.json.Stringify.value(entry.level, .{}, writer);
        try writer.writeAll(",\"thread\":");
        if (worker == 0) try writer.writeAll("\"MainThread\"") else try writer.print("\"Thread-{d}\"", .{worker});
        try writer.writeAll(",\"ts\":");
        try clock.writeTimestamp(writer, clock.now(runtime.io));
        try writer.writeAll(",\"invocation_id\":");
        if (runtime.invocation) |invocation| try std.json.Stringify.value(&invocation.id, .{}, writer) else try writer.writeAll("null");
        try writer.writeAll("}}\n");
    }
    try writer.flush();
}

fn emitMessages(runtime: types.Runtime, options: types.Options, writer: *std.Io.Writer, id: []const u8, worker: u16, messages: []const u8) !void {
    if (options.log_format != .json) {
        try writer.writeAll(messages);
        try writer.flush();
        return;
    }
    var lines = std.mem.splitScalar(u8, messages, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        try writer.writeAll("{\"data\":{\"unique_id\":");
        try std.json.Stringify.value(id, .{}, writer);
        try writer.writeAll(",\"msg\":");
        try std.json.Stringify.value(line, .{}, writer);
        try writer.writeAll("},\"info\":{\"name\":\"JinjaLog\",\"level\":\"info\",\"thread\":");
        if (worker == 0) try writer.writeAll("\"MainThread\"") else try writer.print("\"Thread-{d}\"", .{worker});
        try writer.writeAll(",\"ts\":");
        try clock.writeTimestamp(writer, clock.now(runtime.io));
        try writer.writeAll(",\"invocation_id\":");
        if (runtime.invocation) |invocation| try std.json.Stringify.value(&invocation.id, .{}, writer) else try writer.writeAll("null");
        try writer.writeAll("}}\n");
    }
    try writer.flush();
}

pub fn emitEvent(runtime: types.Runtime, options: types.Options, writer: *std.Io.Writer, name: []const u8, id: []const u8, status: []const u8, worker: u16, execution_time: f64) !void {
    if (options.log_format != .json) return;
    try writer.writeAll("{\"data\":{\"unique_id\":");
    try std.json.Stringify.value(id, .{}, writer);
    try writer.writeAll(",\"status\":");
    try std.json.Stringify.value(status, .{}, writer);
    try writer.print(",\"execution_time\":{d}}},\"info\":{{\"name\":", .{execution_time});
    try std.json.Stringify.value(name, .{}, writer);
    const level = if (std.mem.eql(u8, status, "error") or std.mem.eql(u8, status, "fail") or std.mem.eql(u8, status, "runtime error")) "error" else if (std.mem.eql(u8, status, "warn")) "warn" else "info";
    try writer.writeAll(",\"level\":");
    try std.json.Stringify.value(level, .{}, writer);
    try writer.writeAll(",\"thread\":");
    if (worker == 0) try writer.writeAll("\"MainThread\"") else try writer.print("\"Thread-{d}\"", .{worker});
    try writer.writeAll(",\"ts\":");
    try clock.writeTimestamp(writer, clock.now(runtime.io));
    try writer.writeAll(",\"invocation_id\":");
    if (runtime.invocation) |invocation| try std.json.Stringify.value(&invocation.id, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll("}}\n");
    try writer.flush();
}

test "thread counts reject ignored or invalid concurrency values" {
    try std.testing.expectEqual(@as(u16, 4), try parseThreadCount("4"));
    for ([_][]const u8{ "0", "-1", "1.5", "257", "bogus", "" }) |value| try std.testing.expectError(error.InvalidThreadCount, parseThreadCount(value));
}
