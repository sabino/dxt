//! Native Python str.format fields used by dbt's SQL materialization macros.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const Argument = expression.Argument;

const lib_c = struct {
    extern fn snprintf(?[*]u8, usize, [*:0]const u8, ...) c_int;
};

// The expression engine uses the same allocation ceiling for native iteration.
const max_size: usize = 1_000_000;

fn decimalDigit(code: u21) ?u8 {
    // Unicode 15 decimal blocks (Nd), including the five mathematical styles.
    for ([_]u21{ 0x30, 0x660, 0x6f0, 0x7c0, 0x966, 0x9e6, 0xa66, 0xae6, 0xb66, 0xbe6, 0xc66, 0xce6, 0xd66, 0xde6, 0xe50, 0xed0, 0xf20, 0x1040, 0x1090, 0x17e0, 0x1810, 0x1946, 0x19d0, 0x1a80, 0x1a90, 0x1b50, 0x1bb0, 0x1c40, 0x1c50, 0xa620, 0xa8d0, 0xa900, 0xa9d0, 0xa9f0, 0xaa50, 0xabf0, 0xff10, 0x104a0, 0x10d30, 0x11066, 0x110f0, 0x11136, 0x111d0, 0x112f0, 0x11450, 0x114d0, 0x11650, 0x116c0, 0x11730, 0x118e0, 0x11950, 0x11c50, 0x11d50, 0x11da0, 0x11f50, 0x16a60, 0x16ac0, 0x16b50, 0x1d7ce, 0x1d7d8, 0x1d7e2, 0x1d7ec, 0x1d7f6, 0x1e140, 0x1e2f0, 0x1e4f0, 0x1e950, 0x1fbf0 }) |first| {
        if (code >= first and code < first + 10) return @intCast(code - first);
    }
    return null;
}

fn decimal(a: std.mem.Allocator, text: []const u8) !?[]const u8 {
    if (text.len == 0) return null;
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    var out: std.ArrayList(u8) = .empty;
    while (iterator.nextCodepoint()) |code| try out.append(a, '0' + (decimalDigit(code) orelse return null));
    return try out.toOwnedSlice(a);
}

fn takeDecimal(text: []const u8, position: *usize) !?usize {
    var result: usize = 0;
    const start = position.*;
    while (position.* < text.len) {
        const length = std.unicode.utf8ByteSequenceLength(text[position.*]) catch return error.InvalidJinjaExpression;
        if (position.* + length > text.len) return error.InvalidJinjaExpression;
        const code = std.unicode.utf8Decode(text[position.* .. position.* + length]) catch return error.InvalidJinjaExpression;
        const digit = decimalDigit(code) orelse break;
        if (result > (max_size - digit) / 10) return error.JinjaNumericOverflow;
        result = result * 10 + digit;
        position.* += length;
    }
    return if (position.* == start) null else result;
}

fn positional(args: []const Argument, index: usize) !Value {
    var seen: usize = 0;
    for (args) |arg| if (arg.name == null) {
        if (seen == index) return arg.value;
        seen += 1;
    };
    return error.JinjaIndexError;
}

fn ascii(a: std.mem.Allocator, value: Value) ![]const u8 {
    const representation = try expression.repr(value, a);
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    var iterator = (try std.unicode.Utf8View.init(representation)).iterator();
    while (iterator.nextCodepoint()) |code| {
        if (code < 128) try out.writer.writeByte(@intCast(code)) else if (code <= 0xff) try out.writer.print("\\x{x:0>2}", .{code}) else if (code <= 0xffff) try out.writer.print("\\u{x:0>4}", .{code}) else try out.writer.print("\\U{x:0>8}", .{code});
    }
    return out.toOwnedSlice();
}

const Numbering = struct { next: usize = 0, automatic: bool = false, manual: bool = false };

