{{
  config(
    materialized = 'table',
    tags = ['staging', 'security']
  )
}}
-- Tabel (bukan view), sama seperti stg_pos__customers: hash dihitung saat build sehingga pembaca stg tidak
-- membutuhkan akses ke ops_secrets.pii_salt.
-- Nama & telepon kandidat tidak dibawa; candidate_key (hash ber-salt dari telepon ternormalisasi) cukup
-- untuk mendeteksi pelamar berulang tanpa membuka identitas.
-- CTE sengaja tidak dinamai `source`: tabel ini punya kolom `source`, dan di BigQuery `source` akan
-- menunjuk ke seluruh baris (struct berisi nama & telepon kandidat), bukan ke kolomnya.
with applications as (
    select * from {{ source('hr', 'job_applications') }}
)

select
    application_id,
    requisition_id,
    {{ hash_pii("regexp_replace(trim(candidate_phone), r'^08', '+628')") }}    as candidate_key,
    a.source                                        as application_source,
    {{ to_local_datetime('applied_at') }}           as applied_at_local,
    {{ to_local_datetime('screened_at') }}          as screened_at_local,
    {{ to_local_datetime('interviewed_at') }}       as interviewed_at_local,
    {{ to_local_datetime('offered_at') }}           as offered_at_local,
    {{ to_local_datetime('decided_at') }}           as decided_at_local,
    status                                          as application_status,
    screened_at is not null and status != 'Withdrawn'           as is_screened,
    interviewed_at is not null                      as is_interviewed,
    offered_at is not null                          as is_offered,
    status = 'Hired'                                as is_hired,
    hired_employee_id,
    updated_at                                      as updated_at_utc
from applications as a
