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
    if (std.mem.eql(u8, node.resource_type, "test")) if (try @import("manifest.zig").testContextNode(allocator, graph, node)) |raw_metadata| {
        var metadata = raw_metadata;
        defer values.deinit(allocator, &metadata);
        if (node.compiled_code) |sql| try values.put(allocator, &metadata, "compiled_sql", .{ .string = sql });
        // ModelContext uses to_dict(omit_none=True), including nested configs.
        return try resourceContextValue(allocator, metadata);
    };
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
    if (std.mem.eql(u8, node.resource_type, "seed")) if (node.project_root) |path| {
        const fields = try allocator.alloc(expression.Entry, result.object.len + 1);
        @memcpy(fields[0..result.object.len], result.object);
        fields[result.object.len] = .{ .key = "root_path", .value = .{ .string = path } };
        result = .{ .object = fields };
    };
    if (node.compiled_code) |sql| {
        const fields = try allocator.alloc(expression.Entry, result.object.len + 3);
        @memcpy(fields[0..result.object.len], result.object);
        fields[result.object.len] = .{ .key = "compiled", .value = .{ .boolean = node.compiled } };
        fields[result.object.len + 1] = .{ .key = "compiled_code", .value = .{ .string = sql } };
        fields[result.object.len + 2] = .{ .key = "compiled_sql", .value = .{ .string = sql } };
        result = .{ .object = fields };
    }
    if (node.compiled_path) |path| {
        const fields = try allocator.alloc(expression.Entry, result.object.len + 1);
        @memcpy(fields[0..result.object.len], result.object);
        fields[result.object.len] = .{ .key = "compiled_path", .value = .{ .string = path } };
        result = .{ .object = fields };
    }
    if (node.build_path) |path| {
        const fields = try allocator.alloc(expression.Entry, result.object.len + 1);
        @memcpy(fields[0..result.object.len], result.object);
        fields[result.object.len] = .{ .key = "build_path", .value = .{ .string = path } };
        result = .{ .object = fields };
    }
    return result;
}

/// Core omits None dataclass fields, while arbitrary dictionaries (meta,
/// generic kwargs and config extras) retain their authored null values.
pub fn resourceContextValue(allocator: std.mem.Allocator, raw: std.json.Value) !Value {
    if (raw != .object) return metadataValue(allocator, raw);
    const resource = values.get(raw, "resource_type") orelse std.json.Value{ .string = "model" };
    var config_fields = try @import("canonical_manifest_config.zig").defaults(allocator, if (resource == .string) resource.string else "model");
    defer values.deinit(allocator, &config_fields);
    var entries: std.ArrayList(expression.Entry) = .empty;
    var iterator = raw.object.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* == .null) continue;
        const key = entry.key_ptr.*;
        const value = if (std.mem.eql(u8, key, "config"))
            try dataclassContextValue(allocator, entry.value_ptr.*, config_fields)
        else if (std.mem.eql(u8, key, "refs"))
            try refArgsContextValue(allocator, entry.value_ptr.*)
        else if (std.mem.eql(u8, key, "docs") or std.mem.eql(u8, key, "contract") or std.mem.eql(u8, key, "checksum") or std.mem.eql(u8, key, "test_metadata"))
            try dataclassContextValue(allocator, entry.value_ptr.*, null)
        else
            try metadataValue(allocator, entry.value_ptr.*);
        try entries.append(allocator, .{ .key = try allocator.dupe(u8, key), .value = value });
    }
    return .{ .object = try entries.toOwnedSlice(allocator) };
}

fn refArgsContextValue(allocator: std.mem.Allocator, raw: std.json.Value) !Value {
    if (raw != .array) return metadataValue(allocator, raw);
    const refs = try expression.allocateValues(allocator, raw.array.items.len);
    for (raw.array.items, refs) |ref, *value| value.* = try dataclassContextValue(allocator, ref, null);
    return .{ .list = refs };
}

fn dataclassContextValue(allocator: std.mem.Allocator, raw: std.json.Value, declared: ?std.json.Value) !Value {
    if (raw != .object) return metadataValue(allocator, raw);
    var entries: std.ArrayList(expression.Entry) = .empty;
    var iterator = raw.object.iterator();
    while (iterator.next()) |entry| {
        const known = if (declared) |fields| fields.object.contains(entry.key_ptr.*) else true;
        if (known and entry.value_ptr.* == .null) continue;
        try entries.append(allocator, .{ .key = try allocator.dupe(u8, entry.key_ptr.*), .value = try metadataValue(allocator, entry.value_ptr.*) });
    }
    return .{ .object = try entries.toOwnedSlice(allocator) };
}

