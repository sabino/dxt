{{ config(materialized='table') }}

select
  3 as customer_id,
  'Katherine' as customer_name
