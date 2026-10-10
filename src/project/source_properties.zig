const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");
const resource = @import("resource_config.zig");
const project_config = @import("project_config.zig");
const properties = @import("properties.zig");
const renderer = @import("config_render.zig");

pub fn parse(runtime: types.Runtime, document: std.json.Value, path: []const u8, package: []const u8, graph: *types.Graph) !void {
    const sources = values.get(document, "sources") orelse return;
    if (sources != .array) return error.InvalidSourceConfiguration;
    var fallback_target: std.json.Value = .null;
    defer values.deinit(runtime.allocator, &fallback_target);
    if (graph.target_context == .null) try values.put(runtime.allocator, &fallback_target, "schema", .{ .string = graph.target_schema });
    var context = renderer.Context{ .runtime = runtime, .vars = graph.vars.items, .target = if (graph.target_context == .null) fallback_target else graph.target_context, .package_name = package };
    for (sources.array.items) |source| {
        const source_name = try string(values.get(source, "name") orelse return error.InvalidSourceConfiguration);
        const tables = values.get(source, "tables") orelse continue;
        if (tables != .array) return error.InvalidSourceConfiguration;
        for (tables.array.items) |table| {
            const table_name = try string(values.get(table, "name") orelse return error.InvalidSourceConfiguration);
            var node = types.SourceDef{
                .package_name = package,
                .source_name = try runtime.allocator.dupe(u8, source_name),
                .table_name = try runtime.allocator.dupe(u8, table_name),
                .unique_id = try std.fmt.allocPrint(runtime.allocator, "source.{s}.{s}.{s}", .{ package, source_name, table_name }),
                .original_file_path = path,
                .properties = try values.clone(runtime.allocator, table),
                .source_properties = try values.clone(runtime.allocator, source),
            };
            errdefer types.deinitSourceDef(runtime.allocator, &node);
            var authored: std.json.Value = .null;
            defer values.deinit(runtime.allocator, &authored);
            try collect(&context, source, &authored);
            try collect(&context, table, &authored);
            // Core combines source/table tags separately, in sorted order; they
            // replace project-level source tags rather than append to them.
            var tag_names: std.ArrayList([]const u8) = .empty;
            defer tag_names.deinit(runtime.allocator);
            try tags(runtime.allocator, values.get(values.get(source, "config") orelse .null, "tags") orelse .null, &tag_names);
            try tags(runtime.allocator, values.get(source, "tags") orelse .null, &tag_names);
            try tags(runtime.allocator, values.get(values.get(table, "config") orelse .null, "tags") orelse .null, &tag_names);
            try tags(runtime.allocator, values.get(table, "tags") orelse .null, &tag_names);
            @import("util.zig").sortStrings(tag_names.items);
            var tag_values = std.json.Array.init(runtime.allocator);
            for (tag_names.items) |tag| try tag_values.append(.{ .string = tag });
            try values.put(runtime.allocator, &authored, "tags", .{ .array = tag_values });
            tag_values.deinit();
            node.raw_config = try values.clone(runtime.allocator, authored);
            for (graph.source_project_configs.items) |config| {
                if (config.package_name.len != 0 and !std.mem.eql(u8, config.package_name, package)) continue;
                if (config.source_name) |name| if (!std.mem.eql(u8, name, source_name)) continue;
                if (config.table_name) |name| if (!std.mem.eql(u8, name, table_name)) continue;
                try merge(runtime.allocator, &node.effective_config, config.values);
                if (config.database) |v| node.database = v;
                if (config.schema_name) |v| node.schema_name = v;
                if (config.identifier) |v| node.identifier = v;
                inline for (.{ "database", "schema", "identifier" }) |key| if (@field(config.quoting, key)) |value| {
                    @field(node.quoting, key) = value;
                };
            }
            if (values.get(authored, "freshness")) |freshness| try values.put(runtime.allocator, &node.effective_config, "freshness", freshness);
            try merge(runtime.allocator, &node.effective_config, authored);
            if (values.get(node.effective_config, "enabled")) |v| node.enabled = try resource.boolean(v);
            if (values.get(node.effective_config, "freshness")) |v| {
                node.freshness = try project_config.freshness(runtime.allocator, v);
                node.freshness_set = true;
            }
            if (values.get(node.effective_config, "loaded_at_field")) |v| node.loaded_at_field = try optionalString(v);
            if (values.get(node.effective_config, "loaded_at_query")) |v| node.loaded_at_query = try optionalString(v);
            if (values.get(node.effective_config, "database")) |v| node.database = try optionalString(v);
            if (values.get(node.effective_config, "schema")) |v| node.schema_name = try optionalString(v);
            if (values.get(node.effective_config, "identifier")) |v| node.identifier = try optionalString(v);
            if (node.database == null) if (values.get(graph.target_context, "database")) |v| {
                node.database = try optionalString(v);
            };
            inline for (.{ "database", "schema", "identifier", "loader" }) |key| {
                if (values.get(table, key) orelse values.get(source, key)) |v| {
                    var rendered = try context.render(v);
                    defer values.deinit(runtime.allocator, &rendered);
                    const text = try optionalString(rendered);
                    if (comptime std.mem.eql(u8, key, "schema")) node.schema_name = if (text) |x| try runtime.allocator.dupe(u8, x) else null else if (comptime std.mem.eql(u8, key, "loader")) node.loader = if (text) |x| try runtime.allocator.dupe(u8, x) else "" else @field(node, key) = if (text) |x| try runtime.allocator.dupe(u8, x) else null;
                }
            }
            if (values.get(table, "description")) |v| node.description = try runtime.allocator.dupe(u8, try string(v));
            if (values.get(source, "description")) |v| node.source_description = try runtime.allocator.dupe(u8, try string(v));
            var quoting: std.json.Value = .null;
            defer values.deinit(runtime.allocator, &quoting);
            if (values.get(source, "quoting")) |v| try values.overlay(runtime.allocator, &quoting, v);
            if (values.get(table, "quoting")) |v| try values.overlay(runtime.allocator, &quoting, v);
            const authored_quoting = try project_config.quoting(quoting);
            inline for (.{ "database", "schema", "identifier", "column" }) |key| if (@field(authored_quoting, key)) |value| {
                @field(node.quoting, key) = value;
            };
            try properties.parseColumnsWithArgumentsProperty(runtime.allocator, values.get(table, "columns") orelse .null, &node.columns, graph.require_generic_test_arguments_property);
            try properties.parseTestsWithArgumentsProperty(runtime.allocator, values.get(table, "data_tests") orelse values.get(table, "tests") orelse .null, &node.tests, graph.require_generic_test_arguments_property);
            try graph.sources.append(runtime.allocator, node);
        }
    }
}

