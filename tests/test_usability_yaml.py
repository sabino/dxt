"""Native YAML trees compared with the pinned dbt Core SafeLoader."""
from __future__ import annotations

import base64
import datetime
import json
import math
from pathlib import Path
import subprocess

import pytest
import yaml

try:
    from dbt.clients.yaml_helper import SafeLoader
except ImportError:
    SafeLoader = yaml.CSafeLoader

ROOT = Path(__file__).resolve().parents[1]
ORACLE = ROOT / "zig-out" / "bin" / "dxt-yaml-oracle"


@pytest.fixture(scope="module", autouse=True)
def build_oracle():
    subprocess.run(["zig", "build", "yaml-oracle"], cwd=ROOT, check=True)


def canonical(value):
    if isinstance(value, (datetime.datetime, datetime.date)):
        return value.isoformat()
    if isinstance(value, bytes):
        return base64.b64encode(value).decode()
    if isinstance(value, float) and not math.isfinite(value):
        return ".nan" if math.isnan(value) else "-.inf" if value < 0 else ".inf"
    if isinstance(value, dict):
        return {str(key).lower() if isinstance(key, bool) else "null" if key is None else str(key): canonical(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [canonical(item) for item in value]
    if isinstance(value, set):
        return sorted(canonical(item) for item in value)
    return value


VALID = [
    "",
    "---\n# empty document\n",
    "{name: demo, paths: [models, 'two: paths'], nested: {a: 1, b: null}}\n",
    "sequence:\n- a\n- {x: 2, y: [3, 4]}\n- - nested\n  - list\n",
    "base: &base {a: 1, b: 2}\nother: &other {b: 3, c: 4}\nvalue: {<<: [*base, *other], b: 8}\ncopy: *base\n",
    "a: &a [one, two]\nb: *a\nquoted: {'<<': ordinary}\n",
    "duplicate: first\nduplicate: last\n",
    "literal: |2-\n  line one\n  line two\nfolded: >+\n  first\n  second\n\n  third\n\n",
    "text: \"snowman \\u2603 \\U0001F680\\nnext\\t tab\"\nsingle: 'isn''t escaped'\n",
    "plain: first line\n  second line\n\n  final line\n",
    "%YAML 1.1\n---\nvalue: yes\n",
    "%TAG !safe! tag:yaml.org,2002:\n---\nvalue: !safe!str false\n",
    "[yes, Yes, YES, no, No, NO, on, On, ON, off, Off, OFF, true, True, TRUE, false, False, FALSE, y, n, tRuE, ~, null, Null, NULL, 'null']",
    "[0, -0, +1, 010, 0b1010, 0xFF, 1_000, 1:20, -1:20, 999999999999999999999999999999999999, 08, 0o10]",
    "[1.2, .2, 1., 1.0e+3, 1.0e-3, 1e3, 1.0e3, .inf, .Inf, .INF, -.inf, +.inf, .nan, .NaN, .NAN, 0:20.5, 1:20:30.5]",
    "[2001-12-15, 2001-12-15T02:59:43.1Z, 2001-12-15 2:59:43.123456789 -05:30, 2001-12-15 2:59:43, 2004-02-29]",
    "[!!str 12, !!int '0x10', !!float '1e3', !!bool 'yes', !!null 'anything', !!timestamp '2001-12-15', ! true]",
    "blob: !!binary |\n  SGVsbG8s\n  IFlBTUwh\n",
    "pairs: !!pairs [a: 1, a: 2]\nordered: !!omap [first: 1, second: 2]\nset: !!set {a: null, b: null}\n",
    "? true\n: boolean\n? null\n: empty\n? 12\n: integer\n",
]


@pytest.mark.parametrize("source", VALID)
def test_native_matches_core_safe_loader(tmp_path, source):
    fixture = tmp_path / "fixture.yml"
    fixture.write_text(source)
    result = subprocess.run([ORACLE, fixture], text=True, capture_output=True, timeout=10)
    assert result.returncode == 0, result.stdout + result.stderr
    actual = json.loads(result.stdout)
    expected = canonical(yaml.load(source, Loader=SafeLoader))
    assert actual == expected


@pytest.mark.parametrize("source", [
    "a: [1, 2\n", "a: *missing\n", "a: &same 1\nb: &same 2\n",
    "a: !!python/object:unsafe {}\n", "a: !!int nonsense\n", "a: !custom value\n",
    "value: {<<: 123}\n", "---\na: 1\n---\na: 2\n", "a: 2023-02-30\n",
])
def test_native_rejects_invalid_core_yaml_with_source_diagnostic(tmp_path, source):
    with pytest.raises((yaml.YAMLError, ValueError)):
        yaml.load(source, Loader=SafeLoader)
    fixture = tmp_path / "invalid.yml"
    fixture.write_text(source)
    result = subprocess.run([ORACLE, fixture], text=True, capture_output=True, timeout=10)
    assert result.returncode == 2, result.stdout + result.stderr
    diagnostic = json.loads(result.stdout)["diagnostic"]
    assert diagnostic["line"] >= 1
    assert diagnostic["column"] >= 1
    assert diagnostic["message"]
