{# A comment containing {% snapshot ignored %} is not a block. #}
{% snapshot customer_history %}
{{ config(strategy='timestamp', unique_key='customer_id', updated_at='updated_at', target_schema='history', target_database='archive', tags=['nightly'], invalidate_hard_deletes=true) }}
select * from {{ ref('customers') }}
{% endsnapshot %}

{%- snapshot source_history -%}
{{ config(strategy='check', unique_key=['customer_id', 'region'], check_cols=['name', 'region'], tags='audit', alias='raw_history') }}
select * from {{ source('raw', 'customers') }}
{%- endsnapshot -%}

{% snapshot disabled_history %}
{{ config(enabled=false, tags=['disabled']) }}
select * from {{ ref('missing_disabled_parent') }}
{% endsnapshot %}
