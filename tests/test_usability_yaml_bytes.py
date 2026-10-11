"""Actual Core byte scalar expression and method behavior from SafeLoader."""
import base64
import subprocess

import pytest

from test_usability_commands import core_runner
from test_usability_expression_types import ROOT, DXT, compare, write_project


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


@pytest.mark.parametrize("expression", [
    "fromyaml('!!binary SGVsbG8=')[0]",
    "fromyaml('!!binary SGVsbG8=')[-1]",
    "fromyaml('!!binary SGVsbG8=')[1:]",
    "fromyaml('!!binary SGVsbG8=')[::-1]",
    "fromyaml('!!binary SGVsbG8=')[::2]",
    "fromyaml('!!binary SGVsbG8=') + fromyaml('!!binary IQ==')",
    "fromyaml('!!binary SGVsbG8=') * 2",
    "2 * fromyaml('!!binary SGVsbG8=')",
    "fromyaml('!!binary SGVsbG8=') * -1",
    "fromyaml('!!binary SGVsbG8=') * false",
    "101 in fromyaml('!!binary SGVsbG8=')",
    "true in fromyaml('!!binary AAE=')",
    "fromyaml('!!binary ZWxs') in fromyaml('!!binary SGVsbG8=')",
    "fromyaml('!!binary IA==') not in fromyaml('!!binary SGVsbG8=')",
    "fromyaml('!!binary SGVsbG8=') == fromyaml('!!binary SGVsbG8=')",
    "fromyaml('!!binary SGVsbG8=') != 'Hello'",
    "fromyaml('!!binary YQ==') < fromyaml('!!binary Yg==')",
    "fromyaml('2020-01-02T03:00:00Z') == fromyaml('2020-01-02T04:00:00+01:00')",
    "fromyaml('2020-01-02T03:00:00Z') < fromyaml('2020-01-02T04:01:00+01:00')",
    "fromyaml('2020-01-02') < fromyaml('2020-01-03')",
    "fromyaml('2020-01-02') != fromyaml('2020-01-02T00:00:00')",
    "fromyaml('2020-01-02T03:00:00Z') != fromyaml('2020-01-02T03:00:00')",
    "[fromyaml('!!binary Yg=='),fromyaml('!!binary YQ==')] | sort",
    "[fromyaml('!!binary Yg=='),fromyaml('!!binary YQ==')] | min",
    "[fromyaml('!!binary Yg=='),fromyaml('!!binary YQ==')] | max",
    "[fromyaml('!!binary YQ=='),fromyaml('!!binary YQ=='),fromyaml('!!binary Yg==')] | unique | list",
    "[fromyaml('2020-01-03'),fromyaml('2020-01-02')] | sort",
    "[fromyaml('2020-01-03'),fromyaml('2020-01-02')] | min",
    "[fromyaml('2020-01-02T03:00:00Z'),fromyaml('2020-01-02T04:00:00+01:00')] | unique | list | length",
    "[fromyaml('2020-01-02T04:01:00+01:00'),fromyaml('2020-01-02T03:00:00Z')] | sort | map('string') | list",
])
def test_yaml_bytes_and_dates_expression_protocols_match_core(tmp_path, core_runner, expression):
    project = tmp_path / "project"
    write_project(project, expression)
    compare(project, core_runner)


@pytest.mark.parametrize("expression", [
    "fromyaml('!!binary YQ==') + 'b'",
    "fromyaml('!!binary YQ==') * 1.0",
    "1.0 in fromyaml('!!binary YQ==')",
    "-1 in fromyaml('!!binary YQ==')",
    "256 in fromyaml('!!binary YQ==')",
    "'a' in fromyaml('!!binary YQ==')",
    "fromyaml('2020-01-02') < fromyaml('2020-01-02T00:00:00')",
    "fromyaml('2020-01-02T00:00:00Z') < fromyaml('2020-01-02T00:00:00')",
    "[fromyaml('!!binary YQ=='),'a'] | sort",
    "[fromyaml('2020-01-02'),fromyaml('2020-01-02T00:00:00')] | sort",
])
def test_yaml_typed_scalar_protocol_errors_match_core(tmp_path, core_runner, expression):
    project = tmp_path / "project"
    write_project(project, expression)
    common = ["compile", "--project-dir", str(project), "--profiles-dir", str(project), "--select", "value"]
    actual = subprocess.run([DXT, *common], capture_output=True, text=True)
    expected = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert actual.returncode != 0
    assert not expected.success


@pytest.mark.parametrize("expression", [
    "fromyaml('!!binary AAECAwQ=').hex(':')",
    "fromyaml('!!binary AAECAwQ=').hex(':',2)",
    "fromyaml('!!binary AAECAwQ=').hex(':',-2)",
    "fromyaml('!!binary AAECAwQ=').hex(':',0)",
    "fromyaml('!!binary AAECAwQ=').hex(sep=':',bytes_per_sep=2)",
    "fromyaml('!!binary AAECAwQ=').hex(fromyaml('!!binary Og=='),2)",
    "fromyaml('!!binary SGVsbG8=').decode(errors='unknown')",
    "fromyaml('!!binary /0E=').decode(errors='ignore')",
    "fromyaml('!!binary /0E=').decode(errors='replace')",
    "fromyaml('!!binary /0E=').decode(errors='backslashreplace')",
    "fromyaml('!!binary 4oI=').decode(errors='replace')",
    "fromyaml('!!binary 4kE=').decode(errors='replace')",
    "fromyaml('!!binary 8ICA').decode(errors='replace')",
    "fromyaml('!!binary 7aCA').decode(errors='replace')",
    "fromyaml('!!binary /0E=').decode('ascii',errors='replace')",
    "fromyaml('!!binary /0E=').decode('latin1',errors='unknown')",
])
def test_yaml_bytes_hex_and_decode_methods_match_core(tmp_path, core_runner, expression):
    project = tmp_path / "project"
    write_project(project, expression)
    compare(project, core_runner)


