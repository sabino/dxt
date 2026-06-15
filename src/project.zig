const std = @import("std");
const Io = std.Io;

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: Io,
};

pub const Options = struct {
    project_dir: []const u8 = ".",
    target_path: ?[]const u8 = null,
    select: ?[]const u8 = null,
    exclude: ?[]const u8 = null,
    resource_type: ?[]const u8 = null,
    output: Output = .text,
};

pub const Output = enum {
    text,
    json,
};

const ProjectConfig = struct {
    name: []const u8,
    model_paths: std.ArrayList([]const u8) = .empty,
    target_path: []const u8 = "target",
};

const SourceDef = struct {
    unique_id: []const u8,
    source_name: []const u8,
    table_name: []const u8,
    original_file_path: []const u8,
};

const RefDep = struct {
    package: ?[]const u8,
    name: []const u8,
};

const SourceDep = struct {
    source_name: []const u8,
    table_name: []const u8,
};

const Node = struct {
    unique_id: []const u8,
    name: []const u8,
    path: []const u8,
    original_file_path: []const u8,
    raw_code: []const u8,
    materialized: []const u8 = "view",
    tags: std.ArrayList([]const u8) = .empty,
    refs: std.ArrayList(RefDep) = .empty,
    source_refs: std.ArrayList(SourceDep) = .empty,
    depends_on: std.ArrayList([]const u8) = .empty,
};

const Graph = struct {
    allocator: std.mem.Allocator,
    project_name: []const u8,
    nodes: std.ArrayList(Node) = .empty,
    sources: std.ArrayList(SourceDef) = .empty,

    fn deinit(self: *Graph) void {
        for (self.nodes.items) |*node| {
            node.tags.deinit(self.allocator);
            node.refs.deinit(self.allocator);
            node.source_refs.deinit(self.allocator);
            node.depends_on.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.sources.deinit(self.allocator);
    }
};

pub fn parse(runtime: Runtime, options: Options, stdout: *Io.Writer) !void {
    var graph = try loadGraph(runtime, options.project_dir);
    defer graph.deinit();

    try resolveDependencies(&graph);

    const target_path = options.target_path orelse graphDefaultTarget(runtime, options.project_dir) catch "target";
    const target_dir = if (std.fs.path.isAbsolute(target_path))
        target_path
    else
        try pathJoin(runtime.allocator, &.{ options.project_dir, target_path });
    try std.Io.Dir.cwd().createDirPath(runtime.io, target_dir);
    const manifest_path = try pathJoin(runtime.allocator, &.{ target_dir, "manifest.json" });
    const manifest = try renderManifest(runtime.allocator, &graph);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = manifest_path, .data = manifest });
    try stdout.print("Parsed {d} model(s) and {d} source(s) into {s}\n", .{
        graph.nodes.items.len,
        graph.sources.items.len,
        normalizeForDisplay(manifest_path),
    });
}

pub fn list(runtime: Runtime, options: Options, stdout: *Io.Writer) !void {
    var graph = try loadGraph(runtime, options.project_dir);
    defer graph.deinit();

    try resolveDependencies(&graph);
    const selected = try selectResources(runtime.allocator, &graph, options);
    if (options.output == .json) {
        try writeSelectedJson(stdout, selected);
    } else {
        for (selected) |item| {
            try stdout.print("{s}\n", .{item.unique_id});
        }
    }
}

fn graphDefaultTarget(runtime: Runtime, project_dir: []const u8) ![]const u8 {
    var config = try loadProjectConfig(runtime, project_dir);
    defer config.model_paths.deinit(runtime.allocator);
    return config.target_path;
}

