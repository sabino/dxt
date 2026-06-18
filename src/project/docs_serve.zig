const std = @import("std");
const Io = std.Io;
const http = std.http;

const types = @import("types.zig");
const project_fs = @import("fs.zig");

pub const max_served_file_bytes = 64 * 1024 * 1024;

const index_html =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="utf-8">
    \\  <meta name="viewport" content="width=device-width, initial-scale=1">
    \\  <title>dxt docs</title>
    \\  <style>
    \\    body { font-family: system-ui, sans-serif; margin: 2rem; max-width: 56rem; line-height: 1.5; }
    \\    code { background: #f4f4f5; padding: 0.1rem 0.25rem; border-radius: 0.25rem; }
    \\    a { color: #075985; }
    \\  </style>
    \\</head>
    \\<body>
    \\  <h1>dxt docs</h1>
    \\  <p>This pre-alpha docs server serves generated dbt-shaped artifacts from the target directory.</p>
    \\  <ul>
    \\    <li><a href="/manifest.json"><code>manifest.json</code></a></li>
    \\    <li><a href="/catalog.json"><code>catalog.json</code></a></li>
    \\  </ul>
    \\</body>
    \\</html>
    \\
;

pub fn serve(runtime: types.Runtime, options: types.Options, target_dir: []const u8, stdout: *Io.Writer) !void {
    if (options.docs_open_browser) return error.UnsupportedDocsBrowserOpen;

    try std.Io.Dir.cwd().createDirPath(runtime.io, target_dir);
    const index_path = try project_fs.pathJoin(runtime.allocator, &.{ target_dir, "index.html" });
    defer runtime.allocator.free(index_path);
    try std.Io.Dir.cwd().writeFile(runtime.io, .{ .sub_path = index_path, .data = index_html });

    var address = try Io.net.IpAddress.resolve(runtime.io, options.docs_host, options.docs_port);
    var server = try address.listen(runtime.io, .{
        .reuse_address = true,
        .mode = .stream,
    });
    defer server.deinit(runtime.io);

    try stdout.print("Serving docs at {d}\n", .{options.docs_port});
    try stdout.print("To access from your browser, navigate to: http://{s}:{d}\n", .{ options.docs_host, options.docs_port });
    try stdout.writeAll("\n\nPress Ctrl+C to exit.\n");
    try stdout.flush();

    while (true) {
        const stream = try server.accept(runtime.io);
        accept(runtime, stream, target_dir) catch {};
    }
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
        if (!request.head.keep_alive) return;
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
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = contentType(relative_path) },
            .{ .name = "Cache-Control", .value = "no-store" },
        },
    });
}

fn respondText(request: *http.Server.Request, status: http.Status, body: []const u8, content_type: []const u8) !void {
    try request.respond(body, .{
        .status = status,
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
