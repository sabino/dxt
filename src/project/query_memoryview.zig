//! Read-only psycopg2 buffers retain native formats, shapes and view lifetimes.
const std = @import("std");
const builtin = @import("builtin");
const expr = @import("expression.zig");
const bytes = @import("yaml_values.zig");
const Value = expr.Value;
const A = std.mem.Allocator;
const methods = [_][]const u8{ "tobytes", "tolist", "cast", "toreadonly", "release", "hex" };

fn field(input: Value, name: []const u8) Value {
    if (input == .object) for (input.object) |entry| if (std.mem.eql(u8, name, entry.key)) return entry.value;
    return .undefined;
}
fn marked(input: Value, name: []const u8) bool {
    const marker = field(input, name);
    return marker == .callable and std.mem.eql(u8, marker.callable, name);
}
fn formatCode(format: []const u8) ?u8 {
    const text = if (format.len > 0 and format[0] == '@') format[1..] else format;
    if (text.len != 1 or std.mem.indexOfScalar(u8, "cbB?hHiIlLqQnNefdP", text[0]) == null) return null;
    return text[0];
}
fn formatSize(code: u8) usize {
    return switch (code) {
        'c', 'b', 'B', '?' => 1,
        'h', 'H', 'e' => 2,
        'i', 'I', 'f' => 4,
        'l', 'L' => @sizeOf(c_long),
        'q', 'Q', 'd' => 8,
        'n', 'N', 'P' => @sizeOf(usize),
        else => unreachable,
    };
}
pub const State = struct {
    bytes: []const u8,
    format: u8,
    format_text: []const u8,
    itemsize: usize,
    shape: []const Value,
    strides: []const Value,
    release_cell: []const Value,
    released: bool,
    contiguous: bool,
    identity: []const u8,
    chunk: Value,
};
pub fn state(input: Value) ?State {
    if (!marked(input, "__dxt_memoryview") or !marked(input, "__dxt_context_object")) return null;
    const raw = field(input, "__dxt_memoryview_bytes");
    const format = field(input, "__dxt_memoryview_format");
    const shape = field(input, "__dxt_memoryview_shape");
    const strides = field(input, "__dxt_memoryview_strides");
    const released = field(input, "__dxt_memoryview_release");
    const identity = field(input, "__dxt_memoryview_identity");
    const contiguous = field(input, "__dxt_memoryview_contiguous");
    if (raw != .string or format != .string or shape != .tuple or strides != .tuple or released != .list or identity != .string or contiguous != .boolean) return null;
    if (released.list.len != 2 or released.list[0] != .boolean or released.list[1] != .boolean or shape.tuple.len != strides.tuple.len) return null;
    const code = formatCode(format.string) orelse return null;
    return .{ .bytes = raw.string, .format = code, .format_text = format.string, .itemsize = formatSize(code), .shape = shape.tuple, .strides = strides.tuple, .release_cell = released.list, .released = released.list[0].boolean, .contiguous = contiguous.boolean, .identity = identity.string, .chunk = field(input, "__dxt_memoryview_obj") };
}
pub fn checked(input: Value) !State {
    const result = state(input) orelse return error.JinjaTypeError;
    if (result.released) return error.ReleasedQueryMemoryview;
    return result;
}
pub fn isView(input: Value) bool {
    return state(input) != null;
}
pub fn iterable(input: Value) !bool {
    return (try checked(input)).shape.len != 0;
}
pub fn hashable(input: Value) !void {
    const view = state(input) orelse return error.JinjaTypeError;
    if (view.release_cell[1].boolean) return;
    _ = try checked(input);
    if (std.mem.indexOfScalar(u8, "cbB", view.format) == null) return error.InvalidQueryMemoryviewHash;
    @constCast(view.release_cell)[1] = .{ .boolean = true };
}
/// The default psycopg2 Binary adapter requests a C-contiguous buffer rather
/// than silently flattening a strided view. Numeric and ND formats are bytes.
pub fn parameterBytes(a: A, input: Value) !?[]const u8 {
    _ = state(input) orelse return null;
    const view = try checked(input);
    if (!view.contiguous) return error.NonContiguousQueryMemoryview;
    return try a.dupe(u8, view.bytes);
}
pub fn isMethod(input: Value) bool {
    return marked(input, "__dxt_memoryview_method") and marked(input, "__dxt_context_object");
}
pub fn chunkIdentity(input: Value) ?[]const u8 {
    if (!marked(input, "__dxt_memory_chunk")) return null;
    const identity = field(input, "__dxt_memory_chunk_identity");
    return if (identity == .string) identity.string else null;
}
fn size(input: Value) !usize {
    return std.math.cast(usize, try expr.integerIndex(input)) orelse error.JinjaTypeError;
}
pub fn length(input: Value) !usize {
    const view = try checked(input);
    if (view.shape.len == 0) return error.JinjaTypeError;
    return size(view.shape[0]);
}
pub fn render(a: A, input: Value) !?[]const u8 {
    if (isMethod(input)) {
        const name = field(input, "__dxt_memoryview_method_name");
        if (name != .string) return error.JinjaTypeError;
        const receiver = state(field(input, "__dxt_memoryview_receiver")) orelse return error.JinjaTypeError;
        // Built-in method repr keeps its receiver's identity even after the
        // buffer is released; rendering never reads the buffer contents.
        return try std.fmt.allocPrint(a, "<built-in method {s} of memoryview object at 0x{s}>", .{ name.string, receiver.identity });
    }
    const view = state(input) orelse return null;
    return try std.fmt.allocPrint(a, "<{s}memory at 0x{s}>", .{ if (view.released) @as([]const u8, "released ") else "", view.identity });
}
pub fn attribute(a: A, input: Value, name: []const u8) !?Value {
    _ = state(input) orelse return null;
    for (methods) |method| if (std.mem.eql(u8, name, method)) return try methodValue(a, input, method);
    const result = field(input, name);
    // Unknown attributes remain Undefined; public buffer properties require a
    // live view. Native protocol metadata is private to its callers.
    if (result != .undefined and !std.mem.startsWith(u8, name, "__dxt_")) _ = try checked(input);
    return result;
}
fn methodValue(a: A, input: Value, name: []const u8) !Value {
    // The thin state contains no methods and shares its mutable release cell.
    // Saved methods therefore survive memoized clones without graph cycles.
    var entries: std.ArrayList(expr.Entry) = .empty;
    for (input.object) |entry| if (std.mem.startsWith(u8, entry.key, "__dxt_memoryview") or std.mem.eql(u8, entry.key, "__dxt_context_object")) try entries.append(a, entry);
    return .{ .object = try a.dupe(expr.Entry, &.{
        .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
        .{ .key = "__dxt_memoryview_method", .value = .{ .callable = "__dxt_memoryview_method" } },
        .{ .key = "__dxt_memoryview_receiver", .value = .{ .object = try entries.toOwnedSlice(a) } },
        .{ .key = "__dxt_memoryview_method_name", .value = .{ .string = try a.dupe(u8, name) } },
    }) };
}
fn chunk(a: A, raw_size: usize) !Value {
    const token = try a.alloc(u8, 1);
    token[0] = 0;
    const identity = try std.fmt.allocPrint(a, "{x}", .{@intFromPtr(token.ptr)});
    return .{ .object = try a.dupe(expr.Entry, &.{
        .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_memory_chunk", .value = .{ .callable = "__dxt_memory_chunk" } },
        .{ .key = "__dxt_memory_chunk_identity", .value = .{ .string = identity } },
        .{ .key = "__dxt_memory_chunk_size", .value = try expr.integerValue(a, raw_size) },
        .{ .key = "__dxt_rendered", .value = .{ .string = try std.fmt.allocPrint(a, "<memory chunk at 0x{s} size {d}>", .{ identity, raw_size }) } },
    }) };
}
pub fn value(a: A, raw: []const u8, format: u8, original_chunk: ?Value) !Value {
    const width = formatSize(formatCode(&.{format}) orelse return error.InvalidQueryMemoryviewFormat);
    if (raw.len % width != 0) return error.JinjaTypeError;
    return construct(a, raw, &.{format}, &.{try expr.integerValue(a, raw.len / width)}, null, true, original_chunk);
}
fn construct(a: A, raw: []const u8, format: []const u8, shape: []const Value, supplied_strides: ?[]const Value, contiguous: bool, original_chunk: ?Value) anyerror!Value {
    const code = formatCode(format) orelse return error.InvalidQueryMemoryviewFormat;
    const itemsize = formatSize(code);
    const owned = try a.dupe(u8, raw);
    const source = original_chunk orelse try chunk(a, raw.len);
    const shape_owned = try a.dupe(Value, shape);
    const strides = try a.alloc(Value, shape.len);
    if (supplied_strides) |provided| @memcpy(strides, provided) else {
        var stride = itemsize;
        var i = shape.len;
        while (i != 0) {
            i -= 1;
            strides[i] = try expr.integerValue(a, stride);
            stride = std.math.mul(usize, stride, try size(shape[i])) catch return error.JinjaTypeError;
        }
    }
    const release_cell = try a.dupe(Value, &.{ .{ .boolean = false }, .{ .boolean = false } });
    const identity = try std.fmt.allocPrint(a, "{x}", .{@intFromPtr(release_cell.ptr)});
    const format_owned = try a.dupe(u8, format);
    var fields: std.ArrayList(expr.Entry) = .empty;
    try fields.appendSlice(a, &.{
        .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
        .{ .key = "__dxt_memoryview", .value = .{ .callable = "__dxt_memoryview" } },
        .{ .key = "__dxt_memoryview_bytes", .value = .{ .string = owned } },
        .{ .key = "__dxt_memoryview_format", .value = .{ .string = format_owned } },
        .{ .key = "__dxt_memoryview_shape", .value = .{ .tuple = shape_owned } },
        .{ .key = "__dxt_memoryview_strides", .value = .{ .tuple = strides } },
        .{ .key = "__dxt_memoryview_release", .value = .{ .list = release_cell } },
        .{ .key = "__dxt_memoryview_identity", .value = .{ .string = identity } },
        .{ .key = "__dxt_memoryview_contiguous", .value = .{ .boolean = contiguous } },
        .{ .key = "__dxt_memoryview_obj", .value = source },
        .{ .key = "__dxt_rendered", .value = .{ .string = try std.fmt.allocPrint(a, "<memory at 0x{s}>", .{identity}) } },
        .{ .key = "obj", .value = source },
        .{ .key = "format", .value = .{ .string = format_owned } },
        .{ .key = "itemsize", .value = try expr.integerValue(a, itemsize) },
        .{ .key = "ndim", .value = try expr.integerValue(a, shape.len) },
        .{ .key = "nbytes", .value = try expr.integerValue(a, raw.len) },
        .{ .key = "readonly", .value = .{ .boolean = true } },
        .{ .key = "c_contiguous", .value = .{ .boolean = contiguous } },
        .{ .key = "f_contiguous", .value = .{ .boolean = contiguous and nontrivialDimensions(shape) <= 1 } },
        .{ .key = "contiguous", .value = .{ .boolean = contiguous } },
        .{ .key = "shape", .value = .{ .tuple = shape_owned } },
        .{ .key = "strides", .value = .{ .tuple = strides } },
        .{ .key = "suboffsets", .value = .{ .tuple = &.{} } },
    });
    const thin: Value = .{ .object = fields.items };
    if (shape.len == 1) try fields.append(a, .{ .key = "__dxt_iterable", .value = .{ .list = try values(a, thin) } });
    for (methods) |method| {
        // Appending may move fields.items, so each method captures only owned
        // thin-state entries, never the ArrayList's borrowed backing slice.
        const current: Value = .{ .object = fields.items };
        const bound_method = try methodValue(a, current, method);
        try fields.append(a, .{ .key = method, .value = bound_method });
    }
    return .{ .object = try fields.toOwnedSlice(a) };
}
fn nontrivialDimensions(shape: []const Value) usize {
    var count: usize = 0;
    for (shape) |dim| if ((size(dim) catch return 2) > 1) {
        count += 1;
    };
    return count;
}
const Scalar = union(enum) { character: u8, signed: i64, unsigned: u64, floating: f64, boolean: bool };
fn scalar(view: State, index_: usize) Scalar {
    const raw = view.bytes[index_ * view.itemsize ..][0..view.itemsize];
    const endian = builtin.target.cpu.arch.endian();
    const unsigned: u64 = switch (raw.len) {
        1 => raw[0],
        2 => std.mem.readInt(u16, raw[0..2], endian),
        4 => std.mem.readInt(u32, raw[0..4], endian),
        8 => std.mem.readInt(u64, raw[0..8], endian),
        else => unreachable,
    };
    return switch (view.format) {
        'c' => .{ .character = @intCast(unsigned) },
        '?' => .{ .boolean = unsigned != 0 },
        'b', 'h', 'i', 'l', 'q', 'n' => .{ .signed = switch (view.itemsize) {
            1 => @as(i8, @bitCast(@as(u8, @intCast(unsigned)))),
            2 => @as(i16, @bitCast(@as(u16, @intCast(unsigned)))),
            4 => @as(i32, @bitCast(@as(u32, @intCast(unsigned)))),
            8 => @as(i64, @bitCast(unsigned)),
            else => unreachable,
        } },
        'e' => .{ .floating = @floatCast(@as(f16, @bitCast(@as(u16, @intCast(unsigned))))) },
        'f' => .{ .floating = @floatCast(@as(f32, @bitCast(@as(u32, @intCast(unsigned))))) },
        'd' => .{ .floating = @as(f64, @bitCast(unsigned)) },
        else => .{ .unsigned = unsigned },
    };
}
fn scalarValue(a: A, input: Scalar) !Value {
    return switch (input) {
        .character => |byte| bytes.fromBytes(a, &.{byte}),
        .signed => |n| expr.integerValue(a, n),
        .unsigned => |n| expr.integerValue(a, n),
        .floating => |n| expr.floatValue(a, n),
        .boolean => |n| .{ .boolean = n },
    };
}
pub fn values(a: A, input: Value) ![]const Value {
    const view = try checked(input);
    if (view.shape.len == 0) return error.JinjaTypeError;
    if (view.shape.len != 1) return error.UnsupportedQueryMemoryviewSubview;
    const result = try expr.allocateValues(a, view.bytes.len / view.itemsize);
    for (result, 0..) |*item, i| item.* = try scalarValue(a, scalar(view, i));
    return result;
}
fn scalarEqual(left: Scalar, right: Scalar) bool {
    if (left == .character or right == .character) return left == .character and right == .character and left.character == right.character;
    const lhs = if (left == .boolean) Scalar{ .unsigned = @intFromBool(left.boolean) } else left;
    const rhs = if (right == .boolean) Scalar{ .unsigned = @intFromBool(right.boolean) } else right;
    if (lhs == .floating and rhs == .floating) return lhs.floating == rhs.floating;
    if (lhs == .floating) return integerFloatEqual(rhs, lhs.floating);
    if (rhs == .floating) return integerFloatEqual(lhs, rhs.floating);
    if (lhs == .signed and rhs == .signed) return lhs.signed == rhs.signed;
    if (lhs == .unsigned and rhs == .unsigned) return lhs.unsigned == rhs.unsigned;
    const signed = if (lhs == .signed) lhs.signed else rhs.signed;
    const unsigned = if (lhs == .unsigned) lhs.unsigned else rhs.unsigned;
    return signed >= 0 and @as(u64, @intCast(signed)) == unsigned;
}
fn integerFloatEqual(integer: Scalar, number: f64) bool {
    if (!std.math.isFinite(number)) return false;
    if (integer == .signed) return number >= -0x1p63 and number < 0x1p63 and @as(f64, @floatFromInt(@as(i64, @intFromFloat(number)))) == number and @as(i64, @intFromFloat(number)) == integer.signed;
    return number >= 0 and number < 0x1p64 and @as(f64, @floatFromInt(@as(u64, @intFromFloat(number)))) == number and @as(u64, @intFromFloat(number)) == integer.unsigned;
}
pub fn equal(left: Value, right: Value) ?bool {
    const lhs = state(left);
    const rhs = state(right);
    if (lhs == null and rhs == null) return null;
    if (lhs != null and rhs != null) {
        if (lhs.?.released or rhs.?.released) return lhs.?.release_cell.ptr == rhs.?.release_cell.ptr;
        if (lhs.?.shape.len != rhs.?.shape.len) return false;
        for (lhs.?.shape, rhs.?.shape) |x, y| if (!expr.equalValues(x, y)) return false;
        const count = lhs.?.bytes.len / lhs.?.itemsize;
        if (count != rhs.?.bytes.len / rhs.?.itemsize) return false;
        for (0..count) |i| if (!scalarEqual(scalar(lhs.?, i), scalar(rhs.?, i))) return false;
        return true;
    }
    const view = lhs orelse rhs.?;
    const other = if (lhs != null) right else left;
    const raw = field(other, "__dxt_binary");
    if (view.released or !bytes.isHashable(other) or raw != .string or view.shape.len != 1 or view.bytes.len / view.itemsize != raw.string.len) return false;
    for (raw.string, 0..) |byte, i| if (!scalarEqual(scalar(view, i), .{ .unsigned = byte })) return false;
    return true;
}
fn tolist(a: A, view: State) anyerror!Value {
    var cursor: usize = 0;
    return nestedList(a, view, 0, &cursor);
}
fn nestedList(a: A, view: State, depth: usize, cursor: *usize) anyerror!Value {
    if (depth == view.shape.len) {
        const result = try scalarValue(a, scalar(view, cursor.*));
        cursor.* += 1;
        return result;
    }
    const members = try expr.allocateValues(a, try size(view.shape[depth]));
    for (members) |*member| member.* = try nestedList(a, view, depth + 1, cursor);
    return .{ .list = members };
}
fn orderedBytes(a: A, view: State, order: u8) !Value {
    if (order != 'F' or view.shape.len <= 1) return bytes.fromBytes(a, view.bytes);
    const result = try a.alloc(u8, view.bytes.len);
    for (0..view.bytes.len / view.itemsize) |i| {
        var remaining = i;
        var position: usize = 0;
        for (view.shape) |dim| {
            const dimension = try size(dim);
            position = position * dimension + remaining % dimension;
            remaining /= dimension;
        }
        @memcpy(result[i * view.itemsize ..][0..view.itemsize], view.bytes[position * view.itemsize ..][0..view.itemsize]);
    }
    return bytes.fromBytes(a, result);
}
fn arguments(args: []const expr.Argument, names: []const []const u8) ![2]?Value {
    var result: [2]?Value = .{ null, null };
    var position: usize = 0;
    for (args) |arg| {
        const at = if (arg.name) |keyword| blk: {
            for (names, 0..) |name, i| if (std.mem.eql(u8, name, keyword)) break :blk i;
            return error.InvalidJinjaArguments;
        } else blk: {
            const index_ = position;
            position += 1;
            break :blk index_;
        };
        if (at >= names.len or result[at] != null) return error.InvalidJinjaArguments;
        result[at] = arg.value;
    }
    return result;
}
pub fn callValue(a: A, callee: Value, args: []const expr.Argument) anyerror!?Value {
    if (!isMethod(callee)) return null;
    const receiver = field(callee, "__dxt_memoryview_receiver");
    const name = field(callee, "__dxt_memoryview_method_name");
    if (name != .string) return error.InvalidJinjaArguments;
    const current = state(receiver) orelse return error.JinjaTypeError;
    if (std.mem.eql(u8, name.string, "release")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        @constCast(current.release_cell)[0] = .{ .boolean = true };
        return .none;
    }
    const view = try checked(receiver);
    if (std.mem.eql(u8, name.string, "tobytes")) {
        const parsed = try arguments(args, &.{"order"});
        var order: u8 = 'C';
        if (parsed[0]) |provided| if (provided != .none) {
            if (provided != .string) return error.JinjaTypeError;
            if (provided.string.len != 1 or std.mem.indexOfScalar(u8, "CFA", provided.string[0]) == null) return error.InvalidQueryMemoryviewOrder;
            order = provided.string[0];
        };
        return try orderedBytes(a, view, order);
    }
    if (std.mem.eql(u8, name.string, "hex")) {
        const binary = try bytes.fromBytes(a, view.bytes);
        return (try bytes.call(a, binary.attribute("hex").callable, args)).?;
    }
    if (std.mem.eql(u8, name.string, "cast")) {
        const parsed = try arguments(args, &.{ "format", "shape" });
        const format = parsed[0] orelse return error.InvalidJinjaArguments;
        if (format != .string) return error.JinjaTypeError;
        const code = formatCode(format.string) orelse return error.InvalidQueryMemoryviewFormat;
        if (!view.contiguous or (std.mem.indexOfScalar(u8, "cbB", code) == null and std.mem.indexOfScalar(u8, "cbB", view.format) == null)) return error.JinjaTypeError;
        const width = formatSize(code);
        if (view.bytes.len % width != 0) return error.JinjaTypeError;
        const shape = if (parsed[1]) |provided| blk: {
            const dims = expr.tupleProtocol(provided) orelse (if (provided == .list) provided.list else return error.JinjaTypeError);
            if (dims.len > 64) return error.InvalidQueryMemoryviewShape;
            var count: usize = 1;
            const normalized = try a.alloc(Value, dims.len);
            for (dims, normalized) |dim, *owned_dim| {
                const positive = try expr.integerIndex(dim);
                if (positive <= 0) return error.InvalidQueryMemoryviewShape;
                const dimension: usize = @intCast(positive);
                owned_dim.* = try expr.integerValue(a, dimension);
                count = std.math.mul(usize, count, dimension) catch return error.JinjaTypeError;
            }
            if (count != view.bytes.len / width) return error.JinjaTypeError;
            break :blk normalized;
        } else try a.dupe(Value, &.{try expr.integerValue(a, view.bytes.len / width)});
        if (view.shape.len != 1 and shape.len != 1) return error.JinjaTypeError;
        return try construct(a, view.bytes, format.string, shape, null, true, view.chunk);
    }
    if (args.len != 0) return error.InvalidJinjaArguments;
    if (std.mem.eql(u8, name.string, "tolist")) return try tolist(a, view);
    if (std.mem.eql(u8, name.string, "toreadonly")) return try construct(a, view.bytes, view.format_text, view.shape, view.strides, view.contiguous, view.chunk);
    return error.UndefinedJinjaValue;
}
/// Compatibility for already-created serialized method names during upgrades.
pub fn call(a: A, name: []const u8, args: []const expr.Argument) anyerror!?Value {
    if (!std.mem.startsWith(u8, name, "__dxt_memoryview:")) return null;
    var parts = std.mem.splitScalar(u8, name["__dxt_memoryview:".len..], ':');
    const method = parts.next() orelse return error.InvalidJinjaArguments;
    const format = parts.next() orelse return error.InvalidJinjaArguments;
    const identity = parts.next() orelse return error.InvalidJinjaArguments;
    const chunk_size = std.fmt.parseUnsigned(usize, parts.next() orelse return error.InvalidJinjaArguments, 10) catch return error.InvalidJinjaArguments;
    const binary = try bytes.binary(a, parts.rest());
    const source = try chunk(a, chunk_size);
    for (@constCast(source.object)) |*entry| {
        if (std.mem.eql(u8, entry.key, "__dxt_memory_chunk_identity")) entry.value = .{ .string = try a.dupe(u8, identity) };
        if (std.mem.eql(u8, entry.key, "__dxt_rendered")) entry.value = .{ .string = try std.fmt.allocPrint(a, "<memory chunk at 0x{s} size {d}>", .{ identity, chunk_size }) };
    }
    if (format.len != 1) return error.InvalidQueryMemoryviewFormat;
    const original = try value(a, binary.attribute("__dxt_binary").string, format[0], source);
    return callValue(a, try methodValue(a, original, method), args);
}
fn bound(input: Value) !i64 {
    const text = expr.integerProtocol(input) orelse (if (input == .integer) input.integer else return expr.integerIndex(input));
    return std.fmt.parseInt(i64, text, 10) catch if (text.len > 0 and text[0] == '-') std.math.minInt(i64) else std.math.maxInt(i64);
}
fn optionalBound(input: ?Value) !?i64 {
    const provided = input orelse return null;
    return if (provided == .none) null else try bound(provided);
}
fn cContiguous(shape: []const Value, strides: []const Value, itemsize: usize) !bool {
    var expected: usize = itemsize;
    var i = shape.len;
    while (i != 0) {
        i -= 1;
        const dimension = try size(shape[i]);
        // A single element has no stride constraint. Empty dimensions keep
        // their stride test, as CPython's empty reversed view does.
        if (dimension != 1 and try expr.integerIndex(strides[i]) != std.math.cast(i64, expected)) return false;
        expected = std.math.mul(usize, expected, dimension) catch return false;
    }
    return true;
}
pub fn slice(a: A, input: Value, start: ?Value, stop: ?Value, step: ?Value) anyerror!Value {
    const view = try checked(input);
    if (view.shape.len == 0) return error.JinjaTypeError;
    const length_ = try expr.integerIndex(view.shape[0]);
    const stride = (try optionalBound(step)) orelse 1;
    if (stride == 0) return error.InvalidJinjaArguments;
    const first_bound = try optionalBound(start);
    const last_bound = try optionalBound(stop);
    var first = first_bound orelse if (stride > 0) @as(i64, 0) else length_ - 1;
    var last = last_bound orelse if (stride > 0) length_ else @as(i64, -1);
    if (first_bound != null and first < 0) first = std.math.add(i64, first, length_) catch std.math.maxInt(i64);
    if (last_bound != null and last < 0) last = std.math.add(i64, last, length_) catch std.math.maxInt(i64);
    first = std.math.clamp(first, if (stride > 0) @as(i64, 0) else -1, if (stride > 0) length_ else length_ - 1);
    last = std.math.clamp(last, if (stride > 0) @as(i64, 0) else -1, if (stride > 0) length_ else length_ - 1);
    var row_size = view.itemsize;
    for (view.shape[1..]) |dim| row_size = std.math.mul(usize, row_size, try size(dim)) catch return error.JinjaTypeError;
    var result: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    var i = first;
    while (if (stride > 0) i < last else i > last) {
        const at = @as(usize, @intCast(i)) * row_size;
        try result.appendSlice(a, view.bytes[at..][0..row_size]);
        count += 1;
        i = std.math.add(i64, i, stride) catch break;
    }
    const shape = try a.dupe(Value, view.shape);
    shape[0] = try expr.integerValue(a, count);
    const strides = try a.dupe(Value, view.strides);
    strides[0] = try expr.integerValue(a, std.math.mul(i64, try expr.integerIndex(strides[0]), stride) catch return error.JinjaTypeError);
    return construct(a, result.items, view.format_text, shape, strides, try cContiguous(shape, strides, view.itemsize), view.chunk);
}
pub fn index(a: A, input: Value, key: Value) anyerror!Value {
    const view = try checked(input);
    const dimensions = expr.tupleProtocol(key);
    if (dimensions == null and view.shape.len > 1) return error.UnsupportedQueryMemoryviewSubview;
    if (dimensions == null and view.shape.len == 0) return error.JinjaTypeError;
    const keys = dimensions orelse &.{key};
    if (keys.len != view.shape.len) return error.JinjaTypeError;
    var position: usize = 0;
    for (keys, view.shape) |k, dimension| {
        const length_ = try expr.integerIndex(dimension);
        var at = try expr.integerIndex(k);
        if (at < 0) at += length_;
        if (at < 0 or at >= length_) return error.JinjaIndexError;
        position = position * @as(usize, @intCast(length_)) + @as(usize, @intCast(at));
    }
    return scalarValue(a, scalar(view, position));
}
fn invoke(a: A, input: Value, name: []const u8, args: []const expr.Argument) !Value {
    return (try callValue(a, try methodValue(a, input, name), args)).?;
}