fn loadGraph(runtime: Runtime, project_dir: []const u8) !Graph {
    var config = try loadProjectConfig(runtime, project_dir);
    defer config.model_paths.deinit(runtime.allocator);

    var graph = Graph{ .allocator = runtime.allocator, .project_name = config.name };
    errdefer graph.deinit();

    for (config.model_paths.items) |model_path| {
        var sql_files: std.ArrayList([]const u8) = .empty;
        defer sql_files.deinit(runtime.allocator);
        var yaml_files: std.ArrayList([]const u8) = .empty;
        defer yaml_files.deinit(runtime.allocator);

        const root = try pathJoin(runtime.allocator, &.{ project_dir, model_path });
        discoverFiles(runtime, root, model_path, &sql_files, &yaml_files) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        sortStrings(sql_files.items);
        sortStrings(yaml_files.items);

        for (yaml_files.items) |yaml_path| {
            try parseSources(runtime, project_dir, yaml_path, config.name, &graph);
        }
        for (sql_files.items) |sql_path| {
            try parseModel(runtime, project_dir, model_path, sql_path, config.name, &graph);
        }
    }

    sortNodes(graph.nodes.items);
    sortSources(graph.sources.items);
    try rejectDuplicateModels(&graph);
    return graph;
}

fn loadProjectConfig(runtime: Runtime, project_dir: []const u8) !ProjectConfig {
    const path = try pathJoin(runtime.allocator, &.{ project_dir, "dbt_project.yml" });
    const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.MissingProjectFile,
        else => return err,
    };

    var config = ProjectConfig{ .name = "" };
    errdefer config.model_paths.deinit(runtime.allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var read_model_path_block = false;
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (read_model_path_block) {
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                try config.model_paths.append(runtime.allocator, try dupTrimmedScalar(runtime.allocator, trimmed[2..]));
                continue;
            }
            read_model_path_block = false;
        }

        if (splitKeyValue(trimmed)) |kv| {
            if (std.mem.eql(u8, kv.key, "name")) {
                config.name = try dupTrimmedScalar(runtime.allocator, kv.value);
            } else if (std.mem.eql(u8, kv.key, "target-path")) {
                config.target_path = try dupTrimmedScalar(runtime.allocator, kv.value);
            } else if (std.mem.eql(u8, kv.key, "model-paths")) {
                if (std.mem.trim(u8, kv.value, " \t").len == 0) {
                    read_model_path_block = true;
                } else {
                    try parseInlineStringList(runtime.allocator, kv.value, &config.model_paths);
                }
            }
        }
    }

    if (config.name.len == 0) return error.InvalidProjectName;
    if (config.model_paths.items.len == 0) {
        try config.model_paths.append(runtime.allocator, "models");
    }
    return config;
}

fn discoverFiles(runtime: Runtime, absolute_dir: []const u8, relative_dir: []const u8, sql_files: *std.ArrayList([]const u8), yaml_files: *std.ArrayList([]const u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(runtime.io, absolute_dir, .{ .iterate = true });
    defer dir.close(runtime.io);

    var iter = dir.iterate();
    while (try iter.next(runtime.io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, "target") or
            std.mem.eql(u8, entry.name, "dbt_packages") or
            std.mem.eql(u8, entry.name, ".zig-cache") or
            std.mem.eql(u8, entry.name, "zig-out"))
        {
            continue;
        }

        const child_abs = try pathJoin(runtime.allocator, &.{ absolute_dir, entry.name });
        const child_rel = try pathJoin(runtime.allocator, &.{ relative_dir, entry.name });
        switch (entry.kind) {
            .directory => try discoverFiles(runtime, child_abs, child_rel, sql_files, yaml_files),
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".sql")) {
                    try sql_files.append(runtime.allocator, child_rel);
                } else if (std.mem.endsWith(u8, entry.name, ".yml") or std.mem.endsWith(u8, entry.name, ".yaml")) {
                    try yaml_files.append(runtime.allocator, child_rel);
                }
            },
            else => {},
        }
    }
}

