//! Reversible filesystem publication paired with a native SQL transaction.
const std = @import("std");

const Entry = struct {
    target: []const u8,
    staged: []const u8,
    backup: []const u8,
    lock: std.Io.File,
    had_original: bool = false,
    published: bool = false,
};

pub const Journal = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    entries: std.ArrayList(Entry) = .empty,
    finalized: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Journal {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn prepare(self: *Journal, target: []const u8) ![]const u8 {
        if (self.finalized) return error.ExternalJournalFinalized;
        if (target.len == 0 or std.mem.indexOf(u8, target, "://") != null) return error.UnsupportedExternalPublication;
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.target, target)) return entry.staged;
        const lock_path = try std.fmt.allocPrint(self.allocator, "{s}.dxt-lock", .{target});
        defer self.allocator.free(lock_path);
        // Keep the inode stable: unlinking it would allow another writer to
        // acquire a different lock while an existing holder still owns this one.
        const lock = std.Io.Dir.cwd().createFile(self.io, lock_path, .{ .truncate = false, .lock = .exclusive, .lock_nonblocking = true }) catch |err| return if (err == error.WouldBlock) error.ExternalTargetLocked else err;
        errdefer lock.close(self.io);
        var random: [16]u8 = undefined;
        self.io.random(&random);
        const nonce = std.fmt.bytesToHex(random, .lower);
        const staged = try std.fmt.allocPrint(self.allocator, "{s}.dxt-stage-{s}", .{ target, nonce });
        errdefer self.allocator.free(staged);
        const backup = try std.fmt.allocPrint(self.allocator, "{s}.dxt-backup-{s}", .{ target, nonce });
        errdefer self.allocator.free(backup);
        const owned_target = try self.allocator.dupe(u8, target);
        errdefer self.allocator.free(owned_target);
        try self.entries.append(self.allocator, .{ .target = owned_target, .staged = staged, .backup = backup, .lock = lock });
        return staged;
    }

    pub fn publish(self: *Journal) !void {
        if (self.finalized) return error.ExternalJournalFinalized;
        for (self.entries.items) |*entry| {
            if (entry.published) continue;
            // Verify staging exists before moving the previous output aside.
            _ = try std.Io.Dir.cwd().statFile(self.io, entry.staged, .{});
            if (std.Io.Dir.cwd().statFile(self.io, entry.target, .{})) |_| {
                try std.Io.Dir.rename(std.Io.Dir.cwd(), entry.target, std.Io.Dir.cwd(), entry.backup, self.io);
                entry.had_original = true;
            } else |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            }
            std.Io.Dir.rename(std.Io.Dir.cwd(), entry.staged, std.Io.Dir.cwd(), entry.target, self.io) catch |err| {
                if (entry.had_original) {
                    try std.Io.Dir.rename(std.Io.Dir.cwd(), entry.backup, std.Io.Dir.cwd(), entry.target, self.io);
                    entry.had_original = false;
                }
                return err;
            };
            entry.published = true;
        }
    }

    pub fn rollback(self: *Journal) !void {
        if (self.finalized) return;
        // Attempt every restoration even when one output cannot be restored.
        var failure: ?anyerror = null;
        var i = self.entries.items.len;
        while (i != 0) {
            i -= 1;
            const entry = &self.entries.items[i];
            if (entry.published) {
                removePath(self.io, entry.target) catch |err| {
                    failure = err;
                    continue;
                };
                entry.published = false;
            }
            if (entry.had_original) {
                std.Io.Dir.rename(std.Io.Dir.cwd(), entry.backup, std.Io.Dir.cwd(), entry.target, self.io) catch |err| {
                    failure = err;
                    continue;
                };
                entry.had_original = false;
            }
            removePath(self.io, entry.staged) catch |err| {
                failure = err;
            };
        }
        if (failure) |err| return err;
    }

    pub fn finalize(self: *Journal) !void {
        // SQL has committed. Cleanup failures must never restore an older file
        // underneath the committed view; backups can safely remain for cleanup.
        self.finalized = true;
        var failure: ?anyerror = null;
        for (self.entries.items) |*entry| if (entry.had_original) {
            removePath(self.io, entry.backup) catch |err| {
                failure = err;
                continue;
            };
            entry.had_original = false;
        };
        if (failure) |err| return err;
    }

    pub fn deinit(self: *Journal) void {
        self.rollback() catch {};
        for (self.entries.items) |entry| {
            entry.lock.close(self.io);
            self.allocator.free(entry.target);
            self.allocator.free(entry.staged);
            self.allocator.free(entry.backup);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
};

fn removePath(io: std.Io, path: []const u8) !void {
    try std.Io.Dir.cwd().deleteTree(io, path);
}

fn writeTestFile(path: []const u8, data: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, data);
}

test "file publication restores originals on rollback and retains committed output" {
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const target = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/data.csv", .{temporary.sub_path});
    defer a.free(target);
    try writeTestFile(target, "old");
    {
        var journal = Journal.init(a, std.testing.io);
        defer journal.deinit();
        try writeTestFile(try journal.prepare(target), "new");
        try journal.publish();
        try journal.publish();
        const published = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, target, a, .limited(100));
        defer a.free(published);
        try std.testing.expectEqualStrings("new", published);
        try journal.rollback();
    }
    const restored = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, target, a, .limited(100));
    defer a.free(restored);
    try std.testing.expectEqualStrings("old", restored);
    {
        var journal = Journal.init(a, std.testing.io);
        defer journal.deinit();
        try writeTestFile(try journal.prepare(target), "committed");
        try journal.publish();
        try journal.finalize();
    }
    const committed = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, target, a, .limited(100));
    defer a.free(committed);
    try std.testing.expectEqualStrings("committed", committed);
}

test "directory outputs roll back atomically and concurrent writers cannot publish" {
    const a = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const target = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/parts", .{temporary.sub_path});
    defer a.free(target);
    var journal = Journal.init(a, std.testing.io);
    defer journal.deinit();
    const staged = try journal.prepare(target);
    var other = Journal.init(a, std.testing.io);
    defer other.deinit();
    try std.testing.expectError(error.ExternalTargetLocked, other.prepare(target));
    try std.Io.Dir.cwd().createDirPath(std.testing.io, staged);
    const part = try std.fs.path.join(a, &.{ staged, "part.parquet" });
    defer a.free(part);
    try writeTestFile(part, "partition");
    try journal.publish();
    try journal.rollback();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, target, .{}));
    try std.testing.expectError(error.UnsupportedExternalPublication, journal.prepare("s3://bucket/file.parquet"));
}
