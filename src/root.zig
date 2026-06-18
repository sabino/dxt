const std = @import("std");
const Io = std.Io;
const project = @import("project.zig");

pub const version = "0.0.0";
pub const Runtime = project.Runtime;

pub const ExitCode = enum(u8) {
    ok = 0,
    failure = 1,
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
    if (equals(command, "clean")) {
        if (hasHelp(args[2..])) {
            try printCommandHelp(command, stdout, .clean);
            return .ok;
        }
        const rt = runtime orelse {
            try stderr.writeAll("error: runtime I/O is required for clean\n");
            return .usage;
        };
        const options = parseOptions(rt.allocator, args[2..], stderr, .clean) catch |err| return commandError(err, stderr);
        project.cleanProject(rt, options, stdout, stderr) catch |err| return commandError(err, stderr);
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
    if (equals(command, "test")) {
        if (hasHelp(args[2..])) {
            try printCommandHelp(command, stdout, .test_command);
            return .ok;
        }
        const rt = runtime orelse {
            try stderr.writeAll("error: runtime I/O is required for test\n");
            return .usage;
        };
        const options = parseOptions(rt.allocator, args[2..], stderr, .test_command) catch |err| return commandError(err, stderr);
        project.testPreflight(rt, options, stdout, stderr) catch |err| return commandError(err, stderr);
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
    if (equals(command, "source")) {
        if (args.len >= 3 and equals(args[2], "freshness")) {
            if (hasHelp(args[3..])) {
                try printCommandHelp("source freshness", stdout, .source_freshness);
                return .ok;
            }
            const rt = runtime orelse {
                try stderr.writeAll("error: runtime I/O is required for source freshness\n");
                return .usage;
            };
            const options = parseOptions(rt.allocator, args[3..], stderr, .source_freshness) catch |err| return commandError(err, stderr);
            project.sourceFreshness(rt, options, stdout, stderr) catch |err| return commandError(err, stderr);
            return .ok;
        }
        try stderr.print("error: expected `dxt source freshness`\n", .{});
        return .usage;
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
        if (args.len >= 3 and equals(args[2], "serve")) {
            if (hasHelp(args[3..])) {
                try printCommandHelp("docs serve", stdout, .docs_serve);
                return .ok;
            }
            const rt = runtime orelse {
                try stderr.writeAll("error: runtime I/O is required for docs serve\n");
                return .usage;
            };
            const options = parseOptions(rt.allocator, args[3..], stderr, .docs_serve) catch |err| return commandError(err, stderr);
            project.docsServe(rt, options, stdout, stderr) catch |err| return commandError(err, stderr);
            return .ok;
        }
        try stderr.print("error: expected `dxt docs generate` or `dxt docs serve`\n", .{});
        return .usage;
    }

    try stderr.print("error: unknown command `{s}`\n\n", .{command});
    try printRootHelp(stderr);
    return .usage;
}

const OptionMode = enum {
    common_only,
    common_and_select,
    clean,
    compile,
    docs_generate,
    docs_serve,
    list,
    test_command,
    build,
    source_freshness,
};

const HelpMode = enum {
    project_selection,
    clean,
    list,
    test_command,
    build,
    docs_generate,
    docs_serve,
    source_freshness,
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
        error.DuplicateUnitTestName => stderr.writeAll("error: duplicate unit test name for a model in supported M1 parser subset\n") catch {},
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
        error.UnresolvedUnitTestModel => stderr.writeAll("error: unit test references a missing model in supported M1 parser subset\n") catch {},
        error.UnresolvedVar => stderr.writeAll("error: unresolved var in supported M1 parser subset\n") catch {},
        error.MissingProfileFile => stderr.writeAll("error: missing profiles.yml for selected profile target\n") catch {},
        error.MissingProfileName => stderr.writeAll("error: no profile was specified for profile-aware parsing\n") catch {},
        error.MissingProfile => stderr.writeAll("error: selected profile was not found in profiles.yml\n") catch {},
        error.MissingProfileOutputs => stderr.writeAll("error: selected profile must define outputs in profiles.yml\n") catch {},
        error.MissingProfileTarget => stderr.writeAll("error: selected target was not found in profiles.yml\n") catch {},
        error.MissingProfileType => stderr.writeAll("error: selected profile target must define adapter type\n") catch {},
        error.MissingProfileSchema => stderr.writeAll("error: selected profile target must define a non-empty schema when schema is present\n") catch {},
        error.MissingProfileDatabasePath => stderr.writeAll("error: selected DuckDB profile target must define a non-empty path when path is present\n") catch {},
        error.InvalidOutput => stderr.writeAll("error: --output must be text, json, name, path, or selector\n") catch {},
        error.UnsupportedCleanPath => stderr.writeAll("error: clean-targets must contain non-empty project-relative paths\n") catch {},
        error.UnsupportedCleanOutsideProject => stderr.writeAll("error: clean refuses absolute paths or paths outside the project\n") catch {},
        error.UnsupportedCleanSourcePath => stderr.writeAll("error: clean refuses to remove model, seed, or macro source paths\n") catch {},
        error.UnsupportedResourceType => stderr.writeAll("error: --resource-type supports only model, seed, source, exposure, test, or unit_test in the M1 parser subset\n") catch {},
        error.UnsupportedSelector => stderr.writeAll("error: selector syntax is not supported by the M1 parser subset\n") catch {},
        error.UnsupportedCompileSelection => stderr.writeAll("error: compile currently supports only selected SQL model resources\n") catch {},
        error.UnsupportedRunSelection => stderr.writeAll("error: run currently supports only selected SQL model resources\n") catch {},
        error.UnsupportedTestSelection => stderr.writeAll("error: test currently supports only supported DuckDB generic test resources\n") catch {},
        error.UnsupportedBuildSelection => stderr.writeAll("error: build currently supports only selected model, seed, source, and generic test resources; unit test execution is not supported yet\n") catch {},
        error.UnsupportedMixedBuildExecution => stderr.writeAll("error: build currently executes only seed-only, model-only, seed+model, seed+model+supported-generic-test, model+supported-generic-test, source+supported-generic-test, or supported-generic-test-only selections\n") catch {},
        error.UnsupportedAdapterExecution => stderr.writeAll("error: run currently executes only DuckDB SQL models\n") catch {},
        error.UnsupportedBuildAdapterExecution => stderr.writeAll("error: build currently executes only DuckDB models, seeds, and supported generic tests\n") catch {},
        error.UnsupportedSeedAdapterExecution => stderr.writeAll("error: build currently executes only DuckDB seeds\n") catch {},
        error.UnsupportedSourceFreshnessAdapter => stderr.writeAll("error: source freshness currently supports only DuckDB sources\n") catch {},
        error.UnsupportedSourceFreshnessSelection => stderr.writeAll("error: source freshness currently supports only selected source resources\n") catch {},
        error.UnsupportedSourceFreshness => stderr.writeAll("error: source freshness currently requires loaded_at_field or loaded_at_query and complete freshness thresholds\n") catch {},
        error.UnsupportedModelMaterialization => stderr.writeAll("error: run currently supports only table and view model materializations\n") catch {},
        error.UnsupportedBuildModelMaterialization => stderr.writeAll("error: build currently supports only table and view model materializations\n") catch {},
        error.UnsupportedDuckDbPath => stderr.writeAll("error: this DuckDB execution slice supports only local DuckDB database file paths\n") catch {},
        error.CyclicModelDependency => stderr.writeAll("error: selected model graph contains a cycle\n") catch {},
        error.DuckDbCliNotFound => stderr.writeAll("error: DuckDB execution requires the duckdb CLI on PATH for this M3 slice\n") catch {},
        error.DuckDbExecutionFailed => stderr.writeAll("error: DuckDB execution failed\n") catch {},
        error.TestFailure => {
            stderr.writeAll("error: one or more generic tests failed\n") catch {};
            return .failure;
        },
        error.SourceFreshnessFailure => {
            stderr.writeAll("error: one or more source freshness checks failed\n") catch {};
            return .failure;
        },
        error.UnsupportedModelExecution => stderr.writeAll("error: model execution requires a DuckDB adapter and materialization runner; not implemented yet\n") catch {},
        error.UnsupportedSeedExecution => stderr.writeAll("error: build currently executes only root-project DuckDB seeds with default CSV settings\n") catch {},
        error.UnsupportedTestExecution => stderr.writeAll("error: test/build currently executes only selected DuckDB model/seed/source not_null/unique/accepted_values/relationships column generic tests; unit test and singular test execution are not supported yet\n") catch {},
        error.UnsupportedDocsBrowserOpen => stderr.writeAll("error: docs serve browser opening is not implemented yet; use --no-browser\n") catch {},
        error.InvalidDocsServePort => stderr.writeAll("error: --port must be an integer between 1 and 65535\n") catch {},
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
    var output_key_values: std.ArrayList([]const u8) = .empty;
    defer output_key_values.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (equals(arg, "-h") or equals(arg, "--help")) return options;
        if (equals(arg, "--output-keys")) {
            if (mode != .list) return error.UnsupportedCommandOption;
            i += 1;
            var consumed = false;
            while (i < args.len and !isOptionLike(args[i])) : (i += 1) {
                if (args[i].len == 0) return error.InvalidOption;
                try output_key_values.append(allocator, args[i]);
                consumed = true;
            }
            if (!consumed) {
                try stderr.print("error: option `{s}` requires a value\n", .{arg});
                return error.InvalidOption;
            }
            continue;
        }
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
                if (mode == .common_only) return error.UnsupportedCommandOption;
                options.profiles_dir = value;
            } else if (equals(arg, "--profile")) {
                if (mode == .common_only) return error.UnsupportedCommandOption;
                options.profile = value;
            } else if (equals(arg, "--target")) {
                if (mode == .common_only) return error.UnsupportedCommandOption;
                options.target = value;
            } else if (equals(arg, "--vars")) {
                options.vars = value;
            } else if (equals(arg, "--threads")) {
                if (mode == .common_only or mode == .clean) return error.UnsupportedCommandOption;
                options.threads = value;
            } else if (equals(arg, "--target-path")) {
                if (mode == .list) return error.UnsupportedCommandOption;
                options.target_path = value;
            } else if (equals(arg, "--host")) {
                if (mode != .docs_serve) return error.UnsupportedCommandOption;
                if (value.len == 0) return error.InvalidOption;
                options.docs_host = value;
            } else if (equals(arg, "--port")) {
                if (mode != .docs_serve) return error.UnsupportedCommandOption;
                const port = std.fmt.parseInt(u16, value, 10) catch return error.InvalidDocsServePort;
                if (port == 0) return error.InvalidDocsServePort;
                options.docs_port = port;
            } else if (equals(arg, "--resource-type")) {
                if (!equals(value, "model") and !equals(value, "seed") and !equals(value, "source") and !equals(value, "exposure") and !equals(value, "test") and !equals(value, "unit_test")) return error.UnsupportedResourceType;
                options.resource_type = value;
            } else if (equals(arg, "--output")) {
                if (equals(value, "text")) {
                    options.output = .text;
                } else if (equals(value, "json")) {
                    options.output = .json;
                } else if (equals(value, "name")) {
                    options.output = .name;
                } else if (equals(value, "path")) {
                    options.output = .path;
                } else if (equals(value, "selector")) {
                    options.output = .selector;
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
            if (equals(arg, "--browser")) {
                options.docs_open_browser = true;
            } else if (equals(arg, "--no-browser") or equals(arg, "--no-open")) {
                options.docs_open_browser = false;
            } else if (equals(arg, "--clean-project-files-only")) {
                // This is the only clean mode implemented for dxt's first safe clean slice.
            } else if (equals(arg, "--no-clean-project-files-only")) {
                return error.UnsupportedCleanOutsideProject;
            }
            i += 1;
            continue;
        }
        try stderr.print("error: unsupported option `{s}`\n", .{arg});
        return error.InvalidOption;
    }
    if (select_values.items.len != 0) options.select = try joinSelectorValues(allocator, select_values.items);
    if (exclude_values.items.len != 0) options.exclude = try joinSelectorValues(allocator, exclude_values.items);
    if (output_key_values.items.len != 0) options.output_keys = try allocator.dupe([]const u8, output_key_values.items);
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
        const part = try selectorTermValueForValidation(raw_term);
        if (part.len == 0) return error.UnsupportedSelector;
        if (std.mem.indexOfAny(u8, part, " \t\r")) |_| return error.UnsupportedSelector;
        if (std.mem.indexOfScalar(u8, part, '+')) |_| return error.UnsupportedSelector;
        if (std.mem.indexOfScalar(u8, part, '@')) |_| return error.UnsupportedSelector;
        if (std.mem.indexOfScalar(u8, part, ':')) |_| try validateSelectorMethod(part);
        matched_any = true;
    }
    if (!matched_any) return error.UnsupportedSelector;
}

