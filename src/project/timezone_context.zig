//! Native pytz provider backed by pinned IANA transition tables.
//! The embedded records reproduce pytz's historical rounding and DST deltas.
const std = @import("std");
const expr = @import("expression.zig");
const sets = @import("set_context.zig");
const dates = @import("timestamp_context.zig");
const builtin = @import("timezone_builtin.zig");
const Value = expr.Value;
const Argument = expr.Argument;
const Allocator = std.mem.Allocator;
const database = @import("pytz_data").data;
pub const version = "2026.5";
pub const iana_version = "2026e";
pub const exports = [_][]const u8{ "timezone", "utc", "country_timezones", "country_names", "AmbiguousTimeError", "InvalidTimeError", "NonExistentTimeError", "UnknownTimeZoneError", "all_timezones", "all_timezones_set", "common_timezones", "common_timezones_set", "BaseTzInfo", "FixedOffset" };
const zone_count = read(u32, 8);
const transition_count = read(u32, 12);
const country_count = read(u32, 16);
const country_zone_count = read(u32, 20);
const common_count = read(u32, 24);
const zones_at = 32;
const transitions_at = zones_at + zone_count * 16;
const countries_at = transitions_at + transition_count * 20;
const country_zones_at = countries_at + country_count * 16;
const common_at = country_zones_at + country_zone_count * 4;
const strings_at = common_at + common_count * 4;

