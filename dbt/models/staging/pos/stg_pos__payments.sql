with source as (
    select * from {{ source('pos', 'payments') }}
)

select
    payment_id,
    order_id,
    payment_method,
    cast(amount as numeric)             as amount,
    cast(mdr_fee_amount as numeric)     as mdr_fee_amount,
    paid_at                             as paid_at_utc,
    {{ to_local_datetime('paid_at') }}  as paid_at_local,
    {{ to_local_date('paid_at') }}      as paid_date,
    updated_at                          as updated_at_utc
from source
