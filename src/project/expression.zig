const std = @import("std");
const numbers = @import("expression_number.zig");
const sequences = @import("expression_sequence.zig");
const unicode = @import("expression_unicode.zig");
const complex_numbers = @import("expression_complex.zig");
const mapping_keys = @import("mapping_keys.zig");
const sets = @import("set_context.zig");
const yaml_values = @import("yaml_values.zig");
const temporal = @import("datetime_operations.zig");

pub fn lengthWithHost(a: std.mem.Allocator, value: Value, host: ?Host) anyerror!Value {
    return @import("expression_dynamic.zig").length(a, value, host);
}
pub fn truthyWithHost(a: std.mem.Allocator, value: Value, host: ?Host) anyerror!bool {
    return @import("expression_dynamic.zig").truthy(a, value, host);
}

/// Native Jinja expression values. Allocations belong to the caller's render
/// arena; values can cross macro returns without borrowing a temporary frame.
pub const Value = union(enum) {
    undefined,
    conditional_undefined,
    ordinary_undefined: *CaptureUndefined,
    capture_undefined: *CaptureUndefined,
    none,
    boolean: bool,
    integer: []const u8,
    number: f64,
    complex: complex_numbers.Complex,
    string: []const u8,
    list: []const Value,
    tuple: []const Value,
    object: []const Entry,
    callable: []const u8,

    pub fn truthy(self: Value) bool {
        if (temporal.duration(self)) |micros| return micros != 0;
        if (floatProtocol(self)) |number| return number != 0;
        if (complexProtocol(self)) |number| return number.real != 0 or number.imaginary != 0;
        if (integerProtocol(self)) |number| return !std.mem.eql(u8, number, "0");
        if (sequences.truthy(self)) |result| return result;
        if (self == .object) if (sequence(self)) |items| return items.len != 0;
        if (mappingSource(self)) |source| return source.object.len != 0;
        return switch (self) {
            .undefined, .conditional_undefined, .ordinary_undefined, .capture_undefined, .none => false,
            .boolean => |v| v,
            .number => |v| v != 0,
            .complex => |v| v.real != 0 or v.imaginary != 0,
            .integer => |v| !std.mem.eql(u8, v, "0"),
            .string => |v| v.len != 0,
            .list, .tuple => |v| v.len != 0,
            .object => |v| v.len != 0,
            .callable => true,
        };
    }

    pub fn text(self: Value, allocator: std.mem.Allocator) anyerror![]const u8 {
        return switch (self) {
            .undefined, .conditional_undefined, .ordinary_undefined, .capture_undefined => "",
            .callable => error.JinjaTypeError,
            .none => "None",
            .boolean => |v| if (v) "True" else "False",
            .integer => |v| v,
            .number => |v| try numbers.floatText(allocator, v),
            .complex => |v| try complex_numbers.text(allocator, v),
            .string => |v| v,
            .list, .tuple => |values| blk: {
                var out: std.ArrayList(u8) = .empty;
                try out.append(allocator, if (self == .tuple) '(' else '[');
                for (values, 0..) |v, i| {
                    if (i != 0) try out.appendSlice(allocator, ", ");
                    try out.appendSlice(allocator, try repr(v, allocator));
                }
                if (self == .tuple and values.len == 1) try out.append(allocator, ',');
                try out.append(allocator, if (self == .tuple) ')' else ']');
                break :blk try out.toOwnedSlice(allocator);
            },
            .object => |entries| blk: {
                if (self.attribute("__dxt_string_error").truthy()) return error.JinjaTypeError;
                if (sets.isSet(self)) break :blk try sets.text(allocator, self);
                if (try sequences.text(allocator, self)) |rendered| break :blk rendered;
                // Adapter relation objects retain typed attributes for package
                // macros while their string conversion is the SQL identity.
                for (entries) |entry| if (std.mem.eql(u8, entry.key, "__dxt_rendered") and entry.value == .string) break :blk entry.value.string;
                var out: std.ArrayList(u8) = .empty;
                try out.append(allocator, '{');
                for (entries, 0..) |entry, i| {
                    if (i != 0) try out.appendSlice(allocator, ", ");
                    try out.appendSlice(allocator, try repr(entry.typed_key orelse .{ .string = entry.key }, allocator));
                    try out.appendSlice(allocator, ": ");
                    try out.appendSlice(allocator, try repr(entry.value, allocator));
                }
                try out.append(allocator, '}');
                break :blk try out.toOwnedSlice(allocator);
            },
        };
    }

    pub fn attribute(self: Value, name: []const u8) Value {
        if (floatProtocol(self) != null) {
            if (std.mem.eql(u8, name, "real")) return self;
            if (std.mem.eql(u8, name, "imag")) return .{ .number = 0 };
        }
        if (complexProtocol(self)) |number| {
            if (std.mem.eql(u8, name, "real")) return .{ .number = number.real };
            if (std.mem.eql(u8, name, "imag")) return .{ .number = number.imaginary };
        }
        return switch (self) {
            .capture_undefined => |captured| if (std.mem.eql(u8, name, "name"))
                (if (captured.name) |value| .{ .string = value } else .none)
            else if (std.mem.eql(u8, name, "hint"))
                (if (captured.hint) |value| .{ .string = value } else .none)
            else if (std.mem.eql(u8, name, "unsafe_callable") or std.mem.eql(u8, name, "alters_data"))
                .{ .boolean = false }
            else
                .undefined,
            .complex => |v| if (std.mem.eql(u8, name, "real")) .{ .number = v.real } else if (std.mem.eql(u8, name, "imag")) .{ .number = v.imaginary } else .undefined,
            .object => |entries| blk: {
                for (entries) |entry| if ((entry.typed_key == null or entry.typed_key.? == .string) and std.mem.eql(u8, name, entry.key)) break :blk entry.value;
                if (mappingSource(self) != null) break :blk mappingGet(self, .{ .string = name }) catch .undefined;
                break :blk .undefined;
            },
            else => .undefined,
        };
    }
};

/// dbt's parse environment propagates unresolved attributes and calls. A
/// mutable cell preserves its observable name and identity across aliases.
pub const CaptureUndefined = struct {
    allocator: std.mem.Allocator,
    name: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    identity: u64,
};
pub fn captureUndefined(allocator: std.mem.Allocator, name: ?[]const u8) !Value {
    const captured = try allocator.create(CaptureUndefined);
    captured.* = .{
        .allocator = allocator,
        .name = if (name) |value| try allocator.dupe(u8, value) else null,
        .identity = next_float_identity.fetchAdd(1, .monotonic),
    };
    return .{ .capture_undefined = captured };
}
pub fn undefinedValue(allocator: std.mem.Allocator, name: ?[]const u8) !Value {
    const captured = try captureUndefined(allocator, name);
    return .{ .ordinary_undefined = captured.capture_undefined };
}
/// Jinja checks the callable's pass-argument attribute before invocation.
/// dbt CaptureUndefined exposes that probe by mutating the called cell name.
pub fn callUndefined(value: Value) !Value {
    if (value == .capture_undefined) {
        const cell = value.capture_undefined;
        cell.name = try cell.allocator.dupe(u8, "jinja_pass_arg");
        return value;
    }
    return if (isUndefined(value)) error.UndefinedJinjaValue else error.JinjaTypeError;
}
pub fn isUndefined(value: Value) bool {
    return value == .undefined or value == .conditional_undefined or value == .ordinary_undefined or value == .capture_undefined;
}

/// Probe the iterable protocol without consuming one-shot iterators.
pub fn isIterable(value: Value) bool {
    const noniterable = value.attribute("__dxt_noniterable");
    if (noniterable == .boolean and noniterable.boolean) return false;
    return isUndefined(value) or value == .list or value == .tuple or value == .object or value == .string;
}

pub const Entry = struct { key: []const u8, value: Value, typed_key: ?Value = null };
pub fn entryKey(entry: Entry) Value {
    return mapping_keys.key(entry);
}
pub fn hashableKey(key: Value) !void {
    try mapping_keys.hashable(key);
}
/// Mapping proxies keep metadata out of public keys and preserve their lookup policy.
pub fn mappingSource(container: Value) ?Value {
    if (container != .object) return null;
    for (container.object) |entry| if (std.mem.eql(u8, entry.key, "__dxt_mapping_source") and entry.value == .object) return entry.value;
    return null;
}
pub fn mappingEntry(container: Value, key: Value) !?Entry {
    if (mappingSource(container)) |source| {
        if (container.attribute("__dxt_mapping_uppercase").truthy()) {
            if (key.attribute("__dxt_binary") == .string) return null;
            if (key != .string) return error.InvalidCountryCode;
            const normalized = try unicode.convert(std.heap.page_allocator, key.string, .upper);
            defer std.heap.page_allocator.free(normalized);
            return mapping_keys.entry(source, .{ .string = normalized });
        }
        return mapping_keys.entry(source, key);
    }
    return try mapping_keys.entry(container, key);
}
pub fn mappingGet(container: Value, key: Value) !Value {
    return if (try mappingEntry(container, key)) |entry| entry.value else .undefined;
}
pub fn mappingPut(allocator: std.mem.Allocator, entries: *std.ArrayList(Entry), key: Value, value: Value) !void {
    try hashableKey(key);
    for (entries.items) |*entry| if (mapping_keys.matches(entry.*, key)) {
        entry.value = value;
        return;
    };
    try entries.append(allocator, try mapping_keys.create(key, value));
}
pub const Argument = struct { name: ?[]const u8 = null, value: Value };
pub const Host = struct {
    context: *anyopaque,
    resolve: *const fn (*anyopaque, []const u8, std.mem.Allocator) anyerror!Value,
    call: *const fn (*anyopaque, []const u8, []const Argument, std.mem.Allocator) anyerror!Value,
    // Compiler hosts can preserve the current resource across nested renders
    // without coupling this generic expression module to project Node types.
    set_node: ?*const fn (*anyopaque, ?*const anyopaque) ?*const anyopaque = null,
    capture_undefined: bool = false,
};

/// Named tuples use an internal callable marker, never authored string metadata.
pub fn tupleProtocol(value: Value) ?[]const Value {
    return @import("native_tuple.zig").items(value);
}
pub fn sequence(value: Value) ?[]const Value {
    if (value == .list) return value.list;
    if (value == .tuple) return value.tuple;
    if (value == .object) {
        const items = value.attribute("__dxt_iterable");
        if (items == .list) return items.list;
    }
    return null;
}

pub fn integerValue(allocator: std.mem.Allocator, number: anytype) !Value {
    return .{ .integer = try std.fmt.allocPrint(allocator, "{d}", .{number}) };
}

// Python dictionary lookup preserves a NaN object's identity even though NaN
// compares unequal to itself. Retain that identity across arena-owned clones.
var next_float_identity: std.atomic.Value(u64) = .init(0);
pub fn floatValue(allocator: std.mem.Allocator, number: f64) !Value {
    if (!std.math.isNan(number)) return .{ .number = number };
    const entries = try allocateEntries(allocator, 4);
    entries[0] = .{ .key = "__dxt_float", .value = .{ .number = number } };
    entries[1] = .{ .key = "__dxt_float_identity", .value = .{ .string = try std.fmt.allocPrint(allocator, "{d}", .{next_float_identity.fetchAdd(1, .monotonic)}) } };
    entries[2] = .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } };
    entries[3] = .{ .key = "__dxt_rendered", .value = .{ .string = "nan" } };
    return .{ .object = entries };
}

pub fn floatProtocol(value: Value) ?f64 {
    if (value == .number) return value.number;
    if (value == .object) for (value.object) |entry| {
        if (entry.typed_key == null and std.mem.eql(u8, entry.key, "__dxt_float") and entry.value == .number) return entry.value.number;
    };
    return null;
}

pub fn complexValue(allocator: std.mem.Allocator, number: complex_numbers.Complex) !Value {
    if (!std.math.isNan(number.real) and !std.math.isNan(number.imaginary)) return .{ .complex = number };
    const entries = try allocateEntries(allocator, 4);
    entries[0] = .{ .key = "__dxt_complex", .value = .{ .complex = number } };
    entries[1] = .{ .key = "__dxt_complex_identity", .value = .{ .string = try std.fmt.allocPrint(allocator, "{d}", .{next_float_identity.fetchAdd(1, .monotonic)}) } };
    entries[2] = .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } };
    entries[3] = .{ .key = "__dxt_rendered", .value = .{ .string = try complex_numbers.text(allocator, number) } };
    return .{ .object = entries };
}

pub fn complexProtocol(value: Value) ?complex_numbers.Complex {
    if (value == .complex) return value.complex;
    if (value == .object) for (value.object) |entry| {
        if (entry.typed_key == null and std.mem.eql(u8, entry.key, "__dxt_complex") and entry.value == .complex) return entry.value.complex;
    };
    return null;
}

test "dictionary literals preserve first equal key and tuple lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dictionary = try evaluate(a, "{true:'first',1:'second',1.0:'third',(2,3):'pair'}", null);
    try std.testing.expectEqual(@as(usize, 2), dictionary.object.len);
    try std.testing.expect(entryKey(dictionary.object[0]) == .boolean);
    try std.testing.expectEqualStrings("third", (try mappingGet(dictionary, .{ .integer = "1" })).string);
    try std.testing.expectEqualStrings("pair", (try evaluate(a, "{(2,3):'pair'}[(2.0,3)]", null)).string);
    try std.testing.expectError(error.JinjaTypeError, evaluate(a, "{[]:1}", null));
}

test "NaN scalar equality and container identity follow separate Python rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const nan = try floatValue(a, std.math.nan(f64));
    const other = try floatValue(a, std.math.nan(f64));
    try std.testing.expect(!equalValues(nan, nan));
    try std.testing.expect(equalValues(.{ .tuple = &.{nan} }, .{ .tuple = &.{nan} }));
    try std.testing.expect(!equalValues(.{ .list = &.{nan} }, .{ .list = &.{other} }));
    try std.testing.expectEqualStrings("nan", try nan.text(a));
}

pub fn checkedAttribute(value: Value, name: []const u8) !Value {
    if (sequences.kind(value) != null) return .undefined;
    if (tupleProtocol(value) != null and std.mem.startsWith(u8, name, "__dxt_")) return .undefined;
    if (value == .capture_undefined) {
        if (std.mem.eql(u8, name, "name") or std.mem.eql(u8, name, "hint") or std.mem.eql(u8, name, "unsafe_callable") or std.mem.eql(u8, name, "alters_data")) return value.attribute(name);
        const captured = value.capture_undefined;
        if (undefinedUnsafeAttribute(name, true)) {
            const result = try captureUndefined(captured.allocator, name);
            result.capture_undefined.hint = try std.fmt.allocPrint(captured.allocator, "access to attribute '{s}' of 'Undefined' object is unsafe.", .{name});
            return result;
        }
        // Jinja falls back to subscription after __getattr__ rejects an
        // unknown dunder. CaptureUndefined subscription preserves the cell.
        if (std.mem.startsWith(u8, name, "__") and std.mem.endsWith(u8, name, "__")) return value;
        captured.name = try captured.allocator.dupe(u8, name);
        const result = try captureUndefined(captured.allocator, name);
        result.capture_undefined.hint = captured.hint;
        return result;
    }
    if (isUndefined(value)) {
        if (undefinedUnsafeAttribute(name, false)) return if (value == .ordinary_undefined) try undefinedValue(value.ordinary_undefined.allocator, name) else .undefined;
        return error.UndefinedJinjaValue;
    }
    return value.attribute(name);
}

/// Typed providers may defer a public attribute until it is actually used.
pub fn attributeWithHost(a: std.mem.Allocator, value: Value, name: []const u8, host: ?Host) !Value {
    const getter = value.attribute("__dxt_getattr");
    if (getter == .callable) {
        const current = host orelse return error.UnsupportedJinjaCall;
        return current.call(current.context, getter.callable, &.{.{ .value = .{ .string = name } }}, a);
    }
    return checkedAttribute(value, name);
}

