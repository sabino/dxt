//! Core SeedTask.show_table samples the parsed CSV/agate data, independently of
//! warehouse overrides. Its table is primary stdout even with quiet/JSON logs.
const std = @import("std");
const types = @import("types.zig");
const csv = @import("seed_csv.zig");
const values = @import("config_value.zig");
const compiler = @import("compiler.zig");

pub fn write(runtime: types.Runtime, graph: *const types.Graph, options: types.Options, results: []const @import("run_results.zig").NodeResult, stdout: *std.Io.Writer) !void {
    // BuildTask inherits RunTask's end messages; only SeedTask.show_tables
    // emits this primary output, even though Core also accepts build --show.
    if (!options.seed_show or std.mem.eql(u8, options.which, "build")) return;
    for (results) |result| {
        const node = result.node orelse continue;
        if (!std.mem.eql(u8, node.resource_type, "seed") or !std.mem.eql(u8, result.status, "success")) continue;
        const schema = try compiler.relationSchemaForNode(runtime.allocator, graph, node);
        defer runtime.allocator.free(schema);
        const header = try std.fmt.allocPrint(runtime.allocator, "Random sample of table: {s}.{s}", .{ schema, compiler.relationIdentifierForNode(node) });
        defer runtime.allocator.free(header);
        try stdout.print("{s}\n", .{header});
        const table = try render(runtime, node);
        defer runtime.allocator.free(table);
        // The framing event lets the CLI retain raw table stdout regardless of
        // event format/filter, while keeping it out of the durable event log.
        try stdout.writeAll("{\"info\":{\"name\":\"SeedSampleTable\",\"level\":\"info\"},\"data\":{\"msg\":");
        try std.json.Stringify.value(table, .{}, stdout);
        try stdout.writeAll("}}\n");
    }
}

pub fn render(runtime: types.Runtime, node: *const types.Node) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(runtime.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const delimiter = values.get(node.effective_config, "delimiter") orelse std.json.Value{ .string = "," };
    if (delimiter != .string) return error.InvalidSeedDelimiter;
    var document = try csv.parseWithDelimiter(a, node.raw_code, delimiter.string);
    defer document.deinit();
    const indices = try a.alloc(usize, document.rows.len);
    for (indices, 0..) |*index, value| index.* = value;
    var seed: u64 = undefined;
    runtime.io.random(std.mem.asBytes(&seed));
    var random = std.Random.DefaultPrng.init(seed);
    random.random().shuffle(usize, indices);
    const count = @min(document.rows.len, 10);
    const widths = try a.alloc(usize, document.headers.len);
    const kinds = try a.alloc(csv.Kind, document.headers.len);
    const names = try a.alloc([]const u8, document.headers.len);
    for (document.headers, widths, kinds, names, 0..) |name, *width, *kind, *label, column| {
        label.* = try truncate(a, name);
        width.* = try characterCount(label.*);
        kind.* = try csv.infer(a, document.rows, column);
    }
    const rows = try a.alloc([]const []const u8, count);
    for (rows, 0..) |*row, index| {
        const rendered = try a.alloc([]const u8, names.len);
        for (document.rows[indices[index]], rendered, kinds, widths) |cell, *result, kind, *width| {
            const text = if (csv.isNull(cell)) "" else switch (kind) {
                .integer, .number => try csv.number(a, cell),
                .boolean => if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, cell, " \t\r\n"), "true")) "True" else "False",
                .date, .timestamp => std.mem.trim(u8, cell, " \t\r\n"),
                .text => cell,
            };
            result.* = try truncate(a, text);
            width.* = @max(width.*, try characterCount(result.*));
        }
        row.* = rendered;
    }
    var output: std.Io.Writer.Allocating = .init(runtime.allocator);
    errdefer output.deinit();
    try writeRow(&output.writer, names, widths, kinds);
    try output.writer.writeByte('|');
    for (widths) |width| {
        try output.writer.writeByte(' ');
        try output.writer.splatByteAll('-', width);
        try output.writer.writeAll(" |");
    }
    try output.writer.writeByte('\n');
    for (rows) |row| try writeRow(&output.writer, row, widths, kinds);
    if (document.rows.len > count) {
        const ellipsis = try a.alloc([]const u8, names.len);
        @memset(ellipsis, "...");
        try writeRow(&output.writer, ellipsis, widths, kinds);
    }
    return output.toOwnedSlice();
}
fn writeRow(writer: *std.Io.Writer, cells: []const []const u8, widths: []const usize, kinds: []const csv.Kind) !void {
    try writer.writeByte('|');
    for (cells, widths, kinds) |cell, width, kind| {
        const padding = width -| try characterCount(cell);
        try writer.writeByte(' ');
        if (kind != .text) try writer.splatByteAll(' ', padding);
        try writer.writeAll(cell);
        if (kind == .text) try writer.splatByteAll(' ', padding);
        try writer.writeAll(" |");
    }
    try writer.writeByte('\n');
}
fn characterCount(text: []const u8) !usize {
    return std.unicode.utf8CountCodepoints(text);
}
fn truncate(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (try characterCount(text) <= 20) return text;
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    var end: usize = 0;
    for (0..17) |_| end += iterator.nextCodepointSlice().?.len;
    return std.fmt.allocPrint(a, "{s}...", .{text[0..end]});
}

test "seed preview retains CSV values, alignment and bounded primary table output" {
    const a = std.testing.allocator;
    const node = types.Node{ .resource_type = "seed", .package_name = "fixture", .unique_id = "seed.fixture.people", .name = "people", .path = "people.csv", .original_file_path = "seeds/people.csv", .raw_code = "id,name\n2,Alice\n3,Bob\n" };
    const text = try render(.{ .allocator = a, .io = std.testing.io }, &node);
    defer a.free(text);
    try std.testing.expect(std.mem.startsWith(u8, text, "| id | name  |\n| -- | ----- |\n"));
    try std.testing.expect(std.mem.indexOf(u8, text, "|  2 | Alice |") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "|  3 | Bob   |") != null);
}
