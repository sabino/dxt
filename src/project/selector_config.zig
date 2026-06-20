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
    exclude: ?[]const u8 = null,
};

pub const SelectorAliases = struct {
    items: []SelectorAlias = &.{},

    pub fn deinit(self: *SelectorAliases, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            allocator.free(item.name);
            allocator.free(item.definition);
            if (item.exclude) |value| allocator.free(value);
        }
        allocator.free(self.items);
        self.items = &.{};
    }
};

pub const ResolvedSelection = struct {
    select: ?[]const u8 = null,
    exclude: ?[]const u8 = null,

    pub fn deinit(self: *ResolvedSelection, allocator: std.mem.Allocator) void {
        if (self.select) |value| allocator.free(value);
        if (self.exclude) |value| allocator.free(value);
        self.* = .{};
    }
};

const LineView = struct {
    indent: usize,
    trimmed: []const u8,
};

const LoweredDefinition = struct {
    definition: []const u8,
    exclude: ?[]const u8 = null,

    fn deinit(self: *LoweredDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.definition);
        if (self.exclude) |value| allocator.free(value);
        self.* = .{ .definition = "" };
    }
};

const AliasDraft = struct {
    name: ?[]const u8 = null,
    definition: ?LoweredDefinition = null,

    fn deinit(self: *AliasDraft, allocator: std.mem.Allocator) void {
        if (self.name) |value| allocator.free(value);
        if (self.definition) |*value| value.deinit(allocator);
        self.* = .{};
    }
};

pub fn resolveSelection(runtime: Runtime, project_dir: []const u8, select: ?[]const u8, exclude: ?[]const u8, selector_names: ?[]const u8) !ResolvedSelection {
    if (selector_names == null) {
        return .{
            .select = if (select) |value| try runtime.allocator.dupe(u8, value) else null,
            .exclude = if (exclude) |value| try runtime.allocator.dupe(u8, value) else null,
        };
    }

    var aliases = try loadRootSelectorAliases(runtime, project_dir);
    defer aliases.deinit(runtime.allocator);

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(runtime.allocator);
    var exclude_parts: std.ArrayList([]const u8) = .empty;
    defer exclude_parts.deinit(runtime.allocator);

    var names = std.mem.tokenizeAny(u8, selector_names.?, " \t\r\n");
    var matched_any = false;
    while (names.next()) |name| {
        const alias = findAlias(aliases.items, name) orelse return error.UnsupportedSelector;
        try parts.append(runtime.allocator, alias.definition);
        if (alias.exclude) |value| try exclude_parts.append(runtime.allocator, value);
        matched_any = true;
    }
    if (!matched_any) return error.UnsupportedSelector;
    if (select) |value| try parts.append(runtime.allocator, value);
    if (exclude) |value| try exclude_parts.append(runtime.allocator, value);

    return .{
        .select = try joinPartsOrNull(runtime.allocator, " ", parts.items),
        .exclude = try joinPartsOrNull(runtime.allocator, " ", exclude_parts.items),
    };
}

pub fn loadRootSelectorAliases(runtime: Runtime, project_dir: []const u8) !SelectorAliases {
    const path = try project_fs.pathJoin(runtime.allocator, &.{ project_dir, "selectors.yml" });
    const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.UnsupportedSelector,
        else => return err,
    };
    defer runtime.allocator.free(text);
    return try parseSelectorAliasesText(runtime.allocator, text);
}

