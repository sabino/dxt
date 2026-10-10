//! DuckDB's chunk interface preserves length-delimited text and binary values.
//! Values returned by the C API are chunk-borrowed; public results own copies.
const std = @import("std");
const cursor = @import("adapter_value.zig");
pub const Handle = ?*anyopaque;
pub const Result = extern struct {
    column_count: u64 = 0,
    row_count: u64 = 0,
    rows_changed: u64 = 0,
    columns: Handle = null,
    error_message: Handle = null,
    internal_data: Handle = null,
};
pub const HugeInt = extern struct { lower: u64, upper: i64 };
pub const UHugeInt = extern struct { lower: u64, upper: u64 };
pub const Decimal = extern struct { width: u8, scale: u8, value: HugeInt };
pub const Date = extern struct { days: i32 };
pub const Time = extern struct { micros: i64 };
pub const TimeNs = extern struct { nanos: i64 };
pub const TimeTz = extern struct { bits: u64 };
pub const Timestamp = extern struct { micros: i64 };
pub const TimestampS = extern struct { seconds: i64 };
pub const TimestampMs = extern struct { millis: i64 };
pub const TimestampNs = extern struct { nanos: i64 };
pub const Interval = extern struct { months: i32, days: i32, micros: i64 };
pub const ListEntry = extern struct { offset: u64, length: u64 };
pub const String = extern struct { value: extern union {
    pointer: extern struct { length: u32, prefix: [4]u8, ptr: ?[*]u8 },
    inlined: extern struct { length: u32, data: [12]u8 },
} };
const Bit = extern struct { data: ?[*]u8, size: u64 };
const BigNum = extern struct { data: ?[*]u8, size: u64, is_negative: bool };
const TimeParts = extern struct { hour: i8, min: i8, sec: i8, micros: i32 };
const TimeTzParts = extern struct { time: TimeParts, offset: i32 };

