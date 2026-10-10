//! Native values may defer length and boolean conversion to the active host.
const std = @import("std");
const expression = @import("expression.zig");

pub fn length(a: std.mem.Allocator, value: expression.Value, host: ?expression.Host) anyerror!expression.Value {
    if (try invoke(a, value, "__dxt_len", host)) |result| {
        const count = try expression.integerIndex(result);
        if (count < 0) return error.JinjaTypeError;
        return expression.integerValue(a, count);
    }
    if (expression.isUndefined(value)) return expression.integerValue(a, 0);
    if (@import("expression_sequence.zig").isIterator(value)) return error.JinjaTypeError;
    if (value == .string) {
        var iterator = (try std.unicode.Utf8View.init(value.string)).iterator();
        var count: usize = 0;
        while (iterator.nextCodepoint() != null) count += 1;
        return expression.integerValue(a, count);
    }
    if (value == .list) return expression.integerValue(a, value.list.len);
    if (value == .tuple) return expression.integerValue(a, value.tuple.len);
    return expression.integerValue(a, (try expression.iterableValuesWithHost(a, value, host)).len);
}

pub fn truthy(a: std.mem.Allocator, value: expression.Value, host: ?expression.Host) anyerror!bool {
    if (try invoke(a, value, "__dxt_bool", host)) |result| {
        if (result != .boolean) return error.JinjaTypeError;
        return result.boolean;
    }
    if (expression.callableName(value.attribute("__dxt_len")) != null) return (try length(a, value, host)).truthy();
    return value.truthy();
}

fn invoke(a: std.mem.Allocator, value: expression.Value, marker: []const u8, host: ?expression.Host) !?expression.Value {
    const function = expression.callableName(value.attribute(marker)) orelse return null;
    const current = host orelse return error.JinjaTypeError;
    return try current.call(current.context, function, &.{}, a);
}

test "deferred length and boolean protocols use the current host" {
    const Fixture = struct {
        count: usize = 0,
        fn resolve(_: *anyopaque, _: []const u8, _: std.mem.Allocator) !expression.Value {
            return .undefined;
        }
        fn call(context: *anyopaque, name: []const u8, _: []const expression.Argument, _: std.mem.Allocator) !expression.Value {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            if (std.mem.eql(u8, name, "boolean")) return .{ .boolean = false };
            return .{ .integer = "3" };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = Fixture{};
    const host = expression.Host{ .context = &fixture, .resolve = Fixture.resolve, .call = Fixture.call };
    const sized = expression.Value{ .object = &.{.{ .key = "__dxt_len", .value = .{ .callable = "size" } }} };
    try std.testing.expectEqualStrings("3", (try length(a, sized, host)).integer);
    try std.testing.expect(try truthy(a, sized, host));
    const boolean = expression.Value{ .object = &.{.{ .key = "__dxt_bool", .value = .{ .callable = "boolean" } }} };
    try std.testing.expect(!try truthy(a, boolean, host));
    try std.testing.expectEqual(@as(usize, 3), fixture.count);
    try std.testing.expectError(error.JinjaTypeError, length(a, .none, host));
    try std.testing.expectEqualStrings("2", (try length(a, .{ .string = "aé" }, host)).integer);
}
