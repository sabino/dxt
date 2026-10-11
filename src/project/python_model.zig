//! Static dbt Python model metadata. The native C frontend only builds syntax
//! trees; Zig validates the model contract and reads literal dbt calls. Authored
//! source is never imported, evaluated or executed by this parser.
const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");
const config = @import("resource_config.zig");
const c = @cImport({
    @cInclude("tree_sitter/api.h");
});
extern fn tree_sitter_python() ?*const c.TSLanguage;
const Syntax = c.TSNode;
const Value = std.json.Value;

pub fn scan(allocator: std.mem.Allocator, code: []const u8, node: *types.Node) !void {
    // Core renders code with an empty Jinja context, then rejects any change.
    // Python files are authored source, never SQL/Jinja templates.
    if (std.mem.indexOf(u8, code, "{{") != null or std.mem.indexOf(u8, code, "{%") != null or std.mem.indexOf(u8, code, "{#") != null) return error.JinjaInPythonModel;
    if (code.len > std.math.maxInt(u32)) return error.InvalidPythonModelSyntax;
    const parser = c.ts_parser_new() orelse return error.OutOfMemory;
    defer c.ts_parser_delete(parser);
    if (!c.ts_parser_set_language(parser, tree_sitter_python())) return error.InvalidPythonGrammar;
    const tree = c.ts_parser_parse_string(parser, null, code.ptr, @intCast(code.len)) orelse return error.OutOfMemory;
    defer c.ts_tree_delete(tree);
    const root = c.ts_tree_root_node(tree);
    if (c.ts_node_has_error(root)) return error.InvalidPythonModelSyntax;
    try validatePython3Syntax(root);
    var context = Context{ .allocator = allocator, .code = code, .node = node, .config_keys = std.json.Array.init(allocator), .config_defaults = std.json.Array.init(allocator) };
    var count: usize = 0;
    try context.validate(root, &count);
    if (statementCount(root) != 0 and count != 1) return error.InvalidPythonModelFunction;
    try context.visit(root);
    if (context.config_keys.items.len != 0) {
        var cfg: Value = .{ .object = .empty };
        defer values.deinit(allocator, &cfg);
        try values.put(allocator, &cfg, "config_keys_used", .{ .array = context.config_keys });
        try values.put(allocator, &cfg, "config_keys_defaults", .{ .array = context.config_defaults });
        try config.applyParsedInline(allocator, cfg, node);
    }
}