@pytest.mark.parametrize("encoding", [
    "utf-8", "UTF_8", "UTF 8", "utf-8-sig", "utf-16", "utf_16_le",
    "utf-16-be", "utf-32", "UTF_32_LE", "utf-32-be",
])
def test_yaml_bytes_native_unicode_codecs_match_core(tmp_path, core_runner, encoding):
    encoded = base64.b64encode("Aé好😀".encode(encoding)).decode("ascii")
    expression = f"fromyaml('!!binary {encoded}').decode('{encoding}')"
    project = tmp_path / "project"
    write_project(project, expression)
    compare(project, core_runner)


@pytest.mark.parametrize("encoding, payload, errors", [
    ("utf-16", b"A\x00", "strict"),
    ("utf-16", b"\xfe\xff\x00A", "strict"),
    ("utf-16-le", b"\xff\xfeA\x00", "strict"),
    ("utf-32", b"A\x00\x00\x00", "strict"),
    ("utf-32-be", b"\x00\x00\xfe\xff\x00\x00\x00A", "strict"),
    ("utf-8-sig", b"\xef\xbb\xbfA", "unknown"),
    ("latin_1", b"\x00\xff", "unknown"),
    ("ISO8859_1", b"\xa3", "strict"),
    ("windows-1252", b"\x00\x80\x91", "strict"),
    ("cp1252", b"\x81A", "replace"),
    ("cp1252", b"\x81A", "ignore"),
    ("cp1252", b"\x81A", "backslashreplace"),
    ("us-ascii", b"\xffA", "replace"),
    ("utf-16-le", b"\x00\xd8A\x00", "replace"),
    ("utf-16-le", b"\x00\xd8A", "replace"),
    ("utf-16-le", b"\x00\xd8A", "backslashreplace"),
    ("utf-16-be", b"\xdc\x00\x00A", "ignore"),
    ("utf-32-le", b"\x00\x00\x11\x00A\x00\x00\x00", "replace"),
    ("utf-32-be", b"\x00\x00\xd8\x00\x00", "backslashreplace"),
    ("utf-32-le", b"A\x00", "replace"),
    ("utf-16-le", b"", "unknown"),
])
def test_yaml_bytes_codec_boundaries_match_core(tmp_path, core_runner, encoding, payload, errors):
    encoded = base64.b64encode(payload).decode("ascii")
    expression = f"fromyaml('!!binary {encoded}').decode('{encoding}',errors='{errors}')"
    if not encoded:
        expression = f"fromyaml('!!binary \"\"').decode('{encoding}',errors='{errors}')"
    project = tmp_path / "project"
    write_project(project, expression)
    compare(project, core_runner)


@pytest.mark.parametrize("expression", [
    "fromyaml('!!binary SGVsbG8=').hex(':',bytes_per_sep=2)",
    "fromyaml('!!binary SGVsbG8=').hex(sep=':',bytes_per_sep=-2)",
    "fromyaml('!!binary \"\"').hex(':',2)",
])
def test_yaml_bytes_hex_argument_binding_match_core(tmp_path, core_runner, expression):
    project = tmp_path / "project"
    write_project(project, expression)
    compare(project, core_runner)


@pytest.mark.parametrize("expression", [
    "fromyaml('!!binary YQ==').hex('::')",
    "fromyaml('!!binary YQ==').hex('é')",
    "fromyaml('!!binary YQ==').hex(1)",
    "fromyaml('!!binary YQ==').hex(':',1.0)",
    "fromyaml('!!binary YQ==').hex(':',2,sep=':')",
    "fromyaml('!!binary YQ==').hex(unexpected=':')",
    "fromyaml('!!binary YQ==').decode(1)",
    "fromyaml('!!binary YQ==').decode(errors=1)",
    "fromyaml('!!binary YQ==').decode('utf-8',encoding='ascii')",
    "fromyaml('!!binary YQ==').decode('utf..8')",
    "fromyaml('!!binary gQ==').decode('cp1252')",
    "fromyaml('!!binary ANg=').decode('utf16le')",
    "fromyaml('!!binary QQ==').decode('utf16')",
    "fromyaml('!!binary AAARAA==').decode('utf32le')",
    "fromyaml('!!binary /w==').decode(errors='unknown')",
])
def test_yaml_bytes_method_errors_match_core(tmp_path, core_runner, expression):
    project = tmp_path / "project"
    write_project(project, expression)
    common = ["compile", "--project-dir", str(project), "--profiles-dir", str(project), "--select", "value"]
    actual = subprocess.run([DXT, *common], capture_output=True, text=True)
    expected = core_runner.invoke(["--quiet", *common, "--no-partial-parse"])
    assert actual.returncode != 0
    assert not expected.success