fn undefinedUnsafeAttribute(name: []const u8, capture: bool) bool {
    if (std.mem.eql(u8, name, "__dict__")) return capture;
    inline for (.{ "__class__", "__dict__", "__slots__", "__repr__", "__str__", "__bool__", "__len__", "__iter__", "__aiter__", "__call__", "__getitem__", "__getattr__", "__getattribute__", "__setattr__", "__delattr__", "__dir__", "__eq__", "__ne__", "__hash__", "__reduce__", "__reduce_ex__", "__init__", "__init_subclass__", "__new__", "__subclasshook__", "__doc__", "__module__", "__add__", "__radd__", "__sub__", "__rsub__", "__mul__", "__rmul__", "__div__", "__rdiv__", "__truediv__", "__rtruediv__", "__floordiv__", "__rfloordiv__", "__mod__", "__rmod__", "__pos__", "__neg__", "__lt__", "__le__", "__gt__", "__ge__", "__int__", "__float__", "__complex__", "__pow__", "__rpow__" }) |attribute| if (std.mem.eql(u8, name, attribute)) return true;
    return false;
}

pub fn integerIndex(value: Value) !i64 {
    if (isUndefined(value)) return error.UndefinedJinjaValue;
    if (integerProtocol(value)) |number| return std.fmt.parseInt(i64, number, 10) catch return error.JinjaIndexError;
    return switch (value) {
        .integer => |number| std.fmt.parseInt(i64, number, 10) catch return error.JinjaIndexError,
        .boolean => |number| @intFromBool(number),
        else => error.JinjaTypeError,
    };
}

pub fn numericFloat(value: Value) !f64 {
    if (isUndefined(value)) return error.UndefinedJinjaValue;
    if (floatProtocol(value)) |number| return number;
    if (integerProtocol(value)) |number| return numericFloat(.{ .integer = number });
    return switch (value) {
        .integer => |number| blk: {
            const converted = std.fmt.parseFloat(f64, number) catch return error.JinjaNumericOverflow;
            if (!std.math.isFinite(converted)) return error.JinjaNumericOverflow;
            break :blk converted;
        },
        .number => |number| number,
        .boolean => |number| if (number) 1 else 0,
        else => error.JinjaTypeError,
    };
}

pub fn repr(value: Value, allocator: std.mem.Allocator) ![]const u8 {
    if (isUndefined(value)) return "Undefined";
    const rendered = value.attribute("__dxt_repr");
    if (rendered == .string) return rendered.string;
    if (value == .string) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try @import("native_repr.zig").string(&out.writer, value.string);
        return out.toOwnedSlice();
    }
    return value.text(allocator);
}
pub fn callableName(value: Value) ?[]const u8 {
    if (value == .callable) return value.callable;
    const marker = value.attribute("__dxt_callable");
    return if (marker == .callable) marker.callable else null;
}

pub fn evaluate(allocator: std.mem.Allocator, input: []const u8, host: ?Host) !Value {
    if (topLevelKeyword(input, "if")) |condition_at| {
        const remainder = input[condition_at + 2 ..];
        const else_at = topLevelKeyword(remainder, "else");
        const condition = try evaluate(allocator, remainder[0 .. else_at orelse remainder.len], host);
        if (try truthyWithHost(allocator, condition, host)) return try evaluate(allocator, input[0..condition_at], host);
        return if (else_at) |position| try evaluate(allocator, remainder[position + 4 ..], host) else try undefinedValue(allocator, null);
    }
    var parser = Parser{ .allocator = allocator, .input = input, .host = host };
    const value = try parser.binary(0);
    parser.space();
    if (parser.index != input.len) return error.InvalidJinjaExpression;
    return value;
}

fn topLevelKeyword(input: []const u8, keyword: []const u8) ?usize {
    var depth: usize = 0;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (quote != 0) {
            if (c == '\\') i += 1 else if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        if (c == '(' or c == '[' or c == '{') depth += 1 else if (c == ')' or c == ']' or c == '}') {
            if (depth != 0) depth -= 1;
        }
        if (depth == 0 and std.mem.startsWith(u8, input[i..], keyword) and (i == 0 or std.ascii.isWhitespace(input[i - 1])) and (i + keyword.len == input.len or std.ascii.isWhitespace(input[i + keyword.len]))) return i;
    }
    return null;
}

pub fn evaluateArguments(allocator: std.mem.Allocator, input: []const u8, host: ?Host) ![]const Argument {
    const wrapped = try std.fmt.allocPrint(allocator, "{s})", .{input});
    var parser = Parser{ .allocator = allocator, .input = wrapped, .host = host };
    const args = try parser.arguments();
    parser.space();
    if (parser.index != wrapped.len) return error.InvalidJinjaArguments;
    return args;
}

const Parser = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    index: usize = 0,
    depth: usize = 0,
    active: bool = true,
    host: ?Host,

    fn space(self: *Parser) void {
        while (self.index < self.input.len and std.ascii.isWhitespace(self.input[self.index])) self.index += 1;
    }

    fn take(self: *Parser, token: []const u8) bool {
        self.space();
        if (!std.mem.startsWith(u8, self.input[self.index..], token)) return false;
        const end = self.index + token.len;
        if (token.len != 0 and ident(token[token.len - 1]) and end < self.input.len and ident(self.input[end])) return false;
        self.index = end;
        return true;
    }

    fn expect(self: *Parser, token: []const u8) !void {
        if (!self.take(token)) return error.InvalidJinjaExpression;
    }

    fn name(self: *Parser) ![]const u8 {
        self.space();
        const start = self.index;
        if (start >= self.input.len or !(std.ascii.isAlphabetic(self.input[start]) or self.input[start] == '_')) return error.InvalidJinjaExpression;
        self.index += 1;
        while (self.index < self.input.len and ident(self.input[self.index])) self.index += 1;
        return self.input[start..self.index];
    }

    fn binary(self: *Parser, minimum: u8) anyerror!Value {
        // A conditional has lower precedence than every binary operator. Locate
        // its complete argument/list/group expression before evaluating either
        // branch, so inactive branches never call the database or a macro.
        if (minimum == 0) {
            const finish = expressionFinish(self.input, self.index);
            const input = self.input[self.index..finish];
            if (topLevelKeyword(input, "if") != null) {
                const value = if (self.active) try evaluate(self.allocator, input, self.host) else Value.none;
                self.index = finish;
                return value;
            }
        }
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > 64) return error.JinjaExpressionDepthExceeded;
        var lhs = try self.unary();
        while (true) {
            const saved = self.index;
            const operator = self.readOperator() orelse break;
            const precedence = rank(operator);
            if (precedence < minimum) {
                self.index = saved;
                break;
            }
            if (std.mem.eql(u8, operator, "is")) {
                const negate = self.take("not");
                const test_name = try self.name();
                const args = if (self.take("(")) try self.arguments() else &.{};
                const result = if (self.active) try testValueWithHost(self.allocator, test_name, lhs, args, self.host) else false;
                lhs = .{ .boolean = if (negate) !result else result };
                continue;
            }
            if (comparisonOperator(operator)) {
                var previous = lhs;
                var comparison = operator;
                var matched = true;
                while (true) {
                    const previous_active = self.active;
                    if (!matched) self.active = false;
                    const right = self.binary(4) catch |err| {
                        self.active = previous_active;
                        return err;
                    };
                    self.active = previous_active;
                    if (self.active and matched) matched = (try applyWithHost(self.allocator, comparison, previous, right, self.host)).truthy();
                    previous = right;
                    const next_at = self.index;
                    const next = self.readOperator() orelse break;
                    if (!comparisonOperator(next)) {
                        self.index = next_at;
                        break;
                    }
                    comparison = next;
                }
                lhs = if (self.active) .{ .boolean = matched } else .none;
                continue;
            }
            const previous_active = self.active;
            const logical = std.mem.eql(u8, operator, "and") or std.mem.eql(u8, operator, "or");
            const truth = if (self.active and logical) try truthyWithHost(self.allocator, lhs, self.host) else false;
            const short = (std.mem.eql(u8, operator, "and") and !truth) or (std.mem.eql(u8, operator, "or") and truth);
            if (short) self.active = false;
            const rhs = self.binary(precedence + 1) catch |err| {
                self.active = previous_active;
                return err;
            };
            self.active = previous_active;
            if (!self.active) {
                lhs = .none;
            } else if (std.mem.eql(u8, operator, "and") or std.mem.eql(u8, operator, "or")) {
                if (!short) lhs = rhs;
            } else {
                lhs = try applyWithHost(self.allocator, operator, lhs, rhs, self.host);
            }
        }
        return lhs;
    }

    fn readOperator(self: *Parser) ?[]const u8 {
        const saved = self.index;
        if (self.take("not") and self.take("in")) return "not in";
        self.index = saved;
        for ([_][]const u8{ "or", "and", "in", "is", "==", "!=", "<=", ">=", "<", ">", "~", "+", "-", "//", "**", "*", "/", "%" }) |op| {
            if (self.take(op)) return op;
        }
        return null;
    }

    fn unary(self: *Parser) anyerror!Value {
        return self.unaryFiltered(true);
    }

    fn unaryFiltered(self: *Parser, with_filters: bool) anyerror!Value {
        if (self.take("not")) return .{ .boolean = !try truthyWithHost(self.allocator, try self.binary(3), self.host) };
        const value: Value = if (self.take("-")) blk: {
            const operand = try self.unaryFiltered(false);
            if (!self.active) break :blk .none;
            if (try temporal.unary(self.allocator, "-", operand)) |result| break :blk result;
            if (complexProtocol(operand)) |number| break :blk try complexValue(self.allocator, .{ .real = -number.real, .imaginary = -number.imaginary });
            if (integerText(operand)) |number| break :blk .{ .integer = try numbers.negate(self.allocator, number) };
            break :blk try floatValue(self.allocator, -(try numeric(operand)));
        } else if (self.take("+")) blk: {
            const operand = try self.unaryFiltered(false);
            if (!self.active) break :blk .none;
            if (isUndefined(operand)) return error.UndefinedJinjaValue;
            if (try temporal.unary(self.allocator, "+", operand)) |result| break :blk result;
            if (operand == .boolean) break :blk try integerValue(self.allocator, @as(u8, @intFromBool(operand.boolean)));
            if (integerProtocol(operand)) |number| break :blk .{ .integer = number };
            if (operand != .integer and floatProtocol(operand) == null and complexProtocol(operand) == null) return error.JinjaTypeError;
            break :blk operand;
        } else try self.atom();
        return self.postfix(value, with_filters);
    }

    fn postfix(self: *Parser, primary: Value, with_filters: bool) anyerror!Value {
        var value = primary;
        while (true) {
            if (self.take("(")) {
                const args = try self.arguments();
                if (self.active) {
                    if (value == .capture_undefined) {
                        value = try callUndefined(value);
                        continue;
                    }
                    if (isUndefined(value)) return error.UndefinedJinjaValue;
                    const function = callableName(value) orelse return error.JinjaTypeError;
                    const host = self.host orelse return error.UnsupportedJinjaCall;
                    value = try host.call(host.context, function, args, self.allocator);
                }
            } else if (self.take("[")) {
                const start: ?Value = if (self.take(":")) null else try self.binary(0);
                const sliced = start == null or self.take(":");
                if (sliced) {
                    self.space();
                    const end: ?Value = if (std.mem.startsWith(u8, self.input[self.index..], "]") or std.mem.startsWith(u8, self.input[self.index..], ":")) null else try self.binary(0);
                    const step: ?Value = if (self.take(":")) blk: {
                        self.space();
                        break :blk if (std.mem.startsWith(u8, self.input[self.index..], "]")) null else try self.binary(0);
                    } else null;
                    try self.expect("]");
                    if (self.active) value = try sliceValue(self.allocator, value, start, end, step);
                } else {
                    try self.expect("]");
                    if (self.active) {
                        value = try indexValueWithHost(self.allocator, value, start.?, self.host);
                        if (value == .undefined) value = try self.missing(if (start.? == .string) start.?.string else null);
                    }
                }
            } else if (self.take(".")) {
                const attribute = try self.name();
                if (self.take("(")) {
                    const args = try self.arguments();
                    if (self.active) value = try self.method(value, attribute, args);
                } else if (self.active) {
                    value = try attributeWithHost(self.allocator, value, attribute, self.host);
                    if (value == .undefined) value = try self.missing(attribute);
                    if (value == .number and std.math.isNan(value.number)) value = try floatValue(self.allocator, value.number);
                }
            } else if (with_filters and self.take("is")) {
                const negate = self.take("not");
                const test_name = try self.name();
                const args = try self.testArguments();
                if (self.active) {
                    const result = try testValueWithHost(self.allocator, test_name, value, args, self.host);
                    value = .{ .boolean = if (negate) !result else result };
                }
            } else if (with_filters and self.take("|")) {
                const filter_name = try self.name();
                const args = if (self.take("(")) try self.arguments() else &.{};
                if (self.active) {
                    value = try filterValue(self.allocator, filter_name, value, args, self.host);
                    if (value == .undefined) value = try self.missing(null);
                }
            } else break;
        }
        return value;
    }

    fn testArguments(self: *Parser) anyerror![]const Argument {
        if (self.take("(")) return try self.arguments();
        self.space();
        if (self.index == self.input.len) return &.{};
        const next = self.input[self.index];
        if (std.ascii.isAlphabetic(next) or next == '_') {
            const start = self.index;
            const token = try self.name();
            self.index = start;
            if (std.mem.eql(u8, token, "and") or std.mem.eql(u8, token, "or") or std.mem.eql(u8, token, "else")) return &.{};
            if (std.mem.eql(u8, token, "is")) return error.InvalidJinjaExpression;
        } else if (!std.ascii.isDigit(next) and next != '\'' and next != '"' and next != '[' and next != '{') return &.{};
        const arguments_ = try self.allocator.alloc(Argument, 1);
        arguments_[0] = .{ .value = try self.postfix(try self.atom(), false) };
        return arguments_;
    }

    fn atom(self: *Parser) anyerror!Value {
        self.space();
        if (self.index >= self.input.len) return error.InvalidJinjaExpression;
        const c = self.input[self.index];
        if (c == '\'' or c == '"') {
            self.index += 1;
            var out: std.ArrayList(u8) = .empty;
            while (self.index < self.input.len) {
                const ch = self.input[self.index];
                self.index += 1;
                if (ch == c) return .{ .string = try out.toOwnedSlice(self.allocator) };
                if (ch == '\\') {
                    if (self.index >= self.input.len) return error.InvalidJinjaExpression;
                    const escaped = self.input[self.index];
                    self.index += 1;
                    if (escaped == 'x' or escaped == 'u' or escaped == 'U') {
                        const digits: usize = if (escaped == 'x') 2 else if (escaped == 'u') 4 else 8;
                        if (self.index + digits > self.input.len) return error.InvalidJinjaExpression;
                        const code = std.fmt.parseInt(u21, self.input[self.index .. self.index + digits], 16) catch return error.InvalidJinjaExpression;
                        self.index += digits;
                        var buffer: [4]u8 = undefined;
                        const size = std.unicode.utf8Encode(code, &buffer) catch return error.InvalidJinjaExpression;
                        try out.appendSlice(self.allocator, buffer[0..size]);
                        continue;
                    }
                    if (escaped >= '0' and escaped <= '7') {
                        const start = self.index - 1;
                        while (self.index - start < 3 and self.index < self.input.len and self.input[self.index] >= '0' and self.input[self.index] <= '7') self.index += 1;
                        const code = try std.fmt.parseInt(u21, self.input[start..self.index], 8);
                        var buffer: [4]u8 = undefined;
                        const size = try std.unicode.utf8Encode(code, &buffer);
                        try out.appendSlice(self.allocator, buffer[0..size]);
                        continue;
                    }
                    const decoded: ?u8 = switch (escaped) {
                        'a' => 7,
                        'b' => 8,
                        'f' => 12,
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        'v' => 11,
                        '\\', '\'', '"' => escaped,
                        else => null,
                    };
                    if (decoded) |byte| try out.append(self.allocator, byte) else {
                        try out.append(self.allocator, '\\');
                        try out.append(self.allocator, escaped);
                    }
                } else try out.append(self.allocator, ch);
            }
            return error.InvalidJinjaExpression;
        }
        if (std.ascii.isDigit(c)) {
            const start = self.index;
            while (self.index < self.input.len and (std.ascii.isDigit(self.input[self.index]) or self.input[self.index] == '_')) self.index += 1;
            if (self.index < self.input.len and self.input[self.index] == '.' and self.index + 1 < self.input.len and std.ascii.isDigit(self.input[self.index + 1])) {
                self.index += 1;
                while (self.index < self.input.len and (std.ascii.isDigit(self.input[self.index]) or self.input[self.index] == '_')) self.index += 1;
            }
            if (self.index < self.input.len and (self.input[self.index] == 'e' or self.input[self.index] == 'E')) {
                self.index += 1;
                if (self.index < self.input.len and (self.input[self.index] == '+' or self.input[self.index] == '-')) self.index += 1;
                while (self.index < self.input.len and (std.ascii.isDigit(self.input[self.index]) or self.input[self.index] == '_')) self.index += 1;
            }
            const literal = self.input[start..self.index];
            if (std.mem.indexOfAny(u8, literal, ".eE") == null) return .{ .integer = numbers.canonical(self.allocator, literal, 10) catch return error.InvalidJinjaExpression };
            return try floatValue(self.allocator, std.fmt.parseFloat(f64, literal) catch return error.InvalidJinjaExpression);
        }
        if (self.take("(")) {
            if (self.take(")")) return .{ .tuple = &.{} };
            const value = try self.binary(0);
            if (self.take(",")) {
                var values: std.ArrayList(Value) = .empty;
                try values.append(self.allocator, value);
                while (!self.take(")")) {
                    try values.append(self.allocator, try self.binary(0));
                    if (self.take(")")) break;
                    try self.expect(",");
                }
                return .{ .tuple = try ownedValues(self.allocator, &values) };
            }
            try self.expect(")");
            return value;
        }
        if (self.take("[")) {
            var values: std.ArrayList(Value) = .empty;
            if (!self.take("]")) while (true) {
                try values.append(self.allocator, try self.binary(0));
                if (self.take("]")) break;
                try self.expect(",");
                if (self.take("]")) break;
            };
            return .{ .list = try ownedValues(self.allocator, &values) };
        }
        if (self.take("{")) {
            var entries: std.ArrayList(Entry) = .empty;
            if (!self.take("}")) while (true) {
                const key = try self.binary(0);
                try self.expect(":");
                const value = try self.binary(0);
                if (self.active) try mappingPut(self.allocator, &entries, key, value);
                if (self.take("}")) break;
                try self.expect(",");
                if (self.take("}")) break;
            };
            return .{ .object = try ownedEntries(self.allocator, &entries) };
        }
        const start = self.index;
        const first = try self.name();
        if (std.mem.eql(u8, first, "true") or std.mem.eql(u8, first, "True")) return .{ .boolean = true };
        if (std.mem.eql(u8, first, "false") or std.mem.eql(u8, first, "False")) return .{ .boolean = false };
        if (std.mem.eql(u8, first, "none") or std.mem.eql(u8, first, "None")) return .none;
        // Resolve complete namespace paths through the host before applying
        // object attributes, so dbt package macros and target/this coexist.
        var path_end = self.index;
        while (self.take(".")) {
            _ = try self.name();
            path_end = self.index;
        }
        const path = self.input[start..path_end];
        if (self.take("(")) {
            const args = try self.arguments();
            if (!self.active) return .none;
            if (!(self.host != null and std.mem.eql(u8, path, "zip"))) {
                if (try builtin(self.allocator, path, args, self.host)) |value| return value;
            }
            const host = self.host orelse return error.UnsupportedJinjaCall;
            const callee = try host.resolve(host.context, path, self.allocator);
            if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| {
                const receiver = try host.resolve(host.context, path[0..dot], self.allocator);
                if (receiver == .capture_undefined or receiver == .object or receiver == .list or receiver == .tuple or receiver == .string or receiver == .complex) return try self.method(receiver, path[dot + 1 ..], args);
            }
            if (callee == .capture_undefined) return try callUndefined(callee);
            if (callee == .ordinary_undefined) return error.UndefinedJinjaValue;
            return try host.call(host.context, path, args, self.allocator);
        }
        if (!self.active) return .none;
        const resolved = if (self.host) |host| try host.resolve(host.context, path, self.allocator) else .undefined;
        if (resolved == .undefined and std.mem.indexOfScalar(u8, path, '.') != null) {
            var parts = std.mem.splitScalar(u8, path, '.');
            const root_name = parts.next().?;
            var receiver: Value = if (self.host) |host| try host.resolve(host.context, root_name, self.allocator) else .undefined;
            if (receiver == .undefined) receiver = try self.missing(root_name);
            while (parts.next()) |attribute| {
                receiver = try attributeWithHost(self.allocator, receiver, attribute, self.host);
                if (receiver == .undefined) receiver = try self.missing(attribute);
            }
            return receiver;
        }
        if (resolved == .undefined) return try self.missing(path);
        return if (resolved == .number and std.math.isNan(resolved.number)) try floatValue(self.allocator, resolved.number) else resolved;
    }

    fn method(self: *Parser, receiver: Value, method_name: []const u8, args: []const Argument) !Value {
        if (receiver == .capture_undefined) {
            const bound = try checkedAttribute(receiver, method_name);
            if (bound == .capture_undefined) return try callUndefined(bound);
            return error.JinjaTypeError;
        }
        if (isUndefined(receiver)) return error.UndefinedJinjaValue;
        const bound = try attributeWithHost(self.allocator, receiver, method_name, self.host);
        if (callableName(bound)) |function| {
            const host = self.host orelse return error.UnsupportedJinjaCall;
            return try host.call(host.context, function, args, self.allocator);
        }
        if (try pureMethod(self.allocator, receiver, method_name, args, self.host)) |value| return value;
        if (mappingSource(receiver) != null or sequences.kind(receiver) != null) return if (self.capturing()) try callUndefined(try captureUndefined(self.allocator, method_name)) else error.UndefinedJinjaValue;
        const host = self.host orelse return error.UnsupportedJinjaCall;
        const arguments_with_receiver = try self.allocator.alloc(Argument, args.len + 1);
        arguments_with_receiver[0] = .{ .value = receiver };
        @memcpy(arguments_with_receiver[1..], args);
        return try host.call(host.context, try std.fmt.allocPrint(self.allocator, "__dxt_value.{s}", .{method_name}), arguments_with_receiver, self.allocator);
    }

    fn capturing(self: *const Parser) bool {
        return if (self.host) |host| host.capture_undefined else false;
    }

    fn missing(self: *const Parser, name_: ?[]const u8) !Value {
        return if (self.capturing()) try captureUndefined(self.allocator, name_) else try undefinedValue(self.allocator, name_);
    }

    fn arguments(self: *Parser) anyerror![]const Argument {
        var args: std.ArrayList(Argument) = .empty;
        var saw_keyword = false;
        if (!self.take(")")) while (true) {
            if (self.take("**")) {
                const expanded = try self.binary(0);
                if (self.active) {
                    if (expanded != .object) return error.InvalidJinjaArguments;
                    for (expanded.object) |entry| {
                        const key = entryKey(entry);
                        if (key != .string) return error.InvalidJinjaArguments;
                        for (args.items) |arg| if (arg.name) |argument_name| {
                            if (std.mem.eql(u8, argument_name, key.string)) return error.InvalidJinjaArguments;
                        };
                        try args.append(self.allocator, .{ .name = key.string, .value = entry.value });
                    }
                }
                saw_keyword = true;
            } else if (self.take("*")) {
                const expanded = try self.binary(0);
                if (saw_keyword) return error.InvalidJinjaArguments;
                if (self.active) {
                    const items = try iterableValuesWithHost(self.allocator, expanded, self.host);
                    for (items) |value| try args.append(self.allocator, .{ .value = value });
                }
            } else {
                const saved = self.index;
                var keyword: ?[]const u8 = null;
                if (self.name()) |candidate| {
                    if (self.take("=") and !self.take("=")) keyword = candidate else self.index = saved;
                } else |_| self.index = saved;
                if (keyword != null) saw_keyword = true else if (saw_keyword) return error.InvalidJinjaArguments;
                if (keyword) |key| for (args.items) |arg| if (arg.name) |other| {
                    if (std.mem.eql(u8, key, other)) return error.InvalidJinjaArguments;
                };
                try args.append(self.allocator, .{ .name = keyword, .value = try self.binary(0) });
            }
            if (self.take(")")) break;
            try self.expect(",");
            if (self.take(")")) break;
        };
        return try args.toOwnedSlice(self.allocator);
    }
};

