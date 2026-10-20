{{ config(enabled = var('enable_hr', false)) }}
-- Tahapan rekrutmen harus berurutan: lamar <= screening <= interview <= offer <= keputusan.
select application_id
from {{ ref('stg_hr__job_applications') }}
where
    screened_at_local < applied_at_local
    or interviewed_at_local < screened_at_local
    or offered_at_local < interviewed_at_local
    or decided_at_local < coalesce(offered_at_local, interviewed_at_local, screened_at_local, applied_at_local)
    or (application_status = 'Hired' and offered_at_local is null)
    or (application_status = 'In Process' and decided_at_local is not null)
