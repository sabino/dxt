//! Preserve authored compilation and warehouse errors after render cleanup.
//! Workers retain independent diagnostics; fixed storage bounds error reporting.
const std = @import("std");
const Environment = std.process.Environ.Map;
const secret_projection = @import("secret_projection.zig");
threadlocal var buffer: [65536]u8 = undefined;
threadlocal var used: usize = 0;
threadlocal var environment: ?*const Environment = null;
threadlocal var captured_error: anyerror = error.JinjaCompilerError;

/// A worker can run inline on the command thread. Restore that command's
/// environment while keeping the already-owned diagnostic for error reporting.
pub const Scope = struct {
    previous_environment: ?*const Environment,

    pub fn end(self: Scope) void {
        environment = self.previous_environment;
    }
};

pub fn beginScope(current_environment: ?*const Environment) Scope {
    const scope: Scope = .{ .previous_environment = environment };
    clear();
    environment = current_environment;
    return scope;
}

pub fn clear() void {
    used = 0;
}
pub fn capture(path: []const u8, name: []const u8, authored: []const u8) void {
    captureError(path, name, authored, error.JinjaCompilerError);
}
pub fn captureError(path: []const u8, name: []const u8, authored: []const u8, err: anyerror) void {
    clear();
    captured_error = err;
    const parts = [_][]const u8{ phase(err), " in ", name, " (", path, "):\n", authored };
    // Retain original bytes for the existing publication projection. A complete
    // declared value must fit whole; its prefix cannot cross the raw bound.
    // Matching sees the full input and context parts without allocating.
    used = secret_projection.writeBounded(&buffer, environment, &parts);
}
pub fn phase(err: anyerror) []const u8 {
    return switch (err) {
        error.DuckDbExecutionFailed, error.AdapterQueryCancelled => "Runtime Error",
        error.PostgresExecutionFailed, error.PostgresSerializationFailure, error.PostgresDeadlockDetected, error.PostgresLockNotAvailable => "Database Error",
        else => "Compilation Error",
    };
}
pub fn message(err: anyerror) ?[]const u8 {
    return if (err == captured_error and used != 0) buffer[0..used] else null;
}
test "compiler diagnostics retain authored messages and clear between invocations" {
    const scope = beginScope(null);
    defer scope.end();
    capture("models/orders.sql", "orders", "Expected a Relation");
    try std.testing.expectEqualStrings("Compilation Error in orders (models/orders.sql):\nExpected a Relation", message(error.JinjaCompilerError).?);
    try std.testing.expect(message(error.UnresolvedRef) == null);
    clear();
    try std.testing.expect(message(error.JinjaCompilerError) == null);
}

test "warehouse failures retain their runtime phase while authored errors retain compilation" {
    const scope = beginScope(null);
    defer scope.end();
    for ([_]anyerror{ error.DuckDbExecutionFailed, error.PostgresExecutionFailed, error.PostgresSerializationFailure, error.PostgresDeadlockDetected, error.PostgresLockNotAvailable, error.AdapterQueryCancelled }) |err| {
        captureError("tests/check.sql", "check", "Unknown column", err);
        const expected = if (err == error.DuckDbExecutionFailed or err == error.AdapterQueryCancelled)
            "Runtime Error in check (tests/check.sql):\nUnknown column"
        else
            "Database Error in check (tests/check.sql):\nUnknown column";
        try std.testing.expectEqualStrings(expected, message(err).?);
    }
    capture("tests/check.sql", "check", "Authored compiler exception");
    try std.testing.expect(std.mem.startsWith(u8, message(error.JinjaCompilerError).?, "Compilation Error"));
    clear();
}

test "compiler diagnostic capture sees the complete 100000 byte engine error before its bound" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, longErrorCaptureProof, .{});
}

fn longErrorCaptureProof(allocator: std.mem.Allocator) !void {
    var env = Environment.init(allocator);
    defer env.deinit();
    const repeated = "private_engine_error";
    var authored: [100000]u8 = undefined;
    for (0..5000) |index| @memcpy(authored[index * repeated.len ..][0..repeated.len], repeated);
    try env.put("DBT_ENV_SECRET_LONG_ENGINE_ERROR", &authored);
    const scope = beginScope(&env);
    defer scope.end();
    captureError("tests/check.sql", "check", &authored, error.DuckDbExecutionFailed);
    const prefix = "Runtime Error in check (tests/check.sql):\n";
    // A single declared value longer than the raw capacity leaves only useful
    // context. It must not leave the old truncated private_engine_error prefix.
    try std.testing.expectEqualStrings(prefix, message(error.DuckDbExecutionFailed).?);
    try std.testing.expectEqualSlices(u8, &authored, "private_engine_error" ** 5000);

    // Shorter repeated values remain original and whole, so each can be masked
    // once by the existing publication layer. No authored input is changed.
    try env.put("DBT_ENV_SECRET_LONG_ENGINE_ERROR", repeated);
    captureError("tests/check.sql", "check", &authored, error.DuckDbExecutionFailed);
    const captured = message(error.DuckDbExecutionFailed).?;
    const repetitions = (buffer.len - prefix.len) / repeated.len;
    try std.testing.expectEqual(@as(usize, prefix.len + repetitions * repeated.len), captured.len);
    try std.testing.expectEqualStrings(prefix, captured[0..prefix.len]);
    for (0..repetitions) |index| try std.testing.expectEqualStrings(repeated, captured[prefix.len + index * repeated.len ..][0..repeated.len]);
    const projected = try secret_projection.text(allocator, &env, captured);
    defer allocator.free(projected);
    try std.testing.expectEqual(@as(usize, prefix.len + repetitions * 5), projected.len);
    for (projected[prefix.len..]) |byte| try std.testing.expectEqual(@as(u8, '*'), byte);
    try std.testing.expectEqualSlices(u8, &authored, "private_engine_error" ** 5000);
}

