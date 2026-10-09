//! YAML syntax uses the pinned libyaml event scanner. Construction, SafeLoader
//! resolution, aliases, merges and document ownership are native Zig.
//! Values use JSON's model: dates/timestamps are ISO strings, binary values are
//! canonical base64 strings, sets are arrays, and ordered pairs are two-item arrays.
const std = @import("std");
const c = @cImport({
    @cInclude("yaml.h");
});

pub const Value = std.json.Value;
pub const Diagnostic = struct {
    line: usize = 1,
    column: usize = 1,
    offset: usize = 0,
    message: []const u8 = "",
};

pub const Document = struct {
    arena: *std.heap.ArenaAllocator,
    owner: std.mem.Allocator,
    value: Value,
    // The JSON value model represents YAML dates as strings; retain scalar
    // provenance for consumers whose schemas distinguish a date from a string.
    date_strings: []const []const u8 = &.{},

    pub fn isDate(self: *const Document, value: Value) bool {
        if (value != .string) return false;
        for (self.date_strings) |date| if (date.ptr == value.string.ptr) return true;
        return false;
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.owner.destroy(self.arena);
        self.* = undefined;
    }
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) !Document {
    return parseWithDiagnostics(allocator, text, null);
}

/// Shared scalar resolution for runtime SafeLoader values. Project documents
/// retain their JSON representation while context callers preserve YAML types.
pub const Scalar = struct { value: Value, tag: []const u8, merge: bool };
pub fn resolveScalar(allocator: std.mem.Allocator, text: []const u8, authored_tag: ?[]const u8, plain: bool, key_position: bool) !Scalar {
    var parser = Parser{ .allocator = allocator, .diagnostic = null, .anchors = std.StringHashMap(Anchor).init(allocator) };
    defer parser.anchors.deinit();
    const tag = if (authored_tag) |provided| if (eq(provided, "!")) implicitTag(text) else provided else if (plain) implicitTag(text) else "str";
    const result = try parser.scalar(text, authored_tag, plain, key_position);
    return .{ .value = result.value, .tag = tag, .merge = result.merge };
}

pub fn resolvesAsString(text: []const u8) bool {
    return isTag(implicitTag(text), "str");
}

pub fn parseWithDiagnostics(allocator: std.mem.Allocator, text: []const u8, diagnostic: ?*Diagnostic) !Document {
    if (diagnostic) |out| out.* = .{};
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }
    var parser: Parser = .{ .allocator = arena.allocator(), .diagnostic = diagnostic, .anchors = std.StringHashMap(Anchor).init(arena.allocator()) };
    if (c.yaml_parser_initialize(&parser.syntax) == 0) return error.OutOfMemory;
    defer c.yaml_parser_delete(&parser.syntax);
    defer if (parser.has_event) c.yaml_event_delete(&parser.event);
    c.yaml_parser_set_input_string(&parser.syntax, text.ptr, text.len);
    try parser.next();
    if (parser.event.type != c.YAML_STREAM_START_EVENT) return parser.fail("expected YAML stream", error.InvalidYaml);
    try parser.next();
    var value: Value = .null;
    if (parser.event.type == c.YAML_DOCUMENT_START_EVENT) {
        try parser.next();
        value = (try parser.node(0, false)).value;
        if (parser.event.type != c.YAML_DOCUMENT_END_EVENT) return parser.fail("expected end of YAML document", error.InvalidYaml);
        try parser.next();
    }
    if (parser.event.type != c.YAML_STREAM_END_EVENT) return parser.fail("expected one YAML document; multiple documents are not supported", error.YamlMultipleDocuments);
    return .{ .arena = arena, .owner = allocator, .value = value, .date_strings = parser.date_strings.items };
}

const Node = struct { value: Value, merge: bool = false, mapping_keys: ?[]const Value = null };
const Anchor = struct { complete: bool = false, node: Node = .{ .value = .null } };

