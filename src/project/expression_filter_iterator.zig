//! One-shot Jinja generators. Deferred work is pulled with the consumer's Host.
const std = @import("std");
const expression = @import("expression.zig");
const sequence = @import("expression_sequence.zig");
const attributes = @import("filter_attributes.zig");
const keys = @import("mapping_keys.zig");
const Value = expression.Value;
const Argument = expression.Argument;

fn set(value: Value, name: []const u8, replacement: Value) void {
    for (@constCast(value.object)) |*entry| if (std.mem.eql(u8, entry.key, name)) {
        entry.value = replacement;
        return;
    };
    unreachable;
}
fn get(value: Value, name: []const u8) Value {
    return value.attribute(name);
}
fn descriptor(a: std.mem.Allocator, name: []const u8, input: Value, args: []const Argument, bound: []const Value) !Value {
    const encoded = try expression.allocateValues(a, args.len);
    for (args, encoded) |arg, *out| {
        const entry = try expression.allocateEntries(a, 2);
        entry[0] = .{ .key = "name", .value = if (arg.name) |key| .{ .string = key } else .none };
        entry[1] = .{ .key = "value", .value = arg.value };
        out.* = .{ .object = entry };
    }
    const fields = [_]expression.Entry{
        .{ .key = "__dxt_sequence_kind", .value = .{ .string = name } },
        .{ .key = "__dxt_filter_source", .value = input },
        .{ .key = "__dxt_filter_arguments", .value = .{ .list = encoded } },
        .{ .key = "__dxt_filter_bound", .value = .{ .list = try a.dupe(Value, bound) } },
        .{ .key = "__dxt_filter_initialized", .value = .{ .boolean = false } },
        .{ .key = "__dxt_filter_done", .value = .{ .boolean = false } },
        .{ .key = "__dxt_filter_iterator", .value = .undefined },
        .{ .key = "__dxt_filter_path", .value = .{ .list = &.{} } },
        .{ .key = "__dxt_filter_fallback", .value = .none },
        .{ .key = "__dxt_filter_operation", .value = .none },
        .{ .key = "__dxt_filter_uses_operation", .value = .{ .boolean = false } },
        .{ .key = "__dxt_filter_params", .value = .{ .list = &.{} } },
        .{ .key = "__dxt_filter_seen", .value = .{ .list = &.{} } },
        .{ .key = "__dxt_filter_buffer", .value = .{ .list = &.{} } },
        .{ .key = "__dxt_filter_cursor", .value = .{ .integer = "0" } },
        .{ .key = "__dxt_filter_buffer_storage", .value = .{ .list = &.{} } },
        .{ .key = "__dxt_filter_seen_storage", .value = .{ .list = &.{} } },
    };
    return sequence.descriptor(a, &fields);
}
fn unpack(a: std.mem.Allocator, encoded: []const Value) ![]Argument {
    const args = try a.alloc(Argument, encoded.len);
    for (encoded, args) |item, *arg| {
        const name = item.attribute("name");
        arg.* = .{ .name = if (name == .string) name.string else null, .value = item.attribute("value") };
    }
    return args;
}
pub fn map(a: std.mem.Allocator, input: Value, args: []const Argument) !Value {
    return descriptor(a, "filter_map", input, args, &.{});
}
pub fn select(a: std.mem.Allocator, input: Value, args: []const Argument, attribute: bool, reject: bool) !Value {
    return descriptor(a, "filter_select", input, args, &.{ .{ .boolean = attribute }, .{ .boolean = reject } });
}
pub fn unique(a: std.mem.Allocator, input: Value, args: []const Argument) !Value {
    const bound = try @import("filter_arguments.zig").bind(a, args, &.{ "case_sensitive", "attribute" }, &.{ .{ .boolean = false }, .none }, 0);
    return descriptor(a, "filter_unique", input, &.{}, bound);
}
pub fn batch(a: std.mem.Allocator, input: Value, args: []const Argument) !Value {
    const bound = try @import("filter_arguments.zig").bind(a, args, &.{ "linecount", "fill_with" }, &.{ .undefined, .none }, 1);
    return descriptor(a, "filter_batch", input, &.{}, bound);
}
pub fn slice(a: std.mem.Allocator, input: Value, args: []const Argument) !Value {
    const bound = try @import("filter_arguments.zig").bind(a, args, &.{ "slices", "fill_with" }, &.{ .undefined, .none }, 1);
    return descriptor(a, "filter_slice", input, &.{}, bound);
}
fn initialize(a: std.mem.Allocator, value: Value, name: []const u8, host: ?expression.Host) !void {
    set(value, "__dxt_filter_initialized", .{ .boolean = true });
    const source = get(value, "__dxt_filter_source");
    if (std.mem.eql(u8, name, "filter_map") or std.mem.eql(u8, name, "filter_select")) {
        if (!source.truthy()) {
            set(value, "__dxt_filter_done", .{ .boolean = true });
            return;
        }
        const encoded = get(value, "__dxt_filter_arguments").list;
        const args = try unpack(a, encoded);
        var positional: std.ArrayList(Argument) = .empty;
        var keyword: std.ArrayList(Argument) = .empty;
        for (args) |arg| {
            if (arg.name == null) try positional.append(a, arg) else try keyword.append(a, arg);
        }
        if (std.mem.eql(u8, name, "filter_map")) {
            var attr: ?Value = null;
            for (keyword.items) |arg| if (std.mem.eql(u8, arg.name.?, "attribute")) {
                attr = arg.value;
                break;
            };
            if (positional.items.len == 0 and attr != null) {
                var fallback: Value = .none;
                for (keyword.items) |arg| {
                    if (std.mem.eql(u8, arg.name.?, "default")) fallback = arg.value else if (!std.mem.eql(u8, arg.name.?, "attribute")) return error.InvalidJinjaArguments;
                }
                set(value, "__dxt_filter_path", .{ .list = try attributes.parts(a, attr.?) });
                set(value, "__dxt_filter_fallback", fallback);
            } else {
                if (positional.items.len == 0) return error.InvalidJinjaArguments;
                set(value, "__dxt_filter_operation", positional.items[0].value);
                set(value, "__dxt_filter_uses_operation", .{ .boolean = true });
                // Keep forwarded positional and keyword parameters in their authored order.
                var params: std.ArrayList(Value) = .empty;
                var removed = false;
                for (encoded) |arg| {
                    if (!removed and arg.attribute("name") == .none) {
                        removed = true;
                        continue;
                    }
                    try params.append(a, arg);
                }
                set(value, "__dxt_filter_params", .{ .list = try params.toOwnedSlice(a) });
            }
        } else {
            const lookup = get(value, "__dxt_filter_bound").list[0].boolean;
            const offset: usize = if (lookup) 1 else 0;
            if (lookup and positional.items.len == 0) return error.InvalidJinjaArguments;
            if (lookup) set(value, "__dxt_filter_path", .{ .list = try attributes.parts(a, positional.items[0].value) });
            if (positional.items.len > offset) {
                set(value, "__dxt_filter_operation", positional.items[offset].value);
                set(value, "__dxt_filter_uses_operation", .{ .boolean = true });
                var params: std.ArrayList(Value) = .empty;
                var removed: usize = 0;
                for (encoded) |arg| {
                    if (arg.attribute("name") == .none and removed < offset + 1) {
                        removed += 1;
                        continue;
                    }
                    try params.append(a, arg);
                }
                set(value, "__dxt_filter_params", .{ .list = try params.toOwnedSlice(a) });
            }
        }
    } else if (std.mem.eql(u8, name, "filter_unique")) {
        set(value, "__dxt_filter_path", .{ .list = try attributes.parts(a, get(value, "__dxt_filter_bound").list[1]) });
    }
    if (std.mem.eql(u8, name, "filter_slice")) {
        const members = try expression.iterableValuesWithHost(a, source, host);
        const count = get(value, "__dxt_filter_bound").list[0];
        // Python range requires an index, including when the input is empty.
        if (count == .boolean and !count.boolean or count == .integer and expression.equalValues(count, .{ .integer = "0" }) or expression.floatProtocol(count) != null and try expression.numericFloat(count) == 0) return error.JinjaDivisionByZero;
        const size = try expression.integerIndex(count);
        if (size > 100000) return error.JinjaIterationLimitExceeded;
        set(value, "__dxt_filter_cursor", .{ .integer = "0" });
        set(value, "__dxt_filter_buffer", .{ .list = members });
        if (size < 0) set(value, "__dxt_filter_done", .{ .boolean = true });
        return;
    }
    set(value, "__dxt_filter_iterator", try sequence.iter(a, source));
}
fn append(a: std.mem.Allocator, value: Value, field: []const u8, item: Value) !void {
    const old = get(value, field).list;
    if (old.len == 100000) return error.JinjaIterationLimitExceeded;
    const storage_field = if (std.mem.eql(u8, field, "__dxt_filter_buffer")) "__dxt_filter_buffer_storage" else "__dxt_filter_seen_storage";
    var storage = get(value, storage_field).list;
    if (storage.len == old.len) {
        const replacement = try expression.allocateValues(a, @min(100000, @max(@as(usize, 16), storage.len * 2)));
        @memcpy(replacement[0..old.len], old);
        storage = replacement;
        set(value, storage_field, .{ .list = storage });
    }
    @constCast(storage)[old.len] = item;
    set(value, field, .{ .list = storage[0 .. old.len + 1] });
}

