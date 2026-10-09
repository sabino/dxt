const std = @import("std");
const Io = std.Io;
const project_fs = @import("fs.zig");
const json = @import("json.zig");
const yaml = @import("yaml.zig");
const types = @import("types.zig");

const Node = types.Node;
const GenericTestNode = types.GenericTestNode;
const SingularTestNode = types.SingularTestNode;
const UnitTestDef = types.UnitTestDef;
const Runtime = types.Runtime;
const clock = @import("execution_clock.zig");

pub const LogMessage = struct {
    message: []const u8,
    level: []const u8,
    is_print: bool = false,
};

pub const NodeResult = struct {
    operation_id: ?[]const u8 = null,
    node: ?*const Node = null,
    test_node: ?*const GenericTestNode = null,
    singular_test_node: ?*const SingularTestNode = null,
    unit_test_node: ?*const UnitTestDef = null,
    status: []const u8 = "success",
    message: ?[]const u8 = null,
    failures: ?i64 = null,
    compiled_code: ?[]const u8 = null,
    owns_compiled_code: bool = false,
    relation_name: ?[]const u8 = null,
    owns_relation_name: bool = false,
    compiled_override: ?bool = null,
    thread_number: u16 = 1,
    execution_started_at: ?i96 = null,
    execution_completed_at: ?i96 = null,
    execution_time: f64 = 0,
    compile_started_at: ?i96 = null,
    compile_completed_at: ?i96 = null,
    adapter_response: ?AdapterResponse = null,
    compiled_ctes: []const types.ExtraCte = &.{},
    owns_compiled_ctes: bool = false,
    log_output: ?[]const u8 = null,
    owns_log_output: bool = false,
    log_events: []const LogMessage = &.{},
    owns_log_events: bool = false,
    batch_results: ?BatchResults = null,
    owns_batch_results: bool = false,
};

pub const BatchResults = struct {
    successful: []const types.SampleWindow = &.{},
    failed: []const types.SampleWindow = &.{},

    pub fn deinit(self: BatchResults, allocator: std.mem.Allocator) void {
        allocator.free(self.successful);
        allocator.free(self.failed);
    }
};

pub const AdapterResponse = struct {
    message: ?[]const u8 = null,
    code: ?[]const u8 = null,
    rows_affected: ?i64 = null,
};

pub const ResultStatusRow = struct {
    unique_id: []const u8,
    status: []const u8,
};

pub const ResultStatusIndex = struct {
    rows: []ResultStatusRow = &.{},

    pub fn deinit(self: *ResultStatusIndex, allocator: std.mem.Allocator) void {
        for (self.rows) |row| {
            allocator.free(row.unique_id);
            allocator.free(row.status);
        }
        allocator.free(self.rows);
        self.* = .{};
    }

    pub fn statusFor(self: *const ResultStatusIndex, unique_id: []const u8) ?[]const u8 {
        for (self.rows) |row| {
            if (std.mem.eql(u8, row.unique_id, unique_id)) return row.status;
        }
        return null;
    }
};

pub fn loadResultStatusIndex(runtime: Runtime, state_dir: []const u8) !ResultStatusIndex {
    const path = try project_fs.pathJoin(runtime.allocator, &.{ state_dir, "run_results.json" });
    defer runtime.allocator.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.MissingRunResultsArtifact,
        else => return err,
    };
    defer runtime.allocator.free(text);
    return try parseResultStatusIndex(runtime.allocator, text);
}