/// Mutable empty containers need an identity just like non-empty containers.
/// Their storage belongs to the render arena, including this one-slot backing.
pub fn allocateValues(allocator: std.mem.Allocator, length: usize) ![]Value {
    return (try allocator.alloc(Value, @max(1, length)))[0..length];
}

pub fn allocateEntries(allocator: std.mem.Allocator, length: usize) ![]Entry {
    return (try allocator.alloc(Entry, @max(1, length)))[0..length];
}

fn ownedValues(allocator: std.mem.Allocator, values: *std.ArrayList(Value)) ![]Value {
    if (values.items.len == 0) return try allocateValues(allocator, 0);
    return try values.toOwnedSlice(allocator);
}

fn ownedEntries(allocator: std.mem.Allocator, entries: *std.ArrayList(Entry)) ![]Entry {
    if (entries.items.len == 0) return try allocateEntries(allocator, 0);
    return try entries.toOwnedSlice(allocator);
}

fn pureMethod(allocator: std.mem.Allocator, receiver: Value, name_: []const u8, args: []const Argument, host: ?Host) !?Value {
    if (sequences.kind(receiver) != null) return null;
    if (receiver == .object) if (tupleProtocol(receiver)) |items| return pureMethod(allocator, .{ .tuple = items }, name_, args, host);
    if (sets.isSet(receiver)) return (try sets.call(allocator, receiver, name_, args)) orelse error.UndefinedJinjaValue;
    if (complexProtocol(receiver)) |number| if (std.mem.eql(u8, name_, "conjugate")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        return try complexValue(allocator, .{ .real = number.real, .imaginary = -number.imaginary });
    };
    if (receiver.attribute("__dxt_noniterable").truthy()) return null;
    const positional_only = if (receiver == .object) isMethod(name_, &.{ "get", "keys", "values", "items", "copy" }) else if (receiver == .list or receiver == .tuple) isMethod(name_, &.{ "copy", "count", "index" }) else if (receiver == .string) isMethod(name_, &.{ "lower", "upper", "casefold", "startswith", "endswith", "find", "rfind", "count", "index", "rindex", "strip", "lstrip", "rstrip", "join", "replace" }) else false;
    if (positional_only) for (args) |arg| if (arg.name != null) return error.InvalidJinjaArguments;
    if (receiver == .object) {
        if (std.mem.eql(u8, name_, "get")) {
            if (args.len < 1 or args.len > 2) return error.InvalidJinjaArguments;
            return if (try mappingEntry(receiver, args[0].value)) |entry| entry.value else if (args.len == 2) args[1].value else .none;
        }
        if (std.mem.eql(u8, name_, "keys") or std.mem.eql(u8, name_, "values") or std.mem.eql(u8, name_, "items")) {
            if (args.len != 0) return error.InvalidJinjaArguments;
            return try sequences.view(allocator, mappingSource(receiver) orelse receiver, name_);
        }
        if (std.mem.eql(u8, name_, "copy")) {
            if (mappingSource(receiver) != null) return null;
            if (args.len != 0) return error.InvalidJinjaArguments;
            const entries = try allocateEntries(allocator, receiver.object.len);
            @memcpy(entries, receiver.object);
            return .{ .object = entries };
        }
    }
    if (receiver == .list or receiver == .tuple) {
        const receiver_values = sequence(receiver).?;
        if (std.mem.eql(u8, name_, "copy")) {
            if (receiver == .tuple) return null;
            if (args.len != 0) return error.InvalidJinjaArguments;
            const values = try allocateValues(allocator, receiver.list.len);
            @memcpy(values, receiver.list);
            return .{ .list = values };
        }
        if (std.mem.eql(u8, name_, "count")) {
            if (args.len != 1) return error.InvalidJinjaArguments;
            var count: usize = 0;
            for (receiver_values) |value| if (equalMember(value, args[0].value)) {
                count += 1;
            };
            return try integerValue(allocator, count);
        }
        if (std.mem.eql(u8, name_, "index")) {
            if (args.len < 1 or args.len > 3) return error.InvalidJinjaArguments;
            const length: i64 = @intCast(receiver_values.len);
            var start = if (args.len >= 2) try integer(args[1].value) else 0;
            var stop = if (args.len == 3) try integer(args[2].value) else length;
            if (start < 0) start += length;
            if (stop < 0) stop += length;
            start = std.math.clamp(start, 0, length);
            stop = std.math.clamp(stop, 0, length);
            for (receiver_values[@intCast(start)..@intCast(@max(start, stop))], @as(usize, @intCast(start))..) |value, index| if (equalMember(value, args[0].value)) return try integerValue(allocator, index);
            return error.JinjaValueNotFound;
        }
    }
    if (receiver == .string) {
        const text_ = receiver.string;
        if (std.mem.eql(u8, name_, "format")) return .{ .string = try @import("expression_format.zig").render(allocator, text_, args) };
        if (std.mem.eql(u8, name_, "format_map")) return .{ .string = try @import("expression_format.zig").renderMap(allocator, text_, args) };
        if (std.mem.eql(u8, name_, "casefold")) {
            if (args.len != 0) return error.InvalidJinjaArguments;
            return .{ .string = try unicode.convert(allocator, receiver.string, .casefold) };
        }
        if (std.mem.eql(u8, name_, "lower") or std.mem.eql(u8, name_, "upper")) {
            if (args.len != 0) return error.InvalidJinjaArguments;
            return try filter(allocator, name_, receiver, &.{});
        }
        if (std.mem.eql(u8, name_, "startswith") or std.mem.eql(u8, name_, "endswith") or std.mem.eql(u8, name_, "find") or std.mem.eql(u8, name_, "rfind") or std.mem.eql(u8, name_, "count") or std.mem.eql(u8, name_, "index") or std.mem.eql(u8, name_, "rindex")) {
            if (args.len < 1 or args.len > 3 or args[0].value != .string) return error.InvalidJinjaArguments;
            const characters = try iterableValues(allocator, receiver);
            const length: i64 = @intCast(characters.len);
            var start = if (args.len >= 2) try integer(args[1].value) else 0;
            var stop = if (args.len == 3) try integer(args[2].value) else length;
            const starts_after_end = start > length;
            if (start < 0) start += length;
            if (stop < 0) stop += length;
            start = std.math.clamp(start, 0, length);
            stop = std.math.clamp(stop, 0, length);
            var byte_start: usize = 0;
            var byte_stop: usize = 0;
            for (characters, 0..) |character, index| {
                if (index < @as(usize, @intCast(start))) byte_start += character.string.len;
                if (index < @as(usize, @intCast(@max(start, stop)))) byte_stop += character.string.len;
            }
            const range = text_[byte_start..byte_stop];
            const needle = args[0].value.string;
            if (std.mem.eql(u8, name_, "startswith")) return .{ .boolean = !starts_after_end and stop >= start and std.mem.startsWith(u8, range, needle) };
            if (std.mem.eql(u8, name_, "endswith")) return .{ .boolean = !starts_after_end and stop >= start and std.mem.endsWith(u8, range, needle) };
            if (std.mem.eql(u8, name_, "count")) {
                if (starts_after_end or stop < start) return .{ .integer = "0" };
                if (needle.len == 0) return try integerValue(allocator, stop - start + 1);
                var count: usize = 0;
                var index: usize = 0;
                while (std.mem.indexOfPos(u8, range, index, needle)) |found| {
                    count += 1;
                    index = found + needle.len;
                }
                return try integerValue(allocator, count);
            }
            const found = if (starts_after_end or stop < start) null else if (std.mem.startsWith(u8, name_, "r")) std.mem.lastIndexOf(u8, range, needle) else std.mem.indexOf(u8, range, needle);
            if (found) |byte_position| {
                var position = start;
                var offset: usize = 0;
                while (offset < byte_position) {
                    offset += std.unicode.utf8ByteSequenceLength(range[offset]) catch return error.JinjaTypeError;
                    position += 1;
                }
                return try integerValue(allocator, position);
            }
            if (std.mem.endsWith(u8, name_, "index")) return error.JinjaValueNotFound;
            return .{ .integer = "-1" };
        }
        if (std.mem.eql(u8, name_, "strip") or std.mem.eql(u8, name_, "lstrip") or std.mem.eql(u8, name_, "rstrip")) {
            if (args.len > 1 or (args.len == 1 and args[0].value != .string and args[0].value != .none)) return error.InvalidJinjaArguments;
            const characters = try iterableValues(allocator, receiver);
            const removed = if (args.len == 1 and args[0].value == .string) try iterableValues(allocator, args[0].value) else null;
            var start: usize = 0;
            var stop = characters.len;
            if (!std.mem.eql(u8, name_, "rstrip")) while (start < stop and stripCharacter(characters[start], removed)) : (start += 1) {};
            if (!std.mem.eql(u8, name_, "lstrip")) while (stop > start and stripCharacter(characters[stop - 1], removed)) : (stop -= 1) {};
            var byte_start: usize = 0;
            var byte_stop: usize = 0;
            for (characters, 0..) |character, index| {
                if (index < start) byte_start += character.string.len;
                if (index < stop) byte_stop += character.string.len;
            }
            return .{ .string = text_[byte_start..byte_stop] };
        }
        if (std.mem.eql(u8, name_, "join")) {
            if (args.len != 1) return error.InvalidJinjaArguments;
            const values = try iterableValuesWithHost(allocator, args[0].value, host);
            var output: std.ArrayList(u8) = .empty;
            for (values, 0..) |value, index| {
                if (value != .string) return error.JinjaTypeError;
                if (index != 0) try output.appendSlice(allocator, text_);
                try output.appendSlice(allocator, value.string);
            }
            return .{ .string = try output.toOwnedSlice(allocator) };
        }
        if (std.mem.eql(u8, name_, "split") or std.mem.eql(u8, name_, "rsplit")) {
            if (args.len > 2) return error.InvalidJinjaArguments;
            var positional: usize = 0;
            for (args) |arg| {
                if (arg.name) |key| {
                    if (std.mem.eql(u8, key, "sep")) {
                        if (positional >= 1) return error.InvalidJinjaArguments;
                    } else if (std.mem.eql(u8, key, "maxsplit")) {
                        if (positional >= 2) return error.InvalidJinjaArguments;
                    } else return error.InvalidJinjaArguments;
                } else positional += 1;
            }
            const separator = argument(args, "sep", 0, .none);
            const maximum = try integer(argument(args, "maxsplit", 1, .{ .integer = "-1" }));
            if (separator != .string and separator != .none) return error.JinjaTypeError;
            if (separator == .string and separator.string.len == 0) return error.InvalidJinjaArguments;
            const backwards = std.mem.eql(u8, name_, "rsplit");
            var values: std.ArrayList(Value) = .empty;
            var count: i64 = 0;
            var position: usize = if (backwards) text_.len else 0;
            if (separator == .none) {
                const fields = try unicode.splitWhitespace(allocator, text_, maximum, backwards);
                for (fields) |field| try values.append(allocator, .{ .string = field });
                return .{ .list = try ownedValues(allocator, &values) };
            } else {
                while (maximum < 0 or count < maximum) {
                    if (backwards) {
                        const found = std.mem.lastIndexOf(u8, text_[0..position], separator.string) orelse break;
                        try values.append(allocator, .{ .string = text_[found + separator.string.len .. position] });
                        position = found;
                    } else {
                        const found = std.mem.indexOfPos(u8, text_, position, separator.string) orelse break;
                        try values.append(allocator, .{ .string = text_[position..found] });
                        position = found + separator.string.len;
                    }
                    count += 1;
                }
                try values.append(allocator, .{ .string = if (backwards) text_[0..position] else text_[position..] });
            }
            if (backwards) std.mem.reverse(Value, values.items);
            return .{ .list = try ownedValues(allocator, &values) };
        }
        if (std.mem.eql(u8, name_, "replace")) {
            if (args.len < 2 or args.len > 3 or args[0].value != .string or args[1].value != .string) return error.InvalidJinjaArguments;
            const maximum = if (args.len == 3) try integer(args[2].value) else -1;
            var output: std.ArrayList(u8) = .empty;
            var position: usize = 0;
            var count: i64 = 0;
            const needle = args[0].value.string;
            if (needle.len == 0) {
                if (maximum != 0) {
                    try output.appendSlice(allocator, args[1].value.string);
                    count += 1;
                }
                for (try iterableValues(allocator, receiver)) |character| {
                    try output.appendSlice(allocator, character.string);
                    if (maximum < 0 or count < maximum) {
                        try output.appendSlice(allocator, args[1].value.string);
                        count += 1;
                    }
                }
            } else {
                while (maximum < 0 or count < maximum) {
                    const found = std.mem.indexOfPos(u8, text_, position, needle) orelse break;
                    try output.appendSlice(allocator, text_[position..found]);
                    try output.appendSlice(allocator, args[1].value.string);
                    position = found + needle.len;
                    count += 1;
                }
                try output.appendSlice(allocator, text_[position..]);
            }
            return .{ .string = try output.toOwnedSlice(allocator) };
        }
    }
    return null;
}

