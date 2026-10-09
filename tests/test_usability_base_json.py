"""Real Core BaseContext decoding and project/profile context integration."""
import base64
import json
import subprocess

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import ROOT, DXT, compare, write_project


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.mark.parametrize("expression", [
    "fromjson('NaN')", "fromjson('Infinity')", "fromjson('-Infinity')",
    "fromjson('1e400')", "fromjson('-1e400')",
    "fromjson('[NaN,Infinity,-Infinity,1e400,\"NaN\"]')",
    "fromjson('{\"value\":NaN,\"escaped\":\"NaN\\\\\" Infinity\"}')",
    "set([fromjson('NaN'),fromjson('NaN')])|length",
    "set([fromjson('NaN'),fromyaml('.nan')])|length",
    "fromjson('1NaN','fallback')", "fromjson('NaNx','fallback')",
    "fromjson('+Infinity','fallback')", "fromjson('nan','fallback')",
    "fromjson('\\ufeff{}','fallback')",
])
def test_runtime_json_constants_match_core(tmp_path, core_runner, expression):
    project = tmp_path / "project"
    write_project(project, expression)
    compare(project, core_runner)


@pytest.mark.parametrize("encoding,bom", [
    ("utf-8", False), ("utf-8-sig", True),
    ("utf-16-le", False), ("utf-16-be", False),
    ("utf-16", True), ("utf-32-le", False),
    ("utf-32-be", False), ("utf-32", True),
])
def test_json_byte_encoding_matches_core(tmp_path, core_runner, encoding, bom):
    project = tmp_path / "project"
    payload = json.dumps(["é好😀", 12, True, None], ensure_ascii=False).encode(encoding)
    encoded = base64.b64encode(payload).decode("ascii")
    write_project(project, "fromjson(fromyaml('!!binary " + encoded + "'))")
    compare(project, core_runner)


@pytest.mark.parametrize("expression", [
    "fromjson(fromyaml('!!binary /w=='), 'fallback')",
    "fromjson(fromyaml('!!binary //57AA=='), 'fallback')",
])
def test_invalid_json_bytes_use_core_value_error_default(tmp_path, core_runner, expression):
    project = tmp_path / "project"
    write_project(project, expression)
    compare(project, core_runner)


@pytest.mark.parametrize("helper", [
    "fromyaml('{enabled: true}').enabled",
    "fromjson('{\"enabled\":true}').enabled",
    "local_md5('') == 'd41d8cd98f00b204e9800998ecf8427e'",
    "set_strict([1,1,2])|length == 2",
    "zip_strict([1],[2])|list|length == 1",
])
def test_base_helpers_are_available_in_project_and_profile_configuration(tmp_path, core_runner, helper):
    project = tmp_path / "project"
    write_project(project, "1")
    config = project / "dbt_project.yml"
    config.write_text(config.read_text() + 'models:\n  expressions:\n    +enabled: "{{ ' + helper.replace('"', '\\"') + ' }}"\n')
    profiles = project / "profiles.yml"
    profiles.write_text(profiles.read_text() + '      threads: "{{ fromyaml(\'2\') }}"\n')
    compare(project, core_runner)
    actual = json.loads((project / "native/manifest.json").read_text())["nodes"]["model.expressions.value"]
    expected = json.loads((project / "core/manifest.json").read_text())["nodes"]["model.expressions.value"]
    assert actual["config"]["enabled"] == expected["config"]["enabled"] is True
