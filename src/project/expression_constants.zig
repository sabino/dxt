//! Safe Jinja AST folding and type-sensitive immutable constant keys.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;

pub fn probe(a: std.mem.Allocator, input: []const u8) anyerror!?Value {
    const Guard = struct {
        fn resolve(_: *anyopaque, _: []const u8, _: std.mem.Allocator) !Value {
            return error.NotStaticJinjaExpression;
        }
        fn call(_: *anyopaque, _: []const u8, _: []const expression.Argument, _: std.mem.Allocator) !Value {
            return error.NotStaticJinjaExpression;
        }
    };
    var context: u8 = 0;
    const value = expression.evaluate(a, input, .{ .context = &context, .resolve = Guard.resolve, .call = Guard.call, .static_only = true }) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    return if (safe(value, 0)) value else null;
}

fn safe(value: Value, depth: usize) bool {
    if (depth > 128) return false;
    if (expression.floatProtocol(value) != null or expression.complexProtocol(value) != null) return true;
    return switch (value) {
        .none, .boolean, .integer, .string => true,
        .list, .tuple => |values| blk: {
            for (values) |member| if (!safe(member, depth + 1)) break :blk false;
            break :blk true;
        },
        .object => |entries| blk: {
            for (entries) |entry| if (!safe(expression.entryKey(entry), depth + 1) or !safe(entry.value, depth + 1)) break :blk false;
            break :blk true;
        },
        else => false,
    };
}

/// Mutable containers are rebuilt while their immutable children can be pooled.
/// Nonfinite numbers are emitted as runtime constructors by Python's compiler.
pub fn key(a: std.mem.Allocator, value: Value) !?[]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    if (!try writeKey(&out.writer, value, 0)) return null;
    return try out.toOwnedSlice();
}
fn writeKey(w: *std.Io.Writer, value: Value, depth: usize) anyerror!bool {
    if (depth > 128) return false;
    if (expression.floatProtocol(value)) |number| {
        if (!std.math.isFinite(number)) return false;
        try w.print("f{x};", .{@as(u64, @bitCast(number))});
        return true;
    }
    if (expression.complexProtocol(value)) |number| {
        if (!std.math.isFinite(number.real) or !std.math.isFinite(number.imaginary)) return false;
        try w.print("c{x},{x};", .{ @as(u64, @bitCast(number.real)), @as(u64, @bitCast(number.imaginary)) });
        return true;
    }
    switch (value) {
        .none => try w.writeAll("n;"),
        .boolean => |enabled| try w.writeAll(if (enabled) "b1;" else "b0;"),
        .integer => |text| try w.print("i{d}:{s};", .{ text.len, text }),
        .string => |text| try w.print("s{d}:{s};", .{ text.len, text }),
        .tuple => |members| {
            try w.print("t{d}:", .{members.len});
            for (members) |member| if (!try writeKey(w, member, depth + 1)) return false;
            try w.writeByte(';');
        },
        else => return false,
    }
    return true;
}

/// CPython interns ASCII identifier characters in generated string constants.
pub fn globallyInterned(value: Value) bool {
    if (value != .string) return false;
    for (value.string) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}
/// These builtin strings share the compiler's interned constant namespace.
pub fn globalString(value: Value) Value {
    if (value != .string) return value;
    return .{ .string = @import("expression_identity.zig").builtinBooleanText(@import("expression_identity.zig").cachedString(value.string)) };
}

test "constant probes reject every runtime name and call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "missing|default('x')", "range(3)", "dict(x=1)", "'abc'.upper()", "zip([],[])|list", "x + 1", "[1]|map('float')|first", "[1]|select|first" }) |input|
        try std.testing.expect(try probe(a, input) == null);
    try std.testing.expectEqualStrings("1000", (try probe(a, "500 + 500")).?.integer);
    try std.testing.expectEqualStrings("ABC", (try probe(a, "'abc'|upper")).?.string);
    try std.testing.expect(!(try probe(a, "false and missing_call()")).?.boolean);
}

test "constant keys preserve type, signed zero and mutable freshness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(!std.mem.eql(u8, (try key(a, .{ .boolean = true })).?, (try key(a, .{ .integer = "1" })).?));
    try std.testing.expect(!std.mem.eql(u8, (try key(a, .{ .number = 0 })).?, (try key(a, .{ .number = -0.0 })).?));
    try std.testing.expect(try key(a, try expression.floatValue(a, std.math.nan(f64))) == null);
    try std.testing.expect(try key(a, .{ .list = &.{.{ .integer = "1" }} }) == null);
    try std.testing.expectEqualStrings("t1:i1:1;;", (try key(a, .{ .tuple = &.{.{ .integer = "1" }} })).?);
    try std.testing.expect(globallyInterned(.{ .string = "_a1" }));
    try std.testing.expect(!globallyInterned(.{ .string = "éé" }));
}

test "compiler callback pools static subexpressions without resolving probes" {
    const Frame = struct {
        values: std.StringHashMap(Value),
        fn resolve(_: *anyopaque, _: []const u8, _: std.mem.Allocator) !Value {
            return .{ .integer = "1" };
        }
        fn call(_: *anyopaque, _: []const u8, _: []const expression.Argument, _: std.mem.Allocator) !Value {
            return error.UnexpectedConstantCall;
        }
        fn constant(context: *anyopaque, value: Value, a: std.mem.Allocator) !Value {
            const frame: *@This() = @ptrCast(@alignCast(context));
            const token = (try key(a, value)) orelse return value;
            const entry = try frame.values.getOrPut(token);
            if (!entry.found_existing) entry.value_ptr.* = value;
            return entry.value_ptr.*;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var frame = Frame{ .values = std.StringHashMap(Value).init(a) };
    const host = expression.Host{ .context = &frame, .resolve = Frame.resolve, .call = Frame.call, .constant = Frame.constant };
    const first = try expression.evaluate(a, "1000", host);
    const second = try expression.evaluate(a, "500+500", host);
    try std.testing.expect(first.integer.ptr == second.integer.ptr);
    try std.testing.expectEqualStrings("1001", (try expression.evaluate(a, "x+(500+500)", host)).integer);
}
