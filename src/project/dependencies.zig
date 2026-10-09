//! Native package resolution. External tools provide Git, HTTP and archive transport;
//! dependency parsing, version solving, locks and installation decisions stay in Zig.
const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const config = @import("config.zig");
const json = @import("json.zig");
const yaml = @import("yaml.zig");
const package_render = @import("package_render.zig");
const Dir = std.Io.Dir;
const Runtime = types.Runtime;

pub const Options = struct {
    project_dir: []const u8 = ".",
    registry_url: ?[]const u8 = null,
    vars: ?[]const u8 = null,
    offline: bool = false,
    upgrade: bool = false,
    lock_only: bool = false,
};

const Kind = enum { local, git, registry, tarball, private };
const Spec = struct {
    kind: Kind,
    source: []const u8,
    unrendered_source: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    hash_text: ?[]const u8 = null,
    constraints: std.ArrayList([]const u8) = .empty,
    revision: ?[]const u8 = null,
    subdirectory: ?[]const u8 = null,
    name: ?[]const u8 = null,
    prerelease: bool = false,
    prerelease_set: bool = false,
    warn_unpinned: ?bool = null,
    version_list: bool = false,
};
const Declaration = struct {
    specs: std.ArrayList(Spec) = .empty,
    hash: ?[]const u8 = null,
};
const Requirement = struct {
    spec: Spec,
    key: []const u8,
    base: []const u8,
    parent: ?[]const u8 = null,
};
const Resolved = struct {
    requirement: Requirement,
    name: []const u8,
    version: ?[]const u8,
    directory: []const u8,
    metadata: ?std.json.Value = null,
};
const Failure = enum { conflict, cycle, duplicate_name };

pub fn parseOptions(args: []const []const u8, stderr: *std.Io.Writer) !Options {
    var options: Options = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (eq(arg, "--offline")) options.offline = true else if (eq(arg, "--upgrade")) options.upgrade = true else if (eq(arg, "--lock")) options.lock_only = true else if (eq(arg, "--project-dir") or eq(arg, "--registry-url") or eq(arg, "--vars")) {
            index += 1;
            if (index == args.len or args[index].len == 0 or std.mem.startsWith(u8, args[index], "--")) {
                try stderr.print("error: option `{s}` requires a value\n", .{arg});
                return error.InvalidOption;
            }
            if (eq(arg, "--project-dir")) options.project_dir = args[index] else if (eq(arg, "--vars")) options.vars = args[index] else options.registry_url = args[index];
        } else {
            try stderr.print("error: unsupported deps option `{s}`\n", .{arg});
            return error.InvalidOption;
        }
    }
    if (options.offline and options.upgrade) return error.PackageOfflineUpgrade;
    return options;
}

pub fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: dxt deps [options]
        \\
        \\Resolve packages.yml or dependencies.yml and install locked local, Git, tarball and Hub packages.
        \\
        \\Options:
        \\  --project-dir <path>
        \\  --vars <yaml>           Variables for packages.yml Jinja rendering.
        \\  --upgrade              Resolve versions again instead of retaining existing pins.
        \\  --lock                 Write package-lock.yml without changing installed packages.
        \\  --offline              Use local sources and previously downloaded packages only.
        \\  --registry-url <url>    Override DBT_PACKAGE_HUB_URL (default: https://hub.getdbt.com).
        \\
    );
}

pub fn install(runtime: Runtime, options: Options, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var arena = std.heap.ArenaAllocator.init(runtime.allocator);
    defer arena.deinit();
    const rt: Runtime = .{ .allocator = arena.allocator(), .io = runtime.io, .environment = runtime.environment };
    const root = try Dir.cwd().realPathFileAlloc(rt.io, options.project_dir, rt.allocator);
    const root_config = try config.loadProjectConfig(rt, root);
    const vars = if (options.vars) |text| blk: {
        var document = try yaml.parse(rt.allocator, text);
        defer document.deinit();
        if (document.value != .object) return error.InvalidPackageVariables;
        break :blk try package_render.clone(rt.allocator, document.value);
    } else std.json.Value.null;
    const destination = try installPathWithVars(rt, root, vars);
    const declarations = try loadDeclarationsWithVars(rt, root, vars, stderr);
    const hash = try declarationHash(rt.allocator, declarations.specs.items);
    const lock_path = try join(rt, &.{ root, "package-lock.yml" });
    const cached_lock = try optionalRead(rt, lock_path);
    var pins: []const Spec = &.{};
    if (!options.upgrade) {
        if (cached_lock) |text| {
            if (try lockHash(rt, text)) |previous_hash| {
                // A stale lock can contain env_var expressions that are no longer required.
                // Check its hash before rendering or validating those package definitions.
                if (eq(previous_hash, hash)) {
                    const locked = parseDeclarationWithVars(rt, text, vars, true, null) catch return error.InvalidPackageLock;
                    pins = locked.specs.items;
                }
            }
        }
    }
    const cache = try join(rt, &.{ root, ".dxt-deps", "cache" });
    try Dir.cwd().createDirPath(rt.io, cache);
    const registry = options.registry_url orelse if (runtime.environment) |environment| environment.get("DBT_PACKAGE_HUB_URL") orelse "https://hub.getdbt.com" else "https://hub.getdbt.com";
    var solver: Solver = .{ .runtime = rt, .options = options, .root = root, .root_name = root_config.name, .cache = cache, .registry = std.mem.trimEnd(u8, registry, "/"), .pins = pins, .vars = vars, .stderr = stderr, .fetched = std.StringHashMap(void).init(rt.allocator) };
    var requirements: std.ArrayList(Requirement) = .empty;
    for (declarations.specs.items) |spec| try requirements.append(rt.allocator, try solver.requirement(spec, root, null));
    const resolved = try solver.solve(requirements.items, &.{}, 0) orelse return switch (solver.failure) {
        .conflict => error.PackageVersionConflict,
        .cycle => error.PackageDependencyCycle,
        .duplicate_name => error.DuplicatePackageName,
    };
    const lock_text = try renderLock(rt.allocator, root, resolved, hash);
    // Prepare the complete replacement before touching either installed packages or the lock.
    if (!options.lock_only) {
        const stage = try join(rt, &.{ root, ".dxt-deps", "install-stage" });
        try removeTree(rt, stage);
        try Dir.cwd().createDirPath(rt.io, stage);
        errdefer removeTree(rt, stage) catch {};
        for (resolved) |package| {
            const path = try join(rt, &.{ stage, package.name });
            if (package.requirement.spec.kind == .local) {
                // Core links local packages, including a parent package's own
                // integration project. Linking preserves edits and cannot
                // recurse into the generated installation stage.
                try Dir.cwd().symLink(rt.io, package.directory, path, .{ .is_directory = true });
            } else try solver.copyPackage(package.directory, path);
        }
        const backup = try join(rt, &.{ root, ".dxt-deps", "install-backup" });
        try removeTree(rt, backup);
        try Dir.cwd().createDirPath(rt.io, std.fs.path.dirname(destination).?);
        var had_previous = false;
        Dir.rename(Dir.cwd(), destination, Dir.cwd(), backup, rt.io) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        had_previous = exists(rt, backup);
        Dir.rename(Dir.cwd(), stage, Dir.cwd(), destination, rt.io) catch |err| {
            if (had_previous) Dir.rename(Dir.cwd(), backup, Dir.cwd(), destination, rt.io) catch {};
            return err;
        };
        writeAtomic(rt, lock_path, lock_text) catch |err| {
            removeTree(rt, destination) catch {};
            if (had_previous) Dir.rename(Dir.cwd(), backup, Dir.cwd(), destination, rt.io) catch {};
            return err;
        };
        try removeTree(rt, backup);
    } else try writeAtomic(rt, lock_path, lock_text);
    for (resolved) |package| try stdout.print("{s} {s}{s}{s}\n", .{ if (options.lock_only) "Locked" else "Installed", package.name, if (package.version != null) " @ " else "", package.version orelse "" });
    try stdout.print("{s} {d} package(s)\n", .{ if (options.lock_only) "Locked" else "Installed", resolved.len });
}

