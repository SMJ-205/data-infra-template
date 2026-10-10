{% snapshot snap_menu_items %}

{{
    config(
      target_schema='snapshots',
      unique_key='menu_item_id',
      strategy='timestamp',
      updated_at='updated_at_utc',
      invalidate_hard_deletes=True
    )
}}

select * from {{ ref('stg_pos__menu_items') }}

{% endsnapshot %}
