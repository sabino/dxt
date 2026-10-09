const std = @import("std");
const Io = std.Io;
const config_value = @import("config_value.zig");

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: Io,
    environment: ?*const std.process.Environ.Map = null,
    invocation: ?*const @import("invocation.zig").Metadata = null,
    duckdb_pool: ?*@import("native_duckdb.zig").Pool = null,
    adapter_session: ?*@import("adapter.zig").Session = null,
    cancellation_token: ?*const std.atomic.Value(bool) = null,
    session_observer: ?SessionObserver = null,
    invocation_options: ?*const Options = null,
    global_options: ?*const Options = null,
};

pub const SessionObserver = struct {
    context: *anyopaque,
    changed: *const fn (*anyopaque, ?*@import("adapter.zig").Session) void,
};

pub const Options = struct {
    which: []const u8 = "",
    command_name: ?[]const u8 = null,
    command_args: ?[]const u8 = null,
    skip_profile_setup: bool = false,
    execution_select: ?[]const u8 = null,
    execution_ids: ?[]const []const u8 = null,
    microbatch_retry_results: ?std.json.Value = null,
    project_dir: []const u8 = ".",
    profiles_dir: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    target: ?[]const u8 = null,
    target_path: ?[]const u8 = null,
    vars: ?[]const u8 = null,
    state: ?[]const u8 = null,
    defer_state: ?[]const u8 = null,
    defer_enabled: bool = false,
    favor_state: bool = false,
    indirect_selection: []const u8 = "eager",
    threads: ?[]const u8 = null,
    fail_fast: bool = false,
    populate_cache: bool = true,
    cache_selected_only: bool = false,
    log_cache_events: bool = false,
    log_format: enum { text, json, debug } = .text,
    quiet: bool = false,
    debug: bool = false,
    write_json: bool = true,
    warn_error: bool = false,
    version_check: bool = true,
    warn_error_options: ?[]const u8 = null,
    log_level: LogLevel = .info,
    log_level_file: LogLevel = .debug,
    log_format_file: enum { text, json, debug } = .debug,
    log_path: ?[]const u8 = null,
    log_file_max_bytes: u64 = 10485760,
    use_colors: bool = true,
    use_colors_file: bool = true,
    print_enabled: bool = true,
    full_refresh: bool = false,
    empty: bool = false,
    sample: ?[]const u8 = null,
    sample_window: ?SampleWindow = null,
    event_time_start: ?[]const u8 = null,
    event_time_end: ?[]const u8 = null,
    store_failures: bool = false,
    seed_show: bool = false,
    docs_host: []const u8 = "127.0.0.1",
    docs_port: u16 = 8080,
    docs_open_browser: bool = false,
    docs_static: bool = false,
    docs_compile: bool = true,
    docs_empty_catalog: bool = false,
    select: ?[]const u8 = null,
    selector: ?[]const u8 = null,
    exclude: ?[]const u8 = null,
    resource_type: ?[]const u8 = null,
    resource_types: ?[]const []const u8 = null,
    exclude_resource_types: ?[]const []const u8 = null,
    output: Output = .text,
    output_keys: ?[]const []const u8 = null,
};

pub const SampleWindow = struct { start: i96, end: i96 };

pub const LogLevel = enum { debug, info, warn, @"error", none };

pub const Output = enum {
    text,
    json,
    name,
    path,
    selector,
};

pub const VarEntry = struct {
    name: []const u8,
    value: []const u8,
    typed_value: ?std.json.Value = null,
    package_name: ?[]const u8 = null,
    priority: u8 = 0,
};

pub const ProjectConfig = struct {
    name: []const u8,
    profile_name: ?[]const u8 = null,
    model_paths: std.ArrayList([]const u8) = .empty,
    seed_paths: std.ArrayList([]const u8) = .empty,
    macro_paths: std.ArrayList([]const u8) = .empty,
    test_paths: std.ArrayList([]const u8) = .empty,
    analysis_paths: std.ArrayList([]const u8) = .empty,
    snapshot_paths: std.ArrayList([]const u8) = .empty,
    function_paths: std.ArrayList([]const u8) = .empty,
    model_path_configs: std.ArrayList(ModelPathConfig) = .empty,
    source_project_configs: std.ArrayList(SourceProjectConfig) = .empty,
    dispatch_configs: std.ArrayList(DispatchConfig) = .empty,
    vars: std.ArrayList(VarEntry) = .empty,
    clean_targets: std.ArrayList([]const u8) = .empty,
    seed_docs: DocsConfig = .{},
    macro_paths_set: bool = false,
    test_paths_set: bool = false,
    snapshot_paths_set: bool = false,
    snapshot_config_text: ?[]const u8 = null,
    clean_targets_set: bool = false,
    validate_macro_args: bool = false,
    require_generic_test_arguments_property: bool = false,
    require_batched_execution_for_custom_microbatch_strategy: bool = false,
    target_path: []const u8 = "target",
    raw_project: std.json.Value = .null,
    rendered_project: std.json.Value = .null,
};

