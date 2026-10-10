const std = @import("std");
const values = @import("config_value.zig");

/// Project constraints describe the dbt Core contract, independently of the
/// product version. Core still parses the syntax with version checking off.
pub fn validate(allocator: std.mem.Allocator, requirement: std.json.Value, installed: []const u8, check: bool) !void {
    if (requirement == .null) return;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const current = try parseVersion(scratch, installed);
    var compatible = true;
    if (requirement == .string) {
        var clauses = std.mem.splitScalar(u8, requirement.string, ',');
        while (clauses.next()) |clause| if (!try matches(scratch, current, clause)) {
            compatible = false;
        };
    } else if (requirement == .array) {
        for (requirement.array.items) |clause| {
            if (clause != .string) return error.InvalidRequiredCoreVersion;
            if (!try matches(scratch, current, clause.string)) compatible = false;
        }
    } else return error.InvalidRequiredCoreVersion;
    if (check and !compatible) return error.IncompatibleRequiredCoreVersion;
}

pub fn validateProject(allocator: std.mem.Allocator, project: std.json.Value, check: bool) !void {
    try validate(allocator, values.get(project, "require-dbt-version") orelse .null, @import("invocation.zig").compatible_core, check);
}

fn matches(allocator: std.mem.Allocator, current: std.SemanticVersion, clause: []const u8) !bool {
    var at: usize = 0;
    while (at < clause.len and std.mem.indexOfScalar(u8, "<>=", clause[at]) != null) at += 1;
    const operator = clause[0..at];
    if (operator.len != 0 and !std.mem.eql(u8, operator, "=") and !std.mem.eql(u8, operator, "<") and !std.mem.eql(u8, operator, "<=") and !std.mem.eql(u8, operator, ">") and !std.mem.eql(u8, operator, ">=")) return error.InvalidRequiredCoreVersion;
    const bound = try parseVersion(allocator, clause[at..]);
    const order = current.order(bound);
    if (operator.len == 0 or std.mem.eql(u8, operator, "=")) return order == .eq;
    if (std.mem.eql(u8, operator, "<")) return order == .lt;
    if (std.mem.eql(u8, operator, "<=")) return order != .gt;
    if (std.mem.eql(u8, operator, ">")) return order == .gt;
    return order != .lt;
}

fn parseVersion(allocator: std.mem.Allocator, raw: []const u8) !std.SemanticVersion {
    if (raw.len == 0) return error.InvalidRequiredCoreVersion;
    // Core accepts release candidates both with and without a dash.
    var dots: usize = 0;
    var boundary: usize = 0;
    while (boundary < raw.len) : (boundary += 1) {
        const char = raw[boundary];
        if (char == '.') {
            dots += 1;
            if (dots > 2) break;
        } else if (!std.ascii.isDigit(char)) break;
    }
    const normalized = if (dots == 2 and boundary < raw.len and raw[boundary] != '-' and raw[boundary] != '+') try std.fmt.allocPrint(allocator, "{s}-{s}", .{ raw[0..boundary], raw[boundary..] }) else raw;
    return std.SemanticVersion.parse(normalized) catch error.InvalidRequiredCoreVersion;
}

test "Core version requirements use compatibility version and preserve syntax validation" {
    const allocator = std.testing.allocator;
    try validate(allocator, .{ .string = ">=1.5.0,<2.0.0" }, "1.10.5", true);
    try validate(allocator, .{ .string = "=1.10.5+build" }, "1.10.5", true);
    try validate(allocator, .{ .string = ">1.10.5rc1" }, "1.10.5", true);
    try std.testing.expectError(error.IncompatibleRequiredCoreVersion, validate(allocator, .{ .string = ">=1.11.0" }, "1.10.5", true));
    try validate(allocator, .{ .string = ">=1.11.0" }, "1.10.5", false);
    for ([_][]const u8{ "*", ">=1.11", "==1.10.5", "!=1.10.5", ">=01.10.5", "bad", ">=1.5.0, <2.0.0" }) |invalid| {
        try std.testing.expectError(error.InvalidRequiredCoreVersion, validate(allocator, .{ .string = invalid }, "1.10.5", false));
    }
}