/// Shared with the loader so custom installation directories participate in parse/compile.
pub fn installPath(runtime: Runtime, project_dir: []const u8) ![]const u8 {
    return installPathWithVars(runtime, project_dir, .null);
}

pub fn installPathWithVars(runtime: Runtime, project_dir: []const u8, vars: std.json.Value) ![]const u8 {
    const text = (try optionalRead(runtime, try join(runtime, &.{ project_dir, "dbt_project.yml" }))) orelse return error.MissingProjectFile;
    var path: []const u8 = "dbt_packages";
    var document = try yaml.parse(runtime.allocator, text);
    defer document.deinit();
    if (document.value != .object) return error.InvalidProjectConfig;
    if (document.value.object.get("packages-install-path")) |value| {
        var renderer = package_render.Context.init(runtime, vars);
        const rendered = try renderer.render(value);
        if (rendered != .string) return error.InvalidPackagesInstallPath;
        path = rendered.string;
    }
    if (!safeRelativePath(path)) return error.InvalidPackagesInstallPath;
    var first_segment = std.mem.splitScalar(u8, path, '/');
    const first = first_segment.next().?;
    for ([_][]const u8{ "models", "seeds", "macros", "tests", "analyses", "snapshots", ".git", ".dxt-deps" }) |protected| {
        if (eq(first, protected)) return error.InvalidPackagesInstallPath;
    }
    var cli_entries: std.ArrayList(types.VarEntry) = .empty;
    defer cli_entries.deinit(runtime.allocator);
    if (vars == .object) {
        var vars_it = vars.object.iterator();
        while (vars_it.next()) |entry| try cli_entries.append(runtime.allocator, .{ .name = entry.key_ptr.*, .value = "", .typed_value = entry.value_ptr.*, .priority = 100 });
    }
    var project_config = try config.loadProjectConfigWithContext(runtime, project_dir, cli_entries.items, .null);
    defer types.deinitProjectConfig(runtime.allocator, &project_config);
    for ([_][]const []const u8{ project_config.model_paths.items, project_config.seed_paths.items, project_config.macro_paths.items, project_config.test_paths.items, project_config.analysis_paths.items, project_config.snapshot_paths.items }) |source_paths| {
        for (source_paths) |source_path| {
            const normalized = std.mem.trimEnd(u8, std.mem.trimStart(u8, source_path, "./"), "/");
            if (normalized.len != 0 and (containsPath(normalized, path) or containsPath(path, normalized))) return error.InvalidPackagesInstallPath;
        }
    }
    const destination = try join(runtime, &.{ project_dir, path });
    const canonical_root = try Dir.cwd().realPathFileAlloc(runtime.io, project_dir, runtime.allocator);
    var probe = destination;
    while (true) {
        const canonical_parent = Dir.cwd().realPathFileAlloc(runtime.io, probe, runtime.allocator) catch |err| switch (err) {
            error.FileNotFound => {
                probe = std.fs.path.dirname(probe) orelse return error.InvalidPackagesInstallPath;
                continue;
            },
            else => return err,
        };
        if (!containsPath(canonical_root, canonical_parent)) return error.InvalidPackagesInstallPath;
        break;
    }
    return destination;
}

