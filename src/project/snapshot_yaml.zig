const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const snapshot = @import("snapshot.zig");
const fs = @import("fs.zig");
const json = @import("json.zig");
const compiler = @import("compiler.zig");
const Value = std.json.Value;
const Line = struct { indent: usize, text: []const u8, raw: []const u8 };
const Parser = struct {
    allocator: std.mem.Allocator,
    lines: []const Line,
    cursor: usize = 0,

    fn block(self: *Parser, indent: usize) anyerror!Value {
        if (self.cursor >= self.lines.len) return .null;
        if (std.mem.startsWith(u8, self.lines[self.cursor].text, "- ")) return self.sequence(indent);
        return self.mapping(indent);
    }

    fn mapping(self: *Parser, indent: usize) anyerror!Value {
        var object = std.json.ObjectMap{};
        while (self.cursor < self.lines.len and self.lines[self.cursor].indent == indent) {
            const line = self.lines[self.cursor];
            if (std.mem.startsWith(u8, line.text, "- ")) break;
            self.cursor += 1;
            try self.entry(&object, line.text, indent);
        }
        return .{ .object = object };
    }

    fn entry(self: *Parser, object: *std.json.ObjectMap, text: []const u8, indent: usize) anyerror!void {
        const kv = util.splitKeyValue(text) orelse return error.UnsupportedSnapshotYaml;
        const key = try util.dupTrimmedScalar(self.allocator, kv.key);
        if (object.contains(key)) return error.UnsupportedSnapshotYaml;
        const raw_value = std.mem.trim(u8, kv.value, " \t\r");
        const value: Value = if (raw_value.len == 0)
            if (self.cursor < self.lines.len and self.lines[self.cursor].indent > indent) try self.block(self.lines[self.cursor].indent) else .null
        else if (raw_value[0] == '|' or raw_value[0] == '>')
            try self.blockString(indent, raw_value)
        else
            try inlineValue(self.allocator, raw_value);
        try object.put(self.allocator, key, value);
    }

    fn blockString(self: *Parser, parent_indent: usize, marker: []const u8) !Value {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        var first = self.cursor;
        while (first < self.lines.len and self.lines[first].text.len == 0) : (first += 1) {}
        var indent = if (first < self.lines.len and self.lines[first].indent > parent_indent) self.lines[first].indent else parent_indent + 1;
        for (marker[1..]) |character| {
            if (character >= '1' and character <= '9') indent = parent_indent + character - '0' else if (character != '+' and character != '-') return error.UnsupportedSnapshotYaml;
        }
        var previous_blank = false;
        var previous_indented = false;
        var count: usize = 0;
        while (self.cursor < self.lines.len and (self.lines[self.cursor].indent > parent_indent or self.lines[self.cursor].text.len == 0)) {
            const line = self.lines[self.cursor];
            const blank = line.text.len == 0;
            const more_indented = !blank and line.indent > indent;
            if (!blank and line.indent < indent) return error.UnsupportedSnapshotYaml;
            if (count != 0) {
                if (marker[0] == '|' or more_indented or previous_indented or blank) try out.writer.writeByte('\n') else if (!previous_blank) try out.writer.writeByte(' ');
            }
            if (!blank) try out.writer.writeAll(line.raw[@min(indent, line.raw.len)..]);
            previous_blank = blank;
            previous_indented = more_indented;
            count += 1;
            self.cursor += 1;
        }
        if (count != 0) try out.writer.writeByte('\n');
        const text = try out.toOwnedSlice();
        const stripped = std.mem.trimEnd(u8, text, "\n");
        if (std.mem.indexOfScalar(u8, marker, '-') != null) return .{ .string = stripped };
        if (std.mem.indexOfScalar(u8, marker, '+') != null or text.len == 0) return .{ .string = text };
        return .{ .string = text[0 .. stripped.len + 1] };
    }

    fn sequence(self: *Parser, indent: usize) anyerror!Value {
        var array = std.array_list.Managed(Value).init(self.allocator);
        while (self.cursor < self.lines.len and self.lines[self.cursor].indent == indent and std.mem.startsWith(u8, self.lines[self.cursor].text, "- ")) {
            const item = std.mem.trim(u8, self.lines[self.cursor].text[2..], " \t\r");
            self.cursor += 1;
            if (util.splitKeyValue(item) != null and item[0] != '\'' and item[0] != '"' and item[0] != '{' and item[0] != '[') {
                var object = std.json.ObjectMap{};
                try self.entry(&object, item, indent + 2);
                if (self.cursor < self.lines.len and self.lines[self.cursor].indent > indent) {
                    const tail = try self.mapping(self.lines[self.cursor].indent);
                    var entries = tail.object.iterator();
                    while (entries.next()) |pair| {
                        if (object.contains(pair.key_ptr.*)) return error.UnsupportedSnapshotYaml;
                        try object.put(self.allocator, pair.key_ptr.*, pair.value_ptr.*);
                    }
                }
                try array.append(.{ .object = object });
            } else try array.append(try inlineValue(self.allocator, item));
        }
        return .{ .array = array };
    }
};