const Parser = struct {
    allocator: std.mem.Allocator,
    syntax: c.yaml_parser_t = undefined,
    event: c.yaml_event_t = undefined,
    has_event: bool = false,
    events: usize = 0,
    diagnostic: ?*Diagnostic,
    anchors: std.StringHashMap(Anchor),
    date_strings: std.ArrayList([]const u8) = .empty,

    fn next(self: *Parser) !void {
        if (self.has_event) c.yaml_event_delete(&self.event);
        self.has_event = false;
        self.events += 1;
        if (self.events > 1000000) return self.fail("YAML event count exceeds the document limit", error.YamlLimitExceeded);
        if (c.yaml_parser_parse(&self.syntax, &self.event) == 0) {
            if (self.diagnostic) |out| out.* = .{
                .line = self.syntax.problem_mark.line + 1,
                .column = self.syntax.problem_mark.column + 1,
                .offset = self.syntax.problem_mark.index,
                .message = if (self.syntax.problem != null) std.mem.span(self.syntax.problem) else "invalid YAML syntax",
            };
            return if (self.syntax.@"error" == c.YAML_MEMORY_ERROR) error.OutOfMemory else error.InvalidYaml;
        }
        self.has_event = true;
    }

    fn fail(self: *Parser, message: []const u8, failure: anyerror) anyerror {
        if (self.diagnostic) |out| out.* = .{
            .line = if (self.has_event) self.event.start_mark.line + 1 else self.syntax.mark.line + 1,
            .column = if (self.has_event) self.event.start_mark.column + 1 else self.syntax.mark.column + 1,
            .offset = if (self.has_event) self.event.start_mark.index else self.syntax.mark.index,
            .message = message,
        };
        return failure;
    }

    fn registerAnchor(self: *Parser, raw: [*c]const u8) !?[]const u8 {
        if (raw == null) return null;
        const name = try self.allocator.dupe(u8, std.mem.span(raw));
        if (self.anchors.contains(name)) return self.fail("duplicate YAML anchor", error.YamlDuplicateAnchor);
        try self.anchors.put(name, .{});
        return name;
    }

    fn completeAnchor(self: *Parser, anchor: ?[]const u8, result: Node) void {
        if (anchor) |name| self.anchors.getPtr(name).?.* = .{ .complete = true, .node = result };
    }

    fn node(self: *Parser, depth: usize, key_position: bool) anyerror!Node {
        if (depth > 256) return self.fail("YAML nesting exceeds the document limit", error.YamlLimitExceeded);
        switch (self.event.type) {
            c.YAML_ALIAS_EVENT => {
                const name = std.mem.span(self.event.data.alias.anchor);
                const anchor = self.anchors.get(name) orelse return self.fail("undefined YAML alias", error.YamlUnknownAlias);
                if (!anchor.complete) return self.fail("recursive YAML aliases cannot be represented in project data", error.YamlRecursiveAlias);
                if (anchor.node.merge and !key_position) return self.fail("merge tag is valid only as a mapping key", error.YamlUnsupportedTag);
                const result = anchor.node;
                try self.next();
                return result;
            },
            c.YAML_SCALAR_EVENT => {
                const anchor = try self.registerAnchor(self.event.data.scalar.anchor);
                const scalar_text = self.event.data.scalar.value[0..self.event.data.scalar.length];
                const explicit_tag = if (self.event.data.scalar.tag != null) std.mem.span(self.event.data.scalar.tag) else null;
                const plain = self.event.data.scalar.style == c.YAML_PLAIN_SCALAR_STYLE;
                const result = self.scalar(scalar_text, explicit_tag, plain, key_position) catch |err| return self.fail("invalid YAML scalar or unsupported safe tag", err);
                const tag = explicit_tag orelse if (plain) implicitTag(scalar_text) else "str";
                if (isTag(tag, "timestamp") and result.value == .string and result.value.string.len == 10) try self.date_strings.append(self.allocator, result.value.string);
                self.completeAnchor(anchor, result);
                try self.next();
                return result;
            },
            c.YAML_SEQUENCE_START_EVENT => return self.sequence(depth),
            c.YAML_MAPPING_START_EVENT => return self.mapping(depth),
            else => return self.fail("expected YAML scalar, sequence or mapping", error.InvalidYaml),
        }
    }

    fn sequence(self: *Parser, depth: usize) !Node {
        const anchor = try self.registerAnchor(self.event.data.sequence_start.anchor);
        const tag = if (self.event.data.sequence_start.tag != null) try self.allocator.dupe(u8, std.mem.span(self.event.data.sequence_start.tag)) else null;
        if (tag != null and !isTag(tag.?, "seq") and !isTag(tag.?, "omap") and !isTag(tag.?, "pairs") and !eq(tag.?, "!")) return self.fail("tag requires a different YAML node kind", error.YamlUnsupportedTag);
        var values: std.array_list.Managed(Value) = .init(self.allocator);
        try self.next();
        while (self.event.type != c.YAML_SEQUENCE_END_EVENT) {
            if (self.event.type == c.YAML_DOCUMENT_END_EVENT or self.event.type == c.YAML_STREAM_END_EVENT) return self.fail("unterminated YAML sequence", error.InvalidYaml);
            const child_node = try self.node(depth + 1, false);
            const child = child_node.value;
            if (tag != null and (isTag(tag.?, "omap") or isTag(tag.?, "pairs"))) {
                if (child != .object or child.object.count() != 1) return self.fail("ordered pairs require mappings with exactly one entry", error.InvalidYamlScalar);
                var iterator = child.object.iterator();
                const item = iterator.next().?;
                var pair: std.array_list.Managed(Value) = .init(self.allocator);
                try pair.append(if (child_node.mapping_keys) |keys| keys[0] else .{ .string = item.key_ptr.* });
                try pair.append(item.value_ptr.*);
                try values.append(.{ .array = pair });
            } else try values.append(child);
        }
        const result: Node = .{ .value = .{ .array = values } };
        self.completeAnchor(anchor, result);
        try self.next();
        return result;
    }

    fn mapping(self: *Parser, depth: usize) !Node {
        const anchor = try self.registerAnchor(self.event.data.mapping_start.anchor);
        const tag = if (self.event.data.mapping_start.tag != null) try self.allocator.dupe(u8, std.mem.span(self.event.data.mapping_start.tag)) else null;
        if (tag != null and !isTag(tag.?, "map") and !isTag(tag.?, "set") and !eq(tag.?, "!")) return self.fail("tag requires a different YAML node kind", error.YamlUnsupportedTag);
        var inherited: std.json.ObjectMap = .empty;
        var explicit: std.json.ObjectMap = .empty;
        var typed_keys = std.StringHashMap(Value).init(self.allocator);
        try self.next();
        while (self.event.type != c.YAML_MAPPING_END_EVENT) {
            const key = try self.node(depth + 1, true);
            const value = (try self.node(depth + 1, false)).value;
            if (key.merge) {
                try self.merge(&inherited, value);
            } else {
                const key_text = keyString(self.allocator, key.value) catch |err| return self.fail("YAML mapping keys must be hashable scalars", err);
                try explicit.put(self.allocator, key_text, value);
                try typed_keys.put(key_text, key.value);
            }
        }
        var iterator = explicit.iterator();
        while (iterator.next()) |item| try inherited.put(self.allocator, item.key_ptr.*, item.value_ptr.*);
        var value: Value = .{ .object = inherited };
        var mapping_keys: std.array_list.Managed(Value) = .init(self.allocator);
        var mapping_iterator = inherited.iterator();
        while (mapping_iterator.next()) |item| try mapping_keys.append(typed_keys.get(item.key_ptr.*) orelse .{ .string = item.key_ptr.* });
        if (tag != null and isTag(tag.?, "set")) {
            value = .{ .array = mapping_keys };
        }
        const result: Node = .{ .value = value, .mapping_keys = mapping_keys.items };
        self.completeAnchor(anchor, result);
        try self.next();
        return result;
    }

    fn merge(self: *Parser, target: *std.json.ObjectMap, source: Value) !void {
        switch (source) {
            .object => {
                var iterator = source.object.iterator();
                while (iterator.next()) |item| if (!target.contains(item.key_ptr.*)) try target.put(self.allocator, item.key_ptr.*, item.value_ptr.*);
            },
            .array => for (source.array.items) |item| {
                if (item != .object) return self.fail("YAML merge sequence entries must be mappings", error.YamlInvalidMerge);
                try self.merge(target, item);
            },
            else => return self.fail("YAML merge requires a mapping or sequence of mappings", error.YamlInvalidMerge),
        }
    }

    fn scalar(self: *Parser, text: []const u8, explicit_tag: ?[]const u8, plain: bool, key_position: bool) !Node {
        // YAML's non-specific ! tag requests implicit resolution even on a
        // quoted scalar, as the pinned Core SafeLoader does.
        if (explicit_tag != null and eq(explicit_tag.?, "!")) return self.scalar(text, null, true, key_position);
        const tag = explicit_tag orelse if (plain) implicitTag(text) else "str";
        if (isTag(tag, "merge") or isTag(tag, "value")) {
            if (!key_position) return error.YamlUnsupportedTag;
            return .{ .value = .{ .string = try self.allocator.dupe(u8, text) }, .merge = isTag(tag, "merge") };
        }
        const value: Value = if (eq(tag, "!") or isTag(tag, "str")) .{ .string = try self.allocator.dupe(u8, text) } else if (isTag(tag, "null")) .null else if (isTag(tag, "bool")) .{ .bool = try parseBoolean(text) } else if (isTag(tag, "int")) try parseInteger(self.allocator, text) else if (isTag(tag, "float")) .{ .float = try parseFloat(self.allocator, text) } else if (isTag(tag, "timestamp")) .{ .string = try timestamp(self.allocator, text) } else if (isTag(tag, "binary")) .{ .string = try binary(self.allocator, text) } else return error.YamlUnsupportedTag;
        return .{ .value = value };
    }
};

