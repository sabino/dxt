const std = @import("std");
const Io = std.Io;

pub fn renderCatalog(allocator: std.mem.Allocator) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\n  \"metadata\": {\"dbt_schema_version\": ");
    try writeJsonString(writer, "https://schemas.getdbt.com/dbt/catalog/v1.json");
    try writer.writeAll(", \"dbt_version\": ");
    try writeJsonString(writer, "0.0.0");
    try writer.writeAll(", \"generated_at\": ");
    try writeJsonString(writer, "1970-01-01T00:00:00Z");
    try writer.writeAll(", \"invocation_id\": null, \"invocation_started_at\": null, \"env\": {}");
    try writer.writeAll("},\n  \"nodes\": {},\n  \"sources\": {},\n  \"errors\": null\n}\n");
    return try out.toOwnedSlice();
}

fn writeJsonString(writer: *Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

test "catalog writer emits deterministic empty dbt catalog shape" {
    const rendered = try renderCatalog(std.testing.allocator);
    defer std.testing.allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "{\n  \"metadata\": {\"dbt_schema_version\": \"https://schemas.getdbt.com/dbt/catalog/v1.json\", \"dbt_version\": \"0.0.0\", \"generated_at\": \"1970-01-01T00:00:00Z\", \"invocation_id\": null, \"invocation_started_at\": null, \"env\": {}},\n  \"nodes\": {},\n  \"sources\": {},\n  \"errors\": null\n}\n",
        rendered,
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(root.get("metadata") != null);
    try std.testing.expect(root.get("nodes").?.object.count() == 0);
    try std.testing.expect(root.get("sources").?.object.count() == 0);
    try std.testing.expect(root.get("errors").? == .null);
}
