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
