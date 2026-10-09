//! Namespaced static analysis: native dialect ASTs, read-only type binding,
//! logical operators, resolved column lineage, diagnostics and persisted cache.
const std = @import("std");
const types = @import("types.zig");
const adapter = @import("adapter.zig");
const compiler = @import("compiler.zig");
const parser = @import("sql_parser.zig");
const ir = @import("sql_ir.zig");
const values = @import("config_value.zig");
const commands = @import("commands.zig");
const expression = @import("expression.zig");
const seed_csv = @import("seed_csv.zig");
const sql = @import("duckdb.zig");
const Value = std.json.Value;
const field = parser.field;
const text = parser.text;
const items = parser.items;
const Stats = struct { parsed_nodes: usize = 0, bound_nodes: usize = 0, cache_hits: usize = 0, invalidated_nodes: usize = 0, elapsed_ms: f64 = 0 };
const Virtual = struct { node: *const types.Node, name: []const u8, query: []const u8 };
const Replacement = struct { start: usize, end: usize, value: []const u8 };

pub fn run(runtime: types.Runtime, graph: *types.Graph, selected_ids: []const []const u8, target_dir: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer, json_output: bool) !void {
    var arena = std.heap.ArenaAllocator.init(runtime.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var local_runtime = runtime;
    local_runtime.allocator = allocator;
    const dialect: parser.Dialect = if (eq(graph.adapter_type, "duckdb")) .duckdb else if (eq(graph.adapter_type, "postgres")) .postgres else return error.UnsupportedSqlAnalysisDialect;
    const db_path = if (dialect == .duckdb) sql.databasePath(allocator, target_dir, graph) catch ":memory:" else "";
    var owned_pool = adapter.DuckDBPool.init(allocator, runtime.io, runtime.environment);
    defer owned_pool.deinit();
    if (local_runtime.duckdb_pool == null) local_runtime.duckdb_pool = &owned_pool;
    var session: adapter.Session = if (dialect == .duckdb) blk: {
        if (!eq(db_path, ":memory:")) std.Io.Dir.cwd().access(runtime.io, db_path, .{}) catch break :blk .{ .duckdb = (try local_runtime.duckdb_pool.?.acquire(":memory:", true)) orelse return error.NativeDuckDbLibraryNotFound };
        break :blk .{ .duckdb = (try local_runtime.duckdb_pool.?.acquire(db_path, true)) orelse return error.NativeDuckDbLibraryNotFound };
    } else try adapter.openSession(local_runtime, graph, "");
    defer session.deinit();
    switch (session) {
        .duckdb => |*connection| try connection.enterReadOnlySession(),
        .postgres => |*connection| try connection.execute("begin transaction read only"),
    }
    local_runtime.adapter_session = &session;
    var pg = try parser.Postgres.open(local_runtime);
    defer pg.deinit();
    var discarded: std.Io.Writer.Allocating = .init(allocator);
    var host = commands.OperationHost{ .runtime = local_runtime, .graph = graph, .db_path = db_path, .stdout = &discarded.writer, .values = std.heap.ArenaAllocator.init(allocator) };
    defer host.deinit();
    var readonly_host = ReadonlyHost{ .host = &host, .session = &session, .pg = &pg, .dialect = dialect, .allocator = allocator };
    const prior_hooks = graph.execution_hooks;
    graph.execution_hooks = .{ .context = &readonly_host, .resolve = ReadonlyHost.resolve, .call = ReadonlyHost.call };
    defer graph.execution_hooks = prior_hooks;

    const start = std.Io.Clock.awake.now(runtime.io).nanoseconds;
    const cache_path = try std.fs.path.join(allocator, &.{ target_dir, ".dxt_sql_analysis_cache.json" });
    const previous = try readCache(local_runtime, cache_path);
    var version_result = try session.query("select version()");
    defer version_result.deinit(allocator);
    const parser_signature = try hash(allocator, try std.fmt.allocPrint(allocator, "{s}:pg-17.7:{s}", .{ graph.adapter_type, version_result.firstScalar() orelse "" }));
    var catalog = try loadCatalog(local_runtime, graph, &session);
    var schemas_result = try session.query("select current_database(),unnest(current_schemas(true)) as search_schema");
    defer schemas_result.deinit(allocator);
    var search_path: std.ArrayList([]const u8) = .empty;
    for (schemas_result.rows) |row| {
        const candidate = row[1] orelse continue;
        if (!contains(search_path.items, candidate)) try search_path.append(allocator, try allocator.dupe(u8, candidate));
    }
    const default_catalog = if (schemas_result.rows.len != 0) try allocator.dupe(u8, schemas_result.rows[0][0] orelse "") else "";
    try addTestNodes(graph, selected_ids);
    const order = try requiredOrder(allocator, graph, selected_ids);
    var virtual: std.ArrayList(Virtual) = .empty;
    var nodes: std.json.ObjectMap = .empty;
    var visible: std.json.ObjectMap = .empty;
    var asts: std.json.ObjectMap = .empty;
    var stats = Stats{};
    var failed = false;
    for (order) |index| {
        const node = &graph.nodes.items[index];
        if (dialect == .postgres) try session.execute("savepoint dxt_analysis_node");
        var blocked = false;
        for (node.depends_on.items) |dependency| if (eq(text(field(nodes.get(dependency) orelse .null, "status")), "error")) {
            try appendFailure(allocator, &nodes, &visible, selected_ids, node, .{ .code = "DEPENDENCY_FAILED", .message = try std.fmt.allocPrint(allocator, "Analysis dependency failed: {s}", .{dependency}) }, "", runtime, graph, db_path, stderr);
            blocked = true;
            failed = true;
            break;
        };
        if (blocked) {
            try recover(&session, dialect);
            continue;
        }
        const compiled = if (eq(node.resource_type, "seed")) seed_csv.renderTypeQuery(allocator, node) catch |err| {
            try appendFailure(allocator, &nodes, &visible, selected_ids, node, .{ .code = "CONFIGURATION", .message = @errorName(err) }, "", runtime, graph, db_path, stderr);
            failed = true;
            try recover(&session, dialect);
            continue;
        } else if (eq(node.resource_type, "test")) compileTest(allocator, graph, node.unique_id) catch |err| {
            try appendFailure(allocator, &nodes, &visible, selected_ids, node, .{ .code = "JINJA_COMPILATION", .message = @errorName(err) }, "", runtime, graph, db_path, stderr);
            failed = true;
            try recover(&session, dialect);
            continue;
        } else blk: {
            const result = compiler.compileModelWithInjectedCtes(allocator, graph, node) catch |err| {
                try appendFailure(allocator, &nodes, &visible, selected_ids, node, .{ .code = "JINJA_COMPILATION", .message = @errorName(err) }, "", runtime, graph, db_path, stderr);
                failed = true;
                try recover(&session, dialect);
                continue;
            };
            break :blk sql.trimTrailingSqlTerminator(result.compiled_code);
        };
        const compiled_hash = try hash(allocator, compiled);
        const cached_ast = field(field(previous, "asts"), node.unique_id);
        var parsed: parser.Parsed = .{};
        if (eq(text(field(cached_ast, "compiled_hash")), compiled_hash) and eq(text(field(cached_ast, "parser_signature")), parser_signature)) parsed.tree = try values.clone(allocator, field(cached_ast, "tree"));
        if (parsed.tree == .null) {
            parsed = if (dialect == .duckdb) try parser.parseDuckDb(allocator, &session, compiled) else try pg.parse(allocator, compiled);
            stats.parsed_nodes += 1;
        }
        if (parsed.diagnostic) |diagnostic| {
            try appendFailure(allocator, &nodes, &visible, selected_ids, node, diagnostic, compiled, runtime, graph, db_path, stderr);
            failed = true;
            try recover(&session, dialect);
            continue;
        }
        assertReadOnly(parsed.tree, dialect) catch |err| {
            try appendFailure(allocator, &nodes, &visible, selected_ids, node, .{ .code = "SQL_READ_ONLY", .message = @errorName(err) }, compiled, runtime, graph, db_path, stderr);
            failed = true;
            try recover(&session, dialect);
            continue;
        };
        const fingerprint = try nodeFingerprint(local_runtime, graph, node, compiled, parser_signature, parsed.tree, catalog.items, nodes);
        const cached = field(field(previous, "nodes"), node.unique_id);
        var analysis: Value = .null;
        if (eq(text(field(cached, "fingerprint")), fingerprint) and eq(text(field(cached, "status")), "success")) {
            analysis = try values.clone(allocator, cached);
            stats.cache_hits += 1;
        } else if (cached != .null) stats.invalidated_nodes += 1;
        // Persist the native AST independently from typed analysis. Schema and
        // config changes reuse syntax while rebinding the changed node.
        try asts.put(allocator, node.unique_id, try toValue(allocator, .{ .fingerprint = fingerprint, .compiled_hash = compiled_hash, .parser_signature = parser_signature, .tree = parsed.tree }));
        const rewritten = try rewriteRelations(allocator, compiled, parsed.tree, dialect, graph, virtual.items);
        const bind_query = if (dialect == .postgres) try withVirtualQueries(allocator, rewritten, virtual.items) else rewritten;
        if (analysis == .null) {
            const bound = bind(allocator, &session, dialect, bind_query) catch |err| {
                const diagnostic = try bindingDiagnostic(allocator, &session, compiled, err);
                try appendFailure(allocator, &nodes, &visible, selected_ids, node, diagnostic, compiled, runtime, graph, db_path, stderr);
                failed = true;
                try recover(&session, dialect);
                continue;
            };
            stats.bound_nodes += 1;
            var functions: std.ArrayList(ir.FunctionBinding) = .empty;
            collectFunctions(allocator, &session, dialect, compiled, parsed.tree, parsed.tree, catalog.items, &functions) catch |err| {
                try appendFailure(allocator, &nodes, &visible, selected_ids, node, try bindingDiagnostic(allocator, &session, compiled, err), compiled, runtime, graph, db_path, stderr);
                failed = true;
                try recover(&session, dialect);
                continue;
            };
            var builder = ir.Builder{ .allocator = allocator, .dialect = dialect, .catalog = catalog.items, .default_catalog = default_catalog, .search_path = search_path.items, .functions = functions.items };
            const logical = builder.build(parsed.tree, bound) catch |err| {
                try appendFailure(allocator, &nodes, &visible, selected_ids, node, .{ .code = "COLUMN_LINEAGE", .message = @errorName(err) }, compiled, runtime, graph, db_path, stderr);
                failed = true;
                try recover(&session, dialect);
                continue;
            };
            const plan = explain(allocator, &session, dialect, bind_query) catch |err| {
                try appendFailure(allocator, &nodes, &visible, selected_ids, node, try bindingDiagnostic(allocator, &session, compiled, err), compiled, runtime, graph, db_path, stderr);
                failed = true;
                try recover(&session, dialect);
                continue;
            };
            analysis = try toValue(allocator, .{ .unique_id = node.unique_id, .resource_type = node.resource_type, .path = node.original_file_path, .status = "success", .fingerprint = fingerprint, .compiled_sql = compiled, .columns = logical.columns, .inputs = logical.inputs, .operators = logical.operators, .predicate_origins = logical.predicate_origins, .diagnostics = @as(Value, .{ .array = std.json.Array.init(allocator) }), .plan = plan });
        }
        try nodes.put(allocator, node.unique_id, analysis);
        if (contains(selected_ids, node.unique_id)) try visible.put(allocator, node.unique_id, analysis);
        if (eq(node.resource_type, "test")) {
            if (dialect == .postgres) try session.execute("release savepoint dxt_analysis_node");
            continue;
        }
        const source_columns = try columnsFromValue(allocator, field(analysis, "columns"));
        const relation_query = if (eq(node.resource_type, "snapshot")) try snapshotBindingQuery(allocator, node, rewritten) else rewritten;
        const columns = if (eq(node.resource_type, "snapshot")) snapshotRelationColumns(allocator, &session, dialect, node, relation_query, source_columns) catch |err| {
            try appendFailure(allocator, &nodes, &visible, selected_ids, node, try bindingDiagnostic(allocator, &session, compiled, err), compiled, runtime, graph, db_path, stderr);
            failed = true;
            try recover(&session, dialect);
            continue;
        } else source_columns;
        for (columns) |*column| if (column.origins.len == 0) {
            column.origins = try allocator.dupe(ir.Origin, &.{.{ .resource_id = node.unique_id, .column = column.name }});
        };
        try replaceCatalogNode(allocator, graph, &catalog, node, columns);
        const name = try std.fmt.allocPrint(allocator, "__dxt_bind_{s}", .{(try hash(allocator, node.unique_id))[0..16]});
        if (dialect == .duckdb) {
            const view = try std.fmt.allocPrint(allocator, "create or replace temporary view {s} as {s}", .{ try adapter.quoteIdentifier(allocator, name), relation_query });
            session.execute(view) catch |err| {
                // An error here is a failed binder relation, not a successful
                // analysis cache entry for downstream consumers.
                try appendFailure(allocator, &nodes, &visible, selected_ids, node, try bindingDiagnostic(allocator, &session, compiled, err), compiled, runtime, graph, db_path, stderr);
                failed = true;
                continue;
            };
        }
        try virtual.append(allocator, .{ .node = node, .name = name, .query = relation_query });
        if (dialect == .postgres) try session.execute("release savepoint dxt_analysis_node");
    }
    stats.elapsed_ms = @as(f64, @floatFromInt(std.Io.Clock.awake.now(runtime.io).nanoseconds - start)) / 1_000_000;
    var report = try toValue(allocator, .{ .schema_version = "dxt-sql-analysis-v1", .adapter_type = graph.adapter_type, .stats = stats, .nodes = @as(Value, .{ .object = visible }) });
    try sanitizeTree(allocator, &report, runtime, graph, db_path);
    const report_json = try stringify(allocator, report);
    try std.Io.Dir.cwd().createDirPath(runtime.io, target_dir);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = try std.fs.path.join(allocator, &.{ target_dir, "dxt_sql_analysis.json" }), .data = report_json });
    var safe_asts: std.json.ObjectMap = .empty;
    var ast_iterator = asts.iterator();
    while (ast_iterator.next()) |entry| {
        const before = try stringify(allocator, entry.value_ptr.*);
        var safe = try values.clone(allocator, entry.value_ptr.*);
        try sanitizeTreeMode(allocator, &safe, runtime, graph, db_path, true);
        if (eq(before, try stringify(allocator, safe))) try safe_asts.put(allocator, entry.key_ptr.*, safe);
    }
    var safe_nodes = try values.clone(allocator, .{ .object = nodes });
    try sanitizeTree(allocator, &safe_nodes, runtime, graph, db_path);
    const cache = try toValue(allocator, .{ .schema_version = "dxt-sql-analysis-v1", .adapter_type = graph.adapter_type, .nodes = safe_nodes, .asts = @as(Value, .{ .object = safe_asts }) });
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = cache_path, .data = try stringify(allocator, cache) });
    if (json_output) try stdout.print("{s}\n", .{report_json}) else try stdout.print("Analyzed {d} SQL resource(s): {d} parsed, {d} bound, {d} cached, {d} invalidated ({d:.2} ms)\n", .{ visible.count(), stats.parsed_nodes, stats.bound_nodes, stats.cache_hits, stats.invalidated_nodes, stats.elapsed_ms });
    if (failed) return error.SqlAnalysisFailure;
}

