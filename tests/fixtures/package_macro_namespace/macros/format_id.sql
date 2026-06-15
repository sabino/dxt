{% macro format_id(column_name) %}
    cast({{ column_name }} as integer)
{% endmacro %}
