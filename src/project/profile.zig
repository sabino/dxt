const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");

const Runtime = types.Runtime;
const Options = types.Options;
const ProjectConfig = types.ProjectConfig;
const AdapterIdentity = types.AdapterIdentity;
const stripYamlComment = util.stripYamlComment;
const leadingSpaces = util.leadingSpaces;
const splitKeyValue = util.splitKeyValue;
const dupTrimmedScalar = util.dupTrimmedScalar;

pub fn loadAdapterIdentity(runtime: Runtime, project_dir: []const u8, config: *const ProjectConfig, options: Options) !?AdapterIdentity {
    const explicit_profile_lookup = options.profiles_dir != null or options.profile != null or options.target != null;
    const profiles_path = if (options.profiles_dir) |profiles_dir|
        try std.fs.path.join(runtime.allocator, &.{ profiles_dir, "profiles.yml" })
    else
        try std.fs.path.join(runtime.allocator, &.{ project_dir, "profiles.yml" });

    const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, profiles_path, runtime.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            if (explicit_profile_lookup) return error.MissingProfileFile;
            return null;
        },
        else => return err,
    };

    const selected_profile = options.profile orelse config.profile_name orelse return error.MissingProfileName;
    return try parseAdapterIdentityText(runtime.allocator, text, selected_profile, options.target);
}

pub fn parseAdapterIdentityText(allocator: std.mem.Allocator, text: []const u8, selected_profile: []const u8, target_override: ?[]const u8) !AdapterIdentity {
    const profile_name = try dupTrimmedScalar(allocator, selected_profile);
    if (profile_name.len == 0) return error.MissingProfileName;

    const target_name = if (target_override) |target|
        try dupTrimmedScalar(allocator, target)
    else if (try findProfileTarget(allocator, text, profile_name)) |target|
        target
    else
        try allocator.dupe(u8, "default");
    if (target_name.len == 0) return error.MissingProfileTarget;

    const adapter_type = try findProfileOutputType(allocator, text, profile_name, target_name);
    return .{
        .profile_name = profile_name,
        .target_name = target_name,
        .adapter_type = try normalizeAdapterType(allocator, adapter_type),
    };
}

fn findProfileTarget(allocator: std.mem.Allocator, text: []const u8, selected_profile: []const u8) !?[]const u8 {
    var profile_found = false;
    var in_profile = false;
    var profile_indent: usize = 0;
    var direct_child_indent: ?usize = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);

        if (in_profile and indent <= profile_indent) {
            in_profile = false;
            direct_child_indent = null;
        }
        if (!in_profile) {
            if (indent != 0) continue;
            const kv = splitKeyValue(trimmed) orelse continue;
            if (std.mem.eql(u8, kv.key, selected_profile)) {
                profile_found = true;
                in_profile = true;
                profile_indent = indent;
                direct_child_indent = null;
            }
            continue;
        }

        if (indent <= profile_indent) continue;
        if (direct_child_indent == null) direct_child_indent = indent;
        if (indent != direct_child_indent.?) continue;
        const kv = splitKeyValue(trimmed) orelse continue;
        if (std.mem.eql(u8, kv.key, "target")) {
            const value = std.mem.trim(u8, kv.value, " \t\r");
            if (value.len == 0) return error.MissingProfileTarget;
            return try dupTrimmedScalar(allocator, value);
        }
    }

    if (!profile_found) return error.MissingProfile;
    return null;
}