fn read(comptime T: type, at: usize) T {
    return std.mem.readInt(T, database[at..][0..@sizeOf(T)], .little);
}
fn text(at: u32) []const u8 {
    const start = strings_at + at;
    return database[start .. start + std.mem.indexOfScalar(u8, database[start..], 0).?];
}
const Zone = struct {
    index: u32,
    name: []const u8,
    start: u32,
    count: u32,
    dynamic: bool,
};
fn zoneAt(index: u32) Zone {
    const at = zones_at + index * 16;
    return .{ .index = index, .name = text(read(u32, at)), .start = read(u32, at + 4), .count = read(u32, at + 8), .dynamic = read(u32, at + 12) != 0 };
}
fn findZone(name: []const u8) !Zone {
    for (0..zone_count) |index| {
        const zone = zoneAt(@intCast(index));
        if (std.ascii.eqlIgnoreCase(zone.name, name)) return zone;
    }
    return error.UnknownTimeZoneError;
}
pub const Info = struct {
    offset_seconds: i32,
    dst_seconds: i32,
    abbreviation: []const u8,
};
fn transitionTime(zone: Zone, at: u32) i64 {
    return read(i64, transitions_at + (zone.start + at) * 20);
}
fn transitionInfo(zone: Zone, at: u32) Info {
    const position = transitions_at + (zone.start + at) * 20;
    return .{ .offset_seconds = read(i32, position + 8), .dst_seconds = read(i32, position + 12), .abbreviation = text(read(u32, position + 16)) };
}
fn infoAt(zone: Zone, utc_seconds: i64) Info {
    var low: u32 = 0;
    var high: u32 = zone.count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (transitionTime(zone, middle) <= utc_seconds) low = middle + 1 else high = middle;
    }
    return transitionInfo(zone, if (low == 0) 0 else low - 1);
}
pub fn offsetAtUtc(zone_name: []const u8, utc_seconds: i64) !Info {
    return infoAt(try findZone(zone_name), utc_seconds);
}
fn sameInfo(lhs: Info, rhs: Info) bool {
    return lhs.offset_seconds == rhs.offset_seconds and lhs.dst_seconds == rhs.dst_seconds and std.mem.eql(u8, lhs.abbreviation, rhs.abbreviation);
}
fn localInfo(zone: Zone, civil_seconds: i64, is_dst: ?bool, depth: u8) !Info {
    // This is pytz's normalize-and-test algorithm. It also handles historical
    // transitions unrelated to DST, negative DST and international datelines.
    var candidates: [2]Info = undefined;
    var count: usize = 0;
    for ([_]i64{ -86400, 86400 }) |delta| {
        const nearby = civil_seconds + delta;
        if (nearby < -62135596800 or nearby > 253402300799) continue;
        const tentative = infoAt(zone, nearby);
        const utc_seconds = civil_seconds - tentative.offset_seconds;
        if (utc_seconds < -62135596800 or utc_seconds > 253402300799) return error.JinjaNumericOverflow;
        const normalized = infoAt(zone, utc_seconds);
        if (normalized.offset_seconds == tentative.offset_seconds) {
            if (count == 0 or !sameInfo(candidates[0], normalized)) {
                candidates[count] = normalized;
                count += 1;
            }
        }
    }
    if (count == 1) return candidates[0];
    if (count == 0) {
        const preference = is_dst orelse return error.NonExistentTimeError;
        if (depth > 4) return error.InvalidTimeError;
        return localInfo(zone, civil_seconds + @as(i64, if (preference) 21600 else -21600), preference, depth + 1);
    }
    const preference = is_dst orelse return error.AmbiguousTimeError;
    const first_matches = (candidates[0].dst_seconds != 0) == preference;
    const second_matches = (candidates[1].dst_seconds != 0) == preference;
    if (first_matches != second_matches) return candidates[if (first_matches) 0 else 1];
    // Earliest UTC for is_dst=True, latest UTC for False.
    const first_earlier = candidates[0].offset_seconds > candidates[1].offset_seconds;
    return candidates[if (first_earlier == preference) 0 else 1];
}
pub fn localizeInfo(zone_name: []const u8, civil_seconds: i64, is_dst: ?bool) !Info {
    return localInfo(try findZone(zone_name), civil_seconds, is_dst, 0);
}
fn object(a: Allocator, entries: []const expr.Entry) !Value {
    return .{ .object = try a.dupe(expr.Entry, entries) };
}
fn global(name: []const u8) Value {
    return .{ .callable = name };
}
fn zoneList(a: Allocator, common: bool) !Value {
    const values = try expr.allocateValues(a, if (common) common_count else zone_count);
    for (values, 0..) |*member, index| member.* = .{ .string = if (common) text(read(u32, common_at + index * 4)) else zoneAt(@intCast(index)).name };
    return .{ .list = values };
}
pub fn countryLookup(a: Allocator, kind: []const u8, key: Value) !Value {
    if (key.attribute("__dxt_binary") == .string) return .undefined;
    if (key != .string) return error.InvalidCountryCode;
    const uppercase = try @import("expression_unicode.zig").convert(a, key.string, .upper);
    for (0..country_count) |index| {
        const at = countries_at + index * 16;
        if (!std.ascii.eqlIgnoreCase(text(read(u32, at)), uppercase)) continue;
        if (std.mem.eql(u8, kind, "names")) return .{ .string = text(read(u32, at + 4)) };
        const count = read(u32, at + 12);
        if (count == 0) return .undefined;
        const start = read(u32, at + 8);
        const values = try expr.allocateValues(a, count);
        for (values, 0..) |*value, n| value.* = .{ .string = text(read(u32, country_zones_at + (start + n) * 4)) };
        return .{ .list = values };
    }
    return .undefined;
}
fn countries(a: Allocator, kind: []const u8) !Value {
    var entries: std.ArrayList(expr.Entry) = .empty;
    for (0..country_count) |index| {
        const code = text(read(u32, countries_at + index * 16));
        const value = try countryLookup(a, kind, .{ .string = code });
        if (!expr.isUndefined(value)) try entries.append(a, .{ .key = code, .value = value });
    }
    // The wrapper keeps the visible entries free of implementation metadata.
    return object(a, &.{
        .{ .key = "__dxt_native_mapping", .value = .{ .callable = "__dxt_native_mapping" } },
        .{ .key = "__dxt_mapping_uppercase", .value = .{ .boolean = true } },
        .{ .key = "__dxt_mapping_source", .value = .{ .object = try entries.toOwnedSlice(a) } },
    });
}
fn classValue(a: Allocator, name: []const u8) !Value {
    const module = if (std.mem.eql(u8, name, "BaseTzInfo")) "tzinfo" else "exceptions";
    return object(a, &.{
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_class_identity", .value = .{ .string = try std.fmt.allocPrint(a, "pytz.{s}.{s}", .{ module, name }) } },
        .{ .key = "__dxt_callable", .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_pytz_class:{s}", .{name}) } },
        .{ .key = "__dxt_rendered", .value = .{ .string = try std.fmt.allocPrint(a, "<class 'pytz.{s}.{s}'>", .{ module, name }) } },
        .{ .key = "zone", .value = .none },
    });
}
var base_instance_ids: std.atomic.Value(u64) = .init(1);
fn exportValue(a: Allocator, name: []const u8) !Value {
    if (std.mem.eql(u8, name, "timezone")) return global("modules.pytz.timezone");
    if (std.mem.eql(u8, name, "FixedOffset")) return global("modules.pytz.FixedOffset");
    if (std.mem.eql(u8, name, "utc")) return try timezoneValue(a, "UTC", null);
    if (std.mem.startsWith(u8, name, "country_")) return countries(a, if (std.mem.eql(u8, name, "country_names")) "names" else "timezones");
    if (std.mem.startsWith(u8, name, "all_timezones") or std.mem.startsWith(u8, name, "common_timezones")) {
        const list = try zoneList(a, std.mem.startsWith(u8, name, "common_"));
        return if (std.mem.endsWith(u8, name, "_set")) try sets.construct(a, list) else list;
    }
    return try classValue(a, name);
}
pub fn resolve(a: Allocator, path: []const u8) !?Value {
    if (std.mem.eql(u8, path, "modules.pytz")) {
        const entries = try expr.allocateEntries(a, exports.len);
        for (exports, entries) |name, *entry| entry.* = .{ .key = name, .value = try exportValue(a, name) };
        return .{ .object = entries };
    }
    const prefix = "modules.pytz.";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    var parts = std.mem.splitScalar(u8, path[prefix.len..], '.');
    const name = parts.next().?;
    for (exports) |export_name| if (std.mem.eql(u8, name, export_name)) {
        var result = try exportValue(a, name);
        while (parts.next()) |attribute| result = try expr.checkedAttribute(result, attribute);
        return result;
    };
    return .undefined;
}
const Identity = struct { zone: i32, offset_us: i64, dst_us: i64, abbreviation: []const u8 };
fn identityText(a: Allocator, id: Identity) ![]const u8 {
    return std.fmt.allocPrint(a, "{d}:{d}:{d}:{s}", .{ id.zone, id.offset_us, id.dst_us, id.abbreviation });
}
fn timezoneObject(a: Allocator, id: Identity) !Value {
    const utc = id.zone >= 0 and std.mem.eql(u8, zoneAt(@intCast(id.zone)).name, "UTC");
    const fixed = id.zone == -1;
    const base = id.zone == -2;
    const zone_name = if (id.zone >= 0) zoneAt(@intCast(id.zone)).name else if (fixed) try std.fmt.allocPrint(a, "pytz.FixedOffset({d})", .{if (std.mem.startsWith(u8, id.abbreviation, "fixed=")) @as(i64, @intFromFloat(try std.fmt.parseFloat(f64, id.abbreviation[6..]))) else @divTrunc(id.offset_us, std.time.us_per_min)}) else "";
    const display = if (base) "<pytz.tzinfo.BaseTzInfo object>" else zone_name;
    const info = try identityText(a, id);
    const representation = if (utc) "<UTC>" else if (fixed) zone_name else if (base) display else if (!zoneAt(@intCast(id.zone)).dynamic) try std.fmt.allocPrint(a, "<StaticTzInfo '{s}'>", .{zone_name}) else try std.fmt.allocPrint(a, "<DstTzInfo '{s}' {s}{s}{s} {s}>", .{ zone_name, id.abbreviation, if (id.offset_us >= 0) @as([]const u8, "+") else "", try durationText(a, id.offset_us), if (id.dst_us == 0) @as([]const u8, "STD") else "DST" });
    var entries: std.ArrayList(expr.Entry) = .empty;
    try entries.appendSlice(a, &.{
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_rendered", .value = .{ .string = display } },
        .{ .key = "__dxt_string_error", .value = .{ .boolean = base } },
        .{ .key = "__dxt_repr", .value = .{ .string = representation } },
        .{ .key = "__dxt_timezone_offset", .value = try expr.integerValue(a, @divTrunc(id.offset_us, std.time.us_per_min)) },
        .{ .key = "__dxt_timezone_offset_us", .value = try expr.integerValue(a, id.offset_us) },
        .{ .key = "__dxt_timezone_dst_us", .value = try expr.integerValue(a, id.dst_us) },
        .{ .key = "__dxt_timezone_name", .value = .{ .string = zone_name } },
        .{ .key = "__dxt_timezone_abbreviation", .value = if (fixed or base) .none else .{ .string = id.abbreviation } },
        .{ .key = "__dxt_timezone_identity", .value = .{ .string = info } },
        .{ .key = "zone", .value = if (fixed or base) .none else .{ .string = zone_name } },
    });
    for ([_][]const u8{ "localize", "normalize", "utcoffset", "dst", "tzname", "fromutc" }) |method| {
        if (base and (std.mem.eql(u8, method, "localize") or std.mem.eql(u8, method, "normalize"))) continue;
        try entries.append(a, .{ .key = method, .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_pytz_method:{s}:{s}", .{ method, info }) } });
    }
    return .{ .object = try entries.toOwnedSlice(a) };
}
pub fn timezoneValue(a: Allocator, name: []const u8, localized: ?Info) !Value {
    const zone = try findZone(name);
    const info = localized orelse transitionInfo(zone, 0);
    return timezoneObject(a, .{ .zone = @intCast(zone.index), .offset_us = @as(i64, info.offset_seconds) * std.time.us_per_s, .dst_us = @as(i64, info.dst_seconds) * std.time.us_per_s, .abbreviation = info.abbreviation });
}
pub fn builtinValue(a: Allocator, offset_us: i64, name: ?[]const u8) !Value {
    return builtin.value(a, offset_us, name);
}
pub fn atUtc(a: Allocator, timezone: Value, utc_seconds: i64) !Value {
    if (timezone.attribute("__dxt_timezone_builtin").truthy()) return timezone;
    const name = timezone.attribute("__dxt_timezone_name");
    if (name != .string) return error.JinjaTypeError;
    if (std.mem.startsWith(u8, name.string, "pytz.FixedOffset(")) return timezone;
    return timezoneValue(a, name.string, try offsetAtUtc(name.string, utc_seconds));
}
fn durationText(a: Allocator, micros: i64) ![]const u8 {
    const days = @divFloor(micros, std.time.us_per_day);
    const remainder = @mod(micros, std.time.us_per_day);
    const seconds: u64 = @intCast(@divFloor(remainder, std.time.us_per_s));
    const fraction: u64 = @intCast(@mod(remainder, std.time.us_per_s));
    var writer: std.Io.Writer.Allocating = .init(a);
    if (days != 0) try writer.writer.print("{d} day{s}, ", .{ days, if (days == 1 or days == -1) @as([]const u8, "") else "s" });
    try writer.writer.print("{d}:{d:0>2}:{d:0>2}", .{ @divFloor(seconds, 3600), @divFloor(@mod(seconds, 3600), 60), @mod(seconds, 60) });
    if (fraction != 0) try writer.writer.print(".{d:0>6}", .{fraction});
    return writer.toOwnedSlice();
}
pub fn durationValue(a: Allocator, micros: i64) !Value {
    return object(a, &.{
        .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
        .{ .key = "__dxt_duration", .value = try expr.integerValue(a, micros) },
        .{ .key = "__dxt_rendered", .value = .{ .string = try durationText(a, micros) } },
        .{ .key = "days", .value = try expr.integerValue(a, @divFloor(micros, std.time.us_per_day)) },
        .{ .key = "seconds", .value = try expr.integerValue(a, @divFloor(@mod(micros, std.time.us_per_day), std.time.us_per_s)) },
        .{ .key = "microseconds", .value = try expr.integerValue(a, @mod(micros, std.time.us_per_s)) },
        .{ .key = "total_seconds", .value = .{ .callable = try std.fmt.allocPrint(a, "__dxt_pytz_duration:{d}", .{micros}) } },
    });
}

fn unmunged(a: Allocator, name: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < name.len) {
        if (std.mem.startsWith(u8, name[i..], "_plus_")) {
            try result.append(a, '+');
            i += 6;
        } else if (std.mem.startsWith(u8, name[i..], "_minus_")) {
            try result.append(a, '-');
            i += 7;
        } else {
            try result.append(a, name[i]);
            i += 1;
        }
    }
    return result.toOwnedSlice(a);
}
fn parseIdentity(encoded: []const u8) !Identity {
    var parts = std.mem.splitScalar(u8, encoded, ':');
    const id: Identity = .{
        .zone = try std.fmt.parseInt(i32, parts.next() orelse return error.InvalidTimeZone, 10),
        .offset_us = try std.fmt.parseInt(i64, parts.next() orelse return error.InvalidTimeZone, 10),
        .dst_us = try std.fmt.parseInt(i64, parts.next() orelse return error.InvalidTimeZone, 10),
        .abbreviation = parts.rest(),
    };
    if (id.zone < -2 or id.zone >= zone_count) return error.InvalidTimeZone;
    return id;
}
pub fn isTimezone(value: Value) bool {
    return value == .object and value.attribute("__dxt_timezone_identity") == .string and value.attribute("utcoffset") == .callable;
}
pub fn fromIdentity(a: Allocator, encoded: []const u8) !Value {
    if (std.mem.startsWith(u8, encoded, "abstract_datetime:")) return @import("datetime_tzinfo.zig").fromIdentity(a, encoded);
    if (std.mem.startsWith(u8, encoded, "builtin:")) return builtin.fromIdentity(a, encoded);
    return timezoneObject(a, try parseIdentity(encoded));
}
fn parameter(args: []const Argument, name: []const u8, position: usize) ?Value {
    for (args) |arg| if (arg.name) |key| if (std.mem.eql(u8, key, name)) return arg.value;
    var index: usize = 0;
    for (args) |arg| if (arg.name == null) {
        if (index == position) return arg.value;
        index += 1;
    };
    return null;
}
fn bindMethod(args: []const Argument, extra: bool) !void {
    var supplied: [2]bool = @splat(false);
    var positional: usize = 0;
    for (args) |arg| {
        const at = if (arg.name) |key| (if (std.mem.eql(u8, key, "dt")) @as(usize, 0) else if (extra and std.mem.eql(u8, key, "is_dst")) 1 else return error.InvalidJinjaArguments) else blk: {
            const at = positional;
            positional += 1;
            break :blk at;
        };
        if (at >= (if (extra) @as(usize, 2) else 1) or supplied[at]) return error.InvalidJinjaArguments;
        supplied[at] = true;
    }
    if (!supplied[0]) return error.InvalidJinjaArguments;
}
fn methodCall(a: Allocator, encoded: []const u8, args: []const Argument) anyerror!Value {
    var parts = std.mem.splitScalar(u8, encoded, ':');
    const method = parts.next() orelse return error.InvalidTimeZone;
    const id = try parseIdentity(parts.rest());
    const utc = id.zone >= 0 and std.mem.eql(u8, zoneAt(@intCast(id.zone)).name, "UTC");
    const dynamic = id.zone >= 0 and zoneAt(@intCast(id.zone)).dynamic;
    const accessor = std.mem.eql(u8, method, "utcoffset") or std.mem.eql(u8, method, "dst") or std.mem.eql(u8, method, "tzname");
    const localize = std.mem.eql(u8, method, "localize");
    const normalize = std.mem.eql(u8, method, "normalize");
    const fromutc = std.mem.eql(u8, method, "fromutc");
    if (!accessor and !localize and !normalize and !fromutc) return error.UndefinedJinjaValue;
    try bindMethod(args, localize or (normalize and !dynamic) or (accessor and id.zone >= 0 and !utc));
    if (id.zone == -2) return error.AbstractTimeZoneMethod;
    const dt = parameter(args, "dt", 0).?;
    const is_dst_value: Value = parameter(args, "is_dst", 1) orelse if (accessor) .none else .{ .boolean = false };
    const is_dst: ?bool = if (is_dst_value == .none) null else is_dst_value.truthy();
    if (accessor and !dynamic) {
        if (std.mem.eql(u8, method, "tzname")) return if (id.zone < 0) .none else .{ .string = id.abbreviation };
        return try durationValue(a, if (std.mem.eql(u8, method, "dst")) id.dst_us else id.offset_us);
    }
    if (accessor and dt == .none) return if (std.mem.eql(u8, method, "tzname")) .{ .string = zoneAt(@intCast(id.zone)).name } else .none;
    const temporal = dates.state(dt) orelse return error.JinjaTypeError;
    if (temporal.date_only) return error.JinjaTypeError;
    const receiver = try timezoneObject(a, id);
    const own_identity = receiver.attribute("__dxt_timezone_identity").string;
    const actual_identity = if (temporal.timezone) |zone| zone.attribute("__dxt_timezone_identity") else .undefined;
    const same_timezone = actual_identity == .string and std.mem.eql(u8, own_identity, actual_identity.string);
    if (localize or (accessor and !same_timezone)) {
        if (temporal.offset_us != null) return error.AlreadyAwareDatetime;
        const info = if (dynamic) try localizeInfo(zoneAt(@intCast(id.zone)).name, @intCast(@divFloor(temporal.civil_ns, std.time.ns_per_s)), is_dst) else Info{ .offset_seconds = @intCast(@divTrunc(id.offset_us, std.time.us_per_s)), .dst_seconds = 0, .abbreviation = id.abbreviation };
        const zone = if (dynamic) try timezoneValue(a, zoneAt(@intCast(id.zone)).name, info) else receiver;
        if (accessor) {
            if (std.mem.eql(u8, method, "tzname")) return .{ .string = info.abbreviation };
            return try durationValue(a, @as(i64, if (std.mem.eql(u8, method, "dst")) info.dst_seconds else info.offset_seconds) * std.time.us_per_s);
        }
        return try dates.attachTimezone(a, temporal.civil_ns, zone);
    }
    if (accessor) {
        if (std.mem.eql(u8, method, "tzname")) return .{ .string = id.abbreviation };
        return try durationValue(a, if (std.mem.eql(u8, method, "dst")) id.dst_us else id.offset_us);
    }
    if (normalize) {
        const original_offset = temporal.offset_us orelse return error.NaiveDatetime;
        if (!dynamic and same_timezone) return dt;
        const utc_ns = temporal.civil_ns - @as(i96, original_offset) * std.time.ns_per_us;
        const zone = try atUtc(a, receiver, @intCast(@divFloor(utc_ns, std.time.ns_per_s)));
        const offset = try expr.integerIndex(zone.attribute("__dxt_timezone_offset_us"));
        return try dates.attachTimezone(a, utc_ns + @as(i96, offset) * std.time.ns_per_us, zone);
    }
    if (fromutc) {
        if (temporal.offset_us != null and !same_timezone) {
            // DstTzInfo accepts any instance from the same zone's tzinfo cache.
            if (!dynamic or temporal.timezone == null) return error.InvalidFromUtcTimezone;
            const supplied = try parseIdentity(actual_identity.string);
            if (supplied.zone != id.zone) return error.InvalidFromUtcTimezone;
        }
        if (id.zone == -1 and temporal.offset_us == null) return error.InvalidFromUtcTimezone;
        const zone = try atUtc(a, receiver, @intCast(@divFloor(temporal.civil_ns, std.time.ns_per_s)));
        const offset = try expr.integerIndex(zone.attribute("__dxt_timezone_offset_us"));
        return try dates.attachTimezone(a, temporal.civil_ns + @as(i96, offset) * std.time.ns_per_us, zone);
    }
    return error.UndefinedJinjaValue;
}
pub fn call(a: Allocator, name: []const u8, args: []const Argument) anyerror!?Value {
    if (try @import("datetime_tzinfo.zig").call(a, name, args)) |result| return result;
    if (try builtin.call(a, name, args)) |result| return result;
    if (std.mem.startsWith(u8, name, "__dxt_pytz_method:")) return try methodCall(a, name[18..], args);
    if (std.mem.eql(u8, name, "modules.pytz.timezone")) {
        if (args.len != 1 or (args[0].name != null and !std.mem.eql(u8, args[0].name.?, "zone"))) return error.InvalidJinjaArguments;
        const binary = args[0].value.attribute("__dxt_binary");
        const zone = if (args[0].value == .string) args[0].value.string else if (binary == .string) binary.string else return error.UnknownTimeZoneError;
        for (zone) |byte| if (byte > 127) return error.UnknownTimeZoneError;
        return try timezoneValue(a, try unmunged(a, zone), null);
    }
    if (std.mem.eql(u8, name, "modules.pytz.FixedOffset")) {
        if (args.len != 1 or (args[0].name != null and !std.mem.eql(u8, args[0].name.?, "offset"))) return error.InvalidJinjaArguments;
        const minutes = try expr.numericFloat(args[0].value);
        if (!std.math.isFinite(minutes) or @abs(minutes) >= 1440) return error.InvalidTimeZoneOffset;
        if (minutes == 0) return try timezoneValue(a, "UTC", null);
        const total = minutes * std.time.us_per_min;
        const floor = @floor(total);
        const fraction = total - floor;
        const rounded = floor + @as(f64, if (fraction > 0.5 or (fraction == 0.5 and @mod(floor, 2) != 0)) 1 else 0);
        const micros: i64 = @intFromFloat(rounded);
        const key = if (minutes == @trunc(minutes)) try std.fmt.allocPrint(a, "{d}", .{@as(i64, @intFromFloat(minutes))}) else try expr.Value.text(.{ .number = minutes }, a);
        return try timezoneObject(a, .{ .zone = -1, .offset_us = micros, .dst_us = 0, .abbreviation = try std.fmt.allocPrint(a, "fixed={s}", .{key}) });
    }
    if (std.mem.startsWith(u8, name, "__dxt_pytz_duration:")) {
        if (args.len != 0) return error.InvalidJinjaArguments;
        const micros = try std.fmt.parseInt(i64, name[20..], 10);
        return .{ .number = @as(f64, @floatFromInt(micros)) / std.time.us_per_s };
    }
    if (std.mem.startsWith(u8, name, "__dxt_pytz_class:")) {
        const kind = name[17..];
        if (std.mem.eql(u8, kind, "BaseTzInfo")) {
            if (args.len != 0) return error.InvalidJinjaArguments;
            return try timezoneObject(a, .{ .zone = -2, .offset_us = 0, .dst_us = 0, .abbreviation = try std.fmt.allocPrint(a, "base={d}", .{base_instance_ids.fetchAdd(1, .monotonic)}) });
        }
        const values = try expr.allocateValues(a, args.len);
        for (args, values) |arg, *value| {
            if (arg.name != null) return error.InvalidJinjaArguments;
            value.* = arg.value;
        }
        const message = if (values.len == 0) "" else if (values.len > 1) try expr.repr(.{ .tuple = values }, a) else if (std.mem.eql(u8, kind, "UnknownTimeZoneError")) try expr.repr(values[0], a) else try values[0].text(a);
        return try object(a, &.{
            .{ .key = "__dxt_noniterable", .value = .{ .boolean = true } },
            .{ .key = "__dxt_rendered", .value = .{ .string = message } },
            .{ .key = "__dxt_repr", .value = .{ .string = try std.fmt.allocPrint(a, "{s}({s})", .{ kind, if (values.len == 0) @as([]const u8, "") else if (values.len == 1) try expr.repr(values[0], a) else (try expr.repr(.{ .tuple = values }, a))[1 .. (try expr.repr(.{ .tuple = values }, a)).len - 1] }) } },
            .{ .key = "args", .value = .{ .tuple = values } },
        });
    }
    return null;
}

test "pinned pytz database contains every exported zone and country" {
    try std.testing.expectEqualStrings("DXTZ0001", database[0..8]);
    try std.testing.expectEqual(@as(u32, 597), zone_count);
    try std.testing.expectEqual(@as(u32, 433), common_count);
    try std.testing.expectEqual(@as(u32, 249), country_count);
    try std.testing.expectEqual(strings_at + read(u32, 28), database.len);
    for (0..zone_count) |index| {
        const zone = zoneAt(@intCast(index));
        try std.testing.expect(zone.count > 0);
        try std.testing.expectEqual(index, (try findZone(zone.name)).index);
        var previous: i64 = std.math.minInt(i64);
        for (0..zone.count) |transition| {
            const seconds = transitionTime(zone, @intCast(transition));
            try std.testing.expect(seconds >= previous);
            previous = seconds;
        }
    }
}
test "pytz native transitions preserve gaps folds negative DST and historical offsets" {
    const calendar = @import("workflow_intervals.zig");
    const ny = "America/New_York";
    const autumn = try calendar.parseTimestamp("2020-11-01 01:30:00");
    try std.testing.expectError(error.AmbiguousTimeError, localizeInfo(ny, autumn, null));
    try std.testing.expectEqual(@as(i32, -14400), (try localizeInfo(ny, autumn, true)).offset_seconds);
    try std.testing.expectEqual(@as(i32, -18000), (try localizeInfo(ny, autumn, false)).offset_seconds);
    const spring = try calendar.parseTimestamp("2020-03-08 02:30:00");
    try std.testing.expectError(error.NonExistentTimeError, localizeInfo(ny, spring, null));
    try std.testing.expectEqual(@as(i32, -14400), (try localizeInfo(ny, spring, true)).offset_seconds);
    try std.testing.expectEqual(@as(i32, -18000), (try localizeInfo(ny, spring, false)).offset_seconds);
    try std.testing.expectEqual(@as(i32, -3600), (try localizeInfo("Europe/Dublin", try calendar.parseTimestamp("2020-01-01 00:00:00"), false)).dst_seconds);
    try std.testing.expectEqual(@as(i32, 20460), (try localizeInfo("Asia/Kathmandu", try calendar.parseTimestamp("1800-01-01 00:00:00"), false)).offset_seconds);
    try std.testing.expectEqual(@as(i32, 20700), (try offsetAtUtc("asia/kathmandu", try calendar.parseTimestamp("2020-01-01 00:00:00"))).offset_seconds);
    try std.testing.expectError(error.UnknownTimeZoneError, findZone("Mars/Olympus"));
}
test "pytz classes share identity while abstract timezone instances remain distinct" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const class = (try resolve(a, "modules.pytz.BaseTzInfo")).?;
    const other_class = (try resolve(a, "modules.pytz.BaseTzInfo")).?;
    try std.testing.expect(expr.equalValues(class, other_class));
    const first = (try call(a, class.attribute("__dxt_callable").callable, &.{})).?;
    const second = (try call(a, class.attribute("__dxt_callable").callable, &.{})).?;
    try std.testing.expect(!expr.equalValues(first, second));
    try std.testing.expect(expr.equalValues(first, try fromIdentity(a, first.attribute("__dxt_timezone_identity").string)));
    const keys = @import("mapping_keys.zig");
    try std.testing.expect(keys.matches(try keys.create(first, .none), first));
    try std.testing.expect(!keys.matches(try keys.create(first, .none), second));
}
test "pytz native exports fixed offsets duration methods and exceptions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fixed = (try call(a, "modules.pytz.FixedOffset", &.{.{ .value = .{ .number = 5.5 } }})).?;
    try std.testing.expectEqualStrings("330000000", fixed.attribute("__dxt_timezone_offset_us").integer);
    const country = try countryLookup(a, "names", .{ .string = "us" });
    try std.testing.expectEqualStrings("United States", country.string);
    try std.testing.expectEqualStrings("United States", (try countryLookup(a, "names", .{ .string = "uſ" })).string);
    try std.testing.expectError(error.InvalidCountryCode, countryLookup(a, "names", .{ .integer = "1" }));
    const module = (try resolve(a, "modules.pytz")).?;
    try std.testing.expectEqual(exports.len, module.object.len);
    try std.testing.expect(sets.isSet(module.attribute("all_timezones_set")));
    try std.testing.expectEqual(@as(usize, 597), sets.items(module.attribute("all_timezones_set")).?.len);
    const failure = (try call(a, "__dxt_pytz_class:UnknownTimeZoneError", &.{.{ .value = .{ .string = "Missing" } }})).?;
    try std.testing.expectEqualStrings("'Missing'", try failure.text(a));
    const duration = try durationValue(a, -19800000000);
    try std.testing.expectEqualStrings("-1 day, 18:30:00", try duration.text(a));
}

