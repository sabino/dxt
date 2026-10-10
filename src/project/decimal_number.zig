//! Exact finite Decimal coefficients and the default 28-digit, half-even context.
const std = @import("std");
const numbers = @import("expression_number.zig");
const A = std.mem.Allocator;
pub const Number = struct { coefficient: []const u8, exponent: i32, negative_zero: bool = false };
fn magnitude(text: []const u8) []const u8 {
    return text[@intFromBool(text[0] == '-')..];
}
fn positive(a: A, text: []const u8) ![]const u8 {
    return a.dupe(u8, magnitude(text));
}
fn appendZeros(a: A, text: []const u8, count: usize) ![]const u8 {
    if (count > 1000000) return error.JinjaNumericOverflow;
    const output = try a.alloc(u8, text.len + count);
    @memcpy(output[0..text.len], text);
    @memset(output[text.len..], '0');
    return output;
}
pub fn parse(a: A, text: []const u8) !Number {
    if (text.len == 0) return error.InvalidDecimal;
    const exp_at = std.mem.indexOfAny(u8, text, "eE") orelse text.len;
    var exponent: i32 = if (exp_at < text.len) std.fmt.parseInt(i32, text[exp_at + 1 ..], 10) catch return error.InvalidDecimal else 0;
    const body = text[0..exp_at];
    var digits: std.ArrayList(u8) = .empty;
    const negative = body[0] == '-';
    var point = false;
    var count: usize = 0;
    for (body, 0..) |ch, i| {
        if (i == 0 and (ch == '-' or ch == '+')) continue;
        if (ch == '.' and !point) {
            point = true;
            continue;
        }
        if (!std.ascii.isDigit(ch)) return error.InvalidDecimal;
        try digits.append(a, ch);
        count += 1;
        if (point) exponent = std.math.sub(i32, exponent, 1) catch return error.InvalidDecimal;
    }
    if (count == 0) return error.InvalidDecimal;
    const coefficient = try numbers.canonical(a, digits.items, 10);
    return .{ .coefficient = if (negative and !std.mem.eql(u8, coefficient, "0")) try numbers.negate(a, coefficient) else coefficient, .exponent = exponent, .negative_zero = negative and std.mem.eql(u8, coefficient, "0") };
}
pub fn render(a: A, n: Number) ![]const u8 {
    const digits = magnitude(n.coefficient);
    const negative = n.coefficient[0] == '-' or n.negative_zero;
    const adjusted = @as(i64, n.exponent) + @as(i64, @intCast(digits.len)) - 1;
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    if (negative) try out.writer.writeByte('-');
    if (n.exponent > 0 or adjusted < -6) {
        try out.writer.writeByte(digits[0]);
        if (digits.len > 1) {
            try out.writer.writeByte('.');
            try out.writer.writeAll(digits[1..]);
        }
        try out.writer.print("E{c}{d}", .{ @as(u8, if (adjusted >= 0) '+' else '-'), @abs(adjusted) });
    } else if (n.exponent == 0) try out.writer.writeAll(digits) else {
        const position = @as(i64, @intCast(digits.len)) + n.exponent;
        if (position > 0) {
            try out.writer.writeAll(digits[0..@intCast(position)]);
            try out.writer.writeByte('.');
            try out.writer.writeAll(digits[@intCast(position)..]);
        } else {
            try out.writer.writeAll("0.");
            if (position < -1000000) return error.JinjaNumericOverflow;
            for (0..@intCast(-position)) |_| try out.writer.writeByte('0');
            try out.writer.writeAll(digits);
        }
    }
    return out.toOwnedSlice();
}
fn round(a: A, n: Number) !Number {
    const digits = magnitude(n.coefficient);
    if (digits.len <= 28) return n;
    const cut = digits.len - 28;
    var coefficient: []const u8 = try a.dupe(u8, digits[0..28]);
    const tail = digits[28..];
    var sticky = false;
    for (tail[1..]) |ch| if (ch != '0') {
        sticky = true;
    };
    if (tail[0] > '5' or (tail[0] == '5' and (sticky or ((coefficient[27] - '0') % 2 == 1)))) coefficient = try numbers.apply(a, "+", coefficient, "1");
    const next = Number{ .coefficient = if (n.coefficient[0] == '-') try numbers.negate(a, coefficient) else coefficient, .exponent = std.math.add(i32, n.exponent, @intCast(cut)) catch return error.JinjaNumericOverflow, .negative_zero = n.negative_zero };
    return round(a, next);
}
pub fn order(a: A, x: Number, y: Number) !std.math.Order {
    if (std.mem.eql(u8, x.coefficient, "0") and std.mem.eql(u8, y.coefficient, "0")) return .eq;
    const exponent = @min(x.exponent, y.exponent);
    const left = try appendZeros(a, x.coefficient, @intCast(@as(i64, x.exponent) - exponent));
    const right = try appendZeros(a, y.coefficient, @intCast(@as(i64, y.exponent) - exponent));
    return numbers.order(left, right);
}
pub fn apply(a: A, op: []const u8, x: Number, y: Number) !Number {
    if (std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-")) {
        const exponent = @min(x.exponent, y.exponent);
        const left = try appendZeros(a, x.coefficient, @intCast(@as(i64, x.exponent) - exponent));
        const right = try appendZeros(a, y.coefficient, @intCast(@as(i64, y.exponent) - exponent));
        return round(a, .{ .coefficient = try numbers.apply(a, op, left, right), .exponent = exponent });
    }
    if (std.mem.eql(u8, op, "*")) return round(a, .{ .coefficient = try numbers.apply(a, op, x.coefficient, y.coefficient), .exponent = std.math.add(i32, x.exponent, y.exponent) catch return error.JinjaNumericOverflow, .negative_zero = (x.coefficient[0] == '-' or x.negative_zero) != (y.coefficient[0] == '-' or y.negative_zero) });
    if (std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "//") or std.mem.eql(u8, op, "%")) {
        if (std.mem.eql(u8, y.coefficient, "0")) return error.JinjaDivisionByZero;
        const left = try positive(a, x.coefficient);
        const right = try positive(a, y.coefficient);
        if (std.mem.eql(u8, left, "0")) return .{ .coefficient = "0", .exponent = if (std.mem.eql(u8, op, "/")) x.exponent - y.exponent else 0, .negative_zero = x.negative_zero != (y.coefficient[0] == '-' or y.negative_zero) };
        const difference = @as(i64, @intCast(left.len)) - @as(i64, @intCast(right.len));
        const candidate_order = if (difference >= 0) numbers.order(left, try appendZeros(a, right, @intCast(difference))) else numbers.order(try appendZeros(a, left, @intCast(-difference)), right);
        const power = if (std.mem.eql(u8, op, "/")) 27 - difference + @as(i64, @intFromBool(candidate_order == .lt)) else @as(i64, x.exponent) - y.exponent;
        const numerator = if (power >= 0) try appendZeros(a, left, @intCast(power)) else left;
        const denominator = if (power < 0) try appendZeros(a, right, @intCast(-power)) else right;
        var quotient = try numbers.apply(a, "//", numerator, denominator);
        const remainder = try numbers.apply(a, "%", numerator, denominator);
        if (std.mem.eql(u8, op, "/")) {
            const half = numbers.order(try numbers.apply(a, "*", remainder, "2"), denominator);
            if (half == .gt or (half == .eq and (quotient[quotient.len - 1] - '0') % 2 == 1)) quotient = try numbers.apply(a, "+", quotient, "1");
        }
        if ((x.coefficient[0] == '-') != (y.coefficient[0] == '-')) quotient = try numbers.negate(a, quotient);
        var exponent: i32 = if (std.mem.eql(u8, op, "/")) @intCast(@as(i64, x.exponent) - y.exponent - power) else 0;
        if (std.mem.eql(u8, op, "/") and std.mem.eql(u8, remainder, "0")) {
            const preferred = x.exponent - y.exponent;
            while (exponent < preferred and quotient.len > 1 and quotient[quotient.len - 1] == '0') {
                quotient = quotient[0 .. quotient.len - 1];
                exponent += 1;
            }
        }
        if (std.mem.eql(u8, op, "%")) return apply(a, "-", x, try apply(a, "*", .{ .coefficient = quotient, .exponent = 0 }, y));
        return round(a, .{ .coefficient = quotient, .exponent = exponent });
    }
    return error.JinjaTypeError;
}

