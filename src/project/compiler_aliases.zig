//! Render-owned alias publication. Only verified native CSV backing is sealed;
//! evolving dictionaries, lists, iterators and saved methods remain traversable.
const std = @import("std");
const expression = @import("expression.zig");
const Value = expression.Value;
const Key = @import("compiler_receivers.zig").Key;

pub const Publication = struct {
    readonly: std.AutoHashMapUnmanaged(Key, void) = .empty,
    checked_tables: std.AutoHashMapUnmanaged(Key, void) = .empty,
    visited: std.AutoHashMapUnmanaged(Key, usize) = .empty,
    slots: std.AutoHashMapUnmanaged(usize, void) = .empty,
    disabled: bool = false,
    certificate_visits: usize = 0,
    alias_visits: usize = 0,
    sealed_tables: usize = 0,

    pub fn deinit(self: *Publication, a: std.mem.Allocator) void {
        self.readonly.deinit(a);
        self.checked_tables.deinit(a);
        self.visited.deinit(a);
        self.slots.deinit(a);
        self.* = .{};
    }

    /// Native dot assignment can replace a provider field in place. Disable
    /// certificates before that write, including writes before the first scan.
    pub fn disableReadonly(self: *Publication) void {
        self.disabled = true;
        self.readonly.clearRetainingCapacity();
        self.checked_tables.clearRetainingCapacity();
    }

    pub fn begin(self: *Publication, original: Value) void {
        self.visited.clearRetainingCapacity();
        self.slots.clearRetainingCapacity();
        // Even a borrowed internal list must retain the old native alias
        // semantics if it is actually used as a mutable receiver.
        if (Key.from(original)) |key| if (self.readonly.contains(key)) self.disableReadonly();
    }

    pub fn replace(self: *Publication, a: std.mem.Allocator, value: *Value, original: Value, replacement: Value, depth: usize) anyerror!void {
        var ancestry: [129]Key = undefined;
        return self.replacePath(a, value, original, replacement, depth, &ancestry, 0);
    }

    fn replacePath(self: *Publication, a: std.mem.Allocator, value: *Value, original: Value, replacement: Value, depth: usize, ancestry: *[129]Key, count: usize) anyerror!void {
        if (depth > 128) return error.JinjaExpressionDepthExceeded;
        self.alias_visits += 1;
        const key = switch (value.*) {
            .list, .tuple, .object => Key.from(value.*).?,
            else => return,
        };
        const matches = (value.* == .list and original == .list and value.list.ptr == original.list.ptr and value.list.len == original.list.len) or
            (value.* == .object and original == .object and value.object.ptr == original.object.ptr and value.object.len == original.object.len);
        // Replacement must precede every deduplication check: distinct root
        // slots can reference the same old backing.
        if (matches) {
            value.* = replacement;
            try self.slots.put(a, @intFromPtr(value), {});
            return;
        }
        if (self.slots.contains(@intFromPtr(value))) return;
        for (ancestry[0..count]) |previous| if (std.meta.eql(previous, key)) return;
        // Certificates are limited to relative height 32. At a deeper authored
        // path, walk normally so the existing depth-128 error stays observable.
        if (!self.disabled and depth <= 96 and self.readonly.contains(key)) return;
        if (!self.disabled and @import("seed_table.zig").isTable(value.*)) {
            if (!self.checked_tables.contains(key)) {
                try self.checked_tables.put(a, key, {});
                try self.certify(a, value.*);
            }
            if (depth <= 96 and self.readonly.contains(key)) return;
        }
        if (self.visited.get(key)) |previous_depth| {
            // A previously checked deeper path covers this one's depth limit.
            if (previous_depth >= depth) return;
        }
        try self.visited.put(a, key, depth);
        ancestry[count] = key;
        switch (value.*) {
            .list => for (@constCast(value.list)) |*child| try self.replacePath(a, child, original, replacement, depth + 1, ancestry, count + 1),
            .tuple => for (@constCast(value.tuple)) |*child| try self.replacePath(a, child, original, replacement, depth + 1, ancestry, count + 1),
            .object => for (@constCast(value.object)) |*entry| {
                if (entry.typed_key) |*typed_key| try self.replacePath(a, typed_key, original, replacement, depth + 1, ancestry, count + 1);
                try self.replacePath(a, &entry.value, original, replacement, depth + 1, ancestry, count + 1);
            },
            else => unreachable,
        }
    }

    fn certify(self: *Publication, a: std.mem.Allocator, table: Value) !void {
        // The private callable establishes native constructor provenance. The
        // raw CSV cells must also be immutable; arbitrary returned objects and
        // authored reserved-key dictionaries cannot acquire a certificate.
        const data = table.attribute("__dxt_data");
        if (data != .tuple) return;
        for (data.tuple) |row| {
            if (row != .tuple) return;
            for (row.tuple) |cell| if (!csvScalar(cell)) return;
        }
        var candidate: std.AutoHashMapUnmanaged(Key, void) = .empty;
        defer candidate.deinit(a);
        if (!try self.seal(a, &candidate, table, false, false, 0)) return;
        var keys = candidate.keyIterator();
        while (keys.next()) |key| try self.readonly.put(a, key.*, {});
        self.sealed_tables += 1;
    }

    fn csvScalar(value: Value) bool {
        return switch (value) {
            .none, .boolean, .integer, .number, .string => true,
            .object => expression.floatProtocol(value) != null or @import("timestamp_context.zig").state(value) != null,
            else => false,
        };
    }

    fn seal(self: *Publication, a: std.mem.Allocator, candidate: *std.AutoHashMapUnmanaged(Key, void), value: Value, internal_list: bool, internal_mapping: bool, depth: usize) anyerror!bool {
        if (depth > 32) return false;
        self.certificate_visits += 1;
        switch (value) {
            .list => if (!internal_list) return false,
            .object => {
                const methods = @import("builtin_bound_method.zig");
                if (methods.isBound(value) or @import("expression_sequence.zig").kind(value) != null or @import("set_context.zig").isSet(value)) return false;
                if (!methods.isContextObject(value) and expression.floatProtocol(value) == null and @import("timestamp_context.zig").state(value) == null and !internal_mapping) return false;
            },
            .tuple => {},
            else => return true,
        }
        const key = Key.from(value).?;
        if (candidate.contains(key)) return true;
        try candidate.put(a, key, {});
        switch (value) {
            .list, .tuple => {
                const members = if (value == .list) value.list else value.tuple;
                for (members) |member| if (!try self.seal(a, candidate, member, false, false, depth + 1)) return false;
            },
            .object => for (value.object) |entry| {
                if (entry.typed_key) |typed_key| if (!try self.seal(a, candidate, typed_key, false, false, depth + 1)) return false;
                const list = std.mem.eql(u8, entry.key, "__dxt_iterable") or std.mem.eql(u8, entry.key, "__dxt_seed_kinds");
                const mapping = std.mem.eql(u8, entry.key, "__dxt_string_index");
                if (!try self.seal(a, candidate, entry.value, list, mapping, depth + 1)) return false;
            },
            else => unreachable,
        }
        return true;
    }
};

