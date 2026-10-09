//! Native whole-graph parse reuse with content-safe invalidation. A changed
//! source conservatively reparses the graph, including all macro consumers.
const std = @import("std");
const types = @import("types.zig");
const fs = @import("fs.zig");
const config = @import("config.zig");
const values = @import("config_value.zig");
const codec = @import("parse_cache_codec.zig");
const Value = std.json.Value;
const schema = "dxt-native-parse-v1";

pub const State = struct {
    path: []const u8,
    write_path: ?[]const u8 = null,
    fingerprint: []const u8,
    context_fingerprint: []const u8 = "",
    files: Value,
    enabled: bool, // Whether to read/reuse; Core still saves a fresh full parse.
};

pub fn prepare(runtime: types.Runtime, options: types.Options, graph: *const types.Graph, project: *const types.ProjectConfig) !State {
    const a = runtime.allocator;
    const target = options.target_path orelse project.target_path;
    const target_dir = if (std.fs.path.isAbsolute(target)) target else try fs.pathJoin(a, &.{ options.project_dir, target });
    const write_path = try fs.pathJoin(a, &.{ target_dir, "dxt_parse_cache.json" });
    const path = options.partial_parse_file_path orelse write_path;
    var files: std.ArrayList([]const u8) = .empty;
    try projectFiles(runtime, options.project_dir, project, &files);
    var cli_vars: Value = .{ .object = .empty };
    for (graph.vars.items) |entry| if (entry.priority >= 100 and entry.package_name == null) {
        try values.put(a, &cli_vars, entry.name, entry.typed_value orelse .{ .string = entry.value });
    };
    defer values.deinit(a, &cli_vars);
    const packages = try @import("dependencies.zig").installPathWithVars(runtime, options.project_dir, cli_vars);
    var directories: std.ArrayList([]const u8) = .empty;
    fs.discoverChildDirectories(runtime, packages, &directories) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    @import("util.zig").sortStrings(directories.items);
    for (directories.items) |directory| {
        var child = config.loadProjectConfigWithContext(runtime, directory, graph.vars.items, graph.target_context) catch |err| switch (err) {
            error.MissingProjectFile => continue,
            else => return err,
        };
        defer types.deinitProjectConfig(a, &child);
        try projectFiles(runtime, directory, &child, &files);
    }
    @import("util.zig").sortStrings(files.items);
    var digest: std.crypto.hash.sha2.Sha256 = .init(.{});
    // Compiler/schema changes invalidate development caches as well as releases.
    inline for (.{ schema, @embedFile("types.zig"), @embedFile("loader.zig"), @embedFile("compiler.zig"), @embedFile("expression.zig"), @embedFile("parse.zig"), @embedFile("jinja.zig"), @embedFile("config.zig"), @embedFile("properties.zig"), @embedFile("generic_test_config.zig"), @embedFile("doc_context.zig"), @embedFile("doc_blocks.zig"), @embedFile("macro_properties.zig"), @embedFile("canonical_manifest_config.zig"), @embedFile("resource_config.zig"), @embedFile("group_access.zig"), @embedFile("snapshot_yaml.zig"), @embedFile("model_versions.zig"), @embedFile("unit_yaml.zig"), @embedFile("unit_metadata.zig"), @embedFile("semantic.zig"), @embedFile("bundled_macros.zig"), @embedFile("../project.zig"), @embedFile("parse_cache.zig"), @embedFile("python_model.zig"), @embedFile("parse_cache_codec.zig"), @embedFile("yaml.zig"), @embedFile("profile.zig"), @embedFile("config_render.zig"), @embedFile("config_value.zig"), @embedFile("project_config.zig"), @embedFile("project_flags.zig"), @embedFile("source_properties.zig"), @embedFile("snapshot.zig"), @embedFile("unit_config.zig"), @embedFile("unit_versions.zig") }) |source| hashPart(&digest, source);
    inline for (.{ @embedFile("base_context.zig"), @embedFile("set_context.zig") }) |source| hashPart(&digest, source);
    hashPart(&digest, @embedFile("json_context_load.zig"));
    inline for (.{ @embedFile("yaml_context.zig"), @embedFile("yaml_dump.zig"), @embedFile("yaml_values.zig"), @embedFile("timestamp_context.zig") }) |source| hashPart(&digest, source);
    for (@import("dbt_includes").files) |file| {
        hashPart(&digest, file.path);
        hashPart(&digest, file.text);
    }
    hashPart(&digest, options.project_dir);
    hashPart(&digest, @embedFile("naming.zig"));
    hashPart(&digest, @embedFile("context_values.zig"));
    hashPart(&digest, try std.Io.Dir.cwd().realPathFileAlloc(runtime.io, options.project_dir, a));
    hashPart(&digest, try std.json.Stringify.valueAlloc(a, project.rendered_project, .{}));
    hashPart(&digest, try std.json.Stringify.valueAlloc(a, graph.target_context, .{}));
    hashPart(&digest, try std.json.Stringify.valueAlloc(a, graph.duckdb_credentials, .{}));
    hashPart(&digest, graph.connection_info orelse "");
    hashPart(&digest, graph.adapter_type);
    hashPart(&digest, try std.json.Stringify.valueAlloc(a, graph.vars.items, .{}));
    // Parse-time flags are observable inside macros. Selection/logging changes
    // do not require a rebuild unless an authored macro observes those flags.
    var parsing_options = options;
    // This hidden flag chooses a reader, and is absent from Core's macro flag
    // context. Copying a saved cache to another path preserves its identity.
    parsing_options.partial_parse_file_path = null;
    parsing_options.partial_parse_file_diff = true;
    hashPart(&digest, try std.json.Stringify.valueAlloc(a, parsing_options, .{}));
    if (runtime.environment) |environment| {
        var names: std.ArrayList([]const u8) = .empty;
        var iterator = environment.iterator();
        while (iterator.next()) |entry| try names.append(a, entry.key_ptr.*);
        @import("util.zig").sortStrings(names.items);
        for (names.items) |name| {
            hashPart(&digest, name);
            hashPart(&digest, environment.get(name).?);
        }
    }
    var inputs = std.json.Array.init(a);
    var context_hash = digest;
    const context_digest = std.fmt.bytesToHex(context_hash.finalResult(), .lower);
    var previous: ?[]const u8 = null;
    for (files.items) |file| {
        if (previous != null and std.mem.eql(u8, previous.?, file)) continue;
        previous = file;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(runtime.io, file, a, .limited(256 * 1024 * 1024));
        defer a.free(bytes);
        var content: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &content, .{});
        const checksum = std.fmt.bytesToHex(content, .lower);
        hashPart(&digest, file);
        hashPart(&digest, &checksum);
        var input: Value = .{ .object = .empty };
        try values.put(a, &input, "path", .{ .string = file });
        try values.put(a, &input, "checksum", .{ .string = &checksum });
        try inputs.append(input);
    }
    const fingerprint = std.fmt.bytesToHex(digest.finalResult(), .lower);
    return .{ .path = path, .write_path = write_path, .fingerprint = try a.dupe(u8, &fingerprint), .context_fingerprint = try a.dupe(u8, &context_digest), .files = .{ .array = inputs }, .enabled = options.partial_parse };
}

