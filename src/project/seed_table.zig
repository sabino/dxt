//! Typed CSV input for the real bundled seed helpers and native query bindings.
const std = @import("std");
const types = @import("types.zig");
const expr = @import("expression.zig");
const csv = @import("seed_csv.zig");
const config = @import("config_value.zig");
const parameters = @import("query_parameters.zig");
const timestamp = @import("timestamp_context.zig");
const Value = expr.Value;

pub const Data = struct { names: []const Value, rows: []const []const Value, kinds: []const Value, original_abspath: []const u8 };

pub fn load(a: std.mem.Allocator, node: *const types.Node) !Data {
    if (!std.mem.eql(u8, node.resource_type, "seed")) return error.LoadAgateTableRequiresSeed;
    const delimiter = config.get(node.effective_config, "delimiter") orelse std.json.Value{ .string = "," };
    if (delimiter != .string) return error.InvalidSeedDelimiter;
    var document = try csv.parseWithDelimiter(a, node.raw_code, delimiter.string);
    defer document.deinit();
    const names = try expr.allocateValues(a, document.headers.len);
    const kinds = try expr.allocateValues(a, document.headers.len);
    for (document.headers, names, kinds, 0..) |header, *name, *kind, index| {
        name.* = .{ .string = try a.dupe(u8, header) };
        var overridden = false;
        for (node.seed_column_types.items) |column| if (std.mem.eql(u8, header, column.name)) {
            overridden = true;
            break;
        };
        kind.* = .{ .string = @tagName(if (overridden) csv.Kind.text else try csv.infer(a, document.rows, index)) };
    }
    const rows = try a.alloc([]const Value, document.rows.len);
    for (document.rows, rows) |raw, *row| {
        const cells = try expr.allocateValues(a, names.len);
        for (raw, kinds, cells) |text, kind, *cell| cell.* = try csvValue(a, text, kind.string);
        row.* = cells;
    }
    return .{ .names = names, .rows = rows, .kinds = kinds, .original_abspath = try std.fs.path.join(a, &.{ node.project_root orelse return error.SeedProjectRootRequired, node.original_file_path }) };
}

fn csvValue(a: std.mem.Allocator, raw: []const u8, kind: []const u8) !Value {
    if (csv.isNull(raw)) return .none;
    if (std.mem.eql(u8, kind, "text")) return .{ .string = try a.dupe(u8, raw) };
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, kind, "boolean")) return .{ .boolean = std.ascii.eqlIgnoreCase(text, "true") };
    if (std.mem.eql(u8, kind, "integer") or std.mem.eql(u8, kind, "number")) {
        const numeric = try csv.number(a, text);
        const base = try expr.floatValue(a, std.fmt.parseFloat(f64, numeric) catch return error.InvalidSeedNumber);
        const fields = try expr.allocateEntries(a, base.object.len + 2);
        @memcpy(fields[0..base.object.len], base.object);
        fields[base.object.len] = .{ .key = "__dxt_query_parameter", .value = .{ .callable = "__dxt_query_parameter" } };
        fields[base.object.len + 1] = .{ .key = "__dxt_bound_decimal", .value = .{ .string = numeric } };
        return .{ .object = fields };
    }
    const date_only = std.mem.eql(u8, kind, "date");
    const parsed = if (date_only) try @import("seed_datetime.zig").date(a, text) else @import("seed_datetime.zig").standard(a, text) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        break :blk try @import("seed_datetime.zig").iso(a, text);
    };
    return try timestamp.datetimeValueWithOffsetUs(a, parsed.civil_ns, date_only, parsed.offset_us, null, 0);
}

pub fn parameter(value: Value) !parameters.Parameter {
    if (value.attribute("__dxt_query_parameter") == .callable and std.mem.eql(u8, value.attribute("__dxt_query_parameter").callable, "__dxt_query_parameter")) {
        const decimal = value.attribute("__dxt_bound_decimal");
        if (decimal != .string) return error.InvalidQueryParameter;
        return .{ .decimal = decimal.string };
    }
    if (timestamp.state(value)) |state| {
        if (state.date_only) return .{ .date = @intCast(@divFloor(state.civil_ns, std.time.ns_per_day)) };
        const micros: i64 = @intCast(@divTrunc(state.civil_ns, std.time.ns_per_us));
        return if (state.offset_us) |offset| .{ .timestamp_tz = micros - offset } else .{ .timestamp = micros };
    }
    if (@import("datetime_time.zig").state(value)) |state| return .{ .time = state.micros };
    const decoder = value.attribute("decode");
    if (value.attribute("__dxt_binary") == .string and decoder == .callable and std.mem.startsWith(u8, decoder.callable, "__dxt_yaml_bytes_decode:")) return .{ .binary = value.attribute("__dxt_binary").string };
    if (expr.integerProtocol(value)) |integer| return .{ .integer = integer };
    if (expr.floatProtocol(value)) |float| return .{ .floating = float };
    return switch (value) {
        .none => .none,
        .boolean => |v| .{ .boolean = v },
        .integer => |v| .{ .integer = v },
        .number => |v| .{ .floating = v },
        .string => |v| .{ .text = v },
        else => error.InvalidQueryParameter,
    };
}

pub fn isTable(value: Value) bool {
    const marker = value.attribute("__dxt_seed_table");
    return marker == .callable and std.mem.eql(u8, marker.callable, "__dxt_seed_table");
}

pub fn sqlType(value: Value, index: usize) ![]const u8 {
    if (!isTable(value)) return error.InvalidAgateTable;
    const kinds = expr.sequence(value.attribute("__dxt_seed_kinds")) orelse return error.InvalidAgateTable;
    if (index >= kinds.len) return error.JinjaIndexError;
    const kind = kinds[index];
    if (kind != .string) return error.InvalidAgateTable;
    const names = [_][]const u8{ "integer", "number", "date", "timestamp", "boolean", "text" };
    const types_ = [_][]const u8{ "integer", "float8", "date", "timestamp without time zone", "boolean", "text" };
    for (names, types_) |name, sql| if (std.mem.eql(u8, name, kind.string)) return sql;
    return error.InvalidAgateTable;
}

test "seed table retains exact Decimal bindings, text overrides and native temporal nulls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var node = types.Node{ .package_name = "demo", .unique_id = "seed.demo.input", .name = "input", .resource_type = "seed", .path = "input.csv", .original_file_path = "seeds/input.csv", .project_root = "project", .raw_code = "code,amount,day\n001,0.123456789012345678901,2024-02-29\n002,,\n" };
    try node.seed_column_types.append(a, .{ .name = "code", .data_type = "text" });
    const table = try load(a, &node);
    try std.testing.expectEqualStrings("001", table.rows[0][0].string);
    try std.testing.expectEqualStrings("0.123456789012345678901", (try parameter(table.rows[0][1])).decimal);
    try std.testing.expectEqual(@as(i32, 19782), (try parameter(table.rows[0][2])).date);
    try std.testing.expect((try parameter(table.rows[1][1])) == .none);
    try std.testing.expect((try parameter(table.rows[1][2])) == .none);
    try std.testing.expectEqualStrings("project/seeds/input.csv", table.original_abspath);
    try std.testing.expectError(error.InvalidQueryParameter, parameter(.{ .object = &.{.{ .key = "__dxt_bound_decimal", .value = .{ .string = "1" } }} }));
}