test "publication still visits evolving containers and saved method keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var publication: Publication = .{};
    defer publication.deinit(a);
    const original = Value{ .list = try expression.allocateValues(a, 0) };
    const first = Value{ .list = try a.dupe(Value, &.{.{ .integer = "1" }}) };
    const second = Value{ .list = try a.dupe(Value, &.{ .{ .integer = "1" }, .{ .integer = "2" } }) };
    const entries = try expression.allocateEntries(a, 1);
    entries[0] = .{ .key = "later", .value = .none };
    var namespace = Value{ .object = entries };
    publication.begin(original);
    try publication.replace(a, &namespace, original, first, 0);
    entries[0].value = .{ .tuple = try a.dupe(Value, &.{first}) };
    var direct = first;
    publication.begin(first);
    try publication.replace(a, &namespace, first, second, 0);
    try publication.replace(a, &direct, first, second, 0);
    try std.testing.expectEqual(@as(usize, 2), namespace.attribute("later").tuple[0].list.len);
    try std.testing.expectEqual(@as(usize, 2), direct.list.len);
    const iterator = try @import("expression_filter_iterator.zig").batch(a, .{ .list = try a.dupe(Value, &.{ .none, second }) }, &.{.{ .value = .{ .integer = "1" } }});
    _ = try @import("expression_sequence.zig").next(a, iterator, null);
    var retained = iterator;
    publication.begin(first);
    try publication.replace(a, &retained, first, second, 0);
    _ = try @import("expression_sequence.zig").next(a, iterator, null);
    const third = Value{ .list = try a.dupe(Value, &.{ .{ .integer = "1" }, .{ .integer = "2" }, .{ .integer = "3" } }) };
    publication.begin(second);
    try publication.replace(a, &retained, second, third, 0);
    const storage = iterator.attribute("__dxt_filter_buffer_storage");
    try std.testing.expectEqual(@as(usize, 3), storage.list[0].list.len);
    const spoof = Value{ .object = &.{.{ .key = "__dxt_seed_table", .value = .{ .string = "__dxt_seed_table" } }} };
    var authored = spoof;
    publication.begin(second);
    try publication.replace(a, &authored, second, third, 0);
    try std.testing.expectEqual(@as(usize, 0), publication.sealed_tables);
}

test "readonly certificates preserve depth errors and mutable receiver fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var publication: Publication = .{};
    defer publication.deinit(a);
    const cells = try a.dupe(Value, &.{.{ .integer = "1" }});
    var table = Value{ .object = try a.dupe(expression.Entry, &.{
        .{ .key = "__dxt_seed_table", .value = .{ .callable = "__dxt_seed_table" } },
        .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
        .{ .key = "__dxt_data", .value = .{ .tuple = try a.dupe(Value, &.{.{ .tuple = cells }}) } },
        .{ .key = "__dxt_iterable", .value = .{ .list = cells } },
    }) };
    const original = Value{ .list = try expression.allocateValues(a, 0) };
    publication.begin(original);
    try publication.replace(a, &table, original, original, 0);
    try std.testing.expectEqual(@as(usize, 1), publication.sealed_tables);
    var deep = table;
    for (0..128) |_| deep = .{ .tuple = try a.dupe(Value, &.{deep}) };
    publication.begin(original);
    try std.testing.expectError(error.JinjaExpressionDepthExceeded, publication.replace(a, &deep, original, original, 0));
    const replacement = Value{ .list = try a.dupe(Value, &.{ .{ .integer = "1" }, .{ .integer = "2" } }) };
    publication.begin(.{ .list = cells });
    try std.testing.expect(publication.disabled);
    try publication.replace(a, &table, .{ .list = cells }, replacement, 0);
    try std.testing.expectEqual(@as(usize, 2), table.attribute("__dxt_iterable").list.len);
}
