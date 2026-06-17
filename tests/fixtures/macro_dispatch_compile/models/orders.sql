select
    1 as order_id,
    {{ cents_to_dollars('subtotal') }} as subtotal
from (
    select 1250 as subtotal
) as source_orders
