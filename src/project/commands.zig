const std = @import("std");
const types = @import("types.zig");
const loader = @import("loader.zig");
const duckdb = @import("duckdb.zig");
const expression = @import("expression.zig");
const yaml = @import("yaml.zig");
const config_values = @import("config_value.zig");
const adapter = @import("adapter.zig");
const results = @import("run_results.zig");
const compiler = @import("compiler.zig");
const resolve = @import("resolve.zig");
const selector = @import("selector.zig");
const Runtime = types.Runtime;
const Options = types.Options;

pub fn debug(runtime: Runtime, options: Options, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    _ = stderr;
    var graph = try loader.loadConnectionGraph(runtime, options);
    defer graph.deinit();
    const db_path = try duckdb.databasePath(runtime.allocator, options.project_dir, &graph);
    defer runtime.allocator.free(db_path);
    try stdout.writeAll("Project configuration: OK\nProfile configuration: OK\n");
    try adapter.executeForGraph(runtime, &graph, db_path, "select 1");
    try stdout.writeAll("Connection test: OK\nAll checks passed\n");
}

pub fn validProjectName(name: []const u8) bool {
    if (name.len == 0 or !(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

pub fn initProject(runtime: Runtime, options: Options, stdout: *std.Io.Writer) !void {
    const name = options.command_name orelse return error.MissingCommandName;
    if (!validProjectName(name)) return error.InvalidInitName;
    const allocator = runtime.allocator;
    const root = try std.fs.path.join(allocator, &.{ options.project_dir, name });
    const profiles_dir = options.profiles_dir orelse root;
    const profiles_path = try std.fs.path.join(allocator, &.{ profiles_dir, "profiles.yml" });
    if (!options.skip_profile_setup) {
        if (std.Io.Dir.cwd().access(runtime.io, profiles_path, .{})) |_| return error.ProfileAlreadyExists else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }
    std.Io.Dir.cwd().createDir(runtime.io, root, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return error.ProjectAlreadyExists,
        else => return err,
    };
    errdefer std.Io.Dir.cwd().deleteTree(runtime.io, root) catch {};
    inline for (.{ "models", "seeds", "macros", "tests" }) |folder| {
        const path = try std.fs.path.join(allocator, &.{ root, folder });
        try std.Io.Dir.cwd().createDir(runtime.io, path, .default_dir);
    }
    const config = try std.fmt.allocPrint(allocator, "name: {s}\nversion: '1.0.0'\nconfig-version: 2\nprofile: {s}\nmodel-paths: ['models']\nseed-paths: ['seeds']\nmacro-paths: ['macros']\ntest-paths: ['tests']\nclean-targets: ['target', 'dbt_packages']\nmodels:\n  {s}:\n    +materialized: table\n", .{ name, name, name });
    try writeProjectFile(runtime, root, "dbt_project.yml", config);
    try writeProjectFile(runtime, root, "seeds/raw_customers.csv", "id,name\n1,Ada\n2,Grace\n");
    try writeProjectFile(runtime, root, "models/customers.sql", "select id, name from {{ ref('raw_customers') }}\n");
    try writeProjectFile(runtime, root, "models/schema.yml", "version: 2\nmodels:\n  - name: customers\n    columns:\n      - name: id\n        data_tests:\n          - not_null\n          - unique\n");
    try writeProjectFile(runtime, root, ".gitignore", "target/\ndbt_packages/\nlogs/\n*.duckdb\n*.duckdb.wal\n");
    if (!options.skip_profile_setup) {
        try std.Io.Dir.cwd().createDirPath(runtime.io, profiles_dir);
        const profile = try std.fmt.allocPrint(allocator, "{s}:\n  target: dev\n  outputs:\n    dev:\n      type: duckdb\n      path: {s}.duckdb\n      schema: main\n      threads: 1\n", .{ name, name });
        var file = try std.Io.Dir.cwd().createFile(runtime.io, profiles_path, .{ .exclusive = true });
        defer file.close(runtime.io);
        try file.writeStreamingAll(runtime.io, profile);
    }
    try stdout.print("Created project {s}\nRun dxt build --project-dir {s}\n", .{ name, root });
}

fn writeProjectFile(runtime: Runtime, root: []const u8, name: []const u8, content: []const u8) !void {
    const path = try std.fs.path.join(runtime.allocator, &.{ root, name });
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = path, .data = content });
}

pub fn writeResults(runtime: Runtime, target_dir: []const u8, rows: []const results.NodeResult) !void {
    if (!@import("cli_options.zig").writeJson(runtime)) return;
    try std.Io.Dir.cwd().createDirPath(runtime.io, target_dir);
    const path = try std.fs.path.join(runtime.allocator, &.{ target_dir, "run_results.json" });
    const content = try results.renderRunResultsForRuntime(runtime, rows);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = path, .data = content });
}

pub fn operation(runtime: Runtime, options: Options, graph: *types.Graph, target_dir: []const u8, stdout: *std.Io.Writer) !void {
    try @import("relation_cache.zig").configure(runtime, graph, null);
    defer @import("relation_cache.zig").writeEvents(runtime, graph, stdout) catch {};
    const name = options.command_name orelse return error.MissingCommandName;
    const id = if (std.mem.indexOfScalar(u8, name, '.')) |dot|
        resolve.findMacroIdByPackageAndName(graph, name[0..dot], name[dot + 1 ..])
    else
        resolve.findMacroIdForUnqualifiedNamespaceCall(graph, graph.project_name, name);
    const macro_id = id orelse return error.UnresolvedMacro;
    var kwargs = try parseArgs(runtime.allocator, options.command_args orelse "{}");
    defer config_values.deinit(runtime.allocator, &kwargs);
    const db_path = try duckdb.databasePath(runtime.allocator, target_dir, graph);
    var context = try OperationHost.init(runtime, graph, db_path, stdout);
    defer context.deinit();
    graph.execution_hooks = context.host();
    defer graph.execution_hooks = null;
    const output = compiler.renderOperation(runtime, graph, name, kwargs) catch |err| {
        if (err == error.OutOfMemory) return err;
        try writeResults(runtime, target_dir, &.{.{ .operation_id = macro_id, .status = "error", .failures = 1 }});
        return error.OperationFailure;
    };
    defer runtime.allocator.free(output);
    // dbt invokes the macro. Returned SQL is a value, not an executable job.
    try writeResults(runtime, target_dir, &.{.{ .operation_id = macro_id, .failures = 0 }});
    try stdout.print("Completed operation {s}\n", .{name});
}

