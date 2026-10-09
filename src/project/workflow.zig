//! Native dxt workflow artifacts and warehouse state. Source contract: SQLMesh
//! b44fdf6 docs/concepts/{environments,plans}.md, core/environment.py and
//! docs/guides/incremental_time.md. dxt calls these immutable model versions;
//! dbt snapshot nodes and Core incremental execution retain their own contract.
const std = @import("std");
const types = @import("types.zig");
const adapter = @import("adapter.zig");
const compiler = @import("compiler.zig");
const duckdb = @import("duckdb.zig");
const yaml = @import("yaml.zig");
const values = @import("config_value.zig");
const interval = @import("workflow_intervals.zig");
const seed_csv = @import("seed_csv.zig");

pub const Options = struct {
    environment: []const u8 = "prod",
    from_environment: []const u8 = "prod",
    plan_file: ?[]const u8 = null,
    config_file: ?[]const u8 = null,
    start: ?[]const u8 = null,
    end: ?[]const u8 = null,
    restate: bool = false,
};

pub const Model = struct {
    unique_id: []const u8,
    name: []const u8,
    resource_type: []const u8,
    schema: []const u8,
    alias: []const u8,
    own_hash: []const u8,
    version: []const u8,
    relation: []const u8,
    sql: []const u8 = "",
    ephemeral: bool = false,
    time_column: ?[]const u8 = null,
    interval_unit: interval.Unit = .day,
    lookback: u32 = 0,
    processed: []const interval.Interval = &.{},
    depends_on: []const []const u8 = &.{},
};

pub const Audit = struct {
    unique_id: []const u8,
    sql: []const u8,
    severity: []const u8 = "ERROR",
    error_if: []const u8 = "!= 0",
    warn_if: []const u8 = "!= 0",
    limit: ?u64 = null,
};

pub const Change = struct {
    model: Model,
    change: enum { added, direct, indirect, unchanged },
    missing_intervals: []const interval.Interval = &.{},
    physical_exists: bool = false,
};

pub const Plan = struct {
    schema_version: []const u8 = "dxt/plan/v1",
    project: []const u8,
    adapter: []const u8,
    gateway: []const u8,
    environment: []const u8,
    base_plan_id: ?[]const u8 = null,
    plan_id: []const u8 = "",
    requested: ?interval.Interval = null,
    restate: bool = false,
    models: []const Change,
    removed: []const []const u8 = &.{},
    audits: []const Audit = &.{},
};

pub const Revision = struct {
    plan_id: []const u8,
    models: []const Model,
    audits: []const Audit = &.{},
};

pub const Environment = struct {
    schema_version: []const u8 = "dxt/environment/v1",
    project: []const u8,
    gateway: []const u8,
    name: []const u8,
    plan_id: []const u8,
    models: []const Model,
    audits: []const Audit = &.{},
    history: []const Revision = &.{},
};

pub const AuditResult = struct { unique_id: []const u8, failures: ?u64, status: enum { pass, warn, fail, @"error" }, error_code: ?[]const u8 = null };
pub const Run = struct {
    schema_version: []const u8 = "dxt/run/v1",
    project: []const u8,
    environment: []const u8,
    plan_id: []const u8,
    action: []const u8,
    status: []const u8,
    built: usize = 0,
    reused: usize = 0,
    audits: []const AuditResult = &.{},
    failed_model: ?[]const u8 = null,
    failed_audit: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
};

