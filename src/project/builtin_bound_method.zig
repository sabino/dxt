//! Saved builtin methods retain their receiver without retaining a render Host.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const Argument = expression.Argument;
const Allocator = std.mem.Allocator;
const marker = "__dxt_native_builtin_method";

pub fn isBound(value: Value) bool {
    const tag = value.attribute(marker);
    return tag == .callable and std.mem.eql(u8, tag.callable, marker);
}

pub fn isContextObject(value: Value) bool {
    const tag = value.attribute("__dxt_context_object");
    return tag == .callable and std.mem.eql(u8, tag.callable, "__dxt_context_object");
}

pub fn isMapping(value: Value) bool {
    if (value != .object or isContextObject(value) or isBound(value) or @import("datetime_bound_method.zig").isBound(value)) return false;
    if (@import("expression_sequence.zig").kind(value) != null or expression.tupleProtocol(value) != null) return false;
    if (@import("set_context.zig").isSet(value) or (expression.floatProtocol(value) != null or expression.complexProtocol(value) != null or expression.integerProtocol(value) != null)) return false;
    if (@import("datetime_protocol.zig").kind(value) != null or @import("timezone_context.zig").isTimezone(value)) return false;
    const getter = value.attribute("__dxt_getattr");
    if (getter == .callable and std.mem.startsWith(u8, getter.callable, "__dxt_loop_attribute:")) return false;
    return true;
}

fn owner(value: Value) ?[]const u8 {
    if (value == .string) return "str";
    if (value == .list) return "list";
    if (expression.tupleProtocol(value) != null) return "tuple";
    if (@import("set_context.zig").isSet(value)) return "set";
    if (expression.complexProtocol(value) != null) return "complex";
    // Read-only Mapping providers implement their own class methods. They are
    // not Python dict builtins, and must keep their existing provider dispatch.
    if (isMapping(value) and expression.mappingSource(value) == null) return "dict";
    return null;
}

