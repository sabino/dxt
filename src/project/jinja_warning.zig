//! Authored Jinja warnings share Core's event policy in parse and execution.
const std = @import("std");
const types = @import("types.zig");
const results = @import("run_results.zig");

pub fn emit(runtime: types.Runtime, node: ?*const types.Node, message: []const u8, collector: ?*std.ArrayList(results.LogMessage), writer: ?*std.Io.Writer) !void {
    const policy = @import("cli_options.zig");
    if (try policy.warningIsSilenced(runtime, "JinjaLogWarning")) return;
    if (try policy.warningIsError(runtime, "JinjaLogWarning")) {
        @import("compile_diagnostics.zig").capture(if (node) |n| n.original_file_path else "", if (node) |n| n.name else "", message);
        return error.JinjaCompilerError;
    }
    if (collector) |events| {
        const owned = try runtime.allocator.dupe(u8, message);
        errdefer runtime.allocator.free(owned);
        try events.append(runtime.allocator, .{ .message = owned, .level = "warn", .is_jinja_warning = true });
    } else if (writer) |output| {
        try @import("concurrent_runner.zig").emitLogMessages(runtime, output, if (node) |n| n.unique_id else "operation", 0, &.{.{ .message = message, .level = "warn", .is_jinja_warning = true }});
    }
}