const Solver = struct {
    runtime: Runtime,
    options: Options,
    root: []const u8,
    root_name: []const u8,
    cache: []const u8,
    registry: []const u8,
    pins: []const Spec,
    vars: std.json.Value,
    stderr: *std.Io.Writer,
    failure: Failure = .conflict,
    steps: usize = 0,
    fetched: std.StringHashMap(void),

    fn requirement(self: *Solver, spec: Spec, base: []const u8, parent: ?[]const u8) !Requirement {
        var source = spec.source;
        if (spec.kind == .local) {
            // Core resolves every local declaration from the root project, including transitives.
            source = Dir.cwd().realPathFileAlloc(self.runtime.io, try rootedPath(self.runtime, self.root, source), self.runtime.allocator) catch |err| switch (err) {
                error.FileNotFound => return error.MissingLocalPackage,
                else => return err,
            };
            if (eq(source, self.root)) return error.PackageDependencyCycle;
            if (containsPath(try join(self.runtime, &.{ self.root, ".dxt-deps" }), source)) return error.InvalidLocalPackage;
        }
        if (spec.kind == .registry) source = (try self.registryInfo(source)).canonical;
        if (spec.kind == .private) source = try self.gitSource(spec);
        const key = try std.fmt.allocPrint(self.runtime.allocator, "{s}:{s}:{s}", .{ @tagName(spec.kind), source, spec.subdirectory orelse "" });
        return .{ .spec = spec, .base = base, .key = key, .parent = parent };
    }

    fn solve(self: *Solver, requirements: []const Requirement, assigned: []const Resolved, depth: usize) anyerror!?[]const Resolved {
        self.steps += 1;
        if (depth > 128 or self.steps > 10000) return error.PackageResolutionLimit;
        var unresolved: ?Requirement = null;
        for (requirements) |requirement_| {
            var found = false;
            for (assigned) |package| {
                if (!eq(package.requirement.key, requirement_.key)) continue;
                found = true;
                if (!try self.matches(requirement_, package)) {
                    self.failure = .conflict;
                    return null;
                }
            }
            if (!found and unresolved == null) unresolved = requirement_;
        }
        const request = unresolved orelse {
            if (hasCycle(self.runtime.allocator, requirements, assigned)) {
                self.failure = .cycle;
                return null;
            }
            return assigned;
        };
        const available_versions = try self.candidates(request);
        for (available_versions) |candidate| {
            const package = try self.materialize(request, candidate);
            if (eq(package.name, self.root_name)) {
                self.failure = .duplicate_name;
                continue;
            }
            var collision = false;
            for (assigned) |other| if (eq(package.name, other.name)) {
                collision = true;
                self.failure = .duplicate_name;
            };
            if (collision) continue;
            const next_assigned = try self.runtime.allocator.alloc(Resolved, assigned.len + 1);
            @memcpy(next_assigned[0..assigned.len], assigned);
            next_assigned[assigned.len] = package;
            var next_requirements: std.ArrayList(Requirement) = .empty;
            try next_requirements.appendSlice(self.runtime.allocator, requirements);
            const children = if (package.metadata) |metadata| blk: {
                if (metadata.object.get("packages")) |packages_value| break :blk try parseJsonSpecs(self.runtime, packages_value);
                break :blk (try loadDeclarationsWithVars(self.runtime, package.directory, self.vars, self.stderr)).specs;
            } else (try loadDeclarationsWithVars(self.runtime, package.directory, self.vars, self.stderr)).specs;
            for (children.items) |child| try next_requirements.append(self.runtime.allocator, try self.requirement(child, package.directory, request.key));
            if (try self.solve(next_requirements.items, next_assigned, depth + 1)) |solution| return solution;
        }
        return null;
    }

    fn matches(self: *Solver, request: Requirement, package: Resolved) !bool {
        if (request.spec.kind == .registry) return try satisfiesAll(package.version.?, request.spec.constraints.items);
        if (gitLike(request.spec.kind)) {
            const revision = request.spec.revision orelse "HEAD";
            if (eq(revision, package.requirement.spec.revision orelse "HEAD") or eq(revision, package.version.?)) return true;
            const repo = try self.gitRepository(request);
            const commit = try self.gitCommit(repo, revision);
            return eq(commit, package.version.?);
        }
        return true;
    }

    fn pin(self: *Solver, request: Requirement) ?Spec {
        for (self.pins) |spec| {
            if (spec.kind == request.spec.kind and eq(spec.source, request.spec.source) and eq(spec.subdirectory orelse "", request.spec.subdirectory orelse "")) return spec;
        }
        return null;
    }

    fn candidates(self: *Solver, request: Requirement) ![]const ?[]const u8 {
        if (request.spec.kind != .registry) {
            const result = try self.runtime.allocator.alloc(?[]const u8, 1);
            result[0] = if (self.pin(request)) |pinned| pinned.revision else request.spec.revision;
            return result;
        }
        const metadata = try self.registryMetadata(request.spec.source);
        const versions = metadata.object.get("versions") orelse return error.InvalidPackageRegistry;
        if (versions != .object) return error.InvalidPackageRegistry;
        var result: std.ArrayList(?[]const u8) = .empty;
        var iterator = versions.object.iterator();
        while (iterator.next()) |entry| {
            const version = entry.key_ptr.*;
            const parsed = SemVersion.parse(version) catch return error.InvalidPackageRegistry;
            if (parsed.prerelease.len != 0 and !request.spec.prerelease and !hasPrereleaseConstraint(request.spec.constraints.items)) continue;
            if (!try satisfiesAll(version, request.spec.constraints.items)) continue;
            if (self.pin(request)) |pinned| {
                if (pinned.constraints.items.len != 1 or !eq(version, pinned.constraints.items[0])) continue;
            }
            if (entry.value_ptr.* != .object) return error.InvalidPackageRegistry;
            if (entry.value_ptr.object.get("require_dbt_version")) |required| {
                var constraints: std.ArrayList([]const u8) = .empty;
                try jsonConstraints(self.runtime, required, &constraints);
                if (!try satisfiesAll("1.10.5", constraints.items)) continue;
            }
            try result.append(self.runtime.allocator, version);
        }
        std.mem.sort(?[]const u8, result.items, {}, struct {
            fn less(_: void, a: ?[]const u8, b: ?[]const u8) bool {
                return SemVersion.order(SemVersion.parse(a.?) catch unreachable, SemVersion.parse(b.?) catch unreachable) == .gt;
            }
        }.less);
        return result.items;
    }

    fn registryMetadata(self: *Solver, source: []const u8) !std.json.Value {
        return (try self.registryInfo(source)).metadata;
    }

    fn registryInfo(self: *Solver, original: []const u8) !struct { canonical: []const u8, metadata: std.json.Value } {
        var source = original;
        var seen = std.StringHashMap(void).init(self.runtime.allocator);
        while (seen.count() < 32) {
            if (seen.contains(source)) return error.PackageRegistryRedirectCycle;
            try seen.put(source, {});
            const metadata = try self.registryResponse(source);
            if (metadata.object.contains("redirectnamespace") or metadata.object.contains("redirectname")) {
                var pieces = std.mem.splitScalar(u8, source, '/');
                const old_namespace = pieces.next().?;
                const old_name = pieces.next().?;
                const namespace = try metadataString(metadata, "redirectnamespace") orelse try metadataString(metadata, "namespace") orelse old_namespace;
                const name = try metadataString(metadata, "redirectname") orelse try metadataString(metadata, "name") orelse old_name;
                const canonical = try std.fmt.allocPrint(self.runtime.allocator, "{s}/{s}", .{ namespace, name });
                if (!validRegistryName(canonical)) return error.InvalidPackageRegistry;
                if (!eq(source, canonical)) {
                    const warning_key = try std.fmt.allocPrint(self.runtime.allocator, "redirect:{s}", .{source});
                    if (!self.fetched.contains(warning_key)) {
                        try self.stderr.print("warning: package {s} was renamed to {s}\n", .{ source, canonical });
                        try self.fetched.put(warning_key, {});
                    }
                    // Hub normally embeds version metadata in redirect responses.
                    // Follow a metadata-only redirect as well, with cycle checks.
                    if (metadata.object.get("versions")) |versions| if (versions == .object) return .{ .canonical = canonical, .metadata = metadata };
                    source = canonical;
                    continue;
                }
            }
            return .{ .canonical = source, .metadata = metadata };
        }
        return error.PackageRegistryRedirectCycle;
    }

    fn registryResponse(self: *Solver, source: []const u8) !std.json.Value {
        if (!validRegistryName(source)) return error.InvalidPackageDeclaration;
        const url = try std.fmt.allocPrint(self.runtime.allocator, "{s}/api/v1/{s}.json", .{ self.registry, source });
        const path = try self.cachePath("metadata", url, ".json");
        if ((!exists(self.runtime, path) or self.options.upgrade) and !self.fetched.contains(path)) {
            try self.download(url, path);
            try self.fetched.put(path, {});
        }
        const data = try Dir.cwd().readFileAlloc(self.runtime.io, path, self.runtime.allocator, .limited(16 * 1024 * 1024));
        const parsed = std.json.parseFromSlice(std.json.Value, self.runtime.allocator, data, .{ .allocate = .alloc_always }) catch return error.InvalidPackageRegistry;
        if (parsed.value != .object) return error.InvalidPackageRegistry;
        return parsed.value;
    }

    fn materialize(self: *Solver, request: Requirement, candidate: ?[]const u8) !Resolved {
        var directory: []const u8 = undefined;
        var version: ?[]const u8 = null;
        var metadata: ?std.json.Value = null;
        switch (request.spec.kind) {
            .local => {
                directory = try Dir.cwd().realPathFileAlloc(self.runtime.io, try rootedPath(self.runtime, self.root, request.spec.source), self.runtime.allocator);
            },
            .git, .private => {
                const requested_revision = request.spec.revision orelse "HEAD";
                if (self.pin(request) == null and request.spec.warn_unpinned != false and (eq(requested_revision, "HEAD") or eq(requested_revision, "main") or eq(requested_revision, "master"))) {
                    const warning_key = try std.fmt.allocPrint(self.runtime.allocator, "warning:{s}", .{request.key});
                    if (!self.fetched.contains(warning_key)) {
                        try self.stderr.writeAll("warning: Git package revision is unpinned; package-lock.yml records the resolved commit\n");
                        try self.fetched.put(warning_key, {});
                    }
                }
                const repository = try self.gitRepository(request);
                version = try self.gitCommit(repository, candidate orelse "HEAD");
                const identity = try std.fmt.allocPrint(self.runtime.allocator, "{s}@{s}", .{ request.key, version.? });
                directory = try self.cachePath("git-tree", identity, "");
                if (!exists(self.runtime, try join(self.runtime, &.{ directory, ".dxt-complete" }))) {
                    const archive = try self.cachePath("git-archive", identity, ".tar");
                    _ = try self.command(&.{ "git", "-C", repository, "archive", "--format=tar", "--output", archive, version.? }, error.GitPackageFailed);
                    try self.extract(archive, directory, false);
                }
                if (request.spec.subdirectory) |subdirectory| {
                    if (!safeRelativePath(subdirectory)) return error.InvalidPackageSubdirectory;
                    directory = try join(self.runtime, &.{ directory, subdirectory });
                }
            },
            .registry => {
                version = candidate orelse return error.PackageVersionConflict;
                const registry_metadata = try self.registryMetadata(request.spec.source);
                const versions = registry_metadata.object.get("versions").?;
                const selected = versions.object.get(version.?) orelse return error.PackageVersionConflict;
                metadata = selected;
                const downloads = selected.object.get("downloads") orelse return error.InvalidPackageRegistry;
                if (downloads != .object) return error.InvalidPackageRegistry;
                const tarball = downloads.object.get("tarball") orelse return error.InvalidPackageRegistry;
                if (tarball != .string) return error.InvalidPackageRegistry;
                const archive = try self.cachePath("archive", tarball.string, ".tar.gz");
                if (!exists(self.runtime, archive)) try self.download(tarball.string, archive);
                directory = try self.cachePath("registry-tree", tarball.string, "");
                if (!exists(self.runtime, try join(self.runtime, &.{ directory, ".dxt-complete" }))) try self.extract(archive, directory, true);
            },
            .tarball => {
                const archive = try self.cachePath("archive", request.spec.source, ".tar.gz");
                if (!exists(self.runtime, archive) or self.options.upgrade) try self.download(request.spec.source, archive);
                directory = try self.cachePath("tarball-tree", request.spec.source, "");
                if (self.options.upgrade or !exists(self.runtime, try join(self.runtime, &.{ directory, ".dxt-complete" }))) try self.extract(archive, directory, true);
            },
        }
        const package_config = config.loadProjectConfig(self.runtime, directory) catch |err| switch (err) {
            error.MissingProjectFile => return error.InvalidPackageProject,
            else => return err,
        };
        if (!validProjectName(package_config.name)) return error.InvalidPackageProject;
        if (request.spec.name) |expected_name| if (!eq(package_config.name, expected_name)) return error.InvalidPackageProject;
        return .{ .requirement = request, .name = package_config.name, .directory = directory, .version = version, .metadata = metadata };
    }

    fn gitRepository(self: *Solver, request: Requirement) ![]const u8 {
        const git_source = try self.gitSource(request.spec);
        const path = try self.cachePath("git", git_source, "");
        if (!exists(self.runtime, path)) {
            if (self.options.offline) return error.PackageOfflineCacheMiss;
            errdefer removeTree(self.runtime, path) catch {};
            var source = git_source;
            if (!std.mem.containsAtLeast(u8, source, 1, ":") and !std.fs.path.isAbsolute(source)) source = try join(self.runtime, &.{ self.root, source });
            _ = try self.command(&.{ "git", "clone", "--no-checkout", "--", source, path }, error.GitPackageFailed);
        } else if (self.options.upgrade) _ = try self.command(&.{ "git", "-C", path, "fetch", "--tags", "--force", "origin" }, error.GitPackageFailed);
        return path;
    }

    fn gitSource(self: *Solver, spec: Spec) ![]const u8 {
        if (spec.kind != .private or std.mem.containsAtLeast(u8, spec.source, 1, ":") or std.fs.path.isAbsolute(spec.source) or std.mem.startsWith(u8, spec.source, ".")) return spec.source;
        const provider = spec.provider orelse "github";
        const host = if (eq(provider, "github")) "github.com" else if (eq(provider, "gitlab")) "gitlab.com" else if (eq(provider, "bitbucket")) "bitbucket.org" else return error.InvalidPackageProvider;
        if (!safeRelativePath(spec.source) or !std.mem.containsAtLeast(u8, spec.source, 1, "/")) return error.InvalidPackageDeclaration;
        return try std.fmt.allocPrint(self.runtime.allocator, "https://{s}/{s}{s}", .{ host, spec.source, if (std.mem.endsWith(u8, spec.source, ".git")) "" else ".git" });
    }

    fn gitCommit(self: *Solver, repository: []const u8, revision: []const u8) ![]const u8 {
        if (revision.len == 0 or revision[0] == '-' or std.mem.containsAtLeast(u8, revision, 1, "\n")) return error.InvalidPackageRevision;
        const object = try std.fmt.allocPrint(self.runtime.allocator, "{s}^{{commit}}", .{revision});
        if (self.options.upgrade) {
            const remote_object = try std.fmt.allocPrint(self.runtime.allocator, "origin/{s}^{{commit}}", .{revision});
            const remote = self.command(&.{ "git", "-C", repository, "rev-parse", "--verify", remote_object }, error.InvalidPackageRevision) catch null;
            if (remote) |commit| return std.mem.trim(u8, commit, " \t\r\n");
        }
        const result = self.command(&.{ "git", "-C", repository, "rev-parse", "--verify", object }, error.InvalidPackageRevision) catch |err| blk: {
            if (err != error.InvalidPackageRevision or self.options.offline) return err;
            _ = try self.command(&.{ "git", "-C", repository, "fetch", "--tags", "origin" }, error.GitPackageFailed);
            break :blk try self.command(&.{ "git", "-C", repository, "rev-parse", "--verify", object }, error.InvalidPackageRevision);
        };
        return std.mem.trim(u8, result, " \t\r\n");
    }

    fn cachePath(self: *Solver, prefix: []const u8, key: []const u8, suffix: []const u8) ![]const u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(key, &digest, .{});
        const filename = try std.fmt.allocPrint(self.runtime.allocator, "{s}-{s}{s}", .{ prefix, std.fmt.bytesToHex(digest, .lower), suffix });
        return try join(self.runtime, &.{ self.cache, filename });
    }

    fn download(self: *Solver, url: []const u8, path: []const u8) !void {
        if (self.options.offline) return error.PackageOfflineCacheMiss;
        if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) return error.InvalidPackageRegistry;
        const temporary = try std.fmt.allocPrint(self.runtime.allocator, "{s}.download", .{path});
        defer Dir.cwd().deleteFile(self.runtime.io, temporary) catch {};
        _ = try self.command(&.{ "curl", "--fail", "--location", "--silent", "--show-error", "--connect-timeout", "15", "--max-time", "60", "--proto", "=http,https", "--proto-redir", "=http,https", "--output", temporary, "--", url }, error.PackageNetworkFailed);
        try Dir.rename(Dir.cwd(), temporary, Dir.cwd(), path, self.runtime.io);
    }

    fn extract(self: *Solver, archive: []const u8, directory: []const u8, gzip: bool) !void {
        const listing = try self.command(&.{ "tar", if (gzip) "-tzf" else "-tf", archive }, error.InvalidPackageArchive);
        const strip = if (gzip) try archiveStripCount(listing) else blk: {
            try validateArchivePaths(listing);
            break :blk @as(u8, 0);
        };
        // Reject links and special files before extraction; all payload writes stay inside the stage.
        const verbose = try self.command(&.{ "tar", if (gzip) "-tvzf" else "-tvf", archive }, error.InvalidPackageArchive);
        var lines = std.mem.splitScalar(u8, verbose, '\n');
        while (lines.next()) |line| if (line.len != 0 and line[0] != '-' and line[0] != 'd') return error.UnsafePackageArchive;
        const stage = try std.fmt.allocPrint(self.runtime.allocator, "{s}.extract", .{directory});
        try removeTree(self.runtime, stage);
        try Dir.cwd().createDirPath(self.runtime.io, stage);
        errdefer removeTree(self.runtime, stage) catch {};
        _ = try self.command(&.{ "tar", if (gzip) "-xzf" else "-xf", archive, "--directory", stage, if (strip == 1) "--strip-components=1" else "--strip-components=0", "--no-same-owner", "--no-same-permissions" }, error.InvalidPackageArchive);
        try Dir.cwd().writeFile(self.runtime.io, .{ .sub_path = try join(self.runtime, &.{ stage, ".dxt-complete" }), .data = "1\n" });
        try removeTree(self.runtime, directory);
        try Dir.rename(Dir.cwd(), stage, Dir.cwd(), directory, self.runtime.io);
    }

    fn copyPackage(self: *Solver, source: []const u8, destination: []const u8) !void {
        _ = try self.command(&.{ "cp", "-R", "--", source, destination }, error.PackageInstallFailed);
        for ([_][]const u8{ ".git", ".dxt-deps", ".dxt-complete", "dbt_packages", "target", "logs" }) |generated| try removeTree(self.runtime, try join(self.runtime, &.{ destination, generated }));
    }

    fn command(self: *Solver, argv: []const []const u8, failure: anyerror) ![]const u8 {
        const result = std.process.run(self.runtime.allocator, self.runtime.io, .{ .argv = argv, .environ_map = self.runtime.environment, .stdout_limit = .limited(16 * 1024 * 1024), .stderr_limit = .limited(64 * 1024) }) catch |err| switch (err) {
            error.FileNotFound => return error.PackageTransportNotFound,
            else => return err,
        };
        switch (result.term) {
            .exited => |code| if (code == 0) return result.stdout,
            else => {},
        }
        // Transport errors may contain credentialed URLs; expose only known safe failure classes.
        if (eq(argv[0], "curl")) {
            if (std.mem.containsAtLeast(u8, result.stderr, 1, "403")) try self.stderr.writeAll("error: package download denied (HTTP 403)\n") else if (std.mem.containsAtLeast(u8, result.stderr, 1, "404")) try self.stderr.writeAll("error: package download not found (HTTP 404)\n") else if (std.mem.containsAtLeast(u8, result.stderr, 1, "Could not resolve host")) try self.stderr.writeAll("error: package host could not be resolved\n");
        }
        return failure;
    }
};

