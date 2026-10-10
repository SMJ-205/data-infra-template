{{
  config(
    materialized = 'table',
    partition_by = {'field': 'refund_date', 'data_type': 'date', 'granularity': 'month'},
    cluster_by = ['outlet_id'],
    tags = ['finance', 'daily']
  )
}}

with refunds as (
    select * from {{ ref('stg_pos__refunds') }}
),

orders as (
    select order_id, outlet_id, channel_code from {{ ref('stg_pos__orders') }}
)

select
    r.refund_id,
    r.order_id,
    o.outlet_id,
    o.channel_code,
    r.order_item_id,
    r.refund_date,
    r.refunded_at_local,
    r.refund_amount,
    r.refund_reason,
    r.approved_by_employee_id
from refunds as r
left join orders as o on o.order_id = r.order_id