fn selectorTermValueForValidation(raw_term: []const u8) ![]const u8 {
    var start: usize = 0;
    var end: usize = raw_term.len;
    var has_childrens_parents = false;

    if (start < end and raw_term[start] == '@') {
        has_childrens_parents = true;
        start += 1;
    }

    if (has_childrens_parents and std.mem.indexOfScalar(u8, raw_term[start..], '+') != null) return error.UnsupportedSelector;

    if (start < end) {
        if (raw_term[start] == '+') {
            start += 1;
        } else {
            var digit_end = start;
            while (digit_end < end and isSelectorDigit(raw_term[digit_end])) digit_end += 1;
            if (digit_end > start and digit_end < end and raw_term[digit_end] == '+') {
                _ = std.fmt.parseInt(usize, raw_term[start..digit_end], 10) catch return error.UnsupportedSelector;
                start = digit_end + 1;
            }
        }
    }
    if (start >= end or raw_term[start] == '+' or raw_term[start] == '@') return error.UnsupportedSelector;

    if (raw_term[end - 1] == '+') {
        end -= 1;
    } else {
        var digit_start = end;
        while (digit_start > start and isSelectorDigit(raw_term[digit_start - 1])) digit_start -= 1;
        if (digit_start < end and digit_start > start and raw_term[digit_start - 1] == '+') {
            _ = std.fmt.parseInt(usize, raw_term[digit_start..end], 10) catch return error.UnsupportedSelector;
            end = digit_start - 1;
        }
    }
    if (start >= end or raw_term[end - 1] == '+') return error.UnsupportedSelector;
    return raw_term[start..end];
}

