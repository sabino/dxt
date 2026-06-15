{{ config(materialized="table", tags=["nightly", "finance"]) }}

select 1 as order_id
