//! Run files contain the materializer's actual main statement. Writing happens
//! before execution so a warehouse error still leaves the statement to inspect.
const std = @import("std");
const types = @import("types.zig");

pub const Writer = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, *const types.Node, []const u8) anyerror!void,
};

pub fn write(writer: ?Writer, node: *const types.Node, sql: []const u8) !void {
    if (writer) |destination| try destination.write(destination.context, node, sql);
}

test "stock run artifacts pass the exact main statement and propagate write errors" {
    const Capture = struct {
        node: ?*const types.Node = null,
        sql: ?[]const u8 = null,
        fail: bool = false,
        fn save(raw: *anyopaque, node: *const types.Node, sql: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.node = node;
            self.sql = sql;
            if (self.fail) return error.ArtifactWriteFailed;
        }
    };
    var node: types.Node = undefined;
    var capture: Capture = .{};
    const destination: Writer = .{ .context = &capture, .write = Capture.save };
    const sql = "create table target as select missing_column;\n";
    try write(destination, &node, sql);
    try std.testing.expect(capture.node.? == &node);
    try std.testing.expect(capture.sql.?.ptr == sql.ptr);
    try std.testing.expectEqualStrings(sql, capture.sql.?);
    capture.fail = true;
    try std.testing.expectError(error.ArtifactWriteFailed, write(destination, &node, sql));
    try write(null, &node, sql);
}
