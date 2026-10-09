const std = @import("std");
const types = @import("types.zig");
const parse = @import("parse.zig");
const includes = @import("dbt_includes");
const expression = @import("expression.zig");

/// The original, version-pinned SQL definitions run through the same native
/// parser and renderer as project macros. No Python runtime is involved.
pub fn load(allocator: std.mem.Allocator, graph: *types.Graph) !void {
    const adapter_package = if (std.mem.eql(u8, graph.adapter_type, "postgres")) "dbt_postgres" else "dbt_duckdb";
    for (includes.files) |file| {
        if (!std.mem.eql(u8, file.package, "dbt") and !std.mem.eql(u8, file.package, adapter_package)) continue;
        if (std.mem.endsWith(u8, file.path, ".sql")) {
            try parse.parseMacrosFromText(allocator, file.text, file.path, file.package, graph);
        } else if (std.mem.eql(u8, file.path, "docs/overview.md")) {
            const open = std.mem.indexOf(u8, file.text, "%}") orelse return error.MalformedDocsBlock;
            const end = std.mem.indexOfPos(u8, file.text, open + 2, "{%") orelse return error.MalformedDocsBlock;
            try graph.docs.append(allocator, .{
                .package_name = "dbt",
                .unique_id = "doc.dbt.__overview__",
                .name = "__overview__",
                .path = "overview.md",
                .original_file_path = "docs/overview.md",
                .block_contents = try allocator.dupe(u8, std.mem.trim(u8, file.text[open + 2 .. end], " \t\r\n")),
            });
        }
    }
}

/// Core Column class methods are pure and available during parsing, before an
/// adapter connection exists. Instance methods live with typed adapter values.
pub fn callColumn(allocator: std.mem.Allocator, name: []const u8, args: []const expression.Argument) !?expression.Value {
    if (std.mem.eql(u8, name, "api.Column.translate_type") or std.mem.eql(u8, name, "adapter.Column.translate_type")) {
        if (args.len != 1 or args[0].value != .string) return error.InvalidJinjaArguments;
        const dtype = args[0].value.string;
        return .{ .string = if (std.ascii.eqlIgnoreCase(dtype, "string")) "TEXT" else dtype };
    }
    if (std.mem.eql(u8, name, "api.Column.numeric_type") or std.mem.eql(u8, name, "adapter.Column.numeric_type")) {
        if (args.len != 3 or args[0].value != .string) return error.InvalidJinjaArguments;
        if (args[1].value == .none or args[2].value == .none) return args[0].value;
        return .{ .string = try std.fmt.allocPrint(allocator, "{s}({s},{s})", .{ args[0].value.string, try args[1].value.text(allocator), try args[2].value.text(allocator) }) };
    }
    if (std.mem.eql(u8, name, "api.Column.string_type") or std.mem.eql(u8, name, "adapter.Column.string_type")) {
        if (args.len != 1) return error.InvalidJinjaArguments;
        return .{ .string = try std.fmt.allocPrint(allocator, "character varying({s})", .{try args[0].value.text(allocator)}) };
    }
    return null;
}

test "bundled definitions contain complete pinned Core and adapter macro sets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try load(allocator, &graph);
    var core_count: usize = 0;
    var adapter_count: usize = 0;
    for (graph.macros.items) |macro| {
        if (std.mem.eql(u8, macro.package_name, "dbt")) core_count += 1 else adapter_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 382), core_count);
    try std.testing.expectEqual(@as(usize, 49), adapter_count);
    try std.testing.expectEqualStrings("doc.dbt.__overview__", graph.docs.items[0].unique_id);
    try std.testing.expect(std.mem.startsWith(u8, graph.docs.items[0].block_contents, "### Welcome!"));
}
