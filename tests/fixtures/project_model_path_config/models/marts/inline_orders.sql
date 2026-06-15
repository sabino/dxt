{{ config(materialized="incremental", tags=["inline"]) }}
select 2 as order_id