pub fn parseSelectorAliasesText(allocator: std.mem.Allocator, text: []const u8) !SelectorAliases {
    var aliases: std.ArrayList(SelectorAlias) = .empty;
    errdefer deinitAliasList(allocator, aliases.items);

    var line_views: std.ArrayList(LineView) = .empty;
    defer line_views.deinit(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try line_views.append(allocator, .{ .indent = leadingSpaces(line), .trimmed = trimmed });
    }

    if (line_views.items.len == 0) return error.UnsupportedSelector;
    const root = line_views.items[0];
    if (root.indent != 0) return error.UnsupportedSelector;
    const root_kv = splitKeyValue(root.trimmed) orelse return error.UnsupportedSelector;
    if (!std.mem.eql(u8, root_kv.key, "selectors")) return error.UnsupportedSelector;
    if (std.mem.trim(u8, root_kv.value, " \t\r").len != 0) return error.UnsupportedSelector;

    var index: usize = 1;
    while (index < line_views.items.len) {
        const item = line_views.items[index];
        if (item.indent == 0 or !std.mem.startsWith(u8, item.trimmed, "-")) return error.UnsupportedSelector;
        const item_indent = item.indent;
        var end = index + 1;
        while (end < line_views.items.len) : (end += 1) {
            const candidate = line_views.items[end];
            if (candidate.indent == item_indent and std.mem.startsWith(u8, candidate.trimmed, "-")) break;
            if (candidate.indent <= item_indent) return error.UnsupportedSelector;
        }

        const alias = try parseAliasItem(allocator, line_views.items[index..end], item_indent);
        if (findAlias(aliases.items, alias.name) != null) {
            deinitAlias(allocator, alias);
            return error.UnsupportedSelector;
        }
        aliases.append(allocator, alias) catch |err| {
            deinitAlias(allocator, alias);
            return err;
        };
        index = end;
    }

    return .{ .items = try aliases.toOwnedSlice(allocator) };
}

fn parseAliasItem(allocator: std.mem.Allocator, lines: []const LineView, item_indent: usize) !SelectorAlias {
    if (lines.len == 0) return error.UnsupportedSelector;
    var draft: AliasDraft = .{};
    errdefer draft.deinit(allocator);

    var index: usize = 0;
    const first = lines[0].trimmed;
    if (std.mem.eql(u8, first, "-")) {
        index = 1;
    } else if (std.mem.startsWith(u8, first, "- ")) {
        try applyAliasField(allocator, &draft, std.mem.trim(u8, first[2..], " \t\r"), lines[1..], item_indent + 2, &index);
    } else {
        return error.UnsupportedSelector;
    }

    while (index < lines.len) {
        const line = lines[index];
        if (line.indent <= item_indent) return error.UnsupportedSelector;
        try applyAliasField(allocator, &draft, line.trimmed, lines[index + 1 ..], line.indent, &index);
    }

    const name = draft.name orelse return error.UnsupportedSelector;
    const definition = draft.definition orelse return error.UnsupportedSelector;
    draft = .{};
    return .{
        .name = name,
        .definition = definition.definition,
        .exclude = definition.exclude,
    };
}

fn applyAliasField(allocator: std.mem.Allocator, draft: *AliasDraft, text: []const u8, remaining: []const LineView, field_indent: usize, index: *usize) !void {
    const kv = splitKeyValue(text) orelse return error.UnsupportedSelector;
    const value = std.mem.trim(u8, kv.value, " \t\r");

    if (std.mem.eql(u8, kv.key, "name")) {
        if (value.len == 0 or draft.name != null) return error.UnsupportedSelector;
        draft.name = try normalizeSelectorName(allocator, value);
        index.* += 1;
    } else if (std.mem.eql(u8, kv.key, "definition")) {
        if (draft.definition != null) return error.UnsupportedSelector;
        if (value.len != 0) {
            draft.definition = try normalizeSelectorDefinition(allocator, value);
            index.* += 1;
            return;
        }
        var block_len: usize = 0;
        while (block_len < remaining.len and remaining[block_len].indent > field_indent) : (block_len += 1) {}
        if (block_len == 0) return error.UnsupportedSelector;
        draft.definition = try parseDefinitionBlock(allocator, remaining[0..block_len]);
        index.* += 1 + block_len;
    } else {
        return error.UnsupportedSelector;
    }
}

fn parseDefinitionBlock(allocator: std.mem.Allocator, lines: []const LineView) anyerror!LoweredDefinition {
    if (lines.len == 0) return error.UnsupportedSelector;
    if (std.mem.startsWith(u8, lines[0].trimmed, "-")) return error.UnsupportedSelector;
    return try parseDefinitionMapping(allocator, lines, lines[0].indent, true);
}

