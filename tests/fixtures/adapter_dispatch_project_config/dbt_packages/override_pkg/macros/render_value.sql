{% macro duckdb__render_value(column_name) %}
    override_{{ column_name }}
{% endmacro %}
