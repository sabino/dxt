const std = @import("std");
const types = @import("types.zig");
const sem = @import("semantic.zig");
const compiler = @import("compiler.zig");
const values = @import("config_value.zig");
const expression = @import("expression.zig");
const cross = @import("cross_database.zig");
const Value = std.json.Value;
const Graph = types.Graph;
const Resource = types.SemanticResource;
const field = sem.field;
const list = sem.list;
fn text(value: Value, key: []const u8) ?[]const u8 {
    return sem.string(field(value, key));
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn ident(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    return compiler.quoteIdentifier(a, name);
}
fn sqlText(a: std.mem.Allocator, text_sql: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.writeByte('\'');
    for (text_sql) |c| {
        try out.writer.writeByte(c);
        if (c == '\'') try out.writer.writeByte(c);
    }
    try out.writer.writeByte('\'');
    return out.toOwnedSlice();
}

pub const Query = struct {
    metrics: []const []const u8 = &.{},
    group_by: []const []const u8 = &.{},
    where: []const []const u8 = &.{},
    order_by: []const []const u8 = &.{},
    limit: ?u64 = null,
    start_time: ?[]const u8 = null,
    end_time: ?[]const u8 = null,
    saved_query: ?[]const u8 = null,
    explain: bool = false,
    export_saved_query: bool = false,
    connection: ?[]const u8 = null,
    execution_connection: ?[]const u8 = null,
    movement_policy: cross.Options = .{},
    movement_budget: cross.Budget = .{},
    movement_configured: bool = false,
};

pub const RelationBinding = struct {
    logical_id: []const u8,
    relation_name: []const u8,
    connection: ?[]const u8 = null,
    source_relation: []const u8,
    source_query: ?[]const u8 = null,
    sensitivity: []const u8 = "public",
    estimated_rows: ?u64 = null,
    estimated_bytes: ?u64 = null,
    mapped: bool = false,
};

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    sql: []const u8,
    logical: Value,
    bindings: []const RelationBinding,
    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
    }
    pub fn json(self: *const Plan, allocator: std.mem.Allocator) ![]const u8 {
        return std.json.Stringify.valueAlloc(allocator, self.logical, .{ .whitespace = .indent_2 });
    }
};

pub fn build(allocator: std.mem.Allocator, graph: *const Graph, request: Query) !Plan {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var query = request;
    if (query.saved_query) |name| {
        if (query.metrics.len != 0) return error.InvalidMetricQuery;
        const saved = sem.find(graph, "saved_query", name) orelse return error.MissingSavedQuery;
        const params = field(saved.data, "query_params");
        query.metrics = try names(a, field(params, "metrics"), false);
        if (query.group_by.len == 0) query.group_by = try names(a, field(params, "group_by"), true);
        if (query.order_by.len == 0) query.order_by = try names(a, field(params, "order_by"), true);
        if (query.limit == null and field(params, "limit") == .integer) query.limit = @intCast(field(params, "limit").integer);
        var where: std.ArrayList([]const u8) = .empty;
        try where.appendSlice(a, query.where);
        for (list(field(field(params, "where"), "where_filters"))) |filter| try where.append(a, text(filter, "where_sql_template") orelse return error.InvalidMetricQuery);
        query.where = where.items;
    }
    if (query.metrics.len == 0) return error.InvalidMetricQuery;
    if (!eq(graph.adapter_type, "duckdb") and !eq(graph.adapter_type, "postgres")) return error.UnsupportedMetricAdapter;
    var ctx = Context{ .allocator = a, .graph = graph, .query = query, .relations = .{ .array = std.json.Array.init(a) }, .joins = .{ .array = std.json.Array.init(a) } };
    var selected: std.ArrayList(Output) = .empty;
    for (query.metrics) |name| {
        const metric = sem.find(graph, "metric", name) orelse return error.MissingMetric;
        for (selected.items) |prior| if (eq(prior.name, metric.name)) return error.DuplicateMetricQuery;
        try selected.append(a, .{ .name = metric.name, .cte = try ctx.compileMetric(metric, &.{}, 0) });
    }
    const combined = try ctx.combineOutputs(selected.items, null, null);
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll("WITH\n");
    for (ctx.ctes.items, 0..) |cte, i| {
        if (i != 0) try w.writeAll(",\n");
        try w.print("{s} AS (\n{s}\n)", .{ cte.name, cte.sql });
    }
    try w.print("\nSELECT * FROM {s}", .{combined});
    if (query.order_by.len != 0) {
        try w.writeAll(" ORDER BY ");
        for (query.order_by, 0..) |order, i| {
            if (i != 0) try w.writeByte(',');
            const descending = std.mem.startsWith(u8, order, "-");
            const name = if (descending) order[1..] else order;
            var known = false;
            for (query.group_by) |group| if (eq(group, name)) {
                known = true;
            };
            for (selected.items) |metric| if (eq(metric.name, name)) {
                known = true;
            };
            if (!known) return error.InvalidMetricOrderBy;
            try w.print("{s}{s}", .{ try ident(a, name), if (descending) " DESC" else " ASC" });
        }
    }
    if (query.limit) |limit| try w.print(" LIMIT {d}", .{limit});
    const sql = try out.toOwnedSlice();
    var logical: Value = .{ .object = .empty };
    try values.put(a, &logical, "version", .{ .integer = 1 });
    try values.put(a, &logical, "strategy", .{ .string = "single_engine_pushdown" });
    try values.put(a, &logical, "adapter_type", .{ .string = graph.adapter_type });
    try values.put(a, &logical, "sql", .{ .string = sql });
    try values.put(a, &logical, "metrics", try stringArray(a, query.metrics));
    try values.put(a, &logical, "group_by", try stringArray(a, query.group_by));
    try values.put(a, &logical, "relations", ctx.relations);
    try values.put(a, &logical, "joins", ctx.joins);
    try ctx.finalizeBindings();
    try values.put(a, &logical, "bindings", try std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, ctx.bindings.items, .{}), .{}));
    try values.put(a, &logical, "movement", .{ .array = std.json.Array.init(a) });
    const owned_logical = try values.clone(a, logical);
    return .{ .arena = arena, .sql = sql, .logical = owned_logical, .bindings = ctx.bindings.items };
}
fn stringArray(a: std.mem.Allocator, items: []const []const u8) !Value {
    var result: Value = .{ .array = std.json.Array.init(a) };
    for (items) |item| try result.array.append(.{ .string = item });
    return result;
}
fn names(a: std.mem.Allocator, items: Value, builders: bool) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    for (list(items)) |item| {
        const name = sem.string(item) orelse return error.InvalidMetricQuery;
        try result.append(a, if (builders) try builderName(a, name) else name);
    }
    return result.items;
}
fn builderName(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '(') == null) return name;
    var host = NameHost{};
    var base = name;
    var descending = false;
    if (std.mem.indexOf(u8, name, ".descending(")) |at| {
        base = name[0..at];
        const args_start = at + ".descending(".len;
        if (!std.mem.endsWith(u8, name, ")")) return error.InvalidMetricQuery;
        var argument = std.mem.trim(u8, name[args_start .. name.len - 1], " \t\r\n");
        if (std.mem.startsWith(u8, argument, "descending=")) argument = std.mem.trim(u8, argument["descending=".len..], " \t\r\n");
        if (argument.len == 0) descending = true else {
            const flag = try expression.evaluate(a, argument, .{ .context = &host, .resolve = NameHost.resolve, .call = NameHost.call });
            if (flag != .boolean) return error.InvalidMetricQuery;
            descending = flag.boolean;
        }
    }
    const result = try expression.evaluate(a, base, .{ .context = &host, .resolve = NameHost.resolve, .call = NameHost.call });
    if (result != .string) return error.InvalidMetricQuery;
    return if (descending) std.fmt.allocPrint(a, "-{s}", .{result.string}) else result.string;
}
const NameHost = struct {
    fn resolve(_: *anyopaque, _: []const u8, _: std.mem.Allocator) anyerror!expression.Value {
        return .undefined;
    }
    fn call(_: *anyopaque, name: []const u8, args: []const expression.Argument, a: std.mem.Allocator) anyerror!expression.Value {
        if (args.len == 0 or args[0].value != .string) return error.InvalidMetricQuery;
        if (eq(name, "TimeDimension")) {
            if (args.len != 2 or args[1].value != .string or !sem.grainValid(args[1].value.string)) return error.InvalidMetricGrain;
            return .{ .string = try std.fmt.allocPrint(a, "{s}__{s}", .{ args[0].value.string, args[1].value.string }) };
        }
        if (!eq(name, "Dimension") and !eq(name, "Entity") and !eq(name, "Metric")) return error.InvalidMetricQuery;
        return args[0].value;
    }
};