fn loadDeclarationsWithVars(runtime: Runtime, directory: []const u8, vars: std.json.Value, stderr: *std.Io.Writer) !Declaration {
    const packages = try optionalRead(runtime, try join(runtime, &.{ directory, "packages.yml" }));
    const dependencies = try optionalRead(runtime, try join(runtime, &.{ directory, "dependencies.yml" }));
    if (packages != null and dependencies != null) return error.MultiplePackageDeclarations;
    // Core deliberately keeps dependencies.yml static.
    var diagnostic: yaml.Diagnostic = .{};
    return parseDeclarationWithVars(runtime, packages orelse dependencies orelse "packages: []\n", vars, dependencies == null, &diagnostic) catch |err| {
        if (diagnostic.message.len != 0) try stderr.print("error: invalid YAML in {s} at line {d}, column {d}: {s}\n", .{ if (packages != null) "packages.yml" else "dependencies.yml", diagnostic.line, diagnostic.column, diagnostic.message });
        return err;
    };
}

fn lockHash(runtime: Runtime, text: []const u8) !?[]const u8 {
    var document = yaml.parse(runtime.allocator, text) catch return error.InvalidPackageLock;
    defer document.deinit();
    if (document.value != .object) return error.InvalidPackageLock;
    const value = document.value.object.get("sha1_hash") orelse return null;
    if (value != .string) return error.InvalidPackageLock;
    return try runtime.allocator.dupe(u8, value.string);
}

