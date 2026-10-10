"""Stock statement and empty-result Agate shapes match pinned Core."""
import pytest

from test_cli import build_dxt  # noqa: F401
from test_usability_configuration import configuration_oracle, configuration_postgres  # noqa: F401
from test_usability_resource_hooks import setup_pair


@pytest.mark.parametrize("adapter", ["duckdb", "postgres"])
@pytest.mark.parametrize("kind", ["statement_matrix", "empty_result"])
def test_agate_result_matrix_and_empty_column_name_shapes(
    tmp_path, configuration_oracle, request, adapter, kind
):
    pair = setup_pair(tmp_path, configuration_oracle, request, adapter)
    if kind == "statement_matrix":
        body = """{% call statement('main', fetch_result=true, auto_begin=false) %}
select 'alpha' as first_label, 'beta' as second_label, true as flag
{% endcall %}
{% set result = load_result('main') %}
{{ result.data|string }}:{{ [result.data == [result.data[0]], result.data[0] == ('alpha', 'beta', true), result.data[0] != ['alpha', 'beta', true], result.data is sequence, result.data[0] is sequence, result.table.column_names == ('first_label', 'second_label', 'flag')] }}"""
        expected = "[('alpha', 'beta', True)]:[True, True, True, True, True, True]"
    else:
        body = """{% do store_result('main', response={}) %}
{% set result = load_result('main') %}
{{ result.table.column_names|string }}:{{ [result.table.column_names == (), result.table.column_names != [], result.data == [], result.table.rows|length == 0, result.table.columns|length == 0] }}"""
        expected = "():[True, True, True, True, True]"
    pair.write(
        "models/marts/rendered.sql",
        "{% if execute %}{% set rendered %}" + body
        + "{% endset %}select '{{ rendered|trim }}' as value"
        + "{% else %}select 'parse' as value{% endif %}",
    )
    actual, reference = [
        manifest["nodes"]["model.configuration_fixture.rendered"]
        for manifest in pair.invoke("compile")
    ]
    assert reference["compiled_code"].strip() == "select '" + expected + "' as value"
    assert actual["compiled_code"] == reference["compiled_code"]
