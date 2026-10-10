const std = @import("std");

pub const Kind = enum { boolean, integer, decimal, floating, text, date, time, timestamp, binary, other };
pub const Column = struct { name: []const u8, kind: Kind, native_type: u32 = 0, native_type_modifier: i32 = -1 };
pub const QueryResult = struct {
    /// Allocating producers retain their allocator because a held connection
    /// can outlive the batch allocator used by the caller. The caller-supplied
    /// allocator remains the fallback for manually constructed owned results.
    owner_allocator: ?std.mem.Allocator = null,
    columns: []Column = &.{},
    rows: [][]?[]const u8 = &.{},
    rows_changed: u64 = 0,
    command_tag: ?[]const u8 = null,

    pub fn deinit(self: *QueryResult, allocator: std.mem.Allocator) void {
        const owner = self.owner_allocator orelse allocator;
        if (self.command_tag) |tag| owner.free(tag);
        for (self.columns) |column| owner.free(column.name);
        owner.free(self.columns);
        for (self.rows) |row| {
            for (row) |value| if (value) |text| owner.free(text);
            owner.free(row);
        }
        owner.free(self.rows);
        self.* = .{};
    }

    pub fn firstScalar(self: *const QueryResult) ?[]const u8 {
        if (self.rows.len == 0 or self.columns.len == 0) return null;
        return self.rows[0][0];
    }

    pub fn truncateRows(self: *QueryResult, allocator: std.mem.Allocator, count: usize) !void {
        if (count >= self.rows.len) return;
        const owner = self.owner_allocator orelse allocator;
        // Allocate before releasing row contents. A failed shrink must leave
        // the full result valid for its deferred cleanup.
        const retained = try owner.dupe([]?[]const u8, self.rows[0..count]);
        for (self.rows[count..]) |row| {
            for (row) |cell| if (cell) |text| owner.free(text);
            owner.free(row);
        }
        owner.free(self.rows);
        self.rows = retained;
    }

    pub fn json(self: *const QueryResult, allocator: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.writeByte('[');
        for (self.rows, 0..) |row, r| {
            if (r != 0) try out.writer.writeByte(',');
            try out.writer.writeByte('{');
            for (self.columns, row, 0..) |column, value, c| {
                if (c != 0) try out.writer.writeByte(',');
                try std.json.Stringify.value(column.name, .{}, &out.writer);
                try out.writer.writeByte(':');
                if (value) |text| {
                    switch (column.kind) {
                        .boolean => try out.writer.writeAll(if (std.mem.eql(u8, text, "t") or std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "1")) "true" else "false"),
                        .integer, .decimal, .floating => {
                            const number = std.fmt.parseFloat(f64, text) catch std.math.nan(f64);
                            if (std.math.isFinite(number)) try out.writer.writeAll(text) else try std.json.Stringify.value(text, .{}, &out.writer);
                        },
                        else => try std.json.Stringify.value(text, .{}, &out.writer),
                    }
                } else try out.writer.writeAll("null");
            }
            try out.writer.writeByte('}');
        }
        try out.writer.writeByte(']');
        return try out.toOwnedSlice();
    }
};

pub fn quoteIdentifier(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return quote(allocator, name, '"');
}

pub fn quoteLiteral(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    return quote(allocator, value, '\'');
}

fn quote(allocator: std.mem.Allocator, value: []const u8, delimiter: u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidSqlIdentifier;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, delimiter);
    for (value) |byte| {
        try out.append(allocator, byte);
        if (byte == delimiter) try out.append(allocator, byte);
    }
    try out.append(allocator, delimiter);
    return try out.toOwnedSlice(allocator);
}

pub const Capabilities = struct {
    transactions: bool = true,
    savepoints: bool,
    schemas: bool = true,
    catalogs: bool,
    cancellation: bool = true,
    concurrent_connections: bool = true,
    transactional_ddl: bool = true,
    merge: bool,
    replace_table: bool,
    materialized_views: bool,
};

test "native result JSON preserves typed nullable data and escapes identifiers" {
    const allocator = std.testing.allocator;
    const result = QueryResult{
        .columns = @constCast(&[_]Column{ .{ .name = "id", .kind = .integer }, .{ .name = "flag", .kind = .boolean }, .{ .name = "label", .kind = .text } }),
        .rows = @constCast(&[_][]?[]const u8{@constCast(&[_]?[]const u8{ "42", "t", null })}),
    };
    const text = try result.json(allocator);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("[{\"id\":42,\"flag\":true,\"label\":null}]", text);
    const identifier = try quoteIdentifier(allocator, "a\"b");
    defer allocator.free(identifier);
    try std.testing.expectEqualStrings("\"a\"\"b\"", identifier);
    try std.testing.expectError(error.InvalidSqlIdentifier, quoteIdentifier(allocator, "a\x00b"));
}

test "query result releases every allocation through its owner and resets" {
    var owner: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expectEqual(.ok, owner.deinit()) catch @panic("query result owner leaked");
    var caller: std.heap.DebugAllocator(.{}) = .init;
    defer std.testing.expectEqual(.ok, caller.deinit()) catch @panic("query result caller leaked");
    const a = owner.allocator();
    var result: QueryResult = .{ .owner_allocator = a };
    errdefer result.deinit(a);
    result.columns = try a.alloc(Column, 2);
    for (result.columns) |*column| column.* = .{ .name = "", .kind = .text };
    result.columns[0].name = try a.dupe(u8, "value");
    result.columns[1].name = try a.dupe(u8, "missing");
    result.rows = try a.alloc([]?[]const u8, 1);
    result.rows[0] = &.{};
    result.rows[0] = try a.alloc(?[]const u8, 2);
    @memset(result.rows[0], null);
    result.rows[0][0] = try a.dupe(u8, "retained");
    result.command_tag = try a.dupe(u8, "SELECT 1");
    result.rows_changed = 1;
    result.deinit(caller.allocator());
    try std.testing.expect(result.owner_allocator == null);
    try std.testing.expectEqual(@as(usize, 0), result.columns.len);
    try std.testing.expectEqual(@as(usize, 0), result.rows.len);
    try std.testing.expect(result.command_tag == null);
    try std.testing.expectEqual(@as(u64, 0), result.rows_changed);
    // The reset also makes a second cleanup safe with a different allocator.
    result.deinit(caller.allocator());
}

test "manually owned query result retains caller allocator fallback" {
    const a = std.testing.allocator;
    var result: QueryResult = .{ .command_tag = try a.dupe(u8, "CREATE TABLE") };
    result.deinit(a);
    try std.testing.expect(result.command_tag == null);
}

test "query result truncation remains owned and cleans up on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, truncateAllocationFailures, .{});
}

fn truncateAllocationFailures(a: std.mem.Allocator) !void {
    var result: QueryResult = .{ .owner_allocator = a };
    defer result.deinit(std.testing.allocator);
    result.rows = try a.alloc([]?[]const u8, 3);
    for (result.rows) |*row| row.* = &.{};
    for (result.rows) |*row| {
        row.* = try a.alloc(?[]const u8, 1);
        row.*[0] = null;
        row.*[0] = try a.dupe(u8, "owned");
    }
    result.truncateRows(std.testing.allocator, 1) catch |err| {
        try std.testing.expectEqual(@as(usize, 3), result.rows.len);
        for (result.rows) |row| try std.testing.expectEqualStrings("owned", row[0].?);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 1), result.rows.len);
    try std.testing.expectEqualStrings("owned", result.rows[0][0].?);
    try result.truncateRows(std.testing.allocator, 0);
    try std.testing.expectEqual(@as(usize, 0), result.rows.len);
}
