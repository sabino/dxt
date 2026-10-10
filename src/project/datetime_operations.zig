//! Exact datetime/timedelta arithmetic without Python runtime dependencies.
const std = @import("std");
const expression = @import("expression.zig");
const numbers = @import("expression_number.zig");
const dates = @import("timestamp_context.zig");
const datetime = @import("modules_datetime.zig");
const Value = expression.Value;
const Allocator = std.mem.Allocator;

pub fn duration(value: Value) ?i96 {
    const marker = value.attribute("__dxt_duration");
    return if (marker == .integer) std.fmt.parseInt(i96, marker.integer, 10) catch null else null;
}
pub fn time(value: Value) ?i64 {
    const marker = value.attribute("__dxt_time");
    return if (marker == .integer) std.fmt.parseInt(i64, marker.integer, 10) catch null else null;
}
pub fn offsetError(value: Value) bool {
    const marker = value.attribute("__dxt_temporal_offset_error");
    return marker == .callable and std.mem.eql(u8, marker.callable, "__dxt_temporal_offset_error");
}
pub fn validateComparison(left: Value, right: Value) !void {
    if (!offsetError(left) and !offsetError(right)) return;
    const zone_left = if (time(left) != null) left.attribute("tzinfo") else left.attribute("__dxt_timezone");
    const zone_right = if (time(right) != null) right.attribute("tzinfo") else right.attribute("__dxt_timezone");
    const a = zone_left.attribute("__dxt_timezone_identity");
    const b = zone_right.attribute("__dxt_timezone_identity");
    if (a == .string and b == .string and std.mem.eql(u8, a.string, b.string)) return;
    if ((time(left) != null and time(right) != null) or (dates.state(left) != null and dates.state(right) != null)) return error.AbstractTimeZoneMethod;
}
pub fn hashable(value: Value) bool {
    return duration(value) != null or time(value) != null;
}
pub fn equal(left: Value, right: Value) bool {
    if (duration(left)) |lhs| return if (duration(right)) |rhs| lhs == rhs else false;
    if (time(left)) |lhs| {
        const rhs = time(right) orelse return false;
        const a = offset(left);
        const b = offset(right);
        if ((a == null) != (b == null)) return false;
        return @as(i96, lhs) - (a orelse 0) == @as(i96, rhs) - (b orelse 0);
    }
    return false;
}
fn offset(value: Value) ?i64 {
    const marker = value.attribute("__dxt_offset_us");
    return if (marker == .integer) std.fmt.parseInt(i64, marker.integer, 10) catch null else null;
}
pub fn order(left: Value, right: Value) !std.math.Order {
    try validateComparison(left, right);
    if (duration(left)) |lhs| return std.math.order(lhs, duration(right) orelse return error.JinjaTypeError);
    if (time(left)) |lhs| {
        const rhs = time(right) orelse return error.JinjaTypeError;
        const a = offset(left);
        const b = offset(right);
        if ((a == null) != (b == null)) return error.JinjaTypeError;
        return std.math.order(@as(i96, lhs) - (a orelse 0), @as(i96, rhs) - (b orelse 0));
    }
    return error.JinjaTypeError;
}

