//! Native SQL-operation nodes and Core compile/show end messages.
const std = @import("std");
const types = @import("types.zig");
const compiler = @import("compiler.zig");
const results = @import("run_results.zig");
const values = @import("config_value.zig");
const clock = @import("execution_clock.zig");

pub fn appendInline(runtime: types.Runtime, graph: *types.Graph, sql: []const u8) !void {
    var node: types.Node = .{
        .resource_type = "sql_operation",
        .package_name = graph.project_name,
        .name = "inline_query",
        .unique_id = try std.fmt.allocPrint(runtime.allocator, "sql_operation.{s}.inline_query", .{graph.project_name}),
        .path = "sql/inline_query",
        .original_file_path = "from remote system.sql",
        .raw_code = sql,
    };
    errdefer types.deinitNode(runtime.allocator, &node);
    var project = try @import("config.zig").loadProjectConfigWithContext(runtime, graph.command_options.project_dir, graph.vars.items, graph.target_context);
    defer types.deinitProjectConfig(runtime.allocator, &project);
    var single = graph.*;
    single.nodes = .{ .items = (&node)[0..1], .capacity = 1 };
    node.resource_type = "model";
    try @import("config.zig").applyProjectModelPathConfigs(&single, project.model_path_configs.items, true, null);
    node.resource_type = "sql_operation";
    try compiler.scanDependencies(runtime.allocator, sql, &node, graph);
    node.enabled = true;
    try values.put(runtime.allocator, &node.effective_config, "enabled", .{ .bool = true });
    try graph.nodes.append(runtime.allocator, node);
}

pub fn preview(runtime: types.Runtime, graph: *types.Graph, resource: @import("concurrent_runner.zig").Resource, row: *results.NodeResult, host: *@import("commands.zig").OperationHost, db_path: []const u8) !void {
    const a = runtime.allocator;
    const options = graph.command_options;
    var query: @import("adapter.zig").QueryResult = undefined;
    if (resource == .node and std.mem.eql(u8, resource.node.resource_type, "seed")) {
        const held = try host.heldRuntime();
        graph.log_collector = host.log_events;
        var marker: u8 = 0;
        try @import("materialization_runtime.zig").executeWithBody(held, db_path, graph, resource.node, .{ .context = &marker, .execute = showSeedBody });
        // Core's CSV loader treats configured column_types as text columns,
        // independently of the actual warehouse type selected for the seed.
        query = try seedTable(a, resource.node);
        row.adapter_response = .{ .message = try std.fmt.allocPrint(a, "CREATE {d}", .{query.rows.len}), .code = "CREATE", .rows_affected = @intCast(query.rows.len), .include_query_id = true };
        row.owns_adapter_response = true;
    } else {
        var node = if (resource == .node) resource.node.* else types.Node{
            .resource_type = "test",
            .package_name = if (resource == .generic) resource.generic.package_name else resource.singular.package_name,
            .unique_id = resource.id(),
            .name = if (resource == .generic) resource.generic.name else resource.singular.name,
            .path = "",
            .original_file_path = "",
            .raw_code = "",
            .effective_config = if (resource == .generic) .null else resource.singular.config_values,
        };
        node.compiled_code = row.compiled_code orelse return error.MissingCompiledSql;
        const limit = if (options.query_limit < 0) "none" else try std.fmt.allocPrint(a, "{d}", .{options.query_limit});
        const expression = try std.fmt.allocPrint(a, "{{{{ get_show_sql(compiled_code, config.get('sql_header'), {s}) }}}}", .{limit});
        const sql = try compiler.renderTextForNode(a, graph, &node, expression);
        row.compiled_artifact_code = try a.dupe(u8, node.compiled_code.?);
        row.owns_compiled_artifact_code = true;
        if (row.owns_compiled_code) if (row.compiled_code) |previous| a.free(previous);
        row.compiled_code = sql;
        row.owns_compiled_code = true;
        query = host.queryResult(sql) catch |err| {
            if (host.lastError()) |message| @import("compile_diagnostics.zig").captureError(node.original_file_path, node.name, message, err);
            return err;
        };
        if (std.mem.eql(u8, graph.adapter_type, "postgres")) {
            row.adapter_response = .{ .message = try a.dupe(u8, query.command_tag orelse "SELECT"), .code = "SELECT", .rows_affected = @intCast(query.rows.len), .include_query_id = true };
            row.owns_adapter_response = true;
        } else row.adapter_response = .{ .message = "OK", .include_nulls = true, .include_query_id = true };
    }
    defer query.deinit(a);
    row.preview = try @import("sql_preview.zig").render(a, &query, options.output);
    row.owns_preview = true;
}

