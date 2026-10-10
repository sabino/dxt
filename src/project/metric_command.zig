const std = @import("std");
const types = @import("types.zig");
const planner = @import("metric_plan.zig");
const sem = @import("semantic.zig");
const adapter = @import("adapter.zig");
const duckdb = @import("duckdb.zig");
const fs = @import("fs.zig");
const values = @import("config_value.zig");
const cross = @import("cross_database.zig");
const target_locks = @import("cross_database_lock.zig");

pub fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: dxt metric <query|explain|export> [options]
        \\
        \\  --metrics <names>              Comma-separated metric names.
        \\  --group-by <dimensions>        Dimensions, entities or metric_time__grain.
        \\  --where <SQL>                  SQL predicates with semantic Dimension builders.
        \\  --order-by <names>             Order by output names; prefix '-' to descend.
        \\  --limit <rows>                 Limit output rows.
        \\  --start-time/--end-time <time>  Inclusive metric time periods.
        \\  --saved-query <name>           Use saved query metrics and query parameters.
        \\  --connection <name>            Primary named dxt_connections.yml connection.
        \\  --execution-connection <name>  Explicit execution warehouse or embedded DuckDB.
        \\  --config <path>                Named connection and movement policy document.
        \\  --plan-hash <sha256>           Require the exact reviewed movement plan.
        \\  --allow-movement               Permit movement allowed by connection policy.
        \\  --allow-sensitive              Permit sensitive movement allowed by trust policy.
        \\  --allow-raw-extract            Permit explicitly declared full-table extracts.
        \\  --max-rows/--max-bytes <n>      Bound total movement and final query results.
        \\  --max-memory-bytes <n>         Bound native extraction and execution memory.
        \\  --max-spill-bytes <n>          Bound DuckDB temporary storage (default: no spill).
        \\  --max-objects <n>              Bound staging objects.
        \\  --max-query-seconds <n>        Bound each native query duration.
        \\  --max-cost <amount>            Bound declared and observed egress cost.
        \\  --project-dir/--profiles-dir <path>  Standard dbt project/profile directories.
        \\  --target <name>                Standard dbt profile target.
        \\
    );
}

