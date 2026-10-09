//! dbt Core 1.10.5 cli/params.py defaults and option spelling. Native argument
//! normalization is separate from command-specific validation and execution.
const std = @import("std");
const types = @import("types.zig");
const yaml = @import("yaml.zig");
pub const input_relations = @import("input_relations.zig");

pub const Prepared = struct { args: []const []const u8, options: types.Options };

pub fn prepare(runtime: types.Runtime, args: []const []const u8) !Prepared {
    const a = runtime.allocator;
    var expanded: std.ArrayList([]const u8) = .empty;
    if (args.len == 0) return .{ .args = args, .options = try defaults(runtime, null) };
    try expanded.append(a, args[0]);
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |equal| {
                try expanded.append(a, alias(arg[0..equal]));
                try expanded.append(a, arg[equal + 1 ..]);
                continue;
            }
        }
        if (arg.len > 2 and arg[0] == '-' and arg[1] != '-' and (arg[1] == 's' or arg[1] == 'm' or arg[1] == 't' or arg[1] == 'r')) {
            try expanded.append(a, alias(arg[0..2]));
            try expanded.append(a, arg[2..]);
        } else try expanded.append(a, alias(arg));
    }
    var options = try defaults(runtime, commandHint(expanded.items));
    var before: std.ArrayList([]const u8) = .empty;
    var body: std.ArrayList([]const u8) = .empty;
    var command: ?[]const u8 = null;
    var global_positions: std.StringHashMap(bool) = .init(a);
    defer global_positions.deinit();
    var index: usize = 1;
    while (index < expanded.items.len) : (index += 1) {
        const arg = expanded.items[index];
        if (globalKey(arg)) |key| {
            const before_command = command == null;
            if (global_positions.get(key)) |prior| {
                if (prior != before_command) return error.DuplicateGlobalOption;
            } else try global_positions.put(key, before_command);
        }
        if (try universal(&options, expanded.items, &index)) continue;
        if (command == null) {
            if (!std.mem.startsWith(u8, arg, "-") or eq(arg, "--version") or eq(arg, "--help")) {
                command = if (eq(arg, "list")) "ls" else arg;
                continue;
            }
            if (!globalValue(arg) and !globalFlag(arg)) return error.InvalidGlobalOption;
            try before.append(a, arg);
            if (globalValue(arg)) {
                index += 1;
                if (index >= expanded.items.len) return error.InvalidOption;
                try before.append(a, expanded.items[index]);
            }
        } else {
            try body.append(a, if (eq(arg, "--models") and !eq(command.?, "ls")) "--select" else arg);
            if (valueOption(arg)) {
                index += 1;
                if (index >= expanded.items.len) return error.InvalidOption;
                try body.append(a, expanded.items[index]);
            }
        }
    }
    var normalized: std.ArrayList([]const u8) = .empty;
    try normalized.append(a, args[0]);
    if (command) |name| {
        try normalized.append(a, name);
        var subcommand: usize = 0;
        if ((eq(name, "docs") or eq(name, "source") or eq(name, "metric")) and body.items.len != 0 and !std.mem.startsWith(u8, body.items[0], "-")) {
            try normalized.append(a, body.items[0]);
            subcommand = 1;
        }
        try normalized.appendSlice(a, before.items);
        try normalized.appendSlice(a, body.items[subcommand..]);
    }
    var cursor: usize = 1;
    while (cursor + 1 < normalized.items.len) : (cursor += 1) {
        if (eq(normalized.items[cursor], "--project-dir")) {
            options.project_dir = normalized.items[cursor + 1];
            cursor += 1;
        }
    }
    try validateWarningOptions(runtime, options);
    if (options.resource_types) |kinds| for (kinds) |kind| if (!validResourceType(kind, false)) return error.UnsupportedResourceType;
    if (options.exclude_resource_types) |kinds| for (kinds) |kind| if (!validResourceType(kind, true)) return error.UnsupportedResourceType;
    return .{ .args = try normalized.toOwnedSlice(a), .options = options };
}