fn isSelectorDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn validateSelectorMethod(part: []const u8) !void {
    const prefixes = [_][]const u8{
        "tag:",
        "path:",
        "file:",
        "source:",
        "exposure:",
        "unit_test:",
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
        equals(value, "test") or
        equals(value, "unit_test");
}

fn isSupportedTestType(value: []const u8) bool {
    return equals(value, "generic") or equals(value, "singular") or equals(value, "unit");
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
        .common_and_select, .compile, .docs_generate, .list, .test_command, .build, .source_freshness => {
            if (equals(arg, "--select") or equals(arg, "--exclude")) return true;
        },
        .common_only, .clean, .docs_serve => {},
    }

    if (mode == .list and (equals(arg, "--resource-type") or equals(arg, "--output"))) {
        return true;
    }
    if (mode == .docs_serve and (equals(arg, "--host") or equals(arg, "--port"))) {
        return true;
    }

    return false;
}

fn isSelectorOption(arg: []const u8, mode: OptionMode) bool {
    return mode != .common_only and mode != .clean and mode != .docs_serve and (equals(arg, "--select") or equals(arg, "--exclude"));
}

fn isOptionLike(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "-");
}

fn isFlag(arg: []const u8, mode: OptionMode) bool {
    if (mode == .build and equals(arg, "--full-refresh")) return true;
    if (mode == .docs_serve and (equals(arg, "--browser") or equals(arg, "--no-browser") or equals(arg, "--no-open"))) return true;
    if (mode == .clean and (equals(arg, "--clean-project-files-only") or equals(arg, "--no-clean-project-files-only"))) return true;
    return false;
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
        \\  clean            Delete configured generated project artifacts.
        \\  compile          Compile supported dbt SQL/Jinja without executing.
        \\  run              Execute supported selected DuckDB SQL models.
        \\  test             Execute supported selected DuckDB generic tests.
        \\  build            Execute supported selected DuckDB seeds, models, and tests.
        \\  source freshness Check freshness for supported DuckDB sources.
        \\  docs generate    Generate supported docs artifacts.
        \\  docs serve       Serve generated docs artifacts from the target directory.
        \\
    );
}