fn parseDeclaration(runtime: Runtime, text: []const u8) !Declaration {
    return parseDeclarationWithVars(runtime, text, .null, true, null);
}

fn parseDeclarationWithVars(runtime: Runtime, text: []const u8, vars: std.json.Value, render: bool, diagnostic: ?*yaml.Diagnostic) !Declaration {
    var document = yaml.parseWithDiagnostics(runtime.allocator, text, diagnostic) catch return error.InvalidPackageDeclaration;
    defer document.deinit();
    if (document.value == .null) return .{};
    if (document.value != .object) return error.InvalidPackageDeclaration;
    if (document.value.object.get("projects")) |projects| if (projects != .array or projects.array.items.len != 0) return error.UnsupportedProjectDependency;
    var declaration: Declaration = .{};
    if (document.value.object.get("packages")) |value| declaration.specs = try parseSpecsWithVars(runtime, value, vars, render);
    if (document.value.object.get("sha1_hash")) |value| {
        if (value != .string) return error.InvalidPackageLock;
        declaration.hash = try runtime.allocator.dupe(u8, value.string);
    }
    var fields = document.value.object.iterator();
    while (fields.next()) |field| if (!eq(field.key_ptr.*, "packages") and !eq(field.key_ptr.*, "projects") and !eq(field.key_ptr.*, "sha1_hash")) return error.InvalidPackageDeclaration;
    return declaration;
}

fn parseJsonSpecs(runtime: Runtime, value: std.json.Value) !std.ArrayList(Spec) {
    return parseSpecsWithVars(runtime, value, .null, true);
}

fn parseSpecsWithVars(runtime: Runtime, value: std.json.Value, vars: std.json.Value, render: bool) !std.ArrayList(Spec) {
    if (value != .array) return error.InvalidPackageDeclaration;
    var result: std.ArrayList(Spec) = .empty;
    for (value.array.items) |raw_entry| {
        if (raw_entry != .object) return error.InvalidPackageDeclaration;
        var renderer = package_render.Context.init(runtime, vars);
        const entry = if (render) try renderer.render(raw_entry) else try package_render.clone(runtime.allocator, raw_entry);
        var package: ?Spec = null;
        for ([_]Kind{ .local, .git, .registry, .tarball, .private }) |kind| {
            const key = sourceKey(kind);
            if (entry.object.get(key)) |source| {
                if (source != .string or package != null) return error.InvalidPackageDeclaration;
                const original = raw_entry.object.get(key).?;
                if (original != .string) return error.InvalidPackageDeclaration;
                package = .{ .kind = kind, .source = source.string, .unrendered_source = try runtime.allocator.dupe(u8, original.string) };
            }
        }
        if (package == null) return error.InvalidPackageDeclaration;
        var iterator = entry.object.iterator();
        while (iterator.next()) |field| {
            const key = field.key_ptr.*;
            const item = field.value_ptr.*;
            if (eq(key, sourceKey(package.?.kind))) continue;
            if (eq(key, "version")) {
                package.?.version_list = item == .array;
                try jsonConstraints(runtime, item, &package.?.constraints);
            } else if (eq(key, "revision")) package.?.revision = try optionalNumericScalar(runtime.allocator, item) else if (eq(key, "subdirectory")) package.?.subdirectory = try optionalString(item) else if (eq(key, "provider")) package.?.provider = try optionalString(item) else if (eq(key, "name")) package.?.name = try optionalString(item) else if (eq(key, "install_prerelease")) {
                if (item != .bool and item != .null) return error.InvalidPackageDeclaration;
                package.?.prerelease = item == .bool and item.bool;
                package.?.prerelease_set = true;
            } else if (eq(key, "warn-unpinned")) {
                if (item != .bool and item != .null) return error.InvalidPackageDeclaration;
                package.?.warn_unpinned = if (item == .bool) item.bool else null;
            } else if (eq(key, "unrendered")) {
                if (item != .object) return error.InvalidPackageDeclaration;
            } else return error.InvalidPackageDeclaration;
        }
        try validateSpec(package.?);
        var normalized = try package_render.clone(runtime.allocator, entry);
        if (normalized.object.get("name")) |name| {
            if (name == .null) _ = normalized.object.swapRemove("name");
        }
        if (gitLike(package.?.kind)) {
            for ([_][]const u8{ "revision", "subdirectory", "warn-unpinned" }) |key| if (!normalized.object.contains(key)) try normalized.object.put(runtime.allocator, key, .null);
            if (package.?.kind == .private and !normalized.object.contains("provider")) try normalized.object.put(runtime.allocator, "provider", .null);
        }
        if (package.?.kind == .registry and !normalized.object.contains("install_prerelease")) try normalized.object.put(runtime.allocator, "install_prerelease", .{ .bool = false });
        try normalized.object.put(runtime.allocator, "unrendered", try package_render.clone(runtime.allocator, raw_entry));
        var hash_output: std.Io.Writer.Allocating = .init(runtime.allocator);
        try writePythonJson(runtime.allocator, &hash_output.writer, normalized);
        package.?.hash_text = try hash_output.toOwnedSlice();
        try result.append(runtime.allocator, package.?);
    }
    return result;
}

