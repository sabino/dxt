//! Private native connection initialization matching dbt-duckdb 1.9.6.
const std = @import("std");
const values = @import("config_value.zig");
const sql = @import("adapter_result.zig");
const Value = std.json.Value;

pub fn validate(profile: Value) !void {
    if (profile == .null) return;
    if (profile != .object) return error.InvalidDuckDbProfile;
    inline for (.{ "config_options", "settings" }) |key| if (values.get(profile, key)) |value| {
        if (value != .null and value != .object) return error.InvalidDuckDbProfile;
    };
    inline for (.{ "extensions", "attach", "secrets" }) |key| if (values.get(profile, key)) |value| {
        if (value != .null and value != .array) return error.InvalidDuckDbProfile;
    };
    inline for (.{ "plugins", "filesystems", "module_paths" }) |key| if (values.get(profile, key)) |value| {
        if (value != .null) {
            if (value != .array) return error.InvalidDuckDbProfile;
            if (value.array.items.len != 0) return error.UnsupportedDuckDbPythonProfile;
        }
    };
    if (values.get(profile, "remote")) |value| if (value != .null) {
        if (value != .object) return error.InvalidDuckDbProfile;
        return error.UnsupportedDuckDbPythonProfile;
    };
    if (values.get(profile, "disable_transactions")) |value| if (value != .null and value != .bool) return error.InvalidDuckDbProfile;
    if (values.get(profile, "keep_open")) |value| if (value != .null and value != .bool) return error.InvalidDuckDbProfile;
    if (values.get(profile, "retries")) |retries| if (retries != .null) {
        if (retries != .object) return error.InvalidDuckDbRetryPolicy;
        inline for (.{ "connect_attempts", "query_attempts" }) |key| if (values.get(retries, key)) |count| {
            if (count != .null and (count != .integer or count.integer < 0 or count.integer > std.math.maxInt(u32))) return error.InvalidDuckDbRetryPolicy;
        };
        if (values.get(retries, "retryable_exceptions")) |exceptions| {
            if (exceptions != .array) return error.InvalidDuckDbRetryPolicy;
            for (exceptions.array.items) |exception| if (exception != .string) return error.InvalidDuckDbRetryPolicy;
        }
    };
    if (values.get(profile, "use_credential_provider")) |value| if (value != .null and !(value == .bool and !value.bool) and !(value == .string and value.string.len == 0)) {
        if (value != .string or !std.mem.eql(u8, value.string, "aws")) return error.InvalidDuckDbCredentialProvider;
    };
}

pub fn configuration(profile: Value) Value {
    const value = values.get(profile, "config_options") orelse return .null;
    return if (value == .object) value else .null;
}

pub fn disableTransactions(profile: Value) bool {
    const value = values.get(profile, "disable_transactions") orelse return false;
    return value == .bool and value.bool;
}

pub fn keepOpen(profile: Value) bool {
    const value = values.get(profile, "keep_open") orelse return true;
    return value != .bool or value.bool;
}

pub fn attempts(profile: Value, connect: bool) u32 {
    const retries = values.get(profile, "retries") orelse return 1;
    const count = values.get(retries, if (connect) "connect_attempts" else "query_attempts") orelse return 1;
    if (count != .integer) return 1;
    if (!connect and count.integer == 0) return 1;
    return @intCast(count.integer);
}

pub fn retryable(profile: Value, exception_name: []const u8) bool {
    const retries = values.get(profile, "retries") orelse return false;
    if (retries != .object) return false;
    const exceptions = values.get(retries, "retryable_exceptions") orelse return std.mem.eql(u8, exception_name, "IOException");
    if (exceptions != .array) return false;
    for (exceptions.array.items) |exception| if (exception == .string and std.mem.eql(u8, exception.string, exception_name)) return true;
    return false;
}

pub fn queryRetries(profile: Value) bool {
    const retries = values.get(profile, "retries") orelse return false;
    const count = values.get(retries, "query_attempts") orelse return false;
    return count == .integer and count.integer > 0;
}

