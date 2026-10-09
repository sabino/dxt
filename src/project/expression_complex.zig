//! Native Python complex arithmetic for Jinja exponentiation results.
const std = @import("std");
const numbers = @import("expression_number.zig");
// CPython's complex power uses the platform C math functions. Using the same
// native implementation preserves the last bits of displayed scalar results.
const libm = struct {
    extern fn hypot(f64, f64) f64;
    extern fn pow(f64, f64) f64;
    extern fn atan2(f64, f64) f64;
    extern fn exp(f64) f64;
    extern fn log(f64) f64;
    extern fn cos(f64) f64;
    extern fn sin(f64) f64;
};
pub const Complex = struct { real: f64, imaginary: f64 };

pub fn add(x: Complex, y: Complex) Complex {
    return .{ .real = x.real + y.real, .imaginary = x.imaginary + y.imaginary };
}
pub fn subtract(x: Complex, y: Complex) Complex {
    return .{ .real = x.real - y.real, .imaginary = x.imaginary - y.imaginary };
}
pub fn multiply(x: Complex, y: Complex) Complex {
    return .{ .real = x.real * y.real - x.imaginary * y.imaginary, .imaginary = x.real * y.imaginary + x.imaginary * y.real };
}
pub fn divide(x: Complex, y: Complex) !Complex {
    if (y.real == 0 and y.imaginary == 0) return error.JinjaDivisionByZero;
    // Python's ratio algorithm avoids squaring huge or tiny denominator parts.
    if (@abs(y.real) >= @abs(y.imaginary)) {
        const ratio = y.imaginary / y.real;
        const denominator = y.real + y.imaginary * ratio;
        return .{ .real = (x.real + x.imaginary * ratio) / denominator, .imaginary = (x.imaginary - x.real * ratio) / denominator };
    }
    const ratio = y.real / y.imaginary;
    const denominator = y.real * ratio + y.imaginary;
    return .{ .real = (x.real * ratio + x.imaginary) / denominator, .imaginary = (x.imaginary * ratio - x.real) / denominator };
}
pub fn power(x: Complex, y: Complex) !Complex {
    if (y.real == 0 and y.imaginary == 0) return .{ .real = 1, .imaginary = 0 };
    if (x.real == 0 and x.imaginary == 0) {
        if (y.real < 0 or y.imaginary != 0) return error.JinjaDivisionByZero;
        return .{ .real = 0, .imaginary = 0 };
    }
    if (y.imaginary == 0 and @floor(y.real) == y.real and @abs(y.real) <= 100) {
        var result = Complex{ .real = 1, .imaginary = 0 };
        var factor = x;
        var count: u8 = @intFromFloat(@abs(y.real));
        while (count != 0) {
            if (count & 1 != 0) result = multiply(result, factor);
            count >>= 1;
            if (count != 0) factor = multiply(factor, factor);
        }
        return if (y.real < 0) try divide(.{ .real = 1, .imaginary = 0 }, result) else result;
    }
    const magnitude = libm.hypot(x.real, x.imaginary);
    var length = libm.pow(magnitude, y.real);
    const angle = libm.atan2(x.imaginary, x.real);
    var phase = angle * y.real;
    if (y.imaginary != 0) {
        length /= libm.exp(angle * y.imaginary);
        phase += y.imaginary * libm.log(magnitude);
    }
    if (std.math.isFinite(magnitude) and std.math.isFinite(y.real) and std.math.isFinite(y.imaginary) and !std.math.isFinite(length)) return error.JinjaNumericOverflow;
    return .{ .real = length * libm.cos(phase), .imaginary = length * libm.sin(phase) };
}

fn component(a: std.mem.Allocator, value: f64) ![]const u8 {
    const formatted = try numbers.floatText(a, value);
    return if (std.mem.endsWith(u8, formatted, ".0")) formatted[0 .. formatted.len - 2] else formatted;
}
pub fn text(a: std.mem.Allocator, value: Complex) ![]const u8 {
    if (value.real == 0 and !std.math.signbit(value.real)) return std.fmt.allocPrint(a, "{s}j", .{try component(a, value.imaginary)});
    return std.fmt.allocPrint(a, "({s}{c}{s}j)", .{ try component(a, value.real), @as(u8, if (!std.math.isNan(value.imaginary) and std.math.signbit(value.imaginary)) '-' else '+'), try component(a, @abs(value.imaginary)) });
}

test "native complex power, stable division and signed component rendering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try power(.{ .real = -1, .imaginary = 0 }, .{ .real = 0.5, .imaginary = 0 });
    try std.testing.expectEqualStrings("(6.123233995736766e-17+1j)", try text(a, root));
    try std.testing.expectEqualStrings("(-1+0j)", try text(a, .{ .real = -1, .imaginary = 0 }));
    try std.testing.expectEqualStrings("(-0+1j)", try text(a, .{ .real = -0.0, .imaginary = 1 }));
    try std.testing.expectEqualStrings("(nan+nanj)", try text(a, .{ .real = -std.math.nan(f64), .imaginary = -std.math.nan(f64) }));
    const divided = try divide(.{ .real = 1e300, .imaginary = 1e300 }, .{ .real = 1e300, .imaginary = 1e300 });
    try std.testing.expectEqual(@as(f64, 1), divided.real);
    try std.testing.expectEqual(@as(f64, 0), divided.imaginary);
}
