//! Native adapter column metadata for SQL queries. DuckDB describes and flattens
//! STRUCT fields; PostgreSQL uses cursor OIDs and Core's connection type labels.
const std = @import("std");
const types = @import("types.zig");
const adapter = @import("adapter.zig");
const contexts = @import("dbt_context.zig");
const expression = @import("expression.zig");

pub fn columns(allocator: std.mem.Allocator, runtime: types.Runtime, graph: *const types.Graph, db_path: []const u8, sql: []const u8) !expression.Value {
    const describe = std.mem.eql(u8, graph.adapter_type, "duckdb");
    const statement = if (describe) try std.fmt.allocPrint(allocator, "DESCRIBE ({s})", .{std.mem.trimEnd(u8, sql, " \t\r\n;")}) else sql;
    var result = try adapter.queryForGraph(runtime, graph, db_path, statement);
    defer result.deinit(runtime.allocator);
    var output: std.ArrayList(expression.Value) = .empty;
    if (describe) {
        for (result.rows) |row| {
            if (row.len < 2 or row[0] == null or row[1] == null) return error.InvalidAdapterIntrospection;
            const flattened = try contexts.flattenColumn(allocator, .{ .adapter_type = "duckdb", .column = try allocator.dupe(u8, row[0].?), .dtype = try allocator.dupe(u8, row[1].?) });
            try output.appendSlice(allocator, flattened.list);
        }
    } else {
        for (result.columns) |column| {
            const label = typeLabel(column.native_type) orelse try std.fmt.allocPrint(allocator, "unknown type_code {d}", .{column.native_type});
            try output.append(allocator, try contexts.columnValue(allocator, .{ .adapter_type = graph.adapter_type, .column = try allocator.dupe(u8, column.name), .dtype = if (std.mem.eql(u8, label, "STRING")) "TEXT" else label }));
        }
    }
    return .{ .list = if (output.items.len == 0) try expression.allocateValues(allocator, 0) else try output.toOwnedSlice(allocator) };
}

fn typeLabel(oid: u32) ?[]const u8 {
    return switch (oid) {
        16 => "BOOLEAN",
        17 => "BINARY",
        18, 19, 25, 1042, 1043 => "STRING",
        20 => "LONGINTEGER",
        21, 23 => "INTEGER",
        26 => "ROWID",
        114 => "JSON",
        199 => "JSONARRAY",
        651 => "CIDRARRAY",
        700, 701 => "FLOAT",
        704, 1186 => "INTERVAL",
        705 => "UNKNOWN",
        1000 => "BOOLEANARRAY",
        1001 => "BINARYARRAY",
        1002, 1003, 1009, 1014, 1015 => "STRINGARRAY",
        1005, 1006, 1007 => "INTEGERARRAY",
        1013, 1028 => "ROWIDARRAY",
        1016 => "LONGINTEGERARRAY",
        1021, 1022 => "FLOATARRAY",
        1040 => "MACADDRARRAY",
        1041 => "INETARRAY",
        1082 => "DATE",
        1083, 1266 => "TIME",
        1114 => "DATETIME",
        1115 => "DATETIMEARRAY",
        1182 => "DATEARRAY",
        1183, 1270 => "TIMEARRAY",
        1184 => "DATETIMETZ",
        1185 => "DATETIMETZARRAY",
        1187 => "INTERVALARRAY",
        1231 => "DECIMALARRAY",
        1700 => "DECIMAL",
        3802 => "JSONB",
        3807 => "JSONBARRAY",
        3904, 3906, 3926 => "type",
        3905, 3907, 3927 => "typeARRAY",
        3908 => "tsrange",
        3909 => "tsrangeARRAY",
        3910 => "tstzrange",
        3911 => "tstzrangeARRAY",
        3912 => "daterange",
        3913 => "daterangeARRAY",
        else => null,
    };
}
