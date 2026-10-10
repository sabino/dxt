//! Schema data tests have their own YAML FQN and config hierarchy. Preserve
//! typed authored values separately from effective project and macro configs.
const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");
const Json = std.json.Value;
const legacy = [_][]const u8{ "severity", "tags", "enabled", "where", "limit", "warn_if", "error_if", "fail_calc", "store_failures", "store_failures_as", "meta", "database", "schema", "alias" };

pub fn containsJinja(value: Json) bool {
    switch (value) {
        .string => |text| return std.mem.indexOf(u8, text, "{{") != null or std.mem.indexOf(u8, text, "{%") != null,
        .array => |array| for (array.items) |item| {
            if (containsJinja(item)) return true;
        },
        .object => |object| for (object.values()) |item| {
            if (containsJinja(item)) return true;
        },
        else => {},
    }
    return false;
}

/// Core's legacy configuration keys are popped before argument identity is
/// hashed. A truthy duplicate is rejected; a false/empty legacy value yields
/// to its nested replacement. Remaining config keys retain their JSON types.
pub fn extract(a: std.mem.Allocator, definition: Json, test_def: *types.GenericTestDef) !void {
    var nested = try values.clone(a, values.get(definition, "config") orelse .{ .object = .empty });
    defer values.deinit(a, &nested);
    if (nested != .object) return error.InvalidGenericTestConfiguration;
    for (legacy) |key| {
        var authored = values.get(test_def.arguments, key) orelse .null;
        if (truthy(authored) and values.get(nested, key) != null) return error.DuplicateGenericTestConfiguration;
        if (!truthy(authored)) authored = values.get(nested, key) orelse authored;
        if (authored != .null) try values.put(a, &test_def.config_values, key, authored);
        remove(a, &test_def.arguments, key);
        remove(a, &nested, key);
    }
    if (nested == .object) for (nested.object.keys(), nested.object.values()) |key, value| if (value != .null) {
        try values.put(a, &test_def.config_values, key, value);
    };
    if (values.get(definition, "name")) |name| {
        if (name != .string) return error.InvalidGenericTestConfiguration;
        test_def.custom_name = try a.dupe(u8, name.string);
    }
    if (values.get(definition, "description")) |description| {
        if (description != .string) return error.InvalidGenericTestConfiguration;
        test_def.description = try a.dupe(u8, description.string);
    }
    if (values.get(test_def.arguments, "model") != null) return error.InvalidGenericTestConfiguration;
}
fn truthy(value: Json) bool {
    return switch (value) {
        .null => false,
        .bool => |v| v,
        .string => |v| v.len != 0,
        .integer => |v| v != 0,
        .float => |v| v != 0,
        .array => |v| v.items.len != 0,
        .object => |v| v.count() != 0,
        .number_string => |v| !std.mem.eql(u8, v, "0"),
    };
}
fn remove(a: std.mem.Allocator, object: *Json, key: []const u8) void {
    if (object.* != .object) return;
    const entry = object.object.fetchOrderedRemove(key) orelse return;
    a.free(entry.key);
    var value = entry.value;
    values.deinit(a, &value);
}

pub fn finalize(runtime: types.Runtime, graph: *types.Graph) !void {
    for (graph.tests.items) |*node| try apply(runtime, graph, node);
    for (graph.tests.items, 0..) |node, index| {
        if (node.disabled) continue;
        for (graph.tests.items[0..index]) |prior| if (!prior.disabled and equal(prior.unique_id, node.unique_id)) return error.DuplicateGenericTestNode;
    }
}

