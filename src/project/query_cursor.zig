//! Translate original adapter cursor values without Agate's table coercions.
const std = @import("std");
const expr = @import("expression.zig");
const native = @import("adapter_value.zig");
const result = @import("adapter_result.zig");
const bytes = @import("yaml_values.zig");
const dates = @import("timestamp_context.zig");
const zones = @import("timezone_context.zig");
const Value = expr.Value;
const a_type = std.mem.Allocator;

pub fn value(a: a_type, cell: native.Cell) anyerror!Value {
    return switch (cell) {
        .none => .none,
        .boolean => |v| .{ .boolean = v },
        .integer => |v| .{ .integer = try a.dupe(u8, v) },
        .floating => |v| try expr.floatValue(a, v),
        .text => |v| .{ .string = try a.dupe(u8, v) },
        .binary => |v| try bytes.fromBytes(a, v),
        .memoryview => |v| try @import("query_memoryview.zig").value(a, v, 'c', null),
        .decimal => |v| try @import("decimal_value.zig").value(a, v),
        .date => |days| try dates.datetimeValue(a, @as(i96, days) * std.time.ns_per_day, true, null),
        .time => |clock| try @import("datetime_time.zig").value(a, clock.micros, if (clock.offset_us) |offset| try zones.builtinValue(a, offset, null) else null, 0),
        .timestamp => |stamp| blk: {
            var micros = stamp.micros;
            var zone: ?Value = null;
            var offset = stamp.offset_us;
            if (stamp.timezone) |name| {
                zone = try zones.timezoneValue(a, name, try zones.offsetAtUtc(name, @divFloor(micros, std.time.us_per_s)));
                offset = try expr.integerIndex(zone.?.attribute("__dxt_timezone_offset_us"));
                micros = std.math.add(i64, micros, offset.?) catch return error.InvalidDatetime;
            } else if (offset) |actual| {
                zone = try zones.builtinValue(a, actual, null);
                micros = std.math.add(i64, micros, actual) catch return error.InvalidDatetime;
            }
            break :blk try dates.datetimeValueWithOffsetUs(a, @as(i96, micros) * std.time.ns_per_us, false, offset, zone, 0);
        },
        .interval => |interval| try @import("modules_datetime.zig").durationValue(a, (@as(i96, interval.months) * 30 + interval.days) * std.time.us_per_day + interval.micros),
        .uuid => |text| try @import("query_uuid.zig").value(a, text),
        .list, .tuple => |members| blk: {
            const output = try expr.allocateValues(a, members.len);
            for (members, output) |member, *item| item.* = try value(a, member);
            break :blk if (cell == .tuple) .{ .tuple = output } else .{ .list = output };
        },
        .object => |fields| blk: {
            const output = try expr.allocateEntries(a, fields.len);
            for (fields, output) |field, *item| item.* = .{ .key = try a.dupe(u8, field.name), .value = try value(a, field.value) };
            break :blk .{ .object = output };
        },
        .range => |bounds| try @import("range_value.zig").value(a, switch (bounds.kind) {
            .numeric => "NumericRange",
            .date => "DateRange",
            .datetime => "DateTimeRange",
            .datetimetz => "DateTimeTZRange",
        }, if (bounds.lower) |lower| try value(a, lower.*) else .none, if (bounds.upper) |upper| try value(a, upper.*) else .none, bounds.bounds, bounds.empty),
        .map => |pairs| blk: {
            var output: std.ArrayList(expr.Entry) = .empty;
            const keys = try expr.allocateValues(a, pairs.len);
            const values = try expr.allocateValues(a, pairs.len);
            var dictionary = true;
            for (pairs, keys, values) |pair, *key, *item| {
                key.* = try value(a, pair.key);
                item.* = try value(a, pair.value);
                expr.hashableKey(key.*) catch {
                    dictionary = false;
                };
            }
            if (!dictionary) break :blk .{ .object = try a.dupe(expr.Entry, &.{
                .{ .key = "key", .value = .{ .list = keys } },
                .{ .key = "value", .value = .{ .list = values } },
            }) };
            for (keys, values) |key, item| try expr.mappingPut(a, &output, key, item);
            break :blk .{ .object = try output.toOwnedSlice(a) };
        },
    };
}

fn base64(a: a_type, input: []const u8) ![]const u8 {
    const encoded = try a.alloc(u8, std.base64.standard.Encoder.calcSize(input.len));
    _ = std.base64.standard.Encoder.encode(encoded, input);
    return encoded;
}

