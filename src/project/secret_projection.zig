//! Mask declared secret values only when publishing diagnostics. Authored
//! resources and runtime values remain available to their original consumers.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Environment = std.process.Environ.Map;
const mask = "*****";

/// Retain bounded raw diagnostics for the existing publication projector.
/// Parts form one byte stream; complete declared secrets and UTF-8 codepoints
/// are copied atomically. Stop before a secret that cannot fit in full, so the
/// later complete-value projector never receives a prefix created by this cap.
/// Invalid ordinary UTF-8 ends the useful prefix. Inputs must not alias output.
pub fn writeBounded(output: []u8, environment: ?*const Environment, parts: []const []const u8) usize {
    var input: Parts = .{ .items = parts };
    var used: usize = 0;
    while (used < output.len) {
        var matched: []const u8 = "";
        if (environment) |env| {
            var entries = env.iterator();
            while (entries.next()) |entry| {
                const value = entry.value_ptr.*;
                if (value.len > matched.len and std.mem.startsWith(u8, entry.key_ptr.*, "DBT_ENV_SECRET_") and
                    std.mem.trim(u8, value, " \t\r\n\x0b\x0c").len != 0 and input.startsWith(value)) matched = value;
            }
        }
        if (matched.len != 0) {
            if (output.len - used < matched.len or !std.unicode.utf8ValidateSlice(matched)) break;
            @memcpy(output[used..][0..matched.len], matched);
            used += matched.len;
            input.skip(matched.len);
            continue;
        }
        var next = input;
        var codepoint: [4]u8 = undefined;
        codepoint[0] = next.byte() orelse break;
        const length = std.unicode.utf8ByteSequenceLength(codepoint[0]) catch break;
        for (codepoint[1..length]) |*byte| byte.* = next.byte() orelse return used;
        if (!std.unicode.utf8ValidateSlice(codepoint[0..length]) or output.len - used < length) break;
        @memcpy(output[used..][0..length], codepoint[0..length]);
        used += length;
        input = next;
    }
    return used;
}

const Parts = struct {
    items: []const []const u8,
    index: usize = 0,
    offset: usize = 0,

    fn normalize(self: *Parts) void {
        while (self.index < self.items.len and self.offset == self.items[self.index].len) {
            self.index += 1;
            self.offset = 0;
        }
    }
    fn byte(self: *Parts) ?u8 {
        self.normalize();
        if (self.index == self.items.len) return null;
        const value = self.items[self.index][self.offset];
        self.offset += 1;
        return value;
    }
    fn startsWith(self: Parts, value: []const u8) bool {
        var cursor = self;
        var consumed: usize = 0;
        while (consumed < value.len) {
            cursor.normalize();
            if (cursor.index == cursor.items.len) return false;
            const part = cursor.items[cursor.index][cursor.offset..];
            const count = @min(part.len, value.len - consumed);
            if (!std.mem.eql(u8, part[0..count], value[consumed..][0..count])) return false;
            cursor.offset += count;
            consumed += count;
        }
        return true;
    }
    fn skip(self: *Parts, length: usize) void {
        var remaining = length;
        while (remaining != 0) {
            self.normalize();
            const count = @min(self.items[self.index].len - self.offset, remaining);
            self.offset += count;
            remaining -= count;
        }
    }
};

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

test "bounded raw capture keeps complete longest secrets across part and output boundaries" {
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("DBT_ENV_SECRET_SHORT", "abc");
    try environment.put("DBT_ENV_SECRET_LONG", "abcdef");
    try environment.put("DBT_ENV_SECRET_EMPTY", "");
    try environment.put("DBT_ENV_SECRET_BLANK", " \t\n");
    try environment.put("ORDINARY_VALUE", "visible");
    var output: [32]u8 = @splat(0xaa);
    const parts: []const []const u8 = &.{ "pre abc", "", "d", "ef post" };
    var used = writeBounded(&output, &environment, parts);
    try std.testing.expectEqualStrings("pre abcdef post", output[0..used]);
    try std.testing.expectEqual(@as(u8, 0xaa), output[used]);
    try std.testing.expectEqualStrings("pre abc", parts[0]);
    used = writeBounded(output[0..8], &environment, parts);
    try std.testing.expectEqualStrings("pre ", output[0..used]);
    used = writeBounded(output[0..9], &environment, parts);
    try std.testing.expectEqualStrings("pre ", output[0..used]);
    used = writeBounded(output[0..10], &environment, parts);
    try std.testing.expectEqualStrings("pre abcdef", output[0..used]);
    used = writeBounded(output[0..3], &environment, &.{ "ab", "cde", "fx" });
    try std.testing.expectEqual(@as(usize, 0), used);
    used = writeBounded(&output, &environment, &.{ "ab", "cde", "fx" });
    try std.testing.expectEqualStrings("abcdefx", output[0..used]);
    used = writeBounded(&output, &environment, &.{"visible \t\n abcde"});
    try std.testing.expectEqualStrings("visible \t\n abcde", output[0..used]);
    used = writeBounded(output[0..4], &environment, &.{"visible"});
    try std.testing.expectEqualStrings("visi", output[0..used]);
    used = writeBounded(output[0..1], &environment, &.{" \t\n"});
    try std.testing.expectEqualStrings(" ", output[0..used]);
    try environment.put("DBT_ENV_SECRET_STARS", "*");
    used = writeBounded(&output, &environment, &.{ "*", "" });
    try std.testing.expectEqualStrings("*", output[0..used]);
    const published = try text(std.testing.allocator, &environment, output[0..used]);
    defer std.testing.allocator.free(published);
    try std.testing.expectEqualStrings("*****", published);
    try environment.put("DBT_ENV_SECRET_SPACED", " abc ");
    used = writeBounded(&output, &environment, &.{ "x ", "ab", "c y" });
    try std.testing.expectEqualStrings("x abc y", output[0..used]);
    used = writeBounded(output[0..4], &environment, &.{ "x ", "ab", "c y" });
    try std.testing.expectEqualStrings("x", output[0..used]);
}

