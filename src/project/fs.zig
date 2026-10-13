const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

const Runtime = types.Runtime;

pub fn modelNameFromPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return resourceNameFromPath(allocator, path, if (std.mem.endsWith(u8, path, ".py")) ".py" else ".sql");
}

pub fn discoverPythonFiles(runtime: Runtime, absolute_dir: []const u8, relative_dir: []const u8, files: *std.ArrayList([]const u8)) !void {
    var reader = try DirectoryReader.open(runtime, absolute_dir);
    defer reader.close(runtime.io);
    while (try reader.next(runtime.io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.' or isIgnoredResourceDirectory(entry.name)) continue;
        const child_abs = try pathJoin(runtime.allocator, &.{ absolute_dir, entry.name });
        const child_rel = try pathJoin(runtime.allocator, &.{ relative_dir, entry.name });
        if (entry.kind == .directory or (entry.kind == .unknown and try pathIsDirectory(runtime, child_abs))) {
            try discoverPythonFiles(runtime, child_abs, child_rel, files);
        } else if ((entry.kind == .file or entry.kind == .unknown) and std.mem.endsWith(u8, entry.name, ".py")) try files.append(runtime.allocator, child_rel);
    }
}

pub fn resourceNameFromPath(allocator: std.mem.Allocator, path: []const u8, suffix: []const u8) ![]const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, suffix)) {
        return try allocator.dupe(u8, base[0 .. base.len - suffix.len]);
    }
    return try allocator.dupe(u8, base);
}

pub fn relativeUnderResourcePath(relative_path: []const u8, resource_root: []const u8) []const u8 {
    const root = std.mem.trimEnd(u8, resource_root, "/\\");
    if (root.len != 0 and std.mem.startsWith(u8, relative_path, root) and relative_path.len > root.len and (relative_path[root.len] == '/' or relative_path[root.len] == '\\')) {
        return relative_path[root.len + 1 ..];
    }
    return relative_path;
}

pub fn pathJoin(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return try std.fs.path.join(allocator, parts);
}

