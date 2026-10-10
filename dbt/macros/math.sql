{# Persentase aman pembagi nol -> NULL. Output: angka 0-100, bukan rasio 0-1. #}
{% macro safe_pct(numerator, denominator, digits=2) -%}
    round(safe_divide({{ numerator }}, {{ denominator }}) * 100, {{ digits }})
{%- endmacro %}
