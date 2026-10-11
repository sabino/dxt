"""Native temporal __format__ protocols against unchanged pinned Core."""
import subprocess

import pytest

from test_usability_artifacts import contracts
from test_usability_configuration import (
    ConfigurationPair, configuration_oracle, configuration_postgres, configure_adapter,
)
from test_cli import ROOT


@pytest.fixture(scope="module", autouse=True)
def native_binary():
    subprocess.run(["zig", "build"], cwd=ROOT, check=True)


POSITIVE = [
    "'{:%Y-%m-%d|%H:%M:%S.%f}'.format(modules.datetime.date(2024,2,29))",
    "'{:%a %j %Y-%m-%d %H:%M:%S.%f}'.format(modules.datetime.datetime(2024,2,29,12,34,56,123456))",
    "'{:%Y-%m-%d %H:%M:%S.%f %z %Z}'.format(modules.datetime.time(12,34,56,123456))",
    "'{:%Y-%m-%d %H:%M:%S.%f %z %Z}'.format(modules.pytz.utc.localize(modules.datetime.datetime(2024,2,29,12,34,56,123456)))",
    "'{:%H:%M:%S.%f %z %Z}'.format(modules.datetime.time(12,34,56,123456,tzinfo=modules.pytz.utc))",
    "'{:%H:%M %z %Z}'.format(modules.datetime.time(12,34,tzinfo=modules.pytz.FixedOffset(90)))",
    "'{:%H:%M %z %Z}'.format(modules.datetime.time(12,34,tzinfo=modules.pytz.timezone('America/New_York')))",
    "'{:%Y-%m-%d %H:%M %z %Z}'.format(modules.pytz.timezone('America/New_York').localize(modules.datetime.datetime(2024,7,1,12,34)))",
    "'{value:{spec}}'.format(value=modules.datetime.time(12,34,56),spec='%H:%M:%S')",
    "'{value:{spec}}'.format_map({'value':modules.datetime.date(2024,2,29),'spec':'%Y-%m-%d'})",
    "'{value:%H:%M:%S.%f}'.format_map({'value':modules.datetime.time(12,34,56,123456)})",
    "'{value:%H:%M %z %Z}'.format_map({'value':modules.datetime.time(12,34,tzinfo=modules.pytz.utc)})",
    "'{0:%Y-%m-%d}:{1:%H:%M}'.format(fromyaml('2024-02-29'),fromyaml('2024-02-29T12:34:56Z'))",
    "'{}|{:}|{!s:>20}'.format(modules.datetime.time(1,2,3),modules.datetime.date(2024,2,29),modules.datetime.datetime(2024,2,29,1,2,3))",
    "'{:%Q|%%%Y|literal}'.format(modules.datetime.date(2024,2,29))",
]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("expression", POSITIVE)
def test_native_temporal_format_matches_core(tmp_path, configuration_oracle, request, adapter, expression):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write("models/marts/rendered.sql", "select '{{ " + expression + " }}' as value")
    actual, expected = pair.invoke()
    key = "model.configuration_fixture.rendered"
    assert actual["nodes"][key]["compiled_code"] == expected["nodes"][key]["compiled_code"]
    for project in pair.projects:
        contracts.assert_artifact(project / "target/manifest.json")
        contracts.assert_artifact(project / "target/run_results.json")


NEGATIVE = [
    "'{:%Y}'.format({'strftime':modules.datetime.datetime(2024,2,29).strftime})",
    "'{value:%H}'.format_map({'value':{'strftime':modules.datetime.time(12).strftime}})",
    "'{:%Y}'.format(modules.datetime.timedelta(days=1))",
    "'{:%Y}'.format(modules.pytz.utc)",
    "'{0.__class__.__mro__}'.format(modules.datetime.datetime(2024,2,29))",
    "'{value.__class__.__mro__}'.format_map({'value':modules.datetime.time(12)})",
]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("expression", NEGATIVE)
def test_native_temporal_format_errors_match_core(tmp_path, configuration_oracle, request, adapter, expression):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write("models/marts/rendered.sql", "select '{{ " + expression + " }}' as value")
    pair.invoke(success=False)


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_returned_temporal_aliases_preserve_format_protocol(tmp_path, configuration_oracle, request, adapter):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write("macros/clock.sql", "{% macro clock() %}{{ return(modules.datetime.time(12,34,56,123456,tzinfo=modules.pytz.utc)) }}{% endmacro %}")
    pair.write("models/marts/rendered.sql", "{% set value=clock() %}{% set alias=value %}select '{{ '{:%H:%M:%S.%f %z}'.format(alias) }}|{{ '{value:%H:%M}'.format_map({'value':value}) }}' as value")
    actual, expected = pair.invoke()
    key = "model.configuration_fixture.rendered"
    assert actual["nodes"][key]["compiled_code"] == expected["nodes"][key]["compiled_code"]
