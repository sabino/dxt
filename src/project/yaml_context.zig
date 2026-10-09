//! Runtime SafeLoader composition retains typed keys, aliases and safe tags.
//! libyaml owns syntax; native Zig owns construction and Python value identity.
const std = @import("std");
const c = @cImport({
    @cInclude("yaml.h");
});
const expression = @import("expression.zig");
const yaml = @import("yaml.zig");
const Value = expression.Value;
const Pair = struct { key: *Node, value: *Node };
const Node = struct {
    kind: enum { scalar, sequence, mapping } = .scalar,
    scalar: Value = .none,
    tag: []const u8 = "",
    merge: bool = false,
    children: std.ArrayList(*Node) = .empty,
    pairs: std.ArrayList(Pair) = .empty,
    constructed: ?Value = null,
};

pub fn load(a: std.mem.Allocator, text: []const u8) !Value {
    var parser = Parser{ .a = a, .anchors = std.StringHashMap(*Node).init(a) };
    defer parser.anchors.deinit();
    if (c.yaml_parser_initialize(&parser.syntax) == 0) return error.OutOfMemory;
    defer c.yaml_parser_delete(&parser.syntax);
    defer if (parser.has_event) c.yaml_event_delete(&parser.event);
    c.yaml_parser_set_input_string(&parser.syntax, text.ptr, text.len);
    try parser.next();
    if (parser.event.type != c.YAML_STREAM_START_EVENT) return error.InvalidYaml;
    try parser.next();
    if (parser.event.type == c.YAML_STREAM_END_EVENT) return .none;
    if (parser.event.type != c.YAML_DOCUMENT_START_EVENT) return error.InvalidYaml;
    try parser.next();
    const root = try parser.node(0, false);
    if (parser.event.type != c.YAML_DOCUMENT_END_EVENT) return error.InvalidYaml;
    try parser.next();
    if (parser.event.type != c.YAML_STREAM_END_EVENT) return error.InvalidYaml;
    return try construct(a, root, 0);
}

const Parser = struct {
    a: std.mem.Allocator,
    syntax: c.yaml_parser_t = undefined,
    event: c.yaml_event_t = undefined,
    has_event: bool = false,
    anchors: std.StringHashMap(*Node),
    count: usize = 0,

    fn next(self: *Parser) !void {
        if (self.has_event) c.yaml_event_delete(&self.event);
        self.has_event = false;
        self.count += 1;
        if (self.count > 1_000_000) return error.JinjaIterationLimitExceeded;
        if (c.yaml_parser_parse(&self.syntax, &self.event) == 0) return if (self.syntax.@"error" == c.YAML_MEMORY_ERROR) error.OutOfMemory else error.InvalidYaml;
        self.has_event = true;
    }

    fn anchor(self: *Parser, raw: [*c]const u8, result: *Node) !void {
        if (raw == null) return;
        const name = try self.a.dupe(u8, std.mem.span(raw));
        if (self.anchors.contains(name)) return error.InvalidYaml;
        try self.anchors.put(name, result);
    }

    fn node(self: *Parser, depth: usize, key: bool) anyerror!*Node {
        if (depth > 256) return error.JinjaExpressionDepthExceeded;
        if (self.event.type == c.YAML_ALIAS_EVENT) {
            const result = self.anchors.get(std.mem.span(self.event.data.alias.anchor)) orelse return error.InvalidYaml;
            try self.next();
            return result;
        }
        const result = try self.a.create(Node);
        result.* = .{};
        switch (self.event.type) {
            c.YAML_SCALAR_EVENT => {
                try self.anchor(self.event.data.scalar.anchor, result);
                const text = self.event.data.scalar.value[0..self.event.data.scalar.length];
                const tag = if (self.event.data.scalar.tag != null) try self.a.dupe(u8, std.mem.span(self.event.data.scalar.tag)) else null;
                const scalar = try yaml.resolveScalar(self.a, text, tag, self.event.data.scalar.style == c.YAML_PLAIN_SCALAR_STYLE, key);
                result.tag = scalar.tag;
                result.merge = scalar.merge;
                result.scalar = if (isTag(scalar.tag, "timestamp")) try @import("timestamp_context.zig").fromYaml(self.a, scalar.value.string) else if (isTag(scalar.tag, "binary")) try @import("yaml_values.zig").binary(self.a, scalar.value.string) else try @import("config_value.zig").toExpression(self.a, scalar.value);
                if (expression.floatProtocol(result.scalar)) |number| if (std.math.isNan(number)) {
                    result.scalar = try @import("yaml_values.zig").nan(self.a);
                };
                try self.next();
            },
            c.YAML_SEQUENCE_START_EVENT => {
                result.kind = .sequence;
                try self.anchor(self.event.data.sequence_start.anchor, result);
                result.tag = if (self.event.data.sequence_start.tag != null) try self.a.dupe(u8, std.mem.span(self.event.data.sequence_start.tag)) else "seq";
                if (!isTag(result.tag, "seq") and !isTag(result.tag, "omap") and !isTag(result.tag, "pairs") and !std.mem.eql(u8, result.tag, "!")) return error.YamlUnsupportedTag;
                try self.next();
                while (self.event.type != c.YAML_SEQUENCE_END_EVENT) try result.children.append(self.a, try self.node(depth + 1, false));
                try self.next();
            },
            c.YAML_MAPPING_START_EVENT => {
                result.kind = .mapping;
                try self.anchor(self.event.data.mapping_start.anchor, result);
                result.tag = if (self.event.data.mapping_start.tag != null) try self.a.dupe(u8, std.mem.span(self.event.data.mapping_start.tag)) else "map";
                if (!isTag(result.tag, "map") and !isTag(result.tag, "set") and !std.mem.eql(u8, result.tag, "!")) return error.YamlUnsupportedTag;
                try self.next();
                while (self.event.type != c.YAML_MAPPING_END_EVENT) {
                    const child_key = try self.node(depth + 1, true);
                    const child_value = try self.node(depth + 1, false);
                    try result.pairs.append(self.a, .{ .key = child_key, .value = child_value });
                }
                try self.next();
            },
            else => return error.InvalidYaml,
        }
        return result;
    }
};

