const std = @import("std");
const project_fs = @import("fs.zig");
const selector = @import("selector.zig");
const expressions = @import("selection_expression.zig");
const Expression = expressions.Expression;
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
    default: bool = false,
    indirect_selection: ?[]const u8 = null,
    expression: ?*Expression = null,
};

pub const SelectorAliases = struct {
    items: []SelectorAlias = &.{},

    pub fn deinit(self: *SelectorAliases, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            allocator.free(item.name);
            allocator.free(item.definition);
            if (item.exclude) |value| allocator.free(value);
            if (item.expression) |expression| expression.destroy(allocator);
        }
        allocator.free(self.items);
        self.items = &.{};
    }
};

pub const ResolvedSelection = struct {
    expression: ?*Expression = null,
    indirect_selection: ?[]const u8 = null,
    select: ?[]const u8 = null,
    exclude: ?[]const u8 = null,

    pub fn deinit(self: *ResolvedSelection, allocator: std.mem.Allocator) void {
        if (self.select) |value| allocator.free(value);
        if (self.exclude) |value| allocator.free(value);
        if (self.expression) |expression| expression.destroy(allocator);
        self.* = .{};
    }
};

const LineView = struct {
    indent: usize,
    trimmed: []const u8,
};

const LoweredDefinition = struct {
    expression: ?*Expression = null,
    exclude_only: bool = false,
    indirect_selection: ?[]const u8 = null,
    definition: []const u8,
    exclude: ?[]const u8 = null,

    fn deinit(self: *LoweredDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.definition);
        if (self.exclude) |value| allocator.free(value);
        if (self.expression) |expression| expression.destroy(allocator);
        self.* = .{ .definition = "" };
    }
};

const AliasDraft = struct {
    default: bool = false,
    indirect_selection: ?[]const u8 = null,
    name: ?[]const u8 = null,
    definition: ?LoweredDefinition = null,

    fn deinit(self: *AliasDraft, allocator: std.mem.Allocator) void {
        if (self.name) |value| allocator.free(value);
        if (self.definition) |*value| value.deinit(allocator);
        self.* = .{};
    }
};

pub fn resolveSelection(runtime: Runtime, project_dir: []const u8, select: ?[]const u8, exclude: ?[]const u8, selector_names: ?[]const u8) !ResolvedSelection {
    if (selector_names == null and (select != null or exclude != null)) {
        return .{
            .select = if (select) |value| try runtime.allocator.dupe(u8, value) else null,
            .exclude = if (exclude) |value| try runtime.allocator.dupe(u8, value) else null,
        };
    }

    var aliases = loadRootSelectorAliases(runtime, project_dir) catch |err| switch (err) {
        error.MissingSelectorsFile => {
            if (selector_names != null) return error.UnsupportedSelector;
            return .{};
        },
        else => return err,
    };
    defer aliases.deinit(runtime.allocator);

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(runtime.allocator);
    var exclude_parts: std.ArrayList([]const u8) = .empty;
    defer exclude_parts.deinit(runtime.allocator);

    var default_name: ?[]const u8 = null;
    for (aliases.items) |alias| if (alias.default) {
        default_name = alias.name;
    };
    const effective_names = selector_names orelse default_name orelse return .{};
    const expression = try Expression.create(runtime.allocator, .union_set, "eager");
    errdefer expression.destroy(runtime.allocator);
    var names = std.mem.tokenizeAny(u8, effective_names, " \t\r\n");
    var matched_any = false;
    while (names.next()) |name| {
        const alias = findAlias(aliases.items, name) orelse return error.UnsupportedSelector;
        try parts.append(runtime.allocator, alias.definition);
        const copied = try alias.expression.?.clone(runtime.allocator);
        expression.children.append(runtime.allocator, copied) catch |err| {
            copied.destroy(runtime.allocator);
            return err;
        };
        if (alias.exclude) |value| try exclude_parts.append(runtime.allocator, value);
        matched_any = true;
    }
    if (!matched_any) return error.UnsupportedSelector;
    if (select) |value| {
        try parts.append(runtime.allocator, value);
        const additional = try expressions.parseCli(runtime.allocator, value);
        expression.children.append(runtime.allocator, additional) catch |err| {
            additional.destroy(runtime.allocator);
            return err;
        };
    }
    if (exclude) |value| try exclude_parts.append(runtime.allocator, value);

    var resolved_expression = expression;
    if (exclude) |value| {
        const excluded = try expressions.parseCli(runtime.allocator, value);
        errdefer excluded.destroy(runtime.allocator);
        resolved_expression = try expressions.difference(runtime.allocator, expression, excluded);
    }
    return .{
        .expression = resolved_expression,
        .select = try joinPartsOrNull(runtime.allocator, " ", parts.items),
        .exclude = try joinPartsOrNull(runtime.allocator, " ", exclude_parts.items),
    };
}

