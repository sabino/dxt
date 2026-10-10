//! Core's parse-only TestMacroNamespace contains a seeded DFS closure. Each
//! later macro with the same name replaces the preceding local binding.
const std = @import("std");
const types = @import("types.zig");

pub const Namespace = struct {
    graph: *const types.Graph,
    ids: []const []const u8,

    pub fn init(a: std.mem.Allocator, graph: *const types.Graph, seeds: []const []const u8) !Namespace {
        var ids: std.ArrayList([]const u8) = .empty;
        errdefer ids.deinit(a);
        for (seeds) |id| try visit(a, graph, &ids, id);
        return .{ .graph = graph, .ids = try ids.toOwnedSlice(a) };
    }

    pub fn deinit(self: Namespace, a: std.mem.Allocator) void {
        a.free(self.ids);
    }

    pub fn find(self: Namespace, name: []const u8) ?[]const u8 {
        const dot = std.mem.lastIndexOfScalar(u8, name, '.');
        const macro_name = if (dot) |at| name[at + 1 ..] else name;
        var index = self.ids.len;
        while (index != 0) {
            index -= 1;
            const macro = findMacro(self.graph, self.ids[index]) orelse continue;
            if (!std.mem.eql(u8, macro.name, macro_name)) continue;
            if (dot) |at| if (!std.mem.eql(u8, macro.package_name, name[0..at])) continue;
            return macro.unique_id;
        }
        return null;
    }
};

fn visit(a: std.mem.Allocator, graph: *const types.Graph, ids: *std.ArrayList([]const u8), id: []const u8) anyerror!void {
    for (ids.items) |prior| if (std.mem.eql(u8, prior, id)) return;
    try ids.append(a, id);
    const macro = findMacro(graph, id) orelse return;
    for (macro.macro_depends_on.items) |dependency| try visit(a, graph, ids, dependency);
}

fn findMacro(graph: *const types.Graph, id: []const u8) ?*const types.MacroDef {
    for (graph.macros.items) |*macro| if (std.mem.eql(u8, macro.unique_id, id)) return macro;
    return null;
}

test "generic namespace DFS keeps authored dependency order and later bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph = types.Graph{ .allocator = a, .project_name = "root" };
    defer graph.deinit();
    for ([_][2][]const u8{ .{ "root", "test_check" }, .{ "alpha", "choose" }, .{ "zeta", "choose" }, .{ "hidden", "choose" } }) |definition| {
        try graph.macros.append(a, .{ .package_name = definition[0], .name = definition[1], .unique_id = try std.fmt.allocPrint(a, "macro.{s}.{s}", .{ definition[0], definition[1] }), .path = "tests.sql", .original_file_path = "macros/tests.sql", .macro_sql = "" });
    }
    try graph.macros.items[0].macro_depends_on.appendSlice(a, &.{ "macro.zeta.choose", "macro.alpha.choose" });
    try graph.macros.items[1].macro_depends_on.append(a, "macro.root.test_check");
    const namespace = try Namespace.init(a, &graph, &.{ "macro.root.test_check", "macro.zeta.choose" });
    defer namespace.deinit(a);
    try std.testing.expectEqual(@as(usize, 3), namespace.ids.len);
    try std.testing.expectEqualStrings("macro.zeta.choose", namespace.ids[1]);
    try std.testing.expectEqualStrings("macro.alpha.choose", namespace.ids[2]);
    try std.testing.expectEqualStrings("macro.alpha.choose", namespace.find("choose").?);
    try std.testing.expectEqualStrings("macro.zeta.choose", namespace.find("zeta.choose").?);
    try std.testing.expect(namespace.find("hidden.choose") == null);
}

test "generic namespace survives owned parse cache with discovery metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var graph = types.Graph{ .allocator = a, .project_name = "root" };
    defer graph.deinit();
    try graph.macros.append(a, .{ .package_name = "alpha", .name = "test_check", .unique_id = "macro.alpha.test_check", .path = "tests.sql", .original_file_path = "macros/tests.sql", .macro_sql = "", .namespace_order = 37 });
    const codec = @import("parse_cache_codec.zig");
    var stored = try codec.encodeGraph(a, &graph);
    defer @import("config_value.zig").deinit(a, &stored);
    var restored = types.Graph{ .allocator = a, .project_name = "live" };
    defer restored.deinit();
    try codec.decodeGraph(a, &restored, stored);
    try std.testing.expectEqual(@as(?usize, 37), restored.macros.items[0].namespace_order);
    const namespace = try Namespace.init(a, &restored, &.{"macro.alpha.test_check"});
    defer namespace.deinit(a);
    try std.testing.expectEqualStrings("macro.alpha.test_check", namespace.find("test_check").?);
}