const StoredValue = struct { name: []const u8, value: expression.Value, loaded: bool = false };
/// A native SQL host for operation macros and executable compiler contexts.
/// Results live for the host lifetime, including values retained by load_result.
pub const OperationHost = struct {
    context_values: std.json.Value = .null,
    runtime: Runtime,
    graph: *const types.Graph,
    db_path: []const u8,
    stdout: *std.Io.Writer,
    stored: std.ArrayList(StoredValue) = .empty,
    log_events: ?*std.ArrayList(results.LogMessage) = null,
    session: ?adapter.Session = null,
    borrowed_session: ?*adapter.Session = null,
    owned_pool: ?*adapter.DuckDBPool = null,
    values: std.heap.ArenaAllocator,

    transaction_open: bool = false,
    current_node: ?*const types.Node = null,
    adapter_state: @import("adapter_context.zig").State = .{},
    last_response: expression.Value = .none,

    /// Construct the context without connecting. Offline compilation remains
    /// available; the first database callback opens or borrows a session.
    pub fn initLazy(runtime: Runtime, graph: *const types.Graph, db_path: []const u8, stdout: *std.Io.Writer) !OperationHost {
        return .{ .runtime = runtime, .graph = graph, .db_path = db_path, .stdout = stdout, .values = std.heap.ArenaAllocator.init(runtime.allocator), .borrowed_session = runtime.adapter_session };
    }

    pub fn init(runtime: Runtime, graph: *const types.Graph, db_path: []const u8, stdout: *std.Io.Writer) !OperationHost {
        var self = try initLazy(runtime, graph, db_path, stdout);
        errdefer self.deinit();
        try self.ensureSession();
        return self;
    }

    fn ensureSession(self: *OperationHost) !void {
        if (self.currentSession() != null) return;
        const runtime = self.runtime;
        if (self.runtime.duckdb_pool == null and std.mem.eql(u8, self.graph.adapter_type, "duckdb")) {
            const pool = try runtime.allocator.create(adapter.DuckDBPool);
            pool.* = adapter.DuckDBPool.init(runtime.allocator, runtime.io, runtime.environment);
            self.owned_pool = pool;
            self.runtime.duckdb_pool = pool;
        }
        self.session = adapter.openSession(self.runtime, self.graph, self.db_path) catch |err| switch (err) {
            error.NativeDuckDbLibraryNotFound => blk: {
                if (runtime.environment) |environment| {
                    if (environment.get("DXT_DUCKDB_LIBRARY") != null) return err;
                    if (environment.get("DXT_DUCKDB_BACKEND")) |backend| if (std.mem.eql(u8, backend, "native")) return err;
                }
                break :blk null;
            },
            else => return err,
        };
        if (self.session) |*session| {
            if (runtime.cancellation_token) |token| session.setCancellationToken(token);
            if (runtime.session_observer) |observer| observer.changed(observer.context, session);
        }
    }

    fn currentSession(self: *OperationHost) ?*adapter.Session {
        if (self.borrowed_session) |session| return session;
        return if (self.session) |*session| session else null;
    }

    pub fn commit(self: *OperationHost) !void {
        if (!self.transaction_open) return;
        const session = self.currentSession() orelse return error.NativeDuckDbPoolRequired;
        try session.commit();
        self.transaction_open = false;
    }

    pub fn rollback(self: *OperationHost) !void {
        if (!self.transaction_open) return;
        const session = self.currentSession() orelse return error.NativeDuckDbPoolRequired;
        try session.rollback();
        self.transaction_open = false;
    }

    pub fn host(self: *OperationHost) expression.Host {
        return .{ .context = self, .resolve = resolveValue, .call = call, .set_node = setNode };
    }

    fn setNode(raw: *anyopaque, node: ?*const anyopaque) ?*const anyopaque {
        const self: *OperationHost = @ptrCast(@alignCast(raw));
        const previous = self.current_node;
        self.current_node = if (node) |value| @ptrCast(@alignCast(value)) else null;
        return previous;
    }

    pub fn deinit(self: *OperationHost) void {
        if (self.session != null) if (self.runtime.session_observer) |observer| observer.changed(observer.context, null);
        self.rollback() catch {};
        if (self.session) |*session| session.deinit();
        if (self.owned_pool) |pool| {
            pool.deinit();
            self.runtime.allocator.destroy(pool);
        }
        self.stored.deinit(self.runtime.allocator);
        self.adapter_state.deinit(self.values.allocator());
        self.values.deinit();
    }

    fn resolveValue(raw: *anyopaque, path: []const u8, allocator: std.mem.Allocator) anyerror!expression.Value {
        const self: *OperationHost = @ptrCast(@alignCast(raw));
        return try @import("hook_operations.zig").resolve(allocator, self.context_values, path);
    }

    fn call(raw: *anyopaque, name: []const u8, args: []const expression.Argument, allocator: std.mem.Allocator) anyerror!expression.Value {
        const self: *OperationHost = @ptrCast(@alignCast(raw));
        if (try @import("adapter_context.zig").call(self.values.allocator(), self.graph, &self.adapter_state, .{ .context = self, .render = renderAdapterMacro }, name, args)) |value| return value;
        if (std.mem.eql(u8, name, "adapter.get_column_schema_from_query")) {
            const sql = argument(args, "sql", 0) orelse return error.InvalidJinjaArguments;
            if (sql != .string) return error.InvalidJinjaArguments;
            try self.ensureSession();
            var runtime = self.runtime;
            runtime.adapter_session = self.currentSession();
            return try @import("query_schema.zig").columns(self.values.allocator(), runtime, self.graph, self.db_path, sql.string);
        }
        if (std.mem.eql(u8, name, "log") or std.mem.eql(u8, name, "print")) {
            const message = argument(args, "msg", 0) orelse return error.InvalidJinjaArguments;
            const is_print = std.mem.eql(u8, name, "print");
            if (is_print and !self.graph.command_options.print_enabled) return .{ .string = "" };
            const info: expression.Value = argument(args, "info", 1) orelse .{ .boolean = false };
            const level = if (is_print or info.truthy()) "info" else "debug";
            const text = try message.text(allocator);
            if (self.log_events) |events| {
                const owned = try self.runtime.allocator.dupe(u8, text);
                errdefer self.runtime.allocator.free(owned);
                try events.append(self.runtime.allocator, .{ .message = owned, .level = level, .is_print = is_print });
            } else {
                try self.stdout.writeAll("{\"data\":{\"msg\":");
                try std.json.Stringify.value(text, .{}, self.stdout);
                try self.stdout.writeAll("},\"info\":{\"name\":");
                try std.json.Stringify.value(if (is_print) "PrintEvent" else if (std.mem.eql(u8, level, "debug")) "JinjaLogDebug" else "JinjaLogInfo", .{}, self.stdout);
                try self.stdout.writeAll(",\"level\":");
                try std.json.Stringify.value(level, .{}, self.stdout);
                try self.stdout.writeAll(",\"thread\":\"MainThread\",\"ts\":");
                try @import("execution_clock.zig").writeTimestamp(self.stdout, @import("execution_clock.zig").now(self.runtime.io));
                try self.stdout.writeAll(",\"invocation_id\":");
                if (self.runtime.invocation) |invocation| try std.json.Stringify.value(&invocation.id, .{}, self.stdout) else try self.stdout.writeAll("null");
                try self.stdout.writeAll("}}\n");
            }
            return .{ .string = "" };
        }
        if (std.mem.startsWith(u8, name, "dxt.values.")) {
            if (args.len != 0) return error.InvalidJinjaArguments;
            for (self.stored.items) |stored| if (std.mem.eql(u8, name, stored.name)) return stored.value;
            return error.InvalidJinjaArguments;
        }
        if (std.mem.startsWith(u8, name, "dxt.print_table.")) {
            for (self.stored.items) |stored| if (std.mem.eql(u8, name, stored.name)) {
                try self.stdout.print("{s}\n", .{try stored.value.text(allocator)});
                return .none;
            };
            return error.InvalidJinjaArguments;
        }
        if (std.mem.eql(u8, name, "load_result")) {
            const key: expression.Value = argument(args, "name", 0) orelse return error.InvalidJinjaArguments;
            if (key != .string) return error.InvalidJinjaArguments;
            var index = self.stored.items.len;
            while (index > 0) {
                index -= 1;
                const stored = &self.stored.items[index];
                if (std.mem.eql(u8, key.string, stored.name)) {
                    if (!std.mem.eql(u8, key.string, "main")) {
                        if (stored.loaded) return error.MacroResultAlreadyLoaded;
                        stored.loaded = true;
                    }
                    return stored.value;
                }
            }
            return .none;
        }
        if (std.mem.eql(u8, name, "store_result")) {
            const key = argument(args, "name", 0) orelse return error.InvalidJinjaArguments;
            const response = argument(args, "response", 1) orelse return error.InvalidJinjaArguments;
            const authored_table = argument(args, "agate_table", 2) orelse .none;
            if (key != .string) return error.InvalidJinjaArguments;
            const table = if (authored_table == .none) try self.emptyTable() else authored_table;
            const value: expression.Value = .{ .object = try self.values.allocator().dupe(expression.Entry, &.{
                .{ .key = "table", .value = table },
                .{ .key = "data", .value = table.attribute("__dxt_data") },
                .{ .key = "response", .value = response },
            }) };
            try self.stored.append(self.runtime.allocator, .{ .name = try self.values.allocator().dupe(u8, key.string), .value = try @import("dbt_context.zig").cloneValue(self.values.allocator(), value) });
            return .{ .string = "" };
        }
        if (std.mem.eql(u8, name, "adapter.execute")) {
            const sql = argument(args, "sql", 0) orelse return error.InvalidJinjaArguments;
            if (sql != .string) return error.InvalidJinjaArguments;
            const auto_begin = argument(args, "auto_begin", 1) orelse expression.Value{ .boolean = false };
            const fetch = argument(args, "fetch", 2) orelse expression.Value{ .boolean = false };
            if (auto_begin.truthy() and !self.transaction_open) {
                try self.ensureSession();
                const session = self.currentSession() orelse return error.NativeDuckDbPoolRequired;
                try session.begin();
                self.transaction_open = true;
            }
            const queried = try self.query(sql.string, allocator);
            const table = if (fetch.truthy() and queried != .none) queried else try self.emptyTable();
            return .{ .list = try self.values.allocator().dupe(expression.Value, &.{ self.last_response, table }) };
        }
        if (std.mem.eql(u8, name, "run_query")) {
            const sql = argument(args, "sql", 0) orelse return error.InvalidJinjaArguments;
            if (sql != .string) return error.InvalidJinjaArguments;
            return self.query(sql.string, allocator);
        }
        if (std.mem.eql(u8, name, "statement")) {
            const sql = argument(args, "caller_sql", args.len) orelse return error.InvalidJinjaArguments;
            const key: expression.Value = argument(args, "name", 0) orelse .{ .string = "main" };
            if (sql != .string or key != .string) return error.InvalidJinjaArguments;
            const auto_begin: expression.Value = argument(args, "auto_begin", 2) orelse .{ .boolean = true };
            if (auto_begin.truthy() and !self.transaction_open) {
                try self.ensureSession();
                const session = self.currentSession() orelse return error.NativeDuckDbPoolRequired;
                try session.begin();
                self.transaction_open = true;
            }
            const table = try self.query(sql.string, allocator);
            const fetch: expression.Value = argument(args, "fetch_result", 1) orelse .{ .boolean = false };
            const value: expression.Value = .{ .object = try self.values.allocator().dupe(expression.Entry, &.{
                .{ .key = "table", .value = if (fetch.truthy()) table else .none },
                .{ .key = "data", .value = if (fetch.truthy() and table != .none) table.attribute("__dxt_data") else .{ .list = &.{} } },
                .{ .key = "response", .value = .{ .object = &.{} } },
            }) };
            try self.stored.append(self.runtime.allocator, .{ .name = try self.values.allocator().dupe(u8, key.string), .value = value });
            return .{ .string = "" };
        }
        if (std.mem.eql(u8, name, "adapter.type")) return .{ .string = self.graph.adapter_type };
        if (std.mem.eql(u8, name, "adapter.commit") or std.mem.eql(u8, name, "adapter.clear_transaction")) {
            try self.commit();
            return .none;
        }
        return error.UnresolvedMacro;
    }

    fn renderAdapterMacro(raw: *anyopaque, allocator: std.mem.Allocator, name: []const u8, args: []const expression.Argument) anyerror!expression.Value {
        const self: *OperationHost = @ptrCast(@alignCast(raw));
        const fallback = types.Node{ .package_name = self.graph.project_name, .unique_id = "operation", .name = "operation", .resource_type = "operation", .path = "", .original_file_path = "", .raw_code = "" };
        return try compiler.renderMacroForNode(allocator, self.graph, self.current_node orelse &fallback, name, args);
    }

    fn query(self: *OperationHost, sql: []const u8, _: std.mem.Allocator) !expression.Value {
        try self.ensureSession();
        const allocator = self.values.allocator();
        var output = if (self.currentSession()) |session| try session.query(sql) else try adapter.queryForGraph(self.runtime, self.graph, self.db_path, sql);
        defer output.deinit(self.runtime.allocator);
        const trimmed = std.mem.trim(u8, sql, " \t\r\n;");
        const message = if (output.command_tag) |tag| try allocator.dupe(u8, tag) else "OK";
        var code: expression.Value = .none;
        var affected: expression.Value = .none;
        if (output.command_tag) |tag| {
            var words = std.mem.tokenizeAny(u8, tag, " \t");
            var label: std.ArrayList(u8) = .empty;
            var has_count = false;
            while (words.next()) |word| {
                if (std.fmt.parseUnsigned(u64, word, 10)) |_| has_count = true else |_| {
                    if (label.items.len != 0) try label.append(allocator, ' ');
                    try label.appendSlice(allocator, word);
                }
            }
            code = .{ .string = try label.toOwnedSlice(allocator) };
            affected = if (has_count) try expression.integerValue(allocator, output.rows_changed) else .{ .integer = "-1" };
        }
        self.last_response = .{ .object = try allocator.dupe(expression.Entry, &.{ .{ .key = "__dxt_rendered", .value = .{ .string = message } }, .{ .key = "_message", .value = .{ .string = message } }, .{ .key = "code", .value = code }, .{ .key = "rows_affected", .value = affected } }) };
        if (std.ascii.eqlIgnoreCase(trimmed, "begin") or std.ascii.eqlIgnoreCase(trimmed, "begin transaction")) self.transaction_open = true;
        if (std.ascii.eqlIgnoreCase(trimmed, "commit") or std.ascii.eqlIgnoreCase(trimmed, "rollback")) self.transaction_open = false;
        // Native query results distinguish empty SELECTs from statements.
        if (output.columns.len == 0) return .none;
        const rows = try expression.allocateValues(allocator, output.rows.len);
        const data = try expression.allocateValues(allocator, output.rows.len);
        const columns = try expression.allocateValues(allocator, output.columns.len);
        const names = try expression.allocateValues(allocator, output.columns.len);
        for (output.columns, 0..) |column, column_index| {
            names[column_index] = .{ .string = try allocator.dupe(u8, column.name) };
            const cells = try expression.allocateValues(allocator, output.rows.len);
            for (output.rows, 0..) |row, row_index| cells[row_index] = try cellValue(allocator, column.kind, row[column_index]);
            columns[column_index] = .{ .object = try allocator.dupe(expression.Entry, &.{ .{ .key = "name", .value = names[column_index] }, .{ .key = "values", .value = try self.callback(.{ .list = cells }) } }) };
        }
        for (output.rows, rows, data) |row, *target, *raw_target| {
            const cells = try expression.allocateValues(allocator, output.columns.len);
            const entries = try expression.allocateEntries(allocator, output.columns.len + 3);
            for (row, output.columns, cells, entries[0..output.columns.len]) |cell, column, *value, *entry| {
                value.* = try cellValue(allocator, column.kind, cell);
                entry.* = .{ .key = try allocator.dupe(u8, column.name), .value = value.* };
            }
            entries[output.columns.len] = .{ .key = "__dxt_iterable", .value = .{ .list = cells } };
            entries[output.columns.len + 1] = .{ .key = "keys", .value = try self.callback(.{ .list = names }) };
            entries[output.columns.len + 2] = .{ .key = "values", .value = try self.callback(.{ .list = cells }) };
            target.* = .{ .object = entries };
            raw_target.* = .{ .list = cells };
        }
        const column_entries = try expression.allocateEntries(allocator, output.columns.len + 3);
        for (output.columns, columns, column_entries[0..output.columns.len]) |column, value, *entry| entry.* = .{ .key = try allocator.dupe(u8, column.name), .value = value };
        column_entries[output.columns.len] = .{ .key = "__dxt_iterable", .value = .{ .list = columns } };
        column_entries[output.columns.len + 1] = .{ .key = "keys", .value = try self.callback(.{ .list = names }) };
        column_entries[output.columns.len + 2] = .{ .key = "values", .value = try self.callback(.{ .list = columns }) };
        const method = try std.fmt.allocPrint(allocator, "dxt.print_table.{d}", .{self.stored.items.len});
        try self.stored.append(self.runtime.allocator, .{ .name = method, .value = .{ .list = data } });
        return .{ .object = try allocator.dupe(expression.Entry, &.{
            .{ .key = "__dxt_iterable", .value = .{ .list = rows } },
            .{ .key = "__dxt_data", .value = .{ .list = data } },
            .{ .key = "rows", .value = .{ .list = rows } },
            .{ .key = "columns", .value = .{ .object = column_entries } },
            .{ .key = "column_names", .value = .{ .list = names } },
            .{ .key = "print_table", .value = .{ .callable = method } },
        }) };
    }

    fn callback(self: *OperationHost, value: expression.Value) !expression.Value {
        const method = try std.fmt.allocPrint(self.values.allocator(), "dxt.values.{d}", .{self.stored.items.len});
        try self.stored.append(self.runtime.allocator, .{ .name = method, .value = value });
        return .{ .callable = method };
    }

    fn emptyTable(self: *OperationHost) !expression.Value {
        const allocator = self.values.allocator();
        const empty: expression.Value = .{ .list = try expression.allocateValues(allocator, 0) };
        return .{ .object = try allocator.dupe(expression.Entry, &.{
            .{ .key = "__dxt_iterable", .value = empty },                                                                                          .{ .key = "__dxt_data", .value = empty },
            .{ .key = "rows", .value = empty },                                                                                                    .{ .key = "column_names", .value = empty },
            .{ .key = "columns", .value = .{ .object = try allocator.dupe(expression.Entry, &.{.{ .key = "__dxt_iterable", .value = empty }}) } },
        }) };
    }
};

