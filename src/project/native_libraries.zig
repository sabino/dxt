//! Driver names are host-specific; explicit library overrides take precedence.
const std = @import("std");
pub const Driver = enum { duckdb, postgres };

pub fn candidates(driver: Driver, os: std.Target.Os.Tag) []const []const u8 {
    return switch (driver) {
        .duckdb => switch (os) {
            .macos => &.{ "libduckdb.dylib", "/opt/homebrew/opt/duckdb/lib/libduckdb.dylib", "/usr/local/opt/duckdb/lib/libduckdb.dylib" },
            .windows => &.{"duckdb.dll"},
            else => &.{"libduckdb.so"},
        },
        .postgres => switch (os) {
            .macos => &.{ "libpq.5.dylib", "libpq.dylib", "/opt/homebrew/opt/libpq/lib/libpq.5.dylib", "/usr/local/opt/libpq/lib/libpq.5.dylib" },
            .windows => &.{"libpq.dll"},
            else => &.{"libpq.so.5"},
        },
    };
}

test "native driver discovery uses the selected operating system ABI" {
    try std.testing.expectEqualStrings("libduckdb.dylib", candidates(.duckdb, .macos)[0]);
    try std.testing.expectEqualStrings("libpq.5.dylib", candidates(.postgres, .macos)[0]);
    try std.testing.expectEqualStrings("libduckdb.so", candidates(.duckdb, .linux)[0]);
    try std.testing.expectEqualStrings("libpq.so.5", candidates(.postgres, .linux)[0]);
    try std.testing.expectEqualStrings("duckdb.dll", candidates(.duckdb, .windows)[0]);
    try std.testing.expectEqualStrings("libpq.dll", candidates(.postgres, .windows)[0]);
}
