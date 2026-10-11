const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");
const yaml = @import("yaml.zig");
const compiler = @import("compiler.zig");
const util = @import("util.zig");
const fs = @import("fs.zig");
const Value = std.json.Value;
const Graph = types.Graph;
const Resource = types.SemanticResource;

pub fn field(value: Value, key: []const u8) Value {
    return values.get(value, key) orelse .null;
}
pub fn string(value: Value) ?[]const u8 {
    return if (value == .string) value.string else null;
}
pub fn list(value: Value) []const Value {
    return if (value == .array) value.array.items else &.{};
}
fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn text(value: Value, key: []const u8) ?[]const u8 {
    return string(field(value, key));
}
fn put(a: std.mem.Allocator, target: *Value, key: []const u8, value: Value) !void {
    try values.put(a, target, key, value);
}
fn putText(a: std.mem.Allocator, target: *Value, key: []const u8, value: []const u8) !void {
    try put(a, target, key, .{ .string = value });
}
fn defaults(a: std.mem.Allocator, raw: []const u8) !Value {
    var parsed = try std.json.parseFromSlice(Value, a, raw, .{});
    defer parsed.deinit();
    return values.clone(a, parsed.value);
}
fn append(a: std.mem.Allocator, target: *Value, value: Value) !void {
    if (target.* != .array) return error.InvalidSemanticResource;
    try target.array.append(try values.clone(a, value));
}
fn appendText(a: std.mem.Allocator, target: *Value, value: []const u8) !void {
    try append(a, target, .{ .string = value });
}
fn required(value: Value, key: []const u8) ![]const u8 {
    return text(value, key) orelse error.InvalidSemanticResource;
}
fn validName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}
fn enumeration(value: []const u8, allowed: []const []const u8) !void {
    for (allowed) |candidate| if (equal(value, candidate)) return;
    return error.InvalidSemanticResource;
}
pub fn grainValid(grain: []const u8) bool {
    for ([_][]const u8{ "nanosecond", "microsecond", "millisecond", "second", "minute", "hour", "day", "week", "month", "quarter", "year" }) |candidate| if (equal(grain, candidate)) return true;
    return false;
}

/// A resource owns its complete normalized JSON trees. Resource field slices
/// and the graph edges borrow from those trees; graph teardown releases trees.
pub fn parseProperties(runtime: types.Runtime, text_yaml: []const u8, resource_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    var document = try yaml.parse(runtime.allocator, text_yaml);
    defer document.deinit();
    if (document.value == .null) return;
    if (document.value != .object) return error.InvalidSemanticResource;
    for ([_][]const u8{ "semantic_models", "metrics", "saved_queries" }, [_][]const u8{ "semantic_model", "metric", "saved_query" }) |key, kind| {
        const raw = field(document.value, key);
        if (raw == .null) continue;
        if (raw != .array) return error.InvalidSemanticResource;
        for (raw.array.items) |entry| try addResource(runtime, graph, kind, entry, resource_root, relative_path, package_name);
    }
    for (list(field(document.value, "models"))) |model| {
        const spine = field(model, "time_spine");
        if (spine == .null) continue;
        var raw = try values.clone(runtime.allocator, model);
        errdefer values.deinit(runtime.allocator, &raw);
        try graph.semantic_time_spines.append(runtime.allocator, .{ .package_name = try runtime.allocator.dupe(u8, package_name), .raw = raw });
    }
}

