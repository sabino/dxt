const std = @import("std");
const expression = @import("expression.zig");
const values = @import("config_value.zig");
const types = @import("types.zig");

pub const Context = struct {
    runtime: types.Runtime,
    vars: []const types.VarEntry = &.{},
    target: std.json.Value = .null,
    allow_secrets: bool = false,

    pub fn render(self: *Context, value: std.json.Value) anyerror!std.json.Value {
        switch (value) {
            .string => |text| return try self.renderString(text),
            .array => |items| {
                var array = std.json.Array.init(self.runtime.allocator);
                for (items.items) |item| try array.append(try self.render(item));
                return .{ .array = array };
            },
            .object => |object| {
                var rendered: std.json.ObjectMap = .empty;
                var it = object.iterator();
                while (it.next()) |entry| try rendered.put(self.runtime.allocator, try self.runtime.allocator.dupe(u8, entry.key_ptr.*), try self.render(entry.value_ptr.*));
                return .{ .object = rendered };
            },
            else => return value,
        }
    }

    pub fn renderString(self: *Context, text: []const u8) !std.json.Value {
        const allocator = self.runtime.allocator;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        const host = expression.Host{ .context = self, .resolve = resolve, .call = call };
        if (std.mem.startsWith(u8, trimmed, "{{") and std.mem.endsWith(u8, trimmed, "}}") and std.mem.indexOf(u8, trimmed[2 .. trimmed.len - 2], "}}") == null) {
            const result = try expression.evaluate(scratch, std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t\r\n-"), host);
            return try values.fromExpression(allocator, result);
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, text, cursor, "{{")) |open| {
            try out.appendSlice(allocator, text[cursor..open]);
            const close = std.mem.indexOfPos(u8, text, open + 2, "}}") orelse return error.UnsupportedJinja;
            const result = try expression.evaluate(scratch, std.mem.trim(u8, text[open + 2 .. close], " \t\r\n-"), host);
            try out.appendSlice(allocator, try result.text(scratch));
            cursor = close + 2;
        }
        try out.appendSlice(allocator, text[cursor..]);
        return .{ .string = try out.toOwnedSlice(allocator) };
    }

    fn resolve(raw: *anyopaque, path: []const u8, allocator: std.mem.Allocator) anyerror!expression.Value {
        const self: *Context = @ptrCast(@alignCast(raw));
        if (std.mem.eql(u8, path, "target")) return try values.toExpression(allocator, self.target);
        if (std.mem.startsWith(u8, path, "target.")) return try values.toExpression(allocator, values.get(self.target, path[7..]) orelse return .undefined);
        return .undefined;
    }

    fn call(raw: *anyopaque, name: []const u8, args: []const expression.Argument, allocator: std.mem.Allocator) anyerror!expression.Value {
        const self: *Context = @ptrCast(@alignCast(raw));
        if (!std.mem.eql(u8, name, "env_var") and !std.mem.eql(u8, name, "var")) return error.UnresolvedMacro;
        if (args.len < 1 or args.len > 2 or args[0].value != .string) return error.InvalidJinjaArguments;
        const key = args[0].value.string;
        if (std.mem.eql(u8, name, "env_var")) {
            if (!self.allow_secrets and std.mem.startsWith(u8, key, "DBT_ENV_SECRET_")) return error.SecretEnvironmentVariableForbidden;
            if (self.runtime.environment) |env| if (env.get(key)) |value| return .{ .string = value };
        } else {
            for (self.vars) |entry| if (std.mem.eql(u8, entry.name, key)) return if (entry.typed_value) |value| try values.toExpression(allocator, value) else .{ .string = entry.value };
        }
        if (args.len == 2) return args[1].value;
        return if (std.mem.eql(u8, name, "env_var")) error.EnvironmentVariableMissing else error.UnresolvedVar;
    }
};

test "configuration renderer retains native values and restricts secret contexts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    try env.put("DXT_THREADS", "4");
    try env.put("DBT_ENV_SECRET_PASSWORD", "synthetic");
    var context = Context{ .runtime = .{ .allocator = allocator, .io = std.testing.io, .environment = &env } };
    var rendered = try context.renderString("{{ env_var('DXT_THREADS') | int }}");
    defer values.deinit(allocator, &rendered);
    try std.testing.expectEqual(@as(i64, 4), rendered.integer);
    try std.testing.expectError(error.SecretEnvironmentVariableForbidden, context.renderString("{{ env_var('DBT_ENV_SECRET_PASSWORD') }}"));
    context.allow_secrets = true;
    var password = try context.renderString("{{ env_var('DBT_ENV_SECRET_PASSWORD') }}");
    defer values.deinit(allocator, &password);
    try std.testing.expectEqualStrings("synthetic", password.string);
}
