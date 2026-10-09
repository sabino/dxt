//! Shared, bounded native query facade for semantic/metric physical plans.
const std = @import("std");
const types = @import("types.zig");
const cross = @import("cross_database.zig");
const run = @import("cross_database_run.zig");
const yaml = @import("yaml.zig");
const values = @import("config_value.zig");
const adapter = @import("adapter.zig");
const Runtime = types.Runtime;

pub const RelationBinding = struct {
    logical_id: []const u8,
    relation_name: []const u8,
    connection: ?[]const u8 = null,
    source_relation: []const u8,
    source_query: ?[]const u8 = null,
    sensitivity: []const u8 = "public",
    estimated_rows: ?u64 = null,
    estimated_bytes: ?u64 = null,
};
pub const QueryOptions = struct {
    connection: []const u8,
    execution_connection: ?[]const u8 = null,
    policy: cross.Options = .{},
    budget: cross.Budget = .{},
};
pub const QueryOutcome = struct {
    result: adapter.QueryResult,
    columns: []@import("cross_database_read.zig").Column,
    movement_plan_json: []const u8,
    execution_json: ?[]const u8 = null,
    pub fn deinit(self: *QueryOutcome, allocator: std.mem.Allocator) void {
        self.result.deinit(allocator);
        for (self.columns) |column| {
            allocator.free(column.name);
            allocator.free(column.type_sql);
        }
        allocator.free(self.columns);
        allocator.free(self.movement_plan_json);
        if (self.execution_json) |json| allocator.free(json);
        self.* = undefined;
    }
};

/// All plan/profile storage belongs to this document; credentials are never
/// included in json(). The physical plan can be inspected without opening DBs.
pub const QueryPlan = struct {
    arena: *std.heap.ArenaAllocator,
    owner: std.mem.Allocator,
    value: cross.Plan,
    root: []const u8,
    pub fn deinit(self: *QueryPlan) void {
        self.arena.deinit();
        self.owner.destroy(self.arena);
        self.* = undefined;
    }
    pub fn json(self: *const QueryPlan, allocator: std.mem.Allocator) ![]const u8 {
        return cross.planJson(allocator, self.value);
    }
};

pub fn planQuery(runtime: Runtime, project_dir: []const u8, options: QueryOptions, sql: []const u8, bindings: []const RelationBinding) !QueryPlan {
    const arena = try runtime.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(runtime.allocator);
    errdefer {
        arena.deinit();
        runtime.allocator.destroy(arena);
    }
    const allocator = arena.allocator();
    const rt: Runtime = .{ .allocator = allocator, .io = runtime.io, .environment = runtime.environment };
    const root = try std.Io.Dir.cwd().realPathFileAlloc(runtime.io, project_dir, allocator);
    const path = try cross.projectPath(rt, root, options.policy.config);
    const source = try std.Io.Dir.cwd().readFileAlloc(runtime.io, path, allocator, .limited(16 * 1024 * 1024));
    var document = try yaml.parse(allocator, source);
    defer document.deinit();
    var config = try values.clone(allocator, document.value);
    if (config != .object) return error.InvalidCrossDatabaseConfig;
    const connections = values.get(config, "connections") orelse return error.MissingCrossDatabaseConnections;
    if (values.get(connections, options.connection) == null) return error.MissingCrossDatabaseConnection;
    if (options.execution_connection) |name| if (values.get(connections, name) == null) return error.MissingCrossDatabaseConnection;
    for (bindings) |binding| if (values.get(connections, binding.connection orelse options.connection) == null) return error.MissingCrossDatabaseConnection;
    const used = try allocator.alloc(bool, bindings.len);
    @memset(used, false);
    const rewritten = try bindRelations(allocator, sql, bindings, used);
    var inputs: std.json.Value = .null;
    for (bindings, used, 0..) |binding, selected, index| {
        if (!selected) continue;
        var input: std.json.Value = .null;
        try values.put(allocator, &input, "connection", .{ .string = binding.connection orelse options.connection });
        try values.put(allocator, &input, "logical_id", .{ .string = binding.logical_id });
        try values.put(allocator, &input, "sensitivity", .{ .string = binding.sensitivity });
        if (binding.source_query) |query_sql| try values.put(allocator, &input, "query", .{ .string = query_sql }) else try values.put(allocator, &input, "relation", .{ .string = binding.source_relation });
        if (binding.estimated_rows) |amount| try values.put(allocator, &input, "estimated_rows", .{ .integer = std.math.cast(i64, amount) orelse return error.InvalidCrossDatabaseEstimate });
        if (binding.estimated_bytes) |amount| try values.put(allocator, &input, "estimated_bytes", .{ .integer = std.math.cast(i64, amount) orelse return error.InvalidCrossDatabaseEstimate });
        try values.put(allocator, &inputs, try std.fmt.allocPrint(allocator, "r{d}", .{index}), input);
    }
    if (inputs == .null) return error.MissingCrossDatabaseInputs;
    var model: std.json.Value = .null;
    try values.put(allocator, &model, "destination", .{ .string = options.connection });
    if (options.execution_connection) |name| try values.put(allocator, &model, "execution_connection", .{ .string = name });
    try values.put(allocator, &model, "sql", .{ .string = rewritten });
    try values.put(allocator, &model, "inputs", inputs);
    const budget_json = try std.json.Stringify.valueAlloc(allocator, options.budget, .{});
    const budget = try std.json.parseFromSlice(std.json.Value, allocator, budget_json, .{});
    defer budget.deinit();
    try values.put(allocator, &model, "budget", budget.value);
    var models: std.json.Value = .null;
    try values.put(allocator, &models, "metric_query", model);
    try values.put(allocator, &config, "models", models);
    var policy = options.policy;
    policy.select = null;
    return .{ .arena = arena, .owner = runtime.allocator, .root = root, .value = try cross.buildPlan(rt, policy, root, source, config) };
}