const Context = struct {
    runtime: types.Runtime,
    graph: *types.Graph,
    common: types.Options,
    options: Options,
    target_dir: []const u8,
    db_path: []const u8,
    gateway: []const u8,
    config: std.json.Value = .null,
    session: ?adapter.Session = null,

    fn init(runtime: types.Runtime, graph: *types.Graph, common: types.Options, options: Options, target_dir: []const u8) !Context {
        try validateName(options.environment);
        try validateName(options.from_environment);
        if (common.select != null or common.selector != null or common.exclude != null or common.defer_enabled) return error.WorkflowPartialSelection;
        const db_path = try duckdb.databasePath(runtime.allocator, target_dir, graph);
        const identity = if (std.mem.eql(u8, graph.adapter_type, "postgres")) graph.connection_info orelse "" else db_path;
        const gateway = try hash(runtime.allocator, &.{ graph.adapter_type, identity });
        var context: Context = .{ .runtime = runtime, .graph = graph, .common = common, .options = options, .target_dir = target_dir, .db_path = db_path, .gateway = gateway };
        const config_path = options.config_file orelse try std.fs.path.join(runtime.allocator, &.{ common.project_dir, ".dxt", "workflow.yml" });
        const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, config_path, runtime.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => if (options.config_file != null) return error.WorkflowConfigurationMissing else null,
            else => return err,
        };
        if (text) |raw| {
            var document = try yaml.parse(runtime.allocator, raw);
            defer document.deinit();
            if (document.value != .object) return error.InvalidWorkflowConfiguration;
            context.config = try values.clone(runtime.allocator, document.value);
            try validateConfiguration(context.config, graph);
        }
        for ([_][]const u8{ "dxt_start", "dxt_end" }, [_][]const u8{ "__DXT_INTERVAL_START__", "__DXT_INTERVAL_END__" }) |name, marker| {
            var found = false;
            for (graph.vars.items) |entry| if (eq(entry.name, name)) {
                if (!eq(entry.value, marker)) return error.WorkflowReservedVariable;
                found = true;
            };
            if (!found) try graph.vars.append(runtime.allocator, .{ .name = try runtime.allocator.dupe(u8, name), .value = try runtime.allocator.dupe(u8, marker) });
        }
        return context;
    }

    fn deinit(self: *Context) void {
        if (self.session) |*session| session.deinit();
    }

    fn open(self: *Context, create: bool) !bool {
        if (self.session != null) return true;
        if (!create and std.mem.eql(u8, self.graph.adapter_type, "duckdb")) {
            const file = std.Io.Dir.cwd().openFile(self.runtime.io, self.db_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
            file.close(self.runtime.io);
        }
        self.session = try adapter.openSession(self.runtime, self.graph, self.db_path);
        try self.session.?.execute("set time zone 'UTC'");
        return true;
    }

    fn metadataExists(self: *Context) !bool {
        if (!try self.open(false)) return false;
        return try self.session.?.relationExists(self.runtime.allocator, "_dxt", "workflow_environments");
    }

    fn loadEnvironment(self: *Context, name: []const u8) !?Environment {
        if (!try self.metadataExists()) return null;
        const project = try adapter.quoteLiteral(self.runtime.allocator, self.graph.project_name);
        const environment = try adapter.quoteLiteral(self.runtime.allocator, name);
        const sql = try std.fmt.allocPrint(self.runtime.allocator, "select payload from _dxt.workflow_environments where project = {s} and name = {s}", .{ project, environment });
        var result = try self.session.?.query(sql);
        defer result.deinit(self.runtime.allocator);
        const payload = result.firstScalar() orelse return null;
        const parsed = try std.json.parseFromSlice(Environment, self.runtime.allocator, payload, .{ .allocate = .alloc_always });
        if (!eq(parsed.value.schema_version, "dxt/environment/v1") or !eq(parsed.value.gateway, self.gateway)) return error.WorkflowGatewayMismatch;
        return parsed.value;
    }

    fn loadVersion(self: *Context, version: []const u8) !?Model {
        if (!try self.metadataExists()) return null;
        const project = try adapter.quoteLiteral(self.runtime.allocator, self.graph.project_name);
        const fingerprint = try adapter.quoteLiteral(self.runtime.allocator, version);
        const sql = try std.fmt.allocPrint(self.runtime.allocator, "select payload from _dxt.workflow_versions where project = {s} and version = {s}", .{ project, fingerprint });
        var result = try self.session.?.query(sql);
        defer result.deinit(self.runtime.allocator);
        const payload = result.firstScalar() orelse return null;
        return (try std.json.parseFromSlice(Model, self.runtime.allocator, payload, .{ .allocate = .alloc_always })).value;
    }

    fn ensureMetadata(self: *Context) !void {
        _ = try self.open(true);
        if (!self.session.?.capabilities().transactional_ddl) return error.WorkflowTransactionalDdlRequired;
        try self.session.?.execute("create schema if not exists _dxt; create table if not exists _dxt.workflow_environments(project varchar not null, name varchar not null, payload varchar not null, primary key(project,name)); create table if not exists _dxt.workflow_versions(project varchar not null, version varchar not null, payload varchar not null, primary key(project,version)); create table if not exists _dxt.workflow_events(project varchar not null, plan_id varchar not null, action varchar not null, payload varchar not null); create table if not exists _dxt.workflow_locks(project varchar not null, name varchar not null, primary key(project,name))");
    }

    fn lockEnvironment(self: *Context, name: []const u8) !void {
        const a = self.runtime.allocator;
        const project = try adapter.quoteLiteral(a, self.graph.project_name);
        const environment = try adapter.quoteLiteral(a, name);
        try self.session.?.execute(try std.fmt.allocPrint(a, "insert into _dxt.workflow_locks(project,name) values({s},{s}) on conflict do nothing", .{ project, environment }));
        if (self.session.? == .postgres) {
            var locked = try self.session.?.query(try std.fmt.allocPrint(a, "select name from _dxt.workflow_locks where project={s} and name={s} for update", .{ project, environment }));
            locked.deinit(a);
        } else {
            // DuckDB uses optimistic transactions: a concurrent mutation of
            // this row conflicts, preserving a single environment transition.
            try self.session.?.execute(try std.fmt.allocPrint(a, "update _dxt.workflow_locks set name=name where project={s} and name={s}", .{ project, environment }));
        }
    }

    fn lockVersions(self: *Context, models: []const Model) !void {
        const a = self.runtime.allocator;
        var versions: std.ArrayList([]const u8) = .empty;
        for (models) |model| if (!model.ephemeral) try versions.append(a, model.version);
        std.mem.sort([]const u8, versions.items, {}, struct {
            fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.lessThan(u8, lhs, rhs);
            }
        }.less);
        // Shared physical versions require shared interval coverage locks even
        // when different environments backfill them concurrently. All callers
        // acquire version keys in the same order to avoid lock inversions.
        for (versions.items) |version| try self.lockEnvironment(try std.fmt.allocPrint(a, "version_{s}", .{version}));
    }

    fn store(self: *Context, table: []const u8, key: []const u8, identity: []const u8, object: anytype) !void {
        const project = try adapter.quoteLiteral(self.runtime.allocator, self.graph.project_name);
        const id = try adapter.quoteLiteral(self.runtime.allocator, identity);
        const raw = try std.json.Stringify.valueAlloc(self.runtime.allocator, object, .{});
        const payload = try adapter.quoteLiteral(self.runtime.allocator, raw);
        const sql = try std.fmt.allocPrint(self.runtime.allocator, "delete from _dxt.{s} where project = {s} and {s} = {s}; insert into _dxt.{s}(project,{s},payload) values({s},{s},{s})", .{ table, project, key, id, table, key, project, id, payload });
        try self.session.?.execute(sql);
    }

    fn event(self: *Context, run: Run) !void {
        const project = try adapter.quoteLiteral(self.runtime.allocator, run.project);
        const plan = try adapter.quoteLiteral(self.runtime.allocator, run.plan_id);
        const action = try adapter.quoteLiteral(self.runtime.allocator, run.action);
        const payload = try adapter.quoteLiteral(self.runtime.allocator, try std.json.Stringify.valueAlloc(self.runtime.allocator, run, .{}));
        const sql = try std.fmt.allocPrint(self.runtime.allocator, "insert into _dxt.workflow_events values ({s},{s},{s},{s})", .{ project, plan, action, payload });
        try self.session.?.execute(sql);
    }

    fn artifact(self: *Context, filename: []const u8, object: anytype) !void {
        const directory = try std.fs.path.join(self.runtime.allocator, &.{ self.target_dir, "dxt" });
        try std.Io.Dir.cwd().createDirPath(self.runtime.io, directory);
        const path = try std.fs.path.join(self.runtime.allocator, &.{ directory, filename });
        try atomicWrite(self.runtime, path, try std.json.Stringify.valueAlloc(self.runtime.allocator, object, .{ .whitespace = .indent_2 }));
    }
};