fn unsafeAttribute(value: Value, name: []const u8) bool {
    if (std.mem.eql(u8, name, "__class__")) return true;
    if (value != .object or value.attribute("__dxt_rendered") != .undefined) return false;
    // These attributes exist on Python dict, so SandboxedFormatter rejects
    // them before trying a same-named key. Unknown attributes still use the
    // ordinary dictionary fallback, including underscore-prefixed keys.
    for ([_][]const u8{
        "__class_getitem__", "__contains__", "__delattr__", "__delitem__", "__dir__", "__doc__", "__eq__", "__format__", "__ge__", "__getattribute__", "__getitem__", "__getstate__", "__gt__", "__hash__", "__init__", "__init_subclass__", "__ior__", "__iter__", "__le__", "__len__", "__lt__", "__ne__", "__new__", "__or__", "__reduce__", "__reduce_ex__", "__repr__", "__reversed__", "__ror__", "__setattr__", "__setitem__", "__sizeof__", "__str__", "__subclasshook__",
    }) |attribute| if (std.mem.eql(u8, name, attribute)) return true;
    return false;
}

fn fieldValue(a: std.mem.Allocator, field: []const u8, args: []const Argument, mapping: ?Value, numbering: *Numbering) !Value {
    const first_end = std.mem.indexOfAny(u8, field, ".[!") orelse field.len;
    const first = field[0..first_end];
    var result: Value = undefined;
    if (first.len == 0) {
        if (numbering.manual) return error.InvalidJinjaArguments;
        numbering.automatic = true;
        result = try positional(args, numbering.next);
        numbering.next += 1;
    } else if (try decimal(a, first)) |digits| {
        if (numbering.automatic) return error.InvalidJinjaArguments;
        numbering.manual = true;
        const index = std.fmt.parseInt(usize, digits, 10) catch return error.JinjaIndexError;
        result = try positional(args, index);
    } else {
        result = .undefined;
        var found = false;
        if (mapping) |container| {
            if (expression.isUndefined(container)) return error.UndefinedJinjaValue;
            if (container != .object) return error.JinjaTypeError;
            const string_index = container.attribute("__dxt_string_index");
            const dictionary = if (string_index == .object) string_index else container;
            if (try expression.mappingEntry(dictionary, .{ .string = first })) |entry| {
                result = entry.value;
                found = true;
            }
        } else for (args) |arg| if (arg.name) |name| if (std.mem.eql(u8, name, first)) {
            result = arg.value;
            found = true;
            break;
        };
        if (!found) return error.JinjaKeyError;
    }
    var position = first_end;
    while (position < field.len) {
        if (field[position] == '.') {
            position += 1;
            const end = position + (std.mem.indexOfAny(u8, field[position..], ".[!") orelse field.len - position);
            if (position == end) return error.InvalidJinjaExpression;
            const name = field[position..end];
            // SandboxedFormatter prefers attributes over dictionary items.
            // Python's real __class__ always wins over a same-named dict key;
            // the unsafe Undefined is harmless until a subsequent traversal.
            if (unsafeAttribute(result, name)) {
                if (expression.isUndefined(result)) return error.UndefinedJinjaValue;
                result = .undefined;
            } else if (std.mem.startsWith(u8, name, "__dxt_") and result.attribute("__dxt_rendered") != .undefined) {
                result = .undefined;
            } else result = try expression.checkedAttribute(result, name);
            position = end;
        } else if (field[position] == '[') {
            const end = std.mem.indexOfScalarPos(u8, field, position + 1, ']') orelse return error.InvalidJinjaExpression;
            const key = field[position + 1 .. end];
            if (key.len == 0) return error.InvalidJinjaExpression;
            const key_value: Value = if (try decimal(a, key)) |digits| .{ .integer = try @import("expression_number.zig").canonical(a, digits, 10) } else .{ .string = key };
            result = try getitem(a, result, key_value);
            position = end + 1;
        } else return error.InvalidJinjaExpression;
    }
    return result;
}

fn getitem(a: std.mem.Allocator, value: Value, key: Value) !Value {
    return expression.indexValue(a, value, key) catch |err| {
        if (err == error.JinjaTypeError) return .undefined;
        return err;
    };
}

const Spec = struct {
    fill: []const u8 = " ",
    alignment: u8 = 0,
    sign: u8 = 0,
    coerce_zero: bool = false,
    alternate: bool = false,
    zero: bool = false,
    explicit_fill: bool = false,
    width: usize = 0,
    group: u8 = 0,
    precision: ?usize = null,
    kind: u8 = 0,
};

