//! Native package configuration rendering over the shared typed expression engine.
const std = @import("std");
const types = @import("types.zig");
const expression = @import("expression.zig");
const yaml = @import("yaml.zig");
const Value = expression.Value;
const Macro = struct { parameters: []const u8, body: []const u8 };

pub const Context = struct {
    runtime: types.Runtime,
    vars: std.json.Value = .null,
    bindings: std.StringHashMap(Value),
    macros: std.StringHashMap(Macro),
    returned: ?Value = null,
    calls: usize = 0,
    native_number_float: bool = false,
    output_nodes: usize = 0,
    native_output: ?Value = null,
    iterations: usize = 0,

    pub fn init(runtime: types.Runtime, vars: std.json.Value) Context {
        return .{ .runtime = runtime, .vars = vars, .bindings = std.StringHashMap(Value).init(runtime.allocator), .macros = std.StringHashMap(Macro).init(runtime.allocator) };
    }

    fn host(self: *Context) expression.Host {
        return .{ .context = self, .resolve = resolve, .call = call };
    }

    pub fn evaluate(self: *Context, text: []const u8) !Value {
        return expression.evaluate(self.runtime.allocator, text, self.host());
    }

    pub fn render(self: *Context, value: std.json.Value) anyerror!std.json.Value {
        const allocator = self.runtime.allocator;
        switch (value) {
            .string => |text| {
                // Each YAML scalar is a separate Jinja template/context.
                self.bindings.clearRetainingCapacity();
                self.macros.clearRetainingCapacity();
                self.returned = null;
                self.iterations = 0;
                const rendered = try self.renderString(text);
                if (rendered == .number and self.native_number_float) return .{ .float = rendered.number };
                return toJson(allocator, rendered);
            },
            .array => |items| {
                var result: std.json.Array = .init(allocator);
                for (items.items) |item| try result.append(try self.render(item));
                return .{ .array = result };
            },
            .object => |map| {
                var result: std.json.ObjectMap = .empty;
                var iterator = map.iterator();
                while (iterator.next()) |entry| try result.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try self.render(entry.value_ptr.*));
                return .{ .object = result };
            },
            else => return clone(allocator, value),
        }
    }

    pub fn renderString(self: *Context, text: []const u8) anyerror!Value {
        self.native_number_float = false;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        const prefix = text.len - std.mem.trimStart(u8, text, " \t\r\n").len;
        const suffix = text.len - std.mem.trimEnd(u8, text, " \t\r\n").len;
        if (std.mem.startsWith(u8, trimmed, "{{") and std.mem.endsWith(u8, trimmed, "}}") and (prefix == 0 or std.mem.startsWith(u8, trimmed, "{{-")) and (suffix == 0 or std.mem.endsWith(u8, trimmed, "-}}")) and (findEnd(trimmed, 2, "}}") orelse 0) == trimmed.len - 2) {
            const input = std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], "- \t\r\n");
            const result = try self.evaluate(input);
            if (expression.isUndefined(result)) return error.UndefinedJinjaValue;
            const has_marker = std.mem.indexOf(u8, input, "as_native") != null or std.mem.indexOf(u8, input, "as_number") != null or std.mem.indexOf(u8, input, "as_bool") != null or std.mem.indexOf(u8, input, "as_text") != null;
            if (has_marker and (result == .number or result == .integer)) {
                const pipe = std.mem.indexOfScalar(u8, input, '|') orelse input.len;
                const before = std.mem.trim(u8, input[0..pipe], " \t");
                const original = try self.evaluate(before);
                const raw_number = if (original == .string) original.string else before;
                const parsed_number: ?f64 = std.fmt.parseFloat(f64, raw_number) catch null;
                self.native_number_float = std.mem.indexOfAny(u8, raw_number, ".eE") != null and parsed_number != null;
            }
            // Core folds constant expression output to text, while a dynamic
            // context value or a native marker retains its type.
            const constant = expression.evaluate(self.runtime.allocator, input, null) catch .undefined;
            if (!has_marker and !expression.isUndefined(constant)) {
                if (constant == .number or constant == .integer) {
                    var literal = yaml.parse(self.runtime.allocator, input) catch null;
                    if (literal) |*document| {
                        defer document.deinit();
                        if (document.value == .float) {
                            const number_text = try std.fmt.allocPrint(self.runtime.allocator, "{d}", .{document.value.float});
                            return .{ .string = if (std.mem.indexOfScalar(u8, number_text, '.') == null) try std.fmt.allocPrint(self.runtime.allocator, "{s}.0", .{number_text}) else number_text };
                        }
                    }
                }
                return .{ .string = try result.text(self.runtime.allocator) };
            }
            return result;
        }
        var out: std.ArrayList(u8) = .empty;
        self.output_nodes = 0;
        self.native_output = null;
        try self.template(text, &out, 0);
        if (self.returned) |result| return result;
        if (self.output_nodes == 1 and self.native_output != null) return self.native_output.?;
        const rendered = try out.toOwnedSlice(self.runtime.allocator);
        return .{ .string = rendered };
    }

    fn template(self: *Context, text: []const u8, out: *std.ArrayList(u8), depth: usize) anyerror!void {
        if (depth > 128) return error.JinjaIterationLimitExceeded;
        const allocator = self.runtime.allocator;
        var position: usize = 0;
        var trim_next = false;
        while (position < text.len) {
            if (self.returned != null) return;
            const at = std.mem.indexOfPos(u8, text, position, "{") orelse text.len;
            var plain = text[position..at];
            if (trim_next) plain = std.mem.trimStart(u8, plain, " \t\r\n");
            trim_next = false;
            try out.appendSlice(allocator, plain);
            if (plain.len != 0) {
                self.output_nodes += 1;
                self.native_output = null;
            }
            if (at == text.len) break;
            if (at + 1 >= text.len or (text[at + 1] != '{' and text[at + 1] != '%' and text[at + 1] != '#')) {
                try out.append(allocator, '{');
                self.output_nodes += 1;
                self.native_output = null;
                position = at + 1;
                continue;
            }
            const closing: []const u8 = if (text[at + 1] == '{') "}}" else if (text[at + 1] == '%') "%}" else "#}";
            const end = findEnd(text, at + 2, closing) orelse return error.InvalidJinjaExpression;
            if (text[at + 2] == '-') out.shrinkRetainingCapacity(std.mem.trimEnd(u8, out.items, " \t\r\n").len);
            trim_next = end > at + 2 and text[end - 1] == '-';
            const tag = std.mem.trim(u8, text[at + 2 .. end], "- \t\r\n");
            position = end + 2;
            if (text[at + 1] == '#') continue;
            if (text[at + 1] == '{') {
                const value = try self.renderString(text[at .. end + 2]);
                try out.appendSlice(allocator, try value.text(allocator));
                self.output_nodes += 1;
                self.native_output = value;
                continue;
            }
            if (std.mem.startsWith(u8, tag, "macro ")) {
                const open = std.mem.indexOfScalar(u8, tag, '(') orelse return error.InvalidJinjaExpression;
                if (!std.mem.endsWith(u8, tag, ")")) return error.InvalidJinjaExpression;
                const name = std.mem.trim(u8, tag[6..open], " \t");
                if (!identifier(name)) return error.InvalidJinjaExpression;
                const block = try findBlock(allocator, text, position, "macro", "endmacro");
                try self.macros.put(name, .{ .parameters = tag[open + 1 .. tag.len - 1], .body = text[position..block.start] });
                position = block.end;
            } else if (std.mem.startsWith(u8, tag, "set ")) {
                const equal = std.mem.indexOfScalar(u8, tag, '=') orelse return error.InvalidJinjaExpression;
                const name = std.mem.trim(u8, tag[4..equal], " \t");
                if (!identifier(name)) return error.InvalidJinjaExpression;
                try self.bindings.put(name, try self.evaluate(tag[equal + 1 ..]));
            } else if (std.mem.startsWith(u8, tag, "if ")) {
                const block = try findBlock(allocator, text, position, "if", "endif");
                var branch_start = position;
                var condition = tag[3..];
                var selected = false;
                for (block.branches) |branch| {
                    if (!selected and (condition.len == 0 or (try self.evaluate(condition)).truthy())) {
                        try self.template(text[branch_start..branch.start], out, depth + 1);
                        selected = true;
                    }
                    condition = if (std.mem.startsWith(u8, branch.tag, "elif ")) branch.tag[5..] else "";
                    branch_start = branch.end;
                }
                if (!selected and (condition.len == 0 or (try self.evaluate(condition)).truthy())) try self.template(text[branch_start..block.start], out, depth + 1);
                position = block.end;
            } else if (std.mem.startsWith(u8, tag, "for ")) {
                const in = std.mem.indexOf(u8, tag, " in ") orelse return error.InvalidJinjaExpression;
                const names = std.mem.trim(u8, tag[4..in], " \t");
                const value = try self.evaluate(tag[in + 4 ..]);
                const block = try findBlock(allocator, text, position, "for", "endfor");
                const body_end = if (block.branches.len != 0) block.branches[0].start else block.start;
                var items: std.ArrayList(Value) = .empty;
                try items.appendSlice(allocator, try expression.iterableValues(allocator, value));
                const saved = try self.bindings.clone();
                for (items.items, 0..) |item, i| {
                    self.iterations += 1;
                    if (self.iterations > 100000) return error.JinjaIterationLimitExceeded;
                    if (std.mem.indexOfScalar(u8, names, ',')) |comma| {
                        const first = std.mem.trim(u8, names[0..comma], " \t");
                        const second = std.mem.trim(u8, names[comma + 1 ..], " \t");
                        const pair = try expression.iterableValues(allocator, item);
                        if (!identifier(first) or !identifier(second) or pair.len != 2) return error.JinjaTypeError;
                        try self.bindings.put(first, pair[0]);
                        try self.bindings.put(second, pair[1]);
                    } else {
                        if (!identifier(names)) return error.InvalidJinjaExpression;
                        try self.bindings.put(names, item);
                    }
                    const loop = try allocator.alloc(expression.Entry, 6);
                    loop[0] = .{ .key = "index", .value = try expression.integerValue(allocator, i + 1) };
                    loop[1] = .{ .key = "index0", .value = try expression.integerValue(allocator, i) };
                    loop[2] = .{ .key = "first", .value = .{ .boolean = i == 0 } };
                    loop[3] = .{ .key = "last", .value = .{ .boolean = i + 1 == items.items.len } };
                    loop[4] = .{ .key = "length", .value = try expression.integerValue(allocator, items.items.len) };
                    loop[5] = .{ .key = "revindex", .value = try expression.integerValue(allocator, items.items.len - i) };
                    try self.bindings.put("loop", .{ .object = loop });
                    try self.template(text[position..body_end], out, depth + 1);
                    self.bindings = try saved.clone();
                }
                self.bindings = saved;
                if (items.items.len == 0 and block.branches.len != 0) try self.template(text[block.branches[0].end..block.start], out, depth + 1);
                position = block.end;
            } else if (std.mem.eql(u8, tag, "raw")) {
                const block = try findBlock(allocator, text, position, "raw", "endraw");
                try out.appendSlice(allocator, text[position..block.start]);
                if (position != block.start) {
                    self.output_nodes += 1;
                    self.native_output = null;
                }
                position = block.end;
            } else return error.InvalidJinjaExpression;
        }
    }

    fn resolve(raw: *anyopaque, path: []const u8, allocator: std.mem.Allocator) anyerror!Value {
        const self: *Context = @ptrCast(@alignCast(raw));
        var segments = std.mem.splitScalar(u8, path, '.');
        const name = segments.next().?;
        var value = self.bindings.get(name) orelse if (std.mem.eql(u8, name, "dbt_version")) Value{ .string = "1.10.5" } else if (self.macros.contains(name) or std.mem.eql(u8, name, "env_var") or std.mem.eql(u8, name, "var")) Value{ .callable = name } else Value.undefined;
        while (segments.next()) |segment| value = value.attribute(segment);
        _ = allocator;
        return value;
    }

    fn call(raw: *anyopaque, name: []const u8, args: []const expression.Argument, allocator: std.mem.Allocator) anyerror!Value {
        const self: *Context = @ptrCast(@alignCast(raw));
        if (self.macros.get(name)) |macro| {
            if (self.calls >= 128) return error.JinjaIterationLimitExceeded;
            self.calls += 1;
            defer self.calls -= 1;
            const saved = try self.bindings.clone();
            const previous_return = self.returned;
            const previous_nodes = self.output_nodes;
            const previous_output = self.native_output;
            self.returned = null;
            defer {
                self.bindings = saved;
                self.returned = previous_return;
                self.output_nodes = previous_nodes;
                self.native_output = previous_output;
            }
            const parameters = try splitParameters(allocator, macro.parameters);
            const used = try allocator.alloc(bool, args.len);
            @memset(used, false);
            for (parameters, 0..) |parameter, index| {
                const equal = std.mem.indexOfScalar(u8, parameter, '=');
                const key = std.mem.trim(u8, parameter[0 .. equal orelse parameter.len], " \t");
                if (!identifier(key)) return error.InvalidJinjaArguments;
                var value: ?Value = null;
                if (index < args.len and args[index].name == null) {
                    value = args[index].value;
                    used[index] = true;
                }
                for (args, 0..) |arg, i| if (arg.name != null and std.mem.eql(u8, arg.name.?, key)) {
                    if (value != null) return error.InvalidJinjaArguments;
                    value = arg.value;
                    used[i] = true;
                };
                if (value == null) value = if (equal) |at| try self.evaluate(parameter[at + 1 ..]) else return error.InvalidJinjaArguments;
                try self.bindings.put(key, value.?);
            }
            for (used) |seen| if (!seen) return error.InvalidJinjaArguments;
            return self.renderString(macro.body);
        }
        if (std.mem.eql(u8, name, "env_var") or std.mem.eql(u8, name, "var")) {
            if (args.len < 1 or args.len > 2 or args[0].value != .string) return error.InvalidJinjaArguments;
            const key = args[0].value.string;
            if (std.mem.eql(u8, name, "env_var")) {
                if (self.runtime.environment) |environment| if (environment.get(key)) |value| return .{ .string = value };
                if (args.len == 2) return args[1].value;
                return error.MissingPackageEnvironmentVariable;
            }
            if (self.vars == .object) if (self.vars.object.get(key)) |value| {
                if (value == .float) self.native_number_float = true;
                return fromJson(allocator, value);
            };
            if (args.len == 2) return args[1].value;
            return error.UnresolvedVar;
        }
        if (std.mem.eql(u8, name, "fromjson") or std.mem.eql(u8, name, "fromyaml")) {
            if (args.len < 1 or args.len > 2 or args[0].value != .string) return error.InvalidJinjaArguments;
            if (std.mem.eql(u8, name, "fromjson")) {
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, args[0].value.string, .{ .allocate = .alloc_always }) catch {
                    return if (args.len == 2) args[1].value else .none;
                };
                return fromJson(allocator, parsed.value);
            }
            var document = yaml.parse(allocator, args[0].value.string) catch {
                return if (args.len == 2) args[1].value else .none;
            };
            defer document.deinit();
            return fromJson(allocator, document.value);
        }
        if (std.mem.eql(u8, name, "tojson") or std.mem.eql(u8, name, "toyaml")) {
            if (args.len < 1 or args.len > 2) return error.InvalidJinjaArguments;
            var output: std.Io.Writer.Allocating = .init(allocator);
            try std.json.Stringify.value(try toJson(allocator, args[0].value), .{}, &output.writer);
            return .{ .string = try output.toOwnedSlice() };
        }
        if (std.mem.eql(u8, name, "return")) {
            if (args.len != 1) return error.InvalidJinjaArguments;
            self.returned = args[0].value;
            return args[0].value;
        }
        if (std.mem.eql(u8, name, "log") or std.mem.eql(u8, name, "print")) return .{ .string = "" };
        return error.UnsupportedJinjaCall;
    }
};