pub const Api = struct {
    duckdb_fetch_chunk: *const fn (Result) callconv(.c) Handle,
    duckdb_destroy_data_chunk: *const fn (*Handle) callconv(.c) void,
    duckdb_data_chunk_get_size: *const fn (Handle) callconv(.c) u64,
    duckdb_data_chunk_get_vector: *const fn (Handle, u64) callconv(.c) Handle,
    duckdb_vector_get_data: *const fn (Handle) callconv(.c) Handle,
    duckdb_vector_get_validity: *const fn (Handle) callconv(.c) ?[*]u64,
    duckdb_column_logical_type: *const fn (*Result, u64) callconv(.c) Handle,
    duckdb_get_type_id: *const fn (Handle) callconv(.c) c_uint,
    duckdb_destroy_logical_type: *const fn (*Handle) callconv(.c) void,
    duckdb_string_t_length: *const fn (String) callconv(.c) u32,
    duckdb_string_t_data: *const fn (*String) callconv(.c) ?[*]const u8,
    duckdb_decimal_width: *const fn (Handle) callconv(.c) u8,
    duckdb_decimal_scale: *const fn (Handle) callconv(.c) u8,
    duckdb_decimal_internal_type: *const fn (Handle) callconv(.c) c_uint,
    duckdb_enum_internal_type: *const fn (Handle) callconv(.c) c_uint,
    duckdb_enum_dictionary_value: *const fn (Handle, u64) callconv(.c) ?[*:0]u8,
    duckdb_enum_dictionary_size: *const fn (Handle) callconv(.c) u32,
    duckdb_list_type_child_type: *const fn (Handle) callconv(.c) Handle,
    duckdb_list_vector_get_child: *const fn (Handle) callconv(.c) Handle,
    duckdb_array_type_child_type: *const fn (Handle) callconv(.c) Handle,
    duckdb_array_type_array_size: *const fn (Handle) callconv(.c) u64,
    duckdb_array_vector_get_child: *const fn (Handle) callconv(.c) Handle,
    duckdb_struct_type_child_count: *const fn (Handle) callconv(.c) u64,
    duckdb_struct_type_child_type: *const fn (Handle, u64) callconv(.c) Handle,
    duckdb_struct_type_child_name: *const fn (Handle, u64) callconv(.c) ?[*:0]u8,
    duckdb_struct_vector_get_child: *const fn (Handle, u64) callconv(.c) Handle,
    duckdb_map_type_key_type: *const fn (Handle) callconv(.c) Handle,
    duckdb_map_type_value_type: *const fn (Handle) callconv(.c) Handle,
    duckdb_union_type_member_type: *const fn (Handle, u64) callconv(.c) Handle,
    duckdb_union_type_member_count: *const fn (Handle) callconv(.c) u64,
    duckdb_union_type_member_name: *const fn (Handle, u64) callconv(.c) ?[*:0]u8,
    duckdb_logical_type_get_alias: *const fn (Handle) callconv(.c) ?[*:0]u8,
    duckdb_create_null_value: *const fn () callconv(.c) Handle,
    duckdb_create_bool: *const fn (bool) callconv(.c) Handle,
    duckdb_create_int8: *const fn (i8) callconv(.c) Handle,
    duckdb_create_int16: *const fn (i16) callconv(.c) Handle,
    duckdb_create_int32: *const fn (i32) callconv(.c) Handle,
    duckdb_create_int64: *const fn (i64) callconv(.c) Handle,
    duckdb_create_uint8: *const fn (u8) callconv(.c) Handle,
    duckdb_create_uint16: *const fn (u16) callconv(.c) Handle,
    duckdb_create_uint32: *const fn (u32) callconv(.c) Handle,
    duckdb_create_uint64: *const fn (u64) callconv(.c) Handle,
    duckdb_create_hugeint: *const fn (HugeInt) callconv(.c) Handle,
    duckdb_create_uhugeint: *const fn (UHugeInt) callconv(.c) Handle,
    duckdb_create_float: *const fn (f32) callconv(.c) Handle,
    duckdb_create_double: *const fn (f64) callconv(.c) Handle,
    duckdb_create_decimal: *const fn (Decimal) callconv(.c) Handle,
    duckdb_create_date: *const fn (Date) callconv(.c) Handle,
    duckdb_create_time: *const fn (Time) callconv(.c) Handle,
    duckdb_create_time_ns: *const fn (TimeNs) callconv(.c) Handle,
    duckdb_create_time_tz_value: *const fn (TimeTz) callconv(.c) Handle,
    duckdb_create_timestamp: *const fn (Timestamp) callconv(.c) Handle,
    duckdb_create_timestamp_tz: *const fn (Timestamp) callconv(.c) Handle,
    duckdb_create_timestamp_s: *const fn (TimestampS) callconv(.c) Handle,
    duckdb_create_timestamp_ms: *const fn (TimestampMs) callconv(.c) Handle,
    duckdb_create_timestamp_ns: *const fn (TimestampNs) callconv(.c) Handle,
    duckdb_create_interval: *const fn (Interval) callconv(.c) Handle,
    duckdb_create_uuid: *const fn (UHugeInt) callconv(.c) Handle,
    duckdb_create_blob: *const fn (?[*]const u8, u64) callconv(.c) Handle,
    duckdb_create_varchar_length: *const fn ([*]const u8, u64) callconv(.c) Handle,
    duckdb_create_bit: *const fn (Bit) callconv(.c) Handle,
    duckdb_create_bignum: *const fn (BigNum) callconv(.c) Handle,
    duckdb_create_list_value: *const fn (Handle, [*]Handle, u64) callconv(.c) Handle,
    duckdb_create_array_value: *const fn (Handle, [*]Handle, u64) callconv(.c) Handle,
    duckdb_create_struct_value: *const fn (Handle, [*]Handle) callconv(.c) Handle,
    duckdb_create_map_value: *const fn (Handle, [*]Handle, [*]Handle, u64) callconv(.c) Handle,
    duckdb_create_union_value: *const fn (Handle, u64, Handle) callconv(.c) Handle,
    duckdb_get_varchar: *const fn (Handle) callconv(.c) ?[*:0]u8,
    duckdb_destroy_value: *const fn (*Handle) callconv(.c) void,
    duckdb_from_time_tz: *const fn (TimeTz) callconv(.c) TimeTzParts,
    duckdb_free: *const fn (?*anyopaque) callconv(.c) void,

    pub fn load(dyn: *std.DynLib) !Api {
        var api: Api = undefined;
        inline for (std.meta.fields(Api)) |field| @field(api, field.name) = dyn.lookup(field.type, field.name ++ "\x00") orelse return error.NativeDuckDbAbiMismatch;
        return api;
    }
};