fn parseSources(runtime: Runtime, project_dir: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    const path = try pathJoin(runtime.allocator, &.{ project_dir, relative_path });
    const text = try std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(4 * 1024 * 1024));

    var in_sources = false;
    var in_tables = false;
    var sources_indent: usize = 0;
    var source_item_indent: ?usize = null;
    var table_item_indent: ?usize = null;
    var current_source: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);

        if (std.mem.eql(u8, trimmed, "sources:")) {
            in_sources = true;
            in_tables = false;
            sources_indent = indent;
            source_item_indent = null;
            table_item_indent = null;
            continue;
        }
        if (!in_sources) continue;
        if (indent <= sources_indent and !std.mem.eql(u8, trimmed, "sources:")) {
            in_sources = false;
            in_tables = false;
            current_source = null;
            continue;
        }

        if (std.mem.eql(u8, trimmed, "tables:")) {
            in_tables = true;
            table_item_indent = null;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "- name:")) {
            const name = try dupTrimmedScalar(runtime.allocator, trimmed["- name:".len..]);
            if (source_item_indent == null or indent == source_item_indent.?) {
                source_item_indent = indent;
                current_source = name;
                in_tables = false;
                table_item_indent = null;
            } else if (in_tables and (table_item_indent == null or indent == table_item_indent.?)) {
                table_item_indent = indent;
                const source_name = current_source orelse return error.UnsupportedYaml;
                const unique_id = try std.fmt.allocPrint(runtime.allocator, "source.{s}.{s}.{s}", .{ package_name, source_name, name });
                try graph.sources.append(runtime.allocator, .{
                    .unique_id = unique_id,
                    .source_name = source_name,
                    .table_name = name,
                    .original_file_path = relative_path,
                });
            }
        }
    }
}

fn parseModel(runtime: Runtime, project_dir: []const u8, model_root: []const u8, relative_path: []const u8, package_name: []const u8, graph: *Graph) !void {
    const full_path = try pathJoin(runtime.allocator, &.{ project_dir, relative_path });
    const sql = try std.Io.Dir.cwd().readFileAlloc(runtime.io, full_path, runtime.allocator, .limited(16 * 1024 * 1024));
    const model_name = try modelNameFromPath(runtime.allocator, relative_path);
    const unique_id = try std.fmt.allocPrint(runtime.allocator, "model.{s}.{s}", .{ package_name, model_name });
    const model_path = relativeUnderModelPath(relative_path, model_root);

    var node = Node{
        .unique_id = unique_id,
        .name = model_name,
        .path = model_path,
        .original_file_path = relative_path,
        .raw_code = sql,
    };
    errdefer {
        node.tags.deinit(runtime.allocator);
        node.refs.deinit(runtime.allocator);
        node.source_refs.deinit(runtime.allocator);
        node.depends_on.deinit(runtime.allocator);
    }
    try scanSql(runtime.allocator, sql, &node);
    try graph.nodes.append(runtime.allocator, node);
}

fn rejectDuplicateModels(graph: *const Graph) !void {
    var i: usize = 0;
    while (i < graph.nodes.items.len) : (i += 1) {
        var j = i + 1;
        while (j < graph.nodes.items.len) : (j += 1) {
            if (std.mem.eql(u8, graph.nodes.items[i].unique_id, graph.nodes.items[j].unique_id)) {
                return error.DuplicateModelName;
            }
        }
    }
}

fn resolveDependencies(graph: *Graph) !void {
    for (graph.nodes.items) |*node| {
        for (node.refs.items) |ref_dep| {
            const package = ref_dep.package orelse graph.project_name;
            const unique_id = try std.fmt.allocPrint(graph.allocator, "model.{s}.{s}", .{ package, ref_dep.name });
            if (!hasNode(graph, unique_id)) return error.UnresolvedRef;
            try appendUnique(graph.allocator, &node.depends_on, unique_id);
        }
        for (node.source_refs.items) |source_dep| {
            const unique_id = try std.fmt.allocPrint(graph.allocator, "source.{s}.{s}.{s}", .{ graph.project_name, source_dep.source_name, source_dep.table_name });
            if (!hasSource(graph, unique_id)) return error.UnresolvedSource;
            try appendUnique(graph.allocator, &node.depends_on, unique_id);
        }
        sortStrings(node.depends_on.items);
    }
}

fn scanSql(allocator: std.mem.Allocator, sql: []const u8, node: *Node) !void {
    var index: usize = 0;
    while (index + 1 < sql.len) {
        if (sql[index] != '{') {
            index += 1;
            continue;
        }
        if (sql[index + 1] == '#') {
            const end = std.mem.indexOfPos(u8, sql, index + 2, "#}") orelse return error.UnsupportedJinja;
            index = end + 2;
            continue;
        }
        const close = if (sql[index + 1] == '{')
            std.mem.indexOfPos(u8, sql, index + 2, "}}")
        else if (sql[index + 1] == '%')
            std.mem.indexOfPos(u8, sql, index + 2, "%}")
        else
            null;
        if (close) |end| {
            try scanJinjaSpan(allocator, sql[index + 2 .. end], node);
            index = end + 2;
            continue;
        }
        index += 1;
    }
}