test "bounded raw capture leaves ordinary incomplete prefixes and valid UTF-8 prefixes intact" {
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    try environment.put("DBT_ENV_SECRET_ENGINE", "private_engine_error");
    var output: [32]u8 = undefined;
    var used = writeBounded(&output, &environment, &.{ "private_", "engine" });
    try std.testing.expectEqualStrings("private_engine", output[0..used]);
    used = writeBounded(output[0..7], &environment, &.{ "private_", "engine" });
    try std.testing.expectEqualStrings("private", output[0..used]);
    used = writeBounded(output[0..7], &environment, &.{ "private_", "engine_error" });
    try std.testing.expectEqual(@as(usize, 0), used);
    for (2..4) |capacity| {
        used = writeBounded(output[0..capacity], null, &.{ "a\xe9", "\x9b", "\xaa b" });
        try std.testing.expectEqualStrings("a", output[0..used]);
    }
    used = writeBounded(output[0..4], null, &.{ "a\xe9", "\x9b", "\xaa b" });
    try std.testing.expectEqualStrings("a雪", output[0..used]);
    try std.testing.expect(std.unicode.utf8ValidateSlice(output[0..used]));
    used = writeBounded(output[0..3], null, &.{ "\xf0\x9f", "\x98\x80" });
    try std.testing.expectEqual(@as(usize, 0), used);
    used = writeBounded(output[0..4], null, &.{ "\xf0\x9f", "\x98\x80" });
    try std.testing.expectEqualStrings("😀", output[0..used]);
    used = writeBounded(&output, null, &.{ "ok\xff", "tail" });
    try std.testing.expectEqualStrings("ok", output[0..used]);
    used = writeBounded(&output, null, &.{ "ok\xe9", "\x9b" });
    try std.testing.expectEqualStrings("ok", output[0..used]);
    try environment.put("DBT_ENV_SECRET_MULTILINE", "雪\nsecret");
    used = writeBounded(&output, &environment, &.{ "\xe9", "\x9b\xaa\ns", "ecret" });
    try std.testing.expectEqualStrings("雪\nsecret", output[0..used]);
    try environment.put("DBT_ENV_SECRET_INVALID", "\xff");
    used = writeBounded(&output, &environment, &.{ "\xff", "ok" });
    try std.testing.expectEqual(@as(usize, 0), used);
    try std.testing.expectEqual(@as(usize, 0), writeBounded(&.{}, &environment, &.{"secret"}));
    try std.testing.expectEqual(@as(usize, 0), writeBounded(&output, null, &.{}));
    try std.testing.expectEqual(@as(usize, 0), writeBounded(&output, null, &.{ "", "" }));
}

test "bounded raw capture leaves no cut secret prefix in a 95000 byte error at the 64 KiB limit" {
    var environment = Environment.init(std.testing.allocator);
    defer environment.deinit();
    const secret = "private_engine_error";
    try environment.put("DBT_ENV_SECRET_ENGINE", secret);
    var input: [95000]u8 = undefined;
    for (0..4750) |index| @memcpy(input[index * secret.len ..][0..secret.len], secret);
    var output: [65536]u8 = @splat(0xaa);
    const used = writeBounded(&output, &environment, &.{ input[0..65536], input[65536..] });
    try std.testing.expectEqual(@as(usize, 65520), used);
    try std.testing.expectEqualStrings(input[0..used], output[0..used]);
    const published = try text(std.testing.allocator, &environment, output[0..used]);
    defer std.testing.allocator.free(published);
    try std.testing.expectEqual(@as(usize, 16380), published.len);
    for (published) |byte| try std.testing.expectEqual(@as(u8, '*'), byte);
    try std.testing.expectEqual(@as(u8, 0xaa), output[used]);
    for (0..4750) |index| try std.testing.expectEqualStrings(secret, input[index * secret.len ..][0..secret.len]);
    // A complete declared value can itself be larger than the raw bound.
    try environment.put("DBT_ENV_SECRET_FULL", &input);
    const full_used = writeBounded(output[0..5], &environment, &.{ input[0..7], "", input[7..] });
    try std.testing.expectEqual(@as(usize, 0), full_used);
}
