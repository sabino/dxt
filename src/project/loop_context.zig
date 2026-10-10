//! Jinja loop metadata is evaluated when an authored expression requests it.
const std = @import("std");
const expression = @import("expression.zig");

pub const State = struct {
    iterator: expression.Value,
    items: std.ArrayList(expression.Value) = .empty,
    index: usize = 0,
    ended: bool = false,
    known_length: ?usize = null,
    last_changed: ?expression.Value = null,
};

pub fn value(a: std.mem.Allocator, id: usize) !expression.Value {
    const entries = try expression.allocateEntries(a, 2);
    entries[0] = .{ .key = "__dxt_getattr", .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_loop_attribute:{d}", .{id}) } };
    entries[1] = .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } };
    return .{ .object = entries };
}

pub fn attribute(a: std.mem.Allocator, state: *State, id: usize, name: []const u8) !expression.Value {
    inline for (.{ "cycle", "changed" }) |method_name| if (std.mem.eql(u8, name, method_name)) return .{ .callable = try std.fmt.allocPrint(a, "__dxt_loop_{s}:{d}", .{ method_name, id }) };
    if (std.mem.eql(u8, name, "index")) return expression.integerValue(a, state.index + 1);
    if (std.mem.eql(u8, name, "index0")) return expression.integerValue(a, state.index);
    if (std.mem.eql(u8, name, "first")) return .{ .boolean = state.index == 0 };
    if (std.mem.eql(u8, name, "last")) return .{ .boolean = state.ended and state.items.items.len == state.index + 1 };
    if (std.mem.eql(u8, name, "length")) return expression.integerValue(a, state.known_length orelse state.items.items.len);
    if (std.mem.eql(u8, name, "revindex")) return expression.integerValue(a, (state.known_length orelse state.items.items.len) - state.index);
    if (std.mem.eql(u8, name, "revindex0")) return expression.integerValue(a, (state.known_length orelse state.items.items.len) - state.index - 1);
    if (std.mem.eql(u8, name, "depth")) return expression.integerValue(a, 1);
    if (std.mem.eql(u8, name, "depth0")) return expression.integerValue(a, 0);
    if (std.mem.eql(u8, name, "previtem") or std.mem.eql(u8, name, "nextitem")) {
        const previous = std.mem.eql(u8, name, "previtem");
        if ((previous and state.index == 0) or (!previous and state.items.items.len <= state.index + 1)) {
            const missing = try expression.undefinedValue(a, null);
            missing.ordinary_undefined.hint = if (previous) "there is no previous item" else "there is no next item";
            return missing;
        }
        return state.items.items[if (previous) state.index - 1 else state.index + 1];
    }
    return .undefined;
}

pub fn method(a: std.mem.Allocator, state: *State, name: []const u8, args: []const expression.Argument) !expression.Value {
    for (args) |argument| if (argument.name != null) return error.InvalidJinjaArguments;
    if (std.mem.eql(u8, name, "cycle")) {
        if (args.len == 0) return error.InvalidJinjaArguments;
        return args[state.index % args.len].value;
    }
    if (std.mem.eql(u8, name, "changed")) {
        const values = try expression.allocateValues(a, args.len);
        for (args, values) |argument, *item| item.* = argument.value;
        const current = expression.Value{ .tuple = values };
        const changed = if (state.last_changed) |previous| !expression.equalValues(previous, current) else true;
        state.last_changed = current;
        return .{ .boolean = changed };
    }
    return error.InvalidJinjaArguments;
}
