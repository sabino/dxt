//! Forcing Jinja aggregates preserve each iterator's pull and failure order.
const std = @import("std");
const expression = @import("expression.zig");
const sequence = @import("expression_sequence.zig");
const attributes = @import("filter_attributes.zig");
const arguments = @import("filter_arguments.zig");
const unicode = @import("expression_unicode.zig");
const Value = expression.Value;

pub fn callWithHost(a: std.mem.Allocator, name: []const u8, value: Value, args: []const expression.Argument, host: ?expression.Host) anyerror!?Value {
    if (std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max")) {
        const bound = try arguments.bind(a, args, &.{ "case_sensitive", "attribute" }, &.{ .{ .boolean = false }, .none }, 0);
        const iterator = try sequence.iter(a, value);
        var best = (try sequence.next(a, iterator, host)) orelse return Value.undefined;
        // Core prepares the getter only after finding the first row.
        const path = try attributes.parts(a, bound[1]);
        var best_key = try key(a, best, path, bound[0].truthy(), host);
        while (try sequence.next(a, iterator, host)) |item| {
            const item_key = try key(a, item, path, bound[0].truthy(), host);
            const order = expression.valueOrder(a, item_key, best_key) catch |err| {
                if (err == error.UnorderedJinjaNumber) continue;
                return err;
            };
            if (order == (if (std.mem.eql(u8, name, "min")) std.math.Order.lt else std.math.Order.gt)) {
                best = item;
                best_key = item_key;
            }
        }
        return best;
    }
    if (std.mem.eql(u8, name, "sum")) {
        const bound = try arguments.bind(a, args, &.{ "attribute", "start" }, &.{ .none, .{ .integer = "0" } }, 0);
        const path = try attributes.parts(a, bound[0]);
        const iterator = try sequence.iter(a, value);
        const start = bound[1];
        // Python's sum rejects text starts even when the input is empty.
        if (start == .string or start.attribute("__dxt_binary") == .string) return error.JinjaTypeError;
        var result = @import("expression_sum.zig").Accumulator.init(start);
        while (try sequence.next(a, iterator, host)) |item|
            try result.add(a, try attributes.get(a, item, path, .none, host));
        return try result.finish(a);
    }
    if (std.mem.eql(u8, name, "join")) {
        const bound = try arguments.bind(a, args, &.{ "d", "attribute" }, &.{ .{ .string = "" }, .none }, 0);
        const path = try attributes.parts(a, bound[1]);
        const prepared = if (bound[1] != .none) try sequence.iter(a, value) else null;
        const separator = try expression.textWithHost(a, bound[0], host);
        const iterator = prepared orelse try sequence.iter(a, value);
        var output: std.ArrayList(u8) = .empty;
        var count: usize = 0;
        while (try sequence.next(a, iterator, host)) |item| {
            const text = try expression.textWithHost(a, try attributes.get(a, item, path, .none, host), host);
            if (count != 0) try output.appendSlice(a, separator);
            try output.appendSlice(a, text);
            count += 1;
        }
        return Value{ .string = try output.toOwnedSlice(a) };
    }
    return null;
}

fn key(a: std.mem.Allocator, item: Value, path: []const Value, case_sensitive: bool, host: ?expression.Host) !Value {
    const result = try attributes.get(a, item, path, .none, host);
    return if (!case_sensitive and result == .string) .{ .string = try unicode.convert(a, result.string, .lower) } else result;
}

test "aggregate failure stops at its failing row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sum_input = try sequence.iterator(a, &.{ .{ .string = "bad" }, .{ .integer = "2" } });
    try std.testing.expectError(error.JinjaTypeError, callWithHost(a, "sum", sum_input, &.{}, null));
    try std.testing.expectEqualStrings("1", sum_input.attribute("__dxt_sequence_cursor").integer);
    for ([_][]const u8{ "min", "max" }) |name| {
        const input = try sequence.iterator(a, &.{ .{ .integer = "1" }, .{ .string = "bad" }, .{ .integer = "2" } });
        try std.testing.expectError(error.JinjaTypeError, callWithHost(a, name, input, &.{}, null));
        try std.testing.expectEqualStrings("2", input.attribute("__dxt_sequence_cursor").integer);
    }
}

test "aggregate getter preparation follows Core's empty input stages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = [_]expression.Argument{.{ .name = "attribute", .value = .{ .string = "²" } }};
    for ([_][]const u8{ "min", "max" }) |name|
        try std.testing.expectEqual(Value.undefined, (try callWithHost(a, name, .{ .list = &.{} }, &args, null)).?);
    for ([_][]const u8{ "sum", "join" }) |name| {
        const input = try sequence.iterator(a, &.{.{ .integer = "1" }});
        try std.testing.expectError(error.InvalidJinjaArguments, callWithHost(a, name, input, &args, null));
        try std.testing.expectEqualStrings("0", input.attribute("__dxt_sequence_cursor").integer);
    }
}

