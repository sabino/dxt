"""Developer-only full artifact validation using the pinned upstream contracts.

The schema classes are the source of the published schemas.getdbt.com schemas.
No partial dxt schema, remote fetch, or product runtime is involved.
"""
from __future__ import annotations

import argparse
import importlib.metadata
import json
from pathlib import Path
from functools import lru_cache

import jsonschema


@lru_cache(maxsize=1)
def upstream_schemas():
    installed = importlib.metadata.version("dbt-core")
    if installed != "1.10.5":
        raise RuntimeError(f"Artifact certification requires dbt-core 1.10.5; found {installed}")
    from dbt.artifacts.schemas.manifest.v12.manifest import WritableManifest
    from dbt.artifacts.schemas.run.v5.run import RunResultsArtifact
    from dbt.artifacts.schemas.catalog.v1.catalog import CatalogArtifact
    from dbt.artifacts.schemas.freshness.v3.freshness import FreshnessExecutionResultArtifact

    contracts = (WritableManifest, RunResultsArtifact, CatalogArtifact, FreshnessExecutionResultArtifact)
    schemas = {str(contract.dbt_schema_version): contract.json_schema() for contract in contracts}
    for schema in schemas.values():
        jsonschema.Draft7Validator.check_schema(schema)
    return schemas


def validate_artifact(artifact):
    schema_id = artifact.get("metadata", {}).get("dbt_schema_version")
    schema = upstream_schemas().get(schema_id)
    if schema is None:
        raise ValueError(f"Unsupported dbt artifact schema: {schema_id!r}")
    validator = jsonschema.Draft7Validator(schema, format_checker=jsonschema.FormatChecker())
    return list(validator.iter_errors(artifact))


def assert_artifact(path):
    errors = validate_artifact(json.loads(Path(path).read_text(encoding="utf-8")))
    if errors:
        details = "\n".join(f"{'.'.join(map(str, error.absolute_path))}: {error.message}" for error in errors)
        raise AssertionError(f"{Path(path).name} fails its complete upstream artifact schema:\n{details}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", type=Path, nargs="+")
    arguments = parser.parse_args()
    for path in arguments.artifacts:
        assert_artifact(path)
        print(f"{path.name}: complete upstream schema passed")


if __name__ == "__main__":
    main()
