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
    mod.addAnonymousImport("docs_ui", .{ .root_source_file = b.path("vendor/dbt-docs/embed.zig") });
    mod.addAnonymousImport("dbt_includes", .{ .root_source_file = b.path("vendor/dbt-includes/embed.zig") });
    // libyaml handles YAML token syntax. The native Zig yaml module owns the
    // document model, tag resolution, aliases/merges, diagnostics and lifetimes.
    mod.addIncludePath(b.path("vendor/libyaml/include"));
    mod.addCSourceFiles(.{
        .files = &.{ "vendor/libyaml/src/api.c", "vendor/libyaml/src/reader.c", "vendor/libyaml/src/scanner.c", "vendor/libyaml/src/parser.c" },
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
