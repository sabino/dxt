{% macro wrap_dispatch(column_name) %}
    {{ adapter.dispatch("render_value")(column_name) }}
    {{ adapter.dispatch("package_value", macro_namespace="util_pkg")(column_name) }}
{% endmacro %}