pub fn parseResultStatusIndex(allocator: std.mem.Allocator, text: []const u8) !ResultStatusIndex {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return error.MalformedRunResultsArtifact;
    defer parsed.deinit();

    const root = if (parsed.value == .object) parsed.value.object else return error.MalformedRunResultsArtifact;
    const metadata_value = root.get("metadata") orelse return error.MalformedRunResultsArtifact;
    const metadata = if (metadata_value == .object) metadata_value.object else return error.MalformedRunResultsArtifact;
    const schema_value = metadata.get("dbt_schema_version") orelse return error.MalformedRunResultsArtifact;
    const schema_version = if (schema_value == .string) schema_value.string else return error.MalformedRunResultsArtifact;
    if (!std.mem.eql(u8, schema_version, "https://schemas.getdbt.com/dbt/run-results/v6.json")) return error.UnsupportedRunResultsSchemaVersion;

    const results_value = root.get("results") orelse return error.MalformedRunResultsArtifact;
    const results = if (results_value == .array) results_value.array else return error.MalformedRunResultsArtifact;

    var rows: std.ArrayList(ResultStatusRow) = .empty;
    errdefer {
        for (rows.items) |row| {
            allocator.free(row.unique_id);
            allocator.free(row.status);
        }
        rows.deinit(allocator);
    }

    for (results.items) |result_value| {
        const result = if (result_value == .object) result_value.object else return error.MalformedRunResultsArtifact;
        const unique_id_value = result.get("unique_id") orelse return error.MalformedRunResultsArtifact;
        const status_value = result.get("status") orelse return error.MalformedRunResultsArtifact;
        const unique_id = if (unique_id_value == .string) unique_id_value.string else return error.MalformedRunResultsArtifact;
        const status = if (status_value == .string) status_value.string else return error.MalformedRunResultsArtifact;
        try rows.append(allocator, .{
            .unique_id = try allocator.dupe(u8, unique_id),
            .status = try allocator.dupe(u8, status),
        });
    }

    return .{ .rows = try rows.toOwnedSlice(allocator) };
}

pub fn isSupportedResultSelectorStatus(status: []const u8) bool {
    return std.mem.eql(u8, status, "success") or
        std.mem.eql(u8, status, "error") or
        std.mem.eql(u8, status, "fail") or
        std.mem.eql(u8, status, "skipped");
}

pub fn renderRunResults(allocator: std.mem.Allocator, results: []const NodeResult) ![]const u8 {
    return renderRunResultsWithContext(allocator, results, null, null);
}

pub fn renderRunResultsForRuntime(runtime: Runtime, results: []const NodeResult) ![]const u8 {
    return renderRunResultsWithContext(runtime.allocator, results, runtime.invocation_options, runtime.invocation);
}

pub fn renderRunResultsWithInvocation(allocator: std.mem.Allocator, results: []const NodeResult, metadata: ?*const @import("invocation.zig").Metadata) ![]const u8 {
    return renderRunResultsWithContext(allocator, results, null, metadata);
}

pub fn renderRunResultsWithArgs(allocator: std.mem.Allocator, results: []const NodeResult, options: ?*const types.Options) ![]const u8 {
    return renderRunResultsWithContext(allocator, results, options, null);
}

fn renderRunResultsWithContext(allocator: std.mem.Allocator, results: []const NodeResult, options: ?*const types.Options, metadata: ?*const @import("invocation.zig").Metadata) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\n  \"metadata\": {");
    try @import("invocation.zig").writeFields(writer, "https://schemas.getdbt.com/dbt/run-results/v6.json", metadata);
    try writer.writeAll("},\n");
    try writer.writeAll("  \"results\": [");
    for (results, 0..) |result, index| {
        if (index != 0) try writer.writeAll(",");
        try writeResult(writer, result);
    }
    try writer.print("\n  ],\n  \"elapsed_time\": {d},\n  \"args\": ", .{if (metadata) |value| value.elapsed() else @as(f64, 0)});
    try writeArgs(writer, allocator, options);
    try writer.writeAll("\n}\n");
    return try out.toOwnedSlice();
}

fn writeTiming(writer: *Io.Writer, name: []const u8, start: ?i96, finish: ?i96) !void {
    try writer.writeAll("{\"name\": ");
    try json.string(writer, name);
    try writer.writeAll(", \"started_at\": ");
    try clock.writeTimestamp(writer, start);
    try writer.writeAll(", \"completed_at\": ");
    try clock.writeTimestamp(writer, finish);
    try writer.writeByte('}');
}

