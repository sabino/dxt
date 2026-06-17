const std = @import("std");
const Io = std.Io;
const project = @import("project.zig");

pub const version = "0.0.0";
pub const Runtime = project.Runtime;

pub const ExitCode = enum(u8) {
    ok = 0,
    usage = 2,
};

pub fn run(args: []const []const u8, stdout: *Io.Writer, stderr: *Io.Writer, runtime: ?Runtime) !ExitCode {
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

    if (equals(command, "parse")) {
        if (hasHelp(args[2..])) {
            try printCommandHelp(command, stdout, .project_selection);
            return .ok;
        }
        const rt = runtime orelse {
            try stderr.writeAll("error: runtime I/O is required for parse\n");
            return .usage;
        };
        const options = parseOptions(rt.allocator, args[2..], stderr, .common_and_select) catch |err| return commandError(err, stderr);
        project.parse(rt, options, stdout, stderr) catch |err| return commandError(err, stderr);
        return .ok;
    }
    if (equals(command, "compile")) {
        if (hasHelp(args[2..])) {
            try printCommandHelp(command, stdout, .project_selection);
            return .ok;
        }
        const rt = runtime orelse {
            try stderr.writeAll("error: runtime I/O is required for compile\n");
            return .usage;
        };
        const options = parseOptions(rt.allocator, args[2..], stderr, .compile) catch |err| return commandError(err, stderr);
        project.compile(rt, options, stdout, stderr) catch |err| return commandError(err, stderr);
        return .ok;
    }
    if (equals(command, "ls")) {
        if (hasHelp(args[2..])) {
            try printCommandHelp(command, stdout, .list);
            return .ok;
        }
        const rt = runtime orelse {
            try stderr.writeAll("error: runtime I/O is required for ls\n");
            return .usage;
        };
        const options = parseOptions(rt.allocator, args[2..], stderr, .list) catch |err| return commandError(err, stderr);
        project.list(rt, options, stdout) catch |err| return commandError(err, stderr);
        return .ok;
    }
    if (equals(command, "run")) {
        if (hasHelp(args[2..])) {
            try printCommandHelp(command, stdout, .build);
            return .ok;
        }
        const rt = runtime orelse {
            try stderr.writeAll("error: runtime I/O is required for run\n");
            return .usage;
        };
        const options = parseOptions(rt.allocator, args[2..], stderr, .build) catch |err| return commandError(err, stderr);
        project.runPreflight(rt, options, stdout, stderr) catch |err| return commandError(err, stderr);
        return .ok;
    }
    if (equals(command, "build")) {
        if (hasHelp(args[2..])) {
            try printCommandHelp(command, stdout, .build);
            return .ok;
        }
        const rt = runtime orelse {
            try stderr.writeAll("error: runtime I/O is required for build\n");
            return .usage;
        };
        const options = parseOptions(rt.allocator, args[2..], stderr, .build) catch |err| return commandError(err, stderr);
        project.buildPreflight(rt, options, stdout, stderr) catch |err| return commandError(err, stderr);
        return .ok;
    }
    if (equals(command, "docs")) {
        if (args.len >= 3 and equals(args[2], "generate")) {
            if (hasHelp(args[3..])) {
                try printCommandHelp("docs generate", stdout, .docs_generate);
                return .ok;
            }
            const rt = runtime orelse {
                try stderr.writeAll("error: runtime I/O is required for docs generate\n");
                return .usage;
            };
            const options = parseOptions(rt.allocator, args[3..], stderr, .docs_generate) catch |err| return commandError(err, stderr);
            project.docsGenerate(rt, options, stdout, stderr) catch |err| return commandError(err, stderr);
            return .ok;
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
    compile,
    docs_generate,
    list,
    build,
};

const HelpMode = enum {
    project_selection,
    list,
    build,
    docs_generate,
};

fn commandError(err: anyerror, stderr: *Io.Writer) ExitCode {
    switch (err) {
        error.MissingProjectFile => stderr.writeAll("error: missing dbt_project.yml\n") catch {},
        error.InvalidProjectName => stderr.writeAll("error: dbt_project.yml must define a non-empty name\n") catch {},
        error.DuplicateModelName => stderr.writeAll("error: duplicate model name in supported M1 parser subset\n") catch {},
        error.DuplicateSeedName => stderr.writeAll("error: duplicate seed name in supported M1 parser subset\n") catch {},
        error.DuplicateDocName => stderr.writeAll("error: duplicate docs block name in supported M1 parser subset\n") catch {},
        error.DuplicateExposureName => stderr.writeAll("error: duplicate exposure name in supported M1 parser subset\n") catch {},
        error.DuplicateMacroName => stderr.writeAll("error: duplicate macro name in supported M1 parser subset\n") catch {},
        error.DuplicateMacroProperty => stderr.writeAll("error: duplicate macro property patch in supported M1 parser subset\n") catch {},
        error.UnsupportedDynamicRef => stderr.writeAll("error: unsupported dynamic ref; M1 parser only supports literal ref calls\n") catch {},
        error.UnsupportedDynamicSource => stderr.writeAll("error: unsupported dynamic source; M1 parser only supports literal source calls\n") catch {},
        error.UnsupportedDynamicDoc => stderr.writeAll("error: unsupported dynamic doc; M1 parser only supports literal doc calls in descriptions\n") catch {},
        error.UnsupportedYaml => stderr.writeAll("error: unsupported YAML shape in M1 parser subset\n") catch {},
        error.UnsupportedJinja => stderr.writeAll("error: unsupported or malformed Jinja in M1 parser subset\n") catch {},
        error.MalformedDocsBlock => stderr.writeAll("error: malformed docs block in M1 parser subset\n") catch {},
        error.MalformedMacroBlock => stderr.writeAll("error: malformed macro block in M1 parser subset\n") catch {},
        error.DisabledRef => stderr.writeAll("error: ref targets a disabled model in the M1 parser subset\n") catch {},
        error.UnresolvedRef => stderr.writeAll("error: unresolved ref in supported M1 parser subset\n") catch {},
        error.UnresolvedSource => stderr.writeAll("error: unresolved source in supported M1 parser subset\n") catch {},
        error.UnresolvedDoc => stderr.writeAll("error: unresolved doc reference in supported M1 parser subset\n") catch {},
        error.UnresolvedMacro => stderr.writeAll("error: unresolved macro reference in supported M1 parser subset\n") catch {},
        error.UnresolvedVar => stderr.writeAll("error: unresolved var in supported M1 parser subset\n") catch {},
        error.InvalidOutput => stderr.writeAll("error: --output must be text or json\n") catch {},
        error.UnsupportedResourceType => stderr.writeAll("error: --resource-type supports only model, seed, source, exposure, or test in the M1 parser subset\n") catch {},
        error.UnsupportedSelector => stderr.writeAll("error: selector syntax is not supported by the M1 parser subset\n") catch {},
        error.UnsupportedCompileSelection => stderr.writeAll("error: compile currently supports only selected SQL model resources\n") catch {},
        error.UnsupportedRunSelection => stderr.writeAll("error: run currently supports only selected SQL model resources before execution\n") catch {},
        error.UnsupportedBuildSelection => stderr.writeAll("error: build currently supports only selected model, seed, and test resources before execution\n") catch {},
        error.UnsupportedModelExecution => stderr.writeAll("error: model execution requires a DuckDB adapter and materialization runner; not implemented yet\n") catch {},
        error.UnsupportedSeedExecution => stderr.writeAll("error: seed execution requires a DuckDB adapter and seed runner; not implemented yet\n") catch {},
        error.UnsupportedTestExecution => stderr.writeAll("error: test execution requires a DuckDB adapter and test runner; not implemented yet\n") catch {},
        error.UnsupportedCommandOption => stderr.writeAll("error: option is not supported by the implemented M1 parser command\n") catch {},
        else => stderr.print("error: {s}\n", .{@errorName(err)}) catch {},
    }
    return .usage;
}

fn hasHelp(args: []const []const u8) bool {
    for (args) |arg| {
        if (equals(arg, "-h") or equals(arg, "--help")) return true;
    }
    return false;
}

fn parseOptions(allocator: std.mem.Allocator, args: []const []const u8, stderr: *Io.Writer, mode: OptionMode) !project.Options {
    var options = project.Options{};
    var select_values: std.ArrayList([]const u8) = .empty;
    defer select_values.deinit(allocator);
    var exclude_values: std.ArrayList([]const u8) = .empty;
    defer exclude_values.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (equals(arg, "-h") or equals(arg, "--help")) return options;
        if (isSelectorOption(arg, mode)) {
            i += 1;
            var consumed = false;
            while (i < args.len and !isOptionLike(args[i])) : (i += 1) {
                try validateSelector(args[i]);
                if (equals(arg, "--select")) {
                    try select_values.append(allocator, args[i]);
                } else {
                    try exclude_values.append(allocator, args[i]);
                }
                consumed = true;
            }
            if (!consumed) {
                try stderr.print("error: option `{s}` requires a value\n", .{arg});
                return error.InvalidOption;
            }
            continue;
        }
        if (requiresValue(arg, mode)) {
            if (i + 1 >= args.len) {
                try stderr.print("error: option `{s}` requires a value\n", .{arg});
                return error.InvalidOption;
            }
            const value = args[i + 1];
            if (equals(arg, "--project-dir")) {
                options.project_dir = value;
            } else if (equals(arg, "--profiles-dir")) {
                if (mode != .compile and mode != .docs_generate and mode != .build) return error.UnsupportedCommandOption;
                options.profiles_dir = value;
            } else if (equals(arg, "--profile")) {
                if (mode != .compile and mode != .docs_generate and mode != .build) return error.UnsupportedCommandOption;
                options.profile = value;
            } else if (equals(arg, "--target")) {
                if (mode != .compile and mode != .docs_generate and mode != .build) return error.UnsupportedCommandOption;
                options.target = value;
            } else if (equals(arg, "--vars")) {
                options.vars = value;
            } else if (equals(arg, "--threads")) {
                if (mode != .compile and mode != .docs_generate and mode != .build) return error.UnsupportedCommandOption;
                options.threads = value;
            } else if (equals(arg, "--target-path")) {
                if (mode == .list) return error.UnsupportedCommandOption;
                options.target_path = value;
            } else if (equals(arg, "--resource-type")) {
                if (!equals(value, "model") and !equals(value, "seed") and !equals(value, "source") and !equals(value, "exposure") and !equals(value, "test")) return error.UnsupportedResourceType;
                options.resource_type = value;
            } else if (equals(arg, "--output")) {
                if (equals(value, "text")) {
                    options.output = .text;
                } else if (equals(value, "json")) {
                    options.output = .json;
                } else {
                    return error.InvalidOutput;
                }
            } else {
                return error.UnsupportedCommandOption;
            }
            i += 2;
            continue;
        }
        if (isFlag(arg, mode)) {
            i += 1;
            continue;
        }
        try stderr.print("error: unsupported option `{s}`\n", .{arg});
        return error.InvalidOption;
    }
    if (select_values.items.len != 0) options.select = try joinSelectorValues(allocator, select_values.items);
    if (exclude_values.items.len != 0) options.exclude = try joinSelectorValues(allocator, exclude_values.items);
    return options;
}

fn joinSelectorValues(allocator: std.mem.Allocator, values: []const []const u8) ![]const u8 {
    return try std.mem.join(allocator, " ", values);
}

fn validateSelector(value: []const u8) !void {
    if (value.len == 0) return error.UnsupportedSelector;
    var expressions = std.mem.tokenizeAny(u8, value, " \t\r\n");
    var matched_any = false;
    while (expressions.next()) |expression| {
        try validateSelectorExpression(expression);
        matched_any = true;
    }
    if (!matched_any) return error.UnsupportedSelector;
}

fn validateSelectorExpression(value: []const u8) !void {
    var terms = std.mem.splitScalar(u8, value, ',');
    var matched_any = false;
    while (terms.next()) |raw_term| {
        if (raw_term.len == 0) return error.UnsupportedSelector;
        const leading_plus = raw_term[0] == '+';
        const trailing_plus = raw_term[raw_term.len - 1] == '+';
        const start: usize = if (leading_plus) 1 else 0;
        const end: usize = if (trailing_plus) raw_term.len - 1 else raw_term.len;
        if (start >= end) return error.UnsupportedSelector;
        const part = raw_term[start..end];
        if (part.len == 0) return error.UnsupportedSelector;
        if (std.mem.indexOfAny(u8, part, " \t\r")) |_| return error.UnsupportedSelector;
        if (std.mem.indexOfScalar(u8, part, '+')) |_| return error.UnsupportedSelector;
        if (std.mem.indexOfScalar(u8, part, ':')) |_| try validateSelectorMethod(part);
        matched_any = true;
    }
    if (!matched_any) return error.UnsupportedSelector;
}

fn validateSelectorMethod(part: []const u8) !void {
    const prefixes = [_][]const u8{
        "tag:",
        "path:",
        "source:",
        "exposure:",
        "package:",
        "resource_type:",
        "test_type:",
        "config.materialized:",
    };
    inline for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, part, prefix)) {
            if (part.len == prefix.len) return error.UnsupportedSelector;
            const value = part[prefix.len..];
            if (std.mem.eql(u8, prefix, "resource_type:") and !isSupportedResourceType(value)) return error.UnsupportedSelector;
            if (std.mem.eql(u8, prefix, "test_type:") and !isSupportedTestType(value)) return error.UnsupportedSelector;
            return;
        }
    }
    return error.UnsupportedSelector;
}

