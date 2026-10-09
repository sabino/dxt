//! Python's BaseContext JSON decoder accepts nonfinite constants and bytes.
//! This codec is separate from strict artifact validation and project JSON.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;

fn delimiter(byte: u8) bool {
    return std.mem.indexOfScalar(u8, " \t\r\n,:[]{}", byte) != null;
}

pub fn load(a: std.mem.Allocator, input: Value) !Value {
    const binary = input.attribute("__dxt_binary");
    const source = if (input == .string) input.string else if (binary == .string) try decode(a, binary.string) else return error.JinjaTypeError;
    var marker: []const u8 = "999999999999999999999999999999999999900";
    while (std.mem.indexOf(u8, source, marker) != null) marker = try std.fmt.allocPrint(a, "{s}0", .{marker});
    var normalized: std.Io.Writer.Allocating = .init(a);
    var quoted = false;
    var escaped = false;
    var i: usize = 0;
    while (i < source.len) {
        const byte = source[i];
        if (!quoted and (i == 0 or delimiter(source[i - 1]))) {
            var matched = false;
            inline for (.{ "NaN", "Infinity", "-Infinity" }, 0..) |token, index| {
                if (!matched and std.mem.startsWith(u8, source[i..], token) and (i + token.len == source.len or delimiter(source[i + token.len]))) {
                    try normalized.writer.print("{s}{d}", .{ marker, index });
                    i += token.len;
                    matched = true;
                }
            }
            if (matched) continue;
        }
        try normalized.writer.writeByte(byte);
        if (quoted) {
            if (escaped) escaped = false else if (byte == '\\') escaped = true else if (byte == '"') quoted = false;
        } else if (byte == '"') quoted = true;
        i += 1;
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, a, normalized.written(), .{ .allocate = .alloc_always, .parse_numbers = false, .duplicate_field_behavior = .use_last });
    defer parsed.deinit();
    return convert(a, parsed.value, marker);
}

fn convert(a: std.mem.Allocator, input: std.json.Value, marker: []const u8) anyerror!Value {
    if (input == .number_string and input.number_string.len == marker.len + 1 and std.mem.startsWith(u8, input.number_string, marker)) {
        return switch (input.number_string[marker.len]) {
            '0' => nan(a),
            '1' => expression.floatValue(a, std.math.inf(f64)),
            '2' => expression.floatValue(a, -std.math.inf(f64)),
            else => error.InvalidJson,
        };
    }
    if (input == .number_string and std.mem.indexOfAny(u8, input.number_string, ".eE") == null) {
        const digits = input.number_string.len - @as(usize, @intFromBool(input.number_string[0] == '-'));
        if (digits > 4300) return error.InvalidJson;
    }
    if (input == .array) {
        const members = try expression.allocateValues(a, input.array.items.len);
        for (input.array.items, members) |item, *member| member.* = try convert(a, item, marker);
        return .{ .list = members };
    }
    if (input == .object) {
        const entries = try expression.allocateEntries(a, input.object.count());
        var iterator = input.object.iterator();
        var i: usize = 0;
        while (iterator.next()) |entry| : (i += 1) entries[i] = .{ .key = try a.dupe(u8, entry.key_ptr.*), .value = try convert(a, entry.value_ptr.*, marker) };
        return .{ .object = entries };
    }
    return @import("dbt_context.zig").cloneValue(a, try @import("config_value.zig").toExpression(a, input));
}

pub fn nan(a: std.mem.Allocator) !Value {
    const result = try expression.floatValue(a, std.math.nan(f64));
    for (@constCast(result.object)) |*entry| {
        if (std.mem.eql(u8, entry.key, "__dxt_float_identity")) entry.value = .{ .string = "python-json-constant-nan" };
    }
    return result;
}

fn decode(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var width: usize = 1;
    var little = false;
    var offset: usize = 0;
    if (std.mem.startsWith(u8, bytes, "\x00\x00\xfe\xff")) {
        width = 4;
        offset = 4;
    } else if (std.mem.startsWith(u8, bytes, "\xff\xfe\x00\x00")) {
        width = 4;
        little = true;
        offset = 4;
    } else if (std.mem.startsWith(u8, bytes, "\xfe\xff")) {
        width = 2;
        offset = 2;
    } else if (std.mem.startsWith(u8, bytes, "\xff\xfe")) {
        width = 2;
        little = true;
        offset = 2;
    } else if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) {
        offset = 3;
    } else if (bytes.len >= 4 and bytes[0] == 0) {
        width = if (bytes[1] == 0) 4 else 2;
    } else if (bytes.len >= 4 and bytes[1] == 0) {
        width = if (bytes[2] == 0 and bytes[3] == 0) 4 else 2;
        little = true;
    } else if (bytes.len == 2 and (bytes[0] == 0 or bytes[1] == 0)) {
        width = 2;
        little = bytes[1] == 0;
    }
    if (width == 1) {
        if (!std.unicode.utf8ValidateSlice(bytes[offset..])) return error.InvalidJson;
        return bytes[offset..];
    }
    if ((bytes.len - offset) % width != 0) return error.InvalidJson;
    var out: std.Io.Writer.Allocating = .init(a);
    while (offset < bytes.len) {
        var code = unit(bytes[offset..][0..width], little);
        offset += width;
        if (width == 2 and code >= 0xd800 and code <= 0xdbff) {
            if (offset == bytes.len) return error.InvalidJson;
            const lower = unit(bytes[offset..][0..2], little);
            if (lower < 0xdc00 or lower > 0xdfff) return error.InvalidJson;
            code = 0x10000 + (code - 0xd800) * 1024 + lower - 0xdc00;
            offset += 2;
        }
        if (code > 0x10ffff) return error.InvalidJson;
        var utf8: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(@intCast(code), &utf8) catch return error.InvalidJson;
        try out.writer.writeAll(utf8[0..length]);
    }
    return out.toOwnedSlice();
}

fn unit(bytes: []const u8, little: bool) u32 {
    var result: u32 = 0;
    for (0..bytes.len) |index| result = result * 256 + bytes[if (little) bytes.len - index - 1 else index];
    return result;
}

test "runtime JSON accepts nonfinite constants without changing string contents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const result = try load(a, .{ .string = "[NaN,Infinity,-Infinity,1e400,\"NaN\"]" });
    try std.testing.expect(std.math.isNan(expression.floatProtocol(result.list[0]).?));
    try std.testing.expect(std.math.isInf(expression.floatProtocol(result.list[1]).?));
    try std.testing.expect(std.math.isInf(expression.floatProtocol(result.list[3]).?));
    try std.testing.expectEqualStrings("NaN", result.list[4].string);
    try std.testing.expect(@import("mapping_keys.zig").keyEqual(result.list[0], try nan(a)));
    try std.testing.expectError(error.SyntaxError, load(a, .{ .string = "1NaN" }));
}