const Context = struct {
    allocator: std.mem.Allocator,
    code: []const u8,
    node: *types.Node,
    config_keys: std.json.Array,
    config_defaults: std.json.Array,

    fn text(self: *const Context, n: Syntax) []const u8 {
        return self.code[c.ts_node_start_byte(n)..c.ts_node_end_byte(n)];
    }

    fn validate(self: *Context, n: Syntax, count: *usize) anyerror!void {
        if (kind(n, "function_definition")) {
            // ast.NodeVisitor's FunctionDef visitor deliberately does not recurse
            // into function bodies while counting/validating model definitions.
            if (std.mem.startsWith(u8, self.text(n), "async ")) {
                const body = field(n, "body");
                for (0..c.ts_node_named_child_count(body)) |i| try self.validate(child(body, i), count);
                return;
            }
            if (!std.mem.eql(u8, self.text(field(n, "name")), "model")) return;
            count.* += 1;
            const parameters = field(n, "parameters");
            var positional: usize = 0;
            var first: ?[]const u8 = null;
            var after_star = false;
            for (0..c.ts_node_named_child_count(parameters)) |i| {
                const param = child(parameters, i);
                if (kind(param, "comment")) continue;
                const untyped = if (kind(param, "typed_parameter")) child(param, 0) else param;
                if (kind(param, "positional_separator")) {
                    // Core checks args.args, excluding positional-only args.
                    positional = 0;
                    first = null;
                    continue;
                }
                if (kind(untyped, "keyword_separator") or kind(untyped, "list_splat_pattern") or kind(untyped, "dictionary_splat_pattern")) {
                    after_star = true;
                    continue;
                }
                const name = if (kind(param, "identifier")) self.text(param) else if (kind(param, "typed_parameter")) self.text(child(param, 0)) else self.text(field(param, "name"));
                if (after_star) continue;
                positional += 1;
                if (first == null) first = name;
            }
            if (positional != 2 or first == null or !std.mem.eql(u8, first.?, "dbt")) return error.InvalidPythonModelFunction;
            const body = field(n, "body");
            var last: Syntax = undefined;
            var have_last = false;
            for (0..c.ts_node_named_child_count(body)) |i| {
                const statement = child(body, i);
                if (kind(statement, "comment")) continue;
                last = statement;
                have_last = true;
            }
            if (!have_last or !kind(last, "return_statement")) return error.InvalidPythonModelReturn;
            if (c.ts_node_named_child_count(last) != 0) {
                var returned = child(last, 0);
                while (kind(returned, "parenthesized_expression")) returned = child(returned, 0);
                if (kind(returned, "tuple") or kind(returned, "expression_list")) return error.InvalidPythonModelReturn;
            }
            return;
        }
        for (0..c.ts_node_named_child_count(n)) |i| try self.validate(child(n, i), count);
    }

    fn visit(self: *Context, n: Syntax) anyerror!void {
        if (kind(n, "call")) {
            const function = field(n, "function");
            const name = try self.callName(function);
            if (name) |full| {
                if (std.mem.eql(u8, full, "dbt.ref") or std.mem.eql(u8, full, "dbt.source") or std.mem.eql(u8, full, "dbt.config") or std.mem.eql(u8, full, "dbt.config.get")) try self.dbtCall(full, field(n, "arguments"));
            }
            // Match Core's PythonParseVisitor: direct calls inside call args,
            // list/tuple elements, dict values and f-string substitutions, then
            // the innermost call of a chained attribute receiver. It does not
            // recursively evaluate arbitrary argument expressions.
            const arguments = field(n, "arguments");
            for (0..c.ts_node_named_child_count(arguments)) |i| {
                const argument = child(arguments, i);
                const value = if (kind(argument, "keyword_argument")) field(argument, "value") else argument;
                try self.argumentCalls(value);
            }
            var receiver = function;
            while (kind(receiver, "attribute")) receiver = field(receiver, "object");
            if (kind(receiver, "call")) try self.visit(receiver);
            return;
        }
        for (0..c.ts_node_named_child_count(n)) |i| try self.visit(child(n, i));
    }

    fn argumentCalls(self: *Context, n: Syntax) anyerror!void {
        if (kind(n, "call")) return try self.visit(n);
        if (kind(n, "list") or kind(n, "tuple")) {
            for (0..c.ts_node_named_child_count(n)) |i| if (kind(child(n, i), "call")) try self.visit(child(n, i));
        } else if (kind(n, "dictionary")) {
            for (0..c.ts_node_named_child_count(n)) |i| {
                const value = field(child(n, i), "value");
                if (kind(value, "call")) try self.visit(value);
            }
        } else if (kind(n, "string")) {
            for (0..c.ts_node_named_child_count(n)) |i| {
                const item = child(n, i);
                if (kind(item, "interpolation")) {
                    const value = field(item, "expression");
                    if (kind(value, "call")) try self.visit(value);
                }
            }
        }
    }

    fn callName(self: *Context, n: Syntax) anyerror!?[]const u8 {
        if (kind(n, "identifier")) return self.text(n);
        if (!kind(n, "attribute")) return null;
        const parent = (try self.callName(field(n, "object"))) orelse return null;
        return try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ parent, self.text(field(n, "attribute")) });
    }

    fn dbtCall(self: *Context, name: []const u8, arguments: Syntax) !void {
        const a = self.allocator;
        var args: std.ArrayList(Value) = .empty;
        var kwargs: Value = .{ .object = .empty };
        for (0..c.ts_node_named_child_count(arguments)) |i| {
            const arg = child(arguments, i);
            if (kind(arg, "comment")) continue;
            if (kind(arg, "keyword_argument")) {
                const key = self.text(field(arg, "name"));
                if (std.mem.eql(u8, name, "dbt.config") and std.mem.eql(u8, key, "tags") and kind(field(arg, "value"), "tuple")) return error.InvalidPythonModelArgument;
                try kwargs.object.put(a, try a.dupe(u8, key), try self.literal(field(arg, "value")));
            } else if (kind(arg, "list_splat") or kind(arg, "dictionary_splat")) return error.NonLiteralPythonModelArgument else try args.append(a, try self.literal(arg));
        }
        if (std.mem.eql(u8, name, "dbt.ref")) {
            if (args.items.len != 1 and args.items.len != 2) return error.InvalidPythonModelArgument;
            const package = if (args.items.len == 2) try string(args.items[0]) else null;
            const model = try string(args.items[args.items.len - 1]);
            var version = values.get(kwargs, "version") orelse .null;
            if (!truthy(version)) version = values.get(kwargs, "v") orelse .null;
            if (!truthy(version)) version = .null;
            if (version != .null and version != .string and version != .integer and version != .number_string and version != .float and version != .bool) return error.InvalidPythonModelArgument;
            try self.node.refs.append(a, .{ .package = package, .name = model, .version = version });
        } else if (std.mem.eql(u8, name, "dbt.source")) {
            if (args.items.len != 2 or kwargs.object.count() != 0) return error.InvalidPythonModelArgument;
            try self.node.source_refs.append(a, .{ .source_name = try string(args.items[0]), .table_name = try string(args.items[1]) });
        } else if (std.mem.eql(u8, name, "dbt.config.get")) {
            if (args.items.len != 1 and args.items.len != 2) return error.InvalidPythonModelArgument;
            // The parser records the key/default; it never evaluates the config.
            try self.config_keys.append(args.items[0]);
            try self.config_defaults.append(if (args.items.len == 2) args.items[1] else .null);
        } else {
            if (args.items.len == 1) {
                const mapping = child(arguments, 0);
                if (kind(mapping, "dictionary")) for (0..c.ts_node_named_child_count(mapping)) |i| {
                    const pair = child(mapping, i);
                    if (!kind(pair, "pair")) continue;
                    const key = try self.literal(field(pair, "key"));
                    if (key == .string and std.mem.eql(u8, key.string, "tags") and kind(field(pair, "value"), "tuple")) return error.InvalidPythonModelArgument;
                };
            }
            const cfg = if (args.items.len == 1 and kwargs.object.count() == 0) args.items[0] else if (args.items.len == 0 and kwargs.object.count() != 0) kwargs else return error.InvalidPythonModelArgument;
            if (cfg != .object) return error.InvalidPythonModelArgument;
            if ((cfg.object.contains("pre_hook") and cfg.object.contains("pre-hook")) or (cfg.object.contains("post_hook") and cfg.object.contains("post-hook"))) return error.InvalidPythonModelArgument;
            try config.applyParsedInline(a, cfg, self.node);
        }
    }

    fn literal(self: *Context, n: Syntax) anyerror!Value {
        const a = self.allocator;
        if (kind(n, "true")) return .{ .bool = true };
        if (kind(n, "false")) return .{ .bool = false };
        if (kind(n, "none")) return .null;
        if (kind(n, "string")) return .{ .string = try decodeString(a, self.text(n)) };
        if (kind(n, "concatenated_string")) {
            var out: std.ArrayList(u8) = .empty;
            for (0..c.ts_node_named_child_count(n)) |i| try out.appendSlice(a, try string(try self.literal(child(n, i))));
            return .{ .string = try out.toOwnedSlice(a) };
        }
        if (kind(n, "integer")) return try integer(a, self.text(n));
        if (kind(n, "float")) {
            const clean = try cleanNumber(a, self.text(n));
            return .{ .float = std.fmt.parseFloat(f64, clean) catch return error.NonLiteralPythonModelArgument };
        }
        if (kind(n, "unary_operator")) {
            const operand = try self.literal(field(n, "argument"));
            const op = self.text(field(n, "operator"));
            if (std.mem.eql(u8, op, "+")) return switch (operand) {
                .integer, .float, .number_string => operand,
                else => error.NonLiteralPythonModelArgument,
            };
            if (!std.mem.eql(u8, op, "-")) return error.NonLiteralPythonModelArgument;
            return switch (operand) {
                .integer => |v| if (v == std.math.minInt(i64)) .{ .number_string = try std.fmt.allocPrint(a, "{d}", .{-@as(i128, v)}) } else .{ .integer = -v },
                .number_string => |v| .{ .number_string = try std.fmt.allocPrint(a, "-{s}", .{v}) },
                .float => |v| .{ .float = -v },
                else => error.NonLiteralPythonModelArgument,
            };
        }
        if (kind(n, "parenthesized_expression")) return try self.literal(child(n, 0));
        if (kind(n, "list") or kind(n, "tuple")) {
            var result = std.json.Array.init(a);
            for (0..c.ts_node_named_child_count(n)) |i| {
                const item = child(n, i);
                if (!kind(item, "comment")) try result.append(try self.literal(item));
            }
            return .{ .array = result };
        }
        if (kind(n, "dictionary")) {
            var result: Value = .{ .object = .empty };
            for (0..c.ts_node_named_child_count(n)) |i| {
                const pair = child(n, i);
                if (kind(pair, "comment")) continue;
                if (!kind(pair, "pair")) return error.NonLiteralPythonModelArgument;
                const key = try string(try self.literal(field(pair, "key")));
                try result.object.put(a, key, try self.literal(field(pair, "value")));
            }
            return result;
        }
        return error.NonLiteralPythonModelArgument;
    }
};