fn writeArgs(writer: *Io.Writer, allocator: std.mem.Allocator, options: ?*const types.Options) !void {
    const opts = options orelse {
        try writer.writeAll("{}");
        return;
    };
    try writer.writeAll("{\"which\":");
    try json.string(writer, opts.which);
    inline for (.{ "profile", "target", "state", "defer_state", "selector" }) |key| {
        if (@field(opts, key)) |value| {
            try writer.print(",\"{s}\":", .{key});
            try json.string(writer, value);
        }
    }
    inline for (.{ "select", "exclude" }) |key| {
        try writer.print(",\"{s}\":", .{key});
        if (std.mem.eql(u8, opts.which, "run-operation")) {
            try writer.writeAll("null");
        } else {
            try writer.writeByte('[');
            if (@field(opts, key)) |value| {
                var parts = std.mem.tokenizeAny(u8, value, " \t\r\n");
                var first = true;
                while (parts.next()) |part| {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try json.string(writer, part);
                }
            }
            try writer.writeByte(']');
        }
    }
    try writer.writeAll(",\"vars\":");
    try writeMapping(writer, allocator, opts.vars);
    if (opts.threads) |value| {
        try writer.writeAll(",\"threads\":");
        const threads = std.fmt.parseInt(u32, value, 10) catch return error.InvalidOption;
        if (threads == 0) return error.InvalidOption;
        try writer.print("{d}", .{threads});
    }
    if (std.mem.eql(u8, opts.which, "seed") or std.mem.eql(u8, opts.which, "build")) try writer.print(",\"show\":{s}", .{if (opts.seed_show) "true" else "false"});
    try writer.print(",\"full_refresh\":{s}", .{if (opts.full_refresh) "true" else "false"});
    if (std.mem.eql(u8, opts.which, "test") or std.mem.eql(u8, opts.which, "build")) try writer.print(",\"store_failures\":{s}", .{if (opts.store_failures) "true" else "false"});
    if (std.mem.eql(u8, opts.which, "run") or std.mem.eql(u8, opts.which, "build") or std.mem.eql(u8, opts.which, "compile") or std.mem.eql(u8, opts.which, "snapshot")) try writer.print(",\"empty\":{s}", .{if (opts.empty) "true" else "false"});
    if (opts.sample_window) |window| {
        try writer.writeAll(",\"sample\":{\"start\":");
        inline for (.{ "start", "end" }) |key| {
            if (std.mem.eql(u8, key, "end")) try writer.writeAll(",\"end\":");
            const timestamp = try @import("input_relations.zig").formatSampleTimestamp(allocator, @field(window, key));
            defer allocator.free(timestamp);
            const zoned = try std.fmt.allocPrint(allocator, "{s}T{s}+00:00", .{ timestamp[0..10], timestamp[11..] });
            defer allocator.free(zoned);
            try json.string(writer, zoned);
        }
        try writer.writeByte('}');
    } else if (opts.sample) |value| {
        try writer.writeAll(",\"sample\":");
        try json.string(writer, value);
    }
    inline for (.{ "event_time_start", "event_time_end" }) |key| if (@field(opts, key)) |value| {
        try writer.print(",\"{s}\":", .{key});
        try json.string(writer, value);
    };
    try writer.print(",\"fail_fast\":{s},\"log_format\":", .{if (opts.fail_fast) "true" else "false"});
    try json.string(writer, @tagName(opts.log_format));
    try writer.print(",\"quiet\":{s},\"write_json\":{s},\"warn_error\":{s},\"version_check\":{s}", .{ if (opts.quiet) "true" else "false", if (opts.write_json) "true" else "false", if (opts.warn_error) "true" else "false", if (opts.version_check) "true" else "false" });
    try writer.print(",\"debug\":{s}", .{if (opts.debug) "true" else "false"});
    try writer.print(",\"use_colors\":{s},\"use_colors_file\":{s},\"print\":{s}", .{ if (opts.use_colors) "true" else "false", if (opts.use_colors_file) "true" else "false", if (opts.print_enabled) "true" else "false" });
    try writer.writeAll(",\"warn_error_options\":");
    try writeMapping(writer, allocator, opts.warn_error_options);
    try writer.writeAll(",\"log_level\":");
    try json.string(writer, @tagName(opts.log_level));
    try writer.writeAll(",\"log_level_file\":");
    try json.string(writer, @tagName(opts.log_level_file));
    try writer.writeAll(",\"log_format_file\":");
    try json.string(writer, @tagName(opts.log_format_file));
    if (opts.log_path) |path| {
        try writer.writeAll(",\"log_path\":");
        try json.string(writer, path);
    }
    try writer.print(",\"defer\":{s},\"favor_state\":{s},\"indirect_selection\":", .{ if (opts.defer_enabled) "true" else "false", if (opts.favor_state) "true" else "false" });
    try json.string(writer, opts.indirect_selection);
    if (std.mem.eql(u8, opts.which, "generate")) {
        try writer.print(",\"static\":{s},\"compile\":{s}", .{ if (opts.docs_static) "true" else "false", if (opts.docs_compile) "true" else "false" });
        try writer.print(",\"empty_catalog\":{s}", .{if (opts.docs_empty_catalog) "true" else "false"});
    }
    if (std.mem.eql(u8, opts.which, "run-operation")) {
        try writer.writeAll(",\"macro\":");
        if (opts.command_name) |value| try json.string(writer, value) else try writer.writeAll("null");
        try writer.writeAll(",\"args\":");
        try writeMapping(writer, allocator, opts.command_args);
    }
    try writer.writeAll("}");
}