fn isMethod(name: []const u8, methods: []const []const u8) bool {
    for (methods) |method| if (std.mem.eql(u8, name, method)) return true;
    return false;
}

fn stripCharacter(value: Value, removed: ?[]const Value) bool {
    if (removed) |characters| {
        for (characters) |character| if (equal(value, character)) return true;
        return false;
    }
    return unicode.whitespace(std.unicode.utf8Decode(value.string) catch return false);
}

fn expressionFinish(input: []const u8, start: usize) usize {
    var depth: usize = 0;
    var quote: u8 = 0;
    var index = start;
    while (index < input.len) : (index += 1) {
        const character = input[index];
        if (quote != 0) {
            if (character == '\\') index += 1 else if (character == quote) quote = 0;
            continue;
        }
        if (character == '\'' or character == '"') {
            quote = character;
            continue;
        }
        if (character == '(' or character == '[' or character == '{') {
            depth += 1;
        } else if (character == ')' or character == ']' or character == '}') {
            if (depth == 0) return index;
            depth -= 1;
        } else if (depth == 0 and (character == ',' or character == ':')) return index;
    }
    return index;
}

fn ident(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}
fn comparisonOperator(op: []const u8) bool {
    for ([_][]const u8{ "==", "!=", "<=", ">=", "<", ">", "in", "not in" }) |candidate| if (std.mem.eql(u8, op, candidate)) return true;
    return false;
}
fn rank(op: []const u8) u8 {
    if (std.mem.eql(u8, op, "or")) return 1;
    if (std.mem.eql(u8, op, "and")) return 2;
    if (std.mem.eql(u8, op, "is")) return 7;
    if (std.mem.eql(u8, op, "in") or std.mem.eql(u8, op, "not in") or std.mem.indexOfScalar(u8, "=!<>", op[0]) != null) return 3;
    if (std.mem.eql(u8, op, "~") or std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-")) return 4;
    if (std.mem.eql(u8, op, "**")) return 6;
    return 5;
}
fn numeric(v: Value) !f64 {
    return numericFloat(v);
}
pub fn integerProtocol(value: Value) ?[]const u8 {
    const marker = value.attribute("__dxt_integer");
    return if (marker == .string) marker.string else null;
}
fn integerText(v: Value) ?[]const u8 {
    if (integerProtocol(v)) |number| return number;
    return switch (v) {
        .integer => |n| n,
        .boolean => |b| if (b) "1" else "0",
        else => null,
    };
}
fn integerFromString(a: std.mem.Allocator, text: []const u8, base_arg: u8) ![]const u8 {
    if (text.len == 0) return error.JinjaTypeError;
    var digits = text;
    const negative = digits[0] == '-';
    if (negative or digits[0] == '+') digits = digits[1..];
    var base = base_arg;
    if (base == 0) base = 10;
    if (digits.len >= 2 and digits[0] == '0') {
        const prefixed: ?u8 = switch (digits[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => null,
        };
        if (prefixed) |found| if (base_arg == 0 or base == found) {
            base = found;
            digits = digits[2..];
        };
    }
    if (digits.len == 0 or digits[0] == '_' or digits[digits.len - 1] == '_' or std.mem.indexOf(u8, digits, "__") != null) return error.JinjaTypeError;
    const number = try numbers.canonical(a, digits, base);
    return if (negative) try numbers.negate(a, number) else number;
}
fn numericOrder(a: std.mem.Allocator, left: Value, right: Value) !std.math.Order {
    if (floatProtocol(left)) |number| if (std.math.isNan(number)) return error.UnorderedJinjaNumber;
    if (floatProtocol(right)) |number| if (std.math.isNan(number)) return error.UnorderedJinjaNumber;
    if (integerText(left)) |x| {
        if (integerText(right)) |y| return numbers.order(x, y);
        return try numbers.orderFloat(a, x, try numeric(right));
    }
    if (integerText(right)) |y| return (try numbers.orderFloat(a, y, try numeric(left))).invert();
    const x = try numeric(left);
    const y = try numeric(right);
    if (std.math.isNan(x) or std.math.isNan(y)) return error.UnorderedJinjaNumber;
    return std.math.order(x, y);
}
pub fn valueOrder(allocator: std.mem.Allocator, left: Value, right: Value) !std.math.Order {
    return valueOrderDepth(allocator, left, right, 0);
}
fn valueOrderDepth(allocator: std.mem.Allocator, left: Value, right: Value, depth: usize) anyerror!std.math.Order {
    if (depth > 128) return error.JinjaExpressionDepthExceeded;
    if (temporal.hashable(left) or temporal.hashable(right)) return temporal.order(left, right);
    if (yaml_values.isHashable(left) or yaml_values.isHashable(right)) return yaml_values.order(left, right);
    if (left == .list or tupleProtocol(left) != null or right == .list or tupleProtocol(right) != null) {
        if ((left == .list) != (right == .list)) return error.JinjaTypeError;
        const lhs = (if (left == .list) left.list else tupleProtocol(left)) orelse return error.JinjaTypeError;
        const rhs = (if (right == .list) right.list else tupleProtocol(right)) orelse return error.JinjaTypeError;
        for (lhs[0..@min(lhs.len, rhs.len)], rhs[0..@min(lhs.len, rhs.len)]) |x, y| {
            if (equalMember(x, y)) continue;
            return valueOrderDepth(allocator, x, y, depth + 1);
        }
        return std.math.order(lhs.len, rhs.len);
    }
    if (left == .string and right == .string) return std.mem.order(u8, left.string, right.string);
    return numericOrder(allocator, left, right);
}
fn equal(a: Value, b: Value) bool {
    return equalValues(a, b);
}
fn equalMember(a: Value, b: Value) bool {
    if (floatProtocol(a)) |number| if (std.math.isNan(number) and mapping_keys.keyEqual(a, b)) return true;
    if (complexProtocol(a)) |number| if ((std.math.isNan(number.real) or std.math.isNan(number.imaginary)) and mapping_keys.keyEqual(a, b)) return true;
    return equalValues(a, b);
}
fn immutableIdentity(value: Value) ?[]const u8 {
    for ([_][]const u8{ "__dxt_timezone_identity", "__dxt_class_identity" }) |marker| {
        const identity = value.attribute(marker);
        if (identity == .string) return marker;
    }
    return null;
}
fn immutableSame(left: Value, right: Value) bool {
    const marker = immutableIdentity(left) orelse return false;
    const other = immutableIdentity(right) orelse return false;
    return std.mem.eql(u8, marker, other) and std.mem.eql(u8, left.attribute(marker).string, right.attribute(marker).string);
}
fn immutableEqual(left: Value, right: Value) bool {
    if (left.attribute("__dxt_timezone_builtin").truthy() or right.attribute("__dxt_timezone_builtin").truthy()) {
        return left.attribute("__dxt_timezone_builtin").truthy() and right.attribute("__dxt_timezone_builtin").truthy() and equalValues(left.attribute("__dxt_timezone_offset_us"), right.attribute("__dxt_timezone_offset_us"));
    }
    return immutableSame(left, right);
}
pub fn equalValues(a: Value, b: Value) bool {
    if (tupleProtocol(a)) |items| {
        const other = tupleProtocol(b) orelse return false;
        if (items.len != other.len) return false;
        for (items, other) |left, right| if (!equalMember(left, right)) return false;
        return true;
    }
    if (tupleProtocol(b) != null) return false;
    if (immutableIdentity(a) != null or immutableIdentity(b) != null) return immutableEqual(a, b);
    if (isUndefined(a) or isUndefined(b)) return isUndefined(a) and isUndefined(b) and (a == .capture_undefined) == (b == .capture_undefined);
    if (yaml_values.isHashable(a) or yaml_values.isHashable(b)) return yaml_values.keyEqual(a, b);
    if (sets.isSet(a) or sets.isSet(b)) return sets.equal(a, b);
    const complex_a = complexProtocol(a);
    const complex_b = complexProtocol(b);
    if (complex_a != null or complex_b != null) {
        if (complex_a != null and complex_b != null) return complex_a.?.real == complex_b.?.real and complex_a.?.imaginary == complex_b.?.imaginary;
        const number = complex_a orelse complex_b.?;
        const other = if (complex_a != null) b else a;
        if (number.imaginary != 0) return false;
        return (numericOrder(std.heap.page_allocator, .{ .number = number.real }, other) catch return false) == .eq;
    }
    if (sequences.kind(a)) |kind_a| {
        const kind_b = sequences.kind(b) orelse return false;
        if (!std.mem.eql(u8, kind_a, kind_b)) return false;
        if (std.mem.eql(u8, kind_a, "values") or std.mem.eql(u8, kind_a, "zip")) return a.object.ptr == b.object.ptr;
        const source_a = a.attribute("__dxt_sequence_source");
        const source_b = b.attribute("__dxt_sequence_source");
        if (source_a != .object or source_b != .object or source_a.object.len != source_b.object.len) return false;
        for (source_a.object) |entry| {
            const item = (mappingEntry(source_b, entryKey(entry)) catch return false) orelse return false;
            if (std.mem.eql(u8, kind_a, "items") and !equalMember(entry.value, item.value)) return false;
        }
        return true;
    }
    if ((integerText(a) != null or floatProtocol(a) != null) and (integerText(b) != null or floatProtocol(b) != null)) return (numericOrder(std.heap.page_allocator, a, b) catch return false) == .eq;
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .undefined, .conditional_undefined, .ordinary_undefined, .capture_undefined => unreachable,
        .none => true,
        .string => |s| std.mem.eql(u8, s, b.string),
        .number => |n| n == b.number,
        .complex => unreachable,
        .integer => |n| std.mem.eql(u8, n, b.integer),
        .boolean => |v| v == b.boolean,
        .callable => |v| std.mem.eql(u8, v, b.callable),
        .list, .tuple => |values| blk: {
            const other = sequence(b).?;
            if (values.len != other.len) break :blk false;
            for (values, other) |x, y| if (!equalMember(x, y)) break :blk false;
            break :blk true;
        },
        .object => |entries| blk: {
            if (entries.len != b.object.len) break :blk false;
            for (entries) |entry| {
                const other = (mappingEntry(b, entryKey(entry)) catch break :blk false) orelse break :blk false;
                if (!equalMember(entry.value, other.value)) break :blk false;
            }
            break :blk true;
        },
    };
}
/// Rendering can request deferred native metadata through the active frame.
/// Descriptors retain callable names, never borrowed Host pointers.
threadlocal var text_depth: usize = 0;
pub fn textWithHost(allocator: std.mem.Allocator, value: Value, host: ?Host) anyerror![]const u8 {
    if (text_depth == 128) return error.JinjaExpressionDepthExceeded;
    text_depth += 1;
    defer text_depth -= 1;
    if (try sequences.textWithHost(allocator, value, host)) |sequence_text| return sequence_text;
    const rendered = value.attribute("__dxt_repr");
    if (rendered == .callable) {
        const active = host orelse return error.UnsupportedJinjaCall;
        return textWithHost(allocator, try active.call(active.context, rendered.callable, &.{}, allocator), host);
    }
    if (value == .list or value == .tuple) {
        var result: std.ArrayList(u8) = .empty;
        try result.append(allocator, if (value == .tuple) '(' else '[');
        for (sequence(value).?, 0..) |item, i| {
            if (i != 0) try result.appendSlice(allocator, ", ");
            try result.appendSlice(allocator, try reprWithHost(allocator, item, host));
        }
        if (value == .tuple and sequence(value).?.len == 1) try result.append(allocator, ',');
        try result.append(allocator, if (value == .tuple) ')' else ']');
        return result.toOwnedSlice(allocator);
    }
    if (value == .object and value.attribute("__dxt_rendered") == .undefined and sequences.kind(value) == null and !sets.isSet(value)) {
        var result: std.ArrayList(u8) = .empty;
        try result.append(allocator, '{');
        for ((mappingSource(value) orelse value).object, 0..) |entry, i| {
            if (i != 0) try result.appendSlice(allocator, ", ");
            try result.appendSlice(allocator, try reprWithHost(allocator, entryKey(entry), host));
            try result.appendSlice(allocator, ": ");
            try result.appendSlice(allocator, try reprWithHost(allocator, entry.value, host));
        }
        try result.append(allocator, '}');
        return result.toOwnedSlice(allocator);
    }
    return value.text(allocator);
}
pub fn reprWithHost(allocator: std.mem.Allocator, value: Value, host: ?Host) ![]const u8 {
    const rendered = value.attribute("__dxt_repr");
    if (rendered == .string) return rendered.string;
    if (rendered == .callable or value == .list or value == .tuple or (value == .object and value.attribute("__dxt_rendered") == .undefined)) return textWithHost(allocator, value, host);
    return repr(value, allocator);
}
fn applyWithHost(allocator: std.mem.Allocator, op: []const u8, left: Value, right: Value, host: ?Host) !Value {
    if (std.mem.eql(u8, op, "in")) return .{ .boolean = try containsWithHost(allocator, right, left, host) };
    if (std.mem.eql(u8, op, "not in")) return .{ .boolean = !(try containsWithHost(allocator, right, left, host)) };
    if (std.mem.eql(u8, op, "~")) return .{ .string = try std.fmt.allocPrint(allocator, "{s}{s}", .{ try textWithHost(allocator, left, host), try textWithHost(allocator, right, host) }) };
    return apply(allocator, op, left, right);
}
pub fn addValues(allocator: std.mem.Allocator, left: Value, right: Value) !Value {
    return apply(allocator, "+", left, right);
}
fn contains(allocator: std.mem.Allocator, container: Value, item: Value) anyerror!bool {
    return containsWithHost(allocator, container, item, null);
}
pub fn containsWithHost(allocator: std.mem.Allocator, container: Value, item: Value, host: ?Host) anyerror!bool {
    if (sequences.isIterator(container)) {
        while (try sequences.next(allocator, container, host)) |row| if (equalMember(row, item)) return true;
        return false;
    }
    if (isUndefined(container)) return false;
    if (tupleProtocol(container)) |items| {
        for (items) |member| if (equalMember(member, item)) return true;
        return false;
    }
    if (mappingSource(container)) |source| return if (item == .string) (try mapping_keys.entry(source, item)) != null else false;
    if (container.attribute("__dxt_binary") == .string) return yaml_values.contains(container, item);
    if (sets.isSet(container)) return try sets.contains(container, item);
    if (container.attribute("__dxt_noniterable").truthy()) return error.JinjaTypeError;
    if (sequences.kind(container) != null) {
        for (try iterableValuesWithHost(allocator, container, host)) |value| if (equalMember(value, item)) return true;
        return false;
    }
    return switch (container) {
        .string => |s| if (item == .string) std.mem.indexOf(u8, s, item.string) != null else error.JinjaTypeError,
        .list, .tuple => |values| blk: {
            for (values) |v| if (equalMember(v, item)) break :blk true;
            break :blk false;
        },
        .object => (try mappingEntry(container, item)) != null,
        else => error.JinjaTypeError,
    };
}
fn apply(allocator: std.mem.Allocator, op: []const u8, a: Value, b: Value) !Value {
    if (a == .object) if (tupleProtocol(a)) |items| return apply(allocator, op, .{ .tuple = items }, b);
    if (b == .object) if (tupleProtocol(b)) |items| return apply(allocator, op, a, .{ .tuple = items });
    if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=")) try temporal.validateComparison(a, b);
    if (std.mem.eql(u8, op, "==")) return .{ .boolean = equal(a, b) };
    if (std.mem.eql(u8, op, "!=")) return .{ .boolean = !equal(a, b) };
    if (std.mem.eql(u8, op, "in")) return .{ .boolean = try contains(allocator, b, a) };
    if (std.mem.eql(u8, op, "not in")) return .{ .boolean = !(try contains(allocator, b, a)) };
    if (std.mem.eql(u8, op, "~") or (std.mem.eql(u8, op, "+") and a == .string and b == .string)) return .{ .string = try std.fmt.allocPrint(allocator, "{s}{s}", .{ try a.text(allocator), try b.text(allocator) }) };
    if (try sets.apply(allocator, op, a, b)) |value| return value;
    if (try yaml_values.apply(allocator, op, a, b)) |value| return value;
    if (try temporal.apply(allocator, op, a, b)) |value| return value;
    const complex_a = complexProtocol(a);
    const complex_b = complexProtocol(b);
    if (complex_a != null or complex_b != null) {
        const x = complex_a orelse complex_numbers.Complex{ .real = try numeric(a), .imaginary = 0 };
        const y = complex_b orelse complex_numbers.Complex{ .real = try numeric(b), .imaginary = 0 };
        return try complexValue(allocator, if (std.mem.eql(u8, op, "+")) complex_numbers.add(x, y) else if (std.mem.eql(u8, op, "-")) complex_numbers.subtract(x, y) else if (std.mem.eql(u8, op, "*")) complex_numbers.multiply(x, y) else if (std.mem.eql(u8, op, "/")) try complex_numbers.divide(x, y) else if (std.mem.eql(u8, op, "**")) try complex_numbers.power(x, y) else return error.JinjaTypeError);
    }
    if (std.mem.eql(u8, op, "+") and a == .list and b == .list) return .{ .list = try std.mem.concat(allocator, Value, &.{ a.list, b.list }) };
    if (std.mem.eql(u8, op, "+") and a == .tuple and b == .tuple) return .{ .tuple = try std.mem.concat(allocator, Value, &.{ a.tuple, b.tuple }) };
    if (std.mem.eql(u8, op, "*")) {
        const container: Value = if (a == .string or a == .list or a == .tuple) a else b;
        const repetitions = if (a == .string or a == .list or a == .tuple) b else a;
        if (container == .string or container == .list or container == .tuple) {
            const count: usize = @intCast(@max(0, try integerIndex(repetitions)));
            const size = if (container == .string) container.string.len else sequence(container).?.len;
            if (size != 0 and count > 10000000 / size) return error.JinjaIterationLimitExceeded;
            if (container == .string) {
                const result = try allocator.alloc(u8, count * size);
                for (0..count) |i| @memcpy(result[i * size ..][0..size], container.string);
                return .{ .string = result };
            }
            const result = try allocateValues(allocator, count * size);
            for (0..count) |i| @memcpy(result[i * size ..][0..size], sequence(container).?);
            return if (container == .tuple) .{ .tuple = result } else .{ .list = result };
        }
    }
    if (std.mem.indexOfScalar(u8, "<>", op[0]) != null) {
        const order = valueOrder(allocator, a, b) catch |err| {
            if (err == error.UnorderedJinjaNumber) return .{ .boolean = false };
            return err;
        };
        return .{ .boolean = if (std.mem.eql(u8, op, "<")) order == .lt else if (std.mem.eql(u8, op, ">")) order == .gt else if (std.mem.eql(u8, op, "<=")) order != .gt else order != .lt };
    }
    if (integerText(a)) |x| {
        if (integerText(b)) |y| {
            if (std.mem.eql(u8, op, "/")) return .{ .number = try numbers.divide(allocator, x, y) };
            if (!std.mem.eql(u8, op, "**") or y[0] != '-') return .{ .integer = try numbers.apply(allocator, op, x, y) };
        }
    }
    const x = try numeric(a);
    const y = try numeric(b);
    if (std.mem.eql(u8, op, "**")) {
        if (x == 0 and y < 0) return error.JinjaDivisionByZero;
        if (x < 0 and std.math.isFinite(y) and @floor(y) != y) return try complexValue(allocator, try complex_numbers.power(.{ .real = x, .imaginary = 0 }, .{ .real = y, .imaginary = 0 }));
        const powered = std.math.pow(f64, x, y);
        if (std.math.isNan(powered) and std.math.isFinite(x) and std.math.isFinite(y)) return error.JinjaTypeError;
        if (std.math.isFinite(x) and std.math.isFinite(y) and !std.math.isFinite(powered)) return error.JinjaNumericOverflow;
        return try floatValue(allocator, powered);
    }
    if ((std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "//") or std.mem.eql(u8, op, "%")) and y == 0) return error.JinjaDivisionByZero;
    if (std.mem.eql(u8, op, "//") or std.mem.eql(u8, op, "%")) {
        const result = try numbers.floatDivMod(x, y);
        return try floatValue(allocator, if (std.mem.eql(u8, op, "//")) result.quotient else result.remainder);
    }
    return try floatValue(allocator, if (std.mem.eql(u8, op, "+")) x + y else if (std.mem.eql(u8, op, "-")) x - y else if (std.mem.eql(u8, op, "*")) x * y else if (std.mem.eql(u8, op, "/")) x / y else return error.InvalidJinjaExpression);
}
pub fn indexValue(allocator: std.mem.Allocator, value: Value, key: Value) !Value {
    if (sequences.kind(value) != null) return .undefined;
    if (value == .capture_undefined) return value;
    if (isUndefined(value)) return error.UndefinedJinjaValue;
    if (sets.isSet(value)) return .undefined;
    if (value == .object and tupleProtocol(value) != null and key == .string) return checkedAttribute(value, key.string);
    if (value == .object) {
        const names = value.attribute("__dxt_string_index");
        if (names == .object and key == .string) return names.attribute(key.string);
        const indexed = value.attribute("__dxt_indexed");
        if (indexed == .list and key != .string) {
            const i = try integerIndex(key);
            if (i < 0 or i >= indexed.list.len) return .undefined;
            return indexed.list[@intCast(i)];
        }
    }
    if (value == .object) if (sequence(value)) |items| return try indexValue(allocator, .{ .list = items }, key);
    if (value == .object) return mappingGet(value, key) catch |err| {
        // Jinja's getitem suppresses Python dictionary TypeError, including
        // an unhashable subscript. Direct dict methods and membership raise.
        if (err == error.JinjaTypeError) return .undefined;
        return err;
    };
    var i = integerIndex(key) catch |err| {
        if (err == error.UndefinedJinjaValue) return err;
        return .undefined;
    };
    const characters = if (value == .string) try iterableValues(allocator, value) else null;
    const len: usize = switch (value) {
        .list, .tuple => |v| v.len,
        .string => characters.?.len,
        else => return error.JinjaTypeError,
    };
    if (i < 0) i += @intCast(len);
    if (i < 0 or i >= @as(i64, @intCast(len))) return .undefined;
    return switch (value) {
        .list, .tuple => |v| v[@intCast(i)],
        .string => characters.?[@intCast(i)],
        else => unreachable,
    };
}
pub fn indexValueWithHost(allocator: std.mem.Allocator, value: Value, key: Value, host: ?Host) !Value {
    if (key == .string and value.attribute("__dxt_getattr") == .callable) return attributeWithHost(allocator, value, key.string, host);
    return indexValue(allocator, value, key);
}