const Output = struct { name: []const u8, cte: []const u8 };
const Cte = struct { name: []const u8, sql: []const u8 };
const Context = struct {
    allocator: std.mem.Allocator,
    graph: *const Graph,
    query: Query,
    ctes: std.ArrayList(Cte) = .empty,
    relations: Value,
    joins: Value,
    time_windows: std.ArrayList(Value) = .empty,
    time_to_grains: std.ArrayList([]const u8) = .empty,
    bindings: std.ArrayList(RelationBinding) = .empty,
    columns: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty,

    fn add(self: *Context, sql: []const u8) ![]const u8 {
        const name = try std.fmt.allocPrint(self.allocator, "metric_{d}", .{self.ctes.items.len});
        try self.ctes.append(self.allocator, .{ .name = name, .sql = sql });
        return name;
    }
    fn registerRelation(self: *Context, logical_id: []const u8, relation: Value, meta: Value) ![]const u8 {
        const a = self.allocator;
        const name = text(relation, "relation_name") orelse return error.MissingSemanticModelTarget;
        const connection = text(meta, "connection");
        if (connection == null and !eq(text(relation, "database") orelse sem.databaseForGraph(self.graph), sem.databaseForGraph(self.graph))) return error.MissingMetricConnection;
        for (self.bindings.items) |binding| if (eq(binding.relation_name, name)) {
            if (!optionalEq(binding.connection, connection)) return error.AmbiguousMetricRelation;
            return binding.relation_name;
        };
        const source = field(meta, "source");
        var source_name: []const u8 = undefined;
        if (source != .null) {
            const parts = list(source);
            if (parts.len != 2) return error.InvalidMetricSource;
            source_name = try std.fmt.allocPrint(a, "{s}.{s}", .{ try ident(a, sem.string(parts[0]) orelse return error.InvalidMetricSource), try ident(a, sem.string(parts[1]) orelse return error.InvalidMetricSource) });
        } else source_name = try std.fmt.allocPrint(a, "{s}.{s}", .{ try ident(a, text(relation, "schema_name") orelse return error.MissingSemanticModelTarget), try ident(a, text(relation, "alias") orelse return error.MissingSemanticModelTarget) });
        try self.bindings.append(a, .{
            .logical_id = try a.dupe(u8, logical_id),
            .relation_name = try a.dupe(u8, name),
            .connection = if (connection) |value| try a.dupe(u8, value) else null,
            .source_relation = source_name,
            .source_query = if (text(meta, "source_query")) |value| try a.dupe(u8, value) else null,
            .sensitivity = try a.dupe(u8, text(meta, "sensitivity") orelse "public"),
            .estimated_rows = try estimate(field(meta, "estimated_rows")),
            .estimated_bytes = try estimate(field(meta, "estimated_bytes")),
            .mapped = connection != null or source != .null or field(meta, "source_query") != .null,
        });
        try self.relations.array.append(.{ .string = name });
        return self.bindings.items[self.bindings.items.len - 1].relation_name;
    }
    fn relationFor(self: *Context, model: *const Resource) ![]const u8 {
        const dependencies = list(field(field(model.data, "depends_on"), "nodes"));
        if (dependencies.len != 1) return error.MissingSemanticModelTarget;
        return self.registerRelation(sem.string(dependencies[0]).?, field(model.data, "node_relation"), field(field(model.data, "config"), "meta"));
    }
    fn trackColumn(self: *Context, relation: []const u8, column: []const u8) !void {
        const entry = try self.columns.getOrPut(self.allocator, relation);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        for (entry.value_ptr.items) |prior| if (eq(prior, column)) return;
        try entry.value_ptr.append(self.allocator, try self.allocator.dupe(u8, column));
    }
    fn qualifyFor(self: *Context, model: *const Resource, alias: []const u8, raw: []const u8) ![]const u8 {
        const a = self.allocator;
        const sql = try qualify(a, alias, raw);
        const relation = text(field(model.data, "node_relation"), "relation_name") orelse return error.MissingSemanticModelTarget;
        const prefix = try std.fmt.allocPrint(a, "{s}.\"", .{alias});
        var at: usize = 0;
        while (at < sql.len) {
            if (sql[at] == '\'') {
                at += 1;
                while (at < sql.len) : (at += 1) if (sql[at] == '\'') {
                    at += 1;
                    if (at < sql.len and sql[at] == '\'') continue;
                    break;
                };
                continue;
            }
            if (std.mem.startsWith(u8, sql[at..], prefix)) {
                at += prefix.len;
                var column: std.Io.Writer.Allocating = .init(a);
                while (at < sql.len) : (at += 1) {
                    if (sql[at] == '"') {
                        at += 1;
                        if (at >= sql.len or sql[at] != '"') break;
                    }
                    try column.writer.writeByte(sql[at]);
                }
                try self.trackColumn(relation, column.written());
            } else at += 1;
        }
        return sql;
    }
    fn finalizeBindings(self: *Context) !void {
        const a = self.allocator;
        for (self.bindings.items) |*binding| {
            if (binding.source_query != null) continue;
            var projection: std.Io.Writer.Allocating = .init(a);
            try projection.writer.writeAll("SELECT ");
            const columns = if (self.columns.get(binding.relation_name)) |items| items.items else &.{};
            if (columns.len == 0) try projection.writer.writeAll("1 AS __dxt_row") else for (columns, 0..) |column, i| {
                if (i != 0) try projection.writer.writeByte(',');
                try projection.writer.writeAll(try ident(a, column));
            }
            try projection.writer.print(" FROM {s}", .{binding.source_relation});
            binding.source_query = try projection.toOwnedSlice();
        }
    }
    fn compileMetric(self: *Context, resource: *const Resource, extra: []const Value, depth: usize) anyerror![]const u8 {
        if (depth > self.graph.semantic_resources.items.len) return error.CyclicMetricDependency;
        const a = self.allocator;
        const kind = text(resource.data, "type") orelse return error.InvalidMetricQuery;
        const params = field(resource.data, "type_params");
        if (eq(kind, "simple") or eq(kind, "cumulative")) return self.compileMeasure(resource, field(params, "measure"), extra, eq(kind, "cumulative"));
        if (eq(kind, "conversion")) return self.conversion(resource, extra);
        var inputs: std.ArrayList(Value) = .empty;
        if (eq(kind, "ratio")) {
            try inputs.append(a, field(params, "numerator"));
            try inputs.append(a, field(params, "denominator"));
        } else try inputs.appendSlice(a, list(field(params, "metrics")));
        var outputs: std.ArrayList(Output) = .empty;
        for (inputs.items) |input_metric| {
            const name = text(input_metric, "name") orelse return error.InvalidMetricQuery;
            const target = sem.find(self.graph, "metric", name) orelse return error.MissingMetric;
            var filters: std.ArrayList(Value) = .empty;
            try filters.appendSlice(a, extra);
            try filters.append(a, field(resource.data, "filter"));
            try filters.append(a, field(input_metric, "filter"));
            const offset = field(input_metric, "offset_window");
            const offset_grain = text(input_metric, "offset_to_grain");
            if (offset != .null) try self.time_windows.append(a, offset);
            if (offset_grain) |grain| try self.time_to_grains.append(a, grain);
            var cte = try self.compileMetric(target, filters.items, depth + 1);
            if (offset != .null) _ = self.time_windows.pop();
            if (offset_grain != null) _ = self.time_to_grains.pop();
            if (offset != .null or offset_grain != null) cte = try self.offsetMetric(cte, target.name, offset, offset_grain);
            try outputs.append(a, .{ .name = target.name, .cte = cte });
        }
        var expr: []const u8 = undefined;
        if (eq(kind, "ratio")) {
            expr = try std.fmt.allocPrint(a, "CAST(i0.{s} AS DOUBLE PRECISION) / NULLIF(i1.{s}, 0)", .{ try ident(a, outputs.items[0].name), try ident(a, outputs.items[1].name) });
        } else {
            const raw = text(params, "expr") orelse return error.InvalidMetricQuery;
            var out: std.Io.Writer.Allocating = .init(a);
            var cursor: usize = 0;
            while (cursor < raw.len) {
                if (std.ascii.isAlphabetic(raw[cursor]) or raw[cursor] == '_') {
                    const start = cursor;
                    while (cursor < raw.len and (std.ascii.isAlphanumeric(raw[cursor]) or raw[cursor] == '_')) cursor += 1;
                    const token = raw[start..cursor];
                    var found = false;
                    for (inputs.items, 0..) |item, i| {
                        const name = text(item, "alias") orelse outputs.items[i].name;
                        if (eq(name, token)) {
                            try out.writer.print("i{d}.{s}", .{ i, try ident(a, outputs.items[i].name) });
                            found = true;
                            break;
                        }
                    }
                    if (!found) try out.writer.writeAll(token);
                } else {
                    try out.writer.writeByte(raw[cursor]);
                    cursor += 1;
                }
            }
            expr = try out.toOwnedSlice();
        }
        return self.combineOutputs(outputs.items, resource.name, expr);
    }
    fn combineOutputs(self: *Context, outputs: []const Output, metric_name: ?[]const u8, expr: ?[]const u8) ![]const u8 {
        const a = self.allocator;
        // A union of group keys preserves null groups and supports PostgreSQL,
        // which cannot hash/merge a FULL JOIN with IS NOT DISTINCT FROM.
        var keys: ?[]const u8 = null;
        if (self.query.group_by.len != 0) {
            var axis: std.Io.Writer.Allocating = .init(a);
            for (outputs, 0..) |output, i| {
                if (i != 0) try axis.writer.writeAll(" UNION ");
                try axis.writer.writeAll("SELECT ");
                for (self.query.group_by, 0..) |group, g| {
                    if (g != 0) try axis.writer.writeByte(',');
                    try axis.writer.writeAll(try ident(a, group));
                }
                try axis.writer.print(" FROM {s}", .{output.cte});
            }
            keys = try self.add(try axis.toOwnedSlice());
        }
        var out: std.Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        try w.writeAll("SELECT ");
        for (self.query.group_by) |group| try w.print("k.{s} AS {s},", .{ try ident(a, group), try ident(a, group) });
        if (metric_name) |name| try w.print("({s}) AS {s}", .{ expr.?, try ident(a, name) }) else for (outputs, 0..) |output, i| {
            if (i != 0) try w.writeByte(',');
            try w.print("i{d}.{s} AS {s}", .{ i, try ident(a, output.name), try ident(a, output.name) });
        }
        if (keys) |axis| {
            try w.print(" FROM {s} k", .{axis});
            for (outputs, 0..) |output, i| {
                try w.print(" LEFT JOIN {s} i{d} ON ", .{ output.cte, i });
                for (self.query.group_by, 0..) |group, g| {
                    if (g != 0) try w.writeAll(" AND ");
                    try w.print("k.{s} IS NOT DISTINCT FROM i{d}.{s}", .{ try ident(a, group), i, try ident(a, group) });
                }
            }
        } else {
            try w.print(" FROM {s} i0", .{outputs[0].cte});
            for (outputs[1..], 1..) |output, i| try w.print(" CROSS JOIN {s} i{d}", .{ output.cte, i });
        }
        return self.add(try out.toOwnedSlice());
    }
    fn boundSql(self: *Context, raw: []const u8, end: bool) ![]const u8 {
        const a = self.allocator;
        var grain: []const u8 = "day";
        for (self.query.group_by) |group| if (std.mem.startsWith(u8, group, "metric_time__")) {
            grain = group["metric_time__".len..];
            break;
        };
        var sql = try std.fmt.allocPrint(a, "DATE_TRUNC('{s}',CAST({s} AS TIMESTAMP))", .{ grain, try sqlText(a, raw) });
        if (end) sql = try std.fmt.allocPrint(a, "({s} + INTERVAL '{s}')", .{ sql, if (eq(grain, "quarter")) "3 month" else try std.fmt.allocPrint(a, "1 {s}", .{grain}) });
        for (self.time_windows.items) |window| {
            const count = field(window, "count");
            const unit = text(window, "granularity") orelse return error.InvalidMetricWindow;
            if (count != .integer or !sem.grainValid(unit)) return error.InvalidMetricWindow;
            sql = try std.fmt.allocPrint(a, "({s} - INTERVAL '{d} {s}')", .{ sql, count.integer * @as(i64, if (eq(unit, "quarter")) 3 else 1), if (eq(unit, "quarter")) "month" else unit });
        }
        if (!end) for (self.time_to_grains.items) |unit| {
            if (!sem.grainValid(unit)) return error.InvalidMetricGrain;
            sql = try std.fmt.allocPrint(a, "DATE_TRUNC('{s}',{s})", .{ unit, sql });
        };
        return sql;
    }
    fn inclusiveEnd(self: *Context, raw: []const u8) ![]const u8 {
        const a = self.allocator;
        var grain: []const u8 = "day";
        for (self.query.group_by) |group| if (std.mem.startsWith(u8, group, "metric_time__")) {
            grain = group["metric_time__".len..];
            break;
        };
        const last = try std.fmt.allocPrint(a, "({s} - INTERVAL '1 microsecond')", .{try self.boundSql(raw, true)});
        return if (grainRank(grain) >= grainRank("day")) std.fmt.allocPrint(a, "CAST({s} AS DATE)", .{last}) else last;
    }
    fn offsetMetric(self: *Context, cte: []const u8, metric_name: []const u8, window: Value, to_grain: ?[]const u8) ![]const u8 {
        if (window == .null) return self.offsetToGrain(cte, metric_name, to_grain orelse return error.InvalidMetricGrain);
        const a = self.allocator;
        var out: std.Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        try w.writeAll("SELECT ");
        var time_found = false;
        for (self.query.group_by) |group| {
            if (std.mem.startsWith(u8, group, "metric_time__")) {
                time_found = true;
                if (window != .null) {
                    const count = field(window, "count");
                    const grain = text(window, "granularity") orelse return error.InvalidMetricWindow;
                    if (count != .integer or !sem.grainValid(grain)) return error.InvalidMetricWindow;
                    try w.print("{s}{s} + INTERVAL '{d} {s}'{s} AS {s},", .{ if (grainRank(group["metric_time__".len..]) >= grainRank("day")) "CAST(" else "", try ident(a, group), count.integer * @as(i64, if (eq(grain, "quarter")) 3 else 1), if (eq(grain, "quarter")) "month" else grain, if (grainRank(group["metric_time__".len..]) >= grainRank("day")) " AS DATE)" else "", try ident(a, group) });
                } else {
                    const grain = to_grain orelse return error.InvalidMetricGrain;
                    if (!sem.grainValid(grain)) return error.InvalidMetricGrain;
                    try w.print("DATE_TRUNC('{s}',{s}) AS {s},", .{ grain, try ident(a, group), try ident(a, group) });
                }
            } else try w.print("{s},", .{try ident(a, group)});
        }
        if (!time_found) return error.MissingMetricTimeGroup;
        try w.print("{s} FROM {s}", .{ try ident(a, metric_name), cte });
        const shifted = try self.add(try out.toOwnedSlice());
        var filters: std.ArrayList([]const u8) = .empty;
        for (self.query.group_by) |group| if (std.mem.startsWith(u8, group, "metric_time__")) {
            if (self.query.start_time) |start| try filters.append(a, try std.fmt.allocPrint(a, "{s}>={s}", .{ try ident(a, group), try self.boundSql(start, false) }));
            if (self.query.end_time) |end| try filters.append(a, try std.fmt.allocPrint(a, "{s}<{s}", .{ try ident(a, group), try self.boundSql(end, true) }));
        };
        if (filters.items.len == 0) return shifted;
        var bounded: std.Io.Writer.Allocating = .init(a);
        try bounded.writer.print("SELECT * FROM {s}", .{shifted});
        try writePredicates(&bounded.writer, filters.items);
        return self.add(try bounded.toOwnedSlice());
    }
    fn offsetToGrain(self: *Context, cte: []const u8, metric_name: []const u8, grain: []const u8) ![]const u8 {
        if (!sem.grainValid(grain)) return error.InvalidMetricGrain;
        const a = self.allocator;
        var time_group: ?[]const u8 = null;
        for (self.query.group_by) |group| if (std.mem.startsWith(u8, group, "metric_time__")) {
            time_group = group;
            break;
        };
        const time_name = time_group orelse return error.MissingMetricTimeGroup;
        const query_grain = time_name["metric_time__".len..];
        const spine = try self.timeSpine();
        var out: std.Io.Writer.Allocating = .init(a);
        try out.writer.writeAll("SELECT ");
        for (self.query.group_by) |group| if (eq(group, time_name)) {
            try out.writer.print("sp.t AS {s},", .{try ident(a, group)});
        } else try out.writer.print("b.{s},", .{try ident(a, group)});
        try out.writer.print("b.{s} FROM (SELECT DISTINCT DATE_TRUNC('{s}',{s}) AS t FROM {s}) sp INNER JOIN {s} b ON b.{s}=DATE_TRUNC('{s}',sp.t)", .{ try ident(a, metric_name), query_grain, try ident(a, spine.column), spine.relation, cte, try ident(a, time_name), grain });
        var filters: std.ArrayList([]const u8) = .empty;
        if (self.query.start_time) |start| try filters.append(a, try std.fmt.allocPrint(a, "sp.t>={s}", .{try self.boundSql(start, false)}));
        if (self.query.end_time) |end| try filters.append(a, try std.fmt.allocPrint(a, "sp.t<{s}", .{try self.boundSql(end, true)}));
        try writePredicates(&out.writer, filters.items);
        return self.add(try out.toOwnedSlice());
    }
    fn compileMeasure(self: *Context, metric_resource: *const Resource, measure_input: Value, extra: []const Value, cumulative: bool) ![]const u8 {
        const a = self.allocator;
        if (cumulative) {
            const params = field(field(metric_resource.data, "type_params"), "cumulative_type_params");
            var time_group = false;
            for (self.query.group_by) |group| if (std.mem.startsWith(u8, group, "metric_time__")) {
                time_group = true;
            };
            if (!time_group and field(params, "window") == .null and field(params, "grain_to_date") == .null) return self.compileMeasure(metric_resource, measure_input, extra, false);
        }
        const name = text(measure_input, "name") orelse return error.InvalidMetricQuery;
        var model: ?*const Resource = null;
        var measure: Value = .null;
        for (self.graph.semantic_resources.items) |*candidate| {
            if (!candidate.enabled or !eq(candidate.resource_type, "semantic_model")) continue;
            for (list(field(candidate.data, "measures"))) |entry| if (eq(text(entry, "name").?, name)) {
                model = candidate;
                measure = entry;
            };
        }
        const source_model = model orelse return error.MissingSemanticMeasure;
        var source = Source{ .context = self, .model = source_model, .measure = measure };
        var groups: std.ArrayList([]const u8) = .empty;
        var metric_time_index: ?usize = null;
        for (self.query.group_by, 0..) |group, i| {
            if (std.mem.startsWith(u8, group, "metric_time__")) metric_time_index = i;
            try groups.append(a, try source.resolveDimension(group));
        }
        var predicates: std.ArrayList([]const u8) = .empty;
        for (self.query.where) |filter| try predicates.append(a, try source.filter(filter));
        try source.filters(&predicates, field(metric_resource.data, "filter"));
        try source.filters(&predicates, field(measure_input, "filter"));
        for (extra) |filter| try source.filters(&predicates, filter);
        var cumulative_join: ?[]const u8 = null;
        var cumulative_period: ?[]const u8 = null;
        if (cumulative) {
            const time_index = metric_time_index orelse return error.MissingMetricTimeGroup;
            const grain = self.query.group_by[time_index]["metric_time__".len..];
            const params = field(field(metric_resource.data, "type_params"), "cumulative_type_params");
            const spine = try self.timeSpine();
            const metric_time = try source.resolveDimension(try std.fmt.allocPrint(a, "metric_time__{s}", .{try source.minimumTimeGrain()}));
            groups.items[time_index] = try std.fmt.allocPrint(a, "sp.{s}", .{try ident(a, spine.column)});
            if (grainRank(grain) > grainRank("day")) cumulative_period = text(params, "period_agg") orelse "first";
            var join: std.Io.Writer.Allocating = .init(a);
            try join.writer.print(" INNER JOIN {s} sp ON {s} <= sp.{s}", .{ spine.relation, metric_time, try ident(a, spine.column) });
            const window = field(params, "window");
            if (window != .null) {
                const count = field(window, "count");
                const granularity = text(window, "granularity") orelse return error.InvalidMetricWindow;
                if (count != .integer or count.integer < 0 or !sem.grainValid(granularity)) return error.InvalidMetricWindow;
                try join.writer.print(" AND {s} > sp.{s} - INTERVAL '{d} {s}'", .{ metric_time, try ident(a, spine.column), count.integer * @as(i64, if (eq(granularity, "quarter")) 3 else 1), if (eq(granularity, "quarter")) "month" else granularity });
            } else if (text(params, "grain_to_date")) |granularity| {
                if (!sem.grainValid(granularity)) return error.InvalidMetricGrain;
                try join.writer.print(" AND {s} >= DATE_TRUNC('{s}',sp.{s})", .{ metric_time, granularity, try ident(a, spine.column) });
            }
            cumulative_join = try join.toOwnedSlice();
        }
        const time_expr = if (cumulative) groups.items[metric_time_index.?] else if (self.query.start_time != null or self.query.end_time != null) try source.resolveDimension(try std.fmt.allocPrint(a, "metric_time__{s}", .{try source.minimumTimeGrain()})) else "";
        if (self.query.start_time) |start| try predicates.append(a, try std.fmt.allocPrint(a, "{s} >= {s}", .{ time_expr, try self.boundSql(start, false) }));
        if (self.query.end_time) |end| try predicates.append(a, try std.fmt.allocPrint(a, "{s} <= {s}", .{ time_expr, try self.inclusiveEnd(end) }));
        const measure_expr = try self.qualifyFor(source_model, "s", text(measure, "expr") orelse name);
        const aggregate = try aggregation(a, self.graph.adapter_type, measure, measure_expr);
        var out: std.Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        try w.writeAll("SELECT ");
        for (groups.items, self.query.group_by) |group, alias| try w.print("{s} AS {s},", .{ group, try ident(a, alias) });
        if (field(measure_input, "fill_nulls_with") != .null) {
            const literal = try std.json.Stringify.valueAlloc(a, field(measure_input, "fill_nulls_with"), .{});
            try w.print("COALESCE({s},{s}) AS {s}", .{ aggregate, literal, try ident(a, metric_resource.name) });
        } else try w.print("{s} AS {s}", .{ aggregate, try ident(a, metric_resource.name) });
        try w.print(" FROM {s} s{s}", .{ try self.relationFor(source_model), source.joins.items });
        if (cumulative_join) |join| try w.writeAll(join);
        try writePredicates(w, predicates.items);
        if (groups.items.len != 0) {
            try w.writeAll(" GROUP BY ");
            for (groups.items, 0..) |group, i| {
                if (i != 0) try w.writeByte(',');
                try w.writeAll(group);
            }
        }
        const base = if (field(measure, "non_additive_dimension") != .null) try self.nonAdditive(&source, metric_resource.name, measure_input, groups.items, predicates.items, cumulative_join, measure_expr) else try self.add(try out.toOwnedSlice());
        if (cumulative_period) |period| return self.reaggregateCumulative(base, metric_resource.name, metric_time_index.?, period);
        const join_spine = field(measure_input, "join_to_timespine");
        if (join_spine == .bool and join_spine.bool and !cumulative) return self.fillTimeSpine(base, metric_resource.name, measure_input, metric_time_index orelse return error.MissingMetricTimeGroup);
        return base;
    }
    fn nonAdditive(self: *Context, source: *Source, metric_name: []const u8, input: Value, groups: []const []const u8, predicates: []const []const u8, cumulative_join: ?[]const u8, measure_expr: []const u8) ![]const u8 {
        const a = self.allocator;
        const params = field(source.measure, "non_additive_dimension");
        const nonadd_time = try source.resolveDimension(text(params, "name") orelse return error.InvalidMetricQuery);
        const choice = text(params, "window_choice") orelse return error.InvalidMetricQuery;
        if (!eq(choice, "min") and !eq(choice, "max")) return error.InvalidMetricQuery;
        var partitions: std.ArrayList([]const u8) = .empty;
        for (self.query.group_by, groups) |name, sql| if (std.mem.startsWith(u8, name, "metric_time__")) try partitions.append(a, sql);
        var windows: std.ArrayList([]const u8) = .empty;
        for (list(field(params, "window_groupings"))) |group| {
            const sql = try source.resolveDimension(sem.string(group) orelse return error.InvalidMetricQuery);
            try windows.append(a, sql);
            try partitions.append(a, sql);
        }
        var rows: std.Io.Writer.Allocating = .init(a);
        const w = &rows.writer;
        try w.writeAll("SELECT ");
        for (groups, 0..) |group, i| try w.print("{s} AS __dxt_group_{d},", .{ group, i });
        for (windows.items, 0..) |window, i| try w.print("{s} AS __dxt_window_{d},", .{ window, i });
        try w.print("{s} AS __dxt_value,{s} AS __dxt_nonadd,{s}({s}) OVER (", .{ measure_expr, nonadd_time, choice, nonadd_time });
        if (partitions.items.len != 0) {
            try w.writeAll("PARTITION BY ");
            for (partitions.items, 0..) |partition, i| {
                if (i != 0) try w.writeByte(',');
                try w.writeAll(partition);
            }
        }
        try w.print(") AS __dxt_chosen FROM {s} s{s}", .{ try self.relationFor(source.model), source.joins.items });
        if (cumulative_join) |join| try w.writeAll(join);
        try writePredicates(w, predicates);
        const selected = try self.add(try rows.toOwnedSlice());
        var out: std.Io.Writer.Allocating = .init(a);
        try out.writer.writeAll("SELECT ");
        for (self.query.group_by, 0..) |name, i| try out.writer.print("__dxt_group_{d} AS {s},", .{ i, try ident(a, name) });
        const aggregate = try aggregation(a, self.graph.adapter_type, source.measure, "__dxt_value");
        const fill = field(input, "fill_nulls_with");
        if (fill != .null) try out.writer.print("COALESCE({s},{s}) AS {s}", .{ aggregate, try std.json.Stringify.valueAlloc(a, fill, .{}), try ident(a, metric_name) }) else try out.writer.print("{s} AS {s}", .{ aggregate, try ident(a, metric_name) });
        try out.writer.print(" FROM {s} WHERE __dxt_nonadd=__dxt_chosen", .{selected});
        // Core joins selector grouping keys with ordinary equality; null entity
        // keys do not match a selector group and must not contribute balances.
        for (windows.items, 0..) |_, i| try out.writer.print(" AND __dxt_window_{d} IS NOT NULL", .{i});
        if (groups.len != 0) {
            try out.writer.writeAll(" GROUP BY ");
            for (groups, 0..) |_, i| {
                if (i != 0) try out.writer.writeByte(',');
                try out.writer.print("__dxt_group_{d}", .{i});
            }
        }
        return self.add(try out.toOwnedSlice());
    }
    fn reaggregateCumulative(self: *Context, base: []const u8, metric_name: []const u8, time_index: usize, period: []const u8) ![]const u8 {
        const a = self.allocator;
        if (!eq(period, "first") and !eq(period, "last") and !eq(period, "average")) return error.InvalidMetricQuery;
        const time_name = self.query.group_by[time_index];
        const grain = time_name["metric_time__".len..];
        var projected: std.Io.Writer.Allocating = .init(a);
        var partitions: std.Io.Writer.Allocating = .init(a);
        for (self.query.group_by, 0..) |group, i| {
            const group_sql = if (i == time_index) try std.fmt.allocPrint(a, "DATE_TRUNC('{s}',{s})", .{ grain, try ident(a, group) }) else try ident(a, group);
            if (i != 0) try partitions.writer.writeByte(',');
            try partitions.writer.writeAll(group_sql);
            try projected.writer.print("{s} AS {s},", .{ group_sql, try ident(a, group) });
        }
        var out: std.Io.Writer.Allocating = .init(a);
        if (eq(period, "average")) {
            try out.writer.print("SELECT {s}AVG({s}) AS {s} FROM {s} GROUP BY {s}", .{ projected.written(), try ident(a, metric_name), try ident(a, metric_name), base, partitions.written() });
            return self.add(try out.toOwnedSlice());
        }
        try out.writer.print("SELECT {s}{s},ROW_NUMBER() OVER (PARTITION BY {s} ORDER BY {s} {s}) AS __dxt_period_rank FROM {s}", .{ projected.written(), try ident(a, metric_name), partitions.written(), try ident(a, time_name), if (eq(period, "last")) "DESC" else "ASC", base });
        const ranked = try self.add(try out.toOwnedSlice());
        var selected: std.Io.Writer.Allocating = .init(a);
        try selected.writer.writeAll("SELECT ");
        for (self.query.group_by) |group| try selected.writer.print("{s},", .{try ident(a, group)});
        try selected.writer.print("{s} FROM {s} WHERE __dxt_period_rank=1", .{ try ident(a, metric_name), ranked });
        return self.add(try selected.toOwnedSlice());
    }
    fn timeSpine(self: *Context) !struct { relation: []const u8, column: []const u8 } {
        const a = self.allocator;
        for (self.graph.semantic_time_spines.items) |spine_raw| {
            for (self.graph.nodes.items) |*node| if (node.enabled and eq(node.name, text(spine_raw.raw, "name").?) and eq(node.package_name, spine_raw.package_name)) {
                const relation = try sem.nodeRelation(a, self.graph, node);
                const physical = try self.registerRelation(node.unique_id, relation, field(node.effective_config, "meta"));
                const column = text(field(spine_raw.raw, "time_spine"), "standard_granularity_column").?;
                try self.trackColumn(physical, column);
                return .{ .relation = physical, .column = column };
            };
        }
        for (self.graph.nodes.items) |*node| if (node.enabled and eq(node.name, "metricflow_time_spine")) {
            const relation = try sem.nodeRelation(a, self.graph, node);
            const physical = try self.registerRelation(node.unique_id, relation, field(node.effective_config, "meta"));
            try self.trackColumn(physical, "date_day");
            return .{ .relation = physical, .column = "date_day" };
        };
        return error.MissingSemanticTimeSpine;
    }
    fn fillTimeSpine(self: *Context, base: []const u8, metric_name: []const u8, input: Value, time_index: usize) ![]const u8 {
        const a = self.allocator;
        const spine = try self.timeSpine();
        const group = self.query.group_by[time_index];
        const grain = group["metric_time__".len..];
        var out: std.Io.Writer.Allocating = .init(a);
        const w = &out.writer;
        try w.writeAll("SELECT ");
        for (self.query.group_by, 0..) |dimension, i| {
            if (i == time_index) try w.print("sp.t AS {s},", .{try ident(a, dimension)}) else try w.print("d.{s},", .{try ident(a, dimension)});
        }
        const fill = field(input, "fill_nulls_with");
        if (fill != .null) try w.print("COALESCE(b.{s},{s}) AS {s}", .{ try ident(a, metric_name), try std.json.Stringify.valueAlloc(a, fill, .{}), try ident(a, metric_name) }) else try w.print("b.{s}", .{try ident(a, metric_name)});
        try w.print(" FROM (SELECT DISTINCT DATE_TRUNC('{s}',{s}) AS t FROM {s}) sp", .{ grain, try ident(a, spine.column), spine.relation });
        if (self.query.group_by.len > 1) {
            try w.writeAll(" CROSS JOIN (SELECT DISTINCT ");
            var first = true;
            for (self.query.group_by, 0..) |dimension, i| {
                if (i == time_index) continue;
                if (!first) try w.writeByte(',');
                first = false;
                try w.writeAll(try ident(a, dimension));
            }
            try w.print(" FROM {s}) d", .{base});
        }
        try w.print(" LEFT JOIN {s} b ON b.{s}=sp.t", .{ base, try ident(a, group) });
        for (self.query.group_by, 0..) |dimension, i| if (i != time_index) try w.print(" AND b.{s} IS NOT DISTINCT FROM d.{s}", .{ try ident(a, dimension), try ident(a, dimension) });
        var predicates: std.ArrayList([]const u8) = .empty;
        if (self.query.start_time) |start| try predicates.append(a, try std.fmt.allocPrint(a, "sp.t>={s}", .{try self.boundSql(start, false)}));
        if (self.query.end_time) |end| try predicates.append(a, try std.fmt.allocPrint(a, "sp.t<{s}", .{try self.boundSql(end, true)}));
        try writePredicates(w, predicates.items);
        return self.add(try out.toOwnedSlice());
    }
    fn conversion(self: *Context, resource: *const Resource, extra: []const Value) ![]const u8 {
        const a = self.allocator;
        const params = field(field(resource.data, "type_params"), "conversion_type_params");
        const base_input = field(params, "base_measure");
        const conversion_input = field(params, "conversion_measure");
        const base = try findMeasure(self.graph, text(base_input, "name") orelse return error.InvalidMetricQuery);
        const converted = try findMeasure(self.graph, text(conversion_input, "name") orelse return error.InvalidMetricQuery);
        const entity_name = text(params, "entity") orelse return error.InvalidMetricQuery;
        var base_source = Source{ .context = self, .model = base.model, .measure = base.measure };
        var converted_source = Source{ .context = self, .model = converted.model, .measure = converted.measure };
        var base_groups: std.ArrayList([]const u8) = .empty;
        for (self.query.group_by) |group| try base_groups.append(a, try base_source.resolveDimension(group));
        const base_entity = try base_source.resolveDimension(entity_name);
        const converted_entity = try converted_source.resolveDimension(entity_name);
        const base_time = try base_source.time();
        const converted_time = try converted_source.time();
        var base_filters: std.ArrayList([]const u8) = .empty;
        for (self.query.where) |filter| try base_filters.append(a, try base_source.filter(filter));
        try base_source.filters(&base_filters, field(resource.data, "filter"));
        try base_source.filters(&base_filters, field(base_input, "filter"));
        for (extra) |filter| try base_source.filters(&base_filters, filter);
        if (self.query.start_time) |start| try base_filters.append(a, try std.fmt.allocPrint(a, "{s}>={s}", .{ base_time, try self.boundSql(start, false) }));
        if (self.query.end_time) |end| try base_filters.append(a, try std.fmt.allocPrint(a, "{s}<{s}", .{ base_time, try self.boundSql(end, true) }));
        var conversion_filters: std.ArrayList([]const u8) = .empty;
        try converted_source.filters(&conversion_filters, field(conversion_input, "filter"));
        var base_sql: std.Io.Writer.Allocating = .init(a);
        var conv_sql: std.Io.Writer.Allocating = .init(a);
        try base_sql.writer.print("SELECT {s} AS event_entity,{s} AS event_time", .{ base_entity, base_time });
        try conv_sql.writer.print("SELECT ROW_NUMBER() OVER () AS event_id,{s} AS event_entity,{s} AS event_time,{s} AS event_value", .{ converted_entity, converted_time, try conversionWeight(self, converted.model, converted.measure) });
        for (base_groups.items, self.query.group_by) |group, name| try base_sql.writer.print(",{s} AS {s}", .{ group, try ident(a, name) });
        for (list(field(params, "constant_properties")), 0..) |property, i| {
            const base_property = text(property, "base_property") orelse return error.InvalidMetricQuery;
            const conversion_property = text(property, "conversion_property") orelse return error.InvalidMetricQuery;
            try base_sql.writer.print(",{s} AS p{d}", .{ try base_source.resolveDimension(base_property), i });
            try conv_sql.writer.print(",{s} AS p{d}", .{ try converted_source.resolveDimension(conversion_property), i });
        }
        try base_sql.writer.print(" FROM {s} s{s}", .{ try self.relationFor(base.model), base_source.joins.items });
        try conv_sql.writer.print(" FROM {s} s{s}", .{ try self.relationFor(converted.model), converted_source.joins.items });
        try writePredicates(&base_sql.writer, base_filters.items);
        try writePredicates(&conv_sql.writer, conversion_filters.items);
        const base_cte = try self.add(try base_sql.toOwnedSlice());
        const conversion_cte = try self.add(try conv_sql.toOwnedSlice());
        var joined: std.Io.Writer.Allocating = .init(a);
        try joined.writer.writeAll("SELECT b.*,c.event_value,ROW_NUMBER() OVER (PARTITION BY c.event_id ORDER BY b.event_time DESC) AS conversion_rank");
        try joined.writer.print(" FROM {s} b INNER JOIN {s} c ON b.event_entity=c.event_entity AND b.event_time<=c.event_time", .{ base_cte, conversion_cte });
        const window = field(params, "window");
        if (window != .null) {
            const count = field(window, "count");
            const grain = text(window, "granularity") orelse return error.InvalidMetricWindow;
            if (count != .integer or count.integer < 0 or !sem.grainValid(grain)) return error.InvalidMetricWindow;
            try joined.writer.print(" AND b.event_time>c.event_time-INTERVAL '{d} {s}'", .{ count.integer * @as(i64, if (eq(grain, "quarter")) 3 else 1), if (eq(grain, "quarter")) "month" else grain });
        }
        for (list(field(params, "constant_properties")), 0..) |_, i| try joined.writer.print(" AND b.p{d}=c.p{d}", .{ i, i });
        const matched = try self.add(try joined.toOwnedSlice());
        var numerator: std.Io.Writer.Allocating = .init(a);
        try numerator.writer.writeAll("SELECT ");
        for (self.query.group_by) |group| try numerator.writer.print("{s},", .{try ident(a, group)});
        const agg = text(converted.measure, "agg").?;
        try numerator.writer.print("{s}event_value) AS converted_count FROM {s} WHERE conversion_rank=1", .{ if (eq(agg, "count_distinct")) "COUNT(DISTINCT " else "SUM(", matched });
        if (self.query.group_by.len != 0) {
            try numerator.writer.writeAll(" GROUP BY ");
            for (self.query.group_by, 0..) |group, i| {
                if (i != 0) try numerator.writer.writeByte(',');
                try numerator.writer.writeAll(try ident(a, group));
            }
        }
        const numerator_cte = try self.add(try numerator.toOwnedSlice());
        var denominator_resource = resource.*;
        denominator_resource.name = "base_count";
        const denominator_cte = try self.compileMeasure(&denominator_resource, base_input, extra, false);
        const outputs = [_]Output{ .{ .name = "base_count", .cte = denominator_cte }, .{ .name = "converted_count", .cte = numerator_cte } };
        const calculation = text(params, "calculation") orelse "conversion_rate";
        const expr = if (eq(calculation, "conversions")) "i1.converted_count" else if (eq(calculation, "conversion_rate")) "CAST(i1.converted_count AS DOUBLE PRECISION)/NULLIF(i0.base_count,0)" else return error.InvalidMetricQuery;
        return self.combineOutputs(&outputs, resource.name, expr);
    }
};