fn showSeedBody(_: *anyopaque, runtime: types.Runtime, graph: *const types.Graph, node: *const types.Node, path: []const u8, policy: @import("duckdb.zig").ExecutionPolicy) anyerror!void {
    const adapter = @import("adapter.zig");
    const a = runtime.allocator;
    const schema = try compiler.relationSchemaForNode(a, graph, node);
    const schema_lit = try adapter.quoteLiteral(a, schema);
    const database = compiler.relationDatabaseForNode(graph, node);
    const database_filter = if (database) |name| try std.fmt.allocPrint(a, " and catalog_name={s}", .{try adapter.quoteLiteral(a, name)}) else "";
    const sql = try std.fmt.allocPrint(a, "select schema_name from information_schema.schemata where schema_name={s}{s}", .{ schema_lit, database_filter });
    var lookup = try runtime.adapter_session.?.query(sql);
    defer lookup.deinit(a);
    if (lookup.rows.len == 0) {
        const message = try std.fmt.allocPrint(a, "Schema with name {s} does not exist", .{schema});
        @import("compile_diagnostics.zig").captureError(node.original_file_path, node.name, message, error.MissingPreviewSeedSchema);
        return error.MissingPreviewSeedSchema;
    }
    return @import("duckdb.zig").executeSeedWithPolicy(runtime, path, graph.command_options.project_dir, graph, node, policy);
}

fn seedTable(a: std.mem.Allocator, node: *const types.Node) !@import("adapter.zig").QueryResult {
    const csv = @import("seed_csv.zig");
    const delimiter = values.get(node.effective_config, "delimiter") orelse std.json.Value{ .string = "," };
    if (delimiter != .string) return error.InvalidSeedDelimiter;
    var document = try csv.parseWithDelimiter(a, node.raw_code, delimiter.string);
    defer document.deinit();
    var table: @import("adapter.zig").QueryResult = .{};
    errdefer table.deinit(a);
    table.columns = try a.alloc(@import("adapter.zig").Column, document.headers.len);
    for (table.columns) |*column| column.* = .{ .name = "", .kind = .other };
    for (table.columns, document.headers, 0..) |*column, name, i| {
        column.name = try a.dupe(u8, name);
        const configured_types = values.get(node.effective_config, "column_types") orelse .null;
        column.kind = if (values.get(configured_types, name) != null) .text else switch (try csv.infer(a, document.rows, i)) {
            .integer => .decimal,
            .number => .decimal,
            .boolean => .boolean,
            .date => .date,
            .timestamp => .timestamp,
            .text => .text,
        };
    }
    table.rows = try a.alloc([]?[]const u8, document.rows.len);
    for (table.rows) |*row| row.* = &.{};
    for (table.rows, document.rows) |*row, source| {
        row.* = try a.alloc(?[]const u8, source.len);
        @memset(row.*, null);
        for (row.*, source, table.columns) |*cell, text, column| {
            if (csv.isNull(text)) continue;
            cell.* = if (column.kind == .integer or column.kind == .decimal) try csv.number(a, text) else try a.dupe(u8, text);
        }
    }
    return table;
}

pub fn emit(runtime: types.Runtime, options: types.Options, rows: []const results.NodeResult, stdout: *std.Io.Writer) !void {
    for (rows) |row| {
        if (!std.mem.eql(u8, row.status, "success")) continue;
        const name = if (row.node) |node| node.name else if (row.test_node) |node| node.name else if (row.singular_test_node) |node| node.name else continue;
        const id = if (row.node) |node| node.unique_id else if (row.test_node) |node| node.unique_id else row.singular_test_node.?.unique_id;
        const is_inline = options.inline_sql != null and options.inline_sql.?.len != 0;
        if (is_inline) {
            if (!std.mem.eql(u8, name, "inline_query")) continue;
        } else {
            const selection = options.select orelse continue;
            var tokens = std.mem.tokenizeAny(u8, selection, " \t\r\n");
            const first = tokens.next() orelse continue;
            if (std.mem.indexOf(u8, first, name) == null) continue;
        }
        const show = std.mem.eql(u8, options.which, "show");
        const text = if (show) row.preview orelse continue else row.compiled_code orelse continue;
        const display_name = if (show and row.node != null and row.node.?.version != .null) try std.fmt.allocPrint(runtime.allocator, "{s}.v{s}", .{ name, try @import("config_value.zig").scalarText(runtime.allocator, row.node.?.version) }) else name;
        try emitNode(runtime, options, display_name, id, is_inline, show, text, stdout);
    }
}