fn integer(value: Value) !i64 {
    return integerIndex(value);
}

fn sliceValue(allocator: std.mem.Allocator, value: Value, start: ?Value, stop: ?Value, step: ?Value) !Value {
    if (value == .capture_undefined) return value;
    if (isUndefined(value)) return error.UndefinedJinjaValue;
    if (sets.isSet(value)) return error.JinjaTypeError;
    const values = try iterableValues(allocator, value);
    const length: i64 = @intCast(values.len);
    const stride = if (step) |v| integer(v) catch return .undefined else 1;
    if (stride == 0) return error.InvalidJinjaArguments;
    var first = if (start) |v| integer(v) catch return .undefined else if (stride > 0) @as(i64, 0) else length - 1;
    var last = if (stop) |v| integer(v) catch return .undefined else if (stride > 0) length else @as(i64, -1);
    if (start != null and first < 0) first += length;
    if (stop != null and last < 0) last += length;
    first = std.math.clamp(first, if (stride > 0) @as(i64, 0) else -1, if (stride > 0) length else length - 1);
    last = std.math.clamp(last, if (stride > 0) @as(i64, 0) else -1, if (stride > 0) length else length - 1);
    var result: std.ArrayList(Value) = .empty;
    var i = first;
    while (if (stride > 0) i < last else i > last) : (i += stride) try result.append(allocator, values[@intCast(i)]);
    if (value == .string) {
        var text_result: std.ArrayList(u8) = .empty;
        for (result.items) |v| try text_result.appendSlice(allocator, v.string);
        return .{ .string = try text_result.toOwnedSlice(allocator) };
    }
    const values_result = try ownedValues(allocator, &result);
    if (value.attribute("__dxt_binary") == .string) return yaml_values.fromMembers(allocator, values_result);
    return if (tupleProtocol(value) != null) .{ .tuple = values_result } else .{ .list = values_result };
}

pub fn iterableValues(allocator: std.mem.Allocator, value: Value) anyerror![]const Value {
    return iterableValuesWithHost(allocator, value, null);
}
pub fn iterableValuesWithHost(allocator: std.mem.Allocator, value: Value, host: ?Host) anyerror![]const Value {
    if (value.attribute("__dxt_noniterable") == .boolean and value.attribute("__dxt_noniterable").boolean) return error.JinjaTypeError;
    if (try sequences.itemsWithHost(allocator, value, host)) |items| return items;
    if (sequence(value)) |items| return items;
    if (isUndefined(value)) return &.{};
    if (value == .object) {
        const source = mappingSource(value) orelse value;
        const result = try allocateValues(allocator, source.object.len);
        for (source.object, result) |entry, *v| v.* = entryKey(entry);
        return result;
    }
    if (value == .string) {
        var result: std.ArrayList(Value) = .empty;
        var index: usize = 0;
        while (index < value.string.len) {
            const size = std.unicode.utf8ByteSequenceLength(value.string[index]) catch return error.JinjaTypeError;
            if (index + size > value.string.len) return error.JinjaTypeError;
            try result.append(allocator, .{ .string = value.string[index .. index + size] });
            index += size;
        }
        return try result.toOwnedSlice(allocator);
    }
    return error.JinjaTypeError;
}