pub fn pull(a: std.mem.Allocator, value: Value, host: ?expression.Host) anyerror!?Value {
    if (get(value, "__dxt_filter_done").truthy()) return null;
    errdefer set(value, "__dxt_filter_done", .{ .boolean = true });
    const name = sequence.kind(value) orelse return error.JinjaTypeError;
    if (!get(value, "__dxt_filter_initialized").truthy()) try initialize(a, value, name, host);
    if (get(value, "__dxt_filter_done").truthy()) return null;
    if (std.mem.eql(u8, name, "filter_slice")) {
        const bound = get(value, "__dxt_filter_bound").list;
        const size: usize = @intCast(try expression.integerIndex(bound[0]));
        const at: usize = @intCast(try expression.integerIndex(get(value, "__dxt_filter_cursor")));
        if (at >= size) {
            set(value, "__dxt_filter_done", .{ .boolean = true });
            return null;
        }
        const members = get(value, "__dxt_filter_buffer").list;
        const per = members.len / size;
        const extra = members.len % size;
        const start = at * per + @min(at, extra);
        const end = (at + 1) * per + @min(at + 1, extra);
        const padded = bound[1] != .none and at >= extra;
        const result = try expression.allocateValues(a, end - start + @intFromBool(padded));
        @memcpy(result[0 .. end - start], members[start..end]);
        if (padded) result[result.len - 1] = bound[1];
        set(value, "__dxt_filter_cursor", try expression.integerValue(a, at + 1));
        return .{ .list = result };
    }
    if (std.mem.eql(u8, name, "filter_batch")) {
        const bound = get(value, "__dxt_filter_bound").list;
        while (try sequence.next(a, get(value, "__dxt_filter_iterator"), host)) |row| {
            const buffer = get(value, "__dxt_filter_buffer");
            if (expression.equalValues(try expression.integerValue(a, buffer.list.len), bound[0])) {
                set(value, "__dxt_filter_buffer", .{ .list = &.{} });
                set(value, "__dxt_filter_buffer_storage", .{ .list = &.{} });
                try append(a, value, "__dxt_filter_buffer", row);
                return buffer;
            }
            try append(a, value, "__dxt_filter_buffer", row);
        }
        set(value, "__dxt_filter_done", .{ .boolean = true });
        var buffer = get(value, "__dxt_filter_buffer");
        if (buffer.list.len == 0) return null;
        const should_pad = if (bound[1] == .none) false else blk: {
            const order = expression.valueOrder(a, try expression.integerValue(a, buffer.list.len), bound[0]) catch |err| {
                if (err == error.UnorderedJinjaNumber) break :blk false;
                return err;
            };
            break :blk order == .lt;
        };
        if (should_pad) {
            const count = try expression.integerIndex(bound[0]);
            if (count > 100000) return error.JinjaIterationLimitExceeded;
            while (get(value, "__dxt_filter_buffer").list.len < count) try append(a, value, "__dxt_filter_buffer", bound[1]);
            buffer = get(value, "__dxt_filter_buffer");
        }
        return buffer;
    }
    while (try sequence.next(a, get(value, "__dxt_filter_iterator"), host)) |row| {
        const operation = get(value, "__dxt_filter_operation");
        if (std.mem.eql(u8, name, "filter_map")) {
            if (!get(value, "__dxt_filter_uses_operation").truthy()) return try attributes.get(a, row, get(value, "__dxt_filter_path").list, get(value, "__dxt_filter_fallback"), host);
            if (operation != .string) return error.UnsupportedJinjaFilter;
            return try expression.filterValue(a, operation.string, row, try unpack(a, get(value, "__dxt_filter_params").list), host);
        }
        if (std.mem.eql(u8, name, "filter_select")) {
            const tested = try attributes.get(a, row, get(value, "__dxt_filter_path").list, .none, host);
            const accepted = if (!get(value, "__dxt_filter_uses_operation").truthy()) tested.truthy() else blk: {
                if (operation != .string) return error.UnsupportedJinjaTest;
                break :blk try expression.testValueWithHost(a, operation.string, tested, try unpack(a, get(value, "__dxt_filter_params").list), host);
            };
            if (accepted != get(value, "__dxt_filter_bound").list[1].boolean) return row;
            continue;
        }
        if (std.mem.eql(u8, name, "filter_unique")) {
            var key = try attributes.get(a, row, get(value, "__dxt_filter_path").list, .none, host);
            if (!get(value, "__dxt_filter_bound").list[0].truthy() and key == .string) key = .{ .string = try @import("expression_unicode.zig").convert(a, key.string, .lower) };
            try keys.hashable(key);
            var duplicate = false;
            for (get(value, "__dxt_filter_seen").list) |seen| if (keys.keyEqual(seen, key)) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            try append(a, value, "__dxt_filter_seen", key);
            return row;
        }
        return error.UnsupportedJinjaIterator;
    }
    set(value, "__dxt_filter_done", .{ .boolean = true });
    return null;
}

