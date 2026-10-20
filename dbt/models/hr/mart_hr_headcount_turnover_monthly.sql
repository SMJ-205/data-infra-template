/*
  Grain   : report_month x outlet_id x employment_type
  Turnover: terminations / rata-rata (opening, closing) headcount. Early attrition = keluar < 90 hari.
*/
{{ config(post_hook = "{{ hr_outlet_row_access() }}") }}

with employees as (
    select * from {{ ref('dim_hr_employee') }}
),

months as (
    select distinct date_trunc(date_day, month) as report_month
    from {{ ref('util_dates') }}
    where date_day between {{ var('start_date') }} and current_date('{{ var("local_tz") }}')
),

grid as (
    select m.report_month, o.outlet_id, t.employment_type
    from months as m
    cross join (select distinct outlet_id from employees) as o
    cross join (select distinct employment_type from employees) as t
),

calc as (
    select
        g.report_month,
        g.outlet_id,
        g.employment_type,
        countif(
            e.hired_date < g.report_month
            and (e.terminated_date is null or e.terminated_date >= g.report_month)
        )                                                                       as opening_headcount,
        countif(date_trunc(e.hired_date, month) = g.report_month)               as hires,
        countif(date_trunc(e.terminated_date, month) = g.report_month)          as terminations,
        countif(
            date_trunc(e.terminated_date, month) = g.report_month and e.termination_reason = 'Resign'
        )                                                                       as voluntary_terminations,
        countif(
            date_trunc(e.terminated_date, month) = g.report_month and e.is_early_attrition
        )                                                                       as early_attrition
    from grid as g
    left join employees as e
        on
            g.outlet_id = e.outlet_id
            and g.employment_type = e.employment_type
    group by 1, 2, 3
)

select
    *,
    opening_headcount + hires - terminations                                    as closing_headcount,
    {{ safe_pct('terminations', '(opening_headcount + (opening_headcount + hires - terminations)) / 2') }}
                                                                                as turnover_pct
from calc