fn parseDefinitionMapping(allocator: std.mem.Allocator, lines: []const LineView, base_indent: usize, allow_composition: bool) anyerror!LoweredDefinition {
    var primary: ?LoweredDefinition = null;
    errdefer {
        if (primary) |*item| item.deinit(allocator);
    }
    var excludes: std.ArrayList([]const u8) = .empty;
    defer {
        freeStringList(allocator, excludes.items);
        excludes.deinit(allocator);
    }
    var method: ?[]const u8 = null;
    defer {
        if (method) |item| allocator.free(item);
    }
    var value: ?[]const u8 = null;
    defer {
        if (value) |item| allocator.free(item);
    }

    var index: usize = 0;
    while (index < lines.len) {
        const line = lines[index];
        if (line.indent != base_indent) return error.UnsupportedSelector;
        const kv = splitKeyValue(line.trimmed) orelse return error.UnsupportedSelector;
        const raw_value = std.mem.trim(u8, kv.value, " \t\r");
        const child_start = index + 1;
        var child_end = child_start;
        while (child_end < lines.len and lines[child_end].indent > base_indent) : (child_end += 1) {}

        if (std.mem.eql(u8, kv.key, "union") or std.mem.eql(u8, kv.key, "intersection")) {
            if (!allow_composition or primary != null or method != null or value != null or raw_value.len != 0 or child_start == child_end) return error.UnsupportedSelector;
            primary = try parseDefinitionList(allocator, lines[child_start..child_end], base_indent, kv.key);
        } else if (std.mem.eql(u8, kv.key, "exclude")) {
            if (raw_value.len != 0 or child_start == child_end) return error.UnsupportedSelector;
            var lowered_exclude = try parseDefinitionList(allocator, lines[child_start..child_end], base_indent, "union");
            if (lowered_exclude.exclude != null) {
                lowered_exclude.deinit(allocator);
                return error.UnsupportedSelector;
            }
            excludes.append(allocator, lowered_exclude.definition) catch |err| {
                lowered_exclude.deinit(allocator);
                return err;
            };
        } else if (std.mem.eql(u8, kv.key, "method")) {
            if (method != null or raw_value.len == 0 or child_start != child_end) return error.UnsupportedSelector;
            method = try normalizeSelectorMethod(allocator, raw_value);
        } else if (std.mem.eql(u8, kv.key, "value")) {
            if (value != null or raw_value.len == 0 or child_start != child_end) return error.UnsupportedSelector;
            value = try normalizeSelectorValue(allocator, raw_value);
        } else if (isSupportedYamlLeafMethod(kv.key)) {
            if (primary != null or method != null or value != null or raw_value.len == 0 or child_start != child_end) return error.UnsupportedSelector;
            primary = try lowerLeafSelector(allocator, kv.key, raw_value);
        } else {
            return error.UnsupportedSelector;
        }
        index = child_end;
    }

    if (method != null or value != null) {
        if (primary != null) return error.UnsupportedSelector;
        const method_name = method orelse return error.UnsupportedSelector;
        const method_value = value orelse return error.UnsupportedSelector;
        primary = try lowerNormalizedLeafSelector(allocator, method_name, method_value);
    }

    var result = primary orelse return error.UnsupportedSelector;
    primary = null;
    errdefer result.deinit(allocator);
    const exclude_joined = try joinPartsOrNull(allocator, " ", excludes.items);
    if (exclude_joined) |joined| {
        if (result.exclude) |existing| {
            result.exclude = try joinTwoParts(allocator, existing, joined);
            allocator.free(existing);
            allocator.free(joined);
        } else {
            result.exclude = joined;
        }
    }
    return result;
}

fn parseDefinitionList(allocator: std.mem.Allocator, lines: []const LineView, parent_indent: usize, mode: []const u8) anyerror!LoweredDefinition {
    if (lines.len == 0) return error.UnsupportedSelector;
    var parts: std.ArrayList([]const u8) = .empty;
    defer {
        freeStringList(allocator, parts.items);
        parts.deinit(allocator);
    }

    var index: usize = 0;
    var item_indent: ?usize = null;
    while (index < lines.len) {
        const line = lines[index];
        if (line.indent <= parent_indent or !std.mem.startsWith(u8, line.trimmed, "-")) return error.UnsupportedSelector;
        if (item_indent) |expected| {
            if (line.indent != expected) return error.UnsupportedSelector;
        } else {
            item_indent = line.indent;
        }

        var end = index + 1;
        while (end < lines.len and !(lines[end].indent == item_indent.? and std.mem.startsWith(u8, lines[end].trimmed, "-"))) : (end += 1) {}
        var lowered = try parseDefinitionListItem(allocator, lines[index..end], item_indent.?);
        if (lowered.exclude != null) {
            lowered.deinit(allocator);
            return error.UnsupportedSelector;
        }
        parts.append(allocator, lowered.definition) catch |err| {
            lowered.deinit(allocator);
            return err;
        };
        index = end;
    }

    if (parts.items.len == 0) return error.UnsupportedSelector;
    const separator = if (std.mem.eql(u8, mode, "intersection")) "," else " ";
    return .{
        .definition = try std.mem.join(allocator, separator, parts.items),
    };
}