fn writeMapping(writer: *Io.Writer, allocator: std.mem.Allocator, text: ?[]const u8) !void {
    if (text) |value| {
        var document = try yaml.parse(allocator, value);
        defer document.deinit();
        if (document.value != .object) return error.InvalidOperationArgs;
        try std.json.Stringify.value(document.value, .{}, writer);
    } else try writer.writeAll("{}");
}

fn writeResult(writer: *Io.Writer, result: NodeResult) !void {
    try writer.writeAll("\n    {\"status\": ");
    try json.string(writer, result.status);
    try writer.writeAll(", \"timing\": [");
    var has_timing = false;
    if (result.compile_started_at != null and result.compile_completed_at != null) {
        try writeTiming(writer, "compile", result.compile_started_at, result.compile_completed_at);
        has_timing = true;
    }
    if (result.execution_started_at != null and result.execution_completed_at != null) {
        if (has_timing) try writer.writeAll(", ");
        try writeTiming(writer, "execute", result.execution_started_at, result.execution_completed_at);
    }
    try writer.print("], \"thread_id\": \"Thread-{d}\", \"execution_time\": {d}, \"adapter_response\": {{", .{ result.thread_number, result.execution_time });
    if (result.adapter_response) |response| {
        var fields: usize = 0;
        if (response.message) |message| {
            try writer.writeAll("\"_message\": ");
            try json.string(writer, message);
            fields += 1;
        }
        if (response.code) |code| {
            if (fields != 0) try writer.writeAll(", ");
            try writer.writeAll("\"code\": ");
            try json.string(writer, code);
            fields += 1;
        }
        if (response.rows_affected) |count| {
            if (fields != 0) try writer.writeAll(", ");
            try writer.print("\"rows_affected\": {d}", .{count});
        }
    }
    try writer.writeAll("}, \"message\": ");
    if (result.message) |message| {
        try json.string(writer, message);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(", \"failures\": ");
    if (result.failures) |failures| {
        try writer.print("{d}", .{failures});
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(", \"unique_id\": ");
    try json.string(writer, resultUniqueId(result));
    try writer.writeAll(", \"compiled\": ");
    const skipped = std.mem.eql(u8, result.status, "skipped");
    if (result.compiled_override) |compiled| {
        try writer.writeAll(if (compiled) "true" else "false");
    } else if (result.operation_id != null) {
        try writer.writeAll("false");
    } else if (skipped) {
        if (result.test_node != null or result.singular_test_node != null) {
            try writer.writeAll("false");
        } else if (result.node) |node| {
            try writer.writeAll(if (isCompiledResultNode(node)) "false" else "null");
        } else try writer.writeAll("null");
    } else if (result.unit_test_node != null and std.mem.eql(u8, result.status, "error")) {
        try writer.writeAll("null");
    } else if (result.test_node != null or result.singular_test_node != null or result.unit_test_node != null or result.compiled_code != null) {
        try writer.writeAll("true");
    } else if (result.node) |node| if (isCompiledResultNode(node)) {
        try writer.writeAll(if (node.compiled) "true" else "false");
    } else {
        try writer.writeAll("null");
    } else try writer.writeAll("null");
    try writer.writeAll(", \"compiled_code\": ");
    if (skipped) {
        try writer.writeAll("null");
    } else if (result.compiled_code) |compiled_code| {
        try json.string(writer, compiled_code);
    } else if (result.node) |node| if (isCompiledResultNode(node) and node.compiled_code != null) {
        const compiled_code = node.compiled_code.?;
        try json.string(writer, compiled_code);
    } else {
        try writer.writeAll("null");
    } else try writer.writeAll("null");
    try writer.writeAll(", \"relation_name\": ");
    if (result.relation_name) |relation_name| {
        try json.string(writer, relation_name);
    } else if (result.node) |node| if (isCompiledResultNode(node) and node.relation_name != null) {
        const relation_name = node.relation_name.?;
        try json.string(writer, relation_name);
    } else {
        try writer.writeAll("null");
    } else try writer.writeAll("null");
    if (result.batch_results) |batches| {
        try writer.writeAll(", \"batch_results\": {\"successful\": ");
        try writeBatchIntervals(writer, batches.successful);
        try writer.writeAll(", \"failed\": ");
        try writeBatchIntervals(writer, batches.failed);
        try writer.writeAll("}");
    }
    try writer.writeAll("}");
}

fn writeBatchTimestamp(writer: *Io.Writer, timestamp: i96) !void {
    // Event-time histories may predate the Unix epoch; execution clocks do not.
    var storage: [128]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    const label = try @import("workflow_intervals.zig").formatTimestamp(fixed.allocator(), @intCast(@divFloor(timestamp, std.time.ns_per_s)));
    try writer.print("\"{s}T{s}.{d:0>6}Z\"", .{ label[0..10], label[11..19], @as(u64, @intCast(@divFloor(@mod(timestamp, std.time.ns_per_s), std.time.ns_per_us))) });
}

fn writeBatchIntervals(writer: *Io.Writer, batches: []const types.SampleWindow) !void {
    try writer.writeByte('[');
    for (batches, 0..) |batch, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.writeByte('[');
        try writeBatchTimestamp(writer, batch.start);
        try writer.writeByte(',');
        try writeBatchTimestamp(writer, batch.end);
        try writer.writeByte(']');
    }
    try writer.writeByte(']');
}

fn resultUniqueId(result: NodeResult) []const u8 {
    if (result.operation_id) |id| return id;
    if (result.node) |node| return node.unique_id;
    if (result.test_node) |test_node| return test_node.unique_id;
    if (result.singular_test_node) |test_node| return test_node.unique_id;
    if (result.unit_test_node) |unit_test| return unit_test.unique_id;
    return "";
}

fn isCompiledResultNode(node: *const Node) bool {
    return std.mem.eql(u8, node.resource_type, "model") or std.mem.eql(u8, node.resource_type, "snapshot");
}

test "run-results writer emits dbt v6 success shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select 1 as id",
        .compiled = true,
        .compiled_code = "select 1 as id",
        .relation_name = "\"main\".\"customers\"",
    });

    const rendered = try renderRunResults(allocator, &.{.{ .node = &graph.nodes.items[0] }});
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("https://schemas.getdbt.com/dbt/run-results/v6.json", root.get("metadata").?.object.get("dbt_schema_version").?.string);
    const result = root.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("success", result.get("status").?.string);
    try std.testing.expectEqualStrings("model.demo.customers", result.get("unique_id").?.string);
    try std.testing.expectEqual(true, result.get("compiled").?.bool);
    try std.testing.expectEqualStrings("select 1 as id", result.get("compiled_code").?.string);
    try std.testing.expectEqualStrings("\"main\".\"customers\"", result.get("relation_name").?.string);
}

