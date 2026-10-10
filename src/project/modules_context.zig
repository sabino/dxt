//! dbt's restricted Python module exports, implemented by native providers.
const std = @import("std");
const expression = @import("expression.zig");
const datetime = @import("modules_datetime.zig");
const regex = @import("regex_context.zig");
const pytz = @import("timezone_context.zig");
const itertools = @import("itertools_context.zig");
/// Owned by one render frame; its arena outlives all returned module values.
pub const Cache = struct { value: ?expression.Value = null };
pub fn resolveCached(a: std.mem.Allocator, path: []const u8, cache: *Cache) !?expression.Value {
    if (!std.mem.eql(u8, path, "modules") and !std.mem.startsWith(u8, path, "modules.")) return null;
    if (cache.value == null) cache.value = (try resolve(a, "modules")).?;
    var value = cache.value.?;
    if (path.len == "modules".len) return value;
    var parts = std.mem.splitScalar(u8, path["modules.".len..], '.');
    while (parts.next()) |part| value = try expression.checkedAttribute(value, part);
    return value;
}
pub const CallOptions = struct { host: ?expression.Host = null, io: ?std.Io = null, now_ns: ?i96 = null };
pub fn resolve(a: std.mem.Allocator, path: []const u8) !?expression.Value {
    if (std.mem.eql(u8, path, "modules")) {
        const entries = try expression.allocateEntries(a, 4);
        entries[0] = .{ .key = "pytz", .value = (try pytz.resolve(a, "modules.pytz")).? };
        entries[1] = .{ .key = "datetime", .value = (try datetime.resolve(a, "modules.datetime")).? };
        entries[2] = .{ .key = "re", .value = (try regex.resolve(a, "modules.re")).? };
        entries[3] = .{ .key = "itertools", .value = (try itertools.resolve(a, "modules.itertools")).? };
        return .{ .object = entries };
    }
    if (try datetime.resolve(a, path)) |value| return value;
    if (try pytz.resolve(a, path)) |value| return value;
    if (try itertools.resolve(a, path)) |value| return value;
    return null;
}
pub fn call(a: std.mem.Allocator, name: []const u8, args: []const expression.Argument, options: CallOptions) !?expression.Value {
    if (try datetime.call(a, name, args, .{ .io = options.io, .now_ns = options.now_ns })) |value| return value;
    if (try pytz.call(a, name, args)) |value| return value;
    return itertools.call(a, name, args, options.host);
}
test "native module aggregate preserves restricted datetime and regex exports" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const modules = (try resolve(a, "modules")).?;
    try std.testing.expect(modules.attribute("datetime").attribute("datetime") == .object);
    try std.testing.expect(modules.attribute("re").attribute("sub") == .callable);
}

test "render-owned module cache preserves exported collection identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cache: Cache = .{};
    const modules = (try resolveCached(a, "modules", &cache)).?;
    const zones = (try resolveCached(a, "modules.pytz.all_timezones", &cache)).?;
    const alias = modules.attribute("pytz").attribute("all_timezones");
    try std.testing.expect(zones == .list and alias == .list);
    try std.testing.expect(zones.list.ptr == alias.list.ptr);
    try std.testing.expect((try resolveCached(a, "outside", &cache)) == null);
    const again = (try resolveCached(a, "modules", &cache)).?;
    try std.testing.expect(modules.object.ptr == again.object.ptr);
}