fn defaults(runtime: types.Runtime, command: ?[]const u8) !types.Options {
    var options: types.Options = .{};
    options.which = command orelse "";
    options.project_dir = environment(runtime, "DBT_PROJECT_DIR") orelse try defaultProjectDir(runtime);
    options.profiles_dir = environment(runtime, "DBT_PROFILES_DIR");
    options.profile = environment(runtime, "DBT_PROFILE");
    options.target = environment(runtime, "DBT_TARGET");
    options.target_path = environment(runtime, "DBT_TARGET_PATH");
    if (eq(options.which, "ls")) {
        if (environment(runtime, "DBT_RESOURCE_TYPES")) |value| options.resource_types = try splitTypes(runtime.allocator, value);
        if (environment(runtime, "DBT_EXCLUDE_RESOURCE_TYPES")) |value| options.exclude_resource_types = try splitTypes(runtime.allocator, value);
    }
    options.state = environment(runtime, "DBT_STATE") orelse environment(runtime, "DBT_ARTIFACT_STATE_PATH");
    options.defer_state = environment(runtime, "DBT_DEFER_STATE");
    options.indirect_selection = environment(runtime, "DBT_INDIRECT_SELECTION") orelse "eager";
    if (!eq(options.indirect_selection, "eager") and !eq(options.indirect_selection, "cautious") and !eq(options.indirect_selection, "buildable") and !eq(options.indirect_selection, "empty")) return error.UnsupportedIndirectSelection;
    options.defer_enabled = try environmentBool(runtime, "DBT_DEFER", false);
    options.favor_state = try environmentBool(runtime, "DBT_FAVOR_STATE", false);
    options.fail_fast = try environmentBool(runtime, "DBT_FAIL_FAST", false);
    if (eq(options.which, "run") or eq(options.which, "build") or eq(options.which, "seed") or eq(options.which, "compile")) options.full_refresh = try environmentBool(runtime, "DBT_FULL_REFRESH", false);
    if (eq(options.which, "run") or eq(options.which, "build") or eq(options.which, "snapshot") or eq(options.which, "compile")) options.empty = try environmentBool(runtime, "DBT_EMPTY", false);
    if (eq(options.which, "run") or eq(options.which, "build")) {
        options.sample = environment(runtime, "DBT_SAMPLE");
        options.event_time_start = environment(runtime, "DBT_EVENT_TIME_START");
        options.event_time_end = environment(runtime, "DBT_EVENT_TIME_END");
    }
    options.quiet = try environmentBool(runtime, "DBT_QUIET", false);
    if (eq(options.which, "test") or eq(options.which, "build")) options.store_failures = try environmentBool(runtime, "DBT_STORE_FAILURES", false);
    options.debug = try environmentBool(runtime, "DBT_DEBUG", false);
    options.single_threaded = try environmentBool(runtime, "DBT_SINGLE_THREADED", false);
    options.populate_cache = try environmentBool(runtime, "DBT_POPULATE_CACHE", true);
    options.cache_selected_only = try environmentBool(runtime, "DBT_CACHE_SELECTED_ONLY", false);
    options.log_cache_events = try environmentBool(runtime, "DBT_LOG_CACHE_EVENTS", false);
    options.write_json = try environmentBool(runtime, "DBT_WRITE_JSON", true);
    options.warn_error = try environmentBool(runtime, "DBT_WARN_ERROR", false);
    options.version_check = try environmentBool(runtime, "DBT_VERSION_CHECK", true);
    options.use_colors = try environmentBool(runtime, "DBT_USE_COLORS", true);
    options.use_colors_file = try environmentBool(runtime, "DBT_USE_COLORS_FILE", true);
    options.print_enabled = try environmentBool(runtime, "DBT_PRINT", true);
    options.warn_error_options = environment(runtime, "DBT_WARN_ERROR_OPTIONS");
    if (environment(runtime, "DBT_LOG_FORMAT")) |value| options.log_format = try logFormat(value);
    if (environment(runtime, "DBT_LOG_LEVEL")) |value| options.log_level = try logLevel(value);
    if (environment(runtime, "DBT_LOG_LEVEL_FILE")) |value| options.log_level_file = try logLevel(value);
    if (environment(runtime, "DBT_LOG_FORMAT_FILE")) |value| options.log_format_file = try fileFormat(value);
    options.log_path = environment(runtime, "DBT_LOG_PATH");
    if (environment(runtime, "DBT_LOG_FILE_MAX_BYTES")) |value| options.log_file_max_bytes = try std.fmt.parseInt(u64, value, 10);
    return options;
}

