with source as (
    select * from {{ source('pos', 'orders') }}
),

renamed as (
    select
        order_id,
        outlet_id,
        channel_code,
        customer_id,
        cashier_id                                              as cashier_employee_id,
        promo_code,
        external_order_ref,
        ordered_at                                              as ordered_at_utc,
        {{ to_local_datetime('ordered_at') }}                   as ordered_at_local,
        {{ to_local_date('ordered_at') }}                       as order_date,
        extract(hour from {{ to_local_datetime('ordered_at') }}) as order_hour_local,
        order_status,
        {{ to_local_datetime('cancelled_at') }}                 as cancelled_at_local,
        cancel_reason,
        cast(guest_count as int64)                              as guest_count,
        cast(subtotal_amount as numeric)                        as subtotal_amount,
        cast(item_discount_amount as numeric)                   as item_discount_amount,
        cast(order_discount_amount as numeric)                  as order_discount_amount,
        cast(service_charge_amount as numeric)                  as service_charge_amount,
        cast(tax_amount as numeric)                             as tax_amount,
        cast(total_amount as numeric)                           as total_amount,
        updated_at                                              as updated_at_utc
    from source
)

select * from renamed