test "native pytz localization normalization and exact datetime timezone metadata" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const calendar = @import("workflow_intervals.zig");
    const eastern = try timezoneValue(a, "US/Eastern", null);
    const naive = try dates.datetimeValue(a, @as(i96, try calendar.parseTimestamp("2020-11-01 01:30:00")) * std.time.ns_per_s, false, null);
    const localized = (try call(a, eastern.attribute("localize").callable, &.{ .{ .value = naive }, .{ .name = "is_dst", .value = .{ .boolean = false } } })).?;
    try std.testing.expectEqualStrings("2020-11-01 01:30:00-05:00", try localized.text(a));
    try std.testing.expectEqualStrings("EST -0500", (try dates.call(a, localized.attribute("strftime").callable, &.{.{ .value = .{ .string = "%Z %z" } }})).?.string);
    const temporal = dates.state(localized).?;
    try std.testing.expectEqualStrings("US/Eastern", temporal.zone_name.?);
    try std.testing.expectEqual(@as(i64, -18000000000), temporal.offset_us.?);
    const earlier = try dates.datetimeValueWithOffsetUs(a, temporal.civil_ns - std.time.ns_per_hour, false, temporal.offset_us, temporal.timezone, 0);
    const normalized = (try call(a, eastern.attribute("normalize").callable, &.{.{ .value = earlier }})).?;
    try std.testing.expectEqualStrings("2020-11-01 01:30:00-04:00", try normalized.text(a));
    const fixed = (try call(a, "modules.pytz.FixedOffset", &.{.{ .value = .{ .number = 5.5 } }})).?;
    const fixed_dt = (try call(a, fixed.attribute("localize").callable, &.{.{ .value = naive }})).?;
    try std.testing.expectEqualStrings("2020-11-01 01:30:00+00:05:30", try fixed_dt.text(a));
    try std.testing.expectEqualStrings("+000530 ", (try dates.call(a, fixed_dt.attribute("strftime").callable, &.{.{ .value = .{ .string = "%z %Z" } }})).?.string);
    const fixed_offset = (try dates.call(a, fixed_dt.attribute("utcoffset").callable, &.{})).?;
    try std.testing.expectEqualStrings("0:05:30", try fixed_offset.text(a));
    try std.testing.expectError(error.AlreadyAwareDatetime, call(a, eastern.attribute("localize").callable, &.{.{ .value = localized }}));
    try std.testing.expectError(error.NaiveDatetime, call(a, eastern.attribute("normalize").callable, &.{.{ .value = naive }}));
}