fn universal(options: *types.Options, args: []const []const u8, index: *usize) !bool {
    const arg = args[index.*];
    if (eq(arg, "--quiet") or eq(arg, "--no-quiet")) options.quiet = eq(arg, "--quiet") else if (eq(arg, "--use-colors") or eq(arg, "--no-use-colors")) options.use_colors = eq(arg, "--use-colors") else if (eq(arg, "--use-colors-file") or eq(arg, "--no-use-colors-file")) options.use_colors_file = eq(arg, "--use-colors-file") else if (eq(arg, "--print") or eq(arg, "--no-print")) options.print_enabled = eq(arg, "--print") else if (eq(arg, "--write-json") or eq(arg, "--no-write-json")) options.write_json = eq(arg, "--write-json") else if (eq(arg, "--version-check") or eq(arg, "--no-version-check")) options.version_check = eq(arg, "--version-check") else if (eq(arg, "--warn-error") or eq(arg, "--no-warn-error")) options.warn_error = eq(arg, "--warn-error") else if (eq(arg, "--debug") or eq(arg, "--no-debug")) options.debug = eq(arg, "--debug") else if (eq(arg, "--single-threaded") or eq(arg, "--no-single-threaded")) options.single_threaded = eq(arg, "--single-threaded") else if (eq(arg, "--populate-cache") or eq(arg, "--no-populate-cache")) options.populate_cache = eq(arg, "--populate-cache") else if (eq(arg, "--cache-selected-only") or eq(arg, "--no-cache-selected-only")) options.cache_selected_only = eq(arg, "--cache-selected-only") else if (eq(arg, "--log-cache-events") or eq(arg, "--no-log-cache-events")) options.log_cache_events = eq(arg, "--log-cache-events") else if (eq(arg, "--log-format") or eq(arg, "--log-format-file") or eq(arg, "--log-level") or eq(arg, "--log-level-file") or eq(arg, "--log-path") or eq(arg, "--log-file-max-bytes") or eq(arg, "--warn-error-options") or eq(arg, "--record-timing-info")) {
        index.* += 1;
        if (index.* >= args.len) return error.InvalidOption;
        const value = args[index.*];
        if (eq(arg, "--log-format")) options.log_format = try logFormat(value) else if (eq(arg, "--log-format-file")) options.log_format_file = try fileFormat(value) else if (eq(arg, "--log-level")) options.log_level = try logLevel(value) else if (eq(arg, "--log-level-file")) options.log_level_file = try logLevel(value) else if (eq(arg, "--log-path")) options.log_path = value else if (eq(arg, "--log-file-max-bytes")) options.log_file_max_bytes = try std.fmt.parseInt(u64, value, 10) else if (eq(arg, "--record-timing-info")) options.record_timing_info = value else options.warn_error_options = value;
    } else return false;
    return true;
}

pub fn writeJson(runtime: types.Runtime) bool {
    const options = runtime.invocation_options orelse runtime.global_options orelse return true;
    return options.write_json;
}
pub fn validResourceType(name: []const u8, excluded: bool) bool {
    for ([_][]const u8{ "metric", "semantic_model", "saved_query", "source", "analysis", "model", "test", "unit_test", "exposure", "snapshot", "seed", "default" }) |kind| if (eq(name, kind)) return true;
    return !excluded and eq(name, "all");
}

pub fn resourceIncluded(options: types.Options, kind: []const u8) bool {
    var included = options.resource_types == null;
    if (options.resource_types) |kinds| for (kinds) |candidate| {
        if (eq(candidate, kind) or eq(candidate, "all") or (eq(candidate, "default") and !eq(kind, "analysis"))) included = true;
    };
    if (options.exclude_resource_types) |kinds| for (kinds) |candidate| {
        if (eq(candidate, kind) or (eq(candidate, "default") and !eq(kind, "analysis"))) included = false;
    };
    // Preserve dxt's explicit text/default listing extension. Core selectors
    // exclude analyses unless the list resource type requests them.
    if (options.resource_types == null and options.output != .text and eq(kind, "analysis")) return false;
    return included;
}