pub fn loadRootSelectorAliases(runtime: Runtime, project_dir: []const u8) !SelectorAliases {
    const path = try project_fs.pathJoin(runtime.allocator, &.{ project_dir, "selectors.yml" });
    const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.MissingSelectorsFile,
        else => return err,
    };
    defer runtime.allocator.free(text);
    return try parseSelectorAliasesText(runtime.allocator, text);
}

pub fn parseSelectorAliasesText(allocator: std.mem.Allocator, text: []const u8) !SelectorAliases {
    var aliases: std.ArrayList(SelectorAlias) = .empty;
    errdefer {
        deinitAliasList(allocator, aliases.items);
        aliases.deinit(allocator);
    }

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

    var default_count: usize = 0;
    for (aliases.items) |alias| if (alias.default) {
        default_count += 1;
    };
    if (default_count > 1) return error.UnsupportedSelector;
    for (aliases.items) |*alias| {
        const expanded = try expandReferences(allocator, aliases.items, alias.definition, 0);
        allocator.free(alias.definition);
        alias.definition = expanded;
        const tree = try expandExpressionReferences(allocator, aliases.items, alias.expression.?, 0);
        alias.expression.?.destroy(allocator);
        alias.expression = tree;
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
    if (definition.exclude_only) return error.UnsupportedSelector;
    const is_default = draft.default;
    const indirect_selection = draft.indirect_selection orelse definition.indirect_selection;
    draft = .{};
    return .{
        .default = is_default,
        .indirect_selection = indirect_selection,
        .expression = definition.expression,
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
    } else if (std.mem.eql(u8, kv.key, "default")) {
        draft.default = try parseBool(value);
        index.* += 1;
    } else if (std.mem.eql(u8, kv.key, "description")) {
        index.* += 1;
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
    _ = allow_composition;
    var primary: ?LoweredDefinition = null;
    errdefer {
        if (primary) |*item| item.deinit(allocator);
    }
    var excludes: std.ArrayList([]const u8) = .empty;
    defer {
        freeStringList(allocator, excludes.items);
        excludes.deinit(allocator);
    }
    var excluded_expression: ?*Expression = null;
    defer if (excluded_expression) |expression| expression.destroy(allocator);
    var indirect_selection: ?[]const u8 = null;
    var parents = false;
    var children = false;
    var childrens_parents = false;
    var parents_depth: ?usize = null;
    var children_depth: ?usize = null;
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
            if (primary != null or method != null or value != null or raw_value.len != 0 or child_start == child_end) return error.UnsupportedSelector;
            primary = try parseDefinitionList(allocator, lines[child_start..child_end], base_indent, kv.key);
        } else if (std.mem.eql(u8, kv.key, "exclude")) {
            if (raw_value.len != 0 or child_start == child_end) return error.UnsupportedSelector;
            var lowered_exclude = try parseDefinitionList(allocator, lines[child_start..child_end], base_indent, "union");
            if (lowered_exclude.exclude != null) {
                lowered_exclude.deinit(allocator);
                return error.UnsupportedSelector;
            }
            if (excluded_expression != null) {
                lowered_exclude.deinit(allocator);
                return error.UnsupportedSelector;
            }
            excluded_expression = lowered_exclude.expression;
            lowered_exclude.expression = null;
            excludes.append(allocator, lowered_exclude.definition) catch |err| {
                lowered_exclude.deinit(allocator);
                return err;
            };
        } else if (std.mem.eql(u8, kv.key, "indirect_selection")) {
            indirect_selection = try parseIndirectSelection(raw_value);
        } else if (std.mem.eql(u8, kv.key, "parents")) {
            parents = try parseBool(raw_value);
        } else if (std.mem.eql(u8, kv.key, "children")) {
            children = try parseBool(raw_value);
        } else if (std.mem.eql(u8, kv.key, "childrens_parents")) {
            childrens_parents = try parseBool(raw_value);
        } else if (std.mem.eql(u8, kv.key, "parents_depth")) {
            parents_depth = std.fmt.parseInt(usize, raw_value, 10) catch return error.UnsupportedSelector;
        } else if (std.mem.eql(u8, kv.key, "children_depth")) {
            children_depth = std.fmt.parseInt(usize, raw_value, 10) catch return error.UnsupportedSelector;
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

    if (primary == null) {
        const excluded_text = try joinPartsOrNull(allocator, " ", excludes.items) orelse return error.UnsupportedSelector;
        errdefer allocator.free(excluded_text);
        const result = LoweredDefinition{ .definition = try allocator.dupe(u8, ""), .exclude = excluded_text, .exclude_only = true, .expression = excluded_expression };
        excluded_expression = null;
        return result;
    }
    var result = primary.?;
    primary = null;
    errdefer result.deinit(allocator);
    if (result.expression.?.kind == .leaf) {
        result.expression.?.indirect_selection = indirect_selection;
        if (parents or children or childrens_parents) {
            if (childrens_parents and (parents or children)) return error.UnsupportedSelector;
            const prefix = if (childrens_parents) try allocator.dupe(u8, "@") else if (parents) if (parents_depth) |depth| try std.fmt.allocPrint(allocator, "{d}+", .{depth}) else try allocator.dupe(u8, "+") else try allocator.dupe(u8, "");
            defer allocator.free(prefix);
            const suffix = if (children) if (children_depth) |depth| try std.fmt.allocPrint(allocator, "+{d}", .{depth}) else try allocator.dupe(u8, "+") else try allocator.dupe(u8, "");
            defer allocator.free(suffix);
            const modified = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, result.definition, suffix });
            errdefer allocator.free(modified);
            try selector.validateSelectorSyntax(modified);
            const modified_value = try allocator.dupe(u8, modified);
            allocator.free(result.definition);
            result.definition = modified;
            allocator.free(result.expression.?.value.?);
            result.expression.?.value = modified_value;
        }
    } else if (indirect_selection != null or parents or children or childrens_parents or parents_depth != null or children_depth != null) return error.UnsupportedSelector;
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
    if (excluded_expression) |excluded| {
        result.expression = try expressions.difference(allocator, result.expression.?, excluded);
        excluded_expression = null;
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
    var group = try Expression.create(allocator, if (std.mem.eql(u8, mode, "intersection")) .intersection else .union_set, "eager");
    errdefer group.destroy(allocator);
    var excluded: ?LoweredDefinition = null;
    defer if (excluded) |*value| value.deinit(allocator);
    var index: usize = 0;
    var item_indent: ?usize = null;
    while (index < lines.len) {
        const line = lines[index];
        if (line.indent <= parent_indent or !std.mem.startsWith(u8, line.trimmed, "-")) return error.UnsupportedSelector;
        if (item_indent) |expected| {
            if (line.indent != expected) return error.UnsupportedSelector;
        } else item_indent = line.indent;
        var end = index + 1;
        while (end < lines.len and !(lines[end].indent == item_indent.? and std.mem.startsWith(u8, lines[end].trimmed, "-"))) : (end += 1) {}
        var lowered = try parseDefinitionListItem(allocator, lines[index..end], item_indent.?);
        var transferred = false;
        defer if (!transferred) lowered.deinit(allocator);
        if (lowered.exclude_only) {
            if (excluded != null) return error.UnsupportedSelector;
            excluded = lowered;
            transferred = true;
        } else {
            const text = if (lowered.exclude) |value| try differenceDefinitions(allocator, lowered.definition, value) else try allocator.dupe(u8, lowered.definition);
            parts.append(allocator, text) catch |err| {
                allocator.free(text);
                return err;
            };
            try group.children.append(allocator, lowered.expression.?);
            lowered.expression = null;
        }
        index = end;
    }
    if (parts.items.len == 0) return error.UnsupportedSelector;
    var combined: []const u8 = try allocator.dupe(u8, parts.items[0]);
    errdefer allocator.free(combined);
    for (parts.items[1..]) |part| {
        const next = if (std.mem.eql(u8, mode, "intersection")) try intersectDefinitions(allocator, combined, part) else try joinTwoParts(allocator, combined, part);
        allocator.free(combined);
        combined = next;
    }
    var exclude_text: ?[]const u8 = null;
    if (excluded) |*value| {
        group = try expressions.difference(allocator, group, value.expression.?);
        value.expression = null;
        exclude_text = value.exclude;
        value.exclude = null;
    }
    return .{ .definition = combined, .exclude = exclude_text, .expression = group };
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

fn expandExpressionReferences(allocator: std.mem.Allocator, aliases: []const SelectorAlias, expression: *const Expression, depth: usize) anyerror!*Expression {
    if (depth > aliases.len) return error.UnsupportedSelector;
    if (expression.kind == .leaf) {
        if (expression.value) |value| if (std.mem.startsWith(u8, value, "selector:")) {
            const alias = findAlias(aliases, value["selector:".len..]) orelse return error.UnsupportedSelector;
            return try expandExpressionReferences(allocator, aliases, alias.expression.?, depth + 1);
        };
        return try expression.clone(allocator);
    }
    const result = try Expression.create(allocator, expression.kind, expression.indirect_selection);
    errdefer result.destroy(allocator);
    for (expression.children.items) |child| {
        const expanded = try expandExpressionReferences(allocator, aliases, child, depth);
        result.children.append(allocator, expanded) catch |err| {
            expanded.destroy(allocator);
            return err;
        };
    }
    return result;
}

fn parseBool(value: []const u8) !bool {
    if (std.mem.eql(u8, value, "true")) return true;
    if (std.mem.eql(u8, value, "false")) return false;
    return error.UnsupportedSelector;
}

fn parseIndirectSelection(value: []const u8) ![]const u8 {
    for ([_][]const u8{ "eager", "cautious", "buildable", "empty" }) |mode| {
        if (std.mem.eql(u8, value, mode)) return mode;
    }
    return error.UnsupportedSelector;
}

// Lower nested YAML set operations to disjunctive normal form. In particular,
// intersection distributes over unions and each nested exclude stays scoped to
// its containing set instead of becoming a global exclusion.
fn intersectDefinitions(allocator: std.mem.Allocator, left: []const u8, right: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer {
        freeStringList(allocator, parts.items);
        parts.deinit(allocator);
    }
    var left_items = std.mem.tokenizeAny(u8, left, " \t\r\n");
    while (left_items.next()) |a| {
        var rhs_clauses = std.mem.tokenizeAny(u8, right, " \t\r\n");
        while (rhs_clauses.next()) |b| {
            if (parts.items.len >= 16384) return error.UnsupportedSelector;
            try parts.append(allocator, try std.fmt.allocPrint(allocator, "{s},{s}", .{ a, b }));
        }
    }
    return try std.mem.join(allocator, " ", parts.items);
}

fn differenceDefinitions(allocator: std.mem.Allocator, include: []const u8, exclude: []const u8) ![]const u8 {
    var combined: []const u8 = try allocator.dupe(u8, include);
    errdefer allocator.free(combined);
    var clauses = std.mem.tokenizeAny(u8, exclude, " \t\r\n");
    while (clauses.next()) |clause| {
        var negative: std.ArrayList([]const u8) = .empty;
        defer {
            freeStringList(allocator, negative.items);
            negative.deinit(allocator);
        }
        var terms = std.mem.splitScalar(u8, clause, ',');
        while (terms.next()) |term| {
            try negative.append(allocator, if (std.mem.startsWith(u8, term, "!")) try allocator.dupe(u8, term[1..]) else try std.fmt.allocPrint(allocator, "!{s}", .{term}));
        }
        const negated = try std.mem.join(allocator, " ", negative.items);
        defer allocator.free(negated);
        const next = try intersectDefinitions(allocator, combined, negated);
        allocator.free(combined);
        combined = next;
    }
    return combined;
}

fn expandReferences(allocator: std.mem.Allocator, aliases: []const SelectorAlias, definition: []const u8, depth: usize) anyerror![]const u8 {
    if (depth > aliases.len) return error.UnsupportedSelector;
    var parts: std.ArrayList([]const u8) = .empty;
    defer {
        freeStringList(allocator, parts.items);
        parts.deinit(allocator);
    }
    var clauses = std.mem.tokenizeAny(u8, definition, " \t\r\n");
    while (clauses.next()) |clause| {
        var combined: ?[]const u8 = null;
        defer if (combined) |value| allocator.free(value);
        var terms = std.mem.splitScalar(u8, clause, ',');
        while (terms.next()) |term| {
            var expanded: []const u8 = undefined;
            const negated = std.mem.startsWith(u8, term, "!");
            const positive = if (negated) term[1..] else term;
            if (std.mem.startsWith(u8, positive, "selector:")) {
                const alias = findAlias(aliases, positive["selector:".len..]) orelse return error.UnsupportedSelector;
                const nested = try expandReferences(allocator, aliases, alias.definition, depth + 1);
                defer allocator.free(nested);
                const scoped = if (alias.exclude) |excluded| try differenceDefinitions(allocator, nested, excluded) else try allocator.dupe(u8, nested);
                defer allocator.free(scoped);
                expanded = if (negated) try differenceDefinitions(allocator, "*", scoped) else try allocator.dupe(u8, scoped);
            } else expanded = try allocator.dupe(u8, term);
            defer allocator.free(expanded);
            const next = if (combined) |value| try intersectDefinitions(allocator, value, expanded) else try allocator.dupe(u8, expanded);
            if (combined) |value| allocator.free(value);
            combined = next;
        }
        if (combined) |value| try parts.append(allocator, try allocator.dupe(u8, value));
    }
    return try std.mem.join(allocator, " ", parts.items);
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
    return .{ .definition = definition, .expression = try expressions.parseCli(allocator, definition) };
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
    if (std.mem.eql(u8, method, "selector")) {
        const definition = try std.fmt.allocPrint(allocator, "selector:{s}", .{value});
        errdefer allocator.free(definition);
        return .{ .definition = definition, .expression = try Expression.leaf(allocator, definition, null) };
    }
    const prefix = yamlLeafMethodPrefix(method) orelse return error.UnsupportedSelector;
    const expression = if (prefix.len == 0)
        try allocator.dupe(u8, value)
    else
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, value });
    errdefer allocator.free(expression);
    try selector.validateSelectorSyntax(expression);
    return .{ .definition = expression, .expression = try Expression.leaf(allocator, expression, null) };
}

