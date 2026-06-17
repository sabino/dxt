select
  '{{ target.profile_name }}' as profile_name,
  '{{ target.name }}' as target_name,
  '{{ target.target_name }}' as target_name_alias,
  '{{ target.type }}' as adapter_type,
  '{{ target.schema }}' as target_schema,
  '{{ this.schema }}' as this_schema,
  '{{ this.name }}' as this_name,
  '{{ this.table }}' as this_table,
  '{{ this.identifier }}' as this_identifier
from {{ this }}