test "filter generators share aliases and defer errors until a row is requested" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = Value{ .list = &.{ .{ .string = "A" }, .{ .string = "B" } } };
    const stream = try map(a, values, &.{.{ .value = .{ .string = "lower" } }});
    const alias = try sequence.iter(a, stream);
    try std.testing.expectEqualStrings("a", (try sequence.next(a, stream, null)).?.string);
    try std.testing.expectEqualStrings("b", (try sequence.next(a, alias, null)).?.string);
    try std.testing.expect((try sequence.next(a, stream, null)) == null);
    const failure = try map(a, values, &.{.{ .value = .{ .string = "nonexistent" } }});
    try std.testing.expectError(error.UnsupportedJinjaFilter, sequence.next(a, failure, null));
    try std.testing.expect((try sequence.next(a, failure, null)) == null);
    try std.testing.expect((try sequence.next(a, try map(a, .none, &.{}), null)) == null);
}

test "batch keeps its lookahead and slice padding follows Core distribution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try sequence.iter(a, .{ .list = &.{ .{ .integer = "1" }, .{ .integer = "2" }, .{ .integer = "3" }, .{ .integer = "4" } } });
    const batches = try batch(a, source, &.{.{ .value = .{ .integer = "2" } }});
    try std.testing.expectEqualStrings("[1, 2]", try (try sequence.next(a, batches, null)).?.text(a));
    try std.testing.expectEqualStrings("4", (try sequence.next(a, source, null)).?.integer);
    try std.testing.expectEqualStrings("[3]", try (try sequence.next(a, batches, null)).?.text(a));
    try std.testing.expect((try sequence.next(a, batches, null)) == null);
    const slices = try slice(a, .{ .list = &.{ .{ .integer = "1" }, .{ .integer = "2" }, .{ .integer = "3" }, .{ .integer = "4" } } }, &.{ .{ .value = .{ .integer = "2" } }, .{ .value = .{ .string = "x" } } });
    try std.testing.expectEqualStrings("[1, 2, 'x']", try (try sequence.next(a, slices, null)).?.text(a));
    try std.testing.expectEqualStrings("[3, 4, 'x']", try (try sequence.next(a, slices, null)).?.text(a));
    try std.testing.expect((try sequence.next(a, slices, null)) == null);
}

test "unique preserves hash keys and map defaults apply at each path segment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const stream = try unique(a, .{ .list = &.{ .{ .integer = "1" }, .{ .boolean = true }, .{ .number = 1.0 }, .{ .integer = "2" } } }, &.{});
    try std.testing.expectEqualStrings("1", (try sequence.next(a, stream, null)).?.integer);
    try std.testing.expectEqualStrings("2", (try sequence.next(a, stream, null)).?.integer);
    try std.testing.expect((try sequence.next(a, stream, null)) == null);
    const invalid = try unique(a, .{ .list = &.{.{ .list = &.{} }} }, &.{});
    try std.testing.expectError(error.JinjaTypeError, sequence.next(a, invalid, null));
    try std.testing.expect((try sequence.next(a, invalid, null)) == null);
    const mapped = try expression.evaluate(a, "[{}] | map(attribute='a.b',default={'b':7}) | list", null);
    try std.testing.expectEqualStrings("[7]", try mapped.text(a));
}