// Tests use the same DAG and read-only binder as model SQL, while their
// compiler keeps dbt's generic/singular contexts and arguments intact.
fn addTestNodes(graph: *types.Graph, selected_ids: []const []const u8) !void {
    const allocator = graph.allocator;
    for (graph.singular_tests.items) |test_node| {
        if (!test_node.enabled or !contains(selected_ids, test_node.unique_id)) continue;
        try graph.nodes.append(allocator, .{ .resource_type = "test", .package_name = test_node.package_name, .unique_id = test_node.unique_id, .name = test_node.name, .path = test_node.path, .original_file_path = test_node.original_file_path, .raw_code = test_node.raw_code, .depends_on = try duplicateList(allocator, test_node.depends_on.items), .macro_depends_on = try duplicateList(allocator, test_node.macro_depends_on.items), .effective_config = try testConfigValue(allocator, test_node.config) });
    }
    for (graph.tests.items) |test_node| {
        if (!test_node.enabled) continue;
        if (!contains(selected_ids, test_node.unique_id)) continue;
        try graph.nodes.append(allocator, .{ .resource_type = "test", .package_name = test_node.package_name, .unique_id = test_node.unique_id, .name = test_node.name, .path = test_node.path, .original_file_path = test_node.original_file_path, .raw_code = test_node.raw_code, .depends_on = try duplicateList(allocator, test_node.depends_on.items), .macro_depends_on = try duplicateList(allocator, test_node.macro_depends_on.items), .effective_config = try testConfigValue(allocator, test_node.config) });
    }
}
fn testConfigValue(allocator: std.mem.Allocator, config: types.GenericTestConfig) !Value {
    return try toValue(allocator, .{ .where = config.where, .limit = config.limit, .severity = config.severity, .warn_if = config.warn_if, .error_if = config.error_if, .store_failures = config.store_failures });
}
fn duplicateList(allocator: std.mem.Allocator, input: []const []const u8) !std.ArrayList([]const u8) {
    var result: std.ArrayList([]const u8) = .empty;
    try result.appendSlice(allocator, input);
    return result;
}
fn compileTest(allocator: std.mem.Allocator, graph: *const types.Graph, id: []const u8) ![]const u8 {
    for (graph.singular_tests.items) |*test_node| if (eq(test_node.unique_id, id)) return try compiler.compileSingularTest(allocator, graph, test_node);
    for (graph.tests.items) |*test_node| if (test_node.enabled and eq(test_node.unique_id, id)) return try compiler.compileGenericTest(allocator, graph, test_node);
    return error.UnresolvedTestNode;
}

