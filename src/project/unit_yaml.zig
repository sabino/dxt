//! dbt Core unit definitions and fixture discovery, decoded by shared YAML.
const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");
const fs = @import("fs.zig");
const yaml = @import("yaml.zig");
const csv = @import("seed_csv.zig");

pub fn parse(allocator: std.mem.Allocator, text: []const u8, root: []const u8, path: []const u8, package: []const u8, graph: *types.Graph) !void {
    var document = try yaml.parse(allocator, text);
    defer document.deinit();
    const definitions = values.get(document.value, "unit_tests") orelse return;
    if (definitions != .array) return error.InvalidUnitTestDefinition;
    for (definitions.array.items) |item| {
        if (item != .object) return error.InvalidUnitTestDefinition;
        var unit = types.UnitTestDef{
            .package_name = package,
            .name = try string(allocator, values.get(item, "name") orelse return error.InvalidUnitTestDefinition),
            .model = try string(allocator, values.get(item, "model") orelse return error.InvalidUnitTestDefinition),
            .path = fs.relativeUnderResourcePath(path, root),
            .original_file_path = path,
        };
        errdefer types.deinitUnitTestDef(allocator, &unit);
        if (unit.name.len == 0 or unit.model.len == 0) return error.InvalidUnitTestDefinition;
        unit.unique_id = try std.fmt.allocPrint(allocator, "unit_test.{s}.{s}.{s}", .{ package, unit.model, unit.name });
        if (values.get(item, "description")) |description| unit.description = try string(allocator, description);
        if (values.get(item, "overrides")) |overrides| {
            if (overrides != .null and overrides != .object) return error.InvalidUnitTestOverrides;
            if (overrides == .object) {
                var it = overrides.object.iterator();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    if (!std.mem.eql(u8, key, "macros") and !std.mem.eql(u8, key, "vars") and !std.mem.eql(u8, key, "env_vars")) return error.InvalidUnitTestOverrides;
                    if (entry.value_ptr.* != .object) return error.InvalidUnitTestOverrides;
                }
            }
            unit.overrides = try values.clone(allocator, overrides);
            if (unit.overrides == .object) for ([_][]const u8{ "macros", "vars", "env_vars" }) |category| {
                if (values.get(unit.overrides, category) == null) try values.put(allocator, &unit.overrides, category, .{ .object = .empty });
            };
        }
        if (values.get(item, "versions")) |versions| {
            if (versions != .null and versions != .object) return error.InvalidUnitTestVersions;
            unit.versions = try values.clone(allocator, versions);
            if (unit.versions == .object) for ([_][]const u8{ "include", "exclude" }) |category| {
                if (values.get(unit.versions, category) == null) try values.put(allocator, &unit.versions, category, .null);
            };
        }
        if (values.get(item, "config")) |config| {
            if (config != .object) return error.InvalidUnitTestDefinition;
            unit.config_values = try values.clone(allocator, config);
            if (values.get(config, "enabled")) |enabled| {
                if (enabled != .bool) return error.InvalidUnitTestDefinition;
                unit.enabled = enabled.bool;
            }
            if (values.get(config, "tags")) |tags| {
                if (tags == .string) try unit.tags.append(allocator, try string(allocator, tags)) else if (tags == .array) {
                    for (tags.array.items) |tag| try unit.tags.append(allocator, try string(allocator, tag));
                } else return error.InvalidUnitTestDefinition;
            }
            if (values.get(config, "meta")) |meta| {
                if (meta != .object) return error.InvalidUnitTestDefinition;
                var it = meta.object.iterator();
                while (it.next()) |entry| if (entry.value_ptr.* != .array and entry.value_ptr.* != .object) try unit.meta.append(allocator, .{ .key = try allocator.dupe(u8, entry.key_ptr.*), .value = try scalar(allocator, entry.value_ptr.*) });
            }
        }
        @import("util.zig").sortStrings(unit.tags.items);
        const given = values.get(item, "given") orelse return error.InvalidUnitTestDefinition;
        if (given != .array) return error.InvalidUnitTestDefinition;
        for (given.array.items) |input| {
            var fixture = try parseFixture(allocator, input);
            fixture.input = try string(allocator, values.get(input, "input") orelse return error.InvalidUnitTestDefinition);
            try unit.given.append(allocator, fixture);
        }
        unit.expect = try parseFixture(allocator, values.get(item, "expect") orelse return error.InvalidUnitTestDefinition);
        try graph.unit_tests.append(allocator, unit);
    }
}

