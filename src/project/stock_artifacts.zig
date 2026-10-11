//! Run files contain the materializer's actual main payload. SQL mains write
//! before execution; seed mains are published only after loading completes.
const std = @import("std");
const types = @import("types.zig");

pub const Writer = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, *const types.Node, []const u8) anyerror!void,
};

pub fn write(writer: ?Writer, node: *const types.Node, sql: []const u8) !void {
    if (writer) |destination| try destination.write(destination.context, node, sql);
}

pub fn splitPath(allocator: std.mem.Allocator, path: []const u8, suffix: []const u8) ![]const u8 {
    const filename = std.fs.path.basename(path);
    const extension = std.fs.path.extension(filename);
    const stem = filename[0 .. filename.len - extension.len];
    const split = try std.fmt.allocPrint(allocator, "{s}_{s}{s}", .{ stem, suffix, extension });
    defer allocator.free(split);
    return std.fs.path.join(allocator, &.{ std.fs.path.dirname(path) orelse "", stem, split });
}

pub fn writeCompiledBatch(runtime: types.Runtime, graph: *const types.Graph, node: *const types.Node, sql: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(runtime.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const batch = node.runtime_batch orelse return error.InvalidMicrobatchRange;
    const config = try @import("microbatch.zig").configuration(node);
    const suffix = try @import("microbatch.zig").batchLabel(a, batch.start, config.batch_size);
    const relative = try splitPath(a, try @import("artifact_paths.zig").relative(a, node.path, node.original_file_path), suffix);
    var target_path = graph.command_options.target_path orelse "target";
    if (graph.command_options.target_path == null) for (graph.semantic_project_configs.items) |project| {
        if (std.mem.eql(u8, project.package_name, graph.project_name)) if (@import("config_value.zig").get(project.rendered, "target-path")) |value| {
            if (value == .string) target_path = value.string;
        };
    };
    const base = if (std.fs.path.isAbsolute(target_path)) target_path else try std.fs.path.join(a, &.{ graph.command_options.project_dir, target_path });
    const path = try std.fs.path.join(a, &.{ base, "compiled", node.package_name, relative });
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(runtime.io, parent);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = path, .data = sql });
}

test "microbatch run files use Core's nested stem and calendar suffix" {
    const path = try splitPath(std.testing.allocator, "models/marts/events.sql", "2024-01-02");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("models/marts/events/events_2024-01-02.sql", path);
}

test "stock run artifacts pass the exact main statement and propagate write errors" {
    const Capture = struct {
        node: ?*const types.Node = null,
        sql: ?[]const u8 = null,
        fail: bool = false,
        fn save(raw: *anyopaque, node: *const types.Node, sql: []const u8) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.node = node;
            self.sql = sql;
            if (self.fail) return error.ArtifactWriteFailed;
        }
    };
    var node: types.Node = undefined;
    var capture: Capture = .{};
    const destination: Writer = .{ .context = &capture, .write = Capture.save };
    const sql = "create table target as select missing_column;\n";
    try write(destination, &node, sql);
    try std.testing.expect(capture.node.? == &node);
    try std.testing.expect(capture.sql.?.ptr == sql.ptr);
    try std.testing.expectEqualStrings(sql, capture.sql.?);
    capture.fail = true;
    try std.testing.expectError(error.ArtifactWriteFailed, write(destination, &node, sql));
    try write(null, &node, sql);
}
