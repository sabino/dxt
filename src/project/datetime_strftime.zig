//! CPython datetime's three substitutions followed by native libc strftime.
const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});

pub const Options = struct {
    date_only: bool = false,
    offset_us: ?i64 = null,
    abbreviation: ?[]const u8 = null,
    dst_us: ?i64 = null,
};

/// Python substitutes only exact %z, %:z and %Z directives before libc.
/// Escaped and modified directives do not request a timezone method.
pub const ZoneRequirements = struct { offset: bool = false, name: bool = false };
pub fn zoneRequirements(format: []const u8) ZoneRequirements {
    var result: ZoneRequirements = .{};
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        if (format[i] != '%' or i + 1 >= format.len) continue;
        i += 1;
        if (format[i] == 'z') result.offset = true;
        if (format[i] == 'Z') result.name = true;
        if (format[i] == ':' and i + 1 < format.len and format[i + 1] == 'z') {
            result.offset = true;
            i += 1;
        }
    }
    return result;
}

fn writeOffset(w: *std.Io.Writer, offset_us: i64, colon: bool) !void {
    const total = @abs(offset_us);
    const seconds = total / std.time.us_per_s;
    const fraction = total % std.time.us_per_s;
    try w.print("{c}{d:0>2}{s}{d:0>2}", .{ @as(u8, if (offset_us < 0) '-' else '+'), seconds / 3600, if (colon) ":" else "", (seconds % 3600) / 60 });
    if (seconds % 60 != 0 or fraction != 0) {
        try w.print("{s}{d:0>2}", .{ if (colon) @as([]const u8, ":") else "", seconds % 60 });
        if (fraction != 0) try w.print(".{d:0>6}", .{fraction});
    }
}

fn prepare(a: std.mem.Allocator, format: []const u8, micros: u64, options: Options) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        if (format[i] != '%' or i + 1 == format.len) {
            try out.writer.writeByte(format[i]);
            continue;
        }
        i += 1;
        switch (format[i]) {
            'f' => try out.writer.print("{d:0>6}", .{micros}),
            'z' => if (!options.date_only) if (options.offset_us) |offset| try writeOffset(&out.writer, offset, false),
            ':' => {
                // datetime added %:z in Python 3.12, independently of libc.
                if (i + 1 < format.len and format[i + 1] == 'z') {
                    i += 1;
                    if (!options.date_only) if (options.offset_us) |offset| try writeOffset(&out.writer, offset, true);
                } else try out.writer.writeAll("%:");
            },
            'Z' => if (!options.date_only) if (options.abbreviation) |name| {
                // A tzname may contain directives. CPython escapes its percent
                // signs before passing the substituted format to libc.
                for (name) |byte| {
                    try out.writer.writeByte(byte);
                    if (byte == '%') try out.writer.writeByte('%');
                }
            },
            else => {
                // This also preserves %% as a pair, so %%f stays literal %f.
                try out.writer.writeByte('%');
                try out.writer.writeByte(format[i]);
            },
        }
    }
    return out.toOwnedSlice();
}

fn writeSegment(a: std.mem.Allocator, w: *std.Io.Writer, format: []const u8, fields: *const c.struct_tm) !void {
    if (format.len == 0) return;
    const terminated = try a.dupeZ(u8, format);
    defer a.free(terminated);
    // strftime returns zero both for an empty expansion and insufficient room.
    // Python's time module uses the same format-dependent growth limit.
    const limit = @max(@as(usize, 1024), std.math.mul(usize, format.len, 256) catch return error.OutOfMemory);
    var capacity: usize = 1024;
    while (true) {
        const buffer = try a.alloc(u8, capacity);
        defer a.free(buffer);
        const length = c.strftime(buffer.ptr, buffer.len, terminated.ptr, fields);
        if (length != 0) return w.writeAll(buffer[0..length]);
        if (capacity >= limit) return;
        capacity = @min(limit, std.math.mul(usize, capacity, 2) catch limit);
    }
}

pub fn render(a: std.mem.Allocator, civil_ns: i96, format: []const u8, options: Options) ![]const u8 {
    const actual_ns = if (options.date_only) @divFloor(civil_ns, std.time.ns_per_day) * std.time.ns_per_day else civil_ns;
    var seconds: c.time_t = @intCast(@divFloor(actual_ns, std.time.ns_per_s));
    var fields: c.struct_tm = undefined;
    if (c.gmtime_r(&seconds, &fields) == null) return error.InvalidDatetime;
    fields.tm_isdst = if (options.date_only) -1 else if (options.dst_us) |dst| (if (dst == 0) 0 else 1) else -1;
    // datetime.timetuple does not provide the native extension fields. In
    // particular, modified %z/%Z directives use libc's behavior for that tuple.
    if (@hasField(c.struct_tm, "tm_gmtoff")) fields.tm_gmtoff = 0;
    if (@hasField(c.struct_tm, "tm_zone")) fields.tm_zone = null;
    c.tzset();
    const micros: u64 = if (options.date_only) 0 else @intCast(@divFloor(@mod(actual_ns, std.time.ns_per_s), std.time.ns_per_us));
    const prepared = try prepare(a, format, micros, options);
    defer a.free(prepared);
    var out: std.Io.Writer.Allocating = .init(a);
    // Python retains embedded NULs in the format; libc consumes C strings.
    var segments = std.mem.splitScalar(u8, prepared, 0);
    var first = true;
    while (segments.next()) |segment| {
        if (!first) try out.writer.writeByte(0);
        first = false;
        try writeSegment(a, &out.writer, segment, &fields);
    }
    return out.toOwnedSlice();
}

test "datetime strftime preserves escaped directives NUL and exact timezone fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ns: i96 = 1709223438123456000; // 2024-02-29 16:17:18.123456
    try std.testing.expectEqualStrings("2024-02-29 16:17:18.123456|+000530.123456|50% zone|%f|%z|%Z", try render(a, ns, "%F %T.%f|%z|%Z|%%f|%%z|%%Z", .{ .offset_us = 330123456, .abbreviation = "50% zone" }));
    try std.testing.expectEqualStrings("-00:05:30.123456|%:z", try render(a, ns, "%:z|%%:z", .{ .offset_us = -330123456 }));
    try std.testing.expectEqualStrings("2024\x0002\x0029", try render(a, ns, "%Y\x00%m\x00%d", .{}));
    try std.testing.expectEqualStrings("000000||", try render(a, ns, "%f|%z|%Z", .{ .date_only = true, .offset_us = 0, .abbreviation = "UTC" }));
    try std.testing.expectEqualStrings("0001-01-01", try render(a, -62135596800 * @as(i96, std.time.ns_per_s), "%04Y-%m-%d", .{}));
}

test "datetime strftime delegates native ISO week calendar and locale directives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("2020-53-5|Fri Jan  1 00:00:00 2021|01/01/21|00:00:00| 1", try render(a, 1609459200 * @as(i96, std.time.ns_per_s), "%G-%V-%u|%c|%x|%X|%e", .{}));
}
