with source as (
    select * from {{ source('pos', 'goods_receipts') }}
)

select
    gr_id,
    outlet_id,
    supplier_id,
    invoice_no,
    received_at                         as received_at_utc,
    {{ to_local_datetime('received_at') }} as received_at_local,
    {{ to_local_date('received_at') }}  as received_date,
    updated_at                          as updated_at_utc
from source
