select customer_id, product_id
from {{ ref("customers") }}
cross join {{ ref("stg_products") }}