fn loadCatalog(runtime: types.Runtime, graph: *const types.Graph, session: *adapter.Session) !std.ArrayList(ir.Relation) {
    const allocator = runtime.allocator;
    var result = try session.query(if (session.* == .postgres)
        "select current_database(),n.nspname,c.relname,a.attname,format_type(a.atttypid,a.atttypmod),case when a.attnotnull then 'NO' else 'YES' end from pg_catalog.pg_attribute a join pg_catalog.pg_class c on c.oid=a.attrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace where a.attnum>0 and not a.attisdropped and c.relkind in ('r','v','m','f','p') and n.nspname not in ('pg_catalog','information_schema') order by n.nspname,c.relname,a.attnum"
    else
        "select table_catalog, table_schema, table_name, column_name, data_type, is_nullable from information_schema.columns where table_schema not in ('pg_catalog','information_schema') order by table_catalog,table_schema,table_name,ordinal_position");
    defer result.deinit(allocator);
    var catalog: std.ArrayList(ir.Relation) = .empty;
    var columns: std.ArrayList(ir.Column) = .empty;
    var last_key: []const u8 = "";
    for (result.rows) |row| {
        const database = row[0] orelse "";
        const schema = row[1] orelse "";
        const identifier = row[2] orelse "";
        const key = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ database, schema, identifier });
        if (!eq(key, last_key)) {
            if (catalog.items.len != 0) catalog.items[catalog.items.len - 1].columns = try columns.toOwnedSlice(allocator);
            var resource_id: []const u8 = try std.fmt.allocPrint(allocator, "relation.{s}", .{key});
            for (graph.sources.items) |source| if (eq(compiler.sourceIdentifier(&source), identifier) and eq(compiler.sourceSchemaName(&source), schema) and (compiler.sourceDatabaseName(&source) == null or eq(compiler.sourceDatabaseName(&source).?, database))) {
                resource_id = source.unique_id;
                break;
            };
            try catalog.append(allocator, .{ .resource_id = try allocator.dupe(u8, resource_id), .catalog = try allocator.dupe(u8, database), .schema = try allocator.dupe(u8, schema), .identifier = try allocator.dupe(u8, identifier), .columns = &.{} });
            last_key = key;
        }
        const name = try allocator.dupe(u8, row[3] orelse "");
        try columns.append(allocator, .{ .name = name, .data_type = try allocator.dupe(u8, row[4] orelse "UNKNOWN"), .nullable = !eq(row[5] orelse "YES", "NO"), .origins = try allocator.dupe(ir.Origin, &.{.{ .resource_id = catalog.items[catalog.items.len - 1].resource_id, .column = name }}) });
    }
    if (catalog.items.len != 0) catalog.items[catalog.items.len - 1].columns = try columns.toOwnedSlice(allocator);
    return catalog;
}

