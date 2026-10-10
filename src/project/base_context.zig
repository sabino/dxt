//! dbt BaseContext helpers preserve Python signatures, values and error rules.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const Argument = expression.Argument;

pub fn callable(name: []const u8) bool {
    inline for (.{ "fromjson", "tojson", "fromyaml", "toyaml", "set", "set_strict", "zip", "zip_strict", "local_md5" }) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn bind(comptime names: []const []const u8, args: []const Argument, required: usize) ![names.len]Value {
    var result: [names.len]Value = @splat(.none);
    var present: [names.len]bool = @splat(false);
    var position: usize = 0;
    for (args) |arg| {
        const index = if (arg.name) |name| blk: {
            for (names, 0..) |candidate, at| if (std.mem.eql(u8, name, candidate)) break :blk at;
            return error.InvalidJinjaArguments;
        } else blk: {
            const at = position;
            position += 1;
            break :blk at;
        };
        if (index >= names.len or present[index]) return error.InvalidJinjaArguments;
        result[index] = arg.value;
        present[index] = true;
    }
    for (present[0..required]) |exists| if (!exists) return error.InvalidJinjaArguments;
    return result;
}

pub fn call(a: std.mem.Allocator, name: []const u8, args: []const Argument) !?Value {
    if (try @import("yaml_values.zig").call(a, name, args)) |result| return result;
    if (std.mem.eql(u8, name, "fromyaml")) {
        const bound = try bind(&.{ "value", "default" }, args, 1);
        const input = if (bound[0] == .string) bound[0].string else if (bound[0].attribute("__dxt_binary") == .string) bound[0].attribute("__dxt_binary").string else return error.JinjaTypeError;
        return @import("yaml_context.zig").load(a, input) catch |err| switch (err) {
            error.OutOfMemory, error.JinjaIterationLimitExceeded, error.JinjaExpressionDepthExceeded, error.JinjaKeyError => return err,
            else => return bound[1],
        };
    }
    if (std.mem.eql(u8, name, "toyaml")) {
        const bound = try bind(&.{ "value", "default", "sort_keys" }, args, 1);
        return .{ .string = @import("yaml_dump.zig").dump(a, bound[0], bound[2].truthy()) catch |err| switch (err) {
            error.InvalidYamlRepresentation => return bound[1],
            else => return err,
        } };
    }
    if (std.mem.eql(u8, name, "local_md5")) {
        const bound = try bind(&.{"value"}, args, 1);
        if (bound[0] != .string) return error.JinjaTypeError;
        var digest: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(bound[0].string, &digest, .{});
        return .{ .string = try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower)) };
    }
    if (std.mem.eql(u8, name, "tojson")) {
        const bound = try bind(&.{ "value", "default", "sort_keys" }, args, 1);
        const text = @import("context_json.zig").stringifySorted(a, bound[0], bound[2].truthy()) catch |err| switch (err) {
            error.JinjaCircularReference => return bound[1],
            else => return err,
        };
        return .{ .string = text };
    }
    if (std.mem.eql(u8, name, "fromjson")) {
        const bound = try bind(&.{ "string", "default" }, args, 1);
        return @import("json_context_load.zig").load(a, bound[0]) catch |err| switch (err) {
            error.OutOfMemory, error.JinjaTypeError, error.JinjaExpressionDepthExceeded, error.JinjaIterationLimitExceeded => return err,
            else => return bound[1],
        };
    }
    if (std.mem.eql(u8, name, "set") or std.mem.eql(u8, name, "set_strict")) {
        const strict = std.mem.eql(u8, name, "set_strict");
        const bound = if (strict) blk: {
            const one = try bind(&.{"value"}, args, 1);
            break :blk [2]Value{ one[0], .none };
        } else try bind(&.{ "value", "default" }, args, 1);
        return @import("set_context.zig").construct(a, bound[0]) catch |err| switch (err) {
            error.JinjaTypeError => if (strict) err else bound[1],
            else => err,
        };
    }
    if (std.mem.eql(u8, name, "zip") or std.mem.eql(u8, name, "zip_strict")) {
        const strict = std.mem.eql(u8, name, "zip_strict");
        var inputs: std.ArrayList(Value) = .empty;
        var fallback: Value = .none;
        var has_default = false;
        for (args) |arg| {
            if (arg.name) |keyword| {
                if (strict or !std.mem.eql(u8, keyword, "default") or has_default) return error.InvalidJinjaArguments;
                fallback = arg.value;
                has_default = true;
            } else try inputs.append(a, arg.value);
        }
        for (inputs.items) |input| {
            if (!expression.isIterable(input)) return if (strict) error.JinjaTypeError else fallback;
        }
        return try @import("expression_sequence.zig").zip(a, inputs.items);
    }
    return null;
}

test "base helpers bind keywords preserve defaults and hash UTF8 locally" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const md5 = (try call(a, "local_md5", &.{.{ .name = "value", .value = .{ .string = "hello world" } }})).?;
    try std.testing.expectEqualStrings("5eb63bbbe01eeed093cb22bb8f5acdc3", md5.string);
    const fallback = (try call(a, "set", &.{ .{ .value = .none }, .{ .name = "default", .value = .{ .string = "fallback" } } })).?;
    try std.testing.expectEqualStrings("fallback", fallback.string);
    try std.testing.expectError(error.JinjaTypeError, call(a, "set_strict", &.{.{ .value = .none }}));
    try std.testing.expectError(error.InvalidJinjaArguments, call(a, "local_md5", &.{ .{ .value = .{ .string = "a" } }, .{ .name = "value", .value = .{ .string = "b" } } }));
    const sorted = (try call(a, "tojson", &.{ .{ .value = try expression.evaluate(a, "{'b':2,'a':1}", null) }, .{ .name = "sort_keys", .value = .{ .boolean = true } } })).?;
    try std.testing.expectEqualStrings("{\"a\": 1, \"b\": 2}", sorted.string);
    const empty = (try call(a, "zip", &.{})).?;
    try std.testing.expectEqual(@as(usize, 0), (try expression.iterableValues(a, empty)).len);
}
