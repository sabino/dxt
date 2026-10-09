const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const snapshot = @import("snapshot.zig");
const fs = @import("fs.zig");
const json = @import("json.zig");
const compiler = @import("compiler.zig");
const Value = std.json.Value;
const yaml_document = @import("yaml.zig");
const config_value = @import("config_value.zig");
const config_render = @import("config_render.zig");
const resource_config = @import("resource_config.zig");
const properties_reader = @import("properties.zig");

pub fn section(allocator: std.mem.Allocator, text: []const u8) !?Value {
    var document = try yaml_document.parse(allocator, text);
    defer document.deinit();
    if (document.value == .null) return null;
    if (document.value != .object) return error.UnsupportedSnapshotYaml;
    return if (document.value.object.get("snapshots")) |value| try config_value.clone(allocator, value) else null;
}

fn stringValue(value: Value) ![]const u8 {
    return if (value == .string) value.string else error.UnsupportedSnapshotYaml;
}

pub fn parseProperties(runtime: types.Runtime, text: []const u8, resource_root: []const u8, path: []const u8, package_name: []const u8, graph: *types.Graph) !void {
    const allocator = runtime.allocator;
    const value = (try section(allocator, text)) orelse return;
    if (value == .null) return;
    if (value != .array) return error.UnsupportedSnapshotYaml;
    for (value.array.items) |entry| {
        if (entry != .object) return error.UnsupportedSnapshotYaml;
        var context = config_render.Context{ .runtime = runtime, .vars = graph.vars.items, .target = graph.target_context, .package_name = package_name };
        const name_value = try context.render(entry.object.get("name") orelse return error.UnsupportedSnapshotYaml);
        const name = try stringValue(name_value);
        for (graph.snapshot_properties.items) |previous| {
            if (std.mem.eql(u8, previous.package_name, package_name) and std.mem.eql(u8, previous.name, name)) return error.DuplicateSnapshotPatch;
        }
        var rendered = try config_value.clone(allocator, entry);
        if (entry.object.get("config")) |config| {
            var resolved = try context.render(config);
            defer config_value.deinit(allocator, &resolved);
            try config_value.put(allocator, &rendered, "config", resolved);
        }
        inline for (.{ "meta", "tags", "docs" }) |key| {
            if (entry.object.get(key)) |value_to_render| {
                var resolved = try context.render(value_to_render);
                defer config_value.deinit(allocator, &resolved);
                try config_value.put(allocator, &rendered, key, resolved);
            }
        }
        if (entry.object.get("columns")) |columns| {
            if (columns != .array) return error.UnsupportedSnapshotYaml;
            var resolved_columns = std.json.Array.init(allocator);
            for (columns.array.items) |column| {
                if (column != .object) return error.UnsupportedSnapshotYaml;
                var resolved_column = try config_value.clone(allocator, column);
                inline for (.{ "name", "data_type", "meta", "tags", "quote", "config", "constraints" }) |key| {
                    if (column.object.get(key)) |value_to_render| {
                        var resolved = try context.render(value_to_render);
                        defer config_value.deinit(allocator, &resolved);
                        try config_value.put(allocator, &resolved_column, key, resolved);
                    }
                }
                try resolved_columns.append(resolved_column);
            }
            try config_value.put(allocator, &rendered, "columns", .{ .array = resolved_columns });
        }
        try graph.snapshot_properties.append(allocator, .{ .package_name = package_name, .name = name, .path = path, .config_args = "", .properties = rendered });
        var property = types.ModelProperty{ .package_name = package_name, .resource_type = "snapshot", .name = name, .patch_path = path, .properties = try config_value.clone(allocator, entry), .config_values = try config_value.clone(allocator, rendered.object.get("config") orelse .null) };
        if (entry.object.get("description")) |description| property.description = try stringValue(description);
        inline for (.{ "meta", "tags", "docs" }) |key| {
            if (rendered.object.get(key)) |metadata| try resource_config.mergeField(allocator, &property.config_values, key, metadata);
        }
        try properties_reader.parseTestsWithArgumentsProperty(allocator, entry.object.get("data_tests") orelse entry.object.get("tests") orelse .null, &property.tests, graph.require_generic_test_arguments_property);
        try properties_reader.parseColumnsWithArgumentsProperty(allocator, rendered.object.get("columns") orelse .null, &property.columns, graph.require_generic_test_arguments_property);
        try graph.model_properties.append(allocator, property);
        if (entry.object.get("relation")) |relation_value| {
            const relation = try stringValue(relation_value);
            const body = try std.fmt.allocPrint(allocator, "select * from {{{{ {s} }}}}", .{relation});
            const relative = fs.relativeUnderResourcePath(path, resource_root);
            const dir = std.fs.path.dirname(relative) orelse "";
            const yaml_path = try std.fmt.allocPrint(allocator, "{s}/{s}.sql", .{ relative, name });
            const fqn_path = if (dir.len == 0) try std.fmt.allocPrint(allocator, "{s}.sql", .{name}) else try fs.pathJoin(allocator, &.{ dir, try std.fmt.allocPrint(allocator, "{s}.sql", .{name}) });
            var node = types.Node{ .resource_type = "snapshot", .package_name = package_name, .name = name, .unique_id = try std.fmt.allocPrint(allocator, "snapshot.{s}.{s}", .{ package_name, name }), .path = yaml_path, .original_file_path = path, .raw_code = body, .snapshot_file_code = text, .snapshot_fqn_path = fqn_path, .snapshot_yaml_definition = true, .materialized = "snapshot", .snapshot_config = .{} };
            // Core's YAML relation definitions use statically_parse_ref_or_source;
            // the legacy SQL body retains the complete native Jinja context.
            try snapshot.scanBody(allocator, body, &node);
            try graph.nodes.append(allocator, node);
        }
    }
}

