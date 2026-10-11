//! Developer harness for the product's native YAML document reader.
const std = @import("std");
const yaml = @import("dxt").yaml;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.ExpectedFixturePath;
    const text = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], allocator, .limited(16 * 1024 * 1024));
    var buffer: [4096]u8 = undefined;
    var output: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    var diagnostic: yaml.Diagnostic = .{};
    var document = yaml.parseWithDiagnostics(allocator, text, &diagnostic) catch |err| {
        try std.json.Stringify.value(.{ .error_name = @errorName(err), .diagnostic = diagnostic }, .{}, &output.interface);
        try output.interface.flush();
        std.process.exit(2);
    };
    defer document.deinit();
    try normalize(allocator, &document.value);
    try std.json.Stringify.value(document.value, .{}, &output.interface);
    try output.interface.flush();
}

fn normalize(allocator: std.mem.Allocator, value: *std.json.Value) anyerror!void {
    switch (value.*) {
        .float => |number| if (!std.math.isFinite(number)) {
            value.* = .{ .string = if (std.math.isNan(number)) ".nan" else if (number < 0) "-.inf" else ".inf" };
        },
        .array => |*array| for (array.items) |*item| try normalize(allocator, item),
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |item| try normalize(allocator, item.value_ptr);
        },
        else => {},
    }
}
