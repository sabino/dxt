//! Console and durable file event policy for the native CLI. Log files do not
//! depend on artifact emission, so --no-write-json still retains diagnostics.
const std = @import("std");
const types = @import("types.zig");
const clock = @import("execution_clock.zig");

pub fn finish(runtime: types.Runtime, options: types.Options, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer, output: []const u8, diagnostics: []const u8) !void {
    const data = primaryOutput(args);
    if (data) try stdout.writeAll(output) else try console(runtime, options, stdout, output);
    try console(runtime, options, stderr, diagnostics);
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
    const minimum: types.LogLevel = if (options.quiet) .@"error" else options.log_level;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const severity = level(runtime.allocator, line);
        if (@intFromEnum(severity) < @intFromEnum(minimum)) continue;
        const color = options.use_colors and options.log_format != .json and (severity == .warn or severity == .@"error");
        if (color) try writer.writeAll(if (severity == .warn) "\x1b[33m" else "\x1b[31m");
        if (options.log_format == .debug) {
            try clock.writeTimestamp(writer, clock.now(runtime.io));
            try writer.print(" [{s}] [MainThread]: {s}", .{ @tagName(severity), line });
        } else try writer.writeAll(line);
        if (color) try writer.writeAll("\x1b[0m");
        try writer.writeByte('\n');
    }
}

fn fileEvents(runtime: types.Runtime, options: types.Options, writer: *std.Io.Writer, text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const severity = level(runtime.allocator, line);
        if (@intFromEnum(severity) < @intFromEnum(options.log_level_file)) continue;
        const color = options.use_colors_file and options.log_format_file != .json and (severity == .warn or severity == .@"error");
        if (color) try writer.writeAll(if (severity == .warn) "\x1b[33m" else "\x1b[31m");
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
            try writer.print(" [{s}] [MainThread]: {s}", .{ @tagName(severity), line });
        } else try writer.writeAll(line);
        if (color) try writer.writeAll("\x1b[0m");
        if (options.log_format_file != .json) try writer.writeByte('\n');
    }
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
    for ([_][]const u8{ "ls", "version", "--version", "metric", "plan", "apply", "environment", "intervals", "audit", "promote", "rollback" }) |name| if (std.mem.eql(u8, args[1], name)) return true;
    return false;
}
