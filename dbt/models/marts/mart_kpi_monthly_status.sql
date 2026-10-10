{{ config(
    materialized = 'table',
    tags = ['finance', 'mart']
) }}

with base as (
    select
        report_month,
        outlet_id,
        is_complete_month,
        cast(food_cost_pct as numeric) as food_cost_pct,
        cast(waste_pct as numeric) as waste_pct,
        cast(prime_cost_pct as numeric) as prime_cost_pct,
        cast(gross_margin_pct as numeric) as gross_margin_pct,
        cast(inventory_variance_pct as numeric) as inventory_variance_pct,
        cast(channel_cost_pct as numeric) as channel_cost_pct
    from {{ ref('mart_pnl_monthly') }}
),

kpi as (
    select report_month, outlet_id, is_complete_month, metric_code, metric_value
    from base
    unpivot (metric_value for metric_code in (
        food_cost_pct, waste_pct, prime_cost_pct, gross_margin_pct, inventory_variance_pct, channel_cost_pct
    ))
),

thresholds as (
    select * from {{ ref('kpi_thresholds') }}
)

select
    k.report_month,
    k.outlet_id,
    k.is_complete_month,
    k.metric_code,
    t.metric_name,
    t.direction,
    k.metric_value,
    t.warn_threshold,
    t.critical_threshold,
    case
        when t.direction = 'higher_is_worse' and k.metric_value >= t.critical_threshold then 'CRITICAL'
        when t.direction = 'higher_is_worse' and k.metric_value >= t.warn_threshold     then 'WARN'
        when t.direction = 'lower_is_worse'  and k.metric_value <= t.critical_threshold then 'CRITICAL'
        when t.direction = 'lower_is_worse'  and k.metric_value <= t.warn_threshold     then 'WARN'
        else 'OK'
    end as status
from kpi as k
inner join thresholds as t
    on t.metric_code = k.metric_code
   and k.report_month >= t.effective_from
   and k.report_month <  coalesce(t.effective_to, date '9999-12-31')
