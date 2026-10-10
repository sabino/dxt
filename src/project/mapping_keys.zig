//! Jinja dictionary keys retain their native values. String context objects
//! share the same Entry representation without converting user keys to text.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const Entry = expression.Entry;

pub fn key(item: Entry) Value {
    return item.typed_key orelse .{ .string = item.key };
}

pub fn matches(item: Entry, candidate: Value) bool {
    return keyEqual(key(item), candidate);
}

pub fn entry(container: Value, candidate: Value) anyerror!?Entry {
    try hashable(candidate);
    if (container != .object) return error.JinjaTypeError;
    for (container.object) |item| if (matches(item, candidate)) return item;
    return null;
}

pub fn create(candidate: Value, value: Value) anyerror!Entry {
    try hashable(candidate);
    return if (candidate == .string)
        Entry{ .key = candidate.string, .value = value }
    else
        Entry{ .key = "", .typed_key = candidate, .value = value };
}

pub fn hashable(candidate: Value) anyerror!void {
    return checkHashable(candidate, 0);
}

fn checkHashable(candidate: Value, depth: usize) anyerror!void {
    if (depth > 128) return error.JinjaExpressionDepthExceeded;
    if (expression.isNotImplemented(candidate)) return;
    if (@import("query_memoryview.zig").state(candidate) != null or @import("query_memoryview.zig").chunkIdentity(candidate) != null) return;
    if (@import("query_column.zig").items(candidate) != null) return error.JinjaTypeError;
    if (@import("query_type.zig").name(candidate) != null) return;
    if (@import("builtin_bound_method.zig").isBound(candidate)) return;
    if (@import("datetime_bound_method.zig").isBound(candidate)) return;
    if (@import("decimal_value.zig").state(candidate) != null) return;
    if (@import("range_value.zig").isRange(candidate)) {
        try checkHashable(candidate.attribute("lower"), depth + 1);
        try checkHashable(candidate.attribute("upper"), depth + 1);
        return;
    }
    if (@import("datetime_operations.zig").offsetError(candidate)) return error.AbstractTimeZoneMethod;
    if (@import("native_tuple.zig").items(candidate)) |items| {
        for (items) |item| try checkHashable(item, depth + 1);
        return;
    }
    if (@import("yaml_values.zig").isHashable(candidate)) return;
    if (expression.integerProtocol(candidate) != null) return;
    if (expression.floatProtocol(candidate) != null) return;
    if (expression.complexProtocol(candidate) != null) return;
    if (immutableIdentity(candidate) != null) return;
    switch (candidate) {
        .missing,
        .none,
        .boolean,
        .integer,
        .number,
        .complex,
        .string,
        .callable,
        .undefined,
        .conditional_undefined,
        .ordinary_undefined,
        .capture_undefined,
        => {},
        .tuple => |items| for (items) |item| try checkHashable(item, depth + 1),
        .object => {
            // BaseRelation is immutable and implements hash(render()). The
            // native serialized definition supplies its complete equality
            // identity, including policies and adapter-specific attributes.
            if (candidate.attribute("__dxt_relation") != .string) return error.JinjaTypeError;
        },
        else => return error.JinjaTypeError,
    }
}