pub fn execute(runtime: types.Runtime, graph: *types.Graph, common: types.Options, options: Options, target_dir: []const u8, command: []const u8, stdout: *std.Io.Writer) !void {
    var context = try Context.init(runtime, graph, common, options, target_dir);
    defer context.deinit();
    if (eq(command, "plan")) {
        const plan = try makePlan(&context);
        const path = options.plan_file orelse try std.fs.path.join(runtime.allocator, &.{ target_dir, "dxt", "plan.json" });
        try atomicWrite(runtime, path, try std.json.Stringify.valueAlloc(runtime.allocator, plan, .{ .whitespace = .indent_2 }));
        try jsonOutput(stdout, plan);
    } else if (eq(command, "apply")) {
        const path = options.plan_file orelse try std.fs.path.join(runtime.allocator, &.{ target_dir, "dxt", "plan.json" });
        const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return error.WorkflowPlanMissing,
            else => return err,
        };
        const plan = (try std.json.parseFromSlice(Plan, runtime.allocator, text, .{ .allocate = .alloc_always })).value;
        const run = apply(&context, plan) catch |err| switch (err) {
            error.DuckDbExecutionFailed, error.PostgresExecutionFailed => return error.WorkflowExecutionFailure,
            else => return err,
        };
        try jsonOutput(stdout, run);
    } else if (eq(command, "environment") or eq(command, "intervals")) {
        var environment = try context.loadEnvironment(options.environment) orelse return error.WorkflowEnvironmentMissing;
        if (eq(command, "intervals")) {
            const models = try runtime.allocator.dupe(Model, environment.models);
            for (models) |*model| if (try context.loadVersion(model.version)) |cached| {
                model.processed = cached.processed;
            };
            environment.models = models;
        }
        try context.artifact("environment.json", environment);
        try jsonOutput(stdout, environment);
    } else if (eq(command, "promote") or eq(command, "rollback")) {
        const run = try transition(&context, command);
        try jsonOutput(stdout, run);
    } else if (eq(command, "audit")) {
        const environment = try context.loadEnvironment(options.environment) orelse return error.WorkflowEnvironmentMissing;
        var run: Run = .{ .project = graph.project_name, .environment = options.environment, .plan_id = environment.plan_id, .action = "audit", .status = "success" };
        errdefer |err| {
            if (!eq(run.status, "audit_failed")) run.status = "execution_failed";
            run.error_code = @errorName(err);
            context.artifact("run.json", run) catch {};
        }
        const audits = try runAudits(&context, environment.audits, &run);
        run.audits = audits;
        if (hasAuditFailure(audits)) run.status = "audit_failed";
        try context.artifact("run.json", run);
        try jsonOutput(stdout, run);
        if (hasAuditFailure(audits)) return error.WorkflowAuditFailure;
    } else return error.InvalidWorkflowCommand;
}

fn makePlan(context: *Context) !Plan {
    const a = context.runtime.allocator;
    const current = try context.loadEnvironment(context.options.environment);
    const baseline = current orelse try context.loadEnvironment(context.options.from_environment);
    var builder: Builder = .{ .context = context, .models = try a.alloc(?Model, context.graph.nodes.items.len), .visiting = try a.alloc(bool, context.graph.nodes.items.len) };
    @memset(builder.models, null);
    @memset(builder.visiting, false);
    for (context.graph.nodes.items, 0..) |node, index| {
        if (node.enabled and (eq(node.resource_type, "model") or eq(node.resource_type, "seed"))) _ = try builder.model(index);
    }
    var models: std.ArrayList(Change) = .empty;
    var removed: std.ArrayList([]const u8) = .empty;
    var requested: ?interval.Interval = null;
    for (builder.models) |maybe_model| {
        var model = maybe_model orelse continue;
        const old = if (baseline) |environment| findModel(environment.models, model.unique_id) else null;
        const change: @FieldType(Change, "change") = if (old) |prior| if (eq(prior.version, model.version)) .unchanged else if (eq(prior.own_hash, model.own_hash)) .indirect else .direct else .added;
        const cached = try context.loadVersion(model.version);
        var physical_exists = false;
        if (cached) |version| {
            model.processed = version.processed;
            if (context.session != null and !model.ephemeral) physical_exists = try relationExists(&context.session.?, a, model.relation);
        }
        var missing: []const interval.Interval = &.{};
        if (model.time_column != null) {
            const start_text = context.options.start orelse try configString(context, model.unique_id, model.name, "start") orelse return error.WorkflowIntervalStartRequired;
            const end_text = context.options.end orelse return error.WorkflowIntervalEndRequired;
            const range: interval.Interval = .{ .start = try interval.parseTimestamp(start_text), .end = try interval.parseTimestamp(end_text) };
            requested = range;
            missing = try interval.missing(a, range, if (physical_exists) model.processed else &.{}, model.interval_unit, model.lookback, context.options.restate);
        }
        try models.append(a, .{ .model = model, .change = change, .missing_intervals = missing, .physical_exists = physical_exists });
    }
    if (baseline) |environment| for (environment.models) |old| {
        var found = false;
        for (models.items) |model| if (eq(model.model.unique_id, old.unique_id)) {
            found = true;
            break;
        };
        if (!found) try removed.append(a, old.unique_id);
    };
    try bindRelations(context.graph, models.items, a);
    for (models.items, 0..) |item, index| {
        if (item.model.ephemeral) continue;
        for (models.items[0..index]) |other| if (!other.model.ephemeral and eq(other.model.schema, item.model.schema) and eq(other.model.alias, item.model.alias)) return error.WorkflowRelationCollision;
    }
    for (models.items) |*item| {
        const node = findNode(context.graph, item.model.unique_id).?;
        if (item.model.ephemeral) continue;
        var clone = node.*;
        clone.config_schema = "dxt_data";
        clone.config_alias = try physicalIdentifier(a, item.model.unique_id, item.model.version);
        if (eq(node.resource_type, "seed")) {
            item.model.sql = try seed_csv.renderSql(a, context.graph, &clone);
        } else {
            var compiled = try compiler.compileModelWithInjectedCtes(a, context.graph, &clone);
            item.model.sql = compiled.compiled_code;
            // The command arena owns compiled CTE storage until artifact writing.
            compiled.extra_ctes.deinit(a);
        }
    }
    var plan: Plan = .{ .project = context.graph.project_name, .adapter = context.graph.adapter_type, .gateway = context.gateway, .environment = context.options.environment, .base_plan_id = if (current) |environment| environment.plan_id else null, .requested = requested, .restate = context.options.restate, .models = models.items, .removed = removed.items, .audits = try compileAudits(context) };
    plan.plan_id = try planHash(a, plan);
    return plan;
}