fn printCommandHelp(command: []const u8, writer: *Io.Writer, mode: HelpMode) !void {
    try writer.print("Usage: dxt {s} [options]\n\n", .{command});
    if (equals(command, "parse") or equals(command, "ls") or equals(command, "clean") or equals(command, "compile") or equals(command, "run") or equals(command, "test") or equals(command, "build") or equals(command, "docs generate") or equals(command, "docs serve") or equals(command, "source freshness")) {
        if (equals(command, "docs serve")) {
            try writer.writeAll("`dxt docs serve` serves generated docs artifacts from the target directory.\n\n");
        } else if (equals(command, "clean")) {
            try writer.writeAll("`dxt clean` removes configured generated project artifact directories.\n\n");
        } else {
            try writer.print("`dxt {s}` supports the M1 parser subset documented in PLAN.md.\n\n", .{command});
        }
        try writer.writeAll("Options:\n");
        try writer.writeAll(
            \\  --project-dir <path>
            \\  --vars <yaml>
            \\
        );
        if (equals(command, "parse") or equals(command, "clean") or equals(command, "compile") or equals(command, "run") or equals(command, "test") or equals(command, "build") or equals(command, "docs generate") or equals(command, "docs serve") or equals(command, "source freshness")) {
            try writer.writeAll(
                \\  --target-path <path>
                \\
            );
        }
        if (equals(command, "parse") or equals(command, "ls") or equals(command, "clean") or equals(command, "compile") or equals(command, "run") or equals(command, "test") or equals(command, "build") or equals(command, "docs generate") or equals(command, "docs serve") or equals(command, "source freshness")) {
            try writer.writeAll(
                \\  --profiles-dir <path>
                \\
            );
            if (!equals(command, "clean")) {
                try writer.writeAll(
                    \\  --profile <name>
                    \\  --target <name>
                    \\  --threads <count>
                    \\
                );
            } else {
                try writer.writeAll(
                    \\  --profile <name>
                    \\  --target <name>
                    \\
                );
            }
        }
        if (!equals(command, "docs serve") and !equals(command, "clean")) {
            try writer.writeAll(
                \\  --select <selector> [selector ...]
                \\  --exclude <selector> [selector ...]
                \\
            );
        }
        if (equals(command, "ls")) {
            try writer.writeAll(
                \\  --resource-type <type>
                \\  --output <text|json|name|path|selector>
                \\  --output-keys <keys...>
                \\
            );
        }
        if (equals(command, "build")) {
            try writer.writeAll(
                \\  --full-refresh
                \\
            );
        }
        if (equals(command, "clean")) {
            try writer.writeAll(
                \\  --clean-project-files-only
                \\
            );
        }
        if (equals(command, "docs serve")) {
            try writer.writeAll(
                \\  --host <host>
                \\  --port <port>
                \\  --no-browser
                \\  --browser
                \\  --no-open
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
        .project_selection, .list, .test_command, .build, .docs_generate, .source_freshness => {
            try writer.writeAll(
                \\  --select <selector> [selector ...]
                \\  --exclude <selector> [selector ...]
                \\
            );
        },
        .clean, .docs_serve => {},
    }
    switch (mode) {
        .list => {
            try writer.writeAll(
                \\  --resource-type <type>
                \\  --output <text|json|name|path|selector>
                \\  --output-keys <keys...>
                \\
            );
        },
        .clean => {
            try writer.writeAll(
                \\  --clean-project-files-only
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
        .test_command => {
            try writer.writeAll(
                \\  --threads <count>
                \\
            );
        },
        .docs_generate => {
            try writer.writeAll(
                \\  --threads <count>
                \\
            );
        },
        .docs_serve => {
            try writer.writeAll(
                \\  --host <host>
                \\  --port <port>
                \\  --no-browser
                \\  --browser
                \\  --no-open
                \\
            );
        },
        .source_freshness => {
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

test "test command requires runtime I/O and accepts selectors" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "test", "--project-dir", "fixture", "--select", "customers", "--exclude", "tag:slow" }, &stdout.writer, &stderr.writer, null);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "runtime I/O is required for test") != null);
}

test "test command rejects build-only full refresh flag" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const runtime = Runtime{ .allocator = std.testing.allocator, .io = undefined };
    const code = try run(&.{ "dxt", "test", "--project-dir", "fixture", "--full-refresh" }, &stdout.writer, &stderr.writer, runtime);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "unsupported option `--full-refresh`") != null);
}

