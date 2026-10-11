//! Docs definitions render with an empty Jinja context, independently of the
//! runtime context used later to render resource descriptions.
const std = @import("std");
const types = @import("types.zig");
const jinja = @import("jinja.zig");

pub fn load(runtime: types.Runtime, project_dir: []const u8, config: *const types.ProjectConfig, graph: *types.Graph) !void {
    for (config.docs_paths.items) |path| {
        var sql: std.ArrayList([]const u8) = .empty;
        defer sql.deinit(runtime.allocator);
        var yaml: std.ArrayList([]const u8) = .empty;
        defer yaml.deinit(runtime.allocator);
        var markdown: std.ArrayList([]const u8) = .empty;
        defer markdown.deinit(runtime.allocator);
        const root = try @import("fs.zig").pathJoin(runtime.allocator, &.{ project_dir, path });
        @import("fs.zig").discoverProjectFiles(runtime, root, path, &sql, &yaml, &markdown) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        @import("util.zig").sortStrings(markdown.items);
        for (markdown.items) |relative| {
            const absolute = try @import("fs.zig").pathJoin(runtime.allocator, &.{ project_dir, relative });
            const text = try std.Io.Dir.cwd().readFileAlloc(runtime.io, absolute, runtime.allocator, .limited(4 * 1024 * 1024));
            try parse(runtime.allocator, text, path, relative, config.name, graph);
        }
    }
}

pub fn parse(allocator: std.mem.Allocator, text: []const u8, resource_root: []const u8, path: []const u8, package: []const u8, graph: *types.Graph) !void {
    var cursor: usize = 0;
    var controls: std.ArrayList([]const u8) = .empty;
    defer controls.deinit(allocator);
    while (try nextBlock(text, &cursor)) |open| {
        const close = blockClose(text, open) orelse return error.MalformedDocsBlock;
        const tag = std.mem.trim(u8, text[open + 2 .. close], " \t\r\n-");
        cursor = close + 2;
        if (std.mem.eql(u8, tag, "raw")) {
            cursor = (try endTag(text, cursor, "endraw", false)).close + 2;
            continue;
        }
        if (keyword(tag, "if") or keyword(tag, "for")) {
            try controls.append(allocator, if (keyword(tag, "if")) "endif" else "endfor");
            continue;
        }
        if (std.mem.eql(u8, tag, "endif") or std.mem.eql(u8, tag, "endfor")) {
            const expected = controls.pop() orelse return error.MalformedDocsBlock;
            if (!std.mem.eql(u8, tag, expected)) return error.MalformedDocsBlock;
            continue;
        }
        if (!std.mem.startsWith(u8, tag, "docs") or (tag.len > 4 and !std.ascii.isWhitespace(tag[4]))) continue;
        if (controls.items.len != 0) return error.MalformedDocsBlock;
        const name = std.mem.trim(u8, tag[4..], " \t\r\n");
        if (name.len == 0 or !jinja.isIdentStart(name[0])) return error.MalformedDocsBlock;
        for (name[1..]) |byte| if (!jinja.isIdentChar(byte)) return error.MalformedDocsBlock;
        const end = try endTag(text, cursor, "enddocs", true);
        const id = try std.fmt.allocPrint(allocator, "doc.{s}.{s}", .{ package, name });
        const rendered = try @import("compiler.zig").renderDocumentationBlock(allocator, graph, package, id, path, text[cursor..end.open]);
        defer allocator.free(rendered);
        try graph.docs.append(allocator, .{
            .package_name = package,
            .unique_id = id,
            .name = try allocator.dupe(u8, name),
            .path = @import("fs.zig").relativeUnderResourcePath(path, resource_root),
            .original_file_path = path,
            .block_contents = try allocator.dupe(u8, std.mem.trim(u8, rendered, " \t\r\n")),
        });
        cursor = end.close + 2;
    }
}

fn keyword(tag: []const u8, word: []const u8) bool {
    return std.mem.startsWith(u8, tag, word) and (tag.len == word.len or std.ascii.isWhitespace(tag[word.len]));
}

const EndTag = struct { open: usize, close: usize };
fn endTag(text: []const u8, start: usize, expected: []const u8, skip_raw: bool) !EndTag {
    var cursor = start;
    while (try nextBlock(text, &cursor)) |open| {
        const close = blockClose(text, open) orelse return error.MalformedDocsBlock;
        const tag = std.mem.trim(u8, text[open + 2 .. close], " \t\r\n-");
        if (std.mem.eql(u8, tag, expected)) return .{ .open = open, .close = close };
        if (std.mem.startsWith(u8, tag, "docs ")) return error.MalformedDocsBlock;
        cursor = close + 2;
        if (skip_raw and std.mem.eql(u8, tag, "raw")) cursor = (try endTag(text, cursor, "endraw", false)).close + 2;
    }
    return error.MalformedDocsBlock;
}

fn nextBlock(text: []const u8, cursor: *usize) !?usize {
    while (std.mem.indexOfPos(u8, text, cursor.*, "{")) |open| {
        if (open + 1 >= text.len) return null;
        switch (text[open + 1]) {
            '%' => return open,
            '#' => cursor.* = (std.mem.indexOfPos(u8, text, open + 2, "#}") orelse return error.MalformedDocsBlock) + 2,
            '{' => cursor.* = (jinja.findExpressionClose(text, open + 2) orelse return error.MalformedDocsBlock) + 2,
            else => cursor.* = open + 1,
        }
    }
    return null;
}

fn blockClose(text: []const u8, open: usize) ?usize {
    var cursor = open + 2;
    while (cursor + 1 < text.len) : (cursor += 1) {
        if (text[cursor] == '"' or text[cursor] == '\'') {
            cursor = (jinja.skipQuotedSpan(text, cursor) orelse return null) - 1;
        } else if (text[cursor] == '%' and text[cursor + 1] == '}') return cursor;
    }
    return null;
}

test "docs definitions ignore comments and render native nested Jinja with no dbt globals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph = types.Graph{ .allocator = a, .project_name = "demo" };
    defer graph.deinit();
    try parse(a, "{# {% docs ignored %} #}{% docs active %}{{ 'header' | upper }}{% for item in ['a','b'] %} {{ item }}{% endfor %}{% enddocs %}", "models", "models/docs.md", "demo", &graph);
    try std.testing.expectEqual(@as(usize, 1), graph.docs.items.len);
    try std.testing.expectEqualStrings("HEADER a b", graph.docs.items[0].block_contents);
    try std.testing.expectError(error.UnresolvedMacro, parse(a, "{% docs failure %}{{ var('who','default') }}{% enddocs %}", "models", "models/docs.md", "demo", &graph));
}