fn bind(allocator: std.mem.Allocator, session: *adapter.Session, dialect: parser.Dialect, query: []const u8) ![]ir.Column {
    const command = if (dialect == .duckdb) try std.fmt.allocPrint(allocator, "describe {s}", .{query}) else try std.fmt.allocPrint(allocator, "select * from ({s}) __dxt_bind_output limit 0", .{query});
    var output = try session.query(command);
    defer output.deinit(allocator);
    var columns: std.ArrayList(ir.Column) = .empty;
    if (dialect == .duckdb) {
        for (output.rows) |row| try columns.append(allocator, .{ .name = try allocator.dupe(u8, row[0] orelse ""), .data_type = try allocator.dupe(u8, row[1] orelse "UNKNOWN"), .nullable = !eq(row[2] orelse "YES", "NO") });
    } else {
        for (output.columns) |column| {
            var type_result = try session.query(try std.fmt.allocPrint(allocator, "select format_type({d},{d})", .{ column.native_type, column.native_type_modifier }));
            defer type_result.deinit(allocator);
            try columns.append(allocator, .{ .name = try allocator.dupe(u8, column.name), .data_type = try allocator.dupe(u8, type_result.firstScalar() orelse "UNKNOWN") });
        }
    }
    return try columns.toOwnedSlice(allocator);
}
fn explain(allocator: std.mem.Allocator, session: *adapter.Session, dialect: parser.Dialect, query: []const u8) !Value {
    var output = try session.query(try std.fmt.allocPrint(allocator, "explain ({s}format json) {s}", .{ if (dialect == .postgres) "verbose, " else "", query }));
    defer output.deinit(allocator);
    const raw = if (dialect == .postgres) output.firstScalar() else if (output.rows.len != 0 and output.rows[0].len > 1) output.rows[0][1] else null;
    const result = try std.json.parseFromSlice(Value, allocator, raw orelse return error.InvalidSqlExplain, .{ .allocate = .alloc_always });
    defer result.deinit();
    return try values.clone(allocator, result.value);
}

fn collectFunctions(allocator: std.mem.Allocator, session: *adapter.Session, dialect: parser.Dialect, original: []const u8, ast: Value, root: Value, catalog: []const ir.Relation, result: *std.ArrayList(ir.FunctionBinding)) anyerror!void {
    const function = parser.tableFunction(ast, dialect);
    if (function != .null) {
        const offset = parser.location(function);
        const end = try functionEnd(original, offset);
        const ordinality = if (dialect == .duckdb) eq(text(field(ast, "with_ordinality")), "WITH_ORDINALITY") else field(field(ast, "RangeFunction"), "ordinality") == .bool and field(field(ast, "RangeFunction"), "ordinality").bool;
        var replacements: std.ArrayList(Replacement) = .empty;
        try functionArgumentReplacements(allocator, original, function, dialect, root, catalog, &replacements);
        const fragment = try rewriteSpan(allocator, original, offset, end, replacements.items);
        const query = try std.fmt.allocPrint(allocator, "select * from {s}{s}", .{ fragment, if (ordinality) " with ordinality" else "" });
        const columns = try bind(allocator, session, dialect, query);
        const name = if (dialect == .duckdb) text(field(function, "function_name")) else if (items(field(function, "funcname")).len != 0) text(field(field(items(field(function, "funcname"))[0], "String"), "sval")) else "";
        var input: ?ir.Input = null;
        if (std.mem.startsWith(u8, name, "read_") or eq(name, "postgres_scan") or eq(name, "sqlite_scan")) {
            const id = try std.fmt.allocPrint(allocator, "external.{s}.{s}.{s}", .{ @tagName(dialect), name, (try hash(allocator, original[offset..end]))[0..16] });
            for (columns) |*column| column.origins = try allocator.dupe(ir.Origin, &.{.{ .resource_id = id, .column = column.name }});
            input = .{ .resource_id = id, .catalog = "", .schema = "", .identifier = name, .offset = offset };
        }
        try result.append(allocator, .{ .offset = offset, .columns = columns, .input = input });
    }
    switch (ast) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| try collectFunctions(allocator, session, dialect, original, entry.value_ptr.*, root, catalog, result);
        },
        .array => |array| for (array.items) |child| try collectFunctions(allocator, session, dialect, original, child, root, catalog, result),
        else => {},
    }
}
// Bind a lateral function's schema using the catalog types of its correlated
// arguments. Its original expression and origins remain in the logical IR.
fn functionArgumentReplacements(allocator: std.mem.Allocator, original: []const u8, ast: Value, dialect: parser.Dialect, root: Value, catalog: []const ir.Relation, out: *std.ArrayList(Replacement)) anyerror!void {
    const references = if (dialect == .duckdb and eq(text(field(ast, "class")), "COLUMN_REF")) items(field(ast, "column_names")) else if (dialect == .postgres) items(field(field(ast, "ColumnRef"), "fields")) else &.{};
    if (references.len != 0) {
        const name = if (dialect == .duckdb) text(references[references.len - 1]) else text(field(field(references[references.len - 1], "String"), "sval"));
        const qualifier = if (references.len > 1) if (dialect == .duckdb) text(references[references.len - 2]) else text(field(field(references[references.len - 2], "String"), "sval")) else "";
        var matched: ?ir.Column = null;
        for (catalog) |relation| {
            if (!relationUsed(root, dialect, relation, qualifier)) continue;
            for (relation.columns) |column| if (eq(column.name, name)) {
                if (matched != null and !eq(matched.?.data_type, column.data_type)) return error.SqlLineageAmbiguousFunctionArgument;
                matched = column;
            };
        }
        const column = matched orelse return error.SqlLineageUnresolvedFunctionArgument;
        const position = parser.location(if (dialect == .postgres) field(ast, "ColumnRef") else ast);
        if (position >= original.len) return error.InvalidSqlAstLocation;
        try out.append(allocator, .{ .start = position, .end = identifierEnd(original, position), .value = try std.fmt.allocPrint(allocator, "cast(null as {s})", .{column.data_type}) });
        return;
    }
    switch (ast) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| try functionArgumentReplacements(allocator, original, entry.value_ptr.*, dialect, root, catalog, out);
        },
        .array => |array| for (array.items) |child| try functionArgumentReplacements(allocator, original, child, dialect, root, catalog, out),
        else => {},
    }
}
fn relationUsed(ast: Value, dialect: parser.Dialect, relation: ir.Relation, qualifier: []const u8) bool {
    const node = if (dialect == .duckdb and eq(text(field(ast, "type")), "BASE_TABLE")) ast else if (dialect == .postgres) field(ast, "RangeVar") else .null;
    if (node != .null) {
        const name = text(field(node, if (dialect == .duckdb) "table_name" else "relname"));
        const schema = text(field(node, if (dialect == .duckdb) "schema_name" else "schemaname"));
        const database = text(field(node, if (dialect == .duckdb) "catalog_name" else "catalogname"));
        const alias = if (dialect == .duckdb) text(field(node, "alias")) else text(field(field(node, "alias"), "aliasname"));
        if (eq(name, relation.identifier) and (schema.len == 0 or eq(schema, relation.schema)) and (database.len == 0 or eq(database, relation.catalog)) and (qualifier.len == 0 or eq(qualifier, if (alias.len != 0) alias else name))) return true;
    }
    switch (ast) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| if (relationUsed(entry.value_ptr.*, dialect, relation, qualifier)) return true;
        },
        .array => |array| for (array.items) |child| if (relationUsed(child, dialect, relation, qualifier)) return true,
        else => {},
    }
    return false;
}
fn rewriteSpan(allocator: std.mem.Allocator, original: []const u8, start: usize, end: usize, replacements: []Replacement) ![]const u8 {
    std.mem.sort(Replacement, replacements, {}, struct {
        fn less(_: void, left: Replacement, right: Replacement) bool {
            return left.start < right.start;
        }
    }.less);
    var output: std.Io.Writer.Allocating = .init(allocator);
    var cursor = start;
    for (replacements) |replacement| {
        if (replacement.start < cursor or replacement.end > end) return error.InvalidSqlAstLocation;
        try output.writer.writeAll(original[cursor..replacement.start]);
        try output.writer.writeAll(replacement.value);
        cursor = replacement.end;
    }
    try output.writer.writeAll(original[cursor..end]);
    return try output.toOwnedSlice();
}
// Delimit a function already identified by the native grammar. This renderer
// preserves authored arguments; it does not recognize SQL statements or refs.
fn functionEnd(query: []const u8, start: usize) !usize {
    var depth: usize = 0;
    var opened = false;
    var index = start;
    while (index < query.len) : (index += 1) {
        const byte = query[index];
        if (byte == '-' and index + 1 < query.len and query[index + 1] == '-') {
            while (index < query.len and query[index] != '\n') index += 1;
            continue;
        }
        if (byte == '/' and index + 1 < query.len and query[index + 1] == '*') {
            var comments: usize = 1;
            index += 2;
            while (index + 1 < query.len and comments != 0) {
                if (query[index] == '/' and query[index + 1] == '*') {
                    comments += 1;
                    index += 2;
                } else if (query[index] == '*' and query[index + 1] == '/') {
                    comments -= 1;
                    index += 2;
                } else index += 1;
            }
            if (comments != 0) return error.InvalidSqlAstLocation;
            index -= 1;
            continue;
        }
        if (byte == '\'' or byte == '"') {
            const escaped = byte == '\'' and index != 0 and (query[index - 1] == 'E' or query[index - 1] == 'e');
            index += 1;
            while (index < query.len) : (index += 1) {
                if (escaped and query[index] == '\\' and index + 1 < query.len) {
                    index += 1;
                    continue;
                }
                if (query[index] == byte) {
                    if (index + 1 < query.len and query[index + 1] == byte) {
                        index += 1;
                        continue;
                    }
                    break;
                }
            }
            continue;
        }
        if (byte == '$') {
            var delimiter_end = index + 1;
            while (delimiter_end < query.len and (std.ascii.isAlphanumeric(query[delimiter_end]) or query[delimiter_end] == '_')) delimiter_end += 1;
            if (delimiter_end < query.len and query[delimiter_end] == '$') {
                const delimiter = query[index .. delimiter_end + 1];
                const close = std.mem.indexOfPos(u8, query, delimiter_end + 1, delimiter) orelse return error.InvalidSqlAstLocation;
                index = close + delimiter.len - 1;
                continue;
            }
        }
        if (byte == '(') {
            depth += 1;
            opened = true;
        }
        if (byte == ')') {
            if (depth == 0) return error.InvalidSqlAstLocation;
            depth -= 1;
            if (opened and depth == 0) return index + 1;
        }
    }
    return error.InvalidSqlAstLocation;
}

