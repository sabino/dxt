"""Public Python datetime APIs against pinned Core on both native adapters.

The original cases retain all 46 independent Core review probes, including
semantic errors. Extra cases exercise inherited APIs and public descriptors.
"""
from __future__ import annotations

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


@pytest.fixture(autouse=True)
def utc_clock(monkeypatch):
    try:
        with monkeypatch.context() as clock:
            clock.setenv("TZ", "UTC")
            time.tzset()
            yield
    finally:
        time.tzset()


def pair_at(tmp_path, configuration_oracle, request, adapter, template):
    import pytz
    assert version("dbt-core") == "1.10.5"
    assert version("dbt-duckdb") == "1.9.6"
    assert version("dbt-postgres") == "1.9.1"
    assert version("pytz") == "2026.5"
    assert pytz.OLSON_VERSION == "2026e"
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write("models/marts/rendered.sql", "{% set d=modules.datetime %}" + template)
    return pair


POSITIVE = [
    pytest.param('{% set z=d.tzinfo() %}{{ d.datetime(2024,1,1,tzinfo=z)-d.datetime(2024,1,1,tzinfo=z) }}', id='abstract_sub_same'),
    pytest.param('{{ d.datetime(2024,1,1).replace(fold=true).fold }}', id='fold_bool'),
    pytest.param('{{ d.date(2024,1,1).fromordinal(1) }}', id='instance_date_classmethod'),
    pytest.param('{{ d.datetime(2024,1,1).fromordinal(1) }}', id='instance_datetime_classmethod'),
    pytest.param('{{ d.datetime(2024,1,1).min is sameas d.datetime.min }}', id='instance_datetime_extrema_identity'),
    pytest.param("{{ d.time().fromisoformat('12:30') }}", id='instance_time_classmethod'),
    pytest.param('{{ d.timedelta().max }}', id='instance_timedelta_extrema'),
    pytest.param("{{ d.time(1,tzinfo=modules.pytz.timezone('America/New_York'))==d.time(1) }}|{{ d.time(1,tzinfo=modules.pytz.timezone('America/New_York'))<d.time(2) }}", id='time_none_offset_comparison'),
    pytest.param('{{ d.tzinfo(1,x=2) is defined }}', id='tzinfo_args'),
    pytest.param('{{ d.date.ctime(d.date(2024,1,1)) }}', id='unbound_date_ctime'),
    pytest.param('{{ d.datetime.isoformat(d.datetime(2024,1,1)) }}', id='unbound_datetime_isoformat'),
    pytest.param('{{ d.timedelta.total_seconds(d.timedelta(seconds=2)) }}', id='unbound_timedelta_total_seconds'),
    pytest.param("{{ d.time(tzinfo=d.tzinfo()).strftime('%H %f %%z %_z') }}", id='abstract_time_strftime_fraction'),
    pytest.param("{{ d.time(tzinfo=d.tzinfo()).strftime('literal') }}", id='abstract_time_strftime_literal'),
    pytest.param('{% set v=d.datetime(2024,1,1,tzinfo=modules.pytz.utc) %}{{ v.astimezone(modules.pytz.utc) is sameas v }}', id='astimezone_self_identity'),
    pytest.param('{{ d.datetime.min.replace(tzinfo=modules.pytz.utc).timestamp() }}', id='aware_min_timestamp'),
    pytest.param("{{ '{:%Y-%m-%d}'.format(d.date(2024,1,1)) }}", id='date_format'),
    pytest.param('{{ d.date.fromtimestamp(-62135596800) }}', id='date_min_fromtimestamp'),
    pytest.param('{{ d.date.fromtimestamp(-0.0000001) }}', id='date_negative_fraction'),
    pytest.param('{{ d.date.fromtimestamp(86399.9999999) }}', id='date_positive_day_boundary'),
    pytest.param("{{ '{:%Y-%m-%d}'.format(d.datetime(2024,1,1)) }}", id='datetime_format'),
    pytest.param("{{ '{:%H:%M}'.format(d.time(12,30)) }}", id='time_format'),
    pytest.param('{% set t=d.datetime(2024,1,1).timetuple() %}{{ t.n_fields }}|{{ t.n_sequence_fields }}|{{ t.n_unnamed_fields }}', id='tuple_constants'),
    pytest.param('{% for year,micro in [(1,4),(2500,1),(9999,16)] %}{{ d.datetime(year,1,1,microsecond=micro,tzinfo=modules.pytz.utc).timestamp() }}|{% endfor %}', id='aware_timestamp_large'),
    pytest.param("{% set v=d.datetime(2024,1,1,12,34,56,123,tzinfo=modules.pytz.utc,fold=1) %}{{ d.date.isoformat(v) }}|{{ d.date.ctime(v) }}|{{ d.date.timetuple(v) }}|{{ d.date.strftime(v,'%H:%M:%S.%f %z %Z') }}|{% set r=d.date.replace(v,year=2023) %}{{ r }}|{{ r.hour is defined }}|{{ r.tzinfo }}|{{ r.fold }}", id='base_date_descriptors'),
    pytest.param('{{ d.datetime.year is defined }}|{{ d.date.month is defined }}|{{ d.time.fold is defined }}|{{ d.timedelta.days is defined }}', id='class_data_descriptors'),
    pytest.param('{{ d.timedelta(days=999999999).total_seconds() }}|{{ d.timedelta(days=-999999999).total_seconds() }}|{{ d.timedelta(days=1000000,microseconds=8).total_seconds() }}', id='duration_total_large'),
    pytest.param("{{ d.datetime.fromisoformat('2024-W01-12:30') }}", id='iso_week_dash_separator'),
    pytest.param("{% for text in ['2024W01112:30','2024W01012:30','2024W01912:30'] %}{{ d.datetime.fromisoformat(text) }}|{% endfor %}", id='iso_week_numeric_separator'),
    pytest.param("{{ d.time(12,30).strftime(format='%H:%M') }}|{{ d.datetime(2024,1,1).strftime(format='%Y') }}|{{ d.date(2024,1,1).strftime(format='%Y') }}", id='strftime_keyword'),
    pytest.param('{% set z=d.tzinfo() %}{% set v=d.datetime(2024,1,1,tzinfo=z) %}{{ v.astimezone(z) is sameas v }}', id='abstract_astimezone_self'),
    pytest.param("{% for cls,value in [(d.date,d.date(2024,1,1)),(d.datetime,d.datetime(2024,1,1)),(d.time,d.time()),(d.timedelta,d.timedelta())] %}{% for member in ['min','max','resolution'] %}{{ value[member] is sameas(cls[member]) }}:{{ value[member] }}|{% endfor %}{% endfor %}", id='instance_class_extrema'),
    pytest.param("{% set value=d.date(2024,1,1) %}{% set ordinal=value.fromordinal %}{% set iso=value.fromisoformat %}{% set calendar=value.fromisocalendar %}{{ ordinal(1) }}|{{ iso('2024-W01-1') }}|{{ calendar(2020,53,7) }}", id='captured_date_classmethods'),
    pytest.param("{% set value=d.datetime(2024,1,1) %}{% set ordinal=value.fromordinal %}{% set iso=value.fromisoformat %}{% set calendar=value.fromisocalendar %}{% set combine=value.combine %}{% set parse=value.strptime %}{{ ordinal(1) }}|{{ iso('2024-W01-12:30') }}|{{ calendar(2020,53,7) }}|{{ combine(d.date(2024,1,1),d.time(12,30)) }}|{{ parse('2024-01-01','%Y-%m-%d') }}", id='captured_datetime_classmethods'),
    pytest.param("{% set value=d.time() %}{% set iso=value.fromisoformat %}{{ iso('12:34:56.123456+01:02:03') }}", id='captured_time_classmethod'),
    pytest.param("{% set real=modules %}{% set value=d.datetime(2024,1,1) %}{% set modules={'datetime':{'datetime':{'min':'authored'}}} %}{{ value.min is sameas(real.datetime.datetime.min) }}|{{ value.fromordinal(1) }}|{{ modules.datetime.datetime.min }}", id='intrinsic_instance_class_shadow'),
    pytest.param('{{ d.date.year }}|{{ d.datetime.year }}|{{ d.datetime.month }}|{{ d.datetime.day }}|{{ d.datetime.fold }}|{{ d.datetime.tzinfo }}|{{ d.time.hour }}|{{ d.time.fold }}|{{ d.timedelta.days }}|{{ d.timedelta.seconds }}|{{ d.timedelta.microseconds }}', id='class_descriptor_rendering'),
    pytest.param('{% set value=d.date(2024,1,1) %}{% set alias=value.fromordinal %}{{ value.fromordinal is sameas(value.fromordinal) }}|{{ d.date.fromordinal is sameas(d.date.fromordinal) }}|{{ value.fromordinal == value.fromordinal }}|{{ alias is sameas(alias) }}|{{ alias(1) }}', id='class_method_wrapper_identity'),
    pytest.param('{% for value in [d.date(2024,1,1),d.datetime(2024,1,1),d.datetime(2024,1,1,tzinfo=modules.pytz.utc)] %}{% set t=value.timetuple() %}{{ t.n_fields }}|{{ t.n_sequence_fields }}|{{ t.n_unnamed_fields }}|{{ t.tm_zone }}|{{ t.tm_gmtoff }};{% endfor %}', id='struct_time_all_public_constants'),
    pytest.param('{% for zone in [modules.pytz.utc,modules.pytz.FixedOffset(60),d.datetime.fromisoformat("2024-01-01T00:00:00+01:00").tzinfo] %}{% set value=d.datetime(2024,1,1,tzinfo=zone) %}{{ value.astimezone(zone) is sameas(value) }}|{% endfor %}', id='astimezone_same_zone_variants'),
    pytest.param('{% for stamp in [-86400.0000001,-86399.9999999,-0.0000001,0.0000001,86399.9999999,86400.0000001] %}{{ d.date.fromtimestamp(stamp) }}|{% endfor %}', id='date_timestamp_fractional_boundaries'),
]