pub fn typeName(a: std.mem.Allocator, api: *const Api, logical: Handle) anyerror![]const u8 {
    if (api.duckdb_logical_type_get_alias(logical)) |alias| {
        defer api.duckdb_free(alias);
        if (std.mem.len(alias) != 0) return a.dupe(u8, std.mem.span(alias));
    }
    const id = api.duckdb_get_type_id(logical);
    const name: ?[]const u8 = switch (id) {
        1 => "BOOLEAN",
        2 => "TINYINT",
        3 => "SMALLINT",
        4 => "INTEGER",
        5 => "BIGINT",
        6 => "UTINYINT",
        7 => "USMALLINT",
        8 => "UINTEGER",
        9 => "UBIGINT",
        10 => "FLOAT",
        11 => "DOUBLE",
        12 => "TIMESTAMP",
        13 => "DATE",
        14 => "TIME",
        15 => "INTERVAL",
        16 => "HUGEINT",
        17 => "VARCHAR",
        18 => "BLOB",
        20 => "TIMESTAMP_S",
        21 => "TIMESTAMP_MS",
        22 => "TIMESTAMP_NS",
        27 => "UUID",
        29 => "BIT",
        30 => "TIME WITH TIME ZONE",
        31 => "TIMESTAMP WITH TIME ZONE",
        32 => "UHUGEINT",
        35 => "BIGNUM",
        36 => "INTEGER",
        39 => "TIME_NS",
        else => null,
    };
    if (name) |simple| return a.dupe(u8, simple);
    if (id == 19) return std.fmt.allocPrint(a, "DECIMAL({d},{d})", .{ api.duckdb_decimal_width(logical), api.duckdb_decimal_scale(logical) });
    if (id == 24 or id == 33) {
        var child = if (id == 33) api.duckdb_array_type_child_type(logical) else api.duckdb_list_type_child_type(logical);
        defer api.duckdb_destroy_logical_type(&child);
        const child_name = try typeName(a, api, child);
        defer a.free(child_name);
        return if (id == 33) std.fmt.allocPrint(a, "{s}[{d}]", .{ child_name, api.duckdb_array_type_array_size(logical) }) else std.fmt.allocPrint(a, "{s}[]", .{child_name});
    }
    if (id == 26) {
        var key = api.duckdb_map_type_key_type(logical);
        defer api.duckdb_destroy_logical_type(&key);
        var value = api.duckdb_map_type_value_type(logical);
        defer api.duckdb_destroy_logical_type(&value);
        const key_name = try typeName(a, api, key);
        defer a.free(key_name);
        const value_name = try typeName(a, api, value);
        defer a.free(value_name);
        return std.fmt.allocPrint(a, "MAP({s}, {s})", .{ key_name, value_name });
    }
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    if (id == 23) {
        try out.writer.writeAll("ENUM(");
        for (0..api.duckdb_enum_dictionary_size(logical)) |index| {
            if (index != 0) try out.writer.writeAll(", ");
            const label = api.duckdb_enum_dictionary_value(logical, index) orelse return error.InvalidDuckDbVector;
            defer api.duckdb_free(label);
            try out.writer.writeByte('\'');
            for (std.mem.span(label)) |byte| {
                if (byte == '\'') try out.writer.writeByte('\'');
                try out.writer.writeByte(byte);
            }
            try out.writer.writeByte('\'');
        }
    } else if (id == 25 or id == 28) {
        try out.writer.writeAll(if (id == 25) "STRUCT(" else "UNION(");
        const count = if (id == 25) api.duckdb_struct_type_child_count(logical) else api.duckdb_union_type_member_count(logical);
        for (0..count) |index| {
            if (index != 0) try out.writer.writeAll(", ");
            const field = (if (id == 25) api.duckdb_struct_type_child_name(logical, index) else api.duckdb_union_type_member_name(logical, index)) orelse return error.InvalidDuckDbVector;
            defer api.duckdb_free(field);
            const name_ = std.mem.span(field);
            var simple = name_.len != 0 and !@import("duckdb_keywords.zig").contains(name_);
            for (name_, 0..) |byte, i| if (!(std.ascii.isAlphanumeric(byte) or byte == '_') or (i == 0 and std.ascii.isDigit(byte))) {
                simple = false;
            };
            if (!simple) try out.writer.writeByte('"');
            for (name_) |byte| {
                if (!simple and byte == '"') try out.writer.writeByte('"');
                try out.writer.writeByte(byte);
            }
            if (!simple) try out.writer.writeByte('"');
            try out.writer.writeByte(' ');
            var child = if (id == 25) api.duckdb_struct_type_child_type(logical, index) else api.duckdb_union_type_member_type(logical, index);
            defer api.duckdb_destroy_logical_type(&child);
            const child_name = try typeName(a, api, child);
            defer a.free(child_name);
            try out.writer.writeAll(child_name);
        }
    } else return error.InvalidDuckDbVector;
    try out.writer.writeByte(')');
    return out.toOwnedSlice();
}

pub fn valid(api: *const Api, vector: Handle, row: u64) bool {
    const mask = api.duckdb_vector_get_validity(vector) orelse return true;
    return (mask[row / 64] & (@as(u64, 1) << @as(u6, @intCast(row % 64)))) != 0;
}

