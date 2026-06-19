# Architecture

dxt is organized around a native Zig product runtime. Python tooling is outside
the product boundary and is used only for validation, fixtures, oracle
comparison, and safety scans.

## Runtime Boundary

```mermaid
flowchart LR
    subgraph ProductRuntime[Zig product runtime]
        CLI[src/main.zig and src/root.zig]
        Loader[src/project/loader.zig]
        Parser[src/project/parse.zig]
        Graph[src/project/types.zig]
        Selector[src/project/selector.zig]
        Compiler[src/project/compiler.zig]
        Manifest[src/project/manifest.zig]
        Runner[src/project.zig orchestration]
        DuckDB[src/project/duckdb.zig]
    end

    subgraph DevOnly[Developer-only Python]
        Pytest[pytest fixtures]
        Oracle[dbt oracle harnesses]
        Safety[safety/schema scripts]
    end

    CLI --> Loader --> Parser --> Graph
    Graph --> Selector
    Graph --> Compiler
    Graph --> Manifest
    Selector --> Runner --> DuckDB
    Pytest -. invokes binary .-> CLI
    Oracle -. compares artifacts .-> Manifest
    Safety -. checks repository .-> ProductRuntime
```

## Module Ownership

| Module | Current responsibility |
| --- | --- |
| `src/main.zig` | Thin process entrypoint. |
| `src/root.zig` | CLI parsing, command dispatch, and user-facing error mapping. |
| `src/project.zig` | Public facade and orchestration while extraction continues. |
| `src/project/types.zig` | Core graph, node, source, test, macro, config, and runtime data model. |
| `src/project/config.zig` | `dbt_project.yml` and project config parsing. |
| `src/project/clean.zig` | Safe project-relative clean-target deletion. |
| `src/project/profile.zig` | Narrow profile/target/adapter identity parsing. |
| `src/project/fs.zig` | Deterministic file discovery. |
| `src/project/loader.zig` | Project/package loading order and graph construction callbacks. |
| `src/project/parse.zig` | YAML resource parsing, macro/test block parsing, source/exposure helpers, generic test naming. |
| `src/project/jinja.zig` | Lexical SQL/Jinja scanning for supported dependency/config surfaces. |
| `src/project/resolve.zig` | Dependency resolution, duplicate checks, sorting, macro lookup. |
| `src/project/selector.zig` | Selector matching, graph expansion, wildcards. |
| `src/project/compiler.zig` | Render-only compiler subset and relation rendering. |
| `src/project/duckdb.zig` | Current DuckDB CLI-backed SQL execution/introspection. |
| `src/project/json.zig` | Shared JSON writer helpers for strings, nullable strings, booleans, object fields, and string arrays using Zig `std.json`. |
| `src/project/manifest.zig` | Manifest v12-shaped JSON writer. |
| `src/project/run_results.zig` | Run Results v6-shaped JSON writer. |
| `src/project/catalog.zig` | Catalog v1-shaped JSON writer. |
| `src/project/source_freshness.zig` | Source freshness status and Sources v3-shaped writer. |

`src/project.zig` is intentionally a transition facade. New shared behavior
should move toward focused `src/project/*.zig` modules.

## Parse To Artifact Flow

```mermaid
flowchart TD
    Project[dbt_project.yml] --> Load[loadGraph]
    Profiles[profiles.yml] --> Load
    Packages[dbt_packages] --> Load
    SQL[models/*.sql] --> ParseSQL[SQL/Jinja scanner]
    YAML[properties YAML] --> ParseYAML[YAML parsers]
    Macros[macros/*.sql] --> ParseMacros[macro block parser]
    Load --> ParseSQL
    Load --> ParseYAML
    Load --> ParseMacros
    ParseSQL --> Graph[Graph]
    ParseYAML --> Graph
    ParseMacros --> Graph
    Graph --> Resolve[resolveDependencies]
    Resolve --> Sort[deterministic sorting]
    Sort --> Manifest[manifest.json]
```

## Execution Flow

```mermaid
flowchart LR
    Select[selectResources] --> Preflight[build/run preflight]
    Preflight --> Compile[compile selected models]
    Compile --> DuckDB[DuckDB CLI boundary]
    DuckDB --> Relations[(DuckDB database)]
    DuckDB --> RunResults[run_results.json]
    Relations --> Catalog[catalog.json]
    Relations --> Freshness[sources.json]
```

## Artifact Ownership

```mermaid
flowchart TD
    Graph[Graph] --> ManifestWriter[src/project/manifest.zig]
    JsonWriter[src/project/json.zig] --> ManifestWriter
    JsonWriter --> RunResultsWriter
    JsonWriter --> CatalogWriter
    JsonWriter --> FreshnessCalc
    ManifestWriter --> Manifest[manifest.json]
    Runner[Execution orchestration] --> RunResultsWriter[src/project/run_results.zig]
    RunResultsWriter --> RunResults[run_results.json]
    DuckDB[DuckDB introspection] --> CatalogWriter[src/project/catalog.zig]
    CatalogWriter --> Catalog[catalog.json]
    FreshnessCalc[src/project/source_freshness.zig] --> Sources[sources.json]
```

## Future Cross-Database Planner

```mermaid
flowchart TD
    LogicalPlan[Logical transformation plan] --> Capabilities[Adapter capability matrix]
    Capabilities --> Strategies{Choose strategy}
    Strategies --> Pushdown[Full pushdown]
    Strategies --> Stage[Push filters/projections and stage reduced data]
    Strategies --> Local[Bounded local embedded join]
    Strategies --> Reject[Reject unsafe movement]
    Policy[Movement policy and sensitivity tags] --> Strategies
    Cost[Cost and row/byte estimates] --> Strategies
    Pushdown --> Explain[Plan explanation]
    Stage --> Explain
    Local --> Explain
    Reject --> Explain
```

The planner must preserve source relation identity, model data movement
explicitly, enforce policy before execution, and record rejected strategies.