test "run-results writer emits custom generic test error shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.positive_amount_orders_amount.abc",
        .name = "positive_amount_orders_amount",
        .alias = "positive_amount_orders_amount",
        .path = "positive_amount_orders_amount.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_positive_amount(**_dbt_generic_test_kwargs) }}",
        .test_name = "positive_amount",
        .column_name = "amount",
        .attached_node = "model.demo.orders",
    });

    const rendered = try renderRunResults(allocator, &.{.{
        .test_node = &graph.tests.items[0],
        .status = "error",
        .message = "DuckDB execution failed",
        .compiled_code = "select missing_amount from \"main\".\"orders\"",
    }});
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("error", result.get("status").?.string);
    try std.testing.expectEqualStrings("DuckDB execution failed", result.get("message").?.string);
    try std.testing.expectEqualStrings("test.demo.positive_amount_orders_amount.abc", result.get("unique_id").?.string);
    try std.testing.expectEqual(true, result.get("compiled").?.bool);
    try std.testing.expectEqualStrings("select missing_amount from \"main\".\"orders\"", result.get("compiled_code").?.string);
    try std.testing.expectEqual(.null, result.get("failures").?);
    try std.testing.expectEqual(.null, result.get("relation_name").?);
}

test "run-results status index loads dbt v6 result statuses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text =
        \\{
        \\  "metadata": {"dbt_schema_version": "https://schemas.getdbt.com/dbt/run-results/v6.json"},
        \\  "results": [
        \\    {"unique_id": "model.demo.customers", "status": "success"},
        \\    {"unique_id": "model.demo.orders", "status": "error"},
        \\    {"unique_id": "test.demo.not_null_customers_id.abc", "status": "fail"},
        \\    {"unique_id": "model.demo.downstream", "status": "skipped"},
        \\    {"unique_id": "test.demo.accepted_values_orders_status.def", "status": "pass"}
        \\  ],
        \\  "elapsed_time": 0.0
        \\}
    ;

    var index = try parseResultStatusIndex(allocator, text);
    defer index.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), index.rows.len);
    try std.testing.expectEqualStrings("success", index.statusFor("model.demo.customers").?);
    try std.testing.expectEqualStrings("error", index.statusFor("model.demo.orders").?);
    try std.testing.expectEqualStrings("fail", index.statusFor("test.demo.not_null_customers_id.abc").?);
    try std.testing.expectEqualStrings("skipped", index.statusFor("model.demo.downstream").?);
    try std.testing.expectEqualStrings("pass", index.statusFor("test.demo.accepted_values_orders_status.def").?);
    try std.testing.expect(index.statusFor("model.demo.missing") == null);
}