pub fn apply(runtime: types.Runtime, graph: *const types.Graph, node: *types.GenericTestNode) !void {
    const a = runtime.allocator;
    try node.fqn.append(a, node.package_name);
    var parts = std.mem.tokenizeAny(u8, node.original_file_path, "/\\");
    _ = parts.next();
    while (parts.next()) |part| if (parts.peek() != null) {
        try node.fqn.append(a, part);
    };
    try node.fqn.append(a, node.name);
    var renderer = @import("config_render.zig").Context{ .runtime = runtime, .vars = graph.vars.items, .target = graph.target_context, .package_name = node.package_name };
    var authored: Json = .{ .object = .empty };
    var owns_authored = true;
    errdefer if (owns_authored) values.deinit(a, &authored);
    if (node.builder_config == .object) for (node.builder_config.object.keys(), node.builder_config.object.values()) |key, value| {
        var rendered = if (value == .string) try renderer.render(value) else try values.clone(a, value);
        defer values.deinit(a, &rendered);
        if (rendered != .null) try values.put(a, &authored, key, rendered);
    };
    // Synthesized long names add an alias config call after authored settings.
    if (std.mem.indexOf(u8, node.raw_code, "{{ config(alias=") != null and values.get(authored, "alias") == null) try values.put(a, &authored, "alias", .{ .string = node.alias });
    values.deinit(a, &node.builder_config);
    node.builder_config = authored;
    owns_authored = false;
    var config = try @import("canonical_manifest_config.zig").defaults(a, "test");
    errdefer values.deinit(a, &config);
    var unrendered: Json = .{ .object = .empty };
    errdefer values.deinit(a, &unrendered);
    try projectConfig(a, graph, node, node.package_name, &config, &unrendered);
    // Macro config calls are added here by parse-time native rendering. The
    // authored builder config follows the macro call, matching raw_code order.
    try parseMacro(a, graph, node, &config, &unrendered);
    if (!equal(node.package_name, graph.project_name)) try projectConfig(a, graph, node, graph.project_name, &config, &unrendered);
    try validate(config);
    node.config = .{};
    try @import("properties.zig").parseTestConfig(a, config, &node.config);
    node.enabled = values.get(config, "enabled").?.bool;
    node.disabled = !node.enabled;
    if (!node.enabled) node.depends_on.clearRetainingCapacity();
    const tags = values.get(authored, "tags") orelse .null;
    try appendTags(a, &node.tags, tags, true);
    std.mem.sort([]const u8, node.tags.items, {}, less);
    // Deduplicate the initial sorted column/builder tags, then append project
    // and macro tags in their effective config order.
    var n: usize = 0;
    for (node.tags.items) |tag| {
        if (n != 0 and equal(node.tags.items[n - 1], tag)) continue;
        node.tags.items[n] = tag;
        n += 1;
    }
    node.tags.items.len = n;
    try appendTags(a, &node.tags, values.get(config, "tags").?, true);
    try appendTags(a, &node.config_tags, values.get(config, "tags").?, false);
    node.alias = node.config.alias orelse node.alias;
    node.config_values = config;
    node.unrendered_config = unrendered;
    config = .null;
    unrendered = .null;
    const raw_code = try rawCode(a, node);
    a.free(node.raw_code);
    node.raw_code = raw_code;
}
fn parseMacro(a: std.mem.Allocator, graph: *const types.Graph, node: *types.GenericTestNode, config: *Json, unrendered: *Json) !void {
    // Core's two internal shortcuts do not render the macros at parse time.
    if (node.macro_depends_on.items.len != 0 and (equal(node.macro_depends_on.items[0], "macro.dbt.test_not_null") or equal(node.macro_depends_on.items[0], "macro.dbt.test_unique"))) {
        try merge(a, config, node.builder_config);
        try values.overlay(a, unrendered, node.builder_config);
        return;
    }
    var probe = types.Node{ .resource_type = "test", .materialized = "test", .package_name = node.package_name, .name = node.name, .unique_id = node.unique_id, .path = node.path, .original_file_path = node.original_file_path, .raw_code = node.raw_code, .effective_config = try values.clone(a, config.*) };
    defer types.deinitNode(a, &probe);
    try merge(a, &probe.effective_config, node.builder_config);
    try @import("properties.zig").parseTestConfig(a, probe.effective_config, &probe.test_config);
    var args: std.ArrayList(@import("expression.zig").Argument) = .empty;
    defer args.deinit(a);
    if (node.arguments == .object) for (node.arguments.object.keys(), node.arguments.object.values()) |key, value| {
        if (equal(key, "column_name") or equal(key, "model")) continue;
        try args.append(a, .{ .name = key, .value = try @import("compiler.zig").parseGenericArgumentValue(a, graph, &probe, value) });
    };
    if (node.argument_column_name orelse node.column_name) |column| try args.append(a, .{ .name = "column_name", .value = .{ .string = column } });
    const model_kwarg = if (node.unattached_model_kwarg) |kwarg| try a.dupe(u8, kwarg) else if (node.attached_node) |attached| model: {
        for (graph.nodes.items) |*parent| if (equal(parent.unique_id, attached)) break :model try @import("model_versions.zig").modelKwarg(a, parent);
        return error.UnresolvedRef;
    } else source: {
        const parent = node.attached_source orelse return error.UnresolvedSource;
        break :source try std.fmt.allocPrint(a, "{{{{ get_where_subquery(source('{s}', '{s}')) }}}}", .{ parent.source_name, parent.table_name });
    };
    defer a.free(model_kwarg);
    try args.append(a, .{ .name = "model", .value = try @import("compiler.zig").parseGenericArgumentValue(a, graph, &probe, .{ .string = model_kwarg }) });
    // TestMacroNamespace exposes only seeded macros and their dependencies.
    // A namespaced call outside that set is capture-undefined at parse time;
    // its arguments still collect refs, but its body/config is not executed.
    const macro_name = if (node.macro_depends_on.items.len != 0 and std.mem.startsWith(u8, node.macro_depends_on.items[0], "macro."))
        try a.dupe(u8, node.macro_depends_on.items[0]["macro.".len..])
    else if (node.test_namespace) |namespace|
        try std.fmt.allocPrint(a, "{s}.test_{s}", .{ namespace, node.test_name })
    else
        try std.fmt.allocPrint(a, "test_{s}", .{node.test_name});
    defer a.free(macro_name);
    if (node.test_namespace) |namespace| {
        const requested = try std.fmt.allocPrint(a, "macro.{s}.test_{s}", .{ namespace, node.test_name });
        defer a.free(requested);
        if (try namespaceContains(a, graph, node.macro_depends_on.items, requested)) {
            try @import("compiler.zig").scanMacroDependencies(a, graph, &probe, requested["macro.".len..], args.items);
        }
    } else try @import("compiler.zig").scanMacroDependencies(a, graph, &probe, macro_name, args.items);
    // Core seeds its config-call dictionary with the builder, invokes the
    // macro, then renders the trailing builder config call again. Append and
    // update policies apply within that dictionary before project merging.
    var calls: Json = .{ .object = .empty };
    defer values.deinit(a, &calls);
    try merge(a, &calls, node.builder_config);
    try merge(a, &calls, probe.inline_config);
    try merge(a, &calls, node.builder_config);
    try merge(a, config, calls);
    try values.overlay(a, unrendered, calls);
    node.refs.clearRetainingCapacity();
    node.source_refs.clearRetainingCapacity();
    try node.refs.appendSlice(a, probe.refs.items);
    try node.source_refs.appendSlice(a, probe.source_refs.items);
    for (probe.macro_depends_on.items) |dependency| {
        var found = false;
        for (node.macro_depends_on.items) |existing| if (equal(existing, dependency)) {
            found = true;
        };
        if (!found) try node.macro_depends_on.append(a, dependency);
    }
}
fn namespaceContains(a: std.mem.Allocator, graph: *const types.Graph, seeds: []const []const u8, requested: []const u8) !bool {
    var pending: std.ArrayList([]const u8) = .empty;
    defer pending.deinit(a);
    try pending.appendSlice(a, seeds);
    var i: usize = 0;
    while (i < pending.items.len) : (i += 1) {
        const id = pending.items[i];
        if (equal(id, requested)) return true;
        for (graph.macros.items) |macro| if (equal(macro.unique_id, id)) {
            for (macro.macro_depends_on.items) |dependency| {
                var seen = false;
                for (pending.items) |prior| if (equal(prior, dependency)) {
                    seen = true;
                    break;
                };
                if (!seen) try pending.append(a, dependency);
            }
            break;
        };
    }
    return false;
}
fn projectConfig(a: std.mem.Allocator, graph: *const types.Graph, node: *const types.GenericTestNode, package: []const u8, config: *Json, unrendered: *Json) !void {
    for (graph.semantic_project_configs.items) |project| if (equal(project.package_name, package)) {
        const raw = values.get(project.raw, "data_tests") orelse values.get(project.raw, "tests") orelse .null;
        const rendered_doc = if (project.rendered == .null) project.raw else project.rendered;
        const rendered = values.get(rendered_doc, "data_tests") orelse values.get(rendered_doc, "tests") orelse .null;
        try hierarchy(a, config, rendered, node.fqn.items, false);
        try hierarchy(a, unrendered, raw, node.fqn.items, true);
    };
}
fn hierarchy(a: std.mem.Allocator, config: *Json, block: Json, fqn: []const []const u8, raw: bool) !void {
    var current = block;
    try level(a, config, current, raw);
    for (fqn) |part| {
        current = values.get(current, part) orelse return;
        try level(a, config, current, raw);
    }
}
fn level(a: std.mem.Allocator, config: *Json, block: Json, raw: bool) !void {
    if (block == .null) return;
    if (block != .object) return error.InvalidGenericTestConfiguration;
    var fields: Json = .{ .object = .empty };
    defer values.deinit(a, &fields);
    for (block.object.keys(), block.object.values()) |key, value| {
        if (std.mem.startsWith(u8, key, "+")) try values.put(a, &fields, key[1..], value) else if (value != .object) try values.put(a, &fields, key, value);
    }
    if (raw) try values.overlay(a, config, fields) else try merge(a, config, fields);
}
fn merge(a: std.mem.Allocator, config: *Json, patch: Json) !void {
    if (patch == .null) return;
    if (patch != .object) return error.InvalidGenericTestConfiguration;
    for (patch.object.keys(), patch.object.values()) |key, value| {
        if (equal(key, "tags")) {
            var tags = try values.clone(a, values.get(config.*, key) orelse .{ .array = std.json.Array.init(a) });
            defer values.deinit(a, &tags);
            if (tags != .array) return error.InvalidGenericTestConfiguration;
            if (value == .string) try tags.array.append(try values.clone(a, value)) else if (value == .array) {
                for (value.array.items) |tag| {
                    if (tag != .string) return error.InvalidGenericTestConfiguration;
                    try tags.array.append(try values.clone(a, tag));
                }
            } else return error.InvalidGenericTestConfiguration;
            try values.put(a, config, key, tags);
        } else if (equal(key, "meta")) {
            if (value != .object) return error.InvalidGenericTestConfiguration;
            var meta = try values.clone(a, values.get(config.*, key) orelse .{ .object = .empty });
            defer values.deinit(a, &meta);
            try values.overlay(a, &meta, value);
            try values.put(a, config, key, meta);
        } else try values.put(a, config, key, value);
    }
}
fn validate(config: Json) !void {
    if (values.get(config, "enabled").? != .bool or values.get(config, "meta").? != .object or values.get(config, "tags").? != .array) return error.InvalidGenericTestConfiguration;
    for (values.get(config, "tags").?.array.items) |tag| if (tag != .string) return error.InvalidGenericTestConfiguration;
    const group = values.get(config, "group").?;
    if (group != .null and group != .string) return error.InvalidGenericTestConfiguration;
    const severity = values.get(config, "severity").?;
    if (severity != .string or (!std.ascii.eqlIgnoreCase(severity.string, "warn") and !std.ascii.eqlIgnoreCase(severity.string, "error"))) return error.InvalidGenericTestConfiguration;
    inline for (.{ "materialized", "fail_calc", "warn_if", "error_if" }) |key| if (values.get(config, key).? != .string) return error.InvalidGenericTestConfiguration;
}
fn appendTags(a: std.mem.Allocator, tags: *std.ArrayList([]const u8), value: Json, unique: bool) !void {
    if (value == .null) return;
    const items: []const Json = if (value == .string) &.{value} else if (value == .array) value.array.items else return error.InvalidGenericTestConfiguration;
    for (items) |item| {
        if (item != .string) return error.InvalidGenericTestConfiguration;
        var found = false;
        if (unique) for (tags.items) |tag| if (equal(tag, item.string)) {
            found = true;
        };
        if (!found) try tags.append(a, item.string);
    }
}
fn less(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.lessThan(u8, left, right);
}