fn hasName(name: []const u8, names: []const []const u8) bool {
    for (names) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

/// Only methods already implemented by native expression/container providers
/// are exposed here. Lookup itself never executes or consumes the receiver.
pub fn lookup(a: Allocator, receiver: Value, name: []const u8) !?Value {
    return lookupWithHost(a, receiver, name, null);
}

pub fn lookupWithHost(a: Allocator, receiver: Value, name: []const u8, host: ?expression.Host) !?Value {
    const type_name = owner(receiver) orelse return null;
    const supported = if (std.mem.eql(u8, type_name, "str"))
        hasName(name, &.{ "lower", "upper", "casefold", "startswith", "endswith", "find", "rfind", "count", "index", "rindex", "strip", "lstrip", "rstrip", "join", "split", "rsplit", "replace", "format", "format_map" })
    else if (std.mem.eql(u8, type_name, "dict"))
        hasName(name, &.{ "get", "keys", "values", "items", "copy", "update", "clear", "pop", "setdefault", "popitem" })
    else if (std.mem.eql(u8, type_name, "list"))
        hasName(name, &.{ "copy", "count", "index", "append", "extend", "clear", "pop" })
    else if (std.mem.eql(u8, type_name, "tuple"))
        hasName(name, &.{ "count", "index" })
    else if (std.mem.eql(u8, type_name, "set"))
        hasName(name, &.{ "copy", "clear", "add", "discard", "remove", "pop", "update", "union", "intersection", "difference", "symmetric_difference", "intersection_update", "difference_update", "symmetric_difference_update", "isdisjoint", "issubset", "issuperset" })
    else
        std.mem.eql(u8, name, "conjugate");
    return if (supported) try create(a, receiver, type_name, name, host) else null;
}

fn wrappedFormat(value: Value) bool {
    const kind = value.attribute("__dxt_builtin_owner");
    const name = value.attribute("__dxt_builtin_name");
    return kind == .string and std.mem.eql(u8, kind.string, "str") and name == .string and (std.mem.eql(u8, name.string, "format") or std.mem.eql(u8, name.string, "format_map"));
}

fn receiverPointer(receiver: Value) usize {
    return switch (receiver) {
        .object => @intFromPtr(receiver.object.ptr),
        .list => @intFromPtr(receiver.list.ptr),
        .tuple => @intFromPtr(receiver.tuple.ptr),
        .string => @intFromPtr(receiver.string.ptr),
        else => 0,
    };
}

fn create(a: Allocator, receiver: Value, type_name: []const u8, name: []const u8, host: ?expression.Host) !Value {
    const identity = if (host) |current| if (current.receiver_identity) |callback| try callback(current.context, receiver) else receiverPointer(receiver) else receiverPointer(receiver);
    return .{ .object = try a.dupe(expression.Entry, &.{
        .{ .key = marker, .value = .{ .callable = marker } },
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_callable", .value = .{ .callable = "__dxt_builtin_bound_call" } },
        .{ .key = "__dxt_builtin_owner", .value = .{ .string = type_name } },
        .{ .key = "__dxt_builtin_name", .value = .{ .string = name } },
        .{ .key = "__dxt_builtin_receiver", .value = receiver },
        .{ .key = "__dxt_builtin_receiver_identity", .value = try expression.integerValue(a, identity) },
        .{ .key = "__dxt_builtin_registered_identity", .value = .{ .boolean = host != null and host.?.receiver_identity != null } },
        .{ .key = "__dxt_builtin_portable_identity", .value = .{ .boolean = false } },
    }) };
}

pub fn render(a: Allocator, value: Value) ![]const u8 {
    if (!isBound(value)) return error.JinjaTypeError;
    const name = value.attribute("__dxt_builtin_name").string;
    const type_name = value.attribute("__dxt_builtin_owner").string;
    if (wrappedFormat(value)) return std.fmt.allocPrint(a, "<function str.{s} at 0x{x}>", .{ name, @intFromPtr(value.object.ptr) });
    const pointer = try std.fmt.parseInt(usize, value.attribute("__dxt_builtin_receiver_identity").integer, 10);
    return std.fmt.allocPrint(a, "<built-in method {s} of {s} object at 0x{x}>", .{ name, type_name, pointer });
}

fn sameReceiver(left: Value, right: Value) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .object => left.object.ptr == right.object.ptr,
        .list => left.list.ptr == right.list.ptr,
        .tuple => (left.tuple.len == 0 and right.tuple.len == 0) or left.tuple.ptr == right.tuple.ptr,
        .string => (left.string.len == 0 and right.string.len == 0) or (left.string.ptr == right.string.ptr and left.string.len == right.string.len),
        else => false,
    };
}

fn trustedIdentity(value: Value) bool {
    // Only mutable receivers can acquire new backing storage. Immutable string
    // views and tuples keep their existing pointer/length identity instead.
    const type_name = value.attribute("__dxt_builtin_owner");
    if (type_name != .string or !hasName(type_name.string, &.{ "dict", "list", "set" })) return false;
    const registered = value.attribute("__dxt_builtin_registered_identity");
    const portable = value.attribute("__dxt_builtin_portable_identity");
    return (registered == .boolean and registered.boolean) or (portable == .boolean and portable.boolean);
}

test "portable method IDs do not merge immutable string views" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try a.dupe(u8, "abcdef");
    const full = (try lookup(a, .{ .string = text }, "upper")).?;
    for (@constCast(full.object)) |*entry| {
        if (std.mem.eql(u8, entry.key, "__dxt_builtin_portable_identity")) entry.value = .{ .boolean = true };
    }
    const TestHost = struct {
        fn resolve(_: *anyopaque, _: []const u8, _: Allocator) !Value {
            return .undefined;
        }
        fn call(_: *anyopaque, _: []const u8, _: []const Argument, _: Allocator) !Value {
            return error.UnexpectedMethodInvocation;
        }
        fn identity(_: *anyopaque, receiver: Value) !usize {
            return @intFromPtr(receiver.string.ptr);
        }
    };
    var context: u8 = 0;
    const host: expression.Host = .{ .context = &context, .resolve = TestHost.resolve, .call = TestHost.call, .receiver_identity = TestHost.identity };
    const prefix = (try lookupWithHost(a, .{ .string = text[0..3] }, "upper", host)).?;
    try std.testing.expect(expression.equalValues(full.attribute("__dxt_builtin_receiver_identity"), prefix.attribute("__dxt_builtin_receiver_identity")));
    try std.testing.expect(!equal(full, prefix));
    try std.testing.expect(equal(full, (try lookupWithHost(a, .{ .string = text }, "upper", host)).?));
}