pub fn fromFloat(a: A, n: f64) !Number {
    if (!std.math.isFinite(n)) return error.InvalidDecimal;
    const bits: u64 = @bitCast(n);
    const biased: i32 = @intCast((bits >> 52) & 0x7ff);
    const mantissa = (bits & 0xfffffffffffff) | @as(u64, if (biased == 0) 0 else 0x10000000000000);
    const power = (if (biased == 0) @as(i32, 1) else biased) - 1023 - 52;
    var coefficient: []const u8 = try std.fmt.allocPrint(a, "{d}", .{mantissa});
    if (power >= 0) coefficient = try numbers.apply(a, "*", coefficient, try numbers.apply(a, "**", "2", try std.fmt.allocPrint(a, "{d}", .{power}))) else coefficient = try numbers.apply(a, "*", coefficient, try numbers.apply(a, "**", "5", try std.fmt.allocPrint(a, "{d}", .{-power})));
    if (bits >> 63 != 0) coefficient = try numbers.negate(a, coefficient);
    return .{ .coefficient = coefficient, .exponent = if (power < 0) power else 0, .negative_zero = bits >> 63 != 0 and mantissa == 0 };
}

test "Decimal values preserve scale, exact comparison and half-even context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tiny = try parse(a, "0.123456789012345678901234567890");
    try std.testing.expectEqualStrings("0.123456789012345678901234567890", try render(a, tiny));
    try std.testing.expectEqualStrings("12.340", try render(a, try parse(a, "12.340")));
    try std.testing.expectEqualStrings("2.00", try render(a, try apply(a, "+", try parse(a, "1.25"), try parse(a, "0.75"))));
    try std.testing.expectEqualStrings("0.3333333333333333333333333333", try render(a, try apply(a, "/", try parse(a, "1"), try parse(a, "3"))));
    try std.testing.expectEqualStrings("-1", try render(a, try apply(a, "%", try parse(a, "-7"), try parse(a, "3"))));
    try std.testing.expectEqual(std.math.Order.lt, try order(a, try parse(a, "0.1"), try fromFloat(a, 0.1)));
    try std.testing.expectEqualStrings("-0.0", try render(a, try parse(a, "-0.0")));
}
