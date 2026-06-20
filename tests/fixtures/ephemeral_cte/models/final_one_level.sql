{{ config(materialized='view') }}

select
    customer_id
from {{ ref('base_ephemeral') }}
