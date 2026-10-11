{% snapshot snap_menu_items %}

{{
    config(
      unique_key='menu_item_id',
      strategy='timestamp',
      updated_at='updated_at_utc',
      hard_deletes='invalidate'
    )
}}

select * from {{ ref('stg_pos__menu_items') }}

{% endsnapshot %}