pub const DispatchConfig = struct {
    macro_namespace: []const u8,
    search_order: std.ArrayList([]const u8) = .empty,
};

pub const ModelPathConfig = struct {
    package_name: []const u8,
    path: []const u8,
    materialized: []const u8 = "",
    incremental: IncrementalConfig = .{},
    tags: std.ArrayList([]const u8) = .empty,
    docs: DocsConfig = .{},
    resource_type: []const u8 = "model",
    values: std.json.Value = .null,
    raw_values: std.json.Value = .null,
};

pub const SourceProjectConfig = struct {
    values: std.json.Value = .null,
    package_name: []const u8,
    source_name: ?[]const u8 = null,
    table_name: ?[]const u8 = null,
    database: ?[]const u8 = null,
    schema_name: ?[]const u8 = null,
    identifier: ?[]const u8 = null,
    quoting: SourceQuoting = .{},
    loaded_at_field: ?[]const u8 = null,
    loaded_at_query: ?[]const u8 = null,
    loaded_at_field_set: bool = false,
    loaded_at_query_set: bool = false,
    freshness: ?FreshnessThreshold = null,
    freshness_set: bool = false,
};

pub const DocsConfig = struct {
    configured: bool = false,
    show: bool = true,
    node_color: ?[]const u8 = null,
};

pub const SourceDef = struct {
    enabled: bool = true,
    description: []const u8 = "",
    source_description: []const u8 = "",
    loader: []const u8 = "",
    properties: std.json.Value = .null,
    source_properties: std.json.Value = .null,
    raw_config: std.json.Value = .null,
    effective_config: std.json.Value = .null,
    package_name: []const u8,
    unique_id: []const u8,
    source_name: []const u8,
    table_name: []const u8,
    identifier: ?[]const u8 = null,
    database: ?[]const u8 = null,
    original_file_path: []const u8,
    schema_name: ?[]const u8 = null,
    quoting: SourceQuoting = .{},
    loaded_at_field: ?[]const u8 = null,
    loaded_at_query: ?[]const u8 = null,
    freshness: ?FreshnessThreshold = null,
    freshness_set: bool = false,
    tests: std.ArrayList(GenericTestDef) = .empty,
    columns: std.ArrayList(ColumnDef) = .empty,
};

pub const SourceQuoting = struct {
    column: ?bool = null,
    database: ?bool = null,
    schema: ?bool = null,
    identifier: ?bool = null,
};

pub const FreshnessThreshold = struct {
    warn_after: ?FreshnessTime = null,
    error_after: ?FreshnessTime = null,
    filter: ?[]const u8 = null,
};

pub const FreshnessTime = struct {
    count: ?u64 = null,
    period: ?[]const u8 = null,
};

pub const ExposureDef = struct {
    package_name: []const u8,
    unique_id: []const u8,
    name: []const u8,
    exposure_type: []const u8 = "",
    enabled: bool = true,
    maturity: ?[]const u8 = null,
    url: ?[]const u8 = null,
    description: []const u8 = "",
    owner_name: []const u8 = "",
    owner_email: ?[]const u8 = null,
    path: []const u8,
    original_file_path: []const u8,
    tags: std.ArrayList([]const u8) = .empty,
    meta: std.ArrayList(MetaEntry) = .empty,
    refs: std.ArrayList(RefDep) = .empty,
    source_refs: std.ArrayList(SourceDep) = .empty,
    depends_on: std.ArrayList([]const u8) = .empty,
};

pub const UnitTestRow = struct {
    entries: std.ArrayList(MetaEntry) = .empty,
};

pub const UnitTestFixture = struct {
    input: ?[]const u8 = null,
    rows_set: bool = false,
    rows_string: ?[]const u8 = null,
    rows: std.ArrayList(UnitTestRow) = .empty,
    format: []const u8 = "dict",
    fixture: ?[]const u8 = null,
};

pub const UnitTestDef = struct {
    overrides: std.json.Value = .null,
    versions: std.json.Value = .null,
    version: std.json.Value = .null,
    config_values: std.json.Value = .null,
    package_name: []const u8,
    unique_id: []const u8 = "",
    name: []const u8,
    model: []const u8 = "",
    path: []const u8,
    original_file_path: []const u8,
    description: []const u8 = "",
    enabled: bool = true,
    given: std.ArrayList(UnitTestFixture) = .empty,
    expect: UnitTestFixture = .{},
    tags: std.ArrayList([]const u8) = .empty,
    meta: std.ArrayList(MetaEntry) = .empty,
    depends_on: std.ArrayList([]const u8) = .empty,
};

pub const MetaEntry = struct {
    key: []const u8,
    value: JsonScalar,
};

