with source as (
    select * from {{ source('pos', 'waste_reasons') }}
)

select
    reason_code,
    reason_name,
    controllability,
    updated_at as updated_at_utc
from source
