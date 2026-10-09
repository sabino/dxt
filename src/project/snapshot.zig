const std = @import("std");
const fs = @import("fs.zig");
const jinja = @import("jinja.zig");
const types = @import("types.zig");
const util = @import("util.zig");

// Source contract: dbt-core v1.10.5 parser/snapshots.py and resources/v1/snapshot.py.
// This read-only slice deliberately accepts literal SQL blocks, not general Jinja.
pub fn parseFile(runtime: types.Runtime, project_dir: []const u8, snapshot_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *types.Graph) !void {
    const path = try fs.pathJoin(runtime.allocator, &.{ project_dir, relative_path });
    defer runtime.allocator.free(path);
    const sql = try std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(16 * 1024 * 1024));
    try parseBlocks(runtime.allocator, sql, snapshot_root, relative_path, package_name, graph);
}

const Tag = struct {
    open: usize,
    end: usize,
    kind: u8,
    contents: []const u8,
    trim_left: bool,
    trim_right: bool,
};

fn nextTag(sql: []const u8, start: usize) !?Tag {
    var i = start;
    while (i + 1 < sql.len) : (i += 1) {
        if (sql[i] != '{' or (sql[i + 1] != '%' and sql[i + 1] != '{' and sql[i + 1] != '#')) continue;
        const kind = sql[i + 1];
        var close = i + 2;
        while (close + 1 < sql.len) : (close += 1) {
            if (kind != '#' and (sql[close] == '\'' or sql[close] == '"')) {
                close = jinja.skipQuotedSpan(sql, close) orelse return error.MalformedSnapshotBlock;
                if (close + 1 >= sql.len) return error.MalformedSnapshotBlock;
            }
            if (sql[close] == (if (kind == '{') '}' else kind) and sql[close + 1] == '}') {
                const trim_left = sql[i + 2] == '-';
                const trim_right = sql[close - 1] == '-';
                const raw_start = i + 2 + @as(usize, if (trim_left) 1 else 0);
                const raw_end = close - @as(usize, if (trim_right and close > raw_start) 1 else 0);
                return .{ .open = i, .end = close + 2, .kind = kind, .contents = std.mem.trim(u8, sql[raw_start..raw_end], " \t\r\n"), .trim_left = trim_left, .trim_right = trim_right };
            }
        }
        return error.MalformedSnapshotBlock;
    }
    return null;
}

pub fn parseBlocks(allocator: std.mem.Allocator, sql: []const u8, snapshot_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *types.Graph) !void {
    var cursor: usize = 0;
    var name: ?[]const u8 = null;
    var body_start: usize = 0;
    while (try nextTag(sql, cursor)) |tag| {
        cursor = tag.end;
        if (tag.kind == '#') continue;
        if (tag.kind == '{') {
            if (name == null) return error.UnsupportedSnapshotDefinition;
            continue;
        }
        if (std.mem.startsWith(u8, tag.contents, "snapshot") and
            (tag.contents.len == "snapshot".len or std.ascii.isWhitespace(tag.contents["snapshot".len])))
        {
            if (name != null) return error.MalformedSnapshotBlock;
            const raw_name = std.mem.trim(u8, tag.contents["snapshot".len..], " \t\r\n");
            if (raw_name.len == 0 or !jinja.isIdentStart(raw_name[0])) return error.MalformedSnapshotBlock;
            for (raw_name[1..]) |byte| if (!jinja.isIdentChar(byte)) return error.MalformedSnapshotBlock;
            name = raw_name;
            body_start = tag.end;
            if (tag.trim_right) {
                while (body_start < sql.len and std.ascii.isWhitespace(sql[body_start])) body_start += 1;
            }
        } else if (std.mem.eql(u8, tag.contents, "endsnapshot")) {
            const block_name = name orelse return error.MalformedSnapshotBlock;
            var body_end = tag.open;
            if (tag.trim_left) {
                while (body_end > body_start and std.ascii.isWhitespace(sql[body_end - 1])) body_end -= 1;
            }
            var node = types.Node{
                .resource_type = "snapshot",
                .package_name = package_name,
                .unique_id = try std.fmt.allocPrint(allocator, "snapshot.{s}.{s}", .{ package_name, block_name }),
                .name = try allocator.dupe(u8, block_name),
                .path = fs.relativeUnderResourcePath(relative_path, snapshot_root),
                .original_file_path = relative_path,
                .raw_code = sql[body_start..body_end],
                .snapshot_file_code = sql,
                .snapshot_config = .{},
                .materialized = "snapshot",
            };
            errdefer types.deinitNode(allocator, &node);
            try scanBody(allocator, node.raw_code, &node);
            try validateConfig(&node);
            try graph.nodes.append(allocator, node);
            name = null;
        } else {
            return error.UnsupportedSnapshotDefinition;
        }
    }
    if (name != null) return error.MalformedSnapshotBlock;
}

