with source as (
    select * from {{ source('pos', 'sales_channels') }}
)

select
    channel_code,
    channel_name,
    channel_group,
    updated_at as updated_at_utc
from source
