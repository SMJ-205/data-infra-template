{{
  config(
    materialized = 'table',
    tags = ['staging', 'security']
  )
}}

with source as (
    select * from {{ source('pos', 'customers') }}
),

salt_val as (
    select any_value(salt) as salt
    from `{{ target.project }}.{{ var('secrets_dataset') }}.pii_salt`
),

normalized as (
    select
        customer_id,
        -- normalisasi format Indonesia ke E.164 (+62...)
        regexp_replace(trim(phone_number), r'^08', '+628') as norm_phone,
        lower(trim(email))                                 as norm_email,
        birth_date,
        registered_at,
        deleted_at,
        updated_at
    from source
)

select
    n.customer_id,
    if(n.norm_phone is null, null, to_hex(sha256(concat(n.norm_phone, s.salt)))) as phone_hash,
    if(n.norm_email is null, null, to_hex(sha256(concat(n.norm_email, s.salt)))) as email_hash,
    extract(year from n.birth_date)                                               as birth_year,
    {{ to_local_datetime('n.registered_at') }}                                    as registered_at_local,
    n.deleted_at is not null                                                      as is_deleted,
    n.updated_at                                                                  as updated_at_utc
from normalized as n
cross join salt_val as s