pub fn discoverProjectFiles(runtime: Runtime, absolute_dir: []const u8, relative_dir: []const u8, sql_files: *std.ArrayList([]const u8), yaml_files: *std.ArrayList([]const u8), md_files: *std.ArrayList([]const u8)) !void {
    var reader = try DirectoryReader.open(runtime, absolute_dir);
    defer reader.close(runtime.io);
    while (try reader.next(runtime.io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (isIgnoredResourceDirectory(entry.name)) continue;

        const child_abs = try std.fs.path.join(runtime.allocator, &.{ absolute_dir, entry.name });
        const child_rel = try std.fs.path.join(runtime.allocator, &.{ relative_dir, entry.name });
        if (entry.kind == .unknown and try pathIsDirectory(runtime, child_abs)) {
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
    var reader = try DirectoryReader.open(runtime, absolute_dir);
    defer reader.close(runtime.io);
    while (try reader.next(runtime.io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        const child_abs = try std.fs.path.join(runtime.allocator, &.{ absolute_dir, entry.name });
        const child_rel = try std.fs.path.join(runtime.allocator, &.{ relative_dir, entry.name });
        if (entry.kind == .unknown and try pathIsDirectory(runtime, child_abs)) {
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
    var reader = try DirectoryReader.open(runtime, absolute_dir);
    defer reader.close(runtime.io);
    while (try reader.next(runtime.io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (isIgnoredResourceDirectory(entry.name)) continue;

        const child_abs = try std.fs.path.join(runtime.allocator, &.{ absolute_dir, entry.name });
        const child_rel = try std.fs.path.join(runtime.allocator, &.{ relative_dir, entry.name });
        if (entry.kind == .unknown and try pathIsDirectory(runtime, child_abs)) {
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
    var reader = try DirectoryReader.open(runtime, absolute_dir);
    defer reader.close(runtime.io);
    while (try reader.next(runtime.io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (isIgnoredResourceDirectory(entry.name)) continue;

        const child_abs = try std.fs.path.join(runtime.allocator, &.{ absolute_dir, entry.name });
        const child_rel = try std.fs.path.join(runtime.allocator, &.{ relative_dir, entry.name });
        if (entry.kind == .unknown and try pathIsDirectory(runtime, child_abs)) {
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
    var reader = try DirectoryReader.open(runtime, absolute_dir);
    defer reader.close(runtime.io);
    while (try reader.next(runtime.io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        const child_abs = try std.fs.path.join(runtime.allocator, &.{ absolute_dir, entry.name });
        const is_dir = if (entry.kind == .directory)
            true
        else if (entry.kind == .unknown or entry.kind == .sym_link)
            try pathIsDirectory(runtime, child_abs)
        else
            false;
        if (is_dir) {
            try directories.append(runtime.allocator, child_abs);
        }
    }
}

const LinuxDirEntry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
};

// Keep the established synchronous Linux reader for mounts that report
// DT_UNKNOWN. Other hosts must use their own directory ABI through std.Io.
const DirectoryReader = if (builtin.os.tag == .linux) LinuxDirectoryReader else PortableDirectoryReader;

const LinuxDirectoryReader = struct {
    fd: std.os.linux.fd_t,
    buffer: [8192]u8 align(@alignOf(std.os.linux.dirent64)) = undefined,
    index: usize = 0,
    end: usize = 0,

    fn open(runtime: Runtime, path: []const u8) !LinuxDirectoryReader {
        return .{ .fd = try openLinuxDirectory(runtime.allocator, path) };
    }

    fn close(self: *LinuxDirectoryReader, _: std.Io) void {
        closeLinuxFd(self.fd);
    }

    fn next(self: *LinuxDirectoryReader, _: std.Io) !?LinuxDirEntry {
        var state: LinuxDirReadState = .{ .fd = self.fd, .buffer = &self.buffer, .index = self.index, .end = self.end };
        defer {
            self.index = state.index;
            self.end = state.end;
        }
        return nextLinuxDirectoryEntry(&state);
    }
};

const PortableDirectoryReader = struct {
    directory: std.Io.Dir,
    iterator: std.Io.Dir.Iterator,

    fn open(runtime: Runtime, path: []const u8) !PortableDirectoryReader {
        const directory = try std.Io.Dir.cwd().openDir(runtime.io, path, .{ .iterate = true });
        return .{ .directory = directory, .iterator = directory.iterate() };
    }

    fn close(self: *PortableDirectoryReader, io: std.Io) void {
        self.directory.close(io);
    }

    fn next(self: *PortableDirectoryReader, io: std.Io) !?LinuxDirEntry {
        const entry = (try self.iterator.next(io)) orelse return null;
        return .{ .name = entry.name, .kind = entry.kind };
    }
};

fn pathIsDirectory(runtime: Runtime, path: []const u8) !bool {
    if (builtin.os.tag == .linux) return linuxPathIsDirectory(runtime.allocator, path);
    const directory = std.Io.Dir.cwd().openDir(runtime.io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir, error.FileNotFound => return false,
        else => return err,
    };
    directory.close(runtime.io);
    return true;
}

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

test "host directory discovery loads nested resources and preserves ignored paths" {
    const io = std.testing.io;
    var fixture = std.testing.tmpDir(.{});
    defer fixture.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const runtime: Runtime = .{ .allocator = a, .io = io };
    const paths = [_][]const u8{
        "models/base.sql",          "models/schema.yml",  "models/docs.md",         "models/python.py",
        "macros/format.sql",        "macros/schema.yaml", "seeds/input.csv",        "target/ignored.sql",
        "dbt_packages/ignored.sql", "zig-out/ignored.py", ".zig-cache/ignored.sql", ".hidden/ignored.sql",
    };
    for (paths) |path| {
        try fixture.dir.createDirPath(io, std.fs.path.dirname(path).?);
        try fixture.dir.writeFile(io, .{ .sub_path = path, .data = "fixture" });
    }
    if (builtin.os.tag == .linux or builtin.os.tag == .macos) {
        try fixture.dir.symLink(io, "models", "linked_models", .{ .is_directory = true });
        try fixture.dir.symLink(io, "models/base.sql", "linked.sql", .{});
    }
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = path_buffer[0..try fixture.dir.realPath(io, &path_buffer)];
    var sql: std.ArrayList([]const u8) = .empty;
    var yaml: std.ArrayList([]const u8) = .empty;
    var docs: std.ArrayList([]const u8) = .empty;
    try discoverProjectFiles(runtime, root, "", &sql, &yaml, &docs);
    try std.testing.expectEqual(@as(usize, 2), sql.items.len);
    try std.testing.expectEqual(@as(usize, 2), yaml.items.len);
    try std.testing.expectEqualStrings("models/docs.md", docs.items[0]);
    var python: std.ArrayList([]const u8) = .empty;
    try discoverPythonFiles(runtime, root, "", &python);
    try std.testing.expectEqual(@as(usize, 1), python.items.len);
    try std.testing.expectEqualStrings("models/python.py", python.items[0]);
    var seeds: std.ArrayList([]const u8) = .empty;
    try discoverSeedFiles(runtime, root, "", &seeds);
    try std.testing.expectEqual(@as(usize, 1), seeds.items.len);
    try std.testing.expectEqualStrings("seeds/input.csv", seeds.items[0]);
    try std.testing.expect(try pathIsDirectory(runtime, root));
    try std.testing.expect(!try pathIsDirectory(runtime, try pathJoin(a, &.{ root, "models/base.sql" })));
    try std.testing.expect(!try pathIsDirectory(runtime, try pathJoin(a, &.{ root, "missing" })));
    try std.testing.expectError(error.FileNotFound, DirectoryReader.open(runtime, try pathJoin(a, &.{ root, "missing" })));
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
    try std.testing.expectEqualStrings("generic/test.sql", relativeUnderResourcePath("tests/generic/test.sql", "tests/"));
    try std.testing.expectEqualStrings("models_extra/orders.sql", relativeUnderResourcePath("models_extra/orders.sql", "models"));
    try std.testing.expectEqualStrings("models", relativeUnderResourcePath("models", "models"));
}