fn hashPart(digest: *std.crypto.hash.sha2.Sha256, bytes: []const u8) void {
    var size: [8]u8 = undefined;
    std.mem.writeInt(u64, &size, bytes.len, .little);
    digest.update(&size);
    digest.update(bytes);
}

fn projectFiles(runtime: types.Runtime, root: []const u8, project: *const types.ProjectConfig, files: *std.ArrayList([]const u8)) !void {
    const a = runtime.allocator;
    for ([_][]const u8{ "dbt_project.yml", "packages.yml", "dependencies.yml", "package-lock.yml" }) |name| {
        const path = try fs.pathJoin(a, &.{ root, name });
        const file = std.Io.Dir.cwd().openFile(runtime.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        file.close(runtime.io);
        try files.append(a, path);
    }
    for ([_][]const []const u8{ project.model_paths.items, project.seed_paths.items, project.macro_paths.items, project.test_paths.items, project.analysis_paths.items, project.snapshot_paths.items, project.docs_paths.items, project.function_paths.items }) |paths| for (paths) |path| {
        const directory = try fs.pathJoin(a, &.{ root, path });
        var sql: std.ArrayList([]const u8) = .empty;
        var yaml: std.ArrayList([]const u8) = .empty;
        var markdown: std.ArrayList([]const u8) = .empty;
        var csv: std.ArrayList([]const u8) = .empty;
        fs.discoverProjectFiles(runtime, directory, path, &sql, &yaml, &markdown) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        try fs.discoverSeedFiles(runtime, directory, path, &csv);
        for ([_][]const []const u8{ sql.items, yaml.items, markdown.items, csv.items }) |items| for (items) |item| try files.append(a, try fs.pathJoin(a, &.{ root, item }));
    };
    for (project.model_paths.items) |path| {
        const directory = try fs.pathJoin(a, &.{ root, path });
        var python: std.ArrayList([]const u8) = .empty;
        defer python.deinit(a);
        fs.discoverPythonFiles(runtime, directory, path, &python) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        for (python.items) |item| try files.append(a, try fs.pathJoin(a, &.{ root, item }));
    }
}

pub fn restore(runtime: types.Runtime, state: State, graph: *types.Graph) bool {
    if (!state.enabled) {
        graph.parser_cache_reason = "disabled";
        return false;
    }
    const a = runtime.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(runtime.io, state.path, a, .limited(256 * 1024 * 1024)) catch {
        graph.parser_cache_reason = "missing";
        return false;
    };
    defer a.free(bytes);
    const parsed = std.json.parseFromSlice(Value, a, bytes, .{ .allocate = .alloc_always }) catch {
        graph.parser_cache_reason = "invalid";
        return false;
    };
    defer parsed.deinit();
    const stored = parsed.value;
    if (stored != .object or !textEqual(stored.object.get("schema"), schema)) {
        graph.parser_cache_reason = "incompatible";
        return false;
    }
    const supplied_empty_diff = !graph.command_options.partial_parse_file_diff and
        textEqual(stored.object.get("context_fingerprint"), state.context_fingerprint);
    if (!supplied_empty_diff and !textEqual(stored.object.get("fingerprint"), state.fingerprint)) {
        graph.parser_cache_reason = "changed";
        if (graph.command_options.partial_parse_file_diff) graph.parser_cache_changes = changedFiles(stored.object.get("files") orelse .null, state.files);
        if (graph.command_options.partial_parse_file_diff and textEqual(stored.object.get("context_fingerprint"), state.context_fingerprint)) {
            if (stored.object.get("graph")) |old_graph| if (old_graph == .object) {
                if (old_graph.object.get("parser_file_cache")) |raw_nodes| graph.parser_file_cache = values.clone(a, raw_nodes) catch .null;
            };
        }
        return false;
    }
    // Decode into an independent graph; malformed caches cannot partly replace
    // the live graph before the ordinary parser falls back.
    var decoded = graph.*;
    codec.decodeGraph(a, &decoded, stored.object.get("graph") orelse .null) catch {
        graph.parser_cache_reason = "invalid";
        return false;
    };
    graph.* = decoded;
    graph.parser_cache_hit = true;
    graph.parser_cache_reason = "unchanged";
    return true;
}

fn textEqual(value: ?Value, text: []const u8) bool {
    return value != null and value.? == .string and std.mem.eql(u8, value.?.string, text);
}
fn inputText(input: Value, key: []const u8) ?[]const u8 {
    if (input != .object) return null;
    const value = input.object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}
fn changedFiles(old: Value, new: Value) usize {
    if (old != .array or new != .array) return if (new == .array) new.array.items.len else 0;
    var count: usize = 0;
    for (new.array.items) |input| {
        var found = false;
        if (inputText(input, "path")) |path| for (old.array.items) |previous| {
            if (inputText(previous, "path")) |previous_path| if (std.mem.eql(u8, path, previous_path)) {
                if (inputText(input, "checksum")) |checksum| found = textEqual(previous.object.get("checksum"), checksum);
                break;
            };
        };
        if (!found) count += 1;
    }
    for (old.array.items) |previous| {
        var found = false;
        if (inputText(previous, "path")) |path| for (new.array.items) |input| {
            if (inputText(input, "path")) |input_path| if (std.mem.eql(u8, path, input_path)) {
                found = true;
                break;
            };
        };
        if (!found) count += 1;
    }
    return count;
}

pub fn save(runtime: types.Runtime, state: State, graph: *const types.Graph) !void {
    const a = runtime.allocator;
    var stored: Value = .{ .object = .empty };
    try values.put(a, &stored, "schema", .{ .string = schema });
    try values.put(a, &stored, "fingerprint", .{ .string = state.fingerprint });
    try values.put(a, &stored, "context_fingerprint", .{ .string = state.context_fingerprint });
    try values.put(a, &stored, "files", state.files);
    try stored.object.put(a, try a.dupe(u8, "graph"), try codec.encodeGraph(a, graph));
    const bytes = try std.json.Stringify.valueAlloc(a, stored, .{});
    const write_path = state.write_path orelse state.path;
    const parent = std.fs.path.dirname(write_path) orelse ".";
    try std.Io.Dir.cwd().createDirPath(runtime.io, parent);
    const temporary = try std.fmt.allocPrint(a, "{s}.{d}.{x}.tmp", .{ write_path, std.os.linux.getpid(), @intFromPtr(graph) });
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = temporary, .data = bytes });
    defer std.Io.Dir.cwd().deleteFile(runtime.io, temporary) catch {};
    try std.Io.Dir.cwd().rename(temporary, std.Io.Dir.cwd(), write_path, runtime.io);
}

