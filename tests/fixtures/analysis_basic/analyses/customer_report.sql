select customer_id
from {{ ref('customers') }}
union all
select payment_id as customer_id
from {{ source('raw', 'payments') }}