pub const JsonScalar = struct {
    text: []const u8,
    kind: enum {
        string,
        number,
        bool,
        null,
        json,
    } = .string,
};

pub const RefDep = struct {
    version: std.json.Value = .null,
    package: ?[]const u8,
    name: []const u8,
};

pub const SourceDep = struct {
    source_name: []const u8,
    table_name: []const u8,
};

pub const ColumnDef = struct {
    name: []const u8,
    data_type: ?[]const u8 = null,
    quote: ?bool = null,
    meta_json: ?std.json.Value = null,
    config_json: ?std.json.Value = null,
    tags: std.ArrayList([]const u8) = .empty,
    description: []const u8 = "",
    doc_blocks: std.ArrayList([]const u8) = .empty,
    tests: std.ArrayList(GenericTestDef) = .empty,
    properties: std.json.Value = .null,
};

pub const GenericTestDef = struct {
    name: []const u8,
    arguments: std.json.Value = .null,
    namespace: ?[]const u8 = null,
    column_name: ?[]const u8 = null,
    accepted_values: std.ArrayList([]const u8) = .empty,
    accepted_values_quote: ?bool = null,
    relationship_to: []const u8 = "",
    relationship_field: []const u8 = "",
    config: GenericTestConfig = .{},
};

pub const GenericTestConfig = struct {
    configured: std.enums.EnumSet(GenericTestConfigField) = .initEmpty(),
    configured_order: [std.meta.fields(GenericTestConfigField).len]GenericTestConfigField = undefined,
    configured_order_len: usize = 0,
    where: ?[]const u8 = null,
    limit: ?u64 = null,
    severity: []const u8 = "ERROR",
    warn_if: []const u8 = "!= 0",
    error_if: []const u8 = "!= 0",
    store_failures: ?bool = null,
    store_failures_as: ?[]const u8 = null,
    schema: ?[]const u8 = null,
    alias: ?[]const u8 = null,
    database: ?[]const u8 = null,
    fail_calc: []const u8 = "count(*)",

    pub fn markConfigured(self: *GenericTestConfig, key: GenericTestConfigField) void {
        if (!self.configured.contains(key)) {
            self.configured_order[self.configured_order_len] = key;
            self.configured_order_len += 1;
            self.configured.insert(key);
        }
    }
};

pub const GenericTestConfigField = enum { where, limit, severity, warn_if, error_if, store_failures, store_failures_as, schema, alias, database, fail_calc };

pub const DocBlock = struct {
    package_name: []const u8,
    unique_id: []const u8,
    name: []const u8,
    path: []const u8,
    original_file_path: []const u8,
    block_contents: []const u8,
};

pub const MacroDef = struct {
    unique_id: []const u8,
    package_name: []const u8,
    name: []const u8,
    path: []const u8,
    original_file_path: []const u8,
    macro_sql: []const u8,
    patch_path: ?[]const u8 = null,
    description: []const u8 = "",
    meta: std.ArrayList(MetaEntry) = .empty,
    docs: DocsConfig = .{},
    arguments: std.ArrayList(MacroArgument) = .empty,
    signature_arguments: std.ArrayList(MacroArgument) = .empty,
    macro_depends_on: std.ArrayList([]const u8) = .empty,
    supported_languages: std.ArrayList([]const u8) = .empty,
    has_supported_languages: bool = false,
};

pub const MacroArgument = struct {
    name: []const u8,
    type: []const u8 = "",
    description: []const u8 = "",
};

pub const ModelProperty = struct {
    logical_name: ?[]const u8 = null,
    version: std.json.Value = .null,
    latest_version: std.json.Value = .null,
    assigned_unique_id: ?[]const u8 = null,
    package_name: []const u8,
    resource_type: []const u8 = "model",
    name: []const u8,
    patch_path: []const u8,
    description: []const u8 = "",
    materialized: []const u8 = "",
    incremental: IncrementalConfig = .{},
    tags: std.ArrayList([]const u8) = .empty,
    doc_blocks: std.ArrayList([]const u8) = .empty,
    tests: std.ArrayList(GenericTestDef) = .empty,
    columns: std.ArrayList(ColumnDef) = .empty,
    enabled: ?bool = null,
    quote_columns: ?bool = null,
    seed_column_types: std.ArrayList(SeedColumnType) = .empty,
    config_values: std.json.Value = .null,
    properties: std.json.Value = .null,
    persist_docs: ?PersistDocs = null,
};

pub const SeedColumnType = struct {
    name: []const u8,
    data_type: []const u8,
};

pub const UnmatchedModelProperty = struct {
    resource_type: []const u8 = "model",
    name: []const u8,
    patch_path: []const u8,
};

pub const SingularTestProperty = struct {
    package_name: []const u8,
    name: []const u8,
    patch_path: []const u8,
    description: []const u8 = "",
    enabled: ?bool = null,
    tags: std.ArrayList([]const u8) = .empty,
    config: GenericTestConfig = .{},
};

