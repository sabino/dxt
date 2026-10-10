"""Artifact certification rejects ambiguous or invalid JSON before schemas."""
import importlib.util
from pathlib import Path

import pytest


spec = importlib.util.spec_from_file_location(
    "strict_artifact_json", Path(__file__).resolve().parents[1] / "scripts/validate_dbt_artifacts.py"
)
contracts = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contracts)


@pytest.mark.parametrize("text", [
    '{"relation_name": null, "relation_name": "different"}',
    '{"nodes": {"model.project.a": {"config": {"enabled": true, "enabled": false}}}}',
    '{"elapsed_time": NaN}', '{"elapsed_time": Infinity}', '{"elapsed_time": -Infinity}',
])
def test_artifact_reader_rejects_ambiguous_and_nonstandard_json(tmp_path, text):
    path = tmp_path / "manifest.json"
    path.write_text(text)
    with pytest.raises(ValueError):
        contracts.read_artifact(path)


def test_artifact_reader_preserves_valid_nested_and_repeated_keys_in_distinct_objects(tmp_path):
    path = tmp_path / "manifest.json"
    path.write_text('{"a": {"relation_name": null}, "b": {"relation_name": "physical"}, "elapsed_time": 0.1}')
    assert contracts.read_artifact(path) == {
        "a": {"relation_name": None}, "b": {"relation_name": "physical"}, "elapsed_time": 0.1
    }
