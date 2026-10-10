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

platform_discounts as (
    select
        order_date,
        outlet_id,
        channel_code,
        sum(platform_funded_discount_amount) as platform_funded_discounts
    from {{ ref('fct_order_lines') }}
    where is_revenue_line
    group by 1, 2, 3
)

select
    o.order_date,
    o.outlet_id,
    o.channel_code,
    c.channel_name,
    c.channel_group,
    o.order_count,
    o.gross_sales,
    o.merchant_discounts,
    coalesce(pd.platform_funded_discounts, 0) as platform_funded_discounts,
    o.net_sales,
    o.cogs_standard,
    o.channel_commission,
    o.payment_fees,
    o.net_sales - o.cogs_standard - o.channel_commission - o.payment_fees as contribution_after_channel,
    safe_divide(o.net_sales, nullif(o.order_count, 0)) as avg_order_value,
    {{ safe_pct('o.channel_commission', 'o.net_sales') }} as channel_commission_pct
from orders as o
left join platform_discounts as pd
    on pd.order_date = o.order_date
   and pd.outlet_id = o.outlet_id
   and pd.channel_code = o.channel_code
left join {{ ref('dim_channel') }} as c
    on c.channel_code = o.channel_code