pub const MacroProperty = struct {
    package_name: []const u8,
    name: []const u8,
    patch_path: []const u8,
    description: []const u8 = "",
    meta: std.ArrayList(MetaEntry) = .empty,
    docs: DocsConfig = .{},
    arguments: std.ArrayList(MacroArgument) = .empty,
};

pub const UnmatchedMacroProperty = struct {
    name: []const u8,
    patch_path: []const u8,
};

pub const ExtraCte = struct {
    id: []const u8,
    sql: []const u8,
};

pub const Node = struct {
    runtime_batch: ?SampleWindow = null,
    runtime_batch_id: ?[]const u8 = null,
    default_alias: ?[]const u8 = null,
    version: std.json.Value = .null,
    latest_version: std.json.Value = .null,
    resource_type: []const u8 = "model",
    package_name: []const u8,
    unique_id: []const u8,
    name: []const u8,
    project_root: ?[]const u8 = null,
    path: []const u8,
    original_file_path: []const u8,
    patch_path: ?[]const u8 = null,
    raw_code: []const u8,
    // SQL snapshot blocks retain the source file for dbt's file-level checksum.
    snapshot_file_code: ?[]const u8 = null,
    snapshot_fqn_path: ?[]const u8 = null,
    snapshot_yaml_definition: bool = false,
    snapshot_inline_schema: bool = false,
    snapshot_inline_alias: bool = false,
    snapshot_inline_docs: bool = false,
    snapshot_inline_meta: bool = false,
    snapshot_config: ?SnapshotConfig = null,
    description: []const u8 = "",
    materialized: []const u8 = "view",
    inline_materialized: bool = false,
    inline_enabled: bool = false,
    inline_tags: bool = false,
    incremental: IncrementalConfig = .{},
    inline_incremental: IncrementalConfigMask = .{},
    config_schema: ?[]const u8 = null,
    config_alias: ?[]const u8 = null,
    persist_docs: ?PersistDocs = null,
    quote_columns: ?bool = null,
    seed_column_types: std.ArrayList(SeedColumnType) = .empty,
    test_config: GenericTestConfig = .{},
    inline_store_failures: bool = false,
    enabled: bool = true,
    docs: DocsConfig = .{},
    tags: std.ArrayList([]const u8) = .empty,
    meta: std.ArrayList(MetaEntry) = .empty,
    snapshot_meta_json: ?std.json.Value = null,
    doc_blocks: std.ArrayList([]const u8) = .empty,
    tests: std.ArrayList(GenericTestDef) = .empty,
    columns: std.ArrayList(ColumnDef) = .empty,
    refs: std.ArrayList(RefDep) = .empty,
    source_refs: std.ArrayList(SourceDep) = .empty,
    depends_on: std.ArrayList([]const u8) = .empty,
    macro_depends_on: std.ArrayList([]const u8) = .empty,
    runtime_is_incremental: bool = false,
    compiled: bool = false,
    compiled_code: ?[]const u8 = null,
    compiled_path: ?[]const u8 = null,
    relation_name: ?[]const u8 = null,
    extra_ctes: std.ArrayList(ExtraCte) = .empty,
    raw_config: std.json.Value = .null,
    effective_config: std.json.Value = .null,
    inline_config: std.json.Value = .null,
    project_config: std.json.Value = .null,
    property_config: std.json.Value = .null,
    root_override_config: std.json.Value = .null,
    project_raw_config: std.json.Value = .null,
    property_raw_config: std.json.Value = .null,
    root_override_raw_config: std.json.Value = .null,
    properties: std.json.Value = .null,
};

pub const IncrementalConfigMask = struct {
    unique_key: bool = false,
    strategy: bool = false,
    on_schema_change: bool = false,
    full_refresh: bool = false,
    predicates: bool = false,
};

pub const IncrementalConfig = struct {
    unique_key: ?SnapshotColumns = null,
    strategy: ?[]const u8 = null,
    on_schema_change: ?[]const u8 = null,
    full_refresh: ?bool = null,
    predicates: std.ArrayList([]const u8) = .empty,
    predicates_null: bool = false,
    configured: IncrementalConfigMask = .{},

    pub fn deinit(self: *IncrementalConfig, allocator: std.mem.Allocator) void {
        if (self.unique_key) |*key| key.deinit(allocator);
        self.predicates.deinit(allocator);
    }
};

pub const PersistDocs = struct {
    relation: ?bool = null,
    columns: ?bool = null,
};

pub const SnapshotColumns = union(enum) {
    string: []const u8,
    list: std.ArrayList([]const u8),

    pub fn deinit(self: *SnapshotColumns, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => {},
            .list => |*items| items.deinit(allocator),
        }
    }
};

