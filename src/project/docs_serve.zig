const std = @import("std");
const Io = std.Io;
const http = std.http;

const types = @import("types.zig");
const project_fs = @import("fs.zig");

pub const max_served_file_bytes = 64 * 1024 * 1024;

const index_html = @import("docs_ui").index_html;

pub fn writeIndex(runtime: types.Runtime, target_dir: []const u8, static: bool) !void {
    const page = try renderIndexHtml(runtime.allocator);
    defer runtime.allocator.free(page);
    const index_path = try project_fs.pathJoin(runtime.allocator, &.{ target_dir, "index.html" });
    defer runtime.allocator.free(index_path);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = index_path, .data = page });
    if (!static) return;
    const manifest_path = try project_fs.pathJoin(runtime.allocator, &.{ target_dir, "manifest.json" });
    defer runtime.allocator.free(manifest_path);
    const catalog_path = try project_fs.pathJoin(runtime.allocator, &.{ target_dir, "catalog.json" });
    defer runtime.allocator.free(catalog_path);
    const manifest = try std.Io.Dir.cwd().readFileAlloc(runtime.io, manifest_path, runtime.allocator, .limited(max_served_file_bytes));
    defer runtime.allocator.free(manifest);
    const catalog = try std.Io.Dir.cwd().readFileAlloc(runtime.io, catalog_path, runtime.allocator, .limited(max_served_file_bytes));
    defer runtime.allocator.free(catalog);
    const result = try renderStaticPage(runtime.allocator, page, manifest, catalog);
    defer runtime.allocator.free(result);
    const static_path = try project_fs.pathJoin(runtime.allocator, &.{ target_dir, "static_index.html" });
    defer runtime.allocator.free(static_path);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = static_path, .data = result });
}

fn renderIndexHtml(allocator: std.mem.Allocator) ![]const u8 {
    var page = try allocator.dupe(u8, index_html);
    errdefer allocator.free(page);
    const changes = [_]struct { from: []const u8, to: []const u8 }{
        .{ .from = "dbt Docs", .to = "dxt docs" },
        .{ .from = "documentation for dbt", .to = "documentation for dxt" },
        .{ .from = "<img style=\"width: 100px; height: 40px\" class=\"logo\" ng-src=\"{{ logo }}\" />", .to = "<span style=\"font:700 28px system-ui;color:#16302b\">dxt</span>" },
        .{ .from = "${require('./assets/favicons/favicon.ico')}", .to = "data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20viewBox='0%200%2016%2016'%3E%3Ctext%20y='13'%20font-size='14'%3Ed%3C/text%3E%3C/svg%3E" },
        .{ .from = " src=\"{{ getIcon", .to = " ng-src=\"{{ getIcon" },
    };
    for (changes) |change| {
        const previous = page;
        page = try std.mem.replaceOwned(u8, allocator, previous, change.from, change.to);
        allocator.free(previous);
    }
    return page;
}

fn renderStaticPage(allocator: std.mem.Allocator, page: []const u8, manifest: []const u8, catalog: []const u8) ![]const u8 {
    const replacements = [_]struct { token: []const u8, data: []const u8 }{
        .{ .token = "\"MANIFEST.JSON INLINE DATA\"", .data = manifest },
        .{ .token = "\"CATALOG.JSON INLINE DATA\"", .data = catalog },
    };
    var out: Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var offset: usize = 0;
    while (offset < page.len) {
        var next: ?usize = null;
        var replacement: usize = 0;
        for (replacements, 0..) |item, i| {
            if (std.mem.indexOfPos(u8, page, offset, item.token)) |position| {
                if (next == null or position < next.?) {
                    next = position;
                    replacement = i;
                }
            }
        }
        const position = next orelse break;
        try out.writer.writeAll(page[offset..position]);
        // JSON '<' characters only occur inside strings. Escaping them prevents
        // model SQL or descriptions from terminating the enclosing script tag.
        for (replacements[replacement].data) |character| {
            if (character == '<') try out.writer.writeAll("\\u003c") else try out.writer.writeByte(character);
        }
        offset = position + replacements[replacement].token.len;
    }
    try out.writer.writeAll(page[offset..]);
    return out.toOwnedSlice();
}