fn string(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidUnitTestDefinition;
    return try allocator.dupe(u8, value.string);
}
fn scalar(allocator: std.mem.Allocator, value: std.json.Value) !types.JsonScalar {
    return .{ .text = if (value == .array or value == .object) try std.json.Stringify.valueAlloc(allocator, value, .{}) else try values.scalarText(allocator, value), .kind = switch (value) {
        .string => .string,
        .bool => .bool,
        .null => .null,
        .integer, .float, .number_string => .number,
        .array, .object => .json,
    } };
}
fn parseFixture(allocator: std.mem.Allocator, item: std.json.Value) !types.UnitTestFixture {
    if (item != .object) return error.InvalidUnitTestFixture;
    var fixture: types.UnitTestFixture = .{};
    if (values.get(item, "format")) |format| fixture.format = try string(allocator, format);
    if (!std.mem.eql(u8, fixture.format, "dict") and !std.mem.eql(u8, fixture.format, "csv") and !std.mem.eql(u8, fixture.format, "sql")) return error.InvalidUnitTestFixture;
    if (values.get(item, "fixture")) |name| if (name != .null) {
        fixture.fixture = try string(allocator, name);
    };
    if (values.get(item, "rows")) |rows| {
        if (fixture.fixture != null) return error.InvalidUnitTestFixture;
        fixture.rows_set = true;
        if (std.mem.eql(u8, fixture.format, "dict")) {
            if (rows != .array) return error.InvalidUnitTestFixture;
            for (rows.array.items) |row| {
                if (row != .object) return error.InvalidUnitTestFixture;
                var result: types.UnitTestRow = .{};
                var it = row.object.iterator();
                while (it.next()) |entry| try result.entries.append(allocator, .{ .key = try allocator.dupe(u8, entry.key_ptr.*), .value = try scalar(allocator, entry.value_ptr.*) });
                try fixture.rows.append(allocator, result);
            }
        } else {
            const raw = try string(allocator, rows);
            if (std.mem.eql(u8, fixture.format, "csv")) try csvRows(allocator, raw, &fixture) else fixture.rows_string = std.mem.trim(u8, raw, " \t\r\n");
        }
    } else if (fixture.fixture == null) return error.InvalidUnitTestFixture;
    if (fixture.fixture != null and std.mem.eql(u8, fixture.format, "dict")) return error.InvalidUnitTestFixture;
    promoteNonNullRow(&fixture);
    return fixture;
}
fn promoteNonNullRow(fixture: *types.UnitTestFixture) void {
    for (fixture.rows.items, 0..) |row, i| {
        var all_non_null = true;
        for (row.entries.items) |entry| if (entry.value.kind == .null) {
            all_non_null = false;
            break;
        };
        if (all_non_null) {
            std.mem.swap(types.UnitTestRow, &fixture.rows.items[0], &fixture.rows.items[i]);
            break;
        }
    }
}
pub fn csvRows(allocator: std.mem.Allocator, raw: []const u8, fixture: *types.UnitTestFixture) !void {
    var document = try csv.parseUnitFixture(allocator, raw);
    defer document.deinit();
    for (document.rows) |row| {
        var result: types.UnitTestRow = .{};
        for (document.headers, row) |header, field| {
            const cell = types.JsonScalar{ .text = if (field.len == 0) "null" else try allocator.dupe(u8, field), .kind = if (field.len == 0) .null else .string };
            var duplicate = false;
            for (result.entries.items) |*entry| if (std.mem.eql(u8, entry.key, header)) {
                entry.value = cell;
                duplicate = true;
                break;
            };
            if (!duplicate) try result.entries.append(allocator, .{ .key = try allocator.dupe(u8, header), .value = cell });
        }
        try fixture.rows.append(allocator, result);
    }
    fixture.rows_set = true;
    promoteNonNullRow(fixture);
}

