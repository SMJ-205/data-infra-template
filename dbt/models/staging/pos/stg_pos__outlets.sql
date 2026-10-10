with source as (
    select * from {{ source('pos', 'outlets') }}
)

select
    outlet_id,
    outlet_name,
    city,
    outlet_type,
    cast(seat_capacity as int64) as seat_capacity,
    opened_date,
    closed_date,
    {{ to_local_datetime('created_at') }} as created_at_local,
    updated_at as updated_at_utc
from source
