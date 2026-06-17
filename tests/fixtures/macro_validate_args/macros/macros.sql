{% macro plain_macro(column_name, optional_suffix='') %}
    cast({{ column_name }} as varchar) || {{ optional_suffix }}
{% endmacro %}

{% macro patched_macro(column_name, quote=false) %}
    cast({{ column_name }} as varchar)
{% endmacro %}

{% macro bad_macro(first_arg, second_arg) %}
    {{ first_arg }} || {{ second_arg }}
{% endmacro %}
