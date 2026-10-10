//! Stock psycopg2 range values expose their typed bounds without becoming maps.
const std = @import("std");
const expr = @import("expression.zig");
const Value = expr.Value;
const A = std.mem.Allocator;
pub fn isRange(v: Value) bool {
    const marker = v.attribute("__dxt_range");
    return marker == .callable and std.mem.eql(u8, marker.callable, "__dxt_range");
}
fn endpoint(a: A, v: Value, repr: bool) ![]const u8 {
    return switch (v) {
        .none => "None",
        .integer => |text| a.dupe(u8, text),
        .number => |number| @import("expression_number.zig").floatText(a, number),
        .object => blk: {
            const shown = v.attribute(if (repr) "__dxt_repr" else "__dxt_rendered");
            if (shown != .string) return error.InvalidPostgresRangeEndpoint;
            break :blk shown.string;
        },
        else => error.InvalidPostgresRangeEndpoint,
    };
}
pub fn value(a: A, class_name: []const u8, lower: Value, upper: Value, bounds: [2]u8, empty: bool) !Value {
    const shown = if (empty) "empty" else try std.fmt.allocPrint(a, "{c}{s}, {s}{c}", .{ bounds[0], try endpoint(a, lower, false), try endpoint(a, upper, false), bounds[1] });
    const repr = if (empty) try std.fmt.allocPrint(a, "{s}(empty=True)", .{class_name}) else try std.fmt.allocPrint(a, "{s}({s}, {s}, '{s}')", .{ class_name, try endpoint(a, lower, true), try endpoint(a, upper, true), &bounds });
    return .{ .object = try a.dupe(expr.Entry, &.{
        .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_range", .value = .{ .callable = "__dxt_range" } },
        .{ .key = "__dxt_rendered", .value = .{ .string = shown } },
        .{ .key = "__dxt_repr", .value = .{ .string = repr } },
        .{ .key = "__dxt_bool", .value = .{ .callable = if (empty) "__dxt_range_bool:0" else "__dxt_range_bool:1" } },
        .{ .key = "lower", .value = if (empty) .none else lower },
        .{ .key = "upper", .value = if (empty) .none else upper },
        .{ .key = "isempty", .value = .{ .boolean = empty } },
        .{ .key = "lower_inc", .value = .{ .boolean = !empty and lower != .none and bounds[0] == '[' } },
        .{ .key = "upper_inc", .value = .{ .boolean = !empty and upper != .none and bounds[1] == ']' } },
        .{ .key = "lower_inf", .value = .{ .boolean = !empty and lower == .none } },
        .{ .key = "upper_inf", .value = .{ .boolean = !empty and upper == .none } },
        .{ .key = "_bounds", .value = if (empty) .none else .{ .string = try a.dupe(u8, &bounds) } },
    }) };
}
pub fn truthy(v: Value) ?bool {
    if (!isRange(v)) return null;
    return !v.attribute("isempty").boolean;
}
pub fn equal(lhs: Value, rhs: Value) bool {
    if (!isRange(lhs) or !isRange(rhs)) return false;
    if (lhs.attribute("isempty").boolean or rhs.attribute("isempty").boolean) return lhs.attribute("isempty").boolean and rhs.attribute("isempty").boolean;
    return expr.equalValues(lhs.attribute("lower"), rhs.attribute("lower")) and expr.equalValues(lhs.attribute("upper"), rhs.attribute("upper")) and expr.equalValues(lhs.attribute("_bounds"), rhs.attribute("_bounds"));
}
pub fn contains(a: A, range: Value, item: Value) anyerror!bool {
    if (!isRange(range)) return error.JinjaTypeError;
    if (range.attribute("isempty").boolean) return false;
    const lower = range.attribute("lower");
    const upper = range.attribute("upper");
    if (lower != .none) {
        const order = try expr.valueOrder(a, item, lower);
        if (order == .lt or (order == .eq and !range.attribute("lower_inc").boolean)) return false;
    }
    if (upper != .none) {
        const order = try expr.valueOrder(a, item, upper);
        if (order == .gt or (order == .eq and !range.attribute("upper_inc").boolean)) return false;
    }
    return true;
}
pub fn call(name: []const u8, args: []const expr.Argument) !?Value {
    if (!std.mem.startsWith(u8, name, "__dxt_range_bool:")) return null;
    if (args.len != 0 or name.len != 18) return error.InvalidJinjaArguments;
    return .{ .boolean = name[17] == '1' };
}

test "range carriers preserve empty and unbounded states without forged markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const empty = try value(a, "NumericRange", .none, .none, .{ '[', ')' }, true);
    try std.testing.expect(!truthy(empty).?);
    try std.testing.expect(empty.attribute("_bounds") == .none);
    try std.testing.expect(!empty.attribute("lower_inf").boolean);
    const unbounded = try value(a, "NumericRange", .none, .none, .{ '(', ')' }, false);
    try std.testing.expect(truthy(unbounded).?);
    try std.testing.expectEqualStrings("(None, None)", unbounded.attribute("__dxt_rendered").string);
    try std.testing.expect(unbounded.attribute("lower_inf").boolean);
    const fake: Value = .{ .object = &.{.{ .key = "__dxt_range", .value = .{ .string = "__dxt_range" } }} };
    try std.testing.expect(!isRange(fake));
}
