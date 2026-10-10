//! The materialization's main response survives later hooks and cleanup SQL.
const std = @import("std");
const expression = @import("expression.zig");
const results = @import("run_results.zig");
const types = @import("types.zig");
const adapter = @import("adapter.zig");

pub const Result = struct {
    message: []const u8,
    response: results.AdapterResponse,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        self.response.deinit(allocator);
    }

    /// Transfers ownership to the durable/concurrent run result.
    pub fn row(self: Result, node: *const types.Node) results.NodeResult {
        return .{ .node = node, .message = self.message, .adapter_response = self.response, .owns_adapter_response = true };
    }
};

pub fn fromValue(allocator: std.mem.Allocator, value: expression.Value) !Result {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    var result = Result{ .message = try allocator.dupe(u8, try value.text(scratch.allocator())), .response = .{} };
    errdefer result.deinit(allocator);
    if (value.attribute("__dxt_adapter_response").truthy()) {
        const message = value.attribute("_message");
        if (message != .string) return error.InvalidMaterializationResponse;
        result.response.message = try allocator.dupe(u8, message.string);
        const code = value.attribute("code");
        if (code != .none and code != .undefined) {
            if (code != .string) return error.InvalidMaterializationResponse;
            result.response.code = try allocator.dupe(u8, code.string);
        }
        const count = value.attribute("rows_affected");
        if (count != .none and count != .undefined) {
            if (count == .integer or expression.integerProtocol(count) != null) {
                result.response.rows_affected = expression.integerIndex(count) catch null;
                if (result.response.rows_affected == null) result.response.rows_affected_value = try @import("config_value.zig").fromExpression(allocator, count);
            } else result.response.rows_affected_value = try @import("config_value.zig").fromExpression(allocator, count);
        }
    }
    return result;
}

/// Core DuckDB get_response always reports OK. PostgreSQL reports its actual
/// main command tag and row count; later cleanup does not overwrite them.
pub fn fromQuery(allocator: std.mem.Allocator, query: adapter.QueryResult) !Result {
    const message = query.command_tag orelse "OK";
    var code: ?[]const u8 = null;
    var count: ?i64 = null;
    if (query.command_tag) |tag| {
        var words = std.mem.tokenizeAny(u8, tag, " \t");
        var label: std.ArrayList(u8) = .empty;
        defer label.deinit(allocator);
        var has_count = false;
        while (words.next()) |word| {
            if (std.fmt.parseUnsigned(u64, word, 10)) |_| has_count = true else |_| {
                if (label.items.len != 0) try label.append(allocator, ' ');
                try label.appendSlice(allocator, word);
            }
        }
        count = if (has_count) std.math.cast(i64, query.rows_changed) orelse return error.InvalidMaterializationResponse else -1;
        code = try label.toOwnedSlice(allocator);
    }
    errdefer if (code) |owned| allocator.free(owned);
    const text = try allocator.dupe(u8, message);
    errdefer allocator.free(text);
    return .{ .message = text, .response = .{ .message = try allocator.dupe(u8, message), .code = code, .rows_affected = count } };
}

pub fn captureQuery(allocator: std.mem.Allocator, destination: ?*?Result, query: adapter.QueryResult) !void {
    if (destination) |output| {
        const result = try fromQuery(allocator, query);
        if (output.*) |previous| previous.deinit(allocator);
        output.* = result;
    }
}

pub fn captureSeed(allocator: std.mem.Allocator, destination: ?*?Result, full_refresh: bool, rows: usize) !void {
    if (destination) |output| {
        const code = if (full_refresh) "CREATE" else "INSERT";
        const message = try std.fmt.allocPrint(allocator, "{s} {d}", .{ code, rows });
        errdefer allocator.free(message);
        const response = try allocator.dupe(u8, message);
        errdefer allocator.free(response);
        const result = Result{ .message = message, .response = .{ .message = response, .code = try allocator.dupe(u8, code), .rows_affected = @intCast(rows) } };
        if (output.*) |previous| previous.deinit(allocator);
        output.* = result;
    }
}

test "main response uses the PostgreSQL command tag and DuckDB OK contract" {
    const allocator = std.testing.allocator;
    const pg = try fromQuery(allocator, .{ .command_tag = "INSERT 0 17", .rows_changed = 17 });
    defer pg.deinit(allocator);
    try std.testing.expectEqualStrings("INSERT 0 17", pg.message);
    try std.testing.expectEqualStrings("INSERT", pg.response.code.?);
    try std.testing.expectEqual(@as(i64, 17), pg.response.rows_affected.?);
    const duck = try fromQuery(allocator, .{});
    defer duck.deinit(allocator);
    try std.testing.expectEqualStrings("OK", duck.message);
    try std.testing.expect(duck.response.code == null and duck.response.rows_affected == null);
}

pub fn captureSkip(allocator: std.mem.Allocator, destination: ?*?Result, relation: []const u8) !void {
    if (destination) |output| {
        var result = Result{ .message = try std.fmt.allocPrint(allocator, "skip {s}", .{relation}), .response = .{} };
        errdefer result.deinit(allocator);
        result.response.message = try allocator.dupe(u8, result.message);
        result.response.code = try allocator.dupe(u8, "skip");
        result.response.rows_affected_value = .{ .string = try allocator.dupe(u8, "-1") };
        if (output.*) |previous| previous.deinit(allocator);
        output.* = result;
    }
}

test "authored main responses retain raw row count types and ownership" {
    const a = std.testing.allocator;
    const value = expression.Value{ .object = &.{
        .{ .key = "__dxt_adapter_response", .value = .{ .boolean = true } },
        .{ .key = "__dxt_rendered", .value = .{ .string = "skip relation" } },
        .{ .key = "_message", .value = .{ .string = "skip relation" } },
        .{ .key = "code", .value = .{ .string = "skip" } },
        .{ .key = "rows_affected", .value = .{ .string = "-1" } },
    } };
    const result = try fromValue(a, value);
    defer result.deinit(a);
    const cloned = try result.response.clone(a);
    defer cloned.deinit(a);
    try std.testing.expectEqualStrings("-1", cloned.rows_affected_value.string);
    try std.testing.expect(result.response.rows_affected_value.string.ptr != cloned.rows_affected_value.string.ptr);
}