fn at(comptime T: type, api: *const Api, vector: Handle, row: u64) !T {
    const pointer: [*]const T = @ptrCast(@alignCast(api.duckdb_vector_get_data(vector) orelse return error.InvalidDuckDbVector));
    return pointer[row];
}

fn bytes(api: *const Api, vector: Handle, row: u64) ![]const u8 {
    const strings: [*]String = @ptrCast(@alignCast(api.duckdb_vector_get_data(vector) orelse return error.InvalidDuckDbVector));
    const string = &strings[row];
    const length = api.duckdb_string_t_length(string.*);
    const pointer = api.duckdb_string_t_data(string) orelse if (length == 0) return "" else return error.InvalidDuckDbVector;
    return pointer[0..length];
}

/// TIMESTAMP_TZ uses the actual connection's timezone formatter after copying
/// its signed microseconds. Every other value is copied before chunk release.
pub fn text(a: std.mem.Allocator, api: *const Api, logical: Handle, vector: Handle, row: u64) !?[]const u8 {
    if (!valid(api, vector, row)) return null;
    const id = api.duckdb_get_type_id(logical);
    if (id == 36) return null;
    if (id == 17) return try a.dupe(u8, try bytes(api, vector, row));
    if (id == 31) return try std.fmt.allocPrint(a, "{d}", .{try at(i64, api, vector, row)});
    return try valueText(a, api, logical, vector, row);
}
fn valueText(a: std.mem.Allocator, api: *const Api, logical: Handle, vector: Handle, row: u64) ![]const u8 {
    var value = try cell(a, api, logical, vector, row);
    defer api.duckdb_destroy_value(&value);
    const rendered = api.duckdb_get_varchar(value) orelse return error.InvalidDuckDbVector;
    defer api.duckdb_free(rendered);
    return try a.dupe(u8, std.mem.span(rendered));
}
fn timestampMicros(id: u32, raw: i64) i128 {
    return switch (id) {
        20 => @as(i128, raw) * std.time.us_per_s,
        21 => @as(i128, raw) * std.time.us_per_ms,
        22 => @divTrunc(raw, std.time.ns_per_us),
        else => raw,
    };
}
fn representableTimestamp(micros: i128) bool {
    return micros >= -62135596800000000 and micros <= 253402300799999999;
}

fn integer128(api: *const Api, vector: Handle, row: u64, id: u32) !i128 {
    return switch (id) {
        3 => try at(i16, api, vector, row),
        4 => try at(i32, api, vector, row),
        5 => try at(i64, api, vector, row),
        16 => blk: {
            const value = try at(HugeInt, api, vector, row);
            break :blk (@as(i128, value.upper) << 64) | value.lower;
        },
        else => error.InvalidDuckDbVector,
    };
}

