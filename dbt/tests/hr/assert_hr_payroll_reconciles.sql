{{ config(enabled = var('enable_hr', false)) }}
-- Payroll: net = gross - potongan, dan headcount bulanan konsisten (closing bulan ini = opening bulan depan).
select 'net_pay' as check_name, payroll_id as id
from {{ ref('rst_hr__payroll') }}
where abs(net_pay - (gross_pay - absence_deduction - bpjs_deduction)) > 0.01

union all

select 'headcount_roll', concat(outlet_id, ' ', employment_type, ' ', cast(report_month as string))
from (
    select
        *,
        lead(opening_headcount) over (partition by outlet_id, employment_type order by report_month) as next_opening
    from {{ ref('mart_hr_headcount_turnover_monthly') }}
)
where next_opening is not null and next_opening != closing_headcount
