"""Public datetime/pytz method identity, hash keys, aliases and descriptor parity."""
from __future__ import annotations

import subprocess
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


METHOD_MACROS = (
    "{% macro method_identity(value) %}{{ return(value) }}{% endmacro %}"
    "{% macro make_method(kind) %}{% set d=modules.datetime %}"
    "{% if kind=='date' %}{{ return(d.date(2024,1,1).isoformat) }}"
    "{% elif kind=='datetime' %}{{ return(d.datetime(2024,1,1).isoformat) }}"
    "{% elif kind=='time' %}{{ return(d.time(12,30).isoformat) }}"
    "{% else %}{{ return(d.timedelta(seconds=1).total_seconds) }}"
    "{% endif %}{% endmacro %}"
)


def pair_at(tmp_path, configuration_oracle, request, adapter, template):
    import pytz
    assert version("dbt-core") == "1.10.5"
    assert version("dbt-duckdb") == "1.9.6"
    assert version("dbt-postgres") == "1.9.1"
    assert version("pytz") == "2026.5"
    assert pytz.OLSON_VERSION == "2026e"
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write("models/marts/rendered.sql", "{% set d=modules.datetime %}{% set p=modules.pytz %}" + template)
    pair.write("macros/method_identity.sql", METHOD_MACROS)
    return pair


