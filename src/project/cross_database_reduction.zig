//! Conservative, database-free classification of declared source projections.
//! SQL with an unproved projection requires the explicit raw-extraction policy.
const std = @import("std");

const Token = struct {
    text: []const u8,
    kind: enum { word, identifier, literal, number, symbol },
    depth: usize,
    fn word(self: Token, value: []const u8) bool {
        return self.kind == .word and std.ascii.eqlIgnoreCase(self.text, value);
    }
    fn symbol(self: Token, value: u8) bool {
        return self.kind == .symbol and self.text.len == 1 and self.text[0] == value;
    }
};

/// Deliberately does not infer reductions through CTEs, set operations or
/// subqueries. These remain usable with allow_raw_extract. Simple explicit
/// columns, scalar expressions and count(*) are provable projections without
/// opening a connection or guessing source schema. Wildcards remain raw even
/// when a WHERE clause is present: a full-width query is not a proven projection.
pub fn requiresRawAuthorization(allocator: std.mem.Allocator, sql: []const u8) !bool {
    var tokens: std.ArrayList(Token) = .empty;
    defer tokens.deinit(allocator);
    var at: usize = 0;
    var depth: usize = 0;
    while (at < sql.len) {
        const start = at;
        const char = sql[at];
        if (std.ascii.isWhitespace(char)) {
            at += 1;
            continue;
        }
        if (std.mem.startsWith(u8, sql[at..], "--")) {
            at = if (std.mem.indexOfScalarPos(u8, sql, at, '\n')) |end| end else sql.len;
            continue;
        }
        if (std.mem.startsWith(u8, sql[at..], "/*")) {
            at += 2;
            var nested: usize = 1;
            while (at < sql.len and nested != 0) {
                if (std.mem.startsWith(u8, sql[at..], "/*")) {
                    nested += 1;
                    at += 2;
                } else if (std.mem.startsWith(u8, sql[at..], "*/")) {
                    nested -= 1;
                    at += 2;
                } else at += 1;
            }
            if (nested != 0) return true;
            continue;
        }
        var kind: @FieldType(Token, "kind") = .symbol;
        if (char == '\'' or char == '"') {
            kind = if (char == '\'') .literal else .identifier;
            at += 1;
            var closed = false;
            while (at < sql.len) {
                if (sql[at] == char) {
                    at += 1;
                    if (at < sql.len and sql[at] == char) {
                        at += 1;
                        continue;
                    }
                    closed = true;
                    break;
                }
                // E-prefixed PostgreSQL strings use backslash escaping.
                if (char == '\'' and sql[at] == '\\' and start != 0 and (sql[start - 1] == 'e' or sql[start - 1] == 'E')) {
                    at += @min(@as(usize, 2), sql.len - at);
                } else at += 1;
            }
            if (!closed) return true;
        } else if (char == '$') {
            var end = at + 1;
            while (end < sql.len and (std.ascii.isAlphanumeric(sql[end]) or sql[end] == '_')) end += 1;
            if (end == sql.len or sql[end] != '$') return true;
            const tag = sql[at .. end + 1];
            at = (std.mem.indexOfPos(u8, sql, end + 1, tag) orelse return true) + tag.len;
            kind = .literal;
        } else if (std.ascii.isAlphabetic(char) or char == '_' or char >= 128) {
            kind = .word;
            at += 1;
            while (at < sql.len and (std.ascii.isAlphanumeric(sql[at]) or sql[at] == '_' or sql[at] >= 128)) at += 1;
        } else if (std.ascii.isDigit(char)) {
            kind = .number;
            at += 1;
            while (at < sql.len and (std.ascii.isDigit(sql[at]) or sql[at] == '.')) at += 1;
        } else {
            at += 1;
            if (char == ')') {
                if (depth == 0) return true;
                depth -= 1;
            }
        }
        try tokens.append(allocator, .{ .text = sql[start..at], .kind = kind, .depth = depth });
        if (char == '(' and kind == .symbol) depth += 1;
        if (depth > 64 or tokens.items.len > 65536) return true;
    }
    if (depth != 0 or tokens.items.len < 2 or !tokens.items[0].word("select")) return true;
    var from: usize = tokens.items.len;
    for (tokens.items[1..], 1..) |token, index| {
        if (token.word("select") or token.word("with") or token.word("union") or token.word("intersect") or token.word("except")) return true;
        if (token.word("tablesample") or token.word("pivot") or token.word("unpivot") or token.word("match_recognize")) return true;
        // Unicode-escaped identifiers can disguise a whole-row alias. Their
        // decoded schema identity is outside this database-free proof.
        if (token.word("u") and index + 2 < tokens.items.len and tokens.items[index + 1].symbol('&') and tokens.items[index + 2].kind == .identifier) return true;
        if (token.depth == 0 and token.word("from") and from == tokens.items.len) from = index;
    }
    if (from <= 1) return true;
    for (tokens.items[1..from], 1..) |token, index| {
        if (token.word("exclude") or token.word("replace") or (token.word("distinct") and index + 1 < from and tokens.items[index + 1].word("on"))) return true;
        if ((token.kind == .word or token.kind == .identifier) and (sameIdentifier(token.text, "columns") or sameIdentifier(token.text, "unpack")) and index + 1 < from and tokens.items[index + 1].symbol('(')) return true;
        if (!token.symbol('*')) continue;
        // Exact count(*) is an aggregate scalar, not a row wildcard.
        if (index >= 2 and index + 1 < from and tokens.items[index - 1].symbol('(') and tokens.items[index - 2].word("count") and tokens.items[index + 1].symbol(')')) continue;
        const previous = tokens.items[index - 1];
        if (previous.symbol('.') or previous.symbol(',') or previous.symbol('(') or previous.word("select") or previous.word("distinct") or previous.word("all")) return true;
        // Multiplication has a value on both sides; unsupported operators or
        // projection forms conservatively require raw permission.
        if (index + 1 == from or !endsValue(previous) or !startsValue(tokens.items[index + 1])) return true;
    }
    // A projected relation alias can mean a PostgreSQL whole-row record. It
    // does not prove a column reduction, including inside row-to-JSON calls.
    var from_end = tokens.items.len;
    for (tokens.items[from..], from..) |token, position| {
        if (token.depth == 0 and (token.word("where") or token.word("group") or token.word("order") or token.word("having") or token.word("limit") or token.word("offset") or token.word("fetch") or token.word("window") or token.word("qualify"))) {
            from_end = position;
            break;
        }
    }
    var index = from;
    while (index < from_end) : (index += 1) {
        const token = tokens.items[index];
        if (token.depth != 0 or (!token.word("from") and !token.word("join") and !token.symbol(','))) continue;
        var relation = index + 1;
        if (relation >= tokens.items.len) return true;
        if (tokens.items[relation].word("only") or tokens.items[relation].word("lateral")) return true;
        if (tokens.items[relation].symbol('(')) return true;
        if (tokens.items[relation].kind != .word and tokens.items[relation].kind != .identifier) return true;
        var name = tokens.items[relation];
        relation += 1;
        while (relation + 1 < tokens.items.len and tokens.items[relation].symbol('.') and (tokens.items[relation + 1].kind == .word or tokens.items[relation + 1].kind == .identifier)) {
            name = tokens.items[relation + 1];
            relation += 2;
        }
        if (relation < tokens.items.len and tokens.items[relation].symbol('(')) {
            relation += 1;
            while (relation < tokens.items.len and tokens.items[relation].depth != 0) relation += 1;
            if (relation >= tokens.items.len or !tokens.items[relation].symbol(')')) return true;
            relation += 1;
        }
        if (relation < tokens.items.len and tokens.items[relation].word("as")) relation += 1;
        if (relation < tokens.items.len and (tokens.items[relation].kind == .identifier or (tokens.items[relation].kind == .word and !reserved(tokens.items[relation])))) name = tokens.items[relation];
        for (tokens.items[1..from], 1..) |projected, projection_index| {
            if (projected.kind != .word and projected.kind != .identifier) continue;
            if (!sameIdentifier(projected.text, name.text)) continue;
            if (projection_index + 1 < from and tokens.items[projection_index + 1].symbol('.')) continue;
            if (projection_index != 0 and (tokens.items[projection_index - 1].symbol('.') or tokens.items[projection_index - 1].word("as"))) continue;
            return true;
        }
    }
    return false;
}

