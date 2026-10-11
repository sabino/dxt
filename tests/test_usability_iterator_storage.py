"""Lazy generator state stays valid while live and retained loop aliases mutate."""
import pytest

from test_cli import build_dxt  # noqa: F401
from test_usability_configuration import configuration_oracle, configuration_postgres  # noqa: F401
from test_usability_resource_hooks import setup_pair


CASES = [
    (
        'seed_batch_bindings',
        "{% set bindings=[] %}{% for chunk in [(1,2,3),(4,5,6)]|batch(1000) %}"
        "{% for row in chunk %}{% do bindings.extend(row) %}{% endfor %}{% endfor %}"
        "select '{{ bindings|join(',') }}' as value",
        "select '1,2,3,4,5,6' as value",
    ),
    (
        'batch_growth_retained_loop',
        "{% set saved=namespace(loop=none) %}{% set seen=[] %}"
        "{% for chunk in range(35)|batch(19) %}{% set saved.loop=loop %}"
        "{% for row in chunk %}{% do seen.append(row) %}{% endfor %}{% endfor %}"
        "{% do seen.append(35) %}select '{{ seen|length }}:{{ saved.loop.length }}:{{ saved.loop.index }}' as value",
        "select '36:2:2' as value",
    ),
    (
        'unique_growth_retained_loop',
        "{% set saved=namespace(loop=none) %}{% set seen=[] %}"
        "{% for row in range(35)|unique %}{% set saved.loop=loop %}{% do seen.append(row) %}{% endfor %}"
        "{% do seen.append(35) %}select '{{ seen|length }}:{{ saved.loop.length }}:{{ saved.loop.index }}' as value",
        "select '36:35:35' as value",
    ),
    (
        'batch_break_retained_lazy_loop',
        "{% set saved=namespace(loop=none) %}{% set seen=[] %}"
        "{% for chunk in range(35)|batch(19) %}{% set saved.loop=loop %}{% break %}{% endfor %}"
        "{% do seen.extend([1,2]) %}select '{{ saved.loop.length }}:{{ saved.loop.index }}:{{ saved.loop.last }}' as value",
        "select '2:1:False' as value",
    ),
]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('scenario, template, compiled', CASES, ids=[case[0] for case in CASES])
def test_generator_capacity_and_saved_loop_survive_alias_publication(
    tmp_path, configuration_oracle, request, adapter, scenario, template, compiled
):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    pair.write('models/marts/rendered.sql', template)
    actual, reference = pair.invoke('compile')
    actual_node = actual['nodes']['model.configuration_fixture.rendered']
    reference_node = reference['nodes'][actual_node['unique_id']]
    assert reference_node['compiled_code'] == compiled
    assert actual_node['compiled_code'] == reference_node['compiled_code']
    assert actual_node['depends_on'] == reference_node['depends_on']
