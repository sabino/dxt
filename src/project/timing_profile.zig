//! Native measured call profiles in the marshal/pstats format used by Core's
//! --record-timing-info. Each thread owns an implicit call stack; cumulative
//! and exclusive times are measured with a monotonic clock.
const std = @import("std");

pub const Key = struct { filename: []const u8, line: u32, function: []const u8 };
const Counts = struct { primitive: u32 = 0, total: u32 = 0, exclusive_ns: i96 = 0, cumulative_ns: i96 = 0 };
const Caller = struct { index: usize, counts: Counts = .{} };
const Entry = struct { key: Key, counts: Counts = .{}, callers: std.ArrayList(Caller) = .empty };
const Frame = struct { entry: usize, thread: std.Thread.Id, parent: ?usize, started: i96, children_ns: i96 = 0, active: bool = true };

pub const Span = struct {
    registry: ?*Registry = null,
    index: usize = 0,
    pub fn finish(self: Span) void {
        if (self.registry) |registry| registry.finish(self.index);
    }
};

pub fn start(registry: ?*Registry, key: Key) !Span {
    if (registry) |active| return active.start(key) catch |err| {
        active.mutex.lockUncancelable(active.io);
        active.allocation_failed = true;
        active.mutex.unlock(active.io);
        return err;
    };
    return .{};
}

pub const Registry = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    entries: std.ArrayList(Entry) = .empty,
    frames: std.ArrayList(Frame) = .empty,
    allocation_failed: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Registry {
        return .{ .allocator = allocator, .io = io };
    }
    pub fn deinit(self: *Registry) void {
        for (self.entries.items) |*entry| {
            self.allocator.free(entry.key.filename);
            self.allocator.free(entry.key.function);
            entry.callers.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
        self.frames.deinit(self.allocator);
    }
    fn start(self: *Registry, key: Key) !Span {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const index = try self.entryIndex(key);
        const thread = std.Thread.getCurrentId();
        var parent: ?usize = null;
        var cursor = self.frames.items.len;
        while (cursor != 0) {
            cursor -= 1;
            if (self.frames.items[cursor].active and self.frames.items[cursor].thread == thread) {
                parent = cursor;
                break;
            }
        }
        const frame_index = self.frames.items.len;
        try self.frames.append(self.allocator, .{ .entry = index, .thread = thread, .parent = parent, .started = std.Io.Clock.awake.now(self.io).nanoseconds });
        return .{ .registry = self, .index = frame_index };
    }
    fn entryIndex(self: *Registry, key: Key) !usize {
        for (self.entries.items, 0..) |entry, index| if (entry.key.line == key.line and std.mem.eql(u8, entry.key.filename, key.filename) and std.mem.eql(u8, entry.key.function, key.function)) return index;
        const filename = try self.allocator.dupe(u8, key.filename);
        errdefer self.allocator.free(filename);
        const function = try self.allocator.dupe(u8, key.function);
        errdefer self.allocator.free(function);
        const index = self.entries.items.len;
        try self.entries.append(self.allocator, .{ .key = .{ .filename = filename, .line = key.line, .function = function } });
        return index;
    }
    fn finish(self: *Registry, index: usize) void {
        const completed = std.Io.Clock.awake.now(self.io).nanoseconds;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const frame = self.frames.items[index];
        std.debug.assert(frame.active);
        const elapsed = @max(0, completed - frame.started);
        var ancestor = frame.parent;
        var recursive = false;
        while (ancestor) |parent| {
            const previous = self.frames.items[parent];
            if (previous.entry == frame.entry) recursive = true;
            ancestor = previous.parent;
        }
        const counts: Counts = .{ .primitive = if (recursive) 0 else 1, .total = 1, .exclusive_ns = @max(0, elapsed - frame.children_ns), .cumulative_ns = if (recursive) 0 else elapsed };
        addCounts(&self.entries.items[frame.entry].counts, counts);
        if (frame.parent) |parent| {
            self.frames.items[parent].children_ns += elapsed;
            const caller_index = self.frames.items[parent].entry;
            const entry = &self.entries.items[frame.entry];
            var found = false;
            for (entry.callers.items) |*caller| if (caller.index == caller_index) {
                addCounts(&caller.counts, counts);
                found = true;
                break;
            };
            if (!found) entry.callers.append(self.allocator, .{ .index = caller_index, .counts = counts }) catch {
                self.allocation_failed = true;
            };
        }
        self.frames.items[index].active = false;
        while (self.frames.items.len != 0 and !self.frames.items[self.frames.items.len - 1].active) _ = self.frames.pop();
    }
    pub fn write(self: *Registry, path: []const u8) !void {
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        defer output.deinit();
        try self.marshal(&output.writer);
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = output.written() });
    }
    pub fn marshal(self: *Registry, writer: *std.Io.Writer) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.allocation_failed) return error.OutOfMemory;
        if (self.frames.items.len != 0) return error.IncompleteTimingProfile;
        try writer.writeByte('{');
        for (self.entries.items) |entry| {
            try writeKey(writer, entry.key);
            try tuple(writer, 5);
            try integer(writer, entry.counts.primitive);
            try integer(writer, entry.counts.total);
            try seconds(writer, entry.counts.exclusive_ns);
            try seconds(writer, entry.counts.cumulative_ns);
            try writer.writeByte('{');
            for (entry.callers.items) |caller| {
                try writeKey(writer, self.entries.items[caller.index].key);
                try tuple(writer, 4);
                try integer(writer, caller.counts.primitive);
                try integer(writer, caller.counts.total);
                try seconds(writer, caller.counts.exclusive_ns);
                try seconds(writer, caller.counts.cumulative_ns);
            }
            try writer.writeByte('0');
        }
        try writer.writeByte('0');
    }
};