test "psycopg bytea memoryview keeps character elements and opaque shared chunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original = try value(a, &.{ 0, 255 }, 'c', null);
    const unsigned = try invoke(a, original, "cast", &.{.{ .value = .{ .string = "B" } }});
    try std.testing.expect(!equal(original, unsigned).?);
    try std.testing.expect(equal(unsigned, try bytes.fromBytes(a, &.{ 0, 255 })).?);
    try std.testing.expectEqualStrings(chunkIdentity(original.attribute("obj")).?, chunkIdentity(unsigned.attribute("obj")).?);
    try std.testing.expect(expr.sequence(original.attribute("obj")) == null);
    try std.testing.expect(expr.sequence(original).?[0].attribute("__dxt_binary") == .string);
    const fake: Value = .{ .object = &.{.{ .key = "__dxt_memoryview", .value = .{ .string = "__dxt_memoryview" } }} };
    try std.testing.expect(state(fake) == null);
    const empty = try value(a, "", 'c', null);
    try std.testing.expect(!std.mem.eql(u8, chunkIdentity(empty.attribute("obj")).?, chunkIdentity((try value(a, "", 'c', null)).attribute("obj")).?));
    try std.testing.expect(equal(empty, try bytes.fromBytes(a, "")).?);
    const cast = try invoke(a, try slice(a, original, .{ .integer = "1" }, null, null), "cast", &.{.{ .value = .{ .string = "B" } }});
    try std.testing.expectEqualStrings(original.attribute("obj").attribute("__dxt_rendered").string, cast.attribute("obj").attribute("__dxt_rendered").string);
}

