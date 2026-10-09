//! Explicit, policy checked physical plans for named native database connections.
const std = @import("std");
const types = @import("types.zig");
const yaml = @import("yaml.zig");
const values = @import("config_value.zig");
const adapter = @import("adapter.zig");
const profile = @import("profile.zig");
const jinja = @import("jinja.zig");
const invocation = @import("invocation.zig");
pub const Runtime = types.Runtime;
const Dir = std.Io.Dir;

pub const Mode = enum { plan, run, recover, cleanup, debug, catalog };
pub const Options = struct {
    mode: Mode = .plan,
    project_dir: []const u8 = ".",
    config: []const u8 = "dxt_connections.yml",
    profiles_dir: ?[]const u8 = null,
    select: ?[]const u8 = null,
    output: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
    plan_hash: ?[]const u8 = null,
    allow_movement: bool = false,
    allow_sensitive: bool = false,
    allow_raw_extract: bool = false,
    allow_retention: bool = false,
    full_refresh: bool = false,
    probe_cancellation: bool = false,
    max_concurrent_tasks: ?u16 = null,
    max_retries: ?u8 = null,
    retry_delay_ms: ?u64 = null,
    max_rows: ?u64 = null,
    max_bytes: ?u64 = null,
    max_memory_bytes: ?u64 = null,
    max_spill_bytes: ?u64 = null,
    older_than_seconds: ?u64 = null,
};

pub fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: dxt cross-database <plan|run|recover|cleanup|debug|catalog> [options]
        \\
        \\Plan and execute declared source reductions through native DuckDB/PostgreSQL
        \\connections, with explicit movement policy and destination-local transactions.
        \\
        \\  --project-dir <path>     Project containing dxt_connections.yml.
        \\  --config <path>          Secret-free named connections and model input boundaries.
        \\  --profiles-dir <path>    Directory containing dbt profiles.yml credentials.
        \\  --select <model>         Select one named cross-database model.
        \\  --output <path>          Plan artifact path (default: target/dxt_plan.json).
        \\  --plan-hash <sha256>     Require an unchanged reviewed plan before execution.
        \\  --allow-movement        Authorize movement permitted by connection policy.
        \\  --allow-sensitive       Authorize sensitive movement permitted by trust policy.
        \\  --allow-raw-extract     Authorize a declared unfiltered full-table extraction.
        \\  --allow-retention       Authorize declared cached/snapshot stage retention.
        \\  --max-rows <count>       Override the plan's movement row budget.
        \\  --max-bytes <bytes>      Override the plan's movement byte budget.
        \\  --max-memory-bytes <n>   Bound native extraction and DuckDB working memory.
        \\  --max-spill-bytes <n>    Bound DuckDB temporary storage (default: no spill).
        \\  --full-refresh           Rebuild incremental output and reset source watermarks.
        \\  --run-id <uuid>          Recover one recorded run's cleanup/commit state.
        \\  --older-than-seconds <n> Cleanup retained stages older than n seconds.
        \\  --probe-cancellation     Verify native cancellation during connection debug.
        \\  --max-concurrent-tasks <n> Bound the native task scheduler (1..32).
        \\  --max-retries <n>        Retry known aborted transactions or target contention.
        \\  --retry-delay-ms <n>     Initial exponential backoff (0..10000 ms).
        \\
    );
}

pub fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
    if (args.len == 0) return error.MissingCrossDatabaseMode;
    options.mode = std.meta.stringToEnum(Mode, args[0]) orelse return error.InvalidCrossDatabaseMode;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (eq(arg, "--allow-movement")) options.allow_movement = true else if (eq(arg, "--allow-sensitive")) options.allow_sensitive = true else if (eq(arg, "--allow-raw-extract")) options.allow_raw_extract = true else if (eq(arg, "--allow-retention")) options.allow_retention = true else if (eq(arg, "--full-refresh")) options.full_refresh = true else if (eq(arg, "--probe-cancellation")) options.probe_cancellation = true else {
            index += 1;
            if (index >= args.len or args[index].len == 0 or std.mem.startsWith(u8, args[index], "--")) return error.MissingCrossDatabaseOptionValue;
            const value = args[index];
            if (eq(arg, "--project-dir")) options.project_dir = value else if (eq(arg, "--config")) options.config = value else if (eq(arg, "--profiles-dir")) options.profiles_dir = value else if (eq(arg, "--select")) options.select = value else if (eq(arg, "--output")) options.output = value else if (eq(arg, "--run-id")) options.run_id = value else if (eq(arg, "--plan-hash")) options.plan_hash = value else if (eq(arg, "--max-rows")) options.max_rows = try number(value) else if (eq(arg, "--max-bytes")) options.max_bytes = try number(value) else if (eq(arg, "--max-memory-bytes")) options.max_memory_bytes = try number(value) else if (eq(arg, "--max-spill-bytes")) options.max_spill_bytes = try number(value) else if (eq(arg, "--older-than-seconds")) options.older_than_seconds = try number(value) else if (eq(arg, "--max-concurrent-tasks")) options.max_concurrent_tasks = std.math.cast(u16, try number(value)) orelse return error.InvalidCrossDatabaseScheduler else if (eq(arg, "--max-retries")) options.max_retries = std.math.cast(u8, try number(value)) orelse return error.InvalidCrossDatabaseScheduler else if (eq(arg, "--retry-delay-ms")) options.retry_delay_ms = try number(value) else return error.InvalidCrossDatabaseOption;
        }
    }
    if (options.mode == .recover and options.run_id == null) return error.MissingCrossDatabaseRunId;
    if (options.run_id) |id| if (!validRunId(id)) return error.InvalidCrossDatabaseRunId;
    return options;
}