fn addResource(runtime: types.Runtime, graph: *Graph, kind: []const u8, raw: Value, root: []const u8, path: []const u8, package: []const u8) !void {
    const a = runtime.allocator;
    if (raw != .object) return error.InvalidSemanticResource;
    const name = try required(raw, "name");
    if (!validName(name)) return error.InvalidSemanticResource;
    var data = try defaults(a, "{\"description\":\"\",\"label\":null,\"metadata\":null,\"created_at\":0,\"group\":null,\"depends_on\":{\"macros\":[],\"nodes\":[]},\"refs\":[]}");
    var owns_data = true;
    errdefer if (owns_data) values.deinit(a, &data);
    try putText(a, &data, "name", name);
    try putText(a, &data, "resource_type", kind);
    try putText(a, &data, "package_name", package);
    const short_path = if (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/') path[root.len + 1 ..] else path;
    try putText(a, &data, "path", short_path);
    try putText(a, &data, "original_file_path", path);
    const id = try std.fmt.allocPrint(a, "{s}.{s}.{s}", .{ kind, package, name });
    defer a.free(id);
    for (graph.semantic_resources.items) |resource| if (equal(resource.unique_id, id)) return error.DuplicateSemanticResource;
    try putText(a, &data, "unique_id", id);
    var fqn: Value = .{ .array = std.json.Array.init(a) };
    defer values.deinit(a, &fqn);
    try appendText(a, &fqn, package);
    if (std.fs.path.dirname(short_path)) |parent| {
        var pieces = std.mem.tokenizeAny(u8, parent, "/\\");
        while (pieces.next()) |part| try appendText(a, &fqn, part);
    }
    try appendText(a, &fqn, name);
    try put(a, &data, "fqn", fqn);
    inline for (.{ "description", "label" }) |key| if (values.get(raw, key)) |value| {
        try put(a, &data, key, value);
    };
    var config = try defaults(a, "{\"enabled\":true,\"group\":null,\"meta\":{}}");
    defer values.deinit(a, &config);
    var raw_config: Value = .{ .object = .empty };
    defer values.deinit(a, &raw_config);
    var effective_config: Value = .{ .object = .empty };
    defer values.deinit(a, &effective_config);
    const block = if (equal(kind, "semantic_model")) "semantic-models" else if (equal(kind, "metric")) "metrics" else "saved-queries";
    // Core 1.10 unrendered config lookup uses underscore keys, while rendered
    // project config uses the public hyphenated YAML keys. Preserve that contract.
    const raw_block = if (equal(kind, "semantic_model")) "semantic_models" else if (equal(kind, "metric")) "metrics" else "saved_queries";
    for ([_]bool{ false, true }) |root_pass| {
        for (graph.semantic_project_configs.items) |project| {
            if (equal(project.package_name, graph.project_name) != root_pass) continue;
            if (!root_pass and !equal(project.package_name, package)) continue;
            try pathConfig(a, &raw_config, field(project.raw, raw_block), package, short_path, name, false);
            try pathConfig(a, &effective_config, field(project.rendered, block), package, short_path, name, true);
        }
    }
    if (field(raw, "config") != .null) try values.overlay(a, &raw_config, field(raw, "config"));
    if (field(raw, "config") != .null) {
        var context = @import("config_render.zig").Context{ .runtime = runtime, .vars = graph.vars.items, .target = graph.target_context };
        var rendered = try context.render(field(raw, "config"));
        defer values.deinit(a, &rendered);
        try mergeConfig(a, &effective_config, rendered);
    }
    // The active root project's package override has precedence over a
    // dependency package's YAML patch, as in Core's ContextConfigGenerator.
    if (!equal(package, graph.project_name)) for (graph.semantic_project_configs.items) |project| {
        if (!equal(project.package_name, graph.project_name)) continue;
        try pathConfig(a, &raw_config, field(project.raw, raw_block), package, short_path, name, false);
        try pathConfig(a, &effective_config, field(project.rendered, block), package, short_path, name, true);
    };
    try mergeConfig(a, &config, effective_config);
    if (field(config, "enabled") != .bool or field(config, "meta") != .object) return error.InvalidSemanticResource;
    try put(a, &data, "config", config);
    try put(a, &data, "unrendered_config", if (raw_config == .null) .{ .object = .empty } else raw_config);
    try put(a, &data, "group", field(config, "group"));
    if (equal(kind, "semantic_model")) {
        try normalizeModel(a, &data, raw, config);
    } else if (equal(kind, "metric")) {
        try normalizeMetric(a, &data, raw, config);
    } else {
        try normalizeSavedQuery(a, &data, raw, config, graph);
    }
    var resource = Resource{
        .data = data,
        .name = text(data, "name").?,
        .unique_id = text(data, "unique_id").?,
        .resource_type = text(data, "resource_type").?,
        .package_name = text(data, "package_name").?,
        .path = text(data, "path").?,
        .original_file_path = text(data, "original_file_path").?,
        .enabled = field(field(data, "config"), "enabled").bool,
    };
    errdefer if (owns_data) resource.tags.deinit(a);
    for (list(field(data, "tags"))) |tag| try resource.tags.append(a, string(tag) orelse return error.InvalidSemanticResource);
    try graph.semantic_resources.append(a, resource);
    owns_data = false;
    // Core creates a metric from the declaration but emits create_metric=false
    // in the semantic model's normalized measure.
    if (equal(kind, "semantic_model")) for (list(field(raw, "measures"))) |measure| {
        const create = field(measure, "create_metric");
        if (create != .bool or !create.bool) continue;
        var generated = try defaults(a, "{\"type\":\"simple\",\"type_params\":{},\"config\":{}}");
        defer values.deinit(a, &generated);
        const measure_name = try required(measure, "name");
        try putText(a, &generated, "name", measure_name);
        try putText(a, &generated, "label", text(measure, "label") orelse measure_name);
        const description = try std.fmt.allocPrint(a, "Metric created from measure {s}", .{measure_name});
        defer a.free(description);
        try putText(a, &generated, "description", text(measure, "description") orelse description);
        var params = field(generated, "type_params");
        try putText(a, &params, "measure", measure_name);
        try putText(a, &params, "expr", measure_name);
        generated.object.getPtr("type_params").?.* = params;
        var generated_config = field(generated, "config");
        try put(a, &generated_config, "enabled", field(config, "enabled"));
        generated.object.getPtr("config").?.* = generated_config;
        try addResource(runtime, graph, "metric", generated, root, path, package);
    };
}

fn normalizeModel(a: std.mem.Allocator, data: *Value, raw: Value, config: Value) !void {
    try putText(a, data, "model", try required(raw, "model"));
    if (field(raw, "description") == .null) try put(a, data, "description", .null);
    inline for (.{ "node_relation", "defaults", "primary_entity" }) |key| try put(a, data, key, field(raw, key));
    for ([_][]const u8{ "entities", "dimensions", "measures" }) |key| {
        var result: Value = .{ .array = std.json.Array.init(a) };
        defer values.deinit(a, &result);
        for (list(field(raw, key))) |entry| {
            var element = try defaults(a, if (equal(key, "entities"))
                "{\"description\":null,\"label\":null,\"role\":null,\"expr\":null,\"config\":{\"meta\":{}}}"
            else if (equal(key, "dimensions"))
                "{\"description\":null,\"label\":null,\"is_partition\":false,\"type_params\":null,\"expr\":null,\"metadata\":null,\"config\":{\"meta\":{}}}"
            else
                "{\"description\":null,\"label\":null,\"create_metric\":false,\"expr\":null,\"agg_params\":null,\"non_additive_dimension\":null,\"agg_time_dimension\":null,\"config\":{\"meta\":{}}}");
            defer values.deinit(a, &element);
            try values.overlay(a, &element, entry);
            const name = try required(entry, "name");
            if (!validName(name)) return error.InvalidSemanticResource;
            for (list(result)) |prior| if (equal(try required(prior, "name"), name)) return error.DuplicateSemanticElement;
            if (equal(key, "measures")) {
                try enumeration(try required(entry, "agg"), &.{ "sum", "min", "max", "count", "count_distinct", "average", "median", "percentile", "sum_boolean" });
                try put(a, &element, "create_metric", .{ .bool = false });
                const expr = field(element, "expr");
                if (expr != .null and expr != .string) {
                    const rendered = try std.json.Stringify.valueAlloc(a, expr, .{});
                    defer a.free(rendered);
                    try putText(a, &element, "expr", rendered);
                }
                if (field(element, "non_additive_dimension") != .null) {
                    var non_additive = try defaults(a, "{\"window_groupings\":[]}");
                    defer values.deinit(a, &non_additive);
                    try values.overlay(a, &non_additive, field(element, "non_additive_dimension"));
                    try put(a, &element, "non_additive_dimension", non_additive);
                }
            } else if (equal(key, "entities")) {
                try enumeration(try required(entry, "type"), &.{ "primary", "foreign", "unique", "natural" });
            } else {
                const dimension_type = try required(entry, "type");
                try enumeration(dimension_type, &.{ "categorical", "time" });
                if (equal(dimension_type, "time")) {
                    var params = try defaults(a, "{\"validity_params\":null}");
                    defer values.deinit(a, &params);
                    try values.overlay(a, &params, field(entry, "type_params"));
                    const grain = try required(params, "time_granularity");
                    if (!grainValid(grain)) return error.InvalidSemanticResource;
                    try put(a, &element, "type_params", params);
                }
            }
            var element_config = try defaults(a, "{\"meta\":{}}");
            defer values.deinit(a, &element_config);
            var meta = try values.clone(a, field(config, "meta"));
            defer values.deinit(a, &meta);
            const local_meta = field(field(entry, "config"), "meta");
            if (local_meta != .null) try values.overlay(a, &meta, local_meta);
            try put(a, &element_config, "meta", meta);
            try put(a, &element, "config", element_config);
            try append(a, &result, element);
        }
        try put(a, data, key, result);
    }
}

fn normalizeFilter(a: std.mem.Allocator, raw: Value) !Value {
    if (raw == .null) return .null;
    var result = try defaults(a, "{\"where_filters\":[]}");
    errdefer values.deinit(a, &result);
    var filters: Value = .{ .array = std.json.Array.init(a) };
    defer values.deinit(a, &filters);
    const entries = if (raw == .array) raw.array.items else &.{raw};
    for (entries) |entry| {
        var filter: Value = .{ .object = .empty };
        defer values.deinit(a, &filter);
        try putText(a, &filter, "where_sql_template", string(entry) orelse return error.InvalidSemanticResource);
        try append(a, &filters, filter);
    }
    try put(a, &result, "where_filters", filters);
    return result;
}
fn window(a: std.mem.Allocator, raw: Value) !Value {
    if (raw == .null) return .null;
    if (raw == .object) return values.clone(a, raw);
    const source = string(raw) orelse return error.InvalidMetricWindow;
    var tokens = std.mem.tokenizeScalar(u8, source, ' ');
    const count = std.fmt.parseInt(i64, tokens.next() orelse return error.InvalidMetricWindow, 10) catch return error.InvalidMetricWindow;
    const plural = tokens.next() orelse return error.InvalidMetricWindow;
    if (tokens.next() != null or count < 0) return error.InvalidMetricWindow;
    const grain = if (std.mem.endsWith(u8, plural, "s") and grainValid(plural[0 .. plural.len - 1])) plural[0 .. plural.len - 1] else plural;
    if (!grainValid(grain) and !validName(grain)) return error.InvalidMetricWindow;
    var result: Value = .{ .object = .empty };
    errdefer values.deinit(a, &result);
    try put(a, &result, "count", .{ .integer = count });
    try putText(a, &result, "granularity", grain);
    return result;
}
fn input(a: std.mem.Allocator, raw: Value, measure: bool) !Value {
    if (raw == .null) return .null;
    var result = try defaults(a, if (measure) "{\"filter\":null,\"alias\":null,\"join_to_timespine\":false,\"fill_nulls_with\":null}" else "{\"filter\":null,\"alias\":null,\"offset_window\":null,\"offset_to_grain\":null}");
    errdefer values.deinit(a, &result);
    if (raw == .string) try putText(a, &result, "name", raw.string) else try values.overlay(a, &result, raw);
    _ = try required(result, "name");
    var filter = try normalizeFilter(a, field(result, "filter"));
    defer values.deinit(a, &filter);
    try put(a, &result, "filter", filter);
    if (!measure) {
        var offset = try window(a, field(result, "offset_window"));
        defer values.deinit(a, &offset);
        try put(a, &result, "offset_window", offset);
    }
    return result;
}
fn normalizeMetric(a: std.mem.Allocator, data: *Value, raw: Value, config: Value) !void {
    _ = try required(raw, "label");
    const metric_type = try required(raw, "type");
    try enumeration(metric_type, &.{ "simple", "ratio", "derived", "cumulative", "conversion" });
    try putText(a, data, "type", metric_type);
    var params = try defaults(a, "{\"measure\":null,\"input_measures\":[],\"numerator\":null,\"denominator\":null,\"expr\":null,\"window\":null,\"grain_to_date\":null,\"metrics\":[],\"conversion_type_params\":null,\"cumulative_type_params\":null}");
    defer values.deinit(a, &params);
    const raw_params = field(raw, "type_params");
    if (raw_params != .object) return error.InvalidSemanticResource;
    try values.overlay(a, &params, raw_params);
    for ([_][]const u8{ "measure", "numerator", "denominator" }) |key| {
        var normalized = try input(a, field(raw_params, key), equal(key, "measure"));
        defer values.deinit(a, &normalized);
        try put(a, &params, key, normalized);
    }
    var metrics: Value = .{ .array = std.json.Array.init(a) };
    defer values.deinit(a, &metrics);
    for (list(field(raw_params, "metrics"))) |entry| {
        var normalized = try input(a, entry, false);
        defer values.deinit(a, &normalized);
        try append(a, &metrics, normalized);
    }
    try put(a, &params, "metrics", metrics);
    var legacy_window = try window(a, field(raw_params, "window"));
    defer values.deinit(a, &legacy_window);
    try put(a, &params, "window", legacy_window);
    if (equal(metric_type, "cumulative")) {
        var cumulative = try defaults(a, "{\"window\":null,\"grain_to_date\":null,\"period_agg\":\"first\"}");
        defer values.deinit(a, &cumulative);
        const nested = field(raw_params, "cumulative_type_params");
        if (nested != .null) try values.overlay(a, &cumulative, nested);
        var normalized_window = try window(a, if (field(cumulative, "window") == .null) field(raw_params, "window") else field(cumulative, "window"));
        defer values.deinit(a, &normalized_window);
        try put(a, &cumulative, "window", normalized_window);
        if (field(cumulative, "grain_to_date") == .null) try put(a, &cumulative, "grain_to_date", field(raw_params, "grain_to_date"));
        try put(a, &params, "cumulative_type_params", cumulative);
    }
    if (equal(metric_type, "conversion")) {
        var conversion = try defaults(a, "{\"calculation\":\"conversion_rate\",\"window\":null,\"constant_properties\":null}");
        defer values.deinit(a, &conversion);
        try values.overlay(a, &conversion, field(raw_params, "conversion_type_params"));
        _ = try required(conversion, "entity");
        inline for (.{ "base_measure", "conversion_measure" }) |key| {
            var normalized = try input(a, field(conversion, key), true);
            defer values.deinit(a, &normalized);
            if (normalized == .null) return error.InvalidSemanticResource;
            try put(a, &conversion, key, normalized);
        }
        var conversion_window = try window(a, field(conversion, "window"));
        defer values.deinit(a, &conversion_window);
        try put(a, &conversion, "window", conversion_window);
        try put(a, &params, "conversion_type_params", conversion);
    }
    if ((equal(metric_type, "simple") or equal(metric_type, "cumulative")) and field(params, "measure") == .null) return error.InvalidSemanticResource;
    if (equal(metric_type, "ratio") and (field(params, "numerator") == .null or field(params, "denominator") == .null)) return error.InvalidSemanticResource;
    if (equal(metric_type, "derived") and (field(params, "expr") != .string or list(metrics).len == 0)) return error.InvalidSemanticResource;
    try put(a, data, "type_params", params);
    var filter = try normalizeFilter(a, field(raw, "filter"));
    defer values.deinit(a, &filter);
    try put(a, data, "filter", filter);
    try put(a, data, "time_granularity", field(raw, "time_granularity"));
    try put(a, data, "meta", if (field(config, "meta").object.count() != 0) field(config, "meta") else if (field(raw, "meta") != .null) field(raw, "meta") else .{ .object = .empty });
    const tags = field(raw, "tags");
    if (tags != .null and tags != .array) return error.InvalidSemanticResource;
    try put(a, data, "tags", if (tags == .null) .{ .array = std.json.Array.init(a) } else tags);
    try put(a, data, "sources", .{ .array = std.json.Array.init(a) });
    try put(a, data, "metrics", .{ .array = std.json.Array.init(a) });
}
fn normalizeSavedQuery(a: std.mem.Allocator, data: *Value, raw: Value, config: Value, graph: *const Graph) !void {
    var query = try defaults(a, "{\"metrics\":[],\"group_by\":[],\"where\":null,\"order_by\":[],\"limit\":null}");
    defer values.deinit(a, &query);
    try values.overlay(a, &query, field(raw, "query_params"));
    if (list(field(query, "metrics")).len == 0) return error.InvalidSemanticResource;
    var filter = try normalizeFilter(a, field(query, "where"));
    defer values.deinit(a, &filter);
    try put(a, &query, "where", filter);
    try put(a, data, "query_params", query);
    var effective = try defaults(a, "{\"export_as\":null,\"schema\":null,\"cache\":{\"enabled\":false},\"tags\":[]}");
    defer values.deinit(a, &effective);
    try values.overlay(a, &effective, config);
    try put(a, data, "config", effective);
    var tags: Value = .{ .array = std.json.Array.init(a) };
    defer values.deinit(a, &tags);
    for ([_]Value{ field(effective, "tags"), field(raw, "tags") }) |candidate| {
        if (candidate == .string) try appendText(a, &tags, candidate.string) else for (list(candidate)) |tag| {
            const name = string(tag) orelse return error.InvalidSemanticResource;
            var found = false;
            for (list(tags)) |existing| if (equal(existing.string, name)) {
                found = true;
                break;
            };
            if (!found) try appendText(a, &tags, name);
        }
    }
    try put(a, data, "tags", tags);
    var exports: Value = .{ .array = std.json.Array.init(a) };
    defer values.deinit(a, &exports);
    for (list(field(raw, "exports"))) |entry| {
        var exported: Value = .{ .object = .empty };
        defer values.deinit(a, &exported);
        const name = try required(entry, "name");
        try putText(a, &exported, "name", name);
        const raw_export = field(entry, "config");
        var export_config = try defaults(a, "{\"export_as\":null,\"schema_name\":null,\"alias\":null,\"database\":null}");
        defer values.deinit(a, &export_config);
        try put(a, &export_config, "export_as", field(effective, "export_as"));
        try put(a, &export_config, "schema_name", field(effective, "schema"));
        try putText(a, &export_config, "database", databaseForGraph(graph));
        if (raw_export != .null) {
            for ([_][]const u8{ "export_as", "alias", "database", "schema_name" }) |key| if (values.get(raw_export, key)) |v| try put(a, &export_config, key, v);
            if (values.get(raw_export, "schema")) |schema| try put(a, &export_config, "schema_name", schema);
        }
        if (field(export_config, "alias") == .null) try putText(a, &export_config, "alias", name);
        try enumeration(try required(export_config, "export_as"), &.{ "table", "view" });
        try put(a, &exported, "config", export_config);
        try put(a, &exported, "unrendered_config", if (raw_export == .null) .{ .object = .empty } else raw_export);
        try append(a, &exports, exported);
    }
    try put(a, data, "exports", exports);
}

pub fn find(graph: *const Graph, kind: []const u8, name: []const u8) ?*const Resource {
    for (graph.semantic_resources.items) |*resource| if (resource.enabled and equal(resource.resource_type, kind) and (equal(resource.name, name) or equal(resource.unique_id, name))) return resource;
    return null;
}
fn dependency(a: std.mem.Allocator, resource: *Resource, target: []const u8) !void {
    for (resource.depends_on.items) |prior| if (equal(prior, target)) return;
    try resource.depends_on.append(a, target);
}
pub fn resolve(graph: *Graph) !void {
    const a = graph.allocator;
    for (graph.semantic_resources.items) |*resource| {
        if (!equal(resource.resource_type, "semantic_model")) continue;
        const expr = try required(resource.data, "model");
        var node = types.Node{ .name = "semantic_ref", .unique_id = "semantic_ref", .package_name = resource.package_name, .resource_type = "model", .path = "", .original_file_path = "", .raw_code = "" };
        var scan_arena = std.heap.ArenaAllocator.init(a);
        defer scan_arena.deinit();
        const template = try std.fmt.allocPrint(a, "{{{{ {s} }}}}", .{expr});
        defer a.free(template);
        try compiler.scanDependencies(scan_arena.allocator(), template, &node, graph);
        if (node.refs.items.len != 1 or node.source_refs.items.len != 0) return error.InvalidSemanticModelReference;
        const ref = node.refs.items[0];
        var refs: Value = .{ .array = std.json.Array.init(a) };
        defer values.deinit(a, &refs);
        var ref_json = try defaults(a, "{\"name\":null,\"package\":null,\"version\":null}");
        defer values.deinit(a, &ref_json);
        try putText(a, &ref_json, "name", ref.name);
        if (ref.package) |package| try putText(a, &ref_json, "package", package);
        try append(a, &refs, ref_json);
        try put(a, &resource.data, "refs", refs);
        if (!resource.enabled) continue;
        var target: ?*const types.Node = null;
        for (graph.nodes.items) |*candidate| {
            if (!equal(candidate.resource_type, "model") or !equal(candidate.name, ref.name)) continue;
            if (ref.package) |package| {
                if (!equal(candidate.package_name, package)) continue;
            }
            if (target != null and !equal(candidate.package_name, resource.package_name)) continue;
            target = candidate;
            if (equal(candidate.package_name, resource.package_name)) break;
        }
        const model = target orelse return error.MissingSemanticModelTarget;
        if (!model.enabled) return error.DisabledSemanticModelTarget;
        try dependency(a, resource, model.unique_id);
        var relation = try nodeRelation(a, graph, model);
        defer values.deinit(a, &relation);
        try put(a, &resource.data, "node_relation", relation);
        try validateModel(resource.data);
    }
    const visited = try a.alloc(u8, graph.semantic_resources.items.len);
    defer a.free(visited);
    @memset(visited, 0);
    for (graph.semantic_resources.items, 0..) |resource, index| if (resource.enabled and equal(resource.resource_type, "metric")) try resolveMetric(graph, index, visited);
    for (graph.semantic_resources.items) |*resource| {
        if (!resource.enabled) continue;
        if (equal(resource.resource_type, "saved_query")) for (list(field(field(resource.data, "query_params"), "metrics"))) |metric| {
            const name = string(metric) orelse return error.InvalidSemanticResource;
            const target = find(graph, "metric", name) orelse return error.MissingMetricDependency;
            try dependency(a, resource, target.unique_id);
        };
        var edges: Value = .{ .array = std.json.Array.init(a) };
        defer values.deinit(a, &edges);
        for (resource.depends_on.items) |id| try appendText(a, &edges, id);
        var deps = field(resource.data, "depends_on");
        try put(a, &deps, "nodes", edges);
        resource.data.object.getPtr("depends_on").?.* = deps;
    }
    var config = try projectConfiguration(graph);
    defer values.deinit(a, &config);
    std.mem.sort(Resource, graph.semantic_resources.items, {}, struct {
        fn less(_: void, lhs: Resource, rhs: Resource) bool {
            return std.mem.lessThan(u8, lhs.unique_id, rhs.unique_id);
        }
    }.less);
}
fn validateModel(model: Value) !void {
    var primary_count: usize = 0;
    for (list(field(model, "entities"))) |entity| if (equal(try required(entity, "type"), "primary")) {
        primary_count += 1;
    };
    if (primary_count > 1 or (primary_count != 0 and field(model, "primary_entity") != .null)) return error.AmbiguousSemanticPrimaryEntity;
    if (primary_count == 0 and field(model, "primary_entity") == .null and list(field(model, "dimensions")).len != 0) return error.MissingSemanticPrimaryEntity;
    const default_time = text(field(model, "defaults"), "agg_time_dimension");
    for (list(field(model, "measures"))) |measure| {
        const time = text(measure, "agg_time_dimension") orelse default_time orelse return error.MissingAggregationTimeDimension;
        var found = false;
        for (list(field(model, "dimensions"))) |dimension| if (equal(try required(dimension, "name"), time) and equal(try required(dimension, "type"), "time")) {
            found = true;
            break;
        };
        if (!found) return error.MissingAggregationTimeDimension;
    }
}
fn resolveMetric(graph: *Graph, index: usize, visited: []u8) anyerror!void {
    if (visited[index] == 2) return;
    if (visited[index] == 1) return error.CyclicMetricDependency;
    visited[index] = 1;
    const a = graph.allocator;
    const resource = &graph.semantic_resources.items[index];
    const params = field(resource.data, "type_params");
    var measures: Value = .{ .array = std.json.Array.init(a) };
    defer values.deinit(a, &measures);
    for ([_]Value{ field(params, "measure"), field(field(params, "conversion_type_params"), "base_measure"), field(field(params, "conversion_type_params"), "conversion_measure") }) |measure| {
        if (measure == .null) continue;
        const name = try required(measure, "name");
        var target: ?*const Resource = null;
        for (graph.semantic_resources.items) |*model| {
            if (!model.enabled or !equal(model.resource_type, "semantic_model")) continue;
            for (list(field(model.data, "measures"))) |candidate| if (equal(try required(candidate, "name"), name)) {
                if (target != null) return error.AmbiguousSemanticMeasure;
                target = model;
            };
        }
        const model = target orelse return error.MissingSemanticMeasure;
        try dependency(a, resource, model.unique_id);
        try append(a, &measures, measure);
    }
    var inputs: std.ArrayList(Value) = .empty;
    defer inputs.deinit(a);
    for ([_]Value{ field(params, "numerator"), field(params, "denominator") }) |entry| if (entry != .null) try inputs.append(a, entry);
    try inputs.appendSlice(a, list(field(params, "metrics")));
    for (inputs.items) |entry| {
        const name = try required(entry, "name");
        const target = find(graph, "metric", name) orelse return error.MissingMetricDependency;
        const target_index = (@intFromPtr(target) - @intFromPtr(graph.semantic_resources.items.ptr)) / @sizeOf(Resource);
        try resolveMetric(graph, target_index, visited);
        try dependency(a, resource, target.unique_id);
        for (list(field(field(target.data, "type_params"), "input_measures"))) |measure| {
            var duplicate = false;
            for (list(measures)) |prior| if (equal(try required(prior, "name"), try required(measure, "name"))) {
                duplicate = true;
                break;
            };
            if (!duplicate) try append(a, &measures, measure);
        }
    }
    var normalized_params = field(resource.data, "type_params");
    try put(a, &normalized_params, "input_measures", measures);
    resource.data.object.getPtr("type_params").?.* = normalized_params;
    visited[index] = 2;
}
pub fn databaseForGraph(graph: *const Graph) []const u8 {
    if (text(graph.target_context, "database")) |database| return database;
    if (text(graph.target_context, "dbname")) |database| return database;
    const path = graph.database_path orelse return "memory";
    if (equal(path, ":memory:")) return "memory";
    return std.fs.path.stem(path);
}
pub fn nodeRelation(a: std.mem.Allocator, graph: *const Graph, node: *const types.Node) !Value {
    var result: Value = .{ .object = .empty };
    errdefer values.deinit(a, &result);
    const alias = compiler.relationIdentifierForNode(node);
    const schema = try compiler.relationSchemaForNode(a, graph, node);
    defer a.free(schema);
    const database = compiler.relationDatabaseForNode(graph, node) orelse databaseForGraph(graph);
    try putText(a, &result, "alias", alias);
    try putText(a, &result, "schema_name", schema);
    try putText(a, &result, "database", database);
    const qdb = try compiler.quoteIdentifier(a, database);
    defer a.free(qdb);
    const qs = try compiler.quoteIdentifier(a, schema);
    defer a.free(qs);
    const qi = try compiler.quoteIdentifier(a, alias);
    defer a.free(qi);
    const relation = try std.fmt.allocPrint(a, "{s}.{s}.{s}", .{ qdb, qs, qi });
    defer a.free(relation);
    try putText(a, &result, "relation_name", relation);
    return result;
}

fn projectConfiguration(graph: *const Graph) !Value {
    const a = graph.allocator;
    var config = try defaults(a, "{\"time_spine_table_configurations\":[],\"metadata\":null,\"dsi_package_version\":{\"major_version\":\"0\",\"minor_version\":\"9\",\"patch_version\":\"0\"},\"time_spines\":[]}");
    errdefer values.deinit(a, &config);
    var legacy: Value = .{ .array = std.json.Array.init(a) };
    defer values.deinit(a, &legacy);
    var spines: Value = .{ .array = std.json.Array.init(a) };
    defer values.deinit(a, &spines);
    var has_semantic = false;
    for (graph.semantic_resources.items) |resource| if (resource.enabled and equal(resource.resource_type, "semantic_model")) {
        has_semantic = true;
    };
    var day_spine = false;
    if (has_semantic) for (graph.nodes.items) |*node| {
        if (!node.enabled or !equal(node.resource_type, "model") or !equal(node.name, "metricflow_time_spine")) continue;
        var entry = try defaults(a, "{\"location\":null,\"column_name\":\"date_day\",\"grain\":\"day\"}");
        defer values.deinit(a, &entry);
        var relation = try nodeRelation(a, graph, node);
        defer values.deinit(a, &relation);
        try put(a, &entry, "location", field(relation, "relation_name"));
        try append(a, &legacy, entry);
        day_spine = true;
    };
    for (graph.semantic_time_spines.items) |raw| {
        const name = try required(raw.raw, "name");
        var target: ?*const types.Node = null;
        for (graph.nodes.items) |*node| if (node.enabled and equal(node.package_name, raw.package_name) and equal(node.name, name)) {
            target = node;
            break;
        };
        const node = target orelse return error.MissingTimeSpineModel;
        const spine = field(raw.raw, "time_spine");
        const column = try required(spine, "standard_granularity_column");
        var grain: ?[]const u8 = null;
        for (list(field(raw.raw, "columns"))) |candidate| if (equal(try required(candidate, "name"), column)) {
            grain = text(candidate, "granularity");
            break;
        };
        const granularity = grain orelse return error.InvalidTimeSpine;
        if (!grainValid(granularity)) return error.InvalidTimeSpine;
        if (!equal(granularity, "week") and !equal(granularity, "month") and !equal(granularity, "quarter") and !equal(granularity, "year")) day_spine = true;
        var entry = try defaults(a, "{\"node_relation\":null,\"primary_column\":{},\"custom_granularities\":[]}");
        defer values.deinit(a, &entry);
        var relation = try nodeRelation(a, graph, node);
        defer values.deinit(a, &relation);
        try put(a, &entry, "node_relation", relation);
        var primary: Value = .{ .object = .empty };
        defer values.deinit(a, &primary);
        try putText(a, &primary, "name", column);
        try putText(a, &primary, "time_granularity", granularity);
        try put(a, &entry, "primary_column", primary);
        var custom: Value = .{ .array = std.json.Array.init(a) };
        defer values.deinit(a, &custom);
        for (list(field(spine, "custom_granularities"))) |custom_raw| {
            var custom_entry = try defaults(a, "{\"column_name\":null}");
            defer values.deinit(a, &custom_entry);
            try values.overlay(a, &custom_entry, custom_raw);
            _ = try required(custom_entry, "name");
            try append(a, &custom, custom_entry);
        }
        try put(a, &entry, "custom_granularities", custom);
        try append(a, &spines, entry);
    }
    if (has_semantic and !day_spine) return error.MissingSemanticTimeSpine;
    try put(a, &config, "time_spine_table_configurations", legacy);
    try put(a, &config, "time_spines", spines);
    return config;
}

pub fn renderManifest(a: std.mem.Allocator, graph: *const Graph) ![]const u8 {
    var manifest = try defaults(a, "{\"semantic_models\":[],\"metrics\":[],\"saved_queries\":[],\"project_configuration\":{}}");
    defer values.deinit(a, &manifest);
    var config = try projectConfiguration(graph);
    defer values.deinit(a, &config);
    try put(a, &manifest, "project_configuration", config);
    for (graph.semantic_resources.items) |resource| {
        if (!resource.enabled) continue;
        var emitted: Value = .{ .object = .empty };
        defer values.deinit(a, &emitted);
        const kind = resource.resource_type;
        const keys: []const []const u8 = if (equal(kind, "semantic_model")) &.{ "name", "defaults", "description", "node_relation", "primary_entity", "entities", "measures", "dimensions", "metadata", "label", "config" } else if (equal(kind, "metric")) &.{ "name", "description", "type", "type_params", "filter", "metadata", "label", "config", "time_granularity" } else &.{ "name", "query_params", "description", "metadata", "label", "exports", "tags" };
        for (keys) |key| try put(a, &emitted, key, field(resource.data, key));
        if (!equal(kind, "saved_query")) {
            var semantic_config: Value = .{ .object = .empty };
            defer values.deinit(a, &semantic_config);
            try put(a, &semantic_config, "meta", field(field(resource.data, "config"), "meta"));
            try put(a, &emitted, "config", semantic_config);
        }
        if (equal(kind, "semantic_model")) {
            for ([_][]const u8{ "entities", "measures" }) |key| for (emitted.object.getPtr(key).?.array.items) |*element| try put(a, element, "metadata", .null);
        } else if (equal(kind, "saved_query")) {
            for (emitted.object.getPtr("exports").?.array.items) |*exported| {
                remove(a, exported, "unrendered_config");
                remove(a, exported.object.getPtr("config").?, "database");
            }
        }
        const key = if (equal(kind, "semantic_model")) "semantic_models" else if (equal(kind, "metric")) "metrics" else "saved_queries";
        try append(a, manifest.object.getPtr(key).?, emitted);
    }
    return std.json.Stringify.valueAlloc(a, manifest, .{ .whitespace = .indent_2 });
}

fn remove(a: std.mem.Allocator, value: *Value, key: []const u8) void {
    const index = value.object.getIndex(key) orelse return;
    const owned_key = value.object.keys()[index];
    var owned_value = value.object.values()[index];
    value.object.orderedRemoveAt(index);
    a.free(owned_key);
    values.deinit(a, &owned_value);
}

test "semantic resources own nested YAML and resolve model and metric edges" {
    const a = std.testing.allocator;
    var graph = Graph{ .allocator = a, .project_name = "demo", .database_path = "warehouse.duckdb" };
    defer graph.deinit();
    try graph.nodes.append(a, .{ .name = "orders", .unique_id = "model.demo.orders", .package_name = "demo", .path = "orders.sql", .original_file_path = "models/orders.sql", .raw_code = "select 1" });
    try graph.nodes.append(a, .{ .name = "metricflow_time_spine", .unique_id = "model.demo.metricflow_time_spine", .package_name = "demo", .path = "metricflow_time_spine.sql", .original_file_path = "models/metricflow_time_spine.sql", .raw_code = "select 1" });
    try parseProperties(.{ .allocator = a, .io = std.testing.io },
        \\semantic_models:
        \\  - name: orders
        \\    model: ref('orders')
        \\    defaults: {agg_time_dimension: ordered_at}
        \\    entities: [{name: order, type: primary, expr: id}]
        \\    dimensions: [{name: ordered_at, type: time, type_params: {time_granularity: day}}]
        \\    measures: [{name: amount, agg: sum, expr: amount}]
        \\    config: {meta: {nested: {items: [1, true, "owner"]}}}
        \\metrics:
        \\  - name: revenue
        \\    label: Revenue
        \\    type: simple
        \\    type_params: {measure: amount}
        \\  - name: doubled
        \\    label: Doubled
        \\    type: derived
        \\    type_params: {expr: 'revenue * 2', metrics: [revenue]}
    , "models", "models/semantic.yml", "demo", &graph);
    try resolve(&graph);
    const model = find(&graph, "semantic_model", "orders").?;
    try std.testing.expectEqualStrings("model.demo.orders", model.depends_on.items[0]);
    const nested = field(field(field(model.data, "config"), "meta"), "nested");
    try std.testing.expectEqual(@as(i64, 1), list(field(nested, "items"))[0].integer);
    const metric = find(&graph, "metric", "doubled").?;
    try std.testing.expectEqualStrings("metric.demo.revenue", metric.depends_on.items[0]);
    const emitted = try renderManifest(a, &graph);
    defer a.free(emitted);
    var parsed = try std.json.parseFromSlice(Value, a, emitted, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), list(field(parsed.value, "metrics")).len);
}