test "test command help describes generic test options" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "test", "--help" }, &stdout.writer, &stderr.writer, null);
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "Usage: dxt test") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "--select <selector>") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "--full-refresh") == null);
    try std.testing.expectEqualStrings("", stderr.written());
}

test "clean command requires runtime I/O and accepts clean flags" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "clean", "--project-dir", "fixture", "--target-path", "target-dxt", "--profiles-dir", "profiles", "--profile", "default", "--target", "dev", "--clean-project-files-only" }, &stdout.writer, &stderr.writer, null);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "runtime I/O is required for clean") != null);
}

test "clean command help describes safe clean options" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "clean", "--help" }, &stdout.writer, &stderr.writer, null);
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "Usage: dxt clean") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "--clean-project-files-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "--profile <name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "--target <name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "--select") == null);
    try std.testing.expectEqualStrings("", stderr.written());
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

test "docs serve command is recognized" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "docs", "serve", "--target-path", "target-dxt", "--host", "127.0.0.1", "--port", "8081", "--no-browser" }, &stdout.writer, &stderr.writer, null);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "runtime I/O is required for docs serve") != null);
}

test "docs serve command help describes serve options" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "docs", "serve", "--help" }, &stdout.writer, &stderr.writer, null);
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "Usage: dxt docs serve") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "--host <host>") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "--port <port>") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "--no-browser") != null);
    try std.testing.expectEqualStrings("", stderr.written());
}

