const std = @import("std");

/// Native Jinja expression values. Allocations belong to the caller's render
/// arena; values can cross macro returns without borrowing a temporary frame.
pub const Value = union(enum) {
    undefined,
    none,
    boolean: bool,
    number: f64,
    string: []const u8,
    list: []const Value,
    object: []const Entry,
    callable: []const u8,

    pub fn truthy(self: Value) bool {
        return switch (self) {
            .undefined, .none => false,
            .boolean => |v| v,
            .number => |v| v != 0,
            .string => |v| v.len != 0,
            .list => |v| v.len != 0,
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
            .number => |v| if (std.math.isFinite(v) and @abs(v) < 9007199254740992 and @floor(v) == v)
                try std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @intFromFloat(v))})
            else
                try std.fmt.allocPrint(allocator, "{d}", .{v}),
            .string => |v| v,
            .list => |values| blk: {
                var out: std.ArrayList(u8) = .empty;
                try out.append(allocator, '[');
                for (values, 0..) |v, i| {
                    if (i != 0) try out.appendSlice(allocator, ", ");
                    try out.appendSlice(allocator, try repr(v, allocator));
                }
                try out.append(allocator, ']');
                break :blk try out.toOwnedSlice(allocator);
            },
            .object => |entries| blk: {
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
};

pub fn repr(value: Value, allocator: std.mem.Allocator) ![]const u8 {
    if (value == .string) {
        var out: std.ArrayList(u8) = .empty;
        try out.append(allocator, '\'');
        for (value.string) |c| {
            if (c == '\\' or c == '\'') try out.append(allocator, '\\');
            switch (c) {
                '\n' => try out.appendSlice(allocator, "\\n"),
                '\r' => try out.appendSlice(allocator, "\\r"),
                '\t' => try out.appendSlice(allocator, "\\t"),
                else => try out.append(allocator, c),
            }
        }
        try out.append(allocator, '\'');
        return try out.toOwnedSlice(allocator);
    }
    return value.text(allocator);
}

pub fn evaluate(allocator: std.mem.Allocator, input: []const u8, host: ?Host) !Value {
    var parser = Parser{ .allocator = allocator, .input = input, .host = host };
    const value = try parser.binary(0);
    parser.space();
    if (parser.index != input.len) return error.InvalidJinjaExpression;
    return value;
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
                const result = if (std.mem.eql(u8, test_name, "defined")) lhs != .undefined else if (std.mem.eql(u8, test_name, "undefined")) lhs == .undefined else if (std.mem.eql(u8, test_name, "none") or std.mem.eql(u8, test_name, "None")) lhs == .none else if (std.mem.eql(u8, test_name, "string")) lhs == .string else if (std.mem.eql(u8, test_name, "number")) lhs == .number else if (std.mem.eql(u8, test_name, "boolean")) lhs == .boolean else if (std.mem.eql(u8, test_name, "iterable")) (lhs == .list or lhs == .object or lhs == .string) else return error.UnsupportedJinjaTest;
                lhs = .{ .boolean = if (negate) !result else result };
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
        for ([_][]const u8{ "or", "and", "not in", "in", "is", "==", "!=", "<=", ">=", "<", ">", "~", "+", "-", "//", "*", "/", "%" }) |op| {
            if (self.take(op)) return op;
        }
        return null;
    }

    fn unary(self: *Parser) anyerror!Value {
        if (self.take("not")) return .{ .boolean = !(try self.binary(3)).truthy() };
        if (self.take("-")) {
            const value = try self.unary();
            if (!self.active) return .none;
            return .{ .number = -(try numeric(value)) };
        }
        if (self.take("+")) return try self.unary();
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
                const key = try self.binary(0);
                try self.expect("]");
                if (self.active) value = try indexValue(self.allocator, value, key);
            } else if (self.take(".")) {
                const attribute = try self.name();
                if (self.active) value = value.attribute(attribute);
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
            while (self.index < self.input.len and (std.ascii.isDigit(self.input[self.index]) or self.input[self.index] == '.')) self.index += 1;
            return .{ .number = std.fmt.parseFloat(f64, self.input[start..self.index]) catch return error.InvalidJinjaExpression };
        }
        if (self.take("(")) {
            const value = try self.binary(0);
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
            return .{ .list = try values.toOwnedSlice(self.allocator) };
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
            return .{ .object = try entries.toOwnedSlice(self.allocator) };
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
            return try host.call(host.context, path, args, self.allocator);
        }
        if (!self.active) return .none;
        const host = self.host orelse return .undefined;
        return try host.resolve(host.context, path, self.allocator);
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
                    if (expanded != .list) return error.InvalidJinjaArguments;
                    for (expanded.list) |value| try args.append(self.allocator, .{ .value = value });
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

