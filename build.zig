const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("dxt", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libc = true,
    });
    // libyaml handles YAML token syntax. The native Zig yaml module owns the
    // document model, tag resolution, aliases/merges, diagnostics and lifetimes.
    mod.addIncludePath(b.path("vendor/libyaml/include"));
    mod.addCSourceFiles(.{
        .files = &.{ "vendor/libyaml/src/api.c", "vendor/libyaml/src/reader.c", "vendor/libyaml/src/scanner.c", "vendor/libyaml/src/parser.c" },
        .flags = &.{ "-std=gnu99", "-DYAML_VERSION_STRING=\"0.2.5\"", "-DYAML_VERSION_MAJOR=0", "-DYAML_VERSION_MINOR=2", "-DYAML_VERSION_PATCH=5", b.fmt("-ffile-prefix-map={s}=.", .{b.build_root.path orelse "."}) },
    });

    const exe = b.addExecutable(.{
        .name = "dxt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .link_libc = true,
            .optimize = optimize,
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
}