pub const Budget = struct {
    max_rows: u64 = 100000,
    max_bytes: u64 = 64 * 1024 * 1024,
    max_memory_bytes: u64 = 128 * 1024 * 1024,
    max_spill_bytes: u64 = 0,
    max_objects: u64 = 64,
    max_query_seconds: u64 = 60,
    max_cost: ?f64 = null,
};
pub const Connection = struct {
    name: []const u8,
    profile_name: []const u8,
    target: []const u8,
    adapter_type: []const u8,
    role: []const u8,
    trust_domain: []const u8,
    allowed_destinations: []const []const u8,
    egress_per_gib: f64 = 0,
    limits: @import("cross_database_schedule.zig").Limits = .{},
    // Credentials and local paths remain in memory and are never serialized.
    identity: types.AdapterIdentity,
};
pub const Input = struct {
    name: []const u8,
    logical_id: []const u8,
    source_name: ?[]const u8,
    table_name: ?[]const u8,
    connection: usize,
    query: []const u8,
    query_hash: []const u8,
    sensitivity: []const u8,
    reduction: []const u8,
    estimated_rows: ?u64,
    estimated_bytes: ?u64,
    raw_extract: bool,
    moved: bool,
    incremental_key: ?[]const u8 = null,
    watermark: ?[]const u8 = null,
    lookback_seconds: u64 = 0,
    stage_mode: []const u8 = "ephemeral",
    stage_connection: ?usize = null,
    stage_ttl_seconds: u64 = 0,
    stage_version: ?[]const u8 = null,
    estimate_confidence: []const u8 = "unknown",
    estimate_observed_epoch: ?u64 = null,
    denied: ?[]const u8 = null,
};
pub const Model = struct {
    name: []const u8,
    destination: usize,
    execution_connection: usize,
    schema: []const u8,
    identifier: []const u8,
    sql: []const u8,
    inputs: []Input,
    strategy: []const u8,
    execution_engine: []const u8,
    budget: Budget,
    materialized: []const u8 = "table",
    incremental_strategy: []const u8 = "merge",
    unique_key: ?[]const u8 = null,
    full_refresh: bool = false,
    estimated_rows: u64 = 0,
    estimated_bytes: u64 = 0,
    estimated_cost: f64 = 0,
    estimate_confidence: []const u8 = "declared",
    depends_on: []const []const u8 = &.{},
    alternatives: []const @import("cross_database_cost.zig").Alternative = &.{},
    denied: ?[]const u8 = null,
};
pub const Plan = struct { hash: []const u8, definition_hash: []const u8 = "", catalog_generation: u64 = 0, scheduler: @import("cross_database_schedule.zig").Settings = .{}, connections: []Connection, models: []Model };
pub const RelationBinding = @import("cross_database_query.zig").RelationBinding;
pub const QueryOptions = @import("cross_database_query.zig").QueryOptions;
pub const QueryOutcome = @import("cross_database_query.zig").QueryOutcome;
pub const QueryPlan = @import("cross_database_query.zig").QueryPlan;
pub const planQuery = @import("cross_database_query.zig").planQuery;
pub const query = @import("cross_database_query.zig").query;
pub const executeQueryPlan = @import("cross_database_query.zig").executeQueryPlan;
pub const materializeQueryResult = @import("cross_database_run.zig").materializeQueryResult;
pub const openConnection = @import("cross_database_run.zig").open;
pub const DuckDBPool = adapter.DuckDBPool;

pub fn command(runtime: Runtime, options: Options, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(runtime.allocator);
    defer arena.deinit();
    const rt: Runtime = .{ .allocator = arena.allocator(), .io = runtime.io, .environment = runtime.environment };
    const root = try Dir.cwd().realPathFileAlloc(rt.io, options.project_dir, rt.allocator);
    const path = try projectPath(rt, root, options.config);
    const source = try Dir.cwd().readFileAlloc(rt.io, path, rt.allocator, .limited(16 * 1024 * 1024));
    var diagnostic: yaml.Diagnostic = .{};
    var document = yaml.parseWithDiagnostics(rt.allocator, source, &diagnostic) catch |err| {
        try stderr.print("error: invalid cross-database YAML at line {d}, column {d}: {s}\n", .{ diagnostic.line, diagnostic.column, diagnostic.message });
        return err;
    };
    defer document.deinit();
    var plan = try buildPlan(rt, options, root, source, document.value);
    if (options.mode == .debug) return @import("cross_database_probe.zig").execute(runtime, rt, root, &plan, options, stdout, stderr);
    if (options.mode == .catalog) {
        var store = try @import("cross_database_catalog.zig").load(rt, root);
        defer store.deinit();
        const json = try std.json.Stringify.valueAlloc(rt.allocator, store.value, .{});
        try writeAtomic(rt, try projectPath(rt, root, options.output orelse "target/dxt_catalog.json"), json);
        try stdout.print("Catalog generation {d}: {d} observed source boundaries / {d} indexed runs\n", .{ store.value.generation, store.value.relation_stats.len, store.value.runs.len });
        return;
    }
    const plan_path = try projectPath(rt, root, options.output orelse "target/dxt_plan.json");
    try writePlan(rt, plan_path, plan);
    if (options.mode == .plan) {
        try stdout.print("Cross-database plan {s}\n", .{plan.hash});
        for (plan.models) |model| try stdout.print("  {s}: {s}, estimated {d} rows / {d} bytes, {s}\n", .{ model.name, model.strategy, model.estimated_rows, model.estimated_bytes, model.denied orelse "permitted" });
        return;
    }
    if (options.plan_hash) |hash| if (!eq(hash, plan.hash)) return error.CrossDatabasePlanChanged;
    if (options.mode == .recover) return @import("cross_database_run.zig").recover(runtime, rt, root, options, &plan, stdout);
    if (options.mode == .cleanup) return @import("cross_database_cache.zig").cleanup(runtime, rt, root, options, &plan, stdout);
    for (plan.models) |model| if (model.denied) |reason| {
        try stderr.print("error: cross-database model {s} denied before source execution: {s}\n", .{ model.name, reason });
        return error.CrossDatabasePolicyDenied;
    };
    return @import("cross_database_run.zig").execute(runtime, rt, root, &plan, stdout, stderr);
}

