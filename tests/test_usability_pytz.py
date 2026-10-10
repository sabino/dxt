"""Pinned pytz/IANA exports and historical transitions through native CLI/Core."""
from __future__ import annotations
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
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


def pair_at(tmp_path, configuration_oracle, request, adapter, template):
    import pytz
    assert version("pytz") == "2026.5"
    assert pytz.OLSON_VERSION == "2026e"
    assert version("dbt-core") == "1.10.5"
    assert version("dbt-duckdb") == "1.9.6"
    assert version("dbt-postgres") == "1.9.1"
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write("models/marts/rendered.sql", "{% set p=modules.pytz %}{% set d=modules.datetime %}" + template)
    return pair


def assert_compiled(pair):
    actual, expected = [manifest["nodes"]["model.configuration_fixture.rendered"]["compiled_code"] for manifest in pair.invoke(flags=["--no-partial-parse"])]
    assert actual == expected


EXPORTS = [
    "{{ p.keys()|list }}",
    "{% for name in ['all_timezones','all_timezones_set','common_timezones','common_timezones_set','country_names','country_timezones'] %}{{ p[name] is sameas(modules.pytz[name]) }}|{% endfor %}",
    "{{ p.all_timezones }}",
    "{{ p.common_timezones }}",
    "{{ p.all_timezones_set|sort }}|{{ p.common_timezones_set|sort }}",
    "{{ p.all_timezones|length }}|{{ p.common_timezones|length }}|{{ 'UTC' in p.all_timezones_set }}|{{ 'Mars/Olympus' in p.common_timezones_set }}",
    "{{ p.country_names|length }}|{{ p.country_timezones|length }}",
    "{{ p.country_names.keys()|sort }}|{{ p.country_timezones.keys()|sort }}",
    "{{ p.country_names['us'] }}|{{ p.country_names.get('gb') }}|{{ p.country_names['US'] }}|{{ p.country_names['uſ'] }}",
    "{{ p.country_timezones['us'] }}|{{ p.country_timezones.get('np') }}",
    "{{ p.country_names.get('zz','missing') }}|{{ p.country_timezones['ZZ']|default('missing') }}",
    "{{ 'US' in p.country_names }}|{{ 'us' in p.country_names }}|{{ 'uſ' in p.country_names }}|{{ 1 in p.country_names }}|{{ 'ZZ' in p.country_names }}",
    "{{ p.country_names[fromyaml('!!binary VVM=')]|default('missing') }}|{{ p.country_names.get(fromyaml('!!binary VVM='),'missing') }}",
    "{{ p.country_names is mapping }}|{{ p.country_names is iterable }}|{{ p.utc is mapping }}|{{ p.utc is iterable }}",
    "{{ p.utc }}|{{ [p.utc] }}|{{ p.utc.zone }}|{{ p.UTC|default('missing') }}",
    "{{ p.timezone('america/new_york') }}|{{ p.timezone(zone='Etc/GMT_plus_3') }}",
    "{{ [p.timezone('GMT'),p.timezone('Asia/Kathmandu'),p.timezone('US/Eastern')] }}",
    "{{ p.timezone('utc') is sameas(p.utc) }}|{{ p.timezone('US/Eastern') is sameas(p.timezone('us/eastern')) }}",
    "{{ p.FixedOffset(0) is sameas(p.utc) }}|{{ p.FixedOffset(-330) is sameas(p.FixedOffset(-330)) }}",
    "{{ p.FixedOffset(-330) }}|{{ p.FixedOffset(1380) }}|{{ p.FixedOffset(5.5) }}",
    "{{ p.FixedOffset(59.99999999999) }}|{{ p.FixedOffset(5.00000000001) is sameas(p.FixedOffset(5)) }}|{{ p.FixedOffset(5.0) is sameas(p.FixedOffset(5)) }}",
    "{{ p.utc.utcoffset(none) }}|{{ p.utc.dst(none) }}|{{ p.utc.tzname(none) }}",
    "{{ p.timezone('GMT').utcoffset(none) }}|{{ p.timezone('GMT').dst(none) }}|{{ p.timezone('GMT').tzname(none) }}",
    "{{ p.timezone('Asia/Kathmandu').utcoffset(none) }}|{{ p.timezone('Asia/Kathmandu').dst(none) }}|{{ p.timezone('Asia/Kathmandu').tzname(none) }}",
    "{{ p.FixedOffset(-330).utcoffset(none) }}|{{ p.FixedOffset(-330).dst(none) }}|{{ p.FixedOffset(-330).tzname(none) }}",
    "{{ p.FixedOffset(5.5).utcoffset(none) }}|{{ p.FixedOffset(5.5).utcoffset(none).total_seconds() }}",
    "{{ p.BaseTzInfo }}|{{ p.BaseTzInfo().zone }}",
    "{{ p.BaseTzInfo is sameas(modules.pytz.BaseTzInfo) }}|{{ p.UnknownTimeZoneError is sameas(modules.pytz.UnknownTimeZoneError) }}|{{ {p.BaseTzInfo:1,modules.pytz.BaseTzInfo:2}|length }}|{% set a=p.BaseTzInfo() %}{% set b=p.BaseTzInfo() %}{{ a is sameas(a) }}|{{ a is sameas(b) }}|{{ a==b }}|{{ {a:1,b:2}|length }}",
    "{{ p.AmbiguousTimeError }}|{{ p.InvalidTimeError }}|{{ p.NonExistentTimeError }}|{{ p.UnknownTimeZoneError }}",
    "{{ p.AmbiguousTimeError('clock') }}|{{ p.InvalidTimeError() }}|{{ p.NonExistentTimeError(3,'clock').args }}|{{ p.UnknownTimeZoneError('unknown') }}",
    "{{ p.timezone(fromyaml('!!binary VVRD')) }}",
]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("template", EXPORTS)
def test_pinned_pytz_exports(tmp_path, configuration_oracle, request, adapter, template):
    assert_compiled(pair_at(tmp_path, configuration_oracle, request, adapter, template))