pub const Parsed = struct { query: planner.Query, common: []const []const u8 };
pub fn parse(allocator: std.mem.Allocator, args: []const []const u8, explain: bool, export_saved: bool) !Parsed {
    var query = planner.Query{ .explain = explain, .export_saved_query = export_saved };
    var metrics: std.ArrayList([]const u8) = .empty;
    var groups: std.ArrayList([]const u8) = .empty;
    var filters: std.ArrayList([]const u8) = .empty;
    var orders: std.ArrayList([]const u8) = .empty;
    var common: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        var inline_value: ?[]const u8 = null;
        const name = if (std.mem.indexOfScalar(u8, arg, '=')) |at| blk: {
            inline_value = arg[at + 1 ..];
            break :blk arg[0..at];
        } else arg;
        if (std.mem.eql(u8, name, "--allow-movement") or std.mem.eql(u8, name, "--allow-sensitive") or std.mem.eql(u8, name, "--allow-raw-extract")) {
            if (inline_value != null) return error.InvalidOption;
            if (std.mem.eql(u8, name, "--allow-movement")) query.movement_policy.allow_movement = true else if (std.mem.eql(u8, name, "--allow-sensitive")) query.movement_policy.allow_sensitive = true else query.movement_policy.allow_raw_extract = true;
            query.movement_configured = true;
            continue;
        }
        var recognized = false;
        for ([_][]const u8{ "--metrics", "--group-by", "--where", "--order-by", "--limit", "--start-time", "--end-time", "--saved-query", "--connection", "--execution-connection", "--config", "--plan-hash", "--max-rows", "--max-bytes", "--max-memory-bytes", "--max-spill-bytes", "--max-objects", "--max-query-seconds", "--max-cost" }) |known| if (std.mem.eql(u8, name, known)) {
            recognized = true;
            break;
        };
        if (!recognized) {
            try common.append(allocator, arg);
            if (inline_value == null) {
                i += 1;
                if (i >= args.len) return error.InvalidOption;
                try common.append(allocator, args[i]);
            }
            continue;
        }
        var raw = inline_value;
        if (raw == null) {
            i += 1;
            if (i >= args.len) return error.InvalidOption;
            raw = args[i];
        }
        const value = raw.?;
        if (value.len == 0) return error.InvalidOption;
        if (std.mem.eql(u8, name, "--connection") or std.mem.eql(u8, name, "--execution-connection") or std.mem.eql(u8, name, "--config") or std.mem.eql(u8, name, "--plan-hash") or std.mem.startsWith(u8, name, "--max-")) {
            query.movement_configured = true;
            if (std.mem.eql(u8, name, "--connection")) query.connection = value else if (std.mem.eql(u8, name, "--execution-connection")) query.execution_connection = value else if (std.mem.eql(u8, name, "--config")) query.movement_policy.config = value else if (std.mem.eql(u8, name, "--plan-hash")) query.movement_policy.plan_hash = value else if (std.mem.eql(u8, name, "--max-cost")) {
                const cost = std.fmt.parseFloat(f64, value) catch return error.InvalidOption;
                if (!std.math.isFinite(cost) or cost < 0) return error.InvalidOption;
                query.movement_budget.max_cost = cost;
            } else {
                const amount = std.fmt.parseInt(u64, value, 10) catch return error.InvalidOption;
                if (std.mem.eql(u8, name, "--max-rows")) query.movement_budget.max_rows = amount else if (std.mem.eql(u8, name, "--max-bytes")) query.movement_budget.max_bytes = amount else if (std.mem.eql(u8, name, "--max-memory-bytes")) query.movement_budget.max_memory_bytes = amount else if (std.mem.eql(u8, name, "--max-spill-bytes")) query.movement_budget.max_spill_bytes = amount else if (std.mem.eql(u8, name, "--max-objects")) query.movement_budget.max_objects = amount else query.movement_budget.max_query_seconds = amount;
            }
            continue;
        }
        if (std.mem.eql(u8, name, "--metrics") or std.mem.eql(u8, name, "--group-by") or std.mem.eql(u8, name, "--order-by")) {
            const target = if (std.mem.eql(u8, name, "--metrics")) &metrics else if (std.mem.eql(u8, name, "--group-by")) &groups else &orders;
            try splitNames(allocator, target, value);
            if (inline_value == null) while (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "--")) {
                i += 1;
                try splitNames(allocator, target, args[i]);
            };
        } else if (std.mem.eql(u8, name, "--where")) try filters.append(allocator, value) else if (std.mem.eql(u8, name, "--limit")) {
            query.limit = std.fmt.parseInt(u64, value, 10) catch return error.InvalidOption;
        } else if (std.mem.eql(u8, name, "--start-time")) {
            query.start_time = value;
        } else if (std.mem.eql(u8, name, "--end-time")) {
            query.end_time = value;
        } else {
            query.saved_query = value;
        }
    }
    query.metrics = metrics.items;
    query.group_by = groups.items;
    query.where = filters.items;
    query.order_by = orders.items;
    if (query.metrics.len == 0 and query.saved_query == null) return error.InvalidMetricQuery;
    if (export_saved and query.saved_query == null) return error.MissingSavedQuery;
    return .{ .query = query, .common = common.items };
}
fn splitNames(a: std.mem.Allocator, target: *std.ArrayList([]const u8), raw: []const u8) !void {
    var tokens = std.mem.tokenizeAny(u8, raw, ", \t\r\n");
    while (tokens.next()) |name| try target.append(a, name);
}
pub fn execute(runtime: types.Runtime, graph: *const types.Graph, options: types.Options, query: planner.Query, stdout: *std.Io.Writer) !void {
    if (query.movement_configured and query.connection == null) return error.MissingMetricConnection;
    var planning_graph = graph.*;
    // Named plans discover the execution engine before final SQL rendering.
    if (query.connection != null) planning_graph.adapter_type = "duckdb";
    var plan = try planner.build(runtime.allocator, &planning_graph, query);
    defer plan.deinit();
    if (query.connection == null) for (plan.bindings) |binding| if (binding.mapped) return error.MissingMetricConnection;
    var physical: ?cross.QueryPlan = null;
    defer if (physical) |*document| document.deinit();
    if (query.connection) |connection| {
        physical = try physicalPlan(runtime, options, query, connection, &plan);
        const engine = physical.?.value.connections[physical.?.value.models[0].execution_connection].adapter_type;
        if (!std.mem.eql(u8, engine, planning_graph.adapter_type)) {
            planning_graph.adapter_type = engine;
            const rendered = try planner.build(runtime.allocator, &planning_graph, query);
            plan.deinit();
            plan = rendered;
            const replacement = try physicalPlan(runtime, options, query, connection, &plan);
            physical.?.deinit();
            physical = replacement;
        }
        if (query.movement_policy.plan_hash) |expected| if (!std.mem.eql(u8, expected, physical.?.value.hash)) return error.CrossDatabasePlanChanged;
        const physical_json = try physical.?.json(runtime.allocator);
        defer runtime.allocator.free(physical_json);
        const a = plan.arena.allocator();
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, physical_json, .{ .allocate = .alloc_always });
        try values.put(a, &plan.logical, "cross_database", parsed);
        try values.put(a, &plan.logical, "strategy", sem.field(sem.list(sem.field(parsed, "models"))[0], "strategy"));
        var movement: std.json.Value = .{ .array = std.json.Array.init(a) };
        for (sem.list(sem.field(sem.list(sem.field(parsed, "models"))[0], "inputs"))) |input| {
            const moved = sem.field(input, "moved");
            if (moved == .bool and moved.bool) try movement.array.append(input);
        }
        try values.put(a, &plan.logical, "movement", movement);
    }
    var exports: []const std.json.Value = &.{};
    if (query.export_saved_query) {
        const resource = sem.find(graph, "saved_query", query.saved_query.?) orelse return error.MissingSavedQuery;
        exports = sem.list(sem.field(resource.data, "exports"));
        if (exports.len == 0) return error.MissingSavedQueryExports;
        var destination_graph = graph.*;
        if (physical) |document| {
            const identity = document.value.connections[document.value.models[0].destination].identity;
            destination_graph.target_context = identity.target_context;
            destination_graph.database_path = identity.database_path;
        }
        for (exports) |exported| {
            const config = sem.field(exported, "config");
            const database_name = sem.string(sem.field(config, "database"));
            const explicit_database = sem.field(sem.field(exported, "unrendered_config"), "database") != .null;
            if (database_name) |requested| if ((explicit_database or !std.mem.eql(u8, requested, sem.databaseForGraph(graph))) and !std.mem.eql(u8, requested, sem.databaseForGraph(&destination_graph))) return error.MetricExportDatabaseMismatch;
        }
        if (physical) |document| for (exports) |exported| {
            const kind = sem.string(sem.field(sem.field(exported, "config"), "export_as")) orelse return error.InvalidMetricQuery;
            if (std.mem.eql(u8, kind, "view")) {
                const model = document.value.models[0];
                if (model.execution_connection != model.destination) return error.CrossDatabaseMetricViewUnavailable;
                for (model.inputs) |input| if (input.moved) return error.CrossDatabaseMetricViewUnavailable;
            }
        };
    }
    const target_dir = options.target_path orelse "target";
    const target = if (std.fs.path.isAbsolute(target_dir)) target_dir else try fs.pathJoin(runtime.allocator, &.{ options.project_dir, target_dir });
    try std.Io.Dir.cwd().createDirPath(runtime.io, target);
    const plan_path = try fs.pathJoin(runtime.allocator, &.{ target, "metric_plan.json" });
    const plan_json = try plan.json(runtime.allocator);
    defer runtime.allocator.free(plan_json);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = plan_path, .data = plan_json });
    if (query.explain) {
        try stdout.print("{s}\n", .{plan_json});
        return;
    }
    const database = try duckdb.databasePath(runtime.allocator, target, graph);
    defer runtime.allocator.free(database);
    var locks: std.ArrayList(target_locks.Lock) = .empty;
    defer {
        for (locks.items) |*lock| lock.deinit();
        locks.deinit(runtime.allocator);
    }
    var export_session: ?adapter.Session = null;
    defer if (export_session) |*session| session.deinit();
    errdefer if (export_session) |*session| session.rollback() catch {};
    if (query.export_saved_query) {
        const connection = if (physical) |document| document.value.connections[document.value.models[0].destination] else profileConnection(graph, database);
        var acquired: std.StringHashMap(void) = .init(runtime.allocator);
        defer {
            var keys = acquired.keyIterator();
            while (keys.next()) |key| runtime.allocator.free(key.*);
            acquired.deinit();
        }
        for (exports) |exported| {
            const config = sem.field(exported, "config");
            const schema = sem.string(sem.field(config, "schema_name")) orelse graph.target_schema;
            const alias = sem.string(sem.field(config, "alias")) orelse return error.InvalidMetricQuery;
            const key = try std.fmt.allocPrint(runtime.allocator, "{s}.{s}", .{ schema, alias });
            defer runtime.allocator.free(key);
            if (acquired.contains(key)) continue;
            var lock = try target_locks.acquire(runtime, options.project_dir, connection, schema, alias);
            locks.append(runtime.allocator, lock) catch |err| {
                lock.deinit();
                return err;
            };
            const owned_key = try runtime.allocator.dupe(u8, key);
            acquired.put(owned_key, {}) catch |err| {
                runtime.allocator.free(owned_key);
                return err;
            };
        }
        if (std.mem.eql(u8, connection.adapter_type, "postgres")) {
            export_session = if (physical) |document| try cross.openConnection(runtime, document.root, connection) else try adapter.openSession(runtime, graph, database);
            try export_session.?.begin();
            for (exports) |exported| {
                const config = sem.field(exported, "config");
                const schema = sem.string(sem.field(config, "schema_name")) orelse graph.target_schema;
                const alias = sem.string(sem.field(config, "alias")) orelse return error.InvalidMetricQuery;
                try target_locks.acquireDatabase(runtime.allocator, &export_session.?, schema, alias);
            }
        }
    }
    if (physical) |*document| {
        var outcome = try cross.executeQueryPlan(runtime, document);
        defer outcome.deinit(runtime.allocator);
        if (query.export_saved_query) {
            var destination: ?adapter.Session = if (export_session == null) try cross.openConnection(runtime, document.root, document.value.connections[document.value.models[0].destination]) else null;
            defer if (destination) |*session| session.deinit();
            var destination_runtime = runtime;
            destination_runtime.adapter_session = if (export_session) |*session| session else &destination.?;
            const model = document.value.models[0];
            const local_sql = if (model.execution_connection == model.destination) try cross.renderSql(runtime.allocator, model, null) else "";
            try exportRelations(destination_runtime, graph, database, exports, local_sql, &outcome, document.value.connections[model.execution_connection].adapter_type, export_session != null);
            if (export_session) |*session| session.commit() catch return error.MetricExecutionFailure;
            try stdout.print("Exported {d} saved query relation(s)\n", .{exports.len});
        } else try writeResults(runtime, target, &outcome.result, stdout);
        return;
    }
    if (query.export_saved_query) {
        var export_runtime = runtime;
        if (export_session) |*session| export_runtime.adapter_session = session;
        try exportRelations(export_runtime, graph, database, exports, plan.sql, null, graph.adapter_type, export_session != null);
        if (export_session) |*session| session.commit() catch return error.MetricExecutionFailure;
        try stdout.print("Exported {d} saved query relation(s)\n", .{exports.len});
        return;
    }
    var result = adapter.queryForGraph(runtime, graph, database, plan.sql) catch return error.MetricExecutionFailure;
    defer result.deinit(runtime.allocator);
    try writeResults(runtime, target, &result, stdout);
}
fn profileConnection(graph: *const types.Graph, database: []const u8) cross.Connection {
    return .{
        .name = "profile",
        .profile_name = graph.profile_name orelse graph.project_name,
        .target = graph.target_name orelse "default",
        .adapter_type = graph.adapter_type,
        .role = "destination",
        .trust_domain = "profile",
        .allowed_destinations = &.{},
        .identity = .{
            .profile_name = graph.profile_name orelse graph.project_name,
            .target_name = graph.target_name orelse "default",
            .adapter_type = graph.adapter_type,
            .target_schema = graph.target_schema,
            .database_path = if (std.mem.eql(u8, graph.adapter_type, "duckdb")) database else null,
            .connection_info = graph.connection_info,
            .target_context = graph.target_context,
        },
    };
}