test "run-results status index reports malformed and version mismatch artifacts" {
    try std.testing.expectError(error.MalformedRunResultsArtifact, parseResultStatusIndex(std.testing.allocator, "{}"));
    try std.testing.expectError(
        error.UnsupportedRunResultsSchemaVersion,
        parseResultStatusIndex(std.testing.allocator,
            \\{"metadata":{"dbt_schema_version":"https://schemas.getdbt.com/dbt/run-results/v5.json"},"results":[]}
        ),
    );
    try std.testing.expectError(
        error.MalformedRunResultsArtifact,
        parseResultStatusIndex(std.testing.allocator,
            \\{"metadata":{"dbt_schema_version":"https://schemas.getdbt.com/dbt/run-results/v6.json"},"results":[{"unique_id":"model.demo.customers"}]}
        ),
    );
}

test "run-results writer emits seed result with dbt Core null compiled fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .resource_type = "seed",
        .package_name = "demo",
        .unique_id = "seed.demo.raw_customers",
        .name = "raw_customers",
        .path = "raw_customers.csv",
        .original_file_path = "seeds/raw_customers.csv",
        .raw_code = "",
        .materialized = "seed",
    });

    const rendered = try renderRunResults(allocator, &.{.{ .node = &graph.nodes.items[0] }});
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("seed.demo.raw_customers", result.get("unique_id").?.string);
    try std.testing.expectEqual(.null, result.get("compiled").?);
    try std.testing.expectEqual(.null, result.get("compiled_code").?);
    try std.testing.expectEqual(.null, result.get("relation_name").?);
}

test "run-results writer emits compiled model error result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select * from missing_relation",
        .compiled = true,
        .compiled_code = "select * from missing_relation",
        .relation_name = "\"main\".\"orders\"",
    });

    const rendered = try renderRunResults(allocator, &.{.{
        .node = &graph.nodes.items[0],
        .status = "error",
        .message = "DuckDB execution failed",
    }});
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("error", result.get("status").?.string);
    try std.testing.expectEqualStrings("DuckDB execution failed", result.get("message").?.string);
    try std.testing.expectEqual(.null, result.get("failures").?);
    try std.testing.expectEqualStrings("model.demo.orders", result.get("unique_id").?.string);
    try std.testing.expectEqual(true, result.get("compiled").?.bool);
    try std.testing.expectEqualStrings("select * from missing_relation", result.get("compiled_code").?.string);
    try std.testing.expectEqualStrings("\"main\".\"orders\"", result.get("relation_name").?.string);
}