fn cell(a: std.mem.Allocator, api: *const Api, logical: Handle, vector: Handle, row: u64) anyerror!Handle {
    if (!valid(api, vector, row)) return api.duckdb_create_null_value();
    const id = api.duckdb_get_type_id(logical);
    return switch (id) {
        1 => api.duckdb_create_bool(try at(bool, api, vector, row)),
        2 => api.duckdb_create_int8(try at(i8, api, vector, row)),
        3 => api.duckdb_create_int16(try at(i16, api, vector, row)),
        4 => api.duckdb_create_int32(try at(i32, api, vector, row)),
        5 => api.duckdb_create_int64(try at(i64, api, vector, row)),
        6 => api.duckdb_create_uint8(try at(u8, api, vector, row)),
        7 => api.duckdb_create_uint16(try at(u16, api, vector, row)),
        8 => api.duckdb_create_uint32(try at(u32, api, vector, row)),
        9 => api.duckdb_create_uint64(try at(u64, api, vector, row)),
        10 => api.duckdb_create_float(try at(f32, api, vector, row)),
        11 => api.duckdb_create_double(try at(f64, api, vector, row)),
        12 => api.duckdb_create_timestamp(.{ .micros = try at(i64, api, vector, row) }),
        13 => api.duckdb_create_date(.{ .days = try at(i32, api, vector, row) }),
        14 => api.duckdb_create_time(.{ .micros = try at(i64, api, vector, row) }),
        15 => api.duckdb_create_interval(try at(Interval, api, vector, row)),
        16 => api.duckdb_create_hugeint(try at(HugeInt, api, vector, row)),
        17 => blk: {
            const data = try bytes(api, vector, row);
            break :blk api.duckdb_create_varchar_length(data.ptr, data.len);
        },
        18 => blk: {
            const data = try bytes(api, vector, row);
            break :blk api.duckdb_create_blob(data.ptr, data.len);
        },
        19 => blk: {
            const coefficient = try integer128(api, vector, row, api.duckdb_decimal_internal_type(logical));
            break :blk api.duckdb_create_decimal(.{ .width = api.duckdb_decimal_width(logical), .scale = api.duckdb_decimal_scale(logical), .value = .{ .lower = @truncate(@as(u128, @bitCast(coefficient))), .upper = @intCast(coefficient >> 64) } });
        },
        20 => api.duckdb_create_timestamp_s(.{ .seconds = try at(i64, api, vector, row) }),
        21 => api.duckdb_create_timestamp_ms(.{ .millis = try at(i64, api, vector, row) }),
        22 => api.duckdb_create_timestamp_ns(.{ .nanos = try at(i64, api, vector, row) }),
        23 => blk: {
            const index: u64 = switch (api.duckdb_enum_internal_type(logical)) {
                6 => try at(u8, api, vector, row),
                7 => try at(u16, api, vector, row),
                8 => try at(u32, api, vector, row),
                else => return error.InvalidDuckDbVector,
            };
            const label = api.duckdb_enum_dictionary_value(logical, index) orelse return error.InvalidDuckDbVector;
            defer api.duckdb_free(label);
            break :blk api.duckdb_create_varchar_length(label, std.mem.len(label));
        },
        24, 26, 33 => try collection(a, api, logical, vector, row, id),
        25 => blk: {
            const count = api.duckdb_struct_type_child_count(logical);
            const values = try a.alloc(Handle, count);
            @memset(values, null);
            defer a.free(values);
            defer for (values) |*value| if (value.* != null) api.duckdb_destroy_value(value);
            for (values, 0..) |*value, index| {
                var child_type = api.duckdb_struct_type_child_type(logical, index);
                defer api.duckdb_destroy_logical_type(&child_type);
                value.* = try cell(a, api, child_type, api.duckdb_struct_vector_get_child(vector, index), row);
            }
            break :blk api.duckdb_create_struct_value(logical, values.ptr);
        },
        27 => blk: {
            const raw = try at(HugeInt, api, vector, row);
            break :blk api.duckdb_create_uuid(.{ .lower = raw.lower, .upper = @as(u64, @bitCast(raw.upper)) ^ (@as(u64, 1) << 63) });
        },
        28 => blk: {
            const tag = try at(u8, api, api.duckdb_struct_vector_get_child(vector, 0), row);
            var child_type = api.duckdb_union_type_member_type(logical, tag);
            defer api.duckdb_destroy_logical_type(&child_type);
            var value = try cell(a, api, child_type, api.duckdb_struct_vector_get_child(vector, @as(u64, tag) + 1), row);
            defer api.duckdb_destroy_value(&value);
            break :blk api.duckdb_create_union_value(logical, tag, value);
        },
        29 => blk: {
            const data = try bytes(api, vector, row);
            break :blk api.duckdb_create_bit(.{ .data = @constCast(data.ptr), .size = data.len });
        },
        30 => api.duckdb_create_time_tz_value(.{ .bits = try at(u64, api, vector, row) }),
        31 => api.duckdb_create_timestamp_tz(.{ .micros = try at(i64, api, vector, row) }),
        32 => api.duckdb_create_uhugeint(try at(UHugeInt, api, vector, row)),
        35 => blk: {
            const data = try bytes(api, vector, row);
            if (data.len < 3) return error.InvalidDuckDbVector;
            const negative = (data[0] & 128) == 0;
            const magnitude = try a.dupe(u8, data[3..]);
            defer a.free(magnitude);
            if (negative) for (magnitude) |*byte| {
                byte.* = ~byte.*;
            };
            break :blk api.duckdb_create_bignum(.{ .data = magnitude.ptr, .size = magnitude.len, .is_negative = negative });
        },
        36 => api.duckdb_create_null_value(),
        39 => api.duckdb_create_time_ns(.{ .nanos = try at(i64, api, vector, row) }),
        else => error.InvalidDuckDbVector,
    };
}