test "compiler diagnostic bound cannot publish a partial secret or UTF-8 codepoint" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();
    try env.put("DBT_ENV_SECRET_BOUNDARY", "abcdef");
    const scope = beginScope(&env);
    defer scope.end();
    const prefix = "Compilation Error in n (p):\n";
    var authored: [65536]u8 = @splat('x');
    const boundary = buffer.len - prefix.len - 2;
    @memcpy(authored[boundary..][0..6], "abcdef");
    capture("p", "n", &authored);
    const captured = message(error.JinjaCompilerError).?;
    try std.testing.expectEqual(@as(usize, 65534), captured.len);
    try std.testing.expect(std.mem.endsWith(u8, captured, "x"));
    try std.testing.expect(std.mem.indexOf(u8, captured, "ab") == null);

    @memcpy(authored[boundary..][0..3], "雪");
    capture("p", "n", &authored);
    try std.testing.expectEqual(@as(usize, 65534), message(error.JinjaCompilerError).?.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(message(error.JinjaCompilerError).?));
}

test "compiler capture retains whole context-spanning secrets for one publication projection" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();
    try env.put("DBT_ENV_SECRET_CONTEXT", "check (tests/check.sql):\nprivate_engine_error");
    try env.put("DBT_ENV_SECRET_ENGINE", "private_engine_error");
    const scope = beginScope(&env);
    defer scope.end();
    captureError("tests/check.sql", "check", "private_engine_error remains useful", error.PostgresExecutionFailed);
    try std.testing.expectEqualStrings("Database Error in check (tests/check.sql):\nprivate_engine_error remains useful", message(error.PostgresExecutionFailed).?);
    const projected = try secret_projection.text(std.testing.allocator, &env, message(error.PostgresExecutionFailed).?);
    defer std.testing.allocator.free(projected);
    try std.testing.expectEqualStrings("Database Error in ***** remains useful", projected);
    capture("p", "n", "private_engine remains useful");
    try std.testing.expectEqualStrings("Compilation Error in n (p):\nprivate_engine remains useful", message(error.JinjaCompilerError).?);
}

test "compiler capture does not mask a declared star before publication" {
    var env = Environment.init(std.testing.allocator);
    defer env.deinit();
    try env.put("DBT_ENV_SECRET_STAR", "*");
    const scope = beginScope(&env);
    defer scope.end();
    capture("p", "n", "*");
    try std.testing.expectEqualStrings("Compilation Error in n (p):\n*", message(error.JinjaCompilerError).?);
    const projected = try secret_projection.text(std.testing.allocator, &env, message(error.JinjaCompilerError).?);
    defer std.testing.allocator.free(projected);
    try std.testing.expectEqualStrings("Compilation Error in n (p):\n*****", projected);
}

test "compiler diagnostic scopes reset captures and restore environments without dangling pointers" {
    const baseline = beginScope(null);
    defer baseline.end();
    var outer_env = Environment.init(std.testing.allocator);
    defer outer_env.deinit();
    try outer_env.put("DBT_ENV_SECRET_OUTER", "outer_private");
    {
        const outer = beginScope(&outer_env);
        defer outer.end();
        capture("p", "n", "outer_private");
        try std.testing.expect(environment == &outer_env);
        {
            var inner_env = Environment.init(std.testing.allocator);
            defer inner_env.deinit();
            try inner_env.put("DBT_ENV_SECRET_INNER", "inner_private");
            const inner = beginScope(&inner_env);
            defer inner.end();
            try std.testing.expect(message(error.JinjaCompilerError) == null);
            try std.testing.expect(environment == &inner_env);
            capture("p", "n", "inner_private");
        }
        // Captured bytes outlive the environment that governed their boundary.
        try std.testing.expect(std.mem.endsWith(u8, message(error.JinjaCompilerError).?, "inner_private"));
        try std.testing.expect(environment == &outer_env);
        capture("p", "n", "outer_private inner_private");
    }
    try std.testing.expect(environment == null);
    try std.testing.expect(std.mem.endsWith(u8, message(error.JinjaCompilerError).?, "outer_private inner_private"));
    const next = beginScope(null);
    defer next.end();
    try std.testing.expect(message(error.JinjaCompilerError) == null);
    capture("p", "n", "outer_private inner_private");
    try std.testing.expectEqualStrings("Compilation Error in n (p):\nouter_private inner_private", message(error.JinjaCompilerError).?);
    clear();
}
