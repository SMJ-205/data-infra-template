-- tests/assert_opex_reconciles.sql : opex di mart_pnl_daily = opex sumber, untuk bulan lengkap
with max_data_date as (
    select coalesce(max(order_date), current_date('{{ var("local_tz") }}') - 1) as max_date
    from {{ ref('fct_orders') }}
),
mart as (
    select m.report_month, sum(m.labor_cost + m.other_opex) as opex
    from {{ ref('mart_pnl_daily') }} as m
    cross join max_data_date as x
    where m.report_month < date_trunc(x.max_date, month)
      and not coalesce(m.is_opex_estimated, false)
    group by 1
),
src as (
    select period_month as report_month, sum(amount) as opex
    from {{ ref('stg_pos__operating_expenses') }}
    group by 1
)
select
    m.report_month,
    m.opex as mart_opex,
    s.opex as source_opex
from mart as m
inner join src as s on s.report_month = m.report_month
where abs(coalesce(m.opex, 0) - coalesce(s.opex, 0)) > 1