test "run-results writer omits compiled model fields for skipped execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.orders",
        .name = "orders",
        .path = "orders.sql",
        .original_file_path = "models/orders.sql",
        .raw_code = "select * from {{ ref('customers') }}",
        .compiled = true,
        .compiled_code = "select * from \"main\".\"customers\"",
        .relation_name = "\"main\".\"orders\"",
    });

    const rendered = try renderRunResults(allocator, &.{.{
        .node = &graph.nodes.items[0],
        .status = "skipped",
    }});
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("skipped", result.get("status").?.string);
    try std.testing.expectEqual(.null, result.get("message").?);
    try std.testing.expectEqual(.null, result.get("failures").?);
    try std.testing.expectEqualStrings("model.demo.orders", result.get("unique_id").?.string);
    try std.testing.expectEqual(false, result.get("compiled").?.bool);
    try std.testing.expectEqual(.null, result.get("compiled_code").?);
    try std.testing.expectEqualStrings("\"main\".\"orders\"", result.get("relation_name").?.string);
}

test "run-results writer emits generic test pass and fail statuses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.not_null_customers_customer_id.abc",
        .name = "not_null_customers_customer_id",
        .alias = "not_null_customers_customer_id",
        .path = "not_null_customers_customer_id.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_not_null(**_dbt_generic_test_kwargs) }}",
        .test_name = "not_null",
        .column_name = "customer_id",
        .attached_node = "model.demo.customers",
    });

    const rendered = try renderRunResults(allocator, &.{
        .{
            .test_node = &graph.tests.items[0],
            .status = "fail",
            .message = "Got 1 result, configured to fail if != 0",
            .failures = 1,
            .compiled_code = "select 1 as failures",
            .relation_name = "\"dbt_test__audit\".\"not_null_customers_customer_id\"",
        },
    });
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("fail", result.get("status").?.string);
    try std.testing.expectEqualStrings("test.demo.not_null_customers_customer_id.abc", result.get("unique_id").?.string);
    try std.testing.expectEqual(@as(i64, 1), result.get("failures").?.integer);
    try std.testing.expectEqual(true, result.get("compiled").?.bool);
    try std.testing.expectEqualStrings("select 1 as failures", result.get("compiled_code").?.string);
    try std.testing.expectEqualStrings("\"dbt_test__audit\".\"not_null_customers_customer_id\"", result.get("relation_name").?.string);
}

test "skipped data and unit test rows never expose preflight compiled SQL" {
    const allocator = std.testing.allocator;
    const generic = GenericTestNode{
        .package_name = "demo",
        .unique_id = "test.demo.not_null_orders_id.abc",
        .name = "not_null_orders_id",
        .alias = "not_null_orders_id",
        .path = "not_null_orders_id.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_not_null(**_dbt_generic_test_kwargs) }}",
        .test_name = "not_null",
        .column_name = "id",
    };
    const unit = UnitTestDef{
        .package_name = "demo",
        .unique_id = "unit_test.demo.orders.skipped",
        .name = "skipped",
        .path = "schema.yml",
        .original_file_path = "models/schema.yml",
    };
    const rendered = try renderRunResults(allocator, &.{
        .{ .test_node = &generic, .status = "skipped", .compiled_code = "preflight data SQL" },
        .{ .unit_test_node = &unit, .status = "skipped", .compiled_code = "preflight unit SQL" },
    });
    defer allocator.free(rendered);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();
    const rows = parsed.value.object.get("results").?.array.items;
    try std.testing.expectEqual(false, rows[0].object.get("compiled").?.bool);
    try std.testing.expectEqual(.null, rows[1].object.get("compiled").?);
    for (rows) |row| {
        try std.testing.expectEqual(.null, row.object.get("compiled_code").?);
        try std.testing.expectEqual(.null, row.object.get("failures").?);
        try std.testing.expectEqual(.null, row.object.get("message").?);
    }
}