pub fn buildPlan(runtime: Runtime, options: Options, root: []const u8, source: []const u8, config: std.json.Value) !Plan {
    if (config != .object) return error.InvalidCrossDatabaseConfig;
    const connection_config = values.get(config, "connections") orelse return error.MissingCrossDatabaseConnections;
    if (connection_config != .object or connection_config.object.count() == 0) return error.MissingCrossDatabaseConnections;
    if (connection_config.object.count() > 64) return error.CrossDatabaseConnectionBudgetExceeded;
    const profiles_dir = options.profiles_dir orelse if (runtime.environment) |env| env.get("DBT_PROFILES_DIR") orelse root else root;
    const profiles_path = try std.fs.path.join(runtime.allocator, &.{ profiles_dir, "profiles.yml" });
    const profiles_text = try Dir.cwd().readFileAlloc(runtime.io, profiles_path, runtime.allocator, .limited(16 * 1024 * 1024));
    var connections: std.ArrayList(Connection) = .empty;
    var iterator = connection_config.object.iterator();
    while (iterator.next()) |entry| {
        if (!identifier(entry.key_ptr.*) or entry.value_ptr.* != .object) return error.InvalidCrossDatabaseConnection;
        const raw = entry.value_ptr.*;
        const profile_name = try fieldString(raw, "profile");
        const target = try fieldString(raw, "target");
        var identity = try profile.parseAdapterIdentityTextWithEnvironment(runtime.allocator, profiles_text, profile_name, target, runtime.environment);
        if (!eq(identity.adapter_type, "duckdb") and !eq(identity.adapter_type, "postgres")) return error.UnsupportedCrossDatabaseAdapter;
        if (identity.database_path != null) identity.database_path_base = profiles_dir;
        const role = try optionalFieldString(raw, "role") orelse "both";
        if (!eq(role, "both") and !eq(role, "source") and !eq(role, "destination") and !eq(role, "stage")) return error.InvalidCrossDatabaseConnectionRole;
        const capacity = values.get(raw, "limits") orelse .null;
        const queries = try optionalUnsigned(capacity, "max_queries") orelse 1;
        const readers = try optionalUnsigned(capacity, "max_streaming_readers") orelse 1;
        const loaders = try optionalUnsigned(capacity, "max_loaders") orelse 1;
        if (queries == 0 or queries > 256 or readers == 0 or readers > 256 or loaders == 0 or loaders > 256) return error.InvalidCrossDatabaseConnectionLimit;
        try connections.append(runtime.allocator, .{
            .name = entry.key_ptr.*,
            .profile_name = profile_name,
            .target = target,
            .adapter_type = identity.adapter_type,
            .role = role,
            .trust_domain = try optionalFieldString(raw, "trust_domain") orelse "default",
            .allowed_destinations = try strings(runtime.allocator, values.get(raw, "allowed_destinations") orelse .null),
            .egress_per_gib = try optionalFloat(raw, "egress_per_gib") orelse 0,
            .identity = identity,
            .limits = .{ .max_queries = @intCast(queries), .max_streaming_readers = @intCast(readers), .max_loaders = @intCast(loaders) },
        });
    }
    const model_config = values.get(config, "models") orelse return error.MissingCrossDatabaseModels;
    if (model_config != .object or model_config.object.count() == 0) return error.MissingCrossDatabaseModels;
    if (model_config.object.count() > 1024) return error.CrossDatabaseModelBudgetExceeded;
    const scheduling = values.get(config, "scheduler") orelse .null;
    const concurrency = options.max_concurrent_tasks orelse try optionalUnsigned(scheduling, "max_concurrent_tasks") orelse 1;
    const retries = options.max_retries orelse try optionalUnsigned(scheduling, "max_retries") orelse 2;
    const retry_delay = options.retry_delay_ms orelse try optionalUnsigned(scheduling, "retry_delay_ms") orelse 50;
    const scheduling_memory = try optionalUnsigned(scheduling, "max_memory_bytes") orelse 512 * 1024 * 1024;
    if (concurrency == 0 or concurrency > 32 or retries > 8 or retry_delay > 10000 or scheduling_memory == 0) return error.InvalidCrossDatabaseScheduler;
    const scheduler_settings: @import("cross_database_schedule.zig").Settings = .{ .max_concurrent_tasks = @intCast(concurrency), .max_retries = @intCast(retries), .retry_delay_ms = retry_delay, .max_memory_bytes = scheduling_memory };
    var selected_models: std.StringHashMap(void) = .init(runtime.allocator);
    if (options.select) |selected| {
        if (values.get(model_config, selected) == null) return error.MissingCrossDatabaseSelectedModel;
        try selected_models.put(selected, {});
        var changed = true;
        while (changed) {
            changed = false;
            var selected_iterator = model_config.object.iterator();
            while (selected_iterator.next()) |entry| {
                if (!selected_models.contains(entry.key_ptr.*)) continue;
                for (try strings(runtime.allocator, values.get(entry.value_ptr.*, "depends_on") orelse .null)) |dependency| {
                    if (values.get(model_config, dependency) == null) return error.MissingCrossDatabaseModelDependency;
                    if (!selected_models.contains(dependency)) {
                        try selected_models.put(dependency, {});
                        changed = true;
                    }
                }
            }
        }
    }
    var catalog = try @import("cross_database_catalog.zig").load(runtime, root);
    defer catalog.deinit();
    const catalog_age = try optionalUnsigned(values.get(config, "catalog") orelse .null, "max_age_seconds") orelse 86400;
    var models: std.ArrayList(Model) = .empty;
    var model_iterator = model_config.object.iterator();
    const policy = values.get(config, "policy") orelse .null;
    var fingerprint: std.Io.Writer.Allocating = .init(runtime.allocator);
    try fingerprint.writer.writeAll(source);
    // Bind reviewed plans to physical destinations without serializing paths,
    // hosts or credentials. A profile edit must invalidate execution/recovery.
    for (connections.items) |connection| {
        try fingerprint.writer.print("\n{s}/{s}/{s}/{s}/{s}\n", .{ connection.name, connection.identity.adapter_type, connection.identity.database_path orelse "", connection.identity.database_path_base orelse "", connection.identity.connection_info orelse "" });
    }
    try fingerprint.writer.print("\nselect={s};movement={};sensitive={};raw={};retention={};refresh={}\n", .{ options.select orelse "", options.allow_movement, options.allow_sensitive, options.allow_raw_extract, options.allow_retention, options.full_refresh });
    while (model_iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        if (!identifier(name) or entry.value_ptr.* != .object) return error.InvalidCrossDatabaseModel;
        if (options.select != null and !selected_models.contains(name)) continue;
        const raw = entry.value_ptr.*;
        const destination = try connectionIndex(connections.items, try fieldString(raw, "destination"));
        const execution_connection = if (try optionalFieldString(raw, "execution_connection")) |name_value| try connectionIndex(connections.items, name_value) else destination;
        if (execution_connection != destination and !eq(connections.items[execution_connection].adapter_type, "duckdb")) return error.InvalidCrossDatabaseEmbeddedConnection;
        if (eq(connections.items[execution_connection].role, "source")) return error.InvalidCrossDatabaseDestination;
        if (eq(connections.items[destination].role, "source") or eq(connections.items[destination].role, "stage")) return error.InvalidCrossDatabaseDestination;
        const budget = try parseBudget(raw, options);
        const input_config = values.get(raw, "inputs") orelse return error.MissingCrossDatabaseInputs;
        if (input_config != .object or input_config.object.count() == 0) return error.MissingCrossDatabaseInputs;
        var inputs: std.ArrayList(Input) = .empty;
        var input_iterator = input_config.object.iterator();
        while (input_iterator.next()) |input_entry| {
            const input_name = input_entry.key_ptr.*;
            if (!identifier(input_name) or input_name.len > 48 or input_entry.value_ptr.* != .object) return error.InvalidCrossDatabaseInput;
            const input_raw = input_entry.value_ptr.*;
            const connection = try connectionIndex(connections.items, try fieldString(input_raw, "connection"));
            if (eq(connections.items[connection].role, "destination")) return error.InvalidCrossDatabaseSource;
            const query_sql = try inputQuery(runtime.allocator, input_raw);
            try validateReadQuery(query_sql);
            const source_reference = try strings(runtime.allocator, values.get(input_raw, "source") orelse .null);
            if (source_reference.len != 0 and source_reference.len != 2) return error.InvalidCrossDatabaseInput;
            const moved = connection != execution_connection;
            const sensitivity = try optionalFieldString(input_raw, "sensitivity") orelse "public";
            const raw_extract = values.get(input_raw, "query") == null and values.get(input_raw, "columns") == null and values.get(input_raw, "projection") == null and values.get(input_raw, "filter") == null and values.get(input_raw, "group_by") == null;
            const incremental_config = values.get(input_raw, "incremental") orelse .null;
            if (incremental_config != .null and incremental_config != .object) return error.InvalidCrossDatabaseInput;
            var input: Input = .{
                .name = input_name,
                .logical_id = try optionalFieldString(input_raw, "logical_id") orelse input_name,
                .source_name = if (source_reference.len == 2) source_reference[0] else null,
                .table_name = if (source_reference.len == 2) source_reference[1] else null,
                .connection = connection,
                .query = query_sql,
                .query_hash = try digest(runtime.allocator, query_sql),
                .sensitivity = sensitivity,
                .reduction = if (values.get(input_raw, "query") != null) "declared source subquery" else if (!raw_extract) "source projection/filter/aggregate" else "raw extraction",
                .estimated_rows = try optionalUnsigned(input_raw, "estimated_rows"),
                .estimated_bytes = try optionalUnsigned(input_raw, "estimated_bytes"),
                .raw_extract = raw_extract,
                .moved = moved,
                .incremental_key = try optionalFieldString(incremental_config, "key"),
                .watermark = try optionalFieldString(incremental_config, "watermark"),
                .lookback_seconds = try optionalUnsigned(incremental_config, "lookback_seconds") orelse 0,
            };
            if (moved) {
                const origin = connections.items[connection];
                const target = connections.items[execution_connection];
                if (!options.allow_movement and !try optionalBool(policy, "allow_movement", false)) input.denied = "data movement requires --allow-movement or policy.allow_movement";
                if (origin.allowed_destinations.len != 0 and !contains(origin.allowed_destinations, target.name)) input.denied = "destination is outside the source connection's allowed destinations";
                if (!eq(sensitivity, "public") and !eq(sensitivity, "internal") and (!options.allow_sensitive or !eq(origin.trust_domain, target.trust_domain))) input.denied = "sensitive data movement requires explicit authorization inside one trust domain";
                if (raw_extract and !options.allow_raw_extract and !try optionalBool(policy, "allow_raw_extract", false)) input.denied = "full-table extraction requires --allow-raw-extract or policy.allow_raw_extract";
            }
            if (values.get(input_raw, "stage")) |stage| {
                if (stage != .object) return error.InvalidCrossDatabaseStage;
                input.stage_mode = try optionalFieldString(stage, "mode") orelse "ephemeral";
                if (!eq(input.stage_mode, "ephemeral") and !eq(input.stage_mode, "cached") and !eq(input.stage_mode, "snapshot")) return error.InvalidCrossDatabaseStage;
                if (!eq(input.stage_mode, "ephemeral")) {
                    input.denied = null;
                    const stage_index = try connectionIndex(connections.items, try fieldString(stage, "connection"));
                    const retained = connections.items[stage_index];
                    if (!eq(retained.adapter_type, "duckdb") or retained.identity.database_path == null or eq(retained.identity.database_path.?, ":memory:") or eq(retained.role, "source")) return error.InvalidCrossDatabaseStageConnection;
                    input.stage_connection = stage_index;
                    input.stage_ttl_seconds = try optionalUnsigned(stage, "ttl_seconds") orelse if (eq(input.stage_mode, "snapshot")) 31536000 else return error.MissingCrossDatabaseStageFreshness;
                    if (input.stage_ttl_seconds == 0 or input.stage_ttl_seconds > 3153600000) return error.InvalidCrossDatabaseStageFreshness;
                    input.stage_version = try optionalFieldString(stage, "version");
                    if (eq(input.stage_mode, "snapshot") and input.stage_version == null) return error.MissingCrossDatabaseSnapshotVersion;
                    input.moved = true;
                    const origin = connections.items[connection];
                    const target = connections.items[execution_connection];
                    if (!options.allow_retention and !try optionalBool(policy, "allow_retention", false)) input.denied = "retained stages require --allow-retention or policy.allow_retention";
                    if (!options.allow_movement and !try optionalBool(policy, "allow_movement", false)) input.denied = "retained stage movement requires explicit authorization";
                    if (origin.allowed_destinations.len != 0 and !contains(origin.allowed_destinations, retained.name)) input.denied = "retained stage is outside the source connection's allowed destinations";
                    if (retained.allowed_destinations.len != 0 and !contains(retained.allowed_destinations, target.name)) input.denied = "execution destination is outside the retained stage's allowed destinations";
                    if (!eq(sensitivity, "public") and !eq(sensitivity, "internal") and (!options.allow_sensitive or !eq(origin.trust_domain, retained.trust_domain) or !eq(retained.trust_domain, target.trust_domain))) input.denied = "sensitive stage retention requires explicit authorization inside one trust domain";
                    if (raw_extract and !options.allow_raw_extract and !try optionalBool(policy, "allow_raw_extract", false)) input.denied = "full-table extraction requires explicit authorization";
                }
            }
            try inputs.append(runtime.allocator, input);
        }
        const sql = if (values.get(raw, "sql")) |value| try scalarString(value) else blk: {
            const model_path = try std.fmt.allocPrint(runtime.allocator, "models/{s}.sql", .{name});
            break :blk try Dir.cwd().readFileAlloc(runtime.io, try projectPath(runtime, root, model_path), runtime.allocator, .limited(16 * 1024 * 1024));
        };
        try fingerprint.writer.writeAll(sql);
        var model: Model = .{ .name = name, .destination = destination, .execution_connection = execution_connection, .schema = try optionalFieldString(raw, "schema") orelse connections.items[destination].identity.target_schema, .identifier = try optionalFieldString(raw, "alias") orelse name, .sql = sql, .inputs = inputs.items, .strategy = "single_engine_pushdown", .execution_engine = connections.items[execution_connection].adapter_type, .budget = budget };
        model.depends_on = try strings(runtime.allocator, values.get(raw, "depends_on") orelse .null);
        if (budget.max_memory_bytes > scheduler_settings.max_memory_bytes) model.denied = "model memory budget exceeds the global scheduler reservation limit";
        model.materialized = try optionalFieldString(raw, "materialized") orelse "table";
        if (!eq(model.materialized, "table") and !eq(model.materialized, "incremental")) return error.InvalidCrossDatabaseMaterialization;
        model.incremental_strategy = try optionalFieldString(raw, "incremental_strategy") orelse "merge";
        if (!eq(model.incremental_strategy, "merge") and !eq(model.incremental_strategy, "append") and !eq(model.incremental_strategy, "insert_overwrite")) return error.InvalidCrossDatabaseIncrementalStrategy;
        model.unique_key = try optionalFieldString(raw, "unique_key");
        model.full_refresh = options.full_refresh;
        if (eq(model.materialized, "incremental")) {
            if (model.unique_key == null) return error.MissingCrossDatabaseUniqueKey;
            for (model.inputs) |input| if (input.incremental_key == null or input.watermark == null) return error.MissingCrossDatabaseSourceWatermark;
            for (model.inputs) |input| if (input.lookback_seconds > 3153600000) return error.InvalidCrossDatabaseSourceWatermark;
            for (model.inputs) |input| if (eq(input.stage_mode, "snapshot")) return error.CrossDatabaseFrozenSnapshotCannotAdvanceWatermarks;
        }
        var moved_count: u64 = 0;
        for (inputs.items) |input| if (input.moved) {
            moved_count += 1;
            if (input.denied != null) model.denied = input.denied;
            const legs: u64 = if (input.stage_connection != null) 2 else 1;
            if (input.estimated_rows) |rows| model.estimated_rows = std.math.add(u64, model.estimated_rows, std.math.mul(u64, rows, legs) catch return error.InvalidCrossDatabaseEstimate) catch return error.InvalidCrossDatabaseEstimate else model.estimate_confidence = "unknown";
            if (input.estimated_bytes) |bytes| {
                model.estimated_bytes = std.math.add(u64, model.estimated_bytes, std.math.mul(u64, bytes, legs) catch return error.InvalidCrossDatabaseEstimate) catch return error.InvalidCrossDatabaseEstimate;
                model.estimated_cost += @as(f64, @floatFromInt(bytes)) / (1024 * 1024 * 1024) * connections.items[input.connection].egress_per_gib;
                if (input.stage_connection) |index| model.estimated_cost += @as(f64, @floatFromInt(bytes)) / (1024 * 1024 * 1024) * connections.items[index].egress_per_gib;
            } else model.estimate_confidence = "unknown";
        };
        if (moved_count != 0) model.strategy = if (moved_count == 1) "dimension_broadcast" else "destination_staged_join";
        if (execution_connection != destination) {
            model.strategy = "bounded_embedded_join";
            model.estimate_confidence = "unknown_output";
            const execution = connections.items[execution_connection];
            const target = connections.items[destination];
            if (!options.allow_movement and !try optionalBool(policy, "allow_movement", false)) model.denied = "embedded output movement requires explicit authorization";
            if (execution.allowed_destinations.len != 0 and !contains(execution.allowed_destinations, target.name)) model.denied = "embedded output destination is outside the execution connection's allowed destinations";
            for (model.inputs) |input| if (!eq(input.sensitivity, "public") and !eq(input.sensitivity, "internal") and (!options.allow_sensitive or !eq(execution.trust_domain, target.trust_domain))) {
                model.denied = "embedded sensitive output movement requires explicit authorization inside one trust domain";
            };
        }
        if (eq(model.materialized, "incremental")) model.estimate_confidence = "unknown_affected_keys";
        if (model.estimated_rows > budget.max_rows) model.denied = "estimated movement exceeds the row budget";
        if (model.estimated_bytes > budget.max_bytes) model.denied = "estimated movement exceeds the byte budget";
        var retained_objects: u64 = 0;
        for (model.inputs) |input| if (input.stage_connection != null) {
            retained_objects += 2;
        };
        if (moved_count + 2 + retained_objects > budget.max_objects) model.denied = "stage/output object count exceeds the object budget";
        if (budget.max_cost) |cost| {
            if (model.estimated_cost > cost) model.denied = "estimated egress exceeds the cost budget";
        }
        try std.json.Stringify.value(.{ .name = model.name, .destination = destination, .execution_connection = execution_connection, .schema = model.schema, .identifier = model.identifier, .budget = budget, .inputs = model.inputs, .materialized = model.materialized, .unique_key = model.unique_key, .incremental_strategy = model.incremental_strategy }, .{}, &fingerprint.writer);
        // Render now to reject missing/ambiguous logical relation references.
        _ = try renderSql(runtime.allocator, model, null);
        try models.append(runtime.allocator, model);
    }
    if (models.items.len == 0) return error.MissingCrossDatabaseModels;
    try @import("cross_database_schedule.zig").validate(runtime.allocator, models.items);
    const definition_hash = try digest(runtime.allocator, fingerprint.written());
    try std.json.Stringify.value(scheduler_settings, .{}, &fingerprint.writer);
    // Evidence changes the reviewed plan, while recovery remains bound to the
    // unchanged project and physical profiles plus the recorded commit hash.
    for (models.items) |*model| {
        model.estimated_rows = 0;
        model.estimated_bytes = 0;
        model.estimated_cost = 0;
        model.estimate_confidence = "declared";
        for (model.inputs) |*input| {
            input.estimate_confidence = if (input.estimated_rows != null and input.estimated_bytes != null) "declared" else "unknown";
            const connection = connections.items[input.connection];
            const binding_hash = try @import("cross_database_catalog.zig").bindingHash(runtime.allocator, connection);
            if (if (catalog_age == 0) null else @import("cross_database_catalog.zig").match(&catalog, connection.name, input.logical_id, binding_hash, input.query_hash, @import("cross_database_catalog.zig").epoch(runtime.io), catalog_age)) |observed| {
                if (input.estimated_rows == null) input.estimated_rows = observed.rows;
                if (input.estimated_bytes == null) input.estimated_bytes = observed.bytes;
                if (eq(input.estimate_confidence, "unknown")) {
                    input.estimate_confidence = "observed_previous_run";
                    input.estimate_observed_epoch = observed.observed_epoch;
                }
            }
            if (!input.moved) continue;
            const legs: u64 = if (input.stage_connection != null) 2 else 1;
            if (input.estimated_rows) |rows| model.estimated_rows +|= rows *| legs;
            if (input.estimated_bytes) |bytes| {
                model.estimated_bytes +|= bytes *| legs;
                model.estimated_cost += @as(f64, @floatFromInt(bytes)) / (1024 * 1024 * 1024) * connection.egress_per_gib;
                if (input.stage_connection) |index| model.estimated_cost += @as(f64, @floatFromInt(bytes)) / (1024 * 1024 * 1024) * connections.items[index].egress_per_gib;
            }
            if (eq(input.estimate_confidence, "unknown")) model.estimate_confidence = "unknown" else if (eq(input.estimate_confidence, "observed_previous_run") and !eq(model.estimate_confidence, "unknown")) model.estimate_confidence = "observed_previous_run";
        }
        if (model.execution_connection != model.destination) model.estimate_confidence = "unknown_output";
        if (eq(model.materialized, "incremental")) model.estimate_confidence = "unknown_affected_keys";
        if (model.estimated_rows > model.budget.max_rows) model.denied = "estimated movement exceeds the row budget";
        if (model.estimated_bytes > model.budget.max_bytes) model.denied = "estimated movement exceeds the byte budget";
        if (model.budget.max_cost) |cost| if (model.estimated_cost > cost) {
            model.denied = "estimated egress exceeds the cost budget";
        };
        model.alternatives = try @import("cross_database_cost.zig").alternatives(runtime.allocator, connections.items, model.*, options.allow_movement or try optionalBool(policy, "allow_movement", false), options.allow_sensitive, options.allow_raw_extract or try optionalBool(policy, "allow_raw_extract", false), options.allow_retention or try optionalBool(policy, "allow_retention", false));
        try std.json.Stringify.value(.{ .name = model.name, .inputs = model.inputs, .confidence = model.estimate_confidence }, .{}, &fingerprint.writer);
    }
    return .{ .hash = try digest(runtime.allocator, fingerprint.written()), .definition_hash = definition_hash, .catalog_generation = catalog.value.generation, .scheduler = scheduler_settings, .connections = connections.items, .models = models.items };
}

