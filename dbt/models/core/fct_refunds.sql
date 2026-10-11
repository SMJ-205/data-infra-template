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
    select
        order_id,
        outlet_id,
        channel_code,
        total_amount,
        tax_amount,
        service_charge_amount,
        net_sales_amount
    from {{ ref('fct_orders') }}
),

lines as (
    select
        order_item_id,
        net_sales_amount
    from {{ ref('fct_order_lines') }}
)

select
    r.refund_id,
    r.order_id,
    o.outlet_id,
    o.channel_code,
    r.order_item_id,
    r.refund_date,
    r.refunded_at_local,
    r.refund_amount                                     as refund_gross_amount,
    case
        when r.order_item_id is not null then
            coalesce(l.net_sales_amount, r.refund_amount * coalesce(safe_divide(o.net_sales_amount, o.total_amount), 1))
        else
            r.refund_amount * coalesce(safe_divide(o.net_sales_amount, o.total_amount), 1)
    end                                                 as refund_net_amount,
    r.refund_amount * coalesce(safe_divide(o.tax_amount, o.total_amount), 0)
                                                        as refund_tax_amount,
    r.refund_amount * coalesce(safe_divide(o.service_charge_amount, o.total_amount), 0)
                                                        as refund_service_charge_amount,
    r.refund_amount,
    r.refund_reason,
    r.approved_by_employee_id
from refunds as r
left join orders as o on o.order_id = r.order_id
left join lines as l on l.order_item_id = r.order_item_id