const Branch = struct { start: usize, end: usize, tag: []const u8 };
const Block = struct { start: usize, end: usize, branches: []const Branch };

fn findBlock(allocator: std.mem.Allocator, text: []const u8, start: usize, opening: []const u8, closing: []const u8) anyerror!Block {
    var position = start;
    var depth: usize = 0;
    var branches: std.ArrayList(Branch) = .empty;
    while (std.mem.indexOfPos(u8, text, position, "{%")) |at| {
        const end = findEnd(text, at + 2, "%}") orelse return error.InvalidJinjaExpression;
        const tag = std.mem.trim(u8, text[at + 2 .. end], "- \t\r\n");
        const word_end = std.mem.indexOfAny(u8, tag, " \t\r\n") orelse tag.len;
        const word = tag[0..word_end];
        if (std.mem.eql(u8, word, "raw") and !std.mem.eql(u8, opening, "raw")) {
            position = (try findBlock(allocator, text, end + 2, "raw", "endraw")).end;
            continue;
        }
        if (std.mem.eql(u8, word, opening) or (!std.mem.eql(u8, opening, "raw") and (std.mem.eql(u8, word, "if") or std.mem.eql(u8, word, "for") or std.mem.eql(u8, word, "macro") or std.mem.eql(u8, word, "raw")))) depth += 1 else if (std.mem.eql(u8, word, closing) or (!std.mem.eql(u8, opening, "raw") and (std.mem.eql(u8, word, "endif") or std.mem.eql(u8, word, "endfor") or std.mem.eql(u8, word, "endmacro") or std.mem.eql(u8, word, "endraw")))) {
            if (depth == 0) {
                if (!std.mem.eql(u8, word, closing)) return error.InvalidJinjaExpression;
                return .{ .start = at, .end = end + 2, .branches = try branches.toOwnedSlice(allocator) };
            }
            depth -= 1;
        } else if (depth == 0 and (std.mem.eql(u8, word, "else") or std.mem.eql(u8, word, "elif"))) {
            try branches.append(allocator, .{ .start = at, .end = end + 2, .tag = tag });
        }
        position = end + 2;
    }
    return error.InvalidJinjaExpression;
}

