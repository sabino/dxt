{{ config(materialized="table") }}

select customer_id from {{ ref("customers") }}