fn argument(args: []const expression.Argument, name: []const u8, position: usize) ?expression.Value {
    var index: usize = 0;
    for (args) |arg| {
        if (arg.name) |key| {
            if (std.mem.eql(u8, name, key)) return arg.value;
        } else {
            if (index == position) return arg.value;
            index += 1;
        }
    }
    return null;
}

fn cellValue(allocator: std.mem.Allocator, kind: adapter.Kind, cell: ?[]const u8) !expression.Value {
    const text = cell orelse return .none;
    return switch (kind) {
        .boolean => .{ .boolean = std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "t") or std.mem.eql(u8, text, "1") },
        .integer => .{ .integer = try allocator.dupe(u8, text) },
        .decimal, .floating => .{ .number = try std.fmt.parseFloat(f64, text) },
        else => .{ .string = try allocator.dupe(u8, text) },
    };
}

pub fn parseArgs(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var document = yaml.parse(allocator, text) catch return error.InvalidOperationArgs;
    defer document.deinit();
    if (document.value != .object) return error.InvalidOperationArgs;
    return config_values.clone(allocator, document.value);
}

pub const RetryPlan = struct { options: Options, count: usize };

pub fn prepareRetry(runtime: Runtime, current: Options, default_state_dir: []const u8) !RetryPlan {
    const path = try std.fs.path.join(runtime.allocator, &.{ current.state orelse default_state_dir, "run_results.json" });
    const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.MissingRunResultsArtifact,
        else => return err,
    };
    defer runtime.allocator.free(text);
    return parseRetry(runtime.allocator, text, current);
}