fn addCounts(target: *Counts, value: Counts) void {
    target.primitive +|= value.primitive;
    target.total +|= value.total;
    target.exclusive_ns += value.exclusive_ns;
    target.cumulative_ns += value.cumulative_ns;
}
fn rawInt(writer: *std.Io.Writer, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try writer.writeAll(&bytes);
}
fn tuple(writer: *std.Io.Writer, length: u32) !void {
    try writer.writeByte('(');
    try rawInt(writer, length);
}
fn integer(writer: *std.Io.Writer, value: u32) !void {
    // pstats call counters normally fit Python's signed marshal int. The long
    // representation retains larger genuine native counts without overflow.
    if (value <= std.math.maxInt(i32)) {
        try writer.writeByte('i');
        try rawInt(writer, value);
    } else {
        try writer.writeByte('l');
        const digits: u32 = if (value >> 30 != 0) 3 else 2;
        try rawInt(writer, digits);
        var remaining = value;
        for (0..digits) |_| {
            var bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &bytes, @intCast(remaining & 0x7fff), .little);
            try writer.writeAll(&bytes);
            remaining >>= 15;
        }
    }
}
fn string(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('u');
    try rawInt(writer, std.math.cast(u32, value.len) orelse return error.TimingProfileNameTooLong);
    try writer.writeAll(value);
}
fn seconds(writer: *std.Io.Writer, nanoseconds: i96) !void {
    try writer.writeByte('g');
    const value = @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_s;
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @bitCast(value), .little);
    try writer.writeAll(&bytes);
}
fn writeKey(writer: *std.Io.Writer, key: Key) !void {
    try tuple(writer, 3);
    try string(writer, key.filename);
    try integer(writer, key.line);
    try string(writer, key.function);
}

test "native timing profiles retain nesting, exclusive time and recursion counts" {
    var registry = Registry.init(std.testing.allocator, std.testing.io);
    defer registry.deinit();
    const key = Key{ .filename = "models/example.sql", .line = 1, .function = "example" };
    const parent = try start(&registry, key);
    const child = try start(&registry, key);
    child.finish();
    parent.finish();
    try std.testing.expectEqual(@as(usize, 1), registry.entries.items.len);
    const entry = registry.entries.items[0];
    try std.testing.expectEqual(@as(u32, 1), entry.counts.primitive);
    try std.testing.expectEqual(@as(u32, 2), entry.counts.total);
    try std.testing.expect(entry.counts.cumulative_ns >= entry.counts.exclusive_ns);
    try std.testing.expectEqual(@as(usize, 1), entry.callers.items.len);
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try registry.marshal(&output.writer);
    try std.testing.expectEqual(@as(u8, '{'), output.written()[0]);
    try std.testing.expectEqual(@as(u8, '0'), output.written()[output.written().len - 1]);
}