pub const SnapshotMetaColumns = struct {
    dbt_scd_id: []const u8 = "dbt_scd_id",
    dbt_updated_at: []const u8 = "dbt_updated_at",
    dbt_valid_from: []const u8 = "dbt_valid_from",
    dbt_valid_to: []const u8 = "dbt_valid_to",
    dbt_is_deleted: []const u8 = "dbt_is_deleted",
};

pub const SnapshotConfig = struct {
    configured_fields: u16 = 0,
    strategy: ?[]const u8 = null,
    unique_key: ?SnapshotColumns = null,
    target_schema: ?[]const u8 = null,
    target_database: ?[]const u8 = null,
    updated_at: ?[]const u8 = null,
    check_cols: ?SnapshotColumns = null,
    invalidate_hard_deletes: ?bool = null,
    hard_deletes: ?[]const u8 = null,
    dbt_valid_to_current: ?[]const u8 = null,
    meta_columns: SnapshotMetaColumns = .{},
    meta_columns_configured: bool = false,
    meta_columns_fields: u5 = 0,
};

pub const GenericTestNode = struct {
    package_name: []const u8,
    unique_id: []const u8,
    name: []const u8,
    alias: []const u8,
    path: []const u8,
    original_file_path: []const u8,
    raw_code: []const u8,
    test_name: []const u8,
    arguments: std.json.Value = .null,
    test_namespace: ?[]const u8 = null,
    column_name: ?[]const u8 = null,
    argument_column_name: ?[]const u8 = null,
    accepted_values: std.ArrayList([]const u8) = .empty,
    accepted_values_quote: ?bool = null,
    relationship_to: []const u8 = "",
    relationship_field: []const u8 = "",
    attached_node: ?[]const u8 = null,
    attached_source: ?SourceDep = null,
    attached_source_unique_id: ?[]const u8 = null,
    relationship_source_to: ?SourceDep = null,
    relationship_source_to_unique_id: ?[]const u8 = null,
    config: GenericTestConfig = .{},
    refs: std.ArrayList(RefDep) = .empty,
    source_refs: std.ArrayList(SourceDep) = .empty,
    depends_on: std.ArrayList([]const u8) = .empty,
    macro_depends_on: std.ArrayList([]const u8) = .empty,
    compiled: bool = false,
    compiled_code: ?[]const u8 = null,
    compiled_path: ?[]const u8 = null,
};

pub const SingularTestNode = struct {
    config_values: std.json.Value = .null,
    package_name: []const u8,
    unique_id: []const u8,
    name: []const u8,
    alias: []const u8,
    path: []const u8,
    original_file_path: []const u8,
    patch_path: ?[]const u8 = null,
    raw_code: []const u8,
    description: []const u8 = "",
    doc_blocks: std.ArrayList([]const u8) = .empty,
    tags: std.ArrayList([]const u8) = .empty,
    config: GenericTestConfig = .{},
    enabled: bool = true,
    inline_enabled: bool = false,
    inline_store_failures: bool = false,
    compiled: bool = false,
    compiled_code: ?[]const u8 = null,
    compiled_path: ?[]const u8 = null,
    refs: std.ArrayList(RefDep) = .empty,
    source_refs: std.ArrayList(SourceDep) = .empty,
    depends_on: std.ArrayList([]const u8) = .empty,
    macro_depends_on: std.ArrayList([]const u8) = .empty,
};

pub const SnapshotPatch = struct {
    package_name: []const u8,
    name: []const u8,
    path: []const u8,
    config_args: []const u8,
    properties: std.json.Value,
};
pub const SnapshotProjectConfig = struct { package_name: []const u8, text: []const u8 };

pub const SemanticResource = struct {
    data: std.json.Value,
    name: []const u8,
    unique_id: []const u8,
    resource_type: []const u8,
    package_name: []const u8,
    path: []const u8,
    original_file_path: []const u8,
    enabled: bool = true,
    tags: std.ArrayList([]const u8) = .empty,
    depends_on: std.ArrayList([]const u8) = .empty,
};

pub const SemanticProjectConfig = struct {
    package_name: []const u8,
    raw: std.json.Value,
    rendered: std.json.Value,
};

pub const SemanticTimeSpine = struct {
    package_name: []const u8,
    raw: std.json.Value,
};

