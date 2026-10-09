//! Developer conformance driver: all adapter behavior is imported from the
//! product's native Zig implementation and runs against actual databases.
const std = @import("std");
const adapter = @import("adapter");

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.File.Writer.init(.stderr(), init.io, &buffer);
        writer.interface.print("error: {s}\n", .{@errorName(err)}) catch {};
        writer.interface.flush() catch {};
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    if (args.len < 4) return error.MissingDriverArguments;
    var pool = adapter.DuckDBPool.init(allocator, init.io, init.environ_map);
    defer pool.deinit();
    const runtime: adapter.Runtime = .{ .allocator = allocator, .io = init.io, .environment = init.environ_map, .duckdb_pool = &pool };
    var graph: adapter.Graph = .{ .allocator = allocator, .project_name = "native_demo", .adapter_type = args[1], .connection_info = init.environ_map.get("DXT_TEST_POSTGRES_CONNINFO") };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    if (std.mem.eql(u8, args[2], "profile")) {
        const config: adapter.ProjectConfig = .{ .name = "native_demo", .profile_name = "native_demo" };
        var profile_runtime = runtime;
        profile_runtime.allocator = arena.allocator();
        const identity = (try adapter.profile.loadAdapterIdentity(profile_runtime, args[3], &config, .{})) orelse return error.MissingProfile;
        graph.adapter_type = identity.adapter_type;
        graph.connection_info = identity.connection_info;
        graph.target_schema = identity.target_schema;
    }
    if (std.mem.eql(u8, args[2], "pool")) {
        try poolConformance(runtime, &graph, args[3]);
        try emit(init.io, "{\"shared_pool\":true,\"concurrent_writers\":true}\n");
        return;
    }
    if (std.mem.eql(u8, args[2], "promote")) {
        var reader = (try pool.acquire(args[3], true)).?;
        var other_reader = (try pool.acquire(args[3], true)).?;
        if (pool.acquire(args[3], false)) |_| return error.PromotedActiveReaders else |err| {
            if (err != error.NativeDuckDbReadOnlyConnection) return err;
        }
        reader.deinit();
        if (pool.acquire(args[3], false)) |_| return error.PromotedActiveReaders else |err| {
            if (err != error.NativeDuckDbReadOnlyConnection) return err;
        }
        other_reader.deinit();
        var writer = (try pool.acquire(args[3], false)).?;
        defer writer.deinit();
        try writer.execute("create table promoted(id integer); insert into promoted values (17)");
        var result = try writer.query("select * from promoted");
        defer result.deinit(allocator);
        try expectScalar(&result, "17");
        try emit(init.io, "{\"readers_preserved\":true,\"promoted_after_disconnect\":true}");
        return;
    }
    if (std.mem.eql(u8, args[2], "binder")) {
        var connection = (try pool.acquire(args[3], true)).?;
        defer connection.deinit();
        try connection.enterReadOnlySession();
        try connection.execute("create temporary view dxt_bound as select 17 as id");
        var described = try connection.query("describe select id from dxt_bound");
        defer described.deinit(allocator);
        try expectScalar(&described, "id");
        connection.execute("select missing_column from dxt_bound") catch |err| {
            if (err != error.DuckDbExecutionFailed or connection.last_error == null) return error.MissingBinderDiagnostic;
        };
        // A binder SQL error aborts its transaction; a fresh held session is
        // used by the next model. Disconnect rolls back every temp object.
        try emit(init.io, "{\"temporary_binding\":true,\"diagnostics_in_memory\":true}");
        return;
    }
    if (std.mem.eql(u8, args[2], "binder-write")) {
        var connection = (try pool.acquire(args[3], false)).?;
        defer connection.deinit();
        try connection.execute("create table guarded_binding(id integer)");
        var reader = (try pool.acquire(args[3], true)).?;
        defer reader.deinit();
        try reader.enterReadOnlySession();
        const attempts = [_][]const u8{ "commit", "rollback", "attach ':memory:' as escaped" };
        for (attempts) |attempt| {
            reader.execute(attempt) catch |err| {
                if (err != error.NativeDuckDbReadOnlyConnection) return err;
                continue;
            };
            return error.ReadOnlySessionEscaped;
        }
        reader.execute("insert into guarded_binding values (17)") catch |err| {
            if (err != error.DuckDbExecutionFailed) return err;
            try emit(init.io, "{\"persistent_writes_rejected\":true,\"transaction_escape_rejected\":true}");
            return;
        };
        return error.ReadOnlyWriteWasAllowed;
    }
    if (std.mem.eql(u8, args[2], "query") or std.mem.eql(u8, args[2], "profile")) {
        if (args.len != 5) return error.MissingSql;
        var output = try adapter.queryForGraph(runtime, &graph, args[3], args[4]);
        defer output.deinit(allocator);
        const json = try output.json(allocator);
        defer allocator.free(json);
        try emit(init.io, json);
        return;
    }
    if (std.mem.eql(u8, args[2], "readonly")) {
        if (args.len != 5) return error.MissingSql;
        var connection = (try pool.acquire(args[3], false)) orelse return error.NativeDuckDbLibraryNotFound;
        defer connection.deinit();
        try connection.execute("create sequence native_sequence; create table guard(id integer)");
        var reader = (try pool.acquire(args[3], true)).?;
        defer reader.deinit();
        var output = try reader.query(args[4]);
        defer output.deinit(allocator);
        const json = try output.json(allocator);
        defer allocator.free(json);
        try emit(init.io, json);
        return;
    }
    var session = try adapter.openSession(runtime, &graph, args[3]);
    defer session.deinit();
    if (std.mem.eql(u8, args[2], "conformance")) {
        try conformance(allocator, &session, graph.adapter_type);
        const json = try std.json.Stringify.valueAlloc(allocator, session.capabilities(), .{});
        defer allocator.free(json);
        try emit(init.io, json);
    } else if (std.mem.eql(u8, args[2], "qualified-introspection")) {
        try qualifiedIntrospection(allocator, &session, graph.adapter_type);
        try emit(init.io, "{\"qualified_identity\":true,\"column_types\":true,\"relation_kinds\":true}");
    } else if (std.mem.eql(u8, args[2], "cancel")) {
        var task: QueryTask = .{ .session = &session, .allocator = allocator, .sql = if (std.mem.eql(u8, graph.adapter_type, "postgres")) "select pg_sleep(30)" else "select sum(a.i * b.i) from range(1000000) a(i), range(1000000) b(i)" };
        const worker = try std.Thread.spawn(.{}, QueryTask.run, .{&task});
        try std.Io.sleep(init.io, .fromMilliseconds(200), .awake);
        session.cancel() catch |err| {
            worker.join();
            return err;
        };
        worker.join();
        if (task.failure == null or task.failure.? != error.AdapterQueryCancelled) return error.CancellationNotObserved;
        var output = try session.query("select 7 as recovered");
        defer output.deinit(allocator);
        try expectScalar(&output, "7");
        try emit(init.io, "{\"cancelled\":true,\"connection_recovered\":true}\n");
    } else return error.InvalidDriverMode;
}