const Ratio = struct { numerator: []const u8, denominator: []const u8 };
fn ratio(a: Allocator, value: Value) !Ratio {
    if (value == .integer) return .{ .numerator = value.integer, .denominator = "1" };
    if (value == .boolean) return .{ .numerator = if (value.boolean) "1" else "0", .denominator = "1" };
    const number = expression.floatProtocol(value) orelse return error.JinjaTypeError;
    if (!std.math.isFinite(number)) return error.JinjaNumericOverflow;
    const bits: u64 = @bitCast(number);
    const biased: i32 = @intCast((bits >> 52) & 0x7ff);
    const mantissa = (bits & 0xfffffffffffff) | @as(u64, if (biased == 0) 0 else 0x10000000000000);
    const exponent = if (biased == 0) @as(i32, -1074) else biased - 1023 - 52;
    var numerator: []const u8 = try std.fmt.allocPrint(a, "{d}", .{mantissa});
    if ((bits >> 63) != 0) numerator = try numbers.negate(a, numerator);
    const power = try numbers.apply(a, "**", "2", try std.fmt.allocPrint(a, "{d}", .{@abs(exponent)}));
    return if (exponent >= 0) .{ .numerator = try numbers.apply(a, "*", numerator, power), .denominator = "1" } else .{ .numerator = numerator, .denominator = power };
}
fn roundRatio(a: Allocator, numerator_: []const u8, denominator_: []const u8) !i96 {
    if (std.mem.eql(u8, denominator_, "0")) return error.JinjaDivisionByZero;
    const negative = denominator_[0] == '-';
    const numerator = if (negative) try numbers.negate(a, numerator_) else numerator_;
    const denominator = if (negative) denominator_[1..] else denominator_;
    var quotient = try numbers.apply(a, "//", numerator, denominator);
    const remainder = try numbers.apply(a, "%", numerator, denominator);
    const comparison = numbers.order(try numbers.apply(a, "*", remainder, "2"), denominator);
    if (comparison == .gt or (comparison == .eq and !std.mem.eql(u8, try numbers.apply(a, "%", quotient, "2"), "0"))) quotient = try numbers.apply(a, "+", quotient, "1");
    return std.fmt.parseInt(i96, quotient, 10) catch error.JinjaNumericOverflow;
}
pub fn constructDuration(a: Allocator, values: []const Value, scales: []const i96) !Value {
    var total: []const u8 = "0";
    var leftover: f64 = 0;
    for (values, scales) |value, scale| {
        const scale_text = try std.fmt.allocPrint(a, "{d}", .{scale});
        if (value == .integer or value == .boolean) {
            const current = try ratio(a, value);
            total = try numbers.apply(a, "+", total, try numbers.apply(a, "*", current.numerator, scale_text));
        } else {
            const number = expression.floatProtocol(value) orelse return error.JinjaTypeError;
            if (!std.math.isFinite(number)) return error.JinjaNumericOverflow;
            const integral = @trunc(number);
            const fractional_us = (number - integral) * @as(f64, @floatFromInt(scale));
            const whole_us = @trunc(fractional_us);
            total = try numbers.apply(a, "+", total, try numbers.apply(a, "*", try numbers.floatToInteger(a, integral), scale_text));
            total = try numbers.apply(a, "+", total, try numbers.floatToInteger(a, whole_us));
            leftover += fractional_us - whole_us;
        }
    }
    const whole = @floor(leftover);
    total = try numbers.apply(a, "+", total, try numbers.floatToInteger(a, whole));
    const fractional = leftover - whole;
    if (fractional > 0.5 or (fractional == 0.5 and !std.mem.eql(u8, try numbers.apply(a, "%", total, "2"), "0"))) total = try numbers.apply(a, "+", total, "1");
    return try datetime.durationValue(a, std.fmt.parseInt(i96, total, 10) catch return error.JinjaNumericOverflow);
}
pub fn unary(a: Allocator, operation: []const u8, value: Value) anyerror!?Value {
    const micros = duration(value) orelse return null;
    return try datetime.durationValue(a, if (std.mem.eql(u8, operation, "+")) micros else if (std.mem.eql(u8, operation, "-")) -micros else @intCast(@abs(micros)));
}
fn shifted(a: Allocator, value: Value, micros: i96) anyerror!Value {
    const state = dates.state(value) orelse return error.JinjaTypeError;
    const change = if (state.date_only) @divFloor(micros, std.time.us_per_day) * std.time.ns_per_day else micros * std.time.ns_per_us;
    return dates.datetimeValueWithOffsetUs(a, state.civil_ns + change, state.date_only, state.offset_us, state.timezone, 0);
}
fn sameZone(left: ?Value, right: ?Value) bool {
    if (left == null or right == null) return left == null and right == null;
    const a = left.?.attribute("__dxt_timezone_identity");
    const b = right.?.attribute("__dxt_timezone_identity");
    return a == .string and b == .string and std.mem.eql(u8, a.string, b.string);
}
pub fn apply(a: Allocator, op: []const u8, left: Value, right: Value) anyerror!?Value {
    const lhs = duration(left);
    const rhs = duration(right);
    if (std.mem.eql(u8, op, "+")) {
        if (lhs != null and rhs != null) return try datetime.durationValue(a, lhs.? + rhs.?);
        if (lhs != null and dates.state(right) != null) return try shifted(a, right, lhs.?);
        if (rhs != null and dates.state(left) != null) return try shifted(a, left, rhs.?);
    }
    if (std.mem.eql(u8, op, "-")) {
        if (lhs != null and rhs != null) return try datetime.durationValue(a, lhs.? - rhs.?);
        if (rhs != null and dates.state(left) != null) return try shifted(a, left, if (dates.state(left).?.date_only) -@divFloor(rhs.?, std.time.us_per_day) * std.time.us_per_day else -rhs.?);
        if (dates.state(left)) |first| if (dates.state(right)) |second| {
            if (first.date_only != second.date_only) return error.JinjaTypeError;
            try validateComparison(left, right);
            if ((first.offset_us == null) != (second.offset_us == null)) return error.JinjaTypeError;
            const same = sameZone(first.timezone, second.timezone);
            const first_ns = first.civil_ns - if (same) @as(i96, 0) else @as(i96, first.offset_us orelse 0) * std.time.ns_per_us;
            const second_ns = second.civil_ns - if (same) @as(i96, 0) else @as(i96, second.offset_us orelse 0) * std.time.ns_per_us;
            return try datetime.durationValue(a, @divFloor(first_ns - second_ns, std.time.ns_per_us));
        };
    }
    if (lhs != null and rhs != null) {
        if (std.mem.eql(u8, op, "/")) return .{ .number = try numbers.divide(a, try std.fmt.allocPrint(a, "{d}", .{lhs.?}), try std.fmt.allocPrint(a, "{d}", .{rhs.?})) };
        if (rhs.? == 0) return error.JinjaDivisionByZero;
        if (std.mem.eql(u8, op, "//")) return try expression.integerValue(a, @divFloor(lhs.?, rhs.?));
        if (std.mem.eql(u8, op, "%")) return try datetime.durationValue(a, lhs.? - @divFloor(lhs.?, rhs.?) * rhs.?);
    }
    if (std.mem.eql(u8, op, "*") and (lhs != null or rhs != null)) {
        const micros = lhs orelse rhs.?;
        const multiplier = try ratio(a, if (lhs != null) right else left);
        return try datetime.durationValue(a, try roundRatio(a, try numbers.apply(a, "*", try std.fmt.allocPrint(a, "{d}", .{micros}), multiplier.numerator), multiplier.denominator));
    }
    if (lhs != null and (std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "//"))) {
        if (std.mem.eql(u8, op, "//")) {
            const divisor = try expression.integerIndex(right);
            if (divisor == 0) return error.JinjaDivisionByZero;
            return try datetime.durationValue(a, @divFloor(lhs.?, divisor));
        }
        const divisor = try ratio(a, right);
        return try datetime.durationValue(a, try roundRatio(a, try numbers.apply(a, "*", try std.fmt.allocPrint(a, "{d}", .{lhs.?}), divisor.denominator), divisor.numerator));
    }
    if (lhs != null or rhs != null or time(left) != null or time(right) != null or dates.state(left) != null or dates.state(right) != null) {
        if (std.mem.indexOfScalar(u8, "<>", op[0]) != null) return null;
        return error.JinjaTypeError;
    }
    return null;
}

test "abstract timezone subtraction only bypasses offset calls for identical zones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zone = try @import("datetime_tzinfo.zig").value(a);
    const other = try @import("datetime_tzinfo.zig").value(a);
    const first = try dates.datetimeValueWithOffsetUs(a, 0, false, null, zone, 0);
    const same = try dates.datetimeValueWithOffsetUs(a, std.time.ns_per_day, false, null, zone, 0);
    const distinct = try dates.datetimeValueWithOffsetUs(a, 0, false, null, other, 0);
    const naive = try dates.datetimeValue(a, 0, false, null);
    try std.testing.expectEqual(@as(i96, std.time.us_per_day), duration((try apply(a, "-", same, first)).?).?);
    try std.testing.expectError(error.AbstractTimeZoneMethod, apply(a, "-", first, distinct));
    try std.testing.expectError(error.AbstractTimeZoneMethod, apply(a, "-", first, naive));
    try std.testing.expectError(error.AbstractTimeZoneMethod, apply(a, "-", naive, first));
    try std.testing.expectError(error.AbstractTimeZoneMethod, @import("yaml_values.zig").order(naive, first));
    try std.testing.expectEqual(std.math.Order.lt, try @import("yaml_values.zig").order(first, same));
}