pub fn parseRetry(allocator: std.mem.Allocator, text: []const u8, current: Options) !RetryPlan {
    var status_index = try results.parseResultStatusIndex(allocator, text);
    defer status_index.deinit(allocator);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return error.MalformedRunResultsArtifact;
    defer parsed.deinit();
    const args_value = parsed.value.object.get("args") orelse return error.MissingRetryCommand;
    if (args_value != .object) return error.MissingRetryCommand;
    const args = args_value.object;
    const which_value = args.get("which") orelse return error.MissingRetryCommand;
    if (which_value != .string or which_value.string.len == 0) return error.MissingRetryCommand;
    const which = try allocator.dupe(u8, which_value.string);
    var options = current;
    options.which = which;
    if (args.get("record_timing_info")) |value| {
        if (value != .string and value != .null) return error.MalformedRunResultsArtifact;
        options.record_timing_info = if (value == .string) try allocator.dupe(u8, value.string) else null;
    }
    if (args.get("single_threaded")) |value| {
        if (value != .bool) return error.MalformedRunResultsArtifact;
        options.single_threaded = value.bool;
    }
    if (args.get("show")) |value| {
        if (value != .bool and value != .null) return error.MalformedRunResultsArtifact;
        options.seed_show = value == .bool and value.bool;
    }
    if (args.get("store_failures")) |value| {
        if (value != .bool and value != .null) return error.MalformedRunResultsArtifact;
        options.store_failures = value == .bool and value.bool;
    }
    if (args.get("empty")) |value| {
        if (value != .bool and value != .null) return error.MalformedRunResultsArtifact;
        options.empty = value == .bool and value.bool;
    }
    inline for (.{ "sample", "event_time_start", "event_time_end" }) |key| if (args.get(key)) |value| {
        @field(options, key) = try optionText(allocator, value, false);
        if (!std.mem.eql(u8, key, "sample")) if (@field(options, key)) |raw| {
            const timestamp = try @import("input_relations.zig").parseDate(raw, true);
            const normalized = try @import("input_relations.zig").formatSampleTimestamp(allocator, timestamp);
            allocator.free(raw);
            @field(options, key) = normalized;
        };
    };
    // SAMPLE in Core artifacts is a converted start/end mapping. Retrying a
    // relative window uses the artifact's concrete window rather than now.
    if (args.get("sample")) |value| if (value == .object) {
        const start = value.object.get("start") orelse return error.MalformedRunResultsArtifact;
        const end = value.object.get("end") orelse return error.MalformedRunResultsArtifact;
        if (start != .string or end != .string) return error.MalformedRunResultsArtifact;
        const parse_date = @import("input_relations.zig").parseDate;
        options.sample_window = .{ .start = try parse_date(start.string, true), .end = try parse_date(end.string, true) };
    };
    var microbatch_retries: std.json.Value = .{ .object = .empty };
    for (parsed.value.object.get("results").?.array.items) |row| {
        if (row != .object) return error.MalformedRunResultsArtifact;
        const batches = row.object.get("batch_results") orelse continue;
        if (batches == .null) continue;
        const status = row.object.get("status") orelse return error.MalformedRunResultsArtifact;
        const id = row.object.get("unique_id") orelse return error.MalformedRunResultsArtifact;
        if (status != .string or id != .string or batches != .object) return error.MalformedRunResultsArtifact;
        if (isRetryableStatus(status.string)) try config_values.put(allocator, &microbatch_retries, try allocator.dupe(u8, id.string), try config_values.clone(allocator, batches));
    }
    if (microbatch_retries.object.count() != 0) options.microbatch_retry_results = microbatch_retries;
    if (std.mem.eql(u8, which, "generate")) inline for (.{ .{ "compile", "docs_compile" }, .{ "static", "docs_static" } }) |field| {
        if (args.get(field[0])) |value| {
            if (value != .bool) return error.MalformedRunResultsArtifact;
            @field(options, field[1]) = value.bool;
        }
    };
    inline for (.{ "profile", "target", "state", "defer_state", "select", "selector", "exclude" }) |field| {
        if (args.get(field)) |value| @field(options, field) = try optionText(allocator, value, std.mem.eql(u8, field, "select") or std.mem.eql(u8, field, "exclude"));
    }
    if (current.vars == null) if (args.get("vars")) |value| {
        options.vars = try optionText(allocator, value, false);
    };
    if (current.threads == null) if (args.get("threads")) |value| {
        options.threads = try optionText(allocator, value, false);
    };
    if (args.get("full_refresh")) |value| {
        if (value != .bool and value != .null) return error.MalformedRunResultsArtifact;
        options.full_refresh = value == .bool and value.bool;
    }
    inline for (.{ .{ "defer", "defer_enabled" }, .{ "favor_state", "favor_state" }, .{ "fail_fast", "fail_fast" }, .{ "quiet", "quiet" }, .{ "debug", "debug" }, .{ "write_json", "write_json" }, .{ "warn_error", "warn_error" }, .{ "version_check", "version_check" }, .{ "use_colors", "use_colors" }, .{ "use_colors_file", "use_colors_file" }, .{ "print", "print_enabled" }, .{ "populate_cache", "populate_cache" }, .{ "cache_selected_only", "cache_selected_only" }, .{ "log_cache_events", "log_cache_events" } }) |field| {
        if (args.get(field[0])) |value| {
            if (value != .bool and value != .null) return error.MalformedRunResultsArtifact;
            @field(options, field[1]) = value == .bool and value.bool;
        }
    }
    if (args.get("log_format")) |value| {
        if (value != .string) return error.MalformedRunResultsArtifact;
        options.log_format = std.meta.stringToEnum(@TypeOf(options.log_format), value.string) orelse return error.MalformedRunResultsArtifact;
    }
    inline for (.{ "log_level", "log_level_file", "log_format_file" }) |field| if (args.get(field)) |value| {
        if (value != .string) return error.MalformedRunResultsArtifact;
        @field(options, field) = std.meta.stringToEnum(@TypeOf(@field(options, field)), value.string) orelse return error.MalformedRunResultsArtifact;
    };
    if (args.get("warn_error_options")) |value| options.warn_error_options = try optionText(allocator, value, false);
    if (args.get("log_path")) |value| options.log_path = try optionText(allocator, value, false);
    if (args.get("indirect_selection")) |value| {
        if (value != .string) return error.MalformedRunResultsArtifact;
        options.indirect_selection = try allocator.dupe(u8, value.string);
    }
    options.command_name = if (args.get("macro") orelse args.get("command_name")) |value| try optionText(allocator, value, false) else null;
    options.command_args = if (args.get("args") orelse args.get("command_args")) |value| try optionText(allocator, value, false) else null;
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(allocator);
    var exact_ids: std.ArrayList([]const u8) = .empty;
    defer exact_ids.deinit(allocator);
    var count: usize = 0;
    for (status_index.rows) |row| {
        if (!isRetryableStatus(row.status)) continue;
        if (std.mem.startsWith(u8, row.unique_id, "operation.") and !std.mem.eql(u8, which, "run-operation")) continue;
        const dot = std.mem.indexOfScalar(u8, row.unique_id, '.') orelse return error.MalformedRunResultsArtifact;
        try ids.append(allocator, try std.fmt.allocPrint(allocator, "{s},resource_type:{s}", .{ row.unique_id, row.unique_id[0..dot] }));
        try exact_ids.append(allocator, try allocator.dupe(u8, row.unique_id));
        count += 1;
    }
    options.execution_select = try std.mem.join(allocator, " ", ids.items);
    options.execution_ids = try exact_ids.toOwnedSlice(allocator);
    return .{ .options = options, .count = count };
}

