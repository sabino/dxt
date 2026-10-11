//! The two distinct datetime candidates in dbt_common's CSV type tester.
const std = @import("std");
const calendar = @import("workflow_intervals.zig");
const strptime = @import("datetime_strptime.zig");
pub const Parsed = @import("datetime_parse.zig").Parsed;

pub fn date(a: std.mem.Allocator, text: []const u8) !Parsed {
    if (text.len < 8 or text.len > 10 or text[4] != '-') return error.InvalidSeedDate;
    if (text.len == 10 and text[7] == '-') return .{ .civil_ns = @as(i96, try calendar.parseTimestamp(text)) * std.time.ns_per_s };
    const parsed = try strptime.parse(a, text, "%Y-%m-%d");
    return .{ .civil_ns = parsed.civil_ns };
}

pub fn standard(a: std.mem.Allocator, text: []const u8) !Parsed {
    if (text.len < 15 or text.len > 19 or std.mem.indexOfScalar(u8, text, 'T') != null) return error.InvalidSeedDate;
    if (text.len == 19 and text[4] == '-' and text[7] == '-' and text[10] == ' ' and text[13] == ':' and text[16] == ':') return .{ .civil_ns = @as(i96, try calendar.parseTimestamp(text)) * std.time.ns_per_s };
    const parsed = try strptime.parse(a, text, "%Y-%m-%d %H:%M:%S");
    return .{ .civil_ns = parsed.civil_ns };
}

pub fn iso(a: std.mem.Allocator, text: []const u8) !Parsed {
    if (std.mem.indexOfScalar(u8, text, 'T') == null) return error.InvalidSeedDate;
    return @import("datetime_parse.zig").iso(a, text, false);
}