fn scanBody(allocator: std.mem.Allocator, sql: []const u8, node: *types.Node) !void {
    var cursor: usize = 0;
    while (try nextTag(sql, cursor)) |tag| {
        cursor = tag.end;
        if (tag.kind == '#') continue;
        if (tag.kind != '{') return error.UnsupportedSnapshotDefinition;
        const span = tag.contents;
        var name_end: usize = 0;
        while (name_end < span.len and jinja.isIdentChar(span[name_end])) name_end += 1;
        if (name_end == 0) return error.UnsupportedSnapshotDefinition;
        const call = (jinja.readJinjaCall(span, span[0..name_end], name_end) catch return error.UnsupportedSnapshotDefinition) orelse return error.UnsupportedSnapshotDefinition;
        if (call.package_name != null or std.mem.trim(u8, span[call.close + 1 ..], " \t\r\n").len != 0) return error.UnsupportedSnapshotDefinition;
        const args = span[call.open + 1 .. call.close];
        if (std.mem.eql(u8, call.name, "config")) {
            try parseConfig(allocator, args, node);
        } else if (std.mem.eql(u8, call.name, "ref")) {
            var values = try parseDependencyArgs(allocator, args, error.UnsupportedDynamicRef);
            defer values.deinit(allocator);
            if (values.items.len != 1 and values.items.len != 2) return error.UnsupportedDynamicRef;
            try node.refs.append(allocator, .{ .package = if (values.items.len == 2) values.items[0] else null, .name = values.items[values.items.len - 1] });
        } else if (std.mem.eql(u8, call.name, "source")) {
            var values = try parseDependencyArgs(allocator, args, error.UnsupportedDynamicSource);
            defer values.deinit(allocator);
            if (values.items.len != 2) return error.UnsupportedDynamicSource;
            try node.source_refs.append(allocator, .{ .source_name = values.items[0], .table_name = values.items[1] });
        } else {
            return error.UnsupportedSnapshotDefinition;
        }
    }
}

fn parseDependencyArgs(allocator: std.mem.Allocator, args: []const u8, unsupported_error: anyerror) !std.ArrayList([]const u8) {
    var values: std.ArrayList([]const u8) = .empty;
    errdefer values.deinit(allocator);
    var index: usize = 0;
    while (true) {
        index = jinja.skipWs(args, index);
        if (index == args.len) break;
        if (args[index] != '\'' and args[index] != '"') return unsupported_error;
        const parsed = jinja.parseQuoted(allocator, args, index) catch return unsupported_error;
        try values.append(allocator, parsed.value);
        index = jinja.skipWs(args, parsed.next);
        if (index == args.len) break;
        if (args[index] != ',') return unsupported_error;
        index += 1;
    }
    return values;
}

fn parseString(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (value.len < 2 or (value[0] != '\'' and value[0] != '"')) return error.UnsupportedSnapshotConfig;
    const parsed = jinja.parseQuoted(allocator, value, 0) catch return error.UnsupportedSnapshotConfig;
    if (std.mem.trim(u8, value[parsed.next..], " \t\r\n").len != 0) return error.UnsupportedSnapshotConfig;
    return parsed.value;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "True")) return true;
    if (std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "False")) return false;
    return error.UnsupportedSnapshotConfig;
}

