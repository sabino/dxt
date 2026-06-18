const std = @import("std");
const Io = std.Io;

const project_config = @import("config.zig");
const project_fs = @import("fs.zig");
const types = @import("types.zig");
const util = @import("util.zig");

const ProjectConfig = types.ProjectConfig;

pub fn run(runtime: types.Runtime, options: types.Options, stdout: *Io.Writer) !void {
    var config = try project_config.loadProjectConfig(runtime, options.project_dir);
    defer types.deinitProjectConfig(runtime.allocator, &config);

    const targets = if (config.clean_targets_set) config.clean_targets.items else &.{options.target_path orelse config.target_path};
    var clean_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (clean_paths.items) |path| runtime.allocator.free(path);
        clean_paths.deinit(runtime.allocator);
    }
    for (targets) |target| {
        try clean_paths.append(runtime.allocator, try cleanTargetPath(runtime.allocator, options.project_dir, &config, target));
    }

    var cleaned_count: usize = 0;
    for (clean_paths.items) |clean_path| {
        try deleteCleanDirectory(runtime, clean_path);
        cleaned_count += 1;
        try stdout.print("Cleaned {s}\n", .{util.normalizeForDisplay(clean_path)});
    }
    try stdout.print("Finished cleaning {d} path(s)\n", .{cleaned_count});
}

fn deleteCleanDirectory(runtime: types.Runtime, clean_path: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(runtime.io, clean_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    dir.close(runtime.io);
    try std.Io.Dir.cwd().deleteTree(runtime.io, clean_path);
}

fn cleanTargetPath(allocator: std.mem.Allocator, project_dir: []const u8, config: *const ProjectConfig, raw_target: []const u8) ![]const u8 {
    const target = std.mem.trim(u8, raw_target, " \t\r\n");
    if (target.len == 0) return error.UnsupportedCleanPath;
    if (std.fs.path.isAbsolute(target)) return error.UnsupportedCleanOutsideProject;
    if (!isSafeRelativePath(target)) return error.UnsupportedCleanOutsideProject;
    if (isProtectedSourcePath(target, config)) return error.UnsupportedCleanSourcePath;
    return try project_fs.pathJoin(allocator, &.{ project_dir, target });
}

fn isSafeRelativePath(path: []const u8) bool {
    var saw_segment = false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        saw_segment = true;
    }
    return saw_segment;
}

fn isProtectedSourcePath(target: []const u8, config: *const ProjectConfig) bool {
    const built_in_protected = [_][]const u8{
        "models",
        "seeds",
        "macros",
        "tests",
        "test",
        "analyses",
        "analysis",
        "snapshots",
    };
    for (built_in_protected) |path| {
        if (pathsOverlap(target, path)) return true;
    }
    for (config.model_paths.items) |path| {
        if (pathsOverlap(target, path)) return true;
    }
    for (config.seed_paths.items) |path| {
        if (pathsOverlap(target, path)) return true;
    }
    for (config.macro_paths.items) |path| {
        if (pathsOverlap(target, path)) return true;
    }
    for (config.test_paths.items) |path| {
        if (pathsOverlap(target, path)) return true;
    }
    for (config.analysis_paths.items) |path| {
        if (pathsOverlap(target, path)) return true;
    }
    for (config.snapshot_paths.items) |path| {
        if (pathsOverlap(target, path)) return true;
    }
    for (config.function_paths.items) |path| {
        if (pathsOverlap(target, path)) return true;
    }
    return false;
}

fn pathsOverlap(left: []const u8, right: []const u8) bool {
    const normalized_left = normalizePathForOverlap(left);
    const normalized_right = normalizePathForOverlap(right);
    if (normalized_left.len == 0 or normalized_right.len == 0) return false;
    return rawPathsOverlap(normalized_left, normalized_right);
}

fn normalizePathForOverlap(path: []const u8) []const u8 {
    var normalized = trimCurrentDirPrefixes(path);
    while (std.mem.endsWith(u8, normalized, "/")) {
        normalized = normalized[0 .. normalized.len - 1];
    }
    return normalized;
}

fn trimCurrentDirPrefixes(path: []const u8) []const u8 {
    var normalized = std.mem.trim(u8, path, " \t\r\n");
    while (std.mem.startsWith(u8, normalized, "./")) {
        normalized = normalized[2..];
    }
    return normalized;
}

fn rawPathsOverlap(left: []const u8, right: []const u8) bool {
    if (std.mem.eql(u8, left, right)) return true;
    if (std.mem.startsWith(u8, left, right) and left.len > right.len and left[right.len] == '/') return true;
    if (std.mem.startsWith(u8, right, left) and right.len > left.len and right[left.len] == '/') return true;
    return false;
}

test "clean path safety accepts project-relative non-source targets" {
    try std.testing.expect(isSafeRelativePath("target"));
    try std.testing.expect(isSafeRelativePath("target/nested"));
    try std.testing.expect(!isSafeRelativePath(""));
    try std.testing.expect(!isSafeRelativePath("."));
    try std.testing.expect(!isSafeRelativePath("../target"));
    try std.testing.expect(!isSafeRelativePath("target/../models"));
    try std.testing.expect(!isSafeRelativePath("target//nested"));
}

test "clean protects source path overlaps" {
    var config = ProjectConfig{ .name = "demo" };
    defer types.deinitProjectConfig(std.testing.allocator, &config);
    try config.model_paths.append(std.testing.allocator, "models");
    try config.seed_paths.append(std.testing.allocator, "seeds");
    try config.macro_paths.append(std.testing.allocator, "macros");
    try config.test_paths.append(std.testing.allocator, "custom_tests");
    try config.analysis_paths.append(std.testing.allocator, "./marts");
    try config.snapshot_paths.append(std.testing.allocator, "snapshot_defs/");

    try std.testing.expect(isProtectedSourcePath("models", &config));
    try std.testing.expect(isProtectedSourcePath("models/generated", &config));
    try std.testing.expect(isProtectedSourcePath("macros", &config));
    try std.testing.expect(isProtectedSourcePath("custom_tests", &config));
    try std.testing.expect(isProtectedSourcePath("marts", &config));
    try std.testing.expect(isProtectedSourcePath("marts/generated", &config));
    try std.testing.expect(isProtectedSourcePath("snapshot_defs/generated", &config));
    try std.testing.expect(isProtectedSourcePath("tests", &config));
    try std.testing.expect(isProtectedSourcePath("snapshots/archive", &config));
    try std.testing.expect(!isProtectedSourcePath("target", &config));
    try std.testing.expect(!isProtectedSourcePath("dbt_packages", &config));
}
