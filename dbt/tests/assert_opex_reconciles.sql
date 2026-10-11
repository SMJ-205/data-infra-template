-- tests/assert_opex_reconciles.sql : opex di mart_pnl_daily = opex sumber, untuk bulan lengkap
with mart as (
    select report_month, sum(labor_cost + other_opex) as opex
    from {{ ref('mart_pnl_daily') }}
    where report_month < date_trunc(current_date('{{ var("local_tz") }}'), month)
    group by 1
),
src as (
    select period_month as report_month, sum(amount) as opex
    from {{ ref('stg_pos__operating_expenses') }}
    group by 1
)
select
    coalesce(m.report_month, s.report_month) as report_month,
    m.opex as mart_opex,
    s.opex as source_opex
from mart as m
full outer join src as s on s.report_month = m.report_month
where abs(coalesce(m.opex, 0) - coalesce(s.opex, 0)) > 1
