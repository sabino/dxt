//! Python tuple/dictionary-view/consuming-zip protocols in native values.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
threadlocal var pull_depth: usize = 0;

pub fn kind(value: Value) ?[]const u8 {
    const native = value.attribute("__dxt_native_sequence");
    if (native != .callable or !std.mem.eql(u8, native.callable, "__dxt_native_sequence")) return null;
    const marker = value.attribute("__dxt_sequence_kind");
    return if (marker == .string) marker.string else null;
}

/// An internal callable distinguishes native descriptors from authored map literals.
pub fn descriptor(a: std.mem.Allocator, fields: []const expression.Entry) !Value {
    const entries = try expression.allocateEntries(a, fields.len + 1);
    @memcpy(entries[0..fields.len], fields);
    entries[fields.len] = .{ .key = "__dxt_native_sequence", .value = .{ .callable = "__dxt_native_sequence" } };
    return .{ .object = entries };
}

pub fn view(a: std.mem.Allocator, object: Value, name: []const u8) !Value {
    const entries = try expression.allocateEntries(a, 2);
    entries[0] = .{ .key = "__dxt_sequence_kind", .value = .{ .string = name } };
    entries[1] = .{ .key = "__dxt_sequence_source", .value = object };
    return descriptor(a, entries);
}

pub fn zip(a: std.mem.Allocator, inputs: []const Value) !Value {
    const entries = try expression.allocateEntries(a, 3);
    entries[0] = .{ .key = "__dxt_sequence_kind", .value = .{ .string = "zip" } };
    const iterators = try expression.allocateValues(a, inputs.len);
    for (inputs, iterators) |input, *output| output.* = try iter(a, input);
    entries[1] = .{ .key = "__dxt_sequence_source", .value = .{ .list = iterators } };
    const cursors = try expression.allocateValues(a, inputs.len);
    for (cursors) |*cursor| cursor.* = .{ .integer = "0" };
    entries[2] = .{ .key = "__dxt_sequence_cursor", .value = .{ .list = cursors } };
    return descriptor(a, entries);
}

pub fn iterator(a: std.mem.Allocator, values: []const Value) !Value {
    const entries = try expression.allocateEntries(a, 3);
    entries[0] = .{ .key = "__dxt_sequence_kind", .value = .{ .string = "iterator" } };
    entries[1] = .{ .key = "__dxt_sequence_source", .value = .{ .list = values } };
    entries[2] = .{ .key = "__dxt_sequence_cursor", .value = .{ .integer = "0" } };
    return descriptor(a, entries);
}

pub fn isIterator(value: Value) bool {
    const name = kind(value) orelse return false;
    return std.mem.eql(u8, name, "iterator") or std.mem.eql(u8, name, "zip") or std.mem.startsWith(u8, name, "itertools_") or std.mem.startsWith(u8, name, "filter_");
}

/// Creating an iterator is non-consuming; aliases share each one-shot cursor.
pub fn iter(a: std.mem.Allocator, input: Value) !Value {
    if (@import("builtin_bound_method.zig").isRelationMapping(input)) return error.JinjaTypeError;
    if (isIterator(input)) return input;
    if (!expression.isIterable(input)) return error.JinjaTypeError;
    const entries = try expression.allocateEntries(a, 3);
    entries[0] = .{ .key = "__dxt_sequence_kind", .value = .{ .string = "iterator" } };
    entries[1] = .{ .key = "__dxt_sequence_source", .value = input };
    entries[2] = .{ .key = "__dxt_sequence_cursor", .value = .{ .integer = "0" } };
    return descriptor(a, entries);
}

pub fn next(a: std.mem.Allocator, value: Value, host: ?expression.Host) anyerror!?Value {
    if (pull_depth == 128) return error.JinjaExpressionDepthExceeded;
    pull_depth += 1;
    defer pull_depth -= 1;
    const name = kind(value) orelse return error.JinjaTypeError;
    if (std.mem.eql(u8, name, "iterator")) return nextIterator(a, value, host);
    if (std.mem.eql(u8, name, "zip")) return nextZip(a, value, host);
    if (std.mem.startsWith(u8, name, "itertools_")) return @import("itertools_context.zig").pull(a, value, host);
    if (std.mem.startsWith(u8, name, "filter_")) return @import("expression_filter_iterator.zig").pull(a, value, host);
    // No native callback pointers are stored in authored expression values.
    return error.UnsupportedJinjaIterator;
}