test "psycopg saved method rendering retains method names and receiver identity after release" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const view = try value(a, "ab", 'c', null);
    const identity = state(view).?.identity;
    const saved = try attribute(a, view, "tobytes");
    const before = (try render(a, saved.?)).?;
    for (methods) |name| {
        const first = (try attribute(a, view, name)).?;
        const second = (try attribute(a, view, name)).?;
        const expected = try std.fmt.allocPrint(a, "<built-in method {s} of memoryview object at 0x{s}>", .{ name, identity });
        try std.testing.expectEqualStrings(expected, (try render(a, first)).?);
        try std.testing.expectEqualStrings(expected, (try render(a, second)).?);
    }
    const peer = try invoke(a, view, "cast", &.{.{ .value = .{ .string = "B" } }});
    try std.testing.expect(!std.mem.eql(u8, before, (try render(a, (try attribute(a, peer, "tobytes")).?)).?));
    _ = try invoke(a, view, "release", &.{});
    try std.testing.expectEqualStrings(before, (try render(a, saved.?)).?);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "<released memory at 0x{s}>", .{identity}), (try render(a, view)).?);
    const authored = Value{ .object = &.{
        .{ .key = "__dxt_context_object", .value = .{ .string = "__dxt_context_object" } },
        .{ .key = "__dxt_memoryview_method", .value = .{ .string = "__dxt_memoryview_method" } },
    } };
    try std.testing.expect((try render(a, authored)) == null);
}