fn commaEnd(text: []const u8, start: usize) !usize {
    var depth: usize = 0;
    var index = start;
    while (index < text.len) : (index += 1) {
        if (text[index] == '\'' or text[index] == '"') {
            index = (@import("jinja.zig").skipQuotedSpan(text, index) orelse return error.UnsupportedSnapshotYaml) - 1;
        } else if (text[index] == '[' or text[index] == '{' or text[index] == '(') depth += 1 else if (text[index] == ']' or text[index] == '}' or text[index] == ')') {
            if (depth == 0) return error.UnsupportedSnapshotYaml;
            depth -= 1;
        } else if (text[index] == ',' and depth == 0) return index;
    }
    if (depth != 0) return error.UnsupportedSnapshotYaml;
    return index;
}

fn inlineValue(allocator: std.mem.Allocator, raw: []const u8) anyerror!Value {
    const text = std.mem.trim(u8, raw, " \t\r");
    if (text.len == 0 or std.mem.eql(u8, text, "null") or std.mem.eql(u8, text, "~")) return .null;
    if (text[0] == '&' or text[0] == '*' or text[0] == '!') return error.UnsupportedSnapshotYaml;
    if (text[0] == '[' or text[0] == '{') {
        if (text.len < 2 or text[text.len - 1] != (if (text[0] == '[') @as(u8, ']') else '}')) return error.UnsupportedSnapshotYaml;
        const body = text[1 .. text.len - 1];
        var array = std.array_list.Managed(Value).init(allocator);
        var object = std.json.ObjectMap{};
        var cursor: usize = 0;
        while (cursor < body.len) {
            const end = try commaEnd(body, cursor);
            const item = std.mem.trim(u8, body[cursor..end], " \t\r");
            if (item.len != 0) {
                if (text[0] == '[') try array.append(try inlineValue(allocator, item)) else {
                    const kv = util.splitKeyValue(item) orelse return error.UnsupportedSnapshotYaml;
                    const key = try util.dupTrimmedScalar(allocator, kv.key);
                    if (object.contains(key)) return error.UnsupportedSnapshotYaml;
                    try object.put(allocator, key, try inlineValue(allocator, kv.value));
                }
            }
            cursor = end + 1;
        }
        return if (text[0] == '[') .{ .array = array } else .{ .object = object };
    }
    if (text[0] == '\'' or text[0] == '"') {
        if (text.len < 2 or text[text.len - 1] != text[0]) return error.UnsupportedSnapshotYaml;
        if (text[0] == '"') {
            const parsed = std.json.parseFromSlice(Value, allocator, text, .{}) catch return error.UnsupportedSnapshotYaml;
            if (parsed.value != .string) return error.UnsupportedSnapshotYaml;
            return parsed.value;
        }
        var out: std.ArrayList(u8) = .empty;
        var cursor: usize = 1;
        while (cursor < text.len - 1) : (cursor += 1) {
            if (text[cursor] == '\'' and cursor + 1 < text.len - 1 and text[cursor + 1] == '\'') cursor += 1;
            try out.append(allocator, text[cursor]);
        }
        return .{ .string = try out.toOwnedSlice(allocator) };
    }
    if (std.ascii.eqlIgnoreCase(text, "true")) return .{ .bool = true };
    if (std.ascii.eqlIgnoreCase(text, "false")) return .{ .bool = false };
    if (std.fmt.parseInt(i64, text, 10)) |integer| return .{ .integer = integer } else |_| {}
    if (std.fmt.parseFloat(f64, text)) |number| return .{ .float = number } else |_| {}
    return .{ .string = try allocator.dupe(u8, text) };
}