fn cursorAdvance(a: std.mem.Allocator, value: Value, position: usize) !void {
    for (@constCast(value.object)) |*entry| if (std.mem.eql(u8, entry.key, "__dxt_sequence_cursor")) {
        entry.value = try expression.integerValue(a, position);
        return;
    };
    return error.InvalidJinjaIterator;
}
fn nextIterator(a: std.mem.Allocator, value: Value, host: ?expression.Host) !?Value {
    const source = value.attribute("__dxt_sequence_source");
    const index: usize = @intCast(try expression.integerIndex(value.attribute("__dxt_sequence_cursor")));
    if (source == .string) {
        if (index >= source.string.len) return null;
        const size = std.unicode.utf8ByteSequenceLength(source.string[index]) catch return error.JinjaTypeError;
        if (index + size > source.string.len) return error.JinjaTypeError;
        _ = std.unicode.utf8Decode(source.string[index .. index + size]) catch return error.JinjaTypeError;
        try cursorAdvance(a, value, index + size);
        return .{ .string = source.string[index .. index + size] };
    }
    if (expression.sequence(source)) |members| {
        if (index >= members.len) return null;
        try cursorAdvance(a, value, index + 1);
        return members[index];
    }
    if (source == .object) {
        var mapping = expression.mappingSource(source) orelse source;
        const view_name = kind(source);
        if (view_name != null) mapping = source.attribute("__dxt_sequence_source");
        if (mapping != .object) return error.JinjaTypeError;
        mapping = expression.mappingSource(mapping) orelse mapping;
        const entries = try @import("builtin_bound_method.zig").mappingEntries(mapping);
        if (index >= entries.len) return null;
        const entry = entries[index];
        try cursorAdvance(a, value, index + 1);
        if (view_name) |name| {
            if (std.mem.eql(u8, name, "values")) return entry.value;
            if (std.mem.eql(u8, name, "items")) {
                const pair = try expression.allocateValues(a, 2);
                pair[0] = expression.entryKey(entry);
                pair[1] = entry.value;
                return .{ .tuple = pair };
            }
        }
        return expression.entryKey(entry);
    }
    const members = try expression.iterableValuesWithHost(a, source, host);
    if (index >= members.len) return null;
    try cursorAdvance(a, value, index + 1);
    return members[index];
}

fn viewItems(a: std.mem.Allocator, value: Value, name: []const u8) ![]const Value {
    const source = value.attribute("__dxt_sequence_source");
    if (source != .object) return error.JinjaTypeError;
    const entries = try @import("builtin_bound_method.zig").mappingEntries(source);
    const values = try expression.allocateValues(a, entries.len);
    for (entries, values) |entry, *result| {
        if (std.mem.eql(u8, name, "keys")) result.* = expression.entryKey(entry) else if (std.mem.eql(u8, name, "values")) result.* = entry.value else {
            const pair = try expression.allocateValues(a, 2);
            pair[0] = expression.entryKey(entry);
            pair[1] = entry.value;
            result.* = .{ .tuple = pair };
        }
    }
    return values;
}

pub fn items(a: std.mem.Allocator, value: Value) !?[]const Value {
    return itemsWithHost(a, value, null);
}

pub fn itemsWithHost(a: std.mem.Allocator, value: Value, host: ?expression.Host) !?[]const Value {
    const name = kind(value) orelse return null;
    if (!isIterator(value)) return try viewItems(a, value, name);
    var rows: std.ArrayList(Value) = .empty;
    errdefer rows.deinit(a);
    while (try next(a, value, host)) |row| {
        if (rows.items.len == 100000) return error.JinjaIterationLimitExceeded;
        try rows.append(a, row);
    }
    return try rows.toOwnedSlice(a);
}

fn nextZip(a: std.mem.Allocator, value: Value, host: ?expression.Host) anyerror!?Value {
    const source = value.attribute("__dxt_sequence_source");
    const cursor_value = value.attribute("__dxt_sequence_cursor");
    if (source != .list or cursor_value != .list or source.list.len != cursor_value.list.len) return error.JinjaTypeError;
    if (source.list.len == 0) return null;
    const fields = try expression.allocateValues(a, source.list.len);
    for (source.list, fields) |input, *field| {
        field.* = (try next(a, input, host)) orelse return null;
    }
    return .{ .tuple = fields };
}

pub fn text(a: std.mem.Allocator, value: Value) !?[]const u8 {
    return textWithHost(a, value, null);
}

