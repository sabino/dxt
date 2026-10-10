//! Mask declared secret values only when publishing diagnostics. Authored
//! resources and runtime values remain available to their original consumers.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Environment = std.process.Environ.Map;
const mask = "*****";

pub fn text(allocator: Allocator, environment: ?*const Environment, input: []const u8) ![]const u8 {
    var secrets = try values(allocator, environment);
    defer secrets.deinit(allocator);
    return projectText(allocator, secrets.items, input);
}

fn values(allocator: Allocator, environment: ?*const Environment) !std.ArrayList([]const u8) {
    var result: std.ArrayList([]const u8) = .empty;
    errdefer result.deinit(allocator);
    if (environment) |env| {
        var entries = env.iterator();
        while (entries.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, "DBT_ENV_SECRET_") and std.mem.trim(u8, entry.value_ptr.*, " \t\r\n\x0b\x0c").len != 0)
                try result.append(allocator, entry.value_ptr.*);
        }
    }
    return result;
}

fn matchLength(secrets: []const []const u8, input: []const u8) usize {
    var longest: usize = 0;
    for (secrets) |secret| {
        if (secret.len > longest and std.mem.startsWith(u8, input, secret)) longest = secret.len;
    }
    return longest;
}

fn projectText(allocator: Allocator, secrets: []const []const u8, input: []const u8) ![]const u8 {
    if (secrets.len == 0) return allocator.dupe(u8, input);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var position: usize = 0;
    while (position < input.len) {
        const matched = matchLength(secrets, input[position..]);
        if (matched != 0) {
            try output.appendSlice(allocator, mask);
            position += matched;
        } else {
            try output.append(allocator, input[position]);
            position += 1;
        }
    }
    return output.toOwnedSlice(allocator);
}

pub const Line = struct {
    // Keep classification/routing based on the original event, even when a
    // declared value happens to match its name or severity.
    original: []const u8,
    projected: []const u8,
    terminated: bool,
};

pub const LogLines = struct {
    allocator: Allocator,
    secrets: std.ArrayList([]const u8),
    input: []const u8,
    position: usize = 0,

    pub fn init(allocator: Allocator, environment: ?*const Environment, input: []const u8) !LogLines {
        return .{ .allocator = allocator, .secrets = try values(allocator, environment), .input = input };
    }

    pub fn deinit(self: *LogLines) void {
        self.secrets.deinit(self.allocator);
    }

    pub fn next(self: *LogLines) !?Line {
        if (self.position == self.input.len) return null;
        const start = self.position;
        const first_end = if (std.mem.indexOfScalarPos(u8, self.input, start, '\n')) |end| end else self.input.len;
        if (try projectJson(self.allocator, self.secrets.items, self.input[start..first_end])) |projected| {
            const terminated = first_end < self.input.len;
            self.position = first_end + @intFromBool(terminated);
            return .{ .original = self.input[start..first_end], .projected = projected, .terminated = terminated };
        }
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(self.allocator);
        // A secret may itself contain newlines. Match the complete value
        // before deciding where the next public diagnostic line ends.
        while (self.position < self.input.len) {
            const matched = matchLength(self.secrets.items, self.input[self.position..]);
            if (matched != 0) {
                try output.appendSlice(self.allocator, mask);
                self.position += matched;
            } else if (self.input[self.position] == '\n') break else {
                try output.append(self.allocator, self.input[self.position]);
                self.position += 1;
            }
        }
        const end = self.position;
        const terminated = end < self.input.len;
        const projected = try output.toOwnedSlice(self.allocator);
        self.position += @intFromBool(terminated);
        return .{ .original = self.input[start..end], .projected = projected, .terminated = terminated };
    }
};

pub fn logBuffer(allocator: Allocator, environment: ?*const Environment, input: []const u8) ![]const u8 {
    var lines = try LogLines.init(allocator, environment, input);
    defer lines.deinit();
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    while (try lines.next()) |line| {
        defer allocator.free(line.projected);
        try output.appendSlice(allocator, line.projected);
        if (line.terminated) try output.append(allocator, '\n');
    }
    return output.toOwnedSlice(allocator);
}

