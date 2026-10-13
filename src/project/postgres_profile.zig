//! Connection-only retry contract observed in dbt-postgres 1.9.1 and
//! dbt-adapters 1.16.3. Credential shape and connection limits are separate.
const std = @import("std");
const values = @import("config_value.zig");
const Value = std.json.Value;

pub fn normalize(allocator: std.mem.Allocator, raw: ?Value) !Value {
    const value = raw orelse return .{ .integer = 1 };
    switch (value) {
        .integer => return value,
        .number_string => |text| {
            // YAML retains integers beyond i64 as number strings.
            if (text.len == 0 or std.mem.eql(u8, text, "-")) return error.InvalidPostgresRetryPolicy;
            for (text, 0..) |byte, index| if (!(std.ascii.isDigit(byte) or (index == 0 and byte == '-'))) return error.InvalidPostgresRetryPolicy;
            return values.clone(allocator, value);
        },
        .float => |number| {
            // JSON Schema's integer includes integral floating point values.
            if (!std.math.isFinite(number) or @trunc(number) != number) return error.InvalidPostgresRetryPolicy;
            if (number >= -0x1p63 and number < 0x1p63) return .{ .integer = @intFromFloat(number) };
            return .{ .number_string = try @import("expression_number.zig").floatToInteger(allocator, number) };
        },
        else => return error.InvalidPostgresRetryPolicy,
    }
}

pub fn retryLimit(profile: Value) !u16 {
    const raw = values.get(profile, "retries") orelse return 1;
    const count: i64 = switch (raw) {
        .integer => |number| number,
        .float => |number| if (std.math.isFinite(number) and @trunc(number) == number and number >= 0 and number <= 1000) @intFromFloat(number) else return error.InvalidPostgresRetryLimit,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch return error.InvalidPostgresRetryLimit,
        else => return error.InvalidPostgresRetryPolicy,
    };
    // Core guards opening with the default Python recursion limit, 1000.
    if (count < 0 or count > 1000) return error.InvalidPostgresRetryLimit;
    return @intCast(count);
}

pub fn connect(context: anytype, retries: u16) anyerror!@typeInfo(@TypeOf(context.openOnce())).error_union.payload {
    var attempt: u64 = 0;
    while (true) : (attempt += 1) {
        try context.checkCancellation();
        return context.openOnce() catch |err| {
            if (err != error.PostgresConnectionFailed or attempt == retries) return err;
            // The first retry is immediate; the last failure never sleeps.
            try context.pause(attempt * attempt);
            continue;
        };
    }
}

test "PostgreSQL retry credential normalization preserves parse versus open limits" {
    const allocator = std.testing.allocator;
    const missing = try normalize(allocator, null);
    try std.testing.expectEqual(@as(i64, 1), missing.integer);
    const integral = try normalize(allocator, .{ .float = 2.0 });
    try std.testing.expectEqual(@as(i64, 2), integral.integer);
    var huge = try normalize(allocator, .{ .number_string = "999999999999999999999999999" });
    defer values.deinit(allocator, &huge);
    var float_huge = try normalize(allocator, .{ .float = 0x1p64 });
    defer values.deinit(allocator, &float_huge);
    try std.testing.expectEqualStrings("18446744073709551616", float_huge.number_string);
    for ([_]Value{ .null, .{ .bool = false }, .{ .bool = true }, .{ .string = "2" }, .{ .float = 2.5 }, .{ .float = std.math.inf(f64) }, .{ .float = std.math.nan(f64) } }) |raw| {
        try std.testing.expectError(error.InvalidPostgresRetryPolicy, normalize(allocator, raw));
    }
    for ([_]i64{ -1, 0, 1, 1000, 1001, std.math.maxInt(i64) }) |number| {
        const normalized = try normalize(allocator, .{ .integer = number });
        var profile: Value = .null;
        defer values.deinit(allocator, &profile);
        try values.put(allocator, &profile, "retries", normalized);
        if (number < 0 or number > 1000) {
            try std.testing.expectError(error.InvalidPostgresRetryLimit, retryLimit(profile));
        } else try std.testing.expectEqual(@as(u16, @intCast(number)), try retryLimit(profile));
    }
}

const Probe = struct {
    failures: usize,
    attempts: usize = 0,
    pauses: [4]u64 = undefined,
    pause_count: usize = 0,
    failure: anyerror = error.PostgresConnectionFailed,
    cancelled: bool = false,
    cancel_on_pause: bool = false,

    fn openOnce(self: *Probe) !usize {
        self.attempts += 1;
        if (self.attempts <= self.failures) return self.failure;
        return self.attempts;
    }
    fn checkCancellation(self: *Probe) !void {
        if (self.cancelled) return error.AdapterQueryCancelled;
    }
    fn pause(self: *Probe, seconds: u64) !void {
        self.pauses[self.pause_count] = seconds;
        self.pause_count += 1;
        if (self.cancel_on_pause) self.cancelled = true;
        try self.checkCancellation();
    }
};

test "PostgreSQL connection retries count additional attempts and quadratic waits" {
    for (0..5) |failures| {
        var probe: Probe = .{ .failures = failures };
        if (failures < 4) {
            try std.testing.expectEqual(failures + 1, try connect(&probe, 3));
        } else try std.testing.expectError(error.PostgresConnectionFailed, connect(&probe, 3));
        try std.testing.expectEqual(@min(failures + 1, 4), probe.attempts);
        const expected = [_]u64{ 0, 1, 4 };
        try std.testing.expectEqualSlices(u64, expected[0..@min(failures, 3)], probe.pauses[0..probe.pause_count]);
    }
    var no_retry: Probe = .{ .failures = 1 };
    try std.testing.expectError(error.PostgresConnectionFailed, connect(&no_retry, 0));
    try std.testing.expectEqual(@as(usize, 1), no_retry.attempts);
    try std.testing.expectEqual(@as(usize, 0), no_retry.pause_count);
}

test "PostgreSQL retries stop for cancellation and every nonconnection failure" {
    for ([_]anyerror{ error.OutOfMemory, error.NativePostgresAbiMismatch, error.PostgresCancellationFailed, error.PostgresExecutionFailed, error.PostgresSerializationFailure, error.InvalidPostgresConnection }) |failure| {
        var probe: Probe = .{ .failures = 1, .failure = failure };
        try std.testing.expectError(failure, connect(&probe, 3));
        try std.testing.expectEqual(@as(usize, 1), probe.attempts);
        try std.testing.expectEqual(@as(usize, 0), probe.pause_count);
    }
    var before: Probe = .{ .failures = 1, .cancelled = true };
    try std.testing.expectError(error.AdapterQueryCancelled, connect(&before, 3));
    try std.testing.expectEqual(@as(usize, 0), before.attempts);
    var during: Probe = .{ .failures = 2, .cancel_on_pause = true };
    try std.testing.expectError(error.AdapterQueryCancelled, connect(&during, 3));
    try std.testing.expectEqual(@as(usize, 1), during.attempts);
}