fn ident(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}
fn rank(op: []const u8) u8 {
    if (std.mem.eql(u8, op, "or")) return 1;
    if (std.mem.eql(u8, op, "and")) return 2;
    if (std.mem.eql(u8, op, "is") or std.mem.eql(u8, op, "in") or std.mem.eql(u8, op, "not in") or std.mem.indexOfScalar(u8, "=!<>", op[0]) != null) return 3;
    if (std.mem.eql(u8, op, "~") or std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-")) return 4;
    return 5;
}
fn numeric(v: Value) !f64 {
    return switch (v) {
        .number => |n| n,
        .boolean => |b| if (b) 1 else 0,
        else => error.JinjaTypeError,
    };
}
fn equal(a: Value, b: Value) bool {
    if ((a == .number or a == .boolean) and (b == .number or b == .boolean)) return (numeric(a) catch 0) == (numeric(b) catch 0);
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .undefined, .none => true,
        .string => |s| std.mem.eql(u8, s, b.string),
        .number => |n| n == b.number,
        .boolean => |v| v == b.boolean,
        .callable => |v| std.mem.eql(u8, v, b.callable),
        .list => |values| blk: {
            if (values.len != b.list.len) break :blk false;
            for (values, b.list) |x, y| if (!equal(x, y)) break :blk false;
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
        .list => |values| blk: {
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
    if (std.mem.indexOfScalar(u8, "<>", op[0]) != null) {
        const order: std.math.Order = if (a == .string and b == .string) std.mem.order(u8, a.string, b.string) else std.math.order(try numeric(a), try numeric(b));
        return .{ .boolean = if (std.mem.eql(u8, op, "<")) order == .lt else if (std.mem.eql(u8, op, ">")) order == .gt else if (std.mem.eql(u8, op, "<=")) order != .gt else order != .lt };
    }
    const x = try numeric(a);
    const y = try numeric(b);
    if ((std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "//") or std.mem.eql(u8, op, "%")) and y == 0) return error.JinjaDivisionByZero;
    return .{ .number = if (std.mem.eql(u8, op, "+")) x + y else if (std.mem.eql(u8, op, "-")) x - y else if (std.mem.eql(u8, op, "*")) x * y else if (std.mem.eql(u8, op, "/")) x / y else if (std.mem.eql(u8, op, "//")) @floor(x / y) else if (std.mem.eql(u8, op, "%")) x - @floor(x / y) * y else return error.InvalidJinjaExpression };
}
fn indexValue(allocator: std.mem.Allocator, value: Value, key: Value) !Value {
    if (value == .object and key == .string) return value.attribute(key.string);
    if (key != .number or !std.math.isFinite(key.number) or @floor(key.number) != key.number or @abs(key.number) > 9007199254740991) return error.JinjaTypeError;
    const len: usize = switch (value) {
        .list => |v| v.len,
        .string => |v| v.len,
        else => return error.JinjaTypeError,
    };
    var i: i64 = @intFromFloat(key.number);
    if (i < 0) i += @intCast(len);
    if (i < 0 or i >= @as(i64, @intCast(len))) return .undefined;
    return switch (value) {
        .list => |v| v[@intCast(i)],
        .string => |v| .{ .string = try allocator.dupe(u8, v[@intCast(i) .. @as(usize, @intCast(i)) + 1]) },
        else => unreachable,
    };
}
fn builtin(allocator: std.mem.Allocator, name: []const u8, args: []const Argument) !?Value {
    if (std.mem.eql(u8, name, "range")) {
        if (args.len < 1 or args.len > 3) return error.InvalidJinjaArguments;
        var bounds: [3]i64 = .{ 0, 0, 1 };
        for (args, 0..) |arg, i| {
            const n = try numeric(arg.value);
            if (!std.math.isFinite(n) or @floor(n) != n or @abs(n) > 2147483647) return error.InvalidJinjaArguments;
            bounds[i] = @intFromFloat(n);
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
            try values.append(allocator, .{ .number = @floatFromInt(n) });
        }
        return .{ .list = try values.toOwnedSlice(allocator) };
    }
    if (std.mem.eql(u8, name, "dict") or std.mem.eql(u8, name, "namespace")) {
        var entries: std.ArrayList(Entry) = .empty;
        for (args) |arg| {
            const key = arg.name orelse return error.InvalidJinjaArguments;
            try entries.append(allocator, .{ .key = key, .value = arg.value });
        }
        return .{ .object = try entries.toOwnedSlice(allocator) };
    }
    return null;
}
fn filter(allocator: std.mem.Allocator, name: []const u8, value: Value, args: []const Argument) !Value {
    if (std.mem.eql(u8, name, "default") or std.mem.eql(u8, name, "d")) {
        if (args.len > 2) return error.InvalidJinjaArguments;
        const replacement: Value = if (args.len > 0) args[0].value else .{ .string = "" };
        return if (value == .undefined or (args.len == 2 and args[1].value.truthy() and !value.truthy())) replacement else value;
    }
    if (std.mem.eql(u8, name, "length") or std.mem.eql(u8, name, "count")) return .{ .number = @floatFromInt(switch (value) {
        .string => |v| v.len,
        .list => |v| v.len,
        .object => |v| v.len,
        else => return error.JinjaTypeError,
    }) };
    if (std.mem.eql(u8, name, "string")) return .{ .string = try value.text(allocator) };
    if (std.mem.eql(u8, name, "int") or std.mem.eql(u8, name, "float")) {
        const n: f64 = if (value == .string) std.fmt.parseFloat(f64, value.string) catch (if (args.len > 0) try numeric(args[0].value) else 0) else try numeric(value);
        return .{ .number = if (std.mem.eql(u8, name, "int")) @trunc(n) else n };
    }
    if (std.mem.eql(u8, name, "upper") or std.mem.eql(u8, name, "lower")) {
        const text = try allocator.dupe(u8, try value.text(allocator));
        for (text) |*c| c.* = if (std.mem.eql(u8, name, "upper")) std.ascii.toUpper(c.*) else std.ascii.toLower(c.*);
        return .{ .string = text };
    }
    if (std.mem.eql(u8, name, "trim")) return .{ .string = std.mem.trim(u8, try value.text(allocator), if (args.len > 0) try args[0].value.text(allocator) else " \t\r\n") };
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
        if (value != .list or args.len > 1) return error.JinjaTypeError;
        const separator = if (args.len == 1) try args[0].value.text(allocator) else "";
        var out: std.ArrayList(u8) = .empty;
        for (value.list, 0..) |v, i| {
            if (i != 0) try out.appendSlice(allocator, separator);
            try out.appendSlice(allocator, try v.text(allocator));
        }
        return .{ .string = try out.toOwnedSlice(allocator) };
    }
    if (std.mem.eql(u8, name, "first") or std.mem.eql(u8, name, "last")) {
        const length: usize = switch (value) {
            .list => |v| v.len,
            .string => |v| v.len,
            else => return error.JinjaTypeError,
        };
        if (length == 0) return .undefined;
        return try indexValue(allocator, value, .{ .number = if (std.mem.eql(u8, name, "first")) 0 else -1 });
    }
    if (std.mem.eql(u8, name, "list")) {
        if (value == .list) return value;
        if (value == .object) {
            const values = try allocator.alloc(Value, value.object.len);
            for (value.object, values) |entry, *v| v.* = .{ .string = entry.key };
            return .{ .list = values };
        }
    }
    return error.UnsupportedJinjaFilter;
}

test "typed expressions preserve precedence, containers, filters and short circuit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 14), (try evaluate(a, "2 + 3 * 4", null)).number);
    try std.testing.expect((try evaluate(a, "not false and 3 >= 2 and 'x' in ['x', 'y']", null)).boolean);
    try std.testing.expectEqualStrings("A-B", (try evaluate(a, "['a', 'b'] | join('-') | upper", null)).string);
    try std.testing.expectEqualStrings("last", (try evaluate(a, "['first','last'][-1]", null)).string);
    try std.testing.expectEqual(@as(f64, 2), (try evaluate(a, "{'x': [1,2]}['x'] | length", null)).number);
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
    try std.testing.expectEqual(@as(f64, 2), args[1].value.number);
    try std.testing.expectEqualStrings("strategy", args[2].name.?);
    try std.testing.expect(args[3].value.boolean);
    try std.testing.expectError(error.InvalidJinjaArguments, evaluateArguments(allocator, "a=1, **{'a':2}", null));
    try std.testing.expectError(error.InvalidJinjaArguments, evaluateArguments(allocator, "**[1,2]", null));
    try std.testing.expect(!(try evaluate(allocator, "false and missing_call(**unknown)", null)).truthy());
}