fn isTag(tag: []const u8, name: []const u8) bool {
    return eq(tag, name) or (std.mem.startsWith(u8, tag, "tag:yaml.org,2002:") and eq(tag[18..], name));
}

fn implicitTag(text: []const u8) []const u8 {
    if (text.len == 0 or eq(text, "~") or caseVariant(text, "null")) return "null";
    for ([_][]const u8{ "true", "false", "yes", "no", "on", "off" }) |word| if (caseVariant(text, word)) return "bool";
    if (integerShape(text)) return "int";
    if (floatShape(text)) return "float";
    if (timestampShape(text)) return "timestamp";
    if (eq(text, "<<")) return "merge";
    if (eq(text, "=")) return "value";
    return "str";
}

fn caseVariant(text: []const u8, word: []const u8) bool {
    if (text.len != word.len) return false;
    var lower = true;
    var upper = true;
    var title = true;
    var first_letter = true;
    for (text, word, 0..) |a, b, index| {
        lower = lower and a == b;
        upper = upper and a == std.ascii.toUpper(b);
        _ = index;
        title = title and a == if (first_letter and std.ascii.isAlphabetic(b)) std.ascii.toUpper(b) else b;
        if (std.ascii.isAlphabetic(b)) first_letter = false;
    }
    return lower or upper or title;
}

