//! Owned, typed native graph persistence. Runtime/session pointers never cross
//! this boundary; containers are reconstructed with the invocation allocator.
const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");
const Value = std.json.Value;

pub fn liveField(comptime name: []const u8) bool {
    @setEvalBranchQuota(100000);
    for (.{ "allocator", "environment", "invocation", "command_options", "timing_profile", "relation_cache", "execution_hooks", "log_collector", "unit_fixture_relations", "unit_overrides", "unit_fixture_aliases", "connection_info", "target_context", "duckdb_credentials", "target_threads", "adapter_type", "target_schema", "database_path", "database_path_base", "profile_name", "target_name", "full_refresh", "parser_cache_hit", "parser_cache_reason", "parser_cache_changes", "parser_cache_reused_files" }) |key| if (std.mem.eql(u8, name, key)) return true;
    return false;
}

pub fn encodeGraph(a: std.mem.Allocator, graph: *const types.Graph) !Value {
    var object: Value = .{ .object = .empty };
    inline for (std.meta.fields(types.Graph)) |field| {
        if (comptime !liveField(field.name)) try object.object.put(a, try a.dupe(u8, field.name), try encode(a, @field(graph, field.name)));
    }
    return object;
}

pub fn decodeGraph(a: std.mem.Allocator, graph: *types.Graph, object: Value) !void {
    if (object != .object) return error.InvalidParseCache;
    inline for (std.meta.fields(types.Graph)) |field| {
        if (comptime !liveField(field.name)) {
            const stored = object.object.get(field.name) orelse return error.InvalidParseCache;
            @field(graph, field.name) = try decode(field.type, a, stored);
        }
    }
}

pub fn encodeNode(a: std.mem.Allocator, node: types.Node) !Value {
    return encode(a, node);
}
pub fn decodeNode(a: std.mem.Allocator, node: Value) !types.Node {
    return decode(types.Node, a, node);
}

fn arrayList(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "items") and @hasField(T, "capacity");
}

fn encode(a: std.mem.Allocator, source: anytype) anyerror!Value {
    const T = @TypeOf(source);
    if (T == Value) return values.clone(a, source);
    if (comptime arrayList(T)) return encode(a, source.items);
    return switch (@typeInfo(T)) {
        .bool => .{ .bool = source },
        .int => .{ .integer = std.math.cast(i64, source) orelse return error.InvalidParseCache },
        .float => .{ .float = source },
        .@"enum" => .{ .string = try a.dupe(u8, @tagName(source)) },
        .optional => if (source) |value| encode(a, value) else .null,
        .pointer => |pointer| blk: {
            if (pointer.size != .slice) @compileError("unexpected pointer in persistent graph");
            if (pointer.child == u8) break :blk .{ .string = try a.dupe(u8, source) };
            var array = std.json.Array.init(a);
            for (source) |value| try array.append(try encode(a, value));
            break :blk .{ .array = array };
        },
        .array => blk: {
            var array = std.json.Array.init(a);
            for (source) |value| try array.append(try encode(a, value));
            break :blk .{ .array = array };
        },
        .@"struct" => blk: {
            var object: Value = .{ .object = .empty };
            inline for (std.meta.fields(T)) |field| {
                const value = if (T == types.GenericTestConfig and std.mem.eql(u8, field.name, "configured_order"))
                    try encode(a, source.configured_order[0..source.configured_order_len])
                else
                    try encode(a, @field(source, field.name));
                try object.object.put(a, try a.dupe(u8, field.name), value);
            }
            break :blk object;
        },
        .@"union" => blk: {
            var object: Value = .{ .object = .empty };
            const tag = std.meta.activeTag(source);
            try object.object.put(a, try a.dupe(u8, "tag"), .{ .string = try a.dupe(u8, @tagName(tag)) });
            inline for (std.meta.fields(T)) |field| if (std.mem.eql(u8, field.name, @tagName(tag))) {
                try object.object.put(a, try a.dupe(u8, "value"), try encode(a, @field(source, field.name)));
            };
            break :blk object;
        },
        else => @compileError("unexpected type in persistent graph: " ++ @typeName(T)),
    };
}

