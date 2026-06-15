const std = @import("std");
const Io = std.Io;

pub const version = "0.0.0";

pub const ExitCode = enum(u8) {
    ok = 0,
    usage = 2,
};

pub fn run(args: []const []const u8, stdout: *Io.Writer, stderr: *Io.Writer) !ExitCode {
    if (args.len <= 1) {
        try printRootHelp(stdout);
        return .ok;
    }

    const command = args[1];
    if (equals(command, "-h") or equals(command, "--help")) {
        try printRootHelp(stdout);
        return .ok;
    }
    if (equals(command, "--version")) {
        try stdout.print("dxt {s}\n", .{version});
        return .ok;
    }
    if (equals(command, "version")) {
        try stdout.print("{s}\n", .{version});
        return .ok;
    }

    if (equals(command, "parse") or equals(command, "compile")) {
        return planned(command, args[2..], stdout, stderr, .common_and_select, .project_selection);
    }
    if (equals(command, "ls")) {
        return planned(command, args[2..], stdout, stderr, .list, .list);
    }
    if (equals(command, "build")) {
        return planned(command, args[2..], stdout, stderr, .build, .build);
    }
    if (equals(command, "docs")) {
        if (args.len >= 3 and equals(args[2], "generate")) {
            return planned("docs generate", args[3..], stdout, stderr, .common_only, .docs_generate);
        }
        try stderr.print("error: expected `dxt docs generate`\n", .{});
        return .usage;
    }

    try stderr.print("error: unknown command `{s}`\n\n", .{command});
    try printRootHelp(stderr);
    return .usage;
}

const OptionMode = enum {
    common_only,
    common_and_select,
    list,
    build,
};

const HelpMode = enum {
    project_selection,
    list,
    build,
    docs_generate,
};

fn planned(command: []const u8, args: []const []const u8, stdout: *Io.Writer, stderr: *Io.Writer, option_mode: OptionMode, help_mode: HelpMode) !ExitCode {
    if (hasHelp(args)) {
        try printCommandHelp(command, stdout, help_mode);
        return .ok;
    }
    if (!try validateOptions(args, stderr, option_mode)) {
        return .usage;
    }
    try stdout.print("`dxt {s}` is planned but not implemented yet. See PLAN.md.\n", .{command});
    return .usage;
}

fn hasHelp(args: []const []const u8) bool {
    for (args) |arg| {
        if (equals(arg, "-h") or equals(arg, "--help")) return true;
    }
    return false;
}

fn validateOptions(args: []const []const u8, stderr: *Io.Writer, mode: OptionMode) !bool {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (equals(arg, "-h") or equals(arg, "--help")) return true;
        if (requiresValue(arg, mode)) {
            if (i + 1 >= args.len) {
                try stderr.print("error: option `{s}` requires a value\n", .{arg});
                return false;
            }
            i += 1;
            continue;
        }
        if (isFlag(arg, mode)) continue;
        try stderr.print("error: unsupported option `{s}`\n", .{arg});
        return false;
    }
    return true;
}

fn requiresValue(arg: []const u8, mode: OptionMode) bool {
    if (equals(arg, "--project-dir") or
        equals(arg, "--profiles-dir") or
        equals(arg, "--profile") or
        equals(arg, "--target") or
        equals(arg, "--target-path") or
        equals(arg, "--vars") or
        equals(arg, "--threads"))
    {
        return true;
    }

    switch (mode) {
        .common_and_select, .list, .build => {
            if (equals(arg, "--select") or equals(arg, "--exclude")) return true;
        },
        .common_only => {},
    }

    if (mode == .list and (equals(arg, "--resource-type") or equals(arg, "--output"))) {
        return true;
    }

    return false;
}

fn isFlag(arg: []const u8, mode: OptionMode) bool {
    return mode == .build and equals(arg, "--full-refresh");
}

pub fn printRootHelp(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Usage: dxt [--version] <command> [options]
        \\
        \\Data Transformation eXecutor: a dbt-project-compatible transformation engine.
        \\
        \\Commands:
        \\  version          Print the dxt version.
        \\  parse            Planned: parse a dbt project and emit manifest artifacts.
        \\  ls               Planned: list selected project resources.
        \\  compile          Planned: compile dbt SQL/Jinja without executing.
        \\  build            Planned: run seeds, models, and tests.
        \\  docs generate    Planned: generate docs artifacts.
        \\
    );
}

fn printCommandHelp(command: []const u8, writer: *Io.Writer, mode: HelpMode) !void {
    try writer.print("Usage: dxt {s} [options]\n\n", .{command});
    try writer.print("`dxt {s}` is planned but not implemented yet.\n\n", .{command});
    try writer.writeAll("Options:\n");
    try writer.writeAll(
        \\  --project-dir <path>
        \\  --profiles-dir <path>
        \\  --profile <name>
        \\  --target <name>
        \\  --target-path <path>
        \\  --vars <yaml>
        \\
    );
    switch (mode) {
        .project_selection, .list, .build => {
            try writer.writeAll(
                \\  --select <selector>
                \\  --exclude <selector>
                \\
            );
        },
        .docs_generate => {},
    }
    switch (mode) {
        .list => {
            try writer.writeAll(
                \\  --resource-type <type>
                \\  --output <text|json>
                \\
            );
        },
        .build => {
            try writer.writeAll(
                \\  --threads <count>
                \\  --full-refresh
                \\
            );
        },
        .project_selection, .docs_generate => {},
    }
}

fn equals(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}

test "version command prints raw version" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "version" }, &stdout.writer, &stderr.writer);
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expectEqualStrings("0.0.0\n", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());
}

test "planned command accepts dbt-like flags" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "parse", "--project-dir", "fixture", "--select", "tag:nightly" }, &stdout.writer, &stderr.writer);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "planned but not implemented") != null);
    try std.testing.expectEqualStrings("", stderr.written());
}

test "subcommand help exits successfully" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "parse", "--help" }, &stdout.writer, &stderr.writer);
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "Usage: dxt parse") != null);
    try std.testing.expectEqualStrings("", stderr.written());
}

test "docs generate command is recognized" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "docs", "generate", "--target-path", "target-dxt" }, &stdout.writer, &stderr.writer);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "dxt docs generate") != null);
}