pub fn keyEqual(left: Value, right: Value) bool {
    if (expression.isNotImplemented(left) or expression.isNotImplemented(right)) return expression.isNotImplemented(left) and expression.isNotImplemented(right);
    if (@import("query_memoryview.zig").state(left) != null or @import("query_memoryview.zig").state(right) != null or @import("query_memoryview.zig").chunkIdentity(left) != null or @import("query_memoryview.zig").chunkIdentity(right) != null) return expression.equalValues(left, right);
    if (@import("query_type.zig").keyEqual(left, right)) |equal| return equal;
    if (@import("range_value.zig").isRange(left) or @import("range_value.zig").isRange(right)) return @import("range_value.zig").equal(left, right);
    if (@import("decimal_value.zig").state(left) != null or @import("decimal_value.zig").state(right) != null) return expression.equalValues(left, right);
    const builtin_methods = @import("builtin_bound_method.zig");
    if (builtin_methods.isBound(left) or builtin_methods.isBound(right)) return builtin_methods.equal(left, right);
    const methods = @import("datetime_bound_method.zig");
    if (methods.isBound(left) or methods.isBound(right)) return methods.equal(left, right);
    if (@import("native_tuple.zig").items(left)) |a| {
        const b = @import("native_tuple.zig").items(right) orelse return false;
        if (a.len != b.len) return false;
        for (a, b) |lhs, rhs| if (!keyEqual(lhs, rhs)) return false;
        return true;
    }
    if (@import("native_tuple.zig").items(right) != null) return false;
    const yaml_values = @import("yaml_values.zig");
    if (yaml_values.isHashable(left) or yaml_values.isHashable(right))
        return yaml_values.keyEqual(left, right);
    const builtin_left = left.attribute("__dxt_timezone_builtin").truthy();
    const builtin_right = right.attribute("__dxt_timezone_builtin").truthy();
    if (builtin_left or builtin_right)
        return builtin_left and builtin_right and expression.equalValues(
            left.attribute("__dxt_timezone_offset_us"),
            right.attribute("__dxt_timezone_offset_us"),
        );
    if (immutableIdentity(left)) |a| {
        const b = immutableIdentity(right) orelse return false;
        return std.mem.eql(u8, a.kind, b.kind) and std.mem.eql(u8, a.value, b.value);
    }
    if (immutableIdentity(right) != null) return false;
    if (expression.complexProtocol(left)) |a| {
        if (expression.complexProtocol(right)) |b| {
            const a_nan = std.math.isNan(a.real) or std.math.isNan(a.imaginary);
            const b_nan = std.math.isNan(b.real) or std.math.isNan(b.imaginary);
            if (a_nan or b_nan) {
                if (!a_nan or !b_nan) return false;
                const id_a = left.attribute("__dxt_complex_identity");
                const id_b = right.attribute("__dxt_complex_identity");
                return id_a == .string and id_b == .string and std.mem.eql(u8, id_a.string, id_b.string);
            }
        }
    }
    if (expression.floatProtocol(left)) |a| {
        if (expression.floatProtocol(right)) |b| {
            if (std.math.isNan(a) or std.math.isNan(b)) {
                if (!std.math.isNan(a) or !std.math.isNan(b)) return false;
                const id_a = left.attribute("__dxt_float_identity");
                const id_b = right.attribute("__dxt_float_identity");
                return id_a == .string and id_b == .string and std.mem.eql(u8, id_a.string, id_b.string);
            }
        }
    }
    if (left == .object or right == .object) {
        if (expression.floatProtocol(left) != null or expression.floatProtocol(right) != null)
            return expression.equalValues(left, right);
        if (expression.complexProtocol(left) != null or expression.complexProtocol(right) != null)
            return expression.equalValues(left, right);
        if (expression.integerProtocol(left) != null or expression.integerProtocol(right) != null)
            return expression.equalValues(left, right);
        const relation_left = left.attribute("__dxt_relation");
        const relation_right = right.attribute("__dxt_relation");
        return relation_left == .string and relation_right == .string and
            std.mem.eql(u8, relation_left.string, relation_right.string);
    }
    if (left == .tuple and right == .tuple) {
        if (left.tuple.len != right.tuple.len) return false;
        for (left.tuple, right.tuple) |a, b| if (!keyEqual(a, b)) return false;
        return true;
    }
    return expression.equalValues(left, right);
}

const ImmutableIdentity = struct { kind: []const u8, value: []const u8 };