pub const Graph = struct {
    unit_fixture_relations: bool = false,
    unit_overrides: std.json.Value = .null,
    unit_fixture_aliases: []const DeferredRelation = &.{},
    log_collector: ?*std.ArrayList(@import("run_results.zig").LogMessage) = null,
    invocation: ?*const @import("invocation.zig").Metadata = null,
    command_options: Options = .{},
    allocator: std.mem.Allocator,
    environment: ?*const std.process.Environ.Map = null,
    execution_hooks: ?@import("expression.zig").Host = null,
    project_name: []const u8,
    adapter_type: []const u8 = "duckdb",
    target_schema: []const u8 = "main",
    full_refresh: bool = false,
    database_path: ?[]const u8 = null,
    database_path_base: ?[]const u8 = null,
    connection_info: ?[]const u8 = null,
    target_context: std.json.Value = .null,
    target_threads: u16 = 1,
    profile_name: ?[]const u8 = null,
    target_name: ?[]const u8 = null,
    vars: std.ArrayList(VarEntry) = .empty,
    groups: std.ArrayList(std.json.Value) = .empty,
    semantic_resources: std.ArrayList(SemanticResource) = .empty,
    semantic_time_spines: std.ArrayList(SemanticTimeSpine) = .empty,
    semantic_project_configs: std.ArrayList(SemanticProjectConfig) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    tests: std.ArrayList(GenericTestNode) = .empty,
    singular_tests: std.ArrayList(SingularTestNode) = .empty,
    sources: std.ArrayList(SourceDef) = .empty,
    exposures: std.ArrayList(ExposureDef) = .empty,
    unit_tests: std.ArrayList(UnitTestDef) = .empty,
    docs: std.ArrayList(DocBlock) = .empty,
    macros: std.ArrayList(MacroDef) = .empty,
    model_properties: std.ArrayList(ModelProperty) = .empty,
    snapshot_properties: std.ArrayList(SnapshotPatch) = .empty,
    snapshot_project_configs: std.ArrayList(SnapshotProjectConfig) = .empty,
    singular_test_properties: std.ArrayList(SingularTestProperty) = .empty,
    macro_properties: std.ArrayList(MacroProperty) = .empty,
    unmatched_model_properties: std.ArrayList(UnmatchedModelProperty) = .empty,
    unmatched_macro_properties: std.ArrayList(UnmatchedMacroProperty) = .empty,
    macro_argument_warnings: std.ArrayList([]const u8) = .empty,
    dispatch_configs: std.ArrayList(DispatchConfig) = .empty,
    source_project_configs: std.ArrayList(SourceProjectConfig) = .empty,
    validate_macro_args: bool = false,
    require_generic_test_arguments_property: bool = false,
    require_batched_execution_for_custom_microbatch_strategy: bool = false,
    deferred_relations: std.ArrayList(DeferredRelation) = .empty,

    pub fn unitFixtureRelation(self: *const Graph, unique_id: []const u8) ?[]const u8 {
        for (self.unit_fixture_aliases) |relation| if (std.mem.eql(u8, relation.unique_id, unique_id)) return relation.relation_name;
        return null;
    }

    pub fn deferredRelation(self: *const Graph, unique_id: []const u8) ?[]const u8 {
        for (self.deferred_relations.items) |relation| {
            if (std.mem.eql(u8, relation.unique_id, unique_id)) return relation.relation_name;
        }
        return null;
    }

    pub fn deinit(self: *Graph) void {
        for (self.groups.items) |*definition| config_value.deinit(self.allocator, definition);
        self.groups.deinit(self.allocator);
        for (self.semantic_resources.items) |*resource| {
            config_value.deinit(self.allocator, &resource.data);
            resource.tags.deinit(self.allocator);
            resource.depends_on.deinit(self.allocator);
        }
        self.semantic_resources.deinit(self.allocator);
        for (self.semantic_time_spines.items) |*spine| {
            self.allocator.free(spine.package_name);
            config_value.deinit(self.allocator, &spine.raw);
        }
        self.semantic_time_spines.deinit(self.allocator);
        for (self.semantic_project_configs.items) |*config| {
            self.allocator.free(config.package_name);
            config_value.deinit(self.allocator, &config.raw);
            config_value.deinit(self.allocator, &config.rendered);
        }
        self.semantic_project_configs.deinit(self.allocator);
        config_value.deinit(self.allocator, &self.target_context);
        for (self.nodes.items) |*node| {
            deinitNode(self.allocator, node);
        }
        for (self.tests.items) |*test_node| {
            deinitGenericTestNode(self.allocator, test_node);
        }
        for (self.singular_tests.items) |*test_node| {
            deinitSingularTestNode(self.allocator, test_node);
        }
        for (self.sources.items) |*source| {
            deinitSourceDef(self.allocator, source);
        }
        for (self.exposures.items) |*exposure| {
            deinitExposureDef(self.allocator, exposure);
        }
        for (self.unit_tests.items) |*unit_test| {
            deinitUnitTestDef(self.allocator, unit_test);
        }
        for (self.model_properties.items) |*property| {
            deinitModelProperty(self.allocator, property);
        }
        for (self.singular_test_properties.items) |*property| {
            deinitSingularTestProperty(self.allocator, property);
        }
        for (self.macro_properties.items) |*property| {
            deinitMacroProperty(self.allocator, property);
        }
        for (self.macros.items) |*macro| {
            deinitMacro(self.allocator, macro);
        }
        self.nodes.deinit(self.allocator);
        self.tests.deinit(self.allocator);
        self.singular_tests.deinit(self.allocator);
        self.sources.deinit(self.allocator);
        self.exposures.deinit(self.allocator);
        self.unit_tests.deinit(self.allocator);
        self.docs.deinit(self.allocator);
        self.macros.deinit(self.allocator);
        self.model_properties.deinit(self.allocator);
        self.snapshot_properties.deinit(self.allocator);
        self.snapshot_project_configs.deinit(self.allocator);
        self.singular_test_properties.deinit(self.allocator);
        self.macro_properties.deinit(self.allocator);
        self.unmatched_model_properties.deinit(self.allocator);
        self.unmatched_macro_properties.deinit(self.allocator);
        self.macro_argument_warnings.deinit(self.allocator);
        deinitDispatchConfigs(self.allocator, &self.dispatch_configs);
        for (self.source_project_configs.items) |*source_config| config_value.deinit(self.allocator, &source_config.values);
        self.source_project_configs.deinit(self.allocator);
        deinitVars(self.allocator, &self.vars);
        for (self.deferred_relations.items) |relation| {
            self.allocator.free(relation.unique_id);
            self.allocator.free(relation.relation_name);
        }
        self.deferred_relations.deinit(self.allocator);
    }
};

