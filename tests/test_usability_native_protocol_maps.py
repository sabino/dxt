"""Authored dictionaries retain their Core behavior around native protocols."""
import subprocess
from pathlib import Path

import pytest

from test_usability_configuration import (
    ConfigurationPair, configuration_oracle, configuration_postgres, configure_adapter,
)

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("template", [
    "{% set value={'__dxt_native_tuple':'__dxt_native_tuple','__dxt_iterable':[2026,41,6]} %}"
    "select '{{ tojson(value) }}' as value",
    "{% set value={'__dxt_native_tuple':'__dxt_native_tuple','__dxt_iterable':[2026,41,6]} %}"
    "select '{{ value|tojson(indent=2) }}' as value",
    "{% set value={'__dxt_native_mapping':'__dxt_native_mapping','__dxt_mapping_source':{'x':'a b'}} %}"
    "select '{{ value.keys()|list }};{{ 'x' in value }};{{ value['__dxt_mapping_source']['x'] }}' as value",
])
def test_authored_protocol_field_names_match_core(tmp_path, configuration_oracle, request, adapter, template):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write("models/marts/rendered.sql", template)
    native, core = pair.invoke()
    key = "model.configuration_fixture.rendered"
    assert native["nodes"][key]["compiled_code"] == core["nodes"][key]["compiled_code"]
