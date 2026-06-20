select *
from {{ source('raw', 'customers') }}
union all
select *
from {{ source('raw', 'orders') }}
