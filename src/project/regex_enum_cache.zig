//! Enum values retain a process cache, including authored negative keys.
//! Owned decimal strings outlive every render arena; no user values are retained.
const std = @import("std");
var mutex: std.atomic.Mutex = .unlocked;
var values: std.StringHashMapUnmanaged([]const u8) = .empty;
const predefined = [_][]const u8{ "0", "1", "2", "4", "8", "16", "32", "64", "128", "256" };

fn lock() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}
pub fn lookup(number: []const u8) ?[]const u8 {
    for (predefined) |member| if (std.mem.eql(u8, member, number)) return member;
    lock();
    defer mutex.unlock();
    return values.get(number);
}
pub fn remember(authored: []const u8, normalized: []const u8) !void {
    lock();
    defer mutex.unlock();
    for ([_][]const u8{ authored, normalized }) |key| {
        var known = false;
        for (predefined) |member| if (std.mem.eql(u8, member, key)) {
            known = true;
            break;
        };
        if (known or values.contains(key)) continue;
        const allocator = std.heap.page_allocator;
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        const owned_value = try allocator.dupe(u8, normalized);
        errdefer allocator.free(owned_value);
        try values.put(allocator, owned_key, owned_value);
    }
}

test "Enum cache keeps authored negative keys and normalized positive values" {
    try remember("-257", "255");
    try std.testing.expectEqualStrings("255", lookup("-257").?);
    try std.testing.expectEqualStrings("255", lookup("255").?);
    try std.testing.expectEqualStrings("2", lookup("2").?);
}