fn isSupportedYamlLeafMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "selector") or yamlLeafMethodPrefix(method) != null;
}

fn yamlLeafMethodPrefix(method: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, method, "name") or std.mem.eql(u8, method, "fqn")) return "";
    if (std.mem.eql(u8, method, "package")) return "package:";
    if (std.mem.eql(u8, method, "state")) return "state:";
    if (std.mem.eql(u8, method, "result")) return "result:";
    if (std.mem.eql(u8, method, "source_status")) return "source_status:";
    if (std.mem.eql(u8, method, "config.materialized")) return "config.materialized:";
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
    if (alias.expression) |expression| expression.destroy(allocator);
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
        \\      method: invalid_state
        \\      value: modified
        \\
    ));
    try std.testing.expectError(error.UnsupportedSelector, parseSelectorAliasesText(allocator,
        \\selectors:
        \\  - name: packaged
        \\    definition:
        \\      method: invalid_package
        \\      value: this
        \\
    ));
    try std.testing.expectError(error.UnsupportedSelector, parseSelectorAliasesText(allocator,
        \\selectors:
        \\  - name: recursive
        \\    definition:
        \\      union:
        \\        - invalid_union:
        \\            - customers
        \\
    ));
    try std.testing.expectError(error.UnsupportedSelector, parseSelectorAliasesText(allocator,
        \\selectors:
        \\  - name: indirect
        \\    definition:
        \\      union:
        \\        - customers
        \\      indirect_selection: invalid_mode
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
        \\      method: invalid_package
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
        \\    definition: state:unsupported
        \\
    ));
}

test "yaml default selectors and references preserve nested set operation scope" {
    const allocator = std.testing.allocator;
    var aliases = try parseSelectorAliasesText(allocator,
        \\selectors:
        \\  - name: base
        \\    definition:
        \\      union:
        \\        - a
        \\        - b
        \\  - name: chosen
        \\    default: true
        \\    definition:
        \\      intersection:
        \\        - method: selector
        \\          value: base
        \\        - union:
        \\            - a
        \\            - c
    );
    defer aliases.deinit(allocator);
    try std.testing.expect(aliases.items[1].default);
    try std.testing.expectEqualStrings("a,a b,a a,c b,c", aliases.items[1].definition);
}

test "yaml reference cycles and multiple defaults are errors" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedSelector, parseSelectorAliasesText(allocator,
        \\selectors:
        \\  - name: loop
        \\    definition:
        \\      method: selector
        \\      value: loop
    ));
    try std.testing.expectError(error.UnsupportedSelector, parseSelectorAliasesText(allocator,
        \\selectors:
        \\  - name: one
        \\    default: true
        \\    definition: a
        \\  - name: two
        \\    default: true
        \\    definition: b
    ));
}