const Source = struct {
    context: *Context,
    model: *const Resource,
    measure: Value,
    joins: std.ArrayList(u8) = .empty,
    joined: std.ArrayList(struct { model: *const Resource, alias: []const u8, source_alias: []const u8, entity: []const u8 }) = .empty,
    fn minimumTimeGrain(self: *const Source) ![]const u8 {
        const name = text(self.measure, "agg_time_dimension") orelse text(field(self.model.data, "defaults"), "agg_time_dimension") orelse return error.MissingAggregationTimeDimension;
        for (list(field(self.model.data, "dimensions"))) |dimension| if (eq(text(dimension, "name").?, name)) return text(field(dimension, "type_params"), "time_granularity") orelse return error.InvalidMetricGrain;
        return error.MissingAggregationTimeDimension;
    }
    fn time(self: *Source) ![]const u8 {
        const name = text(self.measure, "agg_time_dimension") orelse text(field(self.model.data, "defaults"), "agg_time_dimension") orelse return error.MissingAggregationTimeDimension;
        for (list(field(self.model.data, "dimensions"))) |dimension| if (eq(text(dimension, "name").?, name)) return self.context.qualifyFor(self.model, "s", text(dimension, "expr") orelse name);
        return error.MissingAggregationTimeDimension;
    }
    fn resolveDimension(self: *Source, requested: []const u8) anyerror![]const u8 {
        const a = self.context.allocator;
        var parts: std.ArrayList([]const u8) = .empty;
        var tokens = std.mem.splitSequence(u8, requested, "__");
        while (tokens.next()) |part| {
            if (part.len == 0) return error.InvalidMetricDimension;
            try parts.append(a, part);
        }
        var grain: ?[]const u8 = null;
        if (parts.items.len > 1 and sem.grainValid(parts.items[parts.items.len - 1])) {
            grain = parts.pop().?;
        }
        var model = self.model;
        var alias: []const u8 = "s";
        for (parts.items[0 .. parts.items.len - 1], 0..) |entity_name, path_index| {
            var local: Value = .null;
            for (list(field(model.data, "entities"))) |entity| if (eq(text(entity, "name").?, entity_name)) {
                local = entity;
                break;
            };
            if (local == .null) return error.InvalidMetricJoinPath;
            const local_type = text(local, "type").?;
            if (path_index == 0 and (eq(local_type, "primary") or eq(local_type, "unique")) and parts.items.len == 2) {
                var local_dimension = false;
                for (list(field(model.data, "dimensions"))) |dimension| if (eq(text(dimension, "name").?, parts.items[1])) {
                    local_dimension = true;
                    break;
                };
                if (local_dimension) continue;
            }
            var target: ?*const Resource = null;
            var target_entity: Value = .null;
            for (self.context.graph.semantic_resources.items) |*candidate| {
                if (!candidate.enabled or !eq(candidate.resource_type, "semantic_model") or candidate == model) continue;
                for (list(field(candidate.data, "entities"))) |entity| {
                    if (!eq(text(entity, "name").?, entity_name)) continue;
                    const kind = text(entity, "type").?;
                    if (!eq(kind, "primary") and !eq(kind, "unique")) continue;
                    if (target != null) return error.AmbiguousMetricJoinPath;
                    target = candidate;
                    target_entity = entity;
                }
            }
            const destination = target orelse return error.MetricFanoutJoin;
            var found: ?[]const u8 = null;
            for (self.joined.items) |join| if (join.model == destination and eq(join.source_alias, alias) and eq(join.entity, entity_name)) {
                found = join.alias;
                break;
            };
            const next_alias = found orelse try std.fmt.allocPrint(a, "j{d}", .{self.joined.items.len});
            if (found == null) {
                const clause = try std.fmt.allocPrint(a, " LEFT JOIN {s} {s} ON {s} = {s}", .{ try self.context.relationFor(destination), next_alias, try self.context.qualifyFor(model, alias, text(local, "expr") orelse entity_name), try self.context.qualifyFor(destination, next_alias, text(target_entity, "expr") orelse entity_name) });
                try self.joins.appendSlice(a, clause);
                try self.joined.append(a, .{ .model = destination, .alias = next_alias, .source_alias = alias, .entity = entity_name });
                var logical: Value = .{ .object = .empty };
                try values.put(a, &logical, "entity", .{ .string = entity_name });
                try values.put(a, &logical, "from", .{ .string = model.unique_id });
                try values.put(a, &logical, "to", .{ .string = destination.unique_id });
                try values.put(a, &logical, "cardinality", .{ .string = "many_to_one" });
                try self.context.joins.array.append(logical);
            }
            model = destination;
            alias = next_alias;
        }
        const name = parts.items[parts.items.len - 1];
        if (eq(name, "metric_time")) {
            const base = try self.time();
            const granularity = grain orelse "day";
            const time_name = text(self.measure, "agg_time_dimension") orelse text(field(self.model.data, "defaults"), "agg_time_dimension") orelse return error.MissingAggregationTimeDimension;
            for (list(field(self.model.data, "dimensions"))) |dim| if (eq(text(dim, "name").?, time_name)) {
                const minimum = text(field(dim, "type_params"), "time_granularity") orelse return error.InvalidMetricGrain;
                if (grainRank(granularity) < grainRank(minimum)) return error.InvalidMetricGrain;
            };
            return std.fmt.allocPrint(a, "DATE_TRUNC('{s}',{s})", .{ granularity, base });
        }
        for (list(field(model.data, "dimensions"))) |dimension| if (eq(text(dimension, "name").?, name)) {
            const expr = try self.context.qualifyFor(model, alias, text(dimension, "expr") orelse name);
            if (eq(text(dimension, "type").?, "time")) {
                const minimum = text(field(dimension, "type_params"), "time_granularity") orelse return error.InvalidMetricGrain;
                const granularity = grain orelse minimum;
                if (grainRank(granularity) < grainRank(minimum)) return error.InvalidMetricGrain;
                return std.fmt.allocPrint(a, "DATE_TRUNC('{s}',{s})", .{ granularity, expr });
            }
            if (grain != null) return error.InvalidMetricGrain;
            return expr;
        };
        for (list(field(model.data, "entities"))) |entity| if (eq(text(entity, "name").?, name)) {
            if (grain != null) return error.InvalidMetricGrain;
            return self.context.qualifyFor(model, alias, text(entity, "expr") orelse name);
        };
        return error.InvalidMetricDimension;
    }
    fn filter(self: *Source, template: []const u8) ![]const u8 {
        const a = self.context.allocator;
        var out: std.Io.Writer.Allocating = .init(a);
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, template, cursor, "{{")) |open| {
            try out.writer.writeAll(template[cursor..open]);
            const end = std.mem.indexOfPos(u8, template, open + 2, "}}") orelse return error.InvalidMetricFilter;
            const result = try expression.evaluate(a, std.mem.trim(u8, template[open + 2 .. end], " \t\r\n"), .{ .context = self, .resolve = resolve, .call = call });
            if (result != .string) return error.InvalidMetricFilter;
            try out.writer.writeAll(result.string);
            cursor = end + 2;
        }
        try out.writer.writeAll(template[cursor..]);
        return self.context.qualifyFor(self.model, "s", try out.toOwnedSlice());
    }
    fn filters(self: *Source, predicates: *std.ArrayList([]const u8), filter_set: Value) !void {
        for (list(field(filter_set, "where_filters"))) |entry| try predicates.append(self.context.allocator, try self.filter(text(entry, "where_sql_template") orelse return error.InvalidMetricFilter));
    }
    fn resolve(_: *anyopaque, _: []const u8, _: std.mem.Allocator) anyerror!expression.Value {
        return .undefined;
    }
    fn call(raw: *anyopaque, name: []const u8, args: []const expression.Argument, a: std.mem.Allocator) anyerror!expression.Value {
        const self: *Source = @ptrCast(@alignCast(raw));
        const result = try NameHost.call(raw, name, args, a);
        return .{ .string = try self.resolveDimension(result.string) };
    }
};
fn optionalEq(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |value| return if (right) |other| eq(value, other) else false;
    return right == null;
}
fn estimate(value: Value) !?u64 {
    if (value == .null) return null;
    if (value != .integer or value.integer < 0) return error.InvalidMetricSource;
    return @intCast(value.integer);
}
fn grainRank(grain: []const u8) usize {
    for ([_][]const u8{ "nanosecond", "microsecond", "millisecond", "second", "minute", "hour", "day", "week", "month", "quarter", "year" }, 0..) |candidate, i| if (eq(grain, candidate)) return i;
    return 100;
}
fn aggregation(a: std.mem.Allocator, adapter_type: []const u8, measure: Value, expr: []const u8) ![]const u8 {
    const agg = text(measure, "agg") orelse return error.InvalidMetricQuery;
    if (eq(agg, "count_distinct")) return std.fmt.allocPrint(a, "COUNT(DISTINCT {s})", .{expr});
    // The semantic manifest count-to-sum transform makes count measures
    // additive across source groups. SUM also preserves its empty-input NULL.
    if (eq(agg, "count")) return std.fmt.allocPrint(a, "SUM(CASE WHEN {s} IS NULL THEN 0 ELSE 1 END)", .{expr});
    if (eq(agg, "sum_boolean")) return std.fmt.allocPrint(a, "SUM(CASE WHEN {s} THEN 1 ELSE 0 END)", .{expr});
    if (eq(agg, "median")) return std.fmt.allocPrint(a, "PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY {s})", .{expr});
    if (eq(agg, "percentile")) {
        const params = field(measure, "agg_params");
        const percentile = field(params, "percentile");
        if (percentile != .float and percentile != .integer) return error.InvalidMetricPercentile;
        const number: f64 = if (percentile == .float) percentile.float else @floatFromInt(percentile.integer);
        if (number < 0 or number > 1) return error.InvalidMetricPercentile;
        const approximate = field(params, "use_approximate_percentile");
        const discrete = field(params, "use_discrete_percentile");
        if (approximate == .bool and approximate.bool) {
            if (!eq(adapter_type, "duckdb") or (discrete == .bool and discrete.bool)) return error.UnsupportedMetricPercentile;
            return std.fmt.allocPrint(a, "APPROX_QUANTILE({s},{d})", .{ expr, number });
        }
        return std.fmt.allocPrint(a, "{s}({d}) WITHIN GROUP(ORDER BY {s})", .{ if (discrete == .bool and discrete.bool) "PERCENTILE_DISC" else "PERCENTILE_CONT", number, expr });
    }
    const function = if (eq(agg, "average")) "AVG" else if (eq(agg, "sum")) "SUM" else if (eq(agg, "min")) "MIN" else if (eq(agg, "max")) "MAX" else return error.InvalidMetricQuery;
    return std.fmt.allocPrint(a, "{s}({s})", .{ function, expr });
}
fn writePredicates(w: *std.Io.Writer, predicates: []const []const u8) !void {
    if (predicates.len == 0) return;
    try w.writeAll(" WHERE ");
    for (predicates, 0..) |predicate, i| {
        if (i != 0) try w.writeAll(" AND ");
        try w.print("({s})", .{predicate});
    }
}
fn qualify(a: std.mem.Allocator, alias: []const u8, expr: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var cursor: usize = 0;
    while (cursor < expr.len) {
        const c = expr[cursor];
        if (c == '\'' or c == '"') {
            const quote = c;
            const start = cursor;
            cursor += 1;
            while (cursor < expr.len) : (cursor += 1) if (expr[cursor] == quote) {
                cursor += 1;
                if (cursor < expr.len and expr[cursor] == quote) continue;
                break;
            };
            if (quote == '"') {
                var next = cursor;
                while (next < expr.len and std.ascii.isWhitespace(expr[next])) next += 1;
                if ((start == 0 or expr[start - 1] != '.') and (next == expr.len or expr[next] != '.')) try out.writer.print("{s}.", .{alias});
            }
            try out.writer.writeAll(expr[start..cursor]);
        } else if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = cursor;
            while (cursor < expr.len and (std.ascii.isAlphanumeric(expr[cursor]) or expr[cursor] == '_')) cursor += 1;
            const token = expr[start..cursor];
            var next = cursor;
            while (next < expr.len and std.ascii.isWhitespace(expr[next])) next += 1;
            var keyword = false;
            for ([_][]const u8{ "case", "when", "then", "else", "end", "and", "or", "not", "null", "true", "false", "as", "distinct", "in", "is", "between", "like", "date", "timestamp", "interval", "integer", "bigint", "double", "precision", "varchar", "decimal", "boolean" }) |word| if (std.ascii.eqlIgnoreCase(token, word)) {
                keyword = true;
                break;
            };
            if (keyword or (next < expr.len and (expr[next] == '(' or expr[next] == '.')) or (start > 0 and expr[start - 1] == '.')) try out.writer.writeAll(token) else try out.writer.print("{s}.{s}", .{ alias, try ident(a, token) });
        } else {
            try out.writer.writeByte(c);
            cursor += 1;
        }
    }
    return out.toOwnedSlice();
}

