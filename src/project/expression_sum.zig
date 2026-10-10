//! CPython 3.12's sum lanes, including Neumaier float compensation.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;

pub const Accumulator = struct {
    mode: enum { integer, float, generic } = .generic,
    value: Value,
    integer: i64 = 0,
    total: f64 = 0,
    correction: f64 = 0,

    pub fn init(start: Value) Accumulator {
        var result = Accumulator{ .value = start };
        if (start == .integer) {
            if (std.fmt.parseInt(i64, start.integer, 10)) |integer| {
                result.mode = .integer;
                result.integer = integer;
            } else |_| {}
        } else if (expression.floatProtocol(start)) |number| {
            result.mode = .float;
            result.total = number;
        }
        return result;
    }

    pub fn add(self: *Accumulator, a: std.mem.Allocator, item: Value) !void {
        @setFloatMode(.strict);
        switch (self.mode) {
            .integer => {
                if (item == .integer or item == .boolean) {
                    if (expression.integerIndex(item)) |integer| {
                        const result = @addWithOverflow(self.integer, integer);
                        if (result[1] == 0) {
                            self.integer = result[0];
                            return;
                        }
                    } else |_| {}
                }
                // Overflow and integer subclasses permanently leave the
                // exact-int lane. A first float can enter the float lane.
                self.value = try expression.addValues(a, try expression.integerValue(a, self.integer), item);
                if (expression.floatProtocol(self.value)) |number| {
                    self.mode = .float;
                    self.total = number;
                } else self.mode = .generic;
            },
            .float => {
                if (expression.floatProtocol(item)) |number| {
                    const next = self.total + number;
                    if (@abs(self.total) >= @abs(number)) {
                        self.correction += (self.total - next) + number;
                    } else self.correction += (number - next) + self.total;
                    self.total = next;
                    return;
                }
                if (item == .integer or item == .boolean or expression.integerProtocol(item) != null) {
                    if (expression.integerIndex(item)) |integer| {
                        // Core adds machine-sized ints directly without
                        // updating its floating-point correction.
                        self.total += @as(f64, @floatFromInt(integer));
                        return;
                    } else |_| {}
                }
                self.value = try expression.addValues(a, try expression.floatValue(a, self.floatResult()), item);
                self.mode = .generic;
            },
            .generic => self.value = try expression.addValues(a, self.value, item),
        }
    }

    fn floatResult(self: Accumulator) f64 {
        @setFloatMode(.strict);
        // Preserve negative zero and avoid making an overflowed infinity NaN
        // by adding a non-finite correction.
        return if (self.correction != 0 and std.math.isFinite(self.correction)) self.total + self.correction else self.total;
    }

    pub fn finish(self: Accumulator, a: std.mem.Allocator) !Value {
        return switch (self.mode) {
            .integer => expression.integerValue(a, self.integer),
            .float => expression.floatValue(a, self.floatResult()),
            .generic => self.value,
        };
    }
};

test "float compensation retains lost low-order terms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sum = Accumulator.init(.{ .integer = "0" });
    for ([_]Value{ .{ .number = 1e16 }, .{ .number = 1 }, .{ .number = -1e16 } }) |item| try sum.add(a, item);
    try std.testing.expectEqual(@as(f64, 1), try expression.numericFloat(try sum.finish(a)));
    var mixed = Accumulator.init(.{ .integer = "0" });
    for ([_]Value{ .{ .number = 1e16 }, .{ .integer = "1" }, .{ .number = -1e16 } }) |item| try mixed.add(a, item);
    try std.testing.expectEqual(@as(f64, 0), try expression.numericFloat(try mixed.finish(a)));
}

test "overflow and bool starts stay in generic addition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]Value{ .{ .boolean = true }, .{ .integer = "-9223372036854775808" } }) |start| {
        var sum = Accumulator.init(start);
        if (start == .integer) try sum.add(a, .{ .integer = "9223372036854775808" });
        for ([_]Value{ .{ .number = 1e16 }, .{ .number = 1 }, .{ .number = -1e16 } }) |item| try sum.add(a, item);
        try std.testing.expectEqual(@as(f64, 0), try expression.numericFloat(try sum.finish(a)));
    }
}

test "float completion preserves signed zero and allocates fresh NaN identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zero = try Accumulator.init(.{ .number = -0.0 }).finish(a);
    try std.testing.expect(std.math.signbit(try expression.numericFloat(zero)));
    const nan = try expression.floatValue(a, std.math.nan(f64));
    const fresh = try Accumulator.init(nan).finish(a);
    try std.testing.expect(!try expression.testValue("sameas", nan, &.{.{ .value = fresh }}));
}
