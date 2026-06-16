const std = @import("std");
const types = @import("types.zig");

const Runtime = types.Runtime;

pub fn modelNameFromPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return resourceNameFromPath(allocator, path, ".sql");
}

pub fn resourceNameFromPath(allocator: std.mem.Allocator, path: []const u8, suffix: []const u8) ![]const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, suffix)) {
        return try allocator.dupe(u8, base[0 .. base.len - suffix.len]);
    }
    return try allocator.dupe(u8, base);
}

pub fn relativeUnderResourcePath(relative_path: []const u8, resource_root: []const u8) []const u8 {
    if (std.mem.startsWith(u8, relative_path, resource_root) and relative_path.len > resource_root.len and relative_path[resource_root.len] == '/') {
        return relative_path[resource_root.len + 1 ..];
    }
    return relative_path;
}

pub fn pathJoin(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return try std.fs.path.join(allocator, parts);
}

pub fn discoverProjectFiles(runtime: Runtime, absolute_dir: []const u8, relative_dir: []const u8, sql_files: *std.ArrayList([]const u8), yaml_files: *std.ArrayList([]const u8), md_files: *std.ArrayList([]const u8)) !void {
    const fd = try openLinuxDirectory(runtime.allocator, absolute_dir);
    defer closeLinuxFd(fd);

    var buffer: [8192]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    var iter = LinuxDirReadState{ .fd = fd, .buffer = &buffer };
    while (try nextLinuxDirectoryEntry(&iter)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (isIgnoredResourceDirectory(entry.name)) continue;

        const child_abs = try std.fs.path.join(runtime.allocator, &.{ absolute_dir, entry.name });
        const child_rel = try std.fs.path.join(runtime.allocator, &.{ relative_dir, entry.name });
        if (entry.kind == .unknown and try linuxPathIsDirectory(runtime.allocator, child_abs)) {
            try discoverProjectFiles(runtime, child_abs, child_rel, sql_files, yaml_files, md_files);
            continue;
        }
        switch (entry.kind) {
            .directory => try discoverProjectFiles(runtime, child_abs, child_rel, sql_files, yaml_files, md_files),
            .file, .unknown => {
                if (std.mem.endsWith(u8, entry.name, ".sql")) {
                    try sql_files.append(runtime.allocator, child_rel);
                } else if (std.mem.endsWith(u8, entry.name, ".yml") or std.mem.endsWith(u8, entry.name, ".yaml")) {
                    try yaml_files.append(runtime.allocator, child_rel);
                } else if (std.mem.endsWith(u8, entry.name, ".md")) {
                    try md_files.append(runtime.allocator, child_rel);
                }
            },
            else => {},
        }
    }
}

pub fn discoverSeedFiles(runtime: Runtime, absolute_dir: []const u8, relative_dir: []const u8, seed_files: *std.ArrayList([]const u8)) !void {
    const fd = try openLinuxDirectory(runtime.allocator, absolute_dir);
    defer closeLinuxFd(fd);

    var buffer: [8192]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    var iter = LinuxDirReadState{ .fd = fd, .buffer = &buffer };
    while (try nextLinuxDirectoryEntry(&iter)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        const child_abs = try std.fs.path.join(runtime.allocator, &.{ absolute_dir, entry.name });
        const child_rel = try std.fs.path.join(runtime.allocator, &.{ relative_dir, entry.name });
        if (entry.kind == .unknown and try linuxPathIsDirectory(runtime.allocator, child_abs)) {
            try discoverSeedFiles(runtime, child_abs, child_rel, seed_files);
            continue;
        }
        switch (entry.kind) {
            .directory => try discoverSeedFiles(runtime, child_abs, child_rel, seed_files),
            .file, .unknown => {
                if (std.mem.endsWith(u8, entry.name, ".csv")) {
                    try seed_files.append(runtime.allocator, child_rel);
                }
            },
            else => {},
        }
    }
}