pub const DeferredRelation = struct {
    unique_id: []const u8,
    relation_name: []const u8,
};

pub const AdapterIdentity = struct {
    profile_name: []const u8,
    target_name: []const u8,
    adapter_type: []const u8,
    target_schema: []const u8,
    database_path: ?[]const u8 = null,
    database_path_base: ?[]const u8 = null,
    connection_info: ?[]const u8 = null,
    target_context: std.json.Value = .null,
    threads: u16 = 1,
};

pub fn deinitProjectConfig(allocator: std.mem.Allocator, config: *ProjectConfig) void {
    config_value.deinit(allocator, &config.raw_project);
    config_value.deinit(allocator, &config.rendered_project);
    for (config.model_path_configs.items) |*path_config| {
        path_config.tags.deinit(allocator);
        path_config.incremental.deinit(allocator);
        config_value.deinit(allocator, &path_config.values);
        config_value.deinit(allocator, &path_config.raw_values);
    }
    config.model_paths.deinit(allocator);
    config.seed_paths.deinit(allocator);
    config.macro_paths.deinit(allocator);
    config.test_paths.deinit(allocator);
    config.analysis_paths.deinit(allocator);
    config.snapshot_paths.deinit(allocator);
    config.function_paths.deinit(allocator);
    config.model_path_configs.deinit(allocator);
    for (config.source_project_configs.items) |*source_config| config_value.deinit(allocator, &source_config.values);
    config.source_project_configs.deinit(allocator);
    deinitDispatchConfigs(allocator, &config.dispatch_configs);
    deinitVars(allocator, &config.vars);
    config.clean_targets.deinit(allocator);
}

pub fn deinitVars(allocator: std.mem.Allocator, vars: *std.ArrayList(VarEntry)) void {
    for (vars.items) |*entry| if (entry.typed_value) |*value| config_value.deinit(allocator, value);
    vars.deinit(allocator);
}

pub fn deinitDispatchConfigs(allocator: std.mem.Allocator, configs: *std.ArrayList(DispatchConfig)) void {
    for (configs.items) |*config| {
        config.search_order.deinit(allocator);
    }
    configs.deinit(allocator);
}

pub fn deinitNode(allocator: std.mem.Allocator, node: *Node) void {
    config_value.deinit(allocator, &node.version);
    config_value.deinit(allocator, &node.latest_version);
    config_value.deinit(allocator, &node.properties);
    config_value.deinit(allocator, &node.raw_config);
    config_value.deinit(allocator, &node.effective_config);
    config_value.deinit(allocator, &node.inline_config);
    config_value.deinit(allocator, &node.project_config);
    config_value.deinit(allocator, &node.property_config);
    config_value.deinit(allocator, &node.root_override_config);
    config_value.deinit(allocator, &node.project_raw_config);
    config_value.deinit(allocator, &node.property_raw_config);
    config_value.deinit(allocator, &node.root_override_raw_config);
    if (node.project_root) |project_root| allocator.free(project_root);
    node.tags.deinit(allocator);
    node.incremental.deinit(allocator);
    node.meta.deinit(allocator);
    node.doc_blocks.deinit(allocator);
    deinitGenericTestDefs(allocator, &node.tests);
    for (node.columns.items) |*column| {
        config_value.deinit(allocator, &column.properties);
        column.doc_blocks.deinit(allocator);
        column.tags.deinit(allocator);
        deinitGenericTestDefs(allocator, &column.tests);
    }
    node.columns.deinit(allocator);
    node.refs.deinit(allocator);
    node.source_refs.deinit(allocator);
    node.depends_on.deinit(allocator);
    node.macro_depends_on.deinit(allocator);
    node.seed_column_types.deinit(allocator);
    if (node.snapshot_config) |*config| {
        if (config.unique_key) |*columns| columns.deinit(allocator);
        if (config.check_cols) |*columns| columns.deinit(allocator);
    }
    for (node.extra_ctes.items) |extra_cte| {
        allocator.free(extra_cte.sql);
    }
    node.extra_ctes.deinit(allocator);
}