const Builder = struct {
    context: *Context,
    models: []?Model,
    visiting: []bool,

    fn model(self: *Builder, index: usize) anyerror!Model {
        if (self.models[index]) |model_value| return model_value;
        if (self.visiting[index]) return error.DependencyCycle;
        self.visiting[index] = true;
        const context = self.context;
        const a = context.runtime.allocator;
        const node = &context.graph.nodes.items[index];
        var parts: std.ArrayList([]const u8) = .empty;
        try parts.appendSlice(a, &.{ node.unique_id, node.raw_code, node.materialized, context.gateway });
        try parts.append(a, try std.json.Stringify.valueAlloc(a, node.effective_config, .{}));
        if (eq(node.resource_type, "model")) {
            try parts.append(a, try compiler.compileModel(a, context.graph, node));
        }
        try appendMacros(a, context.graph, node.macro_depends_on.items, &parts, 0);
        const time_column = try configString(context, node.unique_id, node.name, "time_column");
        if (time_column != null and (!eq(node.resource_type, "model") or eq(node.materialized, "ephemeral"))) return error.InvalidWorkflowIntervalModel;
        const unit_text = try configString(context, node.unique_id, node.name, "interval_unit") orelse "day";
        const unit = try interval.parseUnit(unit_text);
        const lookback_value: std.json.Value = configValue(context, node.unique_id, node.name, "lookback") orelse .{ .integer = 0 };
        if (lookback_value != .integer or lookback_value.integer < 0 or lookback_value.integer > 100000) return error.InvalidWorkflowConfiguration;
        if (lookback_value.integer != 0 and time_column == null) return error.InvalidWorkflowIntervalModel;
        try parts.append(a, time_column orelse "");
        try parts.append(a, unit_text);
        try parts.append(a, try std.fmt.allocPrint(a, "{d}", .{lookback_value.integer}));
        const own_hash = try hash(a, parts.items);
        parts.clearRetainingCapacity();
        try parts.append(a, own_hash);
        var dependencies: std.ArrayList([]const u8) = .empty;
        for (node.depends_on.items) |dependency| {
            var found = false;
            for (context.graph.nodes.items, 0..) |other, other_index| {
                if (!eq(other.unique_id, dependency)) continue;
                found = true;
                if (!other.enabled) return error.UnresolvedRef;
                if (eq(other.resource_type, "snapshot")) {
                    // Existing dbt snapshot relations are inputs, never dxt versions.
                    try parts.append(a, other.raw_code);
                } else if (eq(other.resource_type, "model") or eq(other.resource_type, "seed")) {
                    const upstream = try self.model(other_index);
                    try parts.append(a, upstream.version);
                    try dependencies.append(a, dependency);
                }
                break;
            }
            if (!found) for (context.graph.sources.items) |source| {
                if (eq(source.unique_id, dependency)) {
                    try parts.append(a, try compiler.relationNameForSource(a, &source));
                    break;
                }
            };
        }
        if (context.options.restate and time_column == null) {
            const old = try context.loadEnvironment(context.options.environment);
            try parts.append(a, if (old) |environment| environment.plan_id else "initial_restate");
        }
        const version = try hash(a, parts.items);
        var clone = node.*;
        clone.config_schema = "dxt_data";
        clone.config_alias = try physicalIdentifier(a, node.unique_id, version);
        const result: Model = .{ .unique_id = node.unique_id, .name = node.name, .resource_type = node.resource_type, .schema = try compiler.relationSchemaForNode(a, context.graph, node), .alias = compiler.relationIdentifierForNode(node), .own_hash = own_hash, .version = version, .relation = try compiler.relationNameForNode(a, context.graph, &clone), .ephemeral = eq(node.materialized, "ephemeral"), .time_column = time_column, .interval_unit = unit, .lookback = @intCast(lookback_value.integer), .depends_on = dependencies.items };
        self.models[index] = result;
        self.visiting[index] = false;
        return result;
    }
};