fn splitParameters(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var parameters: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var depth: usize = 0;
    var quote: u8 = 0;
    var escaped = false;
    for (text, 0..) |char, index| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (quote != 0) {
            if (char == '\\') escaped = true else if (char == quote) quote = 0;
        } else if (char == '\'' or char == '"') quote = char else if (char == '[' or char == '{' or char == '(') depth += 1 else if (char == ']' or char == '}' or char == ')') {
            if (depth == 0) return error.InvalidJinjaArguments;
            depth -= 1;
        } else if (char == ',' and depth == 0) {
            try parameters.append(allocator, std.mem.trim(u8, text[start..index], " \t\r\n"));
            start = index + 1;
        }
    }
    if (quote != 0 or depth != 0) return error.InvalidJinjaArguments;
    const last = std.mem.trim(u8, text[start..], " \t\r\n");
    if (last.len != 0) try parameters.append(allocator, last);
    return try parameters.toOwnedSlice(allocator);
}

fn findEnd(text: []const u8, start: usize, closing: []const u8) ?usize {
    var position = start;
    var quote: u8 = 0;
    var escaped = false;
    var depth: usize = 0;
    while (position < text.len) : (position += 1) {
        const char = text[position];
        if (std.mem.eql(u8, closing, "#}") and std.mem.startsWith(u8, text[position..], closing)) return position;
        if (escaped) {
            escaped = false;
            continue;
        }
        if (quote != 0) {
            if (char == '\\') escaped = true else if (char == quote) quote = 0;
        } else if (depth == 0 and std.mem.startsWith(u8, text[position..], closing)) return position else if (char == '\'' or char == '"') quote = char else if (char == '(' or char == '[' or char == '{') depth += 1 else if (char == ')' or char == ']' or char == '}') {
            if (depth == 0) return null;
            depth -= 1;
        }
    }
    return null;
}

