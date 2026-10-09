const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");
const resource = @import("resource_config.zig");
const renderer = @import("config_render.zig");

pub fn parseModels(runtime: types.Runtime, document: std.json.Value, path: []const u8, package: []const u8, graph: *types.Graph) !void {
    inline for (.{ .{ "models", "model" }, .{ "seeds", "seed" }, .{ "analyses", "analysis" } }) |pair| {
        if (values.get(document, pair[0])) |items| {
            if (items != .array) return error.InvalidResourceProperties;
            for (items.array.items) |item| {
                if (item != .object) return error.InvalidResourceProperties;
                var property = types.ModelProperty{ .package_name = package, .resource_type = pair[1], .name = try ownedString(runtime.allocator, values.get(item, "name") orelse return error.InvalidResourceProperties), .patch_path = path, .properties = try values.clone(runtime.allocator, item) };
                if (values.get(item, "description")) |description| property.description = try ownedString(runtime.allocator, description);
                var context = renderer.Context{ .runtime = runtime, .vars = graph.vars.items, .target = graph.target_context, .package_name = package };
                if (values.get(item, "config")) |config| {
                    if (config != .object) return error.InvalidResourceProperties;
                    var it = config.object.iterator();
                    while (it.next()) |entry| {
                        const key = resource.normalizeKey(entry.key_ptr.*);
                        var value = if (std.mem.eql(u8, key, "pre-hook") or std.mem.eql(u8, key, "post-hook")) try values.clone(runtime.allocator, entry.value_ptr.*) else try context.render(entry.value_ptr.*);
                        defer values.deinit(runtime.allocator, &value);
                        try resource.mergeField(runtime.allocator, &property.config_values, key, value);
                    }
                }
                for ([_][]const u8{ "meta", "docs", "tags", "group", "access", "contract" }) |key| {
                    if (values.get(item, key)) |value| try resource.mergeField(runtime.allocator, &property.config_values, key, value);
                }
                try parseTestsWithArgumentsProperty(runtime.allocator, values.get(item, "data_tests") orelse values.get(item, "tests") orelse .null, &property.tests, graph.require_generic_test_arguments_property);
                try parseColumnsWithArgumentsProperty(runtime.allocator, values.get(item, "columns") orelse .null, &property.columns, graph.require_generic_test_arguments_property);
                try graph.model_properties.append(runtime.allocator, property);
            }
        }
    }
}

pub fn parseColumns(allocator: std.mem.Allocator, input: std.json.Value, columns: *std.ArrayList(types.ColumnDef)) !void {
    return parseColumnsWithArgumentsProperty(allocator, input, columns, true);
}

pub fn parseColumnsWithArgumentsProperty(allocator: std.mem.Allocator, input: std.json.Value, columns: *std.ArrayList(types.ColumnDef), nested_arguments: bool) !void {
    if (input == .null) return;
    if (input != .array) return error.InvalidResourceProperties;
    for (input.array.items) |item| {
        const name = values.get(item, "name") orelse return error.InvalidResourceProperties;
        var column = types.ColumnDef{ .name = try ownedString(allocator, name), .properties = try values.clone(allocator, item) };
        if (values.get(item, "description")) |description| column.description = try ownedString(allocator, description);
        try parseTestsWithArgumentsProperty(allocator, values.get(item, "data_tests") orelse values.get(item, "tests") orelse .null, &column.tests, nested_arguments);
        try columns.append(allocator, column);
    }
}

pub fn parseTests(allocator: std.mem.Allocator, input: std.json.Value, tests: *std.ArrayList(types.GenericTestDef)) !void {
    return parseTestsWithArgumentsProperty(allocator, input, tests, true);
}

