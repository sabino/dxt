//! Portable native seeds. Contract: dbt Core 1.10.5 context/providers.py
//! load_agate_table, dbt_common clients/agate_helper.py build_type_tester,
//! SQLAdapter.convert_*_type, and global_project seeds/helpers.sql.
const std = @import("std");
const types = @import("types.zig");
const compiler = @import("compiler.zig");
const adapter = @import("adapter_result.zig");
const values = @import("config_value.zig");
const freshness = @import("source_freshness.zig");

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    headers: []const []const u8,
    rows: []const []const []const u8,
    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn parse(allocator: std.mem.Allocator, raw_csv: []const u8) !Document {
    return parseWithDelimiter(allocator, raw_csv, ",");
}

pub fn parseUnitFixture(allocator: std.mem.Allocator, raw_csv: []const u8) !Document {
    return parseNative(allocator, raw_csv, ",", true);
}
pub fn parseWithDelimiter(allocator: std.mem.Allocator, raw_csv: []const u8, delimiter: []const u8) !Document {
    return parseNative(allocator, raw_csv, delimiter, false);
}
fn parseNative(allocator: std.mem.Allocator, raw_csv: []const u8, delimiter: []const u8, unit_fixture: bool) !Document {
    if (delimiter.len == 0 or std.mem.indexOfAny(u8, delimiter, "\r\n\"") != null or !std.unicode.utf8ValidateSlice(delimiter)) return error.InvalidSeedDelimiter;
    var codepoints = std.unicode.Utf8View.initUnchecked(delimiter).iterator();
    _ = codepoints.nextCodepoint() orelse return error.InvalidSeedDelimiter;
    if (codepoints.nextCodepoint() != null) return error.InvalidSeedDelimiter;
    if (!std.unicode.utf8ValidateSlice(raw_csv)) return error.InvalidSeedCsv;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const text = if (std.mem.startsWith(u8, raw_csv, "\xef\xbb\xbf")) raw_csv[3..] else raw_csv;
    var records: std.ArrayList([]const []const u8) = .empty;
    var fields: std.ArrayList([]const u8) = .empty;
    var field: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    var quoted = false;
    var closed = false;
    var started = false;
    while (index < text.len) {
        const byte = text[index];
        if (quoted) {
            if (byte == '"') {
                if (index + 1 < text.len and text[index + 1] == '"') {
                    try field.append(a, '"');
                    index += 2;
                    continue;
                }
                quoted = false;
                closed = true;
            } else try field.append(a, byte);
            index += 1;
            continue;
        }
        if (std.mem.startsWith(u8, text[index..], delimiter)) {
            try fields.append(a, try field.toOwnedSlice(a));
            closed = false;
            started = true;
            index += delimiter.len;
        } else if (byte == '\n' or byte == '\r') {
            if (started or field.items.len != 0 or fields.items.len != 0 or closed) {
                try fields.append(a, try field.toOwnedSlice(a));
                try records.append(a, try fields.toOwnedSlice(a));
            }
            if (byte == '\r' and index + 1 < text.len and text[index + 1] == '\n') index += 1;
            index += 1;
            closed = false;
            started = false;
        } else if (byte == '"' and field.items.len == 0 and !started and !closed) {
            quoted = true;
            started = true;
            index += 1;
        } else {
            if (closed) return error.InvalidSeedCsv;
            // A quote at the beginning of any field opens its quoted body.
            if (byte == '"' and field.items.len == 0 and !closed) quoted = true else try field.append(a, byte);
            started = true;
            index += 1;
        }
    }
    if (quoted) return error.InvalidSeedCsv;
    if (started or closed or field.items.len != 0 or fields.items.len != 0) {
        try fields.append(a, try field.toOwnedSlice(a));
        try records.append(a, try fields.toOwnedSlice(a));
    }
    if (records.items.len == 0) return error.InvalidSeedCsv;
    const headers = try a.dupe([]const u8, records.items[0]);
    if (!unit_fixture) for (headers, 0..) |*header, column| {
        const base = if (header.*.len != 0) header.* else try alphabetName(a, column);
        var candidate = base;
        var suffix: usize = 2;
        while (contains(headers[0..column], candidate)) : (suffix += 1) candidate = try std.fmt.allocPrint(a, "{s}_{d}", .{ base, suffix });
        header.* = candidate;
    };
    for (records.items[1..]) |*row| {
        if (unit_fixture and row.len < headers.len) {
            const padded = try a.alloc([]const u8, headers.len);
            @memcpy(padded[0..row.len], row.*);
            @memset(padded[row.len..], "");
            row.* = padded;
        }
        if (row.len != headers.len) return error.InvalidSeedColumnCount;
    }
    return .{ .arena = arena, .headers = headers, .rows = records.items[1..] };
}