fn openBrowser(runtime: types.Runtime, options: types.Options, stdout: *Io.Writer) !void {
    const host = if (std.mem.eql(u8, options.docs_host, "0.0.0.0") or std.mem.eql(u8, options.docs_host, "::")) "localhost" else options.docs_host;
    const url = try std.fmt.allocPrint(runtime.allocator, "http://{s}:{d}", .{ host, options.docs_port });
    defer runtime.allocator.free(url);
    const opener = if (@import("builtin").os.tag == .macos) "open" else "xdg-open";
    var child = std.process.spawn(runtime.io, .{ .argv = &.{ opener, url }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch {
        try stdout.writeAll("Browser launcher unavailable; open the URL above.\n");
        try stdout.flush();
        return;
    };
    const thread = std.Thread.spawn(.{}, waitBrowser, .{ runtime.io, child }) catch {
        child.kill(runtime.io);
        return;
    };
    thread.detach();
}

fn waitBrowser(io: Io, process: std.process.Child) void {
    var child = process;
    _ = child.wait(io) catch {};
}

pub fn serve(runtime: types.Runtime, options: types.Options, target_dir: []const u8, stdout: *Io.Writer) !void {
    try std.Io.Dir.cwd().createDirPath(runtime.io, target_dir);
    try writeIndex(runtime, target_dir, false);

    var address = try Io.net.IpAddress.resolve(runtime.io, options.docs_host, options.docs_port);
    var server = try address.listen(runtime.io, .{
        .reuse_address = true,
        .mode = .stream,
    });
    defer server.deinit(runtime.io);

    var startup: std.Io.Writer.Allocating = .init(runtime.allocator);
    defer startup.deinit();
    try startup.writer.print("Serving docs at {d}\n", .{options.docs_port});
    try startup.writer.print("To access from your browser, navigate to: http://{s}:{d}\n", .{ options.docs_host, options.docs_port });
    try startup.writer.writeAll("\n\nPress Ctrl+C to exit.\n");
    if (options.docs_open_browser) try openBrowser(runtime, options, &startup.writer);
    var diagnostics: std.Io.Writer.Discarding = .init(&.{});
    try @import("cli_logs.zig").finish(runtime, options, &.{ "dxt", "docs", "serve" }, stdout, &diagnostics.writer, startup.written(), "");
    try stdout.flush();

    while (true) {
        const stream = try server.accept(runtime.io);
        const thread = std.Thread.spawn(.{}, serveConnection, .{ runtime, stream, target_dir }) catch {
            var rejected = stream;
            rejected.close(runtime.io);
            continue;
        };
        thread.detach();
    }
}

fn serveConnection(runtime: types.Runtime, stream: Io.net.Stream, target_dir: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var connection_runtime = runtime;
    connection_runtime.allocator = arena.allocator();
    accept(connection_runtime, stream, target_dir) catch {};
}

fn accept(runtime: types.Runtime, stream: Io.net.Stream, target_dir: []const u8) !void {
    var closeable = stream;
    defer closeable.close(runtime.io);

    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [4096]u8 = undefined;
    var connection_reader = stream.reader(runtime.io, &recv_buffer);
    var connection_writer = stream.writer(runtime.io, &send_buffer);
    var server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return,
        };
        try serveRequest(runtime, &request, target_dir);
        return;
    }
}