test "run-results writer preserves mixed model and generic test order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select 1 as id",
        .compiled = true,
        .compiled_code = "select 1 as id",
        .relation_name = "\"main\".\"customers\"",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.not_null_customers_customer_id.abc",
        .name = "not_null_customers_customer_id",
        .alias = "not_null_customers_customer_id",
        .path = "not_null_customers_customer_id.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_not_null(**_dbt_generic_test_kwargs) }}",
        .test_name = "not_null",
        .column_name = "customer_id",
        .attached_node = "model.demo.customers",
    });

    const rendered = try renderRunResults(allocator, &.{
        .{ .node = &graph.nodes.items[0] },
        .{
            .test_node = &graph.tests.items[0],
            .status = "pass",
            .failures = 0,
            .compiled_code = "select * from customers where customer_id is null",
        },
    });
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const results = parsed.value.object.get("results").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("model.demo.customers", results[0].object.get("unique_id").?.string);
    try std.testing.expectEqualStrings("success", results[0].object.get("status").?.string);
    try std.testing.expectEqualStrings("test.demo.not_null_customers_customer_id.abc", results[1].object.get("unique_id").?.string);
    try std.testing.expectEqualStrings("pass", results[1].object.get("status").?.string);
    try std.testing.expectEqual(@as(i64, 0), results[1].object.get("failures").?.integer);
}

test "run-results writer preserves seed model and generic test shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.nodes.append(allocator, .{
        .resource_type = "seed",
        .package_name = "demo",
        .unique_id = "seed.demo.raw_customers",
        .name = "raw_customers",
        .path = "raw_customers.csv",
        .original_file_path = "seeds/raw_customers.csv",
        .raw_code = "",
        .materialized = "seed",
    });
    try graph.nodes.append(allocator, .{
        .package_name = "demo",
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "select * from {{ ref(\"raw_customers\") }}",
        .compiled = true,
        .compiled_code = "select * from \"main\".\"raw_customers\"",
        .relation_name = "\"main\".\"customers\"",
    });
    try graph.tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "test.demo.not_null_customers_customer_id.abc",
        .name = "not_null_customers_customer_id",
        .alias = "not_null_customers_customer_id",
        .path = "not_null_customers_customer_id.sql",
        .original_file_path = "models/schema.yml",
        .raw_code = "{{ test_not_null(**_dbt_generic_test_kwargs) }}",
        .test_name = "not_null",
        .column_name = "customer_id",
        .attached_node = "model.demo.customers",
    });

    const rendered = try renderRunResults(allocator, &.{
        .{ .node = &graph.nodes.items[0] },
        .{ .node = &graph.nodes.items[1] },
        .{
            .test_node = &graph.tests.items[0],
            .status = "pass",
            .failures = 0,
            .compiled_code = "select customer_id from customers where customer_id is null",
        },
    });
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const results = parsed.value.object.get("results").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), results.len);
    try std.testing.expectEqualStrings("seed.demo.raw_customers", results[0].object.get("unique_id").?.string);
    try std.testing.expectEqual(.null, results[0].object.get("compiled").?);
    try std.testing.expectEqual(.null, results[0].object.get("compiled_code").?);
    try std.testing.expectEqualStrings("model.demo.customers", results[1].object.get("unique_id").?.string);
    try std.testing.expectEqual(true, results[1].object.get("compiled").?.bool);
    try std.testing.expectEqualStrings("test.demo.not_null_customers_customer_id.abc", results[2].object.get("unique_id").?.string);
    try std.testing.expectEqualStrings("pass", results[2].object.get("status").?.string);
    try std.testing.expectEqual(true, results[2].object.get("compiled").?.bool);
    try std.testing.expectEqual(.null, results[2].object.get("relation_name").?);
}

test "run-results writer emits unit test pass and fail statuses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try graph.unit_tests.append(allocator, .{
        .package_name = "demo",
        .unique_id = "unit_test.demo.orders.assert_order_flags",
        .name = "assert_order_flags",
        .model = "orders",
        .path = "schema.yml",
        .original_file_path = "models/schema.yml",
    });

    const rendered = try renderRunResults(allocator, &.{
        .{
            .unit_test_node = &graph.unit_tests.items[0],
            .status = "fail",
            .message = "Got 2 results, configured to fail if != 0",
            .failures = 2,
            .compiled_code = "select count(*) as failures from dxt_unit_diff",
        },
    });
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("fail", result.get("status").?.string);
    try std.testing.expectEqualStrings("unit_test.demo.orders.assert_order_flags", result.get("unique_id").?.string);
    try std.testing.expectEqual(@as(i64, 2), result.get("failures").?.integer);
    try std.testing.expectEqual(true, result.get("compiled").?.bool);
    try std.testing.expectEqualStrings("select count(*) as failures from dxt_unit_diff", result.get("compiled_code").?.string);
    try std.testing.expectEqual(.null, result.get("relation_name").?);
}
