{{ config(materialized='table', tags=['parse_time']) }}
select 1 as id
{% if execute %}
union all select * from {{ ref('customers') }}
{% else %}
union all select * from {{ source('raw', 'events') }}
{% endif %}