fn scanJinjaSpan(allocator: std.mem.Allocator, span: []const u8, node: *Node) !void {
    var i: usize = 0;
    while (i < span.len) {
        if (span[i] == '"' or span[i] == '\'') {
            i = skipQuotedSpan(span, i) orelse return error.UnsupportedJinja;
            continue;
        }
        if (!isIdentStart(span[i])) {
            i += 1;
            continue;
        }
        const start = i;
        i += 1;
        while (i < span.len and isIdentChar(span[i])) i += 1;
        const ident = span[start..i];
        const call_pos = skipWs(span, i);
        if (call_pos >= span.len or span[call_pos] != '(') continue;
        const close = findMatchingParen(span, call_pos) orelse return error.UnsupportedJinja;
        const args = span[call_pos + 1 .. close];

        if (std.mem.eql(u8, ident, "ref")) {
            var strings = try parseLiteralArgs(allocator, args, error.UnsupportedDynamicRef);
            defer strings.deinit(allocator);
            if (!(strings.items.len == 1 or strings.items.len == 2)) return error.UnsupportedDynamicRef;
            try node.refs.append(allocator, .{
                .package = if (strings.items.len == 2) strings.items[0] else null,
                .name = if (strings.items.len == 2) strings.items[1] else strings.items[0],
            });
        } else if (std.mem.eql(u8, ident, "source")) {
            var strings = try parseLiteralArgs(allocator, args, error.UnsupportedDynamicSource);
            defer strings.deinit(allocator);
            if (strings.items.len != 2) return error.UnsupportedDynamicSource;
            try node.source_refs.append(allocator, .{
                .source_name = strings.items[0],
                .table_name = strings.items[1],
            });
        } else if (std.mem.eql(u8, ident, "config")) {
            try parseConfig(allocator, args, node);
        } else {
            return error.UnsupportedJinja;
        }
        i = close + 1;
    }
}

fn parseLiteralArgs(allocator: std.mem.Allocator, args: []const u8, unsupported_error: anyerror) !std.ArrayList([]const u8) {
    var strings: std.ArrayList([]const u8) = .empty;
    errdefer strings.deinit(allocator);

    var i: usize = 0;
    var saw_literal = false;
    while (i < args.len) {
        i = skipWs(args, i);
        if (i >= args.len) break;
        if (args[i] == ',') {
            i += 1;
            continue;
        }
        if (args[i] != '"' and args[i] != '\'') return unsupported_error;
        const parsed = try parseQuoted(allocator, args, i);
        try strings.append(allocator, parsed.value);
        saw_literal = true;
        i = skipWs(args, parsed.next);
        if (i < args.len and args[i] != ',') return unsupported_error;
    }
    if (!saw_literal) return unsupported_error;
    return strings;
}

fn parseConfig(allocator: std.mem.Allocator, args: []const u8, node: *Node) !void {
    if (findKeyword(args, "materialized")) |pos| {
        if (findValueStart(args, pos + "materialized".len)) |value_pos| {
            if (args[value_pos] != '"' and args[value_pos] != '\'') return error.UnsupportedJinja;
            const parsed = try parseQuoted(allocator, args, value_pos);
            node.materialized = parsed.value;
        }
    }
    if (findKeyword(args, "tags")) |pos| {
        if (findValueStart(args, pos + "tags".len)) |value_pos| {
            try parseTagList(allocator, args[value_pos..], &node.tags);
            sortStrings(node.tags.items);
        }
    }
}

