const std = @import("std");
const Io = std.Io;
const json = @import("json.zig");

pub const CatalogColumn = struct {
    name: []const u8,
    data_type: []const u8,
    index: u64,
};

pub const CatalogEntry = struct {
    unique_id: []const u8,
    database: ?[]const u8 = null,
    schema: []const u8,
    name: []const u8,
    relation_type: []const u8,
    columns: std.ArrayList(CatalogColumn) = .empty,
};

pub const CatalogEntries = struct {
    nodes: std.ArrayList(CatalogEntry) = .empty,
    sources: std.ArrayList(CatalogEntry) = .empty,
};

pub fn deinitCatalogEntries(allocator: std.mem.Allocator, entries: *CatalogEntries) void {
    deinitEntries(allocator, &entries.nodes);
    deinitEntries(allocator, &entries.sources);
}

pub fn deinitEntries(allocator: std.mem.Allocator, entries: *std.ArrayList(CatalogEntry)) void {
    for (entries.items) |*entry| {
        allocator.free(entry.unique_id);
        if (entry.database) |database| allocator.free(database);
        allocator.free(entry.schema);
        allocator.free(entry.name);
        allocator.free(entry.relation_type);
        for (entry.columns.items) |column| {
            allocator.free(column.name);
            allocator.free(column.data_type);
        }
        entry.columns.deinit(allocator);
    }
    entries.deinit(allocator);
}

pub fn renderCatalog(allocator: std.mem.Allocator, nodes: []const CatalogEntry, sources: []const CatalogEntry) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\n  \"metadata\": {\"dbt_schema_version\": ");
    try json.string(writer, "https://schemas.getdbt.com/dbt/catalog/v1.json");
    try writer.writeAll(", \"dbt_version\": ");
    try json.string(writer, "0.0.0");
    try writer.writeAll(", \"generated_at\": ");
    try json.string(writer, "1970-01-01T00:00:00Z");
    try writer.writeAll(", \"invocation_id\": null, \"invocation_started_at\": null, \"env\": {}");
    try writer.writeAll("},\n  \"nodes\": {");
    try writeCatalogEntryMap(writer, nodes);
    try writer.writeAll("},\n  \"sources\": {");
    try writeCatalogEntryMap(writer, sources);
    try writer.writeAll("},\n  \"errors\": null\n}\n");
    return try out.toOwnedSlice();
}

fn writeCatalogEntryMap(writer: *Io.Writer, entries: []const CatalogEntry) !void {
    for (entries, 0..) |entry, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try json.string(writer, entry.unique_id);
        try writer.writeAll(": {\"metadata\": {\"type\": ");
        try json.string(writer, entry.relation_type);
        try writer.writeAll(", \"schema\": ");
        try json.string(writer, entry.schema);
        try writer.writeAll(", \"name\": ");
        try json.string(writer, entry.name);
        try writer.writeAll(", \"database\": ");
        if (entry.database) |database| {
            try json.string(writer, database);
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll(", \"comment\": null, \"owner\": null}, \"columns\": {");
        for (entry.columns.items, 0..) |column, column_index| {
            if (column_index != 0) try writer.writeAll(",");
            try writer.writeAll("\n      ");
            try json.string(writer, column.name);
            try writer.writeAll(": {\"type\": ");
            try json.string(writer, column.data_type);
            try writer.writeAll(", \"index\": ");
            try writer.print("{d}", .{column.index});
            try writer.writeAll(", \"name\": ");
            try json.string(writer, column.name);
            try writer.writeAll(", \"comment\": null}");
        }
        if (entry.columns.items.len != 0) try writer.writeAll("\n    ");
        try writer.writeAll("}, \"stats\": {\"has_stats\": {\"id\": \"has_stats\", \"label\": \"Has Stats?\", \"value\": false, \"description\": \"Indicates whether there are statistics for this table\", \"include\": false}}, \"unique_id\": ");
        try json.string(writer, entry.unique_id);
        try writer.writeAll("}");
    }
    if (entries.len != 0) try writer.writeAll("\n  ");
}

test "catalog writer emits deterministic empty dbt catalog shape" {
    const rendered = try renderCatalog(std.testing.allocator, &.{}, &.{});
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

test "catalog writer emits selected relation metadata and ordered columns" {
    var columns: std.ArrayList(CatalogColumn) = .empty;
    defer columns.deinit(std.testing.allocator);
    try columns.append(std.testing.allocator, .{ .name = "customer_id", .data_type = "INTEGER", .index = 1 });
    try columns.append(std.testing.allocator, .{ .name = "order_count", .data_type = "BIGINT", .index = 2 });
    const entries = [_]CatalogEntry{
        .{
            .unique_id = "model.demo.orders",
            .schema = "main",
            .name = "orders",
            .relation_type = "BASE TABLE",
            .columns = columns,
        },
    };
    const rendered = try renderCatalog(std.testing.allocator, &entries, &.{});
    defer std.testing.allocator.free(rendered);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();
    const nodes = parsed.value.object.get("nodes").?.object;
    const orders = nodes.get("model.demo.orders").?.object;
    try std.testing.expectEqualStrings("model.demo.orders", orders.get("unique_id").?.string);
    try std.testing.expectEqualStrings("BASE TABLE", orders.get("metadata").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("main", orders.get("metadata").?.object.get("schema").?.string);
    const rendered_columns = orders.get("columns").?.object;
    try std.testing.expectEqual(@as(usize, 2), rendered_columns.count());
    try std.testing.expectEqualStrings("INTEGER", rendered_columns.get("customer_id").?.object.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 2), rendered_columns.get("order_count").?.object.get("index").?.integer);
}

test "catalog writer emits selected source metadata separately from nodes" {
    var columns: std.ArrayList(CatalogColumn) = .empty;
    defer columns.deinit(std.testing.allocator);
    try columns.append(std.testing.allocator, .{ .name = "customer_id", .data_type = "INTEGER", .index = 1 });
    const source_entries = [_]CatalogEntry{
        .{
            .unique_id = "source.demo.raw.customers",
            .schema = "raw",
            .name = "customers",
            .relation_type = "BASE TABLE",
            .columns = columns,
        },
    };
    const rendered = try renderCatalog(std.testing.allocator, &.{}, &source_entries);
    defer std.testing.allocator.free(rendered);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rendered, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("nodes").?.object.count() == 0);
    const sources = parsed.value.object.get("sources").?.object;
    const raw_customers = sources.get("source.demo.raw.customers").?.object;
    try std.testing.expectEqualStrings("source.demo.raw.customers", raw_customers.get("unique_id").?.string);
    try std.testing.expectEqualStrings("raw", raw_customers.get("metadata").?.object.get("schema").?.string);
    try std.testing.expectEqualStrings("customers", raw_customers.get("metadata").?.object.get("name").?.string);
}