pub fn digest(a: std.mem.Allocator, profile: Value, global: bool) ![32]u8 {
    var hash: std.crypto.hash.sha2.Sha256 = .init(.{});
    if (global) {
        inline for (.{ "extensions", "secrets", "attach", "use_credential_provider" }) |key| {
            const text = try std.json.Stringify.valueAlloc(a, values.get(profile, key) orelse .null, .{});
            defer a.free(text);
            hash.update(key);
            hash.update(text);
            hash.update("\x00");
        }
    } else {
        const text = try std.json.Stringify.valueAlloc(a, configuration(profile), .{});
        defer a.free(text);
        hash.update(text);
    }
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

pub fn initializeGlobal(connection: anytype, profile: Value) !void {
    var arena = std.heap.ArenaAllocator.init(connection.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (values.get(profile, "extensions")) |extensions| if (extensions == .array) {
        for (extensions.array.items) |extension| {
            const name = if (extension == .string) extension.string else if (extension == .object) try requiredString(extension, "name") else return error.InvalidDuckDbExtension;
            const quoted = try sql.quoteLiteral(a, name);
            if (extension == .object) {
                const repository = try requiredString(extension, "repo");
                try connection.execute(try std.fmt.allocPrint(a, "install {s} from {s}", .{ quoted, try sql.quoteLiteral(a, repository) }));
            } else try connection.execute(try std.fmt.allocPrint(a, "install {s}", .{quoted}));
            try connection.execute(try std.fmt.allocPrint(a, "load {s}", .{quoted}));
        }
    };
    if (values.get(profile, "secrets")) |secrets| if (secrets == .array) {
        for (secrets.array.items, 0..) |secret, index| try connection.execute(try renderSecret(a, secret, index));
    };
    if (values.get(profile, "use_credential_provider")) |provider| if (provider == .string and std.mem.eql(u8, provider.string, "aws")) {
        const start: usize = if (values.get(profile, "secrets")) |secrets| if (secrets == .array) secrets.array.items.len else 0 else 0;
        var secret: Value = .{ .object = .empty };
        try values.put(a, &secret, "type", .{ .string = "s3" });
        try values.put(a, &secret, "provider", .{ .string = "credential_chain" });
        try connection.execute(try renderSecret(a, secret, start));
    };
    if (values.get(profile, "attach")) |attachments| if (attachments == .array) {
        for (attachments.array.items) |attachment| try connection.execute(try renderAttachment(a, attachment));
    };
}

pub fn initializeCursor(connection: anytype, profile: Value) !void {
    const settings = values.get(profile, "settings") orelse return;
    if (settings != .object) return;
    var arena = std.heap.ArenaAllocator.init(connection.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var it = settings.object.iterator();
    while (it.next()) |entry| {
        if (!optionName(entry.key_ptr.*)) return error.InvalidDuckDbSetting;
        const text = try scalar(a, entry.value_ptr.*);
        try connection.execute(try std.fmt.allocPrint(a, "set {s}={s}", .{ try sql.quoteIdentifier(a, entry.key_ptr.*), try sql.quoteLiteral(a, text) }));
    }
}

fn requiredString(value: Value, key: []const u8) ![]const u8 {
    const item = values.get(value, key) orelse return error.InvalidDuckDbProfile;
    if (item != .string or item.string.len == 0) return error.InvalidDuckDbProfile;
    return item.string;
}

fn scalar(a: std.mem.Allocator, value: Value) ![]const u8 {
    return switch (value) {
        .string => value.string,
        .bool => if (value.bool) "True" else "False",
        .integer, .float, .number_string => values.scalarText(a, value),
        else => error.InvalidDuckDbProfile,
    };
}

fn optionName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

fn renderAttachment(a: std.mem.Allocator, attachment: Value) ![]const u8 {
    if (attachment != .object) return error.InvalidDuckDbAttachment;
    const path = try requiredString(attachment, "path");
    const clean_path = if (std.mem.indexOfScalar(u8, path, '?')) |query_start| blk: {
        if (std.mem.indexOfScalarPos(u8, path, query_start, '#')) |fragment| break :blk try std.mem.concat(a, u8, &.{ path[0..query_start], path[fragment..] });
        break :blk path[0..query_start];
    } else path;
    const options = values.get(attachment, "options") orelse .null;
    if (options != .null and options != .object) return error.InvalidDuckDbAttachment;
    var parts: std.ArrayList([]const u8) = .empty;
    inline for (.{ "type", "secret", "read_only" }) |key| {
        const direct = values.get(attachment, key) orelse .null;
        const supplied = values.get(options, key);
        const active = direct != .null and !(direct == .bool and !direct.bool);
        if (active and supplied != null) return error.ConflictingDuckDbAttachmentOptions;
        const value = if (active) direct else supplied orelse .null;
        if (std.mem.eql(u8, key, "read_only")) {
            if (value != .null and value != .bool) return error.InvalidDuckDbAttachment;
            if (value == .bool and value.bool) try parts.append(a, "READ_ONLY");
        } else if (value != .null) {
            if (value != .string) return error.InvalidDuckDbAttachment;
            try parts.append(a, try std.fmt.allocPrint(a, "{s} {s}", .{ key, try sql.quoteIdentifier(a, value.string) }));
        }
    }
    if (options == .object) {
        var it = options.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "type") or std.mem.eql(u8, key, "secret") or std.mem.eql(u8, key, "read_only")) continue;
            if (!optionName(key)) return error.InvalidDuckDbAttachment;
            const value = entry.value_ptr.*;
            if (value == .null or (value == .bool and !value.bool)) continue;
            if (value == .bool) {
                try parts.append(a, key);
                continue;
            }
            const text = try scalar(a, value);
            const rendered = if (value == .string) blk: {
                const trimmed = std.mem.trim(u8, text, " \t\r\n");
                if (trimmed.len >= 2 and ((trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\'') or (trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"'))) break :blk text;
                break :blk try sql.quoteLiteral(a, text);
            } else text;
            try parts.append(a, try std.fmt.allocPrint(a, "{s} {s}", .{ key, rendered }));
        }
    }
    const alias = values.get(attachment, "alias") orelse .null;
    if (alias != .null and alias != .string) return error.InvalidDuckDbAttachment;
    return std.fmt.allocPrint(a, "attach if not exists {s}{s}{s}", .{
        try sql.quoteLiteral(a, clean_path),
        if (alias == .string and alias.string.len != 0) try std.fmt.allocPrint(a, " as {s}", .{try sql.quoteIdentifier(a, alias.string)}) else "",
        if (parts.items.len != 0) try std.fmt.allocPrint(a, " ({s})", .{try std.mem.join(a, ",", parts.items)}) else "",
    });
}

fn secretValue(a: std.mem.Allocator, key: []const u8, value: Value) anyerror![]const u8 {
    if (!optionName(key)) return error.InvalidDuckDbSecret;
    if (value == .object) {
        var pairs: std.ArrayList([]const u8) = .empty;
        var it = value.object.iterator();
        while (it.next()) |entry| try pairs.append(a, try std.fmt.allocPrint(a, "{s}:{s}", .{ try sql.quoteLiteral(a, entry.key_ptr.*), try sql.quoteLiteral(a, try scalar(a, entry.value_ptr.*)) }));
        return std.fmt.allocPrint(a, "{s} map {{{s}}}", .{ key, try std.mem.join(a, ",", pairs.items) });
    }
    if (value == .array) {
        var items: std.ArrayList([]const u8) = .empty;
        for (value.array.items) |item| try items.append(a, try sql.quoteLiteral(a, try scalar(a, item)));
        return std.fmt.allocPrint(a, "{s} array [{s}]", .{ key, try std.mem.join(a, ",", items.items) });
    }
    const text = try scalar(a, value);
    const unquoted = std.mem.eql(u8, key, "type") or std.mem.eql(u8, key, "provider") or std.mem.eql(u8, key, "extra_http_headers");
    return std.fmt.allocPrint(a, "{s} {s}", .{ key, if (unquoted) try sql.quoteIdentifier(a, text) else try sql.quoteLiteral(a, text) });
}

fn renderSecret(a: std.mem.Allocator, secret: Value, index: usize) ![]const u8 {
    if (secret != .object) return error.InvalidDuckDbSecret;
    _ = try requiredString(secret, "type");
    const name = values.get(secret, "name") orelse Value{ .string = try std.fmt.allocPrint(a, "_dbt_secret_{d}", .{index + 1}) };
    if (name != .string and name != .null) return error.InvalidDuckDbSecret;
    const persistent = values.get(secret, "persistent") orelse Value{ .bool = false };
    if (persistent != .null and persistent != .bool) return error.InvalidDuckDbSecret;
    var parts: std.ArrayList([]const u8) = .empty;
    var it = secret.object.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "name") or std.mem.eql(u8, key, "persistent") or entry.value_ptr.* == .null) continue;
        if (std.mem.eql(u8, key, "scope") and entry.value_ptr.* == .array) {
            for (entry.value_ptr.array.items) |scope| try parts.append(a, try secretValue(a, key, scope));
        } else try parts.append(a, try secretValue(a, key, entry.value_ptr.*));
    }
    const named = name == .string and name.string.len != 0;
    return std.fmt.allocPrint(a, "create{s}{s} secret{s} ({s})", .{
        if (named) " or replace" else "",
        if (persistent == .bool and persistent.bool) " persistent" else "",
        if (named) try std.fmt.allocPrint(a, " {s}", .{try sql.quoteIdentifier(a, name.string)}) else "",
        try std.mem.join(a, ",", parts.items),
    });
}