pub fn warningIsError(runtime: types.Runtime, event: []const u8) !bool {
    const options = runtime.invocation_options orelse runtime.global_options orelse return false;
    if (options.warn_error_options) |raw| {
        if (options.warn_error) return error.ConflictingWarnErrorOptions;
        var document = try yaml.parse(runtime.allocator, raw);
        defer document.deinit();
        if (document.value != .object) return error.InvalidWarnErrorOptions;
        const object = document.value.object;
        const included = object.get("error") orelse object.get("include") orelse return false;
        const excluded = object.get("warn") orelse object.get("exclude");
        const silenced = object.get("silence");
        return matchesEvent(included, event) and (excluded == null or !matchesEvent(excluded.?, event)) and (silenced == null or !matchesEvent(silenced.?, event));
    }
    return options.warn_error;
}
pub fn warningIsSilenced(runtime: types.Runtime, event: []const u8) !bool {
    const options = runtime.invocation_options orelse runtime.global_options orelse return false;
    const raw = options.warn_error_options orelse return false;
    var document = try yaml.parse(runtime.allocator, raw);
    defer document.deinit();
    return if (document.value == .object) if (document.value.object.get("silence")) |value| matchesEvent(value, event) else false else false;
}

/// Core flags normalize the deprecated include/exclude spellings, then fire
/// WEOIncludeExcludeDeprecation after event policy has been initialized.
pub fn startupWarnings(runtime: types.Runtime, writer: *std.Io.Writer) !void {
    const options = runtime.global_options orelse return;
    const raw = options.warn_error_options orelse return;
    var document = try yaml.parse(runtime.allocator, raw);
    defer document.deinit();
    if (!document.value.object.contains("include") and !document.value.object.contains("exclude")) return;
    const event = "WEOIncludeExcludeDeprecation";
    if (try warningIsSilenced(runtime, event)) return;
    if (try warningIsError(runtime, event)) return error.WarnErrorOptionsDeprecation;
    try writer.writeAll("warning: [WEOIncludeExcludeDeprecation] warn-error-options include/exclude are deprecated; use error/warn\n");
}

fn validateWarningOptions(runtime: types.Runtime, options: types.Options) !void {
    const raw = options.warn_error_options orelse return;
    if (options.warn_error) return error.ConflictingWarnErrorOptions;
    var document = try yaml.parse(runtime.allocator, raw);
    defer document.deinit();
    if (document.value != .object) return error.InvalidWarnErrorOptions;
    const object = document.value.object;
    if (object.contains("include") and object.contains("error")) return error.ConflictingWarnErrorOptionKeys;
    if (object.contains("exclude") and object.contains("warn")) return error.ConflictingWarnErrorOptionKeys;
    const errors = object.get("error") orelse object.get("include") orelse .null;
    const warnings = object.get("warn") orelse object.get("exclude") orelse .null;
    const silence = object.get("silence") orelse .null;
    try validateWarningList(errors, true);
    try validateWarningList(warnings, false);
    try validateWarningList(silence, false);
    if (warnings == .array and warnings.array.items.len != 0 and !matches(errors, "all") and !matches(errors, "Deprecations") and !matches(silence, "Deprecations")) return error.InvalidWarnErrorOptions;
}

fn validateWarningList(value: std.json.Value, allow_all: bool) !void {
    if (value == .null) return;
    if (allow_all and value == .string and (eq(value.string, "all") or eq(value.string, "*"))) return;
    if (value != .array) return error.InvalidWarnErrorOptions;
    for (value.array.items) |item| {
        if (item != .string) return error.InvalidWarnErrorOptions;
        if (!@import("core_event_names.zig").valid(item.string)) return error.InvalidWarnErrorOptions;
    }
}

fn matches(value: std.json.Value, event: []const u8) bool {
    if (value == .string) return eq(value.string, "all") or eq(value.string, "*") or eq(value.string, event);
    if (value == .array) for (value.array.items) |item| if (matches(item, event)) return true;
    return false;
}
fn matchesEvent(value: std.json.Value, event: []const u8) bool {
    return matches(value, event) or (std.mem.endsWith(u8, event, "Deprecation") and matches(value, "Deprecations"));
}

