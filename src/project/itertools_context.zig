//! The pinned dbt modules.itertools exports, evaluated as native lazy streams.
const std = @import("std");
const expression = @import("expression.zig");
const sequence = @import("expression_sequence.zig");
const Value = expression.Value;
const Argument = expression.Argument;
const Host = expression.Host;
const Allocator = std.mem.Allocator;
const limit: usize = 1_000_000;
const names = [_][]const u8{ "count", "cycle", "repeat", "accumulate", "chain", "compress", "islice", "starmap", "tee", "zip_longest", "product", "permutations", "combinations", "combinations_with_replacement" };

fn object(a: Allocator, entries: []const expression.Entry) !Value {
    return .{ .object = try a.dupe(expression.Entry, entries) };
}
fn function(a: Allocator, name: []const u8) !Value {
    var fields: std.ArrayList(expression.Entry) = .empty;
    try fields.append(a, .{ .key = "__dxt_context_object", .value = .{ .callable = "__dxt_context_object" } });
    try fields.append(a, .{ .key = "__dxt_callable", .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_itertools:{s}", .{name}) } });
    try fields.append(a, .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } });
    try fields.append(a, .{ .key = "__dxt_rendered", .value = .{ .string = if (std.mem.eql(u8, name, "tee")) "<built-in function tee>" else try std.fmt.allocPrint(a, "<class 'itertools.{s}'>", .{name}) } });
    if (std.mem.eql(u8, name, "chain")) try fields.append(a, .{ .key = "from_iterable", .value = .{ .callable = "__dxt_itertools:chain.from_iterable" } });
    return .{ .object = try fields.toOwnedSlice(a) };
}
pub fn resolve(a: Allocator, path: []const u8) anyerror!?Value {
    if (std.mem.eql(u8, path, "modules.itertools")) {
        const fields = try expression.allocateEntries(a, names.len);
        for (names, fields) |name, *entry| entry.* = .{ .key = name, .value = try function(a, name) };
        return .{ .object = fields };
    }
    const prefix = "modules.itertools.";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const name = path[prefix.len..];
    if (std.mem.eql(u8, name, "chain.from_iterable")) return .{ .callable = "__dxt_itertools:chain.from_iterable" };
    for (names) |candidate| if (std.mem.eql(u8, name, candidate)) return try function(a, name);
    return null;
}
fn descriptor(a: Allocator, name: []const u8, fields: []const expression.Entry) !Value {
    const entries = try expression.allocateEntries(a, fields.len + 1);
    entries[0] = .{ .key = "__dxt_sequence_kind", .value = .{ .string = try std.fmt.allocPrint(a, "itertools_{s}", .{name}) } };
    @memcpy(entries[1..], fields);
    return sequence.descriptor(a, entries);
}
fn set(value: Value, name: []const u8, replacement: Value) void {
    for (@constCast(value.object)) |*entry| if (std.mem.eql(u8, entry.key, name)) {
        entry.value = replacement;
        return;
    };
    unreachable;
}
fn integer(value: Value, name: []const u8) !i64 {
    return expression.integerIndex(value.attribute(name));
}
fn setInteger(a: Allocator, value: Value, name: []const u8, number: i64) !void {
    set(value, name, try expression.integerValue(a, number));
}
fn stop(value: Value) ?Value {
    set(value, "done", .{ .boolean = true });
    return null;
}
fn positional(args: []const Argument, minimum: usize, maximum: usize) !void {
    if (args.len < minimum or args.len > maximum) return error.InvalidJinjaArguments;
    for (args) |arg| if (arg.name != null) return error.InvalidJinjaArguments;
}
fn bind(a: Allocator, args: []const Argument, parameters: []const []const u8, required: usize, keyword_only: usize) ![]?Value {
    const values = try a.alloc(?Value, parameters.len);
    @memset(values, null);
    var index: usize = 0;
    for (args) |arg| {
        const at = if (arg.name) |name| blk: {
            for (parameters, 0..) |parameter, position| if (std.mem.eql(u8, name, parameter)) break :blk position;
            return error.InvalidJinjaArguments;
        } else blk: {
            if (index >= keyword_only) return error.InvalidJinjaArguments;
            const position = index;
            index += 1;
            break :blk position;
        };
        if (at >= parameters.len or values[at] != null) return error.InvalidJinjaArguments;
        values[at] = arg.value;
    }
    for (values[0..required]) |value| if (value == null) return error.InvalidJinjaArguments;
    return values;
}
fn unitStep(step: Value) bool {
    return (step == .integer and std.mem.eql(u8, step.integer, "1")) or (step == .boolean and step.boolean) or if (expression.integerProtocol(step)) |number| std.mem.eql(u8, number, "1") else false;
}
fn numeric(value: Value) bool {
    return value == .boolean or value == .integer or value == .number or value == .complex or expression.integerProtocol(value) != null or expression.floatProtocol(value) != null or expression.complexProtocol(value) != null;
}
fn nonnegative(value: Value) !usize {
    const number = try expression.integerIndex(value);
    if (number < 0) return error.InvalidJinjaArguments;
    return @intCast(number);
}
fn indexValues(a: Allocator, count: usize, increasing: bool) !Value {
    if (count > limit) return error.JinjaIterationLimitExceeded;
    const items = try expression.allocateValues(a, count);
    for (items, 0..) |*item, i| item.* = try expression.integerValue(a, if (increasing) i else 0);
    return .{ .list = items };
}
fn bufferAppend(a: Allocator, state: Value, value: Value) !void {
    const length: usize = @intCast(try integer(state, "length"));
    if (length >= limit) return error.JinjaIterationLimitExceeded;
    var buffer = state.attribute("buffer").list;
    if (length == buffer.len) {
        const larger = try expression.allocateValues(a, @min(limit, @max(@as(usize, 8), buffer.len * 2)));
        @memset(larger, .none);
        @memcpy(larger[0..buffer.len], buffer);
        a.free(buffer);
        buffer = larger;
        set(state, "buffer", .{ .list = larger });
    }
    @constCast(buffer)[length] = value;
    try setInteger(a, state, "length", @intCast(length + 1));
}
fn callback(a: Allocator, callable: Value, values: []const Value, host: ?Host) anyerror!Value {
    if (expression.isUndefined(callable)) return try expression.callUndefined(callable);
    const name = expression.callableName(callable) orelse return error.JinjaTypeError;
    const context = host orelse return error.UnsupportedJinjaCall;
    const arguments = try a.alloc(Argument, values.len);
    for (arguments, values) |*argument, value| argument.* = .{ .value = value };
    return try context.call(context.context, name, arguments, a);
}

