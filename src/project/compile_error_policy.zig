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

pub fn failFast(options: types.Options, err: anyerror, rows: []const results.NodeResult) bool {
    if (!options.fail_fast or err != error.ExecutionFailure) return false;
    for (rows) |row| if (std.mem.eql(u8, row.status, "error")) return true;
    return false;
}

test "compile fail-fast retains completed resource errors without enabling ordinary durable publication" {
    const rows = [_]results.NodeResult{
        .{ .status = "error", .message = "authored compilation failure", .compiled_override = false },
        .{ .status = "skipped" },
    };
    const options: types.Options = .{ .fail_fast = true };
    try std.testing.expect(failFast(options, error.ExecutionFailure, &rows));
    try std.testing.expect(!publish(options, error.ExecutionFailure, &rows));
    try std.testing.expect(!failFast(.{}, error.ExecutionFailure, &rows));
    try std.testing.expect(!failFast(.{ .durable_compile_errors = true }, error.ExecutionFailure, &rows));
    const both: types.Options = .{ .fail_fast = true, .durable_compile_errors = true };
    try std.testing.expect(failFast(both, error.ExecutionFailure, &rows));
    try std.testing.expect(publish(both, error.ExecutionFailure, &rows));
}

test "compile fail-fast does not reinterpret preflight infrastructure or incomplete attempts" {
    const rows = [_]results.NodeResult{.{ .status = "error" }};
    const options: types.Options = .{ .fail_fast = true };
    try std.testing.expect(!failFast(options, error.InvalidSelector, &rows));
    try std.testing.expect(!failFast(options, error.NativeDuckDbLibraryNotFound, &rows));
    try std.testing.expect(!failFast(options, error.PostgresConnectionFailed, &rows));
    try std.testing.expect(!failFast(options, error.OutOfMemory, &rows));
    try std.testing.expect(!failFast(options, error.ExecutionFailure, &.{}));
    try std.testing.expect(!failFast(options, error.ExecutionFailure, &.{.{ .status = "success" }}));
    try std.testing.expect(!failFast(options, error.ExecutionFailure, &.{.{ .status = "skipped" }}));
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
