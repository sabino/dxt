const std = @import("std");
pub const DuckDBPool = @import("project/native_duckdb.zig").Pool;
const Io = std.Io;
const project = @import("project.zig");
const dependencies = @import("project/dependencies.zig");
pub const yaml = @import("project/yaml.zig");

test "shared native YAML reader is available" {
    _ = yaml;
}

pub const Invocation = @import("project/invocation.zig").Metadata;
pub const version = @import("project/invocation.zig").version;
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

    if (equals(command, "deps")) {
        if (hasHelp(args[2..])) {
            try dependencies.printHelp(stdout);
            return .ok;
        }
        const rt = runtime orelse {
            try stderr.writeAll("error: runtime I/O is required for deps\n");
            return .usage;
        };
        const options = dependencies.parseOptions(args[2..], stderr) catch |err| return commandError(err, stderr);
        dependencies.install(rt, options, stdout, stderr) catch |err| return commandError(err, stderr);
        return .ok;
    }

    if (equals(command, "snapshot")) {
        if (hasHelp(args[2..])) {
            try printCommandHelp(command, stdout, .build);
            return .ok;
        }
        const rt = runtime orelse return .usage;
        const options = parseOptions(rt.allocator, args[2..], stderr, .build) catch |err| return commandError(err, stderr);
        project.snapshotRun(rt, options, stdout, stderr) catch |err| return commandError(err, stderr);
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
    if (equals(command, "seed")) {
        if (hasHelp(args[2..])) {
            try printCommandHelp(command, stdout, .seed);
            return .ok;
        }
        const rt = runtime orelse {
            try stderr.writeAll("error: runtime I/O is required for seed\n");
            return .usage;
        };
        const options = parseOptions(rt.allocator, args[2..], stderr, .seed) catch |err| return commandError(err, stderr);
        project.seedPreflight(rt, options, stdout, stderr) catch |err| return commandError(err, stderr);
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
    seed,
    test_command,
    build,
    source_freshness,
};

const HelpMode = enum {
    project_selection,
    clean,
    list,
    seed,
    test_command,
    build,
    docs_generate,
    docs_serve,
    source_freshness,
};

fn commandError(err: anyerror, stderr: *Io.Writer) ExitCode {
    switch (err) {
        error.InvalidPackageDeclaration => stderr.writeAll("error: invalid package declaration; use local, git/revision, or package/version entries\n") catch {},
        error.MultiplePackageDeclarations => stderr.writeAll("error: declare dependencies in either packages.yml or dependencies.yml, not both\n") catch {},
        error.UnsupportedProjectDependency => stderr.writeAll("error: project dependencies require a remote service; use local, Git, or Hub packages\n") catch {},
        error.PackageVersionConflict => stderr.writeAll("error: package version constraints conflict or no compatible version exists\n") catch {},
        error.PackageDependencyCycle => stderr.writeAll("error: package dependency graph contains a cycle\n") catch {},
        error.DuplicatePackageName => stderr.writeAll("error: dependencies contain duplicate project names or depend on the root project\n") catch {},
        error.PackageResolutionLimit => stderr.writeAll("error: package resolution exceeded the dependency graph limit\n") catch {},
        error.MissingLocalPackage => stderr.writeAll("error: local package directory does not exist\n") catch {},
        error.InvalidLocalPackage => stderr.writeAll("error: local package source overlaps the project or generated dependency directories\n") catch {},
        error.InvalidPackageProject => stderr.writeAll("error: package must contain dbt_project.yml with a valid matching project name\n") catch {},
        error.InvalidPackagesInstallPath => stderr.writeAll("error: packages-install-path must be a safe project-relative generated directory\n") catch {},
        error.InvalidPackageSubdirectory => stderr.writeAll("error: package subdirectory must be a safe relative path\n") catch {},
        error.InvalidPackageVersion => stderr.writeAll("error: invalid semantic package version or constraint\n") catch {},
        error.InvalidPackageRevision => stderr.writeAll("error: Git package revision does not resolve to a commit\n") catch {},
        error.InvalidPackageLock => stderr.writeAll("error: package-lock.yml is malformed\n") catch {},
        error.InvalidPackageRegistry => stderr.writeAll("error: invalid package Hub metadata or download URL\n") catch {},
        error.InvalidPackageArchive => stderr.writeAll("error: package archive must contain a dbt project\n") catch {},
        error.UnsafePackageArchive => stderr.writeAll("error: package archive contains unsafe paths, links, or special files\n") catch {},
        error.PackageOfflineCacheMiss => stderr.writeAll("error: offline package cache is incomplete; run deps online first\n") catch {},
        error.PackageOfflineUpgrade => stderr.writeAll("error: deps --offline cannot be combined with --upgrade\n") catch {},
        error.PackageNetworkFailed => stderr.writeAll("error: package download failed; check registry availability and network access\n") catch {},
        error.GitPackageFailed => stderr.writeAll("error: Git package transport failed; check repository access\n") catch {},
        error.PackageInstallFailed => stderr.writeAll("error: package installation failed; existing installed packages were preserved\n") catch {},
        error.PackageTransportNotFound => stderr.writeAll("error: deps requires git, curl, tar, and cp transport tools\n") catch {},
        error.UnsupportedPackageJinja => stderr.writeAll("error: package declarations support literal values and env_var calls only\n") catch {},
        error.MissingPackageEnvironmentVariable => stderr.writeAll("error: required package environment variable is missing\n") catch {},
        error.MissingProjectFile => stderr.writeAll("error: missing dbt_project.yml\n") catch {},
        error.InvalidProjectName => stderr.writeAll("error: dbt_project.yml must define a non-empty name\n") catch {},
        error.DuplicateModelName => stderr.writeAll("error: duplicate model name in supported M1 parser subset\n") catch {},
        error.DuplicateAnalysisName => stderr.writeAll("error: duplicate analysis name in supported M1 parser subset\n") catch {},
        error.UnsupportedSnapshotRefCollision => stderr.writeAll("error: ref to a snapshot sharing a name with a model or seed is not supported\n") catch {},
        error.DuplicateSnapshotName => stderr.writeAll("error: duplicate snapshot block name in a package\n") catch {},
        error.MalformedSnapshotBlock => stderr.writeAll("error: malformed SQL snapshot block\n") catch {},
        error.InvalidSnapshotConfig => stderr.writeAll("error: SQL snapshot requires a unique_key and a valid timestamp or check strategy configuration\n") catch {},
        error.UnsupportedProjectSnapshotConfig => stderr.writeAll("error: project snapshot config inheritance is not supported; use literal SQL snapshot config calls\n") catch {},
        error.UnsupportedSnapshotConfig => stderr.writeAll("error: unsupported SQL snapshot config; only the documented literal config subset is supported\n") catch {},
        error.UnsupportedSnapshotDefinition => stderr.writeAll("error: SQL snapshots support only named blocks with literal config, ref, and source calls\n") catch {},
        error.UnsupportedSnapshotYaml => stderr.writeAll("error: YAML snapshot definitions and properties are not supported; use literal SQL snapshot blocks\n") catch {},
        error.UnsupportedSnapshotAdapter => stderr.writeAll("error: snapshot execution requires a DuckDB adapter\n") catch {},
        error.UnsupportedSnapshotExecution => stderr.writeAll("error: snapshot resources currently support parse and ls only; snapshot compilation and execution are not supported\n") catch {},
        error.DuplicateSeedName => stderr.writeAll("error: duplicate seed name in supported M1 parser subset\n") catch {},
        error.DuplicateDocName => stderr.writeAll("error: duplicate docs block name in supported M1 parser subset\n") catch {},
        error.DuplicateExposureName => stderr.writeAll("error: duplicate exposure name in supported M1 parser subset\n") catch {},
        error.DuplicateMacroName => stderr.writeAll("error: duplicate macro name in supported M1 parser subset\n") catch {},
        error.DuplicateMacroProperty => stderr.writeAll("error: duplicate macro property patch in supported M1 parser subset\n") catch {},
        error.DuplicateUnitTestName => stderr.writeAll("error: duplicate unit test name for a model in supported M1 parser subset\n") catch {},
        error.DuplicateSingularTestName => stderr.writeAll("error: duplicate singular SQL test name in supported M1 parser subset\n") catch {},
        error.UnsupportedDynamicRef => stderr.writeAll("error: unsupported dynamic ref; M1 parser only supports literal ref calls\n") catch {},
        error.UnsupportedDynamicSource => stderr.writeAll("error: unsupported dynamic source; M1 parser only supports literal source calls\n") catch {},
        error.UnsupportedDynamicDoc => stderr.writeAll("error: unsupported dynamic doc; M1 parser only supports literal doc calls in descriptions\n") catch {},
        error.UnsupportedYaml => stderr.writeAll("error: unsupported YAML shape in M1 parser subset\n") catch {},
        error.UnsupportedJinja => stderr.writeAll("error: unsupported or malformed Jinja in M1 parser subset\n") catch {},
        error.MalformedDocsBlock => stderr.writeAll("error: malformed docs block in M1 parser subset\n") catch {},
        error.MalformedMacroBlock => stderr.writeAll("error: malformed macro block in M1 parser subset\n") catch {},
        error.DisabledRef => stderr.writeAll("error: ref targets a disabled model, seed, or snapshot in the M1 parser subset\n") catch {},
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
        error.UnsupportedResourceType => stderr.writeAll("error: --resource-type supports only model, analysis, snapshot, seed, source, exposure, test, or unit_test in the M1 parser subset\n") catch {},
        error.UnsupportedSelector => stderr.writeAll("error: selector syntax is not supported by the M1 parser subset\n") catch {},
        error.MissingSourceStatusState => stderr.writeAll("error: source_status selectors require --state pointing to a directory containing sources.json\n") catch {},
        error.MissingSourcesArtifact => stderr.writeAll("error: --state must point to a directory containing sources.json for source_status selectors\n") catch {},
        error.MalformedSourcesArtifact => stderr.writeAll("error: sources.json is malformed or missing required freshness result fields\n") catch {},
        error.UnsupportedSourcesSchemaVersion => stderr.writeAll("error: sources.json must use dbt Sources v3 schema for source_status selectors\n") catch {},
        error.MissingResultState => stderr.writeAll("error: result selectors require --state pointing to a directory containing run_results.json\n") catch {},
        error.MissingRunResultsArtifact => stderr.writeAll("error: --state must point to a directory containing run_results.json for result selectors\n") catch {},
        error.MalformedRunResultsArtifact => stderr.writeAll("error: run_results.json is malformed or missing required result fields\n") catch {},
        error.UnsupportedRunResultsSchemaVersion => stderr.writeAll("error: run_results.json must use dbt Run Results v6 schema for result selectors\n") catch {},
        error.MissingCurrentSourcesArtifact => stderr.writeAll("error: source_status:fresher requires current target sources.json\n") catch {},
        error.MissingDeferState => stderr.writeAll("error: --defer requires --state or --defer-state containing manifest.json\n") catch {},
        error.MalformedDeferRelation => stderr.writeAll("error: deferral manifest resource requires schema and alias relation fields\n") catch {},
        error.DeferRelationLookupFailed => stderr.writeAll("error: could not inspect the current target relation for deferral\n") catch {},
        error.UnsupportedDeferAdapter => stderr.writeAll("error: deferral relation lookup requires the DuckDB adapter\n") catch {},
        error.UnsupportedIndirectSelection => stderr.writeAll("error: --indirect-selection must be eager, cautious, buildable, or empty\n") catch {},
        error.MissingStateManifestState => stderr.writeAll("error: state selectors require --state pointing to a directory containing manifest.json\n") catch {},
        error.MissingStateManifestArtifact => stderr.writeAll("error: --state must point to a directory containing manifest.json for state selectors\n") catch {},
        error.MalformedStateManifestArtifact => stderr.writeAll("error: manifest.json is malformed or missing required state fields\n") catch {},
        error.UnsupportedStateManifestSchemaVersion => stderr.writeAll("error: manifest.json must use dbt Manifest v12 schema for state selectors\n") catch {},
        error.UnsupportedCompileSelection => stderr.writeAll("error: compile currently supports only selected SQL model or supported generic or singular SQL test resources\n") catch {},
        error.UnsupportedCustomGenericTest => stderr.writeAll("error: custom generic test compilation currently supports only model, seed, or source column test blocks with static SQL plus {{ model }} and {{ column_name }}\n") catch {},
        error.UnsupportedRunSelection => stderr.writeAll("error: run currently supports only selected SQL model resources\n") catch {},
        error.UnsupportedSeedSelection => stderr.writeAll("error: seed currently supports only selected seed resources\n") catch {},
        error.UnsupportedTestSelection => stderr.writeAll("error: test currently supports only supported DuckDB test resources\n") catch {},
        error.UnsupportedBuildSelection => stderr.writeAll("error: build currently supports only selected model, seed, source, test, and supported unit test resources\n") catch {},
        error.UnsupportedMixedBuildExecution => stderr.writeAll("error: build currently executes only seed-only, model-only, seed+model, seed+model+supported-test, model+supported-test, source+supported-test, or supported-test-only selections\n") catch {},
        error.UnsupportedAdapterExecution => stderr.writeAll("error: run currently executes only DuckDB SQL models\n") catch {},
        error.UnsupportedBuildAdapterExecution => stderr.writeAll("error: build currently executes only DuckDB models, seeds, and supported tests\n") catch {},
        error.UnsupportedSeedAdapterExecution => stderr.writeAll("error: seed/build currently executes only DuckDB seeds\n") catch {},
        error.UnsupportedSourceFreshnessAdapter => stderr.writeAll("error: source freshness currently supports only DuckDB sources\n") catch {},
        error.UnsupportedSourceFreshnessSelection => stderr.writeAll("error: source freshness currently supports only selected source resources\n") catch {},
        error.UnsupportedSourceFreshness => stderr.writeAll("error: source freshness currently requires loaded_at_field or loaded_at_query and complete freshness thresholds\n") catch {},
        error.UnsupportedModelMaterialization => stderr.writeAll("error: unsupported model materialization; DuckDB supports table, view, and incremental\n") catch {},
        error.UnsupportedIncrementalStrategy => stderr.writeAll("error: dbt-duckdb incremental strategies supported: append, delete+insert, default\n") catch {},
        error.UnsupportedBuildModelMaterialization => stderr.writeAll("error: unsupported build model materialization; DuckDB supports table, view, and incremental\n") catch {},
        error.UnsupportedDuckDbPath => stderr.writeAll("error: this DuckDB execution slice supports only local DuckDB database file paths\n") catch {},
        error.CyclicModelDependency => stderr.writeAll("error: selected model graph contains a cycle\n") catch {},
        error.DuckDbCliNotFound => stderr.writeAll("error: DuckDB execution requires libduckdb or the duckdb CLI on PATH\n") catch {},
        error.NativeDuckDbLibraryNotFound => stderr.writeAll("error: native DuckDB library unavailable; set DXT_DUCKDB_LIBRARY to a compatible libduckdb library or use DXT_DUCKDB_BACKEND=cli\n") catch {},
        error.NativeDuckDbAbiMismatch => stderr.writeAll("error: native DuckDB library does not provide the required C API\n") catch {},
        error.NativeDuckDbConnectionFailed => stderr.writeAll("error: native DuckDB connection failed\n") catch {},
        error.NativeDuckDbReadOnlyConnection => stderr.writeAll("error: DuckDB connection permits read-only queries\n") catch {},
        error.InvalidDuckDbBackend => stderr.writeAll("error: DXT_DUCKDB_BACKEND must be auto, native, or cli\n") catch {},
        error.NativePostgresLibraryNotFound => stderr.writeAll("error: native PostgreSQL library unavailable; install libpq or set DXT_POSTGRES_LIBRARY\n") catch {},
        error.NativePostgresAbiMismatch => stderr.writeAll("error: native PostgreSQL library does not provide the required libpq API\n") catch {},
        error.PostgresConnectionFailed => stderr.writeAll("error: PostgreSQL connection failed\n") catch {},
        error.PostgresExecutionFailed => stderr.writeAll("error: PostgreSQL query failed\n") catch {},
        error.AdapterQueryCancelled => stderr.writeAll("error: database query cancelled\n") catch {},
        error.DuckDbExecutionFailed => stderr.writeAll("error: DuckDB execution failed\n") catch {},
        error.ExecutionFailure => {
            stderr.writeAll("error: one or more selected resources failed\n") catch {};
            return .failure;
        },
        error.TestFailure => {
            stderr.writeAll("error: one or more tests failed\n") catch {};
            return .failure;
        },
        error.SourceFreshnessFailure => {
            stderr.writeAll("error: one or more source freshness checks failed\n") catch {};
            return .failure;
        },
        error.UnsupportedModelExecution => stderr.writeAll("error: model execution requires a DuckDB adapter and materialization runner; not implemented yet\n") catch {},
        error.UnsupportedSeedExecution => stderr.writeAll("error: seed/build currently executes only DuckDB CSV seeds with supported quote_columns and column_types settings\n") catch {},
        error.UnsupportedTestExecution => stderr.writeAll("error: test/build currently executes only selected DuckDB singular SQL tests, supported custom generic column tests, and model/seed/source not_null/unique/accepted_values/relationships column tests\n") catch {},
        error.UnsupportedUnitTestExecution => stderr.writeAll("error: unit test execution currently supports only dict row fixtures for literal ref/source inputs and expected rows\n") catch {},
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
    var selector_values: std.ArrayList([]const u8) = .empty;
    defer selector_values.deinit(allocator);
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
                if (equals(arg, "--select")) {
                    try validateSelector(args[i]);
                    try select_values.append(allocator, args[i]);
                } else if (equals(arg, "--selector")) {
                    if (args[i].len == 0) return error.UnsupportedSelector;
                    try selector_values.append(allocator, args[i]);
                } else {
                    try validateSelector(args[i]);
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
            } else if (equals(arg, "--state")) {
                if (mode == .common_only or mode == .clean or mode == .docs_serve) return error.UnsupportedCommandOption;
                options.state = value;
            } else if (equals(arg, "--defer-state")) {
                if (mode == .common_only or mode == .clean or mode == .docs_serve) return error.UnsupportedCommandOption;
                options.defer_state = value;
            } else if (equals(arg, "--indirect-selection")) {
                if (mode == .common_only or mode == .clean or mode == .docs_serve) return error.UnsupportedCommandOption;
                if (!equals(value, "eager") and !equals(value, "cautious") and !equals(value, "buildable") and !equals(value, "empty")) return error.UnsupportedIndirectSelection;
                options.indirect_selection = value;
            } else if (equals(arg, "--threads")) {
                if (mode == .common_only or mode == .clean) return error.UnsupportedCommandOption;
                options.threads = value;
            } else if (equals(arg, "--target-path")) {
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
                if (!equals(value, "model") and !equals(value, "analysis") and !equals(value, "snapshot") and !equals(value, "seed") and !equals(value, "source") and !equals(value, "exposure") and !equals(value, "test") and !equals(value, "unit_test")) return error.UnsupportedResourceType;
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
            if (equals(arg, "--full-refresh")) {
                options.full_refresh = true;
            } else if (equals(arg, "--defer") or equals(arg, "--no-defer")) {
                options.defer_enabled = equals(arg, "--defer");
            } else if (equals(arg, "--favor-state") or equals(arg, "--no-favor-state")) {
                options.favor_state = equals(arg, "--favor-state");
            } else if (equals(arg, "--browser")) {
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
    if (selector_values.items.len != 0) options.selector = try joinSelectorValues(allocator, selector_values.items);
    if (exclude_values.items.len != 0) options.exclude = try joinSelectorValues(allocator, exclude_values.items);
    if (output_key_values.items.len != 0) options.output_keys = try allocator.dupe([]const u8, output_key_values.items);
    return options;
}

fn joinSelectorValues(allocator: std.mem.Allocator, values: []const []const u8) ![]const u8 {
    return try std.mem.join(allocator, " ", values);
}

fn validateSelector(value: []const u8) !void {
    try project.validateSelectorSyntax(value);
}

fn requiresValue(arg: []const u8, mode: OptionMode) bool {
    if (equals(arg, "--project-dir") or
        equals(arg, "--profiles-dir") or
        equals(arg, "--profile") or
        equals(arg, "--target") or
        equals(arg, "--target-path") or
        equals(arg, "--vars") or
        equals(arg, "--state") or equals(arg, "--defer-state") or equals(arg, "--indirect-selection") or
        equals(arg, "--threads"))
    {
        return true;
    }

    switch (mode) {
        .common_and_select, .compile, .docs_generate, .list, .seed, .test_command, .build, .source_freshness => {
            if (equals(arg, "--select") or equals(arg, "--selector") or equals(arg, "--exclude")) return true;
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
    return mode != .common_only and mode != .clean and mode != .docs_serve and (equals(arg, "--select") or equals(arg, "--selector") or equals(arg, "--exclude"));
}

fn isOptionLike(arg: []const u8) bool {
    return std.mem.startsWith(u8, arg, "-");
}

fn isFlag(arg: []const u8, mode: OptionMode) bool {
    if (mode != .common_only and mode != .clean and mode != .docs_serve and (equals(arg, "--defer") or equals(arg, "--no-defer") or equals(arg, "--favor-state") or equals(arg, "--no-favor-state"))) return true;
    if ((mode == .build or mode == .compile) and equals(arg, "--full-refresh")) return true;
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
        \\  deps             Resolve and install local, Git, and Hub package dependencies.
        \\  compile          Compile supported dbt SQL/Jinja without executing.
        \\  run              Execute supported selected DuckDB SQL models.
        \\  snapshot         Maintain selected DuckDB timestamp and check snapshots.
        \\  seed             Load supported selected DuckDB CSV seeds.
        \\  test             Execute supported selected DuckDB tests.
        \\  build            Execute supported selected DuckDB seeds, models, and tests.
        \\  source freshness Check freshness for supported DuckDB sources.
        \\  docs generate    Generate supported docs artifacts.
        \\  docs serve       Serve generated docs artifacts from the target directory.
        \\
    );
}

fn printCommandHelp(command: []const u8, writer: *Io.Writer, mode: HelpMode) !void {
    try writer.print("Usage: dxt {s} [options]\n\n", .{command});
    if (equals(command, "parse") or equals(command, "ls") or equals(command, "clean") or equals(command, "compile") or equals(command, "run") or equals(command, "seed") or equals(command, "snapshot") or equals(command, "test") or equals(command, "build") or equals(command, "docs generate") or equals(command, "docs serve") or equals(command, "source freshness")) {
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
            \\  --vars <yaml-or-json>
            \\
        );
        if (equals(command, "parse") or equals(command, "clean") or equals(command, "compile") or equals(command, "run") or equals(command, "seed") or equals(command, "snapshot") or equals(command, "test") or equals(command, "build") or equals(command, "docs generate") or equals(command, "docs serve") or equals(command, "source freshness")) {
            try writer.writeAll(
                \\  --target-path <path>
                \\
            );
        }
        if (equals(command, "parse") or equals(command, "ls") or equals(command, "clean") or equals(command, "compile") or equals(command, "run") or equals(command, "seed") or equals(command, "snapshot") or equals(command, "test") or equals(command, "build") or equals(command, "docs generate") or equals(command, "docs serve") or equals(command, "source freshness")) {
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
                \\  --selector <name> [name ...]
                \\  --exclude <selector> [selector ...]
                \\  --state <path>
                \\  --defer, --no-defer
                \\  --defer-state <path>
                \\  --favor-state, --no-favor-state
                \\  --indirect-selection <eager|cautious|buildable|empty>
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
        \\  --vars <yaml-or-json>
        \\
    );
    switch (mode) {
        .project_selection, .list, .seed, .test_command, .build, .docs_generate, .source_freshness => {
            try writer.writeAll(
                \\  --select <selector> [selector ...]
                \\  --selector <name> [name ...]
                \\  --exclude <selector> [selector ...]
                \\  --state <path>
                \\  --defer, --no-defer
                \\  --defer-state <path>
                \\  --favor-state, --no-favor-state
                \\  --indirect-selection <eager|cautious|buildable|empty>
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
        .seed => {
            try writer.writeAll(
                \\  --threads <count>
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

test "command errors include duplicate singular test diagnostic" {
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = commandError(error.DuplicateSingularTestName, &stderr.writer);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expectEqualStrings("error: duplicate singular SQL test name in supported M1 parser subset\n", stderr.written());
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

    const code = try run(&.{ "dxt", "test", "--project-dir", "fixture", "--select", "test_type:data", "--exclude", "tag:slow" }, &stdout.writer, &stderr.writer, null);
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

test "test command help describes test options" {
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

test "seed command requires runtime I/O and accepts selector lists" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "seed", "--project-dir", "fixture", "--select", "raw_customers", "tag:nightly", "--exclude", "old_seed", "--threads", "4" }, &stdout.writer, &stderr.writer, null);
    try std.testing.expectEqual(ExitCode.usage, code);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expect(std.mem.indexOf(u8, stderr.written(), "runtime I/O is required for seed") != null);
}

test "seed command help describes seed options" {
    var stdout: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const code = try run(&.{ "dxt", "seed", "--help" }, &stdout.writer, &stderr.writer, null);
    try std.testing.expectEqual(ExitCode.ok, code);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "Usage: dxt seed") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "--select <selector>") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "--threads <count>") != null);
    try std.testing.expect(std.mem.indexOf(u8, stdout.written(), "--full-refresh") == null);
    try std.testing.expectEqualStrings("", stderr.written());
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

test "list command parses repeated selector alias flags" {
    var stderr: Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const options = try parseOptions(
        std.testing.allocator,
        &.{ "--selector", "customer_family", "--selector", "nightly", "--select", "orders" },
        &stderr.writer,
        .list,
    );
    defer {
        if (options.select) |value| std.testing.allocator.free(value);
        if (options.selector) |value| std.testing.allocator.free(value);
    }

    try std.testing.expectEqualStrings("orders", options.select.?);
    try std.testing.expectEqualStrings("customer_family nightly", options.selector.?);
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