pub fn call(a: Allocator, authored_name: []const u8, args: []const Argument, host: ?Host) anyerror!?Value {
    const name = if (std.mem.startsWith(u8, authored_name, "__dxt_itertools:")) authored_name["__dxt_itertools:".len..] else if (std.mem.startsWith(u8, authored_name, "modules.itertools.")) authored_name["modules.itertools.".len..] else return null;
    if (std.mem.eql(u8, name, "count")) {
        const values = try bind(a, args, &.{ "start", "step" }, 0, 2);
        var start = values[0] orelse Value{ .integer = "0" };
        const step = values[1] orelse Value{ .integer = "1" };
        if (!numeric(start) or !numeric(step)) return error.JinjaTypeError;
        // CPython's unit-integer-step path starts with a plain integer even
        // when the authored start is bool or an integer subclass such as Flag.
        if (unitStep(step)) {
            if (start == .boolean) {
                const digits = if (start.boolean) "1" else "0";
                start = .{ .integer = digits };
            } else if (expression.integerProtocol(start)) |number| start = .{ .integer = number };
        }
        return try descriptor(a, "count", &.{ .{ .key = "current", .value = start }, .{ .key = "step", .value = step }, .{ .key = "started", .value = .{ .boolean = false } } });
    }
    if (std.mem.eql(u8, name, "repeat")) {
        const values = try bind(a, args, &.{ "object", "times" }, 1, 2);
        const times = if (values[1]) |value| @max(0, try expression.integerIndex(value)) else @as(i64, -1);
        return try descriptor(a, "repeat", &.{ .{ .key = "value", .value = values[0].? }, .{ .key = "remaining", .value = try expression.integerValue(a, times) } });
    }
    if (std.mem.eql(u8, name, "cycle")) {
        try positional(args, 1, 1);
        return try descriptor(a, "cycle", &.{
            .{ .key = "source", .value = try sequence.iter(a, args[0].value) }, .{ .key = "buffer", .value = .{ .list = &.{} } }, .{ .key = "length", .value = .{ .integer = "0" } }, .{ .key = "cursor", .value = .{ .integer = "0" } }, .{ .key = "cached", .value = .{ .boolean = false } },
        });
    }
    if (std.mem.eql(u8, name, "accumulate")) {
        const values = try bind(a, args, &.{ "iterable", "func", "initial" }, 1, 2);
        return try descriptor(a, "accumulate", &.{
            .{ .key = "source", .value = try sequence.iter(a, values[0].?) }, .{ .key = "function", .value = values[1] orelse .none }, .{ .key = "total", .value = values[2] orelse .none }, .{ .key = "initial", .value = .{ .boolean = values[2] != null and values[2].? != .none } }, .{ .key = "started", .value = .{ .boolean = false } }, .{ .key = "done", .value = .{ .boolean = false } },
        });
    }
    if (std.mem.eql(u8, name, "chain")) {
        try positional(args, 0, std.math.maxInt(usize));
        const inputs = try expression.allocateValues(a, args.len);
        for (inputs, args) |*input, argument| input.* = argument.value;
        return try descriptor(a, "chain", &.{ .{ .key = "source", .value = try sequence.iterator(a, inputs) }, .{ .key = "active", .value = .none }, .{ .key = "done", .value = .{ .boolean = false } } });
    }
    if (std.mem.eql(u8, name, "chain.from_iterable")) {
        try positional(args, 1, 1);
        return try descriptor(a, "chain", &.{ .{ .key = "source", .value = try sequence.iter(a, args[0].value) }, .{ .key = "active", .value = .none }, .{ .key = "done", .value = .{ .boolean = false } } });
    }
    if (std.mem.eql(u8, name, "compress")) {
        const values = try bind(a, args, &.{ "data", "selectors" }, 2, 2);
        return try descriptor(a, "compress", &.{ .{ .key = "source", .value = try sequence.iter(a, values[0].?) }, .{ .key = "selectors", .value = try sequence.iter(a, values[1].?) }, .{ .key = "done", .value = .{ .boolean = false } } });
    }
    if (std.mem.eql(u8, name, "islice")) {
        try positional(args, 2, 4);
        const start = if (args.len > 2 and args[1].value != .none) try nonnegative(args[1].value) else 0;
        const stop_value = args[if (args.len == 2) @as(usize, 1) else 2].value;
        const end = if (stop_value == .none) null else try nonnegative(stop_value);
        const step = if (args.len == 4 and args[3].value != .none) try nonnegative(args[3].value) else 1;
        if (step == 0) return error.InvalidJinjaArguments;
        return try descriptor(a, "islice", &.{
            .{ .key = "source", .value = try sequence.iter(a, args[0].value) }, .{ .key = "counter", .value = .{ .integer = "0" } }, .{ .key = "next", .value = try expression.integerValue(a, start) }, .{ .key = "stop", .value = if (end) |number| try expression.integerValue(a, number) else .none }, .{ .key = "step", .value = try expression.integerValue(a, step) }, .{ .key = "started", .value = .{ .boolean = false } }, .{ .key = "done", .value = .{ .boolean = false } },
        });
    }
    if (std.mem.eql(u8, name, "starmap")) {
        try positional(args, 2, 2);
        return try descriptor(a, "starmap", &.{ .{ .key = "source", .value = try sequence.iter(a, args[1].value) }, .{ .key = "function", .value = args[0].value } });
    }
    if (std.mem.eql(u8, name, "tee")) {
        try positional(args, 1, 2);
        const count = if (args.len == 2) try nonnegative(args[1].value) else 2;
        if (count > limit) return error.JinjaIterationLimitExceeded;
        const branches = try expression.allocateValues(a, count);
        if (count == 0) return .{ .tuple = branches };
        const source = try sequence.iter(a, args[0].value);
        const already_tee = std.mem.eql(u8, sequence.kind(source) orelse "", "itertools_tee");
        const shared = if (already_tee) source.attribute("shared") else try object(a, &.{ .{ .key = "source", .value = source }, .{ .key = "buffer", .value = .{ .list = &.{} } }, .{ .key = "length", .value = .{ .integer = "0" } }, .{ .key = "done", .value = .{ .boolean = false } } });
        for (branches) |*branch| branch.* = try descriptor(a, "tee", &.{ .{ .key = "shared", .value = shared }, .{ .key = "cursor", .value = if (already_tee) source.attribute("cursor") else .{ .integer = "0" } } });
        return .{ .tuple = branches };
    }
    if (std.mem.eql(u8, name, "zip_longest") or std.mem.eql(u8, name, "product")) {
        const product = std.mem.eql(u8, name, "product");
        var option: Value = if (product) .{ .integer = "1" } else .none;
        var found = false;
        var inputs: std.ArrayList(Value) = .empty;
        for (args) |argument| {
            if (argument.name) |keyword| {
                if (found or !std.mem.eql(u8, keyword, if (product) "repeat" else "fillvalue")) return error.InvalidJinjaArguments;
                option = argument.value;
                found = true;
            } else try inputs.append(a, argument.value);
        }
        if (product) {
            const repetitions = try nonnegative(option);
            if (inputs.items.len != 0 and repetitions > limit / inputs.items.len) return error.JinjaIterationLimitExceeded;
            const pools = try expression.allocateValues(a, inputs.items.len * repetitions);
            if (repetitions != 0) for (inputs.items, 0..) |input, i| {
                const pool: Value = .{ .tuple = try expression.iterableValuesWithHost(a, input, host) };
                for (0..repetitions) |repeat_index| pools[repeat_index * inputs.items.len + i] = pool;
            };
            var empty = false;
            for (pools) |pool| if (pool.tuple.len == 0) {
                empty = true;
            };
            return try descriptor(a, "product", &.{ .{ .key = "pools", .value = .{ .list = pools } }, .{ .key = "indices", .value = try indexValues(a, pools.len, false) }, .{ .key = "started", .value = .{ .boolean = false } }, .{ .key = "done", .value = .{ .boolean = empty } } });
        }
        const sources = try expression.allocateValues(a, inputs.items.len);
        const active = try expression.allocateValues(a, inputs.items.len);
        for (inputs.items, sources, active) |input, *source, *state| {
            source.* = try sequence.iter(a, input);
            state.* = .{ .boolean = true };
        }
        return try descriptor(a, "zip_longest", &.{ .{ .key = "sources", .value = .{ .list = sources } }, .{ .key = "active", .value = .{ .list = active } }, .{ .key = "fill", .value = option }, .{ .key = "done", .value = .{ .boolean = sources.len == 0 } } });
    }
    if (std.mem.eql(u8, name, "permutations") or std.mem.eql(u8, name, "combinations") or std.mem.eql(u8, name, "combinations_with_replacement")) {
        const permutations = std.mem.eql(u8, name, "permutations");
        const values = try bind(a, args, &.{ "iterable", "r" }, if (permutations) 1 else 2, 2);
        const pool = try expression.iterableValuesWithHost(a, values[0].?, host);
        const count = if (permutations and (values[1] == null or values[1].? == .none)) pool.len else try nonnegative(values[1].?);
        const replacement = std.mem.eql(u8, name, "combinations_with_replacement");
        const done = if (replacement) pool.len == 0 and count != 0 else count > pool.len;
        const indices = try indexValues(a, if (done) 0 else if (permutations) pool.len else count, !replacement);
        const cycles = try indexValues(a, if (!done and permutations) count else 0, false);
        for (@constCast(cycles.list), 0..) |*cycle, i| cycle.* = try expression.integerValue(a, pool.len - i);
        return try descriptor(a, name, &.{ .{ .key = "pool", .value = .{ .tuple = pool } }, .{ .key = "indices", .value = indices }, .{ .key = "cycles", .value = cycles }, .{ .key = "length", .value = try expression.integerValue(a, count) }, .{ .key = "started", .value = .{ .boolean = false } }, .{ .key = "done", .value = .{ .boolean = done } } });
    }
    return null;
}

