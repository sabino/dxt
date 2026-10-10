"""Consuming Jinja loops and deferred metadata against actual pinned Core."""
import pytest

from test_cli import build_dxt
from test_usability_configuration import ConfigurationPair, configure_adapter, configuration_oracle, configuration_postgres


MACROS = """{% macro first(stream, metadata='none') %}{% for x in stream %}{% if metadata == 'last' %}{% set ignored = loop.last %}{% elif metadata == 'length' %}{% set ignored = loop.length %}{% endif %}{{ return(x) }}{% endfor %}{{ return('empty') }}{% endmacro %}
{% macro first_filtered(stream, drain=false) %}{% for x in stream if 10/x > 0 %}{% if drain %}{% set ignored = loop.length %}{% endif %}{{ return(x) }}{% endfor %}{{ return('empty') }}{% endmacro %}
"""


POSITIVE = [
    "{% set stream = zip((1,2,3),(4,5,6)) %}select '{{ first(stream) }}|{{ stream|list }}' as value",
    "{% set stream = zip((1,2,3),(4,5,6)) %}select '{{ first(stream, 'last') }}|{{ stream|list }}' as value",
    "{% set stream = zip((1,2,3),(4,5,6)) %}select '{{ first(stream, 'length') }}|{{ stream|list }}' as value",
    "select '{{ first_filtered([1,0]) }}' as value",
    "select '{% for x in zip([1,2],[3,4]) %}{{ loop.index }}:{{ loop.index0 }}:{{ loop.first }}:{{ loop.last }}:{{ loop.length }}:{{ loop.revindex }}:{{ loop.revindex0 }}:{{ loop.depth }}:{{ loop.depth0 }};{% endfor %}' as value",
    "select '{% for x in [1,2,3] %}{{ loop.previtem|default('before') }}:{{ loop.nextitem|default('after') }};{% endfor %}' as value",
    "select '{% for x in [1,1,2,2,1] %}{{ loop.cycle('a','b') }}:{{ loop.changed(x) }}:{{ loop.changed(x) }};{% endfor %}' as value",
    "select '{% for x in zip([1,2],[3,4]) %}{{ [loop][0].length }}:{{ loop['last'] }};{% endfor %}' as value",
    "{% set cutoff=3 %}select '{% for x in [1,2,3] if x<cutoff %}{% set cutoff=0 %}{{ x }}:{{ loop.last }};{% endfor %}' as value",
    "select '{% for x in [1,2] if x>3 %}unexpected{% else %}empty{% endfor %}' as value",
    "{% set stream=zip((1,2,3),(4,5,6)) %}select '{% for x in stream %}{{ x }}{% break %}{% endfor %}|{{ stream|list }}' as value",
    "select '{% for x,y in zip((1,2),(3,4)) %}{{ x+y }}{% if loop.first %}{% continue %}{% endif %}done{% endfor %}' as value",
    "select '{% for x in [1,2] %}{% set outer=loop %}{% for y in [3,4] %}{{ outer.index }}:{{ loop.index }}:{{ loop.last }};{% endfor %}{% endfor %}' as value",
]


@pytest.mark.parametrize("template", POSITIVE)
def test_loops_pull_only_reached_items_and_defer_length_metadata(tmp_path, configuration_oracle, template):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write("macros/first.sql", MACROS)
    pair.write("models/marts/rendered.sql", template)
    actual, expected = pair.invoke()
    assert actual["nodes"]["model.configuration_fixture.rendered"]["compiled_code"] == expected["nodes"]["model.configuration_fixture.rendered"]["compiled_code"]


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
def test_consuming_loop_deferred_errors_and_aliases_on_both_adapters(tmp_path, request, configuration_oracle, adapter):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    pair.write("macros/first.sql", MACROS)
    pair.write("models/marts/rendered.sql", "{% set stream=zip((1,2,3),(4,5,6)) %}select '{{ first(stream) }}|{{ stream|list }}|{{ first_filtered([1,0]) }}' as value")
    actual, expected = pair.invoke()
    assert actual["nodes"]["model.configuration_fixture.rendered"]["compiled_code"] == expected["nodes"]["model.configuration_fixture.rendered"]["compiled_code"]


@pytest.mark.parametrize("template", [
    "select '{{ first_filtered([1,0], true) }}' as value",
    "select '{% for x in [1] %}{{ loop.cycle() }}{% endfor %}' as value",
    "select '{% for x in [1] %}{{ loop.changed(value=x) }}{% endfor %}' as value",
])
def test_requested_loop_metadata_and_invalid_methods_raise_like_core(tmp_path, configuration_oracle, template):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    pair.write("macros/first.sql", MACROS)
    pair.write("models/marts/rendered.sql", template)
    pair.invoke(success=False)