fn parseBoolean(text: []const u8) !bool {
    for ([_][]const u8{ "true", "yes", "on" }) |word| if (std.ascii.eqlIgnoreCase(text, word)) return true;
    for ([_][]const u8{ "false", "no", "off" }) |word| if (std.ascii.eqlIgnoreCase(text, word)) return false;
    return error.InvalidYamlScalar;
}

fn unsigned(text: []const u8) []const u8 {
    return if (text.len != 0 and (text[0] == '+' or text[0] == '-')) text[1..] else text;
}

fn digits(text: []const u8, base: u8, underscores: bool) bool {
    if (text.len == 0) return false;
    for (text) |ch| {
        if (underscores and ch == '_') continue;
        const digit = std.fmt.charToDigit(ch, base) catch return false;
        _ = digit;
    }
    return true;
}

fn integerShape(raw: []const u8) bool {
    const text = unsigned(raw);
    if (text.len == 0) return false;
    if (std.mem.startsWith(u8, text, "0b")) return digits(text[2..], 2, true);
    if (std.mem.startsWith(u8, text, "0x")) return digits(text[2..], 16, true);
    if (text[0] == '0') return if (text.len == 1) true else digits(text[1..], 8, true);
    if (text[0] < '1' or text[0] > '9') return false;
    var pieces = std.mem.splitScalar(u8, text, ':');
    if (!digits(pieces.next().?, 10, true)) return false;
    while (pieces.next()) |piece| {
        if (!digits(piece, 10, false) or piece.len > 2) return false;
        const value = std.fmt.parseInt(u8, piece, 10) catch return false;
        if (value >= 60) return false;
    }
    return true;
}

