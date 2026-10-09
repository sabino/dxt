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
    const environment_profiles = if (runtime.environment) |environment| environment.get("DBT_PROFILES_DIR") else null;
    const profiles_dir = options.profiles_dir orelse environment_profiles;
    const explicit_profile_lookup = profiles_dir != null or options.profile != null or options.target != null;
    var profiles_path = if (profiles_dir) |directory|
        try std.fs.path.join(runtime.allocator, &.{ directory, "profiles.yml" })
    else
        try std.fs.path.join(runtime.allocator, &.{ project_dir, "profiles.yml" });

    const text = std.Io.Dir.cwd().readFileAlloc(runtime.io, profiles_path, runtime.allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            if (explicit_profile_lookup) return error.MissingProfileFile;
            if (runtime.environment) |environment| if (environment.get("HOME")) |home| {
                profiles_path = try std.fs.path.join(runtime.allocator, &.{ home, ".dbt", "profiles.yml" });
                const fallback = std.Io.Dir.cwd().readFileAlloc(runtime.io, profiles_path, runtime.allocator, .limited(1024 * 1024)) catch |failure| switch (failure) {
                    error.FileNotFound => return null,
                    else => return failure,
                };
                const profile_name = options.profile orelse config.profile_name orelse return error.MissingProfileName;
                var identity = try parseAdapterIdentityTextWithEnvironment(runtime.allocator, fallback, profile_name, options.target, runtime.environment);
                if (identity.database_path != null) identity.database_path_base = try runtime.allocator.dupe(u8, std.fs.path.dirname(profiles_path) orelse ".");
                return identity;
            };
            return null;
        },
        else => return err,
    };

    const selected_profile = options.profile orelse config.profile_name orelse return error.MissingProfileName;
    var identity = try parseAdapterIdentityTextWithEnvironment(runtime.allocator, text, selected_profile, options.target, runtime.environment);
    if (identity.database_path != null) {
        const base = std.fs.path.dirname(profiles_path) orelse ".";
        identity.database_path_base = try runtime.allocator.dupe(u8, base);
    }
    return identity;
}

pub fn parseAdapterIdentityText(allocator: std.mem.Allocator, text: []const u8, selected_profile: []const u8, target_override: ?[]const u8) !AdapterIdentity {
    return try parseAdapterIdentityTextWithEnvironment(allocator, text, selected_profile, target_override, null);
}

pub fn parseAdapterIdentityTextWithEnvironment(allocator: std.mem.Allocator, text: []const u8, selected_profile: []const u8, target_override: ?[]const u8, environment: ?*const std.process.Environ.Map) !AdapterIdentity {
    const values = @import("config_value.zig");
    const resource = @import("resource_config.zig");
    var document = try @import("yaml.zig").parse(allocator, text);
    defer document.deinit();
    const profile = values.get(document.value, selected_profile) orelse return error.MissingProfile;
    if (profile != .object) return error.MissingProfile;
    // Scalar profile rendering performs no filesystem or database operations.
    var renderer = @import("config_render.zig").Context{ .runtime = .{ .allocator = allocator, .io = undefined, .environment = environment }, .allow_secrets = true };
    var rendered_target = if (target_override) |name| try values.clone(allocator, .{ .string = name }) else try renderer.render(values.get(profile, "target") orelse .{ .string = "default" });
    defer values.deinit(allocator, &rendered_target);
    const target = resource.string(rendered_target) catch return error.MissingProfileTarget;
    if (target.len == 0) return error.MissingProfileTarget;
    const outputs = values.get(profile, "outputs") orelse return error.MissingProfileOutputs;
    const selected = values.get(outputs, target) orelse return error.MissingProfileTarget;
    var output = try renderer.render(selected);
    defer values.deinit(allocator, &output);
    if (output != .object) return error.MissingProfileTarget;
    const adapter = values.get(output, "type") orelse return error.MissingProfileType;
    const normalized_adapter_type = try normalizeAdapterType(allocator, resource.string(adapter) catch return error.MissingProfileType);
    const target_schema = if (values.get(output, "schema")) |v| try allocator.dupe(u8, resource.string(v) catch return error.MissingProfileSchema) else if (std.mem.eql(u8, normalized_adapter_type, "duckdb")) try allocator.dupe(u8, "main") else return error.MissingProfileSchema;
    const path = if (std.mem.eql(u8, normalized_adapter_type, "duckdb")) if (values.get(output, "path")) |v| try allocator.dupe(u8, resource.string(v) catch return error.MissingProfileDatabasePath) else try allocator.dupe(u8, ":memory:") else null;
    const threads: u16 = if (values.get(output, "threads")) |v| blk: {
        const count = if (v == .integer) v.integer else if (v == .string) try std.fmt.parseInt(i64, v.string, 10) else return error.InvalidProfileThreads;
        if (count < 1 or count > 65535) return error.InvalidProfileThreads;
        break :blk @intCast(count);
    } else 1;
    var target_context: std.json.Value = .null;
    var it = output.object.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "password") or std.mem.eql(u8, entry.key_ptr.*, "pass") or std.mem.eql(u8, entry.key_ptr.*, "private_key") or std.mem.eql(u8, entry.key_ptr.*, "token")) continue;
        try values.put(allocator, &target_context, entry.key_ptr.*, entry.value_ptr.*);
    }
    try values.put(allocator, &target_context, "name", .{ .string = target });
    try values.put(allocator, &target_context, "profile_name", .{ .string = selected_profile });
    try values.put(allocator, &target_context, "schema", .{ .string = target_schema });
    try values.put(allocator, &target_context, "type", .{ .string = normalized_adapter_type });
    try values.put(allocator, &target_context, "threads", .{ .integer = threads });
    if (values.get(output, "dbname")) |database| try values.put(allocator, &target_context, "database", database);
    if (std.mem.eql(u8, normalized_adapter_type, "duckdb")) {
        const basename = std.fs.path.basename(path orelse ":memory:");
        const extension = std.fs.path.extension(basename);
        const database = if (std.mem.eql(u8, basename, ":memory:")) "memory" else basename[0 .. basename.len - extension.len];
        try values.put(allocator, &target_context, "database", .{ .string = database });
    }
    const connection_info = if (std.mem.eql(u8, normalized_adapter_type, "postgres")) try postgresConnectionInfoValue(allocator, output) else null;
    return .{ .profile_name = try allocator.dupe(u8, selected_profile), .target_name = try allocator.dupe(u8, target), .adapter_type = normalized_adapter_type, .target_schema = target_schema, .database_path = path, .connection_info = connection_info, .threads = threads, .target_context = target_context };
}