fn immutableIdentity(value: Value) ?ImmutableIdentity {
    if (value != .object) return null;
    inline for (.{ "__dxt_timezone_identity", "__dxt_class_identity" }) |kind| {
        const identity = value.attribute(kind);
        if (identity == .string) return .{ .kind = kind, .value = identity.string };
    }
    return null;
}

/// Python's JSON encoder accepts primitive scalar keys and converts their
/// spelling at serialization time, independently of dictionary identity.
pub fn jsonKey(allocator: std.mem.Allocator, candidate: Value) ![]const u8 {
    if (candidate == .string) return candidate.string;
    if (candidate == .none) return "null";
    if (candidate == .boolean) return if (candidate.boolean) "true" else "false";
    if (integerKey(candidate)) |number| return number;
    if (expression.floatProtocol(candidate)) |number| {
        if (std.math.isNan(number)) return "NaN";
        if (std.math.isInf(number)) return if (number < 0) "-Infinity" else "Infinity";
        return @import("expression_number.zig").floatText(allocator, number);
    }
    return error.JinjaTypeError;
}

fn integerKey(candidate: Value) ?[]const u8 {
    if (expression.integerProtocol(candidate)) |number| return number;
    return switch (candidate) {
        .integer => |number| number,
        .boolean => |boolean| if (boolean) "1" else "0",
        else => null,
    };
}

/// sort_keys orders the original Python keys before converting them to JSON
/// names. Mixed incomparable types raise rather than sorting their spelling.
pub fn jsonOrder(allocator: std.mem.Allocator, left: Value, right: Value) !std.math.Order {
    if (left == .string and right == .string) return std.mem.order(u8, left.string, right.string);
    if (left == .none and right == .none) return .eq;
    const lhs_integer = integerKey(left);
    const rhs_integer = integerKey(right);
    const lhs_float = expression.floatProtocol(left);
    const rhs_float = expression.floatProtocol(right);
    const numbers = @import("expression_number.zig");
    if (lhs_integer) |a| {
        if (rhs_integer) |b| return numbers.order(a, b);
        if (rhs_float) |b| return if (std.math.isNan(b)) .eq else try numbers.orderFloat(allocator, a, b);
    }
    if (lhs_float) |a| {
        if (rhs_integer) |b| return if (std.math.isNan(a)) .eq else (try numbers.orderFloat(allocator, b, a)).invert();
        if (rhs_float) |b| return if (std.math.isNan(a) or std.math.isNan(b)) .eq else std.math.order(a, b);
    }
    return error.JinjaTypeError;
}

pub fn sortJsonKeys(allocator: std.mem.Allocator, entries: []Entry) !void {
    for (entries) |item| _ = try jsonKey(allocator, key(item));
    var failure: ?anyerror = null;
    const Context = struct {
        allocator: std.mem.Allocator,
        failure: *?anyerror,
        fn less(context: @This(), left: Entry, right: Entry) bool {
            const order = jsonOrder(context.allocator, key(left), key(right)) catch |err| {
                context.failure.* = err;
                return false;
            };
            return order == .lt;
        }
    };
    std.sort.block(Entry, entries, Context{ .allocator = allocator, .failure = &failure }, Context.less);
    if (failure) |err| return err;
}

test "dictionary numeric and tuple keys preserve Python equality" {
    const boolean = try create(.{ .boolean = true }, .none);
    try std.testing.expect(matches(boolean, .{ .integer = "1" }));
    try std.testing.expect(matches(boolean, .{ .number = 1.0 }));
    try std.testing.expect(matches(boolean, .{ .complex = .{ .real = 1, .imaginary = 0 } }));
    try std.testing.expect(!matches(boolean, .{ .string = "1" }));
    try std.testing.expect(keyEqual(
        .{ .tuple = &.{ .{ .boolean = false }, .{ .string = "a" } } },
        .{ .tuple = &.{ .{ .integer = "0" }, .{ .string = "a" } } },
    ));
    try std.testing.expect(!keyEqual(.{ .integer = "9007199254740993" }, .{ .number = 9007199254740992.0 }));
}