pub fn defaultProjectDir(runtime: types.Runtime) ![]const u8 {
    const current = try std.process.currentPathAlloc(runtime.io, runtime.allocator);
    var directory: []const u8 = current;
    while (true) {
        const path = try std.fs.path.join(runtime.allocator, &.{ directory, "dbt_project.yml" });
        defer runtime.allocator.free(path);
        if (std.Io.Dir.cwd().access(runtime.io, path, .{})) |_| return directory else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
        directory = std.fs.path.dirname(directory) orelse return current;
    }
}

fn environment(runtime: types.Runtime, key: []const u8) ?[]const u8 {
    return if (runtime.environment) |env| env.get(key) else null;
}
fn environmentBool(runtime: types.Runtime, key: []const u8, fallback: bool) !bool {
    const raw = environment(runtime, key) orelse return fallback;
    if (std.ascii.eqlIgnoreCase(raw, "true") or std.ascii.eqlIgnoreCase(raw, "t") or std.ascii.eqlIgnoreCase(raw, "yes") or std.ascii.eqlIgnoreCase(raw, "y") or std.ascii.eqlIgnoreCase(raw, "on") or eq(raw, "1")) return true;
    if (std.ascii.eqlIgnoreCase(raw, "false") or std.ascii.eqlIgnoreCase(raw, "f") or std.ascii.eqlIgnoreCase(raw, "no") or std.ascii.eqlIgnoreCase(raw, "n") or std.ascii.eqlIgnoreCase(raw, "off") or eq(raw, "0")) return false;
    return error.InvalidEnvironmentBoolean;
}
fn logFormat(value: []const u8) !@TypeOf(@as(types.Options, .{}).log_format) {
    if (eq(value, "json")) return .json;
    if (eq(value, "debug")) return .debug;
    if (eq(value, "text") or eq(value, "default")) return .text;
    return error.InvalidLogFormat;
}
fn fileFormat(value: []const u8) !@TypeOf(@as(types.Options, .{}).log_format_file) {
    if (eq(value, "default")) return .debug;
    return std.meta.stringToEnum(@TypeOf(@as(types.Options, .{}).log_format_file), value) orelse error.InvalidLogFormat;
}
fn logLevel(value: []const u8) !types.LogLevel {
    return std.meta.stringToEnum(types.LogLevel, value) orelse error.InvalidLogLevel;
}
fn alias(value: []const u8) []const u8 {
    if (eq(value, "-s")) return "--select";
    if (eq(value, "-m") or eq(value, "--model")) return "--models";
    if (eq(value, "-t")) return "--target";
    if (eq(value, "-f")) return "--full-refresh";
    if (eq(value, "-x")) return "--fail-fast";
    if (eq(value, "-q")) return "--quiet";
    if (eq(value, "-d")) return "--debug";
    if (eq(value, "-r")) return "--record-timing-info";
    if (eq(value, "-V") or eq(value, "-v")) return "--version";
    if (eq(value, "-h")) return "--help";
    return value;
}
fn globalValue(arg: []const u8) bool {
    return eq(arg, "--profile") or eq(arg, "--target") or eq(arg, "--state") or eq(arg, "--defer-state") or eq(arg, "--indirect-selection");
}
fn commandHint(args: []const []const u8) ?[]const u8 {
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (eq(arg, "--version")) return "version";
        if (!std.mem.startsWith(u8, arg, "-")) return if (eq(arg, "list")) "ls" else arg;
        if (globalValue(arg) or universalValue(arg) or valueOption(arg)) index += 1;
    }
    return null;
}
fn universalValue(arg: []const u8) bool {
    for ([_][]const u8{ "--log-format", "--log-format-file", "--log-level", "--log-level-file", "--log-path", "--log-file-max-bytes", "--warn-error-options", "--record-timing-info" }) |name| if (eq(arg, name)) return true;
    return false;
}
fn splitTypes(allocator: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    var types_list: std.ArrayList([]const u8) = .empty;
    var iterator = std.mem.tokenizeAny(u8, value, " ,\t");
    while (iterator.next()) |item| try types_list.append(allocator, item);
    return try types_list.toOwnedSlice(allocator);
}
fn globalFlag(arg: []const u8) bool {
    return eq(arg, "--defer") or eq(arg, "--no-defer") or eq(arg, "--favor-state") or eq(arg, "--no-favor-state") or eq(arg, "--fail-fast") or eq(arg, "--no-fail-fast");
}
fn globalKey(arg: []const u8) ?[]const u8 {
    if (globalValue(arg)) return arg;
    for ([_][]const u8{ "quiet", "use-colors", "use-colors-file", "print", "write-json", "warn-error", "version-check", "debug", "defer", "favor-state", "fail-fast", "single-threaded", "populate-cache", "cache-selected-only", "log-cache-events" }) |name| {
        if (std.mem.startsWith(u8, arg, "--") and eq(arg[2..], name)) return name;
        if (std.mem.startsWith(u8, arg, "--no-") and eq(arg[5..], name)) return name;
    }
    for ([_][]const u8{ "--log-format", "--log-format-file", "--log-level", "--log-level-file", "--log-path", "--log-file-max-bytes", "--warn-error-options", "--record-timing-info" }) |name| if (eq(arg, name)) return name;
    return null;
}
fn valueOption(arg: []const u8) bool {
    // Value options consume their next token, even when it resembles a global
    // flag. This preserves YAML/JSON macro arguments and quoted scalar vars.
    for ([_][]const u8{ "--project-dir", "--profiles-dir", "--profile", "--target", "--target-path", "--vars", "--state", "--defer-state", "--indirect-selection", "--threads", "--args", "--selector", "--host", "--port", "--output", "--resource-type", "--environment", "--from-environment", "--plan", "--workflow-config", "--start", "--end", "--sample", "--event-time-start", "--event-time-end" }) |name| if (eq(arg, name)) return true;
    return false;
}
fn eq(lhs: []const u8, rhs: []const u8) bool {
    return std.mem.eql(u8, lhs, rhs);
}

