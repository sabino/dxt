//! UUID values returned by a stock DuckDB cursor keep UUID identity and fields.
const std = @import("std");
const expr = @import("expression.zig");
const binary = @import("yaml_values.zig");
const Value = expr.Value;
const Allocator = std.mem.Allocator;

pub fn hex(input: Value) ?[]const u8 {
    const marker = input.attribute("__dxt_uuid");
    if (marker != .callable or !std.mem.eql(u8, marker.callable, "__dxt_uuid")) return null;
    const digits = input.attribute("hex");
    if (digits != .string or digits.string.len != 32) return null;
    for (digits.string) |digit| if (!std.ascii.isHex(digit)) return null;
    return digits.string;
}

pub fn equal(left: Value, right: Value) ?bool {
    const lhs = hex(left);
    const rhs = hex(right);
    if (lhs == null and rhs == null) return null;
    return lhs != null and rhs != null and std.ascii.eqlIgnoreCase(lhs.?, rhs.?);
}

pub fn order(left: Value, right: Value) !?std.math.Order {
    const lhs = hex(left);
    const rhs = hex(right);
    if (lhs == null and rhs == null) return null;
    const a = std.fmt.parseInt(u128, lhs orelse return error.JinjaTypeError, 16) catch return error.InvalidNativeUuid;
    const b = std.fmt.parseInt(u128, rhs orelse return error.JinjaTypeError, 16) catch return error.InvalidNativeUuid;
    return std.math.order(a, b);
}

pub fn value(a: Allocator, text: []const u8) !Value {
    if (text.len != 36) return error.InvalidNativeUuid;
    var digits: [32]u8 = undefined;
    var position: usize = 0;
    for (text, 0..) |ch, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (ch != '-') return error.InvalidNativeUuid;
        } else {
            if (!std.ascii.isHex(ch)) return error.InvalidNativeUuid;
            digits[position] = std.ascii.toLower(ch);
            position += 1;
        }
    }
    var raw: [16]u8 = undefined;
    _ = try std.fmt.hexToBytes(&raw, &digits);
    const canonical = try std.fmt.allocPrint(a, "{s}-{s}-{s}-{s}-{s}", .{ digits[0..8], digits[8..12], digits[12..16], digits[16..20], digits[20..32] });
    const number = try std.fmt.parseInt(u128, &digits, 16);
    const time_low: u32 = @truncate(number >> 96);
    const time_mid: u16 = @truncate(number >> 80);
    const time_hi_version: u16 = @truncate(number >> 64);
    const clock_seq_hi_variant: u8 = @truncate(number >> 56);
    const clock_seq_low: u8 = @truncate(number >> 48);
    const node: u48 = @truncate(number);
    const fields = try a.dupe(Value, &.{
        try expr.integerValue(a, time_low),             try expr.integerValue(a, time_mid),      try expr.integerValue(a, time_hi_version),
        try expr.integerValue(a, clock_seq_hi_variant), try expr.integerValue(a, clock_seq_low), try expr.integerValue(a, node),
    });
    const variant: []const u8 = if (clock_seq_hi_variant & 0x80 == 0) "reserved for NCS compatibility" else if (clock_seq_hi_variant & 0x40 == 0) "specified in RFC 4122" else if (clock_seq_hi_variant & 0x20 == 0) "reserved for Microsoft compatibility" else "reserved for future definition";
    const version: Value = if (clock_seq_hi_variant & 0xc0 == 0x80) try expr.integerValue(a, time_hi_version >> 12) else .none;
    const timestamp = (@as(u64, time_hi_version & 0x0fff) << 48) | (@as(u64, time_mid) << 32) | time_low;
    const clock_seq = (@as(u16, clock_seq_hi_variant & 0x3f) << 8) | clock_seq_low;
    var little_endian = raw;
    std.mem.reverse(u8, little_endian[0..4]);
    std.mem.reverse(u8, little_endian[4..6]);
    std.mem.reverse(u8, little_endian[6..8]);
    return .{ .object = try a.dupe(expr.Entry, &.{
        .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_uuid", .value = .{ .callable = "__dxt_uuid" } },
        .{ .key = "__dxt_rendered", .value = .{ .string = canonical } },
        .{ .key = "__dxt_repr", .value = .{ .string = try std.fmt.allocPrint(a, "UUID('{s}')", .{canonical}) } },
        .{ .key = "hex", .value = .{ .string = try a.dupe(u8, &digits) } },
        .{ .key = "int", .value = try expr.integerValue(a, number) },
        .{ .key = "bytes", .value = try binary.fromBytes(a, &raw) },
        .{ .key = "bytes_le", .value = try binary.fromBytes(a, &little_endian) },
        .{ .key = "urn", .value = .{ .string = try std.fmt.allocPrint(a, "urn:uuid:{s}", .{canonical}) } },
        .{ .key = "fields", .value = .{ .tuple = fields } },
        .{ .key = "time_low", .value = fields[0] },
        .{ .key = "time_mid", .value = fields[1] },
        .{ .key = "time_hi_version", .value = fields[2] },
        .{ .key = "clock_seq_hi_variant", .value = fields[3] },
        .{ .key = "clock_seq_low", .value = fields[4] },
        .{ .key = "node", .value = fields[5] },
        .{ .key = "time", .value = try expr.integerValue(a, timestamp) },
        .{ .key = "clock_seq", .value = try expr.integerValue(a, clock_seq) },
        .{ .key = "variant", .value = .{ .string = variant } },
        .{ .key = "version", .value = version },
    }) };
}

