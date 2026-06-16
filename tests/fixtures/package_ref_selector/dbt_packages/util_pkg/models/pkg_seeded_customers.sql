select {{ format_id('customer_id') }} as customer_id
from {{ ref('raw_pkg_customers') }}