fn argument(args: []const Argument, name: []const u8, position: usize, fallback: Value) Value {
    var index: usize = 0;
    for (args) |arg| {
        if (arg.name) |key| {
            if (std.mem.eql(u8, key, name)) return arg.value;
        } else {
            if (index == position) return arg.value;
            index += 1;
        }
    }
    return fallback;
}

pub fn attributeValue(allocator: std.mem.Allocator, value: Value, attribute: Value) !Value {
    return attributeValueWithHost(allocator, value, attribute, null);
}
pub fn attributeValueWithHost(allocator: std.mem.Allocator, value: Value, attribute: Value, host: ?Host) !Value {
    const paths = @import("filter_attributes.zig");
    return paths.get(allocator, value, try paths.parts(allocator, attribute), .none, host);
}

pub fn testValueWithHost(allocator: std.mem.Allocator, name: []const u8, value: Value, args: []const Argument, host: ?Host) anyerror!bool {
    if (std.mem.eql(u8, name, "in")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
        if (args[0].name) |keyword| if (!std.mem.eql(u8, keyword, "seq")) return error.InvalidJinjaArguments;
        return containsWithHost(allocator, args[0].value, value, host);
    }
    return testValue(name, value, args);
}

pub fn testValue(name: []const u8, value: Value, args: []const Argument) !bool {
    inline for (.{ "defined", "undefined", "none", "None", "string", "number", "integer", "float", "boolean", "true", "false", "mapping", "iterable", "sequence", "callable", "odd", "even" }) |test_name| {
        if (std.mem.eql(u8, name, test_name) and args.len != 0) return error.InvalidJinjaArguments;
    }
    for (args) |arg| if (arg.name) |keyword| {
        if (std.mem.eql(u8, name, "sameas")) {
            if (!std.mem.eql(u8, keyword, "other")) return error.InvalidJinjaArguments;
        } else if (std.mem.eql(u8, name, "divisibleby")) {
            if (!std.mem.eql(u8, keyword, "num")) return error.InvalidJinjaArguments;
        } else if (std.mem.eql(u8, name, "in")) {
            if (!std.mem.eql(u8, keyword, "seq")) return error.InvalidJinjaArguments;
        } else return error.InvalidJinjaArguments;
    };
    if (std.mem.eql(u8, name, "defined")) return !isUndefined(value);
    if (std.mem.eql(u8, name, "undefined")) return isUndefined(value);
    if (std.mem.eql(u8, name, "none") or std.mem.eql(u8, name, "None")) return value == .none;
    if (std.mem.eql(u8, name, "string")) return value == .string;
    if (std.mem.eql(u8, name, "number")) return integerText(value) != null or floatProtocol(value) != null or complexProtocol(value) != null;
    if (std.mem.eql(u8, name, "integer")) return value == .integer or integerProtocol(value) != null;
    if (std.mem.eql(u8, name, "float")) return floatProtocol(value) != null;
    if (std.mem.eql(u8, name, "boolean")) return value == .boolean;
    if (std.mem.eql(u8, name, "true")) return value == .boolean and value.boolean;
    if (std.mem.eql(u8, name, "false")) return value == .boolean and !value.boolean;
    if (std.mem.eql(u8, name, "sameas")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
        const other = args[0].value;
        if (value == .capture_undefined and other == .capture_undefined) return value.capture_undefined.identity == other.capture_undefined.identity;
        if (value == .ordinary_undefined and other == .ordinary_undefined) return value.ordinary_undefined.identity == other.ordinary_undefined.identity;
        if (isUndefined(value) or isUndefined(other)) return false;
        if (immutableIdentity(value) != null or immutableIdentity(other) != null) return immutableSame(value, other);
        if (floatProtocol(value)) |number| if (std.math.isNan(number)) return mapping_keys.keyEqual(value, other);
        if (complexProtocol(value)) |number| if (std.math.isNan(number.real) or std.math.isNan(number.imaginary)) return mapping_keys.keyEqual(value, other);
        if (std.meta.activeTag(value) != std.meta.activeTag(other)) return false;
        return switch (value) {
            .object => |entries| entries.ptr == other.object.ptr,
            .list => |values| values.ptr == other.list.ptr,
            .tuple => |values| values.ptr == other.tuple.ptr,
            else => equalValues(value, other),
        };
    }
    if (sets.isSet(value)) {
        if (std.mem.eql(u8, name, "mapping") or std.mem.eql(u8, name, "sequence") or std.mem.eql(u8, name, "callable")) return false;
        if (std.mem.eql(u8, name, "iterable")) return true;
    }
    if (value.attribute("__dxt_noniterable") == .boolean and value.attribute("__dxt_noniterable").boolean) {
        if (std.mem.eql(u8, name, "mapping") or std.mem.eql(u8, name, "iterable") or std.mem.eql(u8, name, "sequence")) return false;
    }
    if (std.mem.eql(u8, name, "mapping")) return value == .object and sequence(value) == null and sequences.kind(value) == null;
    if (std.mem.eql(u8, name, "iterable")) return isIterable(value);
    if (std.mem.eql(u8, name, "sequence")) return isUndefined(value) or value == .list or value == .tuple or (value == .object and sequences.kind(value) == null) or value == .string;
    if (std.mem.eql(u8, name, "callable")) return isUndefined(value) or callableName(value) != null;
    if (std.mem.eql(u8, name, "equalto") or std.mem.eql(u8, name, "eq") or std.mem.eql(u8, name, "==")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
        return equal(value, args[0].value);
    }
    if (std.mem.eql(u8, name, "ne") or std.mem.eql(u8, name, "!=")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
        return !equal(value, args[0].value);
    }
    if (std.mem.eql(u8, name, "in")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
        return try contains(std.heap.page_allocator, args[0].value, value);
    }
    if (std.mem.eql(u8, name, "odd") or std.mem.eql(u8, name, "even")) {
        const odd = if (integerText(value)) |number| (number[number.len - 1] - '0') % 2 != 0 else @mod(try numeric(value), 2) != 0;
        return if (std.mem.eql(u8, name, "odd")) odd else !odd;
    }
    if (std.mem.eql(u8, name, "divisibleby")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
        if (integerText(value)) |number| if (integerText(args[0].value)) |divisor| {
            const remainder = try numbers.apply(std.heap.page_allocator, "%", number, divisor);
            defer std.heap.page_allocator.free(remainder);
            return std.mem.eql(u8, remainder, "0");
        };
        const divisor = try numeric(args[0].value);
        if (divisor == 0) return error.JinjaDivisionByZero;
        return @mod(try numeric(value), divisor) == 0;
    }
    if (std.mem.eql(u8, name, "lt") or std.mem.eql(u8, name, "lessthan") or std.mem.eql(u8, name, "gt") or std.mem.eql(u8, name, "greaterthan") or std.mem.eql(u8, name, "le") or std.mem.eql(u8, name, "ge")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
        const operator = if (std.mem.eql(u8, name, "lt") or std.mem.eql(u8, name, "lessthan")) "<" else if (std.mem.eql(u8, name, "gt") or std.mem.eql(u8, name, "greaterthan")) ">" else if (std.mem.eql(u8, name, "le")) "<=" else ">=";
        return (try apply(std.heap.page_allocator, operator, value, args[0].value)).boolean;
    }
    return error.UnsupportedJinjaTest;
}
fn builtin(allocator: std.mem.Allocator, name: []const u8, args: []const Argument, host: ?Host) !?Value {
    if (std.mem.eql(u8, name, "zip")) {
        const inputs = try allocateValues(allocator, args.len);
        for (args, inputs) |arg, *input| {
            if (arg.name != null) return error.InvalidJinjaArguments;
            if (!isIterable(arg.value)) return error.JinjaTypeError;
            input.* = arg.value;
        }
        return try sequences.zip(allocator, inputs);
    }
    if (std.mem.eql(u8, name, "range")) {
        if (args.len < 1 or args.len > 3) return error.InvalidJinjaArguments;
        var bounds: [3]i64 = .{ 0, 0, 1 };
        for (args, 0..) |arg, i| {
            bounds[i] = try integerIndex(arg.value);
        }
        if (args.len == 1) {
            bounds[1] = bounds[0];
            bounds[0] = 0;
        }
        if (bounds[2] == 0) return error.InvalidJinjaArguments;
        var values: std.ArrayList(Value) = .empty;
        var n = bounds[0];
        while (if (bounds[2] > 0) n < bounds[1] else n > bounds[1]) : (n += bounds[2]) {
            if (values.items.len >= 100000) return error.JinjaIterationLimitExceeded;
            try values.append(allocator, try integerValue(allocator, n));
        }
        return .{ .list = try ownedValues(allocator, &values) };
    }
    if (std.mem.eql(u8, name, "dict") or std.mem.eql(u8, name, "namespace")) {
        var entries: std.ArrayList(Entry) = .empty;
        var positional: usize = 0;
        for (args) |arg| {
            const key = arg.name orelse {
                positional += 1;
                if (positional > 1) return error.InvalidJinjaArguments;
                if (arg.value == .object and !arg.value.attribute("__dxt_noniterable").truthy() and sequences.kind(arg.value) == null and !sets.isSet(arg.value) and tupleProtocol(arg.value) == null) {
                    for (arg.value.object) |entry| try mappingPut(allocator, &entries, entryKey(entry), entry.value);
                } else {
                    for (try iterableValuesWithHost(allocator, arg.value, host)) |item| {
                        const pair = try iterableValuesWithHost(allocator, item, host);
                        if (pair.len != 2) return error.InvalidJinjaArguments;
                        try mappingPut(allocator, &entries, pair[0], pair[1]);
                    }
                }
                continue;
            };
            try mappingPut(allocator, &entries, .{ .string = key }, arg.value);
        }
        return .{ .object = try ownedEntries(allocator, &entries) };
    }
    return null;
}
fn filter(allocator: std.mem.Allocator, name: []const u8, value: Value, args: []const Argument) !Value {
    return filterValue(allocator, name, value, args, null);
}
pub fn filterValue(allocator: std.mem.Allocator, name: []const u8, value: Value, args: []const Argument, host: ?Host) anyerror!Value {
    inline for (.{ "lower", "upper", "string", "length", "count", "list", "first", "last", "reverse" }) |parameterless| {
        if (std.mem.eql(u8, name, parameterless) and args.len != 0) return error.InvalidJinjaArguments;
    }
    if (try @import("standard_text_filters.zig").callWithHost(allocator, name, value, args, host)) |result| return result;
    if (std.mem.eql(u8, name, "tojson")) {
        if (args.len > 1) return error.InvalidJinjaArguments;
        if (args.len == 1 and args[0].name != null and !std.mem.eql(u8, args[0].name.?, "indent")) return error.InvalidJinjaArguments;
        const indentation = if (args.len == 1) args[0].value else Value.none;
        const spacing: ?[]const u8 = switch (indentation) {
            .none => null,
            .string => |text| text,
            .integer, .boolean => blk: {
                const size = try integerIndex(indentation);
                if (size > 1000000) return error.JinjaIterationLimitExceeded;
                const result = try allocator.alloc(u8, @intCast(@max(0, size)));
                @memset(result, ' ');
                break :blk result;
            },
            else => return error.JinjaTypeError,
        };
        return .{ .string = try @import("expression_json.zig").render(allocator, value, spacing) };
    }
    if (std.mem.eql(u8, name, "indent")) {
        if (value != .string) return error.JinjaTypeError;
        var bound = [_]Value{ .{ .integer = "4" }, .{ .boolean = false }, .{ .boolean = false } };
        var seen = [_]bool{false} ** 3;
        var positional: usize = 0;
        var has_keyword = false;
        for (args) |arg| {
            const index = if (arg.name) |key| blk: {
                has_keyword = true;
                for ([_][]const u8{ "width", "first", "blank" }, 0..) |parameter, i| if (std.mem.eql(u8, key, parameter)) break :blk i;
                return error.InvalidJinjaArguments;
            } else blk: {
                if (has_keyword or positional >= bound.len) return error.InvalidJinjaArguments;
                const i = positional;
                positional += 1;
                break :blk i;
            };
            if (seen[index]) return error.InvalidJinjaArguments;
            seen[index] = true;
            bound[index] = arg.value;
        }
        const indent = @import("indent_filter.zig");
        const width: indent.Width = switch (bound[0]) {
            .string => |prefix| .{ .text = prefix },
            .boolean => |enabled| .{ .spaces = @intFromBool(enabled) },
            .integer => blk: {
                const number = try integerIndex(bound[0]);
                if (number > 1000000) return error.JinjaIterationLimitExceeded;
                break :blk .{ .spaces = if (number < 0) 0 else @intCast(number) };
            },
            else => return error.JinjaTypeError,
        };
        return .{ .string = try indent.render(allocator, value.string, width, bound[1].truthy(), bound[2].truthy()) };
    }
    if (std.mem.eql(u8, name, "attr")) {
        if (args.len != 1 or args[0].value != .string) return error.InvalidJinjaArguments;
        if (sequences.kind(value) != null) return .undefined;
        if (tupleProtocol(value) != null) return checkedAttribute(value, args[0].value.string);
        if (value == .capture_undefined and std.mem.startsWith(u8, args[0].value.string, "__") and std.mem.endsWith(u8, args[0].value.string, "__") and !undefinedUnsafeAttribute(args[0].value.string, true)) return try captureUndefined(allocator, args[0].value.string);
        if (isUndefined(value)) return try checkedAttribute(value, args[0].value.string);
        return value.attribute(args[0].value.string);
    }
    const generators = @import("expression_filter_iterator.zig");
    if (std.mem.eql(u8, name, "map")) return generators.map(allocator, value, args);
    if (std.mem.eql(u8, name, "select") or std.mem.eql(u8, name, "reject") or std.mem.eql(u8, name, "selectattr") or std.mem.eql(u8, name, "rejectattr")) return generators.select(allocator, value, args, std.mem.endsWith(u8, name, "attr"), std.mem.startsWith(u8, name, "reject"));
    if (std.mem.eql(u8, name, "unique")) return generators.unique(allocator, value, args);
    if (std.mem.eql(u8, name, "batch")) return generators.batch(allocator, value, args);
    if (std.mem.eql(u8, name, "slice")) return generators.slice(allocator, value, args);
    if (try @import("expression_aggregate_filters.zig").callWithHost(allocator, name, value, args, host)) |result| return result;
    if (std.mem.eql(u8, name, "sort")) {
        const bound = try @import("filter_arguments.zig").bind(allocator, args, &.{ "reverse", "case_sensitive", "attribute" }, &.{ .{ .boolean = false }, .{ .boolean = false }, .none }, 0);
        const case_sensitive = bound[1].truthy();
        const attribute = bound[2];
        const attributes = @import("filter_attributes.zig");
        var paths: std.ArrayList([]const Value) = .empty;
        if (attribute == .string) {
            var parts = std.mem.splitScalar(u8, attribute.string, ',');
            while (parts.next()) |part| try paths.append(allocator, try attributes.parts(allocator, .{ .string = part }));
        } else try paths.append(allocator, try attributes.parts(allocator, attribute));
        const values = try iterableValuesWithHost(allocator, value, host);
        const Item = struct { value: Value, key: Value };
        var items: std.ArrayList(Item) = .empty;
        for (values) |v| {
            var fields: std.ArrayList(Value) = .empty;
            for (paths.items) |path| {
                var field = try attributes.get(allocator, v, path, .none, host);
                if (!case_sensitive and field == .string) field = .{ .string = try unicode.convert(allocator, field.string, .lower) };
                try fields.append(allocator, field);
            }
            try items.append(allocator, .{ .value = v, .key = .{ .list = try fields.toOwnedSlice(allocator) } });
        }
        const reverse = bound[0].truthy();
        var failure: ?anyerror = null;
        const Context = struct {
            descending: bool,
            allocator: std.mem.Allocator,
            failure: *?anyerror,
            fn less(context: @This(), a: Item, b: Item) bool {
                const order = valueOrder(context.allocator, a.key, b.key) catch |err| {
                    if (err != error.UnorderedJinjaNumber) context.failure.* = err;
                    return false;
                };
                return if (context.descending) order == .gt else order == .lt;
            }
        };
        std.sort.block(Item, items.items, Context{ .descending = reverse, .allocator = allocator, .failure = &failure }, Context.less);
        if (failure) |err| return err;
        const result = try allocateValues(allocator, items.items.len);
        for (items.items, result) |item, *v| v.* = item.value;
        return .{ .list = result };
    }
    if (std.mem.eql(u8, name, "reverse")) {
        if (value == .string) return sliceValue(allocator, value, null, null, .{ .integer = "-1" });
        const values = try allocator.dupe(Value, try iterableValuesWithHost(allocator, value, host));
        std.mem.reverse(Value, values);
        return sequences.iterator(allocator, values);
    }
    if (std.mem.eql(u8, name, "as_text")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        return .{ .string = try value.text(allocator) };
    }
    if (std.mem.eql(u8, name, "as_native") or std.mem.eql(u8, name, "as_bool") or std.mem.eql(u8, name, "as_number")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        const converted = if (value == .string) blk: {
            const text_value = std.mem.trim(u8, value.string, " \t\r\n");
            if (std.mem.eql(u8, text_value, "true") or std.mem.eql(u8, text_value, "false") or std.mem.eql(u8, text_value, "none") or std.mem.eql(u8, text_value, "null")) break :blk value;
            break :blk evaluate(allocator, text_value, null) catch value;
        } else value;
        if (std.mem.eql(u8, name, "as_bool") and converted != .boolean) return error.JinjaTypeError;
        if (std.mem.eql(u8, name, "as_number") and floatProtocol(converted) == null and converted != .integer and complexProtocol(converted) == null) return error.JinjaTypeError;
        return if (converted == .undefined) value else converted;
    }
    if (std.mem.eql(u8, name, "default") or std.mem.eql(u8, name, "d")) {
        const bound = try @import("filter_arguments.zig").bind(allocator, args, &.{ "default_value", "boolean" }, &.{ .{ .string = "" }, .{ .boolean = false } }, 0);
        return if (isUndefined(value) or (bound[1].truthy() and !value.truthy())) bound[0] else value;
    }
    if (std.mem.eql(u8, name, "length") or std.mem.eql(u8, name, "count")) return try lengthWithHost(allocator, value, host);
    if (std.mem.eql(u8, name, "string")) return .{ .string = try textWithHost(allocator, value, host) };
    if (std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "float")) {
        if (isUndefined(value)) return error.UndefinedJinjaValue;
        if (std.mem.eql(u8, name, "int")) {
            const bound = try @import("filter_arguments.zig").bind(allocator, args, &.{ "default", "base" }, &.{ .{ .integer = "0" }, .{ .integer = "10" } }, 0);
            const fallback = bound[0];
            if (integerText(value)) |number| return .{ .integer = number };
            if (value == .string) {
                const text = try unicode.strip(value.string, null, true, true);
                const base = integerIndex(bound[1]) catch return fallback;
                if (base == 0 or (base >= 2 and base <= 36)) {
                    const converted = integerFromString(allocator, text, @intCast(base)) catch null;
                    if (converted) |number| return .{ .integer = number };
                }
                const floating = std.fmt.parseFloat(f64, text) catch return fallback;
                return .{ .integer = numbers.floatToInteger(allocator, floating) catch return fallback };
            }
            if (floatProtocol(value)) |number| return .{ .integer = try numbers.floatToInteger(allocator, number) };
            return fallback;
        }
        const bound = try @import("filter_arguments.zig").bind(allocator, args, &.{"default"}, &.{.{ .number = 0.0 }}, 0);
        const fallback = bound[0];
        if (value == .string) return try floatValue(allocator, std.fmt.parseFloat(f64, try unicode.strip(value.string, null, true, true)) catch return fallback);
        if (floatProtocol(value) != null) return value;
        return try floatValue(allocator, numeric(value) catch |err| {
            if (err == error.JinjaNumericOverflow) return err;
            return fallback;
        });
    }
    if (std.mem.eql(u8, name, "upper") or std.mem.eql(u8, name, "lower")) return .{ .string = try unicode.convert(allocator, try value.text(allocator), if (std.mem.eql(u8, name, "upper")) .upper else .lower) };
    if (std.mem.eql(u8, name, "trim")) {
        const bound = try @import("filter_arguments.zig").bind(allocator, args, &.{"chars"}, &.{.none}, 0);
        if (bound[0] != .string and bound[0] != .none) return error.JinjaTypeError;
        return .{ .string = try unicode.strip(try value.text(allocator), if (bound[0] == .string) bound[0].string else null, true, true) };
    }
    if (std.mem.eql(u8, name, "replace")) {
        const bound = try @import("filter_arguments.zig").bind(allocator, args, &.{ "old", "new", "count" }, &.{ .undefined, .undefined, .none }, 2);
        const text = Value{ .string = try value.text(allocator) };
        const method_args = [_]Argument{
            .{ .value = .{ .string = try bound[0].text(allocator) } },
            .{ .value = .{ .string = try bound[1].text(allocator) } },
            .{ .value = if (bound[2] == .none) .{ .integer = "-1" } else bound[2] },
        };
        return (try pureMethod(allocator, text, "replace", &method_args, host)) orelse error.UnsupportedJinjaFilter;
    }
    if (std.mem.eql(u8, name, "first") or std.mem.eql(u8, name, "last")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        if (std.mem.eql(u8, name, "first")) return (try sequences.next(allocator, try sequences.iter(allocator, value), host)) orelse .undefined;
        const length: usize = switch (value) {
            .list, .tuple => |v| v.len,
            .string => |v| try unicode.count(v),
            else => return error.JinjaTypeError,
        };
        if (length == 0) return .undefined;
        return try indexValue(allocator, value, .{ .integer = if (std.mem.eql(u8, name, "first")) "0" else "-1" });
    }
    if (std.mem.eql(u8, name, "list")) {
        return .{ .list = try iterableValuesWithHost(allocator, value, host) };
    }
    return error.UnsupportedJinjaFilter;
}

