select *
from {{ ref(var("model_name")) }}