fn parseColumns(allocator: std.mem.Allocator, value: []const u8) !types.SnapshotColumns {
    if (value.len == 0) return error.UnsupportedSnapshotConfig;
    if (value[0] != '[') return .{ .string = try parseString(allocator, value) };
    if (value.len < 2 or value[value.len - 1] != ']') return error.UnsupportedSnapshotConfig;
    var items: std.ArrayList([]const u8) = .empty;
    errdefer items.deinit(allocator);
    var i: usize = 1;
    const end = value.len - 1;
    while (true) {
        i = jinja.skipWs(value, i);
        if (i == end) break;
        if (i > end or (value[i] != '\'' and value[i] != '"')) return error.UnsupportedSnapshotConfig;
        const parsed = jinja.parseQuoted(allocator, value, i) catch return error.UnsupportedSnapshotConfig;
        if (parsed.next > end) return error.UnsupportedSnapshotConfig;
        try items.append(allocator, parsed.value);
        i = jinja.skipWs(value, parsed.next);
        if (i == end) break;
        if (i > end or value[i] != ',') return error.UnsupportedSnapshotConfig;
        i += 1;
    }
    return .{ .list = items };
}

fn parseConfig(allocator: std.mem.Allocator, args: []const u8, node: *types.Node) !void {
    var seen_keys = std.StringHashMap(void).init(allocator);
    defer seen_keys.deinit();
    var index: usize = 0;
    while (true) {
        index = jinja.skipWs(args, index);
        if (index == args.len) break;
        const key_start = index;
        if (!jinja.isIdentStart(args[index])) return error.UnsupportedSnapshotConfig;
        while (index < args.len and jinja.isIdentChar(args[index])) index += 1;
        const key = args[key_start..index];
        if (seen_keys.contains(key)) return error.UnsupportedSnapshotConfig;
        try seen_keys.put(key, {});
        index = jinja.skipWs(args, index);
        if (index >= args.len or args[index] != '=') return error.UnsupportedSnapshotConfig;
        index = jinja.skipWs(args, index + 1);
        const value_start = index;
        var list_depth: usize = 0;
        while (index < args.len) : (index += 1) {
            if (args[index] == '\'' or args[index] == '"') {
                index = (jinja.skipQuotedSpan(args, index) orelse return error.UnsupportedSnapshotConfig) - 1;
            } else if (args[index] == '[') {
                list_depth += 1;
            } else if (args[index] == ']') {
                if (list_depth == 0) return error.UnsupportedSnapshotConfig;
                list_depth -= 1;
            } else if (args[index] == ',' and list_depth == 0) break;
        }
        if (list_depth != 0) return error.UnsupportedSnapshotConfig;
        const value = std.mem.trim(u8, args[value_start..index], " \t\r\n");
        const config = &node.snapshot_config.?;
        if (std.mem.eql(u8, key, "strategy")) {
            config.strategy = try parseString(allocator, value);
        } else if (std.mem.eql(u8, key, "unique_key")) {
            const replacement = try parseColumns(allocator, value);
            if (config.unique_key) |*columns| columns.deinit(allocator);
            config.unique_key = replacement;
        } else if (std.mem.eql(u8, key, "target_schema")) {
            config.target_schema = try parseString(allocator, value);
        } else if (std.mem.eql(u8, key, "target_database")) {
            config.target_database = try parseString(allocator, value);
        } else if (std.mem.eql(u8, key, "updated_at")) {
            config.updated_at = try parseString(allocator, value);
        } else if (std.mem.eql(u8, key, "check_cols")) {
            const replacement = try parseColumns(allocator, value);
            if (config.check_cols) |*columns| columns.deinit(allocator);
            config.check_cols = replacement;
        } else if (std.mem.eql(u8, key, "invalidate_hard_deletes")) {
            config.invalidate_hard_deletes = try parseBool(value);
        } else if (std.mem.eql(u8, key, "enabled")) {
            node.enabled = try parseBool(value);
            node.inline_enabled = true;
        } else if (std.mem.eql(u8, key, "tags")) {
            var tags = try parseColumns(allocator, value);
            defer tags.deinit(allocator);
            switch (tags) {
                .string => |tag| try util.appendUnique(allocator, &node.tags, tag),
                .list => |list| for (list.items) |tag| try util.appendUnique(allocator, &node.tags, tag),
            }
        } else if (std.mem.eql(u8, key, "schema")) {
            node.config_schema = try parseString(allocator, value);
        } else if (std.mem.eql(u8, key, "alias")) {
            node.config_alias = try parseString(allocator, value);
        } else if (std.mem.eql(u8, key, "materialized")) {
            if (!std.mem.eql(u8, try parseString(allocator, value), "snapshot")) return error.InvalidSnapshotConfig;
        } else {
            return error.UnsupportedSnapshotConfig;
        }
        if (index < args.len) index += 1;
    }
}