fn alignment(c: u8) bool {
    return c == '<' or c == '>' or c == '=' or c == '^';
}

fn parseSpec(text: []const u8) !Spec {
    var spec = Spec{};
    var i: usize = 0;
    if (text.len != 0) {
        const length = std.unicode.utf8ByteSequenceLength(text[0]) catch return error.InvalidJinjaArguments;
        if (length < text.len and alignment(text[length])) {
            spec.fill = text[0..length];
            spec.explicit_fill = true;
            spec.alignment = text[length];
            i = length + 1;
        } else if (alignment(text[0])) {
            spec.alignment = text[0];
            i = 1;
        }
    }
    if (i < text.len and std.mem.indexOfScalar(u8, "+- ", text[i]) != null) {
        spec.sign = text[i];
        i += 1;
    }
    if (i < text.len and text[i] == 'z') {
        spec.coerce_zero = true;
        i += 1;
    }
    if (i < text.len and text[i] == '#') {
        spec.alternate = true;
        i += 1;
    }
    if (i < text.len and text[i] == '0') {
        spec.zero = true;
        i += 1;
    }
    spec.width = (try takeDecimal(text, &i)) orelse 0;
    if (i < text.len and (text[i] == ',' or text[i] == '_')) {
        spec.group = text[i];
        i += 1;
    }
    if (i < text.len and text[i] == '.') {
        i += 1;
        spec.precision = (try takeDecimal(text, &i)) orelse return error.InvalidJinjaArguments;
    }
    if (i < text.len) {
        spec.kind = text[i];
        i += 1;
    }
    if (i != text.len) return error.InvalidJinjaArguments;
    return spec;
}

fn repeat(out: *std.ArrayList(u8), a: std.mem.Allocator, text: []const u8, count: usize) !void {
    if (count > max_size or text.len > max_size / @max(count, 1)) return error.JinjaNumericOverflow;
    try out.ensureUnusedCapacity(a, text.len * count);
    for (0..count) |_| out.appendSliceAssumeCapacity(text);
}

fn padded(a: std.mem.Allocator, text: []const u8, original: Spec, numeric: bool, prefix_length: usize) ![]const u8 {
    var spec = original;
    if (spec.zero and !spec.explicit_fill) {
        spec.fill = "0";
        if (spec.alignment == 0 and numeric) spec.alignment = '=';
    }
    const direction = if (spec.alignment == 0) @as(u8, if (numeric) '>' else '<') else spec.alignment;
    const length = try std.unicode.utf8CountCodepoints(text);
    if (length >= spec.width) return text;
    const count = spec.width - length;
    var out: std.ArrayList(u8) = .empty;
    if (direction == '>' or direction == '^') try repeat(&out, a, spec.fill, if (direction == '^') count / 2 else count);
    if (direction == '=') {
        try out.appendSlice(a, text[0..prefix_length]);
        try repeat(&out, a, spec.fill, count);
        try out.appendSlice(a, text[prefix_length..]);
    } else try out.appendSlice(a, text);
    if (direction == '<' or direction == '^') try repeat(&out, a, spec.fill, if (direction == '^') count - count / 2 else count);
    return try out.toOwnedSlice(a);
}

fn grouped(a: std.mem.Allocator, digits: []const u8, separator: u8, size: usize) ![]const u8 {
    if (separator == 0 or digits.len == 0 or (size != 4 and !std.ascii.isDigit(digits[0]))) return digits;
    const end = if (size == 4) digits.len else std.mem.indexOfAny(u8, digits, ".eE%") orelse digits.len;
    var out: std.ArrayList(u8) = .empty;
    for (digits[0..end], 0..) |c, i| {
        if (i != 0 and (end - i) % size == 0) try out.append(a, separator);
        try out.append(a, c);
    }
    try out.appendSlice(a, digits[end..]);
    return try out.toOwnedSlice(a);
}