fn optionalString(value: std.json.Value) !?[]const u8 {
    return if (value == .null) null else if (value == .string) value.string else error.InvalidPackageDeclaration;
}

fn optionalNumericScalar(allocator: std.mem.Allocator, value: std.json.Value) !?[]const u8 {
    return switch (value) {
        .null => null,
        .string => |text| text,
        .integer => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
        .float => |number| try pythonFloat(allocator, number),
        .number_string => |text| text,
        else => error.InvalidPackageDeclaration,
    };
}

fn jsonConstraints(runtime: Runtime, value: std.json.Value, out: *std.ArrayList([]const u8)) anyerror!void {
    switch (value) {
        .array => for (value.array.items) |item| {
            if (item == .array or item == .null) return error.InvalidPackageDeclaration;
            try jsonConstraints(runtime, item, out);
        },
        .null => {},
        else => try out.append(runtime.allocator, (try optionalNumericScalar(runtime.allocator, value)).?),
    }
}

fn gitLike(kind: Kind) bool {
    return kind == .git or kind == .private;
}

fn metadataString(value: std.json.Value, key: []const u8) !?[]const u8 {
    const item = value.object.get(key) orelse return null;
    if (item == .null) return null;
    if (item != .string) return error.InvalidPackageRegistry;
    return if (item.string.len == 0) null else item.string;
}

fn validateSpec(spec: Spec) !void {
    if (spec.source.len == 0 or spec.source[0] == '-' or std.mem.containsAtLeast(u8, spec.source, 1, "\n")) return error.InvalidPackageDeclaration;
    if (spec.kind == .registry and (spec.constraints.items.len == 0 or !validRegistryName(spec.source))) return error.InvalidPackageDeclaration;
    if (spec.kind != .registry and (spec.constraints.items.len != 0 or spec.prerelease_set)) return error.InvalidPackageDeclaration;
    if (!gitLike(spec.kind) and (spec.revision != null or spec.subdirectory != null or spec.warn_unpinned != null)) return error.InvalidPackageDeclaration;
    if (spec.kind != .private and spec.provider != null) return error.InvalidPackageDeclaration;
    if (spec.kind == .private) if (spec.provider) |provider| if (!eq(provider, "github") and !eq(provider, "gitlab") and !eq(provider, "bitbucket")) return error.InvalidPackageProvider;
    if (spec.kind == .tarball and spec.name == null) return error.InvalidPackageDeclaration;
    if (spec.subdirectory) |subdirectory| if (!safeRelativePath(subdirectory)) return error.InvalidPackageSubdirectory;
    if (spec.name) |name| if (!validProjectName(name)) return error.InvalidPackageDeclaration;
    for (spec.constraints.items) |constraint| _ = try satisfies("1.10.5", constraint);
}

const SemVersion = struct {
    major: u64,
    minor: u64,
    patch: u64 = 0,
    prerelease: []const u8 = "",

    fn parse(text: []const u8) !SemVersion {
        const without_metadata = if (std.mem.indexOfScalar(u8, text, '+')) |index| text[0..index] else text;
        const dash = std.mem.indexOfScalar(u8, without_metadata, '-');
        const numeric = if (dash) |index| without_metadata[0..index] else without_metadata;
        var pieces = std.mem.splitScalar(u8, numeric, '.');
        var result: SemVersion = .{ .major = try number(pieces.next() orelse return error.InvalidPackageVersion), .minor = try number(pieces.next() orelse return error.InvalidPackageVersion) };
        if (pieces.next()) |patch| result.patch = try number(patch);
        if (pieces.next() != null) return error.InvalidPackageVersion;
        if (dash) |index| {
            result.prerelease = without_metadata[index + 1 ..];
            if (result.prerelease.len == 0) return error.InvalidPackageVersion;
            var ids = std.mem.splitScalar(u8, result.prerelease, '.');
            while (ids.next()) |id| {
                if (id.len == 0) return error.InvalidPackageVersion;
                for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-') return error.InvalidPackageVersion;
            }
        }
        return result;
    }

    fn number(text: []const u8) !u64 {
        if (text.len == 0 or (text.len > 1 and text[0] == '0')) return error.InvalidPackageVersion;
        for (text) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidPackageVersion;
        return std.fmt.parseInt(u64, text, 10) catch error.InvalidPackageVersion;
    }

    fn order(a: SemVersion, b: SemVersion) std.math.Order {
        inline for (.{ "major", "minor", "patch" }) |field| {
            const result = std.math.order(@field(a, field), @field(b, field));
            if (result != .eq) return result;
        }
        if (a.prerelease.len == 0 and b.prerelease.len != 0) return .gt;
        if (a.prerelease.len != 0 and b.prerelease.len == 0) return .lt;
        var left = std.mem.splitScalar(u8, a.prerelease, '.');
        var right = std.mem.splitScalar(u8, b.prerelease, '.');
        while (true) {
            const x = left.next();
            const y = right.next();
            if (x == null or y == null) return if (x == null and y == null) .eq else if (x == null) .lt else .gt;
            const nx = std.fmt.parseInt(u64, x.?, 10) catch null;
            const ny = std.fmt.parseInt(u64, y.?, 10) catch null;
            const result = if (nx != null and ny != null) std.math.order(nx.?, ny.?) else if (nx != null) std.math.Order.lt else if (ny != null) std.math.Order.gt else std.mem.order(u8, x.?, y.?);
            if (result != .eq) return result;
        }
    }
};

fn satisfies(version: []const u8, raw_constraint: []const u8) !bool {
    var result = true;
    var clauses = std.mem.splitScalar(u8, raw_constraint, ',');
    while (clauses.next()) |raw_clause| {
        const clause = std.mem.trim(u8, raw_clause, " \t");
        if (eq(clause, "*")) continue;
        var index: usize = 0;
        while (index < clause.len and std.mem.indexOfScalar(u8, "><=!", clause[index]) != null) index += 1;
        const operator = clause[0..index];
        const value = std.mem.trim(u8, clause[index..], " \t");
        const compared = SemVersion.order(try SemVersion.parse(version), try SemVersion.parse(value));
        const matches = if (operator.len == 0 or eq(operator, "=") or eq(operator, "==")) compared == .eq else if (eq(operator, ">")) compared == .gt else if (eq(operator, ">=")) compared != .lt else if (eq(operator, "<")) compared == .lt else if (eq(operator, "<=")) compared != .gt else if (eq(operator, "!=")) compared != .eq else return error.InvalidPackageVersion;
        if (!matches) result = false;
    }
    return result;
}