fn floatShape(raw: []const u8) bool {
    const text = unsigned(raw);
    if (caseVariant(text, ".inf") or (raw.len != 0 and raw[0] != '-' and raw[0] != '+' and (eq(text, ".nan") or eq(text, ".NaN") or eq(text, ".NAN")))) return true;
    const dot = std.mem.indexOfScalar(u8, text, '.') orelse return false;
    var end = text.len;
    if (std.mem.indexOfAny(u8, text, "eE")) |exponent| {
        if (std.mem.indexOfScalar(u8, text, ':') != null or exponent <= dot or exponent + 2 >= text.len or (text[exponent + 1] != '+' and text[exponent + 1] != '-')) return false;
        if (!digits(text[exponent + 2 ..], 10, false)) return false;
        end = exponent;
    }
    if (dot == 0) return digits(text[1..end], 10, true);
    if (text[0] < '0' or text[0] > '9') return false;
    if (std.mem.indexOfScalar(u8, text[0..dot], ':') != null) {
        if (!sexagesimalShape(text[0..dot])) return false;
    } else if (!digits(text[0..dot], 10, true)) return false;
    return dot + 1 == end or digits(text[dot + 1 .. end], 10, true);
}

fn sexagesimalShape(text: []const u8) bool {
    var pieces = std.mem.splitScalar(u8, text, ':');
    if (!digits(pieces.next().?, 10, true)) return false;
    while (pieces.next()) |piece| {
        if (!digits(piece, 10, false) or piece.len > 2) return false;
        if ((std.fmt.parseInt(u8, piece, 10) catch return false) >= 60) return false;
    }
    return true;
}

fn removeUnderscores(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (std.mem.trim(u8, text, " \t\r\n")) |ch| if (ch != '_') try out.append(allocator, ch);
    return out.toOwnedSlice(allocator);
}

fn parseInteger(allocator: std.mem.Allocator, raw: []const u8) !Value {
    const cleaned = try removeUnderscores(allocator, raw);
    const text = unsigned(cleaned);
    if (text.len == 0) return error.InvalidYamlScalar;
    var number = try std.math.big.int.Managed.init(allocator);
    var base: u8 = 10;
    var start: usize = 0;
    if (std.mem.startsWith(u8, text, "0b")) {
        base = 2;
        start = 2;
    } else if (std.mem.startsWith(u8, text, "0x")) {
        base = 16;
        start = 2;
    } else if (text[0] == '0' and text.len > 1) base = 8;
    if (std.mem.indexOfScalar(u8, text, ':') != null) {
        var pieces = std.mem.splitScalar(u8, text, ':');
        var multiplier = try std.math.big.int.Managed.initSet(allocator, 60);
        try number.set(0);
        while (pieces.next()) |piece| {
            const digit = std.fmt.parseInt(u64, piece, 10) catch return error.InvalidYamlScalar;
            try number.mul(&number, &multiplier);
            try number.addScalar(&number, digit);
        }
    } else number.setString(base, text[start..]) catch return error.InvalidYamlScalar;
    number.setSign(cleaned[0] != '-');
    const decimal = try number.toString(allocator, 10, .lower);
    const small = std.fmt.parseInt(i64, decimal, 10) catch return .{ .number_string = decimal };
    return .{ .integer = small };
}