fn isSupportedResourceType(value: []const u8) bool {
    return equals(value, "model") or
        equals(value, "seed") or
        equals(value, "source") or
        equals(value, "exposure") or
        equals(value, "test");
}

fn isSupportedTestType(value: []const u8) bool {
    return equals(value, "generic") or equals(value, "singular");
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
        .common_and_select, .compile, .docs_generate, .list, .build => {
            if (equals(arg, "--select") or equals(arg, "--exclude")) return true;
        },
        .common_only => {},
    }

    if (mode == .list and (equals(arg, "--resource-type") or equals(arg, "--output"))) {
        return true;
    }

    return false;
}

fn isSelectorOption(arg: []const u8, mode: OptionMode) bool {
    return mode != .common_only and (equals(arg, "--select") or equals(arg, "--exclude"));
}

fn isOptionLike(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "-");
}

fn isFlag(arg: []const u8, mode: OptionMode) bool {
    return mode == .build and equals(arg, "--full-refresh");
}

pub fn printRootHelp(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Usage: dxt [--version] <command> [options]
        \\
        \\Data eXecution & Transformation: a dbt-project-compatible transformation engine.
        \\
        \\Commands:
        \\  version          Print the dxt version.
        \\  parse            Parse a supported dbt project subset and emit manifest artifacts.
        \\  ls               List resources from the supported parser graph.
        \\  compile          Compile supported dbt SQL/Jinja without executing.
        \\  run              Preflight selected model execution without running SQL.
        \\  build            Preflight selected seeds, models, and tests without running SQL.
        \\  docs generate    Generate supported docs artifacts.
        \\
    );
}

