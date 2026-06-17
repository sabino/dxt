{{ config(schema="mart", alias="order_facts") }}

select
  '{{ this.schema }}' as this_schema,
  '{{ this.name }}' as this_name,
  '{{ this.identifier }}' as this_identifier
from {{ this }}
union all
select
  'ref_schema' as this_schema,
  'ref_name' as this_name,
  'ref_identifier' as this_identifier
from {{ ref('base_orders') }}