fn qualifiedIntrospection(allocator: std.mem.Allocator, session: *adapter.Session, adapter_type: []const u8) !void {
    if (std.mem.eql(u8, adapter_type, "duckdb")) {
        try session.execute("attach ':memory:' as other_catalog; create table main.same_name(id integer); create table other_catalog.main.same_name(label varchar); create view other_catalog.main.typed_view as select label from other_catalog.main.same_name");
        var local = try session.columns(allocator, "main", "same_name");
        defer local.deinit(allocator);
        try expectScalar(&local, "id");
        if (local.rows.len != 1) return error.MixedCatalogColumns;
        var other = try session.columnsInDatabase(allocator, "other_catalog", "main", "same_name");
        defer other.deinit(allocator);
        try expectScalar(&other, "label");
        if (other.rows.len != 1) return error.MixedCatalogColumns;
        const kind = (try session.relationTypeInDatabase(allocator, "other_catalog", "main", "typed_view")) orelse return error.MissingRelation;
        defer allocator.free(kind);
        if (!std.mem.eql(u8, kind, "view")) return error.InvalidRelationKind;
        if (try session.relationExistsInDatabase(allocator, "missing_catalog", "main", "same_name")) return error.WrongCatalogIdentity;
    } else {
        try session.begin();
        defer session.rollback() catch {};
        try session.execute("create schema native_introspection; create table native_introspection.zero_columns(); create materialized view native_introspection.typed_view as select cast('x' as varchar(24)) as label");
        if (!try session.relationExists(allocator, "native_introspection", "zero_columns")) return error.MissingZeroColumnTable;
        var columns = try session.columns(allocator, "native_introspection", "typed_view");
        defer columns.deinit(allocator);
        try expectScalar(&columns, "label");
        if (!std.mem.eql(u8, columns.rows[0][1].?, "character varying(24)")) return error.MissingTypePrecision;
        const kind = (try session.relationTypeInDatabase(allocator, null, "native_introspection", "typed_view")) orelse return error.MissingMaterializedView;
        defer allocator.free(kind);
        if (!std.mem.eql(u8, kind, "materialized_view")) return error.InvalidRelationKind;
        if (try session.relationExistsInDatabase(allocator, "missing_database", "native_introspection", "typed_view")) return error.WrongCatalogIdentity;
    }
}

fn emit(io: std.Io, value: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.Writer.init(.stdout(), io, &buffer);
    try writer.interface.writeAll(value);
    try writer.interface.flush();
}

fn expectScalar(output: *const adapter.QueryResult, value: []const u8) !void {
    if (!std.mem.eql(u8, output.firstScalar() orelse return error.MissingScalar, value)) return error.UnexpectedScalar;
}