fn printCommandHelp(command: []const u8, writer: *Io.Writer, mode: HelpMode) !void {
    try writer.print("Usage: dxt {s} [options]\n\n", .{command});
    if (equals(command, "parse") or equals(command, "ls") or equals(command, "compile") or equals(command, "run") or equals(command, "build") or equals(command, "docs generate")) {
        try writer.print("`dxt {s}` supports the M1 parser subset documented in PLAN.md.\n\n", .{command});
        try writer.writeAll("Options:\n");
        try writer.writeAll(
            \\  --project-dir <path>
            \\  --vars <yaml>
            \\
        );
        if (equals(command, "parse") or equals(command, "compile") or equals(command, "run") or equals(command, "build") or equals(command, "docs generate")) {
            try writer.writeAll(
                \\  --target-path <path>
                \\
            );
        }
        if (equals(command, "compile") or equals(command, "run") or equals(command, "build") or equals(command, "docs generate")) {
            try writer.writeAll(
                \\  --profiles-dir <path>
                \\  --profile <name>
                \\  --target <name>
                \\  --threads <count>
                \\
            );
        }
        try writer.writeAll(
            \\  --select <selector> [selector ...]
            \\  --exclude <selector> [selector ...]
            \\
        );
        if (equals(command, "ls")) {
            try writer.writeAll(
                \\  --resource-type <type>
                \\  --output <text|json>
                \\
            );
        }
        if (equals(command, "build")) {
            try writer.writeAll(
                \\  --full-refresh
                \\
            );
        }
        return;
    } else {
        try writer.print("`dxt {s}` is planned but not implemented yet.\n\n", .{command});
    }
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
        .project_selection, .list, .build, .docs_generate => {
            try writer.writeAll(
                \\  --select <selector> [selector ...]
                \\  --exclude <selector> [selector ...]
                \\
            );
        },
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
        .docs_generate => {
            try writer.writeAll(
                \\  --threads <count>
                \\
            );
        },
        .project_selection => {},
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

    const code = try run(&.{ "dxt", "version" }, &stdout.writer, &stderr.writer, null);
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expectEqualStrings("0.0.0\n", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());
}

