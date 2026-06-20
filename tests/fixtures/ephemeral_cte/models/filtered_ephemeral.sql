{{ config(materialized='ephemeral') }}

select
    customer_id,
    upper(customer_name) as customer_name
from {{ ref('base_ephemeral') }}
where customer_id = 1