fn numberResult(a: std.mem.Allocator, digits_: []const u8, negative: bool, prefix: []const u8, spec: Spec, group_size: usize) ![]const u8 {
    const sign: []const u8 = if (negative) "-" else if (spec.sign == '+') "+" else if (spec.sign == ' ') " " else "";
    const lead = try std.mem.concat(a, u8, &.{ sign, prefix });
    var digits = digits_;
    const zero_padding = (spec.alignment == '=' or (spec.alignment == 0 and spec.zero)) and ((spec.zero and !spec.explicit_fill) or std.mem.eql(u8, spec.fill, "0"));
    if (zero_padding and spec.group != 0 and digits.len != 0 and (group_size == 4 or std.ascii.isDigit(digits[0]))) {
        // Python inserts grouping after sign-aware zero padding, which can
        // exceed the requested width when another separator becomes necessary.
        const integer_end = if (group_size == 4) digits.len else std.mem.indexOfAny(u8, digits, ".eE%") orelse digits.len;
        const suffix_length = digits.len - integer_end;
        var zeros: usize = 0;
        while (lead.len + suffix_length + integer_end + zeros + (integer_end + zeros - 1) / group_size < spec.width) zeros += 1;
        if (zeros != 0) {
            var padded_digits: std.ArrayList(u8) = .empty;
            try repeat(&padded_digits, a, "0", zeros);
            try padded_digits.appendSlice(a, digits);
            digits = try padded_digits.toOwnedSlice(a);
        }
    }
    digits = try grouped(a, digits, spec.group, group_size);
    return try padded(a, try std.mem.concat(a, u8, &.{ lead, digits }), spec, true, lead.len);
}

fn integerFormat(a: std.mem.Allocator, text: []const u8, spec: Spec) ![]const u8 {
    if (std.mem.indexOfScalar(u8, "eEfFgG%", spec.kind) != null and spec.kind != 0) return try floatFormat(a, try expression.numericFloat(.{ .integer = text }), spec, false);
    if (spec.precision != null or spec.coerce_zero) return error.InvalidJinjaArguments;
    const kind = if (spec.kind == 0) @as(u8, 'd') else spec.kind;
    if (kind == 'c') {
        if (spec.sign != 0 or spec.alternate or spec.group != 0) return error.InvalidJinjaArguments;
        const code = std.fmt.parseInt(u21, text, 10) catch return error.JinjaNumericOverflow;
        var buffer: [4]u8 = undefined;
        const length = std.unicode.utf8Encode(code, &buffer) catch return error.JinjaNumericOverflow;
        return try padded(a, try a.dupe(u8, buffer[0..length]), spec, true, 0);
    }
    const base: u8 = switch (kind) {
        'b' => 2,
        'o' => 8,
        'x', 'X' => 16,
        'd', 'n' => 10,
        else => return error.InvalidJinjaArguments,
    };
    if ((kind == 'n' and spec.group != 0) or (base != 10 and spec.group == ',')) return error.InvalidJinjaArguments;
    var number = try std.math.big.int.Managed.init(a);
    defer number.deinit();
    try number.setString(10, text);
    const negative = !number.isPositive();
    number.abs();
    const digits = try number.toString(a, base, if (kind == 'X') .upper else .lower);
    const prefix: []const u8 = if (!spec.alternate) "" else switch (kind) {
        'b' => "0b",
        'o' => "0o",
        'x' => "0x",
        'X' => "0X",
        else => "",
    };
    return try numberResult(a, digits, negative, prefix, spec, if (base == 10) 3 else 4);
}

fn cFloat(a: std.mem.Allocator, magnitude: f64, kind: u8, precision: usize, alternate: bool) ![]const u8 {
    const format = try a.dupeZ(u8, try std.fmt.allocPrint(a, "%{s}.*{c}", .{ if (alternate) "#" else "", kind }));
    const length = lib_c.snprintf(null, 0, format, @as(c_int, @intCast(precision)), magnitude);
    if (length < 0 or length > max_size) return error.JinjaNumericOverflow;
    const buffer = try a.alloc(u8, @as(usize, @intCast(length)) + 1);
    _ = lib_c.snprintf(buffer.ptr, buffer.len, format, @as(c_int, @intCast(precision)), magnitude);
    return buffer[0..@intCast(length)];
}

