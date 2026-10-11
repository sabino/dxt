//! dbt-postgres 1.9.1's available parse_index and PostgresIndexConfig protocol.
const std = @import("std");
const expression = @import("expression.zig");
const context = @import("dbt_context.zig");
const Value = expression.Value;
const Argument = expression.Argument;
const Definition = struct { columns: []const []const u8, unique: bool = false, type: ?[]const u8 = null };
const prefix = "__dxt_pg_index:render:";

pub fn call(a: std.mem.Allocator, adapter_type: []const u8, name: []const u8, args: []const Argument) anyerror!?Value {
    if (std.mem.eql(u8, name, "adapter.parse_index") and std.mem.eql(u8, adapter_type, "postgres")) {
        if (args.len != 1 or (args[0].name != null and !std.mem.eql(u8, args[0].name.?, "raw_index"))) return error.InvalidJinjaArguments;
        return try parse(a, args[0].value);
    }
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    if (args.len != 1 or (args[0].name != null and !std.mem.eql(u8, args[0].name.?, "relation"))) return error.InvalidJinjaArguments;
    const definition = (try std.json.parseFromSlice(Definition, a, name[prefix.len..], .{})).value;
    const relation = try context.renderRelation(a, try context.relationFromValue(a, args[0].value));
    const stamp = @import("invocation.zig").formatTimestamp(std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real));
    var input: std.Io.Writer.Allocating = .init(a);
    for (definition.columns) |column| try input.writer.print("{s}_", .{column});
    try input.writer.print("{s}_{s}_{s}_{s}", .{ relation, if (definition.unique) "True" else "False", definition.type orelse "None", stamp[0 .. stamp.len - 1] });
    var digest: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(input.written(), &digest, .{});
    return .{ .string = try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower)) };
}

fn parse(a: std.mem.Allocator, raw: Value) !Value {
    if (raw == .none) return .none;
    if (raw != .object) return error.InvalidPostgresIndexConfig;
    for (raw.object) |entry| if (!std.mem.eql(u8, entry.key, "columns") and !std.mem.eql(u8, entry.key, "unique") and !std.mem.eql(u8, entry.key, "type")) return error.InvalidPostgresIndexConfig;
    const columns = raw.attribute("columns");
    if (columns != .list) return error.InvalidPostgresIndexConfig;
    const names = try a.alloc([]const u8, columns.list.len);
    for (columns.list, names) |column, *name| {
        if (column != .string) return error.InvalidPostgresIndexConfig;
        name.* = column.string;
    }
    const unique = raw.attribute("unique");
    if (unique != .undefined and unique != .boolean) return error.InvalidPostgresIndexConfig;
    const kind = raw.attribute("type");
    if (kind != .undefined and kind != .none and kind != .string) return error.InvalidPostgresIndexConfig;
    const definition = Definition{ .columns = names, .unique = unique == .boolean and unique.boolean, .type = if (kind == .string) kind.string else null };
    const serialized = try std.json.Stringify.valueAlloc(a, definition, .{});
    const repr = try std.fmt.allocPrint(a, "PostgresIndexConfig(columns={s}, unique={s}, type={s})", .{ try expression.reprWithHost(a, columns, null), if (definition.unique) "True" else "False", try expression.reprWithHost(a, if (kind == .undefined) .none else kind, null) });
    return .{ .object = try a.dupe(expression.Entry, &.{
        .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } },
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "columns", .value = try context.cloneValue(a, columns) },
        .{ .key = "unique", .value = .{ .boolean = definition.unique } },
        .{ .key = "type", .value = if (kind == .undefined) .none else kind },
        .{ .key = "__dxt_rendered", .value = .{ .string = repr } },
        .{ .key = "__dxt_repr", .value = .{ .string = repr } },
        .{ .key = "render", .value = .{ .callable = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, serialized }) } },
    }) };
}

test "PostgreSQL index config validates defaults and produces a fresh server-safe name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw: Value = .{ .object = &.{.{ .key = "columns", .value = .{ .list = &.{.{ .string = "id" }} } }} };
    const index = (try call(a, "postgres", "adapter.parse_index", &.{.{ .value = raw }})).?;
    try std.testing.expect(!index.attribute("unique").boolean);
    try std.testing.expect(index.attribute("type") == .none);
    try std.testing.expect(!try expression.testValue("mapping", index, &.{}));
    try std.testing.expect(!try expression.testValue("iterable", index, &.{}));
    try std.testing.expectError(error.JinjaTypeError, expression.iterableValues(a, index));
    try std.testing.expectEqualStrings("PostgresIndexConfig(columns=['id'], unique=False, type=None)", try index.text(a));
    const relation = try context.relationValue(a, .{ .adapter_type = "postgres", .database = "warehouse", .schema = "public", .identifier = "events" });
    const name = (try call(a, "postgres", index.attribute("render").callable, &.{.{ .value = relation }})).?.string;
    try std.testing.expectEqual(@as(usize, 32), name.len);
    for (name) |byte| try std.testing.expect(std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f'));
    try std.testing.expect((try call(a, "postgres", "adapter.parse_index", &.{.{ .value = .none }})).? == .none);
    try std.testing.expect((try call(a, "duckdb", "adapter.parse_index", &.{.{ .value = raw }})) == null);
}

test "PostgreSQL index config rejects unknown fields and wrongly typed columns or options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(error.InvalidPostgresIndexConfig, call(a, "postgres", "adapter.parse_index", &.{.{ .value = .{ .object = &.{} } }}));
    const columns: expression.Entry = .{ .key = "columns", .value = .{ .list = &.{.{ .string = "id" }} } };
    inline for (.{ "unique", "type", "extra" }) |key| try std.testing.expectError(error.InvalidPostgresIndexConfig, call(a, "postgres", "adapter.parse_index", &.{.{ .value = .{ .object = &.{ columns, .{ .key = key, .value = .{ .integer = "1" } } } } }}));
    try std.testing.expectError(error.InvalidJinjaArguments, call(a, "postgres", "adapter.parse_index", &.{}));
}