fn physicalPlan(runtime: types.Runtime, options: types.Options, query: planner.Query, connection: []const u8, plan: *const planner.Plan) !cross.QueryPlan {
    const bindings = try runtime.allocator.alloc(cross.RelationBinding, plan.bindings.len);
    defer runtime.allocator.free(bindings);
    for (bindings, plan.bindings) |*binding, source| binding.* = .{ .logical_id = source.logical_id, .relation_name = source.relation_name, .connection = source.connection, .source_relation = source.source_relation, .source_query = source.source_query, .sensitivity = source.sensitivity, .estimated_rows = source.estimated_rows, .estimated_bytes = source.estimated_bytes };
    var policy = query.movement_policy;
    policy.profiles_dir = options.profiles_dir;
    return cross.planQuery(runtime, options.project_dir, .{ .connection = connection, .execution_connection = query.execution_connection, .policy = policy, .budget = query.movement_budget }, plan.sql, bindings);
}
fn writeResults(runtime: types.Runtime, target: []const u8, result: *const adapter.QueryResult, stdout: *std.Io.Writer) !void {
    const json = try result.json(runtime.allocator);
    defer runtime.allocator.free(json);
    const path = try fs.pathJoin(runtime.allocator, &.{ target, "metric_results.json" });
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = path, .data = json });
    try stdout.print("{s}\n", .{json});
}
fn exportRelations(runtime: types.Runtime, graph: *const types.Graph, database: []const u8, exports: []const std.json.Value, sql: []const u8, outcome: ?*const cross.QueryOutcome, source_adapter: []const u8, transaction_open: bool) !void {
    var owned_session: ?adapter.Session = null;
    defer if (owned_session) |*session| session.deinit();
    var export_runtime = runtime;
    if (runtime.adapter_session == null and std.mem.eql(u8, graph.adapter_type, "postgres")) {
        owned_session = try adapter.openSession(runtime, graph, database);
        export_runtime.adapter_session = &owned_session.?;
    }
    const session = export_runtime.adapter_session;
    for (exports) |exported| {
        const config = sem.field(exported, "config");
        const schema = sem.string(sem.field(config, "schema_name")) orelse graph.target_schema;
        const alias = sem.string(sem.field(config, "alias")) orelse return error.InvalidMetricQuery;
        const kind = sem.string(sem.field(config, "export_as")) orelse return error.InvalidMetricQuery;
        errdefer if (session) |destination| destination.rollback() catch {};
        if (session) |destination| {
            if (!transaction_open) {
                try destination.begin();
                try target_locks.acquireDatabase(runtime.allocator, destination, schema, alias);
            }
        }
        const qs = try adapter.quoteIdentifier(runtime.allocator, schema);
        const qi = try adapter.quoteIdentifier(runtime.allocator, alias);
        const schema_literal = try adapter.quoteLiteral(runtime.allocator, schema);
        const alias_literal = try adapter.quoteLiteral(runtime.allocator, alias);
        const lookup = try std.fmt.allocPrint(runtime.allocator, "select table_type from information_schema.tables where table_schema={s} and table_name={s}", .{ schema_literal, alias_literal });
        var existing = adapter.queryForGraph(export_runtime, graph, database, lookup) catch return error.MetricExecutionFailure;
        defer existing.deinit(runtime.allocator);
        const drop = if (existing.firstScalar()) |table_type| try std.fmt.allocPrint(runtime.allocator, "DROP {s} {s}.{s};", .{ if (std.mem.eql(u8, table_type, "VIEW")) "VIEW" else "TABLE", qs, qi }) else "";
        if (outcome != null and std.mem.eql(u8, kind, "table")) {
            const destination = session orelse return error.MetricExecutionFailure;
            destination.execute(try std.fmt.allocPrint(runtime.allocator, "CREATE SCHEMA IF NOT EXISTS {s}; {s}", .{ qs, drop })) catch return error.MetricExecutionFailure;
            const relation = try std.fmt.allocPrint(runtime.allocator, "{s}.{s}", .{ qs, qi });
            cross.materializeQueryResult(export_runtime, destination, relation, outcome.?, source_adapter) catch return error.MetricExecutionFailure;
        } else if (session) |destination| {
            destination.execute(try std.fmt.allocPrint(runtime.allocator, "CREATE SCHEMA IF NOT EXISTS {s}; {s} CREATE {s} {s}.{s} AS {s};", .{ qs, drop, kind, qs, qi, sql })) catch return error.MetricExecutionFailure;
        } else {
            const export_sql = try std.fmt.allocPrint(runtime.allocator, "BEGIN; CREATE SCHEMA IF NOT EXISTS {s}; {s} CREATE {s} {s}.{s} AS {s}; COMMIT;", .{ qs, drop, kind, qs, qi, sql });
            adapter.executeForGraph(export_runtime, graph, database, export_sql) catch return error.MetricExecutionFailure;
        }
        if (session) |destination| if (!transaction_open) destination.commit() catch return error.MetricExecutionFailure;
    }
}

