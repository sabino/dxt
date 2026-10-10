//! Runtime refs must have been captured during parse, including SQL hints.
const std = @import("std");
const types = @import("types.zig");
const expression = @import("expression.zig");

pub fn validate(graph: *const types.Graph, node: *const types.Node, target: []const u8, reference: types.RefDep) !void {
    // OperationProvider and the unit-fixture resolver have distinct contracts.
    if (graph.unit_fixture_relations or std.mem.eql(u8, node.resource_type, "macro") or std.mem.eql(u8, node.unique_id, "operation")) return;
    for (node.depends_on.items) |dependency| if (std.mem.eql(u8, dependency, target)) return;
    var scratch = std.heap.ArenaAllocator.init(graph.allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var hint: std.Io.Writer.Allocating = .init(a);
    defer hint.deinit();
    try hint.writer.writeAll("ref(");
    if (reference.package) |package| try hint.writer.print("{s}, ", .{try expression.repr(.{ .string = package }, a)});
    try hint.writer.writeAll(try expression.repr(.{ .string = reference.name }, a));
    if (reference.version != .null) try hint.writer.print(", v={s}", .{try expression.repr(try @import("config_value.zig").toExpression(a, reference.version), a)});
    try hint.writer.writeAll(")");
    const message = try std.fmt.allocPrint(a, "dbt was unable to infer all dependencies for the model \"{s}\".\nThis typically happens when ref() is placed within a conditional block.\n\nTo fix this, add the following hint to the top of the model \"{s}\":\n\n-- depends_on: {{{{ {s} }}}}", .{ node.name, node.name, hint.written() });
    @import("compile_diagnostics.zig").captureError(node.original_file_path, node.name, message, error.MissingRefDependency);
    return error.MissingRefDependency;
}

test "runtime ref validation accepts parsed dependencies and operation contexts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph = types.Graph{ .allocator = a, .project_name = "demo" };
    var node = types.Node{ .package_name = "demo", .unique_id = "model.demo.child", .name = "child", .path = "models/child.sql", .original_file_path = "models/child.sql", .raw_code = "" };
    const reference = types.RefDep{ .package = "package", .name = "parent", .version = .{ .integer = 2 } };
    try std.testing.expectError(error.MissingRefDependency, validate(&graph, &node, "model.package.parent.v2", reference));
    const message = @import("compile_diagnostics.zig").message(error.MissingRefDependency).?;
    try std.testing.expect(std.mem.indexOf(u8, message, "ref('package', 'parent', v=2)") != null);
    try node.depends_on.append(a, "model.package.parent.v2");
    try validate(&graph, &node, "model.package.parent.v2", reference);
    graph.unit_fixture_relations = true;
    try validate(&graph, &node, "model.demo.other", reference);
    graph.unit_fixture_relations = false;
    node.resource_type = "macro";
    try validate(&graph, &node, "model.demo.other", reference);
}
