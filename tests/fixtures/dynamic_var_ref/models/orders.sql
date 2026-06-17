select *
from {{ ref(var('customer_model', 'customers')) }}