fn postgresConnectionInfoValue(allocator: std.mem.Allocator, output: std.json.Value) ![]const u8 {
    const values = @import("config_value.zig");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "connect_timeout=10 application_name=dxt ");
    inline for (.{ "host", "port", "dbname", "user", "password", "sslmode", "sslcert", "sslkey", "sslrootcert", "connect_timeout", "keepalives_idle" }) |key| {
        if (values.get(output, key)) |raw| {
            const value = try values.scalarText(allocator, raw);
            defer allocator.free(value);
            if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidPostgresProfile;
            try out.appendSlice(allocator, key ++ "='");
            for (value) |byte| {
                if (byte == '\'' or byte == '\\') try out.append(allocator, '\\');
                try out.append(allocator, byte);
            }
            try out.appendSlice(allocator, "' ");
        }
    }
    return try out.toOwnedSlice(allocator);
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

fn postgresConnectionInfo(allocator: std.mem.Allocator, text: []const u8, profile_name: []const u8, target_name: []const u8, environment: ?*const std.process.Environ.Map) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "connect_timeout=10 application_name=dxt ");
    inline for (.{ "host", "port", "dbname", "user", "password", "sslmode", "connect_timeout", "keepalives_idle" }) |key| {
        if (try findProfileOutputScalar(allocator, text, profile_name, target_name, key, error.InvalidPostgresProfile)) |raw| {
            const value = try resolveProfileEnvironment(allocator, raw, environment);
            if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidPostgresProfile;
            try out.appendSlice(allocator, key ++ "='");
            for (value) |byte| {
                if (byte == '\'' or byte == '\\') try out.append(allocator, '\\');
                try out.append(allocator, byte);
            }
            try out.appendSlice(allocator, "' ");
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn resolveProfileEnvironment(allocator: std.mem.Allocator, value: []const u8, environment: ?*const std.process.Environ.Map) ![]const u8 {
    if (std.mem.indexOf(u8, value, "{{") == null) return value;
    if (!std.mem.startsWith(u8, value, "{{") or !std.mem.endsWith(u8, value, "}}")) return error.UnsupportedProfileExpression;
    const expression = std.mem.trim(u8, value[2 .. value.len - 2], " \t\r\n");
    if (!std.mem.startsWith(u8, expression, "env_var(") or !std.mem.endsWith(u8, expression, ")")) return error.UnsupportedProfileExpression;
    var arguments = try @import("jinja.zig").parseLiteralArgs(allocator, expression[8 .. expression.len - 1], error.UnsupportedProfileExpression);
    defer arguments.deinit(allocator);
    if (arguments.items.len != 1 and arguments.items.len != 2) return error.UnsupportedProfileExpression;
    if (environment) |map| if (map.get(arguments.items[0])) |resolved| return try allocator.dupe(u8, resolved);
    if (arguments.items.len == 2) return arguments.items[1];
    return error.MissingProfileEnvironmentVariable;
}

test "postgres profile credentials use libpq escaping and stay in memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\demo:
        \\  target: dev
        \\  outputs:
        \\    dev:
        \\      type: postgres
        \\      schema: analytics
        \\      host: localhost
        \\      user: "{{ env_var('DXT_SYNTHETIC_USER', 'fixture_user') }}"
        \\      password: a'b\c
    ;
    const identity = try parseAdapterIdentityText(arena.allocator(), text, "demo", null);
    try std.testing.expect(std.mem.indexOf(u8, identity.connection_info.?, "user='fixture_user'") != null);
    try std.testing.expect(std.mem.indexOf(u8, identity.connection_info.?, "password='a\\'b\\\\c'") != null);
}

fn findProfileOutputScalar(
    allocator: std.mem.Allocator,
    text: []const u8,
    selected_profile: []const u8,
    selected_target: []const u8,
    wanted_key: []const u8,
    comptime empty_value_error: anyerror,
) !?[]const u8 {
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
        if (std.mem.eql(u8, kv.key, wanted_key)) {
            const value = std.mem.trim(u8, kv.value, " \t\r");
            if (value.len == 0) return empty_value_error;
            const scalar = try dupTrimmedScalar(allocator, value);
            if (scalar.len == 0) return empty_value_error;
            return scalar;
        }
    }

    if (!profile_found) return error.MissingProfile;
    if (!outputs_found) return error.MissingProfileOutputs;
    if (!target_found) return error.MissingProfileTarget;
    return null;
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
    try std.testing.expectEqualStrings("analytics", identity.target_schema);
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
        \\      schema: analytics
        \\    duck:
        \\      type: duckdb
    ;

    const identity = try parseAdapterIdentityText(allocator, text, "analytics", "pg");
    try std.testing.expectEqualStrings("pg", identity.target_name);
    try std.testing.expectEqualStrings("postgres", identity.adapter_type);
    try std.testing.expectEqualStrings("analytics", identity.target_schema);
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
    try std.testing.expectEqualStrings("main", identity.target_schema);
}

