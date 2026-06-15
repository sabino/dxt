{% macro wrap_external_id(column_name) %}
    {{ util_pkg.format_id(column_name) }}
{% endmacro %}