test "aggregate callbacks are evaluated only through the failing row" {
    const Frame = struct {
        calls: usize = 0,
        values: []const Value,
        fn resolve(_: *anyopaque, _: []const u8, _: std.mem.Allocator) !Value {
            return .undefined;
        }
        fn call(context: *anyopaque, _: []const u8, _: []const expression.Argument, _: std.mem.Allocator) !Value {
            const frame: *@This() = @ptrCast(@alignCast(context));
            const index = frame.calls;
            frame.calls += 1;
            if (index >= frame.values.len) return error.UnexpectedLatePull;
            return frame.values[index];
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const receiver = Value{ .object = &.{.{ .key = "__dxt_getattr", .value = .{ .callable = "row" } }} };
    const input = Value{ .list = &.{ receiver, receiver, receiver } };
    for ([_][]const u8{ "min", "max", "sum", "join", "urlencode" }) |name| {
        const values: []const Value = if (std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max"))
            &.{ .{ .integer = "1" }, .{ .string = "bad" } }
        else if (std.mem.eql(u8, name, "join"))
            &.{.{ .callable = "unrenderable" }}
        else
            &.{.{ .string = "bad" }};
        var frame = Frame{ .values = values };
        const host = expression.Host{ .context = &frame, .resolve = Frame.resolve, .call = Frame.call };
        const stream = try expression.filterValue(a, "map", input, &.{.{ .name = "attribute", .value = .{ .string = "x" } }}, host);
        try std.testing.expectError(if (std.mem.eql(u8, name, "urlencode")) error.JinjaValueError else error.JinjaTypeError, expression.filterValue(a, name, stream, &.{}, host));
        try std.testing.expectEqual(values.len, frame.calls);
    }
    for ([_][]const u8{ "sort", "sum", "join", "min", "max" }) |name| {
        var frame = Frame{ .values = &.{.{ .integer = "1" }} };
        const host = expression.Host{ .context = &frame, .resolve = Frame.resolve, .call = Frame.call };
        const stream = try expression.filterValue(a, "map", input, &.{.{ .name = "attribute", .value = .{ .string = "x" } }}, host);
        try std.testing.expectError(error.InvalidJinjaArguments, expression.filterValue(a, name, stream, &.{.{ .name = "attribute", .value = .{ .string = "²" } }}, host));
        try std.testing.expectEqual(@as(usize, if (std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max")) 1 else 0), frame.calls);
    }
}

test "text filters retain deferred rendering callbacks and mapping keys" {
    const Frame = struct {
        calls: usize = 0,
        fn resolve(_: *anyopaque, _: []const u8, _: std.mem.Allocator) !Value {
            return .undefined;
        }
        fn call(context: *anyopaque, _: []const u8, _: []const expression.Argument, _: std.mem.Allocator) !Value {
            const frame: *@This() = @ptrCast(@alignCast(context));
            frame.calls += 1;
            return .{ .string = "<LoopContext 1/2>" };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var frame = Frame{};
    const host = expression.Host{ .context = &frame, .resolve = Frame.resolve, .call = Frame.call };
    const loop = Value{ .object = &.{.{ .key = "__dxt_repr", .value = .{ .callable = "repr" } }} };
    try std.testing.expectEqualStrings("<LoopContext 1/2>", (try expression.filterValue(a, "join", .{ .list = &.{loop} }, &.{}, host)).string);
    try std.testing.expectEqualStrings("a<LoopContext 1/2>b", (try expression.filterValue(a, "join", .{ .list = &.{ .{ .string = "a" }, .{ .string = "b" } } }, &.{.{ .value = loop }}, host)).string);
    for ([_][]const u8{ "as_text", "trim", "lower", "upper" }) |name| _ = try expression.filterValue(a, name, loop, &.{}, host);
    try std.testing.expectEqualStrings("<row 1/2>", (try expression.filterValue(a, "replace", loop, &.{ .{ .value = .{ .string = "LoopContext" } }, .{ .value = .{ .string = "row" } } }, host)).string);
    try std.testing.expectEqualStrings("x=%3CLoopContext+1%2F2%3E", (try expression.filterValue(a, "urlencode", .{ .list = &.{.{ .tuple = &.{ .{ .string = "x" }, loop } }} }, &.{}, host)).string);
    const proxy = Value{ .object = &.{ .{ .key = "__dxt_mapping_uppercase", .value = .{ .boolean = false } }, .{ .key = "__dxt_mapping_source", .value = .{ .object = &.{.{ .key = "ab", .value = .{ .string = "ignored" } }} } }, .{ .key = "__dxt_private", .value = .{ .string = "hidden" } } } };
    try std.testing.expectEqualStrings("a=b", (try expression.filterValue(a, "urlencode", proxy, &.{}, host)).string);
    try std.testing.expectEqual(@as(usize, 8), frame.calls);
}