fn snapshotBindingQuery(allocator: std.mem.Allocator, node: *const types.Node, query: []const u8) ![]const u8 {
    const config = node.snapshot_config orelse return error.InvalidSnapshotConfig;
    const names = config.meta_columns;
    const updated = config.updated_at orelse "current_timestamp::timestamp";
    return try std.fmt.allocPrint(allocator, "select s.*,cast(null as varchar) as {s},({s}) as {s},({s}) as {s},nullif(({s}),({s})) as {s}{s} from ({s}) s", .{
        try adapter.quoteIdentifier(allocator, names.dbt_scd_id),                                                                                                                                                   updated, try adapter.quoteIdentifier(allocator, names.dbt_updated_at), updated, try adapter.quoteIdentifier(allocator, names.dbt_valid_from), updated, updated, try adapter.quoteIdentifier(allocator, names.dbt_valid_to),
        if (config.hard_deletes != null and eq(config.hard_deletes.?, "new_record")) try std.fmt.allocPrint(allocator, ",'False' as {s}", .{try adapter.quoteIdentifier(allocator, names.dbt_is_deleted)}) else "", query,
    });
}
fn snapshotRelationColumns(allocator: std.mem.Allocator, session: *adapter.Session, dialect: parser.Dialect, node: *const types.Node, query: []const u8, source: []const ir.Column) ![]ir.Column {
    const typed = try bind(allocator, session, dialect, query);
    if (typed.len < source.len) return error.SqlLineageOutputMismatch;
    for (typed[0..source.len], source) |*column, original| column.origins = original.origins;
    const config = node.snapshot_config.?;
    for (typed[source.len..]) |*column| {
        // SCD identity and validity are produced by snapshot materialization;
        // preserve that producer identity rather than invent a source field.
        column.origins = try allocator.dupe(ir.Origin, &.{.{ .resource_id = node.unique_id, .column = column.name }});
        if (config.updated_at) |updated| if (eq(column.name, config.meta_columns.dbt_updated_at) or eq(column.name, config.meta_columns.dbt_valid_from)) {
            for (source) |original| if (eq(original.name, updated)) {
                column.origins = original.origins;
                break;
            };
        };
    }
    return typed;
}

fn replaceCatalogNode(allocator: std.mem.Allocator, graph: *const types.Graph, catalog: *std.ArrayList(ir.Relation), node: *const types.Node, columns: []const ir.Column) !void {
    const database = compiler.relationDatabaseForNode(graph, node) orelse "";
    const schema = try compiler.relationSchemaForNode(allocator, graph, node);
    const identifier = compiler.relationIdentifierForNode(node);
    const relation = ir.Relation{ .resource_id = node.unique_id, .catalog = database, .schema = schema, .identifier = identifier, .columns = columns };
    for (catalog.items) |*existing| if (eq(existing.schema, schema) and eq(existing.identifier, identifier) and (database.len == 0 or eq(existing.catalog, database))) {
        existing.* = relation;
        return;
    };
    try catalog.append(allocator, relation);
}

