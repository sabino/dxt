{% snapshot package_history %}
{{ config(strategy='check', unique_key='customer_id', check_cols='all', tags=['package']) }}
select * from {{ ref('pkg_customers') }}
{% endsnapshot %}