TEMPORAL = [
    "{% set t=p.timezone('America/New_York').localize(d.datetime(2020,7,1,12)) %}{{ t }}|{{ t.isoformat() }}|{{ t.strftime('%Y-%m-%d %H:%M:%S %Z %z') }}|{{ t.tzinfo.zone }}",
    "{% set t=p.timezone('America/New_York').localize(d.datetime(2020,1,1,12)) %}{{ t.utcoffset() }}|{{ t.dst() }}|{{ t.tzname() }}|{{ t.timestamp() }}",
    "{% set t=p.timezone('America/New_York') %}{{ t.utcoffset(d.datetime(2020,7,1)) }}|{{ t.dst(d.datetime(2020,7,1)) }}|{{ t.tzname(d.datetime(2020,7,1)) }}",
    "{% set t=p.timezone('America/New_York') %}{{ t.utcoffset(d.datetime(2020,11,1,1,30),is_dst=true) }}|{{ t.utcoffset(d.datetime(2020,11,1,1,30),is_dst=false) }}",
    "{% set t=p.timezone('America/New_York') %}{{ t.localize(d.datetime(2020,11,1,1,30),true) }}|{{ t.localize(d.datetime(2020,11,1,1,30),false) }}|{{ t.localize(d.datetime(2020,11,1,1,30)) }}",
    "{% set t=p.timezone('America/New_York') %}{{ t.localize(d.datetime(2020,3,8,2,30),true) }}|{{ t.localize(d.datetime(2020,3,8,2,30),false) }}",
    "{% set t=p.timezone('Europe/Warsaw') %}{{ t.localize(d.datetime(1915,8,4,23,50),true) }}|{{ t.localize(d.datetime(1915,8,4,23,50),false) }}",
    "{% set t=p.timezone('Europe/Dublin') %}{{ t.localize(d.datetime(2020,10,25,1,30),true).strftime('%Z %z') }}|{{ t.localize(d.datetime(2020,10,25,1,30),false).strftime('%Z %z') }}",
    "{% set t=p.timezone('Pacific/Apia') %}{{ t.localize(d.datetime(2011,12,30,12),true) }}|{{ t.localize(d.datetime(2011,12,30,12),false) }}",
    "{% set t=p.timezone('Australia/Lord_Howe') %}{{ t.localize(d.datetime(2020,10,4,2,15),true) }}|{{ t.localize(d.datetime(2020,10,4,2,15),false) }}",
    "{% set t=p.timezone('Asia/Kathmandu') %}{{ t.localize(d.datetime(1800,1,1)) }}|{{ t.localize(d.datetime(1985,1,1)) }}|{{ t.localize(d.datetime(2020,1,1)) }}",
    "{{ p.utc.localize(d.datetime(2020,1,1)) }}|{{ p.FixedOffset(5.5).localize(d.datetime(2020,1,1)).isoformat() }}",
    "{% set t=fromyaml('2020-01-01T12:34:56.123456+05:30') %}{{ t.tzinfo }}|{{ [t.tzinfo] }}|{{ t.utcoffset() }}|{{ t.dst() }}|{{ t.tzname() }}|{{ t.timestamp() }}|{{ t.tzinfo.utcoffset(none) }}|{{ t.tzinfo.dst(none) }}|{{ t.tzinfo.tzname(none) }}",
    "{% set a=fromyaml('2020-01-01T00:00:00+05:30').tzinfo %}{% set b=fromyaml('2020-01-01T00:00:00+05:30').tzinfo %}{{ a is sameas(b) }}|{{ a==b }}|{{ {a:1,b:2}|length }}",

    "{% set t=p.timezone('US/Eastern') %}{% set v=t.localize(d.datetime(2020,11,1,1,30),false) %}{{ t.normalize(v-d.timedelta(minutes=60)).strftime('%Y-%m-%d %H:%M:%S %Z %z') }}",
    "{% set t=p.timezone('US/Eastern') %}{% set v=t.localize(d.datetime(2020,3,8,1,30)) %}{{ t.normalize(v+d.timedelta(hours=2)).strftime('%Y-%m-%d %H:%M:%S %Z %z') }}",
    "{% set t=p.timezone('Asia/Tokyo') %}{{ t.normalize(p.utc.localize(d.datetime(2020,1,1))) }}|{{ p.FixedOffset(-330).normalize(p.utc.localize(d.datetime(2020,1,1))) }}",
    "{% set t=p.timezone('US/Eastern') %}{{ t.fromutc(d.datetime(2020,11,1,6,30,tzinfo=t)).strftime('%Y-%m-%d %H:%M:%S %Z %z') }}",
    "{% set t=p.utc.localize(d.datetime(2020,7,1,12)) %}{{ t.astimezone(p.timezone('US/Eastern')).strftime('%Y-%m-%d %H:%M:%S %Z %z') }}",
    "{% set t=d.datetime(2020,7,1,12,tzinfo=p.timezone('US/Eastern')) %}{{ t.strftime('%Y-%m-%d %H:%M:%S %Z %z') }}|{{ [t.tzinfo] }}",
    "{% set t=p.timezone('US/Eastern').localize(d.datetime(2020,7,1)) %}{{ t.tzinfo.utcoffset(t) }}|{{ t.tzinfo.dst(t) }}|{{ t.tzinfo.tzname(t) }}",
    "{{ p.utc.localize(d.datetime.min) }}|{{ p.timezone('Asia/Tokyo').localize(d.datetime.max) }}",
]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("template", TEMPORAL)
def test_pinned_pytz_temporal_methods(tmp_path, configuration_oracle, request, adapter, template):
    assert_compiled(pair_at(tmp_path, configuration_oracle, request, adapter, template))


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_every_zone_historical_and_current_offsets(tmp_path, configuration_oracle, request, adapter):
    template = """{% for name in p.all_timezones %}{% set zone=p.timezone(name) %}{% for year in [1800,1900,1945,2000,2020,2038] %}{% set v=zone.localize(d.datetime(year,1,15,12)) %}{{ name }}|{{ year }}|{{ v.strftime('%Z %z') }}|{{ v.dst() }}\n{% endfor %}{% endfor %}"""
    assert_compiled(pair_at(tmp_path, configuration_oracle, request, adapter, template))


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_native_strftime_matches_core_platform_and_timezone_directives(tmp_path, configuration_oracle, request, adapter):
    formats = [
        "%a|%A|%b|%B|%c|%d|%H|%I|%j|%m|%M|%p|%S|%U|%w|%W|%x|%X|%y|%Y",
        "%G|%g|%V|%u|%e|%h|%C|%D|%F|%R|%r|%T|%s|%n|%t",
        "%Y|%04Y|%_Y|%-Y|%EY|%OY|%q|%",
        "%f|%z|%:z|%Z|%_z|%_Z|%^Z|%::z|%:::z|%_f",
        "%%f|%%z|%%:z|%%Z|%%%f|%%%z|%%%Z|%%",
        "日付:%Y-%m-%d\x00時刻:%H:%M:%S.%f\x00%z|%Z",
        "", "%z", "%Z", "%:z", "%_Z",
    ]
    encoded_formats = "[" + ",".join(json.dumps(fmt, ensure_ascii=False).replace("\\u0000", "\x00") for fmt in formats) + "]"
    template = """{% for value in [d.datetime(1,1,1),d.datetime(1899,12,31,23,59,59,999999),d.datetime(2021,1,1,16,17,18,123456),d.datetime.max,d.date(2021,1,1),p.utc.localize(d.datetime(2021,1,1,16,17,18,123456)),p.FixedOffset(330).localize(d.datetime(2021,1,1)),p.FixedOffset(5.5000001).localize(d.datetime(2021,1,1)),p.FixedOffset(-5.5000001).localize(d.datetime(2021,1,1)),p.timezone('Europe/Dublin').localize(d.datetime(2021,1,1)),p.timezone('US/Eastern').localize(d.datetime(2021,7,1))] %}{% for format in """ + encoded_formats + """ %}{{ value.strftime(format) }}\n{% endfor %}{% endfor %}"""
    assert_compiled(pair_at(tmp_path, configuration_oracle, request, adapter, template))


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_strftime_native_directives_obey_host_timezone(tmp_path, configuration_oracle, request, adapter, monkeypatch):
    template = """{% for value in [d.datetime(2020,3,8,2,30),d.datetime(2020,11,1,1,30,fold=1),p.utc.localize(d.datetime(2020,1,1)),p.FixedOffset(330).localize(d.datetime(2020,1,1)),p.timezone('Europe/Dublin').localize(d.datetime(2020,1,1)),fromyaml('2020-01-01T00:00:00+05:30')] %}{{ value.strftime('%s|%z|%:z|%Z|%_z|%_Z') }}\n{% endfor %}"""
    try:
        with monkeypatch.context() as clock:
            clock.setenv("TZ", "America/New_York")
            time.tzset()
            assert_compiled(pair_at(tmp_path, configuration_oracle, request, adapter, template))
    finally:
        time.tzset()


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("expression", [
    "d.datetime(2020,1,1).strftime()",
    "d.datetime(2020,1,1).strftime(none)",
    "d.datetime(2020,1,1).strftime('%Y','extra')",
    "d.datetime(2020,1,1).strftime('%Y',format='%m')",
    "d.date(2020,1,1).strftime(pattern='%Y')",
])
def test_strftime_argument_errors_match_core(tmp_path, configuration_oracle, request, adapter, expression):
    pair = pair_at(tmp_path, configuration_oracle, request, adapter, "{{ " + expression + " }}")
    result, reference = pair.invoke("parse", flags=["--no-partial-parse"], success=False)
    assert reference.exception is not None or reference.result is not None
    assert "InvalidOption" not in result.stderr
    assert "Unsupported" not in result.stderr


