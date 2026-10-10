//! Native Decimal cursor values retain coefficients, scale and numeric identity.
const std = @import("std");
const expr = @import("expression.zig");
const decimal = @import("decimal_number.zig");
const ints = @import("expression_number.zig");
const Value = expr.Value;
const A = std.mem.Allocator;
pub fn state(v: Value) ?[]const u8 {
    const marker = v.attribute("__dxt_decimal");
    if (marker != .callable or !std.mem.eql(u8, marker.callable, "__dxt_decimal")) return null;
    const text = v.attribute("__dxt_decimal_text");
    return if (text == .string) text.string else null;
}
fn special(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "NaN") != null or std.mem.indexOf(u8, text, "Infinity") != null;
}
fn nan(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "NaN") != null;
}
pub fn value(a: A, text: []const u8) anyerror!Value {
    const rendered = if (special(text)) try a.dupe(u8, text) else try decimal.render(a, try decimal.parse(a, text));
    var entries: std.ArrayList(expr.Entry) = .empty;
    try entries.appendSlice(a, &.{
        .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
        .{ .key = "__dxt_decimal", .value = .{ .callable = "__dxt_decimal" } },
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_decimal_text", .value = .{ .string = rendered } },
        .{ .key = "__dxt_query_parameter", .value = .{ .callable = "__dxt_query_parameter" } },
        .{ .key = "__dxt_bound_decimal", .value = .{ .string = rendered } },
        .{ .key = "__dxt_rendered", .value = .{ .string = rendered } },
        .{ .key = "__dxt_repr", .value = .{ .string = try std.fmt.allocPrint(a, "Decimal('{s}')", .{rendered}) } },
    });
    const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(rendered.len));
    _ = std.base64.standard.Encoder.encode(encoded, rendered);
    for ([_][]const u8{ "is_finite", "is_nan", "is_infinite", "is_zero", "is_signed", "as_tuple", "adjusted", "copy_abs", "copy_negate", "normalize", "to_integral_value", "to_integral_exact", "quantize" }) |method| try entries.append(a, .{ .key = method, .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_decimal:{s}:{s}", .{ method, encoded }) } });
    return .{ .object = try entries.toOwnedSlice(a) };
}
pub fn truthy(v: Value) ?bool {
    const text = state(v) orelse return null;
    if (special(text)) return true;
    for (text[0 .. std.mem.indexOfAny(u8, text, "eE") orelse text.len]) |ch| if (ch >= '1' and ch <= '9') return true;
    return false;
}
fn operand(a: A, v: Value, allow_float: bool) !decimal.Number {
    if (state(v)) |text| return decimal.parse(a, text);
    if (expr.integerProtocol(v)) |text| return decimal.parse(a, text);
    if (v == .integer) return decimal.parse(a, v.integer);
    if (v == .boolean) return decimal.parse(a, if (v.boolean) "1" else "0");
    if (allow_float) if (expr.floatProtocol(v)) |number| return decimal.fromFloat(a, number);
    return error.JinjaTypeError;
}
pub fn order(a: A, lhs: Value, rhs: Value) !std.math.Order {
    if (state(lhs)) |text| if (nan(text)) return error.DecimalInvalidOperation;
    if (state(rhs)) |text| if (nan(text)) return error.DecimalInvalidOperation;
    const left_inf = if (state(lhs)) |text| std.mem.indexOf(u8, text, "Infinity") != null else if (expr.floatProtocol(lhs)) |n| std.math.isInf(n) else false;
    const right_inf = if (state(rhs)) |text| std.mem.indexOf(u8, text, "Infinity") != null else if (expr.floatProtocol(rhs)) |n| std.math.isInf(n) else false;
    if (left_inf or right_inf) {
        const left_negative = if (state(lhs)) |text| text[0] == '-' else if (expr.floatProtocol(lhs)) |n| std.math.signbit(n) else false;
        const right_negative = if (state(rhs)) |text| text[0] == '-' else if (expr.floatProtocol(rhs)) |n| std.math.signbit(n) else false;
        if (left_inf and right_inf) return std.math.order(@as(i8, if (left_negative) -1 else 1), @as(i8, if (right_negative) -1 else 1));
        return if (left_inf) (if (left_negative) .lt else .gt) else (if (right_negative) .gt else .lt);
    }
    return decimal.order(a, try operand(a, lhs, true), try operand(a, rhs, true));
}
pub fn equal(lhs: Value, rhs: Value) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    return (order(arena.allocator(), lhs, rhs) catch return false) == .eq;
}
pub fn apply(a: A, op: []const u8, lhs: Value, rhs: Value) !Value {
    return value(a, try decimal.render(a, try decimal.apply(a, op, try operand(a, lhs, false), try operand(a, rhs, false))));
}
pub fn integer(a: A, v: Value) ![]const u8 {
    const n = try operand(a, v, false);
    if (n.exponent >= 0) return ints.apply(a, "*", n.coefficient, try ints.apply(a, "**", "10", try std.fmt.allocPrint(a, "{d}", .{n.exponent})));
    const digits = n.coefficient[@intFromBool(n.coefficient[0] == '-')..];
    const drop: usize = @intCast(-@as(i64, n.exponent));
    if (drop >= digits.len) return "0";
    const result = digits[0 .. digits.len - drop];
    return if (n.coefficient[0] == '-') try ints.negate(a, result) else try a.dupe(u8, result);
}
fn quantized(a: A, n: decimal.Number, exponent: i32) !decimal.Number {
    const shift = @as(i64, n.exponent) - exponent;
    if (shift >= 0) return .{ .coefficient = try ints.apply(a, "*", n.coefficient, try ints.apply(a, "**", "10", try std.fmt.allocPrint(a, "{d}", .{shift}))), .exponent = exponent, .negative_zero = n.negative_zero };
    const digits = n.coefficient[@intFromBool(n.coefficient[0] == '-')..];
    const cut: usize = @intCast(-shift);
    var coefficient: []const u8 = if (cut >= digits.len) "0" else try a.dupe(u8, digits[0 .. digits.len - cut]);
    const first: u8 = if (cut > digits.len) '0' else digits[digits.len - cut];
    var sticky = false;
    if (cut <= digits.len) for (digits[digits.len - cut + 1 ..]) |ch| if (ch != '0') {
        sticky = true;
    };
    if (first > '5' or (first == '5' and (sticky or (coefficient[coefficient.len - 1] - '0') % 2 == 1))) coefficient = try ints.apply(a, "+", coefficient, "1");
    return .{ .coefficient = if (n.coefficient[0] == '-') try ints.negate(a, coefficient) else coefficient, .exponent = exponent, .negative_zero = (n.coefficient[0] == '-' or n.negative_zero) and std.mem.eql(u8, coefficient, "0") };
}
pub fn call(a: A, name: []const u8, args: []const expr.Argument) anyerror!?Value {
    if (!std.mem.startsWith(u8, name, "__dxt_decimal:")) return null;
    const at = std.mem.indexOfScalarPos(u8, name, 14, ':') orelse return error.InvalidJinjaArguments;
    const method = name[14..at];
    const encoded = name[at + 1 ..];
    const text = try a.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(encoded));
    try std.base64.standard.Decoder.decode(text, encoded);
    if (std.mem.eql(u8, method, "quantize")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
        const other = try operand(a, args[0].value, false);
        return try value(a, try decimal.render(a, try quantized(a, try decimal.parse(a, text), other.exponent)));
    }
    if (args.len != 0) return error.InvalidJinjaArguments;
    if (std.mem.eql(u8, method, "is_finite")) return .{ .boolean = !special(text) };
    if (std.mem.eql(u8, method, "is_nan")) return .{ .boolean = nan(text) };
    if (std.mem.eql(u8, method, "is_infinite")) return .{ .boolean = std.mem.indexOf(u8, text, "Infinity") != null };
    if (std.mem.eql(u8, method, "is_signed")) return .{ .boolean = text[0] == '-' };
    const n = try decimal.parse(a, text);
    if (std.mem.eql(u8, method, "is_zero")) return .{ .boolean = std.mem.eql(u8, n.coefficient, "0") };
    if (std.mem.eql(u8, method, "copy_abs")) return try value(a, if (text[0] == '-') text[1..] else text);
    if (std.mem.eql(u8, method, "copy_negate")) return try value(a, if (text[0] == '-') text[1..] else try std.fmt.allocPrint(a, "-{s}", .{text}));
    if (std.mem.eql(u8, method, "adjusted")) return try expr.integerValue(a, @as(i64, n.exponent) + @as(i64, @intCast(n.coefficient.len - @intFromBool(n.coefficient[0] == '-'))) - 1);
    if (std.mem.eql(u8, method, "to_integral_value") or std.mem.eql(u8, method, "to_integral_exact")) return try value(a, try decimal.render(a, try quantized(a, n, 0)));
    if (std.mem.eql(u8, method, "normalize")) {
        var normalized = try decimal.apply(a, "+", n, .{ .coefficient = "0", .exponent = n.exponent });
        if (std.mem.eql(u8, normalized.coefficient, "0")) normalized.exponent = 0 else while (normalized.coefficient[normalized.coefficient.len - 1] == '0') {
            normalized.coefficient = normalized.coefficient[0 .. normalized.coefficient.len - 1];
            normalized.exponent += 1;
        }
        return try value(a, try decimal.render(a, normalized));
    }
    if (std.mem.eql(u8, method, "as_tuple")) {
        const digits = n.coefficient[@intFromBool(n.coefficient[0] == '-')..];
        const members = try expr.allocateValues(a, digits.len);
        for (digits, members) |ch, *member| member.* = try expr.integerValue(a, ch - '0');
        const fields = try a.dupe(Value, &.{ try expr.integerValue(a, @intFromBool(n.coefficient[0] == '-' or n.negative_zero)), .{ .tuple = members }, try expr.integerValue(a, n.exponent) });
        const repr = try std.fmt.allocPrint(a, "DecimalTuple(sign={s}, digits={s}, exponent={s})", .{ try fields[0].text(a), try fields[1].text(a), try fields[2].text(a) });
        return .{ .object = try a.dupe(expr.Entry, &.{
            .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
            .{ .key = "__dxt_native_tuple", .value = .{ .callable = "__dxt_native_tuple" } },
            .{ .key = "__dxt_iterable", .value = .{ .list = fields } },
            .{ .key = "__dxt_rendered", .value = .{ .string = repr } },
            .{ .key = "__dxt_repr", .value = .{ .string = repr } },
            .{ .key = "sign", .value = fields[0] },
            .{ .key = "digits", .value = fields[1] },
            .{ .key = "exponent", .value = fields[2] },
        }) };
    }
    return error.UnsupportedJinjaMethod;
}

