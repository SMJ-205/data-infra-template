{#
  Pola late-arriving data (insert_overwrite per partisi hari):
  1. Watermark = max(source_updated_at_utc) yang sudah ada di tabel target, dikurangi var('lookback_days')
     sebagai toleransi lag ingestion (dlt lag, job gagal sehari, dsb).
  2. Partisi yang perlu dibangun ulang = semua order_date yang barisnya BERUBAH di source sejak watermark
     (berbasis updated_at, bukan order_date) → order offline yang tersinkron H+1, H+7, dst tetap tertangkap.
  3. Model memilih SELURUH baris pada tanggal-tanggal itu, lalu dbt mengganti partisi tsb secara atomik.
  Perubahan retroaktif yang tidak menyentuh updated_at (mis. koreksi resep/std cost) ditangani full refresh
  mingguan di daily_pipeline.yml.
#}

{% macro late_arriving_watermark(column='source_updated_at_utc') -%}
    (
        select timestamp_sub(max({{ column }}), interval {{ var('lookback_days') }} day)
        from {{ this }}
    )
{%- endmacro %}


{#
  Pre-hook untuk model incremental insert_overwrite. dbt-bigquery TIDAK memeriksa perubahan partition/cluster
  spec di jalur incremental: target ber-partisi bulan + model ber-partisi hari akan menimpa satu bulan penuh
  dengan data beberapa hari saja (kehilangan data). Guard ini menghentikan run dan meminta --full-refresh.
#}
{% macro guard_incremental_relation(required_column='source_updated_at_utc') -%}
    {%- if execute and is_incremental() -%}
        {%- set partition_by = adapter.parse_partition_by(config.get('partition_by')) -%}
        {%- if not adapter.is_replaceable(this, partition_by, config.get('cluster_by')) -%}
            {{ exceptions.raise_compiler_error(
                this ~ ": partition/cluster spec tabel berbeda dengan config model. Jalankan sekali dengan --full-refresh.") }}
        {%- endif -%}
        {%- set existing = adapter.get_columns_in_relation(this) | map(attribute='name') | map('lower') | list -%}
        {%- if required_column is not none and required_column not in existing -%}
            {{ exceptions.raise_compiler_error(
                this ~ ": kolom `" ~ required_column ~ "` belum ada. Jalankan sekali dengan --full-refresh.") }}
        {%- endif -%}
    {%- endif -%}
    select 1
{%- endmacro %}
