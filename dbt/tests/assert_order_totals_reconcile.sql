-- Memastikan total amount order sama dengan jumlah net lines + service charge + tax
with line_totals as (
    select
        order_id,
        sum(net_sales_amount) as total_net_lines
    from {{ ref('fct_order_lines') }}
    where is_revenue_line
    group by 1
),

orders as (
    select
        o.order_id,
        o.total_amount,
        o.service_charge_amount,
        o.tax_amount,
        coalesce(l.total_net_lines, 0) as total_net_lines,
        coalesce(l.total_net_lines, 0) + o.service_charge_amount + o.tax_amount as calculated_total
    from {{ ref('fct_orders') }} as o
    left join line_totals as l on l.order_id = o.order_id
    where o.order_status = 'Completed'
)

select
    order_id,
    total_amount,
    calculated_total,
    abs(total_amount - calculated_total) as diff
from orders
where abs(total_amount - calculated_total) > 1
