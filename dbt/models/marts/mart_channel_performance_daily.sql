{{ config(
    materialized = 'table',
    partition_by = {'field': 'order_date', 'data_type': 'date', 'granularity': 'month'},
    cluster_by = ['outlet_id', 'channel_code'],
    tags = ['sales', 'mart']
) }}

with orders as (
    select
        order_date,
        outlet_id,
        channel_code,
        count(*)                            as order_count,
        sum(gross_sales_amount)             as gross_sales,
        sum(merchant_discount_amount)       as merchant_discounts,
        sum(net_sales_amount)               as net_sales,
        sum(cogs_std_amount)                as cogs_standard,
        sum(channel_commission_amount)      as channel_commission,
        sum(payment_fee_amount)             as payment_fees
    from {{ ref('fct_orders') }}
    where order_status = 'Completed'
    group by 1, 2, 3
),

refunds as (
    select
        refund_date as order_date,
        outlet_id,
        channel_code,
        sum(refund_net_amount)              as refunds
    from {{ ref('fct_refunds') }}
    group by 1, 2, 3
),

platform_discounts as (
    select
        order_date,
        outlet_id,
        channel_code,
        sum(platform_funded_discount_amount) as platform_funded_discounts
    from {{ ref('fct_order_lines') }}
    where is_revenue_line
    group by 1, 2, 3
),

keys as (
    select order_date, outlet_id, channel_code from orders
    union distinct
    select order_date, outlet_id, channel_code from refunds
    union distinct
    select order_date, outlet_id, channel_code from platform_discounts
)

select
    k.order_date,
    k.outlet_id,
    k.channel_code,
    c.channel_name,
    c.channel_group,
    coalesce(o.order_count, 0) as order_count,
    coalesce(o.gross_sales, 0) as gross_sales,
    coalesce(o.merchant_discounts, 0) as merchant_discounts,
    coalesce(r.refunds, 0) as refunds,
    coalesce(pd.platform_funded_discounts, 0) as platform_funded_discounts,
    coalesce(o.net_sales, 0) - coalesce(r.refunds, 0) as net_sales,
    coalesce(o.cogs_standard, 0) as cogs_standard,
    coalesce(o.channel_commission, 0) as channel_commission,
    coalesce(o.payment_fees, 0) as payment_fees,
    (coalesce(o.net_sales, 0) - coalesce(r.refunds, 0)) - coalesce(o.cogs_standard, 0) - coalesce(o.channel_commission, 0) - coalesce(o.payment_fees, 0) as contribution_after_channel,
    safe_divide(coalesce(o.net_sales, 0) - coalesce(r.refunds, 0), nullif(o.order_count, 0)) as avg_order_value,
    {{ safe_pct('coalesce(o.channel_commission, 0)', 'coalesce(o.net_sales, 0) - coalesce(r.refunds, 0)') }} as channel_commission_pct
from keys as k
left join orders as o
    on o.order_date = k.order_date
   and o.outlet_id = k.outlet_id
   and o.channel_code = k.channel_code
left join refunds as r
    on r.order_date = k.order_date
   and r.outlet_id = k.outlet_id
   and r.channel_code = k.channel_code
left join platform_discounts as pd
    on pd.order_date = k.order_date
   and pd.outlet_id = k.outlet_id
   and pd.channel_code = k.channel_code
left join {{ ref('dim_channel') }} as c
    on c.channel_code = k.channel_code
