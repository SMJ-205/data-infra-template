{# Persentase aman pembagi nol -> NULL. Output: angka 0-100, bukan rasio 0-1. #}
{% macro safe_pct(numerator, denominator, digits=2) -%}
    round(safe_divide({{ numerator }}, {{ denominator }}) * 100, {{ digits }})
{%- endmacro %}

{# Stok kritis: < 1 hari pemakaian, kecuali bahan segar yang dikirim harian (shelf life <= 4 hari,
   sama dengan inventory.daily_delivery_shelf_life_max di generator) yang memang habis tiap malam
   → kritis bila < 0.25 hari. Bahan tanpa pemakaian 28 hari tidak pernah kritis. #}
{% macro is_stock_critical(days_on_hand, avg_daily_usage, shelf_life_days) -%}
    (
        coalesce({{ avg_daily_usage }}, 0) > 0
        and {{ days_on_hand }} < if(coalesce({{ shelf_life_days }}, 999) <= 4, 0.25, 1)
    )
{%- endmacro %}