pub fn call(a: a_type, name: []const u8, args: []const expr.Argument) !?Value {
    if (try @import("query_memoryview.zig").call(a, name, args)) |memoryview| return memoryview;
    if (try @import("range_value.zig").call(name, args)) |range_bool| return range_bool;
    if (std.mem.startsWith(u8, name, "__dxt_cursor_type_primitive:")) {
        if (args.len != 1 or args[0].value != .string) return error.InvalidJinjaArguments;
        const attribute = args[0].value.string;
        if (std.mem.eql(u8, attribute, "children")) return error.DuckDbInvalidInput;
        if (!std.mem.eql(u8, attribute, "id")) return .undefined;
        const encoded = name["__dxt_cursor_type_primitive:".len..];
        const size = try std.base64.standard.Decoder.calcSizeForSlice(encoded);
        const text = try a.alloc(u8, size);
        try std.base64.standard.Decoder.decode(text, encoded);
        return .{ .string = text };
    }
    const as_bytes = std.mem.startsWith(u8, name, "__dxt_cursor_bytes:");
    const as_list = std.mem.startsWith(u8, name, "__dxt_cursor_list:");
    if (!as_bytes and !as_list) return null;
    if (args.len != 0) return error.InvalidJinjaArguments;
    const binary = try bytes.binary(a, name[if (as_bytes) 19 else 18..]);
    if (as_bytes) return binary;
    const raw = binary.attribute("__dxt_binary").string;
    const members = try expr.allocateValues(a, raw.len);
    for (raw, members) |byte, *member| member.* = try bytes.fromBytes(a, &.{byte});
    return .{ .list = members };
}

pub fn description(a: a_type, columns: []const result.Column, postgres: bool) anyerror!Value {
    const output = try expr.allocateValues(a, columns.len);
    for (columns, output) |column, *item| {
        var fields = [_]Value{ .{ .string = try a.dupe(u8, column.name) }, .none, .none, .none, .none, .none, .none };
        if (postgres) {
            const metadata = @import("postgres_cursor.zig").description(column.name, column.native_type, column.native_type_size, column.native_type_modifier);
            fields[1] = try expr.integerValue(a, metadata.type_code);
            if (metadata.internal_size) |size| fields[3] = try expr.integerValue(a, size);
            if (metadata.precision) |precision| fields[4] = try expr.integerValue(a, precision);
            if (metadata.scale) |scale| fields[5] = try expr.integerValue(a, scale);
        } else {
            fields[1] = try duckType(a, column.native_type_description orelse return error.NativeCursorMetadataMissing);
        }
        item.* = if (postgres) try @import("query_column.zig").value(a, &fields) else .{ .tuple = try a.dupe(Value, &fields) };
    }
    return .{ .tuple = output };
}

fn metadataField(cell: native.Cell, name: []const u8) !native.Cell {
    if (cell != .object) return error.NativeCursorMetadataMissing;
    for (cell.object) |item| if (std.mem.eql(u8, item.name, name)) return item.value;
    return error.NativeCursorMetadataMissing;
}

fn duckType(a: a_type, metadata: native.Cell) anyerror!Value {
    const type_name = try metadataField(metadata, "name");
    const identifier = try metadataField(metadata, "id");
    const children = try metadataField(metadata, "children");
    if (type_name != .text or identifier != .text) return error.NativeCursorMetadataMissing;
    var entries: std.ArrayList(expr.Entry) = .empty;
    try entries.appendSlice(a, &.{
        .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_duck_type", .value = .{ .callable = "__dxt_duck_type" } },
        .{ .key = "__dxt_rendered", .value = .{ .string = try a.dupe(u8, type_name.text) } },
        .{ .key = "__dxt_repr", .value = .{ .string = try a.dupe(u8, type_name.text) } },
        .{ .key = "id", .value = .{ .string = try a.dupe(u8, identifier.text) } },
    });
    if (children == .none) {
        try entries.append(a, .{ .key = "__dxt_getattr", .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_cursor_type_primitive:{s}", .{try base64(a, identifier.text)}) } });
    } else {
        if (children != .list) return error.NativeCursorMetadataMissing;
        const members = try expr.allocateValues(a, children.list.len);
        for (children.list, members) |pair, *member| {
            if (pair != .list or pair.list.len != 2 or pair.list[0] != .text) return error.NativeCursorMetadataMissing;
            const child = pair.list[1];
            member.* = .{ .tuple = try a.dupe(Value, &.{
                .{ .string = try a.dupe(u8, pair.list[0].text) },
                if (child == .object) try duckType(a, child) else try value(a, child),
            }) };
        }
        try entries.append(a, .{ .key = "children", .value = .{ .list = members } });
    }
    return .{ .object = try entries.toOwnedSlice(a) };
}
