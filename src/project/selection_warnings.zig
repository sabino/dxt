const std = @import("std");
const types = @import("types.zig");
const selector = @import("selector.zig");
const expressions = @import("selection_expression.zig");
const cli_options = @import("cli_options.zig");
const clock = @import("execution_clock.zig");

/// Warnings are evaluated on the enabled graph before a command narrows its
/// resource types. Each explicit CLI union clause has its own expectation;
/// its comma-separated intersection is one criterion in Core's event contract.
pub fn check(runtime: types.Runtime, graph: *const types.Graph, select: ?[]const u8, exclude: ?[]const u8, context: selector.SelectionContext, writer: *std.Io.Writer) !void {
    var owned: ?*expressions.Expression = null;
    defer if (owned) |expression| expression.destroy(runtime.allocator);
    const expression = context.expression orelse blk: {
        const included = try expressions.parseCli(runtime.allocator, select);
        errdefer included.destroy(runtime.allocator);
        if (exclude) |value| {
            const excluded = try expressions.parseCli(runtime.allocator, value);
            errdefer excluded.destroy(runtime.allocator);
            owned = try expressions.difference(runtime.allocator, included, excluded);
        } else owned = included;
        break :blk owned.?;
    };
    try checkExpression(runtime, graph, expression, context, writer);
}

fn checkExpression(runtime: types.Runtime, graph: *const types.Graph, expression: *const expressions.Expression, context: selector.SelectionContext, writer: *std.Io.Writer) anyerror!void {
    for (expression.children.items) |child| try checkExpression(runtime, graph, child, context, writer);
    const criterion = expression.unmatched_criterion orelse return;
    var criteria_context = context;
    criteria_context.expression = expression;
    criteria_context.execution_only = false;
    criteria_context.allowed_ids = null;
    const matched = try selector.selectResourcesWithContext(runtime.allocator, graph, null, null, null, criteria_context);
    defer runtime.allocator.free(matched);
    if (matched.len == 0) {
        const message = try std.fmt.allocPrint(runtime.allocator, "The selection criterion '{s}' does not match any enabled nodes", .{criterion});
        defer runtime.allocator.free(message);
        try warning(runtime, writer, "NoNodesForSelectionCriteria", "M030", message, criterion);
    }
}

pub fn nothingToDo(runtime: types.Runtime, writer: *std.Io.Writer) !void {
    try warning(runtime, writer, "NothingToDo", "Q035", "Nothing to do. Try checking your model configs and model specification args", null);
}

fn warning(runtime: types.Runtime, writer: *std.Io.Writer, event: []const u8, code: []const u8, message: []const u8, criterion: ?[]const u8) !void {
    if (try cli_options.warningIsSilenced(runtime, event)) return;
    const promoted = try cli_options.warningIsError(runtime, event);
    try writer.writeAll("{\"data\":{");
    if (criterion) |raw| {
        try writer.writeAll("\"spec_raw\":");
        try std.json.Stringify.value(raw, .{}, writer);
        try writer.writeByte(',');
    }
    try writer.writeAll("\"msg\":");
    try std.json.Stringify.value(message, .{}, writer);
    try writer.writeAll("},\"info\":{\"name\":");
    try std.json.Stringify.value(if (promoted) "MainEncounteredError" else event, .{}, writer);
    try writer.writeAll(",\"code\":");
    try std.json.Stringify.value(code, .{}, writer);
    try writer.writeAll(",\"msg\":");
    try std.json.Stringify.value(message, .{}, writer);
    try writer.writeAll(",\"level\":");
    try std.json.Stringify.value(if (promoted) "error" else "warn", .{}, writer);
    try writer.writeAll(",\"thread\":\"MainThread\",\"ts\":");
    try clock.writeTimestamp(writer, clock.now(runtime.io));
    try writer.writeAll(",\"invocation_id\":");
    if (runtime.invocation) |invocation| try std.json.Stringify.value(&invocation.id, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll("}}\n");
    if (promoted) return error.SelectionWarningAsError;
}

test "CLI criteria preserve intersection warning boundaries through cloning" {
    const allocator = std.testing.allocator;
    const expression = try expressions.parseCli(allocator, "a absent,tag:missing");
    defer expression.destroy(allocator);
    const cloned = try expression.clone(allocator);
    defer cloned.destroy(allocator);
    try std.testing.expectEqualStrings("a", cloned.children.items[0].unmatched_criterion.?);
    try std.testing.expectEqualStrings("absent,tag:missing", cloned.children.items[1].unmatched_criterion.?);
    try std.testing.expect(cloned.children.items[1].children.items[0].unmatched_criterion == null);
}