test "typed expressions preserve precedence, containers, filters and short circuit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("14", (try evaluate(a, "2 + 3 * 4", null)).integer);
    try std.testing.expect((try evaluate(a, "not false and 3 >= 2 and 'x' in ['x', 'y']", null)).boolean);
    try std.testing.expectEqualStrings("A-B", (try evaluate(a, "['a', 'b'] | join('-') | upper", null)).string);
    try std.testing.expectEqualStrings("last", (try evaluate(a, "['first','last'][-1]", null)).string);
    try std.testing.expectEqualStrings("2", (try evaluate(a, "{'x': [1,2]}['x'] | length", null)).integer);
    try std.testing.expect(!(try evaluate(a, "false and missing_call()", null)).truthy());
    try std.testing.expectEqualStrings("fallback", (try evaluate(a, "missing | default('fallback')", null)).string);
    try std.testing.expectError(error.JinjaDivisionByZero, evaluate(a, "3/0", null));
    try std.testing.expectError(error.InvalidJinjaExpression, evaluate(a, "[1,", null));
}

test "typed Jinja calls expand positional lists and keyword maps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try evaluateArguments(allocator, "*[1,2], **{'strategy':'timestamp','enabled':true}", null);
    try std.testing.expectEqual(@as(usize, 4), args.len);
    try std.testing.expectEqualStrings("2", args[1].value.integer);
    try std.testing.expectEqualStrings("strategy", args[2].name.?);
    try std.testing.expect(args[3].value.boolean);
    try std.testing.expectError(error.InvalidJinjaArguments, evaluateArguments(allocator, "a=1, **{'a':2}", null));
    try std.testing.expectError(error.InvalidJinjaArguments, evaluateArguments(allocator, "**[1,2]", null));
    try std.testing.expect(!(try evaluate(allocator, "false and missing_call(**unknown)", null)).truthy());
}

test "collection expressions preserve ordering, missing values and lazy branches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("['a', 'b']", try (try evaluate(a, "['A','B'] | map('lower') | list", null)).text(a));
    try std.testing.expectEqualStrings("[1, 9]", try (try evaluate(a, "[{'x':1},{}] | map(attribute='x', default=9) | list", null)).text(a));
    try std.testing.expectEqualStrings("[3, 1]", try (try evaluate(a, "[1,2,3] | select('odd') | reverse | list", null)).text(a));
    try std.testing.expectEqualStrings("[2, 3]", try (try evaluate(a, "[3,1,2] | sort | reject('equalto', 1) | list", null)).text(a));
    try std.testing.expectEqualStrings("[0, 2, 4]", try (try evaluate(a, "[0,1,2,3,4][::2]", null)).text(a));
    try std.testing.expectEqualStrings("[3, 2, 1]", try (try evaluate(a, "[0,1,2,3,4][-2:0:-1]", null)).text(a));
    try std.testing.expectEqualStrings("好é", (try evaluate(a, "'aé好'[1:][::-1]", null)).string);
    try std.testing.expectEqualStrings("chosen", (try evaluate(a, "1 / 0 if false else 'chosen'", null)).string);
    try std.testing.expectEqualStrings("chosen", (try evaluate(a, "'chosen' if true else 1 / 0", null)).string);
    try std.testing.expect((try evaluate(a, "{} is mapping and [1,2] is sequence and 3 is odd", null)).boolean);
    try std.testing.expectError(error.InvalidJinjaArguments, evaluate(a, "[1,2][::0]", null));
    try std.testing.expectError(error.JinjaTypeError, evaluate(a, "[1,'a'] | sort", null));
}

test "sequences order lexicographically and extrema retain the first tied row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try evaluate(a, "[1,[2,3]] < [1,[2,4]]", null)).boolean);
    try std.testing.expect((try evaluate(a, "[] < [none]", null)).boolean);
    try std.testing.expectEqualStrings("[(1,), (1, 2), (2,)]", try (try evaluate(a, "[(2,),(1,2),(1,)]|sort", null)).text(a));
    try std.testing.expectEqualStrings("first", (try evaluate(a, "([{'n':1,'v':'first'},{'n':1,'v':'last'}]|max(attribute='n')).v", null)).string);
    try std.testing.expectEqualStrings("[(0, 0)]", try (try evaluate(a, "[[(0,0),(1,none),(1,2)]|min]", null)).text(a));
    try std.testing.expectError(error.JinjaTypeError, evaluate(a, "[(0,0),(1,none),(1,2)]|sort", null));
    try std.testing.expectError(error.JinjaTypeError, evaluate(a, "[] < ()", null));
}

// Jinja's parse_pow loop is deliberately left associative and binds below
// unary signs; matching Python's different exponent precedence changes macros.
test "power follows Core Jinja precedence, associativity and lazy evaluation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("64", (try evaluate(a, "2 ** 3 ** 2", null)).integer);
    try std.testing.expectEqualStrings("4", (try evaluate(a, "-2 ** 2", null)).integer);
    try std.testing.expectEqualStrings("24", (try evaluate(a, "3 * 2 ** 3", null)).integer);
    try std.testing.expectEqual(@as(f64, 0.5), (try evaluate(a, "2 ** -1", null)).number);
    try std.testing.expect(!(try evaluate(a, "false and 0 ** -1", null)).truthy());
    try std.testing.expectError(error.JinjaDivisionByZero, evaluate(a, "0 ** -1", null));
}

test "chained comparisons retain adjacent operands and skip later effects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try evaluate(a, "3 > 2 > 1", null)).truthy());
    try std.testing.expect(!(try evaluate(a, "3 > 2 < 1", null)).truthy());
    try std.testing.expect(!(try evaluate(a, "1 > 2 > (1 / 0)", null)).truthy());
    try std.testing.expect((try evaluate(a, "1 not   in [2,3]", null)).truthy());
}

test "integer and float identities, tuples and consuming zip remain typed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("9007199254740994", try (try evaluate(a, "9007199254740993 + 1", null)).text(a));
    try std.testing.expect(!(try evaluate(a, "9007199254740993 == 9007199254740992.0", null)).boolean);
    try std.testing.expect((try evaluate(a, "1 == 1.0 and true == 1", null)).boolean);
    try std.testing.expectEqualStrings("1.0", try (try evaluate(a, "1.0", null)).text(a));
    try std.testing.expectEqualStrings("-0.0", try (try evaluate(a, "-0.0", null)).text(a));
    try std.testing.expectEqualStrings("('x',)", try (try evaluate(a, "('x',)", null)).text(a));
    try std.testing.expectEqualStrings("[(1, 3), (2, 4)]", try (try evaluate(a, "zip([1,2],[3,4]) | list", null)).text(a));
    try std.testing.expectEqualStrings("dict_items([('a', 1)])", try (try evaluate(a, "{'a':1}.items()", null)).text(a));
    try std.testing.expectError(error.JinjaTypeError, evaluate(a, "'x'|indent(4.0)", null));
    try std.testing.expectEqualStrings("2", try (try evaluate(a, "1 + 2 is even", null)).text(a));
    const iterator = try sequences.zip(a, &.{.{ .list = &.{.{ .integer = "1" }} }});
    try std.testing.expectEqual(@as(usize, 1), (try iterableValues(a, iterator)).len);
    try std.testing.expectEqual(@as(usize, 0), (try iterableValues(a, iterator)).len);
}

test "omitted conditional alternatives preserve Jinja plain Undefined" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const missing = try evaluate(a, "'x' if false", null);
    try std.testing.expect(missing == .ordinary_undefined);
    try std.testing.expectEqualStrings("", try missing.text(a));
    try std.testing.expect((try evaluate(a, "('x' if false) is undefined", null)).boolean);
    try std.testing.expectEqualStrings("fallback", try (try evaluate(a, "('x' if false)|default('fallback')", null)).text(a));
    try std.testing.expectEqualStrings("0", (try evaluate(a, "('x' if false)|length", null)).integer);
    try std.testing.expectEqualStrings("", try (try evaluate(a, "authored_missing", null)).text(a));
}

test "ordinary undefined renders and iterates but rejects attribute arithmetic and calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("", try (try evaluate(a, "missing", null)).text(a));
    try std.testing.expectEqualStrings("0", (try evaluate(a, "missing|length", null)).integer);
    try std.testing.expectEqualStrings("[]", try (try evaluate(a, "missing|list", null)).text(a));
    try std.testing.expectEqualStrings("Undefined", try repr(.undefined, a));
    try std.testing.expect((try evaluate(a, "missing is callable and missing is iterable and missing is sequence", null)).boolean);
    try std.testing.expect(equalValues(.undefined, .conditional_undefined));
    const bound = try evaluate(a, "missing", null);
    try std.testing.expect(try testValue("sameas", bound, &.{.{ .value = bound }}));
    try std.testing.expect(!try testValue("sameas", bound, &.{.{ .value = try evaluate(a, "missing", null) }}));
    try std.testing.expectEqualStrings("", try (try evaluate(a, "missing.__class__", null)).text(a));
    try std.testing.expectError(error.UndefinedJinjaValue, evaluate(a, "missing.field", null));
    try std.testing.expectError(error.UndefinedJinjaValue, evaluate(a, "missing|attr('field')", null));
    try std.testing.expectError(error.UndefinedJinjaValue, evaluate(a, "missing + 1", null));
    try std.testing.expectError(error.UndefinedJinjaValue, evaluate(a, "+missing", null));
    try std.testing.expectError(error.UndefinedJinjaValue, evaluate(a, "missing[:2]", null));
    try std.testing.expectError(error.UndefinedJinjaValue, evaluate(a, "(missing)()", null));
    try std.testing.expectError(error.JinjaTypeError, evaluate(a, "none|list", null));
}

