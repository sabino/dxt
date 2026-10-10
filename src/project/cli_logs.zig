//! Console and durable file event policy for the native CLI. Log files do not
//! depend on artifact emission, so --no-write-json still retains diagnostics.
const std = @import("std");
const types = @import("types.zig");
const clock = @import("execution_clock.zig");

pub fn finish(runtime: types.Runtime, options: types.Options, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer, output: []const u8, diagnostics: []const u8) !void {
    const data = primaryOutput(args);
    if (data) try stdout.writeAll(output) else try console(runtime, options, stdout, output);
    // Adapter logger events use Core's console stream even when the native
    // execution callback also carries diagnostics on its stderr buffer.
    var diagnostic_lines = std.mem.splitScalar(u8, diagnostics, '\n');
    while (diagnostic_lines.next()) |line| {
        if (line.len == 0) continue;
        try console(runtime, options, if (coreConsoleStream(runtime.allocator, line)) stdout else stderr, line);
    }
    if (args.len < 2 or help(args) or std.mem.eql(u8, args[1], "version") or std.mem.eql(u8, args[1], "--version")) return;
    const path = options.log_path orelse try std.fs.path.join(runtime.allocator, &.{ options.project_dir, "logs" });
    try std.Io.Dir.cwd().createDirPath(runtime.io, path);
    const filename = try std.fs.path.join(runtime.allocator, &.{ path, "dbt.log" });
    var log: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer log.deinit();
    if (!data) try fileEvents(runtime, options, &log.writer, output);
    try fileEvents(runtime, options, &log.writer, diagnostics);
    if (log.written().len == 0) return;
    var file = try std.Io.Dir.cwd().createFile(runtime.io, filename, .{ .truncate = false, .read = true });
    defer file.close(runtime.io);
    const stat = try file.stat(runtime.io);
    if (options.log_file_max_bytes != 0 and stat.size != 0 and stat.size + log.written().len > options.log_file_max_bytes) {
        const backup = try std.fmt.allocPrint(runtime.allocator, "{s}.1", .{filename});
        try std.Io.Dir.rename(std.Io.Dir.cwd(), filename, std.Io.Dir.cwd(), backup, runtime.io);
        var rotated = try std.Io.Dir.cwd().createFile(runtime.io, filename, .{});
        defer rotated.close(runtime.io);
        try rotated.writeStreamingAll(runtime.io, log.written());
    } else {
        try file.writePositionalAll(runtime.io, log.written(), stat.size);
    }
}

fn console(runtime: types.Runtime, options: types.Options, writer: *std.Io.Writer, text: []const u8) !void {
    const minimum: types.LogLevel = if (options.quiet) .@"error" else if (options.debug) .debug else options.log_level;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const severity = level(runtime.allocator, line);
        const event = try displayedEvent(runtime.allocator, line);
        defer if (event) |value| runtime.allocator.free(value.message);
        if (event) |value| if (value.primary) {
            try writer.writeAll(value.message);
            continue;
        };
        if (options.log_level == .none) continue;
        const printed = if (event) |value| value.printed else false;
        if (@intFromEnum(if (printed) types.LogLevel.@"error" else severity) < @intFromEnum(minimum)) continue;
        const display = if (options.log_format != .json and event != null) event.?.message else line;
        if (options.use_colors and options.log_format != .json and !printed) try writer.writeAll("\x1b[0m");
        const color = options.use_colors and options.log_format != .json and (severity == .warn or severity == .@"error");
        if (color) try writer.writeAll(if (severity == .warn) "\x1b[33m" else "\x1b[31m");
        if (options.log_format == .debug and !printed) {
            try clock.writeTimestamp(writer, clock.now(runtime.io));
            try writer.print(" [{s}] [MainThread]: {s}", .{ @tagName(severity), display });
        } else try writer.writeAll(display);
        if (color) try writer.writeAll("\x1b[0m");
        try writer.writeByte('\n');
    }
}