fn parseTagList(allocator: std.mem.Allocator, text: []const u8, tags: *std.ArrayList([]const u8)) !void {
    var i = skipWs(text, 0);
    if (i >= text.len) return;
    if (text[i] == '"' or text[i] == '\'') {
        const parsed = try parseQuoted(allocator, text, i);
        try appendUnique(allocator, tags, parsed.value);
        return;
    }
    if (text[i] != '[') return error.UnsupportedJinja;
    i += 1;
    while (i < text.len) {
        i = skipWs(text, i);
        if (i >= text.len or text[i] == ']') break;
        if (text[i] == ',') {
            i += 1;
            continue;
        }
        if (text[i] != '"' and text[i] != '\'') return error.UnsupportedJinja;
        const parsed = try parseQuoted(allocator, text, i);
        try appendUnique(allocator, tags, parsed.value);
        i = parsed.next;
    }
}

const ParsedString = struct {
    value: []const u8,
    next: usize,
};

fn parseQuoted(allocator: std.mem.Allocator, text: []const u8, start: usize) !ParsedString {
    const quote = text[start];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == quote) {
            return .{ .value = try out.toOwnedSlice(allocator), .next = i + 1 };
        }
        if (ch == '\\' and i + 1 < text.len) {
            i += 1;
            try out.append(allocator, text[i]);
        } else {
            try out.append(allocator, ch);
        }
    }
    return error.UnsupportedJinja;
}

fn skipQuotedSpan(text: []const u8, start: usize) ?usize {
    const quote = text[start];
    var i = start + 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len) {
            i += 1;
            continue;
        }
        if (text[i] == quote) return i + 1;
    }
    return null;
}

const SelectedResource = struct {
    unique_id: []const u8,
    name: []const u8,
    resource_type: []const u8,
};

fn selectResources(allocator: std.mem.Allocator, graph: *const Graph, options: Options) ![]SelectedResource {
    var selected: std.ArrayList(SelectedResource) = .empty;
    errdefer selected.deinit(allocator);
    for (graph.nodes.items) |node| {
        if (matchesResourceType(options.resource_type, "model") and matchesSelector(graph, node, options.select) and (options.exclude == null or !matchesSelector(graph, node, options.exclude))) {
            try selected.append(allocator, .{ .unique_id = node.unique_id, .name = node.name, .resource_type = "model" });
        }
    }
    for (graph.sources.items) |source| {
        if (matchesResourceType(options.resource_type, "source") and matchesSourceSelector(source, options.select) and (options.exclude == null or !matchesSourceSelector(source, options.exclude))) {
            try selected.append(allocator, .{ .unique_id = source.unique_id, .name = source.table_name, .resource_type = "source" });
        }
    }
    std.mem.sort(SelectedResource, selected.items, {}, struct {
        fn lessThan(_: void, a: SelectedResource, b: SelectedResource) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
        }
    }.lessThan);
    return try selected.toOwnedSlice(allocator);
}

fn matchesResourceType(requested: ?[]const u8, actual: []const u8) bool {
    if (requested) |value| return std.mem.eql(u8, value, actual);
    return true;
}

fn matchesSelector(graph: *const Graph, node: Node, selector: ?[]const u8) bool {
    const raw = selector orelse return true;
    const value = trimPlus(raw);
    if (value.len == 0) return true;
    if (std.mem.eql(u8, value, node.name) or std.mem.eql(u8, value, node.unique_id)) return true;
    if (std.mem.startsWith(u8, value, "tag:")) {
        const tag = value["tag:".len..];
        for (node.tags.items) |node_tag| {
            if (std.mem.eql(u8, tag, node_tag)) return true;
        }
    }
    if (std.mem.startsWith(u8, value, "path:")) {
        const path = value["path:".len..];
        return std.mem.indexOf(u8, node.original_file_path, path) != null;
    }
    if (std.mem.startsWith(u8, value, "source:")) {
        _ = graph;
        return false;
    }
    _ = graph;
    return false;
}

fn matchesSourceSelector(source: SourceDef, selector: ?[]const u8) bool {
    const raw = selector orelse return true;
    const value = trimPlus(raw);
    if (value.len == 0) return true;
    if (std.mem.eql(u8, value, source.unique_id) or std.mem.eql(u8, value, source.table_name)) return true;
    if (std.mem.startsWith(u8, value, "source:")) {
        const source_value = value["source:".len..];
        return std.mem.eql(u8, source_value, source.source_name) or std.mem.eql(u8, source_value, source.unique_id);
    }
    return false;
}

