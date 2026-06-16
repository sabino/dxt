{{ config(materialized='table') }}

select
    customer_id,
    count(*) as order_count
from {{ ref('customers') }}
group by 1