pub fn equal(left: Value, right: Value) bool {
    if (!isBound(left) or !isBound(right)) return false;
    if (left.object.ptr == right.object.ptr) return true;
    // SandboxedEnvironment.wrap_str_format creates fresh Python functions.
    if (wrappedFormat(left) or wrappedFormat(right)) return false;
    return expression.equalValues(left.attribute("__dxt_builtin_owner"), right.attribute("__dxt_builtin_owner")) and
        expression.equalValues(left.attribute("__dxt_builtin_name"), right.attribute("__dxt_builtin_name")) and
        (sameReceiver(left.attribute("__dxt_builtin_receiver"), right.attribute("__dxt_builtin_receiver")) or
            (trustedIdentity(left) and trustedIdentity(right) and
                expression.equalValues(left.attribute("__dxt_builtin_receiver_identity"), right.attribute("__dxt_builtin_receiver_identity"))));
}

pub fn call(a: Allocator, value: Value, args: []const Argument, host: ?expression.Host) anyerror!Value {
    if (!isBound(value)) return error.JinjaTypeError;
    var receiver = value.attribute("__dxt_builtin_receiver");
    if (host) |current| if (current.receiver_value) |forward| {
        receiver = try forward(current.context, receiver);
    };
    return expression.callBuiltinMethod(a, receiver, value.attribute("__dxt_builtin_name").string, args, host);
}

test "saved builtin methods have receiver equality and fresh lookup identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const receiver = Value{ .string = try a.dupe(u8, "hello world") };
    const other = Value{ .string = try a.dupe(u8, "hello world") };
    const first = (try lookup(a, receiver, "upper")).?;
    const repeated = (try lookup(a, receiver, "upper")).?;
    try std.testing.expect(equal(first, repeated));
    try std.testing.expect(!equal(first, (try lookup(a, other, "upper")).?));
    try std.testing.expect(first.object.ptr != repeated.object.ptr);
    try std.testing.expectEqualStrings("HELLO WORLD", (try call(a, first, &.{}, null)).string);
    try std.testing.expect(std.mem.startsWith(u8, try render(a, first), "<built-in method upper of str object at 0x"));
    const format = (try lookup(a, receiver, "format")).?;
    try std.testing.expect(equal(format, format));
    try std.testing.expect(!equal(format, (try lookup(a, receiver, "format")).?));
    try std.testing.expect(std.mem.startsWith(u8, try render(a, format), "<function str.format at 0x"));
    const authored = Value{ .object = &.{.{ .key = marker, .value = .{ .string = marker } }} };
    try std.testing.expect(!isBound(authored));
}

test "method keys retain receiver equality without exposing serialization or keyword fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const receiver = Value{ .object = try expression.allocateEntries(a, 0) };
    const first = (try lookup(a, receiver, "get")).?;
    const repeated = (try lookup(a, receiver, "get")).?;
    const distinct = (try lookup(a, .{ .object = try expression.allocateEntries(a, 0) }, "get")).?;
    var entries: std.ArrayList(expression.Entry) = .empty;
    try expression.mappingPut(a, &entries, first, .{ .integer = "1" });
    try expression.mappingPut(a, &entries, repeated, .{ .integer = "2" });
    try expression.mappingPut(a, &entries, distinct, .{ .integer = "3" });
    const mapping = Value{ .object = entries.items };
    try std.testing.expectEqual(@as(usize, 2), entries.items.len);
    try std.testing.expectEqualStrings("2", (try expression.mappingGet(mapping, first)).integer);
    try std.testing.expect(try expression.equalMemberChecked(first, repeated));
    try std.testing.expect((try expression.checkedAttribute(first, marker)) == .undefined);
    try std.testing.expect((try expression.indexValue(a, first, .{ .string = marker })) == .undefined);
    try std.testing.expectError(error.JinjaTypeError, @import("context_json.zig").stringify(a, first));
    try std.testing.expectError(error.JinjaTypeError, @import("expression_json.zig").render(a, first, null));

    const TestHost = struct {
        fn resolve(raw: *anyopaque, name: []const u8, _: Allocator) !Value {
            return if (std.mem.eql(u8, name, "method")) @as(*Value, @ptrCast(@alignCast(raw))).* else .undefined;
        }
        fn call(_: *anyopaque, _: []const u8, _: []const Argument, _: Allocator) !Value {
            return error.UnexpectedMethodInvocation;
        }
    };
    var stored = first;
    const host: expression.Host = .{ .context = &stored, .resolve = TestHost.resolve, .call = TestHost.call };
    try std.testing.expectError(error.InvalidJinjaArguments, expression.evaluate(a, "sink(**method)", host));
}

