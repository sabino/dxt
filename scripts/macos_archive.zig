//! Build-only bridge from Zig 0.16 archives to Apple's aligned archive format.
//! Extract by ordinal because C libraries can contain duplicate member names.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.ExpectedInputAndOutputArchives;
    const cwd = std.Io.Dir.cwd();
    const archive = try cwd.readFileAlloc(init.io, args[1], allocator, .limited(512 * 1024 * 1024));
    if (!std.mem.startsWith(u8, archive, "!<arch>\n")) return error.InvalidArchiveMagic;

    const directory = try std.fmt.allocPrint(allocator, "{s}.objects", .{args[2]});
    try cwd.createDirPath(init.io, directory);
    defer cwd.deleteTree(init.io, directory) catch {};
    var command: std.ArrayList([]const u8) = .empty;
    try command.appendSlice(allocator, &.{ "/usr/bin/libtool", "-static", "-D", "-o", args[2] });

    var offset: usize = 8;
    var ordinal: usize = 0;
    while (offset < archive.len) {
        if (archive.len - offset < 60) return error.TruncatedArchiveHeader;
        const header = archive[offset..][0..60];
        if (!std.mem.eql(u8, header[58..60], "`\n")) return error.InvalidArchiveHeader;
        const size = try std.fmt.parseInt(usize, std.mem.trim(u8, header[48..58], " "), 10);
        offset += 60;
        if (size > archive.len - offset) return error.TruncatedArchiveMember;
        var body = archive[offset..][0..size];
        var name = std.mem.trim(u8, header[0..16], " ");
        if (std.mem.startsWith(u8, name, "#1/")) {
            const name_size = try std.fmt.parseInt(usize, name[3..], 10);
            if (name_size > body.len) return error.InvalidArchiveMemberName;
            name = std.mem.trimEnd(u8, body[0..name_size], "\x00 ");
            body = body[name_size..];
        }
        offset += size;
        if (offset % 2 != 0) offset += 1;
        if (std.mem.startsWith(u8, name, "__.SYMDEF") or
            std.mem.eql(u8, name, "/") or std.mem.eql(u8, name, "//") or
            std.mem.eql(u8, name, "/SYM64/")) continue;
        if (!std.mem.startsWith(u8, body, "\xcf\xfa\xed\xfe")) return error.Expected64BitMachObject;

        const path = try std.fmt.allocPrint(allocator, "{s}/{d}.o", .{ directory, ordinal });
        try cwd.writeFile(init.io, .{ .sub_path = path, .data = body });
        try command.append(allocator, path);
        ordinal += 1;
    }
    if (ordinal == 0) return error.EmptyObjectArchive;
    const result = try std.process.run(allocator, init.io, .{ .argv = command.items });
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("{s}", .{result.stderr});
            return error.AppleArchiveFailed;
        },
        else => return error.AppleArchiveFailed,
    }
}
