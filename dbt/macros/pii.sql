{# Hash SHA-256 + salt dari ops_secrets.pii_salt. NULL tetap NULL. #}
{% macro hash_pii(column_expr) -%}
    if(
        {{ column_expr }} is null,
        null,
        to_hex(sha256(concat(
            cast({{ column_expr }} as string),
            (select salt from `{{ target.project }}.{{ var('secrets_dataset') }}.pii_salt`)
        )))
    )
{%- endmacro %}