// The parsed JSON projection is released before the context is evaluated.
// Own strings/keys while retaining every authored value in arbitrary mappings.
fn metadataValue(allocator: std.mem.Allocator, raw: std.json.Value) anyerror!Value {
    return switch (raw) {
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .object => |object| blk: {
            const entries = try expression.allocateEntries(allocator, object.count());
            var iterator = object.iterator();
            for (entries) |*entry| {
                const item = iterator.next().?;
                entry.* = .{ .key = try allocator.dupe(u8, item.key_ptr.*), .value = try metadataValue(allocator, item.value_ptr.*) };
            }
            break :blk .{ .object = entries };
        },
        .array => |array| blk: {
            const items = try expression.allocateValues(allocator, array.items.len);
            for (array.items, items) |item, *value| value.* = try metadataValue(allocator, item);
            break :blk .{ .list = items };
        },
        else => try values.toExpression(allocator, raw),
    };
}

test "runtime tests preserve authored metadata and canonical compiled SQL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph = types.Graph{ .allocator = a, .project_name = "fixture" };
    try graph.singular_tests.append(a, .{ .package_name = "fixture", .unique_id = "test.fixture.check", .name = "check", .alias = "check", .path = "check.sql", .original_file_path = "tests/check.sql", .raw_code = "select {{ ref('input') }}", .description = "Authored test" });
    try graph.singular_tests.items[0].tags.append(a, "runtime");
    const node = types.Node{ .resource_type = "test", .package_name = "fixture", .unique_id = "test.fixture.check", .name = "check", .path = "check.sql", .original_file_path = "tests/check.sql", .raw_code = "select {{ ref('input') }}", .compiled = true, .compiled_code = "select 1" };
    const context = try model(a, &graph, &node);
    try std.testing.expectEqualStrings("Authored test", context.attribute("description").string);
    try std.testing.expectEqualStrings("runtime", context.attribute("tags").list[0].string);
    try std.testing.expectEqualStrings("select 1", context.attribute("compiled_code").string);
    try std.testing.expectEqualStrings("select 1", context.attribute("compiled_sql").string);
    try std.testing.expect(context.attribute("compiled").boolean);
    try std.testing.expect(context.attribute("config").attribute("limit") == .undefined);
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

test "resource context omits dataclass None while preserving arbitrary metadata and config extras" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try std.json.parseFromSlice(std.json.Value, a,
        \\{"resource_type":"test","database":null,"meta":{"nullable":null},"docs":{"show":true,"node_color":null},"contract":{"enforced":false,"checksum":null},"config":{"database":null,"custom_null":null,"meta":{"nullable":null},"docs":{"node_color":null}},"test_metadata":{"namespace":null,"kwargs":{"payload":{"nullable":null}}}}
    , .{});
    const context = try resourceContextValue(a, raw.value);
    try std.testing.expect(context.attribute("database") == .undefined);
    try std.testing.expect(context.attribute("meta").attribute("nullable") == .none);
    try std.testing.expect(context.attribute("docs").attribute("node_color") == .undefined);
    try std.testing.expect(context.attribute("contract").attribute("checksum") == .undefined);
    try std.testing.expect(context.attribute("config").attribute("database") == .undefined);
    try std.testing.expect(context.attribute("config").attribute("custom_null") == .none);
    try std.testing.expect(context.attribute("config").attribute("docs").attribute("node_color") == .none);
    try std.testing.expect(context.attribute("test_metadata").attribute("namespace") == .undefined);
    try std.testing.expect(context.attribute("test_metadata").attribute("kwargs").attribute("payload").attribute("nullable") == .none);
}

test "runtime RefArgs omit dataclass nulls while raw refs and arbitrary kwargs retain them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try std.json.parseFromSlice(std.json.Value, a,
        \\{"resource_type":"test","refs":[{"name":"input","package":null,"version":null},{"name":"versioned","package":"dependency","version":2}],"meta":{"package":null},"test_metadata":{"kwargs":{"payload":{"package":null,"version":null}}}}
    , .{});
    const context = try resourceContextValue(a, raw.value);
    const refs = context.attribute("refs").list;
    try std.testing.expectEqual(@as(usize, 2), refs.len);
    try std.testing.expectEqualStrings("input", refs[0].attribute("name").string);
    try std.testing.expect(refs[0].attribute("package") == .undefined);
    try std.testing.expect(refs[0].attribute("version") == .undefined);
    try std.testing.expectEqualStrings("dependency", refs[1].attribute("package").string);
    try std.testing.expectEqualStrings("2", refs[1].attribute("version").integer);
    try std.testing.expect(context.attribute("meta").attribute("package") == .none);
    const payload = context.attribute("test_metadata").attribute("kwargs").attribute("payload");
    try std.testing.expect(payload.attribute("package") == .none);
    try std.testing.expect(payload.attribute("version") == .none);
    try std.testing.expect(raw.value.object.get("refs").?.array.items[0].object.get("package").? == .null);
    try std.testing.expect(raw.value.object.get("refs").?.array.items[0].object.get("version").? == .null);
}