fn apply(context: *Context, plan: Plan) !Run {
    const a = context.runtime.allocator;
    if (!eq(plan.schema_version, "dxt/plan/v1") or !eq(plan.project, context.graph.project_name) or !eq(plan.gateway, context.gateway) or !eq(plan.adapter, context.graph.adapter_type)) return error.WorkflowGatewayMismatch;
    if (!eq(plan.plan_id, try planHash(a, plan))) return error.WorkflowPlanModified;
    try validateName(plan.environment);
    if (!eq(plan.environment, context.options.environment)) return error.WorkflowEnvironmentMismatch;
    var current = try context.loadEnvironment(plan.environment);
    if (current) |environment| if (eq(environment.plan_id, plan.plan_id)) return .{ .project = plan.project, .environment = plan.environment, .plan_id = plan.plan_id, .action = "apply", .status = "already_applied", .reused = plan.models.len };
    if (!optionalEqual(plan.base_plan_id, if (current) |environment| environment.plan_id else null)) return error.WorkflowStalePlan;
    context.options.restate = plan.restate;
    if (plan.requested) |range| {
        context.options.start = try interval.formatTimestamp(a, range.start);
        context.options.end = try interval.formatTimestamp(a, range.end);
    }
    const fresh = try makePlan(context);
    if (fresh.models.len != plan.models.len) return error.WorkflowProjectChanged;
    for (plan.models) |item| {
        var matched = false;
        for (fresh.models) |candidate| if (eq(candidate.model.unique_id, item.model.unique_id) and eq(candidate.model.version, item.model.version)) {
            matched = true;
            break;
        };
        if (!matched) return error.WorkflowProjectChanged;
    }
    if (!eq(try hash(a, &.{try std.json.Stringify.valueAlloc(a, fresh.audits, .{})}), try hash(a, &.{try std.json.Stringify.valueAlloc(a, plan.audits, .{})}))) return error.WorkflowProjectChanged;
    _ = try context.open(true);
    try context.session.?.begin();
    var committed = false;
    defer if (!committed) context.session.?.rollback() catch {};
    try context.ensureMetadata();
    try context.lockEnvironment(plan.environment);
    current = try context.loadEnvironment(plan.environment);
    if (!optionalEqual(plan.base_plan_id, if (current) |environment| environment.plan_id else null)) return error.WorkflowStalePlan;
    const models = try a.alloc(Model, plan.models.len);
    for (plan.models, models) |item, *model| model.* = item.model;
    try context.lockVersions(models);
    var completed = try a.alloc(bool, models.len);
    @memset(completed, false);
    var remaining = models.len;
    var run: Run = .{ .project = plan.project, .environment = plan.environment, .plan_id = plan.plan_id, .action = "apply", .status = "success" };
    errdefer |err| {
        if (!eq(run.status, "audit_failed")) run.status = "execution_failed";
        run.error_code = @errorName(err);
        context.artifact("run.json", run) catch {};
    }
    while (remaining != 0) {
        var progressed = false;
        for (models, 0..) |*model, index| {
            if (completed[index] or !dependenciesReady(models, completed, model.depends_on)) continue;
            if (!model.ephemeral) {
                run.failed_model = model.unique_id;
                const exists = try relationExists(&context.session.?, a, model.relation);
                if (model.time_column) |column| {
                    if (try context.loadVersion(model.version)) |cached| model.processed = cached.processed;
                    if (!exists) try createEmptyModel(context, model.*);
                    for (plan.models[index].missing_intervals) |range| try buildInterval(context, model.*, column, range);
                    var ranges: std.ArrayList(interval.Interval) = .empty;
                    if (exists) try ranges.appendSlice(a, model.processed);
                    try ranges.appendSlice(a, plan.models[index].missing_intervals);
                    model.processed = try interval.normalize(a, ranges.items);
                    if (!exists or plan.models[index].missing_intervals.len != 0) run.built += 1 else run.reused += 1;
                } else if (!exists) {
                    try buildFullModel(context, model.*);
                    run.built += 1;
                } else run.reused += 1;
                try context.store("workflow_versions", "version", model.version, model.*);
            }
            completed[index] = true;
            remaining -= 1;
            progressed = true;
        }
        if (!progressed) return error.DependencyCycle;
    }
    run.failed_model = null;
    run.audits = try runAudits(context, plan.audits, &run);
    if (hasAuditFailure(run.audits)) {
        run.status = "audit_failed";
        try context.artifact("run.json", run);
        return error.WorkflowAuditFailure;
    }
    const environment: Environment = .{ .project = plan.project, .gateway = plan.gateway, .name = plan.environment, .plan_id = plan.plan_id, .models = models, .audits = plan.audits, .history = try appendHistory(a, current) };
    try switchViews(context, current, environment);
    try context.store("workflow_environments", "name", environment.name, environment);
    try context.event(run);
    try context.session.?.commit();
    committed = true;
    try context.artifact("run.json", run);
    try context.artifact("environment.json", environment);
    return run;
}