pub fn loadFixtures(runtime: types.Runtime, project: []const u8, package: []const u8, test_paths: []const []const u8, graph: *types.Graph) !void {
    var files: std.StringHashMap([]const u8) = .init(runtime.allocator);
    defer files.deinit();
    for (test_paths) |test_path| {
        const relative = try fs.pathJoin(runtime.allocator, &.{ test_path, "fixtures" });
        defer runtime.allocator.free(relative);
        const root = try fs.pathJoin(runtime.allocator, &.{ project, relative });
        defer runtime.allocator.free(root);
        var sql: std.ArrayList([]const u8) = .empty;
        defer sql.deinit(runtime.allocator);
        var csvs: std.ArrayList([]const u8) = .empty;
        defer csvs.deinit(runtime.allocator);
        var yml: std.ArrayList([]const u8) = .empty;
        defer yml.deinit(runtime.allocator);
        var md: std.ArrayList([]const u8) = .empty;
        defer md.deinit(runtime.allocator);
        fs.discoverProjectFiles(runtime, root, relative, &sql, &yml, &md) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        try fs.discoverSeedFiles(runtime, root, relative, &csvs);
        try sql.appendSlice(runtime.allocator, csvs.items);
        for (sql.items) |path| {
            const basename = std.fs.path.basename(path);
            const name = basename[0 .. basename.len - 4];
            if (files.contains(name)) return error.DuplicateUnitTestFixture;
            try files.put(try runtime.allocator.dupe(u8, name), path);
        }
    }
    for (graph.unit_tests.items) |*unit| {
        if (!std.mem.eql(u8, unit.package_name, package)) continue;
        for (unit.given.items) |*fixture| try loadFixture(runtime, project, &files, fixture);
        try loadFixture(runtime, project, &files, &unit.expect);
    }
}
fn loadFixture(runtime: types.Runtime, project: []const u8, files: *const std.StringHashMap([]const u8), fixture: *types.UnitTestFixture) !void {
    const name = fixture.fixture orelse return;
    if (fixture.rows_set) return;
    const path = files.get(name) orelse return error.UnitTestFixtureNotFound;
    if (!std.mem.endsWith(u8, path, if (std.mem.eql(u8, fixture.format, "csv")) ".csv" else ".sql")) return error.InvalidUnitTestFixture;
    const absolute = try fs.pathJoin(runtime.allocator, &.{ project, path });
    defer runtime.allocator.free(absolute);
    const text = try std.Io.Dir.cwd().readFileAlloc(runtime.io, absolute, runtime.allocator, .limited(4 * 1024 * 1024));
    if (std.mem.eql(u8, fixture.format, "csv")) {
        defer runtime.allocator.free(text);
        try csvRows(runtime.allocator, text, fixture);
    } else fixture.rows_string = std.mem.trim(u8, text, " \t\r\n");
    fixture.rows_set = true;
}

test "unit YAML preserves sparse rows, block SQL, CSV strings and typed overrides" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph: types.Graph = .{ .allocator = a, .project_name = "demo" };
    defer graph.deinit();
    try parse(a,
        \\unit_tests:
        \\  - name: check
        \\    model: final
        \\    overrides: {macros: {marker: [1, true]}, vars: {count: 11}, env_vars: {UNIT_VALUE: override}}
        \\    given:
        \\      - input: ref('base')
        \\        rows: [{id: 2}, {note: only}]
        \\      - input: ref('sql_base')
        \\        format: sql
        \\        rows: |
        \\          select 3 as id
        \\    expect: {rows: [{id: 2}, {id: null}]}
    , "models", "models/schema.yml", "demo", &graph);
    const unit = graph.unit_tests.items[0];
    try std.testing.expectEqual(@as(i64, 11), values.get(values.get(unit.overrides, "vars").?, "count").?.integer);
    try std.testing.expectEqualStrings("note", unit.given.items[0].rows.items[1].entries.items[0].key);
    try std.testing.expectEqualStrings("select 3 as id", unit.given.items[1].rows_string.?);
    var fixture: types.UnitTestFixture = .{ .format = "csv" };
    try csvRows(a, "id,note\n2,\n", &fixture);
    try std.testing.expectEqual(@as(@TypeOf(fixture.rows.items[0].entries.items[0].value.kind), .string), fixture.rows.items[0].entries.items[0].value.kind);
    try std.testing.expectEqual(@as(@TypeOf(fixture.rows.items[0].entries.items[1].value.kind), .null), fixture.rows.items[0].entries.items[1].value.kind);
}

test "unit CSV follows duplicate-header and short-row DictReader semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fixture: types.UnitTestFixture = .{ .format = "csv" };
    try csvRows(a, "id,id,note\n1,2,label\n3,4\n", &fixture);
    try std.testing.expectEqual(@as(usize, 2), fixture.rows.items[0].entries.items.len);
    try std.testing.expectEqualStrings("2", fixture.rows.items[0].entries.items[0].value.text);
    try std.testing.expectEqual(@as(@TypeOf(fixture.rows.items[1].entries.items[1].value.kind), .null), fixture.rows.items[1].entries.items[1].value.kind);
}
