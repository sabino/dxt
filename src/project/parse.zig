const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");

const JsonScalar = types.JsonScalar;
const GenericTestDef = types.GenericTestDef;
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

pub const GenericTestNames = struct {
    full: []const u8,
    compiled: []const u8,
};

pub fn synthesizeGenericTestNames(allocator: std.mem.Allocator, test_def: GenericTestDef, model_name: []const u8, column_name: ?[]const u8) !GenericTestNames {
    var clean_args: std.ArrayList([]const u8) = .empty;
    defer {
        for (clean_args.items) |arg| allocator.free(arg);
        clean_args.deinit(allocator);
    }

    if (column_name) |column| try clean_args.append(allocator, try cleanTestNamePart(allocator, column));
    if (std.mem.eql(u8, test_def.name, "relationships")) {
        try clean_args.append(allocator, try cleanTestNamePart(allocator, test_def.relationship_field));
        try clean_args.append(allocator, try cleanTestNamePart(allocator, test_def.relationship_to));
    } else if (std.mem.eql(u8, test_def.name, "accepted_values")) {
        for (test_def.accepted_values.items) |value| {
            try clean_args.append(allocator, try cleanTestNamePart(allocator, value));
        }
    }

    const test_identifier = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ test_def.name, model_name });
    const unique = try joinStrings(allocator, clean_args.items, "__");
    defer allocator.free(unique);

    const full = if (unique.len == 0)
        try std.fmt.allocPrint(allocator, "{s}_", .{test_identifier})
    else
        try std.fmt.allocPrint(allocator, "{s}_{s}", .{ test_identifier, unique });
    if (full.len < 64) return .{ .full = full, .compiled = full };

    const label = genericTestHashFull(full);
    const prefix_len = @min(test_identifier.len, 30);
    const compiled = try std.fmt.allocPrint(allocator, "{s}_{s}", .{ test_identifier[0..prefix_len], label });
    return .{ .full = full, .compiled = compiled };
}

pub fn genericTestUniqueId(allocator: std.mem.Allocator, package_name: []const u8, name: []const u8, test_def: GenericTestDef, model_name: []const u8, column_name: ?[]const u8) ![]const u8 {
    const model_kwarg = try std.fmt.allocPrint(allocator, "{{{{ get_where_subquery(ref('{s}')) }}}}", .{model_name});
    defer allocator.free(model_kwarg);
    const metadata = try genericTestMetadataRepr(allocator, test_def, model_kwarg, column_name);
    defer allocator.free(metadata);

    const hash_input = try std.fmt.allocPrint(allocator, "{s}{s}", .{ name, metadata });
    defer allocator.free(hash_input);
    const suffix = genericTestHashSuffix(hash_input);
    return try std.fmt.allocPrint(allocator, "test.{s}.{s}.{s}", .{ package_name, name, suffix });
}

fn genericTestMetadataRepr(allocator: std.mem.Allocator, test_def: GenericTestDef, model_kwarg: []const u8, column_name: ?[]const u8) ![]const u8 {
    if (std.mem.eql(u8, test_def.name, "accepted_values")) {
        const values = try pythonReprStringList(allocator, test_def.accepted_values.items);
        defer allocator.free(values);
        if (column_name) |column| {
            return try std.fmt.allocPrint(allocator, "{{'kwargs': {{'column_name': '{s}', 'model': \"{s}\", 'values': {s}}}, 'name': '{s}', 'namespace': 'None'}}", .{ column, model_kwarg, values, test_def.name });
        }
    }
    if (std.mem.eql(u8, test_def.name, "relationships")) {
        if (column_name) |column| {
            return try std.fmt.allocPrint(allocator, "{{'kwargs': {{'column_name': '{s}', 'field': '{s}', 'model': \"{s}\", 'to': \"{s}\"}}, 'name': '{s}', 'namespace': 'None'}}", .{ column, test_def.relationship_field, model_kwarg, test_def.relationship_to, test_def.name });
        }
    }
    if (column_name) |column| {
        return try std.fmt.allocPrint(allocator, "{{'kwargs': {{'column_name': '{s}', 'model': \"{s}\"}}, 'name': '{s}', 'namespace': 'None'}}", .{ column, model_kwarg, test_def.name });
    }
    return try std.fmt.allocPrint(allocator, "{{'kwargs': {{'model': \"{s}\"}}, 'name': '{s}', 'namespace': 'None'}}", .{ model_kwarg, test_def.name });
}

fn genericTestHashSuffix(input: []const u8) [10]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(input, &digest, .{});
    var hex: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;
    var suffix: [10]u8 = undefined;
    @memcpy(&suffix, hex[22..32]);
    return suffix;
}

fn genericTestHashFull(input: []const u8) [32]u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(input, &digest, .{});
    var hex: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;
    return hex;
}

fn pythonReprStringList(allocator: std.mem.Allocator, values: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '[');
    for (values, 0..) |value, index| {
        if (index != 0) try out.appendSlice(allocator, ", ");
        const repr = try pythonReprString(allocator, value);
        defer allocator.free(repr);
        try out.appendSlice(allocator, repr);
    }
    try out.append(allocator, ']');
    return try out.toOwnedSlice(allocator);
}

fn pythonReprString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const has_single = std.mem.indexOfScalar(u8, value, '\'') != null;
    const has_double = std.mem.indexOfScalar(u8, value, '"') != null;
    const quote: u8 = if (has_single and !has_double) '"' else '\'';

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, quote);
    for (value) |ch| {
        switch (ch) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (ch == quote) try out.append(allocator, '\\');
                try out.append(allocator, ch);
            },
        }
    }
    try out.append(allocator, quote);
    return try out.toOwnedSlice(allocator);
}

fn joinStrings(allocator: std.mem.Allocator, values: []const []const u8, separator: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (values, 0..) |value, index| {
        if (index != 0) try out.appendSlice(allocator, separator);
        try out.appendSlice(allocator, value);
    }
    return try out.toOwnedSlice(allocator);
}

fn cleanTestNamePart(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var previous_was_replacement = false;
    for (value) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            try out.append(allocator, ch);
            previous_was_replacement = false;
        } else {
            if (previous_was_replacement) continue;
            try out.append(allocator, '_');
            previous_was_replacement = true;
        }
    }
    return try out.toOwnedSlice(allocator);
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

test "synthesizeGenericTestNames preserves short generic test identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const names = try synthesizeGenericTestNames(allocator, .{ .name = "not_null" }, "customers", "id");
    try std.testing.expectEqualStrings("not_null_customers_id", names.full);
    try std.testing.expectEqualStrings("not_null_customers_id", names.compiled);
}

test "synthesizeGenericTestNames normalizes accepted value arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var values: std.ArrayList([]const u8) = .empty;
    defer values.deinit(allocator);
    try values.append(allocator, "placed");
    try values.append(allocator, "shipped late");

    const names = try synthesizeGenericTestNames(allocator, .{ .name = "accepted_values", .accepted_values = values }, "orders", "status");
    try std.testing.expectEqualStrings("accepted_values_orders_status__placed__shipped_late", names.full);
    try std.testing.expectEqualStrings("accepted_values_orders_status__placed__shipped_late", names.compiled);
}

test "genericTestUniqueId keeps dbt-style hash suffix stable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const test_def = GenericTestDef{ .name = "not_null" };
    const unique_id = try genericTestUniqueId(allocator, "demo", "not_null_customers_id", test_def, "customers", "id");
    try std.testing.expectEqualStrings("test.demo.not_null_customers_id.422908bfae", unique_id);
}