fn string(value: Value) ![]const u8 {
    return if (value == .string) value.string else error.InvalidPythonModelArgument;
}
fn truthy(value: Value) bool {
    return switch (value) {
        .null => false,
        .bool => |v| v,
        .integer => |v| v != 0,
        .float => |v| v != 0,
        .number_string => |v| !std.mem.eql(u8, v, "0"),
        .string => |v| v.len != 0,
        .array => |v| v.items.len != 0,
        .object => |v| v.count() != 0,
    };
}
fn validatePython3Syntax(n: Syntax) anyerror!void {
    // Upstream's grammar retains Python 2 statements for editor support. Core's
    // pinned Python 3 AST rejects those legacy forms even in unused functions.
    if (kind(n, "print_statement") or kind(n, "exec_statement")) return error.InvalidPythonModelSyntax;
    if (kind(n, "parameters") or kind(n, "lambda_parameters")) {
        var default_seen = false;
        var keyword_only = false;
        for (0..c.ts_node_named_child_count(n)) |i| {
            const parameter = child(n, i);
            if (kind(parameter, "comment") or kind(parameter, "positional_separator")) continue;
            const untyped = if (kind(parameter, "typed_parameter")) child(parameter, 0) else parameter;
            if (kind(untyped, "keyword_separator") or kind(untyped, "list_splat_pattern") or kind(untyped, "dictionary_splat_pattern")) {
                keyword_only = true;
                continue;
            }
            if (keyword_only) continue;
            if (kind(parameter, "default_parameter") or kind(parameter, "typed_default_parameter")) default_seen = true else if (default_seen) return error.InvalidPythonModelSyntax;
        }
    }
    if (kind(n, "argument_list")) {
        var keyword_seen = false;
        var dict_unpack_seen = false;
        for (0..c.ts_node_named_child_count(n)) |i| {
            const argument = child(n, i);
            if (kind(argument, "comment")) continue;
            if (kind(argument, "keyword_argument")) keyword_seen = true else if (kind(argument, "dictionary_splat")) {
                keyword_seen = true;
                dict_unpack_seen = true;
            } else if (kind(argument, "list_splat")) {
                if (dict_unpack_seen) return error.InvalidPythonModelSyntax;
            } else if (keyword_seen) return error.InvalidPythonModelSyntax;
        }
    }
    for (0..c.ts_node_named_child_count(n)) |i| try validatePython3Syntax(child(n, i));
}
fn kind(n: Syntax, name: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(c.ts_node_type(n)), name);
}
fn child(n: Syntax, i: usize) Syntax {
    return c.ts_node_named_child(n, @intCast(i));
}
fn field(n: Syntax, name: []const u8) Syntax {
    return c.ts_node_child_by_field_name(n, name.ptr, @intCast(name.len));
}
fn statementCount(n: Syntax) usize {
    var count: usize = 0;
    for (0..c.ts_node_named_child_count(n)) |i| if (!kind(child(n, i), "comment")) {
        count += 1;
    };
    return count;
}
fn cleanNumber(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |byte| if (byte != '_') {
        try out.append(a, byte);
    };
    return try out.toOwnedSlice(a);
}
fn integer(a: std.mem.Allocator, text: []const u8) !Value {
    const clean = try cleanNumber(a, text);
    if (std.fmt.parseInt(i64, clean, 0)) |v| return .{ .integer = v } else |_| {}
    const base: u8 = if (std.mem.startsWith(u8, clean, "0x") or std.mem.startsWith(u8, clean, "0X")) 16 else if (std.mem.startsWith(u8, clean, "0o") or std.mem.startsWith(u8, clean, "0O")) 8 else if (std.mem.startsWith(u8, clean, "0b") or std.mem.startsWith(u8, clean, "0B")) 2 else 10;
    if (base == 10) return .{ .number_string = clean };
    // Decimal digits in reverse order keep arbitrary-precision literals exact.
    var digits: std.ArrayList(u8) = .empty;
    try digits.append(a, 0);
    for (clean[2..]) |byte| {
        var carry: u16 = std.fmt.charToDigit(byte, base) catch return error.InvalidPythonModelSyntax;
        for (digits.items) |*digit| {
            const v: u16 = @as(u16, digit.*) * base + carry;
            digit.* = @intCast(v % 10);
            carry = v / 10;
        }
        while (carry != 0) {
            try digits.append(a, @intCast(carry % 10));
            carry /= 10;
        }
    }
    const result = try a.alloc(u8, digits.items.len);
    for (digits.items, 0..) |digit, i| result[result.len - 1 - i] = '0' + digit;
    return .{ .number_string = result };
}
fn decodeString(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const quote = std.mem.indexOfAny(u8, text, "'\"") orelse return error.NonLiteralPythonModelArgument;
    const prefix = text[0..quote];
    var raw = false;
    for (prefix) |byte| switch (std.ascii.toLower(byte)) {
        'r' => raw = true,
        'u' => {},
        else => return error.NonLiteralPythonModelArgument,
    };
    const width: usize = if (text.len >= quote + 6 and text[quote] == text[quote + 1] and text[quote] == text[quote + 2]) 3 else 1;
    const body = text[quote + width .. text.len - width];
    if (raw) return try a.dupe(u8, body);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        if (body[i] != '\\') {
            try out.append(a, body[i]);
            continue;
        }
        i += 1;
        if (i >= body.len) return error.InvalidPythonModelSyntax;
        const escaped = body[i];
        switch (escaped) {
            '\n' => {},
            '\r' => {
                if (i + 1 < body.len and body[i + 1] == '\n') i += 1;
            },
            'a' => try out.append(a, 7),
            'b' => try out.append(a, 8),
            'f' => try out.append(a, 12),
            'n' => try out.append(a, '\n'),
            'r' => try out.append(a, '\r'),
            't' => try out.append(a, '\t'),
            'v' => try out.append(a, 11),
            '\\', '\'', '"' => try out.append(a, escaped),
            'x', 'u', 'U' => {
                const count: usize = if (escaped == 'x') 2 else if (escaped == 'u') 4 else 8;
                if (i + count >= body.len) return error.InvalidPythonModelSyntax;
                const cp = std.fmt.parseInt(u21, body[i + 1 .. i + count + 1], 16) catch return error.InvalidPythonModelSyntax;
                var bytes: [4]u8 = undefined;
                const size = std.unicode.utf8Encode(cp, &bytes) catch return error.InvalidPythonModelSyntax;
                try out.appendSlice(a, bytes[0..size]);
                i += count;
            },
            '0'...'7' => {
                var end = i + 1;
                while (end < body.len and end < i + 3 and body[end] >= '0' and body[end] <= '7') : (end += 1) {}
                const cp = try std.fmt.parseInt(u21, body[i..end], 8);
                var bytes: [4]u8 = undefined;
                const size = try std.unicode.utf8Encode(cp, &bytes);
                try out.appendSlice(a, bytes[0..size]);
                i = end - 1;
            },
            'N' => return error.NonLiteralPythonModelArgument,
            else => {
                try out.append(a, '\\');
                try out.append(a, escaped);
            },
        }
    }
    return try out.toOwnedSlice(a);
}

