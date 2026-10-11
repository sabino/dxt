//! Macro patches use the shared YAML value model, including flow collections,
//! block scalars, aliases and arbitrary typed metadata.
const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");

pub fn parse(allocator: std.mem.Allocator, document: std.json.Value, path: []const u8, package: []const u8, graph: *types.Graph) !void {
    return parseWithContext(allocator, document, path, package, graph, null);
}

pub fn parseWithRuntime(runtime: types.Runtime, document: std.json.Value, path: []const u8, package: []const u8, graph: *types.Graph) !void {
    var context = @import("config_render.zig").Context{ .runtime = runtime, .vars = graph.vars.items, .target = graph.target_context, .package_name = package };
    return parseWithContext(runtime.allocator, document, path, package, graph, &context);
}

fn parseWithContext(allocator: std.mem.Allocator, document: std.json.Value, path: []const u8, package: []const u8, graph: *types.Graph, context: ?*@import("config_render.zig").Context) !void {
    const macros = values.get(document, "macros") orelse return;
    if (macros != .array) return error.InvalidMacroProperties;
    for (macros.array.items) |item| {
        if (item != .object) return error.InvalidMacroProperties;
        var name = try render(allocator, context, values.get(item, "name") orelse return error.InvalidMacroProperties);
        defer values.deinit(allocator, &name);
        var property = types.MacroProperty{
            .package_name = package,
            .name = try ownedString(allocator, name),
            .patch_path = path,
        };
        if (values.get(item, "description")) |value| property.description = try ownedString(allocator, value);
        // Core macro patches currently read top-level docs/meta; config does
        // not relocate these attributes as it does for model patches.
        if (values.get(item, "meta")) |meta| {
            var rendered = try render(allocator, context, meta);
            defer values.deinit(allocator, &rendered);
            if (rendered != .object) return error.InvalidMacroProperties;
            var entries = rendered.object.iterator();
            while (entries.next()) |entry| {
                const value = entry.value_ptr.*;
                try property.meta.append(allocator, .{
                    .key = try allocator.dupe(u8, entry.key_ptr.*),
                    .value = .{
                        .text = try values.scalarText(allocator, value),
                        .kind = switch (value) {
                            .string => .string,
                            .bool => .bool,
                            .null => .null,
                            .integer, .float, .number_string => .number,
                            .array, .object => .json,
                        },
                    },
                });
            }
            std.mem.sort(types.MetaEntry, property.meta.items, {}, struct {
                fn less(_: void, a: types.MetaEntry, b: types.MetaEntry) bool {
                    return std.mem.lessThan(u8, a.key, b.key);
                }
            }.less);
        }
        if (values.get(item, "docs")) |input| {
            var docs = try render(allocator, context, input);
            defer values.deinit(allocator, &docs);
            if (docs != .object) return error.InvalidMacroProperties;
            property.docs.configured = true;
            if (values.get(docs, "show")) |show| {
                if (show != .bool) return error.InvalidMacroProperties;
                property.docs.show = show.bool;
            }
            if (values.get(docs, "node_color")) |color| property.docs.node_color = if (color == .null) null else try ownedString(allocator, color);
        }
        if (values.get(item, "arguments")) |arguments| {
            if (arguments != .array) return error.InvalidMacroProperties;
            for (arguments.array.items) |argument| {
                if (argument != .object) return error.InvalidMacroProperties;
                var arg_name = try render(allocator, context, values.get(argument, "name") orelse return error.InvalidMacroProperties);
                defer values.deinit(allocator, &arg_name);
                var parsed = types.MacroArgument{ .name = try ownedString(allocator, arg_name) };
                if (values.get(argument, "type")) |input| {
                    var kind = try render(allocator, context, input);
                    defer values.deinit(allocator, &kind);
                    parsed.type = if (kind == .null) "" else try ownedString(allocator, kind);
                    parsed.has_type = kind != .null;
                }
                if (values.get(argument, "description")) |description| parsed.description = try ownedString(allocator, description);
                try property.arguments.append(allocator, parsed);
            }
        }
        if (values.get(item, "config")) |config| {
            var rendered = try render(allocator, context, config);
            defer values.deinit(allocator, &rendered);
            if (rendered != .object) return error.InvalidMacroProperties;
        }
        try graph.macro_properties.append(allocator, property);
    }
}

fn render(allocator: std.mem.Allocator, context: ?*@import("config_render.zig").Context, input: std.json.Value) anyerror!std.json.Value {
    const renderer = context orelse return try values.clone(allocator, input);
    switch (input) {
        .string => |text| {
            // SchemaYamlRenderer uses text Jinja, so a templated boolean or
            // collection remains a string before the macro patch is validated.
            var value = try renderer.renderString(text);
            if (value == .string) return value;
            defer values.deinit(allocator, &value);
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const scratch = arena.allocator();
            return .{ .string = try allocator.dupe(u8, try (try values.toExpression(scratch, value)).text(scratch)) };
        },
        .array => |items| {
            var output = std.json.Array.init(allocator);
            for (items.items) |item| try output.append(try render(allocator, renderer, item));
            return .{ .array = output };
        },
        .object => |object| {
            var output: std.json.ObjectMap = .empty;
            var entries = object.iterator();
            while (entries.next()) |entry| try output.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try render(allocator, renderer, entry.value_ptr.*));
            return .{ .object = output };
        },
        else => return try values.clone(allocator, input),
    }
}

fn ownedString(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidMacroProperties;
    return try allocator.dupe(u8, value.string);
}

test "macro YAML retains inline arguments multiline descriptions and typed metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var document = try @import("yaml.zig").parse(a,
        \\macros:
        \\  - name: helper
        \\    description: >-
        \\      First line
        \\      second line.
        \\    arguments: [{name: value, type: null, description: "{{ doc('value') }}"}]
        \\    docs: {show: false, node_color: null}
        \\    meta: {nested: {values: [1, true, null]}}
    );
    defer document.deinit();
    var graph = types.Graph{ .allocator = a, .project_name = "demo" };
    defer graph.deinit();
    try parse(a, document.value, "macros/schema.yml", "demo", &graph);
    const patch = graph.macro_properties.items[0];
    try std.testing.expectEqualStrings("First line second line.", patch.description);
    try std.testing.expectEqualStrings("{{ doc('value') }}", patch.arguments.items[0].description);
    try std.testing.expect(!patch.docs.show);
    try std.testing.expectEqual(.json, patch.meta.items[0].value.kind);
    try std.testing.expectEqualStrings("{\"values\":[1,true,null]}", patch.meta.items[0].value.text);
}
