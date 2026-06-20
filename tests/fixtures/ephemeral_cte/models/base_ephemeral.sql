{{ config(materialized='ephemeral') }}

select 1 as customer_id, 'Ada' as customer_name
union all
select 2 as customer_id, 'Linus' as customer_name
