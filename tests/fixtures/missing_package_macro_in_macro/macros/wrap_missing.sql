{% macro wrap_missing(column_name) %}
    {{ util_pkg.missing_id(column_name) }}
{% endmacro %}
