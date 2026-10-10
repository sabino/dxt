//! Preserve authored compilation and warehouse errors after render cleanup.
//! Workers retain independent diagnostics; fixed storage bounds error reporting.
const std = @import("std");
threadlocal var buffer: [65536]u8 = undefined;
threadlocal var used: usize = 0;
threadlocal var captured_error: anyerror = error.JinjaCompilerError;

pub fn clear() void {
    used = 0;
}
fn append(text: []const u8) void {
    const length = @min(text.len, buffer.len - used);
    @memcpy(buffer[used .. used + length], text[0..length]);
    used += length;
}
pub fn capture(path: []const u8, name: []const u8, authored: []const u8) void {
    captureError(path, name, authored, error.JinjaCompilerError);
}
pub fn captureError(path: []const u8, name: []const u8, authored: []const u8, err: anyerror) void {
    clear();
    captured_error = err;
    append(phase(err));
    append(" in ");
    append(name);
    append(" (");
    append(path);
    append("):\n");
    append(authored);
    while (used != 0 and !std.unicode.utf8ValidateSlice(buffer[0..used])) used -= 1;
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
    capture("models/orders.sql", "orders", "Expected a Relation");
    try std.testing.expectEqualStrings("Compilation Error in orders (models/orders.sql):\nExpected a Relation", message(error.JinjaCompilerError).?);
    try std.testing.expect(message(error.UnresolvedRef) == null);
    clear();
    try std.testing.expect(message(error.JinjaCompilerError) == null);
}

test "warehouse failures retain their runtime phase while authored errors retain compilation" {
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