pub fn textWithHost(a: std.mem.Allocator, value: Value, host: ?expression.Host) anyerror!?[]const u8 {
    const name = kind(value) orelse return null;
    if (std.mem.startsWith(u8, name, "itertools_")) return @import("itertools_context.zig").renderWithHost(a, value, host);
    if (isIterator(value)) {
        var label: []const u8 = "zip";
        if (std.mem.eql(u8, name, "iterator")) {
            const source = value.attribute("__dxt_sequence_source");
            label = switch (source) {
                .list => "list_iterator",
                .tuple => "tuple_iterator",
                .string => "str_iterator",
                .object => blk: {
                    if (@import("set_context.zig").isSet(source)) break :blk "set_iterator";
                    if (source.attribute("__dxt_binary") == .string) break :blk "bytes_iterator";
                    const view_kind = kind(source);
                    if (view_kind) |view_name| {
                        if (std.mem.eql(u8, view_name, "values")) break :blk "dict_valueiterator";
                        if (std.mem.eql(u8, view_name, "items")) break :blk "dict_itemiterator";
                    }
                    break :blk "dict_keyiterator";
                },
                else => "tuple_iterator",
            };
        } else if (std.mem.startsWith(u8, name, "filter_")) {
            const function = if (std.mem.eql(u8, name, "filter_map")) "sync_do_map" else if (std.mem.eql(u8, name, "filter_unique")) "sync_do_unique" else if (std.mem.eql(u8, name, "filter_batch")) "do_batch" else if (std.mem.eql(u8, name, "filter_slice")) "sync_do_slice" else "select_or_reject";
            return try std.fmt.allocPrint(a, "<generator object {s} at 0x{x}>", .{ function, @intFromPtr(value.object.ptr) });
        }
        return try std.fmt.allocPrint(a, "<{s} object at 0x{x}>", .{ label, @intFromPtr(value.object.ptr) });
    }
    const source = value.attribute("__dxt_sequence_source");
    if (@import("builtin_bound_method.zig").isRelationMapping(source)) {
        const class_name = if (std.mem.eql(u8, name, "keys")) "KeysView" else if (std.mem.eql(u8, name, "values")) "ValuesView" else "ItemsView";
        return try std.fmt.allocPrint(a, "{s}({s})", .{ class_name, try expression.repr(source, a) });
    }
    const values = try viewItems(a, value, name);
    return try std.fmt.allocPrint(a, "dict_{s}({s})", .{ name, try expression.textWithHost(a, .{ .list = values }, host) });
}

pub fn length(value: Value) !?usize {
    _ = kind(value) orelse return null;
    if (isIterator(value)) return error.JinjaTypeError;
    const source = value.attribute("__dxt_sequence_source");
    if (@import("builtin_bound_method.zig").isRelationMapping(source)) return error.JinjaTypeError;
    return if (source == .object) source.object.len else error.JinjaTypeError;
}

pub fn truthy(value: Value) ?bool {
    _ = kind(value) orelse return null;
    if (isIterator(value)) return true;
    return (length(value) catch 0 orelse 0) != 0;
}

test "native pull iterators share cursors and zip consumes only one row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = Value{ .tuple = &.{ .{ .integer = "1" }, .{ .integer = "2" }, .{ .integer = "3" }, .{ .integer = "4" } } };
    const stream = try iter(a, input);
    const alias = try iter(a, stream);
    try std.testing.expectEqualStrings("1", (try next(a, stream, null)).?.integer);
    try std.testing.expectEqualStrings("2", (try next(a, alias, null)).?.integer);
    const zipped = try zip(a, &.{ stream, stream });
    try std.testing.expectEqualStrings("(3, 4)", try (try next(a, zipped, null)).?.text(a));
    try std.testing.expect((try next(a, zipped, null)) == null);
    try std.testing.expect((try next(a, stream, null)) == null);
    const characters = try iter(a, .{ .string = "a\u{1f600}" });
    try std.testing.expectEqualStrings("a", (try next(a, characters, null)).?.string);
    try std.testing.expectEqualStrings("\u{1f600}", (try next(a, characters, null)).?.string);
    try std.testing.expectError(error.JinjaTypeError, iter(a, .none));
}

test "pulling reusable text allocates one cursor without rebuilding all characters" {
    var storage: [32768]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const a = fixed.allocator();
    const input: [4096]u8 = @splat('x');
    const source = try iter(a, .{ .string = &input });
    var count: usize = 0;
    while (try next(a, source, null)) |item| {
        try std.testing.expectEqualStrings("x", item.string);
        count += 1;
    }
    try std.testing.expectEqual(input.len, count);
}

test "iterator rendering retains state and public representation shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = try iter(a, .{ .tuple = &.{.{ .integer = "7" }} });
    const rendered = (try textWithHost(a, input, null)).?;
    try std.testing.expect(std.mem.startsWith(u8, rendered, "<tuple_iterator object at 0x"));
    try std.testing.expectEqualStrings("7", (try next(a, input, null)).?.integer);
    try std.testing.expectEqualStrings(rendered, (try textWithHost(a, input, null)).?);
    const count = (try @import("itertools_context.zig").call(a, "__dxt_itertools:count", &.{.{ .value = .{ .integer = "3" } }}, null)).?;
    try std.testing.expectEqualStrings("count(3)", try expression.textWithHost(a, count, null));
    _ = try next(a, count, null);
    try std.testing.expectEqualStrings("count(4)", try expression.textWithHost(a, count, null));
}
