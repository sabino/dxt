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

pub fn sortStrings(values: [][]const u8) void {
    std.mem.sort([]const u8, values, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
}

pub fn appendUnique(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8), value: []const u8) !void {
    if (!containsString(values.items, value)) {
        try values.append(allocator, value);
    }
}

pub fn stripYamlComment(line: []const u8) []const u8 {
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (quote) |q| {
            if (ch == q) quote = null;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (ch == '#') return line[0..i];
    }
    return line;
}

pub fn leadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') count += 1;
    return count;
}

pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub fn splitKeyValue(line: []const u8) ?KeyValue {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    return .{
        .key = std.mem.trim(u8, line[0..colon], " \t"),
        .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
    };
}

pub fn parseInlineStringList(allocator: std.mem.Allocator, value: []const u8, out: *std.ArrayList([]const u8)) !void {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
        try out.append(allocator, try dupTrimmedScalar(allocator, trimmed));
        return;
    }
    var pieces = std.mem.splitScalar(u8, trimmed[1 .. trimmed.len - 1], ',');
    while (pieces.next()) |piece| {
        const item = std.mem.trim(u8, piece, " \t");
        if (item.len != 0) try out.append(allocator, try dupTrimmedScalar(allocator, item));
    }
}

pub fn dupTrimmedScalar(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (trimmed.len >= 2 and ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))) {
        return try allocator.dupe(u8, trimmed[1 .. trimmed.len - 1]);
    }
    return try allocator.dupe(u8, trimmed);
}

test "containsString matches exact byte strings only" {
    const values = [_][]const u8{ "customers", "orders" };
    try std.testing.expect(containsString(&values, "customers"));
    try std.testing.expect(!containsString(&values, "customer"));
}

test "normalizeForDisplay preserves relative paths" {
    try std.testing.expectEqualStrings("models/customers.sql", normalizeForDisplay("models/customers.sql"));
}

test "sortStrings orders byte strings lexicographically" {
    var values = [_][]const u8{ "orders", "customers", "stg_customers" };
    sortStrings(&values);
    try std.testing.expectEqualStrings("customers", values[0]);
    try std.testing.expectEqualStrings("orders", values[1]);
    try std.testing.expectEqualStrings("stg_customers", values[2]);
}

test "appendUnique preserves first occurrence order" {
    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(std.testing.allocator);

    try appendUnique(std.testing.allocator, &values, "model.demo.customers");
    try appendUnique(std.testing.allocator, &values, "model.demo.orders");
    try appendUnique(std.testing.allocator, &values, "model.demo.customers");

    try std.testing.expectEqual(@as(usize, 2), values.items.len);
    try std.testing.expectEqualStrings("model.demo.customers", values.items[0]);
    try std.testing.expectEqualStrings("model.demo.orders", values.items[1]);
}

test "stripYamlComment ignores hashes inside quotes" {
    try std.testing.expectEqualStrings("name: customers ", stripYamlComment("name: customers # comment"));
    try std.testing.expectEqualStrings("description: \"keeps # hash\"", stripYamlComment("description: \"keeps # hash\""));
}

test "leadingSpaces counts only literal spaces" {
    try std.testing.expectEqual(@as(usize, 2), leadingSpaces("  models:"));
    try std.testing.expectEqual(@as(usize, 0), leadingSpaces("\tmodels:"));
}

test "splitKeyValue trims keys and values" {
    const kv = splitKeyValue(" name : \"customers\" ") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("name", kv.key);
    try std.testing.expectEqualStrings("\"customers\"", kv.value);
    try std.testing.expect(splitKeyValue("not yaml") == null);
}

test "dupTrimmedScalar strips one matching quote pair" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("customers", try dupTrimmedScalar(allocator, " customers "));
    try std.testing.expectEqualStrings("customers", try dupTrimmedScalar(allocator, "\"customers\""));
    try std.testing.expectEqualStrings("customers", try dupTrimmedScalar(allocator, "'customers'"));
}

test "parseInlineStringList reads scalar and inline list values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(allocator);
    try parseInlineStringList(allocator, "[\"models\", marts]", &values);
    try std.testing.expectEqual(@as(usize, 2), values.items.len);
    try std.testing.expectEqualStrings("models", values.items[0]);
    try std.testing.expectEqualStrings("marts", values.items[1]);

    var scalar: std.ArrayList([]const u8) = .empty;
    defer scalar.deinit(allocator);
    try parseInlineStringList(allocator, "'macros'", &scalar);
    try std.testing.expectEqual(@as(usize, 1), scalar.items.len);
    try std.testing.expectEqualStrings("macros", scalar.items[0]);
}

test "parseInlineStringList skips empty inline list items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(allocator);
    try parseInlineStringList(allocator, "[a, , b]", &values);
    try std.testing.expectEqual(@as(usize, 2), values.items.len);
    try std.testing.expectEqualStrings("a", values.items[0]);
    try std.testing.expectEqualStrings("b", values.items[1]);
}