fn hasColumns(columns: types.SnapshotColumns) bool {
    return switch (columns) {
        .string => |value| value.len != 0,
        .list => |values| values.items.len != 0,
    };
}

fn validateConfig(node: *const types.Node) !void {
    if (!node.enabled) return;
    const config = node.snapshot_config.?;
    const strategy = config.strategy orelse return error.InvalidSnapshotConfig;
    if (!hasColumns(config.unique_key orelse return error.InvalidSnapshotConfig)) return error.InvalidSnapshotConfig;
    if (std.mem.eql(u8, strategy, "timestamp")) {
        if ((config.updated_at orelse return error.InvalidSnapshotConfig).len == 0) return error.InvalidSnapshotConfig;
        if (config.check_cols) |columns| if (hasColumns(columns)) return error.InvalidSnapshotConfig;
    } else if (std.mem.eql(u8, strategy, "check")) {
        const columns = config.check_cols orelse return error.InvalidSnapshotConfig;
        if (!hasColumns(columns)) return error.InvalidSnapshotConfig;
        switch (columns) {
            .string => |value| if (!std.mem.eql(u8, value, "all")) return error.InvalidSnapshotConfig,
            .list => {},
        }
    } else return error.UnsupportedSnapshotConfig;
}

pub fn rejectYamlDefinitions(text: []const u8) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = util.stripYamlComment(std.mem.trim(u8, line, " \t\r"));
        if (util.leadingSpaces(line) == 0) {
            if (util.splitKeyValue(trimmed)) |kv| {
                if (std.mem.eql(u8, kv.key, "snapshots") and !std.mem.eql(u8, std.mem.trim(u8, kv.value, " \t\r"), "[]")) return error.UnsupportedSnapshotYaml;
            }
        }
    }
}

pub fn rejectSelectedResources(graph: *const types.Graph, selected: anytype) !void {
    var visited = std.StringHashMap(void).init(graph.allocator);
    defer visited.deinit();
    for (selected) |item| {
        visited.clearRetainingCapacity();
        if (std.mem.eql(u8, item.resource_type, "snapshot") or try hasSnapshotDependency(graph, item.unique_id, &visited)) return error.UnsupportedSnapshotExecution;
    }
}

fn hasSnapshotDependency(graph: *const types.Graph, unique_id: []const u8, visited: *std.StringHashMap(void)) !bool {
    if (std.mem.startsWith(u8, unique_id, "snapshot.")) return true;
    if (visited.contains(unique_id)) return false;
    try visited.put(unique_id, {});
    for (graph.nodes.items) |node| {
        if (!node.enabled or !std.mem.eql(u8, node.unique_id, unique_id)) continue;
        for (node.depends_on.items) |dependency| if (try hasSnapshotDependency(graph, dependency, visited)) return true;
    }
    for (graph.singular_tests.items) |node| {
        if (!node.enabled or !std.mem.eql(u8, node.unique_id, unique_id)) continue;
        for (node.depends_on.items) |dependency| if (try hasSnapshotDependency(graph, dependency, visited)) return true;
    }
    for (graph.tests.items) |node| {
        if (!std.mem.eql(u8, node.unique_id, unique_id)) continue;
        for (node.depends_on.items) |dependency| if (try hasSnapshotDependency(graph, dependency, visited)) return true;
    }
    for (graph.unit_tests.items) |node| {
        if (!node.enabled or !std.mem.eql(u8, node.unique_id, unique_id)) continue;
        for (node.depends_on.items) |dependency| if (try hasSnapshotDependency(graph, dependency, visited)) return true;
    }
    return false;
}

