//! Core compile tasks preserve previous results on failure. Native durable
//! error results are an explicit opt-in for completed per-resource attempts.
const std = @import("std");
const types = @import("types.zig");
const results = @import("run_results.zig");

pub fn publish(options: types.Options, err: anyerror, rows: []const results.NodeResult) bool {
    if (!options.durable_compile_errors or err != error.ExecutionFailure) return false;
    for (rows) |row| if (std.mem.eql(u8, row.status, "error")) return true;
    return false;
}

test "durable publication distinguishes resource errors from preflight and infrastructure failures" {
    const completed = [_]results.NodeResult{
        .{ .status = "success", .compiled_code = "select 1" },
        .{ .status = "error", .message = "authored compilation failure", .compiled_override = false },
    };
    const enabled: types.Options = .{ .durable_compile_errors = true };
    try std.testing.expect(!publish(.{}, error.ExecutionFailure, &completed));
    try std.testing.expect(publish(enabled, error.ExecutionFailure, &completed));
    try std.testing.expect(!publish(enabled, error.ExecutionFailure, &.{}));
    try std.testing.expect(!publish(enabled, error.ExecutionFailure, completed[0..1]));
    try std.testing.expect(!publish(enabled, error.PostgresConnectionFailed, &.{}));
    try std.testing.expect(!publish(enabled, error.AccessDenied, &completed));
    try std.testing.expect(!publish(enabled, error.OutOfMemory, &completed));
}

test "native durable mode never becomes an unsupported Core retry argument" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "compile", "generate" }) |command| {
        const options: types.Options = .{ .which = command, .durable_compile_errors = true };
        const text = try results.renderRunResultsWithArgs(a, &.{}, &options);
        defer a.free(text);
        var document = try std.json.parseFromSlice(std.json.Value, a, text, .{});
        defer document.deinit();
        const args = document.value.object.get("args").?.object;
        try std.testing.expectEqualStrings(command, args.get("which").?.string);
        try std.testing.expect(!args.contains("durable_compile_errors"));
        try std.testing.expect(!args.contains("DXT_DURABLE_COMPILE_ERRORS"));
    }
}
