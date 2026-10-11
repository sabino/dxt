const std = @import("std");
const json = @import("json.zig");
pub const version = "0.0.0";
pub const compatible_core = "1.10.5";

pub const Metadata = struct {
    io: std.Io,
    environment: ?*const std.process.Environ.Map,
    id: [36]u8,
    started_at: [27]u8,
    monotonic_start: std.Io.Timestamp,

    pub fn init(io: std.Io, environment: ?*const std.process.Environ.Map) Metadata {
        var bytes: [16]u8 = undefined;
        io.random(&bytes);
        bytes[6] = (bytes[6] & 0x0f) | 0x40;
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        const hex = std.fmt.bytesToHex(bytes, .lower);
        var id: [36]u8 = undefined;
        _ = std.fmt.bufPrint(&id, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] }) catch unreachable;
        return .{ .io = io, .environment = environment, .id = id, .started_at = formatTimestamp(std.Io.Timestamp.now(io, .real)), .monotonic_start = std.Io.Timestamp.now(io, .awake) };
    }

    pub fn elapsed(self: *const Metadata) f64 {
        const nanoseconds = self.monotonic_start.durationTo(std.Io.Timestamp.now(self.io, .awake)).nanoseconds;
        return @as(f64, @floatFromInt(@max(0, nanoseconds))) / std.time.ns_per_s;
    }
};

pub fn formatTimestamp(timestamp: std.Io.Timestamp) [27]u8 {
    const seconds: u64 = @intCast(@max(0, timestamp.toSeconds()));
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day = epoch.getDaySeconds();
    const micros: u64 = @intCast(@mod(@divTrunc(timestamp.nanoseconds, std.time.ns_per_us), std.time.us_per_s));
    var result: [27]u8 = undefined;
    _ = std.fmt.bufPrint(&result, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}Z", .{ year_day.year, @intFromEnum(month_day.month), month_day.day_index + 1, day.getHoursIntoDay(), day.getMinutesIntoHour(), day.getSecondsIntoMinute(), micros }) catch unreachable;
    return result;
}

pub fn writeFields(writer: *std.Io.Writer, schema: []const u8, metadata: ?*const Metadata) !void {
    try writer.writeAll("\"dbt_schema_version\":");
    try json.string(writer, schema);
    try writer.writeAll(",\"dbt_version\":");
    try json.string(writer, version);
    try writer.writeAll(",\"generated_at\":");
    if (metadata) |value| {
        const generated = formatTimestamp(std.Io.Timestamp.now(value.io, .real));
        try json.string(writer, &generated);
        try writer.writeAll(",\"invocation_id\":");
        try json.string(writer, &value.id);
        try writer.writeAll(",\"invocation_started_at\":");
        try json.string(writer, &value.started_at);
    } else try writer.writeAll("\"1970-01-01T00:00:00Z\",\"invocation_id\":null,\"invocation_started_at\":null");
    try writer.writeAll(",\"env\":{");
    var first = true;
    if (metadata) |value| if (value.environment) |environment| {
        var iterator = environment.iterator();
        while (iterator.next()) |entry| {
            const prefix = "DBT_ENV_CUSTOM_ENV_";
            if (!std.mem.startsWith(u8, entry.key_ptr.*, prefix)) continue;
            if (!first) try writer.writeAll(",");
            first = false;
            try json.string(writer, entry.key_ptr.*[prefix.len..]);
            try writer.writeAll(":");
            try json.string(writer, entry.value_ptr.*);
        }
    };
    try writer.writeAll("}");
}

test "UTC formatting keeps leap days and microsecond precision" {
    const rendered = formatTimestamp(.{ .nanoseconds = 1709251199123456000 });
    try std.testing.expectEqualStrings("2024-02-29T23:59:59.123456Z", &rendered);
}
