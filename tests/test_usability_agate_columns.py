"""Agate named sequence methods retain public values and Core tuple types."""
import pytest

from test_cli import build_dxt
from test_usability_configuration import ConfigurationPair, configuration_oracle, configuration_postgres, configure_adapter


TEMPLATES = [
    "{% set sql_results={} %}{% for name,column in table.columns.items() %}{% do sql_results.update({name:column.values()}) %}{% endfor %}select '{{ tojson(sql_results) }}' as value",
    "select '{{ table.columns.keys() }}|{{ table.columns[0].values() }}|{{ table.columns.values()|map(attribute='name')|join(',') }}' as value",
    "{% set sql_results={} %}{% for name,value in table.rows[0].items() %}{% do sql_results.update({name:value}) %}{% endfor %}select '{{ tojson(sql_results) }}|{{ table.rows[0].keys() }}|{{ table.rows[0].values() }}' as value",
    "select '{{ table.columns['items'].values() }}|{{ table.columns['values'].values() }}|{{ table.columns.keys()|join(',') }}' as value",
]


@pytest.mark.parametrize('adapter', ['duckdb', 'postgres'])
@pytest.mark.parametrize('template', TEMPLATES)
def test_query_named_columns_items_values_and_dictionary_updates(tmp_path, configuration_oracle, request, adapter, template):
    pair = ConfigurationPair(tmp_path, configuration_oracle)
    configure_adapter(pair, request, adapter)
    query = "select 1 as id, true as items, 'first' as values union all select 2, false, null order by id"
    pair.write('models/marts/rendered.sql', "{% if execute %}{% set table=run_query(\"" + query + "\") %}" + template + "{% else %}select 0{% endif %}")
    actual, expected = pair.invoke('compile')
    assert actual['nodes']['model.configuration_fixture.rendered']['compiled_code'] == expected['nodes']['model.configuration_fixture.rendered']['compiled_code']
