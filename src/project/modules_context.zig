//! dbt's restricted Python module exports, implemented by native providers.
const std = @import("std");
const expression = @import("expression.zig");
const datetime = @import("modules_datetime.zig");
const regex = @import("regex_context.zig");
const pytz = @import("timezone_context.zig");
pub const CallOptions = struct { host: ?expression.Host = null, io: ?std.Io = null, now_ns: ?i96 = null };
pub fn resolve(a: std.mem.Allocator, path: []const u8) !?expression.Value {
    if (std.mem.eql(u8, path, "modules")) {
        const entries = try expression.allocateEntries(a, 3);
        entries[0] = .{ .key = "pytz", .value = (try pytz.resolve(a, "modules.pytz")).? };
        entries[1] = .{ .key = "datetime", .value = (try datetime.resolve(a, "modules.datetime")).? };
        entries[2] = .{ .key = "re", .value = (try regex.resolve(a, "modules.re")).? };
        return .{ .object = entries };
    }
    if (try datetime.resolve(a, path)) |value| return value;
    if (try pytz.resolve(a, path)) |value| return value;
    return null;
}
pub fn call(a: std.mem.Allocator, name: []const u8, args: []const expression.Argument, options: CallOptions) !?expression.Value {
    if (try datetime.call(a, name, args, .{ .io = options.io, .now_ns = options.now_ns })) |value| return value;
    return pytz.call(a, name, args);
}
test "native module aggregate preserves restricted datetime and regex exports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const modules = (try resolve(a, "modules")).?;
    try std.testing.expect(modules.attribute("datetime").attribute("datetime") == .object);
    try std.testing.expect(modules.attribute("re").attribute("sub") == .callable);
}
