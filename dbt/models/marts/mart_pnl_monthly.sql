{{ config(
    materialized = 'table',
    tags = ['finance', 'mart']
) }}

with daily as (
    select * from {{ ref('mart_pnl_daily') }}
),

variance as (
    select
        outlet_id,
        date_trunc(period_end, month)       as report_month,
        sum(unexplained_variance_value)     as inventory_variance_cost
    from {{ ref('mart_inventory_variance') }}
    group by 1, 2
),

monthly as (
    select
        report_month,
        outlet_id,
        count(*)                        as reported_days,
        sum(order_count)                as order_count,
        sum(gross_sales)                as gross_sales,
        sum(discounts)                  as discounts,
        sum(refunds)                    as refunds,
        sum(net_sales)                  as net_sales,
        sum(cogs_standard)              as cogs_standard,
        sum(waste_cost)                 as waste_cost,
        sum(channel_commission)         as channel_commission,
        sum(payment_fees)               as payment_fees,
        sum(labor_cost)                 as labor_cost,
        sum(other_opex)                 as other_opex
    from daily
    group by 1, 2
),

calc as (
    select
        m.*,
        m.report_month < date_trunc(current_date('{{ var("local_tz") }}'), month)    as is_complete_month,
        coalesce(v.inventory_variance_cost, 0)                                      as inventory_variance_cost,
        m.cogs_standard + m.waste_cost                                              as theoretical_cost_of_sales,
        m.cogs_standard + m.waste_cost + coalesce(v.inventory_variance_cost, 0)     as actual_cost_of_sales
    from monthly as m
    left join variance as v on v.outlet_id = m.outlet_id and v.report_month = m.report_month
),

pnl as (
    select
        *,
        net_sales - actual_cost_of_sales                                            as gross_profit,
        net_sales - actual_cost_of_sales - channel_commission - payment_fees
            - labor_cost - other_opex                                               as outlet_ebitda
    from calc
)

select
    *,
    {{ safe_pct('theoretical_cost_of_sales', 'net_sales') }}        as theoretical_food_cost_pct,
    {{ safe_pct('actual_cost_of_sales', 'net_sales') }}             as food_cost_pct,
    {{ safe_pct('waste_cost', 'net_sales') }}                       as waste_pct,
    {{ safe_pct('inventory_variance_cost', 'net_sales') }}          as inventory_variance_pct,
    {{ safe_pct('actual_cost_of_sales + labor_cost', 'net_sales') }} as prime_cost_pct,
    {{ safe_pct('gross_profit', 'net_sales') }}                     as gross_margin_pct,
    {{ safe_pct('channel_commission', 'net_sales') }}               as channel_cost_pct,
    {{ safe_pct('outlet_ebitda', 'net_sales') }}                    as ebitda_margin_pct
from pnl