test "builtin temporal method keys compare intrinsic function and receiver" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const methods = @import("datetime_bound_method.zig");
    const dates = @import("timestamp_context.zig");
    const module = @import("modules_datetime.zig");
    const date_class = (try module.resolve(a, "modules.datetime.date")).?;
    const raw_class_method = date_class.attribute("fromordinal");
    const first = try methods.attribute(a, date_class, "fromordinal", raw_class_method);
    const repeated = try methods.attribute(a, date_class, "fromordinal", raw_class_method);
    const keyed = try create(first, .{ .string = "first" });
    try std.testing.expect(matches(keyed, repeated));
    try std.testing.expect(matches(keyed, first));
    const other_class = (try module.resolve(a, "modules.datetime.datetime")).?;
    const other = try methods.attribute(a, other_class, "fromordinal", other_class.attribute("fromordinal"));
    try std.testing.expect(!matches(keyed, other));
    const value = try dates.fromYaml(a, "2024-01-01");
    const same_value = try dates.fromYaml(a, "2024-01-01");
    const instance = try methods.attribute(a, value, "isoformat", value.attribute("isoformat"));
    const repeat_instance = try methods.attribute(a, value, "isoformat", value.attribute("isoformat"));
    const different_instance = try methods.attribute(a, same_value, "isoformat", same_value.attribute("isoformat"));
    const instance_key = try create(instance, .none);
    try std.testing.expect(matches(instance_key, repeat_instance));
    try std.testing.expect(!matches(instance_key, different_instance));
    try std.testing.expectError(error.JinjaTypeError, jsonKey(a, first));
    try std.testing.expectError(error.JinjaTypeError, hashable(.{ .object = &.{.{ .key = "__dxt_native_bound_method", .value = .{ .string = "__dxt_native_bound_method" } }} }));
}

test "dictionary keys reject mutable containers, including nested tuples" {
    try std.testing.expectError(error.JinjaTypeError, hashable(.{ .list = &.{} }));
    try std.testing.expectError(error.JinjaTypeError, hashable(.{ .object = &.{} }));
    try std.testing.expectError(error.JinjaTypeError, hashable(.{ .tuple = &.{.{ .list = &.{} }} }));
    try hashable(.{ .tuple = &.{ .none, .{ .integer = "7" }, .{ .tuple = &.{} } } });
}

test "opaque tuple keys share immutable tuple equality and recursive hashability" {
    const items = [_]Value{ .{ .integer = "2026" }, .{ .boolean = true } };
    const tuple: Value = .{ .object = &.{
        .{ .key = "__dxt_native_tuple", .value = .{ .callable = "__dxt_native_tuple" } },
        .{ .key = "__dxt_iterable", .value = .{ .list = &items } },
    } };
    try hashable(tuple);
    const plain: Value = .{ .tuple = &.{ .{ .integer = "2026" }, .{ .integer = "1" } } };
    try std.testing.expect(keyEqual(tuple, plain));
    try std.testing.expect(keyEqual(plain, tuple));
    try std.testing.expect(!keyEqual(tuple, .{ .list = &items }));
    const item = try create(tuple, .{ .string = "calendar" });
    try std.testing.expect(matches(item, plain));
    const mutable: Value = .{ .object = &.{
        .{ .key = "__dxt_native_tuple", .value = .{ .callable = "__dxt_native_tuple" } },
        .{ .key = "__dxt_iterable", .value = .{ .list = &.{.{ .list = &.{} }} } },
    } };
    try std.testing.expectError(error.JinjaTypeError, hashable(.{ .tuple = &.{mutable} }));
    const forged: Value = .{ .object = &.{
        .{ .key = "__dxt_native_tuple", .value = .{ .string = "__dxt_native_tuple" } },
        .{ .key = "__dxt_iterable", .value = .{ .list = &items } },
    } };
    try std.testing.expectError(error.JinjaTypeError, hashable(forged));
    try std.testing.expect(!keyEqual(forged, tuple));
}