fn isTag(tag: []const u8, short: []const u8) bool {
    return std.mem.eql(u8, tag, short) or (std.mem.startsWith(u8, tag, "tag:yaml.org,2002:") and std.mem.eql(u8, tag[18..], short));
}

fn flatten(a: std.mem.Allocator, node: *Node, output: *std.ArrayList(Pair), depth: usize) !void {
    if (depth > 256) return error.InvalidYaml;
    if (node.kind != .mapping) return error.InvalidYaml;
    for (node.pairs.items) |pair| if (pair.key.merge) {
        if (pair.value.kind == .sequence) {
            var index = pair.value.children.items.len;
            while (index != 0) {
                index -= 1;
                try flatten(a, pair.value.children.items[index], output, depth + 1);
            }
        } else try flatten(a, pair.value, output, depth + 1);
    };
    for (node.pairs.items) |pair| if (!pair.key.merge) try output.append(a, pair);
}

fn construct(a: std.mem.Allocator, node: *Node, depth: usize) anyerror!Value {
    if (node.constructed) |result| return result;
    if (depth > 256) return error.JinjaExpressionDepthExceeded;
    if (node.kind == .scalar) return node.scalar;
    if (node.kind == .sequence) {
        const members = try expression.allocateValues(a, node.children.items.len);
        const result = Value{ .list = members };
        node.constructed = result;
        for (node.children.items, members) |child, *member| {
            if (isTag(node.tag, "pairs") or isTag(node.tag, "omap")) {
                if (child.kind != .mapping or child.pairs.items.len != 1) return error.InvalidYaml;
                const pair = try expression.allocateValues(a, 2);
                pair[0] = try construct(a, child.pairs.items[0].key, depth + 1);
                pair[1] = try construct(a, child.pairs.items[0].value, depth + 1);
                member.* = .{ .tuple = pair };
            } else member.* = try construct(a, child, depth + 1);
        }
        return result;
    }
    var flattened: std.ArrayList(Pair) = .empty;
    try flatten(a, node, &flattened, 0);
    var entries: std.ArrayList(expression.Entry) = .empty;
    var values: std.ArrayList(*Node) = .empty;
    for (flattened.items) |pair| {
        if (pair.key.kind != .scalar) return error.InvalidYaml;
        const key = try construct(a, pair.key, depth + 1);
        expression.hashableKey(key) catch return error.InvalidYaml;
        var found = false;
        for (entries.items, values.items) |entry, *target| if (@import("mapping_keys.zig").matches(entry, key)) {
            target.* = pair.value;
            found = true;
            break;
        };
        if (found) continue;
        try entries.append(a, try @import("mapping_keys.zig").create(key, .none));
        try values.append(a, pair.value);
    }
    if (isTag(node.tag, "set")) {
        const members = try expression.allocateValues(a, entries.items.len);
        for (entries.items, members) |entry, *member| member.* = expression.entryKey(entry);
        const result = try @import("set_context.zig").fromMembers(a, members);
        node.constructed = result;
        return result;
    }
    const storage = try expression.allocateEntries(a, entries.items.len);
    @memcpy(storage, entries.items);
    const result = Value{ .object = storage };
    node.constructed = result;
    for (storage, values.items) |*entry, child| entry.value = try construct(a, child, depth + 1);
    return result;
}

test "context YAML preserves typed mapping collisions safe tags and recursive aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dictionary = try load(a, "{1: integer, true: boolean, '1': string, nested: &v [1, 2], alias: *v}");
    try std.testing.expectEqualStrings("boolean", (try expression.mappingEntry(dictionary, .{ .integer = "1" })).?.value.string);
    try std.testing.expectEqualStrings("string", dictionary.attribute("1").string);
    try std.testing.expect(dictionary.attribute("nested").list.ptr == dictionary.attribute("alias").list.ptr);
    const cyclic = try load(a, "&root [*root]");
    try std.testing.expect(cyclic.list.ptr == cyclic.list[0].list.ptr);
    const tags = try load(a, "{bytes: !!binary SGVsbG8=, date: 2020-01-02, set: !!set {a: null, b: null}, pairs: !!pairs [{1: first}]}");
    try std.testing.expectEqualStrings("Hello", tags.attribute("bytes").attribute("__dxt_binary").string);
    try std.testing.expectEqualStrings("2020-01-02", tags.attribute("date").attribute("__dxt_yaml_timestamp").string);
    try std.testing.expect(@import("set_context.zig").isSet(tags.attribute("set")));
    try std.testing.expect(tags.attribute("pairs").list[0] == .tuple);
}
