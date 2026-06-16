{% macro root_format_id(column_name) %}
    cast({{ column_name }} as text)
{% endmacro %}
