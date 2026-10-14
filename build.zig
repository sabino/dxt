const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bundle_drivers = b.option(bool, "bundle-drivers", "Statically bundle DuckDB and the PostgreSQL client with TLS") orelse false;
    const bundle_duckdb = b.option(bool, "bundle-duckdb", "Statically bundle DuckDB 1.4.2") orelse bundle_drivers;
    const bundle_postgres = b.option(bool, "bundle-postgres", "Statically bundle the PostgreSQL client with TLS") orelse bundle_drivers;
    const use_apple_linker = target.result.os.tag == .macos;
    const macos_sdk = if (use_apple_linker) b.option([]const u8, "macos-sdk", "macOS SDK directory for native linking") orelse b.graph.environ_map.get("SDKROOT") orelse "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk" else "";

    const mod = b.addModule("dxt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
        .link_libc = true,
    });
    const runtime_options = b.addOptions();
    runtime_options.addOption([]const u8, "parse_code_fingerprint", runtimeSourceFingerprint(b));
    runtime_options.addOption(bool, "bundle_duckdb", bundle_duckdb);
    runtime_options.addOption(bool, "bundle_postgres", bundle_postgres);
    mod.addOptions("runtime_options", runtime_options);
    if (bundle_duckdb) {
        if (target.result.os.tag != .macos) @panic("bundled DuckDB currently requires a macOS x86_64 or aarch64 target; use the dynamic-driver build on other platforms");
        const dependency = switch (target.result.cpu.arch) {
            .aarch64 => b.lazyDependency("duckdb_macos_arm64", .{}),
            .x86_64 => b.lazyDependency("duckdb_macos_x86_64", .{}),
            else => @panic("no pinned DuckDB static archive for this macOS architecture"),
        };
        if (dependency) |driver| {
            for (duckdb_static_libraries) |name| mod.addObjectFile(driver.path(name));
            // Use macOS's own C++ runtime. No separately installed C++ library
            // is needed by the executable; the SDK is a build-time requirement.
            mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ macos_sdk, "usr", "lib" }) });
            mod.linkSystemLibrary("c++.1", .{ .use_pkg_config = .no });
        }
    }
    if (bundle_postgres) {
        if (b.lazyDependency("libpq", .{
            .target = target,
            .optimize = optimize,
            .ssl = .LibreSSL,
            .@"disable-zlib" = true,
            .@"disable-zstd" = true,
        })) |client| {
            const library = client.artifact("pq");
            mapDependencySourcePaths(b, library.root_module);
            mod.linkLibrary(library);
        }
    }
    mod.addAnonymousImport("docs_ui", .{ .root_source_file = b.path("vendor/dbt-docs/embed.zig") });
    mod.addAnonymousImport("dbt_includes", .{ .root_source_file = b.path("vendor/dbt-includes/embed.zig") });
    mod.addAnonymousImport("unicode_names", .{ .root_source_file = b.path("vendor/unicode/names.zig") });
    mod.addAnonymousImport("pytz_data", .{ .root_source_file = b.path("vendor/pytz/embed.zig") });
    // libyaml handles YAML token syntax. The native Zig yaml module owns the
    // document model, tag resolution, aliases/merges, diagnostics and lifetimes.
    mod.addIncludePath(b.path("vendor/libyaml/include"));
    mod.addCSourceFiles(.{
        .files = &.{ "vendor/libyaml/src/api.c", "vendor/libyaml/src/reader.c", "vendor/libyaml/src/scanner.c", "vendor/libyaml/src/parser.c", "vendor/libyaml/src/emitter.c", "vendor/libyaml/src/writer.c" },
        .flags = &.{ "-std=gnu99", "-DYAML_VERSION_STRING=\"0.2.5\"", "-DYAML_VERSION_MAJOR=0", "-DYAML_VERSION_MINOR=2", "-DYAML_VERSION_PATCH=5", b.fmt("-ffile-prefix-map={s}=.", .{b.build_root.path orelse "."}) },
    });
    // The PostgreSQL grammar is statically linked into the native binary. Zig
    // owns AST normalization, logical IR, binding and analysis artifacts.
    const pg_parser = b.addLibrary(.{
        .name = "dxt_pg_query",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .strip = optimize != .Debug, .link_libc = true }),
    });
    pg_parser.root_module.addIncludePath(b.path("vendor/libpg_query"));
    pg_parser.root_module.addIncludePath(b.path("vendor/libpg_query/vendor"));
    pg_parser.root_module.addIncludePath(b.path("vendor/libpg_query/src/include"));
    pg_parser.root_module.addIncludePath(b.path("vendor/libpg_query/src/postgres/include"));
    if (bundle_postgres) {
        // libpq and the SQL grammar carry different PostgreSQL source versions.
        // Keep the grammar's private helpers and keyword tables out of the
        // client's ABI, including symbols that would silently interpose.
        for ([_][]const u8{
            "ScanKeywordCategories",  "ScanKeywordLookup",      "ScanKeywords",
            "appendBinaryStringInfo", "appendStringInfo",       "appendStringInfoChar",
            "appendStringInfoSpaces", "appendStringInfoString", "appendStringInfoVA",
            "destroyStringInfo",      "enlargeStringInfo",      "hash_bytes",
            "initStringInfo",         "makeStringInfo",         "pg_enc2name_tbl",
            "pg_encoding_max_length", "pg_encoding_mblen",      "pg_encoding_mblen_or_incomplete",
            "pg_fprintf",             "pg_leftmost_one_pos",    "pg_mule_mblen",
            "pg_number_of_ones",      "pg_popcount32",          "pg_popcount64",
            "pg_printf",              "pg_qsort",               "pg_qsort_strcmp",
            "pg_rightmost_one_pos",   "pg_snprintf",            "pg_sprintf",
            "pg_strcasecmp",          "pg_strerror_r",          "pg_strncasecmp",
            "pg_toupper",             "pg_utf8_islegal",        "pg_vfprintf",
            "pg_vsnprintf",           "pg_vsprintf",            "pg_wchar_table",
            "psprintf",               "pvsnprintf",             "resetStringInfo",
        }) |name| pg_parser.root_module.addCMacro(name, b.fmt("dxt_parser_{s}", .{name}));
    }
    pg_parser.root_module.addCSourceFiles(.{
        .files = @import("vendor/libpg_query/sources.zig").files,
        .flags = &.{ "-std=gnu99", "-fno-strict-aliasing", "-fwrapv", "-Wno-unused-function", "-Wno-unused-variable", b.fmt("-ffile-prefix-map={s}=.", .{b.build_root.path orelse "."}) },
    });
    mod.linkLibrary(pg_parser);
    // Syntax only: the C Python grammar never imports or executes authored code.
    // Zig owns dbt's static model validation, literal arguments and graph data.
    mod.addIncludePath(b.path("vendor/tree-sitter/include"));
    mod.addIncludePath(b.path("vendor/tree-sitter/src"));
    mod.addIncludePath(b.path("vendor/tree-sitter-python/src"));
    mod.addCSourceFiles(.{
        .files = &.{ "vendor/tree-sitter/src/lib.c", "vendor/tree-sitter-python/src/parser.c", "vendor/tree-sitter-python/src/scanner.c" },
        .flags = &.{ "-std=gnu11", b.fmt("-ffile-prefix-map={s}=.", .{b.build_root.path orelse "."}) },
    });

    // General native regular expressions back the dbt modules.re context.
    // The UTF-8 engine and Unicode 15 tables are static; no plugin or runtime
    // interpreter is needed by installed binaries.
    const regex = b.addLibrary(.{
        .name = "dxt_pcre2",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .strip = optimize != .Debug, .link_libc = true }),
    });
    regex.root_module.addIncludePath(b.path("vendor/pcre2/src"));
    regex.root_module.addCSourceFiles(.{
        .files = @import("vendor/pcre2/sources.zig").files,
        .flags = &.{ "-std=gnu99", "-DHAVE_CONFIG_H", "-DPCRE2_CODE_UNIT_WIDTH=8", "-DPCRE2_STATIC", "-DSUPPORT_PCRE2_8", "-DSUPPORT_UNICODE", "-DHAVE_MEMMOVE", "-DHAVE_STDLIB_H", "-DHAVE_STRING_H", "-DHAVE_STDINT_H", "-DHAVE_INTTYPES_H", "-DHAVE_LIMITS_H", "-DHAVE_STRERROR", b.fmt("-ffile-prefix-map={s}=.", .{b.build_root.path orelse "."}) },
    });
    mod.addIncludePath(b.path("vendor/pcre2/src"));
    mod.linkLibrary(regex);

    const executable_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .link_libc = true,
        .optimize = optimize,
        .strip = optimize != .Debug,
        .imports = &.{.{ .name = "dxt", .module = mod }},
    });
    const exe = b.addExecutable(.{
        .name = "dxt",
        .root_module = executable_module,
    });
    const apple_linker = if (use_apple_linker) AppleLinker.init(b, mod, target, optimize, macos_sdk, bundle_duckdb) else null;
    const executable = if (apple_linker) |linker| linker.executable("dxt", b.path("src/main.zig")) else exe.getEmittedBin();
    if (use_apple_linker) {
        b.getInstallStep().dependOn(&b.addInstallBinFile(executable, "dxt").step);
    } else {
        b.installArtifact(exe);
    }

    const run_step = b.step("run", "Run dxt");
    const run_cmd = if (use_apple_linker) std.Build.Step.Run.create(b, "run dxt") else b.addRunArtifact(exe);
    if (use_apple_linker) run_cmd.addFileArg(executable);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = if (apple_linker) |linker| linker.product else mod,
        .emit_object = use_apple_linker,
        // LLVM crashes generating stack protection for this Intel Mach-O
        // Debug object. Zig's x86 backend keeps all Debug checks and tests.
        .use_llvm = if (use_apple_linker and target.result.cpu.arch == .x86_64 and optimize == .Debug) false else null,
    });
    const tests_binary = if (apple_linker) |linker| linker.link("dxt-native-tests", mod_tests) else mod_tests.getEmittedBin();
    const run_mod_tests = if (use_apple_linker) std.Build.Step.Run.create(b, "run native tests") else b.addRunArtifact(mod_tests);
    if (use_apple_linker) run_mod_tests.addFileArg(tests_binary);

    const test_step = b.step("test", "Run Zig tests");
    test_step.dependOn(&run_mod_tests.step);

    const install_tests = if (use_apple_linker) &b.addInstallBinFile(tests_binary, "test").step else &b.addInstallArtifact(mod_tests, .{}).step;
    b.step("test-binary", "Build the developer native test binary").dependOn(install_tests);

    // Developer-only black-box oracle; excluded from ordinary product installs.
    const yaml_oracle = b.addExecutable(.{
        .name = "dxt-yaml-oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/yaml_oracle.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "dxt", .module = mod }},
        }),
    });
    const oracle_binary = if (apple_linker) |linker| linker.executable("dxt-yaml-oracle", b.path("tests/yaml_oracle.zig")) else yaml_oracle.getEmittedBin();
    const oracle_install = if (use_apple_linker) &b.addInstallBinFile(oracle_binary, "dxt-yaml-oracle").step else &b.addInstallArtifact(yaml_oracle, .{}).step;
    b.step("yaml-oracle", "Build the developer YAML conformance oracle").dependOn(oracle_install);

    // Developer conformance uses the exact product dependencies and C sources.
    // Only this named step installs the driver; ordinary installs stay unchanged.
    const adapter_driver = b.addExecutable(.{
        .name = "dxt-adapter-driver",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/native_adapter_driver.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "dxt", .module = mod }},
        }),
    });
    const adapter_binary = if (apple_linker) |linker| linker.executable("dxt-adapter-driver", b.path("tests/native_adapter_driver.zig")) else adapter_driver.getEmittedBin();
    const adapter_driver_install = if (use_apple_linker) &b.addInstallBinFile(adapter_binary, "dxt-adapter-driver").step else &b.addInstallArtifact(adapter_driver, .{}).step;
    b.step("adapter-driver", "Build the developer native adapter conformance driver").dependOn(adapter_driver_install);

    const cross_database_driver = b.addExecutable(.{
        .name = "dxt-cross-database-driver",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/native_cross_database_driver.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "dxt", .module = mod }},
        }),
    });
    const cross_binary = if (apple_linker) |linker| linker.executable("dxt-cross-database-driver", b.path("tests/native_cross_database_driver.zig")) else cross_database_driver.getEmittedBin();
    const cross_database_driver_install = if (use_apple_linker) &b.addInstallBinFile(cross_binary, "dxt-cross-database-driver").step else &b.addInstallArtifact(cross_database_driver, .{}).step;
    b.step("cross-database-driver", "Build the developer cross-database conformance driver").dependOn(cross_database_driver_install);
}