/// Preserve the DB-API value separately from the string/Agate projection.
pub fn native(a: std.mem.Allocator, api: *const Api, logical: Handle, vector: Handle, row: u64) anyerror!cursor.Cell {
    if (!valid(api, vector, row)) return .none;
    const id = api.duckdb_get_type_id(logical);
    return switch (id) {
        1 => .{ .boolean = try at(bool, api, vector, row) },
        2...9, 16, 32 => .{ .integer = (try text(a, api, logical, vector, row)).? },
        10 => .{ .floating = try at(f32, api, vector, row) },
        11 => .{ .floating = try at(f64, api, vector, row) },
        12, 20, 21, 22, 31 => blk: {
            const raw = try at(i64, api, vector, row);
            // DuckDB's Python cursor maps SQL infinity to naïve datetime
            // boundaries, including TIMESTAMPTZ under a non-UTC session.
            if (raw == std.math.maxInt(i64)) break :blk .{ .timestamp = .{ .micros = 253402300799999999 } };
            if (raw == -std.math.maxInt(i64)) break :blk .{ .timestamp = .{ .micros = -62135596800000000 } };
            const micros = timestampMicros(id, raw);
            // The stock cursor preserves finite dates outside Python's
            // representable years as the actual warehouse's formatted text.
            if (!representableTimestamp(micros)) break :blk .{ .text = try valueText(a, api, logical, vector, row) };
            break :blk .{ .timestamp = .{ .micros = @intCast(micros), .timezone = if (id == 31) try a.dupe(u8, "UTC") else null } };
        },
        13 => blk: {
            const raw = try at(i32, api, vector, row);
            if (raw == std.math.maxInt(i32)) break :blk .{ .date = 2932896 };
            if (raw == -std.math.maxInt(i32)) break :blk .{ .date = -719162 };
            if (raw < -719162 or raw > 2932896) break :blk .{ .text = try valueText(a, api, logical, vector, row) };
            break :blk .{ .date = raw };
        },
        14, 39 => .{ .time = .{ .micros = if (id == 39) @divTrunc(try at(i64, api, vector, row), std.time.ns_per_us) else try at(i64, api, vector, row) } },
        15 => blk: {
            const value = try at(Interval, api, vector, row);
            break :blk .{ .interval = .{ .months = value.months, .days = value.days, .micros = value.micros } };
        },
        17 => .{ .text = try a.dupe(u8, try bytes(api, vector, row)) },
        18 => .{ .binary = try a.dupe(u8, try bytes(api, vector, row)) },
        19 => .{ .decimal = (try text(a, api, logical, vector, row)).? },
        23, 29, 35 => .{ .text = (try text(a, api, logical, vector, row)).? },
        24, 26, 33 => blk: {
            const child = if (id == 33) api.duckdb_array_vector_get_child(vector) else api.duckdb_list_vector_get_child(vector);
            const entry = if (id == 33) size: {
                const length = api.duckdb_array_type_array_size(logical);
                break :size ListEntry{ .offset = row * length, .length = length };
            } else try at(ListEntry, api, vector, row);
            if (id == 26) {
                var key_type = api.duckdb_map_type_key_type(logical);
                defer api.duckdb_destroy_logical_type(&key_type);
                var value_type = api.duckdb_map_type_value_type(logical);
                defer api.duckdb_destroy_logical_type(&value_type);
                var result: cursor.Cell = .{ .map = try a.alloc(cursor.Pair, entry.length) };
                for (result.map) |*pair| pair.* = .{ .key = .none, .value = .none };
                errdefer result.deinit(a);
                for (result.map, 0..) |*pair, index| {
                    pair.key = try native(a, api, key_type, api.duckdb_struct_vector_get_child(child, 0), entry.offset + index);
                    pair.value = try native(a, api, value_type, api.duckdb_struct_vector_get_child(child, 1), entry.offset + index);
                }
                break :blk result;
            }
            var child_type = if (id == 33) api.duckdb_array_type_child_type(logical) else api.duckdb_list_type_child_type(logical);
            defer api.duckdb_destroy_logical_type(&child_type);
            var result: cursor.Cell = .{ .list = try a.alloc(cursor.Cell, entry.length) };
            @memset(result.list, .none);
            errdefer result.deinit(a);
            for (result.list, 0..) |*value, index| value.* = try native(a, api, child_type, child, entry.offset + index);
            if (id == 33) {
                const members = result.list;
                result = .{ .tuple = members };
            }
            break :blk result;
        },
        25 => blk: {
            var result: cursor.Cell = .{ .object = try a.alloc(cursor.Field, api.duckdb_struct_type_child_count(logical)) };
            for (result.object) |*field| field.* = .{ .name = "", .value = .none };
            errdefer result.deinit(a);
            for (result.object, 0..) |*field, index| {
                const name = api.duckdb_struct_type_child_name(logical, index) orelse return error.InvalidDuckDbVector;
                defer api.duckdb_free(name);
                field.name = try a.dupe(u8, std.mem.span(name));
                var child_type = api.duckdb_struct_type_child_type(logical, index);
                defer api.duckdb_destroy_logical_type(&child_type);
                field.value = try native(a, api, child_type, api.duckdb_struct_vector_get_child(vector, index), row);
            }
            break :blk result;
        },
        27 => .{ .uuid = (try text(a, api, logical, vector, row)).? },
        28 => blk: {
            const tag = try at(u8, api, api.duckdb_struct_vector_get_child(vector, 0), row);
            var child_type = api.duckdb_union_type_member_type(logical, tag);
            defer api.duckdb_destroy_logical_type(&child_type);
            break :blk try native(a, api, child_type, api.duckdb_struct_vector_get_child(vector, @as(u64, tag) + 1), row);
        },
        30 => blk: {
            const parts = api.duckdb_from_time_tz(.{ .bits = try at(u64, api, vector, row) });
            break :blk .{ .time = .{ .micros = (@as(i64, parts.time.hour) * 3600 + @as(i64, parts.time.min) * 60 + parts.time.sec) * std.time.us_per_s + parts.time.micros, .offset_us = @as(i64, parts.offset) * std.time.us_per_s } };
        },
        36 => .none,
        else => error.InvalidDuckDbVector,
    };
}

