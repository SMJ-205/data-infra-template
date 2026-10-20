{{ config(enabled = var('enable_hr', false)) }}
-- Governance: dataset hr (analis) dan model stg_hr__* tidak boleh memiliki kolom PII langsung atau
-- gaji/rating individual. Dicek dari metadata BigQuery (INFORMATION_SCHEMA), bukan dari YAML,
-- sehingga kolom yang lolos dari dokumentasi pun tertangkap.
{% set hr_rel = ref('dim_hr_employee') %}
{% set stg_rel = ref('stg_hr__employees') %}
{% set banned = '^(full_name|phone_number|email|national_id|birth_date|candidate_name|candidate_phone|base_salary_monthly|hourly_rate|base_pay|net_pay|gross_pay|rating|goals_met_pct)$' %}

select table_schema, table_name, column_name
from `{{ hr_rel.database }}`.`{{ hr_rel.schema }}`.INFORMATION_SCHEMA.COLUMNS
where regexp_contains(lower(column_name), r'{{ banned }}')

union all

select table_schema, table_name, column_name
from `{{ stg_rel.database }}`.`{{ stg_rel.schema }}`.INFORMATION_SCHEMA.COLUMNS
where
    starts_with(table_name, 'stg_hr__')
    and regexp_contains(lower(column_name), r'{{ banned }}')
