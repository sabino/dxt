//! Preserve Core's checksum of the normalized, unexpanded unit definition.
const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");
const repr = @import("native_repr.zig");
const Writer = std.Io.Writer;

pub fn checksums(graph: *types.Graph) !void {
    for (graph.unit_tests.items) |*unit| unit.checksum = try checksum(graph.allocator, unit);
}
pub fn checksum(allocator: std.mem.Allocator, unit: *const types.UnitTestDef) ![]const u8 {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("{s}-", .{unit.model});
    if (unit.versions == .null) try w.writeAll("None") else {
        try w.writeAll("UnitTestNodeVersions(include=");
        try repr.value(a, w, values.get(unit.versions, "include") orelse .null);
        try w.writeAll(", exclude=");
        try repr.value(a, w, values.get(unit.versions, "exclude") orelse .null);
        try w.writeByte(')');
    }
    try w.writeAll("-[");
    for (unit.given.items, 0..) |fixture, i| {
        if (i != 0) try w.writeAll(", ");
        try fixtureRepr(a, w, fixture, true);
    }
    try w.writeAll("]-");
    try fixtureRepr(a, w, unit.expect, false);
    try w.writeByte('-');
    if (unit.overrides == .null) try w.writeAll("None") else {
        try w.writeAll("UnitTestOverrides(");
        for ([_][]const u8{ "macros", "vars", "env_vars" }, 0..) |key, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("{s}=", .{key});
            try repr.value(a, w, values.get(unit.overrides, key) orelse .{ .object = .empty });
        }
        try w.writeByte(')');
    }
    for (unit.given.items) |fixture| if (fixture.fixture != null) {
        try w.writeByte('-');
        if (fixture.rows_string) |sql| try w.writeAll(sql) else try rowsRepr(a, w, fixture);
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(out.written(), &digest, .{});
    return allocator.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}
fn fixtureRepr(a: std.mem.Allocator, w: *Writer, fixture: types.UnitTestFixture, input: bool) !void {
    try w.writeAll(if (input) "UnitTestInputFixture(input=" else "UnitTestOutputFixture(");
    if (input) {
        if (fixture.input) |name| try repr.string(w, name) else try w.writeAll("None");
        try w.writeAll(", ");
    }
    try w.writeAll("rows=");
    try rowsRepr(a, w, fixture);
    const label = if (equal(fixture.format, "dict")) "Dict" else if (equal(fixture.format, "csv")) "CSV" else "SQL";
    try w.print(", format=<UnitTestFormat.{s}: ", .{label});
    try repr.string(w, fixture.format);
    try w.writeAll(">, fixture=");
    if (fixture.fixture) |name| try repr.string(w, name) else try w.writeAll("None");
    try w.writeByte(')');
}
fn rowsRepr(a: std.mem.Allocator, w: *Writer, fixture: types.UnitTestFixture) !void {
    if (fixture.rows_string) |sql| return repr.string(w, sql);
    if (!fixture.rows_set) return w.writeAll("None");
    try w.writeByte('[');
    for (fixture.rows.items, 0..) |row, i| {
        if (i != 0) try w.writeAll(", ");
        try w.writeByte('{');
        for (row.entries.items, 0..) |entry, j| {
            if (j != 0) try w.writeAll(", ");
            try repr.string(w, entry.key);
            try w.writeAll(": ");
            switch (entry.value.kind) {
                .string => try repr.string(w, entry.value.text),
                .bool => try w.writeAll(if (equal(entry.value.text, "true")) "True" else "False"),
                .null => try w.writeAll("None"),
                .number, .json => {
                    const parsed = try std.json.parseFromSlice(std.json.Value, a, entry.value.text, .{ .parse_numbers = false });
                    try repr.value(a, w, parsed.value);
                },
            }
        }
        try w.writeByte('}');
    }
    try w.writeByte(']');
}
fn equal(l: []const u8, r: []const u8) bool {
    return std.mem.eql(u8, l, r);
}