pub fn pull(a: Allocator, value: Value, host: ?Host) anyerror!?Value {
    const marker = sequence.kind(value) orelse return error.JinjaTypeError;
    if (!std.mem.startsWith(u8, marker, "itertools_")) return error.JinjaTypeError;
    const name = marker["itertools_".len..];
    if (value.attribute("done").truthy()) return null;
    if (std.mem.eql(u8, name, "count")) {
        if (value.attribute("started").truthy()) set(value, "current", try expression.addValues(a, value.attribute("current"), value.attribute("step"))) else set(value, "started", .{ .boolean = true });
        return value.attribute("current");
    }
    if (std.mem.eql(u8, name, "repeat")) {
        const remaining = try integer(value, "remaining");
        if (remaining == 0) return null;
        if (remaining > 0) try setInteger(a, value, "remaining", remaining - 1);
        return value.attribute("value");
    }
    if (std.mem.eql(u8, name, "cycle")) {
        if (!value.attribute("cached").truthy()) {
            if (try sequence.next(a, value.attribute("source"), host)) |item| {
                try bufferAppend(a, value, item);
                return item;
            }
            set(value, "cached", .{ .boolean = true });
        }
        const length = try integer(value, "length");
        if (length == 0) return null;
        const cursor = try integer(value, "cursor");
        try setInteger(a, value, "cursor", @mod(cursor + 1, length));
        return value.attribute("buffer").list[@intCast(cursor)];
    }
    if (std.mem.eql(u8, name, "accumulate")) {
        if (!value.attribute("started").truthy()) {
            set(value, "started", .{ .boolean = true });
            if (value.attribute("initial").truthy()) return value.attribute("total");
            const first = (try sequence.next(a, value.attribute("source"), host)) orelse return stop(value);
            set(value, "total", first);
            return first;
        }
        const item = (try sequence.next(a, value.attribute("source"), host)) orelse return stop(value);
        const callable = value.attribute("function");
        const total = if (callable == .none) try expression.addValues(a, value.attribute("total"), item) else try callback(a, callable, &.{ value.attribute("total"), item }, host);
        set(value, "total", total);
        return total;
    }
    if (std.mem.eql(u8, name, "chain")) {
        var skipped: usize = 0;
        while (true) {
            const active = value.attribute("active");
            if (active != .none) if (try sequence.next(a, active, host)) |item| return item;
            const input = (try sequence.next(a, value.attribute("source"), host)) orelse return stop(value);
            set(value, "active", .none);
            set(value, "active", try sequence.iter(a, input));
            skipped += 1;
            if (skipped > limit) return error.JinjaIterationLimitExceeded;
        }
    }
    if (std.mem.eql(u8, name, "compress")) {
        for (0..limit) |_| {
            const item = (try sequence.next(a, value.attribute("source"), host)) orelse return stop(value);
            const selected = (try sequence.next(a, value.attribute("selectors"), host)) orelse return stop(value);
            if (selected.truthy()) return item;
        }
        return error.JinjaIterationLimitExceeded;
    }
    if (std.mem.eql(u8, name, "islice")) {
        const next_index = try integer(value, "next");
        const end = value.attribute("stop");
        var counter = try integer(value, "counter");
        const wanted = if (value.attribute("started").truthy() and end != .none) @min(next_index, try expression.integerIndex(end)) else next_index;
        var skipped: usize = 0;
        while (counter < wanted) : (counter += 1) {
            _ = (try sequence.next(a, value.attribute("source"), host)) orelse return stop(value);
            skipped += 1;
            if (skipped > limit) return error.JinjaIterationLimitExceeded;
        }
        try setInteger(a, value, "counter", counter);
        set(value, "started", .{ .boolean = true });
        if (end != .none and next_index >= try expression.integerIndex(end)) return stop(value);
        const item = (try sequence.next(a, value.attribute("source"), host)) orelse return stop(value);
        if (counter == std.math.maxInt(i64)) return error.JinjaIterationLimitExceeded;
        try setInteger(a, value, "counter", counter + 1);
        const step = try integer(value, "step");
        try setInteger(a, value, "next", if (next_index > std.math.maxInt(i64) - step) std.math.maxInt(i64) else next_index + step);
        return item;
    }
    if (std.mem.eql(u8, name, "starmap")) {
        const item = (try sequence.next(a, value.attribute("source"), host)) orelse return null;
        return try callback(a, value.attribute("function"), try expression.iterableValuesWithHost(a, item, host), host);
    }
    if (std.mem.eql(u8, name, "tee")) {
        const shared = value.attribute("shared");
        const cursor: usize = @intCast(try integer(value, "cursor"));
        const length: usize = @intCast(try integer(shared, "length"));
        if (cursor == length) {
            if (shared.attribute("done").truthy()) return null;
            const item = (try sequence.next(a, shared.attribute("source"), host)) orelse {
                set(shared, "done", .{ .boolean = true });
                return null;
            };
            try bufferAppend(a, shared, item);
        }
        try setInteger(a, value, "cursor", @intCast(cursor + 1));
        return shared.attribute("buffer").list[cursor];
    }
    if (std.mem.eql(u8, name, "zip_longest")) {
        const sources = value.attribute("sources").list;
        const active = @constCast(value.attribute("active").list);
        const fields = try expression.allocateValues(a, sources.len);
        var produced = false;
        for (sources, active, fields) |source, *state, *field| {
            field.* = value.attribute("fill");
            if (!state.truthy()) continue;
            if (try sequence.next(a, source, host)) |item| {
                field.* = item;
                produced = true;
            } else state.* = .{ .boolean = false };
        }
        return if (produced) .{ .tuple = fields } else stop(value);
    }
    if (std.mem.eql(u8, name, "product")) {
        const pools = value.attribute("pools").list;
        const indices = @constCast(value.attribute("indices").list);
        if (value.attribute("started").truthy()) {
            var i = indices.len;
            var advanced = false;
            while (i != 0) {
                i -= 1;
                const index: usize = @intCast(try expression.integerIndex(indices[i]));
                if (index + 1 < pools[i].tuple.len) {
                    indices[i] = try expression.integerValue(a, index + 1);
                    advanced = true;
                    break;
                }
                indices[i] = .{ .integer = "0" };
            }
            if (!advanced) return stop(value);
        } else set(value, "started", .{ .boolean = true });
        const row = try expression.allocateValues(a, pools.len);
        for (row, pools, indices) |*field, pool, index| field.* = pool.tuple[@intCast(try expression.integerIndex(index))];
        return .{ .tuple = row };
    }
    if (std.mem.eql(u8, name, "permutations") or std.mem.eql(u8, name, "combinations") or std.mem.eql(u8, name, "combinations_with_replacement")) {
        const pool = value.attribute("pool").tuple;
        const indices = @constCast(value.attribute("indices").list);
        const length: usize = @intCast(try integer(value, "length"));
        if (value.attribute("started").truthy()) {
            var advanced = false;
            var i = length;
            const permutations = std.mem.eql(u8, name, "permutations");
            const replacement = std.mem.eql(u8, name, "combinations_with_replacement");
            const cycles = @constCast(value.attribute("cycles").list);
            while (i != 0) {
                i -= 1;
                if (permutations) {
                    const remaining = try expression.integerIndex(cycles[i]) - 1;
                    cycles[i] = try expression.integerValue(a, remaining);
                    if (remaining == 0) {
                        const first = indices[i];
                        std.mem.copyForwards(Value, indices[i .. indices.len - 1], indices[i + 1 ..]);
                        indices[indices.len - 1] = first;
                        cycles[i] = try expression.integerValue(a, pool.len - i);
                    } else {
                        std.mem.swap(Value, &indices[i], &indices[pool.len - @as(usize, @intCast(remaining))]);
                        advanced = true;
                        break;
                    }
                } else {
                    const index: usize = @intCast(try expression.integerIndex(indices[i]));
                    const maximum = if (replacement) pool.len - 1 else i + pool.len - length;
                    if (index == maximum) continue;
                    indices[i] = try expression.integerValue(a, index + 1);
                    for (i + 1..length) |j| indices[j] = try expression.integerValue(a, index + 1 + if (replacement) @as(usize, 0) else j - i);
                    advanced = true;
                    break;
                }
            }
            if (!advanced) return stop(value);
        } else set(value, "started", .{ .boolean = true });
        const row = try expression.allocateValues(a, length);
        for (row, indices[0..length]) |*field, index| field.* = pool[@intCast(try expression.integerIndex(index))];
        return .{ .tuple = row };
    }
    return error.UnsupportedJinjaCall;
}

