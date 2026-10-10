//! Invocation-scoped Core deprecation events and warning policy.
const std = @import("std");
const types = @import("types.zig");
const policy = @import("cli_options.zig");
const event = "PackageMaterializationOverrideDeprecation";

pub fn packageMaterializationOverride(runtime: types.Runtime, graph: *const types.Graph, node: *const types.Node, package: []const u8) !void {
    if (try policy.warningIsSilenced(runtime, event)) return;
    const message = try std.fmt.allocPrint(runtime.allocator, "Installed package '{s}' is overriding the built-in materialization '{s}'. Overrides of built-in materializations from installed packages will be deprecated in future versions of dbt. For more information: https://docs.getdbt.com/reference/global-configs/legacy-behaviors", .{ package, node.materialized });
    defer runtime.allocator.free(message);
    if (try policy.warningIsError(runtime, event)) {
        @import("compile_diagnostics.zig").captureError(node.original_file_path, node.name, message, error.PackageMaterializationOverrideDeprecation);
        return error.PackageMaterializationOverrideDeprecation;
    }
    if (!graph.command_options.show_all_deprecations) if (graph.warning_registry) |registry| {
        if (!try registry.first("deprecation:package-materialization-override")) return;
    };
    const writer = runtime.event_writer orelse return;
    if (graph.warning_registry) |registry| registry.mutex.lockUncancelable(registry.io);
    defer if (graph.warning_registry) |registry| registry.mutex.unlock(registry.io);
    try writer.writeAll("{\"data\":{\"package_name\":");
    try std.json.Stringify.value(package, .{}, writer);
    try writer.writeAll(",\"materialization_name\":");
    try std.json.Stringify.value(node.materialized, .{}, writer);
    try writer.writeAll("},\"info\":{\"name\":\"" ++ event ++ "\",\"code\":\"D016\",\"level\":\"warn\",\"msg\":");
    try std.json.Stringify.value(message, .{}, writer);
    try writer.writeAll(",\"ts\":");
    try @import("execution_clock.zig").writeTimestamp(writer, @import("execution_clock.zig").now(runtime.io));
    try writer.writeAll(",\"invocation_id\":");
    if (runtime.invocation) |invocation| try std.json.Stringify.value(&invocation.id, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll("}}\n");
}

test "package override deprecation deduplicates invocation and honors policy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    var options: types.Options = .{};
    const runtime: types.Runtime = .{ .allocator = a, .io = std.testing.io, .invocation_options = &options, .event_writer = &output.writer };
    var registry = @import("warning_registry.zig").Registry.init(a, std.testing.io);
    defer registry.deinit();
    var graph = types.Graph{ .allocator = a, .project_name = "root", .warning_registry = &registry };
    const node = types.Node{ .unique_id = "model.root.m", .package_name = "root", .name = "m", .path = "m.sql", .original_file_path = "models/m.sql", .raw_code = "", .materialized = "table" };
    try packageMaterializationOverride(runtime, &graph, &node, "dependency");
    try packageMaterializationOverride(runtime, &graph, &node, "dependency");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.written(), event));
    graph.command_options.show_all_deprecations = true;
    try packageMaterializationOverride(runtime, &graph, &node, "dependency");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.written(), event));
    options.warn_error_options = "{silence: [Deprecations]}";
    try packageMaterializationOverride(runtime, &graph, &node, "dependency");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, output.written(), event));
    options.warn_error_options = "{error: [PackageMaterializationOverrideDeprecation]}";
    try std.testing.expectError(error.PackageMaterializationOverrideDeprecation, packageMaterializationOverride(runtime, &graph, &node, "dependency"));
}
