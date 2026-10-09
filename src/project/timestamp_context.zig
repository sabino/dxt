//! Native UTC datetime values exposed by dbt's microbatch model context.
const std = @import("std");
const expression = @import("expression.zig");
const calendar = @import("workflow_intervals.zig");
const Value = expression.Value;
const Argument = expression.Argument;

pub fn value(a: std.mem.Allocator, epoch_ns: i96) !Value {
    return datetimeValue(a, epoch_ns, false);
}

fn datetimeValue(a: std.mem.Allocator, epoch_ns: i96, date_only: bool) !Value {
    const label = try calendar.formatTimestamp(a, @intCast(@divFloor(epoch_ns, std.time.ns_per_s)));
    const micros: u64 = @intCast(@divFloor(@mod(epoch_ns, std.time.ns_per_s), std.time.ns_per_us));
    const rendered = if (date_only) try a.dupe(u8, label[0..10]) else try isoformat(a, epoch_ns, " ", "auto");
    var entries: std.ArrayList(expression.Entry) = .empty;
    try entries.append(a, .{ .key = "__dxt_rendered", .value = .{ .string = rendered } });
    inline for (.{ .{ "year", 0, 4 }, .{ "month", 5, 7 }, .{ "day", 8, 10 }, .{ "hour", 11, 13 }, .{ "minute", 14, 16 }, .{ "second", 17, 19 } }) |field| {
        if (!date_only or field[1] < 10) try entries.append(a, .{ .key = field[0], .value = .{ .number = @floatFromInt(try std.fmt.parseInt(u64, label[field[1]..field[2]], 10)) } });
    }
    if (!date_only) try entries.appendSlice(a, &.{ .{ .key = "microsecond", .value = .{ .number = @floatFromInt(micros) } }, .{ .key = "tzinfo", .value = .{ .string = "UTC" } } });
    for ([_][]const u8{ "strftime", "isoformat", "date", "timestamp", "weekday", "isoweekday", "replace" }) |method| {
        try entries.append(a, .{ .key = method, .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_datetime:{s}:{d}:{s}", .{ method, epoch_ns, if (date_only) "date" else "datetime" }) } });
    }
    return .{ .object = try entries.toOwnedSlice(a) };
}

fn named(args: []const Argument, name: []const u8, position: usize) ?Value {
    for (args) |arg| if (arg.name) |key| if (std.mem.eql(u8, key, name)) return arg.value;
    var index: usize = 0;
    for (args) |arg| if (arg.name == null) {
        if (index == position) return arg.value;
        index += 1;
    };
    return null;
}

fn textArg(args: []const Argument, name: []const u8, position: usize, fallback: []const u8) ![]const u8 {
    const v = named(args, name, position) orelse return fallback;
    if (v != .string) return error.JinjaTypeError;
    return v.string;
}

pub fn call(a: std.mem.Allocator, name: []const u8, args: []const Argument) !?Value {
    const prefix = "__dxt_datetime:";
    if (!std.mem.startsWith(u8, name, prefix)) return null;
    var parts = std.mem.splitScalar(u8, name[prefix.len..], ':');
    const method = parts.next() orelse return error.InvalidDatetime;
    const ns = std.fmt.parseInt(i96, parts.next() orelse return error.InvalidDatetime, 10) catch return error.InvalidDatetime;
    const date_only = std.mem.eql(u8, parts.next() orelse return error.InvalidDatetime, "date");
    if (std.mem.eql(u8, method, "strftime")) return .{ .string = try strftime(a, ns, try textArg(args, "format", 0, ""), date_only) };
    if (std.mem.eql(u8, method, "isoformat")) {
        if (date_only) {
            const label = try calendar.formatTimestamp(a, @intCast(@divFloor(ns, std.time.ns_per_s)));
            return .{ .string = try a.dupe(u8, label[0..10]) };
        }
        return .{ .string = try isoformat(a, ns, try textArg(args, "sep", 0, "T"), try textArg(args, "timespec", 1, "auto")) };
    }
    if (std.mem.eql(u8, method, "date")) return try datetimeValue(a, @divFloor(ns, std.time.ns_per_day) * std.time.ns_per_day, true);
    if (std.mem.eql(u8, method, "timestamp") and !date_only) return .{ .number = @as(f64, @floatFromInt(ns)) / std.time.ns_per_s };
    const day = @divFloor(ns, std.time.ns_per_day);
    if (std.mem.eql(u8, method, "weekday")) return .{ .number = @floatFromInt(@mod(day + 3, 7)) };
    if (std.mem.eql(u8, method, "isoweekday")) return .{ .number = @floatFromInt(@mod(day + 3, 7) + 1) };
    if (std.mem.eql(u8, method, "replace")) {
        const original = try calendar.formatTimestamp(a, @intCast(@divFloor(ns, std.time.ns_per_s)));
        var fields: [7]u64 = undefined;
        inline for (.{ .{ "year", 0, 4 }, .{ "month", 5, 7 }, .{ "day", 8, 10 }, .{ "hour", 11, 13 }, .{ "minute", 14, 16 }, .{ "second", 17, 19 } }, 0..) |field, index| {
            fields[index] = try std.fmt.parseInt(u64, original[field[1]..field[2]], 10);
            if (named(args, field[0], index)) |replacement| fields[index] = try integer(replacement);
        }
        fields[6] = @intCast(@divFloor(@mod(ns, std.time.ns_per_s), std.time.ns_per_us));
        if (named(args, "microsecond", 6)) |replacement| fields[6] = try integer(replacement);
        if (fields[6] > 999999) return error.InvalidDatetime;
        const label = try std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ fields[0], fields[1], fields[2], fields[3], fields[4], fields[5] });
        const timestamp = @as(i96, calendar.parseTimestamp(label) catch return error.InvalidDatetime) * std.time.ns_per_s;
        return try datetimeValue(a, timestamp + @as(i96, @intCast(fields[6])) * std.time.ns_per_us, date_only);
    }
    return error.JinjaTypeError;
}

