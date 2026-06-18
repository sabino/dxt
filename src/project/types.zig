const std = @import("std");
const Io = std.Io;

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: Io,
};

pub const Options = struct {
    project_dir: []const u8 = ".",
    profiles_dir: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    target: ?[]const u8 = null,
    target_path: ?[]const u8 = null,
    vars: ?[]const u8 = null,
    threads: ?[]const u8 = null,
    docs_host: []const u8 = "127.0.0.1",
    docs_port: u16 = 8080,
    docs_open_browser: bool = false,
    select: ?[]const u8 = null,
    exclude: ?[]const u8 = null,
    resource_type: ?[]const u8 = null,
    output: Output = .text,
    output_keys: ?[]const []const u8 = null,
};

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
};

pub const ProjectConfig = struct {
    name: []const u8,
    profile_name: ?[]const u8 = null,
    model_paths: std.ArrayList([]const u8) = .empty,
    seed_paths: std.ArrayList([]const u8) = .empty,
    macro_paths: std.ArrayList([]const u8) = .empty,
    model_path_configs: std.ArrayList(ModelPathConfig) = .empty,
    dispatch_configs: std.ArrayList(DispatchConfig) = .empty,
    vars: std.ArrayList(VarEntry) = .empty,
    seed_docs: DocsConfig = .{},
    macro_paths_set: bool = false,
    validate_macro_args: bool = false,
    target_path: []const u8 = "target",
};

pub const DispatchConfig = struct {
    macro_namespace: []const u8,
    search_order: std.ArrayList([]const u8) = .empty,
};

pub const ModelPathConfig = struct {
    package_name: []const u8,
    path: []const u8,
    materialized: []const u8 = "",
    tags: std.ArrayList([]const u8) = .empty,
    docs: DocsConfig = .{},
};

pub const DocsConfig = struct {
    configured: bool = false,
    show: bool = true,
    node_color: ?[]const u8 = null,
};

pub const SourceDef = struct {
    package_name: []const u8,
    unique_id: []const u8,
    source_name: []const u8,
    table_name: []const u8,
    identifier: ?[]const u8 = null,
    original_file_path: []const u8,
    schema_name: ?[]const u8 = null,
    loaded_at_field: ?[]const u8 = null,
    loaded_at_query: ?[]const u8 = null,
    freshness: ?FreshnessThreshold = null,
    tests: std.ArrayList(GenericTestDef) = .empty,
    columns: std.ArrayList(ColumnDef) = .empty,
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
    } = .string,
};

pub const RefDep = struct {
    package: ?[]const u8,
    name: []const u8,
};

pub const SourceDep = struct {
    source_name: []const u8,
    table_name: []const u8,
};

pub const ColumnDef = struct {
    name: []const u8,
    description: []const u8 = "",
    doc_blocks: std.ArrayList([]const u8) = .empty,
    tests: std.ArrayList(GenericTestDef) = .empty,
};

pub const GenericTestDef = struct {
    name: []const u8,
    column_name: ?[]const u8 = null,
    accepted_values: std.ArrayList([]const u8) = .empty,
    accepted_values_quote: ?bool = null,
    relationship_to: []const u8 = "",
    relationship_field: []const u8 = "",
};

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
    package_name: []const u8,
    resource_type: []const u8 = "model",
    name: []const u8,
    patch_path: []const u8,
    description: []const u8 = "",
    materialized: []const u8 = "",
    tags: std.ArrayList([]const u8) = .empty,
    doc_blocks: std.ArrayList([]const u8) = .empty,
    tests: std.ArrayList(GenericTestDef) = .empty,
    columns: std.ArrayList(ColumnDef) = .empty,
    enabled: ?bool = null,
};

