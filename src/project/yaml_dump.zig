//! SafeDumper representations are native; the pinned libyaml emitter writes
//! block styles, quoting, wrapping, Unicode escapes and document boundaries.
const std = @import("std");
const c = @cImport({
    @cInclude("yaml.h");
});
const expression = @import("expression.zig");
const Value = expression.Value;
const Anchor = struct { pointer: usize, name: ?[:0]const u8 = null, emitted: bool = false };

pub fn dump(a: std.mem.Allocator, input: Value, sorted: bool) ![]const u8 {
    var context = Dumper{ .a = a, .sorted = sorted };
    defer context.anchors.deinit(a);
    defer context.out.deinit();
    context.out = .init(a);
    try context.count(input, 0);
    if (c.yaml_emitter_initialize(&context.syntax) == 0) return error.OutOfMemory;
    defer c.yaml_emitter_delete(&context.syntax);
    c.yaml_emitter_set_output(&context.syntax, write, &context);
    c.yaml_emitter_set_unicode(&context.syntax, 0);
    c.yaml_emitter_set_indent(&context.syntax, 2);
    c.yaml_emitter_set_width(&context.syntax, 80);
    var event: c.yaml_event_t = undefined;
    try context.initialized(c.yaml_stream_start_event_initialize(&event, c.YAML_UTF8_ENCODING));
    try context.emit(&event);
    try context.initialized(c.yaml_document_start_event_initialize(&event, null, null, null, 1));
    try context.emit(&event);
    try context.node(input, 0);
    try context.initialized(c.yaml_document_end_event_initialize(&event, @intFromBool(!context.root_plain)));
    try context.emit(&event);
    try context.initialized(c.yaml_stream_end_event_initialize(&event));
    try context.emit(&event);
    if (context.failure) |err| return err;
    return try context.out.toOwnedSlice();
}

fn write(raw: ?*anyopaque, buffer: [*c]u8, size: usize) callconv(.c) c_int {
    const context: *Dumper = @ptrCast(@alignCast(raw.?));
    context.out.writer.writeAll(buffer[0..size]) catch |err| {
        context.failure = err;
        return 0;
    };
    return 1;
}

fn pointer(input: Value) ?usize {
    if (expression.integerProtocol(input) != null or expression.floatProtocol(input) != null or input.attribute("__dxt_binary") != .undefined) return null;
    return switch (input) {
        .list => |members| @intFromPtr(members.ptr),
        .tuple => |members| if (members.len == 0) null else @intFromPtr(members.ptr),
        .object => |entries| @intFromPtr(entries.ptr),
        else => null,
    };
}

