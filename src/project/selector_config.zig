const std = @import("std");
const project_fs = @import("fs.zig");
const selector = @import("selector.zig");
const types = @import("types.zig");
const util = @import("util.zig");

const Runtime = types.Runtime;
const dupTrimmedScalar = util.dupTrimmedScalar;
const leadingSpaces = util.leadingSpaces;
const splitKeyValue = util.splitKeyValue;
const stripYamlComment = util.stripYamlComment;

pub const SelectorAlias = struct {
    name: []const u8,
    definition: []const u8,
};

pub const SelectorAliases = struct {
    items: []SelectorAlias = &.{},

    pub fn deinit(self: *SelectorAliases, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            allocator.free(item.name);
            allocator.free(item.definition);
        }
        allocator.free(self.items);
        self.items = &.{};
    }
};

const PendingAlias = struct {
    started: bool = false,
    name: ?[]const u8 = null,
    definition: ?[]const u8 = null,
};

pub fn resolveSelection(runtime: Runtime, project_dir: []const u8, select: ?[]const u8, selector_names: ?[]const u8) !?[]const u8 {
    if (selector_names == null) {
        if (select) |value| return try runtime.allocator.dupe(u8, value);
        return null;
    }

    var aliases = try loadRootSelectorAliases(runtime, project_dir);
    defer aliases.deinit(runtime.allocator);

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(runtime.allocator);

    var names = std.mem.tokenizeAny(u8, selector_names.?, " \t\r\n");
    var matched_any = false;
    while (names.next()) |name| {
        const definition = findAliasDefinition(aliases.items, name) orelse return error.UnsupportedSelector;
        try parts.append(runtime.allocator, definition);
        matched_any = true;
    }
    if (!matched_any) return error.UnsupportedSelector;
    if (select) |value| try parts.append(runtime.allocator, value);

    return try std.mem.join(runtime.allocator, " ", parts.items);
}

pub fn loadRootSelectorAliases(runtime: Runtime, project_dir: []const u8) !SelectorAliases {
    const path = try project_fs.pathJoin(runtime.allocator, &.{ project_dir, "selectors.yml" });
    const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.UnsupportedSelector,
        else => return err,
    };
    return try parseSelectorAliasesText(runtime.allocator, text);
}

pub fn parseSelectorAliasesText(allocator: std.mem.Allocator, text: []const u8) !SelectorAliases {
    var aliases: std.ArrayList(SelectorAlias) = .empty;
    errdefer aliases.deinit(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_selectors = false;
    var saw_selectors = false;
    var pending: PendingAlias = .{};

    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (!in_selectors) {
            if (leadingSpaces(line) != 0) return error.UnsupportedSelector;
            const kv = splitKeyValue(trimmed) orelse return error.UnsupportedSelector;
            if (!std.mem.eql(u8, kv.key, "selectors")) return error.UnsupportedSelector;
            if (std.mem.trim(u8, kv.value, " \t\r").len != 0) return error.UnsupportedSelector;
            in_selectors = true;
            saw_selectors = true;
            continue;
        }

        if (leadingSpaces(line) == 0) return error.UnsupportedSelector;
        if (std.mem.eql(u8, trimmed, "-")) {
            try finishPendingAlias(allocator, &aliases, &pending);
            pending.started = true;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "- ")) {
            try finishPendingAlias(allocator, &aliases, &pending);
            pending.started = true;
            try applyPendingAliasField(allocator, &pending, std.mem.trim(u8, trimmed[2..], " \t\r"));
            continue;
        }

        if (!pending.started) return error.UnsupportedSelector;
        try applyPendingAliasField(allocator, &pending, trimmed);
    }

    if (!saw_selectors) return error.UnsupportedSelector;
    try finishPendingAlias(allocator, &aliases, &pending);
    return .{ .items = try aliases.toOwnedSlice(allocator) };
}

fn applyPendingAliasField(allocator: std.mem.Allocator, pending: *PendingAlias, line: []const u8) !void {
    const kv = splitKeyValue(line) orelse return error.UnsupportedSelector;
    const value = std.mem.trim(u8, kv.value, " \t\r");
    if (value.len == 0) return error.UnsupportedSelector;

    if (std.mem.eql(u8, kv.key, "name")) {
        if (pending.name != null) return error.UnsupportedSelector;
        pending.name = try normalizeSelectorName(allocator, value);
    } else if (std.mem.eql(u8, kv.key, "definition")) {
        if (pending.definition != null) return error.UnsupportedSelector;
        pending.definition = try normalizeSelectorDefinition(allocator, value);
    } else {
        return error.UnsupportedSelector;
    }
}