fn parseFloat(allocator: std.mem.Allocator, raw: []const u8) !f64 {
    const cleaned = try removeUnderscores(allocator, raw);
    const text = unsigned(cleaned);
    if (std.ascii.eqlIgnoreCase(text, ".inf")) return if (cleaned[0] == '-') -std.math.inf(f64) else std.math.inf(f64);
    if (std.ascii.eqlIgnoreCase(text, ".nan")) return std.math.nan(f64);
    if (std.mem.indexOfScalar(u8, text, ':') != null) {
        var pieces = std.mem.splitScalar(u8, text, ':');
        var result: f64 = 0;
        while (pieces.next()) |piece| result = result * 60 + (std.fmt.parseFloat(f64, piece) catch return error.InvalidYamlScalar);
        return if (cleaned[0] == '-') -result else result;
    }
    return std.fmt.parseFloat(f64, cleaned) catch error.InvalidYamlScalar;
}

const Timestamp = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: ?u8 = null,
    minute: u8 = 0,
    second: u8 = 0,
    micros: u32 = 0,
    timezone_minutes: ?i16 = null,
};

fn timestampParts(text: []const u8) !Timestamp {
    var cursor: usize = 0;
    const year = try dateNumber(text, &cursor, 4, 4);
    try consume(text, &cursor, '-');
    const month = try dateNumber(text, &cursor, 1, 2);
    try consume(text, &cursor, '-');
    const day = try dateNumber(text, &cursor, 1, 2);
    var result: Timestamp = .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
    if (cursor == text.len) return result;
    if (text[cursor] == 'T' or text[cursor] == 't') cursor += 1 else {
        const start = cursor;
        while (cursor < text.len and (text[cursor] == ' ' or text[cursor] == '\t')) cursor += 1;
        if (start == cursor) return error.InvalidYamlScalar;
    }
    result.hour = @intCast(try dateNumber(text, &cursor, 1, 2));
    try consume(text, &cursor, ':');
    result.minute = @intCast(try dateNumber(text, &cursor, 2, 2));
    try consume(text, &cursor, ':');
    result.second = @intCast(try dateNumber(text, &cursor, 2, 2));
    if (cursor < text.len and text[cursor] == '.') {
        cursor += 1;
        const start = cursor;
        while (cursor < text.len and std.ascii.isDigit(text[cursor])) cursor += 1;
        const fraction = text[start..@min(cursor, start + 6)];
        if (fraction.len != 0) result.micros = std.fmt.parseInt(u32, fraction, 10) catch return error.InvalidYamlScalar;
        for (fraction.len..6) |_| result.micros *= 10;
    }
    while (cursor < text.len and (text[cursor] == ' ' or text[cursor] == '\t')) cursor += 1;
    if (cursor == text.len) return result;
    if (text[cursor] == 'Z') {
        cursor += 1;
        result.timezone_minutes = 0;
    } else if (text[cursor] == '+' or text[cursor] == '-') {
        const negative = text[cursor] == '-';
        cursor += 1;
        const timezone_hour = try dateNumber(text, &cursor, 1, 2);
        var timezone_minute: u16 = 0;
        if (cursor < text.len and text[cursor] == ':') {
            cursor += 1;
            timezone_minute = try dateNumber(text, &cursor, 2, 2);
        }
        const offset: i16 = @intCast(timezone_hour * 60 + timezone_minute);
        result.timezone_minutes = if (negative) -offset else offset;
    } else return error.InvalidYamlScalar;
    if (cursor != text.len) return error.InvalidYamlScalar;
    return result;
}

fn timestampShape(text: []const u8) bool {
    if (text.len < 10 or text[4] != '-') return false;
    const parts = timestampParts(text) catch return false;
    if (parts.hour == null) return text.len == 10 and text[7] == '-';
    return true;
}

fn timestamp(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const value = try timestampParts(text);
    if (value.year == 0 or value.month == 0 or value.month > 12 or value.day == 0) return error.InvalidYamlScalar;
    const days = [_]u8{ 31, if (value.year % 4 == 0 and (value.year % 100 != 0 or value.year % 400 == 0)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (value.day > days[value.month - 1]) return error.InvalidYamlScalar;
    var out: std.Io.Writer.Allocating = .init(allocator);
    try out.writer.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ value.year, value.month, value.day });
    if (value.hour) |hour| {
        if (hour > 23 or value.minute > 59 or value.second > 59) return error.InvalidYamlScalar;
        try out.writer.print("T{d:0>2}:{d:0>2}:{d:0>2}", .{ hour, value.minute, value.second });
        if (value.micros != 0) try out.writer.print(".{d:0>6}", .{value.micros});
        if (value.timezone_minutes) |timezone| {
            if (@abs(timezone) >= 24 * 60) return error.InvalidYamlScalar;
            try out.writer.print("{c}{d:0>2}:{d:0>2}", .{ if (timezone < 0) @as(u8, '-') else @as(u8, '+'), @divTrunc(@abs(timezone), 60), @mod(@abs(timezone), 60) });
        }
    }
    return out.toOwnedSlice();
}

