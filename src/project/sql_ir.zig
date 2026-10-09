//! Native logical SQL IR and scope-aware column lineage. Syntax and final
//! output types come from the dialect parser and the database binder.
const std = @import("std");
const parser = @import("sql_parser.zig");
const Dialect = parser.Dialect;
const Value = std.json.Value;
const field = parser.field;
const text = parser.text;
const items = parser.items;

pub const Origin = struct { resource_id: []const u8, column: []const u8 };
pub const Column = struct { name: []const u8, data_type: []const u8 = "UNKNOWN", nullable: bool = true, origins: []const Origin = &.{} };
pub const Relation = struct { resource_id: []const u8, catalog: []const u8 = "", schema: []const u8 = "", identifier: []const u8, columns: []const Column };
pub const Input = struct { resource_id: []const u8, catalog: []const u8, schema: []const u8, identifier: []const u8, offset: usize };
pub const Operator = struct { kind: []const u8, offset: usize = 0 };
pub const Ir = struct { columns: []const Column, inputs: []const Input, operators: []const Operator, predicate_origins: []const Origin };
const Binding = struct { alias: []const u8, columns: []const Column };
const Scope = struct { bindings: std.ArrayList(Binding) = .empty, ctes: std.ArrayList(Binding) = .empty, outer: ?*const Scope = null, projected: []const Column = &.{}, join_keys: std.StringHashMapUnmanaged(Column) = .empty };
pub const FunctionBinding = struct { offset: usize, columns: []const Column };