pub fn query(runtime: Runtime, project_dir: []const u8, options: QueryOptions, sql: []const u8, bindings: []const RelationBinding) !QueryOutcome {
    var plan = try planQuery(runtime, project_dir, options, sql, bindings);
    defer plan.deinit();
    for (plan.value.models) |model| if (model.denied != null) return error.CrossDatabasePolicyDenied;
    if (options.policy.plan_hash) |hash| if (!std.mem.eql(u8, hash, plan.value.hash)) return error.CrossDatabasePlanChanged;
    return executeQueryPlan(runtime, &plan);
}

/// Execute one already-reviewed physical query plan, retaining its exact hash
/// and JSON. The document must remain alive until this call returns.
pub fn executeQueryPlan(runtime: Runtime, plan: *QueryPlan) !QueryOutcome {
    for (plan.value.models) |model| if (model.denied != null) return error.CrossDatabasePolicyDenied;
    const json = try plan.json(runtime.allocator);
    errdefer runtime.allocator.free(json);
    const arena_runtime: Runtime = .{ .allocator = plan.arena.allocator(), .io = runtime.io, .environment = runtime.environment };
    var metadata = @import("invocation.zig").Metadata.init(runtime.io, runtime.environment);
    var record: run.Record = .{ .model = plan.value.models[0].name, .run_id = &metadata.id, .target_lock = "not required for read-only query" };
    var attempts: std.ArrayList(@import("cross_database_schedule.zig").Attempt) = .empty;
    while (true) {
        record.attempt_count += 1;
        record.stage_artifacts = &.{};
        record.status = "running";
        record.error_name = null;
        const started = @import("cross_database_catalog.zig").epoch(runtime.io);
        const before_rows = record.rows_moved;
        const before_bytes = record.bytes_moved;
        var failure: ?anyerror = null;
        var output = run.queryPlan(runtime, arena_runtime, plan.root, &plan.value, &record) catch |err| blk: {
            failure = err;
            break :blk run.TypedQueryResult{ .result = .{}, .columns = &.{} };
        };
        errdefer {
            output.result.deinit(runtime.allocator);
            for (output.columns) |column| {
                runtime.allocator.free(column.name);
                runtime.allocator.free(column.type_sql);
            }
            runtime.allocator.free(output.columns);
        }
        try attempts.append(arena_runtime.allocator, .{ .number = record.attempt_count, .started_epoch = started, .finished_epoch = @import("cross_database_catalog.zig").epoch(runtime.io), .status = if (failure == null) "success" else "error", .error_name = if (failure) |err| @errorName(err) else null, .rows_moved = record.rows_moved -| before_rows, .bytes_moved = record.bytes_moved -| before_bytes });
        record.attempts = attempts.items;
        if (failure) |err| {
            record.status = "error";
            record.error_name = @errorName(err);
            if (!@import("cross_database_schedule.zig").retryable(err) or record.attempt_count > plan.value.scheduler.max_retries) {
                record.cleanup = "complete";
                try @import("cross_database_catalog.zig").record(runtime, plan.root, &plan.value, record.run_id, &.{record});
                return err;
            }
            record.throttled_connection = record.active_connection;
            const delay = @min(5000, plan.value.scheduler.retry_delay_ms *| (@as(u64, 1) << @intCast(record.attempt_count - 1)));
            try std.Io.sleep(runtime.io, .fromMilliseconds(@intCast(delay)), .awake);
            continue;
        }
        try @import("cross_database_catalog.zig").record(runtime, plan.root, &plan.value, record.run_id, &.{record});
        const execution_json = try std.json.Stringify.valueAlloc(runtime.allocator, record, .{});
        return .{ .result = output.result, .columns = output.columns, .movement_plan_json = json, .execution_json = execution_json };
    }
}