fn integer(v: Value) !u64 {
    if (v != .number or !std.math.isFinite(v.number) or v.number < 0 or v.number > 999999999 or @floor(v.number) != v.number) return error.JinjaTypeError;
    return @intFromFloat(v.number);
}

fn isoformat(a: std.mem.Allocator, ns: i96, separator: []const u8, timespec: []const u8) ![]const u8 {
    if ((std.unicode.utf8CountCodepoints(separator) catch return error.JinjaTypeError) != 1) return error.JinjaTypeError;
    const label = try calendar.formatTimestamp(a, @intCast(@divFloor(ns, std.time.ns_per_s)));
    const micros: u64 = @intCast(@divFloor(@mod(ns, std.time.ns_per_s), std.time.ns_per_us));
    const spec = if (std.mem.eql(u8, timespec, "auto")) (if (micros == 0) "seconds" else "microseconds") else timespec;
    const length: usize = if (std.mem.eql(u8, spec, "hours")) 13 else if (std.mem.eql(u8, spec, "minutes")) 16 else if (std.mem.eql(u8, spec, "seconds") or std.mem.eql(u8, spec, "milliseconds") or std.mem.eql(u8, spec, "microseconds")) 19 else return error.InvalidDatetimeTimespec;
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.print("{s}{s}{s}", .{ label[0..10], separator, label[11..length] });
    if (std.mem.eql(u8, spec, "milliseconds")) try out.writer.print(".{d:0>3}", .{micros / 1000});
    if (std.mem.eql(u8, spec, "microseconds")) try out.writer.print(".{d:0>6}", .{micros});
    try out.writer.writeAll("+00:00");
    return out.toOwnedSlice();
}