test "profile parser captures scalar duckdb path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const text =
        \\analytics:
        \\  target: duck
        \\  outputs:
        \\    duck:
        \\      type: duckdb
        \\      schema: analytics
        \\      path: "warehouse.duckdb"
    ;

    const identity = try parseAdapterIdentityText(allocator, text, "analytics", null);
    try std.testing.expectEqualStrings("duckdb", identity.adapter_type);
    try std.testing.expectEqualStrings("analytics", identity.target_schema);
    try std.testing.expectEqualStrings("warehouse.duckdb", identity.database_path.?);
}

test "profile YAML anchors env target and native credential values stay in memory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var environment: std.process.Environ.Map = .init(allocator);
    defer environment.deinit();
    try environment.put("DXT_PROFILE_TARGET", "dev");
    try environment.put("DXT_PROFILE_THREADS", "3");
    try environment.put("DBT_ENV_SECRET_PASSWORD", "synthetic ' escaped\\ password");
    const identity = try parseAdapterIdentityTextWithEnvironment(allocator,
        \\base: &base {type: postgres, schema: public, host: localhost, user: synthetic, dbname: fixture, port: 5432}
        \\fixture:
        \\  target: "{{ env_var('DXT_PROFILE_TARGET') }}"
        \\  outputs:
        \\    dev:
        \\      <<: *base
        \\      threads: "{{ env_var('DXT_PROFILE_THREADS') | int }}"
        \\      password: "{{ env_var('DBT_ENV_SECRET_PASSWORD') }}"
    , "fixture", null, &environment);
    try std.testing.expectEqual(@as(u16, 3), identity.threads);
    try std.testing.expect(identity.target_context.object.get("password") == null);
    try std.testing.expectEqualStrings("fixture", identity.target_context.object.get("database").?.string);
    try std.testing.expect(std.mem.indexOf(u8, identity.connection_info.?, "password='synthetic \\' escaped\\\\ password'") != null);
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
    try std.testing.expectError(error.MissingProfileSchema, parseAdapterIdentityText(allocator, "analytics:\n  outputs:\n    default:\n      type: postgres\n", "analytics", null));
    try std.testing.expectError(error.MissingProfile, parseAdapterIdentityText(allocator, text, "other", null));
}