fn rewriteRelations(allocator: std.mem.Allocator, original: []const u8, ast: Value, dialect: parser.Dialect, graph: *const types.Graph, virtual: []const Virtual) ![]const u8 {
    var replacements: std.ArrayList(Replacement) = .empty;
    try collectReplacements(allocator, original, ast, dialect, graph, virtual, &replacements);
    std.mem.sort(Replacement, replacements.items, {}, struct {
        fn less(_: void, a: Replacement, b: Replacement) bool {
            return a.start < b.start;
        }
    }.less);
    var output: std.Io.Writer.Allocating = .init(allocator);
    var cursor: usize = 0;
    for (replacements.items) |replacement| {
        if (replacement.start < cursor) continue;
        try output.writer.writeAll(original[cursor..replacement.start]);
        try output.writer.writeAll(replacement.value);
        cursor = replacement.end;
    }
    try output.writer.writeAll(original[cursor..]);
    return try output.toOwnedSlice();
}
fn collectReplacements(allocator: std.mem.Allocator, original: []const u8, ast: Value, dialect: parser.Dialect, graph: *const types.Graph, virtual: []const Virtual, out: *std.ArrayList(Replacement)) anyerror!void {
    const relation = if (dialect == .duckdb and eq(text(field(ast, "type")), "BASE_TABLE")) ast else if (dialect == .postgres) field(ast, "RangeVar") else .null;
    if (relation != .null) {
        const identifier = text(field(relation, if (dialect == .duckdb) "table_name" else "relname"));
        const schema = text(field(relation, if (dialect == .duckdb) "schema_name" else "schemaname"));
        const database = text(field(relation, if (dialect == .duckdb) "catalog_name" else "catalogname"));
        for (virtual) |candidate| {
            const target_schema = try compiler.relationSchemaForNode(allocator, graph, candidate.node);
            const target_database = compiler.relationDatabaseForNode(graph, candidate.node) orelse "";
            if (!eq(identifier, compiler.relationIdentifierForNode(candidate.node)) or (schema.len != 0 and !eq(schema, target_schema)) or (database.len != 0 and !eq(database, target_database))) continue;
            // Unqualified CTE names remain lexical bindings; only compiled
            // physical refs or an exact schema-qualified relation are rewritten.
            if (schema.len == 0 and database.len == 0) continue;
            const offset = parser.location(relation);
            if (offset >= original.len) return error.InvalidSqlAstLocation;
            try out.append(allocator, .{ .start = offset, .end = identifierEnd(original, offset), .value = try adapter.quoteIdentifier(allocator, candidate.name) });
            break;
        }
    }
    switch (ast) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| try collectReplacements(allocator, original, entry.value_ptr.*, dialect, graph, virtual, out);
        },
        .array => |array| for (array.items) |entry| try collectReplacements(allocator, original, entry, dialect, graph, virtual, out),
        else => {},
    }
}
fn identifierEnd(query: []const u8, start: usize) usize {
    var index = start;
    while (index < query.len) {
        if (query[index] == '"') {
            index += 1;
            while (index < query.len) {
                if (query[index] == '"') {
                    index += 1;
                    if (index < query.len and query[index] == '"') {
                        index += 1;
                        continue;
                    }
                    break;
                }
                index += 1;
            }
        } else {
            const before = index;
            while (index < query.len and (std.ascii.isAlphanumeric(query[index]) or query[index] == '_' or query[index] == '$' or query[index] >= 128)) index += 1;
            if (before == index) return index;
        }
        var dot = index;
        while (dot < query.len and std.ascii.isWhitespace(query[dot])) dot += 1;
        if (dot == query.len or query[dot] != '.') break;
        index = dot + 1;
        while (index < query.len and std.ascii.isWhitespace(query[index])) index += 1;
    }
    return index;
}
fn withVirtualQueries(allocator: std.mem.Allocator, query: []const u8, virtual: []const Virtual) ![]const u8 {
    if (virtual.len == 0) return query;
    var output: std.Io.Writer.Allocating = .init(allocator);
    try output.writer.writeAll("with ");
    for (virtual, 0..) |candidate, index| {
        if (index != 0) try output.writer.writeByte(',');
        try output.writer.print("{s} as ({s})", .{ try adapter.quoteIdentifier(allocator, candidate.name), candidate.query });
    }
    // A nested SELECT preserves authored WITH/RECURSIVE scope and shadowing.
    try output.writer.print(" select * from ({s}) __dxt_analysis_query", .{query});
    return try output.toOwnedSlice();
}

fn requiredOrder(allocator: std.mem.Allocator, graph: *const types.Graph, selected: []const []const u8) ![]const usize {
    const colors = try allocator.alloc(u8, graph.nodes.items.len);
    @memset(colors, 0);
    var order: std.ArrayList(usize) = .empty;
    for (graph.nodes.items, 0..) |node, index| if (node.enabled and contains(selected, node.unique_id)) try visit(graph, allocator, index, colors, &order);
    return try order.toOwnedSlice(allocator);
}
fn visit(graph: *const types.Graph, allocator: std.mem.Allocator, index: usize, colors: []u8, order: *std.ArrayList(usize)) anyerror!void {
    if (colors[index] == 2) return;
    if (colors[index] == 1) return error.CyclicModelDependency;
    colors[index] = 1;
    for (graph.nodes.items[index].depends_on.items) |id| for (graph.nodes.items, 0..) |dependency, child| if (dependency.enabled and eq(dependency.unique_id, id)) {
        try visit(graph, allocator, child, colors, order);
        break;
    };
    colors[index] = 2;
    try order.append(allocator, index);
}
fn nodeFingerprint(runtime: types.Runtime, graph: *const types.Graph, node: *const types.Node, compiled: []const u8, parser_signature: []const u8, ast: Value, catalog: []const ir.Relation, completed: std.json.ObjectMap) ![]const u8 {
    const allocator = runtime.allocator;
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digest.update("dxt-sql-analysis-v1-ir-4");
    digest.update(parser_signature);
    digest.update(graph.adapter_type);
    if (graph.connection_info) |connection| digest.update(connection);
    if (graph.target_context != .null) digest.update(try stringify(allocator, graph.target_context));
    digest.update(node.unique_id);
    digest.update(node.raw_code);
    digest.update(compiled);
    digest.update(try stringify(allocator, node.effective_config));
    for (node.depends_on.items) |id| digest.update(text(field(completed.get(id) orelse .null, "fingerprint")));
    for (node.macro_depends_on.items) |id| try hashMacro(&digest, graph, id, 0);
    // External relation metadata is an input even when SQL used a direct table
    // name rather than source(). Model schemas are hashed through their DAG.
    for (catalog) |relation| {
        if (completed.contains(relation.resource_id)) continue;
        digest.update(relation.resource_id);
        for (relation.columns) |column| {
            digest.update(column.name);
            digest.update(column.data_type);
            digest.update(if (column.nullable) "?" else "!");
        }
    }
    try hashFileInputs(runtime, ast, &digest);
    return try digestString(allocator, &digest);
}
// Literal file inputs found in the native tree participate in invalidation.
// A schema change in read_csv/read_json/read_parquet must rebind the consumer.
fn hashFileInputs(runtime: types.Runtime, ast: Value, digest: *std.crypto.hash.sha2.Sha256) anyerror!void {
    switch (ast) {
        .string => |path| {
            if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return;
            const file = std.Io.Dir.cwd().openFile(runtime.io, path, .{}) catch return;
            defer file.close(runtime.io);
            const stat = file.stat(runtime.io) catch return;
            if (stat.kind != .file) return;
            digest.update(path);
            digest.update(std.mem.asBytes(&stat.size));
            digest.update(std.mem.asBytes(&stat.mtime.nanoseconds));
            // Content protects same-size/coarse-mtime edits for ordinary SQL
            // fixture inputs; large files use the filesystem version metadata.
            if (stat.size <= 64 * 1024 * 1024) {
                const bytes = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(64 * 1024 * 1024)) catch return;
                defer runtime.allocator.free(bytes);
                digest.update(bytes);
            }
        },
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| try hashFileInputs(runtime, entry.value_ptr.*, digest);
        },
        .array => |array| for (array.items) |value| try hashFileInputs(runtime, value, digest),
        else => {},
    }
}
fn hashMacro(digest: *std.crypto.hash.sha2.Sha256, graph: *const types.Graph, id: []const u8, depth: usize) !void {
    if (depth > 64) return error.SqlAnalysisDepthExceeded;
    for (graph.macros.items) |macro| if (eq(macro.unique_id, id)) {
        digest.update(id);
        digest.update(macro.macro_sql);
        for (macro.macro_depends_on.items) |child| try hashMacro(digest, graph, child, depth + 1);
        return;
    };
}
fn hash(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    digest.update(bytes);
    return try digestString(allocator, &digest);
}
fn digestString(allocator: std.mem.Allocator, digest: *std.crypto.hash.sha2.Sha256) ![]const u8 {
    const bytes = digest.finalResult();
    return try allocator.dupe(u8, &std.fmt.bytesToHex(bytes, .lower));
}