fn writeSelectedJson(writer: *Io.Writer, selected: []SelectedResource) !void {
    try writer.writeAll("[");
    for (selected, 0..) |item, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("{\"unique_id\":");
        try writeJsonString(writer, item.unique_id);
        try writer.writeAll(",\"resource_type\":");
        try writeJsonString(writer, item.resource_type);
        try writer.writeAll(",\"name\":");
        try writeJsonString(writer, item.name);
        try writer.writeAll("}");
    }
    try writer.writeAll("]\n");
}

fn renderManifest(allocator: std.mem.Allocator, graph: *const Graph) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\n  \"metadata\": {\"dbt_schema_version\": null, \"dbt_version\": null, \"project_name\": ");
    try writeJsonString(writer, graph.project_name);
    try writer.writeAll(", \"generated_by\": \"dxt\"},\n  \"dxt_metadata\": {\"artifact_kind\": \"partial_manifest\", \"compatibility_target\": \"dbt-manifest-v12-slice\", \"supported_surface\": [\"model\", \"source\", \"literal_ref\", \"literal_source\", \"inline_config\"]},\n  \"nodes\": {");
    for (graph.nodes.items, 0..) |node, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try writeJsonString(writer, node.unique_id);
        try writer.writeAll(": {\"unique_id\":");
        try writeJsonString(writer, node.unique_id);
        try writer.writeAll(",\"resource_type\":\"model\",\"package_name\":");
        try writeJsonString(writer, graph.project_name);
        try writer.writeAll(",\"name\":");
        try writeJsonString(writer, node.name);
        try writer.writeAll(",\"path\":");
        try writeJsonString(writer, normalizeForDisplay(node.path));
        try writer.writeAll(",\"original_file_path\":");
        try writeJsonString(writer, normalizeForDisplay(node.original_file_path));
        try writer.writeAll(",\"language\":\"sql\",\"raw_code\":");
        try writeJsonString(writer, node.raw_code);
        try writer.writeAll(",\"config\":{\"materialized\":");
        try writeJsonString(writer, node.materialized);
        try writer.writeAll(",\"tags\":");
        try writeStringArray(writer, node.tags.items);
        try writer.writeAll("},\"depends_on\":{\"macros\":[],\"nodes\":");
        try writeStringArray(writer, node.depends_on.items);
        try writer.writeAll("}}");
    }
    try writer.writeAll("\n  },\n  \"sources\": {");
    for (graph.sources.items, 0..) |source, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try writeJsonString(writer, source.unique_id);
        try writer.writeAll(": {\"unique_id\":");
        try writeJsonString(writer, source.unique_id);
        try writer.writeAll(",\"resource_type\":\"source\",\"package_name\":");
        try writeJsonString(writer, graph.project_name);
        try writer.writeAll(",\"source_name\":");
        try writeJsonString(writer, source.source_name);
        try writer.writeAll(",\"name\":");
        try writeJsonString(writer, source.table_name);
        try writer.writeAll(",\"original_file_path\":");
        try writeJsonString(writer, normalizeForDisplay(source.original_file_path));
        try writer.writeAll("}");
    }
    try writer.writeAll("\n  },\n  \"macros\": {},\n  \"docs\": {},\n  \"exposures\": {},\n  \"metrics\": {},\n  \"groups\": {},\n  \"selectors\": {},\n  \"disabled\": {},\n  \"parent_map\": {");
    for (graph.nodes.items, 0..) |node, index| {
        if (index != 0) try writer.writeAll(",");
        try writer.writeAll("\n    ");
        try writeJsonString(writer, node.unique_id);
        try writer.writeAll(": ");
        try writeStringArray(writer, node.depends_on.items);
    }
    try writer.writeAll("\n  },\n  \"child_map\": {");
    try writeChildMap(writer, graph);
    try writer.writeAll("\n  }\n}\n");
    return try out.toOwnedSlice();
}

fn writeChildMap(writer: *Io.Writer, graph: *const Graph) !void {
    var first = true;
    for (graph.nodes.items) |candidate| {
        try writeChildMapEntry(writer, graph, candidate.unique_id, &first);
    }
    for (graph.sources.items) |candidate| {
        try writeChildMapEntry(writer, graph, candidate.unique_id, &first);
    }
}

