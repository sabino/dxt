//! Enumerated, policy-checked join locations. Unknown cardinality remains
//! unknown; opaque SQL and output estimates prevent speculative relocation.
const std = @import("std");
const cross = @import("cross_database.zig");

pub const Alternative = struct {
    strategy: []const u8,
    execution_connection: []const u8,
    execution_engine: []const u8,
    selected: bool,
    permitted: bool,
    estimated_rows: ?u64,
    estimated_moved_bytes: ?u64,
    estimated_egress_cost: ?f64,
    output_movement: bool,
    confidence: []const u8,
    reason: []const u8,
};
pub const Contributor = struct { input: []const u8, rows: ?u64, bytes: ?u64 };

pub fn alternatives(allocator: std.mem.Allocator, connections: []const cross.Connection, model: cross.Model, allow_movement: bool, allow_sensitive: bool, allow_raw: bool, allow_retention: bool) ![]Alternative {
    const result = try allocator.alloc(Alternative, connections.len);
    for (connections, 0..) |host, index| {
        const selected = index == model.execution_connection;
        var rows: u64 = 0;
        var bytes: u64 = 0;
        var cost: f64 = 0;
        var known = true;
        var moved: usize = 0;
        var denied: ?[]const u8 = null;
        if (std.mem.eql(u8, host.role, "source") or std.mem.eql(u8, host.role, "stage")) denied = "connection role does not authorize model execution";
        if (index != model.destination and !std.mem.eql(u8, host.adapter_type, "duckdb")) denied = "non-destination joins require the bounded native DuckDB execution backend";
        for (model.inputs) |input| {
            if (input.connection == index and input.stage_connection == null) continue;
            moved += 1;
            if (input.stage_connection != null and !allow_retention) denied = "stage retention has not been authorized";
            const origin = connections[input.connection];
            const stage = if (input.stage_connection) |n| connections[n] else host;
            if (!allow_movement) denied = "data movement has not been authorized";
            if (origin.allowed_destinations.len != 0 and !contains(origin.allowed_destinations, stage.name)) denied = "source policy excludes this stage or execution connection";
            if (input.stage_connection != null and stage.allowed_destinations.len != 0 and !contains(stage.allowed_destinations, host.name)) denied = "retained-stage policy excludes this execution connection";
            if (input.raw_extract and !allow_raw) denied = "raw extraction has not been authorized";
            if (!std.mem.eql(u8, input.sensitivity, "public") and !std.mem.eql(u8, input.sensitivity, "internal") and (!allow_sensitive or !std.mem.eql(u8, origin.trust_domain, stage.trust_domain) or !std.mem.eql(u8, stage.trust_domain, host.trust_domain))) denied = "sensitivity or trust-domain policy excludes this location";
            const legs: u64 = if (input.stage_connection == null) 1 else 2;
            if (input.estimated_rows) |count| rows +|= count *| legs else known = false;
            if (input.estimated_bytes) |count| {
                bytes +|= count *| legs;
                cost += @as(f64, @floatFromInt(count)) / (1024 * 1024 * 1024) * origin.egress_per_gib;
                if (input.stage_connection != null) cost += @as(f64, @floatFromInt(count)) / (1024 * 1024 * 1024) * stage.egress_per_gib;
            } else known = false;
        }
        const output_movement = index != model.destination;
        if (output_movement) {
            const destination = connections[model.destination];
            if (!allow_movement) denied = "output movement has not been authorized";
            if (host.allowed_destinations.len != 0 and !contains(host.allowed_destinations, destination.name)) denied = "execution policy excludes the final destination";
            for (model.inputs) |input| if (!std.mem.eql(u8, input.sensitivity, "public") and !std.mem.eql(u8, input.sensitivity, "internal") and (!allow_sensitive or !std.mem.eql(u8, host.trust_domain, destination.trust_domain))) {
                denied = "sensitive output cannot cross this trust boundary";
            };
            // A prior source reduction does not reveal join-output cardinality.
            known = false;
        }
        if (rows > model.budget.max_rows) denied = "estimated rows exceed the movement budget";
        if (bytes > model.budget.max_bytes) denied = "estimated bytes exceed the movement budget";
        if (model.budget.max_cost) |maximum| if (cost > maximum) {
            denied = "estimated egress cost exceeds the budget";
        };
        if (selected and model.denied != null) denied = model.denied;
        result[index] = .{ .strategy = if (selected) model.strategy else if (output_movement) "bounded_embedded_join" else if (moved == 0) "single_engine_pushdown" else if (moved == 1) "dimension_broadcast" else "destination_staged_join", .execution_connection = host.name, .execution_engine = host.adapter_type, .selected = selected, .permitted = denied == null, .estimated_rows = if (known) rows else null, .estimated_moved_bytes = if (known) bytes else null, .estimated_egress_cost = if (known) cost else null, .output_movement = output_movement, .confidence = if (!known) "unknown_output_or_source" else model.estimate_confidence, .reason = denied orelse if (selected) "selected declared native execution location; source reductions retain their connection identity" else if (output_movement) "not selected: opaque final SQL and unknown output cardinality require an explicit execution_connection" else "not selected: another execution location is explicitly configured" };
    }
    return result;
}

pub fn largest(model: cross.Model) ?Contributor {
    var result: ?Contributor = null;
    for (model.inputs) |input| if (input.moved) {
        const legs: u64 = if (input.stage_connection == null) 1 else 2;
        const bytes = if (input.estimated_bytes) |value| value *| legs else null;
        if (result == null or (bytes orelse 0) > (result.?.bytes orelse 0)) result = .{ .input = input.name, .rows = if (input.estimated_rows) |value| value *| legs else null, .bytes = bytes };
    };
    return result;
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}
