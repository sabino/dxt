//! Pure grant helpers follow Core's casefold comparison and preserve authored case.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const Argument = expression.Argument;

pub fn call(allocator: std.mem.Allocator, name: []const u8, args: []const Argument) !?Value {
    if (std.mem.eql(u8, name, "adapter.standardize_grants_dict")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
        const rows = try expression.iterableValues(allocator, args[0].value);
        var entries: std.ArrayList(expression.Entry) = .empty;
        for (rows) |row| {
            const privilege = row.attribute("privilege_type");
            const grantee = row.attribute("grantee");
            if (privilege != .string or grantee != .string) return error.InvalidGrantResult;
            var found = false;
            for (entries.items) |*entry| if (std.mem.eql(u8, entry.key, privilege.string)) {
                const list = try expression.allocateValues(allocator, entry.value.list.len + 1);
                @memcpy(list[0..entry.value.list.len], entry.value.list);
                list[list.len - 1] = grantee;
                entry.value = .{ .list = list };
                found = true;
                break;
            };
            if (!found) try entries.append(allocator, .{ .key = privilege.string, .value = .{ .list = try allocator.dupe(Value, &.{grantee}) } });
        }
        return .{ .object = if (entries.items.len == 0) try expression.allocateEntries(allocator, 0) else try entries.toOwnedSlice(allocator) };
    }
    if (!std.mem.eql(u8, name, "diff_of_two_dicts")) return null;
    if (args.len != 2 or args[0].value != .object or args[1].value != .object) return error.InvalidJinjaArguments;
    var output: std.ArrayList(expression.Entry) = .empty;
    for (args[0].value.object) |left| {
        const key = try fold(allocator, left.key);
        var compared_values: ?[]const Value = null;
        // Python's lowered dict keeps the final value for colliding keys.
        for (args[1].value.object) |right| if (std.mem.eql(u8, key, try fold(allocator, right.key))) {
            compared_values = try stringList(allocator, right.value);
        };
        const left_values = try stringList(allocator, left.value);
        if (compared_values == null) {
            try output.append(allocator, left);
            continue;
        }
        var missing: std.ArrayList(Value) = .empty;
        for (left_values) |value| {
            const lowered = try fold(allocator, value.string);
            var present = false;
            for (compared_values.?) |other| if (std.mem.eql(u8, lowered, try fold(allocator, other.string))) {
                present = true;
                break;
            };
            if (!present) try missing.append(allocator, value);
        }
        if (missing.items.len != 0) try output.append(allocator, .{ .key = left.key, .value = .{ .list = try missing.toOwnedSlice(allocator) } });
    }
    return .{ .object = if (output.items.len == 0) try expression.allocateEntries(allocator, 0) else try output.toOwnedSlice(allocator) };
}

fn stringList(allocator: std.mem.Allocator, value: Value) ![]const Value {
    const items = try expression.iterableValues(allocator, value);
    for (items) |item| if (item != .string) return error.InvalidGrantConfiguration;
    return items;
}

fn fold(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return @import("expression_unicode.zig").convert(allocator, text, .casefold);
}