fn decode(comptime T: type, a: std.mem.Allocator, source: Value) anyerror!T {
    if (T == Value) return values.clone(a, source);
    if (comptime arrayList(T)) {
        if (source != .array) return error.InvalidParseCache;
        var list: T = .empty;
        const Child = @typeInfo(@TypeOf(list.items)).pointer.child;
        for (source.array.items) |value| try list.append(a, try decode(Child, a, value));
        return list;
    }
    return switch (@typeInfo(T)) {
        .bool => if (source == .bool) source.bool else error.InvalidParseCache,
        .int => if (source == .integer) std.math.cast(T, source.integer) orelse error.InvalidParseCache else error.InvalidParseCache,
        .float => if (source == .float) @floatCast(source.float) else if (source == .integer) @floatFromInt(source.integer) else error.InvalidParseCache,
        .@"enum" => if (source == .string) std.meta.stringToEnum(T, source.string) orelse error.InvalidParseCache else error.InvalidParseCache,
        .optional => |optional| if (source == .null) null else try decode(optional.child, a, source),
        .pointer => |pointer| blk: {
            if (pointer.size != .slice) @compileError("unexpected pointer in persistent graph");
            if (pointer.child == u8) {
                if (source != .string) return error.InvalidParseCache;
                break :blk try a.dupe(u8, source.string);
            }
            if (source != .array) return error.InvalidParseCache;
            const items = try a.alloc(pointer.child, source.array.items.len);
            for (source.array.items, items) |value, *target| target.* = try decode(pointer.child, a, value);
            break :blk items;
        },
        .array => |array| blk: {
            if (source != .array or source.array.items.len > array.len) return error.InvalidParseCache;
            var target: T = undefined;
            for (source.array.items, target[0..source.array.items.len]) |value, *item| item.* = try decode(array.child, a, value);
            break :blk target;
        },
        .@"struct" => blk: {
            if (source != .object) return error.InvalidParseCache;
            var target: T = undefined;
            inline for (std.meta.fields(T)) |field| {
                @field(target, field.name) = try decode(field.type, a, source.object.get(field.name) orelse return error.InvalidParseCache);
            }
            if (T == types.GenericTestConfig and (target.configured_order_len > target.configured_order.len or source.object.get("configured_order").?.array.items.len != target.configured_order_len)) return error.InvalidParseCache;
            break :blk target;
        },
        .@"union" => blk: {
            if (source != .object) return error.InvalidParseCache;
            const tag = source.object.get("tag") orelse return error.InvalidParseCache;
            const value = source.object.get("value") orelse return error.InvalidParseCache;
            if (tag != .string) return error.InvalidParseCache;
            inline for (std.meta.fields(T)) |field| if (std.mem.eql(u8, field.name, tag.string)) break :blk @unionInit(T, field.name, try decode(field.type, a, value));
            return error.InvalidParseCache;
        },
        else => @compileError("unexpected type in persistent graph: " ++ @typeName(T)),
    };
}

test "native parse cache owns groups, singular configs and union containers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var original: types.Graph = .{ .allocator = a, .project_name = "cached", .connection_info = "password=not-persisted" };
    defer original.deinit();
    original.duckdb_credentials = try std.json.parseFromSliceLeaky(Value, a, "{\"secrets\":[{\"type\":\"http\",\"bearer_token\":\"private-cached-token\"}]}", .{});
    try original.groups.append(a, try std.json.parseFromSliceLeaky(Value, a, "{\"name\":\"finance\",\"owner\":{\"name\":\"Team\"}}", .{}));
    try original.singular_tests.append(a, .{ .package_name = "cached", .unique_id = "test.cached.verify", .name = "verify", .alias = "verify", .path = "tests/verify.sql", .original_file_path = "tests/verify.sql", .raw_code = "select 1", .config_values = try std.json.parseFromSliceLeaky(Value, a, "{\"group\":\"finance\"}", .{}) });
    var stored = try encodeGraph(a, &original);
    defer values.deinit(a, &stored);
    const bytes = try std.json.Stringify.valueAlloc(a, stored, .{});
    try std.testing.expect(std.mem.indexOf(u8, bytes, "not-persisted") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "private-cached-token") == null);
    var restored: types.Graph = .{ .allocator = a, .project_name = "live", .connection_info = "password=live" };
    defer restored.deinit();
    restored.duckdb_credentials = try std.json.parseFromSliceLeaky(Value, a, "{\"secrets\":[{\"type\":\"http\",\"bearer_token\":\"private-live-token\"}]}", .{});
    try decodeGraph(a, &restored, stored);
    try std.testing.expectEqualStrings("cached", restored.project_name);
    try std.testing.expectEqualStrings("password=live", restored.connection_info.?);
    try std.testing.expectEqualStrings("private-live-token", restored.duckdb_credentials.object.get("secrets").?.array.items[0].object.get("bearer_token").?.string);
    try std.testing.expectEqualStrings("finance", restored.groups.items[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("finance", restored.singular_tests.items[0].config_values.object.get("group").?.string);
    try stored.object.getPtr("groups").?.array.append(.null);
    try std.testing.expectEqual(@as(usize, 1), restored.groups.items.len);
}