const Dumper = struct {
    a: std.mem.Allocator,
    sorted: bool,
    syntax: c.yaml_emitter_t = undefined,
    out: std.Io.Writer.Allocating = undefined,
    failure: ?anyerror = null,
    anchors: std.ArrayList(Anchor) = .empty,
    next_anchor: usize = 0,
    depth: usize = 0,
    root_plain: bool = false,

    fn initialized(_: *Dumper, succeeded: c_int) !void {
        if (succeeded == 0) return error.OutOfMemory;
    }

    fn emit(self: *Dumper, event: *c.yaml_event_t) !void {
        if (c.yaml_emitter_emit(&self.syntax, event) == 0) return self.failure orelse error.InvalidYamlRepresentation;
    }

    fn entries(self: *Dumper, input: Value) ![]const expression.Entry {
        const result = try self.a.dupe(expression.Entry, input.object);
        if (self.sorted) @import("mapping_keys.zig").sortJsonKeys(self.a, result) catch |err| switch (err) {
            error.JinjaTypeError => @memcpy(result, input.object),
            else => return err,
        };
        return result;
    }

    fn count(self: *Dumper, input: Value, depth: usize) anyerror!void {
        if (depth > 256) return error.JinjaExpressionDepthExceeded;
        if (pointer(input)) |identity| {
            for (self.anchors.items) |*anchor| if (anchor.pointer == identity) {
                if (anchor.name == null) {
                    self.next_anchor += 1;
                    anchor.name = try std.fmt.allocPrintSentinel(self.a, "id{d:0>3}", .{self.next_anchor}, 0);
                }
                return;
            };
            try self.anchors.append(self.a, .{ .pointer = identity });
        }
        if (expression.integerProtocol(input) != null or expression.floatProtocol(input) != null) return;
        if (input.attribute("__dxt_yaml_timestamp") != .undefined or input.attribute("__dxt_binary") != .undefined) return;
        if (@import("set_context.zig").items(input)) |members| {
            for (members) |member| try self.count(member, depth + 1);
            return;
        }
        switch (input) {
            .list, .tuple => |members| for (members) |member| try self.count(member, depth + 1),
            .object => {
                if (input.attribute("__dxt_noniterable").truthy() or input.attribute("__dxt_relation") != .undefined or input.attribute("__dxt_sequence_kind") != .undefined or input.attribute("__dxt_iterable") != .undefined) return error.InvalidYamlRepresentation;
                for (try self.entries(input)) |entry| {
                    try self.count(expression.entryKey(entry), depth + 1);
                    try self.count(entry.value, depth + 1);
                }
            },
            .complex, .undefined, .conditional_undefined, .callable => return error.InvalidYamlRepresentation,
            else => {},
        }
    }

    fn scalar(self: *Dumper, anchor: [*c]const u8, tag: [:0]const u8, text: []const u8, style: c.yaml_scalar_style_t, plain: bool, quoted: bool) !void {
        if (text.len > std.math.maxInt(c_int)) return error.JinjaIterationLimitExceeded;
        var event: c.yaml_event_t = undefined;
        try self.initialized(c.yaml_scalar_event_initialize(&event, anchor, tag.ptr, text.ptr, @intCast(text.len), @intFromBool(plain), @intFromBool(quoted), style));
        try self.emit(&event);
        if (self.depth == 0) self.root_plain = self.syntax.scalar_data.style == c.YAML_PLAIN_SCALAR_STYLE;
    }

    fn node(self: *Dumper, input: Value, depth: usize) anyerror!void {
        if (depth > 256) return error.JinjaExpressionDepthExceeded;
        const previous_depth = self.depth;
        self.depth = depth;
        defer self.depth = previous_depth;
        var name: [*c]const u8 = null;
        if (pointer(input)) |identity| {
            for (self.anchors.items) |*anchor| if (anchor.pointer == identity) {
                if (anchor.emitted and anchor.name != null) {
                    var event: c.yaml_event_t = undefined;
                    try self.initialized(c.yaml_alias_event_initialize(&event, anchor.name.?.ptr));
                    return self.emit(&event);
                }
                anchor.emitted = true;
                if (anchor.name) |label| name = label.ptr;
                break;
            };
        }
        if (expression.integerProtocol(input)) |integer| return self.scalar(name, "tag:yaml.org,2002:int", integer, c.YAML_PLAIN_SCALAR_STYLE, true, false);
        if (expression.floatProtocol(input)) |number| {
            const text = if (std.math.isNan(number)) ".nan" else if (std.math.isInf(number)) (if (number < 0) "-.inf" else ".inf") else blk: {
                const rendered = try @import("expression_number.zig").floatText(self.a, number);
                if (std.mem.indexOfScalar(u8, rendered, '.') == null) if (std.mem.indexOfScalar(u8, rendered, 'e')) |exponent| break :blk try std.fmt.allocPrint(self.a, "{s}.0{s}", .{ rendered[0..exponent], rendered[exponent..] });
                break :blk rendered;
            };
            return self.scalar(name, "tag:yaml.org,2002:float", text, c.YAML_PLAIN_SCALAR_STYLE, true, false);
        }
        const timestamp = input.attribute("__dxt_yaml_timestamp");
        if (timestamp == .string) {
            const rendered = if (timestamp.string.len > 10) try std.fmt.allocPrint(self.a, "{s} {s}", .{ timestamp.string[0..10], timestamp.string[11..] }) else timestamp.string;
            return self.scalar(name, "tag:yaml.org,2002:timestamp", rendered, c.YAML_PLAIN_SCALAR_STYLE, true, false);
        }
        const binary = input.attribute("__dxt_binary");
        if (binary == .string) {
            const encoded = try self.a.alloc(u8, std.base64.standard.Encoder.calcSize(binary.string.len));
            _ = std.base64.standard.Encoder.encode(encoded, binary.string);
            var text: std.Io.Writer.Allocating = .init(self.a);
            var cursor: usize = 0;
            while (cursor < encoded.len) : (cursor += 76) {
                try text.writer.writeAll(encoded[cursor..@min(cursor + 76, encoded.len)]);
                try text.writer.writeByte('\n');
            }
            return self.scalar(null, "tag:yaml.org,2002:binary", text.written(), c.YAML_LITERAL_SCALAR_STYLE, false, false);
        }
        if (@import("set_context.zig").items(input)) |members| {
            var event: c.yaml_event_t = undefined;
            try self.initialized(c.yaml_mapping_start_event_initialize(&event, name, "tag:yaml.org,2002:set", 0, c.YAML_BLOCK_MAPPING_STYLE));
            try self.emit(&event);
            for (members) |member| {
                try self.node(member, depth + 1);
                try self.node(.none, depth + 1);
            }
            try self.initialized(c.yaml_mapping_end_event_initialize(&event));
            return self.emit(&event);
        }
        switch (input) {
            .none => try self.scalar(name, "tag:yaml.org,2002:null", "null", c.YAML_PLAIN_SCALAR_STYLE, true, false),
            .boolean => |boolean| try self.scalar(name, "tag:yaml.org,2002:bool", if (boolean) "true" else "false", c.YAML_PLAIN_SCALAR_STYLE, true, false),
            .integer => |integer| try self.scalar(name, "tag:yaml.org,2002:int", integer, c.YAML_PLAIN_SCALAR_STYLE, true, false),
            .string => |text| try self.scalar(name, "tag:yaml.org,2002:str", text, c.YAML_ANY_SCALAR_STYLE, @import("yaml.zig").resolvesAsString(text), true),
            .list, .tuple => |members| {
                var event: c.yaml_event_t = undefined;
                try self.initialized(c.yaml_sequence_start_event_initialize(&event, name, "tag:yaml.org,2002:seq", 1, c.YAML_BLOCK_SEQUENCE_STYLE));
                try self.emit(&event);
                for (members) |member| try self.node(member, depth + 1);
                try self.initialized(c.yaml_sequence_end_event_initialize(&event));
                try self.emit(&event);
            },
            .object => {
                var event: c.yaml_event_t = undefined;
                try self.initialized(c.yaml_mapping_start_event_initialize(&event, name, "tag:yaml.org,2002:map", 1, c.YAML_BLOCK_MAPPING_STYLE));
                try self.emit(&event);
                for (try self.entries(input)) |entry| {
                    try self.node(expression.entryKey(entry), depth + 1);
                    try self.node(entry.value, depth + 1);
                }
                try self.initialized(c.yaml_mapping_end_event_initialize(&event));
                try self.emit(&event);
            },
            else => return error.InvalidYamlRepresentation,
        }
    }
};

test "context YAML dump emits block collections quoted schema strings and repeated anchors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = try expression.evaluate(a, "{'values':[true,none,1,1.0],'str':'yes'}", null);
    try std.testing.expectEqualStrings("values:\n- true\n- null\n- 1\n- 1.0\nstr: 'yes'\n", try dump(a, data, false));
    const aliased = try @import("yaml_context.zig").load(a, "{first: &items [1], second: *items}");
    try std.testing.expectEqualStrings("first: &id001\n- 1\nsecond: *id001\n", try dump(a, aliased, false));
}