/// Representation is independent of consumption; callbacks use the active
/// caller only when a repeated value itself exposes deferred metadata.
pub fn render(a: Allocator, value: Value) anyerror!?[]const u8 {
    return renderWithHost(a, value, null);
}
pub fn renderWithHost(a: Allocator, value: Value, host: ?Host) anyerror!?[]const u8 {
    const marker = sequence.kind(value) orelse return null;
    if (!std.mem.startsWith(u8, marker, "itertools_")) return null;
    const name = marker["itertools_".len..];
    if (std.mem.eql(u8, name, "count")) {
        const step = value.attribute("step");
        const current = if (value.attribute("started").truthy()) try expression.addValues(a, value.attribute("current"), step) else value.attribute("current");
        const text = try expression.reprWithHost(a, current, host);
        if (unitStep(step)) return try std.fmt.allocPrint(a, "count({s})", .{text});
        return try std.fmt.allocPrint(a, "count({s}, {s})", .{ text, try expression.reprWithHost(a, step, host) });
    }
    if (std.mem.eql(u8, name, "repeat")) {
        const text = try expression.reprWithHost(a, value.attribute("value"), host);
        const remaining = try integer(value, "remaining");
        return if (remaining < 0) try std.fmt.allocPrint(a, "repeat({s})", .{text}) else try std.fmt.allocPrint(a, "repeat({s}, {d})", .{ text, remaining });
    }
    return try std.fmt.allocPrint(a, "<itertools.{s} object at 0x{x}>", .{ if (std.mem.eql(u8, name, "tee")) "_tee" else name, @intFromPtr(value.object.ptr) });
}