/// Reuse only independently parsed literal models. Models executing macros,
/// variables, control flow or runtime context always pass through the renderer.
/// Global properties and dependency/access resolution are applied again later.
pub fn model(runtime: types.Runtime, root: []const u8, model_root: []const u8, relative_path: []const u8, package: []const u8, graph: *types.Graph, parse: *const fn (types.Runtime, []const u8, []const u8, []const u8, []const u8, *types.Graph) anyerror!void) !void {
    const a = runtime.allocator;
    if (!graph.command_options.partial_parse or !graph.command_options.partial_parse_file_diff) return parse(runtime, root, model_root, relative_path, package, graph);
    const path = try fs.pathJoin(a, &.{ root, relative_path });
    const sql = try std.Io.Dir.cwd().readFileAlloc(runtime.io, path, a, .limited(16 * 1024 * 1024));
    if (!independentLiteralSql(sql)) return parse(runtime, root, model_root, relative_path, package, graph);
    const key = try std.fmt.allocPrint(a, "{d}:{s}:{d}:{s}:{s}", .{ package.len, package, model_root.len, model_root, path });
    if (graph.parser_file_cache == .object) if (graph.parser_file_cache.object.get(key)) |entry| {
        if (entry == .object and textEqual(entry.object.get("sql"), sql)) {
            if (entry.object.get("node")) |raw| {
                if (codec.decodeNode(a, raw)) |node| {
                    try graph.nodes.append(a, node);
                    graph.parser_cache_reused_files += 1;
                    return;
                } else |_| {}
            }
        }
    };
    const before = graph.nodes.items.len;
    try parse(runtime, root, model_root, relative_path, package, graph);
    if (graph.nodes.items.len != before + 1) return;
    const node = graph.nodes.items[before];
    if (node.macro_depends_on.items.len != 0) return;
    if (graph.parser_file_cache != .object) {
        values.deinit(a, &graph.parser_file_cache);
        graph.parser_file_cache = .{ .object = .empty };
    }
    var entry: Value = .{ .object = .empty };
    try values.put(a, &entry, "sql", .{ .string = sql });
    try entry.object.put(a, try a.dupe(u8, "node"), try codec.encodeNode(a, node));
    if (graph.parser_file_cache.object.getPtr(key)) |old| values.deinit(a, old);
    try graph.parser_file_cache.object.put(a, key, entry);
}