// Zig 0.16's Mach-O linker rejects the official DuckDB archives and fails on
// some native driver executables. Zig compiles product/C code; the SDK links it.
const AppleLinker = struct {
    b: *std.Build,
    product: *std.Build.Module,
    original: *std.Build.Module,
    support: *std.Build.Step.Compile,
    repack: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdk: []const u8,
    use_cxx: bool,

    fn init(b: *std.Build, original: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, sdk: []const u8, use_cxx: bool) AppleLinker {
        const product = b.createModule(.{ .root_source_file = original.root_source_file, .target = target, .optimize = optimize, .strip = optimize != .Debug, .link_libc = true });
        product.include_dirs = original.include_dirs;
        product.c_macros = original.c_macros;
        var imports = original.import_table.iterator();
        while (imports.next()) |entry| product.addImport(entry.key_ptr.*, entry.value_ptr.*);
        const support_module = b.createModule(.{ .target = target, .optimize = optimize, .strip = optimize != .Debug, .link_libc = true });
        support_module.include_dirs = original.include_dirs;
        for (original.link_objects.items) |object| switch (object) {
            .c_source_files, .c_source_file => support_module.link_objects.append(b.allocator, object) catch @panic("cannot allocate native C support"),
            else => {},
        };
        const support = b.addLibrary(.{ .name = "dxt_c_support", .linkage = .static, .root_module = support_module });
        const repack = b.addExecutable(.{
            .name = "dxt-macos-archive",
            .root_module = b.createModule(.{
                .root_source_file = b.path("scripts/macos_archive.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
                .link_libc = true,
            }),
        });
        return .{ .b = b, .product = product, .original = original, .support = support, .repack = repack, .target = target, .optimize = optimize, .sdk = sdk, .use_cxx = use_cxx };
    }

    fn executable(self: AppleLinker, name: []const u8, source: std.Build.LazyPath) std.Build.LazyPath {
        const object = self.b.addObject(.{
            .name = name,
            // Match the native test object's Intel Mac Debug backend.
            .use_llvm = if (self.target.result.cpu.arch == .x86_64 and self.optimize == .Debug) false else null,
            .root_module = self.b.createModule(.{
                .root_source_file = source,
                .target = self.target,
                .optimize = self.optimize,
                .strip = self.optimize != .Debug,
                .link_libc = true,
                .imports = &.{.{ .name = "dxt", .module = self.product }},
            }),
        });
        return self.link(name, object);
    }

    fn link(self: AppleLinker, name: []const u8, object: *std.Build.Step.Compile) std.Build.LazyPath {
        object.bundle_compiler_rt = true;
        object.bundle_ubsan_rt = self.optimize == .Debug;
        const command = self.b.addSystemCommand(&.{ "/usr/bin/clang", "-arch", if (self.target.result.cpu.arch == .aarch64) "arm64" else "x86_64", "-isysroot", self.sdk, "-Wl,-dead_strip", "-o" });
        const output = command.addOutputFileArg(name);
        const minimum = self.target.result.os.version_range.semver.min;
        command.addArg(self.b.fmt("-mmacosx-version-min={d}.{d}.{d}", .{ minimum.major, minimum.minor, minimum.patch }));
        if (self.optimize != .Debug) command.addArg("-Wl,-S,-x");
        command.addFileArg(object.getEmittedBin());
        command.addFileArg(self.repacked(self.support));
        self.addLibraries(command, self.original);
        if (self.use_cxx) command.addArg("-lc++");
        return output;
    }

    fn addLibraries(self: AppleLinker, command: *std.Build.Step.Run, module: *std.Build.Module) void {
        for (module.link_objects.items) |object| switch (object) {
            .static_path => |path| command.addFileArg(path),
            .other_step => |library| {
                command.addFileArg(self.repacked(library));
                self.addLibraries(command, library.root_module);
            },
            else => {},
        };
    }

    fn repacked(self: AppleLinker, library: *std.Build.Step.Compile) std.Build.LazyPath {
        // Apple's linker requires 8-byte aligned Mach-O archive members. Zig
        // 0.16 archives can use 2-byte alignment, so rebuild their container
        // without changing the compiled objects or losing duplicate names.
        const command = self.b.addRunArtifact(self.repack);
        command.addFileArg(library.getEmittedBin());
        return command.addOutputFileArg(self.b.fmt("lib{s}.a", .{library.name}));
    }
};

const duckdb_static_libraries = [_][]const u8{
    "libduckdb_static.a",     "libcore_functions_extension.a", "libjson_extension.a",
    "libparquet_extension.a", "libicu_extension.a",            "libautocomplete_extension.a",
    "libtpch_extension.a",    "libtpcds_extension.a",          "libduckdb_fastpforlib.a",
    "libduckdb_fmt.a",        "libduckdb_fsst.a",              "libduckdb_hyperloglog.a",
    "libduckdb_mbedtls.a",    "libduckdb_miniz.a",             "libduckdb_pg_query.a",
    "libduckdb_re2.a",        "libduckdb_skiplistlib.a",       "libduckdb_utf8proc.a",
    "libduckdb_yyjson.a",     "libduckdb_zstd.a",
};

fn mapDependencySourcePaths(b: *std.Build, module: *std.Build.Module) void {
    const flag = b.fmt("-ffile-prefix-map={s}=.", .{b.build_root.path orelse "."});
    for (module.link_objects.items) |object| switch (object) {
        .c_source_files => |files| {
            const flags = b.allocator.alloc([]const u8, files.flags.len + 1) catch @panic("cannot allocate dependency compiler flags");
            @memcpy(flags[0..files.flags.len], files.flags);
            flags[files.flags.len] = flag;
            files.flags = flags;
        },
        .other_step => |library| mapDependencySourcePaths(b, library.root_module),
        else => {},
    };
}

/// A cache written by another build must never retain graph values produced
/// by changed native helpers or vendored data. Hash relative names and bytes
/// at build time, so new modules participate automatically without embedding
/// the full implementation in the installed binary.
fn runtimeSourceFingerprint(b: *std.Build) []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    files.append(b.allocator, "build.zig") catch @panic("cannot allocate native source fingerprint");
    files.append(b.allocator, "build.zig.zon") catch @panic("cannot allocate native package fingerprint");
    for ([_][]const u8{ "src", "vendor" }) |root| {
        var directory = std.Io.Dir.cwd().openDir(b.graph.io, b.pathFromRoot(root), .{ .iterate = true }) catch @panic("cannot open native source directory");
        defer directory.close(b.graph.io);
        var walker = directory.walk(b.allocator) catch @panic("cannot allocate native source walker");
        defer walker.deinit();
        while (walker.next(b.graph.io) catch @panic("cannot walk native sources")) |entry| {
            if (entry.kind != .file) continue;
            files.append(b.allocator, b.pathJoin(&.{ root, entry.path })) catch @panic("cannot allocate native source path");
        }
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.less);
    var digest: std.crypto.hash.sha2.Sha256 = .init(.{});
    fingerprintPart(&digest, @import("builtin").zig_version_string);
    for (files.items) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(b.graph.io, b.pathFromRoot(path), b.allocator, .limited(256 * 1024 * 1024)) catch @panic("cannot read native source input");
        fingerprintPart(&digest, path);
        fingerprintPart(&digest, bytes);
        b.allocator.free(bytes);
    }
    const encoded = std.fmt.bytesToHex(digest.finalResult(), .lower);
    return b.allocator.dupe(u8, &encoded) catch @panic("cannot allocate native source digest");
}

fn fingerprintPart(digest: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var size: [8]u8 = undefined;
    std.mem.writeInt(u64, &size, bytes.len, .little);
    digest.update(&size);
    digest.update(bytes);
}