pub fn renderSql(allocator: std.mem.Allocator, model: Model, stage_names: ?[]const []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var position: usize = 0;
    while (std.mem.indexOfPos(u8, model.sql, position, "{{")) |at| {
        try out.writer.writeAll(model.sql[position..at]);
        const end = std.mem.indexOfPos(u8, model.sql, at + 2, "}}") orelse return error.InvalidCrossDatabaseTemplate;
        const tag = std.mem.trim(u8, model.sql[at + 2 .. end], " \t\r\n");
        const open = std.mem.indexOfScalar(u8, tag, '(') orelse return error.InvalidCrossDatabaseTemplate;
        if (!std.mem.endsWith(u8, tag, ")")) return error.InvalidCrossDatabaseTemplate;
        const name = std.mem.trim(u8, tag[0..open], " \t");
        if (!eq(name, "input") and !eq(name, "source") and !eq(name, "ref")) return error.InvalidCrossDatabaseTemplate;
        var args = try jinja.parseLiteralArgs(allocator, tag[open + 1 .. tag.len - 1], error.InvalidCrossDatabaseTemplate);
        defer {
            for (args.items) |argument| allocator.free(argument);
            args.deinit(allocator);
        }
        var found: ?usize = null;
        for (model.inputs, 0..) |input, index| {
            const matches = if (eq(name, "source")) args.items.len == 2 and input.source_name != null and input.table_name != null and eq(args.items[0], input.source_name.?) and eq(args.items[1], input.table_name.?) else args.items.len == 1 and eq(args.items[0], input.name);
            if (matches) {
                if (found != null) return error.AmbiguousCrossDatabaseInput;
                found = index;
            }
        }
        const index = found orelse return error.MissingCrossDatabaseInput;
        const input = model.inputs[index];
        if (input.moved) {
            const stage = if (stage_names) |names| names[index] else try std.fmt.allocPrint(allocator, "__dxt_stage_{s}", .{input.name});
            defer if (stage_names == null) allocator.free(stage);
            const quoted = try adapter.quoteIdentifier(allocator, stage);
            defer allocator.free(quoted);
            try out.writer.writeAll(quoted);
        } else try out.writer.print("({s})", .{input.query});
        position = end + 2;
    }
    try out.writer.writeAll(model.sql[position..]);
    return normalizeReadQuery(allocator, out.written());
}