fn discoverSqlFiles(runtime: Runtime, absolute_dir: []const u8, relative_dir: []const u8, sql_files: *std.ArrayList([]const u8)) !void {
    const fd = try openLinuxDirectory(runtime.allocator, absolute_dir);
    defer closeLinuxFd(fd);

    var buffer: [8192]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    var iter = LinuxDirReadState{ .fd = fd, .buffer = &buffer };
    while (try nextLinuxDirectoryEntry(&iter)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (isIgnoredResourceDirectory(entry.name)) continue;

        const child_abs = try std.fs.path.join(runtime.allocator, &.{ absolute_dir, entry.name });
        const child_rel = try std.fs.path.join(runtime.allocator, &.{ relative_dir, entry.name });
        if (entry.kind == .unknown and try linuxPathIsDirectory(runtime.allocator, child_abs)) {
            try discoverSqlFiles(runtime, child_abs, child_rel, sql_files);
            continue;
        }
        switch (entry.kind) {
            .directory => try discoverSqlFiles(runtime, child_abs, child_rel, sql_files),
            .file, .unknown => {
                if (std.mem.endsWith(u8, entry.name, ".sql")) {
                    try sql_files.append(runtime.allocator, child_rel);
                }
            },
            else => {},
        }
    }
}

pub fn discoverMacroFiles(runtime: Runtime, absolute_dir: []const u8, relative_dir: []const u8, sql_files: *std.ArrayList([]const u8), yaml_files: *std.ArrayList([]const u8)) !void {
    const fd = try openLinuxDirectory(runtime.allocator, absolute_dir);
    defer closeLinuxFd(fd);

    var buffer: [8192]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    var iter = LinuxDirReadState{ .fd = fd, .buffer = &buffer };
    while (try nextLinuxDirectoryEntry(&iter)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (isIgnoredResourceDirectory(entry.name)) continue;

        const child_abs = try std.fs.path.join(runtime.allocator, &.{ absolute_dir, entry.name });
        const child_rel = try std.fs.path.join(runtime.allocator, &.{ relative_dir, entry.name });
        if (entry.kind == .unknown and try linuxPathIsDirectory(runtime.allocator, child_abs)) {
            try discoverMacroFiles(runtime, child_abs, child_rel, sql_files, yaml_files);
            continue;
        }
        switch (entry.kind) {
            .directory => try discoverMacroFiles(runtime, child_abs, child_rel, sql_files, yaml_files),
            .file, .unknown => {
                if (std.mem.endsWith(u8, entry.name, ".sql")) {
                    try sql_files.append(runtime.allocator, child_rel);
                } else if (std.mem.endsWith(u8, entry.name, ".yml") or std.mem.endsWith(u8, entry.name, ".yaml")) {
                    try yaml_files.append(runtime.allocator, child_rel);
                }
            },
            else => {},
        }
    }
}

pub fn discoverChildDirectories(runtime: Runtime, absolute_dir: []const u8, directories: *std.ArrayList([]const u8)) !void {
    const fd = try openLinuxDirectory(runtime.allocator, absolute_dir);
    defer closeLinuxFd(fd);

    var buffer: [8192]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    var iter = LinuxDirReadState{ .fd = fd, .buffer = &buffer };
    while (try nextLinuxDirectoryEntry(&iter)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const child_abs = try std.fs.path.join(runtime.allocator, &.{ absolute_dir, entry.name });
        const is_dir = if (entry.kind == .directory)
            true
        else if (entry.kind == .unknown)
            try linuxPathIsDirectory(runtime.allocator, child_abs)
        else
            false;
        if (is_dir) {
            try directories.append(runtime.allocator, child_abs);
        }
    }
}

const LinuxDirEntry = struct {
    name: [:0]const u8,
    kind: std.Io.File.Kind,
};

const LinuxDirReadState = struct {
    fd: std.os.linux.fd_t,
    buffer: []u8,
    index: usize = 0,
    end: usize = 0,
};

