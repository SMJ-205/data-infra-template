/*
  Grain : period_month x outlet_id. Payroll aktual (HR) vs anggaran LABOR di operating_expenses (Finance) dan
          terhadap net sales. Level outlet (>= 8 orang) sehingga total tidak membuka gaji individu.
*/
{{ config(post_hook = "{{ hr_outlet_row_access() }}") }}

with payroll as (
    select
        period_month,
        outlet_id,
        sum(gross_pay)                  as payroll_cost,
        sum(overtime_pay)               as overtime_pay,
        count(distinct employee_id)     as headcount_paid
    from {{ ref('rst_hr__payroll') }}
    group by 1, 2
),

labor_budget as (
    select
        period_month,
        outlet_id,
        sum(amount)                     as labor_opex
    from {{ ref('stg_pos__operating_expenses') }}
    where category_code = 'LABOR'
    group by 1, 2
),

sales as (
    select report_month, outlet_id, net_sales
    from {{ ref('mart_pnl_monthly') }}
)

select
    p.period_month,
    p.outlet_id,
    p.headcount_paid,
    round(p.payroll_cost, 0)                                            as payroll_cost,
    round(p.overtime_pay, 0)                                            as overtime_pay,
    round(b.labor_opex, 0)                                              as labor_opex,
    round(p.payroll_cost - b.labor_opex, 0)                             as payroll_vs_opex_gap,
    {{ safe_pct('p.payroll_cost', 's.net_sales') }}                     as payroll_pct_of_net_sales,
    {{ safe_pct('p.overtime_pay', 'p.payroll_cost') }}                  as overtime_pct_of_payroll
from payroll as p
left join labor_budget as b
    on
        p.period_month = b.period_month
        and p.outlet_id = b.outlet_id
left join sales as s
    on
        p.period_month = s.report_month
        and p.outlet_id = s.outlet_id