pub fn isRetryableStatus(status: []const u8) bool {
    for ([_][]const u8{ "error", "fail", "skipped", "runtime error", "partial success" }) |candidate| if (std.mem.eql(u8, status, candidate)) return true;
    return false;
}

fn optionText(allocator: std.mem.Allocator, value: std.json.Value, selector_list: bool) !?[]const u8 {
    if (value == .null) return null;
    if (value == .string) return try allocator.dupe(u8, value.string);
    if (selector_list and value == .array) {
        var strings: std.ArrayList([]const u8) = .empty;
        defer strings.deinit(allocator);
        for (value.array.items) |item| {
            if (item != .string) return error.MalformedRunResultsArtifact;
            try strings.append(allocator, item.string);
        }
        if (strings.items.len == 0) return null;
        return try std.mem.join(allocator, " ", strings.items);
    }
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
}

pub fn cloneRelations(runtime: Runtime, options: Options, graph: *types.Graph, selected: []const selector.SelectedResource, target_dir: []const u8, stdout: *std.Io.Writer) !void {
    const state_dir = options.state orelse return error.MissingCloneState;
    const path = try std.fs.path.join(runtime.allocator, &.{ state_dir, "manifest.json" });
    const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.MissingStateManifestArtifact,
        else => return err,
    };
    defer runtime.allocator.free(text);
    var parsed = std.json.parseFromSlice(std.json.Value, runtime.allocator, text, .{}) catch return error.MalformedStateManifestArtifact;
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedStateManifestArtifact;
    const metadata = parsed.value.object.get("metadata") orelse return error.MalformedStateManifestArtifact;
    if (metadata != .object) return error.MalformedStateManifestArtifact;
    const version = metadata.object.get("dbt_schema_version") orelse return error.MalformedStateManifestArtifact;
    if (version != .string) return error.MalformedStateManifestArtifact;
    if (!std.mem.eql(u8, version.string, "https://schemas.getdbt.com/dbt/manifest/v12.json")) return error.UnsupportedStateManifestSchemaVersion;
    const nodes = parsed.value.object.get("nodes") orelse return error.MalformedStateManifestArtifact;
    if (nodes != .object) return error.MalformedStateManifestArtifact;
    if (!std.mem.eql(u8, graph.adapter_type, "duckdb")) return error.UnsupportedAdapterExecution;
    const db_path = try duckdb.databasePath(runtime.allocator, target_dir, graph);
    var rows: std.ArrayList(results.NodeResult) = .empty;
    defer rows.deinit(runtime.allocator);
    var failed = false;
    for (graph.nodes.items) |*node| {
        if (!node.enabled or std.mem.eql(u8, node.materialized, "ephemeral")) continue;
        if (!std.mem.eql(u8, node.resource_type, "model") and !std.mem.eql(u8, node.resource_type, "seed") and !std.mem.eql(u8, node.resource_type, "snapshot")) continue;
        var chosen = false;
        for (selected) |item| if (std.mem.eql(u8, item.unique_id, node.unique_id)) {
            chosen = true;
            break;
        };
        if (!chosen) continue;
        cloneOne(runtime, options, graph, node, nodes.object.get(node.unique_id), db_path) catch |err| {
            if (err == error.OutOfMemory) return err;
            failed = true;
            try rows.append(runtime.allocator, .{ .node = node, .status = "error", .message = "DuckDB execution failed" });
            continue;
        };
        try rows.append(runtime.allocator, .{ .node = node, .message = "OK", .adapter_response = .{ .message = "OK" } });
    }
    try writeResults(runtime, target_dir, rows.items);
    try stdout.print("Cloned {d} relation(s)\n", .{rows.items.len});
    if (failed) return error.ExecutionFailure;
}