test "psycopg memoryview casts native numeric formats and validates method arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ints = [_]i32{ 1, -2, 3, 4 };
    const original = try value(a, std.mem.sliceAsBytes(&ints), 'c', null);
    const integer = try invoke(a, original, "cast", &.{.{ .name = "format", .value = .{ .string = "@i" } }});
    try std.testing.expectEqualStrings("@i", integer.attribute("format").string);
    try std.testing.expectEqual(@as(usize, 4), state(integer).?.itemsize);
    try std.testing.expectEqualStrings("[1, -2, 3, 4]", try (try invoke(a, integer, "tolist", &.{})).text(a));
    for ([_][]const u8{ "c", "b", "B", "?", "h", "H", "i", "I", "l", "L", "q", "Q", "n", "N", "e", "f", "d", "P", "@B" }) |format| {
        const cast = try invoke(a, original, "cast", &.{.{ .value = .{ .string = format } }});
        const roundtrip = try invoke(a, cast, "cast", &.{.{ .value = .{ .string = "c" } }});
        try std.testing.expectEqualSlices(u8, state(original).?.bytes, state(roundtrip).?.bytes);
        try std.testing.expectEqualStrings(chunkIdentity(state(original).?.chunk).?, chunkIdentity(state(cast).?.chunk).?);
    }
    const half: u16 = 0x3c00;
    const half_view = try invoke(a, try value(a, std.mem.asBytes(&half), 'c', null), "cast", &.{.{ .value = .{ .string = "e" } }});
    try std.testing.expectEqual(@as(f64, 1.0), expr.floatProtocol(try index(a, half_view, .{ .integer = "0" })).?);
    try std.testing.expectError(error.JinjaTypeError, invoke(a, integer, "cast", &.{.{ .value = .{ .string = "h" } }}));
    try std.testing.expectError(error.JinjaTypeError, invoke(a, try value(a, "abc", 'c', null), "cast", &.{.{ .value = .{ .string = "i" } }}));
    for ([_][]const u8{ "<i", ">i", "!i", "=i", "ii", "", "2i", "s", "x" }) |format| try std.testing.expectError(error.InvalidQueryMemoryviewFormat, invoke(a, original, "cast", &.{.{ .value = .{ .string = format } }}));
    try std.testing.expectError(error.InvalidJinjaArguments, invoke(a, original, "cast", &.{}));
    try std.testing.expectError(error.InvalidJinjaArguments, invoke(a, original, "cast", &.{ .{ .value = .{ .string = "i" } }, .{ .name = "format", .value = .{ .string = "i" } } }));
    try std.testing.expectError(error.JinjaTypeError, invoke(a, original, "cast", &.{.{ .value = .{ .integer = "1" } }}));
}

