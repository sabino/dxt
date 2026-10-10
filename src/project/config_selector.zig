//! Core config selectors descend typed dictionaries and compare authored values.
const std = @import("std");
const values = @import("config_value.zig");
const Json = std.json.Value;

pub fn matches(config: Json, term: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, term, ':') orelse return false;
    var current = config;
    var parts = std.mem.splitScalar(u8, term[0..colon], '.');
    var depth: usize = 0;
    while (parts.next()) |part| {
        // getattr is attempted before dictionary lookup by Core. Dictionary
        // methods are callable values and cannot equal a CLI string criterion.
        if (depth != 0 and current == .object) {
            for ([_][]const u8{ "clear", "copy", "fromkeys", "get", "items", "keys", "pop", "popitem", "setdefault", "update", "values" }) |method| {
                if (std.mem.eql(u8, method, part)) return false;
            }
        }
        current = values.get(current, part) orelse return false;
        depth += 1;
    }
    const expected = term[colon + 1 ..];
    const insensitive = std.mem.eql(u8, term[0..colon], "severity");
    if (current == .array) {
        for (current.array.items) |item| {
            if (scalarMatches(item, expected, insensitive)) return true;
            // Python list membership considers bool and numeric equality;
            // scalar numbers do not receive Core's explicit bool shortcut.
            if (item == .integer and ((item.integer == 1 and std.ascii.eqlIgnoreCase(expected, "true")) or (item.integer == 0 and std.ascii.eqlIgnoreCase(expected, "false")))) return true;
            if (item == .float and ((item.float == 1 and std.ascii.eqlIgnoreCase(expected, "true")) or (item.float == 0 and std.ascii.eqlIgnoreCase(expected, "false")))) return true;
        }
        return false;
    }
    return scalarMatches(current, expected, insensitive);
}

fn scalarMatches(value: Json, expected: []const u8, insensitive: bool) bool {
    return switch (value) {
        .string => |text| if (insensitive) std.ascii.eqlIgnoreCase(text, expected) else std.mem.eql(u8, text, expected),
        .bool => |enabled| std.ascii.eqlIgnoreCase(expected, if (enabled) "true" else "false"),
        else => false,
    };
}

test "config selectors preserve scalar types and one-level list membership" {
    const a = std.testing.allocator;
    const document = try std.json.parseFromSlice(Json, a,
        \\{"enabled":true,"count":1,"tags":["nightly"],"meta":{"nested":[["nightly"]],"flags":[1.0,0],"items":"hidden","team":"Core"},"severity":"ERROR"}
    , .{});
    defer document.deinit();
    try std.testing.expect(matches(document.value, "enabled:TRUE"));
    try std.testing.expect(!matches(document.value, "count:1"));
    try std.testing.expect(!matches(document.value, "count:true"));
    try std.testing.expect(matches(document.value, "tags:nightly"));
    try std.testing.expect(!matches(document.value, "meta.nested:nightly"));
    try std.testing.expect(matches(document.value, "meta.flags:true"));
    try std.testing.expect(matches(document.value, "meta.flags:FALSE"));
    try std.testing.expect(!matches(document.value, "meta.items:hidden"));
    try std.testing.expect(matches(document.value, "meta.team:Core"));
    try std.testing.expect(!matches(document.value, "meta.team:core"));
    try std.testing.expect(matches(document.value, "severity:error"));
}