fn conformance(allocator: std.mem.Allocator, session: *adapter.Session, adapter_type: []const u8) !void {
    const schema = if (std.mem.eql(u8, adapter_type, "postgres")) "public" else "main";
    const table_name = "adapter\"quoted";
    const identifier = try adapter.quoteIdentifier(allocator, table_name);
    defer allocator.free(identifier);
    const create_sql = try std.fmt.allocPrint(allocator, "create table {s}(id bigint, label text, amount decimal(20,4), enabled boolean)", .{identifier});
    defer allocator.free(create_sql);
    try session.begin();
    try session.execute(create_sql);
    try session.rollback();
    if (try session.relationExists(allocator, schema, table_name)) return error.RollbackDidNotRestoreSchema;
    try session.execute(create_sql);
    try session.begin();
    const insert_sql = try std.fmt.allocPrint(allocator, "insert into {s} values (42, 'O''Brien', 1234567890123456.7890, true), (null, null, null, false)", .{identifier});
    defer allocator.free(insert_sql);
    var inserted = try session.query(insert_sql);
    defer inserted.deinit(allocator);
    if (inserted.rows_changed != 2) return error.InvalidRowsChanged;
    try session.commit();
    try session.begin();
    const delete_sql = try std.fmt.allocPrint(allocator, "delete from {s}", .{identifier});
    defer allocator.free(delete_sql);
    try session.execute(delete_sql);
    try session.rollback();
    var columns = try session.columns(allocator, schema, table_name);
    defer columns.deinit(allocator);
    if (columns.rows.len != 4 or !try session.relationExists(allocator, schema, table_name)) return error.InvalidIntrospection;
    const select_sql = try std.fmt.allocPrint(allocator, "select id, label, amount, enabled from {s} order by id nulls last", .{identifier});
    defer allocator.free(select_sql);
    var values = try session.query(select_sql);
    defer values.deinit(allocator);
    if (values.rows.len != 2 or values.columns.len != 4) return error.InvalidResultShape;
    try expectScalar(&values, "42");
    if (!std.mem.eql(u8, values.rows[0][1].?, "O'Brien") or !std.mem.eql(u8, values.rows[0][2].?, "1234567890123456.7890")) return error.InvalidTypedValue;
    if (values.rows[1][0] != null or values.rows[1][1] != null or values.rows[1][2] != null) return error.NullValueWasLost;
    if (values.columns[0].kind != .integer or values.columns[1].kind != .text or values.columns[2].kind != .decimal or values.columns[3].kind != .boolean) return error.InvalidTypeMapping;
    const empty_sql = try std.fmt.allocPrint(allocator, "select id, label, amount, enabled from {s} where false", .{identifier});
    defer allocator.free(empty_sql);
    var empty = try session.query(empty_sql);
    defer empty.deinit(allocator);
    if (empty.rows.len != 0 or empty.columns.len != 4) return error.EmptyResultLostColumns;
    try session.begin();
    session.execute("select * from missing_adapter_relation") catch {};
    try session.rollback();
    if (session.capabilities().savepoints) {
        try session.begin();
        try session.execute("savepoint conformance; select 1; rollback to savepoint conformance");
        try session.commit();
        session.execute("copy (select 17 as id) to stdout") catch |err| {
            if (err != error.UnsupportedCopyStreaming) return err;
        };
        var recovered = try session.query("select 7");
        defer recovered.deinit(allocator);
        try expectScalar(&recovered, "7");
    }
    const drop_sql = try std.fmt.allocPrint(allocator, "drop table {s}", .{identifier});
    defer allocator.free(drop_sql);
    try session.execute(drop_sql);
    if (try session.relationExists(allocator, schema, table_name)) return error.DropWasNotObserved;
}

const QueryTask = struct {
    session: *adapter.Session,
    allocator: std.mem.Allocator,
    sql: []const u8,
    failure: ?anyerror = null,
    fn run(self: *QueryTask) void {
        var output = self.session.query(self.sql) catch |err| {
            self.failure = err;
            return;
        };
        output.deinit(self.allocator);
    }
};

fn poolConformance(runtime: adapter.Runtime, graph: *const adapter.Graph, path: []const u8) !void {
    var first = try adapter.openSession(runtime, graph, path);
    defer first.deinit();
    var second = try adapter.openSession(runtime, graph, path);
    defer second.deinit();
    try first.execute("create table pool_first(id integer); create table pool_second(id integer)");
    try first.begin();
    try second.begin();
    var a: QueryTask = .{ .session = &first, .allocator = runtime.allocator, .sql = "insert into pool_first select * from range(10000)" };
    var b: QueryTask = .{ .session = &second, .allocator = runtime.allocator, .sql = "insert into pool_second select * from range(10000)" };
    const one = try std.Thread.spawn(.{}, QueryTask.run, .{&a});
    const two = std.Thread.spawn(.{}, QueryTask.run, .{&b}) catch |err| {
        one.join();
        return err;
    };
    one.join();
    two.join();
    if (a.failure) |err| return err;
    if (b.failure) |err| return err;
    try first.commit();
    try second.rollback();
    var committed = try second.query("select count(*) from pool_first");
    defer committed.deinit(runtime.allocator);
    try expectScalar(&committed, "10000");
    var rolled_back = try first.query("select count(*) from pool_second");
    defer rolled_back.deinit(runtime.allocator);
    try expectScalar(&rolled_back, "0");
}