fn inputQuery(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    if (values.get(value, "query")) |query_value| return normalizeReadQuery(allocator, try scalarString(query_value));
    const relation = try relationSql(allocator, try fieldString(value, "relation"));
    var out: std.Io.Writer.Allocating = .init(allocator);
    try out.writer.writeAll("select ");
    if (values.get(value, "projection")) |projection| {
        if (projection != .object or projection.object.count() == 0) return error.InvalidCrossDatabaseInput;
        var iterator = projection.object.iterator();
        var first = true;
        while (iterator.next()) |entry| {
            if (!first) try out.writer.writeAll(", ");
            first = false;
            try out.writer.print("{s} as {s}", .{ try scalarString(entry.value_ptr.*), try adapter.quoteIdentifier(allocator, entry.key_ptr.*) });
        }
    } else {
        const columns = try strings(allocator, values.get(value, "columns") orelse .null);
        if (columns.len == 0) try out.writer.writeByte('*') else for (columns, 0..) |column, index| {
            if (index != 0) try out.writer.writeAll(", ");
            try out.writer.writeAll(try adapter.quoteIdentifier(allocator, column));
        }
    }
    try out.writer.print(" from {s}", .{relation});
    if (try optionalFieldString(value, "filter")) |filter| try out.writer.print(" where {s}", .{filter});
    const group_by = try strings(allocator, values.get(value, "group_by") orelse .null);
    if (group_by.len != 0) try out.writer.print(" group by {s}", .{try std.mem.join(allocator, ", ", group_by)});
    return try out.toOwnedSlice();
}