test "psycopg memoryview shape supports scalar and multidimensional lists and Fortran bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ints = [_]i32{ 1, -2, 3, 4 };
    const original = try value(a, std.mem.sliceAsBytes(&ints), 'c', null);
    const shape: Value = .{ .list = &.{ .{ .integer = "2" }, .{ .integer = "2" } } };
    const matrix = try invoke(a, original, "cast", &.{ .{ .value = .{ .string = "i" } }, .{ .name = "shape", .value = shape } });
    try std.testing.expectEqualStrings("[[1, -2], [3, 4]]", try (try invoke(a, matrix, "tolist", &.{})).text(a));
    try std.testing.expectEqualStrings("(8, 4)", try matrix.attribute("strides").text(a));
    const bool_shape = try invoke(a, original, "cast", &.{ .{ .value = .{ .string = "i" } }, .{ .value = .{ .list = &.{ .{ .boolean = true }, .{ .integer = "4" } } } } });
    try std.testing.expectEqualStrings("(1, 4)", try bool_shape.attribute("shape").text(a));
    try std.testing.expect(matrix.attribute("c_contiguous").boolean and !matrix.attribute("f_contiguous").boolean);
    const expected_f = [_]i32{ 1, 3, -2, 4 };
    const fortran = try invoke(a, matrix, "tobytes", &.{.{ .name = "order", .value = .{ .string = "F" } }});
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&expected_f), fortran.attribute("__dxt_binary").string);
    for ([_]Value{ .none, .{ .string = "C" }, .{ .string = "A" } }) |order| try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&ints), (try invoke(a, matrix, "tobytes", &.{.{ .value = order }})).attribute("__dxt_binary").string);
    try std.testing.expectEqualStrings("3", (try index(a, matrix, .{ .tuple = &.{ .{ .integer = "1" }, .{ .integer = "0" } } })).integer);
    try std.testing.expectError(error.UnsupportedQueryMemoryviewSubview, index(a, matrix, .{ .integer = "0" }));
    try std.testing.expectError(error.UnsupportedQueryMemoryviewSubview, values(a, matrix));
    const scalar_view = try invoke(a, try value(a, std.mem.sliceAsBytes(ints[0..1]), 'c', null), "cast", &.{ .{ .value = .{ .string = "i" } }, .{ .value = .{ .tuple = &.{} } } });
    try std.testing.expectEqualStrings("1", (try invoke(a, scalar_view, "tolist", &.{})).integer);
    try std.testing.expectEqualStrings("1", (try index(a, scalar_view, .{ .tuple = &.{} })).integer);
    try std.testing.expectError(error.JinjaTypeError, length(scalar_view));
    try std.testing.expectError(error.JinjaTypeError, index(a, scalar_view, .{ .integer = "0" }));
    try std.testing.expect(!try iterable(scalar_view));
    try std.testing.expectError(error.InvalidQueryMemoryviewOrder, invoke(a, original, "tobytes", &.{.{ .value = .{ .string = "c" } }}));
    try std.testing.expectError(error.JinjaTypeError, invoke(a, original, "tobytes", &.{.{ .value = .{ .integer = "1" } }}));
    try std.testing.expectError(error.InvalidJinjaArguments, invoke(a, original, "tobytes", &.{.{ .name = "unknown", .value = .{ .string = "C" } }}));
    try std.testing.expectError(error.InvalidQueryMemoryviewShape, invoke(a, original, "cast", &.{ .{ .value = .{ .string = "i" } }, .{ .value = .{ .list = &.{.{ .integer = "0" }} } } }));
    try std.testing.expectError(error.InvalidQueryMemoryviewShape, invoke(a, original, "cast", &.{ .{ .value = .{ .string = "i" } }, .{ .value = .{ .list = &.{.{ .integer = "-1" }} } } }));
    try std.testing.expectError(error.JinjaTypeError, invoke(a, original, "cast", &.{ .{ .value = .{ .string = "i" } }, .{ .value = .none } }));
    try std.testing.expectError(error.JinjaTypeError, invoke(a, original, "cast", &.{ .{ .value = .{ .string = "i" } }, .{ .value = .{ .list = &.{.{ .integer = "3" }} } } }));
}