test "Python model parser validates syntax and reads literal refs sources configs without execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var node = types.Node{ .package_name = "p", .unique_id = "model.p.x", .name = "x", .path = "x.py", .original_file_path = "models/x.py", .raw_code = "" };
    try scan(a, "def model(dbt, session):\n dbt.config(materialized='table', meta={'owner': '\\u00e1'})\n x = dbt.ref('p','base',v=2)\n y = [dbt.source('raw','orders')]\n limit = dbt.config.get('limit', 9007199254740993)\n return x\n", &node);
    try std.testing.expectEqualStrings("table", node.materialized);
    try std.testing.expectEqualStrings("base", node.refs.items[0].name);
    try std.testing.expectEqualStrings("p", node.refs.items[0].package.?);
    try std.testing.expectEqual(@as(i64, 2), node.refs.items[0].version.integer);
    try std.testing.expectEqualStrings("orders", node.source_refs.items[0].table_name);
    try std.testing.expectEqualStrings("á", values.get(node.effective_config, "meta").?.object.get("owner").?.string);
    try std.testing.expectEqual(@as(i64, 9007199254740993), values.get(node.effective_config, "config_keys_defaults").?.array.items[0].integer);
}

test "Python model parser rejects invalid source contracts and nonliteral dbt calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var node = types.Node{ .package_name = "p", .unique_id = "model.p.x", .name = "x", .path = "x.py", .original_file_path = "models/x.py", .raw_code = "" };
    try std.testing.expectError(error.InvalidPythonModelSyntax, scan(a, "def model(dbt, session):\n return (\n", &node));
    try std.testing.expectError(error.InvalidPythonModelFunction, scan(a, "def model(other, session):\n return other\n", &node));
    try std.testing.expectError(error.InvalidPythonModelReturn, scan(a, "def model(dbt, session):\n return 1,2\n", &node));
    try std.testing.expectError(error.NonLiteralPythonModelArgument, scan(a, "def model(dbt, session):\n x = dbt.ref(name)\n return x\n", &node));
    try std.testing.expectError(error.JinjaInPythonModel, scan(a, "def model(dbt, session):\n return '{{ var(\"x\") }}'\n", &node));
}