test "metric options retain typed movement policy and reject ignored booleans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try parse(arena.allocator(), &.{ "--metrics", "revenue", "--connection=warehouse", "--execution-connection", "embedded", "--allow-movement", "--max-rows=23", "--max-query-seconds", "10", "--max-cost", "0.5", "--project-dir", "example" }, false, false);
    try std.testing.expectEqualStrings("warehouse", parsed.query.connection.?);
    try std.testing.expectEqualStrings("embedded", parsed.query.execution_connection.?);
    try std.testing.expect(parsed.query.movement_policy.allow_movement);
    try std.testing.expectEqual(@as(u64, 23), parsed.query.movement_budget.max_rows);
    try std.testing.expectEqual(@as(u64, 10), parsed.query.movement_budget.max_query_seconds);
    try std.testing.expectEqual(@as(f64, 0.5), parsed.query.movement_budget.max_cost.?);
    try std.testing.expectEqualStrings("--project-dir", parsed.common[0]);
    try std.testing.expectError(error.InvalidOption, parse(arena.allocator(), &.{ "--metrics", "revenue", "--allow-movement=false" }, false, false));
    try std.testing.expectError(error.InvalidOption, parse(arena.allocator(), &.{ "--metrics", "revenue", "--max-cost", "nan" }, false, false));
}
