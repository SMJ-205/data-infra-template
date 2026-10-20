-- Story event 2026-11-01: standarisasi "Bumbu Dasar" untuk menu nasi/mie goreng.
-- BOM menjadi 3 level: Menu -> PRP_BUMBU -> PRP_BWGOR -> bahan raw.
--   MNU_NGORENG / MNU_MIEGOR (V2)
--     └─ PRP_BUMBU  Bumbu Dasar Nasi Goreng (batch 1.000 g)
--          ├─ ING_SHALLOT, ING_GARLIC, ING_CHILI, ING_OIL
--          └─ PRP_BWGOR  Bawang Goreng (batch 400 g)
--               └─ ING_SHALLOT, ING_OIL
-- Idempoten: aman dijalankan berulang (init-master). Histori sebelum 2026-11-01 tidak berubah.

INSERT INTO fnb.ingredients (ingredient_id, ingredient_name, ingredient_category, base_uom, is_prep_item, is_perishable, shelf_life_days) VALUES
('ING_SHALLOT', 'Bawang Merah',            'Produce',   'g',  FALSE, TRUE,  14),
('ING_GARLIC',  'Bawang Putih',            'Produce',   'g',  FALSE, TRUE,  14),
('ING_CHILI',   'Cabai Merah',             'Produce',   'g',  FALSE, TRUE,  5),
('ING_OIL',     'Minyak Goreng',           'Dry Goods', 'ml', FALSE, FALSE, 180),
('PRP_BWGOR',   'Bawang Goreng',           'Prep',      'g',  TRUE,  TRUE,  7),
('PRP_BUMBU',   'Bumbu Dasar Nasi Goreng', 'Prep',      'g',  TRUE,  TRUE,  3)
ON CONFLICT DO NOTHING;

-- Standard cost sejak awal periode: explosion 'Ingredient' memvaluasi semua bahan raw di setiap tanggal.
INSERT INTO fnb.ingredient_standard_costs (ingredient_id, effective_from, effective_to, standard_cost_per_base_uom) VALUES
('ING_SHALLOT', '2025-07-01', NULL, 45.0000),
('ING_GARLIC',  '2025-07-01', NULL, 40.0000),
('ING_CHILI',   '2025-07-01', NULL, 60.0000),
('ING_OIL',     '2025-07-01', NULL, 18.0000)
ON CONFLICT DO NOTHING;

INSERT INTO fnb.recipes (recipe_id, prep_ingredient_id, version_no, yield_qty, effective_from) VALUES
('R_PRP_BWGOR_V1', 'PRP_BWGOR', 1, 400,  '2026-11-01'),
('R_PRP_BUMBU_V1', 'PRP_BUMBU', 1, 1000, '2026-11-01')
ON CONFLICT DO NOTHING;
INSERT INTO fnb.recipe_lines (recipe_id, ingredient_id, qty_per_yield, loss_pct) VALUES
('R_PRP_BWGOR_V1', 'ING_SHALLOT', 1000, 10),  -- 10% kupasan
('R_PRP_BWGOR_V1', 'ING_OIL',     150,  0),
('R_PRP_BUMBU_V1', 'ING_SHALLOT', 400,  10),
('R_PRP_BUMBU_V1', 'ING_GARLIC',  200,  10),
('R_PRP_BUMBU_V1', 'ING_CHILI',   250,  5),   -- buang tangkai
('R_PRP_BUMBU_V1', 'ING_OIL',     100,  0),
('R_PRP_BUMBU_V1', 'PRP_BWGOR',   100,  0)    -- prep di dalam prep
ON CONFLICT DO NOTHING;

-- Tutup versi lama dulu (constraint EXCLUDE melarang periode tumpang tindih). updated_at dinaikkan agar dlt menarik perubahan.
UPDATE fnb.recipes
SET effective_to = '2026-11-01', updated_at = now()
WHERE recipe_id IN ('R_MNU_NGORENG_V1', 'R_MNU_MIEGOR_V1')
  AND effective_to IS NULL;

INSERT INTO fnb.recipes (recipe_id, menu_item_id, version_no, yield_qty, effective_from, effective_to) VALUES
('R_MNU_NGORENG_V2', 'MNU_NGORENG', 2, 1, '2026-11-01', NULL),
('R_MNU_MIEGOR_V2',  'MNU_MIEGOR',  2, 1, '2026-11-01', NULL)
ON CONFLICT DO NOTHING;
INSERT INTO fnb.recipe_lines (recipe_id, ingredient_id, qty_per_yield, loss_pct) VALUES
('R_MNU_NGORENG_V2', 'ING_RICE', 90, 0), ('R_MNU_NGORENG_V2', 'ING_EGG', 1, 0), ('R_MNU_NGORENG_V2', 'ING_CHKN', 60, 8),
('R_MNU_NGORENG_V2', 'ING_VEG', 30, 10), ('R_MNU_NGORENG_V2', 'PRP_BUMBU', 25, 0), ('R_MNU_NGORENG_V2', 'ING_BOX', 1, 0),
('R_MNU_MIEGOR_V2',  'ING_NOOD', 120, 0), ('R_MNU_MIEGOR_V2', 'ING_EGG', 1, 0), ('R_MNU_MIEGOR_V2', 'ING_VEG', 30, 10),
('R_MNU_MIEGOR_V2',  'PRP_BUMBU', 20, 0), ('R_MNU_MIEGOR_V2', 'ING_BOX', 1, 0)
ON CONFLICT DO NOTHING;