pub const Builder = struct {
    allocator: std.mem.Allocator,
    dialect: Dialect,
    catalog: []const Relation,
    functions: []const FunctionBinding = &.{},
    inputs: std.ArrayList(Input) = .empty,
    operators: std.ArrayList(Operator) = .empty,
    predicate_origins: std.ArrayList(Origin) = .empty,
    depth: usize = 0,

    pub fn build(self: *Builder, ast: Value, bound: []const Column) !Ir {
        const statements = items(field(ast, if (self.dialect == .duckdb) "statements" else "stmts"));
        if (statements.len != 1) return error.SqlAnalysisRequiresSingleQuery;
        const query_node = if (self.dialect == .duckdb) field(statements[0], "node") else field(field(statements[0], "stmt"), "SelectStmt");
        if (query_node == .null) return error.SqlAnalysisRequiresSelect;
        const inferred = try self.query(query_node, null);
        if (inferred.len != bound.len) return error.SqlLineageOutputMismatch;
        for (inferred, bound) |*column, typed| {
            column.name = typed.name;
            column.data_type = typed.data_type;
            column.nullable = typed.nullable;
        }
        return .{ .columns = inferred, .inputs = try self.inputs.toOwnedSlice(self.allocator), .operators = try self.operators.toOwnedSlice(self.allocator), .predicate_origins = try self.predicate_origins.toOwnedSlice(self.allocator) };
    }

    fn query(self: *Builder, node: Value, outer: ?*const Scope) anyerror![]Column {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > 256) return error.SqlAnalysisDepthExceeded;
        var scope = Scope{ .outer = outer };
        const ctes = if (self.dialect == .duckdb) items(field(field(node, "cte_map"), "map")) else items(field(field(node, "withClause"), "ctes"));
        for (ctes) |wrapped| {
            const cte = if (self.dialect == .duckdb) wrapped else field(wrapped, "CommonTableExpr");
            const name = text(field(cte, if (self.dialect == .duckdb) "key" else "ctename"));
            const query_node = if (self.dialect == .duckdb) field(field(field(cte, "value"), "query"), "node") else field(field(cte, "ctequery"), "SelectStmt");
            const names = if (self.dialect == .duckdb) items(field(field(cte, "value"), "aliases")) else items(field(cte, "aliascolnames"));
            const recursive = eq(text(field(query_node, "type")), "RECURSIVE_CTE_NODE") or (self.dialect == .postgres and field(field(node, "withClause"), "recursive") == .bool and field(field(node, "withClause"), "recursive").bool and !eq(text(field(query_node, "op")), "SETOP_NONE"));
            const columns = if (recursive) try self.recursiveCte(query_node, &scope, name, names) else try self.query(query_node, &scope);
            for (names, 0..) |name_value, index| if (index < columns.len) {
                columns[index].name = try self.stringName(name_value);
            };
            try scope.ctes.append(self.allocator, .{ .alias = name, .columns = columns });
            try self.op("CTE", parser.location(cte));
        }
        const kind = text(field(node, if (self.dialect == .duckdb) "type" else "op"));
        if (eq(kind, "SET_OPERATION_NODE") or (self.dialect == .postgres and kind.len != 0 and !eq(kind, "SETOP_NONE"))) {
            const left = try self.query(field(node, if (self.dialect == .duckdb) "left" else "larg"), &scope);
            const right = try self.query(field(node, if (self.dialect == .duckdb) "right" else "rarg"), &scope);
            if (left.len != right.len) return error.SqlLineageOutputMismatch;
            for (left, right) |*column, other| column.origins = try self.joinOrigins(column.origins, other.origins);
            try self.op(if (self.dialect == .duckdb) text(field(node, "setop_type")) else kind, parser.location(node));
            return left;
        }
        if (self.dialect == .postgres and items(field(node, "valuesLists")).len != 0) return try self.valuesColumns(field(node, "valuesLists"), &scope);
        if (self.dialect == .duckdb) try self.from(field(node, "from_table"), &scope) else for (items(field(node, "fromClause"))) |source| try self.from(source, &scope);
        const where = field(node, if (self.dialect == .duckdb) "where_clause" else "whereClause");
        if (where != .null) {
            try self.appendPredicates(try self.expression(where, &scope));
            try self.op("Filter", parser.location(where));
        }
        var columns: std.ArrayList(Column) = .empty;
        const projections = items(field(node, if (self.dialect == .duckdb) "select_list" else "targetList"));
        for (projections) |projection| {
            scope.projected = columns.items;
            const target = if (self.dialect == .duckdb) projection else field(projection, "ResTarget");
            const expression_node = if (self.dialect == .duckdb) target else field(target, "val");
            if (self.star(expression_node)) |qualifier| {
                try self.expandStar(&columns, &scope, qualifier, expression_node);
            } else {
                const refs = try self.expression(expression_node, &scope);
                var name = text(field(target, if (self.dialect == .duckdb) "alias" else "name"));
                if (name.len == 0) name = try self.expressionName(expression_node);
                try columns.append(self.allocator, .{ .name = name, .origins = refs });
            }
        }
        scope.projected = columns.items;
        try self.op("Project", parser.location(node));
        inline for (.{ .{ "group_expressions", "groupClause", "Aggregate" }, .{ "having", "havingClause", "Having" }, .{ "qualify", "windowClause", "Window" }, .{ "sample", "distinctClause", "Distinct" }, .{ "orders", "sortClause", "Sort" }, .{ "limit", "limitCount", "Limit" } }) |keys| {
            const value = field(node, if (self.dialect == .duckdb) keys[0] else keys[1]);
            if (value != .null and !(value == .array and value.array.items.len == 0)) {
                try self.appendPredicates(try self.expression(value, &scope));
                try self.op(keys[2], parser.location(value));
            }
        }
        // DuckDB represents ordering/limit/distinct as logical modifiers.
        for (items(field(node, "modifiers"))) |modifier| {
            const modifier_type = text(field(modifier, "type"));
            try self.op(modifier_type, parser.location(modifier));
            try self.appendPredicates(try self.expression(modifier, &scope));
        }
        return try columns.toOwnedSlice(self.allocator);
    }

    // Recursive output lineage is a finite union of base-column origins. The
    // anchor establishes names; the recursive member reaches a fixed point.
    fn recursiveCte(self: *Builder, node: Value, scope: *Scope, name: []const u8, aliases: []const Value) anyerror![]Column {
        const columns = try self.query(field(node, if (self.dialect == .duckdb) "left" else "larg"), scope);
        for (aliases, 0..) |alias, index| if (index < columns.len) {
            columns[index].name = try self.stringName(alias);
        };
        const before = scope.ctes.items.len;
        try scope.ctes.append(self.allocator, .{ .alias = name, .columns = columns });
        defer scope.ctes.shrinkRetainingCapacity(before);
        var iteration: usize = 0;
        while (iteration < 256) : (iteration += 1) {
            const operators_before = self.operators.items.len;
            const right = try self.query(field(node, if (self.dialect == .duckdb) "right" else "rarg"), scope);
            if (iteration != 0) self.operators.shrinkRetainingCapacity(operators_before);
            if (right.len != columns.len) return error.SqlLineageOutputMismatch;
            var changed = false;
            for (columns, right) |*column, other| {
                const combined = try self.joinOrigins(column.origins, other.origins);
                changed = changed or combined.len != column.origins.len;
                column.origins = combined;
            }
            if (!changed) {
                try self.op("RecursiveCTE", parser.location(node));
                return columns;
            }
        }
        return error.SqlAnalysisDepthExceeded;
    }

    fn from(self: *Builder, raw: Value, scope: *Scope) anyerror!void {
        if (raw == .null) return;
        var node = raw;
        var kind = text(field(node, "type"));
        if (self.dialect == .postgres) {
            for ([_][]const u8{ "RangeVar", "RangeSubselect", "JoinExpr", "RangeFunction" }) |name| if (field(raw, name) != .null) {
                node = field(raw, name);
                kind = name;
                break;
            };
        }
        if (eq(kind, "EMPTY")) return;
        if (eq(kind, "JOIN") or eq(kind, "CROSS_PRODUCT") or eq(kind, "JoinExpr")) {
            const before = scope.bindings.items.len;
            try self.from(field(node, if (self.dialect == .duckdb) "left" else "larg"), scope);
            const middle = scope.bindings.items.len;
            try self.from(field(node, if (self.dialect == .duckdb) "right" else "rarg"), scope);
            const using_columns = items(field(node, if (self.dialect == .duckdb) "using_columns" else "usingClause"));
            for (using_columns) |name_value| {
                const name = try self.stringName(name_value);
                var key: ?Column = null;
                for (scope.bindings.items[before..]) |binding| for (binding.columns) |column| if (self.equal(column.name, name)) {
                    if (key) |existing| {
                        var merged = existing;
                        merged.origins = try self.joinOrigins(existing.origins, column.origins);
                        key = merged;
                    } else key = column;
                };
                if (key) |column| {
                    try scope.join_keys.put(self.allocator, name, column);
                    try self.appendPredicates(column.origins);
                }
            }
            const natural = field(node, "isNatural");
            if ((natural == .bool and natural.bool) or eq(text(field(node, "ref_type")), "NATURAL")) {
                for (scope.bindings.items[before..middle]) |left_binding| for (left_binding.columns) |left| for (scope.bindings.items[middle..]) |rhs_binding| for (rhs_binding.columns) |right| if (self.equal(left.name, right.name)) {
                    var merged = left;
                    merged.origins = try self.joinOrigins(left.origins, right.origins);
                    try scope.join_keys.put(self.allocator, left.name, merged);
                    try self.appendPredicates(merged.origins);
                };
            }
            try self.appendPredicates(try self.expression(field(node, if (self.dialect == .duckdb) "condition" else "quals"), scope));
            try self.op("Join", parser.location(node));
            return;
        }
        const alias = if (self.dialect == .duckdb) text(field(node, "alias")) else text(field(field(node, "alias"), "aliasname"));
        if (eq(kind, "SUBQUERY") or eq(kind, "RangeSubselect")) {
            const subquery = if (self.dialect == .duckdb) field(field(node, "subquery"), "node") else field(field(node, "subquery"), "SelectStmt");
            const columns = try self.query(subquery, scope);
            const aliases = if (self.dialect == .duckdb) items(field(node, "column_name_alias")) else items(field(field(node, "alias"), "colnames"));
            for (aliases, 0..) |name, index| if (index < columns.len) {
                columns[index].name = try self.stringName(name);
            };
            try scope.bindings.append(self.allocator, .{ .alias = alias, .columns = columns });
            return;
        }
        if (eq(kind, "EXPRESSION_LIST")) {
            const columns = try self.valuesColumns(field(node, "values"), scope);
            try scope.bindings.append(self.allocator, .{ .alias = alias, .columns = columns });
            try self.op("Values", parser.location(node));
            return;
        }
        if (eq(kind, "TABLE_FUNCTION") or eq(kind, "RangeFunction")) {
            const function = parser.tableFunction(raw, self.dialect);
            const offset = parser.location(function);
            for (self.functions) |binding| if (binding.offset == offset) {
                const columns = try self.allocator.dupe(Column, binding.columns);
                const aliases = if (self.dialect == .duckdb) items(field(node, "column_name_alias")) else items(field(field(node, "alias"), "colnames"));
                for (aliases, 0..) |name, index| if (index < columns.len) {
                    columns[index].name = try self.stringName(name);
                };
                if (self.dialect == .postgres and aliases.len == 0 and alias.len != 0 and columns.len == 1) columns[0].name = alias;
                var name = alias;
                if (name.len == 0) name = if (self.dialect == .duckdb) text(field(function, "function_name")) else try self.stringName(items(field(function, "funcname"))[0]);
                const argument_origins = try self.expression(function, scope);
                for (columns) |*column| column.origins = argument_origins;
                try scope.bindings.append(self.allocator, .{ .alias = name, .columns = columns });
                try self.op("TableFunction", offset);
                return;
            };
            return error.SqlLineageUnboundTableFunction;
        }
        if (!eq(kind, "BASE_TABLE") and !eq(kind, "RangeVar")) return error.SqlLineageUnsupportedRelation;
        const identifier = text(field(node, if (self.dialect == .duckdb) "table_name" else "relname"));
        const schema = text(field(node, if (self.dialect == .duckdb) "schema_name" else "schemaname"));
        const catalog = text(field(node, if (self.dialect == .duckdb) "catalog_name" else "catalogname"));
        if (schema.len == 0 and catalog.len == 0) if (self.findCte(scope, identifier)) |binding| {
            try scope.bindings.append(self.allocator, .{ .alias = if (alias.len == 0) identifier else alias, .columns = binding.columns });
            return;
        };
        var matched: ?Relation = null;
        for (self.catalog) |relation| {
            if (!self.equal(identifier, relation.identifier) or (schema.len != 0 and !self.equal(schema, relation.schema)) or (catalog.len != 0 and !self.equal(catalog, relation.catalog))) continue;
            if (matched != null) return error.SqlLineageAmbiguousRelation;
            matched = relation;
        }
        const relation = matched orelse return error.SqlLineageUnresolvedRelation;
        try scope.bindings.append(self.allocator, .{ .alias = if (alias.len == 0) identifier else alias, .columns = relation.columns });
        var found = false;
        for (self.inputs.items) |input| if (eq(input.resource_id, relation.resource_id)) {
            found = true;
            break;
        };
        if (!found) try self.inputs.append(self.allocator, .{ .resource_id = relation.resource_id, .catalog = relation.catalog, .schema = relation.schema, .identifier = relation.identifier, .offset = parser.location(node) });
        try self.op("Scan", parser.location(node));
    }

    fn expression(self: *Builder, raw: Value, scope: *const Scope) anyerror![]const Origin {
        if (raw == .null) return &.{};
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > 512) return error.SqlAnalysisDepthExceeded;
        var origins: std.ArrayList(Origin) = .empty;
        if (self.columnNames(raw)) |names| {
            const name = names[names.len - 1];
            const qualifier = if (names.len > 1) names[names.len - 2] else "";
            const column = try self.resolveColumn(scope, qualifier, name);
            try self.appendOrigins(&origins, column.origins);
            return try origins.toOwnedSlice(self.allocator);
        }
        if (self.dialect == .duckdb and eq(text(field(raw, "class")), "SUBQUERY")) {
            const columns = try self.query(field(field(raw, "subquery"), "node"), scope);
            for (columns) |column| try self.appendOrigins(&origins, column.origins);
            try self.appendOrigins(&origins, try self.expression(field(raw, "child"), scope));
            return try origins.toOwnedSlice(self.allocator);
        }
        if (self.dialect == .postgres and field(raw, "SubLink") != .null) {
            const link = field(raw, "SubLink");
            const columns = try self.query(field(field(link, "subselect"), "SelectStmt"), scope);
            for (columns) |column| try self.appendOrigins(&origins, column.origins);
            try self.appendOrigins(&origins, try self.expression(field(link, "testexpr"), scope));
            return try origins.toOwnedSlice(self.allocator);
        }
        switch (raw) {
            .object => |object| {
                var it = object.iterator();
                while (it.next()) |entry| {
                    // A parser's positional GROUP/ORDER reference points at
                    // an output expression; ordinary metadata carries no refs.
                    try self.appendOrigins(&origins, try self.expression(entry.value_ptr.*, scope));
                }
            },
            .array => |array| for (array.items) |child| try self.appendOrigins(&origins, try self.expression(child, scope)),
            else => {},
        }
        return try origins.toOwnedSlice(self.allocator);
    }

    fn columnNames(self: *Builder, node: Value) ?[]const []const u8 {
        const references = if (self.dialect == .duckdb) if (eq(text(field(node, "class")), "COLUMN_REF")) field(node, "column_names") else .null else field(field(node, "ColumnRef"), "fields");
        if (references != .array or references.array.items.len == 0) return null;
        var names: std.ArrayList([]const u8) = .empty;
        for (references.array.items) |name| {
            if (self.dialect == .postgres and field(name, "A_Star") != .null) return null;
            names.append(self.allocator, self.stringName(name) catch return null) catch return null;
        }
        return names.toOwnedSlice(self.allocator) catch null;
    }
    fn star(self: *Builder, node: Value) ?[]const u8 {
        if (self.dialect == .duckdb) return if (eq(text(field(node, "class")), "STAR")) text(field(node, "relation_name")) else null;
        const names = items(field(field(node, "ColumnRef"), "fields"));
        if (names.len == 0 or field(names[names.len - 1], "A_Star") == .null) return null;
        return if (names.len > 1) self.stringName(names[names.len - 2]) catch null else "";
    }
    fn expandStar(self: *Builder, out: *std.ArrayList(Column), scope: *const Scope, qualifier: []const u8, expression_node: Value) !void {
        var matched = false;
        for (scope.bindings.items) |binding| {
            if (qualifier.len != 0 and !self.equal(qualifier, binding.alias)) continue;
            matched = true;
            for (binding.columns) |column| {
                var excluded = false;
                for (items(field(expression_node, "exclude_list"))) |name| if (self.equal(column.name, text(name))) {
                    excluded = true;
                    break;
                };
                if (!excluded) {
                    if (qualifier.len == 0) if (scope.join_keys.get(column.name)) |merged| {
                        var present = false;
                        for (out.items) |prior| if (self.equal(prior.name, column.name)) {
                            present = true;
                            break;
                        };
                        if (!present) try out.append(self.allocator, merged);
                        continue;
                    };
                    var projected = column;
                    for (items(field(expression_node, "replace_list"))) |replacement| if (self.equal(text(field(replacement, "key")), column.name)) {
                        projected.origins = try self.expression(field(replacement, "value"), scope);
                    };
                    for (items(field(expression_node, "rename_list"))) |rename| if (self.equal(text(field(field(rename, "key"), "column")), column.name)) {
                        projected.name = text(field(rename, "value"));
                    };
                    try out.append(self.allocator, projected);
                }
            }
        }
        if (!matched) return error.SqlLineageUnresolvedRelation;
    }
    fn resolveColumn(self: *Builder, scope: *const Scope, qualifier: []const u8, name: []const u8) anyerror!Column {
        if (qualifier.len == 0) for (scope.projected) |column| if (self.equal(column.name, name)) return column;
        if (qualifier.len == 0) if (scope.join_keys.get(name)) |column| return column;
        var matched: ?Column = null;
        for (scope.bindings.items) |binding| {
            if (qualifier.len != 0 and !self.equal(binding.alias, qualifier)) continue;
            for (binding.columns) |column| if (self.equal(column.name, name)) {
                if (matched != null) return error.SqlLineageAmbiguousColumn;
                matched = column;
            };
        }
        if (matched) |column| return column;
        // ORDER BY/HAVING may refer to projected aliases. Bound output remains
        // authoritative; projection lineage is already in the IR columns.
        if (scope.outer) |outer| return try self.resolveColumn(outer, qualifier, name);
        return error.SqlLineageUnresolvedColumn;
    }
    fn findCte(self: *Builder, scope: *const Scope, name: []const u8) ?Binding {
        for (scope.ctes.items) |binding| if (self.equal(binding.alias, name)) return binding;
        return if (scope.outer) |outer| self.findCte(outer, name) else null;
    }
    fn expressionName(self: *Builder, node: Value) ![]const u8 {
        if (self.columnNames(node)) |names| return names[names.len - 1];
        return if (self.dialect == .duckdb) text(field(node, "function_name")) else "?column?";
    }
    fn stringName(self: *Builder, node: Value) ![]const u8 {
        _ = self;
        return if (node == .string) node.string else text(field(field(node, "String"), "sval"));
    }
    fn equal(self: *const Builder, a: []const u8, b: []const u8) bool {
        return if (self.dialect == .duckdb) std.ascii.eqlIgnoreCase(a, b) else eq(a, b);
    }
    fn op(self: *Builder, kind: []const u8, offset: usize) !void {
        try self.operators.append(self.allocator, .{ .kind = kind, .offset = offset });
    }
    fn appendOrigins(self: *Builder, out: *std.ArrayList(Origin), origins: []const Origin) !void {
        for (origins) |origin| {
            var found = false;
            for (out.items) |existing| if (eq(origin.resource_id, existing.resource_id) and eq(origin.column, existing.column)) {
                found = true;
                break;
            };
            if (!found) try out.append(self.allocator, origin);
        }
    }
    fn joinOrigins(self: *Builder, left: []const Origin, right: []const Origin) ![]const Origin {
        var origins: std.ArrayList(Origin) = .empty;
        try self.appendOrigins(&origins, left);
        try self.appendOrigins(&origins, right);
        return try origins.toOwnedSlice(self.allocator);
    }
    fn appendPredicates(self: *Builder, origins: []const Origin) !void {
        try self.appendOrigins(&self.predicate_origins, origins);
    }
    fn rowValues(self: *const Builder, row: Value) []const Value {
        return if (self.dialect == .postgres) items(field(field(row, "List"), "items")) else items(row);
    }
    fn valuesColumns(self: *Builder, rows: Value, scope: *const Scope) ![]Column {
        const entries = items(rows);
        if (entries.len == 0) return &.{};
        const columns = try self.allocator.alloc(Column, self.rowValues(entries[0]).len);
        for (columns, 0..) |*column, index| {
            var origins: std.ArrayList(Origin) = .empty;
            for (entries) |row| if (index < self.rowValues(row).len) try self.appendOrigins(&origins, try self.expression(self.rowValues(row)[index], scope));
            column.* = .{ .name = try std.fmt.allocPrint(self.allocator, "{s}{d}", .{ if (self.dialect == .duckdb) "col" else "column", if (self.dialect == .duckdb) index else index + 1 }), .origins = try origins.toOwnedSlice(self.allocator) };
        }
        return columns;
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "logical IR resolves PostgreSQL CTE joins and expressions to typed base columns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var pg = try parser.Postgres.open(.{ .allocator = allocator, .io = std.testing.io });
    defer pg.deinit();
    const parsed = try pg.parse(allocator, "with orders as (select a as x,b from foo) select o.x,f.b+1 as z from orders o join foo f on o.x=f.a");
    const base = [_]Column{ .{ .name = "a", .data_type = "INTEGER", .origins = &.{.{ .resource_id = "source.demo.foo", .column = "a" }} }, .{ .name = "b", .data_type = "INTEGER", .origins = &.{.{ .resource_id = "source.demo.foo", .column = "b" }} } };
    var builder = Builder{ .allocator = allocator, .dialect = .postgres, .catalog = &.{.{ .resource_id = "source.demo.foo", .identifier = "foo", .columns = &base }} };
    const ir = try builder.build(parsed.tree, &.{ .{ .name = "x", .data_type = "INTEGER" }, .{ .name = "z", .data_type = "INTEGER" } });
    try std.testing.expectEqualStrings("a", ir.columns[0].origins[0].column);
    try std.testing.expectEqualStrings("b", ir.columns[1].origins[0].column);
    try std.testing.expectEqualStrings("INTEGER", ir.columns[0].data_type);
    try std.testing.expectEqual(@as(usize, 1), ir.inputs.len);
    try std.testing.expect(ir.predicate_origins.len != 0);
}
