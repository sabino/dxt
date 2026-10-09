//! DuckDB's external views and parameterized table macros use native sessions.
const std = @import("std");
const adapter = @import("adapter.zig");
const compiler = @import("compiler.zig");
const values = @import("config_value.zig");
const journal_module = @import("materialization_journal.zig");
const types = @import("types.zig");
const ExecutionPolicy = @import("postgres_materialization.zig").ExecutionPolicy;

pub fn execute(runtime: types.Runtime, db_path: []const u8, graph: *const types.Graph, node: *const types.Node, policy: ExecutionPolicy) !void {
    if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedModelMaterialization;
    if (!policy.manage_transaction and runtime.adapter_session == null) return error.NativeAdapterSessionRequired;
    var owned: ?adapter.Session = null;
    defer if (owned) |*session| session.deinit();
    const session = runtime.adapter_session orelse blk: {
        owned = try adapter.openSession(runtime, graph, db_path);
        break :blk &owned.?;
    };
    var local_journal = journal_module.Journal.init(runtime.allocator, runtime.io);
    defer local_journal.deinit();
    const journal = policy.file_effects orelse &local_journal;
    if (policy.manage_transaction) try session.begin();
    errdefer if (policy.manage_transaction) {
        session.rollback() catch {};
        journal.rollback() catch {};
    };
    var arena = std.heap.ArenaAllocator.init(runtime.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try compiler.relationSchemaForNode(a, graph, node);
    const quoted_schema = try adapter.quoteIdentifier(a, schema);
    const relation = try compiler.relationNameForNode(a, graph, node);
    try session.execute(try std.fmt.allocPrint(a, "create schema if not exists {s}", .{quoted_schema}));
    if (std.mem.eql(u8, node.materialized, "table_function")) {
        const parameters = try renderParameters(a, node);
        const sql = @import("duckdb.zig").trimTrailingSqlTerminator(node.compiled_code orelse return error.UnsupportedModelExecution);
        try session.execute(try std.fmt.allocPrint(a, "create or replace function {s}({s}) as table (\n{s}\n)", .{ relation, parameters, sql }));
    } else if (std.mem.eql(u8, node.materialized, "external")) {
        if (!policy.manage_transaction and policy.file_effects == null) return error.ExternalJournalRequired;
        try executeExternal(a, runtime, session, graph, node, schema, relation, journal);
    } else return error.UnsupportedModelMaterialization;
    if (policy.manage_transaction) {
        try journal.publish();
        try session.commit();
        try journal.finalize();
    }
}

fn renderText(a: std.mem.Allocator, graph: *const types.Graph, node: *const types.Node, text: []const u8) ![]const u8 {
    var template = node.*;
    template.raw_code = text;
    return compiler.compileModel(a, graph, &template);
}

fn scalarText(a: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return if (value == .string) value.string else try values.scalarText(a, value);
}

fn renderParameters(a: std.mem.Allocator, node: *const types.Node) ![]const u8 {
    const value = values.get(node.effective_config, "parameters") orelse return "";
    switch (value) {
        .null => return "",
        .bool => return if (!value.bool) "" else error.InvalidTableFunctionParameters,
        .integer => return if (value.integer == 0) "" else scalarText(a, value),
        .float => return if (value.float == 0) "" else scalarText(a, value),
        .string, .number_string => return scalarText(a, value),
        .array => |array| {
            const items = try a.alloc([]const u8, array.items.len);
            for (items, array.items) |*item, element| item.* = try scalarText(a, element);
            return std.mem.join(a, ", ", items);
        },
        else => return error.InvalidTableFunctionParameters,
    }
}

fn optionName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn allowedFormat(format: []const u8) bool {
    return std.mem.eql(u8, format, "parquet") or std.mem.eql(u8, format, "csv") or std.mem.eql(u8, format, "json");
}

fn extensionFormat(a: std.mem.Allocator, location: []const u8) ![]const u8 {
    const extension = std.fs.path.extension(location);
    return if (extension.len > 1) try std.ascii.allocLowerString(a, extension[1..]) else "";
}

fn executeExternal(a: std.mem.Allocator, runtime: types.Runtime, session: *adapter.Session, graph: *const types.Graph, node: *const types.Node, schema: []const u8, relation: []const u8, journal: *journal_module.Journal) !void {
    for ([_][]const u8{ "plugin", "glue_register" }) |key| if (values.get(node.effective_config, key)) |plugin| if (plugin != .null and !(plugin == .bool and !plugin.bool)) return error.UnsupportedExternalRegistration;
    const format_config = values.get(node.effective_config, "format") orelse .null;
    if (format_config != .null and (format_config != .string or !allowedFormat(format_config.string))) return error.InvalidExternalFormat;
    const options_config = values.get(node.effective_config, "options") orelse std.json.Value{ .object = .empty };
    if (options_config != .object) return error.InvalidExternalOptions;
    var options = try values.clone(a, options_config);
    var iterator = options.object.iterator();
    while (iterator.next()) |entry| {
        if (!optionName(entry.key_ptr.*)) return error.InvalidExternalOptions;
        if (entry.value_ptr.* == .string) entry.value_ptr.* = .{ .string = try renderText(a, graph, node, entry.value_ptr.string) };
    }
    for ([_][]const u8{ "format", "delimiter" }) |key| if (values.get(node.effective_config, key)) |value| if (value != .null) try values.put(a, &options, key, value);
    const partition = values.get(options, "partition_by") orelse .null;
    if (partition != .null and partition != .string) return error.InvalidExternalOptions;
    const partitioned = partition == .string and partition.string.len != 0;
    const root = values.get(graph.target_context, "external_root") orelse std.json.Value{ .string = "." };
    if (root != .string) return error.InvalidExternalLocation;
    const default_location = if (partitioned)
        try std.fs.path.join(a, &.{ root.string, compiler.relationIdentifierForNode(node) })
    else
        try std.fs.path.join(a, &.{ root.string, try std.fmt.allocPrint(a, "{s}.{s}", .{ compiler.relationIdentifierForNode(node), if (format_config == .string) format_config.string else "parquet" }) });
    const location_config = values.get(node.effective_config, "location") orelse std.json.Value{ .string = default_location };
    if (location_config != .string) return error.InvalidExternalLocation;
    const location = try renderText(a, graph, node, location_config.string);
    const extension = try extensionFormat(a, location);
    const format = if (format_config == .string) format_config.string else if (allowedFormat(extension)) extension else "parquet";
    if (values.get(options, "format") == null) try values.put(a, &options, "format", .{ .string = if (extension.len != 0) extension else if (values.get(options, "delimiter") != null) "csv" else "parquet" });
    const write_format = values.get(options, "format").?;
    if (write_format != .string) return error.InvalidExternalOptions;
    if (std.mem.eql(u8, write_format.string, "csv") and values.get(options, "header") == null) try values.put(a, &options, "header", .{ .integer = 1 });
    if (partitioned and std.mem.indexOfScalar(u8, partition.string, ',') != null and !std.mem.startsWith(u8, partition.string, "(")) try values.put(a, &options, "partition_by", .{ .string = try std.fmt.allocPrint(a, "({s})", .{partition.string}) });
    const staged_path = try journal.prepare(location);
    const per_thread = values.get(options, "per_thread_output") orelse .null;
    const directory_output = partitioned or (per_thread == .bool and per_thread.bool) or (per_thread == .integer and per_thread.integer != 0) or (per_thread == .string and std.ascii.eqlIgnoreCase(per_thread.string, "true"));
    if (directory_output) try copyExistingDirectory(a, runtime.io, location, staged_path);
    const write_options = try renderWriteOptions(a, options);
    const stage_id = try std.fmt.allocPrint(a, "{s}__dbt_tmp", .{compiler.relationIdentifierForNode(node)});
    const stage = try std.fmt.allocPrint(a, "{s}.{s}", .{ try adapter.quoteIdentifier(a, schema), try adapter.quoteIdentifier(a, stage_id) });
    const sql = @import("duckdb.zig").trimTrailingSqlTerminator(node.compiled_code orelse return error.UnsupportedModelExecution);
    const header = values.get(node.effective_config, "sql_header") orelse .null;
    if (header != .null and header != .string) return error.InvalidExternalOptions;
    try session.execute(try std.fmt.allocPrint(a, "{s}\ncreate or replace table {s} as (\n{s}\n)", .{ if (header == .string) header.string else "", stage, sql }));
    var count = try session.query(try std.fmt.allocPrint(a, "select count(*) from {s}", .{stage}));
    defer count.deinit(runtime.allocator);
    const empty = std.mem.eql(u8, count.firstScalar() orelse return error.InvalidAdapterIntrospection, "0");
    var columns = try session.query(try std.fmt.allocPrint(a, "select * from {s} limit 0", .{stage}));
    defer columns.deinit(runtime.allocator);
    if (empty) {
        const nulls = try a.alloc([]const u8, columns.columns.len);
        @memset(nulls, "NULL");
        try session.execute(try std.fmt.allocPrint(a, "insert into {s} values({s})", .{ stage, try std.mem.join(a, ",", nulls) }));
    }
    try session.execute(try std.fmt.allocPrint(a, "copy {s} to {s} ({s})", .{ stage, try adapter.quoteLiteral(a, staged_path), write_options }));
    // CREATE VIEW binds the output schema immediately. Publish reversibly first,
    // so first builds and schema changes bind the newly written file.
    try journal.publish();
    var read_location = location;
    if (directory_output) {
        var glob: std.ArrayList([]const u8) = .empty;
        try glob.append(a, location);
        try glob.append(a, "*");
        if (partitioned) {
            var parts = std.mem.splitScalar(u8, partition.string, ',');
            while (parts.next() != null) try glob.append(a, "*");
        }
        read_location = try std.fmt.allocPrint(a, "{s}.{s}", .{ try std.mem.join(a, "/", glob.items), write_format.string });
    }
    const read_key = try std.fmt.allocPrint(a, "{s}_read_options", .{format});
    const default_read: std.json.Value = .{ .object = .empty };
    var read_options = try values.clone(a, values.get(node.effective_config, read_key) orelse default_read);
    if (values.get(node.effective_config, read_key) == null) try values.put(a, &read_options, if (std.mem.eql(u8, format, "parquet")) "union_by_name" else "auto_detect", .{ .bool = !std.mem.eql(u8, format, "parquet") });
    const read_arguments = try renderReadOptions(a, read_options);
    var filter: std.ArrayList(u8) = .empty;
    if (empty) {
        try filter.appendSlice(a, " where 1");
        for (columns.columns) |column| try filter.appendSlice(a, try std.fmt.allocPrint(a, " and {s} is not NULL", .{try adapter.quoteIdentifier(a, column.name)}));
    }
    const existing = try session.relationTypeInDatabase(a, compiler.relationDatabaseForNode(graph, node), schema, compiler.relationIdentifierForNode(node));
    if (existing) |kind| if (!std.mem.eql(u8, kind, "view")) try session.execute(try std.fmt.allocPrint(a, "drop table {s}", .{relation}));
    try session.execute(try std.fmt.allocPrint(a, "create or replace view {s} as (select * from read_{s}({s}{s}){s})", .{ relation, format, try adapter.quoteLiteral(a, read_location), read_arguments, filter.items }));
    try session.execute(try std.fmt.allocPrint(a, "drop table {s}", .{stage}));
}

fn copyExistingDirectory(a: std.mem.Allocator, io: std.Io, original: []const u8, staged: []const u8) !void {
    const stat = std.Io.Dir.cwd().statFile(io, original, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    if (stat.kind != .directory) return;
    var source = try std.Io.Dir.cwd().openDir(io, original, .{ .iterate = true });
    defer source.close(io);
    try std.Io.Dir.cwd().createDirPath(io, staged);
    var walker = try source.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const destination = try std.fs.path.join(a, &.{ staged, entry.path });
        switch (entry.kind) {
            .directory => try std.Io.Dir.cwd().createDirPath(io, destination),
            .file => try std.Io.Dir.copyFile(source, entry.path, std.Io.Dir.cwd(), destination, io, .{ .make_path = true }),
            else => return error.UnsupportedExternalOutputEntry,
        }
    }
}

fn renderWriteOptions(a: std.mem.Allocator, options: std.json.Value) ![]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var it = options.object.iterator();
    while (it.next()) |entry| {
        const text = try scalarText(a, entry.value_ptr.*);
        var quoted = false;
        for ([_][]const u8{ "delimiter", "quote", "escape", "null" }) |name| if (std.ascii.eqlIgnoreCase(name, entry.key_ptr.*)) {
            quoted = true;
        };
        const value = if (quoted and !std.mem.startsWith(u8, text, "'")) try adapter.quoteLiteral(a, text) else text;
        try result.append(a, try std.fmt.allocPrint(a, "{s} {s}", .{ entry.key_ptr.*, value }));
    }
    return std.mem.join(a, ", ", result.items);
}

fn renderReadOptions(a: std.mem.Allocator, options: std.json.Value) ![]const u8 {
    if (options != .object) return error.InvalidExternalReadOptions;
    var result: std.ArrayList([]const u8) = .empty;
    var it = options.object.iterator();
    while (it.next()) |entry| {
        if (!optionName(entry.key_ptr.*)) return error.InvalidExternalReadOptions;
        const value = if (entry.value_ptr.* == .string) try adapter.quoteLiteral(a, entry.value_ptr.string) else try scalarText(a, entry.value_ptr.*);
        try result.append(a, try std.fmt.allocPrint(a, ", {s}={s}", .{ entry.key_ptr.*, value }));
    }
    return std.mem.join(a, "", result.items);
}
