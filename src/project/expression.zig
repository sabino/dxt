const std = @import("std");
const numbers = @import("expression_number.zig");
const sequences = @import("expression_sequence.zig");
const unicode = @import("expression_unicode.zig");

/// Native Jinja expression values. Allocations belong to the caller's render
/// arena; values can cross macro returns without borrowing a temporary frame.
pub const Value = union(enum) {
    undefined,
    none,
    boolean: bool,
    integer: []const u8,
    number: f64,
    string: []const u8,
    list: []const Value,
    tuple: []const Value,
    object: []const Entry,
    callable: []const u8,

    pub fn truthy(self: Value) bool {
        if (sequences.truthy(self)) |result| return result;
        if (self == .object) if (sequence(self)) |items| return items.len != 0;
        return switch (self) {
            .undefined, .none => false,
            .boolean => |v| v,
            .number => |v| v != 0,
            .integer => |v| !std.mem.eql(u8, v, "0"),
            .string => |v| v.len != 0,
            .list, .tuple => |v| v.len != 0,
            .object => |v| v.len != 0,
            .callable => true,
        };
    }

    pub fn text(self: Value, allocator: std.mem.Allocator) anyerror![]const u8 {
        return switch (self) {
            .undefined => error.UndefinedJinjaValue,
            .callable => error.JinjaTypeError,
            .none => "None",
            .boolean => |v| if (v) "True" else "False",
            .integer => |v| v,
            .number => |v| try numbers.floatText(allocator, v),
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
                if (try sequences.text(allocator, self)) |rendered| break :blk rendered;
                // Adapter relation objects retain typed attributes for package
                // macros while their string conversion is the SQL identity.
                for (entries) |entry| if (std.mem.eql(u8, entry.key, "__dxt_rendered") and entry.value == .string) break :blk entry.value.string;
                var out: std.ArrayList(u8) = .empty;
                try out.append(allocator, '{');
                for (entries, 0..) |entry, i| {
                    if (i != 0) try out.appendSlice(allocator, ", ");
                    try out.appendSlice(allocator, try repr(.{ .string = entry.key }, allocator));
                    try out.appendSlice(allocator, ": ");
                    try out.appendSlice(allocator, try repr(entry.value, allocator));
                }
                try out.append(allocator, '}');
                break :blk try out.toOwnedSlice(allocator);
            },
        };
    }

    pub fn attribute(self: Value, name: []const u8) Value {
        return switch (self) {
            .object => |entries| blk: {
                for (entries) |entry| if (std.mem.eql(u8, name, entry.key)) break :blk entry.value;
                break :blk .undefined;
            },
            else => .undefined,
        };
    }
};

pub const Entry = struct { key: []const u8, value: Value };
pub const Argument = struct { name: ?[]const u8 = null, value: Value };
pub const Host = struct {
    context: *anyopaque,
    resolve: *const fn (*anyopaque, []const u8, std.mem.Allocator) anyerror!Value,
    call: *const fn (*anyopaque, []const u8, []const Argument, std.mem.Allocator) anyerror!Value,
    // Compiler hosts can preserve the current resource across nested renders
    // without coupling this generic expression module to project Node types.
    set_node: ?*const fn (*anyopaque, ?*const anyopaque) ?*const anyopaque = null,
};

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

pub fn integerIndex(value: Value) !i64 {
    return switch (value) {
        .integer => |number| std.fmt.parseInt(i64, number, 10) catch return error.JinjaIndexError,
        .boolean => |number| @intFromBool(number),
        else => error.JinjaTypeError,
    };
}

pub fn numericFloat(value: Value) !f64 {
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
    if (value == .string) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try @import("native_repr.zig").string(&out.writer, value.string);
        return out.toOwnedSlice();
    }
    return value.text(allocator);
}

