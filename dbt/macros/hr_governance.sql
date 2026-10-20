{#
  k-anonymity: nilai agregat (gaji, rating) hanya ditampilkan bila kelompoknya berisi >= var('hr_k_anonymity_min')
  orang. Kelompok kecil (mis. 1 Outlet Manager per outlet) akan membuka gaji/rating individu.
#}
{% macro k_anon(value_expr, group_size_expr) -%}
    if({{ group_size_expr }} >= {{ var('hr_k_anonymity_min', 3) }}, {{ value_expr }}, null)
{%- endmacro %}


{#
  Row-level security per outlet untuk model HR (post-hook). Nonaktif secara default: hanya membuat policy bila
  var('hr_row_access') diisi, mis.
    hr_row_access:
      full_access: ["group:hr-managers@ngemeal.co.id", "serviceAccount:sa-dbt@<project>.iam.gserviceaccount.com"]
      outlets:
        FLG-01: ["user:manager.flg@ngemeal.co.id"]
  Catatan: tabel yang dibuat ulang dbt kehilangan row access policy-nya, karena itu policy dipasang ulang
  setiap build lewat post-hook (bukan sekali di infra). Begitu satu policy ada, principal tanpa policy tidak
  melihat baris apa pun, maka full_access WAJIB berisi pembaca analitik & service account pipeline.
#}
{% macro hr_outlet_row_access() -%}
    {%- set cfg = var('hr_row_access', {}) -%}
    {%- if cfg and cfg.get('full_access') -%}
        create or replace row access policy rap_hr_full_access on {{ this }}
            grant to ({{ cfg['full_access'] | map('tojson') | join(', ') }})
            filter using (true);
        {%- for outlet_id, principals in (cfg.get('outlets') or {}).items() %}
        create or replace row access policy rap_hr_{{ outlet_id | lower | replace('-', '_') }} on {{ this }}
            grant to ({{ principals | map('tojson') | join(', ') }})
            filter using (outlet_id = '{{ outlet_id }}');
        {%- endfor -%}
    {%- else -%}
        select 1
    {%- endif -%}
{%- endmacro %}