fn transition(context: *Context, command: []const u8) !Run {
    const a = context.runtime.allocator;
    _ = try context.open(true);
    try context.session.?.begin();
    var committed = false;
    defer if (!committed) context.session.?.rollback() catch {};
    if (!try context.metadataExists()) return error.WorkflowEnvironmentMissing;
    try context.ensureMetadata();
    if (eq(command, "promote") and std.mem.order(u8, context.options.from_environment, context.options.environment) == .lt) {
        try context.lockEnvironment(context.options.from_environment);
        try context.lockEnvironment(context.options.environment);
    } else {
        try context.lockEnvironment(context.options.environment);
        if (eq(command, "promote") and !eq(context.options.from_environment, context.options.environment)) try context.lockEnvironment(context.options.from_environment);
    }
    const current = try context.loadEnvironment(context.options.environment);
    var environment: Environment = undefined;
    if (eq(command, "promote")) {
        const source = try context.loadEnvironment(context.options.from_environment) orelse return error.WorkflowEnvironmentMissing;
        if (eq(source.name, context.options.environment)) return error.WorkflowEnvironmentMismatch;
        environment = source;
        environment.name = context.options.environment;
        environment.history = try appendHistory(a, current);
        environment.plan_id = try hash(a, &.{ "promote", source.plan_id, environment.name, if (current) |prior| prior.plan_id else "" });
    } else {
        const prior = current orelse return error.WorkflowEnvironmentMissing;
        if (prior.history.len == 0) return error.WorkflowRollbackMissing;
        const revision = prior.history[prior.history.len - 1];
        environment = prior;
        environment.models = revision.models;
        environment.audits = revision.audits;
        environment.plan_id = revision.plan_id;
        environment.history = prior.history[0 .. prior.history.len - 1];
    }
    var run: Run = .{ .project = context.graph.project_name, .environment = environment.name, .plan_id = environment.plan_id, .action = command, .status = "success", .reused = environment.models.len };
    try context.lockVersions(environment.models);
    errdefer |err| {
        if (!eq(run.status, "audit_failed")) run.status = "execution_failed";
        run.error_code = @errorName(err);
        context.artifact("run.json", run) catch {};
    }
    const audits = try runAudits(context, environment.audits, &run);
    run.audits = audits;
    if (hasAuditFailure(audits)) {
        run.status = "audit_failed";
        try context.artifact("run.json", run);
        return error.WorkflowAuditFailure;
    }
    try switchViews(context, current, environment);
    try context.store("workflow_environments", "name", environment.name, environment);
    try context.event(run);
    try context.session.?.commit();
    committed = true;
    try context.artifact("run.json", run);
    try context.artifact("environment.json", environment);
    return run;
}

fn buildFullModel(context: *Context, model: Model) !void {
    if (eq(model.resource_type, "seed")) return context.session.?.execute(model.sql);
    try createPhysicalSchema(context);
    try context.session.?.execute(try std.fmt.allocPrint(context.runtime.allocator, "create table {s} as {s}", .{ model.relation, trimSql(model.sql) }));
}

fn createPhysicalSchema(context: *Context) !void {
    const schema = try adapter.quoteIdentifier(context.runtime.allocator, try std.fmt.allocPrint(context.runtime.allocator, "{s}_dxt_data", .{context.graph.target_schema}));
    try context.session.?.execute(try std.fmt.allocPrint(context.runtime.allocator, "create schema if not exists {s}", .{schema}));
}

fn createEmptyModel(context: *Context, model: Model) !void {
    try createPhysicalSchema(context);
    const sql = try intervalSql(context.runtime.allocator, model.sql, .{ .start = 0, .end = 0 });
    try context.session.?.execute(try std.fmt.allocPrint(context.runtime.allocator, "create table {s} as select * from ({s}) as __dxt_empty where false", .{ model.relation, trimSql(sql) }));
}

fn buildInterval(context: *Context, model: Model, column: []const u8, range: interval.Interval) !void {
    const a = context.runtime.allocator;
    const quoted = try adapter.quoteIdentifier(a, column);
    const start = try adapter.quoteLiteral(a, try interval.formatTimestamp(a, range.start));
    const end = try adapter.quoteLiteral(a, try interval.formatTimestamp(a, range.end));
    const filter = try std.fmt.allocPrint(a, "{s} >= cast({s} as timestamp) and {s} < cast({s} as timestamp)", .{ quoted, start, quoted, end });
    const rendered = try intervalSql(a, model.sql, range);
    const sql = try std.fmt.allocPrint(a, "delete from {s} where {s}; insert into {s} select * from ({s}) as __dxt_interval where {s}", .{ model.relation, filter, model.relation, trimSql(rendered), filter });
    try context.session.?.execute(sql);
}

fn intervalSql(a: std.mem.Allocator, sql: []const u8, range: interval.Interval) ![]const u8 {
    const start = try interval.formatTimestamp(a, range.start);
    const end = try interval.formatTimestamp(a, range.end);
    const with_start = try std.mem.replaceOwned(u8, a, sql, "__DXT_INTERVAL_START__", start);
    return std.mem.replaceOwned(u8, a, with_start, "__DXT_INTERVAL_END__", end);
}

fn switchViews(context: *Context, current: ?Environment, environment: Environment) !void {
    const a = context.runtime.allocator;
    // Remove dependent views first; physical versions remain available to rollback.
    if (current) |previous| {
        var index = previous.models.len;
        while (index > 0) {
            index -= 1;
            const model = previous.models[index];
            if (model.ephemeral) continue;
            const relation = try environmentRelation(a, model, environment.name);
            try context.session.?.execute(try std.fmt.allocPrint(a, "drop view if exists {s}", .{relation}));
        }
    }
    for (environment.models) |model| {
        if (model.ephemeral) continue;
        if (!try relationExists(&context.session.?, a, model.relation)) return error.WorkflowPhysicalVersionMissing;
        const schema_name = if (eq(environment.name, "prod")) model.schema else try std.fmt.allocPrint(a, "{s}__{s}", .{ model.schema, environment.name });
        const schema = try adapter.quoteIdentifier(a, schema_name);
        const relation = try environmentRelation(a, model, environment.name);
        try context.session.?.execute(try std.fmt.allocPrint(a, "create schema if not exists {s}; create or replace view {s} as select * from {s}", .{ schema, relation, model.relation }));
    }
}