pub fn configTags(node: *const types.GenericTestNode) []const []const u8 {
    return node.config_tags.items;
}
pub fn matchesConfig(node: *const types.GenericTestNode, term: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, term, ':') orelse return false;
    var current = node.config_values;
    var parts = std.mem.splitScalar(u8, term[0..colon], '.');
    while (parts.next()) |part| current = values.get(current, part) orelse return false;
    if (equal(term[0..colon], "severity") and current == .string) return std.ascii.eqlIgnoreCase(current.string, term[colon + 1 ..]);
    return matchesValue(current, term[colon + 1 ..]);
}
fn matchesValue(value: Json, expected: []const u8) bool {
    switch (value) {
        .string => |text| return equal(text, expected),
        .bool => |v| return std.ascii.eqlIgnoreCase(expected, if (v) "true" else "false"),
        .null => return false,
        .array => |array| {
            for (array.items) |item| {
                if (matchesValue(item, expected)) return true;
                // Core list membership follows Python's bool/integer equality.
                if (item == .integer and ((item.integer == 1 and std.ascii.eqlIgnoreCase(expected, "true")) or (item.integer == 0 and std.ascii.eqlIgnoreCase(expected, "false")))) return true;
            }
            return false;
        },
        else => return false,
    }
}
fn equal(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

pub fn rawCode(a: std.mem.Allocator, node: *const types.GenericTestNode) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{{ ");
    if (node.test_namespace) |namespace| try w.print("{s}.", .{namespace});
    try w.print("test_{s}(**_dbt_generic_test_kwargs) }}}}", .{node.test_name});
    if (node.builder_config == .object and node.builder_config.object.count() != 0) {
        try w.writeAll("{{ config(");
        for (node.builder_config.object.keys(), node.builder_config.object.values(), 0..) |key, value, index| {
            if (index != 0) try w.writeByte(',');
            try w.print("{s}=", .{key});
            try pythonRepr(w, value, true);
        }
        try w.writeAll(") }}");
    }
    return try out.toOwnedSlice();
}
fn pythonRepr(w: *std.Io.Writer, value: Json, outer: bool) anyerror!void {
    switch (value) {
        .null => try w.writeAll("None"),
        .bool => |v| try w.writeAll(if (v) "True" else "False"),
        .string => |text| {
            const quote: u8 = if (outer) '"' else if (std.mem.indexOfScalar(u8, text, '\'') != null and std.mem.indexOfScalar(u8, text, '"') == null) '"' else '\'';
            try w.writeByte(quote);
            for (text) |byte| {
                switch (byte) {
                    '\\' => if (outer) try w.writeByte(byte) else try w.writeAll("\\\\"),
                    '\n' => if (outer) try w.writeByte(byte) else try w.writeAll("\\n"),
                    '\r' => if (outer) try w.writeByte(byte) else try w.writeAll("\\r"),
                    '\t' => if (outer) try w.writeByte(byte) else try w.writeAll("\\t"),
                    else => {
                        if (byte == quote) try w.writeByte('\\');
                        try w.writeByte(byte);
                    },
                }
            }
            try w.writeByte(quote);
        },
        .array => |array| {
            try w.writeByte('[');
            for (array.items, 0..) |item, i| {
                if (i != 0) try w.writeAll(", ");
                try pythonRepr(w, item, false);
            }
            try w.writeByte(']');
        },
        .object => |object| {
            try w.writeByte('{');
            for (object.keys(), object.values(), 0..) |key, item, i| {
                if (i != 0) try w.writeAll(", ");
                try pythonRepr(w, .{ .string = key }, false);
                try w.writeAll(": ");
                try pythonRepr(w, item, false);
            }
            try w.writeByte('}');
        },
        else => try std.json.Stringify.value(value, .{}, w),
    }
}

test "generic parse namespace follows seeded transitive macros and terminates cycles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph = types.Graph{ .allocator = a, .project_name = "root" };
    defer graph.deinit();
    for ([_][2][]const u8{ .{ "root", "test_check" }, .{ "dependency", "test_check" }, .{ "other", "test_check" } }) |definition| {
        try graph.macros.append(a, .{ .package_name = definition[0], .name = definition[1], .unique_id = try std.fmt.allocPrint(a, "macro.{s}.{s}", .{ definition[0], definition[1] }), .path = "tests.sql", .original_file_path = "macros/tests.sql", .macro_sql = "" });
    }
    try graph.macros.items[0].macro_depends_on.append(a, "macro.dependency.test_check");
    try graph.macros.items[1].macro_depends_on.append(a, "macro.root.test_check");
    try std.testing.expect(try namespaceContains(a, &graph, &.{"macro.root.test_check"}, "macro.dependency.test_check"));
    try std.testing.expect(!try namespaceContains(a, &graph, &.{"macro.root.test_check"}, "macro.other.test_check"));
}

test "generic config extraction separates identity arguments and rejects truthy duplicate legacy keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var document = try std.json.parseFromSlice(Json, a, "{\"enabled\":false,\"tags\":[\"legacy\"],\"config\":{\"enabled\":true,\"meta\":{\"owner\":\"test\"},\"extension\":{\"nested\":[false,2]}}}", .{});
    defer document.deinit();
    var test_def = types.GenericTestDef{ .name = "example", .arguments = try values.clone(a, document.value) };
    remove(a, &test_def.arguments, "config");
    defer values.deinit(a, &test_def.arguments);
    defer values.deinit(a, &test_def.config_values);
    try extract(a, document.value, &test_def);
    try std.testing.expectEqual(@as(usize, 0), test_def.arguments.object.count());
    try std.testing.expect(values.get(test_def.config_values, "enabled").?.bool);
    try std.testing.expectEqual(@as(i64, 2), values.get(values.get(test_def.config_values, "extension").?, "nested").?.array.items[1].integer);
    try values.put(a, &test_def.arguments, "enabled", .{ .bool = true });
    try std.testing.expectError(error.DuplicateGenericTestConfiguration, extract(a, document.value, &test_def));
}