fn parseDefinitionListItem(allocator: std.mem.Allocator, lines: []const LineView, item_indent: usize) anyerror!LoweredDefinition {
    if (lines.len == 0) return error.UnsupportedSelector;
    const first = lines[0].trimmed;
    if (!std.mem.startsWith(u8, first, "-")) return error.UnsupportedSelector;
    const rest = if (std.mem.eql(u8, first, "-")) "" else if (std.mem.startsWith(u8, first, "- ")) std.mem.trim(u8, first[2..], " \t\r") else return error.UnsupportedSelector;
    if (rest.len == 0) {
        if (lines.len == 1) return error.UnsupportedSelector;
        return try parseDefinitionBlock(allocator, lines[1..]);
    }
    if (splitKeyValue(rest) == null) {
        if (lines.len != 1) return error.UnsupportedSelector;
        return try normalizeSelectorDefinition(allocator, rest);
    }

    var mapping: std.ArrayList(LineView) = .empty;
    defer mapping.deinit(allocator);
    try mapping.append(allocator, .{ .indent = item_indent + 2, .trimmed = rest });
    for (lines[1..]) |line| try mapping.append(allocator, line);
    return try parseDefinitionMapping(allocator, mapping.items, item_indent + 2, false);
}

fn findAlias(aliases: []const SelectorAlias, name: []const u8) ?SelectorAlias {
    for (aliases) |alias| {
        if (std.mem.eql(u8, alias.name, name)) return alias;
    }
    return null;
}

fn normalizeSelectorName(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (isUnsupportedScalarValue(value)) return error.UnsupportedSelector;
    const name = try dupTrimmedScalar(allocator, value);
    if (name.len == 0 or std.mem.indexOfAny(u8, name, " \t\r\n") != null) return error.UnsupportedSelector;
    return name;
}

fn normalizeSelectorDefinition(allocator: std.mem.Allocator, value: []const u8) !LoweredDefinition {
    if (isUnsupportedScalarValue(value)) return error.UnsupportedSelector;
    const definition = try dupTrimmedScalar(allocator, value);
    errdefer allocator.free(definition);
    try selector.validateSelectorSyntax(definition);
    return .{ .definition = definition };
}

fn normalizeSelectorMethod(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (isUnsupportedScalarValue(value)) return error.UnsupportedSelector;
    const method = try dupTrimmedScalar(allocator, value);
    errdefer allocator.free(method);
    if (!isSupportedYamlLeafMethod(method)) return error.UnsupportedSelector;
    return method;
}

fn normalizeSelectorValue(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (isUnsupportedScalarValue(value)) return error.UnsupportedSelector;
    return try dupTrimmedScalar(allocator, value);
}

fn lowerLeafSelector(allocator: std.mem.Allocator, method: []const u8, raw_value: []const u8) !LoweredDefinition {
    const normalized_value = try normalizeSelectorValue(allocator, raw_value);
    defer allocator.free(normalized_value);
    return try lowerNormalizedLeafSelector(allocator, method, normalized_value);
}

fn lowerNormalizedLeafSelector(allocator: std.mem.Allocator, method: []const u8, value: []const u8) !LoweredDefinition {
    const prefix = yamlLeafMethodPrefix(method) orelse return error.UnsupportedSelector;
    const expression = if (prefix.len == 0)
        try allocator.dupe(u8, value)
    else
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, value });
    errdefer allocator.free(expression);
    try selector.validateSelectorSyntax(expression);
    return .{ .definition = expression };
}