fn findMeasure(graph: *const Graph, name: []const u8) !struct { model: *const Resource, measure: Value } {
    for (graph.semantic_resources.items) |*model| {
        if (!model.enabled or !eq(model.resource_type, "semantic_model")) continue;
        for (list(field(model.data, "measures"))) |measure| if (eq(text(measure, "name").?, name)) return .{ .model = model, .measure = measure };
    }
    return error.MissingSemanticMeasure;
}
fn conversionWeight(context: *Context, model: *const Resource, measure: Value) ![]const u8 {
    const a = context.allocator;
    const agg = text(measure, "agg").?;
    const expr = try context.qualifyFor(model, "s", text(measure, "expr") orelse text(measure, "name").?);
    if (eq(agg, "count")) return std.fmt.allocPrint(a, "CASE WHEN {s} IS NULL THEN 0 ELSE 1 END", .{expr});
    if (eq(agg, "count_distinct")) return expr;
    if (eq(agg, "sum") and eq(std.mem.trim(u8, expr, " "), "1")) return expr;
    return error.InvalidConversionAggregation;
}

fn testGraph(a: std.mem.Allocator) !Graph {
    var graph = Graph{ .allocator = a, .project_name = "demo", .database_path = "warehouse.duckdb" };
    errdefer graph.deinit();
    for ([_][]const u8{ "orders", "customers", "metricflow_time_spine" }) |name| {
        const id = if (eq(name, "orders")) "model.demo.orders" else if (eq(name, "customers")) "model.demo.customers" else "model.demo.metricflow_time_spine";
        try graph.nodes.append(a, .{ .name = name, .unique_id = id, .package_name = "demo", .path = "model.sql", .original_file_path = "models/model.sql", .raw_code = "select 1" });
    }
    try sem.parseProperties(.{ .allocator = a, .io = std.testing.io },
        \\semantic_models:
        \\ - name: orders
        \\   model: ref('orders')
        \\   defaults: {agg_time_dimension: created_at}
        \\   entities: [{name: order_key, type: primary, expr: id}, {name: customer, type: foreign, expr: customer_id}]
        \\   dimensions: [{name: created_at, type: time, type_params: {time_granularity: day}}]
        \\   measures: [{name: amount, agg: sum, expr: amount}]
        \\ - name: customers
        \\   model: ref('customers')
        \\   entities: [{name: customer, type: primary, expr: id}]
        \\   dimensions: [{name: country, type: categorical}]
        \\metrics:
        \\ - {name: revenue, label: Revenue, type: simple, type_params: {measure: amount}}
        \\ - {name: doubled, label: Doubled, type: derived, type_params: {expr: 'revenue * 2', metrics: [revenue]}}
    , "models", "models/semantic.yml", "demo", &graph);
    try sem.resolve(&graph);
    return graph;
}