fn dateNumber(text: []const u8, cursor: *usize, minimum: usize, maximum: usize) !u16 {
    const start = cursor.*;
    while (cursor.* < text.len and std.ascii.isDigit(text[cursor.*]) and cursor.* - start < maximum) cursor.* += 1;
    if (cursor.* - start < minimum) return error.InvalidYamlScalar;
    return std.fmt.parseInt(u16, text[start..cursor.*], 10) catch error.InvalidYamlScalar;
}

fn consume(text: []const u8, cursor: *usize, expected: u8) !void {
    if (cursor.* >= text.len or text[cursor.*] != expected) return error.InvalidYamlScalar;
    cursor.* += 1;
}

fn binary(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var cleaned: std.ArrayList(u8) = .empty;
    for (text) |ch| if (!std.ascii.isWhitespace(ch)) try cleaned.append(allocator, ch);
    const codec = std.base64.standard;
    const length = codec.Decoder.calcSizeForSlice(cleaned.items) catch return error.InvalidYamlScalar;
    const decoded = try allocator.alloc(u8, length);
    codec.Decoder.decode(decoded, cleaned.items) catch return error.InvalidYamlScalar;
    const encoded = try allocator.alloc(u8, codec.Encoder.calcSize(length));
    return codec.Encoder.encode(encoded, decoded);
}

