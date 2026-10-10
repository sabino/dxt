const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("dxt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
        .link_libc = true,
    });
    const runtime_options = b.addOptions();
    runtime_options.addOption([]const u8, "parse_code_fingerprint", runtimeSourceFingerprint(b));
    mod.addOptions("runtime_options", runtime_options);
    mod.addAnonymousImport("docs_ui", .{ .root_source_file = b.path("vendor/dbt-docs/embed.zig") });
    mod.addAnonymousImport("dbt_includes", .{ .root_source_file = b.path("vendor/dbt-includes/embed.zig") });
    mod.addAnonymousImport("unicode_names", .{ .root_source_file = b.path("vendor/unicode/names.zig") });
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

    const exe = b.addExecutable(.{
        .name = "dxt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .link_libc = true,
            .optimize = optimize,
            .strip = optimize != .Debug,
            .imports = &.{
                .{ .name = "dxt", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run dxt");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run Zig tests");
    test_step.dependOn(&run_mod_tests.step);

    const install_tests = b.addInstallArtifact(mod_tests, .{});
    b.step("test-binary", "Build the developer native test binary").dependOn(&install_tests.step);

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
    const oracle_install = b.addInstallArtifact(yaml_oracle, .{});
    b.step("yaml-oracle", "Build the developer YAML conformance oracle").dependOn(&oracle_install.step);
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