test "metric logical plan validates joins and owns its SQL and relational IR" {
    const a = std.testing.allocator;
    var graph = try testGraph(a);
    var plan = build(a, &graph, .{ .metrics = &.{ "revenue", "doubled" }, .group_by = &.{"customer__country"} }) catch |err| {
        graph.deinit();
        return err;
    };
    graph.deinit();
    defer plan.deinit();
    try std.testing.expect(std.mem.indexOf(u8, plan.sql, "LEFT JOIN") != null);
    try std.testing.expectEqualStrings("many_to_one", text(list(field(plan.logical, "joins"))[0], "cardinality").?);
    const serialized = try plan.json(a);
    defer a.free(serialized);
    var parsed = try std.json.parseFromSlice(Value, a, serialized, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(plan.sql, text(parsed.value, "sql").?);
    try std.testing.expectEqual(@as(usize, 0), list(field(parsed.value, "movement")).len);
    try std.testing.expectEqual(@as(usize, 2), plan.bindings.len);
    var found = false;
    for (plan.bindings) |binding| if (eq(binding.logical_id, "model.demo.orders")) {
        found = true;
        const query_sql = binding.source_query.?;
        try std.testing.expect(std.mem.indexOf(u8, query_sql, "\"amount\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, query_sql, "\"customer_id\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, query_sql, "\"created_at\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, query_sql, "SELECT *") == null);
    };
    try std.testing.expect(found);
}

test "metric planner rejects finer grains unknown dimensions and invalid percentiles" {
    const a = std.testing.allocator;
    var graph = try testGraph(a);
    defer graph.deinit();
    try std.testing.expectError(error.InvalidMetricGrain, build(a, &graph, .{ .metrics = &.{"revenue"}, .group_by = &.{"metric_time__hour"} }));
    try std.testing.expectError(error.InvalidMetricDimension, build(a, &graph, .{ .metrics = &.{"revenue"}, .group_by = &.{"customer__absent"} }));
    var raw = try std.json.parseFromSlice(Value, a, "{\"agg\":\"percentile\",\"agg_params\":{\"percentile\":1.5}}", .{});
    defer raw.deinit();
    try std.testing.expectError(error.InvalidMetricPercentile, aggregation(a, "duckdb", raw.value, "amount"));
}

test "semantic count measures use additive null-aware sums" {
    const a = std.testing.allocator;
    var raw = try std.json.parseFromSlice(Value, a, "{\"agg\":\"count\"}", .{});
    defer raw.deinit();
    const sql = try aggregation(a, "duckdb", raw.value, "amount");
    defer a.free(sql);
    try std.testing.expectEqualStrings("SUM(CASE WHEN amount IS NULL THEN 0 ELSE 1 END)", sql);
}