pub fn evaluate(allocator: std.mem.Allocator, input: []const u8, host: ?Host) !Value {
    if (topLevelKeyword(input, "if")) |condition_at| {
        const remainder = input[condition_at + 2 ..];
        const else_at = topLevelKeyword(remainder, "else");
        const condition = try evaluate(allocator, remainder[0 .. else_at orelse remainder.len], host);
        if (condition.truthy()) return try evaluate(allocator, input[0..condition_at], host);
        return if (else_at) |position| try evaluate(allocator, remainder[position + 4 ..], host) else .undefined;
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
                const result = if (self.active) try testValue(test_name, lhs, args) else false;
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
                    if (self.active and matched) matched = (try apply(self.allocator, comparison, previous, right)).truthy();
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
            const short = (std.mem.eql(u8, operator, "and") and !lhs.truthy()) or (std.mem.eql(u8, operator, "or") and lhs.truthy());
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
                lhs = try apply(self.allocator, operator, lhs, rhs);
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
        if (self.take("not")) return .{ .boolean = !(try self.binary(3)).truthy() };
        if (self.take("-")) {
            const value = try self.unary();
            if (!self.active) return .none;
            if (integerText(value)) |number| return .{ .integer = try numbers.negate(self.allocator, number) };
            return .{ .number = -(try numeric(value)) };
        }
        if (self.take("+")) {
            const value = try self.unary();
            if (!self.active) return .none;
            if (value == .boolean) return try integerValue(self.allocator, @as(u8, @intFromBool(value.boolean)));
            if (value != .integer and value != .number) return error.JinjaTypeError;
            return value;
        }
        var value = try self.atom();
        while (true) {
            if (self.take("(")) {
                const args = try self.arguments();
                if (self.active) {
                    if (value != .callable) return error.JinjaTypeError;
                    const host = self.host orelse return error.UnsupportedJinjaCall;
                    value = try host.call(host.context, value.callable, args, self.allocator);
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
                    if (self.active) value = try indexValue(self.allocator, value, start.?);
                }
            } else if (self.take(".")) {
                const attribute = try self.name();
                if (self.take("(")) {
                    const args = try self.arguments();
                    if (self.active) value = try self.method(value, attribute, args);
                } else if (self.active) value = value.attribute(attribute);
            } else if (self.take("is")) {
                const negate = self.take("not");
                const test_name = try self.name();
                const args = if (self.take("(")) try self.arguments() else &.{};
                if (self.active) {
                    const result = try testValue(test_name, value, args);
                    value = .{ .boolean = if (negate) !result else result };
                }
            } else if (self.take("|")) {
                const filter_name = try self.name();
                const args = if (self.take("(")) try self.arguments() else &.{};
                if (self.active) value = try filter(self.allocator, filter_name, value, args);
            } else break;
        }
        return value;
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
                    try out.append(self.allocator, switch (escaped) {
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        else => escaped,
                    });
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
            return .{ .number = std.fmt.parseFloat(f64, literal) catch return error.InvalidJinjaExpression };
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
                if (key != .string) return error.InvalidJinjaExpression;
                try self.expect(":");
                try entries.append(self.allocator, .{ .key = key.string, .value = try self.binary(0) });
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
            if (try builtin(self.allocator, path, args)) |value| return value;
            const host = self.host orelse return error.UnsupportedJinjaCall;
            if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| {
                const receiver = try host.resolve(host.context, path[0..dot], self.allocator);
                if (receiver == .object or receiver == .list or receiver == .tuple or receiver == .string) return try self.method(receiver, path[dot + 1 ..], args);
            }
            return try host.call(host.context, path, args, self.allocator);
        }
        if (!self.active) return .none;
        const host = self.host orelse return .undefined;
        return try host.resolve(host.context, path, self.allocator);
    }

    fn method(self: *Parser, receiver: Value, method_name: []const u8, args: []const Argument) !Value {
        const bound = receiver.attribute(method_name);
        if (bound == .callable) {
            const host = self.host orelse return error.UnsupportedJinjaCall;
            return try host.call(host.context, bound.callable, args, self.allocator);
        }
        if (try pureMethod(self.allocator, receiver, method_name, args)) |value| return value;
        const host = self.host orelse return error.UnsupportedJinjaCall;
        const arguments_with_receiver = try self.allocator.alloc(Argument, args.len + 1);
        arguments_with_receiver[0] = .{ .value = receiver };
        @memcpy(arguments_with_receiver[1..], args);
        return try host.call(host.context, try std.fmt.allocPrint(self.allocator, "__dxt_value.{s}", .{method_name}), arguments_with_receiver, self.allocator);
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
                        for (args.items) |arg| if (arg.name) |argument_name| {
                            if (std.mem.eql(u8, argument_name, entry.key)) return error.InvalidJinjaArguments;
                        };
                        try args.append(self.allocator, .{ .name = entry.key, .value = entry.value });
                    }
                }
                saw_keyword = true;
            } else if (self.take("*")) {
                const expanded = try self.binary(0);
                if (saw_keyword) return error.InvalidJinjaArguments;
                if (self.active) {
                    const items = try iterableValues(self.allocator, expanded);
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

fn pureMethod(allocator: std.mem.Allocator, receiver: Value, name_: []const u8, args: []const Argument) !?Value {
    const positional_only = if (receiver == .object) isMethod(name_, &.{ "get", "keys", "values", "items", "copy" }) else if (receiver == .list) isMethod(name_, &.{ "copy", "count", "index" }) else if (receiver == .string) isMethod(name_, &.{ "lower", "upper", "startswith", "endswith", "find", "rfind", "count", "index", "rindex", "strip", "lstrip", "rstrip", "join", "replace" }) else false;
    if (positional_only) for (args) |arg| if (arg.name != null) return error.InvalidJinjaArguments;
    if (receiver == .object) {
        if (std.mem.eql(u8, name_, "get")) {
            if (args.len < 1 or args.len > 2 or args[0].value != .string) return error.InvalidJinjaArguments;
            const value = receiver.attribute(args[0].value.string);
            return if (value != .undefined) value else if (args.len == 2) args[1].value else .none;
        }
        if (std.mem.eql(u8, name_, "keys") or std.mem.eql(u8, name_, "values") or std.mem.eql(u8, name_, "items")) {
            if (args.len != 0) return error.InvalidJinjaArguments;
            return try sequences.view(allocator, receiver, name_);
        }
        if (std.mem.eql(u8, name_, "copy")) {
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
            for (receiver_values) |value| if (equal(value, args[0].value)) {
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
            for (receiver_values[@intCast(start)..@intCast(@max(start, stop))], @as(usize, @intCast(start))..) |value, index| if (equal(value, args[0].value)) return try integerValue(allocator, index);
            return error.JinjaValueNotFound;
        }
    }
    if (receiver == .string) {
        const text_ = receiver.string;
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
            const values = try iterableValues(allocator, args[0].value);
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
                while (true) {
                    if (backwards) {
                        while (position > 0 and std.ascii.isWhitespace(text_[position - 1])) position -= 1;
                        if (position == 0) break;
                        if (maximum >= 0 and count >= maximum) {
                            try values.append(allocator, .{ .string = text_[0..position] });
                            break;
                        }
                        const finish = position;
                        while (position > 0 and !std.ascii.isWhitespace(text_[position - 1])) position -= 1;
                        try values.append(allocator, .{ .string = text_[position..finish] });
                    } else {
                        while (position < text_.len and std.ascii.isWhitespace(text_[position])) position += 1;
                        if (position == text_.len) break;
                        if (maximum >= 0 and count >= maximum) {
                            try values.append(allocator, .{ .string = text_[position..] });
                            break;
                        }
                        const start = position;
                        while (position < text_.len and !std.ascii.isWhitespace(text_[position])) position += 1;
                        try values.append(allocator, .{ .string = text_[start..position] });
                    }
                    count += 1;
                }
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
fn integerText(v: Value) ?[]const u8 {
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
fn equal(a: Value, b: Value) bool {
    return equalValues(a, b);
}
pub fn equalValues(a: Value, b: Value) bool {
    if ((a == .integer or a == .number or a == .boolean) and (b == .integer or b == .number or b == .boolean)) return (numericOrder(std.heap.page_allocator, a, b) catch return false) == .eq;
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .undefined, .none => true,
        .string => |s| std.mem.eql(u8, s, b.string),
        .number => |n| n == b.number,
        .integer => |n| std.mem.eql(u8, n, b.integer),
        .boolean => |v| v == b.boolean,
        .callable => |v| std.mem.eql(u8, v, b.callable),
        .list, .tuple => |values| blk: {
            const other = sequence(b).?;
            if (values.len != other.len) break :blk false;
            for (values, other) |x, y| if (!equal(x, y)) break :blk false;
            break :blk true;
        },
        .object => |entries| blk: {
            if (entries.len != b.object.len) break :blk false;
            for (entries) |entry| if (!equal(entry.value, b.attribute(entry.key))) break :blk false;
            break :blk true;
        },
    };
}
fn contains(container: Value, item: Value) !bool {
    return switch (container) {
        .string => |s| if (item == .string) std.mem.indexOf(u8, s, item.string) != null else error.JinjaTypeError,
        .list, .tuple => |values| blk: {
            for (values) |v| if (equal(v, item)) break :blk true;
            break :blk false;
        },
        .object => if (item == .string) container.attribute(item.string) != .undefined else error.JinjaTypeError,
        else => error.JinjaTypeError,
    };
}
fn apply(allocator: std.mem.Allocator, op: []const u8, a: Value, b: Value) !Value {
    if (std.mem.eql(u8, op, "==")) return .{ .boolean = equal(a, b) };
    if (std.mem.eql(u8, op, "!=")) return .{ .boolean = !equal(a, b) };
    if (std.mem.eql(u8, op, "in")) return .{ .boolean = try contains(b, a) };
    if (std.mem.eql(u8, op, "not in")) return .{ .boolean = !(try contains(b, a)) };
    if (std.mem.eql(u8, op, "~") or (std.mem.eql(u8, op, "+") and a == .string and b == .string)) return .{ .string = try std.fmt.allocPrint(allocator, "{s}{s}", .{ try a.text(allocator), try b.text(allocator) }) };
    if (std.mem.eql(u8, op, "+") and a == .list and b == .list) return .{ .list = try std.mem.concat(allocator, Value, &.{ a.list, b.list }) };
    if (std.mem.eql(u8, op, "+") and a == .tuple and b == .tuple) return .{ .tuple = try std.mem.concat(allocator, Value, &.{ a.tuple, b.tuple }) };
    if (std.mem.indexOfScalar(u8, "<>", op[0]) != null) {
        const order: std.math.Order = if (a == .string and b == .string) std.mem.order(u8, a.string, b.string) else numericOrder(allocator, a, b) catch |err| {
            if (err == error.UnorderedJinjaNumber) return .{ .boolean = false };
            return err;
        };
        return .{ .boolean = if (std.mem.eql(u8, op, "<")) order == .lt else if (std.mem.eql(u8, op, ">")) order == .gt else if (std.mem.eql(u8, op, "<=")) order != .gt else order != .lt };
    }
    if (!std.mem.eql(u8, op, "/")) if (integerText(a)) |x| {
        if (integerText(b)) |y| {
            if (!std.mem.eql(u8, op, "**") or y[0] != '-') return .{ .integer = try numbers.apply(allocator, op, x, y) };
        }
    };
    const x = try numeric(a);
    const y = try numeric(b);
    if (std.mem.eql(u8, op, "**")) {
        if (x == 0 and y < 0) return error.JinjaDivisionByZero;
        const powered = std.math.pow(f64, x, y);
        if (std.math.isNan(powered)) return error.JinjaTypeError;
        return .{ .number = powered };
    }
    if ((std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "//") or std.mem.eql(u8, op, "%")) and y == 0) return error.JinjaDivisionByZero;
    return .{ .number = if (std.mem.eql(u8, op, "+")) x + y else if (std.mem.eql(u8, op, "-")) x - y else if (std.mem.eql(u8, op, "*")) x * y else if (std.mem.eql(u8, op, "/")) x / y else if (std.mem.eql(u8, op, "//")) @floor(x / y) else if (std.mem.eql(u8, op, "%")) x - @floor(x / y) * y else return error.InvalidJinjaExpression };
}
fn indexValue(allocator: std.mem.Allocator, value: Value, key: Value) !Value {
    if (value == .object and key == .string) return value.attribute(key.string);
    if (value == .object) if (sequence(value)) |items| return try indexValue(allocator, .{ .list = items }, key);
    var i = integerIndex(key) catch return .undefined;
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

fn integer(value: Value) !i64 {
    return integerIndex(value);
}

fn sliceValue(allocator: std.mem.Allocator, value: Value, start: ?Value, stop: ?Value, step: ?Value) !Value {
    const values = try iterableValues(allocator, value);
    const length: i64 = @intCast(values.len);
    const stride = if (step) |v| try integer(v) else 1;
    if (stride == 0) return error.InvalidJinjaArguments;
    var first = if (start) |v| try integer(v) else if (stride > 0) @as(i64, 0) else length - 1;
    var last = if (stop) |v| try integer(v) else if (stride > 0) length else @as(i64, -1);
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
    return if (value == .tuple) .{ .tuple = values_result } else .{ .list = values_result };
}

pub fn iterableValues(allocator: std.mem.Allocator, value: Value) anyerror![]const Value {
    if (try sequences.items(allocator, value)) |items| return items;
    if (sequence(value)) |items| return items;
    if (value == .undefined or value == .none) return &.{};
    if (value == .object) {
        const result = try allocateValues(allocator, value.object.len);
        for (value.object, result) |entry, *v| v.* = .{ .string = entry.key };
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

fn attributeValue(allocator: std.mem.Allocator, value: Value, attribute: Value) !Value {
    if (attribute == .none) return value;
    if (attribute == .integer or attribute == .number) return try indexValue(allocator, value, attribute);
    if (attribute != .string) return error.JinjaTypeError;
    var parts = std.mem.splitScalar(u8, attribute.string, '.');
    var result = value;
    while (parts.next()) |part| {
        if (result == .undefined) return result;
        if (std.fmt.parseInt(i64, part, 10)) |i| {
            result = try indexValue(allocator, result, try integerValue(allocator, i));
        } else |_| result = result.attribute(part);
    }
    return result;
}

fn testValue(name: []const u8, value: Value, args: []const Argument) !bool {
    if (std.mem.eql(u8, name, "defined")) return value != .undefined;
    if (std.mem.eql(u8, name, "undefined")) return value == .undefined;
    if (std.mem.eql(u8, name, "none") or std.mem.eql(u8, name, "None")) return value == .none;
    if (std.mem.eql(u8, name, "string")) return value == .string;
    if (std.mem.eql(u8, name, "number")) return value == .integer or value == .number or value == .boolean;
    if (std.mem.eql(u8, name, "integer")) return value == .integer;
    if (std.mem.eql(u8, name, "float")) return value == .number;
    if (std.mem.eql(u8, name, "boolean")) return value == .boolean;
    if (std.mem.eql(u8, name, "true")) return value == .boolean and value.boolean;
    if (std.mem.eql(u8, name, "false")) return value == .boolean and !value.boolean;
    if (std.mem.eql(u8, name, "mapping")) return value == .object and sequence(value) == null and sequences.kind(value) == null;
    if (std.mem.eql(u8, name, "iterable")) return value == .list or value == .tuple or value == .object or value == .string;
    if (std.mem.eql(u8, name, "sequence")) return value == .list or value == .tuple or (value == .object and sequences.kind(value) == null) or value == .string;
    if (std.mem.eql(u8, name, "callable")) return value == .callable;
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
        return try contains(args[0].value, value);
    }
    if (std.mem.eql(u8, name, "odd") or std.mem.eql(u8, name, "even")) {
        const odd = @mod(try numeric(value), 2) != 0;
        return if (std.mem.eql(u8, name, "odd")) odd else !odd;
    }
    if (std.mem.eql(u8, name, "divisibleby")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
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
fn builtin(allocator: std.mem.Allocator, name: []const u8, args: []const Argument) !?Value {
    if (std.mem.eql(u8, name, "zip")) {
        const inputs = try allocateValues(allocator, args.len);
        for (args, inputs) |arg, *input| {
            if (arg.name != null) return error.InvalidJinjaArguments;
            if (arg.value != .list and arg.value != .tuple and arg.value != .object and arg.value != .string) return error.JinjaTypeError;
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
        for (args) |arg| {
            const key = arg.name orelse {
                if (arg.value != .object) return error.InvalidJinjaArguments;
                try entries.appendSlice(allocator, arg.value.object);
                continue;
            };
            var updated = false;
            for (entries.items) |*entry| if (std.mem.eql(u8, entry.key, key)) {
                entry.value = arg.value;
                updated = true;
                break;
            };
            if (updated) continue;
            try entries.append(allocator, .{ .key = key, .value = arg.value });
        }
        return .{ .object = try ownedEntries(allocator, &entries) };
    }
    return null;
}
fn filter(allocator: std.mem.Allocator, name: []const u8, value: Value, args: []const Argument) !Value {
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
        return value.attribute(args[0].value.string);
    }
    if (std.mem.eql(u8, name, "map")) {
        const values = try iterableValues(allocator, value);
        const attribute = argument(args, "attribute", std.math.maxInt(usize), .none);
        const fallback = argument(args, "default", std.math.maxInt(usize), .undefined);
        const mapped = try allocateValues(allocator, values.len);
        if (attribute != .none) {
            for (values, mapped) |v, *out| {
                out.* = try attributeValue(allocator, v, attribute);
                if (out.* == .undefined and fallback != .undefined) out.* = fallback;
            }
        } else {
            if (args.len == 0 or args[0].name != null or args[0].value != .string) return error.InvalidJinjaArguments;
            for (values, mapped) |v, *out| out.* = try filter(allocator, args[0].value.string, v, args[1..]);
        }
        return .{ .list = mapped };
    }
    if (std.mem.eql(u8, name, "select") or std.mem.eql(u8, name, "reject") or std.mem.eql(u8, name, "selectattr") or std.mem.eql(u8, name, "rejectattr")) {
        const values = try iterableValues(allocator, value);
        const has_attribute = std.mem.endsWith(u8, name, "attr");
        const reject = std.mem.startsWith(u8, name, "reject");
        if (has_attribute and args.len == 0) return error.InvalidJinjaArguments;
        const offset: usize = if (has_attribute) 1 else 0;
        var result: std.ArrayList(Value) = .empty;
        for (values) |v| {
            const tested = if (has_attribute) try attributeValue(allocator, v, args[0].value) else v;
            const accepted = if (args.len > offset) blk: {
                if (args[offset].value != .string) return error.InvalidJinjaArguments;
                break :blk try testValue(args[offset].value.string, tested, args[offset + 1 ..]);
            } else tested.truthy();
            if (accepted != reject) try result.append(allocator, v);
        }
        return .{ .list = try ownedValues(allocator, &result) };
    }
    if (std.mem.eql(u8, name, "sort") or std.mem.eql(u8, name, "unique") or std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max")) {
        const values = try iterableValues(allocator, value);
        const sorted = std.mem.eql(u8, name, "sort");
        const case_sensitive = argument(args, "case_sensitive", if (sorted) 1 else 0, .{ .boolean = false }).truthy();
        const attribute = argument(args, "attribute", if (sorted) 2 else 1, .none);
        const Item = struct { value: Value, key: Value };
        var items: std.ArrayList(Item) = .empty;
        for (values) |v| {
            var key = try attributeValue(allocator, v, attribute);
            if (!case_sensitive and key == .string) key = .{ .string = try unicode.convert(allocator, key.string, .lower) };
            if (std.mem.eql(u8, name, "unique")) {
                var duplicate = false;
                for (items.items) |item| if (equal(item.key, key)) {
                    duplicate = true;
                    break;
                };
                if (duplicate) continue;
            }
            try items.append(allocator, .{ .value = v, .key = key });
        }
        if (!std.mem.eql(u8, name, "unique")) {
            const reverse = sorted and argument(args, "reverse", 0, .{ .boolean = false }).truthy();
            if (items.items.len > 1) {
                const first = items.items[0].key;
                for (items.items[1..]) |item| _ = try apply(allocator, "<", item.key, first);
            }
            const Context = struct {
                descending: bool,
                fn less(context: @This(), a: Item, b: Item) bool {
                    const order = if (a.key == .string) std.mem.order(u8, a.key.string, b.key.string) else numericOrder(std.heap.page_allocator, a.key, b.key) catch unreachable;
                    return if (context.descending) order == .gt else order == .lt;
                }
            };
            std.sort.block(Item, items.items, Context{ .descending = reverse }, Context.less);
        }
        if (std.mem.eql(u8, name, "min") or std.mem.eql(u8, name, "max")) {
            if (items.items.len == 0) return .undefined;
            return items.items[if (std.mem.eql(u8, name, "min")) 0 else items.items.len - 1].value;
        }
        const result = try allocateValues(allocator, items.items.len);
        for (items.items, result) |item, *v| v.* = item.value;
        return .{ .list = result };
    }
    if (std.mem.eql(u8, name, "sum")) {
        var result = argument(args, "start", 1, .{ .integer = "0" });
        const attribute = argument(args, "attribute", 0, .none);
        for (try iterableValues(allocator, value)) |v| result = try apply(allocator, "+", result, try attributeValue(allocator, v, attribute));
        return result;
    }
    if (std.mem.eql(u8, name, "reverse")) {
        if (value == .string) return sliceValue(allocator, value, null, null, .{ .integer = "-1" });
        const values = try allocator.dupe(Value, try iterableValues(allocator, value));
        std.mem.reverse(Value, values);
        return .{ .list = values };
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
        if (std.mem.eql(u8, name, "as_number") and converted != .number and converted != .integer) return error.JinjaTypeError;
        return if (converted == .undefined) value else converted;
    }
    if (std.mem.eql(u8, name, "default") or std.mem.eql(u8, name, "d")) {
        if (args.len > 2) return error.InvalidJinjaArguments;
        const replacement = argument(args, "default_value", 0, .{ .string = "" });
        return if (value == .undefined or (argument(args, "boolean", 1, .{ .boolean = false }).truthy() and !value.truthy())) replacement else value;
    }
    if (std.mem.eql(u8, name, "length") or std.mem.eql(u8, name, "count")) return try integerValue(allocator, switch (value) {
        .string => |v| try unicode.count(v),
        .list, .tuple => |v| v.len,
        .object => |v| if (try sequences.length(value)) |length| length else if (sequence(value)) |items| items.len else v.len,
        else => return error.JinjaTypeError,
    });
    if (std.mem.eql(u8, name, "string")) return .{ .string = try value.text(allocator) };
    if (std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "float")) {
        if (std.mem.eql(u8, name, "int")) {
            const fallback = argument(args, "default", 0, .{ .integer = "0" });
            if (integerText(value)) |number| return .{ .integer = number };
            if (value == .string) {
                const text = try unicode.strip(value.string, null, true, true);
                const base = integerIndex(argument(args, "base", 1, .{ .integer = "10" })) catch return fallback;
                if (base == 0 or (base >= 2 and base <= 36)) {
                    const converted = integerFromString(allocator, text, @intCast(base)) catch null;
                    if (converted) |number| return .{ .integer = number };
                }
                const floating = std.fmt.parseFloat(f64, text) catch return fallback;
                return .{ .integer = numbers.floatToInteger(allocator, floating) catch return fallback };
            }
            if (value == .number) return .{ .integer = try numbers.floatToInteger(allocator, value.number) };
            return fallback;
        }
        const fallback = argument(args, "default", 0, .{ .number = 0.0 });
        if (value == .string) return .{ .number = std.fmt.parseFloat(f64, try unicode.strip(value.string, null, true, true)) catch return fallback };
        return .{ .number = numeric(value) catch return fallback };
    }
    if (std.mem.eql(u8, name, "upper") or std.mem.eql(u8, name, "lower")) return .{ .string = try unicode.convert(allocator, try value.text(allocator), if (std.mem.eql(u8, name, "upper")) .upper else .lower) };
    if (std.mem.eql(u8, name, "trim")) return .{ .string = try unicode.strip(try value.text(allocator), if (args.len > 0) try args[0].value.text(allocator) else null, true, true) };
    if (std.mem.eql(u8, name, "replace")) {
        if (args.len != 2) return error.InvalidJinjaArguments;
        const text = try value.text(allocator);
        const old = try args[0].value.text(allocator);
        const new = try args[1].value.text(allocator);
        if (old.len == 0) return error.InvalidJinjaArguments;
        var out: std.ArrayList(u8) = .empty;
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, text, pos, old)) |at| {
            try out.appendSlice(allocator, text[pos..at]);
            try out.appendSlice(allocator, new);
            pos = at + old.len;
        }
        try out.appendSlice(allocator, text[pos..]);
        return .{ .string = try out.toOwnedSlice(allocator) };
    }
    if (std.mem.eql(u8, name, "join")) {
        if (args.len > 2) return error.InvalidJinjaArguments;
        const separator = try argument(args, "d", 0, .{ .string = "" }).text(allocator);
        const attribute = argument(args, "attribute", 1, .none);
        var out: std.ArrayList(u8) = .empty;
        for (try iterableValues(allocator, value), 0..) |v, i| {
            if (i != 0) try out.appendSlice(allocator, separator);
            try out.appendSlice(allocator, try (try attributeValue(allocator, v, attribute)).text(allocator));
        }
        return .{ .string = try out.toOwnedSlice(allocator) };
    }
    if (std.mem.eql(u8, name, "first") or std.mem.eql(u8, name, "last")) {
        const length: usize = switch (value) {
            .list, .tuple => |v| v.len,
            .string => |v| try unicode.count(v),
            else => return error.JinjaTypeError,
        };
        if (length == 0) return .undefined;
        return try indexValue(allocator, value, .{ .integer = if (std.mem.eql(u8, name, "first")) "0" else "-1" });
    }
    if (std.mem.eql(u8, name, "list")) {
        return .{ .list = try iterableValues(allocator, value) };
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
