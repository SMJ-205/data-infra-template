{{ config(
    materialized = 'table',
    tags = ['sales', 'mart']
) }}

with orders as (
    select
        o.outlet_id,
        o.channel_code,
        extract(dayofweek from o.order_date) as day_of_week_num,
        format_date('%A', o.order_date) as day_of_week_name,
        o.order_hour_local,
        count(*) as order_count,
        sum(o.net_sales_amount) as total_net_sales
    from {{ ref('fct_orders') }} as o
    where o.order_status = 'Completed'
    group by 1, 2, 3, 4, 5
)

select
    outlet_id,
    channel_code,
    day_of_week_num,
    day_of_week_name,
    order_hour_local,
    order_count,
    total_net_sales,
    safe_divide(total_net_sales, order_count) as avg_order_value
from orders
