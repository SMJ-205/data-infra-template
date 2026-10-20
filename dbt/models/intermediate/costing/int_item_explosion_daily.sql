/*
  Grain   : date_day x item_type x item_id x ingredient_id (bahan raw)
  item_type: 'Menu Item' | 'Modifier' | 'Prep Item' | 'Ingredient'
  Rumus   : qty bruto per unit = qty_per_yield / (1 - loss_pct/100) / yield_qty, dikalikan sepanjang jalur BOM
  BOM     : diurai rekursif (WITH RECURSIVE) sampai bahan raw, berapa pun tingkatnya
            (mis. Menu -> PRP_BUMBU -> PRP_BWGOR -> ING_SHALLOT). Resep dipilih per tanggal (versi berlaku).
  Guard   : prep yang tidak bisa diurai (tanpa resep aktif, siklus, atau > var('bom_max_depth')) keluar dengan
            ingredient_id NULL → gagal test not_null di sini & n_components_missing_cost di std cost.
            Tidak pernah hilang diam-diam.
*/
with recursive

dates as (
    select date_day
    from {{ ref('util_dates') }}
    where date_day between {{ var('start_date') }} and current_date('{{ var("local_tz") }}')
),

ingredients as (
    select * from {{ ref('stg_pos__ingredients') }}
),

recipes as (
    select * from {{ ref('stg_pos__recipes') }}
),

recipe_lines as (
    select * from {{ ref('stg_pos__recipe_lines') }}
),

modifier_lines as (
    select * from {{ ref('stg_pos__modifier_lines') }}
),

recipe_lines_on_day as (
    select
        d.date_day,
        if(r.menu_item_id is not null, 'Menu Item', 'Prep Item') as item_type,
        coalesce(r.menu_item_id, r.prep_ingredient_id) as item_id,
        rl.ingredient_id as component_id,
        rl.qty_per_yield / (1 - rl.loss_pct / 100) / r.yield_qty as qty_per_unit
    from dates as d
    inner join recipes as r
        on
            d.date_day >= r.effective_from
            and d.date_day < coalesce(r.effective_to, date '9999-12-31')
    inner join recipe_lines as rl
        on r.recipe_id = rl.recipe_id
),

modifier_lines_on_day as (
    select
        d.date_day,
        'Modifier' as item_type,
        ml.modifier_id as item_id,
        ml.ingredient_id as component_id,
        ml.qty_delta as qty_per_unit
    from dates as d
    cross join modifier_lines as ml
),

first_level as (
    select * from recipe_lines_on_day
    union all
    select * from modifier_lines_on_day
),

-- edge prep -> komponen (raw atau prep lain) yang berlaku per tanggal
prep_edges as (
    select
        date_day,
        item_id as prep_id,
        component_id,
        qty_per_unit
    from recipe_lines_on_day
    where item_type = 'Prep Item'
),

bom as (
    -- anchor: komponen langsung dari resep menu / prep / modifier
    select
        date_day,
        item_type,
        item_id,
        component_id,
        qty_per_unit,
        1 as bom_level,
        concat(item_id, '>', component_id) as node_key,
        cast(null as string) as parent_key
    from first_level

    union all

    -- recursive: bila komponen adalah prep, turunkan ke komponen resep prep-nya
    select
        b.date_day,
        b.item_type,
        b.item_id,
        e.component_id,
        b.qty_per_unit * e.qty_per_unit as qty_per_unit,
        b.bom_level + 1 as bom_level,
        concat(b.node_key, '>', e.component_id) as node_key,
        b.node_key as parent_key
    from bom as b
    inner join prep_edges as e
        on
            b.date_day = e.date_day
            and b.component_id = e.prep_id
    where
        b.bom_level < {{ var('bom_max_depth', 10) }}
        and e.component_id not in unnest(split(b.node_key, '>'))   -- putus siklus
),

leaves as (
    -- 1) daun bahan raw
    select
        b.date_day,
        b.item_type,
        b.item_id,
        b.component_id as ingredient_id,
        b.qty_per_unit,
        b.bom_level
    from bom as b
    inner join ingredients as i
        on
            b.component_id = i.ingredient_id
            and not i.is_prep_item

    union all

    -- 2) edge prep yang tidak terurai → ingredient_id NULL (ditangkap test not_null & missing cost):
    --    prep tanpa resep aktif (e NULL), atau edge yang diputus siklus / bom_max_depth (c NULL)
    select
        b.date_day,
        b.item_type,
        b.item_id,
        cast(null as string) as ingredient_id,
        b.qty_per_unit * coalesce(e.qty_per_unit, cast(1 as numeric)) as qty_per_unit,
        b.bom_level + if(e.prep_id is null, 0, 1) as bom_level
    from bom as b
    inner join ingredients as i
        on
            b.component_id = i.ingredient_id
            and i.is_prep_item
    left join prep_edges as e
        on
            b.date_day = e.date_day
            and b.component_id = e.prep_id
    left join bom as c
        on
            b.date_day = c.date_day
            and b.item_type = c.item_type
            and b.node_key = c.parent_key
            and e.component_id = c.component_id
    where
        e.prep_id is null
        or c.node_key is null

    union all

    -- 3) bahan raw sebagai dirinya sendiri (untuk valuasi waste & stock)
    select
        d.date_day,
        'Ingredient' as item_type,
        i.ingredient_id as item_id,
        i.ingredient_id,
        cast(1 as numeric) as qty_per_unit,
        0 as bom_level
    from dates as d
    cross join ingredients as i
    where not i.is_prep_item
),

final as (
    select
        date_day,
        item_type,
        item_id,
        ingredient_id,
        sum(qty_per_unit) as qty_per_unit,
        max(bom_level) as bom_depth
    from leaves
    group by 1, 2, 3, 4
)

-- wajib diakhiri `select * from final`: lihat macro bigquery__get_unit_test_sql
select * from final