pub fn section(allocator: std.mem.Allocator, text: []const u8) !?Value {
    var lines: std.ArrayList(Line) = .empty;
    var in_section = false;
    var block_parent: ?usize = null;
    var raw_lines = std.mem.splitScalar(u8, text, '\n');
    while (raw_lines.next()) |raw| {
        const clean = util.stripYamlComment(raw);
        const trimmed = std.mem.trim(u8, clean, " \t\r");
        const indent = util.leadingSpaces(raw);
        if (in_section and block_parent != null) {
            if (std.mem.trim(u8, raw, " \t\r").len == 0 or indent > block_parent.?) {
                try lines.append(allocator, .{ .indent = indent, .text = std.mem.trim(u8, raw, " \t\r"), .raw = raw });
                continue;
            }
            block_parent = null;
        }
        if (trimmed.len == 0) continue;
        if (!in_section) {
            if (indent == 0) if (util.splitKeyValue(trimmed)) |kv| {
                if (std.mem.eql(u8, kv.key, "snapshots")) {
                    if (std.mem.trim(u8, kv.value, " \t\r").len != 0) return try inlineValue(allocator, kv.value);
                    in_section = true;
                }
            };
            continue;
        }
        if (indent == 0 and !std.mem.startsWith(u8, trimmed, "- ")) break;
        try lines.append(allocator, .{ .indent = indent, .text = trimmed, .raw = raw });
        const sequence_entry = std.mem.startsWith(u8, trimmed, "- ");
        if (util.splitKeyValue(if (sequence_entry) trimmed[2..] else trimmed)) |kv| {
            const value = std.mem.trim(u8, kv.value, " \t\r");
            if (value.len != 0 and (value[0] == '|' or value[0] == '>')) block_parent = indent + @as(usize, if (sequence_entry) 2 else 0);
        }
    }
    if (!in_section) return null;
    if (lines.items.len == 0) return .null;
    var parser = Parser{ .allocator = allocator, .lines = lines.items };
    const value = try parser.block(lines.items[0].indent);
    if (parser.cursor != lines.items.len) return error.UnsupportedSnapshotYaml;
    return value;
}

fn stringValue(value: Value) ![]const u8 {
    return if (value == .string) value.string else error.UnsupportedSnapshotYaml;
}

fn configArgs(allocator: std.mem.Allocator, object: Value, project: bool) ![]const u8 {
    if (object == .null) return "";
    if (object != .object) return error.UnsupportedSnapshotYaml;
    var out: std.Io.Writer.Allocating = .init(allocator);
    var entries = object.object.iterator();
    var count: usize = 0;
    while (entries.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "docs") or std.mem.eql(u8, key, "meta") or std.mem.eql(u8, key, "+docs") or std.mem.eql(u8, key, "+meta")) continue;
        if (project and (key.len == 0 or (key[0] != '+' and !isConfigKey(key)))) continue;
        if (count != 0) try out.writer.writeAll(",");
        try out.writer.writeAll(if (project and key[0] == '+') key[1..] else key);
        try out.writer.writeAll("=");
        try writeRepr(&out.writer, entry.value_ptr.*);
        count += 1;
    }
    return out.toOwnedSlice();
}