test "Core spelling preserves global precedence and nested commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const runtime: types.Runtime = .{ .allocator = arena.allocator(), .io = std.testing.io };
    const parsed = try prepare(runtime, &.{ "dxt", "--profile=first", "-q", "docs", "generate", "--vars", "--quiet", "--no-write-json" });
    try std.testing.expectEqualDeep(&[_][]const u8{ "dxt", "docs", "generate", "--profile", "first", "--vars", "--quiet" }, parsed.args);
    try std.testing.expect(parsed.options.quiet and !parsed.options.write_json);
    try std.testing.expectError(error.DuplicateGlobalOption, prepare(runtime, &.{ "dxt", "--target", "first", "parse", "--target", "last" }));
    const aliases = try prepare(runtime, &.{ "dxt", "list", "-smain", "-tprod", "--project-dir=fixture" });
    try std.testing.expectEqualDeep(&[_][]const u8{ "dxt", "ls", "--select", "main", "--target", "prod", "--project-dir", "fixture" }, aliases.args);
    const debugging = try prepare(runtime, &.{ "dxt", "--debug", "parse", "--log-level", "info" });
    try std.testing.expect(debugging.options.debug and debugging.options.log_level == .info);
}

test "cache controls preserve environment precedence and global duplication rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("DBT_POPULATE_CACHE", "false");
    try env.put("DBT_CACHE_SELECTED_ONLY", "true");
    try env.put("DBT_LOG_CACHE_EVENTS", "true");
    const runtime: types.Runtime = .{ .allocator = arena.allocator(), .io = std.testing.io, .environment = &env };
    const inherited = try prepare(runtime, &.{ "dxt", "run" });
    try std.testing.expect(!inherited.options.populate_cache and inherited.options.cache_selected_only and inherited.options.log_cache_events);
    const overridden = try prepare(runtime, &.{ "dxt", "--populate-cache", "run", "--no-cache-selected-only", "--no-log-cache-events" });
    try std.testing.expect(overridden.options.populate_cache and !overridden.options.cache_selected_only and !overridden.options.log_cache_events);
    try std.testing.expectError(error.DuplicateGlobalOption, prepare(runtime, &.{ "dxt", "--populate-cache", "run", "--no-populate-cache" }));
}