fn findProfileOutputType(allocator: std.mem.Allocator, text: []const u8, selected_profile: []const u8, selected_target: []const u8) ![]const u8 {
    var profile_found = false;
    var outputs_found = false;
    var target_found = false;
    var in_profile = false;
    var profile_indent: usize = 0;
    var profile_child_indent: ?usize = null;
    var in_outputs = false;
    var outputs_indent: usize = 0;
    var in_target = false;
    var target_indent: usize = 0;
    var target_child_indent: ?usize = null;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = stripYamlComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const indent = leadingSpaces(line);

        if (in_target and indent <= target_indent) {
            in_target = false;
            target_child_indent = null;
        }
        if (in_outputs and indent <= outputs_indent) {
            in_outputs = false;
            in_target = false;
            target_child_indent = null;
        }
        if (in_profile and indent <= profile_indent) {
            in_profile = false;
            profile_child_indent = null;
            in_outputs = false;
            in_target = false;
            target_child_indent = null;
        }

        if (!in_profile) {
            if (indent != 0) continue;
            const kv = splitKeyValue(trimmed) orelse continue;
            if (std.mem.eql(u8, kv.key, selected_profile)) {
                profile_found = true;
                in_profile = true;
                profile_indent = indent;
                profile_child_indent = null;
            }
            continue;
        }

        if (indent <= profile_indent) continue;
        const kv = splitKeyValue(trimmed) orelse continue;

        if (!in_outputs) {
            if (profile_child_indent == null) profile_child_indent = indent;
            if (indent != profile_child_indent.?) continue;
            if (std.mem.eql(u8, kv.key, "outputs")) {
                outputs_found = true;
                in_outputs = true;
                outputs_indent = indent;
            }
            continue;
        }

        if (indent <= outputs_indent) continue;
        if (!in_target) {
            if (std.mem.eql(u8, kv.key, selected_target)) {
                target_found = true;
                in_target = true;
                target_indent = indent;
                target_child_indent = null;
            }
            continue;
        }

        if (target_child_indent == null) target_child_indent = indent;
        if (indent != target_child_indent.?) continue;
        if (std.mem.eql(u8, kv.key, "type")) {
            const value = std.mem.trim(u8, kv.value, " \t\r");
            if (value.len == 0) return error.MissingProfileType;
            return try dupTrimmedScalar(allocator, value);
        }
    }

    if (!profile_found) return error.MissingProfile;
    if (!outputs_found) return error.MissingProfileOutputs;
    if (!target_found) return error.MissingProfileTarget;
    return error.MissingProfileType;
}

pub fn normalizeAdapterType(allocator: std.mem.Allocator, raw_value: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, raw_value, " \t\r");
    if (trimmed.len == 0) return error.MissingProfileType;
    const scalar = try dupTrimmedScalar(allocator, trimmed);
    if (scalar.len == 0) return error.MissingProfileType;

    const lowered = try allocator.alloc(u8, scalar.len);
    for (scalar, 0..) |ch, index| {
        lowered[index] = std.ascii.toLower(ch);
    }
    if (std.mem.eql(u8, lowered, "postgresql")) {
        @memcpy(lowered[0.."postgres".len], "postgres");
        return lowered[0.."postgres".len];
    }
    return lowered;
}

test "profile parser selects project profile target and adapter type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text =
        \\analytics:
        \\  target: pg
        \\  outputs:
        \\    pg:
        \\      type: postgres
        \\      schema: analytics
        \\    duck:
        \\      type: duckdb
    ;

    const identity = try parseAdapterIdentityText(allocator, text, "analytics", null);
    try std.testing.expectEqualStrings("analytics", identity.profile_name);
    try std.testing.expectEqualStrings("pg", identity.target_name);
    try std.testing.expectEqualStrings("postgres", identity.adapter_type);
}

test "profile parser applies target override and postgres alias normalization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text =
        \\analytics:
        \\  target: duck
        \\  outputs:
        \\    pg:
        \\      type: postgresql
        \\    duck:
        \\      type: duckdb
    ;

    const identity = try parseAdapterIdentityText(allocator, text, "analytics", "pg");
    try std.testing.expectEqualStrings("pg", identity.target_name);
    try std.testing.expectEqualStrings("postgres", identity.adapter_type);
}

test "profile parser defaults missing target to default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text =
        \\analytics:
        \\  outputs:
        \\    default:
        \\      type: duckdb
    ;

    const identity = try parseAdapterIdentityText(allocator, text, "analytics", null);
    try std.testing.expectEqualStrings("default", identity.target_name);
    try std.testing.expectEqualStrings("duckdb", identity.adapter_type);
}

test "profile parser reports missing profile target and type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text =
        \\analytics:
        \\  target: missing
        \\  outputs:
        \\    dev:
        \\      schema: analytics
    ;

    try std.testing.expectError(error.MissingProfileTarget, parseAdapterIdentityText(allocator, text, "analytics", null));
    try std.testing.expectError(error.MissingProfileType, parseAdapterIdentityText(allocator, text, "analytics", "dev"));
    try std.testing.expectError(error.MissingProfile, parseAdapterIdentityText(allocator, text, "other", null));
}