fn collect(context: *renderer.Context, item: std.json.Value, target: *std.json.Value) !void {
    const allocator = context.runtime.allocator;
    const raw_config = values.get(item, "config") orelse .null;
    const raw_field = values.get(item, "loaded_at_field") orelse values.get(raw_config, "loaded_at_field") orelse .null;
    const raw_query = values.get(item, "loaded_at_query") orelse values.get(raw_config, "loaded_at_query") orelse .null;
    if (raw_field != .null and raw_query != .null) return error.InvalidSourceConfiguration;
    var config = try renderConfig(context, raw_config);
    defer values.deinit(allocator, &config);
    try merge(allocator, target, config);
    for ([_][]const u8{ "meta", "tags", "freshness", "loaded_at_field", "loaded_at_query", "enabled", "event_time" }) |key| if (values.get(item, key)) |v| {
        var rendered = if (std.mem.eql(u8, key, "loaded_at_query")) try values.clone(allocator, v) else try context.render(v);
        defer values.deinit(allocator, &rendered);
        if (std.mem.eql(u8, key, "loaded_at_field")) try values.put(allocator, target, "loaded_at_query", .null);
        if (std.mem.eql(u8, key, "freshness")) {
            var merged = if (values.get(target.*, key)) |existing| try values.clone(allocator, existing) else @as(std.json.Value, .null);
            defer values.deinit(allocator, &merged);
            if (rendered == .null) try values.put(allocator, target, key, .null) else {
                try values.overlay(allocator, &merged, rendered);
                try values.put(allocator, target, key, merged);
            }
        } else try resource.mergeField(allocator, target, key, rendered);
    };
}

