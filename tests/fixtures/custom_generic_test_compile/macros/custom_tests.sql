{% test positive_amount(model, column_name) %}
select {{ column_name }}
from {{ model }}
where {{ column_name }} < 0
{% endtest %}

{% data_test nonzero_amount(model, column_name) %}
select {{ column_name }}
from {{ model }}
where {{ column_name }} = 0
{% enddata_test %}