test "psycopg memoryview slices retain numeric rows stride and original chunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ints = [_]i32{ 1, -2, 3, 4 };
    const original = try value(a, std.mem.sliceAsBytes(&ints), 'c', null);
    const integer = try invoke(a, original, "cast", &.{.{ .value = .{ .string = "i" } }});
    const stride = try slice(a, integer, null, null, .{ .integer = "2" });
    try std.testing.expectEqualStrings("[1, 3]", try (try invoke(a, stride, "tolist", &.{})).text(a));
    try std.testing.expectEqualStrings("(8,)", try stride.attribute("strides").text(a));
    try std.testing.expect(!stride.attribute("contiguous").boolean);
    try std.testing.expectError(error.JinjaTypeError, invoke(a, stride, "cast", &.{.{ .value = .{ .string = "B" } }}));
    const reverse = try slice(a, integer, null, null, .{ .integer = "-1" });
    try std.testing.expectEqualStrings("[4, 3, -2, 1]", try (try invoke(a, reverse, "tolist", &.{})).text(a));
    try std.testing.expectEqualStrings("(-4,)", try reverse.attribute("strides").text(a));
    const restored = try slice(a, reverse, null, null, .{ .integer = "-1" });
    try std.testing.expect(restored.attribute("contiguous").boolean);
    _ = try invoke(a, restored, "cast", &.{.{ .value = .{ .string = "B" } }});
    const singleton = try slice(a, integer, .{ .integer = "0" }, .{ .integer = "1" }, .{ .integer = "2" });
    try std.testing.expect(singleton.attribute("contiguous").boolean);
    const empty_reverse = try slice(a, try slice(a, integer, .{ .integer = "0" }, .{ .integer = "0" }, null), null, null, .{ .integer = "-1" });
    try std.testing.expect(!empty_reverse.attribute("contiguous").boolean);
    try std.testing.expectEqualStrings(chunkIdentity(state(original).?.chunk).?, chunkIdentity(state(reverse).?.chunk).?);
    const matrix = try invoke(a, original, "cast", &.{ .{ .value = .{ .string = "i" } }, .{ .value = .{ .tuple = &.{ .{ .integer = "2" }, .{ .integer = "2" } } } } });
    const rows = try slice(a, matrix, null, null, .{ .integer = "-1" });
    try std.testing.expectEqualStrings("[[3, 4], [1, -2]]", try (try invoke(a, rows, "tolist", &.{})).text(a));
    try std.testing.expectEqualStrings("(-8, 4)", try rows.attribute("strides").text(a));
    try std.testing.expectError(error.InvalidJinjaArguments, slice(a, integer, null, null, .{ .integer = "0" }));
}