test "connection bootstrap renders extension installation before secrets and attachments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const profile = try std.json.parseFromSlice(Value, a,
        \\{"extensions":["parquet",{"name":"httpfs","repo":"local-repo"}],"secrets":[{"type":"http","bearer_token":"synthetic ' token","scope":["https://example.invalid/a","https://example.invalid/b"]}],"attach":[{"path":"warehouse.duckdb?ignored=yes","alias":"attached data","options":{"read_only":true,"type":"duckdb"}}],"settings":{"TimeZone":"Europe/Amsterdam","threads":2}}
    , .{});
    const Recorder = struct {
        allocator: std.mem.Allocator,
        commands: std.ArrayList([]const u8) = .empty,
        pub fn execute(self: *@This(), command: []const u8) !void {
            try self.commands.append(self.allocator, try self.allocator.dupe(u8, command));
        }
    };
    var connection = Recorder{ .allocator = a };
    try validate(profile.value);
    try initializeGlobal(&connection, profile.value);
    try initializeCursor(&connection, profile.value);
    try std.testing.expectEqual(@as(usize, 8), connection.commands.items.len);
    try std.testing.expectEqualStrings("install 'parquet'", connection.commands.items[0]);
    try std.testing.expectEqualStrings("load 'parquet'", connection.commands.items[1]);
    try std.testing.expectEqualStrings("install 'httpfs' from 'local-repo'", connection.commands.items[2]);
    try std.testing.expectEqualStrings("load 'httpfs'", connection.commands.items[3]);
    try std.testing.expect(std.mem.startsWith(u8, connection.commands.items[4], "create or replace secret \"_dbt_secret_1\""));
    try std.testing.expect(std.mem.indexOf(u8, connection.commands.items[4], "synthetic '' token") != null);
    try std.testing.expectEqualStrings("attach if not exists 'warehouse.duckdb' as \"attached data\" (type \"duckdb\",READ_ONLY)", connection.commands.items[5]);
    try std.testing.expectEqualStrings("set \"TimeZone\"='Europe/Amsterdam'", connection.commands.items[6]);
    try std.testing.expectEqualStrings("set \"threads\"='2'", connection.commands.items[7]);
}
