"""Restricted native datetime constructors against actual pinned dbt Core CLI."""
import json
import os
import subprocess
import time
from pathlib import Path

import pytest

from test_usability_configuration import (
    ConfigurationPair, configuration_oracle, configuration_postgres, configure_adapter,
)

ROOT = Path(__file__).resolve().parents[1]

@pytest.fixture(scope='module', autouse=True)
def native_binary():
    subprocess.run(['zig', 'build'], cwd=ROOT, check=True)

POSITIVE = [
    "modules.datetime.date(2024,2,29)",
    "modules.datetime.datetime(year=2024,month=2,day=29,hour=1,microsecond=4,fold=1)",
    "modules.datetime.time()",
    "modules.datetime.time(1,2,3,4,fold=1)",
    "modules.datetime.date.fromordinal(1)",
    "modules.datetime.date.fromordinal(3652059)",
    "modules.datetime.date.fromisoformat('20240229')",
    "modules.datetime.date.fromisoformat('2024-W01')",
    "modules.datetime.datetime.fromisoformat('20240229🐍120405,123456789+05:30:45.678901')",
    "modules.datetime.datetime.fromisoformat('2024-W01-1T12')",
    "modules.datetime.time.fromisoformat('T120405.123456+00:99').isoformat(timespec='milliseconds')",
    "modules.datetime.time.fromisoformat('12:04:05-00:00:99')",
    "modules.datetime.time.fromisoformat('12.123456789+00:00:00.5')",
    "modules.datetime.date.fromisocalendar(2020,53,7)",
    "modules.datetime.datetime.fromisocalendar(year=2020,week=53,day=7)",
    "modules.datetime.datetime.combine(modules.datetime.datetime(2024,2,29,20),modules.datetime.time(1,2,3,tzinfo=modules.pytz.utc,fold=1))",
    "modules.datetime.datetime.combine(modules.datetime.date(2024,2,29),modules.datetime.time(1,tzinfo=modules.pytz.utc),tzinfo=none)",
    "modules.datetime.time(1,tzinfo=modules.pytz.timezone('America/New_York')).utcoffset()",
    "modules.datetime.time(1,tzinfo=modules.pytz.timezone('America/New_York')).tzname()",
    "modules.datetime.time(1,tzinfo=modules.pytz.utc).tzinfo is sameas modules.pytz.utc",
    "modules.datetime.time(1,tzinfo=modules.pytz.FixedOffset(60)) == modules.datetime.time(0,tzinfo=modules.pytz.utc)",
    "[modules.datetime.time(1,2,3,4,tzinfo=modules.pytz.utc,fold=1)]",
    "modules.datetime.time(1,2,3,4,tzinfo=modules.pytz.utc,fold=1).replace(hour=4).strftime('%Y-%m-%d %H:%M:%S.%f %z %Z')",
    "modules.datetime.time(1,2,3,999999).isoformat('milliseconds')",
    "modules.datetime.timedelta(seconds=2.5e-6)",
    "modules.datetime.timedelta(microseconds=3)*0.5",
    "modules.datetime.timedelta(microseconds=5)/2",
    "modules.datetime.timedelta(microseconds=-5)//2",
    "modules.datetime.timedelta(microseconds=-5)%modules.datetime.timedelta(microseconds=2)",
    "modules.datetime.timedelta(microseconds=3)/modules.datetime.timedelta(microseconds=2)",
    "modules.datetime.date(2020,3,1)-modules.datetime.timedelta(microseconds=1)",
    "modules.datetime.datetime(2020,2,28,23,59,59)+modules.datetime.timedelta(seconds=2)",
]