pub fn validateReadQuery(query_sql: []const u8) !void {
    try scanReadQuery(query_sql, null);
}

pub fn normalizeReadQuery(allocator: std.mem.Allocator, query_sql: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try scanReadQuery(query_sql, &out.writer);
    return allocator.dupe(u8, std.mem.trim(u8, out.written(), " \t\r\n"));
}

fn scanReadQuery(query_sql: []const u8, writer: ?*std.Io.Writer) !void {
    if (query_sql.len == 0 or std.mem.indexOfScalar(u8, query_sql, 0) != null) return error.InvalidCrossDatabaseQuery;
    var at: usize = 0;
    var first = true;
    var ended = false;
    while (at < query_sql.len) {
        const start = at;
        const char = query_sql[at];
        if (std.ascii.isWhitespace(char)) {
            at += 1;
        } else if (std.mem.startsWith(u8, query_sql[at..], "--")) {
            at = if (std.mem.indexOfScalarPos(u8, query_sql, at, '\n')) |end| end else query_sql.len;
            if (writer) |out| try out.writeByte(' ');
            continue;
        } else if (std.mem.startsWith(u8, query_sql[at..], "/*")) {
            at += 2;
            var depth: usize = 1;
            while (at < query_sql.len and depth != 0) {
                if (std.mem.startsWith(u8, query_sql[at..], "/*")) {
                    depth += 1;
                    at += 2;
                } else if (std.mem.startsWith(u8, query_sql[at..], "*/")) {
                    depth -= 1;
                    at += 2;
                } else at += 1;
            }
            if (depth != 0) return error.InvalidCrossDatabaseQuery;
            if (writer) |out| try out.writeByte(' ');
            continue;
        } else {
            if (ended) return error.InvalidCrossDatabaseQuery;
            if (char == ';') {
                ended = true;
                at += 1;
                continue;
            }
            if (char == '\'' or char == '"') {
                if (first) return error.InvalidCrossDatabaseQuery;
                at += 1;
                var closed = false;
                while (at < query_sql.len) {
                    if (query_sql[at] == char) {
                        at += 1;
                        if (at < query_sql.len and query_sql[at] == char) {
                            at += 1;
                            continue;
                        }
                        closed = true;
                        break;
                    }
                    at += 1;
                }
                if (!closed) return error.InvalidCrossDatabaseQuery;
            } else if (char == '$') {
                var end = at + 1;
                while (end < query_sql.len and (std.ascii.isAlphanumeric(query_sql[end]) or query_sql[end] == '_')) end += 1;
                if (end < query_sql.len and query_sql[end] == '$') {
                    const tag = query_sql[at .. end + 1];
                    at = (std.mem.indexOfPos(u8, query_sql, end + 1, tag) orelse return error.InvalidCrossDatabaseQuery) + tag.len;
                } else at += 1;
            } else if (std.ascii.isAlphabetic(char) or char == '_') {
                at += 1;
                while (at < query_sql.len and (std.ascii.isAlphanumeric(query_sql[at]) or query_sql[at] == '_')) at += 1;
                const word = query_sql[start..at];
                if (first) {
                    if (!std.ascii.eqlIgnoreCase(word, "select") and !std.ascii.eqlIgnoreCase(word, "with")) return error.InvalidCrossDatabaseQuery;
                    first = false;
                } else inline for (.{ "insert", "update", "delete", "merge", "copy", "create", "alter", "drop", "truncate", "grant", "revoke", "attach", "detach", "pragma", "call" }) |forbidden| {
                    if (std.ascii.eqlIgnoreCase(word, forbidden)) return error.InvalidCrossDatabaseQuery;
                }
            } else {
                if (first) return error.InvalidCrossDatabaseQuery;
                at += 1;
            }
        }
        if (writer) |out| try out.writeAll(query_sql[start..at]);
    }
    if (first) return error.InvalidCrossDatabaseQuery;
}