const TestHost = struct {
    fn resolveValue(_: *anyopaque, path: []const u8, a: Allocator) !Value {
        if (std.mem.eql(u8, path, "modules")) return try object(a, &.{.{ .key = "itertools", .value = (try resolve(a, "modules.itertools")).? }});
        if (std.mem.eql(u8, path, "add")) return .{ .callable = "add" };
        return (try resolve(a, path)) orelse .undefined;
    }
    fn callValue(_: *anyopaque, name: []const u8, args: []const Argument, a: Allocator) anyerror!Value {
        var context: u8 = 0;
        const host = Host{ .context = &context, .resolve = resolveValue, .call = callValue };
        if (std.mem.eql(u8, name, "add")) {
            if (args.len != 2) return error.InvalidJinjaArguments;
            return try expression.addValues(a, args[0].value, args[1].value);
        }
        return (try call(a, name, args, host)) orelse return error.UnsupportedJinjaCall;
    }
};

test "native itertools exports produce lazy typed rows with all pinned constructors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var context: u8 = 0;
    const host = Host{ .context = &context, .resolve = TestHost.resolveValue, .call = TestHost.callValue };
    const cases = [_]struct { authored: []const u8, expected: []const u8 }{
        .{ .authored = "modules.itertools.islice(modules.itertools.count(2,3),4)|list", .expected = "[2, 5, 8, 11]" },
        .{ .authored = "modules.itertools.islice(modules.itertools.count(true,true),3)|list", .expected = "[1, 2, 3]" },
        .{ .authored = "modules.itertools.islice(modules.itertools.cycle([1,2]),5)|list", .expected = "[1, 2, 1, 2, 1]" },
        .{ .authored = "modules.itertools.repeat('x',3)|list", .expected = "['x', 'x', 'x']" },
        .{ .authored = "modules.itertools.accumulate([1,2,3],initial=10)|list", .expected = "[10, 11, 13, 16]" },
        .{ .authored = "modules.itertools.chain.from_iterable([[1],[2,3]])|list", .expected = "[1, 2, 3]" },
        .{ .authored = "modules.itertools.compress('abc',[1,0,1])|list", .expected = "['a', 'c']" },
        .{ .authored = "modules.itertools.islice([0,1,2,3,4],1,5,2)|list", .expected = "[1, 3]" },
        .{ .authored = "modules.itertools.starmap(add,[(1,2),(3,4)])|list", .expected = "[3, 7]" },
        .{ .authored = "modules.itertools.zip_longest([1,2],[3],fillvalue='x')|list", .expected = "[(1, 3), (2, 'x')]" },
        .{ .authored = "modules.itertools.product([1,2],'ab')|list", .expected = "[(1, 'a'), (1, 'b'), (2, 'a'), (2, 'b')]" },
        .{ .authored = "modules.itertools.permutations([1,2,3],2)|list", .expected = "[(1, 2), (1, 3), (2, 1), (2, 3), (3, 1), (3, 2)]" },
        .{ .authored = "modules.itertools.combinations([1,2,3],2)|list", .expected = "[(1, 2), (1, 3), (2, 3)]" },
        .{ .authored = "modules.itertools.combinations_with_replacement([1,2],2)|list", .expected = "[(1, 1), (1, 2), (2, 2)]" },
        .{ .authored = "modules.itertools.product(none,repeat=0)|list", .expected = "[()]" },
        .{ .authored = "modules.itertools.tee(none,0)", .expected = "()" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.expected, try (try expression.evaluate(a, case.authored, host)).text(a));
}

