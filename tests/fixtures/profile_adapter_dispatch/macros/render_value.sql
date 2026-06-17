{% macro duckdb__render_value(column_name) %}
    duckdb_{{ column_name }}
{% endmacro %}

{% macro postgres__render_value(column_name) %}
    postgres_{{ column_name }}
{% endmacro %}

{% macro default__render_value(column_name) %}
    default_{{ column_name }}
{% endmacro %}