fn finishPendingAlias(allocator: std.mem.Allocator, aliases: *std.ArrayList(SelectorAlias), pending: *PendingAlias) !void {
    if (!pending.started) return;
    const name = pending.name orelse return error.UnsupportedSelector;
    const definition = pending.definition orelse return error.UnsupportedSelector;
    if (findAliasDefinition(aliases.items, name) != null) return error.UnsupportedSelector;
    try aliases.append(allocator, .{ .name = name, .definition = definition });
    pending.* = .{};
}

fn findAliasDefinition(aliases: []const SelectorAlias, name: []const u8) ?[]const u8 {
    for (aliases) |alias| {
        if (std.mem.eql(u8, alias.name, name)) return alias.definition;
    }
    return null;
}

fn normalizeSelectorName(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (isUnsupportedScalarValue(value)) return error.UnsupportedSelector;
    const name = try dupTrimmedScalar(allocator, value);
    if (name.len == 0 or std.mem.indexOfAny(u8, name, " \t\r\n") != null) return error.UnsupportedSelector;
    return name;
}

fn normalizeSelectorDefinition(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (isUnsupportedScalarValue(value)) return error.UnsupportedSelector;
    const definition = try dupTrimmedScalar(allocator, value);
    try selector.validateSelectorSyntax(definition);
    return definition;
}

fn isUnsupportedScalarValue(value: []const u8) bool {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (trimmed.len == 0) return true;
    if (isQuotedScalar(trimmed)) return false;
    if (trimmed[0] == '[' or trimmed[0] == '{' or trimmed[0] == '|' or trimmed[0] == '>') return true;
    if (std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "false") or
        std.ascii.eqlIgnoreCase(trimmed, "null") or
        std.mem.eql(u8, trimmed, "~"))
    {
        return true;
    }
    return looksLikeYamlNumber(trimmed);
}

fn isQuotedScalar(value: []const u8) bool {
    return value.len >= 2 and
        ((value[0] == '"' and value[value.len - 1] == '"') or
            (value[0] == '\'' and value[value.len - 1] == '\''));
}

fn looksLikeYamlNumber(value: []const u8) bool {
    var index: usize = 0;
    if (value[index] == '-' or value[index] == '+') {
        index += 1;
        if (index == value.len) return false;
    }

    var saw_digit = false;
    while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {
        saw_digit = true;
    }
    if (index < value.len and value[index] == '.') {
        index += 1;
        while (index < value.len and std.ascii.isDigit(value[index])) : (index += 1) {
            saw_digit = true;
        }
    }
    return saw_digit and index == value.len;
}

test "selector config parses scalar string aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var aliases = try parseSelectorAliasesText(allocator,
        \\selectors:
        \\  - name: customer_family
        \\    definition: "*customers"
        \\  - name: nightly
        \\    definition: tag:nightly
        \\
    );
    defer aliases.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), aliases.items.len);
    try std.testing.expectEqualStrings("customer_family", aliases.items[0].name);
    try std.testing.expectEqualStrings("*customers", aliases.items[0].definition);
    try std.testing.expectEqualStrings("nightly", aliases.items[1].name);
    try std.testing.expectEqualStrings("tag:nightly", aliases.items[1].definition);
}

test "selector config rejects duplicate and missing scalar alias fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.UnsupportedSelector, parseSelectorAliasesText(allocator,
        \\selectors:
        \\  - name: customer_family
        \\    definition: customers
        \\  - name: customer_family
        \\    definition: orders
        \\
    ));
    try std.testing.expectError(error.UnsupportedSelector, parseSelectorAliasesText(allocator,
        \\selectors:
        \\  - name: customer_family
        \\
    ));
    try std.testing.expectError(error.UnsupportedSelector, parseSelectorAliasesText(allocator,
        \\selectors:
        \\  - definition: customers
        \\
    ));
}

test "selector config rejects non-string and unsupported definitions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.UnsupportedSelector, parseSelectorAliasesText(allocator,
        \\selectors:
        \\  - name: customer_family
        \\    definition:
        \\      method: tag
        \\      value: nightly
        \\
    ));
    try std.testing.expectError(error.UnsupportedSelector, parseSelectorAliasesText(allocator,
        \\selectors:
        \\  - name: numeric
        \\    definition: 1
        \\
    ));
    try std.testing.expectError(error.UnsupportedSelector, parseSelectorAliasesText(allocator,
        \\selectors:
        \\  - name: stateful
        \\    definition: state:modified
        \\
    ));
}