fn floatFormat(a: std.mem.Allocator, number: f64, spec: Spec, complex_component: bool) ![]const u8 {
    if (spec.kind != 0 and std.mem.indexOfScalar(u8, "eEfFgGn%", spec.kind) == null) return error.InvalidJinjaArguments;
    if (spec.kind == 'n' and spec.group != 0) return error.InvalidJinjaArguments;
    const magnitude = @abs(number) * @as(f64, if (spec.kind == '%') 100 else 1);
    var digits: []const u8 = undefined;
    if (spec.kind == 0 and spec.precision == null) {
        digits = try @import("expression_number.zig").floatText(a, magnitude);
        if (complex_component and std.mem.endsWith(u8, digits, ".0")) digits = digits[0 .. digits.len - 2];
        if (spec.alternate and std.math.isFinite(magnitude) and std.mem.indexOfScalar(u8, digits, '.') == null) {
            const end = std.mem.indexOfAny(u8, digits, "eE") orelse digits.len;
            digits = try std.mem.concat(a, u8, &.{ digits[0..end], ".", digits[end..] });
        }
    } else {
        const precision = spec.precision orelse 6;
        const kind = if (spec.kind == 0 or spec.kind == 'n') @as(u8, 'g') else if (spec.kind == '%') @as(u8, 'f') else spec.kind;
        digits = try cFloat(a, magnitude, kind, precision, spec.alternate);
        if (spec.kind == 0 and !complex_component and std.math.isFinite(magnitude)) {
            // Float's omitted presentation type retains a decimal point and
            // uses scientific notation at exponent >= precision - 1.
            const p = @max(precision, 1);
            const rounded = std.fmt.parseFloat(f64, digits) catch magnitude;
            const exponent = if (rounded == 0) 0 else @floor(@log10(rounded));
            if (exponent >= @as(f64, @floatFromInt(p - 1)) and std.mem.indexOfAny(u8, digits, "eE") == null) {
                digits = try cFloat(a, magnitude, 'e', p - 1, spec.alternate);
                if (!spec.alternate) {
                    const end = std.mem.indexOfScalar(u8, digits, 'e').?;
                    var decimal_end = end;
                    if (std.mem.indexOfScalar(u8, digits[0..end], '.')) |dot| {
                        while (decimal_end > dot + 1 and digits[decimal_end - 1] == '0') decimal_end -= 1;
                        if (decimal_end == dot + 1) decimal_end = dot;
                    }
                    digits = try std.mem.concat(a, u8, &.{ digits[0..decimal_end], digits[end..] });
                }
            } else if (std.mem.indexOfAny(u8, digits, ".eE") == null) digits = try std.mem.concat(a, u8, &.{ digits, ".0" });
        }
    }
    const rounded_zero = (std.fmt.parseFloat(f64, digits) catch 1) == 0;
    const negative = std.math.signbit(number) and !std.math.isNan(number) and !(spec.coerce_zero and rounded_zero);
    if (spec.kind == '%') digits = try std.mem.concat(a, u8, &.{ digits, "%" });
    return try numberResult(a, digits, negative, "", spec, 3);
}

fn complexFormat(a: std.mem.Allocator, value: @import("expression_complex.zig").Complex, original: Spec) ![]const u8 {
    if (original.zero or original.alignment == '=' or std.mem.eql(u8, original.fill, "0") or (original.kind != 0 and std.mem.indexOfScalar(u8, "eEfFgGn", original.kind) == null)) return error.InvalidJinjaArguments;
    var component = original;
    component.width = 0;
    component.alignment = 0;
    component.fill = " ";
    const omit_real = original.kind == 0 and value.real == 0 and !std.math.signbit(value.real);
    const real = if (omit_real) "" else try floatFormat(a, value.real, component, true);
    if (!omit_real) component.sign = '+';
    const imaginary = try floatFormat(a, value.imaginary, component, true);
    const parentheses = original.kind == 0 and !omit_real;
    const text = try std.mem.concat(a, u8, &.{ if (parentheses) "(" else "", real, imaginary, "j", if (parentheses) ")" else "" });
    return try padded(a, text, original, true, 0);
}