test "compile command requires runtime I/O" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "compile", "--project-dir", "fixture", "--select", "tag:nightly" }, &stdout.writer, &stderr.writer, null);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "runtime I/O is required for compile") != null);
}

test "run command requires runtime I/O and accepts selector lists" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "run", "--project-dir", "fixture", "--select", "customers", "tag:nightly", "--exclude", "orders" }, &stdout.writer, &stderr.writer, null);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "runtime I/O is required for run") != null);
}

test "build command requires runtime I/O and accepts selector lists" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "build", "--select", "customers", "orders", "--exclude", "stg_customers", "--threads", "4", "--full-refresh" }, &stdout.writer, &stderr.writer, null);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "runtime I/O is required for build") != null);
}

test "build command help describes preflight options" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "build", "--help" }, &stdout.writer, &stderr.writer, null);
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "Usage: dxt build") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "--full-refresh") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "planned but not implemented") == null);
    try std.testing.expectEqualStrings("", stderr.written());
}

test "subcommand help exits successfully" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "parse", "--help" }, &stdout.writer, &stderr.writer, null);
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "Usage: dxt parse") != null);
    try std.testing.expectEqualStrings("", stderr.written());
}

test "docs generate command is recognized" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "docs", "generate", "--target-path", "target-dxt" }, &stdout.writer, &stderr.writer, null);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "runtime I/O is required for docs generate") != null);
}