test "source freshness command is recognized" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "source", "freshness", "--target-path", "target-dxt", "--select", "source:raw.orders" }, &stdout.writer, &stderr.writer, null);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "runtime I/O is required for source freshness") != null);
}

test "list command parses repeated output keys with selector lists" {
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const options = try parseOptions(
        std.testing.allocator,
        &.{ "--select", "orders", "tag:nightly", "--output", "json", "--output-keys", "name", "resource_type", "--output-keys", "unique_id" },
        &stderr.writer,
        .list,
    );
    defer {
        if (options.select) |value| std.testing.allocator.free(value);
        if (options.output_keys) |values| std.testing.allocator.free(values);
    }

    try std.testing.expectEqual(project.Output.json, options.output);
    try std.testing.expectEqualStrings("orders tag:nightly", options.select.?);
    try std.testing.expectEqual(@as(usize, 3), options.output_keys.?.len);
    try std.testing.expectEqualStrings("name", options.output_keys.?[0]);
    try std.testing.expectEqualStrings("resource_type", options.output_keys.?[1]);
    try std.testing.expectEqualStrings("unique_id", options.output_keys.?[2]);
    try std.testing.expectEqualStrings("", stderr.written());
}

test "docs serve parses host port and browser flags" {
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const options = try parseOptions(
        std.testing.allocator,
        &.{ "--target-path", "target-dxt", "--host", "127.0.0.1", "--port", "8082", "--browser", "--no-browser", "--no-open" },
        &stderr.writer,
        .docs_serve,
    );

    try std.testing.expectEqualStrings("target-dxt", options.target_path.?);
    try std.testing.expectEqualStrings("127.0.0.1", options.docs_host);
    try std.testing.expectEqual(@as(u16, 8082), options.docs_port);
    try std.testing.expect(!options.docs_open_browser);
    try std.testing.expectEqualStrings("", stderr.written());
}

test "docs serve rejects invalid port" {
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const result = parseOptions(std.testing.allocator, &.{ "--port", "0" }, &stderr.writer, .docs_serve);

    try std.testing.expectError(error.InvalidDocsServePort, result);
}

test "list command requires output keys value" {
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const result = parseOptions(std.testing.allocator, &.{"--output-keys"}, &stderr.writer, .list);

    try std.testing.expectError(error.InvalidOption, result);
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "option `--output-keys` requires a value") != null);
}