fn compileAudits(context: *Context) ![]const Audit {
    const a = context.runtime.allocator;
    var audits: std.ArrayList(Audit) = .empty;
    for (context.graph.tests.items) |*test_node| {
        if (test_node.attached_node) |id| {
            if (findNode(context.graph, id)) |node| if (!node.enabled) continue;
        }
        try audits.append(a, .{ .unique_id = test_node.unique_id, .sql = try compiler.compileGenericTest(a, context.graph, test_node), .severity = test_node.config.severity, .error_if = test_node.config.error_if, .warn_if = test_node.config.warn_if, .limit = test_node.config.limit });
    }
    for (context.graph.singular_tests.items) |*test_node| {
        if (!test_node.enabled) continue;
        try audits.append(a, .{ .unique_id = test_node.unique_id, .sql = try compiler.compileSingularTest(a, context.graph, test_node), .severity = test_node.config.severity, .error_if = test_node.config.error_if, .warn_if = test_node.config.warn_if, .limit = test_node.config.limit });
    }
    return audits.items;
}

fn runAudits(context: *Context, audits: []const Audit, run: *Run) ![]const AuditResult {
    const a = context.runtime.allocator;
    const results = try a.alloc(AuditResult, audits.len);
    for (audits, results, 0..) |audit, *result, index| {
        run.failed_audit = audit.unique_id;
        const body = if (audit.limit) |limit| try std.fmt.allocPrint(a, "select * from ({s}) as __dxt_limited limit {d}", .{ trimSql(audit.sql), limit }) else trimSql(audit.sql);
        const sql = try std.fmt.allocPrint(a, "select count(*) as failures, count(*) {s} as should_error, count(*) {s} as should_warn from ({s}) as __dxt_audit", .{ audit.error_if, audit.warn_if, body });
        var query = context.session.?.query(sql) catch |err| {
            result.* = .{ .unique_id = audit.unique_id, .failures = null, .status = .@"error", .error_code = @errorName(err) };
            run.audits = results[0 .. index + 1];
            return err;
        };
        defer query.deinit(a);
        if (query.rows.len != 1 or query.columns.len != 3) return error.WorkflowAuditResultInvalid;
        const failures = std.fmt.parseInt(u64, query.rows[0][0] orelse return error.WorkflowAuditResultInvalid, 10) catch return error.WorkflowAuditResultInvalid;
        const error_condition = truth(query.rows[0][1]);
        const warning_condition = truth(query.rows[0][2]);
        result.* = .{ .unique_id = audit.unique_id, .failures = failures, .status = if (std.ascii.eqlIgnoreCase(audit.severity, "ERROR") and error_condition) .fail else if (warning_condition) .warn else .pass };
    }
    run.failed_audit = null;
    return results;
}

fn appendHistory(a: std.mem.Allocator, current: ?Environment) ![]const Revision {
    const environment = current orelse return &.{};
    const history = try a.alloc(Revision, environment.history.len + 1);
    @memcpy(history[0..environment.history.len], environment.history);
    history[environment.history.len] = .{ .plan_id = environment.plan_id, .models = environment.models, .audits = environment.audits };
    return history;
}

fn bindRelations(graph: *types.Graph, changes: []const Change, a: std.mem.Allocator) !void {
    graph.deferred_relations.clearRetainingCapacity();
    for (changes) |change| if (!change.model.ephemeral) try graph.deferred_relations.append(a, .{ .unique_id = change.model.unique_id, .relation_name = change.model.relation });
}

fn relationExists(session: *adapter.Session, a: std.mem.Allocator, relation: []const u8) !bool {
    const literal = try adapter.quoteLiteral(a, relation);
    // ANSI information_schema needs individual identifiers; PostgreSQL's
    // to_regclass and DuckDB's catalog both accept the same qualified syntax.
    if (session.* == .postgres) {
        var result = try session.query(try std.fmt.allocPrint(a, "select to_regclass({s}) is not null", .{literal}));
        defer result.deinit(a);
        return truth(result.firstScalar());
    }
    const parsed = try splitRelation(a, relation);
    return session.relationExists(a, parsed[0], parsed[1]);
}

fn splitRelation(a: std.mem.Allocator, relation: []const u8) ![2][]const u8 {
    var identifiers: std.ArrayList([]const u8) = .empty;
    var buffer: std.ArrayList(u8) = .empty;
    var quoted = false;
    var index: usize = 0;
    while (index < relation.len) : (index += 1) {
        const byte = relation[index];
        if (byte == '"') {
            if (quoted and index + 1 < relation.len and relation[index + 1] == '"') {
                try buffer.append(a, '"');
                index += 1;
            } else quoted = !quoted;
        } else if (byte == '.' and !quoted) {
            try identifiers.append(a, try buffer.toOwnedSlice(a));
        } else try buffer.append(a, byte);
    }
    if (quoted) return error.InvalidSqlIdentifier;
    try identifiers.append(a, try buffer.toOwnedSlice(a));
    if (identifiers.items.len < 2) return error.InvalidSqlIdentifier;
    return .{ identifiers.items[identifiers.items.len - 2], identifiers.items[identifiers.items.len - 1] };
}

fn environmentRelation(a: std.mem.Allocator, model: Model, name: []const u8) ![]const u8 {
    const schema_name = if (eq(name, "prod")) model.schema else try std.fmt.allocPrint(a, "{s}__{s}", .{ model.schema, name });
    defer if (!eq(name, "prod")) a.free(schema_name);
    const schema = try adapter.quoteIdentifier(a, schema_name);
    defer a.free(schema);
    const alias = try adapter.quoteIdentifier(a, model.alias);
    defer a.free(alias);
    return std.fmt.allocPrint(a, "{s}.{s}", .{ schema, alias });
}

fn physicalIdentifier(a: std.mem.Allocator, id: []const u8, version: []const u8) ![]const u8 {
    const prefix = try hash(a, &.{id});
    return std.fmt.allocPrint(a, "m_{s}_{s}", .{ prefix[0..12], version[0..32] });
}