pub const Kind = enum { integer, number, date, timestamp, boolean, text };
const Column = struct { name: []const u8, sql_name: []const u8, kind: Kind, data_type: []const u8, explicit: bool };

/// Bind seed column types without executing DDL or exposing files to a server.
/// Uses the same native CSV inference and overrides as seed execution.
pub fn renderTypeQuery(allocator: std.mem.Allocator, node: *const types.Node) ![]u8 {
    const delimiter: std.json.Value = values.get(node.effective_config, "delimiter") orelse .{ .string = "," };
    if (delimiter != .string) return error.InvalidSeedDelimiter;
    var document = try parseWithDelimiter(allocator, node.raw_code, delimiter.string);
    defer document.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try output.writer.writeAll("select ");
    for (document.headers, 0..) |header, index| {
        if (index != 0) try output.writer.writeAll(", ");
        const kind = try infer(allocator, document.rows, index);
        const data_type = columnOverride(node, header) orelse switch (kind) {
            .integer => "integer",
            .number => "float8",
            .date => "date",
            .timestamp => "timestamp without time zone",
            .boolean => "boolean",
            .text => "text",
        };
        try output.writer.print("cast(null as {s}) as {s}", .{ data_type, try adapter.quoteIdentifier(allocator, header) });
    }
    try output.writer.writeAll(" where false");
    return output.toOwnedSlice();
}

pub fn renderSql(allocator: std.mem.Allocator, graph: *const types.Graph, node: *const types.Node) ![]u8 {
    return renderSqlMode(allocator, graph, node, true);
}

pub fn renderInsertSql(allocator: std.mem.Allocator, graph: *const types.Graph, node: *const types.Node) ![]u8 {
    return renderSqlMode(allocator, graph, node, false);
}