fn independentLiteralSql(sql: []const u8) bool {
    if (std.mem.indexOf(u8, sql, "{%") != null or std.mem.indexOf(u8, sql, "{#") != null) return false;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, sql, offset, "{{")) |open| {
        const close = std.mem.indexOfPos(u8, sql, open + 2, "}}") orelse return false;
        const expression = std.mem.trim(u8, sql[open + 2 .. close], " \t\r\n-");
        var index: usize = 0;
        while (index < expression.len and std.ascii.isAlphabetic(expression[index])) index += 1;
        const function = expression[0..index];
        if (!std.mem.eql(u8, function, "config") and !std.mem.eql(u8, function, "ref") and !std.mem.eql(u8, function, "source")) return false;
        while (index < expression.len) {
            const ch = expression[index];
            if (ch == '\'' or ch == '"') {
                const quote = ch;
                index += 1;
                var ended = false;
                while (index < expression.len) {
                    if (expression[index] == '\\') {
                        index += 2;
                        continue;
                    }
                    if (expression[index] == quote) {
                        index += 1;
                        ended = true;
                        break;
                    }
                    index += 1;
                }
                if (!ended) return false;
            } else if (std.ascii.isAlphabetic(ch) or ch == '_') {
                const start = index;
                while (index < expression.len and (std.ascii.isAlphanumeric(expression[index]) or expression[index] == '_')) index += 1;
                const word = expression[start..index];
                var next = index;
                while (next < expression.len and std.ascii.isWhitespace(expression[next])) next += 1;
                const named_argument = next < expression.len and expression[next] == '=' and (next + 1 == expression.len or expression[next + 1] != '=');
                if (!named_argument and !std.mem.eql(u8, word, "true") and !std.mem.eql(u8, word, "True") and !std.mem.eql(u8, word, "false") and !std.mem.eql(u8, word, "False") and !std.mem.eql(u8, word, "none") and !std.mem.eql(u8, word, "None")) return false;
            } else index += 1;
        }
        offset = close + 2;
    }
    return true;
}

test "incremental parse reuse requires independent literal SQL" {
    try std.testing.expect(independentLiteralSql("select 1"));
    try std.testing.expect(independentLiteralSql("{{ config(tags=['daily'], materialized='table', meta={'owner': 'team'}) }}select * from {{ ref('base', version=2) }}"));
    try std.testing.expect(!independentLiteralSql("{{ var('value') }}"));
    try std.testing.expect(!independentLiteralSql("{{ config(enabled=flags.ENABLED) }}select 1"));
    try std.testing.expect(!independentLiteralSql("{{ config(tags=project_tags) }}select 1"));
    try std.testing.expect(!independentLiteralSql("{% if execute %}select 1{% endif %}"));
    try std.testing.expect(!independentLiteralSql("select {{ authored_macro() }}"));
}