pub fn emitError(runtime: types.Runtime, message: []const u8, writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"data\":{\"exc\":");
    try std.json.Stringify.value(message, .{}, writer);
    try writer.writeAll("},\"info\":{\"name\":\"MainEncounteredError\",\"code\":\"Z002\",\"level\":\"error\",\"msg\":");
    const formatted = try std.fmt.allocPrint(runtime.allocator, "Encountered an error:\n{s}", .{message});
    defer runtime.allocator.free(formatted);
    try std.json.Stringify.value(formatted, .{}, writer);
    try writer.writeAll(",\"thread\":\"MainThread\",\"ts\":");
    try clock.writeTimestamp(writer, clock.now(runtime.io));
    try writer.writeAll(",\"invocation_id\":");
    if (runtime.invocation) |metadata| try std.json.Stringify.value(&metadata.id, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll("}}\n");
}

pub fn emitNode(runtime: types.Runtime, options: types.Options, name: []const u8, id: []const u8, is_inline: bool, show: bool, text: []const u8, writer: *std.Io.Writer) !void {
    const a = runtime.allocator;
    var data: std.json.Value = .null;
    defer values.deinit(a, &data);
    try values.put(a, &data, "node_name", .{ .string = name });
    try values.put(a, &data, "unique_id", .{ .string = id });
    try values.put(a, &data, "is_inline", .{ .bool = is_inline });
    try values.put(a, &data, "quiet", .{ .bool = options.quiet });
    try values.put(a, &data, "output_format", .{ .string = @tagName(options.output) });
    try values.put(a, &data, if (show) "preview" else "compiled", .{ .string = text });
    const message = if (options.output == .json) blk: {
        var object: std.json.Value = .null;
        defer values.deinit(a, &object);
        if (!is_inline) try values.put(a, &object, "node", .{ .string = name });
        if (show) {
            const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
            defer parsed.deinit();
            try values.put(a, &object, "show", parsed.value);
        } else try values.put(a, &object, "compiled", .{ .string = text });
        break :blk try std.json.Stringify.valueAlloc(a, object, .{ .whitespace = .indent_2 });
    } else if (options.quiet) try a.dupe(u8, text) else if (is_inline) try std.fmt.allocPrint(a, "{s}\n{s}", .{ if (show) "Previewing inline node:" else "Compiled inline node is:", text }) else try std.fmt.allocPrint(a, "{s} '{s}'{s}\n{s}", .{ if (show) "Previewing node" else "Compiled node", name, if (show) ":" else " is:", text });
    defer a.free(message);
    try writer.writeAll("{\"data\":");
    try std.json.Stringify.value(data, .{}, writer);
    try writer.writeAll(",\"info\":{\"name\":");
    try std.json.Stringify.value(if (show) "ShowNode" else "CompiledNode", .{}, writer);
    try writer.writeAll(",\"code\":");
    try std.json.Stringify.value(if (show) "Q041" else "Q042", .{}, writer);
    try writer.writeAll(",\"level\":\"info\",\"msg\":");
    try std.json.Stringify.value(message, .{}, writer);
    try writer.writeAll(",\"thread\":\"MainThread\",\"ts\":");
    try clock.writeTimestamp(writer, clock.now(runtime.io));
    try writer.writeAll(",\"invocation_id\":");
    if (runtime.invocation) |metadata| try std.json.Stringify.value(&metadata.id, .{}, writer) else try writer.writeAll("null");
    try writer.writeAll("}}\n");
}

pub fn showDirect(runtime: types.Runtime, options: types.Options, graph: *types.Graph, stdout: *std.Io.Writer) !void {
    const sql = options.inline_direct orelse return error.MissingCompiledSql;
    const path = try @import("duckdb.zig").databasePath(runtime.allocator, options.project_dir, graph);
    defer runtime.allocator.free(path);
    var host = try @import("commands.zig").OperationHost.initDirect(runtime, graph, path, stdout);
    defer host.deinit();
    var table = try host.queryResult(sql);
    defer table.deinit(runtime.allocator);
    // SQLConnectionManager.fetchmany treats a zero direct-query limit as
    // its unbounded fetch path. Ordinary show uses a literal SQL LIMIT 0.
    if (options.query_limit > 0 and table.rows.len > @as(u64, @intCast(options.query_limit))) {
        const count: usize = @intCast(options.query_limit);
        const owner = table.owner_allocator orelse runtime.allocator;
        for (table.rows[count..]) |row| {
            for (row) |cell| if (cell) |value| owner.free(value);
            owner.free(row);
        }
        table.rows = try owner.realloc(table.rows, count);
    }
    const rendered = try @import("sql_preview.zig").render(runtime.allocator, &table, options.output);
    defer runtime.allocator.free(rendered);
    try emitNode(runtime, options, "direct-query", "direct-query", true, true, rendered, stdout);
}