test "semantic metric cycles fail deterministically" {
    const a = std.testing.allocator;
    var graph = Graph{ .allocator = a, .project_name = "demo" };
    defer graph.deinit();
    try parseProperties(.{ .allocator = a, .io = std.testing.io },
        \\metrics:
        \\  - {name: first, label: First, type: derived, type_params: {expr: second, metrics: [second]}}
        \\  - {name: second, label: Second, type: derived, type_params: {expr: first, metrics: [first]}}
    , "models", "models/semantic.yml", "demo", &graph);
    try std.testing.expectError(error.CyclicMetricDependency, resolve(&graph));
}

pub fn captureProject(graph: *Graph, config: *const types.ProjectConfig) !void {
    const a = graph.allocator;
    var raw = try values.clone(a, config.raw_project);
    errdefer values.deinit(a, &raw);
    var rendered = try values.clone(a, config.rendered_project);
    errdefer values.deinit(a, &rendered);
    const package = try a.dupe(u8, config.name);
    errdefer a.free(package);
    try graph.semantic_project_configs.append(a, .{ .package_name = package, .raw = raw, .rendered = rendered, .file_checksum = config.file_checksum });
}
fn mergeConfig(a: std.mem.Allocator, target: *Value, source: Value) !void {
    if (source == .null) return;
    if (source != .object) return error.InvalidSemanticResource;
    var it = source.object.iterator();
    while (it.next()) |entry| {
        const key = if (std.mem.startsWith(u8, entry.key_ptr.*, "+")) entry.key_ptr.*[1..] else entry.key_ptr.*;
        if (equal(key, "meta") and field(target.*, key) == .object) {
            var meta = try values.clone(a, field(target.*, key));
            defer values.deinit(a, &meta);
            try values.overlay(a, &meta, entry.value_ptr.*);
            try put(a, target, key, meta);
        } else try put(a, target, key, entry.value_ptr.*);
    }
}
fn applyLevel(a: std.mem.Allocator, target: *Value, block: Value, rendered: bool) !void {
    if (block == .null) return;
    if (block != .object) return error.InvalidSemanticResource;
    var config: Value = .{ .object = .empty };
    defer values.deinit(a, &config);
    var it = block.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.startsWith(u8, key, "+") or equal(key, "enabled") or equal(key, "group") or equal(key, "meta") or equal(key, "tags") or equal(key, "export_as") or equal(key, "schema") or equal(key, "cache")) try put(a, &config, if (std.mem.startsWith(u8, key, "+")) key[1..] else key, entry.value_ptr.*);
    }
    if (rendered) try mergeConfig(a, target, config) else try values.overlay(a, target, config);
}
fn pathConfig(a: std.mem.Allocator, target: *Value, block: Value, package: []const u8, path: []const u8, name: []const u8, rendered: bool) !void {
    if (block == .null) return;
    try applyLevel(a, target, block, rendered);
    var current = field(block, package);
    try applyLevel(a, target, current, rendered);
    if (std.fs.path.dirname(path)) |parent| {
        var parts = std.mem.tokenizeAny(u8, parent, "/\\");
        while (parts.next()) |part| {
            current = field(current, part);
            try applyLevel(a, target, current, rendered);
        }
    }
    try applyLevel(a, target, field(current, name), rendered);
}
