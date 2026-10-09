const std = @import("std");
const types = @import("types.zig");
const expression = @import("expression.zig");
const values = @import("config_value.zig");
const Value = expression.Value;

pub fn config(allocator: std.mem.Allocator, node: *const types.Node) !Value {
    // The render arena retains the config until the macro frame completes.
    var canonical = try @import("canonical_manifest_config.zig").node(allocator, node);
    // Core's ModelConfig exposes empty parser metadata to the scaffold macros,
    // even when no config.get call added these extra fields to the artifact.
    if (std.mem.eql(u8, node.language, "python")) {
        if (!canonical.object.contains("config_keys_used")) try canonical.object.put(allocator, "config_keys_used", .{ .array = std.json.Array.init(allocator) });
        if (!canonical.object.contains("config_keys_defaults")) try canonical.object.put(allocator, "config_keys_defaults", .{ .array = std.json.Array.init(allocator) });
    }
    var result = try values.toExpression(allocator, canonical);
    if (result.attribute("begin") == .string) {
        const timestamp = try @import("input_relations.zig").parseDate(result.attribute("begin").string, true);
        const replacement = try @import("timestamp_context.zig").configuredValue(allocator, timestamp, result.attribute("begin").string);
        for (@constCast(result.object)) |*entry| if (std.mem.eql(u8, entry.key, "begin")) {
            entry.value = replacement;
            break;
        };
    }
    if (node.runtime_batch) |batch| {
        const entries = try allocator.alloc(expression.Entry, result.object.len + 2);
        @memcpy(entries[0..result.object.len], result.object);
        entries[result.object.len] = .{ .key = "__dbt_internal_microbatch_event_time_start", .value = try @import("timestamp_context.zig").value(allocator, batch.start) };
        entries[result.object.len + 1] = .{ .key = "__dbt_internal_microbatch_event_time_end", .value = try @import("timestamp_context.zig").value(allocator, batch.end) };
        result = .{ .object = entries };
    }
    return result;
}

pub fn model(allocator: std.mem.Allocator, graph: *const types.Graph, node: *const types.Node) !Value {
    const compiler = @import("compiler.zig");
    const effective_config = try config(allocator, node);
    var columns: std.ArrayList(expression.Entry) = .empty;
    var authored_columns = node.columns.items;
    if (authored_columns.len == 0) for (graph.model_properties.items) |property| {
        if (std.mem.eql(u8, property.package_name, node.package_name) and std.mem.eql(u8, property.resource_type, node.resource_type) and std.mem.eql(u8, property.name, node.name)) {
            authored_columns = property.columns.items;
            break;
        }
    };
    for (authored_columns) |column| {
        var fields = if (column.properties == .object) try values.clone(allocator, column.properties) else std.json.Value{ .object = .empty };
        try fields.object.put(allocator, "name", .{ .string = column.name });
        try fields.object.put(allocator, "description", .{ .string = column.description });
        if (column.data_type) |dtype| try fields.object.put(allocator, "data_type", .{ .string = dtype }) else _ = fields.object.swapRemove("data_type");
        const contract = values.get(node.effective_config, "contract") orelse .null;
        const aliases = values.get(contract, "alias_types") orelse std.json.Value{ .bool = true };
        if (aliases == .bool and aliases.bool) if (column.data_type) |dtype| {
            const translated = (try @import("bundled_macros.zig").callColumn(allocator, "api.Column.translate_type", &.{.{ .value = .{ .string = dtype } }})).?;
            try fields.object.put(allocator, "data_type", .{ .string = translated.string });
        };
        if (column.quote) |quote| try fields.object.put(allocator, "quote", .{ .bool = quote }) else _ = fields.object.swapRemove("quote");
        if (!fields.object.contains("constraints")) try fields.object.put(allocator, "constraints", .{ .array = std.json.Array.init(allocator) });
        try columns.append(allocator, .{ .key = column.name, .value = try values.toExpression(allocator, fields) });
    }
    const tags = try expression.allocateValues(allocator, node.tags.items.len);
    for (node.tags.items, tags) |tag, *value| value.* = .{ .string = tag };
    var batch_value: Value = .none;
    const refs = try expression.allocateValues(allocator, node.refs.items.len);
    for (node.refs.items, refs) |ref, *value| {
        var entries: std.ArrayList(expression.Entry) = .empty;
        try entries.append(allocator, .{ .key = "name", .value = .{ .string = ref.name } });
        if (ref.package) |package| try entries.append(allocator, .{ .key = "package", .value = .{ .string = package } });
        if (ref.version != .null) try entries.append(allocator, .{ .key = "version", .value = try values.toExpression(allocator, ref.version) });
        value.* = .{ .object = try entries.toOwnedSlice(allocator) };
    }
    const sources = try expression.allocateValues(allocator, node.source_refs.items.len);
    for (node.source_refs.items, sources) |source, *value| value.* = .{ .list = try allocator.dupe(Value, &.{ .{ .string = source.source_name }, .{ .string = source.table_name } }) };
    if (node.runtime_batch) |batch| batch_value = .{ .object = try allocator.dupe(expression.Entry, &.{
        .{ .key = "id", .value = if (node.runtime_batch_id) |id| .{ .string = id } else .none },
        .{ .key = "event_time_start", .value = try @import("timestamp_context.zig").value(allocator, batch.start) },
        .{ .key = "event_time_end", .value = try @import("timestamp_context.zig").value(allocator, batch.end) },
    }) };
    var result: Value = .{ .object = try allocator.dupe(expression.Entry, &.{
        .{ .key = "name", .value = .{ .string = node.name } },
        .{ .key = "unique_id", .value = .{ .string = node.unique_id } },
        .{ .key = "resource_type", .value = .{ .string = node.resource_type } },
        .{ .key = "language", .value = .{ .string = node.language } },
        .{ .key = "refs", .value = .{ .list = refs } },
        .{ .key = "sources", .value = .{ .list = sources } },
        .{ .key = "package_name", .value = .{ .string = node.package_name } },
        .{ .key = "path", .value = .{ .string = node.path } },
        .{ .key = "original_file_path", .value = .{ .string = node.original_file_path } },
        .{ .key = "raw_code", .value = .{ .string = node.raw_code } },
        .{ .key = "fqn", .value = try fqn(allocator, node) },
        .{ .key = "description", .value = .{ .string = node.description } },
        .{ .key = "database", .value = if (compiler.relationDatabaseForNode(graph, node)) |database| .{ .string = database } else .none },
        .{ .key = "schema", .value = .{ .string = try compiler.relationSchemaForNode(allocator, graph, node) } },
        .{ .key = "alias", .value = .{ .string = compiler.relationIdentifierForNode(node) } },
        .{ .key = "config", .value = effective_config },
        .{ .key = "meta", .value = effective_config.attribute("meta") },
        .{ .key = "group", .value = effective_config.attribute("group") },
        .{ .key = "access", .value = effective_config.attribute("access") },
        .{ .key = "contract", .value = try values.toExpression(allocator, try @import("contracts.zig").metadata(allocator, node)) },
        .{ .key = "constraints", .value = try values.toExpression(allocator, try @import("contracts.zig").modelConstraints(allocator, node)) },
        .{ .key = "columns", .value = .{ .object = if (columns.items.len == 0) try expression.allocateEntries(allocator, 0) else try columns.toOwnedSlice(allocator) } },
        .{ .key = "tags", .value = .{ .list = tags } },
        .{ .key = "version", .value = try values.toExpression(allocator, node.version) },
        .{ .key = "latest_version", .value = try values.toExpression(allocator, node.latest_version) },
        .{ .key = "batch", .value = batch_value },
    }) };
    if (node.hook_index) |index| {
        const fields = try allocator.alloc(expression.Entry, result.object.len + 1);
        @memcpy(fields[0..result.object.len], result.object);
        fields[result.object.len] = .{ .key = "index", .value = try expression.integerValue(allocator, index) };
        result = .{ .object = fields };
    }
    return result;
}

