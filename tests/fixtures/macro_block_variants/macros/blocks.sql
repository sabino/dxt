{% macro format_id(column_name, optional_suffix='') %}
    cast({{ column_name }} as varchar) || {{ optional_suffix }}
{% endmacro %}

{% test positive_value(model, column_name) %}
    select * from {{ model }} where {{ column_name }} <= 0
{% endtest %}

{% materialization table, default %}
    {{ return({'relations': []}) }}
{% endmaterialization %}

{% materialization incremental %}
    {{ return({'relations': []}) }}
{% endmaterialization %}

{% materialization snapshot, supported_languages=['sql'], adapter='duckdb' %}
    {{ return({'relations': []}) }}
{% endmaterialization %}

{% materialization empty_langs, default, supported_languages=[] %}
    {{ return({'relations': []}) }}
{% endmaterialization %}

{% materialization tuple_langs, supported_languages=('sql',), default %}
    {{ return({'relations': []}) }}
{% endmaterialization %}

{% materialization view, adapter='duckdb', supported_languages=['sql', 'python'] %}
    {{ return({'relations': []}) }}
{% endmaterialization %}