POSITIVE += [
    "modules.datetime.datetime.utcfromtimestamp(0.0000005)",
    "modules.datetime.datetime.utcfromtimestamp(0.0000015)",
    "modules.datetime.datetime.utcfromtimestamp(-0.0000005)",
    "modules.datetime.datetime.utcfromtimestamp(-0.0000015)",
    "modules.datetime.datetime.utcfromtimestamp(1.0000005)",
    "modules.datetime.datetime.utcfromtimestamp(1.0000015)",
    "modules.datetime.date.min.toordinal()",
    "modules.datetime.datetime.max.toordinal()",
    "modules.datetime.date(1,1,1).ctime()",
    "modules.datetime.date(2021,1,1).isocalendar()",
    "modules.datetime.date(2021,1,1).isocalendar() == (2020,53,5)",
    "modules.datetime.date(2021,1,1).isocalendar()['week']",
    "modules.datetime.date(2021,1,1).isocalendar()[::-1]",
    "modules.datetime.date(2021,1,1).isocalendar().count(53)",
    "modules.datetime.date(2021,1,1).isocalendar() + (7,)",
    "modules.datetime.date(2021,1,1).isocalendar() * 2",
    "53 in modules.datetime.date(2021,1,1).isocalendar()",
    "[modules.datetime.date(2021,1,1).isocalendar()]",
    "tojson(modules.datetime.date(2021,1,1).isocalendar())",
    "tojson({'nested':[(modules.datetime.date(2021,1,1).isocalendar(),)]})",
    "{'nested':[(modules.datetime.date(2021,1,1).isocalendar(),)]}|tojson(indent=2)",
    "modules.datetime.date(2021,1,1).isocalendar()|tojson",
    "{modules.datetime.date(2021,1,1).isocalendar():'first',(2020,53,5):'second'}",
    "[modules.datetime.date(2021,1,1).isocalendar(),(2020,53,5)]|unique|list",
    "modules.datetime.date(2024,2,29).timetuple()",
    "modules.datetime.datetime(2024,2,29,1,2,3,tzinfo=modules.pytz.utc).timetuple().tm_zone",
    "modules.datetime.datetime(2024,2,29,1,2,3,tzinfo=modules.pytz.FixedOffset(90)).utctimetuple()",
    "tojson(modules.datetime.date(2024,2,29).timetuple())",
    "modules.datetime.datetime(2024,2,29,1,2,3,4,tzinfo=modules.pytz.utc,fold=1).time()",
    "modules.datetime.datetime(2024,2,29,1,2,3,4,tzinfo=modules.pytz.utc,fold=1).timetz()",
    "modules.datetime.datetime(2024,2,29,1,2,3,4,tzinfo=modules.pytz.utc,fold=1).timetz().fold",
    "modules.datetime.timedelta(days=-1,seconds=1)|abs",
    "(-9007199254740993)|abs",
    "true|abs",
    "(-0.0)|abs",
    "((-1)**0.5)|abs",
]

@pytest.mark.parametrize('expression', POSITIVE)
@pytest.mark.parametrize('adapter', ['duckdb','postgres'])
def test_datetime_constructor_and_method_surface(tmp_path, configuration_oracle, request, adapter, expression):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('models/marts/rendered.sql', "select '{{ " + expression + " }}' as value")
    native, core = pair.invoke()
    key = 'model.configuration_fixture.rendered'
    assert native['nodes'][key]['compiled_code'] == core['nodes'][key]['compiled_code']

NEGATIVE = [
    "modules.datetime.date(2023,2,29)",
    "modules.datetime.date(2024.0,1,1)",
    "modules.datetime.time(24)",
    "modules.datetime.time(1,2,3,4,none,1)",
    "modules.datetime.time(1,tzinfo=1)",
    "modules.datetime.date.fromtimestamp(timestamp=0)",
    "modules.datetime.datetime.utcfromtimestamp(timestamp=0)",
    "modules.datetime.date.fromordinal(ordinal=1)",
    "modules.datetime.date.fromisoformat('2023-W53')",
    "modules.datetime.date.fromisoformat('2024-01-01T00:00')",
    "modules.datetime.time.fromisoformat('12:00+24:00')",
    "modules.datetime.time.fromisoformat('24:00')",
    "modules.datetime.datetime.fromisoformat(1)",
    "modules.datetime.datetime.fromisocalendar(2024,54,1)",
    "modules.datetime.datetime.combine(modules.datetime.date(2024,1,1),none)",
    "modules.datetime.time(1).isoformat('invalid')",
    "modules.datetime.time(1).replace(fold=2)",
    "modules.datetime.time(1).utcoffset(1)",
    "modules.datetime.timedelta.max + modules.datetime.timedelta.resolution",
    "modules.datetime.timedelta(seconds=1)/0",
]

NEGATIVE += [
    "modules.datetime.datetime.fromisoformat('2024-01-01TT12')",
    "dict(modules.datetime.date(2021,1,1).isocalendar())",
    "modules.datetime.datetime(2024,1,1,tzinfo={'__dxt_timezone_offset_us':0})",
    "modules.datetime.tzinfo().utcoffset(none)",
    "modules.datetime.tzinfo().utcoffset(dt=none)",
    "modules.datetime.tzinfo().fromutc(none)",
    "modules.datetime.time(tzinfo=modules.datetime.tzinfo())|string",
    "modules.datetime.time(tzinfo=modules.datetime.tzinfo()).isoformat()",
    "modules.datetime.datetime(2024,1,1,tzinfo=modules.datetime.tzinfo())|string",
    "modules.datetime.datetime(2024,1,1,tzinfo=modules.datetime.tzinfo()).utcoffset()",
    "modules.datetime.datetime(2024,1,1,tzinfo=modules.datetime.tzinfo()).timetuple()",
    "modules.datetime.datetime(2024,1,1,tzinfo=modules.datetime.tzinfo()) == modules.datetime.datetime(2024,1,1)",
    "{(modules.datetime.date(2021,1,1).isocalendar(),[]):1}",
    "{modules.datetime.time(tzinfo=modules.datetime.tzinfo()):1}",
    "{modules.datetime.datetime(2024,1,1,tzinfo=modules.datetime.tzinfo()):1}",
    "tojson({modules.datetime.date(2021,1,1).isocalendar():1})",
    "{modules.datetime.date(2021,1,1).isocalendar():1}|tojson",
    "none|abs",
    "1|abs(1)",
]

