with source as (
    select * from {{ source('pos', 'refunds') }}
)

select
    refund_id,
    order_id,
    cast(order_item_id as string)       as order_item_id,
    cast(refund_amount as numeric)      as refund_amount,
    refund_reason,
    approved_by                         as approved_by_employee_id,
    refunded_at                         as refunded_at_utc,
    {{ to_local_datetime('refunded_at') }} as refunded_at_local,
    {{ to_local_date('refunded_at') }}  as refund_date,
    updated_at                          as updated_at_utc
from source
