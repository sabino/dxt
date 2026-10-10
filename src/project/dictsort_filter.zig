//! Jinja's stable dictionary sorting retains the original typed item pairs.
const std = @import("std");
const expression = @import("expression.zig");
const arguments = @import("filter_arguments.zig");
const unicode = @import("expression_unicode.zig");
const Value = expression.Value;

pub fn apply(a: std.mem.Allocator, value: Value, args: []const expression.Argument, host: ?expression.Host) !Value {
    const bound = try arguments.bind(a, args, &.{ "case_sensitive", "by", "reverse" }, &.{ .{ .boolean = false }, .{ .string = "key" }, .{ .boolean = false } }, 0);
    const position: Value = if (expression.equalValues(bound[1], .{ .string = "key" }))
        .{ .integer = "0" }
    else if (expression.equalValues(bound[1], .{ .string = "value" }))
        .{ .integer = "1" }
    else
        return error.InvalidJinjaArguments;

    // Invoke the real items method rather than treating every object carrier
    // as a dictionary. Providers retain their public methods and restrictions.
    const method = try expression.attributeWithHost(a, value, "items", host);
    const iterable = try expression.callValue(a, method, &.{}, host);
    const reverse = try expression.truthyWithHost(a, bound[2], host);
    const pairs = try expression.iterableValuesWithHost(a, iterable, host);
    const Item = struct { pair: Value, key: Value };
    const items = try a.alloc(Item, pairs.len);
    for (pairs, items) |pair, *item| {
        var key = try expression.indexValueWithHost(a, pair, position, host);
        if (!try expression.truthyWithHost(a, bound[0], host) and key == .string) key = .{ .string = try unicode.convert(a, key.string, .lower) };
        item.* = .{ .pair = pair, .key = key };
    }
    var failure: ?anyerror = null;
    const Context = struct {
        allocator: std.mem.Allocator,
        failure: *?anyerror,
        fn less(context: @This(), left: Item, right: Item) bool {
            const order = expression.valueOrder(context.allocator, left.key, right.key) catch |err| {
                if (err != error.UnorderedJinjaNumber) context.failure.* = err;
                return false;
            };
            return order == .lt;
        }
    };
    const context = Context{ .allocator = a, .failure = &failure };
    // Python reverses the input and final output so ties retain their original
    // order. This also preserves its false comparisons for unordered floats.
    if (reverse) std.mem.reverse(Item, items);
    if (items.len < 64) {
        // Python's short sort keeps an already ascending natural run intact,
        // then inserts remaining keys after equal ones. A sorting network can
        // reorder a NaN-separated run even though all adjacent tests are false.
        var run: usize = @min(2, items.len);
        if (items.len >= 2) {
            const descending = Context.less(context, items[1], items[0]);
            while (run < items.len) : (run += 1) {
                if (Context.less(context, items[run], items[run - 1]) != descending) break;
            }
            if (descending) std.mem.reverse(Item, items[0..run]);
        }
        for (run..items.len) |at| {
            const item = items[at];
            var left: usize = 0;
            var right = at;
            while (left < right) {
                const middle = left + (right - left) / 2;
                if (Context.less(context, item, items[middle])) right = middle else left = middle + 1;
            }
            std.mem.copyBackwards(Item, items[left + 1 .. at + 1], items[left..at]);
            items[left] = item;
        }
    } else std.sort.block(Item, items, context, Context.less);
    if (reverse) std.mem.reverse(Item, items);
    if (failure) |err| return err;
    const result = try a.alloc(Value, items.len);
    for (items, result) |item, *pair| pair.* = item.pair;
    return .{ .list = result };
}

test "dictsort preserves original tuple items and stable Unicode ties" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sorted = try expression.evaluate(a, "{'É':1,'é':2,'A':3,'a':4}|dictsort(reverse=true)", null);
    try std.testing.expectEqualStrings("[('É', 1), ('é', 2), ('A', 3), ('a', 4)]", try sorted.text(a));
    for (sorted.list) |pair| try std.testing.expect(pair == .tuple and pair.tuple.len == 2);
    try std.testing.expectEqualStrings("[('A', 3), ('a', 4), ('É', 1), ('é', 2)]", try (try expression.evaluate(a, "{'É':1,'é':2,'A':3,'a':4}|dictsort(true)", null)).text(a));
    try std.testing.expectEqualStrings("[(9007199254740992, 'first'), (9007199254740993, 'second')]", try (try expression.evaluate(a, "{9007199254740993:'second',9007199254740992:'first'}|dictsort", null)).text(a));
    try std.testing.expectEqualStrings("[('a', 'a'), ('b', 'A'), ('c', 'z')]", try (try expression.evaluate(a, "{'a':'a','b':'A','c':'z'}|dictsort(by='value')", null)).text(a));
    const child: Value = .{ .list = try a.dupe(Value, &.{.{ .integer = "7" }}) };
    const mapping: Value = .{ .object = &.{.{ .key = "a", .value = child }} };
    const kept = try apply(a, mapping, &.{}, null);
    try std.testing.expect(kept.list[0].tuple[1].list.ptr == child.list.ptr);
}

test "dictsort uses builtin items and rejects closed provider metadata and invalid arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("[('__dxt_context_object', 'ordinary'), ('items', 3)]", try (try expression.evaluate(a, "{'items':3,'__dxt_context_object':'ordinary'}|dictsort", null)).text(a));
    try std.testing.expectError(error.UndefinedJinjaValue, apply(a, .{ .object = &.{
        .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
        .{ .key = "private", .value = .{ .integer = "1" } },
    } }, &.{}, null));
    try std.testing.expectError(error.JinjaTypeError, expression.evaluate(a, "{'a':1,2:3}|dictsort", null));
    try std.testing.expectError(error.InvalidJinjaArguments, expression.evaluate(a, "{}|dictsort(by='other')", null));
    try std.testing.expectError(error.InvalidJinjaArguments, expression.evaluate(a, "{}|dictsort(false, case_sensitive=true)", null));
    try std.testing.expectError(error.InvalidJinjaArguments, expression.evaluate(a, "{}|dictsort(unknown=true)", null));
}

fn allocationProof(backing: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try expression.evaluate(a, "{'É':'b','a':'B','Z':'a'}|dictsort(by='value',reverse=true)", null);
    try std.testing.expectEqual(@as(usize, 3), result.list.len);
}

test "dictsort propagates allocation failures without leaking caller arena storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProof, .{});
}