test "abstract temporal keys defer the same offset error through nested tuples" {
    const temporal: Value = .{ .object = &.{
        .{ .key = "__dxt_temporal_offset_error", .value = .{ .callable = "__dxt_temporal_offset_error" } },
    } };
    try std.testing.expectError(error.AbstractTimeZoneMethod, hashable(temporal));
    try std.testing.expectError(error.AbstractTimeZoneMethod, hashable(.{ .tuple = &.{temporal} }));
}

test "immutable timezone and class keys retain identities across copies" {
    const zone: Value = .{ .object = &.{.{ .key = "__dxt_timezone_identity", .value = .{ .string = "UTC" } }} };
    const copy: Value = .{ .object = &.{.{ .key = "__dxt_timezone_identity", .value = .{ .string = "UTC" } }} };
    const other: Value = .{ .object = &.{.{ .key = "__dxt_timezone_identity", .value = .{ .string = "Europe/London" } }} };
    const class: Value = .{ .object = &.{.{ .key = "__dxt_class_identity", .value = .{ .string = "UTC" } }} };
    try hashable(zone);
    try hashable(class);
    const item = try create(zone, .{ .string = "stored" });
    try std.testing.expect(matches(item, copy));
    try std.testing.expect(!matches(item, other));
    try std.testing.expect(!matches(item, class));
    try std.testing.expect(!matches(item, .{ .string = "UTC" }));
    try std.testing.expectError(error.JinjaTypeError, jsonKey(std.testing.allocator, zone));
    try std.testing.expectError(error.JinjaTypeError, jsonKey(std.testing.allocator, class));
}

test "builtin timezone keys compare offsets independently of names and instance identities" {
    const first: Value = .{ .object = &.{
        .{ .key = "__dxt_timezone_builtin", .value = .{ .boolean = true } },
        .{ .key = "__dxt_timezone_identity", .value = .{ .string = "first" } },
        .{ .key = "__dxt_timezone_offset_us", .value = .{ .integer = "3600000000" } },
    } };
    const alias: Value = .{ .object = &.{
        .{ .key = "__dxt_timezone_builtin", .value = .{ .boolean = true } },
        .{ .key = "__dxt_timezone_identity", .value = .{ .string = "alias" } },
        .{ .key = "__dxt_timezone_offset_us", .value = .{ .integer = "3600000000" } },
    } };
    const different_offset: Value = .{ .object = &.{
        .{ .key = "__dxt_timezone_builtin", .value = .{ .boolean = true } },
        .{ .key = "__dxt_timezone_identity", .value = .{ .string = "first" } },
        .{ .key = "__dxt_timezone_offset_us", .value = .{ .integer = "7200000000" } },
    } };
    const pytz_zone: Value = .{ .object = &.{
        .{ .key = "__dxt_timezone_identity", .value = .{ .string = "first" } },
        .{ .key = "__dxt_timezone_offset_us", .value = .{ .integer = "3600000000" } },
    } };
    const item = try create(first, .{ .string = "stored" });
    try std.testing.expect(matches(item, alias));
    try std.testing.expect(!matches(item, different_offset));
    try std.testing.expect(!matches(item, pytz_zone));
    try std.testing.expect(!matches(item, .{ .integer = "3600000000" }));
}

test "relation keys compare complete identity and do not collapse to rendered SQL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const context = @import("dbt_context.zig");
    const table = try context.relationValue(allocator, .{ .schema = "main", .identifier = "a", .relation_type = "table" });
    const copy = try context.cloneValue(allocator, table);
    const view = try context.relationValue(allocator, .{ .schema = "main", .identifier = "a", .relation_type = "view" });
    try hashable(table);
    try std.testing.expect(keyEqual(table, copy));
    try std.testing.expect(!keyEqual(table, view));
    try std.testing.expect(!keyEqual(table, .{ .string = try table.text(allocator) }));
}