fn strftime(a: std.mem.Allocator, ns: i96, format: []const u8, date_only: bool) ![]const u8 {
    const label = try calendar.formatTimestamp(a, @intCast(@divFloor(ns, std.time.ns_per_s)));
    const micros: u64 = if (date_only) 0 else @intCast(@divFloor(@mod(ns, std.time.ns_per_s), std.time.ns_per_us));
    const days: i64 = @intCast(@divFloor(ns, std.time.ns_per_day));
    const weekday: usize = @intCast(@mod(days + 4, 7));
    const year_start = try calendar.parseTimestamp(try std.fmt.allocPrint(a, "{s}-01-01", .{label[0..4]}));
    const year_day: u64 = @intCast(days - @divFloor(year_start, 86400) + 1);
    const hour = try std.fmt.parseInt(u64, label[11..13], 10);
    const month = try std.fmt.parseInt(usize, label[5..7], 10);
    const week_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
    const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
    var out: std.Io.Writer.Allocating = .init(a);
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        if (format[i] != '%' or i + 1 == format.len) {
            try out.writer.writeByte(format[i]);
            continue;
        }
        i += 1;
        switch (format[i]) {
            '%' => try out.writer.writeByte('%'),
            'Y' => try out.writer.writeAll(label[0..4]),
            'y' => try out.writer.writeAll(label[2..4]),
            'm' => try out.writer.writeAll(label[5..7]),
            'd' => try out.writer.writeAll(label[8..10]),
            'H' => try out.writer.writeAll(if (date_only) "00" else label[11..13]),
            'I' => try out.writer.print("{d:0>2}", .{if (date_only or @mod(hour, 12) == 0) @as(u64, 12) else @mod(hour, 12)}),
            'M' => try out.writer.writeAll(if (date_only) "00" else label[14..16]),
            'S' => try out.writer.writeAll(if (date_only) "00" else label[17..19]),
            'f' => try out.writer.print("{d:0>6}", .{micros}),
            'p' => try out.writer.writeAll(if (date_only or hour < 12) "AM" else "PM"),
            'z' => if (!date_only) try out.writer.writeAll("+0000"),
            'Z' => if (!date_only) try out.writer.writeAll("UTC"),
            'j' => try out.writer.print("{d:0>3}", .{year_day}),
            'w' => try out.writer.print("{d}", .{weekday}),
            'u' => try out.writer.print("{d}", .{@mod(weekday + 6, 7) + 1}),
            'a' => try out.writer.writeAll(week_names[weekday][0..3]),
            'A' => try out.writer.writeAll(week_names[weekday]),
            'b', 'h' => try out.writer.writeAll(month_names[month - 1][0..3]),
            'B' => try out.writer.writeAll(month_names[month - 1]),
            'F' => try out.writer.writeAll(label[0..10]),
            'T' => try out.writer.writeAll(if (date_only) "00:00:00" else label[11..19]),
            'n' => try out.writer.writeByte('\n'),
            't' => try out.writer.writeByte('\t'),
            else => try out.writer.print("%{c}", .{format[i]}),
        }
    }
    return out.toOwnedSlice();
}

test "native UTC datetime values retain microseconds and Python ISO/format behavior" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ns = @as(i96, try calendar.parseTimestamp("2024-02-29 16:17:18")) * std.time.ns_per_s + 123456 * std.time.ns_per_us;
    const dt = try value(a, ns);
    try std.testing.expectEqualStrings("2024-02-29 16:17:18.123456+00:00", try dt.text(a));
    const formatted = (try call(a, dt.attribute("strftime").callable, &.{.{ .value = .{ .string = "%Y-%m-%d %H:%M:%S.%f %z %Z %A %j" } }})).?;
    try std.testing.expectEqualStrings("2024-02-29 16:17:18.123456 +0000 UTC Thursday 060", formatted.string);
    try std.testing.expectEqualStrings("2024-02-29T16:17:18.123+00:00", (try call(a, dt.attribute("isoformat").callable, &.{.{ .name = "timespec", .value = .{ .string = "milliseconds" } }})).?.string);
    const date = (try call(a, dt.attribute("date").callable, &.{})).?;
    try std.testing.expectEqualStrings("2024-02-29", try date.text(a));
    const replaced = (try call(a, dt.attribute("replace").callable, &.{ .{ .name = "hour", .value = .{ .number = 0 } }, .{ .name = "microsecond", .value = .{ .number = 0 } } })).?;
    try std.testing.expectEqualStrings("2024-02-29 00:17:18+00:00", try replaced.text(a));
    try std.testing.expectEqual(@as(f64, 3), (try call(a, dt.attribute("weekday").callable, &.{})).?.number);
}
