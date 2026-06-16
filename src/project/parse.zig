const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");

const JsonScalar = types.JsonScalar;
const dupTrimmedScalar = util.dupTrimmedScalar;

pub fn parseBool(value: []const u8) !bool {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (std.ascii.eqlIgnoreCase(trimmed, "true")) return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "false")) return false;
    return error.UnsupportedYaml;
}

pub fn parseJsonScalar(allocator: std.mem.Allocator, value: []const u8) !JsonScalar {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    const unquoted = try dupTrimmedScalar(allocator, trimmed);
    if (std.mem.eql(u8, trimmed, "true") or std.mem.eql(u8, trimmed, "false")) return .{ .text = unquoted, .kind = .bool };
    if (std.mem.eql(u8, trimmed, "null")) return .{ .text = unquoted, .kind = .null };
    if (isJsonNumber(trimmed)) return .{ .text = unquoted, .kind = .number };
    return .{ .text = unquoted, .kind = .string };
}

fn isJsonNumber(value: []const u8) bool {
    if (value.len == 0) return false;
    var i: usize = 0;
    if (value[i] == '-') {
        i += 1;
        if (i == value.len) return false;
    }
    if (value[i] == '0') {
        i += 1;
        if (i < value.len and std.ascii.isDigit(value[i])) return false;
    } else if (value[i] >= '1' and value[i] <= '9') {
        i += 1;
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {}
    } else {
        return false;
    }
    if (i < value.len and value[i] == '.') {
        i += 1;
        var frac_digits: usize = 0;
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {
            frac_digits += 1;
        }
        if (frac_digits == 0) return false;
    }
    if (i < value.len and (value[i] == 'e' or value[i] == 'E')) {
        i += 1;
        if (i < value.len and (value[i] == '+' or value[i] == '-')) i += 1;
        var exp_digits: usize = 0;
        while (i < value.len and std.ascii.isDigit(value[i])) : (i += 1) {
            exp_digits += 1;
        }
        if (exp_digits == 0) return false;
    }
    return i == value.len;
}

pub fn testNameFromYamlItem(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (trimmed.len == 0) return error.UnsupportedYaml;
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse trimmed.len;
    return try dupTrimmedScalar(allocator, trimmed[0..colon]);
}

test "parseBool accepts YAML bool scalars case-insensitively" {
    try std.testing.expect(try parseBool(" true "));
    try std.testing.expect(try parseBool("FALSE\r") == false);
    try std.testing.expectError(error.UnsupportedYaml, parseBool("yes"));
}

test "parseJsonScalar classifies JSON-compatible YAML scalars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const string_scalar = try parseJsonScalar(allocator, "\"blue\"");
    try std.testing.expectEqual(.string, string_scalar.kind);
    try std.testing.expectEqualStrings("blue", string_scalar.text);

    const number_scalar = try parseJsonScalar(allocator, "-12.5e+3");
    try std.testing.expectEqual(.number, number_scalar.kind);
    try std.testing.expectEqualStrings("-12.5e+3", number_scalar.text);

    const bool_scalar = try parseJsonScalar(allocator, "false");
    try std.testing.expectEqual(.bool, bool_scalar.kind);
    try std.testing.expectEqualStrings("false", bool_scalar.text);

    const null_scalar = try parseJsonScalar(allocator, "null");
    try std.testing.expectEqual(.null, null_scalar.kind);
    try std.testing.expectEqualStrings("null", null_scalar.text);
}

test "json number parser rejects invalid leading zero forms" {
    try std.testing.expect(isJsonNumber("0"));
    try std.testing.expect(isJsonNumber("-12.5e+3"));
    try std.testing.expect(!isJsonNumber("007"));
    try std.testing.expect(!isJsonNumber("-01"));
    try std.testing.expect(!isJsonNumber("1."));
}

test "testNameFromYamlItem reads scalar and mapping test names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("not_null", try testNameFromYamlItem(allocator, " not_null "));
    try std.testing.expectEqualStrings("relationships", try testNameFromYamlItem(allocator, "relationships:"));
    try std.testing.expectEqualStrings("accepted_values", try testNameFromYamlItem(allocator, "\"accepted_values\": {values: [a, b]}"));
    try std.testing.expectError(error.UnsupportedYaml, testNameFromYamlItem(allocator, "   "));
}