fn collection(a: std.mem.Allocator, api: *const Api, logical: Handle, vector: Handle, row: u64, id: u32) !Handle {
    var child_type = if (id == 33) api.duckdb_array_type_child_type(logical) else api.duckdb_list_type_child_type(logical);
    defer api.duckdb_destroy_logical_type(&child_type);
    const entry = if (id == 33) blk: {
        const size = api.duckdb_array_type_array_size(logical);
        break :blk ListEntry{ .offset = row * size, .length = size };
    } else try at(ListEntry, api, vector, row);
    const child = if (id == 33) api.duckdb_array_vector_get_child(vector) else api.duckdb_list_vector_get_child(vector);
    if (id == 26) {
        var key_type = api.duckdb_map_type_key_type(logical);
        defer api.duckdb_destroy_logical_type(&key_type);
        var value_type = api.duckdb_map_type_value_type(logical);
        defer api.duckdb_destroy_logical_type(&value_type);
        const keys = try a.alloc(Handle, entry.length);
        @memset(keys, null);
        defer a.free(keys);
        defer for (keys) |*value| if (value.* != null) api.duckdb_destroy_value(value);
        const values = try a.alloc(Handle, entry.length);
        @memset(values, null);
        defer a.free(values);
        defer for (values) |*value| if (value.* != null) api.duckdb_destroy_value(value);
        for (keys, values, 0..) |*key, *value, index| {
            key.* = try cell(a, api, key_type, api.duckdb_struct_vector_get_child(child, 0), entry.offset + index);
            value.* = try cell(a, api, value_type, api.duckdb_struct_vector_get_child(child, 1), entry.offset + index);
        }
        return api.duckdb_create_map_value(logical, keys.ptr, values.ptr, values.len);
    }
    const values = try a.alloc(Handle, entry.length);
    @memset(values, null);
    defer a.free(values);
    defer for (values) |*value| if (value.* != null) api.duckdb_destroy_value(value);
    for (values, 0..) |*value, index| value.* = try cell(a, api, child_type, child, entry.offset + index);
    return if (id == 33) api.duckdb_create_array_value(child_type, values.ptr, values.len) else api.duckdb_create_list_value(child_type, values.ptr, values.len);
}

test "DuckDB string and vector physical layouts retain C ABI alignment" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(String));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(String));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ListEntry));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Interval));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Result));
}

