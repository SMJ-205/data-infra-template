{{
  config(
    materialized = 'table',
    partition_by = {'field': 'received_date', 'data_type': 'date', 'granularity': 'month'},
    cluster_by = ['outlet_id', 'ingredient_id'],
    tags = ['inventory', 'daily']
  )
}}

with lines as (
    select * from {{ ref('stg_pos__goods_receipt_lines') }}
),

headers as (
    select * from {{ ref('stg_pos__goods_receipts') }}
)

select
    l.gr_line_id,
    l.gr_id,
    h.outlet_id,
    h.supplier_id,
    h.received_date,
    h.received_at_local,
    l.ingredient_id,
    l.purchase_qty,
    l.purchase_uom,
    l.qty_base_uom,
    l.line_amount,
    safe_divide(l.line_amount, l.qty_base_uom) as actual_unit_cost,
    l.expiry_date
from lines as l
inner join headers as h on h.gr_id = l.gr_id