fn parseBudget(raw: std.json.Value, options: Options) !Budget {
    const input = values.get(raw, "budget") orelse .null;
    var budget: Budget = .{};
    inline for (.{ "max_rows", "max_bytes", "max_memory_bytes", "max_spill_bytes", "max_objects", "max_query_seconds" }) |field| {
        if (try optionalUnsigned(input, field)) |value| @field(budget, field) = value;
    }
    if (options.max_rows) |v| budget.max_rows = v;
    if (options.max_bytes) |v| budget.max_bytes = v;
    if (options.max_memory_bytes) |v| budget.max_memory_bytes = v;
    if (options.max_spill_bytes) |v| budget.max_spill_bytes = v;
    budget.max_cost = try optionalFloat(input, "max_cost");
    if (budget.max_memory_bytes < 1024 * 1024 or budget.max_objects < 2 or budget.max_query_seconds == 0 or budget.max_query_seconds > std.math.maxInt(u64) / 1000) return error.InvalidCrossDatabaseBudget;
    return budget;
}

pub fn writePlan(runtime: Runtime, path: []const u8, plan: Plan) !void {
    const output = try planJson(runtime.allocator, plan);
    defer runtime.allocator.free(output);
    try writeAtomic(runtime, path, output);
}

pub fn planJson(allocator: std.mem.Allocator, plan: Plan) ![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;
    try writer.writeAll("{\"schema_version\":1,\"plan_hash\":");
    try std.json.Stringify.value(plan.hash, .{}, writer);
    try writer.writeAll(",\"definition_hash\":");
    try std.json.Stringify.value(plan.definition_hash, .{}, writer);
    try writer.print(",\"catalog_generation\":{d},\"scheduler\":", .{plan.catalog_generation});
    try std.json.Stringify.value(plan.scheduler, .{}, writer);
    try writer.writeAll(",\"connections\":[");
    for (plan.connections, 0..) |connection, i| {
        if (i != 0) try writer.writeByte(',');
        try std.json.Stringify.value(.{ .name = connection.name, .profile = connection.profile_name, .target = connection.target, .adapter = connection.adapter_type, .role = connection.role, .trust_domain = connection.trust_domain, .allowed_destinations = connection.allowed_destinations, .limits = connection.limits, .native_upper_bounds = @import("cross_database_schedule.zig").effectiveLimits(connection), .scheduling_note = "physical aliases share the strictest limits; destination DDL writes serialize", .capabilities = .{ .transactions = true, .transactional_ddl = true, .native_reads = true, .temporary_stages = true } }, .{}, writer);
    }
    try writer.writeAll("],\"models\":[");
    for (plan.models, 0..) |model, i| {
        if (i != 0) try writer.writeByte(',');
        const query_sql = try renderSql(allocator, model, null);
        defer allocator.free(query_sql);
        try std.json.Stringify.value(.{ .name = model.name, .destination = plan.connections[model.destination].name, .execution_connection = plan.connections[model.execution_connection].name, .output = .{ .schema = model.schema, .identifier = model.identifier }, .materialized = model.materialized, .unique_key = model.unique_key, .incremental_strategy = model.incremental_strategy, .full_refresh = model.full_refresh, .strategy = model.strategy, .execution_engine = model.execution_engine, .output_movement = model.execution_connection != model.destination, .budget = model.budget, .estimated_rows = model.estimated_rows, .estimated_scan_bytes = @as(?u64, null), .estimated_moved_bytes = model.estimated_bytes, .estimated_load_bytes = model.estimated_bytes, .estimated_egress_cost = model.estimated_cost, .confidence = model.estimate_confidence, .permitted = model.denied == null, .denial = model.denied, .query = query_sql, .inputs = model.inputs, .alternatives = model.alternatives, .depends_on = model.depends_on, .largest_movement_contributor = @import("cross_database_cost.zig").largest(model), .suggested_changes = if (model.denied != null) @as([]const []const u8, &.{ "reduce source rows with a filter or partial aggregate", "project only required columns", "choose an authorized destination or adjust the declared budget" }) else @as([]const []const u8, &.{}) }, .{}, writer);
    }
    try writer.writeAll("]}\n");
    return output.toOwnedSlice();
}

