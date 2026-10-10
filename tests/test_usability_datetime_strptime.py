"""General datetime.strptime through the native CLI and actual pinned Core."""
from __future__ import annotations

import datetime
import json
import subprocess
import time
from importlib.metadata import version
from pathlib import Path

import pytest
from test_usability_configuration import (
    ConfigurationPair, configuration_oracle, configuration_postgres, configure_adapter,
)

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module", autouse=True)
def native_strptime_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


def pair_at(tmp_path, oracle, request, adapter, template):
    assert version("dbt-core") == "1.10.5"
    assert version("dbt-duckdb") == "1.9.6"
    assert version("dbt-postgres") == "1.9.1"
    pair = ConfigurationPair(tmp_path, oracle)
    configure_adapter(pair, request, adapter)
    pair.write("models/marts/rendered.sql", "{% set d=modules.datetime %}" + template)
    return pair


def assert_compiled(pair):
    actual, expected = [manifest["nodes"]["model.configuration_fixture.rendered"]["compiled_code"] for manifest in pair.invoke(flags=["--no-partial-parse"])]
    assert actual == expected


POSITIVE = [
    ("", ""), ("literal.+[]()", "literal.+[]()"), ("0001", "%Y"),
    ("9999-12-31", "%Y-%m-%d"), ("٢٠٢٤", "%Y"), ("０００１", "%Y"),
    ("٢٠٢٤\x00 ١\t١", "%Y\x00 %Om %Od"),
    ("0", "%Oy"), ("١١", "%Om"), ("٢٣ ٥٩ ٥٩", "%OH %OM %OS"),
    ("00", "%y"), ("68", "%y"), ("69", "%y"), ("99", "%y"),
    ("2024-2-9 1:2:3", "%Y-%m-%d %H:%M:%S"),
    ("Thursday FEBRUARY 29 2024", "%A %B %d %Y"),
    ("MON feb 29 2024", "%a %b %d %Y"),
    ("12", "%I"), ("12 am", "%I %p"), ("12 PM", "%I %p"), ("pm 4", "%p %I"),
    ("16 4 PM", "%H %I %p"), ("4 PM 16", "%I %p %H"),
    ("1 2", "%m %d"), ("2 Mar", "%m %b"), ("Mar 2", "%b %m"),
    ("2024\n\t2  29", "%Y %m %d"), ("2024\u00a02\t29", "%Y\u2003%m %d"),
    ("donʼt 2024", "don't %Y"), ("2024%02", "%Y%%%m"),
    ("2020 366", "%Y %j"), ("2019 366", "%Y %j"), ("1", "%j"),
    ("02 31 60 2020", "%m %d %j %Y"), ("02 29 61", "%m %d %j"),
    ("2020 53 5", "%G %V %u"), ("2015 53 Sunday", "%G %V %A"),
    ("2020 01 1", "%G %V %w"), ("0001 01 1", "%G %V %u"),
    ("9999 52 5", "%G %V %u"),
    ("UTC", "%Z"), ("gmt", "%Z"), ("utc +0000", "%Z %z"),
    ("+05:30 GMT", "%z %Z"), ("Z", "%z"), ("-0000", "%z"),
    ("+1234", "%z"), ("-12:34", "%z"), ("+053012", "%z"),
    ("-05:30:12", "%z"), ("+00:00:00.000001", "%z"),
]
POSITIVE += [("2024-02-29 16:17:18." + "123456"[:length], "%Y-%m-%d %H:%M:%S.%f") for length in range(1, 7)]
POSITIVE += [("+05:30:12." + "123456"[:length], "%z") for length in range(1, 7)]
POSITIVE += [(f"{year} {week:02d} {weekday}", f"%Y %{directive} %w") for year in (2019, 2020, 2021) for week in (0, 1, 52, 53) for weekday in range(7) for directive in ("U", "W")]
POSITIVE += [(datetime.datetime(2024, 2, 29, 16, 17, 18).strftime(fmt), fmt) for fmt in ("%c", "%x", "%X")]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_general_strptime_calendar_locale_offset_matrix(tmp_path, configuration_oracle, request, adapter):
    encoded = json.dumps(POSITIVE, ensure_ascii=False).replace("\\u0000", "\x00")
    template = "{% for input,format in " + encoded + " %}{% set v=d.datetime.strptime(input,format) %}{{ v }}|{{ [v] }}|{{ v.isoformat() }}|{{ v.tzname() }}\n{% endfor %}"
    assert_compiled(pair_at(tmp_path, configuration_oracle, request, adapter, template))


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_strptime_host_timezone_names_and_named_offsets(tmp_path, configuration_oracle, request, adapter, monkeypatch):
    template = "{% for input,format in [('EST','%Z'),('edt','%Z'),('EDT -0400','%Z %z'),('-0500 est','%z %Z')] %}{% set v=d.datetime.strptime(input,format) %}{{ v }}|{{ [v] }}|{{ v.tzname() }}\n{% endfor %}"
    try:
        with monkeypatch.context() as clock:
            clock.setenv("TZ", "America/New_York")
            time.tzset()
            assert_compiled(pair_at(tmp_path, configuration_oracle, request, adapter, template))
    finally:
        time.tzset()


