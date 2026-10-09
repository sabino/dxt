const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");
const resource = @import("resource_config.zig");

pub const Expanded = struct { item: std.json.Value, name: []const u8, sql_name: []const u8, version: std.json.Value, latest: std.json.Value };
pub fn expand(allocator: std.mem.Allocator, item: std.json.Value) !std.ArrayList(Expanded) {
    const versions = values.get(item, "versions") orelse return error.InvalidModelVersion;
    if (versions != .array or versions.array.items.len == 0) return error.InvalidModelVersion;
    const name = try resource.string(values.get(item, "name") orelse return error.InvalidModelVersion);
    var latest = values.get(item, "latest_version") orelse .null;
    if (latest == .null) for (versions.array.items) |version| {
        const v = values.get(version, "v") orelse return error.InvalidModelVersion;
        if (latest == .null or try less(allocator, latest, v)) latest = v;
    };
    var result: std.ArrayList(Expanded) = .empty;
    errdefer deinit(allocator, &result);
    var found_latest = false;
    for (versions.array.items) |version| {
        const v = values.get(version, "v") orelse return error.InvalidModelVersion;
        if (v != .integer and v != .float and v != .string) return error.InvalidModelVersion;
        const text = try values.scalarText(allocator, v);
        defer allocator.free(text);
        for (result.items) |existing| if (try equal(allocator, existing.version, v)) return error.DuplicateModelVersion;
        if (try equal(allocator, latest, v)) found_latest = true;
        var merged = try values.clone(allocator, item);
        errdefer values.deinit(allocator, &merged);
        for ([_][]const u8{ "versions", "latest_version" }) |key| if (merged.object.fetchOrderedRemove(key)) |removed| {
            allocator.free(removed.key);
            var removed_value = removed.value;
            values.deinit(allocator, &removed_value);
        };
        var it = version.object.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, "v") or std.mem.eql(u8, entry.key_ptr.*, "defined_in") or std.mem.eql(u8, entry.key_ptr.*, "columns")) continue;
            if (std.mem.eql(u8, entry.key_ptr.*, "config")) {
                var config = if (values.get(merged, "config")) |base| try values.clone(allocator, base) else @as(std.json.Value, .null);
                defer values.deinit(allocator, &config);
                try resource.merge(allocator, &config, entry.value_ptr.*);
                try values.put(allocator, &merged, "config", config);
            } else try values.put(allocator, &merged, entry.key_ptr.*, entry.value_ptr.*);
        }
        if (values.get(version, "columns")) |columns| {
            var expanded_columns = try expandColumns(allocator, values.get(item, "columns") orelse .null, columns);
            defer values.deinit(allocator, &expanded_columns);
            try values.put(allocator, &merged, "columns", expanded_columns);
        }
        const sql_name = if (values.get(version, "defined_in")) |defined| try allocator.dupe(u8, try resource.string(defined)) else try std.fmt.allocPrint(allocator, "{s}_v{s}", .{ name, text });
        try result.append(allocator, .{ .item = merged, .name = name, .sql_name = sql_name, .version = v, .latest = latest });
    }
    if (!found_latest) return error.InvalidModelVersion;
    return result;
}
pub fn deinit(allocator: std.mem.Allocator, expanded: *std.ArrayList(Expanded)) void {
    for (expanded.items) |*item| {
        values.deinit(allocator, &item.item);
        allocator.free(item.sql_name);
    }
    expanded.deinit(allocator);
}
fn expandColumns(allocator: std.mem.Allocator, inherited: std.json.Value, authored: std.json.Value) !std.json.Value {
    if (authored != .array) return error.InvalidModelVersion;
    var out: std.json.Value = .{ .array = std.json.Array.init(allocator) };
    errdefer values.deinit(allocator, &out);
    var inclusion: ?std.json.Value = null;
    for (authored.array.items) |column| if (values.get(column, "include") != null) {
        if (inclusion != null) return error.InvalidModelVersion;
        inclusion = column;
    };
    const include = if (inclusion) |rule| values.get(rule, "include").? else @as(std.json.Value, .{ .string = "all" });
    const exclude = if (inclusion) |rule| values.get(rule, "exclude") orelse .null else @as(std.json.Value, .null);
    const include_all = include == .string and (std.mem.eql(u8, include.string, "all") or std.mem.eql(u8, include.string, "*"));
    if (!include_all and include != .array) return error.InvalidModelVersion;
    if (exclude != .null and (exclude != .array or (!include_all and exclude.array.items.len != 0))) return error.InvalidModelVersion;
    if (include == .array) for (include.array.items) |name| if (name != .string) return error.InvalidModelVersion;
    if (exclude == .array) for (exclude.array.items) |name| if (name != .string) return error.InvalidModelVersion;
    if (inherited == .array) for (inherited.array.items) |base| {
        const name = try resource.string(values.get(base, "name") orelse return error.InvalidModelVersion);
        if ((include_all or contains(include, name)) and !contains(exclude, name)) try out.array.append(try values.clone(allocator, base));
    };
    for (authored.array.items) |column| {
        if (values.get(column, "include") != null) continue;
        _ = try resource.string(values.get(column, "name") orelse return error.InvalidModelVersion);
        // Core appends explicit columns after inherited columns. The patch
        // writer replaces their metadata, while tests from both stay attached.
        try out.array.append(try values.clone(allocator, column));
    }
    return out;
}
fn contains(input: std.json.Value, name: []const u8) bool {
    if (input == .string) return std.mem.eql(u8, input.string, name);
    if (input == .array) for (input.array.items) |entry| if (entry == .string and std.mem.eql(u8, entry.string, name)) return true;
    return false;
}
pub fn equal(allocator: std.mem.Allocator, a: std.json.Value, b: std.json.Value) !bool {
    const left = try values.scalarText(allocator, a);
    defer allocator.free(left);
    const right = try values.scalarText(allocator, b);
    defer allocator.free(right);
    return std.mem.eql(u8, left, right);
}
pub fn less(allocator: std.mem.Allocator, a: std.json.Value, b: std.json.Value) !bool {
    const left = try values.scalarText(allocator, a);
    defer allocator.free(left);
    const right = try values.scalarText(allocator, b);
    defer allocator.free(right);
    if (std.fmt.parseFloat(f64, left)) |number| {
        if (std.fmt.parseFloat(f64, right)) |other| return number < other else |_| {}
    } else |_| {}
    return std.mem.lessThan(u8, left, right);
}