fn readCache(runtime: types.Runtime, path: []const u8) !Value {
    const bytes = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(64 * 1024 * 1024)) catch return .null;
    const document = std.json.parseFromSlice(Value, runtime.allocator, bytes, .{ .allocate = .alloc_always }) catch return .null;
    defer document.deinit();
    if (!eq(text(field(document.value, "schema_version")), "dxt-sql-analysis-v1")) return .null;
    return try values.clone(runtime.allocator, document.value);
}
fn columnsFromValue(allocator: std.mem.Allocator, value: Value) ![]ir.Column {
    var result: std.ArrayList(ir.Column) = .empty;
    for (items(value)) |column| {
        var origins: std.ArrayList(ir.Origin) = .empty;
        for (items(field(column, "origins"))) |origin| try origins.append(allocator, .{ .resource_id = text(field(origin, "resource_id")), .column = text(field(origin, "column")) });
        try result.append(allocator, .{ .name = text(field(column, "name")), .data_type = text(field(column, "data_type")), .nullable = field(column, "nullable") != .bool or field(column, "nullable").bool, .origins = try origins.toOwnedSlice(allocator) });
    }
    return try result.toOwnedSlice(allocator);
}
fn appendFailure(allocator: std.mem.Allocator, nodes: *std.json.ObjectMap, visible: *std.json.ObjectMap, selected: []const []const u8, node: *const types.Node, diagnostic: parser.Diagnostic, query: []const u8, runtime: types.Runtime, graph: *const types.Graph, db_path: []const u8, stderr: *std.Io.Writer) !void {
    const offset = @min(diagnostic.offset, query.len);
    var line: usize = 1;
    var column: usize = 1;
    for (query[0..offset]) |byte| if (byte == '\n') {
        line += 1;
        column = 1;
    } else {
        column += 1;
    };
    var entry = try toValue(allocator, .{ .unique_id = node.unique_id, .resource_type = node.resource_type, .path = node.original_file_path, .status = "error", .fingerprint = "", .compiled_sql = query, .columns = [_]ir.Column{}, .inputs = [_]ir.Input{}, .operators = [_]ir.Operator{}, .predicate_origins = [_]ir.Origin{}, .plan = @as(Value, .null), .diagnostics = [_]struct { code: []const u8, message: []const u8, offset: usize, line: usize, column: usize, coordinate_space: []const u8 }{.{ .code = diagnostic.code, .message = diagnostic.message, .offset = offset, .line = line, .column = column, .coordinate_space = "compiled_sql" }} });
    try sanitizeTree(allocator, &entry, runtime, graph, db_path);
    try nodes.put(allocator, node.unique_id, entry);
    if (contains(selected, node.unique_id)) try visible.put(allocator, node.unique_id, entry);
    const details = items(field(entry, "diagnostics"))[0];
    try stderr.print("{s}:{d}:{d}: {s}: {s}\n", .{ node.original_file_path, line, column, diagnostic.code, text(field(details, "message")) });
}
fn bindingDiagnostic(allocator: std.mem.Allocator, session: *const adapter.Session, query: []const u8, err: anyerror) !parser.Diagnostic {
    const raw = session.lastError() orelse @errorName(err);
    const message_end = std.mem.indexOfScalar(u8, raw, '\n') orelse raw.len;
    var offset: usize = 0;
    if (session.* == .postgres) {
        if (session.postgres.last_error_position) |position| offset = position -| 1;
    }
    for ([_][]const u8{ "Referenced column \"", "column \"", "Ambiguous reference to column name \"" }) |prefix| if (std.mem.indexOf(u8, raw, prefix)) |begin| {
        const name_start = begin + prefix.len;
        const end = std.mem.indexOfScalarPos(u8, raw, name_start, '"') orelse continue;
        if (std.mem.indexOf(u8, query, raw[name_start..end])) |position| offset = position;
        break;
    };
    return .{ .code = if (std.mem.indexOf(u8, raw, "ambiguous") != null or std.mem.indexOf(u8, raw, "Ambiguous") != null) "AMBIGUOUS_COLUMN" else if (std.mem.indexOf(u8, raw, "column") != null) "UNRESOLVED_COLUMN" else "SQL_BINDING", .message = try allocator.dupe(u8, raw[0..message_end]), .offset = offset };
}
fn recover(session: *adapter.Session, dialect: parser.Dialect) !void {
    if (dialect == .postgres) try session.execute("rollback to savepoint dxt_analysis_node; release savepoint dxt_analysis_node");
}
fn sanitizeTree(allocator: std.mem.Allocator, value: *Value, runtime: types.Runtime, graph: *const types.Graph, db_path: []const u8) anyerror!void {
    return try sanitizeTreeMode(allocator, value, runtime, graph, db_path, false);
}
// Private native ASTs retain authored file names for replay. Connection strings
// and secret values are never persisted; public diagnostics also redact paths.
fn sanitizeTreeMode(allocator: std.mem.Allocator, value: *Value, runtime: types.Runtime, graph: *const types.Graph, db_path: []const u8, authored_paths: bool) anyerror!void {
    switch (value.*) {
        .string => |original| {
            var rendered = original;
            for ([_][]const u8{ graph.connection_info orelse "", db_path, if (runtime.invocation_options) |options| options.project_dir else "" }, 0..) |sensitive, index| if (sensitive.len > 1 and (index == 0 or (!authored_paths and std.fs.path.isAbsolute(sensitive)))) {
                rendered = try replace(allocator, rendered, sensitive, "[redacted]");
            };
            rendered = try redactCredentials(allocator, rendered, graph.connection_info orelse "");
            if (runtime.environment) |environment| {
                var it = environment.iterator();
                while (it.next()) |entry| if (std.mem.startsWith(u8, entry.key_ptr.*, "DBT_ENV_SECRET_") and entry.value_ptr.len != 0) {
                    rendered = try replace(allocator, rendered, entry.value_ptr.*, "[redacted]");
                };
            }
            value.* = .{ .string = rendered };
        },
        .object => |*object| {
            var it = object.iterator();
            while (it.next()) |entry| try sanitizeTreeMode(allocator, entry.value_ptr, runtime, graph, db_path, authored_paths);
        },
        .array => |*array| for (array.items) |*entry| try sanitizeTreeMode(allocator, entry, runtime, graph, db_path, authored_paths),
        else => {},
    }
}
// libpq connection values use single quotes and backslash escaping. Redact
// individual credential values even when a diagnostic prints only the value.
fn redactCredentials(allocator: std.mem.Allocator, original: []const u8, connection: []const u8) ![]const u8 {
    var rendered = original;
    var index: usize = 0;
    while (index < connection.len) {
        while (index < connection.len and std.ascii.isWhitespace(connection[index])) index += 1;
        const begin = index;
        while (index < connection.len and connection[index] != '=' and !std.ascii.isWhitespace(connection[index])) index += 1;
        const key = connection[begin..index];
        while (index < connection.len and std.ascii.isWhitespace(connection[index])) index += 1;
        if (index == connection.len or connection[index] != '=') break;
        index += 1;
        while (index < connection.len and std.ascii.isWhitespace(connection[index])) index += 1;
        const quoted = index < connection.len and connection[index] == '\'';
        if (quoted) index += 1;
        var decoded: std.Io.Writer.Allocating = .init(allocator);
        defer decoded.deinit();
        while (index < connection.len) {
            const byte = connection[index];
            index += 1;
            if ((quoted and byte == '\'') or (!quoted and std.ascii.isWhitespace(byte))) break;
            if (byte == '\\' and index < connection.len) {
                try decoded.writer.writeByte(connection[index]);
                index += 1;
            } else try decoded.writer.writeByte(byte);
        }
        if (eq(key, "password") or eq(key, "sslpassword") or eq(key, "sslkey") or eq(key, "passfile")) {
            if (decoded.written().len != 0) rendered = try replace(allocator, rendered, decoded.written(), "[redacted]");
        }
    }
    return rendered;
}