test "psycopg memoryview numeric equality compares values and retains NaN behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const integers = [_]i32{ 1, 2 };
    const floats = [_]f32{ 1, 2 };
    const lhs = try value(a, std.mem.sliceAsBytes(&integers), 'i', null);
    const rhs = try value(a, std.mem.sliceAsBytes(&floats), 'f', null);
    try std.testing.expect(equal(lhs, rhs).?);
    const nan: f32 = std.math.nan(f32);
    const nan_view = try value(a, std.mem.asBytes(&nan), 'f', null);
    try std.testing.expect(!equal(nan_view, nan_view).?);
    const booleans = try value(a, &.{ 1, 0, 1 }, '?', null);
    try std.testing.expect(equal(booleans, try value(a, &.{ 1, 0, 1 }, 'B', null)).?);
    try std.testing.expect(!equal(booleans, try value(a, &.{ 2, 0, 1 }, 'B', null)).?);
    const large: u64 = 9_007_199_254_740_993;
    const rounded: f64 = 9_007_199_254_740_992;
    try std.testing.expect(!equal(try value(a, std.mem.asBytes(&large), 'Q', null), try value(a, std.mem.asBytes(&rounded), 'd', null)).?);
}

test "psycopg memoryview release invalidates aliases and saved methods independently of casts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original = try value(a, "abc", 'c', null);
    const saved = (try attribute(a, original, "tobytes")).?;
    const release = (try attribute(a, original, "release")).?;
    const peer = try invoke(a, original, "cast", &.{.{ .value = .{ .string = "B" } }});
    try std.testing.expect((try callValue(a, release, &.{})).? == .none);
    try std.testing.expect((try callValue(a, release, &.{})).? == .none);
    try std.testing.expect(isView(original));
    try std.testing.expectError(error.ReleasedQueryMemoryview, checked(original));
    try std.testing.expectError(error.ReleasedQueryMemoryview, callValue(a, saved, &.{}));
    try std.testing.expectError(error.ReleasedQueryMemoryview, attribute(a, original, "format"));
    try std.testing.expectError(error.ReleasedQueryMemoryview, length(original));
    try std.testing.expectError(error.ReleasedQueryMemoryview, values(a, original));
    try std.testing.expectError(error.ReleasedQueryMemoryview, iterable(original));
    try std.testing.expectError(error.ReleasedQueryMemoryview, hashable(original));
    try std.testing.expect(equal(original, original).? and !equal(original, peer).?);
    try std.testing.expectEqualStrings("abc", (try invoke(a, peer, "tobytes", &.{})).attribute("__dxt_binary").string);
    try std.testing.expect(std.mem.startsWith(u8, (try render(a, original)).?, "<released memory at 0x"));
    const cached = try value(a, "abc", 'c', null);
    try hashable(cached);
    _ = try invoke(a, cached, "release", &.{});
    try hashable(cached);
    try std.testing.expectError(error.InvalidQueryMemoryviewHash, hashable(peer_cast: {
        const zero: i32 = 0;
        break :peer_cast try value(a, std.mem.asBytes(&zero), 'i', null);
    }));
}