/// DuckDBPyType keeps an identifier and named children separate from SQL text.
pub fn typeDescription(a: std.mem.Allocator, api: *const Api, logical: Handle) anyerror!cursor.Cell {
    const id = api.duckdb_get_type_id(logical);
    const type_id: []const u8 = switch (id) {
        1 => "boolean",
        2 => "tinyint",
        3 => "smallint",
        4, 36 => "integer",
        5 => "bigint",
        6 => "utinyint",
        7 => "usmallint",
        8 => "uinteger",
        9 => "ubigint",
        10 => "float",
        11 => "double",
        12 => "timestamp",
        13 => "date",
        14 => "time",
        15 => "interval",
        16 => "hugeint",
        17 => "varchar",
        18 => "blob",
        19 => "decimal",
        20 => "timestamp_s",
        21 => "timestamp_ms",
        22 => "timestamp_ns",
        23 => "enum",
        24 => "list",
        25 => "struct",
        26 => "map",
        27 => "uuid",
        28 => "union",
        29 => "bit",
        30 => "time with time zone",
        31 => "timestamp with time zone",
        32 => "uhugeint",
        33 => "array",
        35 => "bignum",
        39 => "time_ns",
        else => return error.InvalidDuckDbVector,
    };
    var descriptor: cursor.Cell = .{ .object = try a.alloc(cursor.Field, 3) };
    for (descriptor.object) |*field| field.* = .{ .name = "", .value = .none };
    errdefer descriptor.deinit(a);
    for ([_][]const u8{ "name", "id", "children" }, descriptor.object) |name, *field| field.name = try a.dupe(u8, name);
    descriptor.object[0].value = .{ .text = try typeName(a, api, logical) };
    descriptor.object[1].value = .{ .text = try a.dupe(u8, type_id) };
    const count: usize = switch (id) {
        19, 26, 33 => 2,
        23, 24 => 1,
        25 => @intCast(api.duckdb_struct_type_child_count(logical)),
        28 => @intCast(api.duckdb_union_type_member_count(logical) + 1),
        else => return descriptor,
    };
    descriptor.object[2].value = .{ .list = try a.alloc(cursor.Cell, count) };
    @memset(descriptor.object[2].value.list, .none);
    for (descriptor.object[2].value.list, 0..) |*pair, index| {
        pair.* = .{ .list = try a.alloc(cursor.Cell, 2) };
        @memset(pair.list, .none);
        const label: []const u8 = switch (id) {
            19 => if (index == 0) "precision" else "scale",
            23 => "values",
            24 => "child",
            26 => if (index == 0) "key" else "value",
            33 => if (index == 0) "child" else "size",
            25, 28 => blk: {
                if (id == 28 and index == 0) break :blk try a.dupe(u8, "");
                const owned = (if (id == 25) api.duckdb_struct_type_child_name(logical, index) else api.duckdb_union_type_member_name(logical, index - 1)) orelse return error.InvalidDuckDbVector;
                defer api.duckdb_free(owned);
                break :blk try a.dupe(u8, std.mem.span(owned));
            },
            else => unreachable,
        };
        defer if (id == 25 or id == 28) a.free(label);
        pair.list[0] = .{ .text = try a.dupe(u8, label) };
        if (id == 19) {
            pair.list[1] = .{ .integer = try std.fmt.allocPrint(a, "{d}", .{if (index == 0) api.duckdb_decimal_width(logical) else api.duckdb_decimal_scale(logical)}) };
        } else if (id == 33 and index == 1) {
            pair.list[1] = .{ .integer = try std.fmt.allocPrint(a, "{d}", .{api.duckdb_array_type_array_size(logical)}) };
        } else if (id == 23) {
            pair.list[1] = .{ .list = try a.alloc(cursor.Cell, api.duckdb_enum_dictionary_size(logical)) };
            @memset(pair.list[1].list, .none);
            for (pair.list[1].list, 0..) |*member, enum_index| {
                const owned = api.duckdb_enum_dictionary_value(logical, enum_index) orelse return error.InvalidDuckDbVector;
                defer api.duckdb_free(owned);
                member.* = .{ .text = try a.dupe(u8, std.mem.span(owned)) };
            }
        } else if (id == 28 and index == 0) {
            pair.list[1] = .{ .object = try a.alloc(cursor.Field, 3) };
            for (pair.list[1].object) |*field| field.* = .{ .name = "", .value = .none };
            for ([_][]const u8{ "name", "id", "children" }, pair.list[1].object) |name, *field| field.name = try a.dupe(u8, name);
            pair.list[1].object[0].value = .{ .text = try a.dupe(u8, "UTINYINT") };
            pair.list[1].object[1].value = .{ .text = try a.dupe(u8, "utinyint") };
        } else {
            var child = switch (id) {
                24 => api.duckdb_list_type_child_type(logical),
                25 => api.duckdb_struct_type_child_type(logical, index),
                26 => if (index == 0) api.duckdb_map_type_key_type(logical) else api.duckdb_map_type_value_type(logical),
                28 => api.duckdb_union_type_member_type(logical, index - 1),
                33 => api.duckdb_array_type_child_type(logical),
                else => unreachable,
            };
            defer api.duckdb_destroy_logical_type(&child);
            pair.list[1] = try typeDescription(a, api, child);
        }
    }
    return descriptor;
}

test "finite timestamp cursor fallback uses Python date boundaries without overflow" {
    try std.testing.expect(representableTimestamp(-62135596800000000));
    try std.testing.expect(representableTimestamp(253402300799999999));
    try std.testing.expect(!representableTimestamp(-62135596800000001));
    try std.testing.expect(!representableTimestamp(253402300800000000));
    try std.testing.expect(!representableTimestamp(timestampMicros(20, std.math.maxInt(i64) - 1)));
}