pub fn deinitGenericTestNode(allocator: std.mem.Allocator, test_node: *GenericTestNode) void {
    config_value.deinit(allocator, &test_node.arguments);
    test_node.accepted_values.deinit(allocator);
    test_node.refs.deinit(allocator);
    test_node.source_refs.deinit(allocator);
    test_node.depends_on.deinit(allocator);
    test_node.macro_depends_on.deinit(allocator);
}

pub fn deinitSingularTestNode(allocator: std.mem.Allocator, test_node: *SingularTestNode) void {
    config_value.deinit(allocator, &test_node.config_values);
    test_node.doc_blocks.deinit(allocator);
    test_node.tags.deinit(allocator);
    test_node.refs.deinit(allocator);
    test_node.source_refs.deinit(allocator);
    test_node.depends_on.deinit(allocator);
    test_node.macro_depends_on.deinit(allocator);
}

fn deinitSingularTestProperty(allocator: std.mem.Allocator, property: *SingularTestProperty) void {
    property.tags.deinit(allocator);
}

pub fn deinitSourceDef(allocator: std.mem.Allocator, source: *SourceDef) void {
    config_value.deinit(allocator, &source.properties);
    config_value.deinit(allocator, &source.source_properties);
    config_value.deinit(allocator, &source.raw_config);
    config_value.deinit(allocator, &source.effective_config);
    deinitGenericTestDefs(allocator, &source.tests);
    for (source.columns.items) |*column| {
        config_value.deinit(allocator, &column.properties);
        column.doc_blocks.deinit(allocator);
        column.tags.deinit(allocator);
        deinitGenericTestDefs(allocator, &column.tests);
    }
    source.columns.deinit(allocator);
}

fn deinitExposureDef(allocator: std.mem.Allocator, exposure: *ExposureDef) void {
    exposure.tags.deinit(allocator);
    exposure.meta.deinit(allocator);
    exposure.refs.deinit(allocator);
    exposure.source_refs.deinit(allocator);
    exposure.depends_on.deinit(allocator);
}

pub fn deinitUnitTestDef(allocator: std.mem.Allocator, unit_test: *UnitTestDef) void {
    config_value.deinit(allocator, &unit_test.overrides);
    config_value.deinit(allocator, &unit_test.versions);
    config_value.deinit(allocator, &unit_test.version);
    config_value.deinit(allocator, &unit_test.config_values);
    for (unit_test.given.items) |*fixture| {
        deinitUnitTestFixture(allocator, fixture);
    }
    unit_test.given.deinit(allocator);
    deinitUnitTestFixture(allocator, &unit_test.expect);
    unit_test.tags.deinit(allocator);
    unit_test.meta.deinit(allocator);
    unit_test.depends_on.deinit(allocator);
}

fn deinitUnitTestFixture(allocator: std.mem.Allocator, fixture: *UnitTestFixture) void {
    for (fixture.rows.items) |*row| {
        row.entries.deinit(allocator);
    }
    fixture.rows.deinit(allocator);
}

fn deinitMacro(allocator: std.mem.Allocator, macro: *MacroDef) void {
    macro.meta.deinit(allocator);
    macro.arguments.deinit(allocator);
    macro.signature_arguments.deinit(allocator);
    macro.macro_depends_on.deinit(allocator);
    macro.supported_languages.deinit(allocator);
}

fn deinitModelProperty(allocator: std.mem.Allocator, property: *ModelProperty) void {
    config_value.deinit(allocator, &property.version);
    config_value.deinit(allocator, &property.latest_version);
    config_value.deinit(allocator, &property.config_values);
    config_value.deinit(allocator, &property.properties);
    property.incremental.deinit(allocator);
    property.tags.deinit(allocator);
    property.doc_blocks.deinit(allocator);
    deinitGenericTestDefs(allocator, &property.tests);
    for (property.columns.items) |*column| {
        config_value.deinit(allocator, &column.properties);
        column.doc_blocks.deinit(allocator);
        column.tags.deinit(allocator);
        deinitGenericTestDefs(allocator, &column.tests);
    }
    property.columns.deinit(allocator);
    property.seed_column_types.deinit(allocator);
}

fn deinitMacroProperty(allocator: std.mem.Allocator, property: *MacroProperty) void {
    property.meta.deinit(allocator);
    property.arguments.deinit(allocator);
}

fn deinitGenericTestDefs(allocator: std.mem.Allocator, tests: *std.ArrayList(GenericTestDef)) void {
    for (tests.items) |*test_def| {
        config_value.deinit(allocator, &test_def.arguments);
        test_def.accepted_values.deinit(allocator);
    }
    tests.deinit(allocator);
}