pub fn finalize(runtime: types.Runtime, graph: *types.Graph) !void {
    _ = runtime;
    for (graph.nodes.items) |*node| {
        if (node.snapshot_config == null) continue;
        for (graph.snapshot_properties.items) |patch| {
            if (!std.mem.eql(u8, patch.package_name, node.package_name) or !std.mem.eql(u8, patch.name, node.name)) continue;
            try resource_config.mergeAuthored(graph.allocator, &node.property_config, patch.properties.object.get("config") orelse .null);
            inline for (.{ "tags", "docs", "meta" }) |key| {
                if (patch.properties.object.get(key)) |value| try resource_config.mergeField(graph.allocator, &node.property_config, key, value);
            }
            try applyMetadata(graph, node, patch.properties);
            node.patch_path = patch.path;
        }
        try resource_config.rebuild(graph.allocator, node);
        try snapshot.validateConfig(node);
    }
}

fn applyMetadata(graph: *types.Graph, node: *types.Node, properties: Value) !void {
    if (properties.object.get("description")) |description| {
        const text = try stringValue(description);
        if (std.mem.indexOf(u8, text, "{{") == null) node.description = text;
    }
    const config = properties.object.get("config") orelse .null;
    const docs = properties.object.get("docs") orelse if (config == .object) config.object.get("docs") orelse .null else .null;
    if (docs == .object) {
        node.docs.configured = true;
        if (docs.object.get("show")) |value| node.docs.show = if (value == .bool) value.bool else return error.UnsupportedSnapshotYaml;
        if (docs.object.get("node_color")) |value| node.docs.node_color = if (value == .null) null else try stringValue(value);
    }
    const meta = properties.object.get("meta") orelse if (config == .object) config.object.get("meta") orelse .null else .null;
    if (meta == .object) {
        var merged = if (node.snapshot_meta_json) |old| old.object else std.json.ObjectMap{};
        var entries = meta.object.iterator();
        while (entries.next()) |entry| try merged.put(graph.allocator, entry.key_ptr.*, entry.value_ptr.*);
        node.snapshot_meta_json = .{ .object = merged };
    }
    if (properties.object.get("columns")) |columns| {
        if (columns != .array) return error.UnsupportedSnapshotYaml;
        for (columns.array.items) |column| {
            if (column != .object) return error.UnsupportedSnapshotYaml;
            const name = try stringValue(column.object.get("name") orelse return error.UnsupportedSnapshotYaml);
            for (node.columns.items) |*existing| {
                if (!std.mem.eql(u8, existing.name, name)) continue;
                if (column.object.get("description")) |value| {
                    const text = try stringValue(value);
                    if (std.mem.indexOf(u8, text, "{{") == null) existing.description = text;
                }
                if (column.object.get("data_type")) |value| existing.data_type = if (value == .null) null else try stringValue(value);
                if (column.object.get("quote")) |value| existing.quote = if (value == .null) null else if (value == .bool) value.bool else return error.UnsupportedSnapshotYaml;
                const column_config = column.object.get("config") orelse .null;
                if (column_config != .null and column_config != .object) return error.UnsupportedSnapshotYaml;
                var resolved_config = if (column_config == .object) column_config.object else std.json.ObjectMap{};
                if (!resolved_config.contains("meta")) try resolved_config.put(graph.allocator, "meta", .{ .object = .{} });
                if (!resolved_config.contains("tags")) try resolved_config.put(graph.allocator, "tags", .{ .array = std.array_list.Managed(Value).init(graph.allocator) });
                existing.config_json = .{ .object = resolved_config };
                if (column.object.get("meta")) |value| existing.meta_json = value;
                if (column.object.get("tags")) |value| {
                    if (value == .string) try util.appendUnique(graph.allocator, &existing.tags, value.string) else if (value == .array) {
                        for (value.array.items) |tag| try util.appendUnique(graph.allocator, &existing.tags, try stringValue(tag));
                    } else return error.UnsupportedSnapshotYaml;
                }
            }
        }
    }
}

