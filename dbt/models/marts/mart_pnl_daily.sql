{{ config(
    materialized = 'table',
    partition_by = {'field': 'report_date', 'data_type': 'date', 'granularity': 'month'},
    cluster_by = ['outlet_id'],
    tags = ['finance', 'mart']
) }}

with max_data_date as (
    select coalesce(max(order_date), current_date('{{ var("local_tz") }}') - 1) as max_date
    from {{ ref('fct_orders') }}
),

outlet_days as (
    select d.date_day as report_date, o.outlet_id
    from {{ ref('util_dates') }} as d
    cross join max_data_date as m
    inner join {{ ref('stg_pos__outlets') }} as o
        on d.date_day between o.opened_date
                          and coalesce(o.closed_date, m.max_date)
    where d.date_day >= {{ var('start_date') }}
      and d.date_day <= m.max_date

    union all

    select d.date_day as report_date, 'Unallocated' as outlet_id
    from {{ ref('util_dates') }} as d
    cross join max_data_date as m
    where d.date_day >= {{ var('start_date') }}
      and d.date_day <= m.max_date
      and exists (
          select 1 from {{ ref('fct_opex_allocated_monthly') }}
          where outlet_id = 'Unallocated'
            and period_month = date_trunc(d.date_day, month)
      )
),

sales as (
    select
        order_date                      as report_date,
        outlet_id,
        sum(gross_sales_amount)         as gross_sales,
        sum(merchant_discount_amount)   as discounts,
        sum(cogs_std_amount)            as cogs_standard,
        sum(qty)                        as units_sold
    from {{ ref('fct_order_lines') }}
    where is_revenue_line
    group by 1, 2
),

orders as (
    select
        order_date                          as report_date,
        outlet_id,
        count(*)                            as order_count,
        sum(channel_commission_amount)      as channel_commission,
        sum(payment_fee_amount)             as payment_fees
    from {{ ref('fct_orders') }}
    where order_status = 'Completed'
    group by 1, 2
),

refunds as (
    select
        refund_date as report_date,
        outlet_id,
        sum(refund_net_amount) as refunds,
        sum(refund_tax_amount) as tax_refunds
    from {{ ref('fct_refunds') }}
    group by 1, 2
),

waste as (
    select waste_date as report_date, outlet_id, sum(waste_cost_amount) as waste_cost
    from {{ ref('fct_waste') }}
    group by 1, 2
),

opex_daily as (
    select
        period_month,
        outlet_id,
        sum(if(pnl_line = 'Labor', allocated_amount, 0)) / nullif(any_value(active_days_in_month), 0)   as labor_cost,
        sum(if(pnl_line != 'Labor', allocated_amount, 0)) / nullif(any_value(active_days_in_month), 0)  as other_opex,
        logical_or(is_opex_estimated)                                                                     as is_opex_estimated
    from {{ ref('fct_opex_allocated_monthly') }}
    group by 1, 2
),

joined as (
    select
        od.report_date,
        date_trunc(od.report_date, month)                                   as report_month,
        od.outlet_id,
        coalesce(o.order_count, 0)                                          as order_count,
        coalesce(s.units_sold, 0)                                           as units_sold,
        coalesce(s.gross_sales, 0)                                          as gross_sales,
        coalesce(s.discounts, 0)                                            as discounts,
        coalesce(r.refunds, 0)                                              as refunds,
        coalesce(s.gross_sales, 0) - coalesce(s.discounts, 0) - coalesce(r.refunds, 0) as net_sales,
        coalesce(s.cogs_standard, 0)                                        as cogs_standard,
        coalesce(w.waste_cost, 0)                                           as waste_cost,
        coalesce(o.channel_commission, 0)                                   as channel_commission,
        coalesce(o.payment_fees, 0)                                         as payment_fees,
        coalesce(x.labor_cost, 0)                                           as labor_cost,
        coalesce(x.other_opex, 0)                                           as other_opex,
        coalesce(x.is_opex_estimated, false)                                as is_opex_estimated
    from outlet_days as od
    left join sales as s on s.report_date = od.report_date and s.outlet_id = od.outlet_id
    left join orders as o on o.report_date = od.report_date and o.outlet_id = od.outlet_id
    left join refunds as r on r.report_date = od.report_date and r.outlet_id = od.outlet_id
    left join waste as w on w.report_date = od.report_date and w.outlet_id = od.outlet_id
    left join opex_daily as x
        on x.outlet_id = od.outlet_id
       and x.period_month = date_trunc(od.report_date, month)
),

calc as (
    select
        *,
        cogs_standard + waste_cost                                              as cost_of_sales,
        net_sales - cogs_standard - waste_cost                                  as gross_profit,
        net_sales - cogs_standard - waste_cost - channel_commission - payment_fees
                                                                                as contribution_after_channel,
        net_sales - cogs_standard - waste_cost - channel_commission - payment_fees
            - labor_cost - other_opex                                           as outlet_ebitda
    from joined
)

select
    *,
    {{ safe_pct('cost_of_sales', 'net_sales') }}                as food_cost_pct,
    {{ safe_pct('waste_cost', 'net_sales') }}                   as waste_pct,
    {{ safe_pct('cost_of_sales + labor_cost', 'net_sales') }}   as prime_cost_pct,
    {{ safe_pct('gross_profit', 'net_sales') }}                 as gross_margin_pct,
    {{ safe_pct('outlet_ebitda', 'net_sales') }}                as ebitda_margin_pct,
    safe_divide(net_sales, nullif(order_count, 0))              as avg_order_value
from calc