test "cursor UUID fields remain exact and independently fetched values compare by UUID" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = try value(a, "F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6");
    const same = try value(a, "f81d4fae-7dec-11d0-a765-00a0c91e6bf6");
    const other = try value(a, "ffffffff-ffff-4fff-bfff-ffffffffffff");
    try std.testing.expect(equal(first, same).?);
    try std.testing.expect(!equal(first, first.attribute("int")).?);
    try std.testing.expectEqual(std.math.Order.lt, (try order(first, other)).?);
    try std.testing.expectError(error.JinjaTypeError, order(first, .{ .integer = "1" }));
    try std.testing.expectEqualStrings("329800735698586629295641978511506172918", first.attribute("int").integer);
    try std.testing.expectEqualStrings("130742845922168750", first.attribute("time").integer);
    try std.testing.expectEqualStrings("10085", first.attribute("clock_seq").integer);
    try std.testing.expectEqualStrings("1", first.attribute("version").integer);
    try std.testing.expectEqualStrings("specified in RFC 4122", first.attribute("variant").string);
    try std.testing.expectEqualStrings("f81d4fae-7dec-11d0-a765-00a0c91e6bf6", try first.text(a));
    try std.testing.expectEqual(@as(usize, 6), first.attribute("fields").tuple.len);
    try std.testing.expectEqualStrings(&.{ 0xae, 0x4f, 0x1d, 0xf8, 0xec, 0x7d, 0xd0, 0x11, 0xa7, 0x65, 0, 0xa0, 0xc9, 0x1e, 0x6b, 0xf6 }, first.attribute("bytes_le").attribute("__dxt_binary").string);
    for ([_][]const u8{ "00000000-0000-0000-0000-000000000000", "00000000-0000-0000-c000-000000000000", "00000000-0000-0000-e000-000000000000" }) |text| try std.testing.expect((try value(a, text)).attribute("version") == .none);
    const fake: Value = .{ .object = &.{.{ .key = "__dxt_uuid", .value = .{ .string = "__dxt_uuid" } }} };
    try std.testing.expect(hex(fake) == null);
    try std.testing.expect(!equal(first, fake).?);
    try std.testing.expectError(error.InvalidNativeUuid, value(a, "f81d4fae7dec11d0a76500a0c91e6bf6"));
}