fn serveRequest(runtime: types.Runtime, request: *http.Server.Request, target_dir: []const u8) !void {
    switch (request.head.method) {
        .GET, .HEAD => {},
        else => return respondText(request, .method_not_allowed, "Method Not Allowed\n", "text/plain; charset=utf-8"),
    }

    const relative_path = normalizedRequestPath(request.head.target) catch {
        return respondText(request, .bad_request, "Bad Request\n", "text/plain; charset=utf-8");
    };
    const full_path = try project_fs.pathJoin(runtime.allocator, &.{ target_dir, relative_path });
    defer runtime.allocator.free(full_path);
    const file_contents = std.Io.Dir.cwd().readFileAlloc(runtime.io, full_path, runtime.allocator, .limited(max_served_file_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir, error.IsDir => return respondText(request, .not_found, "Not Found\n", "text/plain; charset=utf-8"),
        else => return respondText(request, .internal_server_error, "Internal Server Error\n", "text/plain; charset=utf-8"),
    };
    defer runtime.allocator.free(file_contents);

    try request.respond(file_contents, .{
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = contentType(relative_path) },
            .{ .name = "Cache-Control", .value = "no-store" },
        },
    });
}

fn respondText(request: *http.Server.Request, status: http.Status, body: []const u8, content_type: []const u8) !void {
    try request.respond(body, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = content_type },
            .{ .name = "Cache-Control", .value = "no-store" },
        },
    });
}

pub fn normalizedRequestPath(target: []const u8) ![]const u8 {
    if (target.len == 0 or target[0] != '/') return error.InvalidDocsServePath;
    const query_start = std.mem.indexOfAny(u8, target, "?#") orelse target.len;
    const path = target[0..query_start];
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.InvalidDocsServePath;
    if (std.mem.indexOfScalar(u8, path, '%') != null) return error.InvalidDocsServePath;
    if (path.len == 1) return "index.html";

    const relative = path[1..];
    var segments = std.mem.splitScalar(u8, relative, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return error.InvalidDocsServePath;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidDocsServePath;
    }
    return relative;
}

pub fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".sql")) return "text/plain; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    return "application/octet-stream";
}

test "docs serve normalizes safe request paths" {
    try std.testing.expectEqualStrings("index.html", try normalizedRequestPath("/"));
    try std.testing.expectEqualStrings("manifest.json", try normalizedRequestPath("/manifest.json"));
    try std.testing.expectEqualStrings("compiled/pkg/models/orders.sql", try normalizedRequestPath("/compiled/pkg/models/orders.sql?cache=1"));
}

test "docs serve rejects unsafe request paths" {
    try std.testing.expectError(error.InvalidDocsServePath, normalizedRequestPath(""));
    try std.testing.expectError(error.InvalidDocsServePath, normalizedRequestPath("manifest.json"));
    try std.testing.expectError(error.InvalidDocsServePath, normalizedRequestPath("/../manifest.json"));
    try std.testing.expectError(error.InvalidDocsServePath, normalizedRequestPath("/compiled/../manifest.json"));
    try std.testing.expectError(error.InvalidDocsServePath, normalizedRequestPath("/compiled//manifest.json"));
    try std.testing.expectError(error.InvalidDocsServePath, normalizedRequestPath("/%2e%2e/manifest.json"));
    try std.testing.expectError(error.InvalidDocsServePath, normalizedRequestPath("/compiled\\manifest.json"));
}

test "docs serve assigns common content types" {
    try std.testing.expectEqualStrings("text/html; charset=utf-8", contentType("index.html"));
    try std.testing.expectEqualStrings("application/json; charset=utf-8", contentType("manifest.json"));
    try std.testing.expectEqualStrings("text/plain; charset=utf-8", contentType("compiled/pkg/models/orders.sql"));
    try std.testing.expectEqualStrings("application/octet-stream", contentType("asset.bin"));
}

test "static docs inline artifacts once and escape script terminators" {
    const page = "manifest=\"MANIFEST.JSON INLINE DATA\";catalog=\"CATALOG.JSON INLINE DATA\";";
    const result = try renderStaticPage(std.testing.allocator, page, "{\"raw_code\":\"</script> \\\"CATALOG.JSON INLINE DATA\\\"\"}", "{}");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("manifest={\"raw_code\":\"\\u003c/script> \\\"CATALOG.JSON INLINE DATA\\\"\"};catalog={};", result);
}
