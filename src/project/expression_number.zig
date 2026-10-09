//! Exact native integers and Python numeric conversion rules for Jinja.
const std = @import("std");
const Big = std.math.big.int.Managed;

fn parse(a: std.mem.Allocator, text: []const u8) !Big {
    var n = try Big.init(a);
    errdefer n.deinit();
    try n.setString(10, text);
    return n;
}

pub fn canonical(a: std.mem.Allocator, text: []const u8, base: u8) ![]const u8 {
    var n = try Big.init(a);
    defer n.deinit();
    try n.setString(base, text);
    return n.toString(a, 10, .lower);
}

pub fn negate(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.eql(u8, text, "0")) return "0";
    if (text[0] == '-') return a.dupe(u8, text[1..]);
    return std.fmt.allocPrint(a, "-{s}", .{text});
}

/// Both operands are canonical decimal. A negative exponent uses the caller's
/// floating implementation; every nonnegative integer operation stays exact.
pub fn apply(a: std.mem.Allocator, op: []const u8, left: []const u8, right: []const u8) ![]const u8 {
    var x = try parse(a, left);
    defer x.deinit();
    var y = try parse(a, right);
    defer y.deinit();
    var result = try Big.init(a);
    defer result.deinit();
    if (std.mem.eql(u8, op, "+")) try result.add(&x, &y) else if (std.mem.eql(u8, op, "-")) try result.sub(&x, &y) else if (std.mem.eql(u8, op, "*")) try result.mul(&x, &y) else if (std.mem.eql(u8, op, "**")) {
        const exponent = y.toInt(u32) catch return error.JinjaNumericOverflow;
        // Bound native allocations consistently with the expression iteration
        // guard; impossible exponents must not overflow big-int capacity math.
        if (exponent > 1000000 or (x.bitCountAbs() != 0 and exponent > 8000000 / x.bitCountAbs())) return error.JinjaNumericOverflow;
        try result.pow(&x, exponent);
    } else if (std.mem.eql(u8, op, "//") or std.mem.eql(u8, op, "%")) {
        if (std.mem.eql(u8, right, "0")) return error.JinjaDivisionByZero;
        var remainder = try Big.init(a);
        defer remainder.deinit();
        try result.divFloor(&remainder, &x, &y);
        if (std.mem.eql(u8, op, "%")) return remainder.toString(a, 10, .lower);
    } else return error.InvalidJinjaExpression;
    return result.toString(a, 10, .lower);
}

pub fn order(left: []const u8, right: []const u8) std.math.Order {
    const negative_left = left[0] == '-';
    const negative_right = right[0] == '-';
    if (negative_left != negative_right) return if (negative_left) .lt else .gt;
    const x = left[@intFromBool(negative_left)..];
    const y = right[@intFromBool(negative_right)..];
    const result = if (x.len == y.len) std.mem.order(u8, x, y) else std.math.order(x.len, y.len);
    return if (negative_left) result.invert() else result;
}

fn floatMagnitude(a: std.mem.Allocator, number: f64) !struct { integer: Big, exponent: i32 } {
    const bits: u64 = @bitCast(number);
    const biased: i32 = @intCast((bits >> 52) & 0x7ff);
    const mantissa = (bits & 0xfffffffffffff) | @as(u64, if (biased == 0) 0 else 0x10000000000000);
    var n = try Big.initSet(a, mantissa);
    if ((bits >> 63) != 0 and mantissa != 0) n.negate();
    return .{ .integer = n, .exponent = if (biased == 0) -1074 else biased - 1023 - 52 };
}

/// Compare against the exact binary rational, without rounding an integer to
/// f64. The caller handles NaN, whose comparisons are always unordered.
pub fn orderFloat(a: std.mem.Allocator, integer: []const u8, number: f64) !std.math.Order {
    if (std.math.isInf(number)) return if (number < 0) .gt else .lt;
    if (std.math.isNan(number)) return error.UnorderedJinjaNumber;
    var x = try parse(a, integer);
    defer x.deinit();
    var floating = try floatMagnitude(a, number);
    defer floating.integer.deinit();
    if (floating.exponent >= 0) try floating.integer.shiftLeft(&floating.integer, @intCast(floating.exponent)) else try x.shiftLeft(&x, @intCast(-floating.exponent));
    return Big.order(x, floating.integer);
}

pub fn floatToInteger(a: std.mem.Allocator, number: f64) ![]const u8 {
    if (!std.math.isFinite(number)) return error.JinjaNumericOverflow;
    var floating = try floatMagnitude(a, number);
    defer floating.integer.deinit();
    if (floating.exponent >= 0) {
        try floating.integer.shiftLeft(&floating.integer, @intCast(floating.exponent));
        return floating.integer.toString(a, 10, .lower);
    }
    var denominator = try Big.initSet(a, @as(u8, 1));
    defer denominator.deinit();
    try denominator.shiftLeft(&denominator, @intCast(-floating.exponent));
    var quotient = try Big.init(a);
    defer quotient.deinit();
    var remainder = try Big.init(a);
    defer remainder.deinit();
    try quotient.divTrunc(&remainder, &floating.integer, &denominator);
    return quotient.toString(a, 10, .lower);
}

pub fn floatText(a: std.mem.Allocator, number: f64) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    try @import("native_repr.zig").float(a, &out.writer, number);
    return out.toOwnedSlice();
}

test "integers retain precision, floor signs and exact mixed comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("9007199254740994", try apply(a, "+", "9007199254740993", "1"));
    try std.testing.expectEqualStrings("1267650600228229401496703205376", try apply(a, "**", "2", "100"));
    try std.testing.expectEqualStrings("-3", try apply(a, "//", "-7", "3"));
    try std.testing.expectEqualStrings("2", try apply(a, "%", "-7", "3"));
    try std.testing.expectEqualStrings("-2", try apply(a, "%", "7", "-3"));
    try std.testing.expectEqual(std.math.Order.gt, try orderFloat(a, "9007199254740993", 9007199254740992.0));
    try std.testing.expectEqual(std.math.Order.lt, try orderFloat(a, "0", std.math.floatMin(f64)));
    try std.testing.expectEqualStrings("-1", try floatToInteger(a, -1.9));
    try std.testing.expectEqualStrings("100000000000000000000", try floatToInteger(a, 1e20));
}