test "snapshot YAML reads nested maps flow lists and relation definitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var graph = types.Graph{ .allocator = arena.allocator(), .project_name = "demo" };
    defer graph.deinit();
    const yaml = "version: 2\nsnapshots:\n  - name: history\n    relation: ref('base')\n    description: |-\n      Stored history\n      across runs\n    config:\n      strategy: check\n      unique_key: [id, region]\n      check_cols: all\n      snapshot_meta_column_names: {dbt_valid_from: valid_from}\n";
    try parseProperties(.{ .allocator = graph.allocator, .io = std.testing.io }, yaml, "snapshots", "snapshots/nested/definitions.yml", "demo", &graph);
    try compiler.scanDependencies(graph.allocator, graph.nodes.items[0].raw_code, &graph.nodes.items[0], &graph);
    try finalize(.{ .allocator = graph.allocator, .io = std.testing.io }, &graph);
    const node = graph.nodes.items[0];
    try std.testing.expectEqualStrings("nested/history.sql", node.snapshot_fqn_path.?);
    try std.testing.expectEqualStrings("base", node.refs.items[0].name);
    try std.testing.expectEqualStrings("Stored history\nacross runs", node.description);
    try std.testing.expectEqual(@as(usize, 2), node.snapshot_config.?.unique_key.?.list.items.len);
}

test "snapshot YAML block scalar folding chomping blank lines and literal comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const value = (try section(arena.allocator(), "snapshots:\n  - name: history\n    description: >-\n      first line\n      second line\n\n      next paragraph\n    literal: |+\n      # preserved comment\n\n      final line\n\n    config: {}\n")).?;
    const entry = value.array.items[0].object;
    try std.testing.expectEqualStrings("first line second line\nnext paragraph", entry.get("description").?.string);
    try std.testing.expectEqualStrings("# preserved comment\n\nfinal line\n\n", entry.get("literal").?.string);
}

pub fn rejectRelationCollisions(graph: *const types.Graph) !void {
    for (graph.nodes.items, 0..) |node, index| {
        if (!node.enabled or node.snapshot_config == null) continue;
        const database = compiler.relationDatabaseForNode(graph, &node);
        const schema = try compiler.relationSchemaForNode(graph.allocator, graph, &node);
        const identifier = compiler.relationIdentifierForNode(&node);
        for (graph.nodes.items, 0..) |other, other_index| {
            if (other_index == index or !other.enabled) continue;
            if (!std.mem.eql(u8, other.resource_type, "model") and !std.mem.eql(u8, other.resource_type, "seed") and other.snapshot_config == null) continue;
            if (std.mem.eql(u8, other.materialized, "ephemeral")) continue;
            var relation_probe = other;
            if (relation_probe.snapshot_config == null) relation_probe.snapshot_config = .{};
            const other_database = compiler.relationDatabaseForNode(graph, &relation_probe);
            if ((database == null) != (other_database == null)) continue;
            if (database != null and !std.mem.eql(u8, database.?, other_database.?)) continue;
            const other_schema = try compiler.relationSchemaForNode(graph.allocator, graph, &other);
            if (std.mem.eql(u8, schema, other_schema) and std.mem.eql(u8, identifier, compiler.relationIdentifierForNode(&other))) return error.SnapshotRelationCollision;
        }
    }
}