fn writeChildMapEntry(writer: *Io.Writer, graph: *const Graph, unique_id: []const u8, first: *bool) !void {
    if (!first.*) try writer.writeAll(",");
    first.* = false;
    try writer.writeAll("\n    ");
    try writeJsonString(writer, unique_id);
    try writer.writeAll(": [");
    var child_first = true;
    for (graph.nodes.items) |node| {
        if (containsString(node.depends_on.items, unique_id)) {
            if (!child_first) try writer.writeAll(",");
            child_first = false;
            try writeJsonString(writer, node.unique_id);
        }
    }
    try writer.writeAll("]");
}

fn writeStringArray(writer: *Io.Writer, values: []const []const u8) !void {
    try writer.writeAll("[");
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(",");
        try writeJsonString(writer, value);
    }
    try writer.writeAll("]");
}

fn writeJsonString(writer: *Io.Writer, value: []const u8) !void {
    try std.json.Stringify.value(value, .{}, writer);
}

fn stripYamlComment(line: []const u8) []const u8 {
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (quote) |q| {
            if (ch == q) quote = null;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (ch == '#') return line[0..i];
    }
    return line;
}

fn leadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') count += 1;
    return count;
}

const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

fn splitKeyValue(line: []const u8) ?KeyValue {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    return .{
        .key = std.mem.trim(u8, line[0..colon], " \t"),
        .value = std.mem.trim(u8, line[colon + 1 ..], " \t"),
    };
}

fn parseInlineStringList(allocator: std.mem.Allocator, value: []const u8, out: *std.ArrayList([]const u8)) !void {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') {
        try out.append(allocator, try dupTrimmedScalar(allocator, trimmed));
        return;
    }
    var pieces = std.mem.splitScalar(u8, trimmed[1 .. trimmed.len - 1], ',');
    while (pieces.next()) |piece| {
        const item = std.mem.trim(u8, piece, " \t");
        if (item.len != 0) try out.append(allocator, try dupTrimmedScalar(allocator, item));
    }
}

fn dupTrimmedScalar(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (trimmed.len >= 2 and ((trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') or (trimmed[0] == '\'' and trimmed[trimmed.len - 1] == '\''))) {
        return try allocator.dupe(u8, trimmed[1 .. trimmed.len - 1]);
    }
    return try allocator.dupe(u8, trimmed);
}

fn modelNameFromPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, ".sql")) {
        return try allocator.dupe(u8, base[0 .. base.len - ".sql".len]);
    }
    return try allocator.dupe(u8, base);
}

fn relativeUnderModelPath(relative_path: []const u8, model_root: []const u8) []const u8 {
    if (std.mem.startsWith(u8, relative_path, model_root) and relative_path.len > model_root.len and relative_path[model_root.len] == '/') {
        return relative_path[model_root.len + 1 ..];
    }
    return relative_path;
}

fn pathJoin(allocator: std.mem.Allocator, parts: []const []const u8) ![]const u8 {
    return try std.fs.path.join(allocator, parts);
}

fn normalizeForDisplay(path: []const u8) []const u8 {
    return path;
}

fn sortStrings(values: [][]const u8) void {
    std.mem.sort([]const u8, values, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
}

fn sortNodes(nodes: []Node) void {
    std.mem.sort(Node, nodes, {}, struct {
        fn lessThan(_: void, a: Node, b: Node) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
        }
    }.lessThan);
}

fn sortSources(sources: []SourceDef) void {
    std.mem.sort(SourceDef, sources, {}, struct {
        fn lessThan(_: void, a: SourceDef, b: SourceDef) bool {
            return std.mem.lessThan(u8, a.unique_id, b.unique_id);
        }
    }.lessThan);
}

fn skipWs(text: []const u8, start: usize) usize {
    var i = start;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\r' or text[i] == '\n')) i += 1;
    return i;
}