test "Decimal cursor wrappers preserve scale and cannot be forged with string markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decimal_value = try value(a, "12345678901234567890.123456789");
    try std.testing.expectEqualStrings("12345678901234567890.123456789", state(decimal_value).?);
    try std.testing.expectEqualStrings("Decimal('12345678901234567890.123456789')", decimal_value.attribute("__dxt_repr").string);
    try std.testing.expectEqualStrings("12345678901234567890.123456789", decimal_value.attribute("__dxt_bound_decimal").string);
    const zero = try value(a, "-0.000");
    try std.testing.expect(!truthy(zero).?);
    try std.testing.expectEqualStrings("-0.000", state(zero).?);
    const fake: Value = .{ .object = &.{
        .{ .key = "__dxt_decimal", .value = .{ .string = "__dxt_decimal" } },
        .{ .key = "__dxt_decimal_text", .value = .{ .string = "1" } },
    } };
    try std.testing.expect(state(fake) == null);
}

pub fn unary(a: A, op: []const u8, v: Value) !Value {
    const text = state(v) orelse return error.JinjaTypeError;
    if (special(text)) {
        if (nan(text)) return value(a, text);
        if (std.mem.eql(u8, op, "abs")) return value(a, if (text[0] == '-') text[1..] else text);
        if (std.mem.eql(u8, op, "-")) return value(a, if (text[0] == '-') text[1..] else try std.fmt.allocPrint(a, "-{s}", .{text}));
        return value(a, text);
    }
    var number = try operand(a, v, false);
    if (std.mem.eql(u8, op, "-")) number.coefficient = try ints.negate(a, number.coefficient);
    if (std.mem.eql(u8, op, "abs") and number.coefficient[0] == '-') number.coefficient = number.coefficient[1..];
    number.negative_zero = false;
    return value(a, try decimal.render(a, try decimal.contextual(a, number)));
}