pub fn writeAtomic(runtime: Runtime, path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |directory| try Dir.cwd().createDirPath(runtime.io, directory);
    const temporary = try std.fmt.allocPrint(runtime.allocator, "{s}.tmp", .{path});
    defer runtime.allocator.free(temporary);
    defer Dir.cwd().deleteFile(runtime.io, temporary) catch {};
    try Dir.cwd().writeFile(runtime.io, .{ .sub_path = temporary, .data = text });
    try Dir.rename(Dir.cwd(), temporary, Dir.cwd(), path, runtime.io);
}
pub fn projectPath(runtime: Runtime, root: []const u8, path: []const u8) ![]const u8 {
    return if (std.fs.path.isAbsolute(path)) path else std.fs.path.join(runtime.allocator, &.{ root, path });
}
pub fn relationSql(allocator: std.mem.Allocator, relation: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, relation, '.');
    var output: std.Io.Writer.Allocating = .init(allocator);
    var first = true;
    while (parts.next()) |part| {
        if (part.len == 0) return error.InvalidCrossDatabaseRelation;
        if (!first) try output.writer.writeByte('.');
        first = false;
        try output.writer.writeAll(try adapter.quoteIdentifier(allocator, part));
    }
    return output.toOwnedSlice();
}
pub fn digest(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &hash, .{});
    return try allocator.dupe(u8, &std.fmt.bytesToHex(hash, .lower));
}
fn connectionIndex(connections: []const Connection, name: []const u8) !usize {
    for (connections, 0..) |connection, index| if (eq(connection.name, name)) return index;
    return error.MissingCrossDatabaseConnection;
}
fn strings(allocator: std.mem.Allocator, value: std.json.Value) ![]const []const u8 {
    if (value == .null) return &.{};
    if (value != .array) return error.InvalidCrossDatabaseConfig;
    const result = try allocator.alloc([]const u8, value.array.items.len);
    for (value.array.items, result) |item, *out| out.* = try scalarString(item);
    return result;
}
fn fieldString(value: std.json.Value, field: []const u8) ![]const u8 {
    return scalarString(values.get(value, field) orelse return error.InvalidCrossDatabaseConfig);
}
fn optionalFieldString(value: std.json.Value, field: []const u8) !?[]const u8 {
    return if (values.get(value, field)) |item| if (item == .null) null else try scalarString(item) else null;
}
fn scalarString(value: std.json.Value) ![]const u8 {
    return if (value == .string and value.string.len != 0) value.string else error.InvalidCrossDatabaseConfig;
}
fn optionalUnsigned(value: std.json.Value, field: []const u8) !?u64 {
    const item = values.get(value, field) orelse return null;
    if (item == .null) return null;
    if (item == .integer and item.integer >= 0) return @intCast(item.integer);
    return error.InvalidCrossDatabaseBudget;
}
fn optionalFloat(value: std.json.Value, field: []const u8) !?f64 {
    const item = values.get(value, field) orelse return null;
    if (item == .null) return null;
    const amount: f64 = if (item == .integer) @floatFromInt(item.integer) else if (item == .float) item.float else return error.InvalidCrossDatabaseEstimate;
    if (!std.math.isFinite(amount) or amount < 0) return error.InvalidCrossDatabaseEstimate;
    return amount;
}
fn optionalBool(value: std.json.Value, field: []const u8, default: bool) !bool {
    const item = values.get(value, field) orelse return default;
    if (item != .bool) return error.InvalidCrossDatabaseConfig;
    return item.bool;
}
fn number(text: []const u8) !u64 {
    return std.fmt.parseUnsigned(u64, text, 10) catch error.InvalidCrossDatabaseBudget;
}
fn contains(items: []const []const u8, name: []const u8) bool {
    for (items) |item| if (eq(item, name)) return true;
    return false;
}
pub fn identifier(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |char| if (!std.ascii.isAlphanumeric(char) and char != '_') return false;
    return true;
}
pub fn validRunId(id: []const u8) bool {
    if (id.len != 36) return false;
    for (id, 0..) |char, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (char != '-') return false;
        } else if (!std.ascii.isHex(char)) return false;
    }
    return true;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "cross query lexical boundary preserves literals and comments" {
    const allocator = std.testing.allocator;
    const sql = try normalizeReadQuery(allocator, "-- header\n select 'a;--b' as value, $$semi;drop$$ as text /* outer /* nested */ */; -- end");
    defer allocator.free(sql);
    try std.testing.expectEqualStrings("select 'a;--b' as value, $$semi;drop$$ as text", std.mem.trim(u8, sql, " \t\r\n"));
    try std.testing.expectError(error.InvalidCrossDatabaseQuery, validateReadQuery("select 1; drop table output"));
    try std.testing.expectError(error.InvalidCrossDatabaseQuery, validateReadQuery("with changed as (delete from output returning *) select * from changed"));
    try std.testing.expectError(error.InvalidCrossDatabaseQuery, validateReadQuery("select 'unterminated"));
    try std.testing.expectError(error.InvalidCrossDatabaseQuery, validateReadQuery("select 1 /* unterminated"));
}

test "cross option and budget diagnostics reject malformed recovery and numeric values" {
    try std.testing.expectError(error.MissingCrossDatabaseRunId, parseOptions(&.{"recover"}));
    try std.testing.expectError(error.InvalidCrossDatabaseRunId, parseOptions(&.{ "recover", "--run-id", "../state" }));
    try std.testing.expectError(error.InvalidCrossDatabaseBudget, parseOptions(&.{ "run", "--max-bytes", "-1" }));
    const options = try parseOptions(&.{ "run", "--allow-movement", "--max-spill-bytes", "1024" });
    try std.testing.expect(options.allow_movement);
    try std.testing.expectEqual(@as(?u64, 1024), options.max_spill_bytes);
    try std.testing.expectError(error.InvalidCrossDatabaseBudget, parseBudget(.null, .{ .max_memory_bytes = 1 }));
    try std.testing.expect(validRunId("12345678-1234-5678-abcd-1234567890ab"));
}