# Expected text was observed through actual pinned Core compilation on CPython 3.12.
# Repr cases normalize only process-specific pointer addresses, retaining owner,
# function and receiver text; equality/identity cases perform no normalization.
POSITIVE = [
    pytest.param(
        '{% for cls,value in [(d.date,d.date(2024,1,1)),(d.datetime,d.datetime(2024,1,1)),(d.time,d.time())] %}{% set keys={cls.fromisoformat:1,cls.fromisoformat:2,value.fromisoformat:3} %}{{ keys|length }}:{{ keys.get(cls.fromisoformat) }}:{{ cls.fromisoformat == value.fromisoformat }}|{% endfor %}',
        '1:3:True|1:3:True|1:3:True|',
        id='classmethod_dictionary_repeat',
    ),
    pytest.param(
        "{% set keys={d.date.fromisoformat:'date',d.datetime.fromisoformat:'datetime',d.time.fromisoformat:'time'} %}{{ keys|length }}|{{ keys.get(d.date.fromisoformat) }}|{{ keys.get(d.datetime.fromisoformat) }}|{{ keys.get(d.time.fromisoformat) }}",
        '3|date|datetime|time',
        id='classmethod_distinct_receivers',
    ),
    pytest.param(
        "{% set a=d.date(2024,1,1) %}{% set b=d.date(2024,1,1) %}{% set keys={a.isoformat:1,a.isoformat:2,b.isoformat:3} %}{{ keys|length }}|{{ keys.get(a.isoformat) }}|{{ keys.get(b.isoformat) }}|{{ keys.get(d.date(2024,1,1).isoformat,'new') }}|{{ a==b }}|{{ a.isoformat==b.isoformat }}",
        '2|2|3|new|True|False',
        id='date_method_dictionary_repeat_collision',
    ),
    pytest.param(
        "{% set a=d.time(12,30) %}{% set b=d.time(12,30) %}{% set keys={a.isoformat:1,a.isoformat:2,b.isoformat:3} %}{{ keys|length }}|{{ keys.get(a.isoformat) }}|{{ keys.get(b.isoformat) }}|{{ keys.get(d.time(12,30).isoformat,'new') }}|{{ a==b }}|{{ a.isoformat==b.isoformat }}",
        '2|2|3|new|True|False',
        id='time_method_dictionary_repeat_collision',
    ),
    pytest.param(
        "{% set a=d.timedelta(seconds=1) %}{% set b=d.timedelta(seconds=1) %}{% set keys={a.total_seconds:1,a.total_seconds:2,b.total_seconds:3} %}{{ keys|length }}|{{ keys.get(a.total_seconds) }}|{{ keys.get(b.total_seconds) }}|{{ keys.get(d.timedelta(seconds=1).total_seconds,'new') }}|{{ a==b }}|{{ a.total_seconds==b.total_seconds }}",
        '2|2|3|new|True|False',
        id='timedelta_method_dictionary_repeat_collision',
    ),
    pytest.param(
        '{% set v=d.datetime(2024,1,1,tzinfo=d.tzinfo()) %}{% set keys={v.isoformat:1,v.isoformat:2} %}{{ keys|length }}|{{ keys.get(v.isoformat) }}|{{ v.isoformat == v.isoformat }}|{{ v.isoformat is sameas(v.isoformat) }}',
        '1|2|True|False',
        id='abstract_datetime_method_hash',
    ),
    pytest.param(
        '{% set v=d.tzinfo() %}{% set other=d.tzinfo() %}{% set keys={v.utcoffset:1,v.utcoffset:2,other.utcoffset:3} %}{{ keys|length }}|{{ keys.get(v.utcoffset) }}|{{ v.utcoffset == v.utcoffset }}|{{ v.utcoffset is sameas(v.utcoffset) }}|{{ v.utcoffset == other.utcoffset }}',
        '2|2|True|False|False',
        id='abstract_tzinfo_method_repeat',
    ),
    pytest.param(
        "{% for name in ['strftime','toordinal','weekday','isoweekday','isocalendar'] %}{{ d.date[name] is sameas(d.datetime[name]) }}|{% endfor %}{% for name in ['ctime','isoformat','replace','timetuple'] %}{{ d.date[name] is sameas(d.datetime[name]) }}|{% endfor %}{{ {d.date.strftime:1,d.datetime.strftime:2}|length }}",
        'True|True|True|True|True|False|False|False|False|1',
        id='inherited_descriptor_identity',
    ),
    pytest.param(
        '{% set v=d.date(2024,1,1) %}{% set keys={(v.isoformat,):1,(v.isoformat,):2} %}{{ keys|length }}|{{ keys.get((v.isoformat,)) }}|{{ v.isoformat in keys.keys() }}',
        '1|2|False',
        id='tuple_method_key_repeat',
    ),
    pytest.param(
        '{% set v=d.date(2024,1,1) %}{% set keys={v.isoformat:1,v.ctime:2} %}{{ keys|length }}|{{ keys.get(v.isoformat) }}|{{ keys.get(v.ctime) }}|{{ v.isoformat==v.ctime }}',
        '2|1|2|False',
        id='same_receiver_distinct_method',
    ),
    pytest.param(
        '{% set v=d.date(2024,1,1) %}{% set method=v.isoformat %}{% set alias=method_identity(method) %}{{ alias is sameas(method) }}|{{ alias==v.isoformat }}|{{ {method:1,alias:2,v.isoformat:3}|length }}|{{ alias() }}',
        'True|True|1|2024-01-01',
        id='method_wrapper_alias_macro',
    ),
    pytest.param(
        "{% for original,name in [(d.date(2024,1,1),'isoformat'),(d.datetime(2024,1,1),'isoformat'),(d.time(12,30),'isoformat'),(d.timedelta(seconds=1),'total_seconds')] %}{% set alias=method_identity(original) %}{% set keys={original[name]:17} %}{{ alias is sameas(original) }}|{{ original[name]==alias[name] }}|{{ keys.get(alias[name],'lost') }};{% endfor %}",
        'True|True|17;True|True|17;True|True|17;True|True|17;',
        id='receiver_alias_macro',
    ),
    pytest.param(
        '{% set v=modules.pytz.utc %}{% set method=v.localize %}{% set keys={v.localize:1,v.localize:2} %}{{ keys|length }}|{{ keys.get(v.localize) }}|{{ v.localize==v.localize }}|{{ v.localize is sameas(v.localize) }}|{{ method is sameas(method) }}',
        '1|2|True|False|True',
        id='pytz_python_method_repeat',
    ),
    pytest.param(
        "{% set v=d.datetime.fromisoformat('2024-01-01T00:00:00+01:00').tzinfo %}{% set other=d.datetime.fromisoformat('2024-01-01T00:00:00+01:00').tzinfo %}{% set keys={v.utcoffset:1,v.utcoffset:2,other.utcoffset:3} %}{{ keys|length }}|{{ keys.get(v.utcoffset) }}|{{ v.utcoffset==v.utcoffset }}|{{ v.utcoffset is sameas(v.utcoffset) }}|{{ v.utcoffset==other.utcoffset }}",
        '2|2|True|False|False',
        id='builtin_timezone_method_repeat',
    ),
    pytest.param(
        "{% for kind in ['date','datetime','time','timedelta'] %}{% set first=make_method(kind) %}{% set second=make_method(kind) %}{{ first==second }}|{{ first is sameas(second) }}|{{ {first:1,second:2}|length }};{% endfor %}",
        'False|False|2;False|False|2;False|False|2;False|False|2;',
        id='macro_distinct_retained_method_receivers',
    ),
    pytest.param(
        '{% set value=d.tzinfo() %}{% set alias=method_identity(value) %}{% set method=value.utcoffset %}{% set method_alias=method_identity(method) %}{{ alias is sameas(value) }}|{{ value.utcoffset == alias.utcoffset }}|{{ value.utcoffset is sameas(alias.utcoffset) }}|{{ method_alias is sameas(method) }}|{{ {method:1,method_alias:2,alias.utcoffset:3}|length }}',
        'True|True|False|True|1',
        id='abstract_tzinfo_method_alias_macro',
    ),
    pytest.param(
        "{% set descriptor=d.date.isoformat %}{% set holder={'__dxt_timezone_builtin':true,'method':descriptor} %}{{ holder.method is sameas(descriptor) }}|{{ holder.method==holder['method'] }}|{{ holder.method(d.date(2024,1,1)) }}",
        'True|True|2024-01-01',
        id='authored_mapping_method_alias',
    ),
    pytest.param(
        "{% for cls,names in [(d.date,['ctime','isoformat','replace','strftime','timetuple','toordinal','weekday','isoweekday','isocalendar']),(d.datetime,['ctime','isoformat','replace','strftime','timetuple','toordinal','weekday','isoweekday','isocalendar','astimezone','date','dst','time','timestamp','timetz','tzname','utcoffset','utctimetuple']),(d.time,['dst','isoformat','replace','strftime','tzname','utcoffset']),(d.timedelta,['total_seconds']),(d.tzinfo,['utcoffset','dst','tzname','fromutc'])] %}{% for name in names %}{{ cls[name] }}|{% endfor %}{% endfor %}",
        "<method 'ctime' of 'datetime.date' objects>|<method 'isoformat' of 'datetime.date' objects>|<method 'replace' of 'datetime.date' objects>|<method 'strftime' of 'datetime.date' objects>|<method 'timetuple' of 'datetime.date' objects>|<method 'toordinal' of 'datetime.date' objects>|<method 'weekday' of 'datetime.date' objects>|<method 'isoweekday' of 'datetime.date' objects>|<method 'isocalendar' of 'datetime.date' objects>|<method 'ctime' of 'datetime.datetime' objects>|<method 'isoformat' of 'datetime.datetime' objects>|<method 'replace' of 'datetime.datetime' objects>|<method 'strftime' of 'datetime.date' objects>|<method 'timetuple' of 'datetime.datetime' objects>|<method 'toordinal' of 'datetime.date' objects>|<method 'weekday' of 'datetime.date' objects>|<method 'isoweekday' of 'datetime.date' objects>|<method 'isocalendar' of 'datetime.date' objects>|<method 'astimezone' of 'datetime.datetime' objects>|<method 'date' of 'datetime.datetime' objects>|<method 'dst' of 'datetime.datetime' objects>|<method 'time' of 'datetime.datetime' objects>|<method 'timestamp' of 'datetime.datetime' objects>|<method 'timetz' of 'datetime.datetime' objects>|<method 'tzname' of 'datetime.datetime' objects>|<method 'utcoffset' of 'datetime.datetime' objects>|<method 'utctimetuple' of 'datetime.datetime' objects>|<method 'dst' of 'datetime.time' objects>|<method 'isoformat' of 'datetime.time' objects>|<method 'replace' of 'datetime.time' objects>|<method 'strftime' of 'datetime.time' objects>|<method 'tzname' of 'datetime.time' objects>|<method 'utcoffset' of 'datetime.time' objects>|<method 'total_seconds' of 'datetime.timedelta' objects>|<method 'utcoffset' of 'datetime.tzinfo' objects>|<method 'dst' of 'datetime.tzinfo' objects>|<method 'tzname' of 'datetime.tzinfo' objects>|<method 'fromutc' of 'datetime.tzinfo' objects>|",
        id='public_method_descriptor_repr',
    ),
    pytest.param(
        "{% for cls,name in [(d.date,'fromordinal'),(d.datetime,'fromisoformat'),(d.time,'fromisoformat')] %}{{ modules.re.sub('0x[0-9a-fA-F]+','0xADDR',cls[name]|string) }}|{% endfor %}",
        '<built-in method fromordinal of type object at 0xADDR>|<built-in method fromisoformat of type object at 0xADDR>|<built-in method fromisoformat of type object at 0xADDR>|',
        id='classmethod_bound_repr',
    ),
    pytest.param(
        "{% for value,name in [(d.date(2024,1,1),'isoformat'),(d.datetime(2024,1,1),'isoformat'),(d.time(12,30),'isoformat'),(d.timedelta(seconds=1),'total_seconds'),(d.tzinfo(),'utcoffset'),(d.datetime.fromisoformat('2024-01-01T00:00:00+01:00').tzinfo,'utcoffset')] %}{{ modules.re.sub('0x[0-9a-fA-F]+','0xADDR',value[name]|string) }}|{% endfor %}",
        '<built-in method isoformat of datetime.date object at 0xADDR>|<built-in method isoformat of datetime.datetime object at 0xADDR>|<built-in method isoformat of datetime.time object at 0xADDR>|<built-in method total_seconds of datetime.timedelta object at 0xADDR>|<built-in method utcoffset of datetime.tzinfo object at 0xADDR>|<built-in method utcoffset of datetime.timezone object at 0xADDR>|',
        id='builtin_instance_method_repr',
    ),
    pytest.param(
        "{% for zone in [p.utc,p.FixedOffset(60),p.timezone('GMT'),p.timezone('America/New_York')] %}{% for name in ['localize','normalize','utcoffset','dst','tzname','fromutc'] %}{{ modules.re.sub('0x[0-9a-fA-F]+','0xADDR',zone[name]|string) }}|{% endfor %}{% endfor %}",
        "<bound method UTC.localize of <UTC>>|<bound method UTC.normalize of <UTC>>|<bound method UTC.utcoffset of <UTC>>|<bound method UTC.dst of <UTC>>|<bound method UTC.tzname of <UTC>>|<bound method UTC.fromutc of <UTC>>|<bound method _FixedOffset.localize of pytz.FixedOffset(60)>|<bound method _FixedOffset.normalize of pytz.FixedOffset(60)>|<bound method _FixedOffset.utcoffset of pytz.FixedOffset(60)>|<bound method _FixedOffset.dst of pytz.FixedOffset(60)>|<bound method _FixedOffset.tzname of pytz.FixedOffset(60)>|<built-in method fromutc of _FixedOffset object at 0xADDR>|<bound method StaticTzInfo.localize of <StaticTzInfo 'GMT'>>|<bound method StaticTzInfo.normalize of <StaticTzInfo 'GMT'>>|<bound method StaticTzInfo.utcoffset of <StaticTzInfo 'GMT'>>|<bound method StaticTzInfo.dst of <StaticTzInfo 'GMT'>>|<bound method StaticTzInfo.tzname of <StaticTzInfo 'GMT'>>|<bound method StaticTzInfo.fromutc of <StaticTzInfo 'GMT'>>|<bound method DstTzInfo.localize of <DstTzInfo 'America/New_York' LMT-1 day, 19:04:00 STD>>|<bound method DstTzInfo.normalize of <DstTzInfo 'America/New_York' LMT-1 day, 19:04:00 STD>>|<bound method DstTzInfo.utcoffset of <DstTzInfo 'America/New_York' LMT-1 day, 19:04:00 STD>>|<bound method DstTzInfo.dst of <DstTzInfo 'America/New_York' LMT-1 day, 19:04:00 STD>>|<bound method DstTzInfo.tzname of <DstTzInfo 'America/New_York' LMT-1 day, 19:04:00 STD>>|<bound method DstTzInfo.fromutc of <DstTzInfo 'America/New_York' LMT-1 day, 19:04:00 STD>>|",
        id='pytz_python_method_repr',
    ),
]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("template, expected_text", POSITIVE)
def test_temporal_method_objects(tmp_path, configuration_oracle, request, adapter, template, expected_text):
    pair = pair_at(tmp_path, configuration_oracle, request, adapter, template)
    actual, reference = [
        manifest["nodes"]["model.configuration_fixture.rendered"]["compiled_code"]
        for manifest in pair.invoke(flags=["--no-partial-parse"])
    ]
    assert reference == expected_text
    assert actual == reference


# Authored metadata must preserve an ordinary unbound date method descriptor,
# including its genuine receiver type error; it must not turn it into a zone method.
NEGATIVE = [
    pytest.param(
        "{% set descriptor=d.date.isoformat %}{% set holder={'__dxt_timezone_builtin':true,'method':descriptor} %}{{ holder.method(d.time()) }}",
        id='authored_mapping_descriptor_wrong_receiver',
    ),
]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("template", NEGATIVE)
def test_temporal_descriptor_invalid_receiver(tmp_path, configuration_oracle, request, adapter, template):
    pair = pair_at(tmp_path, configuration_oracle, request, adapter, template)
    result, reference = pair.invoke("parse", flags=["--no-partial-parse"], success=False)
    assert "descriptor 'isoformat'" in str(reference.exception)
    assert "datetime.time" in str(reference.exception)
    assert "Unsupported" not in result.stdout + result.stderr
    assert "InvalidOption" not in result.stdout + result.stderr