fn keyString(allocator: std.mem.Allocator, value: Value) ![]const u8 {
    return switch (value) {
        .string, .number_string => |text| text,
        .null => "null",
        .bool => |boolean| if (boolean) "true" else "false",
        .integer => |integer| std.fmt.allocPrint(allocator, "{d}", .{integer}),
        .float => |float| std.fmt.allocPrint(allocator, "{d}", .{float}),
        else => error.YamlUnhashableKey,
    };
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "native YAML composes block flow multiline Unicode and typed values" {
    var document = try parse(std.testing.allocator,
        \\name: demo
        \\flow: {enabled: yes, count: 0x10, values: [1, 1.25, null, "on"]}
        \\literal: |-
        \\  first
        \\  second
        \\folded: >-
        \\  first
        \\  second
        \\unicode: "\u00E9 \U0001F600"
        \\quoted: !!str 123
    );
    defer document.deinit();
    const root = document.value.object;
    try std.testing.expectEqualStrings("demo", root.get("name").?.string);
    const flow = root.get("flow").?.object;
    try std.testing.expect(flow.get("enabled").?.bool);
    try std.testing.expectEqual(@as(i64, 16), flow.get("count").?.integer);
    try std.testing.expectEqualStrings("first\nsecond", root.get("literal").?.string);
    try std.testing.expectEqualStrings("first second", root.get("folded").?.string);
    try std.testing.expectEqualStrings("é 😀", root.get("unicode").?.string);
    try std.testing.expectEqualStrings("123", root.get("quoted").?.string);
}

test "native YAML aliases and merge precedence follow Core SafeLoader" {
    var document = try parse(std.testing.allocator,
        \\defaults: &defaults {name: first, enabled: true}
        \\other: &other {name: second, count: 2}
        \\combined:
        \\  <<: [*defaults, *other]
        \\  enabled: false
        \\  nested: *defaults
        \\  "<<": literal
    );
    defer document.deinit();
    const combined = document.value.object.get("combined").?.object;
    try std.testing.expectEqualStrings("first", combined.get("name").?.string);
    try std.testing.expect(!combined.get("enabled").?.bool);
    try std.testing.expectEqual(@as(i64, 2), combined.get("count").?.integer);
    try std.testing.expectEqualStrings("first", combined.get("nested").?.object.get("name").?.string);
    try std.testing.expectEqualStrings("literal", combined.get("<<").?.string);
}

test "native YAML scalar resolution reproduces YAML 1.1 Core distinctions" {
    var document = try parse(std.testing.allocator,
        \\[yes, NO, On, y, tRuE, 0123, 08, 0b101, 1:20, 1.0e+3, 1e3, 1.0e3, .inf, -.Inf, .NaN, 99999999999999999999999999, 2020-01-02, 2020-01-02T03:04:05.1Z]
    );
    defer document.deinit();
    const values = document.value.array.items;
    try std.testing.expect(values[0].bool);
    try std.testing.expect(!values[1].bool);
    try std.testing.expect(values[2].bool);
    try std.testing.expectEqualStrings("y", values[3].string);
    try std.testing.expectEqualStrings("tRuE", values[4].string);
    try std.testing.expectEqual(@as(i64, 83), values[5].integer);
    try std.testing.expectEqualStrings("08", values[6].string);
    try std.testing.expectEqual(@as(i64, 5), values[7].integer);
    try std.testing.expectEqual(@as(i64, 80), values[8].integer);
    try std.testing.expectEqual(@as(f64, 1000), values[9].float);
    try std.testing.expectEqualStrings("1e3", values[10].string);
    try std.testing.expectEqualStrings("1.0e3", values[11].string);
    try std.testing.expect(std.math.isPositiveInf(values[12].float));
    try std.testing.expect(std.math.isNegativeInf(values[13].float));
    try std.testing.expect(std.math.isNan(values[14].float));
    try std.testing.expectEqualStrings("99999999999999999999999999", values[15].number_string);
    try std.testing.expectEqualStrings("2020-01-02", values[16].string);
    try std.testing.expectEqualStrings("2020-01-02T03:04:05.100000+00:00", values[17].string);
}

test "native YAML safe tags and diagnostics reject unsafe or malformed construction" {
    var tagged = try parse(std.testing.allocator, "{binary: !!binary SGVsbG8=, pairs: !!pairs [{a: 1}, {b: 2}], members: !!set {a: null, b: null}}\n");
    defer tagged.deinit();
    try std.testing.expectEqualStrings("SGVsbG8=", tagged.value.object.get("binary").?.string);
    try std.testing.expectEqual(@as(usize, 2), tagged.value.object.get("pairs").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 2), tagged.value.object.get("members").?.array.items.len);
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidYaml, parseWithDiagnostics(std.testing.allocator, "name: demo\ninvalid: [1,\n", &diagnostic));
    try std.testing.expectEqual(@as(usize, 3), diagnostic.line);
    try std.testing.expect(diagnostic.message.len != 0);
    try std.testing.expectError(error.YamlUnknownAlias, parse(std.testing.allocator, "value: *missing"));
    try std.testing.expectError(error.YamlDuplicateAnchor, parse(std.testing.allocator, "a: &same 1\nb: &same 2"));
    try std.testing.expectError(error.YamlRecursiveAlias, parse(std.testing.allocator, "a: &same [*same]"));
    try std.testing.expectError(error.YamlInvalidMerge, parse(std.testing.allocator, "value: {<<: 1}"));
    try std.testing.expectError(error.YamlUnsupportedTag, parse(std.testing.allocator, "value: !!python/object {}"));
    try std.testing.expectError(error.YamlMultipleDocuments, parse(std.testing.allocator, "---\na: 1\n---\nb: 2"));
    try std.testing.expectError(error.InvalidYamlScalar, parse(std.testing.allocator, "value: 2021-02-29"));
}

test "owned YAML collections retain stable allocators after parse returns" {
    var document = try parse(std.testing.allocator, "[]");
    defer document.deinit();
    for (0..100) |index| try document.value.array.append(.{ .integer = @intCast(index) });
    try std.testing.expectEqual(@as(usize, 100), document.value.array.items.len);
    try std.testing.expectEqual(@as(i64, 99), document.value.array.items[99].integer);
}