fn cloneOne(runtime: Runtime, options: Options, graph: *const types.Graph, node: *types.Node, prior_value: ?std.json.Value, db_path: []const u8) !void {
    const allocator = runtime.allocator;
    const schema = try compiler.relationSchemaForNode(allocator, graph, node);
    const target = try compiler.relationNameForNode(allocator, graph, node);
    const database = std.fs.path.stem(std.fs.path.basename(db_path));
    if (std.mem.eql(u8, node.resource_type, "model")) {
        node.compiled = false;
        node.compiled_code = null;
        node.relation_name = if (compiler.relationDatabaseForNode(graph, node) != null)
            try allocator.dupe(u8, target)
        else
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ try compiler.quoteIdentifier(allocator, database), target });
    }
    const prior = prior_value orelse return;
    if (prior != .object) return error.MalformedStateManifestArtifact;
    if (prior.object.get("relation_name")) |relation_value| {
        if (relation_value == .null) return;
    }
    const schema_value = prior.object.get("schema") orelse return error.MalformedStateManifestArtifact;
    const alias_value = prior.object.get("alias") orelse return error.MalformedStateManifestArtifact;
    if (schema_value != .string or alias_value != .string) return error.MalformedStateManifestArtifact;
    const quoted_schema = try compiler.quoteIdentifier(allocator, schema);
    const prior_schema = try compiler.quoteIdentifier(allocator, schema_value.string);
    const prior_alias = try compiler.quoteIdentifier(allocator, alias_value.string);
    const database_value = prior.object.get("database") orelse .null;
    const source = if (database_value == .string)
        try std.fmt.allocPrint(allocator, "{s}.{s}.{s}", .{ try compiler.quoteIdentifier(allocator, database_value.string), prior_schema, prior_alias })
    else
        try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prior_schema, prior_alias });
    const sql = try std.fmt.allocPrint(allocator, "select * from {s}", .{source});
    // Avoid a self-referential replacement when source and destination coincide.
    if (std.mem.eql(u8, schema, schema_value.string) and std.mem.eql(u8, compiler.relationIdentifierForNode(node), alias_value.string)) return;
    const lookup = try std.fmt.allocPrint(allocator, "select table_type from information_schema.tables where table_schema = {s} and table_name = {s}", .{ try sqlLiteral(allocator, schema), try sqlLiteral(allocator, compiler.relationIdentifierForNode(node)) });
    var existing_result = try adapter.queryForGraph(runtime, graph, db_path, lookup);
    defer existing_result.deinit(allocator);
    const existing_json = try existing_result.json(allocator);
    defer allocator.free(existing_json);
    var existing = std.json.parseFromSlice(std.json.Value, allocator, if (std.mem.trim(u8, existing_json, " \t\r\n").len == 0) "[]" else existing_json, .{}) catch return error.DuckDbExecutionFailed;
    defer existing.deinit();
    if (existing.value != .array) return error.DuckDbExecutionFailed;
    const exists = existing.value.array.items.len != 0;
    if (exists and !options.full_refresh) return;
    const drop = if (exists) blk: {
        const kind = existing.value.array.items[0].object.get("table_type") orelse return error.DuckDbExecutionFailed;
        break :blk try std.fmt.allocPrint(allocator, "drop {s} {s};\n", .{ if (kind == .string and std.mem.eql(u8, kind.string, "VIEW")) "view" else "table", target });
    } else "";
    const create = try std.fmt.allocPrint(allocator, "begin;\ncreate schema if not exists {s};\n{s}create view {s} as {s};\ncommit;", .{ quoted_schema, drop, target, sql });
    try adapter.executeForGraph(runtime, graph, db_path, create);
}

