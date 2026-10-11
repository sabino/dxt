"""Restricted module singleton exports survive aliases and macro frames."""
import pytest

from test_cli import build_dxt
from test_usability_configuration import ConfigurationPair, configuration_oracle, configuration_postgres, configure_adapter


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('template', [
    "{% set countries=modules.pytz.country_timezones %}select '{{ countries is sameas modules.pytz.country_timezones }}|{{ same_module(countries) }}|{{ modules.datetime.datetime.max is sameas modules.datetime.datetime.max }}' as value",
    "{% set provider=modules %}{% set zones=provider.pytz.all_timezones %}select '{{ zones is sameas modules.pytz.all_timezones }}|{{ provider.re.RegexFlag is sameas modules.re.RegexFlag }}' as value",
    "{% set local='model-only' %}select '{{ read_globals() }}|{{ local }}' as value",
    "{% set values=[] %}{% set alias=values %}{% do append_one(values) %}select '{{ values }}|{{ alias }}' as value",
    "{% set original=modules %}{% set modules={'value':'shadow'} %}select '{{ modules.value }}|{{ original.pytz.country_timezones is sameas same_countries() }}' as value",
])
def test_native_module_singleton_identity_and_lexical_shadowing(tmp_path, configuration_oracle, request, adapter, template):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write('macros/module.sql', "{% macro same_module(value) %}{{ value is sameas modules.pytz.country_timezones }}{% endmacro %}{% macro same_countries() %}{{ return(modules.pytz.country_timezones) }}{% endmacro %}{% macro read_globals(value=local|default('global')) %}{{ value }}{% endmacro %}{% macro append_one(value) %}{% do value.append(1) %}{% endmacro %}")
    pair.write('models/marts/rendered.sql', template)
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.rendered']['compiled_code'] == expected['nodes']['model.configuration_fixture.rendered']['compiled_code']
