with source as (
    select * from {{ source('pos', 'channel_commission_rates') }}
)

select
    channel_code,
    effective_from,
    effective_to,
    cast(commission_pct as numeric) as commission_pct,
    updated_at as updated_at_utc
from source
