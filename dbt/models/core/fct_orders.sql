{{
  config(
    materialized = 'table',
    partition_by = {'field': 'order_date', 'data_type': 'date', 'granularity': 'month'},
    cluster_by = ['outlet_id', 'channel_code'],
    tags = ['finance', 'daily']
  )
}}

with orders as (
    select * from {{ ref('stg_pos__orders') }}
),

lines as (
    select
        order_id,
        sum(gross_sales_amount)         as gross_sales_amount,
        sum(merchant_discount_amount)   as merchant_discount_amount,
        sum(net_sales_amount)           as net_sales_amount,
        sum(cogs_std_amount)            as cogs_std_amount,
        sum(qty)                        as units
    from {{ ref('fct_order_lines') }}
    where is_revenue_line
    group by 1
),

payments as (
    select
        order_id,
        sum(amount)                                                 as paid_amount,
        sum(mdr_fee_amount)                                         as payment_fee_amount,
        string_agg(distinct payment_method order by payment_method) as payment_methods
    from {{ ref('stg_pos__payments') }}
    group by 1
),

rates as (
    select * from {{ ref('stg_pos__channel_commission_rates') }}
)

select
    o.order_id,
    o.order_date,
    o.ordered_at_local,
    o.order_hour_local,
    o.outlet_id,
    o.channel_code,
    o.customer_id,
    o.promo_code,
    o.order_status,
    o.guest_count,
    coalesce(l.gross_sales_amount, 0)                               as gross_sales_amount,
    coalesce(l.merchant_discount_amount, 0)                         as merchant_discount_amount,
    coalesce(l.net_sales_amount, 0)                                 as net_sales_amount,
    coalesce(l.cogs_std_amount, 0)                                  as cogs_std_amount,
    coalesce(l.units, 0)                                            as units,
    o.service_charge_amount,
    o.tax_amount,
    o.total_amount,
    coalesce(p.paid_amount, 0)                                      as paid_amount,
    coalesce(p.payment_fee_amount, 0)                               as payment_fee_amount,
    p.payment_methods,
    coalesce(r.commission_pct, 0)                                   as commission_pct,
    if(o.order_status = 'Completed',
       coalesce(l.net_sales_amount, 0) * coalesce(r.commission_pct, 0) / 100,
       0)                                                           as channel_commission_amount
from orders as o
left join lines as l on l.order_id = o.order_id
left join payments as p on p.order_id = o.order_id
left join rates as r
    on r.channel_code = o.channel_code
   and o.order_date >= r.effective_from
   and o.order_date <  coalesce(r.effective_to, date '9999-12-31')