fn satisfiesAll(version: []const u8, constraints: []const []const u8) !bool {
    for (constraints) |constraint| if (!try satisfies(version, constraint)) return false;
    return true;
}

fn hasPrereleaseConstraint(constraints: []const []const u8) bool {
    for (constraints) |constraint| if (std.mem.indexOfScalar(u8, constraint, '-') != null) return true;
    return false;
}

fn hasCycle(allocator: std.mem.Allocator, requirements: []const Requirement, assigned: []const Resolved) bool {
    const states = allocator.alloc(u8, assigned.len) catch return true;
    @memset(states, 0);
    for (assigned, 0..) |_, index| if (visitCycle(index, states, requirements, assigned)) return true;
    return false;
}

fn visitCycle(index: usize, states: []u8, requirements: []const Requirement, assigned: []const Resolved) bool {
    if (states[index] == 1) return true;
    if (states[index] == 2) return false;
    states[index] = 1;
    for (requirements) |request| {
        const parent = request.parent orelse continue;
        if (!eq(parent, assigned[index].requirement.key)) continue;
        for (assigned, 0..) |package, child| if (eq(package.requirement.key, request.key) and visitCycle(child, states, requirements, assigned)) return true;
    }
    states[index] = 2;
    return false;
}

fn declarationHash(allocator: std.mem.Allocator, specs: []const Spec) ![]const u8 {
    var entries: std.ArrayList([]const u8) = .empty;
    for (specs) |spec| try entries.append(allocator, spec.hash_text orelse return error.InvalidPackageDeclaration);
    util.sortStrings(entries.items);
    const text = try std.mem.join(allocator, "\n", entries.items);
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(text, &digest, .{});
    return try allocator.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

// Core's fingerprint uses json.dumps(sort_keys=True), including ASCII escapes,
// Python's float spelling, and a space after each comma and colon.
fn writePythonJson(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: std.json.Value) anyerror!void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |v| try json.boolValue(writer, v),
        .integer => |v| try writer.print("{d}", .{v}),
        .number_string => |v| try writer.writeAll(v),
        .float => |v| try writer.writeAll(try pythonFloat(allocator, v)),
        .string => |v| try pythonString(writer, v),
        .array => |items| {
            try writer.writeByte('[');
            for (items.items, 0..) |item, i| {
                if (i != 0) try writer.writeAll(", ");
                try writePythonJson(allocator, writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |map| {
            const keys = try allocator.dupe([]const u8, map.keys());
            util.sortStrings(keys);
            try writer.writeByte('{');
            for (keys, 0..) |key, i| {
                if (i != 0) try writer.writeAll(", ");
                try pythonString(writer, key);
                try writer.writeAll(": ");
                try writePythonJson(allocator, writer, map.get(key).?);
            }
            try writer.writeByte('}');
        },
    }
}

fn pythonString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    var iterator = (try std.unicode.Utf8View.init(text)).iterator();
    while (iterator.nextCodepoint()) |codepoint| {
        switch (codepoint) {
            '"', '\\' => {
                try writer.writeByte('\\');
                try writer.writeByte(@intCast(codepoint));
            },
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            8 => try writer.writeAll("\\b"),
            12 => try writer.writeAll("\\f"),
            else => if (codepoint < 32 or codepoint >= 127) {
                if (codepoint <= 0xffff) try writer.print("\\u{x:0>4}", .{codepoint}) else {
                    const supplementary = codepoint - 0x10000;
                    try writer.print("\\u{x:0>4}\\u{x:0>4}", .{ 0xd800 + (supplementary >> 10), 0xdc00 + (supplementary & 0x3ff) });
                }
            } else try writer.writeByte(@intCast(codepoint)),
        }
    }
    try writer.writeByte('"');
}

fn pythonFloat(allocator: std.mem.Allocator, number: f64) ![]const u8 {
    if (std.math.isNan(number)) return "NaN";
    if (std.math.isInf(number)) return if (number < 0) "-Infinity" else "Infinity";
    const magnitude = @abs(number);
    if (magnitude != 0 and (magnitude >= 1e16 or magnitude < 1e-4)) {
        const scientific = try std.fmt.allocPrint(allocator, "{e}", .{number});
        const exponent_at = std.mem.indexOfScalar(u8, scientific, 'e').?;
        const exponent = try std.fmt.parseInt(i32, scientific[exponent_at + 1 ..], 10);
        return try std.fmt.allocPrint(allocator, "{s}e{s}{d:0>2}", .{ scientific[0..exponent_at], if (exponent < 0) "-" else "+", @abs(exponent) });
    }
    const decimal = try std.fmt.allocPrint(allocator, "{d}", .{number});
    if (std.mem.indexOfScalar(u8, decimal, '.') == null) return try std.fmt.allocPrint(allocator, "{s}.0", .{decimal});
    return decimal;
}

fn renderLock(allocator: std.mem.Allocator, root: []const u8, resolved: []const Resolved, hash: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    try out.writer.writeAll(if (resolved.len == 0) "packages: []\n" else "packages:\n");
    for (resolved) |package| {
        const spec = package.requirement.spec;
        const unrendered_source = spec.unrendered_source orelse spec.source;
        const source = if (spec.kind == .local and !std.mem.containsAtLeast(u8, unrendered_source, 1, "{{")) try std.fs.path.relative(allocator, root, null, root, package.directory) else unrendered_source;
        try out.writer.print("  - {s}: ", .{sourceKey(spec.kind)});
        try json.string(&out.writer, source);
        try out.writer.writeAll("\n    name: ");
        try json.string(&out.writer, package.name);
        if (package.version) |version| {
            try out.writer.print("\n    {s}: ", .{if (gitLike(spec.kind)) "revision" else "version"});
            try json.string(&out.writer, version);
        }
        if (spec.subdirectory) |subdirectory| {
            try out.writer.writeAll("\n    subdirectory: ");
            try json.string(&out.writer, subdirectory);
        }
        if (spec.provider) |provider| {
            try out.writer.writeAll("\n    provider: ");
            try json.string(&out.writer, provider);
        }
        try out.writer.writeAll("\n");
    }
    try out.writer.print("sha1_hash: {s}\n", .{hash});
    return try out.toOwnedSlice();
}

fn archiveStripCount(listing: []const u8) !u8 {
    try validateArchivePaths(listing);
    var prefix: ?[]const u8 = null;
    var root_project = false;
    var nested_project = false;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        var name = std.mem.trimEnd(u8, raw, "/\r");
        if (std.mem.startsWith(u8, name, "./")) name = name[2..];
        if (name.len == 0 or eq(name, ".")) continue;
        if (!safeRelativePath(name)) return error.UnsafePackageArchive;
        if (eq(name, "dbt_project.yml")) root_project = true;
        const slash = std.mem.indexOfScalar(u8, name, '/');
        if (slash) |index| {
            if (prefix == null) prefix = name[0..index];
            if (eq(name[index + 1 ..], "dbt_project.yml")) nested_project = true;
        }
    }
    if (root_project) return 0;
    if (!nested_project or prefix == null) return error.InvalidPackageArchive;
    lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        var name = std.mem.trimEnd(u8, raw, "/\r");
        if (std.mem.startsWith(u8, name, "./")) name = name[2..];
        if (name.len == 0 or eq(name, ".")) continue;
        if (!eq(name, prefix.?) and !containsPath(prefix.?, name)) return error.UnsafePackageArchive;
    }
    return 1;
}