fn renderConfig(context: *renderer.Context, config: std.json.Value) !std.json.Value {
    if (config == .null) return .null;
    if (config != .object) return error.InvalidSourceConfiguration;
    var rendered: std.json.Value = .null;
    errdefer values.deinit(context.runtime.allocator, &rendered);
    var it = config.object.iterator();
    while (it.next()) |entry| {
        var value = if (std.mem.eql(u8, entry.key_ptr.*, "loaded_at_query")) try values.clone(context.runtime.allocator, entry.value_ptr.*) else try context.render(entry.value_ptr.*);
        defer values.deinit(context.runtime.allocator, &value);
        try values.put(context.runtime.allocator, &rendered, entry.key_ptr.*, value);
    }
    return rendered;
}

fn merge(allocator: std.mem.Allocator, target: *std.json.Value, config: std.json.Value) !void {
    if (config == .null) return;
    if (config != .object) return error.InvalidSourceConfiguration;
    var it = config.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "tags")) {
            try values.put(allocator, target, entry.key_ptr.*, entry.value_ptr.*);
        } else if (std.mem.eql(u8, entry.key_ptr.*, "freshness")) {
            var merged = if (values.get(target.*, "freshness")) |existing| try values.clone(allocator, existing) else @as(std.json.Value, .null);
            defer values.deinit(allocator, &merged);
            if (entry.value_ptr.* == .null) try values.put(allocator, target, "freshness", .null) else {
                try values.overlay(allocator, &merged, entry.value_ptr.*);
                try values.put(allocator, target, "freshness", merged);
            }
        } else try resource.mergeField(allocator, target, entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn tags(allocator: std.mem.Allocator, input: std.json.Value, target: *std.ArrayList([]const u8)) !void {
    if (input == .null) return;
    if (input == .array) {
        for (input.array.items) |item| try tags(allocator, item, target);
        return;
    }
    const name = try string(input);
    for (target.items) |existing| if (std.mem.eql(u8, existing, name)) return;
    try target.append(allocator, name);
}
fn string(value: std.json.Value) ![]const u8 {
    return resource.string(value) catch error.InvalidSourceConfiguration;
}
fn optionalString(value: std.json.Value) !?[]const u8 {
    return if (value == .null) null else try string(value);
}

test "typed source properties preserve inheritance and disable tables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var document = try @import("yaml.zig").parse(allocator,
        \\defaults: &defaults {schema: landing, loaded_at_field: loaded_at, freshness: {warn_after: {count: 4, period: hour}}}
        \\sources:
        \\ - <<: *defaults
        \\   name: raw
        \\   tables:
        \\    - {name: events, freshness: {error_after: {count: 8, period: hour}}, columns: [{name: id, data_type: integer}]}
        \\    - {name: hidden, config: {enabled: false}}
    );
    defer document.deinit();
    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try parse(.{ .allocator = allocator, .io = std.testing.io }, document.value, "models/sources.yml", "demo", &graph);
    try std.testing.expectEqualStrings("landing", graph.sources.items[0].schema_name.?);
    try std.testing.expectEqual(@as(u64, 4), graph.sources.items[0].freshness.?.warn_after.?.count.?);
    try std.testing.expectEqual(@as(u64, 8), graph.sources.items[0].freshness.?.error_after.?.count.?);
    try std.testing.expect(!graph.sources.items[1].enabled);
    try std.testing.expectEqualStrings("integer", values.get(graph.sources.items[0].columns.items[0].properties, "data_type").?.string);
}