fn sqlLiteral(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(allocator, '\'');
    for (value) |c| {
        try out.append(allocator, c);
        if (c == '\'') try out.append(allocator, c);
    }
    try out.append(allocator, '\'');
    return try out.toOwnedSlice(allocator);
}

test "retry statuses follow the pinned dbt task contract" {
    for ([_][]const u8{ "error", "fail", "skipped", "runtime error", "partial success" }) |status| try std.testing.expect(isRetryableStatus(status));
    for ([_][]const u8{ "success", "pass", "warn" }) |status| try std.testing.expect(!isRetryableStatus(status));
}

test "initialization names never escape the new project directory" {
    try std.testing.expect(validProjectName("analytics_42"));
    for ([_][]const u8{ "", "../existing", "a/b", ".", "1project", "hyphen-name" }) |name| try std.testing.expect(!validProjectName(name));
}

test "retry restores typed Core arguments while excluding successful IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const text =
        \\{"metadata":{"dbt_schema_version":"https://schemas.getdbt.com/dbt/run-results/v6.json"},"args":{"which":"run","select":["broken+","independent"],"exclude":[],"target":"prod","vars":{"limit":7},"threads":2},"results":[{"unique_id":"model.retry.broken","status":"error"},{"unique_id":"model.retry.child","status":"skipped"},{"unique_id":"model.retry.independent","status":"success"}]}
    ;
    const plan = try parseRetry(allocator, text, .{ .project_dir = "project", .profiles_dir = "profiles", .threads = "4" });
    try std.testing.expectEqualStrings("run", plan.options.which);
    try std.testing.expectEqualStrings("prod", plan.options.target.?);
    try std.testing.expectEqualStrings("4", plan.options.threads.?);
    try std.testing.expectEqualStrings("broken+ independent", plan.options.select.?);
    try std.testing.expectEqual(@as(usize, 2), plan.count);
    try std.testing.expectEqualStrings("model.retry.broken", plan.options.execution_ids.?[0]);
    try std.testing.expectEqualStrings("model.retry.child", plan.options.execution_ids.?[1]);
    const vars = try parseArgs(allocator, plan.options.vars.?);
    try std.testing.expectEqual(@as(i64, 7), vars.object.get("limit").?.integer);
}

