//! dbt Core 1.10.5 config/project.py read_project_flags: root profile config is
//! a deprecated fallback, and a nonempty root flags/config pair is an error.
const std = @import("std");
const types = @import("types.zig");
const values = @import("config_value.zig");

// Adapter behavior overrides such as enable_truthy_nulls_equals_macro remain
// in the authored project flags. Core ProjectFlags does not read profile extras.
pub const names = .{ "require_generic_test_arguments_property", "validate_macro_args", "require_batched_execution_for_custom_microbatch_strategy" };

pub fn apply(runtime: types.Runtime, options: types.Options, config: *types.ProjectConfig) !bool {
    const text = (try @import("profile.zig").loadProfileText(runtime, options.project_dir, options)) orelse return false;
    defer runtime.allocator.free(text);
    var document = try @import("yaml.zig").parse(runtime.allocator, text);
    defer document.deinit();
    return applyValues(config, values.get(document.value, "config") orelse .null);
}

fn nonempty(value: std.json.Value) bool {
    return value == .object and value.object.count() != 0;
}

pub fn applyValues(config: *types.ProjectConfig, profile_config: std.json.Value) !bool {
    if (!nonempty(profile_config)) return false;
    if (nonempty(values.get(config.raw_project, "flags") orelse .null)) return error.ConflictingProjectProfileFlags;
    // Core catches ProjectFlags schema errors and returns the complete default
    // behavior configuration. A partial invalid override must not leak through.
    var valid = true;
    inline for (names) |name| {
        if (values.get(profile_config, name)) |value| if (value != .bool) {
            valid = false;
        };
    }
    inline for (names) |name| {
        const value: std.json.Value = values.get(profile_config, name) orelse .{ .bool = false };
        @field(config, name) = valid and value == .bool and value.bool;
    }
    return true;
}

test "root profile behavior flags fall back as a unit and reject explicit conflict" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var config = types.ProjectConfig{ .name = "flags" };
    defer types.deinitProjectConfig(a, &config);
    var profile: std.json.Value = .null;
    inline for (names) |name| try values.put(a, &profile, name, .{ .bool = true });
    defer values.deinit(a, &profile);
    try std.testing.expect(try applyValues(&config, profile));
    inline for (names) |name| try std.testing.expect(@field(config, name));
    try values.put(a, &profile, "validate_macro_args", .{ .string = "true" });
    try std.testing.expect(try applyValues(&config, profile));
    inline for (names) |name| try std.testing.expect(!@field(config, name));
    var flags: std.json.Value = .null;
    defer values.deinit(a, &flags);
    try values.put(a, &flags, "validate_macro_args", .{ .bool = false });
    try values.put(a, &config.raw_project, "flags", flags);
    try std.testing.expectError(error.ConflictingProjectProfileFlags, applyValues(&config, profile));
}