test "NaN mapping keys preserve object identity independently of numeric equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const first = try expression.floatValue(allocator, std.math.nan(f64));
    const second = try expression.floatValue(allocator, std.math.nan(f64));
    const copy = try @import("dbt_context.zig").cloneValue(allocator, first);
    try hashable(first);
    try std.testing.expect(keyEqual(first, copy));
    try std.testing.expect(!keyEqual(first, second));
    try std.testing.expect(!expression.equalValues(first, first));
}

test "complex NaN keys preserve identity and remain invalid JSON keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const first = try expression.complexValue(allocator, .{ .real = std.math.nan(f64), .imaginary = 0 });
    const second = try expression.complexValue(allocator, .{ .real = std.math.nan(f64), .imaginary = 0 });
    const copy = try @import("dbt_context.zig").cloneValue(allocator, first);
    try hashable(first);
    try std.testing.expect(keyEqual(first, copy));
    try std.testing.expect(!keyEqual(first, second));
    try std.testing.expect(!expression.equalValues(first, first));
    try std.testing.expectError(error.JinjaTypeError, jsonKey(allocator, first));
}

test "capture Undefined dictionary keys retain Python class equality" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const first = try expression.captureUndefined(allocator, "first");
    const second = try expression.captureUndefined(allocator, "second");
    try hashable(first);
    try std.testing.expect(keyEqual(first, second));
    try std.testing.expect(!keyEqual(first, .undefined));
    const ordinary_first = try expression.undefinedValue(allocator, "first");
    const ordinary_second = try expression.undefinedValue(allocator, "second");
    try hashable(ordinary_first);
    try std.testing.expect(keyEqual(ordinary_first, ordinary_second));
    try std.testing.expect(!keyEqual(first, ordinary_first));
    try std.testing.expectError(error.JinjaTypeError, jsonKey(allocator, ordinary_first));
}

test "YAML bytes and timestamps retain Python dictionary key identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const scalars = @import("yaml_values.zig");
    const dates = @import("timestamp_context.zig");
    const bytes = try scalars.binary(a, "SGVsbG8=");
    try hashable(bytes);
    try std.testing.expect(matches(try create(bytes, .none), try scalars.binary(a, "SGVsbG8=")));
    try std.testing.expect(!keyEqual(bytes, .{ .string = "Hello" }));
    const utc = try dates.fromYaml(a, "2020-01-02T03:04:05+00:00");
    try hashable(utc);
    try std.testing.expect(keyEqual(utc, try dates.fromYaml(a, "2020-01-02T04:04:05+01:00")));
    try std.testing.expect(!keyEqual(utc, try dates.fromYaml(a, "2020-01-02T03:04:05")));
    const date = try dates.fromYaml(a, "2020-01-02");
    try hashable(date);
    try std.testing.expect(!keyEqual(date, utc));
    try std.testing.expectError(error.JinjaTypeError, jsonKey(a, date));
    try std.testing.expectError(error.JinjaTypeError, jsonKey(a, bytes));
}

test "JSON keys stringify primitives and sort original numeric types exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("true", try jsonKey(allocator, .{ .boolean = true }));
    try std.testing.expectEqualStrings("null", try jsonKey(allocator, .none));
    try std.testing.expectEqualStrings("1.0", try jsonKey(allocator, .{ .number = 1 }));
    try std.testing.expectEqual(std.math.Order.gt, try jsonOrder(allocator, .{ .integer = "9007199254740993" }, .{ .number = 9007199254740992.0 }));
    try std.testing.expectError(error.JinjaTypeError, jsonOrder(allocator, .{ .integer = "1" }, .{ .string = "2" }));
    try std.testing.expectError(error.JinjaTypeError, jsonKey(allocator, .{ .tuple = &.{} }));
}
