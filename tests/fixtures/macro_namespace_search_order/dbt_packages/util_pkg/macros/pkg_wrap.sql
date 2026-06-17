{% macro pkg_wrap(column_name) %}
    {{ same_name(column_name) }}
    {{ root_only(column_name) }}
    {{ shared(column_name) }}
{% endmacro %}
