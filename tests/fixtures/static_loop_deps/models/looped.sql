{% set model_names = ['customers', 'orders'] %}
{% for model_name in model_names %}
select * from {{ ref(model_name) }}
{% endfor %}

{% set table_names = ['events', 'payments'] %}
{% for table_name in table_names %}
union all select * from {{ source('raw', table_name) }}
{% endfor %}
