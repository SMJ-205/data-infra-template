with source as (
    select * from {{ source('pos', 'goods_receipt_lines') }}
)

select
    cast(gr_line_id as string)          as gr_line_id,
    gr_id,
    ingredient_id,
    cast(purchase_qty as numeric)       as purchase_qty,
    purchase_uom,
    cast(qty_base_uom as numeric)       as qty_base_uom,
    cast(line_amount as numeric)        as line_amount,
    expiry_date,
    updated_at                          as updated_at_utc
from source
