{#
  Pertahanan lapis kedua: memindai ISI setiap baris (seluruh kolom, termasuk STRUCT/ARRAY, via to_json_string)
  untuk pola PII: telepon Indonesia, email, NIK 16 digit. Test berbasis nama kolom tidak menangkap kebocoran
  lewat kolom bernama netral - mis. baris mentah yang tak sengaja ter-select sebagai STRUCT.
  Hash hex 64 karakter aman: tidak ada batas kata di dalam string hex sehingga pola digit tidak cocok.
#}
{% test no_pii_values(model) %}
    {%- set pii_regex = "(\\b(\\+62|0)8[0-9]{8,12}\\b|[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\\.[A-Za-z0-9.-]+|\\b[0-9]{16}\\b)" %}
    select to_json_string(t) as offending_row
    from {{ model }} as t
    where regexp_contains(to_json_string(t), r'{{ pii_regex }}')
{% endtest %}