fn projectJson(allocator: Allocator, secrets: []const []const u8, input: []const u8) !?[]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r");
    if (trimmed.len == 0 or (trimmed[0] != '{' and trimmed[0] != '[')) return null;
    if (secrets.len == 0) return try allocator.dupe(u8, input);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{ .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    defer parsed.deinit();
    if (!try projectValue(parsed.arena.allocator(), secrets, &parsed.value)) return try allocator.dupe(u8, input);
    return try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
}

fn projectValue(allocator: Allocator, secrets: []const []const u8, value: *std.json.Value) Allocator.Error!bool {
    var changed = false;
    switch (value.*) {
        .string => |original| {
            const projected = try projectText(allocator, secrets, original);
            changed = !std.mem.eql(u8, original, projected);
            value.* = .{ .string = projected };
        },
        .array => |*array| for (array.items) |*item| {
            changed = (try projectValue(allocator, secrets, item)) or changed;
        },
        .object => |*object| {
            var entries = object.iterator();
            while (entries.next()) |entry| changed = (try projectValue(allocator, secrets, entry.value_ptr)) or changed;
        },
        else => {},
    }
    return changed;
}

test "declared secret text uses longest original matches and ignores blank or ordinary values" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, textAllocationProof, .{});
}

fn textAllocationProof(allocator: Allocator) !void {
    var environment = Environment.init(allocator);
    defer environment.deinit();
    try environment.put("DBT_ENV_SECRET_SHORT", "abc");
    try environment.put("DBT_ENV_SECRET_LONG", "abcdef");
    try environment.put("DBT_ENV_SECRET_STARS", "*");
    try environment.put("DBT_ENV_SECRET_EMPTY", "");
    try environment.put("DBT_ENV_SECRET_BLANK", " \t\n");
    try environment.put("ORDINARY_VALUE", "visible");
    const projected = try text(allocator, &environment, "visible abcdef abc *; \t\n");
    defer allocator.free(projected);
    try std.testing.expectEqualStrings("visible ***** ***** *****; \t\n", projected);
    const unmatched = try text(allocator, &environment, "visible and useful");
    defer allocator.free(unmatched);
    try std.testing.expectEqualStrings("visible and useful", unmatched);
}

test "structured logs mask decoded values and preserve keys and exact numeric fields" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, projectionAllocationProof, .{});
}

fn projectionAllocationProof(allocator: Allocator) !void {
    var environment = Environment.init(allocator);
    defer environment.deinit();
    try environment.put("DBT_ENV_SECRET_KEY", "info");
    try environment.put("DBT_ENV_SECRET_NUMBER", "123");
    try environment.put("DBT_ENV_SECRET_ESCAPED", "quoted\"\\\n雪");
    const input = "{\"info\":{\"msg\":\"info 123 quoted\\\"\\\\\\n雪\",\"level\":\"error\"},\"data\":{\"info\":123,\"big\":123456789012345678901234567890,\"float\":1.2300,\"ok\":true,\"values\":[\"info\",null]}}\nerror: quoted\"\\\n雪 remains useful\n";
    const projected = try logBuffer(allocator, &environment, input);
    defer allocator.free(projected);
    const end = std.mem.indexOfScalar(u8, projected, '\n').?;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, projected[0..end], .{ .parse_numbers = false });
    defer parsed.deinit();
    const event = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 2), event.count());
    try std.testing.expectEqualStrings("***** ***** *****", event.get("info").?.object.get("msg").?.string);
    try std.testing.expectEqualStrings("error", event.get("info").?.object.get("level").?.string);
    const data = event.get("data").?.object;
    try std.testing.expectEqualStrings("123", data.get("info").?.number_string);
    try std.testing.expectEqualStrings("123456789012345678901234567890", data.get("big").?.number_string);
    try std.testing.expectEqualStrings("1.2300", data.get("float").?.number_string);
    try std.testing.expect(data.get("ok").?.bool);
    try std.testing.expectEqualStrings("*****", data.get("values").?.array.items[0].string);
    try std.testing.expect(data.get("values").?.array.items[1] == .null);
    try std.testing.expectEqualStrings("error: ***** remains useful\n", projected[end + 1 ..]);
    const unmatched = "{\"info\":{\"msg\":\"unchanged\"},\"data\":123}\nplain unchanged\n";
    const preserved = try logBuffer(allocator, &environment, unmatched);
    defer allocator.free(preserved);
    try std.testing.expectEqualStrings(unmatched, preserved);
    const empty = try text(allocator, null, "");
    defer allocator.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