fn identifier(name: []const u8) bool {
    if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_')) return false;
    for (name) |char| if (!std.ascii.isAlphanumeric(char) and char != '_') return false;
    return true;
}

pub fn clone(allocator: std.mem.Allocator, value: std.json.Value) anyerror!std.json.Value {
    return switch (value) {
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .number_string => |text| .{ .number_string = try allocator.dupe(u8, text) },
        .array => |items| blk: {
            var result: std.json.Array = .init(allocator);
            for (items.items) |item| try result.append(try clone(allocator, item));
            break :blk .{ .array = result };
        },
        .object => |map| blk: {
            var result: std.json.ObjectMap = .empty;
            var iterator = map.iterator();
            while (iterator.next()) |entry| try result.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try clone(allocator, entry.value_ptr.*));
            break :blk .{ .object = result };
        },
        else => value,
    };
}

pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) anyerror!Value {
    return try @import("config_value.zig").toExpression(allocator, value);
}

pub fn toJson(allocator: std.mem.Allocator, value: Value) anyerror!std.json.Value {
    return try @import("config_value.zig").fromExpression(allocator, value);
}

test "package expressions preserve dynamic values and Core native marker types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var vars = try yaml.parse(allocator, "path: ../utils\nversions: ['>=1.0.0', '<2.0.0']\nflag: true\n");
    defer vars.deinit();
    var context = Context.init(.{ .allocator = allocator, .io = std.testing.io }, vars.value);
    try std.testing.expectEqualStrings("../utils", (try context.renderString("{{ var('path') }}")).string);
    try std.testing.expectEqualStrings("True", (try context.renderString("{{ true }}")).string);
    try std.testing.expectEqualStrings("1.0", (try context.renderString("{{ 1.0 }}")).string);
    try std.testing.expect((try context.renderString("{{ true | as_bool }}")).boolean);
    try std.testing.expect((try context.renderString("{{ var('flag') }}")).boolean);
    try std.testing.expectEqual(@as(usize, 2), (try context.renderString("{{ var('versions') }}")).list.len);
    try std.testing.expectEqual(@as(usize, 2), (try context.renderString("{{['a','b']|as_native}}")).list.len);
    const number = try context.render(.{ .string = "{{ '1.0' | as_number }}" });
    try std.testing.expectEqual(@as(f64, 1), number.float);
    try std.testing.expectError(error.JinjaTypeError, context.renderString("{{ 'yes' | as_bool }}"));
}

