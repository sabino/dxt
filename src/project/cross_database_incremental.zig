//! Affected-key recomputation with per-source timestamp watermarks. Progress and
//! output commit together in the destination; failed runs never advance inputs.
const std = @import("std");
const cross = @import("cross_database.zig");
const run = @import("cross_database_run.zig");
const read = @import("cross_database_read.zig");
const adapter = @import("adapter.zig");

pub const Watermark = struct { input: []const u8, query_hash: []const u8, value: ?[]const u8 = null };
pub const State = struct {
    arena: *std.heap.ArenaAllocator,
    owner: std.mem.Allocator,
    model: cross.Model,
    target_key: []const u8,
    keys_sql: []const u8,
    key_count: usize,
    watermarks: []Watermark,
    rebuild: bool,

    pub fn deinit(self: *State) void {
        self.arena.deinit();
        self.owner.destroy(self.arena);
        self.* = undefined;
    }

    pub fn prepare(runtime: cross.Runtime, root: []const u8, plan: *cross.Plan, destination: *adapter.Session, model: cross.Model, record: *run.Record, spill: []const u8) !State {
        const arena = try runtime.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(runtime.allocator);
        errdefer {
            arena.deinit();
            runtime.allocator.destroy(arena);
        }
        const allocator = arena.allocator();
        var state: State = .{ .arena = arena, .owner = runtime.allocator, .model = model, .target_key = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ model.schema, model.identifier }), .keys_sql = "", .key_count = 0, .watermarks = try allocator.alloc(Watermark, model.inputs.len), .rebuild = model.full_refresh or !try destination.relationExists(runtime.allocator, model.schema, model.identifier) };
        try destination.execute("create schema if not exists dxt_internal; create table if not exists dxt_internal.cross_watermarks (model text,input text,query_hash text,watermark text,primary key(model,input))");
        const target_literal = try adapter.quoteLiteral(allocator, state.target_key);
        for (model.inputs, state.watermarks) |input, *progress| {
            const hash_text = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}/{d}", .{ input.query_hash, input.incremental_key.?, input.watermark.?, input.lookback_seconds });
            progress.* = .{ .input = input.name, .query_hash = try cross.digest(allocator, hash_text) };
            const query = try std.fmt.allocPrint(allocator, "select query_hash,watermark from dxt_internal.cross_watermarks where model={s} and input={s}", .{ target_literal, try adapter.quoteLiteral(allocator, input.name) });
            var previous = try destination.query(query);
            defer previous.deinit(runtime.allocator);
            if (previous.rows.len == 0 or previous.rows[0][0] == null or !std.mem.eql(u8, previous.rows[0][0].?, progress.query_hash)) state.rebuild = true else if (previous.rows[0][1]) |value| progress.value = try allocator.dupe(u8, value);
        }
        if (state.rebuild) for (state.watermarks) |*progress| {
            progress.value = null;
        };
        var keys: std.StringHashMap(void) = .init(allocator);
        var key_bytes: u64 = 0;
        for (model.inputs, state.watermarks) |input, *progress| {
            record.active_connection = plan.connections[input.connection].name;
            var source = try run.open(runtime, root, plan.connections[input.connection]);
            defer source.deinit();
            try run.configure(runtime, &source, model.budget, spill);
            const key = try adapter.quoteIdentifier(allocator, input.incremental_key.?);
            const watermark = try adapter.quoteIdentifier(allocator, input.watermark.?);
            const predicate = if (!state.rebuild and progress.value != null) try std.fmt.allocPrint(allocator, "where {s} is null or cast({s} as timestamp) >= cast({s} as timestamp) - interval '{d} seconds'", .{ watermark, watermark, try adapter.quoteLiteral(allocator, progress.value.?), input.lookback_seconds }) else "";
            const query = try std.fmt.allocPrint(allocator, "select {s} as __dxt_key,max(cast({s} as timestamp)) as __dxt_watermark from ({s}) __dxt_source {s} group by {s}", .{ key, watermark, input.query, predicate, key });
            var timer = run.Timer.init(runtime, &source, model.budget.max_query_seconds);
            try timer.start();
            defer timer.deinit();
            var reader = try read.Reader.open(runtime.allocator, &source, query, .{ .max_rows = model.budget.max_rows -| record.rows_moved, .max_bytes = model.budget.max_bytes -| record.bytes_moved, .max_memory_bytes = model.budget.max_memory_bytes }, model.budget.max_query_seconds);
            defer {
                timer.deinit();
                record.rows_moved +|= reader.guard.rows;
                record.bytes_moved +|= reader.guard.bytes;
                record.egress_cost += @as(f64, @floatFromInt(reader.guard.bytes)) / (1024 * 1024 * 1024) * plan.connections[input.connection].egress_per_gib;
                reader.deinit();
            }
            if (reader.columns.len != 2 or reader.columns[1].kind != .timestamp) return error.InvalidCrossDatabaseSourceWatermark;
            while (try reader.next()) |result| {
                var batch = result;
                defer batch.deinit(runtime.allocator);
                if (timer.expired.load(.acquire)) return error.CrossDatabaseTimeBudgetExceeded;
                if (model.budget.max_cost) |max_cost| if (record.egress_cost + @as(f64, @floatFromInt(reader.guard.bytes)) / (1024 * 1024 * 1024) * plan.connections[input.connection].egress_per_gib > max_cost) return error.CrossDatabaseCostBudgetExceeded;
                for (batch.rows) |row| {
                    const value = row[0] orelse return error.CrossDatabaseIncrementalNullKey;
                    if (!keys.contains(value)) {
                        key_bytes +|= value.len + @sizeOf([]const u8) + 64;
                        if (key_bytes > model.budget.max_memory_bytes / 8) return error.CrossDatabaseMemoryBudgetExceeded;
                        try keys.put(try allocator.dupe(u8, value), {});
                    }
                    if (row[1]) |value_watermark| {
                        if (!validTimestamp(value_watermark)) return error.InvalidCrossDatabaseSourceWatermark;
                        if (progress.value == null or std.mem.order(u8, progress.value.?, value_watermark) == .lt) progress.value = try allocator.dupe(u8, value_watermark);
                    }
                }
            }
        }
        // Canonical ordering makes physical predicates reproducible, independent
        // of native query/cursor batch order.
        const key_list = try allocator.alloc([]const u8, keys.count());
        var iterator = keys.keyIterator();
        var index: usize = 0;
        while (iterator.next()) |key| : (index += 1) key_list[index] = key.*;
        std.mem.sort([]const u8, key_list, {}, less);
        var literals: std.Io.Writer.Allocating = .init(allocator);
        for (key_list, 0..) |key, at| {
            if (at != 0) try literals.writer.writeByte(',');
            try literals.writer.writeAll(try adapter.quoteLiteral(allocator, key));
        }
        state.keys_sql = literals.written();
        state.key_count = key_list.len;
        state.model.inputs = try allocator.dupe(cross.Input, model.inputs);
        if (!state.rebuild) for (state.model.inputs) |*input| {
            const key = try adapter.quoteIdentifier(allocator, input.incremental_key.?);
            input.query = if (key_list.len == 0) try std.fmt.allocPrint(allocator, "select * from ({s}) __dxt_current where false", .{input.query}) else try std.fmt.allocPrint(allocator, "select * from ({s}) __dxt_current where {s} in ({s})", .{ input.query, key, state.keys_sql });
        };
        return state;
    }

    /// Replace affected rows/partitions in a transactional target. Append only
    /// inserts previously unseen keys; merge validates its promised unique key.
    pub fn apply(self: *State, runtime: cross.Runtime, destination: *adapter.Session, temporary: []const u8, target: []const u8) !bool {
        const allocator = self.arena.allocator();
        const key = try adapter.quoteIdentifier(allocator, self.model.unique_key.?);
        if (!std.mem.eql(u8, self.model.incremental_strategy, "insert_overwrite")) {
            const validation = try std.fmt.allocPrint(allocator, "select count(*) from (select {s} from {s} group by {s} having count(*)>1 or {s} is null) __dxt_invalid", .{ key, temporary, key, key });
            var invalid = try destination.query(validation);
            defer invalid.deinit(runtime.allocator);
            if (!std.mem.eql(u8, invalid.firstScalar() orelse "", "0")) return error.CrossDatabaseIncrementalUniqueKeyViolation;
        }
        if (self.rebuild) return false;
        if (self.key_count != 0) {
            if (std.mem.eql(u8, self.model.incremental_strategy, "append")) {
                const insert = try std.fmt.allocPrint(allocator, "insert into {s} select source.* from {s} source where not exists(select 1 from {s} existing where source.{s}=existing.{s})", .{ target, temporary, target, key, key });
                try destination.execute(insert);
            } else {
                const remove = try std.fmt.allocPrint(allocator, "delete from {s} where {s} in ({s})", .{ target, key, self.keys_sql });
                try destination.execute(remove);
                const insert = try std.fmt.allocPrint(allocator, "insert into {s} select * from {s}", .{ target, temporary });
                try destination.execute(insert);
            }
        }
        const drop = try std.fmt.allocPrint(allocator, "drop table {s}", .{temporary});
        try destination.execute(drop);
        return true;
    }

    pub fn commit(self: *State, destination: *adapter.Session, run_id: []const u8) !void {
        const allocator = self.arena.allocator();
        try destination.execute("create table if not exists dxt_internal.cross_watermark_history (run_id text,model text,input text,query_hash text,watermark text,primary key(run_id,model,input))");
        const target = try adapter.quoteLiteral(allocator, self.target_key);
        const clear = try std.fmt.allocPrint(allocator, "delete from dxt_internal.cross_watermarks where model={s}", .{target});
        try destination.execute(clear);
        for (self.watermarks) |watermark| {
            const statement = try std.fmt.allocPrint(allocator, "insert into dxt_internal.cross_watermarks values({s},{s},{s},{s})", .{ target, try adapter.quoteLiteral(allocator, watermark.input), try adapter.quoteLiteral(allocator, watermark.query_hash), if (watermark.value) |value| try adapter.quoteLiteral(allocator, value) else "null" });
            try destination.execute(statement);
            const history = try std.fmt.allocPrint(allocator, "insert into dxt_internal.cross_watermark_history values({s},{s},{s},{s},{s})", .{ try adapter.quoteLiteral(allocator, run_id), target, try adapter.quoteLiteral(allocator, watermark.input), try adapter.quoteLiteral(allocator, watermark.query_hash), if (watermark.value) |value| try adapter.quoteLiteral(allocator, value) else "null" });
            try destination.execute(history);
        }
    }
};

fn less(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}
fn validTimestamp(value: []const u8) bool {
    if (value.len < 19 or value[4] != '-' or value[7] != '-' or value[10] != ' ' or value[13] != ':' or value[16] != ':') return false;
    for (value, 0..) |char, index| if (index != 4 and index != 7 and index != 10 and index != 13 and index != 16 and !std.ascii.isDigit(char) and char != '.') return false;
    return true;
}

test "source watermark shape rejects infinities timezone and noncanonical years" {
    try std.testing.expect(validTimestamp("2024-02-29 12:34:56.1234"));
    try std.testing.expect(!validTimestamp("infinity"));
    try std.testing.expect(!validTimestamp("2024-02-29 12:34:56+02"));
}