fn formatValue(a: std.mem.Allocator, value: Value, specification: []const u8) ![]const u8 {
    if (specification.len == 0) return try value.text(a);
    if (expression.floatProtocol(value)) |number| return try floatFormat(a, number, try parseSpec(specification), false);
    if (expression.integerProtocol(value)) |number| return try integerFormat(a, number, try parseSpec(specification));
    if (expression.complexProtocol(value)) |number| return try complexFormat(a, number, try parseSpec(specification));
    if (value == .integer) return try integerFormat(a, value.integer, try parseSpec(specification));
    if (value == .boolean) return try integerFormat(a, if (value.boolean) "1" else "0", try parseSpec(specification));
    if (value == .object) {
        const method = value.attribute("strftime");
        if (method == .callable and std.mem.startsWith(u8, method.callable, "__dxt_datetime:")) {
            const result = (try @import("timestamp_context.zig").call(a, method.callable, &.{.{ .value = .{ .string = specification } }})) orelse return error.JinjaTypeError;
            return try result.text(a);
        }
    }
    if (value != .string) return error.JinjaTypeError;
    const spec = try parseSpec(specification);
    if ((spec.kind != 0 and spec.kind != 's') or spec.sign != 0 or spec.coerce_zero or spec.alternate or spec.group != 0 or spec.alignment == '=') return error.InvalidJinjaArguments;
    var text = value.string;
    if (spec.precision) |maximum| {
        var iterator = (try std.unicode.Utf8View.init(text)).iterator();
        var end: usize = 0;
        for (0..maximum) |_| {
            const character = iterator.nextCodepointSlice() orelse break;
            end += character.len;
        }
        text = text[0..end];
    }
    return try padded(a, text, spec, false, 0);
}

fn renderLevel(a: std.mem.Allocator, format: []const u8, args: []const Argument, mapping: ?Value, numbering: *Numbering, depth: u8) anyerror![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var index: usize = 0;
    while (index < format.len) {
        const character = format[index];
        if ((character == '{' or character == '}') and index + 1 < format.len and format[index + 1] == character) {
            try out.append(a, character);
            index += 2;
        } else if (character == '{') {
            if (depth == 0) return error.InvalidJinjaExpression;
            var end = index + 1;
            var nesting: usize = 0;
            var in_bracket = false;
            var in_spec = false;
            while (end < format.len) : (end += 1) {
                const c = format[end];
                if (!in_spec) {
                    if (c == '[') in_bracket = true else if (c == ']') in_bracket = false;
                    if (c == ':' and !in_bracket) in_spec = true;
                    if (c == '{' and !in_bracket) return error.InvalidJinjaExpression;
                } else if (c == '{') nesting += 1;
                if (c == '}' and !in_bracket) {
                    if (nesting == 0) break;
                    nesting -= 1;
                }
            }
            if (end == format.len) return error.InvalidJinjaExpression;
            const field = format[index + 1 .. end];
            var conversion_at: ?usize = null;
            var specification_at: ?usize = null;
            in_bracket = false;
            for (field, 0..) |c, at| {
                if (c == '[') in_bracket = true else if (c == ']') in_bracket = false;
                if (!in_bracket and c == '!' and conversion_at == null) conversion_at = at;
                if (!in_bracket and c == ':') {
                    specification_at = at;
                    break;
                }
            }
            const name_end = @min(conversion_at orelse field.len, specification_at orelse field.len);
            var value = try fieldValue(a, field[0..name_end], args, mapping, numbering);
            if (conversion_at) |at| {
                if (at + 2 != (specification_at orelse field.len)) return error.InvalidJinjaExpression;
                const converted = switch (field[at + 1]) {
                    's' => try value.text(a),
                    'r' => try expression.repr(value, a),
                    'a' => try ascii(a, value),
                    else => return error.InvalidJinjaExpression,
                };
                value = .{ .string = converted };
            }
            const specification = if (specification_at) |at| try renderLevel(a, field[at + 1 ..], args, mapping, numbering, depth - 1) else "";
            const text = try formatValue(a, value, specification);
            try out.appendSlice(a, text);
            index = end + 1;
        } else if (character == '}') return error.InvalidJinjaExpression else {
            try out.append(a, character);
            index += 1;
        }
    }
    return out.toOwnedSlice(a);
}

pub fn render(a: std.mem.Allocator, format: []const u8, args: []const Argument) anyerror![]const u8 {
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    var numbering = Numbering{};
    return try a.dupe(u8, try renderLevel(scratch.allocator(), format, args, null, &numbering, 2));
}