test "package templates render nested control flow scoped loops macros and whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var context = Context.init(.{ .allocator = arena.allocator(), .io = std.testing.io }, .null);
    try std.testing.expectEqualStrings("../utils", (try context.renderString("{% set prefix = '../' %}{% if true %}{{ prefix }}{% for p in ['u','t','i','l','s'] %}{{ p }}{% else %}unused{% endfor %}{% else %}unused{% endif %}")).string);
    try std.testing.expectEqual(@as(i64, 2), try expression.integerIndex(try context.renderString("{% set revision = 2 %}{{ revision }}")));
    try std.testing.expectEqualStrings("fallback", (try context.renderString("{% for p in [] %}unused{% else %}fallback{% endfor %}")).string);
    try std.testing.expectEqualStrings("../utils", (try context.renderString("{% macro path(name='utils') %}{{ '../' ~ name }}{% endmacro %}{{ path() }}")).string);
    try std.testing.expect((try context.renderString("{% macro flag() %}{{ return(true) }}unreachable{% endmacro %}{{ flag() }}")).boolean);
    try std.testing.expectEqualStrings("value", (try context.renderString("  {{- 'value' -}}  ")).string);
    try std.testing.expectEqualStrings(" value ", (try context.renderString(" {{ 'value' }} ")).string);
    try std.testing.expectEqualStrings("{{ unchanged }}", (try context.renderString("{% raw %}{{ unchanged }}{% endraw %}")).string);
    try std.testing.expectEqualStrings("{% if unmatched %}", (try context.renderString("{% if true %}{% raw %}{% if unmatched %}{% endraw %}{% endif %}")).string);
    try std.testing.expectEqualStrings("value", (try context.renderString("{# here's a comment #}value")).string);
}