INVALID = [
    ("2020", "%q"), ("2020", "%"), ("2020-01-01", "%F"),
    ("+00:00", "%:z"), ("1", "%-d"), ("2020 2020", "%Y %Y"),
    ("01 01", "%d %Od"), ("0000", "%Y"), ("1", "%Y"),
    ("2020-00-01", "%Y-%m-%d"), ("2020-13-01", "%Y-%m-%d"),
    ("2020-02-30", "%Y-%m-%d"), ("1900-02-29", "%Y-%m-%d"),
    ("Feb 29", "%b %d"), ("9999 366", "%Y %j"),
    ("24", "%H"), ("0", "%I"), ("13", "%I"), ("60", "%M"),
    ("60", "%S"), ("61", "%S"), ("1234567", "%f"), ("١", "%f"),
    ("z", "%z"), ("+05", "%z"), ("+05:3012", "%z"), ("+0530:12", "%z"),
    ("+2400", "%z"), ("+0560", "%z"), ("+00:00:00.1234567", "%z"),
    ("Mars", "%Z"), ("2020 01", "%G %V"), ("2020 01 1", "%Y %V %u"),
    ("2020 01 1 001", "%G %V %u %j"), ("2021 53 1", "%G %V %u"),
    ("2020 00 1", "%G %V %u"), ("2020 54 1", "%G %V %u"),
    ("2020 01 9", "%G %V %Ow"), ("2020 extra", "%Y"), ("", " "),
]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("input,format", INVALID)
def test_strptime_invalid_data_and_format_fail_in_parse(tmp_path, configuration_oracle, request, adapter, input, format):
    encoded_input, encoded_format = json.dumps(input), json.dumps(format)
    template = "{{ d.datetime.strptime(" + encoded_input + "," + encoded_format + ") }}"
    result, reference = pair_at(tmp_path, configuration_oracle, request, adapter, template).invoke("parse", flags=["--no-partial-parse"], success=False)
    assert reference.exception is not None or reference.result is not None
    assert "InvalidOption" not in result.stderr
    assert "Unsupported" not in result.stderr


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("expression", [
    "d.datetime.strptime()", "d.datetime.strptime('2020')",
    "d.datetime.strptime(none,'%Y')", "d.datetime.strptime('2020',none)",
    "d.datetime.strptime('2020','%Y','extra')",
    "d.datetime.strptime(date_string='2020',format='%Y')",
])
def test_strptime_argument_errors_fail_in_parse(tmp_path, configuration_oracle, request, adapter, expression):
    result, reference = pair_at(tmp_path, configuration_oracle, request, adapter, "{{ " + expression + " }}").invoke("parse", flags=["--no-partial-parse"], success=False)
    assert reference.exception is not None or reference.result is not None
    assert "InvalidOption" not in result.stderr
    assert "Unsupported" not in result.stderr
