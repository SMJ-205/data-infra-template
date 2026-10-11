-- tests/assert_order_totals_reconcile.sql
-- Memastikan total amount order sama dengan:
-- net_sales_amount - platform_funded_discount_amount + service_charge_amount + tax_amount
-- Catatan: net_sales_amount sengaja tidak mengurangi diskon yang didanai platform (merchant tetap diakui pendapatannya),
-- namun total_amount yang dibayar pelanggan mengurangi seluruh diskon (merchant + platform).
with line_totals as (
    select
        order_id,
        sum(net_sales_amount) as total_net_lines,
        sum(platform_funded_discount_amount) as total_platform_discounts
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
        coalesce(l.total_platform_discounts, 0) as total_platform_discounts,
        coalesce(l.total_net_lines, 0) - coalesce(l.total_platform_discounts, 0)
            + o.service_charge_amount + o.tax_amount as calculated_total
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