/// Bind only lexical relation occurrences; string literals and unused semantic
/// resources never initiate movement. SQL comments are already normalized.
fn bindRelations(allocator: std.mem.Allocator, sql: []const u8, bindings: []const RelationBinding, used: []bool) ![]const u8 {
    const normalized = try cross.normalizeReadQuery(allocator, sql);
    defer allocator.free(normalized);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var at: usize = 0;
    while (at < normalized.len) {
        var found: ?usize = null;
        for (bindings, 0..) |binding, index| {
            if (binding.relation_name.len == 0) return error.InvalidCrossDatabaseRelation;
            if (!std.mem.startsWith(u8, normalized[at..], binding.relation_name)) continue;
            const end = at + binding.relation_name.len;
            if ((at != 0 and wordChar(normalized[at - 1])) or (end < normalized.len and wordChar(normalized[end]))) continue;
            if (found != null) return error.AmbiguousCrossDatabaseInput;
            found = index;
        }
        if (found) |index| {
            used[index] = true;
            try out.writer.print("{{{{ input('r{d}') }}}}", .{index});
            at += bindings[index].relation_name.len;
            continue;
        }
        const start = at;
        if (normalized[at] == '\'' or normalized[at] == '"') {
            const quote = normalized[at];
            at += 1;
            while (at < normalized.len) {
                const char = normalized[at];
                at += 1;
                if (char == quote) {
                    if (at < normalized.len and normalized[at] == quote) {
                        at += 1;
                        continue;
                    }
                    break;
                }
            }
        } else if (normalized[at] == '$') {
            var end = at + 1;
            while (end < normalized.len and wordChar(normalized[end])) end += 1;
            if (end < normalized.len and normalized[end] == '$') {
                const tag = normalized[at .. end + 1];
                at = (std.mem.indexOfPos(u8, normalized, end + 1, tag) orelse return error.InvalidCrossDatabaseQuery) + tag.len;
            } else at += 1;
        } else at += 1;
        try out.writer.writeAll(normalized[start..at]);
    }
    return out.toOwnedSlice();
}
fn wordChar(char: u8) bool {
    return std.ascii.isAlphanumeric(char) or char == '_';
}

test "semantic relation bindings skip literals and never extract unused resources" {
    var used = [_]bool{ false, false };
    const bindings = [_]RelationBinding{
        .{ .logical_id = "semantic.a", .relation_name = "\"logical\".\"a\"", .source_relation = "public.a" },
        .{ .logical_id = "semantic.unused", .relation_name = "\"logical\".\"unused\"", .source_relation = "public.unused" },
    };
    const sql = try bindRelations(std.testing.allocator, "select '\"logical\".\"a\"' as text from \"logical\".\"a\";", &bindings, &used);
    defer std.testing.allocator.free(sql);
    try std.testing.expectEqualStrings("select '\"logical\".\"a\"' as text from {{ input('r0') }}", sql);
    try std.testing.expect(used[0] and !used[1]);
}
