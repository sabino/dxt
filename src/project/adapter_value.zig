//! Owned native cursor values, separate from the textual query/Agate transport.
const std = @import("std");
pub const Time = struct { micros: i64, offset_us: ?i64 = null };
pub const Timestamp = struct { micros: i64, timezone: ?[]const u8 = null, offset_us: ?i64 = null };
pub const Interval = struct { months: i32, days: i32, micros: i64 };
pub const Field = struct { name: []const u8, value: Cell };
pub const Pair = struct { key: Cell, value: Cell };
pub const Range = struct {
    kind: enum { numeric, date, datetime, datetimetz },
    lower: ?*Cell = null,
    upper: ?*Cell = null,
    bounds: [2]u8 = .{ '[', ')' },
    empty: bool = false,
};
pub const Cell = union(enum) {
    none,
    boolean: bool,
    integer: []const u8,
    decimal: []const u8,
    floating: f64,
    text: []const u8,
    binary: []const u8,
    memoryview: []const u8,
    date: i32,
    time: Time,
    timestamp: Timestamp,
    interval: Interval,
    uuid: []const u8,
    list: []Cell,
    tuple: []Cell,
    object: []Field,
    map: []Pair,
    range: Range,

    pub fn setTimezone(self: *Cell, a: std.mem.Allocator, name: []const u8) anyerror!void {
        switch (self.*) {
            .timestamp => |*value| if (value.timezone != null) {
                const owned = try a.dupe(u8, name);
                a.free(value.timezone.?);
                value.timezone = owned;
            },
            .list, .tuple => |values| for (values) |*value| try value.setTimezone(a, name),
            .object => |values| for (values) |*field| try field.value.setTimezone(a, name),
            .map => |values| for (values) |*pair| {
                try pair.key.setTimezone(a, name);
                try pair.value.setTimezone(a, name);
            },
            .range => |bounds| {
                if (bounds.lower) |lower| try lower.setTimezone(a, name);
                if (bounds.upper) |upper| try upper.setTimezone(a, name);
            },
            else => {},
        }
    }

    pub fn deinit(self: *Cell, a: std.mem.Allocator) void {
        switch (self.*) {
            .integer, .decimal, .text, .binary, .memoryview, .uuid => |bytes| a.free(bytes),
            .timestamp => |value| if (value.timezone) |zone| a.free(zone),
            .list, .tuple => |values| {
                for (values) |*value| value.deinit(a);
                a.free(values);
            },
            .object => |values| {
                for (values) |*field| {
                    a.free(field.name);
                    field.value.deinit(a);
                }
                a.free(values);
            },
            .map => |values| {
                for (values) |*pair| {
                    pair.key.deinit(a);
                    pair.value.deinit(a);
                }
                a.free(values);
            },
            .range => |bounds| {
                if (bounds.lower) |lower| {
                    lower.deinit(a);
                    a.destroy(lower);
                }
                if (bounds.upper) |upper| {
                    upper.deinit(a);
                    a.destroy(upper);
                }
            },
            else => {},
        }
        self.* = .none;
    }
};

test "nested native cursor cells release exact binary and numeric data" {
    const a = std.testing.allocator;
    var cell: Cell = .{ .object = try a.alloc(Field, 1) };
    cell.object[0] = .{ .name = try a.dupe(u8, "payload"), .value = .{ .list = try a.alloc(Cell, 2) } };
    cell.object[0].value.list[0] = .{ .binary = try a.dupe(u8, &.{ 'a', 0, 255 }) };
    cell.object[0].value.list[1] = .{ .decimal = try a.dupe(u8, "12345678901234567890.123456789") };
    try std.testing.expectEqual(@as(usize, 3), cell.object[0].value.list[0].binary.len);
    try std.testing.expectEqualStrings("12345678901234567890.123456789", cell.object[0].value.list[1].decimal);
    cell.deinit(a);
    try std.testing.expect(cell == .none);
}

test "native cursor timezone projection updates nested aware timestamps only" {
    const a = std.testing.allocator;
    var cell: Cell = .{ .list = try a.alloc(Cell, 2) };
    cell.list[0] = .{ .timestamp = .{ .micros = 123, .timezone = try a.dupe(u8, "UTC") } };
    cell.list[1] = .{ .timestamp = .{ .micros = 456 } };
    defer cell.deinit(a);
    try cell.setTimezone(a, "Europe/Berlin");
    try std.testing.expectEqualStrings("Europe/Berlin", cell.list[0].timestamp.timezone.?);
    try std.testing.expectEqual(@as(i64, 123), cell.list[0].timestamp.micros);
    try std.testing.expect(cell.list[1].timestamp.timezone == null);
}

test "PostgreSQL ranges retain owned typed endpoints and unbounded nulls" {
    const a = std.testing.allocator;
    const lower = try a.create(Cell);
    lower.* = .{ .decimal = try a.dupe(u8, "1.000000000000000000001") };
    var range: Cell = .{ .range = .{ .kind = .numeric, .lower = lower } };
    defer range.deinit(a);
    try std.testing.expect(range.range.upper == null);
    try std.testing.expectEqualStrings("1.000000000000000000001", range.range.lower.?.decimal);
    try std.testing.expectEqualSlices(u8, "[)", &range.range.bounds);
}

test "fixed DuckDB arrays retain distinct owned tuple identity" {
    const a = std.testing.allocator;
    var cell: Cell = .{ .tuple = try a.alloc(Cell, 1) };
    cell.tuple[0] = .{ .text = try a.dupe(u8, "owned") };
    try std.testing.expectEqualStrings("owned", cell.tuple[0].text);
    cell.deinit(a);
    try std.testing.expect(cell == .none);
}
