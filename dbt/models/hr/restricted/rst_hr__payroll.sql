-- RESTRICTED: payroll individual.
select
    payroll_id,
    employee_id,
    outlet_id,
    period_month,
    cast(base_pay as numeric)                       as base_pay,
    cast(allowance_pay as numeric)                  as allowance_pay,
    cast(overtime_pay as numeric)                   as overtime_pay,
    cast(absence_deduction as numeric)              as absence_deduction,
    cast(bpjs_deduction as numeric)                 as bpjs_deduction,
    cast(net_pay as numeric)                        as net_pay,
    cast(base_pay + allowance_pay + overtime_pay as numeric) as gross_pay,
    {{ to_local_datetime('paid_at') }}              as paid_at_local
from {{ source('hr', 'payroll') }}