test "named tests accept conventional unparenthesized primary and postfix arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try evaluate(a, "1 is equalto 1", null)).boolean);
    try std.testing.expect((try evaluate(a, "1 is not equalto 2", null)).boolean);
    try std.testing.expect((try evaluate(a, "'x' is in ['x']", null)).boolean);
    try std.testing.expect((try evaluate(a, "'x' is equalto 'X'.lower()", null)).boolean);
    try std.testing.expect((try evaluate(a, "2 is divisibleby 2 and 2 is even", null)).boolean);
    try std.testing.expectEqualStrings("2", (try evaluate(a, "1 is equalto 1 + 1", null)).integer);
    try std.testing.expectError(error.InvalidJinjaExpression, evaluate(a, "1 is odd is boolean", null));
    try std.testing.expectError(error.InvalidJinjaArguments, evaluate(a, "1 is defined 2", null));
    try std.testing.expectError(error.InvalidJinjaArguments, evaluate(a, "1 is eq(other=1)", null));
}

test "parse undefined captures mutable alias names and stable subscript call identity" {
    const Fixture = struct {
        fn resolve(_: *anyopaque, _: []const u8, _: std.mem.Allocator) !Value {
            return .undefined;
        }
        fn call(_: *anyopaque, name: []const u8, _: []const Argument, a: std.mem.Allocator) !Value {
            return callUndefined(try captureUndefined(a, name));
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var context: u8 = 0;
    const host = Host{ .context = &context, .resolve = Fixture.resolve, .call = Fixture.call, .capture_undefined = true };
    const original = try captureUndefined(a, "missing");
    const child = try checkedAttribute(original, "field");
    try std.testing.expectEqualStrings("field", original.capture_undefined.name.?);
    try std.testing.expectEqualStrings("field", child.capture_undefined.name.?);
    try std.testing.expect(original.capture_undefined.identity != child.capture_undefined.identity);
    try std.testing.expect(equalValues(original, child));
    try std.testing.expect(!equalValues(original, .undefined));
    try std.testing.expectEqualStrings("field", (try evaluate(a, "missing.field.name", host)).string);
    try std.testing.expectEqualStrings("missing", (try evaluate(a, "(missing)[1].name", host)).string);
    try std.testing.expectEqualStrings("missing", (try evaluate(a, "(missing)[:2].name", host)).string);
    try std.testing.expectEqualStrings("jinja_pass_arg", (try evaluate(a, "(missing)().name", host)).string);
    try std.testing.expectEqualStrings("jinja_pass_arg", (try evaluate(a, "missing().name", host)).string);
    try std.testing.expectEqualStrings("jinja_pass_arg", (try evaluate(a, "missing.field.call().name", host)).string);
    try std.testing.expectEqualStrings("", try (try evaluate(a, "missing.field.call()", host)).text(a));
    try std.testing.expectError(error.UndefinedJinjaValue, evaluate(a, "missing + 1", host));
    try std.testing.expect(isUndefined(try checkedAttribute(original, "__reduce__")));
    try std.testing.expectEqualStrings("missing", (try evaluate(a, "missing.__unknown__.name", host)).string);
    try std.testing.expectEqualStrings("__class__", (try evaluate(a, "missing.__class__.name", host)).string);
    try std.testing.expectEqualStrings("field", (try evaluate(a, "(missing|attr('field')).name", host)).string);
    try std.testing.expectEqualStrings("__unknown__", (try evaluate(a, "(missing|attr('__unknown__')).name", host)).string);
}

test "set expressions preserve aliases comparisons iteration and typed map conversion" {
    const Fixture = struct {
        left: Value,
        right: Value,
        pairs: Value,
        fn resolve(context: *anyopaque, name: []const u8, _: std.mem.Allocator) !Value {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, name, "left")) return self.left;
            if (std.mem.eql(u8, name, "right")) return self.right;
            if (std.mem.eql(u8, name, "pairs")) return self.pairs;
            return .undefined;
        }
        fn call(_: *anyopaque, name: []const u8, _: []const Argument, _: std.mem.Allocator) !Value {
            if (std.mem.eql(u8, name, "zip")) return .{ .string = "host zip" };
            return error.UnsupportedJinjaCall;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var context = Fixture{
        .left = try sets.construct(a, try evaluate(a, "[1,2,1.0]", null)),
        .right = try sets.construct(a, try evaluate(a, "[2,3]", null)),
        .pairs = try sets.construct(a, try evaluate(a, "[(1,'one'),(2,'two')]", null)),
    };
    const host = Host{ .context = &context, .resolve = Fixture.resolve, .call = Fixture.call };
    const alias = context.left;
    try std.testing.expect((try evaluate(a, "1.0 in left", host)).boolean);
    try std.testing.expect(!(try evaluate(a, "left is mapping or left is sequence or left is callable", host)).boolean);
    try std.testing.expect((try evaluate(a, "left is iterable", host)).boolean);
    try std.testing.expectEqualStrings("[1, 2, 3]", try (try evaluate(a, "left.union(right)|list|sort", host)).text(a));
    try std.testing.expectEqualStrings("[1]", try (try evaluate(a, "(left - right)|list", host)).text(a));
    try std.testing.expect((try evaluate(a, "left < left.union(right)", host)).boolean);
    try std.testing.expect((try evaluate(a, "left == left.copy()", host)).boolean);
    try std.testing.expectEqualStrings("{1: 'one', 2: 'two'}", try (try evaluate(a, "dict(pairs)", host)).text(a));
    try std.testing.expectEqualStrings("missing", try (try evaluate(a, "left[0]|default('missing')", host)).text(a));
    try std.testing.expectError(error.JinjaTypeError, evaluate(a, "left[:1]", host));
    try std.testing.expectError(error.UndefinedJinjaValue, evaluate(a, "left.keys()", host));
    _ = try evaluate(a, "left.add(3)", host);
    try std.testing.expect(try sets.contains(alias, .{ .number = 3.0 }));
    _ = try evaluate(a, "left.clear()", host);
    try std.testing.expect(!alias.truthy());
    try std.testing.expectEqualStrings("set()", try alias.text(a));
    try std.testing.expectEqualStrings("host zip", (try evaluate(a, "zip([], default=[])", host)).string);
    try std.testing.expectEqualStrings("[]", try (try evaluate(a, "zip(missing)|list", null)).text(a));
}

test "immutable YAML scalars use native bytes and timestamp expression protocols" {
    const Fixture = struct {
        entries: []const Entry,
        fn resolve(context: *anyopaque, name: []const u8, _: std.mem.Allocator) !Value {
            const self: *@This() = @ptrCast(@alignCast(context));
            return (Value{ .object = self.entries }).attribute(name);
        }
        fn call(_: *anyopaque, _: []const u8, _: []const Argument, _: std.mem.Allocator) !Value {
            return error.UnsupportedJinjaCall;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dates = @import("timestamp_context.zig");
    var context = Fixture{ .entries = &.{
        .{ .key = "bytes", .value = try yaml_values.fromBytes(a, "Hello") },
        .{ .key = "same", .value = try yaml_values.fromBytes(a, "Hello") },
        .{ .key = "part", .value = try yaml_values.fromBytes(a, "ell") },
        .{ .key = "utc", .value = try dates.fromYaml(a, "2020-01-02T03:00:00Z") },
        .{ .key = "offset", .value = try dates.fromYaml(a, "2020-01-02T04:00:00+01:00") },
        .{ .key = "later", .value = try dates.fromYaml(a, "2020-01-02T04:01:00+01:00") },
        .{ .key = "naive", .value = try dates.fromYaml(a, "2020-01-02T03:00:00") },
        .{ .key = "date", .value = try dates.fromYaml(a, "2020-01-02") },
    } };
    const host = Host{ .context = &context, .resolve = Fixture.resolve, .call = Fixture.call };
    try std.testing.expectEqualStrings("111", (try evaluate(a, "bytes[-1]", host)).integer);
    try std.testing.expectEqualStrings("b'ell'", try (try evaluate(a, "bytes[1:4]", host)).text(a));
    try std.testing.expectEqualStrings("b'olleH'", try (try evaluate(a, "bytes[::-1]", host)).text(a));
    try std.testing.expectEqualStrings("b'Helloell'", try (try evaluate(a, "bytes+part", host)).text(a));
    try std.testing.expectEqualStrings("b'HelloHello'", try (try evaluate(a, "2*bytes", host)).text(a));
    try std.testing.expect((try evaluate(a, "101 in bytes and part in bytes and bytes == same and bytes != 'Hello'", host)).boolean);
    try std.testing.expect((try evaluate(a, "utc == offset and utc < later and utc != naive and date != naive", host)).boolean);
    try std.testing.expectEqualStrings("[b'Hello', b'ell']", try (try evaluate(a, "[part,bytes]|sort", host)).text(a));
    try std.testing.expectEqualStrings("2020-01-02 03:00:00+00:00", try (try evaluate(a, "[later,utc]|min", host)).text(a));
    try std.testing.expectEqualStrings("1", (try evaluate(a, "[utc,offset]|unique|list|length", host)).integer);
    try std.testing.expectError(error.JinjaTypeError, evaluate(a, "bytes+'x'", host));
    try std.testing.expectError(error.JinjaTypeError, evaluate(a, "bytes*2.0", host));
    try std.testing.expectError(error.JinjaValueError, evaluate(a, "256 in bytes", host));
    try std.testing.expectError(error.JinjaTypeError, evaluate(a, "utc < naive", host));
    try std.testing.expectError(error.JinjaTypeError, evaluate(a, "date < naive", host));
}

test "typed lazy attributes dispatch through the consuming host and preserve indexed aliases" {
    const Fixture = struct {
        calls: usize = 0,
        value: Value,
        fn resolve(context: *anyopaque, name: []const u8, _: std.mem.Allocator) !Value {
            const self: *@This() = @ptrCast(@alignCast(context));
            return if (std.mem.eql(u8, name, "deferred")) self.value else .undefined;
        }
        fn call(context: *anyopaque, name: []const u8, args: []const Argument, a: std.mem.Allocator) !Value {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (!std.mem.eql(u8, name, "__dxt_loop_attribute:fixture") or args.len != 1 or args[0].value != .string) return error.UnsupportedJinjaCall;
            self.calls += 1;
            return if (std.mem.eql(u8, args[0].value.string, "length")) try integerValue(a, 3) else .undefined;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var context = Fixture{ .value = .{ .object = &.{.{ .key = "__dxt_getattr", .value = .{ .callable = "__dxt_loop_attribute:fixture" } }} } };
    const host = Host{ .context = &context, .resolve = Fixture.resolve, .call = Fixture.call };
    try std.testing.expectEqualStrings("3", (try evaluate(a, "[deferred][0].length", host)).integer);
    try std.testing.expectEqualStrings("3", (try evaluate(a, "deferred['length']", host)).integer);
    try std.testing.expectEqual(@as(usize, 2), context.calls);
    try std.testing.expectEqualStrings("9007199254740994", (try addValues(a, .{ .integer = "9007199254740993" }, .{ .integer = "1" })).integer);
}

test "pytz mapping proxies preserve Unicode lookup and public views" {
    const Fixture = struct {
        countries: Value,
        capturing: bool = false,
        fn resolve(context: *anyopaque, name: []const u8, a: std.mem.Allocator) !Value {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (std.mem.eql(u8, name, "countries")) return self.countries;
            return if (self.capturing) try captureUndefined(a, name) else .undefined;
        }
        fn call(_: *anyopaque, _: []const u8, _: []const Argument, _: std.mem.Allocator) !Value {
            return error.UnsupportedJinjaCall;
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var context = Fixture{ .countries = (try @import("timezone_context.zig").resolve(a, "modules.pytz.country_names")).? };
    const host = Host{ .context = &context, .resolve = Fixture.resolve, .call = Fixture.call };
    try std.testing.expectEqualStrings("United States", (try evaluate(a, "countries['uſ']", host)).string);
    try std.testing.expectEqualStrings("United States", (try evaluate(a, "countries.get('us')", host)).string);
    try std.testing.expectEqualStrings("249", (try evaluate(a, "countries|length", host)).integer);
    try std.testing.expect((try evaluate(a, "'US' in countries and 'us' not in countries and 1 not in countries", host)).boolean);
    try std.testing.expect((try evaluate(a, "countries is mapping and countries is sequence and countries is iterable", host)).boolean);
    try std.testing.expectEqualStrings("249", (try evaluate(a, "countries.keys()|list|length", host)).integer);
    try std.testing.expectError(error.InvalidCountryCode, evaluate(a, "countries[1]", host));
    try std.testing.expectError(error.UndefinedJinjaValue, evaluate(a, "countries.copy()", host));
    context.capturing = true;
    var parse_host = host;
    parse_host.capture_undefined = true;
    try std.testing.expectError(error.InvalidCountryCode, evaluate(a, "countries.get(1)", parse_host));
    try std.testing.expect((try evaluate(a, "countries.copy()", parse_host)) == .capture_undefined);
}

test "immutable timezone and class equality preserve cached identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pytz = @import("timezone_context.zig");
    const one = (try pytz.resolve(a, "modules.pytz.utc")).?;
    const two = (try pytz.resolve(a, "modules.pytz.utc")).?;
    try std.testing.expect(equalValues(one, two));
    try std.testing.expect(try testValue("sameas", one, &.{.{ .value = two }}));
    const kind = @import("modules_datetime.zig");
    const cls = (try kind.resolve(a, "modules.datetime.date")).?;
    const other = (try kind.resolve(a, "modules.datetime.date")).?;
    try std.testing.expect(equalValues(cls, other));
    try std.testing.expect(try testValue("sameas", cls, &.{.{ .value = other }}));
}

test "deferred repr uses current host through nested values" {
    const Fixture = struct {
        calls: usize = 0,
        fn resolve(_: *anyopaque, _: []const u8, _: std.mem.Allocator) !Value {
            return .undefined;
        }
        fn call(context: *anyopaque, name: []const u8, args: []const Argument, _: std.mem.Allocator) !Value {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (!std.mem.eql(u8, name, "loop_repr") or args.len != 0) return error.InvalidJinjaArguments;
            self.calls += 1;
            return .{ .string = "<LoopContext 1/3>" };
        }
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture = Fixture{};
    const host = Host{ .context = &fixture, .resolve = Fixture.resolve, .call = Fixture.call };
    const value = Value{ .object = &.{.{ .key = "__dxt_repr", .value = .{ .callable = "loop_repr" } }} };
    try std.testing.expectEqualStrings("<LoopContext 1/3>", try textWithHost(a, value, host));
    try std.testing.expectEqualStrings("[<LoopContext 1/3>]", try textWithHost(a, .{ .list = &.{value} }, host));
    try std.testing.expectEqualStrings("{'loop': <LoopContext 1/3>}", try textWithHost(a, .{ .object = &.{.{ .key = "loop", .value = value }} }, host));
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
}

test "authored reserved iterator keys remain ordinary mapping data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const value = try evaluate(a, "{'__dxt_sequence_kind':'itertools_count','__dxt_native_sequence':'__dxt_native_sequence'}", null);
    try std.testing.expect(sequences.kind(value) == null);
    try std.testing.expectEqual(@as(usize, 2), (try iterableValues(a, value)).len);
    const iterator = try sequences.iter(a, .{ .list = &.{.{ .integer = "1" }} });
    try std.testing.expect((try indexValue(a, iterator, .{ .string = "__dxt_native_sequence" })) == .undefined);
    try std.testing.expect((try checkedAttribute(iterator, "__dxt_native_sequence")) == .undefined);
    try std.testing.expect((try pureMethod(a, iterator, "items", &.{}, null)) == null);
}