fn findMatchingParen(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var quote: ?u8 = null;
    var i = open;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (quote) |q| {
            if (ch == '\\' and i + 1 < text.len) {
                i += 1;
                continue;
            }
            if (ch == q) quote = null;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
        } else if (ch == '(') {
            depth += 1;
        } else if (ch == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn isIdentStart(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
}

fn isIdentChar(ch: u8) bool {
    return isIdentStart(ch) or (ch >= '0' and ch <= '9');
}

fn findKeyword(text: []const u8, keyword: []const u8) ?usize {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, keyword)) |pos| {
        const before_ok = pos == 0 or !isIdentChar(text[pos - 1]);
        const after = pos + keyword.len;
        const after_ok = after >= text.len or !isIdentChar(text[after]);
        if (before_ok and after_ok) return pos;
        i = after;
    }
    return null;
}

fn findValueStart(text: []const u8, start: usize) ?usize {
    var i = skipWs(text, start);
    if (i >= text.len or text[i] != '=') return null;
    i = skipWs(text, i + 1);
    if (i >= text.len) return null;
    return i;
}

fn hasNode(graph: *const Graph, unique_id: []const u8) bool {
    for (graph.nodes.items) |node| {
        if (std.mem.eql(u8, node.unique_id, unique_id)) return true;
    }
    return false;
}

fn hasSource(graph: *const Graph, unique_id: []const u8) bool {
    for (graph.sources.items) |source| {
        if (std.mem.eql(u8, source.unique_id, unique_id)) return true;
    }
    return false;
}

fn appendUnique(allocator: std.mem.Allocator, values: *std.ArrayList([]const u8), value: []const u8) !void {
    if (!containsString(values.items, value)) {
        try values.append(allocator, value);
    }
}

fn containsString(values: []const []const u8, value: []const u8) bool {
    for (values) |candidate| {
        if (std.mem.eql(u8, candidate, value)) return true;
    }
    return false;
}

fn trimPlus(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, "+");
}

test "project yaml parser reads dbt name and inline model paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "name: demo\nmodel-paths: [\"models\", marts]\ntarget-path: target-dxt\n";
    var parsed_paths: std.ArrayList([]const u8) = .empty;
    defer parsed_paths.deinit(allocator);
    var lines = std.mem.splitScalar(u8, input, '\n');
    var project_name: []const u8 = "";
    while (lines.next()) |line| {
        if (splitKeyValue(stripYamlComment(line))) |kv| {
            if (std.mem.eql(u8, kv.key, "name")) project_name = try dupTrimmedScalar(allocator, kv.value);
            if (std.mem.eql(u8, kv.key, "model-paths")) try parseInlineStringList(allocator, kv.value, &parsed_paths);
        }
    }

    try std.testing.expectEqualStrings("demo", project_name);
    try std.testing.expectEqual(@as(usize, 2), parsed_paths.items.len);
    try std.testing.expectEqualStrings("models", parsed_paths.items[0]);
    try std.testing.expectEqualStrings("marts", parsed_paths.items[1]);
}

test "sql scanner extracts refs sources and config tags from jinja spans" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var node = Node{
        .unique_id = "model.demo.customers",
        .name = "customers",
        .path = "customers.sql",
        .original_file_path = "models/customers.sql",
        .raw_code = "",
    };
    defer {
        node.tags.deinit(allocator);
        node.refs.deinit(allocator);
        node.source_refs.deinit(allocator);
        node.depends_on.deinit(allocator);
    }

    try scanSql(allocator,
        \\{{ config(materialized="table", tags=["nightly", 'core']) }}
        \\select * from {{ ref("stg_customers") }}
        \\union all select * from {{ source('raw', "customers") }}
        \\select {{ "ref('not_a_dependency')" }} as literal_ref
        \\{# {{ ref("ignored") }} #}
    , &node);

    try std.testing.expectEqual(@as(usize, 1), node.refs.items.len);
    try std.testing.expectEqualStrings("stg_customers", node.refs.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), node.source_refs.items.len);
    try std.testing.expectEqualStrings("raw", node.source_refs.items[0].source_name);
    try std.testing.expectEqualStrings("customers", node.source_refs.items[0].table_name);
    try std.testing.expectEqualStrings("table", node.materialized);
    try std.testing.expectEqual(@as(usize, 2), node.tags.items.len);
}