pub fn parseTestsWithArgumentsProperty(allocator: std.mem.Allocator, input: std.json.Value, tests: *std.ArrayList(types.GenericTestDef), nested_arguments: bool) !void {
    if (input == .null) return;
    if (input != .array) return error.InvalidGenericTestConfiguration;
    for (input.array.items) |item| {
        var name: []const u8 = undefined;
        var definition: std.json.Value = .null;
        if (item == .string) name = item.string else if (item == .object and item.object.count() == 1) {
            name = item.object.keys()[0];
            definition = item.object.values()[0];
            if (definition != .object and definition != .null) return error.InvalidGenericTestConfiguration;
        } else return error.InvalidGenericTestConfiguration;
        var test_def = types.GenericTestDef{ .name = try allocator.dupe(u8, name) };
        if (if (nested_arguments) values.get(definition, "arguments") else null) |args| {
            if (args != .object) return error.InvalidGenericTestConfiguration;
            test_def.arguments = try values.clone(allocator, args);
        } else if (definition == .object) {
            var it = definition.object.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "config") or std.mem.eql(u8, entry.key_ptr.*, "name") or std.mem.eql(u8, entry.key_ptr.*, "description")) continue;
                try values.put(allocator, &test_def.arguments, entry.key_ptr.*, entry.value_ptr.*);
            }
        }
        if (values.get(test_def.arguments, "column_name")) |v| test_def.column_name = try resource.string(v);
        if (values.get(test_def.arguments, "quote")) |v| test_def.accepted_values_quote = try resource.boolean(v);
        if (values.get(test_def.arguments, "field")) |v| test_def.relationship_field = try resource.string(v);
        if (values.get(test_def.arguments, "to")) |v| test_def.relationship_to = try resource.string(v);
        if (values.get(test_def.arguments, "values")) |items| {
            if (items != .array) return error.InvalidGenericTestConfiguration;
            for (items.array.items) |value| try test_def.accepted_values.append(allocator, try values.scalarText(allocator, value));
        }
        if (values.get(definition, "config")) |config| try parseTestConfig(allocator, config, &test_def.config);
        try tests.append(allocator, test_def);
    }
}

pub fn parseTestConfig(allocator: std.mem.Allocator, config: std.json.Value, target: *types.GenericTestConfig) !void {
    if (config == .null) return;
    if (config != .object) return error.InvalidGenericTestConfiguration;
    if (values.get(config, "where")) |value| target.where = if (value == .null) null else try ownedString(allocator, value);
    if (values.get(config, "limit")) |value| {
        if (value != .integer or value.integer < 0) return error.InvalidGenericTestConfiguration;
        target.limit = @intCast(value.integer);
    }
    if (values.get(config, "severity")) |value| target.severity = try ownedString(allocator, value);
    if (values.get(config, "warn_if")) |value| target.warn_if = try ownedString(allocator, value);
    if (values.get(config, "error_if")) |value| target.error_if = try ownedString(allocator, value);
    if (values.get(config, "store_failures")) |value| target.store_failures = if (value == .null) null else try resource.boolean(value);
    inline for (std.meta.tags(types.GenericTestConfigField)) |key| {
        if (values.get(config, @tagName(key)) != null) target.markConfigured(key);
    }
}

fn ownedString(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return try allocator.dupe(u8, try resource.string(value));
}

test "typed properties retain nested test arguments and complete column definitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var document = try @import("yaml.zig").parse(allocator,
        \\models:
        \\  - name: orders
        \\    config: {meta: {nested: [1, true]}, contract: {enforced: true}}
        \\    columns:
        \\      - {name: id, data_type: integer, constraints: [{type: not_null}]}
        \\    data_tests:
        \\      - custom: {arguments: {options: {nested: [1, false]}, threshold: 3}}
    );
    defer document.deinit();
    var graph = types.Graph{ .allocator = allocator, .project_name = "demo", .require_generic_test_arguments_property = true };
    defer graph.deinit();
    try parseModels(.{ .allocator = allocator, .io = std.testing.io }, document.value, "models/schema.yml", "demo", &graph);
    const property = graph.model_properties.items[0];
    try std.testing.expectEqualStrings("integer", values.get(property.columns.items[0].properties, "data_type").?.string);
    try std.testing.expectEqual(@as(i64, 3), values.get(property.tests.items[0].arguments, "threshold").?.integer);
    try std.testing.expect(!values.get(values.get(property.tests.items[0].arguments, "options").?, "nested").?.array.items[1].bool);
}

test "generic argument nesting respects the Core project flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var document = try @import("yaml.zig").parse(allocator, "[{custom: {arguments: {threshold: 3}}}]");
    defer document.deinit();
    var legacy: std.ArrayList(types.GenericTestDef) = .empty;
    var modern: std.ArrayList(types.GenericTestDef) = .empty;
    try parseTestsWithArgumentsProperty(allocator, document.value, &legacy, false);
    try parseTestsWithArgumentsProperty(allocator, document.value, &modern, true);
    try std.testing.expect(values.get(legacy.items[0].arguments, "threshold") == null);
    try std.testing.expectEqual(@as(i64, 3), values.get(values.get(legacy.items[0].arguments, "arguments").?, "threshold").?.integer);
    try std.testing.expectEqual(@as(i64, 3), values.get(modern.items[0].arguments, "threshold").?.integer);
}