test "SQL snapshot blocks preserve body identity and literal configuration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    const sql = "{# {% snapshot ignored %} #}\n{% snapshot history %}\n{{ config(strategy='check', unique_key=['id','region'], check_cols='all', tags=['nightly'], target_schema='archive') }}\nselect * from {{ ref('base') }}\n{% endsnapshot %}\n{% snapshot disabled %}{{ config(enabled=false) }}{% endsnapshot %}";
    try parseBlocks(allocator, sql, "snapshots", "snapshots/nested/many.sql", "demo", &graph);
    try std.testing.expectEqual(@as(usize, 2), graph.nodes.items.len);
    const history = graph.nodes.items[0];
    try std.testing.expectEqualStrings("snapshot.demo.history", history.unique_id);
    try std.testing.expectEqualStrings("nested/many.sql", history.path);
    try std.testing.expectEqualStrings("archive", history.snapshot_config.?.target_schema.?);
    try std.testing.expectEqual(@as(usize, 2), history.snapshot_config.?.unique_key.?.list.items.len);
    try std.testing.expectEqualStrings("base", history.refs.items[0].name);
    try std.testing.expect(std.mem.startsWith(u8, history.raw_code, "\n{{ config("));
    try std.testing.expectEqualStrings(sql, history.snapshot_file_code.?);
    try std.testing.expect(!graph.nodes.items[1].enabled);
}

test "snapshot parser fails closed for malformed unsupported and invalid blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var graph = types.Graph{ .allocator = allocator, .project_name = "demo" };
    defer graph.deinit();
    try std.testing.expectError(error.MalformedSnapshotBlock, parseBlocks(allocator, "{% snapshot x %}select 1", "snapshots", "snapshots/x.sql", "demo", &graph));
    try std.testing.expectError(error.MalformedSnapshotBlock, parseBlocks(allocator, "{% snapshot x %}{{ ref('x'}", "snapshots", "snapshots/x.sql", "demo", &graph));
    try std.testing.expectError(error.MalformedSnapshotBlock, parseBlocks(allocator, "{% endsnapshot %}", "snapshots", "snapshots/x.sql", "demo", &graph));
    try std.testing.expectError(error.MalformedSnapshotBlock, parseBlocks(allocator, "{% snapshot x %}{% snapshot y %}{% endsnapshot %}", "snapshots", "snapshots/x.sql", "demo", &graph));
    try std.testing.expectError(error.UnsupportedSnapshotDefinition, parseBlocks(allocator, "{% snapshot x %}{% if execute %}select 1{% endif %}{% endsnapshot %}", "snapshots", "snapshots/x.sql", "demo", &graph));
    try std.testing.expectError(error.InvalidSnapshotConfig, parseBlocks(allocator, "{% snapshot x %}select 1{% endsnapshot %}", "snapshots", "snapshots/x.sql", "demo", &graph));
    try std.testing.expectError(error.InvalidSnapshotConfig, parseBlocks(allocator, "{% snapshot x %}{{ config(strategy='timestamp', unique_key='id', updated_at='ts', check_cols='all') }}{% endsnapshot %}", "snapshots", "snapshots/x.sql", "demo", &graph));
    try std.testing.expectError(error.UnsupportedSnapshotConfig, parseBlocks(allocator, "{% snapshot x %}{{ config(strategy=var('strategy')) }}{% endsnapshot %}", "snapshots", "snapshots/x.sql", "demo", &graph));
    try std.testing.expectError(error.UnsupportedSnapshotConfig, parseBlocks(allocator, "{% snapshot x %}{{ config(enabled=false, unknown='value') }}{% endsnapshot %}", "snapshots", "snapshots/x.sql", "demo", &graph));
    try std.testing.expectError(error.UnsupportedSnapshotConfig, parseBlocks(allocator, "{% snapshot x %}{{ config(enabled=false, enabled=true) }}{% endsnapshot %}", "snapshots", "snapshots/x.sql", "demo", &graph));
    try std.testing.expectError(error.UnsupportedSnapshotConfig, parseBlocks(allocator, "{% snapshot x %}{{ config(enabled=false, unique_key=['id']) }}{{ config(unique_key=var('key')) }}{% endsnapshot %}", "snapshots", "snapshots/x.sql", "demo", &graph));
    try std.testing.expectError(error.UnsupportedSnapshotYaml, rejectYamlDefinitions("version: 2\nsnapshots:\n  - name: history\n"));
}