fn validateArchivePaths(listing: []const u8) !void {
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |raw| {
        var name = std.mem.trimEnd(u8, raw, "/\r");
        if (std.mem.startsWith(u8, name, "./")) name = name[2..];
        if (name.len == 0 or eq(name, ".")) continue;
        if (!safeRelativePath(name)) return error.UnsafePackageArchive;
    }
}

fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| if (segment.len == 0 or eq(segment, ".") or eq(segment, "..")) return false;
    return true;
}

fn validProjectName(name: []const u8) bool {
    if (name.len == 0 or (!std.ascii.isAlphabetic(name[0]) and name[0] != '_')) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    return true;
}

fn validRegistryName(name: []const u8) bool {
    var pieces = std.mem.splitScalar(u8, name, '/');
    const namespace = pieces.next() orelse return false;
    const package = pieces.next() orelse return false;
    if (namespace.len == 0 or package.len == 0 or pieces.next() != null) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '/') return false;
    return true;
}

fn containsPath(parent: []const u8, child: []const u8) bool {
    return eq(parent, child) or (std.mem.startsWith(u8, child, parent) and child.len > parent.len and child[parent.len] == '/');
}

fn sourceKey(kind: Kind) []const u8 {
    return switch (kind) {
        .local => "local",
        .git => "git",
        .registry => "package",
        .tarball => "tarball",
        .private => "private",
    };
}

fn optionalRead(runtime: Runtime, path: []const u8) !?[]const u8 {
    return Dir.cwd().readFileAlloc(runtime.io, path, runtime.allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn writeAtomic(runtime: Runtime, path: []const u8, data: []const u8) !void {
    const temporary = try std.fmt.allocPrint(runtime.allocator, "{s}.dxt-tmp", .{path});
    defer Dir.cwd().deleteFile(runtime.io, temporary) catch {};
    try Dir.cwd().writeFile(runtime.io, .{ .sub_path = temporary, .data = data });
    try Dir.rename(Dir.cwd(), temporary, Dir.cwd(), path, runtime.io);
}

fn exists(runtime: Runtime, path: []const u8) bool {
    _ = Dir.cwd().statFile(runtime.io, path, .{}) catch return false;
    return true;
}

fn removeTree(runtime: Runtime, path: []const u8) !void {
    try Dir.cwd().deleteTree(runtime.io, path);
}

fn join(runtime: Runtime, paths: []const []const u8) ![]const u8 {
    return std.fs.path.join(runtime.allocator, paths);
}

fn rootedPath(runtime: Runtime, base: []const u8, path: []const u8) ![]const u8 {
    return if (std.fs.path.isAbsolute(path)) path else try join(runtime, &.{ base, path });
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "package semantic version ranges and prerelease ordering" {
    try std.testing.expect(try satisfies("1.2.3", ">=1.0.0, <2.0.0"));
    try std.testing.expect(!try satisfies("2.0.0", ">=1.0.0, <2.0.0"));
    try std.testing.expect(try satisfies("1.2.0", "1.2"));
    try std.testing.expectEqual(std.math.Order.lt, SemVersion.order(try SemVersion.parse("1.0.0-rc.2"), try SemVersion.parse("1.0.0-rc.10")));
    try std.testing.expectEqual(std.math.Order.lt, SemVersion.order(try SemVersion.parse("1.0.0-rc.10"), try SemVersion.parse("1.0.0")));
    try std.testing.expectError(error.InvalidPackageVersion, satisfies("1.0.0", "^1.0.0"));
}

test "package declarations parse all transport kinds and multiline version ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const runtime: Runtime = .{ .allocator = arena.allocator(), .io = std.testing.io };
    const declaration = try parseDeclaration(runtime,
        \\packages:
        \\  - local: '../common'
        \\  - git: https://example.org/package.git
        \\    revision: 'v1.0.0'
        \\    subdirectory: dbt
        \\  - package: example/utils
        \\    version:
        \\      - '>=1.0.0'
        \\      - '<2.0.0'
    );
    try std.testing.expectEqual(@as(usize, 3), declaration.specs.items.len);
    try std.testing.expectEqualStrings("../common", declaration.specs.items[0].source);
    try std.testing.expectEqualStrings("v1.0.0", declaration.specs.items[1].revision.?);
    try std.testing.expectEqual(@as(usize, 2), declaration.specs.items[2].constraints.items.len);
    try std.testing.expectError(error.InvalidPackageDeclaration, parseDeclaration(runtime, "packages:\n  - package: example/utils\n"));
    try std.testing.expectError(error.UnsupportedProjectDependency, parseDeclaration(runtime, "projects:\n  - name: private_project\n"));
}

test "package archives reject traversal and mixed archive roots" {
    try std.testing.expectEqual(@as(u8, 0), try archiveStripCount("dbt_project.yml\nmodels/m.sql\n"));
    try std.testing.expectEqual(@as(u8, 1), try archiveStripCount("pkg/\npkg/dbt_project.yml\npkg/models/m.sql\n"));
    try std.testing.expectError(error.UnsafePackageArchive, archiveStripCount("pkg/dbt_project.yml\n../outside.sql\n"));
    try std.testing.expectError(error.UnsafePackageArchive, archiveStripCount("pkg/dbt_project.yml\nother/m.sql\n"));
    try std.testing.expect(!safeRelativePath("../dbt_packages"));
    try std.testing.expect(!safeRelativePath("/dbt_packages"));
}

test "package declaration hashes match pinned Core for local Git and registry entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const runtime: Runtime = .{ .allocator = arena.allocator(), .io = std.testing.io };
    const cases = [_]struct { text: []const u8, hash: []const u8 }{
        .{ .text = "packages:\n  - local: ../utils\n", .hash = "7007d90499dded017f2eb54969e75d7703b23edf" },
        .{ .text = "packages:\n  - git: https://example.org/package.git\n    revision: v1.0.0\n    subdirectory: dbt\n    warn-unpinned: false\n", .hash = "55f6b195850174ace6db08ec89e731de28f81d7f" },
        .{ .text = "packages:\n  - package: example/utils\n    version: ['>=1.0.0', '<2.0.0']\n", .hash = "4a4890db5b4338c0c4adcb58eeae5ad86986b1ec" },
        .{ .text = "packages:\n  - version: 1.0.0\n    name: utils\n    package: example/utils\n", .hash = "ee69ee051ac4ffe4fe32b36fd22c565a2f7c5397" },
    };
    for (cases) |case| {
        const declaration = try parseDeclaration(runtime, case.text);
        try std.testing.expectEqualStrings(case.hash, try declarationHash(runtime.allocator, declaration.specs.items));
    }
}

test "package graph cycle detection includes reused transitive dependencies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a: Requirement = .{ .key = "local:a", .base = ".", .spec = .{ .kind = .local, .source = "a" } };
    const b: Requirement = .{ .key = "local:b", .base = ".", .spec = .{ .kind = .local, .source = "b" }, .parent = a.key };
    var repeated = a;
    repeated.parent = b.key;
    const assigned = [_]Resolved{
        .{ .name = "a", .requirement = a, .version = null, .directory = "a" },
        .{ .name = "b", .requirement = b, .version = null, .directory = "b" },
    };
    try std.testing.expect(!hasCycle(arena.allocator(), &.{ a, b }, &assigned));
    try std.testing.expect(hasCycle(arena.allocator(), &.{ a, b, repeated }, &assigned));
}
