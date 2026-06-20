{{ config(materialized='table') }}

select
    customer_id,
    customer_name
from {{ ref('filtered_ephemeral') }}