fn findModel(models: []const Model, id: []const u8) ?Model {
    for (models) |model| if (eq(model.unique_id, id)) return model;
    return null;
}

fn findNode(graph: *types.Graph, id: []const u8) ?*types.Node {
    for (graph.nodes.items) |*node| if (eq(node.unique_id, id)) return node;
    return null;
}

fn dependenciesReady(models: []const Model, completed: []const bool, dependencies: []const []const u8) bool {
    for (dependencies) |dependency| for (models, completed) |model, done| if (eq(model.unique_id, dependency) and !done) return false;
    return true;
}

fn configValue(context: *Context, id: []const u8, name: []const u8, key: []const u8) ?std.json.Value {
    const models = values.get(context.config, "models") orelse return null;
    const model = values.get(models, id) orelse values.get(models, name) orelse return null;
    return values.get(model, key);
}

fn validateConfiguration(config: std.json.Value, graph: *const types.Graph) !void {
    if (config != .object) return error.InvalidWorkflowConfiguration;
    var root_keys = config.object.iterator();
    while (root_keys.next()) |entry| if (!eq(entry.key_ptr.*, "models")) return error.InvalidWorkflowConfiguration;
    const models = values.get(config, "models") orelse return;
    if (models != .object) return error.InvalidWorkflowConfiguration;
    var entries = models.object.iterator();
    while (entries.next()) |entry| {
        var matched = false;
        for (graph.nodes.items) |node| if ((eq(node.resource_type, "model") or eq(node.resource_type, "seed")) and (eq(node.name, entry.key_ptr.*) or eq(node.unique_id, entry.key_ptr.*))) {
            matched = true;
            break;
        };
        if (!matched or entry.value_ptr.* != .object) return error.InvalidWorkflowConfiguration;
        var fields = entry.value_ptr.object.iterator();
        while (fields.next()) |field| {
            const key = field.key_ptr.*;
            if (!eq(key, "time_column") and !eq(key, "interval_unit") and !eq(key, "lookback") and !eq(key, "start")) return error.InvalidWorkflowConfiguration;
        }
    }
}

fn configString(context: *Context, id: []const u8, name: []const u8, key: []const u8) !?[]const u8 {
    const value = configValue(context, id, name, key) orelse return null;
    if (value == .null) return null;
    if (value != .string) return error.InvalidWorkflowConfiguration;
    return value.string;
}

fn appendMacros(a: std.mem.Allocator, graph: *const types.Graph, ids: []const []const u8, parts: *std.ArrayList([]const u8), depth: usize) anyerror!void {
    if (depth > 128) return error.DependencyCycle;
    for (ids) |id| for (graph.macros.items) |macro| if (eq(macro.unique_id, id)) {
        try parts.append(a, macro.macro_sql);
        try appendMacros(a, graph, macro.macro_depends_on.items, parts, depth + 1);
        break;
    };
}

fn planHash(a: std.mem.Allocator, input: Plan) ![]const u8 {
    var plan = input;
    plan.plan_id = "";
    return hash(a, &.{try std.json.Stringify.valueAlloc(a, plan, .{})});
}

fn hash(a: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts) |part| {
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, part.len, .little);
        digest.update(&length);
        digest.update(part);
    }
    var bytes: [32]u8 = undefined;
    digest.final(&bytes);
    return a.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
}

fn atomicWrite(runtime: types.Runtime, path: []const u8, text: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(runtime.io, parent);
    const temporary = try std.fmt.allocPrint(runtime.allocator, "{s}.{d}.{d}.tmp", .{ path, std.os.linux.getpid(), std.Io.Clock.real.now(runtime.io).nanoseconds });
    defer std.Io.Dir.cwd().deleteFile(runtime.io, temporary) catch {};
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = temporary, .data = text });
    try std.Io.Dir.rename(std.Io.Dir.cwd(), temporary, std.Io.Dir.cwd(), path, runtime.io);
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > 63) return error.InvalidWorkflowEnvironment;
    for (name) |byte| if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '_') return error.InvalidWorkflowEnvironment;
}

fn hasAuditFailure(results: []const AuditResult) bool {
    for (results) |result| if (result.status == .fail) return true;
    return false;
}
fn optionalEqual(lhs: ?[]const u8, rhs: ?[]const u8) bool {
    if (lhs) |left| return if (rhs) |right| eq(left, right) else false;
    return rhs == null;
}
fn truth(text: ?[]const u8) bool {
    const value = text orelse return false;
    return eq(value, "true") or eq(value, "t") or eq(value, "1");
}
fn trimSql(sql: []const u8) []const u8 {
    return std.mem.trimEnd(u8, std.mem.trim(u8, sql, " \t\r\n"), "; \t\r\n");
}
fn eq(lhs: []const u8, rhs: []const u8) bool {
    return std.mem.eql(u8, lhs, rhs);
}
fn jsonOutput(writer: *std.Io.Writer, object: anytype) !void {
    try std.json.Stringify.value(object, .{ .whitespace = .indent_2 }, writer);
    try writer.writeByte('\n');
}

test "workflow namespaces reject ambiguous environment names and quote aliases" {
    const a = std.testing.allocator;
    try validateName("pr_42");
    try std.testing.expectError(error.InvalidWorkflowEnvironment, validateName("prod;drop"));
    const model: Model = .{ .unique_id = "model.demo.a", .name = "a", .resource_type = "model", .schema = "main", .alias = "a\"b", .own_hash = "", .version = "", .relation = "" };
    const relation = try environmentRelation(a, model, "preview");
    defer a.free(relation);
    try std.testing.expectEqualStrings("\"main__preview\".\"a\"\"b\"", relation);
}
