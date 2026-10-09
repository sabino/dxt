//! Mutable Python sets keep a stable container identity across native aliases.
//! Membership uses the same hashability and numeric identity as dictionary keys.
const std = @import("std");
const expression = @import("expression.zig");
const keys = @import("mapping_keys.zig");
const Value = expression.Value;
const Argument = expression.Argument;

pub fn isSet(value: Value) bool {
    const marker = value.attribute("__dxt_set");
    return marker == .boolean and marker.boolean;
}

pub fn items(value: Value) ?[]const Value {
    if (!isSet(value)) return null;
    const members = value.attribute("__dxt_iterable");
    return if (members == .list) members.list else null;
}

pub fn contains(value: Value, member: Value) !bool {
    try expression.hashableKey(member);
    for (items(value) orelse return error.JinjaTypeError) |existing| if (keys.keyEqual(existing, member)) return true;
    return false;
}

pub fn construct(a: std.mem.Allocator, iterable: Value) !Value {
    if (iterable == .none) return error.JinjaTypeError;
    var members: std.ArrayList(Value) = .empty;
    for (try expression.iterableValues(a, iterable)) |member| try append(a, &members, member);
    return fromMembers(a, members.items);
}

pub fn fromMembers(a: std.mem.Allocator, members: []const Value) !Value {
    var unique: std.ArrayList(Value) = .empty;
    for (members) |member| try append(a, &unique, member);
    const entries = try expression.allocateEntries(a, 2);
    entries[0] = .{ .key = "__dxt_set", .value = .{ .boolean = true } };
    const owned = try expression.allocateValues(a, unique.items.len);
    @memcpy(owned, unique.items);
    entries[1] = .{ .key = "__dxt_iterable", .value = .{ .list = owned } };
    return .{ .object = entries };
}

fn append(a: std.mem.Allocator, target: *std.ArrayList(Value), member: Value) !void {
    try expression.hashableKey(member);
    for (target.items) |existing| if (keys.keyEqual(existing, member)) return;
    try target.append(a, member);
}

fn replace(a: std.mem.Allocator, target: Value, members: []const Value) !void {
    for (@constCast(target.object)) |*entry| if (std.mem.eql(u8, entry.key, "__dxt_iterable")) {
        entry.value = .{ .list = try a.dupe(Value, members) };
        return;
    };
    return error.JinjaTypeError;
}