test "generic config validates effective types before disabled execution boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var config = try @import("canonical_manifest_config.zig").defaults(a, "test");
    defer values.deinit(a, &config);
    try values.put(a, &config, "enabled", .{ .bool = false });
    try validate(config);
    try values.put(a, &config, "severity", .{ .string = "invalid" });
    try std.testing.expectError(error.InvalidGenericTestConfiguration, validate(config));
    try values.put(a, &config, "severity", .{ .string = "WARN" });
    try values.put(a, &config, "enabled", .{ .string = "false" });
    try std.testing.expectError(error.InvalidGenericTestConfiguration, validate(config));
}

test "generic config FQN root override preserves effective append and raw replacement policies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph = types.Graph{ .allocator = a, .project_name = "root" };
    defer graph.deinit();
    var dependency = try std.json.parseFromSlice(Json, a, "{\"data_tests\":{\"+tags\":[\"global\"],\"pkg\":{\"nested\":{\"+meta\":{\"nested\":{\"a\":1},\"owner\":\"dependency\"}}}}}", .{});
    defer dependency.deinit();
    var root = try std.json.parseFromSlice(Json, a, "{\"data_tests\":{\"pkg\":{\"nested\":{\"check\":{\"+tags\":\"root\",\"+enabled\":false,\"+meta\":{\"owner\":\"root\"}}}}}}", .{});
    defer root.deinit();
    try graph.semantic_project_configs.append(a, .{ .package_name = try a.dupe(u8, "pkg"), .raw = try values.clone(a, dependency.value), .rendered = .null });
    try graph.semantic_project_configs.append(a, .{ .package_name = try a.dupe(u8, "root"), .raw = try values.clone(a, root.value), .rendered = .null });
    var node = types.GenericTestNode{ .package_name = "pkg", .unique_id = "test.pkg.check.abc", .name = "check", .alias = "check", .path = "check.sql", .original_file_path = "models/nested/schema.yml", .raw_code = try a.dupe(u8, "{{ test_not_null(**_dbt_generic_test_kwargs) }}"), .test_name = "not_null" };
    defer types.deinitGenericTestNode(a, &node);
    try node.macro_depends_on.append(a, "macro.dbt.test_not_null");
    var authored = try std.json.parseFromSlice(Json, a, "{\"tags\":[\"local\"],\"meta\":{\"owner\":\"authored\"},\"extra\":{\"types\":[true,3]}}", .{});
    defer authored.deinit();
    node.builder_config = try values.clone(a, authored.value);
    try node.tags.append(a, "column");
    try apply(.{ .allocator = a, .io = std.testing.io }, &graph, &node);
    try std.testing.expectEqualStrings("nested", node.fqn.items[1]);
    try std.testing.expect(!node.enabled and node.disabled);
    try std.testing.expectEqualStrings("root", values.get(values.get(node.config_values, "meta").?, "owner").?.string);
    try std.testing.expectEqualStrings("global", node.config_tags.items[0]);
    try std.testing.expectEqualStrings("local", node.config_tags.items[1]);
    try std.testing.expectEqualStrings("root", node.config_tags.items[2]);
    try std.testing.expectEqualStrings("root", values.get(node.unrendered_config, "tags").?.string);
    try std.testing.expectEqualStrings("column", node.tags.items[0]);
    try std.testing.expect(!matchesConfig(&node, "extra.types:3"));
    try std.testing.expect(matchesConfig(&node, "extra.types:true"));
}