fn isSupportedYamlLeafMethod(method: []const u8) bool {
    return yamlLeafMethodPrefix(method) != null;
}

fn yamlLeafMethodPrefix(method: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, method, "name")) return "";
    if (std.mem.eql(u8, method, "path")) return "path:";
    if (std.mem.eql(u8, method, "file")) return "file:";
    if (std.mem.eql(u8, method, "tag")) return "tag:";
    if (std.mem.eql(u8, method, "resource_type")) return "resource_type:";
    if (std.mem.eql(u8, method, "source")) return "source:";
    if (std.mem.eql(u8, method, "exposure")) return "exposure:";
    if (std.mem.eql(u8, method, "test_type")) return "test_type:";
    return null;
}

fn joinPartsOrNull(allocator: std.mem.Allocator, separator: []const u8, parts: []const []const u8) !?[]const u8 {
    if (parts.len == 0) return null;
    return try std.mem.join(allocator, separator, parts);
}

fn joinTwoParts(allocator: std.mem.Allocator, left: []const u8, right: []const u8) ![]const u8 {
    if (left.len == 0) return try allocator.dupe(u8, right);
    if (right.len == 0) return try allocator.dupe(u8, left);
    return try std.fmt.allocPrint(allocator, "{s} {s}", .{ left, right });
}

fn deinitAliasList(allocator: std.mem.Allocator, aliases: []SelectorAlias) void {
    for (aliases) |alias| deinitAlias(allocator, alias);
}

fn deinitAlias(allocator: std.mem.Allocator, alias: SelectorAlias) void {
    allocator.free(alias.name);
    allocator.free(alias.definition);
    if (alias.exclude) |value| allocator.free(value);
}

fn freeStringList(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
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

test "selector config lowers method leaves and composition aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var aliases = try parseSelectorAliasesText(allocator,
        \\selectors:
        \\  - name: unioned
        \\    definition:
        \\      union:
        \\        - method: name
        \\          value: customers
        \\        - method: tag
        \\          value: nightly
        \\  - name: intersected
        \\    definition:
        \\      intersection:
        \\        - method: path
        \\          value: models/stg_*
        \\        - method: resource_type
        \\          value: model
        \\  - name: without_staging
        \\    definition:
        \\      union:
        \\        - method: name
        \\          value: "*customers"
        \\      exclude:
        \\        - method: file
        \\          value: stg_customers.sql
        \\  - name: shorthand_source
        \\    definition:
        \\      method: source
        \\      value: raw.customers
        \\
    );
    defer aliases.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), aliases.items.len);
    try std.testing.expectEqualStrings("customers tag:nightly", aliases.items[0].definition);
    try std.testing.expect(aliases.items[0].exclude == null);
    try std.testing.expectEqualStrings("path:models/stg_*,resource_type:model", aliases.items[1].definition);
    try std.testing.expectEqualStrings("*customers", aliases.items[2].definition);
    try std.testing.expectEqualStrings("file:stg_customers.sql", aliases.items[2].exclude.?);
    try std.testing.expectEqualStrings("source:raw.customers", aliases.items[3].definition);
}

test "selector config rejects unsupported yaml selector shapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(error.UnsupportedSelector, parseSelectorAliasesText(allocator,
        \\selectors:
        \\  - name: stateful
        \\    definition:
        \\      method: state
        \\      value: modified
        \\
    ));
    try std.testing.expectError(error.UnsupportedSelector, parseSelectorAliasesText(allocator,
        \\selectors:
        \\  - name: packaged
        \\    definition:
        \\      method: package
        \\      value: this
        \\
    ));
    try std.testing.expectError(error.UnsupportedSelector, parseSelectorAliasesText(allocator,
        \\selectors:
        \\  - name: recursive
        \\    definition:
        \\      union:
        \\        - union:
        \\            - customers
        \\
    ));
    try std.testing.expectError(error.UnsupportedSelector, parseSelectorAliasesText(allocator,
        \\selectors:
        \\  - name: indirect
        \\    definition:
        \\      union:
        \\        - customers
        \\      indirect_selection: eager
        \\
    ));
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
        \\  - name: unsupported_package
        \\    definition:
        \\      method: package
        \\      value: this
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
