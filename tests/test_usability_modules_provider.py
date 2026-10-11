"""Native module provider compilation against the pinned Core module context."""
import pytest

from test_cli import build_dxt
from test_usability_configuration import ConfigurationPair, configuration_oracle


@pytest.mark.parametrize('template', [
    "select '{{ modules.datetime.datetime.now().strftime(\"%Y-%m-%d\") }}' as native_clock, '{{ modules.datetime.datetime(2024,1,2,3,4,5).isoformat() }}' as calendar, '{{ modules.re.sub(\"a\",\"b\",\"a\") }}' as regex",
    "{% set m = modules %}{% set calendar = m.datetime.datetime %}select '{{ calendar(2024,1,2,3,4,5).strftime(\"%Y-%m-%d %H:%M:%S\") }}' as value, '{{ m.re.sub(\"a\",\"b\",\"a\") }}' as regex",
])
def test_native_datetime_provider_clock_constructors_aliases_and_module_aggregate(tmp_path, configuration_oracle, template):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write('models/marts/rendered.sql', template)
    actual, reference = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.rendered']['compiled_code'] == reference['nodes']['model.configuration_fixture.rendered']['compiled_code']