fn endsValue(token: Token) bool {
    return token.kind == .word or token.kind == .identifier or token.kind == .literal or token.kind == .number or token.symbol(')') or token.symbol(']');
}
fn startsValue(token: Token) bool {
    return token.kind == .word or token.kind == .identifier or token.kind == .literal or token.kind == .number or token.symbol('(');
}

fn reserved(token: Token) bool {
    inline for (.{ "where", "join", "left", "right", "full", "inner", "outer", "cross", "natural", "semi", "anti", "positional", "asof", "on", "using", "group", "order", "having", "limit", "offset", "fetch", "window", "qualify", "tablesample" }) |value| if (token.word(value)) return true;
    return false;
}
fn sameIdentifier(a: []const u8, b: []const u8) bool {
    const first = if (a.len >= 2 and a[0] == '"') a[1 .. a.len - 1] else a;
    const second = if (b.len >= 2 and b[0] == '"') b[1 .. b.len - 1] else b;
    // Case-insensitive matching is deliberately conservative for quoted names.
    return std.ascii.eqlIgnoreCase(first, second);
}

test "source query wildcard and ambiguous trees require raw authorization" {
    for ([_][]const u8{
        "select * from customers",                              "select c.* from customers c",                         "select (*) from customers",
        "select distinct * from customers",                     "select * from customers where enabled",               "with c as (select id from customers) select id from c",
        "select id from (select id from customers) c",          "select id from customers union select id from other", "select columns(*) from customers",
        "select c from customers c",                            "select row_to_json(c) from customers c",              "select c.* exclude(name) from customers c",
        "select * from customers /* where enabled */",          "select * from customers where 'where'='where'",       "select (select id from customers) as id",
        "select id from customers except select id from other", "select columns('.*') from customers",                 "select columns(c -> true) from customers",
        "select unpack(columns('.*')) from customers",          "select U&\"c\\0064\" from customers cd",              "select c from only customers c",
        "select c from customers tablesample system(10) c",
    }) |sql| try std.testing.expect(try requiresRawAuthorization(std.testing.allocator, sql));
}

test "source query explicit projections ignore literal comment and aggregate stars" {
    for ([_][]const u8{
        "select id from customers",                            "select c.id, c.name from customers c",                                           "select count(*) as amount from customers",
        "select id * price as amount from customers",          "select 'select * from customers where' as note, id from customers",              "select $$select * from customers$$ as note, id from customers",
        "select id /* outer /* select * */ */ from customers", "select \"*\", \"where\" from customers",                                         "select coalesce(id,0) as id from customers",
        "select 1::bigint id from pg_sleep(1)",                "select \"custom\".retry_query(id) as id from generate_series(1,17) as rows(id)",
    }) |sql| try std.testing.expect(!try requiresRawAuthorization(std.testing.allocator, sql));
}