pub const UnmatchedModelProperty = struct {
    resource_type: []const u8 = "model",
    name: []const u8,
    patch_path: []const u8,
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

pub const Node = struct {
    resource_type: []const u8 = "model",
    package_name: []const u8,
    unique_id: []const u8,
    name: []const u8,
    path: []const u8,
    original_file_path: []const u8,
    patch_path: ?[]const u8 = null,
    raw_code: []const u8,
    description: []const u8 = "",
    materialized: []const u8 = "view",
    inline_materialized: bool = false,
    inline_tags: bool = false,
    config_schema: ?[]const u8 = null,
    config_alias: ?[]const u8 = null,
    enabled: bool = true,
    docs: DocsConfig = .{},
    tags: std.ArrayList([]const u8) = .empty,
    doc_blocks: std.ArrayList([]const u8) = .empty,
    tests: std.ArrayList(GenericTestDef) = .empty,
    columns: std.ArrayList(ColumnDef) = .empty,
    refs: std.ArrayList(RefDep) = .empty,
    source_refs: std.ArrayList(SourceDep) = .empty,
    depends_on: std.ArrayList([]const u8) = .empty,
    macro_depends_on: std.ArrayList([]const u8) = .empty,
    compiled: bool = false,
    compiled_code: ?[]const u8 = null,
    compiled_path: ?[]const u8 = null,
    relation_name: ?[]const u8 = null,
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
    refs: std.ArrayList(RefDep) = .empty,
    source_refs: std.ArrayList(SourceDep) = .empty,
    depends_on: std.ArrayList([]const u8) = .empty,
    macro_depends_on: std.ArrayList([]const u8) = .empty,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    project_name: []const u8,
    adapter_type: []const u8 = "duckdb",
    target_schema: []const u8 = "main",
    database_path: ?[]const u8 = null,
    database_path_base: ?[]const u8 = null,
    profile_name: ?[]const u8 = null,
    target_name: ?[]const u8 = null,
    vars: std.ArrayList(VarEntry) = .empty,
    nodes: std.ArrayList(Node) = .empty,
    tests: std.ArrayList(GenericTestNode) = .empty,
    sources: std.ArrayList(SourceDef) = .empty,
    exposures: std.ArrayList(ExposureDef) = .empty,
    unit_tests: std.ArrayList(UnitTestDef) = .empty,
    docs: std.ArrayList(DocBlock) = .empty,
    macros: std.ArrayList(MacroDef) = .empty,
    model_properties: std.ArrayList(ModelProperty) = .empty,
    macro_properties: std.ArrayList(MacroProperty) = .empty,
    unmatched_model_properties: std.ArrayList(UnmatchedModelProperty) = .empty,
    unmatched_macro_properties: std.ArrayList(UnmatchedMacroProperty) = .empty,
    macro_argument_warnings: std.ArrayList([]const u8) = .empty,
    dispatch_configs: std.ArrayList(DispatchConfig) = .empty,
    validate_macro_args: bool = false,

    pub fn deinit(self: *Graph) void {
        for (self.nodes.items) |*node| {
            deinitNode(self.allocator, node);
        }
        for (self.tests.items) |*test_node| {
            deinitGenericTestNode(self.allocator, test_node);
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
        for (self.macro_properties.items) |*property| {
            deinitMacroProperty(self.allocator, property);
        }
        for (self.macros.items) |*macro| {
            deinitMacro(self.allocator, macro);
        }
        self.nodes.deinit(self.allocator);
        self.tests.deinit(self.allocator);
        self.sources.deinit(self.allocator);
        self.exposures.deinit(self.allocator);
        self.unit_tests.deinit(self.allocator);
        self.docs.deinit(self.allocator);
        self.macros.deinit(self.allocator);
        self.model_properties.deinit(self.allocator);
        self.macro_properties.deinit(self.allocator);
        self.unmatched_model_properties.deinit(self.allocator);
        self.unmatched_macro_properties.deinit(self.allocator);
        self.macro_argument_warnings.deinit(self.allocator);
        deinitDispatchConfigs(self.allocator, &self.dispatch_configs);
        self.vars.deinit(self.allocator);
    }
};

pub const AdapterIdentity = struct {
    profile_name: []const u8,
    target_name: []const u8,
    adapter_type: []const u8,
    target_schema: []const u8,
    database_path: ?[]const u8 = null,
    database_path_base: ?[]const u8 = null,
};

pub fn deinitProjectConfig(allocator: std.mem.Allocator, config: *ProjectConfig) void {
    for (config.model_path_configs.items) |*path_config| {
        path_config.tags.deinit(allocator);
    }
    config.model_paths.deinit(allocator);
    config.seed_paths.deinit(allocator);
    config.macro_paths.deinit(allocator);
    config.model_path_configs.deinit(allocator);
    deinitDispatchConfigs(allocator, &config.dispatch_configs);
    config.vars.deinit(allocator);
}

pub fn deinitDispatchConfigs(allocator: std.mem.Allocator, configs: *std.ArrayList(DispatchConfig)) void {
    for (configs.items) |*config| {
        config.search_order.deinit(allocator);
    }
    configs.deinit(allocator);
}

pub fn deinitNode(allocator: std.mem.Allocator, node: *Node) void {
    node.tags.deinit(allocator);
    node.doc_blocks.deinit(allocator);
    deinitGenericTestDefs(allocator, &node.tests);
    for (node.columns.items) |*column| {
        column.doc_blocks.deinit(allocator);
        deinitGenericTestDefs(allocator, &column.tests);
    }
    node.columns.deinit(allocator);
    node.refs.deinit(allocator);
    node.source_refs.deinit(allocator);
    node.depends_on.deinit(allocator);
    node.macro_depends_on.deinit(allocator);
}

pub fn deinitGenericTestNode(allocator: std.mem.Allocator, test_node: *GenericTestNode) void {
    test_node.accepted_values.deinit(allocator);
    test_node.refs.deinit(allocator);
    test_node.source_refs.deinit(allocator);
    test_node.depends_on.deinit(allocator);
    test_node.macro_depends_on.deinit(allocator);
}

pub fn deinitSourceDef(allocator: std.mem.Allocator, source: *SourceDef) void {
    deinitGenericTestDefs(allocator, &source.tests);
    for (source.columns.items) |*column| {
        column.doc_blocks.deinit(allocator);
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
    property.tags.deinit(allocator);
    property.doc_blocks.deinit(allocator);
    deinitGenericTestDefs(allocator, &property.tests);
    for (property.columns.items) |*column| {
        column.doc_blocks.deinit(allocator);
        deinitGenericTestDefs(allocator, &column.tests);
    }
    property.columns.deinit(allocator);
}

fn deinitMacroProperty(allocator: std.mem.Allocator, property: *MacroProperty) void {
    property.meta.deinit(allocator);
    property.arguments.deinit(allocator);
}

fn deinitGenericTestDefs(allocator: std.mem.Allocator, tests: *std.ArrayList(GenericTestDef)) void {
    for (tests.items) |*test_def| {
        test_def.accepted_values.deinit(allocator);
    }
    tests.deinit(allocator);
}