fn isConfigKey(key: []const u8) bool {
    inline for (.{ "strategy", "unique_key", "target_schema", "target_database", "updated_at", "check_cols", "invalidate_hard_deletes", "hard_deletes", "dbt_valid_to_current", "snapshot_meta_column_names", "enabled", "tags", "schema", "alias", "materialized" }) |name| {
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

fn writeRepr(writer: *std.Io.Writer, value: Value) anyerror!void {
    switch (value) {
        .string => try json.string(writer, value.string),
        .bool => try writer.writeAll(if (value.bool) "true" else "false"),
        .null => try writer.writeAll("none"),
        .integer => try writer.print("{d}", .{value.integer}),
        .float => try writer.print("{d}", .{value.float}),
        .array => {
            try writer.writeAll("[");
            for (value.array.items, 0..) |item, index| {
                if (index != 0) try writer.writeAll(",");
                try writeRepr(writer, item);
            }
            try writer.writeAll("]");
        },
        .object => {
            try writer.writeAll("{");
            var iterator = value.object.iterator();
            var count: usize = 0;
            while (iterator.next()) |entry| {
                if (count != 0) try writer.writeAll(",");
                try json.string(writer, entry.key_ptr.*);
                try writer.writeAll(":");
                try writeRepr(writer, entry.value_ptr.*);
                count += 1;
            }
            try writer.writeAll("}");
        },
        else => return error.UnsupportedSnapshotYaml,
    }
}

pub fn parseProperties(allocator: std.mem.Allocator, text: []const u8, resource_root: []const u8, path: []const u8, package_name: []const u8, graph: *types.Graph) !void {
    const value = (try section(allocator, text)) orelse return;
    if (value == .null) return;
    if (value != .array) return error.UnsupportedSnapshotYaml;
    for (value.array.items) |entry| {
        if (entry != .object) return error.UnsupportedSnapshotYaml;
        const name = try stringValue(entry.object.get("name") orelse return error.UnsupportedSnapshotYaml);
        for (graph.snapshot_properties.items) |previous| {
            if (std.mem.eql(u8, previous.package_name, package_name) and std.mem.eql(u8, previous.name, name)) return error.DuplicateSnapshotPatch;
        }
        const args = try configArgs(allocator, entry.object.get("config") orelse .null, false);
        try graph.snapshot_properties.append(allocator, .{ .package_name = package_name, .name = name, .path = path, .config_args = args, .properties = entry });
        if (entry.object.get("relation")) |relation_value| {
            const relation = try stringValue(relation_value);
            const body = try std.fmt.allocPrint(allocator, "select * from {{{{ {s} }}}}", .{relation});
            const relative = fs.relativeUnderResourcePath(path, resource_root);
            const dir = std.fs.path.dirname(relative) orelse "";
            const yaml_path = try std.fmt.allocPrint(allocator, "{s}/{s}.sql", .{ relative, name });
            const fqn_path = if (dir.len == 0) try std.fmt.allocPrint(allocator, "{s}.sql", .{name}) else try fs.pathJoin(allocator, &.{ dir, try std.fmt.allocPrint(allocator, "{s}.sql", .{name}) });
            var node = types.Node{ .resource_type = "snapshot", .package_name = package_name, .name = name, .unique_id = try std.fmt.allocPrint(allocator, "snapshot.{s}.{s}", .{ package_name, name }), .path = yaml_path, .original_file_path = path, .raw_code = body, .snapshot_file_code = text, .snapshot_fqn_path = fqn_path, .snapshot_yaml_definition = true, .materialized = "snapshot", .snapshot_config = .{} };
            try snapshot.scanBody(allocator, body, &node);
            try graph.nodes.append(allocator, node);
        }
    }
}

fn applyHierarchy(graph: *types.Graph, value: Value, fqn: []const []const u8, index: usize, node: *types.Node) !void {
    if (value == .null) return;
    if (value != .object) return error.UnsupportedProjectSnapshotConfig;
    const args = try configArgs(graph.allocator, value, true);
    try snapshot.parseConfig(graph.allocator, args, node);
    var metadata = std.json.ObjectMap{};
    if (value.object.get("+docs") orelse value.object.get("docs")) |docs| try metadata.put(graph.allocator, "docs", docs);
    if (value.object.get("+meta") orelse value.object.get("meta")) |meta| try metadata.put(graph.allocator, "meta", meta);
    try applyMetadata(graph, node, .{ .object = metadata });
    if (index < fqn.len) if (value.object.get(fqn[index])) |child| try applyHierarchy(graph, child, fqn, index + 1, node);
}

pub fn finalize(graph: *types.Graph) !void {
    for (graph.nodes.items) |*node| {
        if (node.snapshot_config == null) continue;
        const inline_config = node.snapshot_config.?;
        var base = node.*;
        base.snapshot_config = .{};
        base.tags = .empty;
        base.config_schema = null;
        base.config_alias = null;
        base.docs = .{};
        base.snapshot_meta_json = null;
        base.inline_enabled = false;
        base.enabled = true;
        var fqn: std.ArrayList([]const u8) = .empty;
        try fqn.append(graph.allocator, node.package_name);
        var parts = std.mem.tokenizeAny(u8, node.snapshot_fqn_path orelse node.path, "/\\");
        while (parts.next()) |part| {
            const dot = std.mem.lastIndexOfScalar(u8, part, '.');
            try fqn.append(graph.allocator, if (parts.peek() == null and dot != null) part[0..dot.?] else part);
        }
        if (!node.snapshot_yaml_definition) try fqn.append(graph.allocator, node.name);
        for (graph.snapshot_project_configs.items) |config| {
            if (!std.mem.eql(u8, config.package_name, node.package_name)) continue;
            if (try section(graph.allocator, config.text)) |value| try applyHierarchy(graph, value, fqn.items, 0, &base);
        }
        for (graph.snapshot_properties.items) |patch| {
            if (!std.mem.eql(u8, patch.package_name, node.package_name) or !std.mem.eql(u8, patch.name, node.name)) continue;
            try snapshot.parseConfig(graph.allocator, patch.config_args, &base);
            try applyMetadata(graph, &base, patch.properties);
            base.patch_path = patch.path;
        }
        snapshot.overlayConfig(graph.allocator, &base.snapshot_config.?, inline_config);
        if (node.snapshot_inline_schema) base.config_schema = node.config_schema;
        if (node.snapshot_inline_alias) base.config_alias = node.config_alias;
        if (node.snapshot_inline_docs) base.docs = node.docs;
        if (node.snapshot_inline_meta) {
            var merged = if (base.snapshot_meta_json) |prior| prior.object else std.json.ObjectMap{};
            var values = node.snapshot_meta_json.?.object.iterator();
            while (values.next()) |entry| try merged.put(graph.allocator, entry.key_ptr.*, entry.value_ptr.*);
            base.snapshot_meta_json = .{ .object = merged };
        }
        if (node.inline_enabled) base.enabled = node.enabled;
        if (!std.mem.eql(u8, node.package_name, graph.project_name)) {
            for (graph.snapshot_project_configs.items) |config| {
                if (!std.mem.eql(u8, config.package_name, graph.project_name)) continue;
                if (try section(graph.allocator, config.text)) |value| try applyHierarchy(graph, value, fqn.items, 0, &base);
            }
        }
        for (node.tags.items) |tag| try util.appendUnique(graph.allocator, &base.tags, tag);
        node.tags.deinit(graph.allocator);
        node.tags = base.tags;
        node.snapshot_config = base.snapshot_config;
        node.config_schema = base.config_schema;
        node.config_alias = base.config_alias;
        node.enabled = base.enabled;
        node.patch_path = base.patch_path;
        node.description = base.description;
        node.docs = base.docs;
        node.meta = base.meta;
        node.snapshot_meta_json = base.snapshot_meta_json;
        try snapshot.validateConfig(node);
    }
}

fn applyMetadata(graph: *types.Graph, node: *types.Node, properties: Value) !void {
    if (properties.object.get("description")) |description| node.description = try stringValue(description);
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
                if (column.object.get("description")) |value| existing.description = try stringValue(value);
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
    try parseProperties(graph.allocator, yaml, "snapshots", "snapshots/nested/definitions.yml", "demo", &graph);
    try finalize(&graph);
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
