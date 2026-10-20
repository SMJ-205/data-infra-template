{{ config(enabled = var('enable_hr', false)) }}
-- Governance: tidak ada agregat gaji / rating untuk kelompok < var('hr_k_anonymity_min') orang.
select 'mart_hr_compensation_monthly' as model, outlet_id, job_role, cast(period_month as string) as period
from {{ ref('mart_hr_compensation_monthly') }}
where
    headcount_paid < {{ var('hr_k_anonymity_min', 3) }}
    and (avg_base_pay is not null or median_base_pay is not null or gross_payroll_cost is not null
         or overtime_pay is not null or compa_ratio is not null)

union all

select 'mart_hr_workforce_semiannual', outlet_id, job_role, review_period
from {{ ref('mart_hr_workforce_semiannual') }}
where
    reviewed < {{ var('hr_k_anonymity_min', 3) }}
    and (avg_rating is not null or avg_goals_met_pct is not null)
