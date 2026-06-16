const std = @import("std");

pub fn normalizeForDisplay(path: []const u8) []const u8 {
    return path;
}

pub fn containsString(values: []const []const u8, value: []const u8) bool {
    for (values) |candidate| {
        if (std.mem.eql(u8, candidate, value)) return true;
    }
    return false;
}

test "containsString matches exact byte strings only" {
    const values = [_][]const u8{ "customers", "orders" };
    try std.testing.expect(containsString(&values, "customers"));
    try std.testing.expect(!containsString(&values, "customer"));
}

test "normalizeForDisplay preserves relative paths" {
    try std.testing.expectEqualStrings("models/customers.sql", normalizeForDisplay("models/customers.sql"));
}
