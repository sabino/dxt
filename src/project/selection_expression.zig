const std = @import("std");

/// A selector keeps its set-operation boundaries because indirect tests are
/// combined at each boundary, rather than expanded after selecting all models.
pub const Expression = struct {
    kind: enum { leaf, union_set, intersection, difference },
    value: ?[]const u8 = null,
    indirect_selection: ?[]const u8 = null,
    children: std.ArrayList(*Expression) = .empty,

    pub fn leaf(allocator: std.mem.Allocator, value: []const u8, mode: ?[]const u8) !*Expression {
        const result = try create(allocator, .leaf, mode);
        errdefer result.destroy(allocator);
        result.value = try allocator.dupe(u8, value);
        return result;
    }

    pub fn create(allocator: std.mem.Allocator, kind: @FieldType(Expression, "kind"), mode: ?[]const u8) !*Expression {
        const result = try allocator.create(Expression);
        result.* = .{ .kind = kind, .indirect_selection = mode };
        return result;
    }

    pub fn clone(self: *const Expression, allocator: std.mem.Allocator) !*Expression {
        const result = try create(allocator, self.kind, self.indirect_selection);
        errdefer result.destroy(allocator);
        if (self.value) |value| result.value = try allocator.dupe(u8, value);
        for (self.children.items) |child| {
            const copied = try child.clone(allocator);
            result.children.append(allocator, copied) catch |err| {
                copied.destroy(allocator);
                return err;
            };
        }
        return result;
    }

    pub fn destroy(self: *Expression, allocator: std.mem.Allocator) void {
        if (self.value) |value| allocator.free(value);
        for (self.children.items) |child| child.destroy(allocator);
        self.children.deinit(allocator);
        allocator.destroy(self);
    }
};

/// The CLI is a union of comma-separated intersections. A null mode inherits
/// the invocation flag, while YAML set operators explicitly use Core's eager
/// default and individual YAML criteria can override the flag.
pub fn parseCli(allocator: std.mem.Allocator, value: ?[]const u8) !*Expression {
    if (value == null) return try Expression.leaf(allocator, "", null);
    const expression = try Expression.create(allocator, .union_set, null);
    errdefer expression.destroy(allocator);
    var clauses = std.mem.tokenizeAny(u8, value orelse "*", " \t\r\n");
    while (clauses.next()) |clause| {
        const intersection = try Expression.create(allocator, .intersection, null);
        errdefer intersection.destroy(allocator);
        var terms = std.mem.splitScalar(u8, clause, ',');
        while (terms.next()) |term| {
            const child = try Expression.leaf(allocator, term, null);
            intersection.children.append(allocator, child) catch |err| {
                child.destroy(allocator);
                return err;
            };
        }
        try expression.children.append(allocator, intersection);
    }
    return expression;
}

pub fn difference(allocator: std.mem.Allocator, included: *Expression, excluded: *Expression) !*Expression {
    const result = try Expression.create(allocator, .difference, "eager");
    errdefer {
        result.children.deinit(allocator);
        allocator.destroy(result);
    }
    try result.children.ensureTotalCapacity(allocator, 2);
    result.children.appendAssumeCapacity(included);
    result.children.appendAssumeCapacity(excluded);
    return result;
}