test "native tee aliases and nested branches share source position without advancing peers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = (try call(a, "modules.itertools.count", &.{.{ .value = .{ .integer = "1" } }}, null)).?;
    const branches = (try call(a, "modules.itertools.tee", &.{.{ .value = source }}, null)).?.tuple;
    try std.testing.expectEqualStrings("1", (try sequence.next(a, branches[0], null)).?.integer);
    try std.testing.expectEqualStrings("2", (try sequence.next(a, branches[0], null)).?.integer);
    try std.testing.expectEqualStrings("1", (try sequence.next(a, branches[1], null)).?.integer);
    const nested = (try call(a, "modules.itertools.tee", &.{.{ .value = branches[1] }}, null)).?.tuple;
    try std.testing.expect(nested[0].object.ptr != branches[1].object.ptr);
    try std.testing.expectEqualStrings("2", (try sequence.next(a, nested[1], null)).?.integer);
    try std.testing.expectEqualStrings("3", (try sequence.next(a, branches[0], null)).?.integer);
    try std.testing.expectEqualStrings("2", (try sequence.next(a, nested[0], null)).?.integer);
    try std.testing.expectEqualStrings("2", (try sequence.next(a, branches[1], null)).?.integer);
}

test "native islice drains skipped positions and defers starmap callback errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source = try sequence.iterator(a, &.{ .{ .integer = "0" }, .{ .integer = "1" }, .{ .integer = "2" }, .{ .integer = "3" }, .{ .integer = "4" }, .{ .integer = "5" } });
    const sliced = (try call(a, "modules.itertools.islice", &.{ .{ .value = source }, .{ .value = .{ .integer = "4" } }, .{ .value = .{ .integer = "2" } } }, null)).?;
    try std.testing.expect((try sequence.next(a, sliced, null)) == null);
    try std.testing.expectEqualStrings("4", (try sequence.next(a, source, null)).?.integer);
    const mapped = (try call(a, "modules.itertools.starmap", &.{ .{ .value = .none }, .{ .value = .{ .list = &.{.{ .tuple = &.{} }} } } }, null)).?;
    try std.testing.expectError(error.JinjaTypeError, sequence.next(a, mapped, null));
    const deferred = (try call(a, "modules.itertools.chain", &.{.{ .value = .none }}, null)).?;
    try std.testing.expectError(error.JinjaTypeError, sequence.next(a, deferred, null));
}

