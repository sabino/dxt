//! Read-only psycopg2 bytea views retain their character-buffer protocol.
const std = @import("std");
const expr = @import("expression.zig");
const bytes = @import("yaml_values.zig");
const Value = expr.Value;
const A = std.mem.Allocator;
pub const State = struct { bytes: []const u8, format: u8 };
pub fn state(input: Value) ?State {
    const marker = input.attribute("__dxt_memoryview");
    if (marker != .callable or !std.mem.eql(u8, marker.callable, "__dxt_memoryview")) return null;
    const raw = input.attribute("__dxt_memoryview_bytes");
    const format = input.attribute("format");
    if (raw != .string or format != .string or format.string.len != 1) return null;
    return .{ .bytes = raw.string, .format = format.string[0] };
}
pub fn chunkIdentity(input: Value) ?[]const u8 {
    const marker = input.attribute("__dxt_memory_chunk");
    if (marker != .callable or !std.mem.eql(u8, marker.callable, "__dxt_memory_chunk")) return null;
    const identity = input.attribute("__dxt_memory_chunk_identity");
    return if (identity == .string) identity.string else null;
}
pub fn equal(left: Value, right: Value) ?bool {
    const lhs = state(left);
    const rhs = state(right);
    if (lhs == null and rhs == null) return null;
    if (lhs != null and rhs != null) {
        if (lhs.?.bytes.len == 0 and rhs.?.bytes.len == 0) return true;
        if ((lhs.?.format == 'c') != (rhs.?.format == 'c')) return false;
        if (lhs.?.bytes.len != rhs.?.bytes.len) return false;
        for (lhs.?.bytes, rhs.?.bytes) |x, y| {
            const a: i16 = if (lhs.?.format == 'b') @as(i8, @bitCast(x)) else x;
            const b: i16 = if (rhs.?.format == 'b') @as(i8, @bitCast(y)) else y;
            if (a != b) return false;
        }
        return true;
    }
    const view = lhs orelse rhs.?;
    const other = if (lhs != null) right else left;
    if (!bytes.isHashable(other)) return false;
    const raw = other.attribute("__dxt_binary");
    if (raw != .string or raw.string.len != view.bytes.len) return false;
    if (raw.string.len == 0) return true;
    if (view.format == 'c') return false;
    for (view.bytes, raw.string) |x, y| if ((if (view.format == 'b') @as(i16, @as(i8, @bitCast(x))) else @as(i16, x)) != y) return false;
    return true;
}
pub fn value(a: A, raw: []const u8, format: u8, original_chunk: ?Value) !Value {
    if (format != 'c' and format != 'b' and format != 'B') return error.InvalidQueryMemoryviewFormat;
    const owned = try a.dupe(u8, raw);
    const object = try bytes.fromBytes(a, owned);
    const token = try a.alloc(u8, 1);
    token[0] = 0;
    const chunk: Value = original_chunk orelse Value{ .object = try a.dupe(expr.Entry, &.{
        .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_memory_chunk", .value = .{ .callable = "__dxt_memory_chunk" } },
        .{ .key = "__dxt_memory_chunk_identity", .value = .{ .string = try std.fmt.allocPrint(a, "{x}", .{@intFromPtr(token.ptr)}) } },
        .{ .key = "__dxt_memory_chunk_size", .value = try expr.integerValue(a, raw.len) },
        .{ .key = "__dxt_rendered", .value = .{ .string = try std.fmt.allocPrint(a, "<memory chunk at 0x{x} size {d}>", .{ @intFromPtr(token.ptr), owned.len }) } },
    }) };
    const members = try expr.allocateValues(a, raw.len);
    for (raw, members) |byte, *member| member.* = if (format == 'c') try bytes.fromBytes(a, &.{byte}) else try expr.integerValue(a, if (format == 'b') @as(i16, @as(i8, @bitCast(byte))) else @as(i16, byte));
    const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
    _ = std.base64.standard.Encoder.encode(encoded, raw);
    var fields: std.ArrayList(expr.Entry) = .empty;
    try fields.appendSlice(a, &.{
        .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
        .{ .key = "__dxt_iterable", .value = .{ .list = members } },
        .{ .key = "__dxt_memoryview", .value = .{ .callable = "__dxt_memoryview" } },
        .{ .key = "__dxt_memoryview_bytes", .value = .{ .string = owned } },
        .{ .key = "__dxt_rendered", .value = .{ .string = try std.fmt.allocPrint(a, "<memory at 0x{x}>", .{@intFromPtr(members.ptr)}) } },
        .{ .key = "obj", .value = chunk },
        .{ .key = "format", .value = .{ .string = try a.dupe(u8, &.{format}) } },
        .{ .key = "itemsize", .value = .{ .integer = "1" } },
        .{ .key = "ndim", .value = .{ .integer = "1" } },
        .{ .key = "nbytes", .value = try expr.integerValue(a, raw.len) },
        .{ .key = "readonly", .value = .{ .boolean = true } },
        .{ .key = "c_contiguous", .value = .{ .boolean = true } },
        .{ .key = "f_contiguous", .value = .{ .boolean = true } },
        .{ .key = "contiguous", .value = .{ .boolean = true } },
        .{ .key = "shape", .value = .{ .tuple = try a.dupe(Value, &.{try expr.integerValue(a, raw.len)}) } },
        .{ .key = "strides", .value = .{ .tuple = &.{.{ .integer = "1" }} } },
        .{ .key = "suboffsets", .value = .{ .tuple = &.{} } },
        .{ .key = "hex", .value = object.attribute("hex") },
    });
    for ([_][]const u8{ "tobytes", "tolist", "cast", "toreadonly" }) |method| try fields.append(a, .{ .key = method, .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_memoryview:{s}:{c}:{s}:{d}:{s}", .{ method, format, chunkIdentity(chunk).?, try expr.integerIndex(chunk.attribute("__dxt_memory_chunk_size")), encoded }) } });
    return .{ .object = try fields.toOwnedSlice(a) };
}
pub fn call(a: A, name: []const u8, args: []const expr.Argument) anyerror!?Value {
    if (!std.mem.startsWith(u8, name, "__dxt_memoryview:")) return null;
    var parts = std.mem.splitScalar(u8, name["__dxt_memoryview:".len..], ':');
    const method = parts.next() orelse return error.InvalidJinjaArguments;
    const format = parts.next() orelse return error.InvalidJinjaArguments;
    const identity = parts.next() orelse return error.InvalidJinjaArguments;
    const chunk_size = std.fmt.parseUnsigned(usize, parts.next() orelse return error.InvalidJinjaArguments, 10) catch return error.InvalidJinjaArguments;
    const encoded = parts.rest();
    const binary = try bytes.binary(a, encoded);
    const raw = binary.attribute("__dxt_binary").string;
    if (std.mem.eql(u8, method, "tobytes")) {
        if (args.len > 1) return error.InvalidJinjaArguments;
        if (args.len == 1) {
            if (args[0].name) |keyword| if (!std.mem.eql(u8, keyword, "order")) return error.InvalidJinjaArguments;
            const order = args[0].value;
            if (order != .string) return error.JinjaTypeError;
            if (order.string.len != 1 or std.mem.indexOfScalar(u8, "CFA", order.string[0]) == null) return error.InvalidQueryMemoryviewOrder;
        }
        return binary;
    }
    var output_format = format[0];
    if (std.mem.eql(u8, method, "cast")) {
        if (args.len != 1 or args[0].value != .string or args[0].value.string.len != 1) return error.JinjaTypeError;
        output_format = args[0].value.string[0];
        if (output_format != 'c' and output_format != 'b' and output_format != 'B') return error.InvalidQueryMemoryviewFormat;
    } else if (args.len != 0) return error.InvalidJinjaArguments;
    const chunk: Value = .{ .object = try a.dupe(expr.Entry, &.{
        .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_memory_chunk", .value = .{ .callable = "__dxt_memory_chunk" } },
        .{ .key = "__dxt_memory_chunk_identity", .value = .{ .string = try a.dupe(u8, identity) } },
        .{ .key = "__dxt_memory_chunk_size", .value = try expr.integerValue(a, chunk_size) },
        .{ .key = "__dxt_rendered", .value = .{ .string = try std.fmt.allocPrint(a, "<memory chunk at 0x{s} size {d}>", .{ identity, chunk_size }) } },
    }) };
    const output = try value(a, raw, output_format, chunk);
    if (std.mem.eql(u8, method, "tolist")) return output.attribute("__dxt_iterable");
    return output;
}

test "psycopg bytea memoryview keeps character elements and opaque shared chunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const original = try value(a, &.{ 0, 255 }, 'c', null);
    try std.testing.expect(state(original) != null);
    try std.testing.expect(!equal(original, try bytes.fromBytes(a, &.{ 0, 255 })).?);
    const unsigned = (try call(a, original.attribute("cast").callable, &.{.{ .value = .{ .string = "B" } }})).?;
    try std.testing.expect(!equal(original, unsigned).?);
    try std.testing.expect(equal(unsigned, try bytes.fromBytes(a, &.{ 0, 255 })).?);
    try std.testing.expectEqualStrings(chunkIdentity(original.attribute("obj")).?, chunkIdentity(unsigned.attribute("obj")).?);
    try std.testing.expect(expr.sequence(original.attribute("obj")) == null);
    try std.testing.expect(expr.sequence(original).?[0].attribute("__dxt_binary") == .string);
    try std.testing.expectEqual(@as(usize, 0), original.attribute("suboffsets").tuple.len);
    const fake: Value = .{ .object = &.{.{ .key = "__dxt_memoryview", .value = .{ .string = "__dxt_memoryview" } }} };
    try std.testing.expect(state(fake) == null);
    const empty = try value(a, "", 'c', null);
    const second = try value(a, "", 'c', null);
    try std.testing.expect(!std.mem.eql(u8, chunkIdentity(empty.attribute("obj")).?, chunkIdentity(second.attribute("obj")).?));
    try std.testing.expect(equal(empty, try bytes.fromBytes(a, "")).?);
    const sliced = try value(a, &.{255}, 'c', original.attribute("obj"));
    const cast = (try call(a, sliced.attribute("cast").callable, &.{.{ .value = .{ .string = "B" } }})).?;
    try std.testing.expectEqualStrings(original.attribute("obj").attribute("__dxt_rendered").string, cast.attribute("obj").attribute("__dxt_rendered").string);
}