ERRORS = [
    "p.timezone('Mars/Olympus')", "p.timezone(none)", "p.timezone(false)",
    "p.timezone('São_Paulo')", "p.timezone()", "p.timezone('UTC','extra')",
    "p.timezone(name='UTC')", "p.FixedOffset(1440)", "p.FixedOffset(-1440)",
    "p.FixedOffset('12')", "p.FixedOffset()", "p.FixedOffset(offset=1,extra=2)",
    "p.timezone('America/New_York').localize(d.datetime(2020,11,1,1,30),none)",
    "p.timezone('America/New_York').localize(d.datetime(2020,3,8,2,30),none)",
    "p.timezone('America/New_York').utcoffset(d.datetime(2020,11,1,1,30))",
    "p.timezone('America/New_York').localize(d.datetime(2020,1,1,tzinfo=p.utc))",
    "p.timezone('America/New_York').normalize(d.datetime(2020,1,1))",
    "p.timezone('America/New_York').fromutc(d.datetime(2020,1,1,tzinfo=p.utc))",
    "p.utc.fromutc(d.datetime(2020,1,1,tzinfo=p.FixedOffset(1)))",
    "p.timezone('America/New_York').localize(1)",
    "p.utc.localize(d.datetime(2020,1,1),extra=true)",
    "p.timezone('Asia/Tokyo').localize(d.datetime.min)",
    "p.country_names[1]", "p.country_names.get(1)", "p.country_names.copy()",
    "p.utc.utcoffset()", "p.BaseTzInfo()", "p.BaseTzInfo(1)", "p.UnknownTimeZoneError(extra=1)",
]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("expression", ERRORS)
def test_pytz_errors_are_semantic_failures(tmp_path, configuration_oracle, request, adapter, expression):
    pair = pair_at(tmp_path, configuration_oracle, request, adapter, "{{ " + expression + " }}")
    phase = "compile" if expression == "p.country_names.copy()" else "parse"
    result, reference = pair.invoke(phase, flags=["--no-partial-parse"], success=False)
    assert reference.exception is not None or reference.result is not None
    assert "InvalidOption" not in result.stderr
    assert "Unsupported" not in result.stderr


def test_pinned_pytz_tables_are_reproducible():
    subprocess.run(["python", "scripts/generate_pytz_tables.py", "--check"], cwd=ROOT, check=True)