// Keep discovery synchronous and deterministic on mounts that report DT_UNKNOWN
// or behave poorly with the experimental std.Io directory iterator.
fn openLinuxDirectory(allocator: std.mem.Allocator, path: []const u8) !std.os.linux.fd_t {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const rc = std.os.linux.openat(std.os.linux.AT.FDCWD, path_z.ptr, .{ .DIRECTORY = true, .CLOEXEC = true }, 0);
    return switch (std.os.linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .ACCES => error.AccessDenied,
        else => error.Unexpected,
    };
}

fn closeLinuxFd(fd: std.os.linux.fd_t) void {
    _ = std.os.linux.close(fd);
}

fn linuxPathIsDirectory(allocator: std.mem.Allocator, path: []const u8) !bool {
    const fd = openLinuxDirectory(allocator, path) catch |err| switch (err) {
        error.NotDir => return false,
        error.FileNotFound => return false,
        else => return err,
    };
    closeLinuxFd(fd);
    return true;
}

fn nextLinuxDirectoryEntry(state: *LinuxDirReadState) !?LinuxDirEntry {
    while (true) {
        if (state.index >= state.end) {
            const rc = std.os.linux.getdents64(state.fd, state.buffer.ptr, state.buffer.len);
            switch (std.os.linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.Unexpected,
            }
            if (rc == 0) return null;
            state.index = 0;
            state.end = rc;
        }

        const linux_entry: *align(1) std.os.linux.dirent64 = @ptrCast(&state.buffer[state.index]);
        state.index += linux_entry.reclen;

        const name_ptr: [*]u8 = &linux_entry.name;
        const padded_name = name_ptr[0 .. linux_entry.reclen - @offsetOf(std.os.linux.dirent64, "name")];
        const name_len = std.mem.findScalar(u8, padded_name, 0).?;
        const name = name_ptr[0..name_len :0];
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        return .{
            .name = name,
            .kind = switch (linux_entry.type) {
                std.os.linux.DT.DIR => .directory,
                std.os.linux.DT.REG => .file,
                std.os.linux.DT.LNK => .sym_link,
                else => .unknown,
            },
        };
    }
}

fn isIgnoredResourceDirectory(name: []const u8) bool {
    return std.mem.eql(u8, name, "target") or
        std.mem.eql(u8, name, "dbt_packages") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-out");
}

test "resource discovery skips generated and package directories" {
    try std.testing.expect(isIgnoredResourceDirectory("target"));
    try std.testing.expect(isIgnoredResourceDirectory("dbt_packages"));
    try std.testing.expect(isIgnoredResourceDirectory(".zig-cache"));
    try std.testing.expect(isIgnoredResourceDirectory("zig-out"));
    try std.testing.expect(!isIgnoredResourceDirectory("models"));
}

test "resourceNameFromPath strips the requested suffix from the basename only" {
    const allocator = std.testing.allocator;

    const nested_model = try resourceNameFromPath(allocator, "models/staging/orders.sql", ".sql");
    defer allocator.free(nested_model);
    try std.testing.expectEqualStrings("orders", nested_model);

    const seed = try resourceNameFromPath(allocator, "seeds/raw/customers.csv", ".csv");
    defer allocator.free(seed);
    try std.testing.expectEqualStrings("customers", seed);

    const unchanged = try resourceNameFromPath(allocator, "models/staging/orders.sql", ".csv");
    defer allocator.free(unchanged);
    try std.testing.expectEqualStrings("orders.sql", unchanged);
}

test "modelNameFromPath strips sql suffix using resource name semantics" {
    const allocator = std.testing.allocator;

    const model = try modelNameFromPath(allocator, "models/marts/customers.sql");
    defer allocator.free(model);
    try std.testing.expectEqualStrings("customers", model);
}

test "relativeUnderResourcePath strips only slash-delimited resource roots" {
    try std.testing.expectEqualStrings("staging/orders.sql", relativeUnderResourcePath("models/staging/orders.sql", "models"));
    try std.testing.expectEqualStrings("models_extra/orders.sql", relativeUnderResourcePath("models_extra/orders.sql", "models"));
    try std.testing.expectEqualStrings("models", relativeUnderResourcePath("models", "models"));
}