fn replace(allocator: std.mem.Allocator, original: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
    return try std.mem.replaceOwned(u8, allocator, original, needle, replacement);
}
fn toValue(allocator: std.mem.Allocator, data: anytype) !Value {
    const document = try std.json.parseFromSlice(Value, allocator, try std.json.Stringify.valueAlloc(allocator, data, .{}), .{ .allocate = .alloc_always });
    defer document.deinit();
    return try values.clone(allocator, document.value);
}
fn stringify(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
}
fn contains(values_list: []const []const u8, wanted: []const u8) bool {
    for (values_list) |value| if (eq(value, wanted)) return true;
    return false;
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn assertReadOnly(ast: Value, dialect: parser.Dialect) anyerror!void {
    const statements = items(field(ast, if (dialect == .duckdb) "statements" else "stmts"));
    if (statements.len != 1) return error.SqlAnalysisRequiresSingleQuery;
    if (dialect == .postgres and field(field(statements[0], "stmt"), "SelectStmt") == .null) return error.SqlAnalysisRequiresSelect;
    try rejectWrites(ast);
}
fn rejectWrites(value: Value) anyerror!void {
    switch (value) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                for ([_][]const u8{ "InsertStmt", "UpdateStmt", "DeleteStmt", "MergeStmt", "intoClause", "IntoClause" }) |forbidden| if (eq(entry.key_ptr.*, forbidden) and entry.value_ptr.* != .null) return error.SqlAnalysisReadOnly;
                try rejectWrites(entry.value_ptr.*);
            }
        },
        .array => |array| for (array.items) |child| try rejectWrites(child),
        else => {},
    }
}
const ReadonlyHost = struct {
    host: *commands.OperationHost,
    session: *adapter.Session,
    pg: *parser.Postgres,
    dialect: parser.Dialect,
    allocator: std.mem.Allocator,
    fn resolve(raw: *anyopaque, path: []const u8, allocator: std.mem.Allocator) anyerror!expression.Value {
        const self: *ReadonlyHost = @ptrCast(@alignCast(raw));
        const wrapped = self.host.host();
        return try wrapped.resolve(wrapped.context, path, allocator);
    }
    fn call(raw: *anyopaque, name: []const u8, arguments: []const expression.Argument, allocator: std.mem.Allocator) anyerror!expression.Value {
        const self: *ReadonlyHost = @ptrCast(@alignCast(raw));
        if (eq(name, "adapter.commit") or eq(name, "adapter.clear_transaction")) return .none;
        var args: std.ArrayList(expression.Argument) = .empty;
        try args.appendSlice(self.allocator, arguments);
        if (eq(name, "run_query") or eq(name, "statement")) {
            var query: ?[]const u8 = null;
            for (arguments, 0..) |argument, index| if ((argument.name != null and (eq(argument.name.?, "sql") or eq(argument.name.?, "caller_sql"))) or (argument.name == null and index == 0 and eq(name, "run_query"))) {
                if (argument.value == .string) query = argument.value.string;
            };
            const parsed = if (self.dialect == .duckdb) try parser.parseDuckDb(self.allocator, self.session, query orelse return error.InvalidJinjaArguments) else try self.pg.parse(self.allocator, query orelse return error.InvalidJinjaArguments);
            if (parsed.diagnostic != null) return error.SqlAnalysisReadOnly;
            try assertReadOnly(parsed.tree, self.dialect);
            if (eq(name, "statement")) {
                var overridden = false;
                for (args.items) |*argument| if (argument.name != null and eq(argument.name.?, "auto_begin")) {
                    argument.value = .{ .boolean = false };
                    overridden = true;
                };
                if (!overridden) try args.append(self.allocator, .{ .name = "auto_begin", .value = .{ .boolean = false } });
            }
        }
        const wrapped = self.host.host();
        return try wrapped.call(wrapped.context, name, args.items, allocator);
    }
};

test "AST relation rewriting respects quoted identifiers and qualification boundaries" {
    try std.testing.expectEqual(@as(usize, 20), identifierEnd("\"db\".\"s\".\"a\"\"quoted\" as a", 0));
    try std.testing.expectEqual(@as(usize, 5), identifierEnd("tbl.x where x=1", 0));
    try std.testing.expectEqual(@as(usize, 3), identifierEnd("tbl where x=1", 0));
}

test "native diagnostic projection redacts escaped connection credentials" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try redactCredentials(arena.allocator(), "failed: synthetic ' quote\\ key", "host='fixture' password='synthetic \\' quote\\\\ key'");
    try std.testing.expectEqualStrings("failed: [redacted]", result);
}