fn renderSqlMode(allocator: std.mem.Allocator, graph: *const types.Graph, node: *const types.Node, create: bool) ![]u8 {
    if (!std.mem.eql(u8, node.resource_type, "seed")) return error.UnsupportedSeedExecution;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const delimiter_value: std.json.Value = values.get(node.effective_config, "delimiter") orelse .{ .string = "," };
    if (delimiter_value != .string) return error.InvalidSeedDelimiter;
    var document = try parseWithDelimiter(a, node.raw_code, delimiter_value.string);
    defer document.deinit();
    const columns = try a.alloc(Column, document.headers.len);
    for (document.headers, columns, 0..) |header, *column, index| {
        const override = columnOverride(node, header);
        const kind = if (override != null) Kind.text else try infer(a, document.rows, index);
        const data_type = override orelse switch (kind) {
            .integer => "integer",
            .number => "float8",
            .date => "date",
            .timestamp => "timestamp without time zone",
            .boolean => "boolean",
            .text => "text",
        };
        const sql_name = if (node.quote_columns orelse true) try adapter.quoteIdentifier(a, header) else blk: {
            try validateUnquoted(header);
            break :blk header;
        };
        column.* = .{ .name = header, .sql_name = sql_name, .kind = kind, .data_type = data_type, .explicit = override != null };
    }
    const relation = try compiler.relationNameForNode(a, graph, node);
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    if (create) {
        const schema = try adapter.quoteIdentifier(a, try compiler.relationSchemaForNode(a, graph, node));
        try output.writer.print("create schema if not exists {s};\ncreate table {s} (", .{ schema, relation });
        for (columns, 0..) |column, index| {
            if (index != 0) try output.writer.writeAll(", ");
            try output.writer.print("{s} {s}", .{ column.sql_name, column.data_type });
        }
        try output.writer.writeAll(");\n");
    }
    // Match Core's bounded batches instead of constructing a single unlimited
    // VALUES statement; no subprocess or server-side filesystem access is used.
    for (document.rows, 0..) |row, row_index| {
        if (row_index % 10000 == 0) {
            try output.writer.print("insert into {s} (", .{relation});
            for (columns, 0..) |column, index| {
                if (index != 0) try output.writer.writeAll(", ");
                try output.writer.writeAll(column.sql_name);
            }
            try output.writer.writeAll(") values\n");
        } else try output.writer.writeAll(",\n");
        try output.writer.writeByte('(');
        for (row, columns, 0..) |cell, column, index| {
            if (index != 0) try output.writer.writeAll(", ");
            if (isNull(cell)) {
                try output.writer.writeAll("null");
            } else {
                const cooked = switch (column.kind) {
                    .integer, .number => try number(a, cell),
                    .boolean => if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, cell, " \t\r\n"), "true")) "true" else "false",
                    .date, .timestamp => std.mem.trim(u8, cell, " \t\r\n"),
                    .text => cell,
                };
                try output.writer.writeAll(try adapter.quoteLiteral(a, cooked));
            }
        }
        try output.writer.writeByte(')');
        if (row_index % 10000 == 9999 or row_index + 1 == document.rows.len) try output.writer.writeAll(";\n");
    }
    return output.toOwnedSlice();
}

pub fn infer(a: std.mem.Allocator, rows: []const []const []const u8, column: usize) !Kind {
    var numeric = true;
    var fractional = false;
    var date = true;
    var timestamp = true;
    var boolean = true;
    for (rows) |row| {
        const value = std.mem.trim(u8, row[column], " \t\r\n");
        if (isNull(value)) continue;
        if (number(a, value)) |parsed| {
            if (std.mem.indexOfAny(u8, parsed, ".eE") != null) {
                const point = std.mem.indexOfScalar(u8, parsed, '.');
                const exponent_index = std.mem.indexOfAny(u8, parsed, "eE");
                const exponent = if (exponent_index) |index| std.fmt.parseInt(i32, parsed[index + 1 ..], 10) catch 0 else 0;
                const decimal_places: i32 = if (point) |index| @intCast((exponent_index orelse parsed.len) - index - 1) else 0;
                if (decimal_places - exponent > 0) fractional = true;
            }
        } else |_| numeric = false;
        if (!isIsoDate(value)) date = false;
        if (value.len <= 10) timestamp = false else _ = freshness.parseFreshnessTimestamp(value) catch blk: {
            timestamp = false;
            break :blk 0;
        };
        if (!std.ascii.eqlIgnoreCase(value, "true") and !std.ascii.eqlIgnoreCase(value, "false")) boolean = false;
    }
    if (numeric) return if (fractional) .number else .integer;
    if (date) return .date;
    if (timestamp) return .timestamp;
    if (boolean) return .boolean;
    return .text;
}