test "saved method rendering retains the render-owned receiver identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const TestHost = struct {
        fn resolve(_: *anyopaque, _: []const u8, _: Allocator) !Value {
            return .undefined;
        }
        fn call(_: *anyopaque, _: []const u8, _: []const Argument, _: Allocator) !Value {
            return error.UnexpectedMethodInvocation;
        }
        fn identity(raw: *anyopaque, _: Value) !usize {
            return @as(*usize, @ptrCast(@alignCast(raw))).*;
        }
    };
    var identity: usize = 0x1234;
    const host: expression.Host = .{ .context = &identity, .resolve = TestHost.resolve, .call = TestHost.call, .receiver_identity = TestHost.identity };
    const first = (try lookupWithHost(a, .{ .object = try expression.allocateEntries(a, 0) }, "get", host)).?;
    const second = (try lookupWithHost(a, .{ .object = try expression.allocateEntries(a, 0) }, "get", host)).?;
    try std.testing.expect(equal(first, second));
    try std.testing.expectEqualStrings("<built-in method get of dict object at 0x1234>", try render(a, first));
    try std.testing.expectEqualStrings(try render(a, first), try render(a, second));
}

test "authored boolean markers stay mappings while native providers stay closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const authored = try expression.evaluate(a, "{'__dxt_noniterable': true, '__dxt_set': true, '__dxt_context_object': '__dxt_context_object'}", null);
    try std.testing.expect(isMapping(authored));
    try std.testing.expect(!@import("set_context.zig").isSet(authored));
    try std.testing.expect((try lookup(a, authored, "get")) != null);
    const class = (try @import("modules_datetime.zig").resolve(a, "modules.datetime.date")).?;
    try std.testing.expect(isContextObject(class));
    try std.testing.expect(!isMapping(class));
    try std.testing.expect((try lookup(a, class, "get")) == null);
    try std.testing.expect((try expression.checkedAttribute(class, "__dxt_context_object")) == .undefined);
    const regex = (try @import("regex_context.zig").call(a, "modules.re.compile", &.{.{ .value = .{ .string = "x" } }}, null)).?;
    try std.testing.expect(isContextObject(regex));
    try std.testing.expect(!isMapping(regex));
    try std.testing.expect((try expression.checkedAttribute(regex, "__dxt_context_object")) == .undefined);
}

test "saved builtin calls resolve their receiver through the current render registry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const TestHost = struct {
        original: Value,
        current: Value,
        fn resolve(_: *anyopaque, _: []const u8, _: Allocator) !Value {
            return .undefined;
        }
        fn call(_: *anyopaque, _: []const u8, _: []const Argument, _: Allocator) !Value {
            return error.UnexpectedMethodInvocation;
        }
        fn receiver(raw: *anyopaque, stored: Value) !Value {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try std.testing.expect(stored.object.ptr == self.original.object.ptr);
            return self.current;
        }
    };
    var context = TestHost{
        .original = .{ .object = try a.dupe(expression.Entry, &.{.{ .key = "x", .value = .{ .integer = "1" } }}) },
        .current = .{ .object = try a.dupe(expression.Entry, &.{.{ .key = "x", .value = .{ .integer = "2" } }}) },
    };
    const host: expression.Host = .{ .context = &context, .resolve = TestHost.resolve, .call = TestHost.call, .receiver_value = TestHost.receiver };
    const get = (try lookupWithHost(a, context.original, "get", host)).?;
    try std.testing.expectEqualStrings("2", (try call(a, get, &.{.{ .value = .{ .string = "x" } }}, host)).integer);
    try std.testing.expect(get.attribute("__dxt_builtin_receiver").object.ptr == context.original.object.ptr);
}