pub fn text(a: std.mem.Allocator, set: Value) ![]const u8 {
    const members = items(set) orelse return error.JinjaTypeError;
    if (members.len == 0) return "set()";
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.writeByte('{');
    for (members, 0..) |member, index| {
        if (index != 0) try out.writer.writeAll(", ");
        try out.writer.writeAll(try expression.repr(member, a));
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

pub fn equal(lhs: Value, rhs: Value) bool {
    const a = items(lhs) orelse return false;
    const b = items(rhs) orelse return false;
    if (a.len != b.len) return false;
    for (a) |member| if (!(contains(rhs, member) catch return false)) return false;
    return true;
}

pub fn apply(a: std.mem.Allocator, operator: []const u8, lhs: Value, rhs: Value) !?Value {
    if (!isSet(lhs) and !isSet(rhs)) return null;
    if (!isSet(lhs) or !isSet(rhs)) return error.JinjaTypeError;
    if (std.mem.eql(u8, operator, "==")) return .{ .boolean = equal(lhs, rhs) };
    if (std.mem.eql(u8, operator, "!=")) return .{ .boolean = !equal(lhs, rhs) };
    if (std.mem.eql(u8, operator, "<") or std.mem.eql(u8, operator, "<=") or std.mem.eql(u8, operator, ">") or std.mem.eql(u8, operator, ">=")) {
        const reverse = operator[0] == '>';
        const left = if (reverse) rhs else lhs;
        const right = if (reverse) lhs else rhs;
        for (items(left).?) |member| if (!try contains(right, member)) return .{ .boolean = false };
        return .{ .boolean = operator.len == 2 or items(left).?.len < items(right).?.len };
    }
    const method = if (std.mem.eql(u8, operator, "|")) "union" else if (std.mem.eql(u8, operator, "&")) "intersection" else if (std.mem.eql(u8, operator, "-")) "difference" else if (std.mem.eql(u8, operator, "^")) "symmetric_difference" else return error.JinjaTypeError;
    return (try call(a, lhs, method, &.{.{ .value = rhs }})).?;
}

pub fn call(a: std.mem.Allocator, receiver: Value, method: []const u8, args: []const Argument) !?Value {
    const original = items(receiver) orelse return null;
    for (args) |arg| if (arg.name != null) return error.InvalidJinjaArguments;
    if (std.mem.eql(u8, method, "copy")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        return try fromMembers(a, original);
    }
    if (std.mem.eql(u8, method, "clear")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        try replace(a, receiver, &.{});
        return .none;
    }
    if (std.mem.eql(u8, method, "add")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
        var updated: std.ArrayList(Value) = .empty;
        try updated.appendSlice(a, original);
        try append(a, &updated, args[0].value);
        try replace(a, receiver, updated.items);
        return .none;
    }
    if (std.mem.eql(u8, method, "discard") or std.mem.eql(u8, method, "remove")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
        try expression.hashableKey(args[0].value);
        var updated: std.ArrayList(Value) = .empty;
        var found = false;
        for (original) |member| if (keys.keyEqual(member, args[0].value)) {
            found = true;
        } else try updated.append(a, member);
        if (!found and std.mem.eql(u8, method, "remove")) return error.JinjaKeyError;
        try replace(a, receiver, updated.items);
        return .none;
    }
    if (std.mem.eql(u8, method, "pop")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        if (original.len == 0) return error.JinjaKeyError;
        const member = original[0];
        try replace(a, receiver, original[1..]);
        return member;
    }
    if (std.mem.eql(u8, method, "isdisjoint") or std.mem.eql(u8, method, "issubset") or std.mem.eql(u8, method, "issuperset")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
        const other = try construct(a, args[0].value);
        if (std.mem.eql(u8, method, "isdisjoint")) {
            for (original) |member| if (try contains(other, member)) return .{ .boolean = false };
        } else {
            const left = if (std.mem.eql(u8, method, "issubset")) receiver else other;
            const right = if (std.mem.eql(u8, method, "issubset")) other else receiver;
            for (items(left).?) |member| if (!try contains(right, member)) return .{ .boolean = false };
        }
        return .{ .boolean = true };
    }
    const updating = std.mem.eql(u8, method, "update") or std.mem.endsWith(u8, method, "_update");
    const operation = if (std.mem.eql(u8, method, "update")) "union" else if (updating) method[0 .. method.len - "_update".len] else method;
    if (!std.mem.eql(u8, operation, "union") and !std.mem.eql(u8, operation, "intersection") and !std.mem.eql(u8, operation, "difference") and !std.mem.eql(u8, operation, "symmetric_difference")) return null;
    if (std.mem.eql(u8, operation, "symmetric_difference") and args.len != 1) return error.InvalidJinjaArguments;
    var result: std.ArrayList(Value) = .empty;
    try result.appendSlice(a, original);
    for (args) |arg| {
        const other = try construct(a, arg.value);
        var next: std.ArrayList(Value) = .empty;
        if (std.mem.eql(u8, operation, "union")) {
            try next.appendSlice(a, result.items);
            for (items(other).?) |member| try append(a, &next, member);
        } else {
            for (result.items) |member| {
                const shared = try contains(other, member);
                if (shared == std.mem.eql(u8, operation, "intersection")) try next.append(a, member);
            }
            if (std.mem.eql(u8, operation, "symmetric_difference")) {
                const prior = try fromMembers(a, result.items);
                for (items(other).?) |member| if (!try contains(prior, member)) try next.append(a, member);
            }
        }
        result = next;
    }
    if (updating) {
        try replace(a, receiver, result.items);
        return .none;
    }
    return try fromMembers(a, result.items);
}

test "native sets preserve equal numeric members NaN identity and mutable aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const set = try construct(a, .{ .list = &.{ .{ .boolean = true }, .{ .integer = "1" }, .{ .number = 1.0 }, .{ .integer = "2" } } });
    const alias = set;
    try std.testing.expectEqual(@as(usize, 2), items(set).?.len);
    _ = try call(a, set, "add", &.{.{ .value = .{ .integer = "3" } }});
    try std.testing.expect(try contains(alias, .{ .number = 3.0 }));
    _ = try call(a, set, "clear", &.{});
    try std.testing.expectEqualStrings("set()", try text(a, alias));
    const nan = try expression.floatValue(a, std.math.nan(f64));
    const other = try expression.floatValue(a, std.math.nan(f64));
    const nans = try construct(a, .{ .list = &.{ nan, nan, other } });
    try std.testing.expectEqual(@as(usize, 2), items(nans).?.len);
    try std.testing.expectError(error.JinjaTypeError, construct(a, .{ .list = &.{.{ .list = &.{} }} }));
}