pub fn renderMap(a: std.mem.Allocator, format: []const u8, args: []const Argument) anyerror![]const u8 {
    if (args.len != 1 or args[0].name != null) return error.InvalidJinjaArguments;
    var scratch = std.heap.ArenaAllocator.init(a);
    defer scratch.deinit();
    var numbering = Numbering{};
    return try a.dupe(u8, try renderLevel(scratch.allocator(), format, &.{}, args[0].value, &numbering, 2));
}

test "str.format keeps typed values, field paths, conversions and escaped braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try expression.evaluateArguments(a, "9007199254740993, 1.0, name='é'", null);
    try std.testing.expectEqualStrings("{9007199254740993} 1.0 'é' '\\xe9'", try render(a, "{{{0}}} {1} {name!r} {name!a}", args));
    try std.testing.expectError(error.InvalidJinjaArguments, render(a, "{} {0}", args));
    try std.testing.expectError(error.InvalidJinjaExpression, render(a, "{", args));
}

test "str.format applies native numeric and Unicode specification semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { format: []const u8, argument: []const u8, expected: []const u8 }{
        .{ .format = "{:010,}", .argument = "1234", .expected = "00,001,234" },
        .{ .format = "{:#012_X}", .argument = "11259375", .expected = "0X0_00AB_CDEF" },
        .{ .format = "{:🦆^7.2s}", .argument = "'é好😀'", .expected = "🦆🦆é好🦆🦆🦆" },
        .{ .format = "{:z.2f}", .argument = "-0.0001", .expected = "0.00" },
        .{ .format = "{:.2}", .argument = "9.99", .expected = "1e+01" },
        .{ .format = "{0:{1}.{2}f}", .argument = "1.2,8,3", .expected = "   1.200" },
        .{ .format = "{0[1]} {0[9]!r}", .argument = "'é好'", .expected = "好 Undefined" },
        .{ .format = "{0[01]} {0[missing]}", .argument = "{1:'typed','1':'string'}", .expected = "typed " },
        .{ .format = "{0.__globals__}:{0.__init__}:{0[__init__]}", .argument = "{'__globals__':'g','__init__':'data'}", .expected = "g::data" },
        .{ .format = "{0!a:>10}", .argument = "'é'", .expected = "    '\\xe9'" },
        .{ .format = "{:d}", .argument = "9007199254740993", .expected = "9007199254740993" },
    };
    for (cases) |case| {
        const args = try expression.evaluateArguments(a, case.argument, null);
        try std.testing.expectEqualStrings(case.expected, try render(a, case.format, args));
    }
}

test "str.format rejects invalid types, deep nesting and unsafe object traversal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try expression.evaluateArguments(a, "'text',2,3", null);
    try std.testing.expectError(error.InvalidJinjaArguments, render(a, "{:d}", args));
    try std.testing.expectError(error.InvalidJinjaExpression, render(a, "{0:{1:{2}}}", args));
    try std.testing.expectError(error.UndefinedJinjaValue, render(a, "{0.__class__.__mro__}", args));
    try std.testing.expectEqualStrings("", try render(a, "{0.__class__}", args));
}

test "str.format_map retains typed lookups and performs lazy mapping validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try expression.evaluateArguments(a, "{'value':1.25,'width':8,'precision':2}", null);
    try std.testing.expectEqualStrings("    1.25", try renderMap(a, "{value:{width}.{precision}f}", args));
    try std.testing.expectError(error.JinjaIndexError, renderMap(a, "{0}", args));
    try std.testing.expectError(error.JinjaKeyError, renderMap(a, "{missing}", args));
    try std.testing.expectEqualStrings("literal {}", try renderMap(a, "literal {{}}", &.{.{ .value = .none }}));
    try std.testing.expectError(error.InvalidJinjaArguments, renderMap(a, "literal", &.{}));
}

fn checkFormatAllocations(a: std.mem.Allocator) !void {
    const actual = try render(a, "{0:+012,.2f}", &.{.{ .value = .{ .number = -1234.5 } }});
    defer a.free(actual);
    try std.testing.expectEqualStrings("-0,001,234.50", actual);
}

test "str.format releases intermediate allocations on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkFormatAllocations, .{});
}
