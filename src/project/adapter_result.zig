const std = @import("std");

pub const Kind = enum { boolean, integer, decimal, floating, text, date, time, timestamp, binary, other };
pub const Column = struct { name: []const u8, kind: Kind, native_type: u32 = 0, native_type_modifier: i32 = -1 };
pub const QueryResult = struct {
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
