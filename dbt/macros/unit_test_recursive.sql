{#
  BigQuery hanya mengizinkan WITH RECURSIVE di level teratas statement, sedangkan dbt membungkus SQL model
  di dalam subquery saat unit test (`get_unit_test_sql`) dan saat membaca skema kolom (`get_empty_subquery_sql`).
  Override di bawah: bila SQL model diawali `with recursive` (boleh didahului komentar) dan diakhiri
  `select * from final`, CTE `final` dipakai langsung sehingga rekursi tetap di level teratas.
  SQL lain diteruskan ke implementasi bawaan tanpa perubahan.
#}

{% macro recursive_final_body(sql) -%}
    {#- -> SQL tanpa `select * from final` bila model rekursif, none bila bukan -#}
    {%- set sql = sql | trim -%}
    {%- set tail = 'select * from final' -%}
    {%- set is_recursive = modules.re.search('(?is)^\\s*(/\\*.*?\\*/\\s*|--[^\\n]*\\n\\s*)*with\\s+recursive\\b', sql) is not none -%}
    {%- if not is_recursive -%}
        {{ return(none) }}
    {%- elif not (sql | lower).endswith(tail) -%}
        {{ exceptions.raise_compiler_error("Model WITH RECURSIVE wajib diakhiri `" ~ tail ~ "` agar bisa di-unit-test di BigQuery.") }}
    {%- endif -%}
    {{ return(sql[:(sql | length) - (tail | length)]) }}
{%- endmacro %}


{% macro bigquery__get_empty_subquery_sql(select_sql, select_sql_header=none) -%}
    {%- set body = recursive_final_body(select_sql) -%}
    {%- if select_sql_header is not none -%}
    {{ select_sql_header }}
    {%- endif -%}
    {%- if body is none %}
    {#- sama dengan implementasi bawaan dbt-bigquery -#}
    select * from (
        {{ select_sql }}
    ) as __dbt_sbq
    where false and current_timestamp() = current_timestamp()
    limit 0
    {%- else %}
{{ body }}
select * from final
where false and current_timestamp() = current_timestamp()
limit 0
    {%- endif -%}
{%- endmacro %}


{% macro bigquery__get_unit_test_sql(main_sql, expected_fixture_sql, expected_column_names) -%}
    {%- set body = recursive_final_body(main_sql) -%}
    {%- if body is none -%}
        {{ dbt.default__get_unit_test_sql(main_sql, expected_fixture_sql, expected_column_names) }}
    {%- else %}
{{ body }}
, dbt_internal_unit_test_actual as (
  select
    {% for c in expected_column_names %}{{ c }}{% if not loop.last %}, {% endif %}{% endfor %}, {{ dbt.string_literal("actual") }} as {{ adapter.quote("actual_or_expected") }}
  from final
),
dbt_internal_unit_test_expected as (
  select
    {% for c in expected_column_names %}{{ c }}{% if not loop.last %}, {% endif %}{% endfor %}, {{ dbt.string_literal("expected") }} as {{ adapter.quote("actual_or_expected") }}
  from (
    {{ expected_fixture_sql }}
  ) _dbt_internal_unit_test_expected
)
select * from dbt_internal_unit_test_actual
union all
select * from dbt_internal_unit_test_expected
    {%- endif -%}
{%- endmacro %}
