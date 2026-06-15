from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SCHEMA = ROOT / "tests" / "schemas" / "dbt_manifest_v12_m1_slice.schema.json"


class ValidationError(Exception):
    pass


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def schema_ref(schema: dict[str, Any], ref: str) -> dict[str, Any]:
    if not ref.startswith("#/"):
        raise ValidationError(f"unsupported external $ref: {ref}")
    target: Any = schema
    for raw_part in ref[2:].split("/"):
        part = raw_part.replace("~1", "/").replace("~0", "~")
        target = target[part]
    if not isinstance(target, dict):
        raise ValidationError(f"$ref does not point to a schema object: {ref}")
    return target


def type_matches(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return (isinstance(value, int) or isinstance(value, float)) and not isinstance(value, bool)
    raise ValidationError(f"unsupported schema type: {expected}")


def path_join(path: str, part: str) -> str:
    if path == "$":
        return f"$.{part}"
    return f"{path}.{part}"


def validate_value(value: Any, subschema: dict[str, Any], root_schema: dict[str, Any], path: str = "$") -> list[str]:
    if "$ref" in subschema:
        return validate_value(value, schema_ref(root_schema, subschema["$ref"]), root_schema, path)

    errors: list[str] = []
    if "oneOf" in subschema:
        branch_results = [
            validate_value(value, branch_schema, root_schema, path)
            for branch_schema in subschema["oneOf"]
        ]
        matches = [branch_errors for branch_errors in branch_results if not branch_errors]
        if len(matches) == 1:
            return []
        if len(matches) == 0:
            errors.append(f"{path}: value did not match any oneOf schema")
            for index, branch_errors in enumerate(branch_results):
                for branch_error in branch_errors:
                    errors.append(f"{path}: oneOf[{index}] {branch_error}")
        else:
            errors.append(f"{path}: value matched {len(matches)} oneOf schemas")
        return errors

    if "const" in subschema and value != subschema["const"]:
        errors.append(f"{path}: expected const {subschema['const']!r}, got {value!r}")
    if "enum" in subschema and value not in subschema["enum"]:
        errors.append(f"{path}: expected one of {subschema['enum']!r}, got {value!r}")

    expected_type = subschema.get("type")
    if expected_type is not None:
        expected_types = expected_type if isinstance(expected_type, list) else [expected_type]
        if not any(type_matches(value, item) for item in expected_types):
            errors.append(f"{path}: expected type {expected_type!r}, got {type(value).__name__}")
            return errors

    if isinstance(value, dict):
        required = subschema.get("required", [])
        for key in required:
            if key not in value:
                errors.append(f"{path}: missing required property {key!r}")

        properties = subschema.get("properties", {})
        for key, child_schema in properties.items():
            if key in value:
                errors.extend(validate_value(value[key], child_schema, root_schema, path_join(path, key)))

        matched_pattern_keys: set[str] = set()
        for pattern, child_schema in subschema.get("patternProperties", {}).items():
            compiled = re.compile(pattern)
            for key, child_value in value.items():
                if compiled.search(key):
                    matched_pattern_keys.add(key)
                    errors.extend(validate_value(child_value, child_schema, root_schema, path_join(path, key)))

        additional = subschema.get("additionalProperties", True)
        known_keys = set(properties) | matched_pattern_keys
        for key, child_value in value.items():
            if key in known_keys:
                continue
            if additional is False:
                errors.append(f"{path}: unexpected property {key!r}")
            elif isinstance(additional, dict):
                errors.extend(validate_value(child_value, additional, root_schema, path_join(path, key)))

    if isinstance(value, list) and isinstance(subschema.get("items"), dict):
        item_schema = subschema["items"]
        for index, item in enumerate(value):
            errors.extend(validate_value(item, item_schema, root_schema, f"{path}[{index}]"))

    return errors


def validate_manifest(manifest: dict[str, Any], schema: dict[str, Any]) -> list[str]:
    return validate_value(manifest, schema, schema)


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate a dxt manifest against the pinned M1 dbt schema slice.")
    parser.add_argument("manifest", nargs="+", type=Path)
    parser.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA)
    args = parser.parse_args()

    schema = load_json(args.schema)
    failed = False
    for manifest_path in args.manifest:
        manifest = load_json(manifest_path)
        errors = validate_manifest(manifest, schema)
        if errors:
            failed = True
            print(f"{manifest_path}: schema validation failed", file=sys.stderr)
            for error in errors:
                print(f"  - {error}", file=sys.stderr)
        else:
            print(f"{manifest_path}: schema validation passed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