test "psycopg memoryview parameter buffers preserve formats and reject release or strides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ints = [_]i32{ 1, 2 };
    const original = try value(a, std.mem.sliceAsBytes(&ints), 'c', null);
    const cast = try invoke(a, original, "cast", &.{.{ .value = .{ .string = "i" } }});
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&ints), (try parameterBytes(a, cast)).?);
    try std.testing.expectError(error.NonContiguousQueryMemoryview, parameterBytes(a, try slice(a, cast, null, null, .{ .integer = "-1" })));
    _ = try invoke(a, cast, "release", &.{});
    try std.testing.expectError(error.ReleasedQueryMemoryview, parameterBytes(a, cast));
    try std.testing.expect((try parameterBytes(a, .{ .string = "ordinary" })) == null);
}

fn allocationProbe(a: A) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    const ints = [_]i32{ 1, -2, 3, 4 };
    const original = try value(scratch, std.mem.sliceAsBytes(&ints), 'c', null);
    const matrix = try invoke(scratch, original, "cast", &.{ .{ .value = .{ .string = "i" } }, .{ .value = .{ .list = &.{ .{ .integer = "2" }, .{ .integer = "2" } } } } });
    _ = try invoke(scratch, matrix, "tolist", &.{});
    _ = try invoke(scratch, matrix, "tobytes", &.{.{ .value = .{ .string = "F" } }});
    _ = try slice(scratch, matrix, null, null, .{ .integer = "-1" });
    const saved = (try attribute(scratch, original, "tobytes")).?;
    _ = try invoke(scratch, original, "release", &.{});
    if (callValue(scratch, saved, &.{})) |_| return error.ExpectedReleasedView else |err| if (err != error.ReleasedQueryMemoryview) return err;
}

test "psycopg memoryview construction methods and release retain arena ownership on failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