test "native tee and cycle growth retains the values shared by iterator aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const items = try expression.allocateValues(a, 40);
    for (items, 0..) |*item, i| item.* = try object(a, &.{.{ .key = "n", .value = try expression.integerValue(a, i) }});
    const branches = (try call(a, "modules.itertools.tee", &.{.{ .value = .{ .list = items } }}, null)).?.tuple;
    for (items) |item| try std.testing.expect(item.object.ptr == (try sequence.next(a, branches[0], null)).?.object.ptr);
    try std.testing.expect((try sequence.next(a, branches[0], null)) == null);
    for (items) |item| try std.testing.expect(item.object.ptr == (try sequence.next(a, branches[1], null)).?.object.ptr);
    try std.testing.expect((try sequence.next(a, branches[1], null)) == null);
    const cycle = (try call(a, "modules.itertools.cycle", &.{.{ .value = .{ .list = items } }}, null)).?;
    for (0..120) |i| try std.testing.expect(items[i % items.len].object.ptr == (try sequence.next(a, cycle, null)).?.object.ptr);
}

test "native count and repeat representations reflect next state without consuming it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const count = (try call(a, "modules.itertools.count", &.{ .{ .value = .{ .integer = "1" } }, .{ .value = .{ .number = 1.0 } } }, null)).?;
    try std.testing.expectEqualStrings("count(1, 1.0)", (try render(a, count)).?);
    try std.testing.expectEqualStrings("1", (try sequence.next(a, count, null)).?.integer);
    try std.testing.expectEqualStrings("count(2.0, 1.0)", (try render(a, count)).?);
    try std.testing.expectEqualStrings("count(2.0, 1.0)", (try render(a, count)).?);
    try std.testing.expectEqual(@as(f64, 2), try expression.numericFloat((try sequence.next(a, count, null)).?));
    const repeat = (try call(a, "modules.itertools.repeat", &.{ .{ .value = .{ .string = "x" } }, .{ .value = .{ .integer = "2" } } }, null)).?;
    try std.testing.expectEqualStrings("repeat('x', 2)", (try render(a, repeat)).?);
    _ = try sequence.next(a, repeat, null);
    try std.testing.expectEqualStrings("repeat('x', 1)", (try render(a, repeat)).?);
    _ = try sequence.next(a, repeat, null);
    try std.testing.expectEqualStrings("repeat('x', 0)", (try render(a, repeat)).?);
}

test "attr filter hides iterator state while validating its arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const iterator = (try call(a, "modules.itertools.count", &.{}, null)).?;
    const field = [_]Argument{.{ .value = .{ .string = "current" } }};
    try std.testing.expect((try expression.filterValue(a, "attr", iterator, &field, null)) == .undefined);
    try std.testing.expectError(error.InvalidJinjaArguments, expression.filterValue(a, "attr", iterator, &.{}, null));
    const invalid = [_]Argument{ .{ .value = .{ .string = "current" } }, .{ .value = .{ .string = "other" } } };
    try std.testing.expectError(error.InvalidJinjaArguments, expression.filterValue(a, "attr", iterator, &invalid, null));
}
