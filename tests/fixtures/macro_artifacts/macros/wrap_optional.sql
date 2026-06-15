{% macro wrap_optional(column_name, enabled=true) %}
    {% if enabled %}
        coalesce({{ column_name }}, 'unknown')
    {% else %}
        {{ column_name }}
    {% endif %}
{% endmacro %}