pub fn modelKwarg(allocator: std.mem.Allocator, node: *const types.Node) ![]u8 {
    if (node.version == .null) return std.fmt.allocPrint(allocator, "{{{{ get_where_subquery(ref('{s}')) }}}}", .{node.name});
    const version = try values.scalarText(allocator, node.version);
    defer allocator.free(version);
    return std.fmt.allocPrint(allocator, "{{{{ get_where_subquery(ref('{s}', version='{s}')) }}}}", .{ node.name, version });
}

pub fn assign(graph: *types.Graph, package: []const u8) !void {
    for (graph.model_properties.items) |*property| {
        if (!std.mem.eql(u8, property.package_name, package) or property.version == .null or property.assigned_unique_id != null) continue;
        for (graph.nodes.items) |*node| {
            if (!std.mem.eql(u8, node.package_name, package) or !std.mem.eql(u8, node.resource_type, "model")) continue;
            const latest_file = node.version == .null and try equal(graph.allocator, property.version, property.latest_version) and std.mem.eql(u8, node.name, property.logical_name orelse "");
            if (!std.mem.eql(u8, node.name, property.name) and !latest_file) continue;
            if (node.version != .null) return error.DuplicateModelVersion;
            node.name = property.logical_name orelse return error.InvalidModelVersion;
            node.version = try values.clone(graph.allocator, property.version);
            node.latest_version = try values.clone(graph.allocator, property.latest_version);
            const version = try values.scalarText(graph.allocator, node.version);
            defer graph.allocator.free(version);
            node.unique_id = try std.fmt.allocPrint(graph.allocator, "model.{s}.{s}.v{s}", .{ package, node.name, version });
            node.default_alias = try std.fmt.allocPrint(graph.allocator, "{s}_v{s}", .{ node.name, version });
            property.assigned_unique_id = node.unique_id;
            break;
        }
        if (property.assigned_unique_id == null) return error.UnresolvedModelVersion;
    }
}

test "model versions expand latest and column inheritance and reject inconsistent declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var document = try @import("yaml.zig").parse(allocator,
        \\name: orders
        \\columns: [{name: id}, {name: legacy}]
        \\versions:
        \\ - {v: 1}
        \\ - {v: 2, defined_in: custom_orders, columns: [{include: all, exclude: [legacy]}, {name: label}]}
    );
    defer document.deinit();
    var expanded = try expand(allocator, document.value);
    defer deinit(allocator, &expanded);
    try std.testing.expectEqual(@as(usize, 2), expanded.items.len);
    try std.testing.expectEqual(@as(i64, 2), expanded.items[0].latest.integer);
    try std.testing.expectEqualStrings("custom_orders", expanded.items[1].sql_name);
    const columns = values.get(expanded.items[1].item, "columns").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), columns.len);
    try std.testing.expectEqualStrings("id", values.get(columns[0], "name").?.string);
    try std.testing.expectEqualStrings("label", values.get(columns[1], "name").?.string);
    try values.put(allocator, &document.value, "latest_version", .{ .integer = 3 });
    try std.testing.expectError(error.InvalidModelVersion, expand(allocator, document.value));
}