fn isIsoDate(text: []const u8) bool {
    if (text.len != 10 or text[4] != '-' or text[7] != '-') return false;
    const year = std.fmt.parseInt(u16, text[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return false;
    const days: u8 = switch (month) {
        2 => if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        1, 3, 5, 7, 8, 10, 12 => 31,
        else => return false,
    };
    return year != 0 and day > 0 and day <= days;
}

pub fn number(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var text = std.mem.trim(u8, raw, " \t\r\n%");
    const negative = std.mem.startsWith(u8, text, "-");
    if (negative) text = text[1..];
    const symbols = [_][]const u8{ "؋", "$", "ƒ", "៛", "¥", "₡", "₱", "£", "€", "¢", "﷼", "₪", "₩", "₭", "₮", "₦", "฿", "₤", "₫" };
    for (symbols) |symbol| {
        while (std.mem.startsWith(u8, text, symbol)) text = text[symbol.len..];
        while (std.mem.endsWith(u8, text, symbol)) text = text[0 .. text.len - symbol.len];
    }
    const grouped = try std.mem.replaceOwned(u8, a, text, ",", "");
    if (grouped.len == 0) return error.InvalidSeedNumber;
    var digits: usize = 0;
    var point = false;
    var exponent = false;
    for (grouped, 0..) |byte, index| {
        if (std.ascii.isDigit(byte)) {
            digits += 1;
            continue;
        }
        if ((byte == '+' or byte == '-') and (index == 0 or grouped[index - 1] == 'e' or grouped[index - 1] == 'E')) continue;
        if (byte == '.' and !point and !exponent) {
            point = true;
            continue;
        }
        if ((byte == 'e' or byte == 'E') and !exponent and digits != 0) {
            exponent = true;
            digits = 0;
            continue;
        }
        return error.InvalidSeedNumber;
    }
    if (digits == 0) return error.InvalidSeedNumber;
    return if (negative) std.fmt.allocPrint(a, "-{s}", .{grouped}) else grouped;
}

fn columnOverride(node: *const types.Node, name: []const u8) ?[]const u8 {
    for (node.seed_column_types.items) |column| if (std.mem.eql(u8, column.name, name)) return column.data_type;
    return null;
}
pub fn isNull(value: []const u8) bool {
    const text = std.mem.trim(u8, value, " \t\r\n");
    return text.len == 0 or std.ascii.eqlIgnoreCase(text, "null");
}
fn contains(items: []const []const u8, value: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}
fn validateUnquoted(name: []const u8) !void {
    if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_' and name[0] < 128)) return error.InvalidSeedColumnName;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '$' and byte < 128) return error.InvalidSeedColumnName;
}
fn alphabetName(a: std.mem.Allocator, column: usize) ![]const u8 {
    var buffer: [32]u8 = undefined;
    var cursor = buffer.len;
    var value = column + 1;
    while (value != 0) {
        cursor -= 1;
        value -= 1;
        buffer[cursor] = 'a' + @as(u8, @intCast(value % 26));
        value /= 26;
    }
    return a.dupe(u8, buffer[cursor..]);
}

test "native seed CSV preserves RFC4180 quoted commas, escaped quotes and newlines" {
    var document = try parse(std.testing.allocator, "\xef\xbb\xbfId,notes,Id,\r\n1,\"A, B\r\nC \"\"D\"\"\",2,\r\n");
    defer document.deinit();
    try std.testing.expectEqualDeep(&[_][]const u8{ "Id", "notes", "Id_2", "d" }, document.headers);
    try std.testing.expectEqualStrings("A, B\r\nC \"D\"", document.rows[0][1]);
    try std.testing.expectEqualStrings("", document.rows[0][3]);
    try std.testing.expectError(error.InvalidSeedCsv, parse(std.testing.allocator, "id\n\"unfinished"));
    try std.testing.expectError(error.InvalidSeedColumnCount, parse(std.testing.allocator, "a,b\n1\n"));
}

test "portable seed renderer preserves Core inference and explicit text overrides" {
    const a = std.testing.allocator;
    var graph: types.Graph = .{ .allocator = a, .project_name = "demo", .target_schema = "public", .adapter_type = "postgres" };
    var node: types.Node = .{ .package_name = "demo", .unique_id = "seed.demo.raw", .name = "raw", .path = "raw.csv", .original_file_path = "seeds/raw.csv", .raw_code = "id,amount,day,active,code\n1,\"$1,234.50\",2024-02-29,true,001\n2,2.00,2024-03-01,false,null\n", .resource_type = "seed", .materialized = "seed" };
    try node.seed_column_types.append(a, .{ .name = "code", .data_type = "varchar(8)" });
    defer node.seed_column_types.deinit(a);
    const sql = try renderSql(a, &graph, &node);
    defer a.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"amount\" float8") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"day\" date") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "\"active\" boolean") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "'001'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "'1234.50'") != null);
}