NEGATIVE = [
    pytest.param('{% set v=d.datetime(2024,1,1,tzinfo=d.tzinfo()) %}{{ {v:1}|length }}', id='abstract_hash'),
    pytest.param('{{ d.datetime(2024,1,1,tzinfo=d.tzinfo())-d.datetime(2024,1,1,tzinfo=d.tzinfo()) }}', id='abstract_sub_distinct'),
    pytest.param('{% set z=d.tzinfo() %}{{ d.datetime(2024,1,1,tzinfo=z)-d.datetime(2024,1,1) }}', id='abstract_sub_naive'),
    pytest.param('{{ d.datetime(2024,1,1,tzinfo=d.tzinfo()) in [d.datetime(2024,1,1)] }}', id='abstract_datetime_membership'),
    pytest.param('{{ d.datetime(2024,1,1,tzinfo=d.tzinfo())<d.datetime(2024,1,2) }}', id='abstract_datetime_order'),
    pytest.param('{{ d.time(tzinfo=d.tzinfo()) in [d.time()] }}', id='abstract_time_membership'),
    pytest.param("{{ d.time(tzinfo=d.tzinfo()).strftime('%z') }}", id='abstract_time_strftime_zone'),
    pytest.param('{{ d.datetime.fromtimestamp(-62135596800) }}', id='naive_min_fromtimestamp'),
    pytest.param('{{ d.datetime.min.timestamp() }}', id='naive_min_timestamp'),
    pytest.param("{{ modules.pytz.timezone('America/New_York').fromutc(d.datetime(2024,1,1,tzinfo=d.tzinfo())) }}", id='abstract_pytz_ny_fromutc'),
    pytest.param("{{ modules.pytz.timezone('America/New_York').localize(d.datetime(2024,1,1,tzinfo=d.tzinfo())) }}", id='abstract_pytz_ny_localize'),
    pytest.param("{{ modules.pytz.timezone('America/New_York').utcoffset(d.datetime(2024,1,1,tzinfo=d.tzinfo())) }}", id='abstract_pytz_ny_utcoffset'),
    pytest.param('{{ modules.pytz.utc.fromutc(d.datetime(2024,1,1,tzinfo=d.tzinfo())) }}', id='abstract_pytz_utc_fromutc'),
    pytest.param('{{ modules.pytz.utc.localize(d.datetime(2024,1,1,tzinfo=d.tzinfo())) }}', id='abstract_pytz_utc_localize'),
    pytest.param('{{ d.datetime.isoformat(d.date(2024,1,1)) }}', id='datetime_descriptor_wrong_receiver'),
    pytest.param('{{ d.date.isoformat(d.time()) }}', id='date_descriptor_time_receiver'),
    pytest.param('{{ d.time.isoformat(d.date(2024,1,1)) }}', id='time_descriptor_date_receiver'),
    pytest.param('{{ d.timedelta.total_seconds(d.datetime(2024,1,1)) }}', id='duration_descriptor_datetime_receiver'),
]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("template", POSITIVE)
def test_public_datetime_apis(tmp_path, configuration_oracle, request, adapter, template):
    pair = pair_at(tmp_path, configuration_oracle, request, adapter, template)
    actual, expected = [
        manifest["nodes"]["model.configuration_fixture.rendered"]["compiled_code"]
        for manifest in pair.invoke(flags=["--no-partial-parse"])
    ]
    assert actual == expected


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("template", NEGATIVE)
def test_public_datetime_errors(tmp_path, configuration_oracle, request, adapter, template):
    pair = pair_at(tmp_path, configuration_oracle, request, adapter, template)
    result, reference = pair.invoke("parse", flags=["--no-partial-parse"], success=False)
    assert reference.exception is not None or reference.result is not None
    assert "InvalidOption" not in result.stderr
    assert "Unsupported" not in result.stderr


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_macro_datetime_provider_identity_ignores_model_shadow(
    tmp_path, configuration_oracle, request, adapter,
):
    pair = pair_at(tmp_path, configuration_oracle, request, adapter, """
{% set real=modules %}
{% set modules={'datetime':{'datetime':{'min':'authored'}}} %}
{{ cached_datetime_identity(real.datetime.datetime.min) }}|{{ modules.datetime.datetime.min }}
""")
    pair.write("macros/identity.sql", """{% macro cached_datetime_identity(minimum) -%}
{{ minimum is sameas(modules.datetime.datetime.min) }}|{{ modules.datetime.datetime.fromordinal(1) }}
{%- endmacro %}""")
    actual, expected = [
        manifest["nodes"]["model.configuration_fixture.rendered"]["compiled_code"]
        for manifest in pair.invoke(flags=["--no-partial-parse"])
    ]
    assert actual == expected