fn fileEvents(runtime: types.Runtime, options: types.Options, writer: *std.Io.Writer, text: []const u8) !void {
    if (options.log_level_file == .none) return;
    const minimum: types.LogLevel = if (options.debug) .debug else options.log_level_file;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const severity = level(runtime.allocator, line);
        if (@intFromEnum(severity) < @intFromEnum(minimum)) continue;
        const event = try displayedEvent(runtime.allocator, line);
        defer if (event) |value| runtime.allocator.free(value.message);
        if (event) |value| if (value.primary) continue;
        const display = if (options.log_format_file != .json and event != null) event.?.message else line;
        if (options.use_colors_file and options.log_format_file != .json) try writer.writeAll("\x1b[0m");
        // Core warning messages are colored by global USE_COLOR before either
        // logger formats them. The file flag independently controls its prefix.
        const color = options.use_colors and options.log_format_file != .json and (severity == .warn or severity == .@"error");
        if (options.log_format_file == .json) {
            if (line[0] == '{') {
                try writer.print("{s}\n", .{line});
                continue;
            }
            try writer.writeAll("{\"data\":{\"message\":");
            try std.json.Stringify.value(line, .{}, writer);
            try writer.writeAll("},\"info\":{\"name\":\"Diagnostic\",\"level\":");
            try std.json.Stringify.value(@tagName(severity), .{}, writer);
            try writer.writeAll(",\"thread\":\"MainThread\",\"ts\":");
            try clock.writeTimestamp(writer, clock.now(runtime.io));
            try writer.writeAll(",\"invocation_id\":");
            if (runtime.invocation) |invocation| try std.json.Stringify.value(&invocation.id, .{}, writer) else try writer.writeAll("null");
            try writer.writeAll("}}\n");
        } else if (options.log_format_file == .debug) {
            try clock.writeTimestamp(writer, clock.now(runtime.io));
            try writer.print(" [{s}] [MainThread]: ", .{@tagName(severity)});
            if (color) try writer.writeAll(if (severity == .warn) "\x1b[33m" else "\x1b[31m");
            try writer.writeAll(display);
        } else {
            if (color) try writer.writeAll(if (severity == .warn) "\x1b[33m" else "\x1b[31m");
            try writer.writeAll(display);
        }
        if (color) try writer.writeAll("\x1b[0m");
        if (options.log_format_file != .json) try writer.writeByte('\n');
    }
}

fn coreConsoleStream(allocator: std.mem.Allocator, line: []const u8) bool {
    if (line.len == 0 or line[0] != '{') return false;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const info = parsed.value.object.get("info") orelse return false;
    if (info != .object) return false;
    const name = info.object.get("name") orelse return false;
    return name == .string and (std.mem.eql(u8, name.string, "AdapterEventWarning") or std.mem.eql(u8, name.string, "JinjaLogWarning") or std.mem.eql(u8, name.string, "PackageMaterializationOverrideDeprecation") or std.mem.eql(u8, name.string, "RunResultError"));
}

const DisplayedEvent = struct { message: []const u8, printed: bool, primary: bool = false };
fn displayedEvent(allocator: std.mem.Allocator, line: []const u8) !?DisplayedEvent {
    if (line[0] != '{') return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const info = parsed.value.object.get("info") orelse return null;
    if (info != .object) return null;
    const name = info.object.get("name") orelse return null;
    if (name != .string) return null;
    const printed = std.mem.eql(u8, name.string, "PrintEvent") or std.mem.eql(u8, name.string, "ShowNode") or std.mem.eql(u8, name.string, "CompiledNode");
    const primary = std.mem.eql(u8, name.string, "SeedSampleTable");
    if (!primary and !printed and !std.mem.startsWith(u8, name.string, "JinjaLog") and !std.mem.eql(u8, name.string, "AdapterEventWarning") and !std.mem.eql(u8, name.string, "PackageMaterializationOverrideDeprecation") and !std.mem.eql(u8, name.string, "NothingToDo") and !std.mem.eql(u8, name.string, "NoNodesForSelectionCriteria") and !std.mem.eql(u8, name.string, "MainEncounteredError") and !std.mem.eql(u8, name.string, "RunResultError") and !std.mem.eql(u8, name.string, "RunningOperationCaughtError")) return null;
    const data = parsed.value.object.get("data") orelse return null;
    if (data != .object) return null;
    const message = info.object.get("msg") orelse data.object.get("msg") orelse data.object.get("message") orelse return null;
    if (message != .string) return null;
    return .{ .message = try allocator.dupe(u8, message.string), .printed = printed, .primary = primary };
}

fn level(allocator: std.mem.Allocator, line: []const u8) types.LogLevel {
    if (line[0] == '{') {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return .info;
        defer parsed.deinit();
        if (parsed.value == .object) if (parsed.value.object.get("info")) |info| if (info == .object) if (info.object.get("level")) |value| if (value == .string) return std.meta.stringToEnum(types.LogLevel, value.string) orelse .info;
    }
    if (std.mem.startsWith(u8, line, "error:")) return .@"error";
    if (std.mem.startsWith(u8, line, "warning:")) return .warn;
    return .info;
}

fn help(args: []const []const u8) bool {
    for (args) |arg| if (std.mem.eql(u8, arg, "--help")) return true;
    return false;
}
fn primaryOutput(args: []const []const u8) bool {
    if (args.len < 2 or help(args)) return true;
    // dbt/task/docs/serve.py uses click.echo directly: the server address is
    // command output and remains visible with --quiet and JSON event logging.
    if (args.len > 2 and std.mem.eql(u8, args[1], "docs") and std.mem.eql(u8, args[2], "serve")) return true;
    if (std.mem.eql(u8, args[1], "explain")) return true;
    if (std.mem.eql(u8, args[1], "analyze")) for (args, 0..) |arg, index| {
        if (std.mem.eql(u8, arg, "--output") and index + 1 < args.len and std.mem.eql(u8, args[index + 1], "json")) return true;
    };
    for ([_][]const u8{ "ls", "version", "--version", "metric", "plan", "apply", "environment", "intervals", "audit", "promote", "rollback" }) |name| if (std.mem.eql(u8, args[1], name)) return true;
    return false;
}
