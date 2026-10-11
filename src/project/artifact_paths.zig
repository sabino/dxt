//! ParsedNode.get_target_write_path maps multiple nodes beneath their source.
const std = @import("std");

pub fn relative(allocator: std.mem.Allocator, path: []const u8, original_file_path: []const u8) ![]const u8 {
    if (std.mem.eql(u8, std.fs.path.basename(path), std.fs.path.basename(original_file_path))) return allocator.dupe(u8, original_file_path);
    return std.fs.path.join(allocator, &.{ original_file_path, path });
}

test "target artifacts retain singular and generated generic source directories" {
    const allocator = std.testing.allocator;
    const singular = try relative(allocator, "check.sql", "tests/check.sql");
    defer allocator.free(singular);
    try std.testing.expectEqualStrings("tests/check.sql", singular);
    const generic = try relative(allocator, "not_null_input_id.sql", "models/schema.yml");
    defer allocator.free(generic);
    try std.testing.expectEqualStrings("models/schema.yml/not_null_input_id.sql", generic);
}