test "operation args parse nested YAML with native owned documents" {
    const allocator = std.testing.allocator;
    var value = try parseArgs(allocator, "n: 7\nflags:\n  enabled: true\nnames: [Ada, Grace]\n");
    defer config_values.deinit(allocator, &value);
    try std.testing.expectEqual(@as(i64, 7), value.object.get("n").?.integer);
    try std.testing.expect(value.object.get("flags").?.object.get("enabled").?.bool);
    try std.testing.expectEqualStrings("Ada", value.object.get("names").?.array.items[0].string);
    try std.testing.expectError(error.InvalidOperationArgs, parseArgs(allocator, "[]"));
}

test "operation host preserves typed debug info and authored print events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var events: std.ArrayList(results.LogMessage) = .empty;
    defer events.deinit(allocator);
    var context = try OperationHost.initLazy(.{ .allocator = allocator, .io = std.testing.io }, &graph, ":memory:", &output.writer);
    defer context.deinit();
    context.log_events = &events;
    const host = context.host();
    const args = [_]expression.Argument{.{ .value = .{ .string = "message" } }};
    _ = try host.call(host.context, "log", &args, allocator);
    _ = try host.call(host.context, "print", &args, allocator);
    graph.command_options.print_enabled = false;
    _ = try host.call(host.context, "print", &args, allocator);
    const info_args = [_]expression.Argument{ args[0], .{ .name = "info", .value = .{ .boolean = true } } };
    _ = try host.call(host.context, "log", &info_args, allocator);
    try std.testing.expectEqual(@as(usize, 3), events.items.len);
    try std.testing.expectEqualStrings("debug", events.items[0].level);
    try std.testing.expect(!events.items[0].is_print);
    try std.testing.expect(events.items[1].is_print);
    try std.testing.expectEqualStrings("info", events.items[2].level);
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}