fn fqn(allocator: std.mem.Allocator, node: *const types.Node) !Value {
    var parts: std.ArrayList(Value) = .empty;
    try parts.append(allocator, .{ .string = node.package_name });
    const path = @import("util.zig").normalizeForDisplay(node.path);
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) continue;
        const last = segments.peek() == null;
        const stem = if (last) if (std.mem.lastIndexOfScalar(u8, segment, '.')) |dot| segment[0..dot] else segment else segment;
        try parts.append(allocator, .{ .string = if (last and node.version != .null) node.name else stem });
    }
    if (parts.items.len == 1) try parts.append(allocator, .{ .string = node.name });
    if (node.version != .null) try parts.append(allocator, .{ .string = try std.fmt.allocPrint(allocator, "v{s}", .{try values.scalarText(allocator, node.version)}) });
    return .{ .list = try parts.toOwnedSlice(allocator) };
}

pub fn attribute(value: Value, path: []const u8) Value {
    var result = value;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |part| result = result.attribute(part);
    return result;
}

test "model batch and config boundaries expose native UTC datetime methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const graph = types.Graph{ .allocator = allocator, .project_name = "fixture" };
    const node = types.Node{ .package_name = "fixture", .unique_id = "model.fixture.batched", .name = "batched", .path = "batched.sql", .original_file_path = "models/batched.sql", .raw_code = "select 1", .runtime_batch_id = "19700101", .runtime_batch = .{ .start = 0, .end = std.time.ns_per_day } };
    const context = try model(allocator, &graph, &node);
    try std.testing.expectEqualStrings("19700101", attribute(context, "batch.id").string);
    const start = attribute(context, "batch.event_time_start");
    const formatted = (try @import("dbt_context.zig").call(allocator, "duckdb", start.attribute("strftime").callable, &.{.{ .value = .{ .string = "%Y-%m-%d" } }})).?;
    try std.testing.expectEqualStrings("1970-01-01", formatted.string);
    const end = attribute(context, "config.__dbt_internal_microbatch_event_time_end");
    const iso = (try @import("dbt_context.zig").call(allocator, "duckdb", end.attribute("isoformat").callable, &.{})).?;
    try std.testing.expectEqualStrings("1970-01-02T00:00:00+00:00", iso.string);
}
