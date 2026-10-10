{# Satu-satunya titik konversi zona waktu. Input: kolom TIMESTAMP (UTC). #}
{% macro to_local_datetime(column_name) -%}
    datetime({{ column_name }}, '{{ var("local_tz") }}')
{%- endmacro %}

{% macro to_local_date(column_name) -%}
    date({{ column_name }}, '{{ var("local_tz") }}')
{%- endmacro %}