@pytest.mark.parametrize('expression', NEGATIVE)
@pytest.mark.parametrize('adapter', ['duckdb','postgres'])
def test_datetime_native_errors_match_core(tmp_path, configuration_oracle, request, adapter, expression):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('models/marts/rendered.sql', "select '{{ " + expression + " }}' as value")
    pair.invoke(success=False)

@pytest.mark.parametrize('zone', ['UTC','America/New_York','Asia/Kathmandu'])
@pytest.mark.parametrize('adapter', ['duckdb','postgres'])
def test_host_local_timestamp_fold_and_precision(tmp_path, configuration_oracle, request, monkeypatch, adapter, zone):
    previous = os.environ.get('TZ')
    monkeypatch.setenv('TZ', zone)
    time.tzset()
    try:
        pair = ConfigurationPair(tmp_path, configuration_oracle)
        configure_adapter(pair, request, adapter)
        pair.write('models/marts/rendered.sql', """select '{{ modules.datetime.datetime.fromtimestamp(1730611800.123456) }}|{{ modules.datetime.datetime.fromtimestamp(1730615400.123456).fold }}|{{ modules.datetime.datetime(2024,11,3,1,30,fold=1).timestamp() }}|{{ modules.datetime.datetime(2024,3,10,2,30).timestamp() }}|{{ modules.datetime.date.fromtimestamp(0) }}' as value""")
        native, core = pair.invoke()
        key = 'model.configuration_fixture.rendered'
        assert native['nodes'][key]['compiled_code'] == core['nodes'][key]['compiled_code']
    finally:
        if previous is None: os.environ.pop('TZ', None)
        else: os.environ['TZ'] = previous
        time.tzset()


@pytest.mark.parametrize('adapter', ['duckdb','postgres'])
def test_abstract_timezones_construct_without_forcing_offset_and_preserve_aliases(tmp_path, configuration_oracle, request, adapter):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('models/marts/rendered.sql', """{% set zone=modules.datetime.tzinfo() %}{% set other=modules.datetime.tzinfo() %}{% set clock=modules.datetime.time(1,tzinfo=zone,fold=1) %}{% set moment=modules.datetime.datetime(2024,1,1,tzinfo=zone) %}select '{{ zone is sameas zone }}|{{ zone == other }}|{{ clock.tzinfo is sameas zone }}|{{ moment.date() }}|{{ moment.time() }}|{{ moment.ctime() }}|{{ clock == clock.replace() }}|{{ modules.re.fullmatch('<datetime.tzinfo object at 0x[0-9a-f]+>',zone|string) is not none }}' as value""")
    native, core = pair.invoke()
    key = 'model.configuration_fixture.rendered'
    assert native['nodes'][key]['compiled_code'] == core['nodes'][key]['compiled_code']

@pytest.mark.parametrize('adapter', ['duckdb','postgres'])
def test_calendar_named_tuple_is_serializable_configuration_value(tmp_path, configuration_oracle, request, adapter):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('models/marts/rendered.sql', "{{ config(meta={'calendar':modules.datetime.date(2021,1,1).isocalendar()}) }}select 1")
    # Core event serialization treats PYTEST_CURRENT_TEST as an instruction to
    # raise on logging protobuf failures. Tuple metadata triggers that testing
    # branch, whose worker exception leaves the queue unfinished. Invoke the
    # unmodified CLI in its ordinary process environment instead.
    actual, expected = pair.projects
    for program, project in ((ROOT / 'zig-out/bin/dxt', actual), ('dbt', expected)):
        command = ([str(program), '--quiet', 'compile', '--no-partial-parse']
                   if program == 'dbt' else [str(program), 'compile'])
        command.extend(['--project-dir', str(project),
                        '--profiles-dir', str(project)])
        environment = os.environ.copy()
        if program == 'dbt':
            environment.pop('PYTEST_CURRENT_TEST', None)
        result = subprocess.run(command, text=True, capture_output=True,
                                cwd=ROOT, env=environment, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
    native, core = [json.loads((project / 'target/manifest.json').read_text())
                    for project in pair.projects]
    key = 'model.configuration_fixture.rendered'
    assert native['nodes'][key]['config']['meta'] == core['nodes'][key]['config']['meta']
    assert native['nodes'][key]['config']['meta']['calendar'] == [2020, 53, 5]
    assert native['nodes'][key]['compiled_code'] == core['nodes'][key]['compiled_code']
