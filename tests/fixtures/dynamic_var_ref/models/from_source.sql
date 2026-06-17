select *
from {{ source('raw', var('raw_table')) }}
