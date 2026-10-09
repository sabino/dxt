//! The materialization's main response survives later hooks and cleanup SQL.
const std = @import("std");
const expression = @import("expression.zig");
const results = @import("run_results.zig");
const types = @import("types.zig");

pub const Result = struct {
    message: []const u8,
    response: results.AdapterResponse,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.response.message) |text| allocator.free(text);
        if (self.response.code) |text| allocator.free(text);
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
        if (count != .none and count != .undefined) result.response.rows_affected = try expression.integerIndex(count);
    }
    return result;
}
