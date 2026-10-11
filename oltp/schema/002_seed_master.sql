-- Seed master data (idempotent: ON CONFLICT DO NOTHING). Brand fiktif "Kopi Senja"; semua data sintetis.
-- Karyawan dan pelanggan dibuat oleh generator (data PII sintetis). Transaksi dibuat oleh generator.
-- Harga online = harga offline + ±15% (dibulatkan ribuan), umum pada platform delivery.

-- ============================ ORGANISASI =============================
INSERT INTO fnb.outlets (outlet_id, outlet_name, city, outlet_type, seat_capacity, opened_date) VALUES
('FLG-01',   'Kopi Senja Flagship Sudirman', 'Jakarta', 'Flagship',      60, '2025-07-01'),
('KIOSK-02', 'Kopi Senja Kiosk Dago',        'Bandung', 'Kiosk',          0, '2025-07-01'),
('CLOUD-03', 'Kopi Senja Cloud Kitchen Kemang', 'Jakarta', 'Cloud Kitchen', 0, '2025-07-01')
ON CONFLICT DO NOTHING;

-- ========================= KANAL & PROMO =============================
INSERT INTO fnb.sales_channels (channel_code, channel_name, channel_group) VALUES
('DINE_IN',    'Dine-In',    'Offline'),
('TAKEAWAY',   'Takeaway',   'Offline'),
('GOFOOD',     'GoFood',     'Online Delivery'),
('GRABFOOD',   'GrabFood',   'Online Delivery'),
('SHOPEEFOOD', 'ShopeeFood', 'Online Delivery')
ON CONFLICT DO NOTHING;

INSERT INTO fnb.channel_commission_rates (channel_code, effective_from, effective_to, commission_pct) VALUES
('DINE_IN',    '2025-07-01', NULL,         0),
('TAKEAWAY',   '2025-07-01', NULL,         0),
('GOFOOD',     '2025-07-01', '2026-04-01', 20),
('GOFOOD',     '2026-04-01', NULL,         22),   -- story event: komisi naik 20% -> 22%
('GRABFOOD',   '2025-07-01', NULL,         20),
('SHOPEEFOOD', '2025-07-01', NULL,         18)
ON CONFLICT DO NOTHING;

INSERT INTO fnb.promotions (promo_code, promo_name, promo_type, promo_value, funded_by, start_date, end_date) VALUES
('HEMAT10',   'Diskon Hemat 10%',            'PERCENT', 10,   'Merchant', '2025-07-01', '2027-12-31'),
('POTONG5K',  'Potongan Rp 5.000',           'FIXED',   5000, 'Merchant', '2025-07-01', '2027-12-31'),
('GOFOOD15',  'Promo GoFood 15%',            'PERCENT', 15,   'Platform', '2025-07-01', '2027-12-31'),
('GRAB20',    'Promo GrabFood 20%',          'PERCENT', 20,   'Platform', '2025-07-01', '2027-12-31'),
('SHOPEE12',  'Promo ShopeeFood 12%',        'PERCENT', 12,   'Platform', '2025-07-01', '2027-12-31')
ON CONFLICT DO NOTHING;

-- =============================== MENU ================================
INSERT INTO fnb.menu_categories (category_code, category_name, category_group) VALUES
('COFFEE',    'Coffee',       'Beverage'),
('NONCOFFEE', 'Non-Coffee',   'Beverage'),
('TEA',       'Tea',          'Beverage'),
('BAKERY',    'Bakery',       'Bakery'),
('FOOD',      'Main Course',  'Food')
ON CONFLICT DO NOTHING;

INSERT INTO fnb.menu_items (menu_item_id, menu_name, category_code, launched_date) VALUES
('MNU_AMERICANO', 'Americano',          'COFFEE',    '2025-07-01'),
('MNU_LATTE',     'Cafe Latte',         'COFFEE',    '2025-07-01'),
('MNU_KSAREN',    'Kopi Susu Aren',     'COFFEE',    '2025-07-01'),
('MNU_CAPPU',     'Cappuccino',         'COFFEE',    '2025-07-01'),
('MNU_COLDBREW',  'Cold Brew',          'COFFEE',    '2025-07-01'),
('MNU_OATLATTE',  'Oat Latte',          'COFFEE',    '2025-07-01'),
('MNU_CHOCO',     'Chocolate',          'NONCOFFEE', '2025-07-01'),
('MNU_MATCHA',    'Matcha Latte',       'NONCOFFEE', '2025-09-01'),
('MNU_LEMONTEA',  'Lemon Tea',          'TEA',       '2025-07-01'),
('MNU_ICETEA',    'Iced Tea',           'TEA',       '2025-07-01'),
('MNU_CROIS',     'Butter Croissant',   'BAKERY',    '2025-07-01'),
('MNU_TOAST',     'Cheese Toast',       'BAKERY',    '2025-07-01'),
('MNU_NGORENG',   'Nasi Goreng Ayam',   'FOOD',      '2025-07-01'),
('MNU_MIEGOR',    'Mie Goreng',         'FOOD',      '2025-07-01'),
('MNU_CHKRICE',   'Chicken Rice Bowl',  'FOOD',      '2025-07-01'),
('MNU_EGGSAND',   'Egg Sandwich',       'FOOD',      '2025-11-01')
ON CONFLICT DO NOTHING;

INSERT INTO fnb.menu_item_prices (menu_item_id, channel_group, effective_from, selling_price)
SELECT m.menu_item_id, g.channel_group, m.launched_date,
       CASE g.channel_group WHEN 'Offline' THEN p.offline_price ELSE p.online_price END
FROM fnb.menu_items m
JOIN (VALUES
  ('MNU_AMERICANO', 28000, 32000), ('MNU_LATTE',    35000, 40000), ('MNU_KSAREN',   30000, 35000),
  ('MNU_CAPPU',     35000, 40000), ('MNU_COLDBREW', 33000, 38000), ('MNU_OATLATTE', 42000, 48000),
  ('MNU_CHOCO',     32000, 37000), ('MNU_MATCHA',   38000, 44000), ('MNU_LEMONTEA', 24000, 28000),
  ('MNU_ICETEA',    18000, 21000), ('MNU_CROIS',    28000, 32000), ('MNU_TOAST',    26000, 30000),
  ('MNU_NGORENG',   42000, 48000), ('MNU_MIEGOR',   36000, 42000), ('MNU_CHKRICE',  45000, 52000),
  ('MNU_EGGSAND',   34000, 39000)
) AS p(menu_item_id, offline_price, online_price) USING (menu_item_id)
CROSS JOIN (VALUES ('Offline'), ('Online Delivery')) AS g(channel_group)
ON CONFLICT DO NOTHING;

-- ========================== BAHAN & RESEP ============================
INSERT INTO fnb.ingredients (ingredient_id, ingredient_name, ingredient_category, base_uom, is_prep_item, is_perishable, shelf_life_days) VALUES
('ING_ESPR',   'Espresso Beans',        'Coffee',    'g',   FALSE, FALSE, 60),
('ING_MILK',   'Fresh Milk',            'Dairy',     'ml',  FALSE, TRUE,  7),
('ING_OAT',    'Oat Milk',              'Dairy',     'ml',  FALSE, TRUE,  10),
('ING_CHSE',   'Cheddar Cheese',        'Dairy',     'g',   FALSE, TRUE,  30),
('ING_PALM',   'Gula Aren Cair',        'Syrup',     'ml',  FALSE, FALSE, 90),
('ING_CHOC',   'Chocolate Powder',      'Dry Goods', 'g',   FALSE, FALSE, 180),
('ING_MATCHA', 'Matcha Powder',         'Tea',       'g',   FALSE, FALSE, 120),
('ING_TEA',    'Black Tea Leaves',      'Tea',       'g',   FALSE, FALSE, 180),
('ING_SUGR',   'Gula Pasir',            'Dry Goods', 'g',   FALSE, FALSE, 365),
('ING_WATR',   'Air Mineral Galon',     'Dry Goods', 'ml',  FALSE, FALSE, 30),
('ING_LEMON',  'Lemon',                 'Produce',   'pcs', FALSE, TRUE,  7),
('ING_VEG',    'Sayur Mix',             'Produce',   'g',   FALSE, TRUE,  4),
('ING_CROIS',  'Croissant (frozen)',    'Bakery',    'pcs', FALSE, TRUE,  3),
('ING_BREAD',  'Roti Tawar (slice)',    'Bakery',    'pcs', FALSE, TRUE,  5),
('ING_EGG',    'Telur Ayam',            'Protein',   'pcs', FALSE, TRUE,  21),
('ING_CHKN',   'Ayam Fillet',           'Protein',   'g',   FALSE, TRUE,  3),
('ING_RICE',   'Beras',                 'Dry Goods', 'g',   FALSE, FALSE, 365),
('ING_NOOD',   'Mie Kuning',            'Dry Goods', 'g',   FALSE, FALSE, 60),
('ING_CUP',    'Paper Cup & Lid 12oz',  'Packaging', 'pcs', FALSE, FALSE, NULL),
('ING_BOX',    'Food Box',              'Packaging', 'pcs', FALSE, FALSE, NULL),
('PRP_AREN',   'Sirup Aren Batch',      'Prep',      'ml',  TRUE,  TRUE,  3),
('PRP_CBREW',  'Cold Brew Concentrate', 'Prep',      'ml',  TRUE,  TRUE,  2)
ON CONFLICT DO NOTHING;

INSERT INTO fnb.ingredient_standard_costs (ingredient_id, effective_from, effective_to, standard_cost_per_base_uom) VALUES
('ING_ESPR',   '2025-07-01', NULL,          250.0000),
('ING_MILK',   '2025-07-01', '2026-01-01',   20.0000),
('ING_MILK',   '2026-01-01', NULL,           22.4000),   -- story event: susu naik 12%
('ING_OAT',    '2025-07-01', NULL,           45.0000),
('ING_CHSE',   '2025-07-01', NULL,          110.0000),
('ING_PALM',   '2025-07-01', NULL,           60.0000),
('ING_CHOC',   '2025-07-01', NULL,          180.0000),
('ING_MATCHA', '2025-07-01', NULL,          650.0000),
('ING_TEA',    '2025-07-01', NULL,          120.0000),
('ING_SUGR',   '2025-07-01', NULL,           16.0000),
('ING_WATR',   '2025-07-01', NULL,            0.5000),
('ING_LEMON',  '2025-07-01', NULL,         2500.0000),
('ING_VEG',    '2025-07-01', NULL,           20.0000),
('ING_CROIS',  '2025-07-01', NULL,         9000.0000),
('ING_BREAD',  '2025-07-01', NULL,         2500.0000),
('ING_EGG',    '2025-07-01', NULL,         2200.0000),
('ING_CHKN',   '2025-07-01', NULL,           38.0000),
('ING_RICE',   '2025-07-01', NULL,           14.0000),
('ING_NOOD',   '2025-07-01', NULL,           25.0000),
('ING_CUP',    '2025-07-01', NULL,         1500.0000),
('ING_BOX',    '2025-07-01', NULL,         1800.0000)
ON CONFLICT DO NOTHING;

INSERT INTO fnb.suppliers (supplier_id, supplier_name, city, payment_term_days) VALUES
('SUP01', 'PT Kopi Nusantara Jaya',  'Jakarta', 14),
('SUP02', 'CV Susu Lembang Segar',   'Bandung', 7),
('SUP03', 'Toko Roti Sentosa',       'Jakarta', 0),
('SUP04', 'UD Pasar Segar',          'Jakarta', 0),
('SUP05', 'PT Kemasan Prima',        'Jakarta', 30),
('SUP06', 'PT Sembako Makmur',       'Jakarta', 14)
ON CONFLICT DO NOTHING;

-- Resep prep. yield_qty = hasil batch (base uom). qty_per_yield = qty bersih per batch; loss_pct menambah kebutuhan kotor.
INSERT INTO fnb.recipes (recipe_id, prep_ingredient_id, version_no, yield_qty, effective_from) VALUES
('R_PRP_AREN_V1',  'PRP_AREN',  1, 1000, '2025-07-01'),
('R_PRP_CBREW_V1', 'PRP_CBREW', 1, 1000, '2025-07-01')
ON CONFLICT DO NOTHING;
INSERT INTO fnb.recipe_lines (recipe_id, ingredient_id, qty_per_yield, loss_pct) VALUES
('R_PRP_AREN_V1',  'ING_PALM', 600, 0),
('R_PRP_AREN_V1',  'ING_WATR', 400, 10),     -- 10% menguap saat dimasak
('R_PRP_CBREW_V1', 'ING_ESPR', 150, 0),
('R_PRP_CBREW_V1', 'ING_WATR', 1000, 0)
ON CONFLICT DO NOTHING;

-- Resep menu (1 porsi). Kopi Susu Aren punya 2 versi (story event 2026-02-01: sirup 30 -> 25 ml).
INSERT INTO fnb.recipes (recipe_id, menu_item_id, version_no, yield_qty, effective_from, effective_to) VALUES
('R_MNU_AMERICANO_V1', 'MNU_AMERICANO', 1, 1, '2025-07-01', NULL),
('R_MNU_LATTE_V1',     'MNU_LATTE',     1, 1, '2025-07-01', NULL),
('R_MNU_KSAREN_V1',    'MNU_KSAREN',    1, 1, '2025-07-01', '2026-02-01'),
('R_MNU_KSAREN_V2',    'MNU_KSAREN',    2, 1, '2026-02-01', NULL),
('R_MNU_CAPPU_V1',     'MNU_CAPPU',     1, 1, '2025-07-01', NULL),
('R_MNU_COLDBREW_V1',  'MNU_COLDBREW',  1, 1, '2025-07-01', NULL),
('R_MNU_OATLATTE_V1',  'MNU_OATLATTE',  1, 1, '2025-07-01', NULL),
('R_MNU_CHOCO_V1',     'MNU_CHOCO',     1, 1, '2025-07-01', NULL),
('R_MNU_MATCHA_V1',    'MNU_MATCHA',    1, 1, '2025-09-01', NULL),
('R_MNU_LEMONTEA_V1',  'MNU_LEMONTEA',  1, 1, '2025-07-01', NULL),
('R_MNU_ICETEA_V1',    'MNU_ICETEA',    1, 1, '2025-07-01', NULL),
('R_MNU_CROIS_V1',     'MNU_CROIS',     1, 1, '2025-07-01', NULL),
('R_MNU_TOAST_V1',     'MNU_TOAST',     1, 1, '2025-07-01', NULL),
('R_MNU_NGORENG_V1',   'MNU_NGORENG',   1, 1, '2025-07-01', NULL),
('R_MNU_MIEGOR_V1',    'MNU_MIEGOR',    1, 1, '2025-07-01', NULL),
('R_MNU_CHKRICE_V1',   'MNU_CHKRICE',   1, 1, '2025-07-01', NULL),
('R_MNU_EGGSAND_V1',   'MNU_EGGSAND',   1, 1, '2025-11-01', NULL)
ON CONFLICT DO NOTHING;

INSERT INTO fnb.recipe_lines (recipe_id, ingredient_id, qty_per_yield, loss_pct) VALUES
('R_MNU_AMERICANO_V1', 'ING_ESPR', 18, 0), ('R_MNU_AMERICANO_V1', 'ING_WATR', 150, 0), ('R_MNU_AMERICANO_V1', 'ING_CUP', 1, 0),
('R_MNU_LATTE_V1',     'ING_ESPR', 18, 0), ('R_MNU_LATTE_V1',     'ING_MILK', 180, 0), ('R_MNU_LATTE_V1',     'ING_CUP', 1, 0),
('R_MNU_KSAREN_V1',    'ING_ESPR', 18, 0), ('R_MNU_KSAREN_V1',    'ING_MILK', 120, 0), ('R_MNU_KSAREN_V1',    'PRP_AREN', 30, 0), ('R_MNU_KSAREN_V1', 'ING_CUP', 1, 0),
('R_MNU_KSAREN_V2',    'ING_ESPR', 18, 0), ('R_MNU_KSAREN_V2',    'ING_MILK', 120, 0), ('R_MNU_KSAREN_V2',    'PRP_AREN', 25, 0), ('R_MNU_KSAREN_V2', 'ING_CUP', 1, 0),
('R_MNU_CAPPU_V1',     'ING_ESPR', 18, 0), ('R_MNU_CAPPU_V1',     'ING_MILK', 150, 0), ('R_MNU_CAPPU_V1',     'ING_CUP', 1, 0),
('R_MNU_COLDBREW_V1',  'PRP_CBREW', 150, 0), ('R_MNU_COLDBREW_V1', 'ING_WATR', 100, 0), ('R_MNU_COLDBREW_V1', 'ING_CUP', 1, 0),
('R_MNU_OATLATTE_V1',  'ING_ESPR', 18, 0), ('R_MNU_OATLATTE_V1',  'ING_OAT', 180, 0), ('R_MNU_OATLATTE_V1',  'ING_CUP', 1, 0),
('R_MNU_CHOCO_V1',     'ING_CHOC', 30, 0), ('R_MNU_CHOCO_V1',     'ING_MILK', 200, 0), ('R_MNU_CHOCO_V1',     'ING_CUP', 1, 0),
('R_MNU_MATCHA_V1',    'ING_MATCHA', 8, 0), ('R_MNU_MATCHA_V1',   'ING_MILK', 200, 0), ('R_MNU_MATCHA_V1',    'PRP_AREN', 15, 0), ('R_MNU_MATCHA_V1', 'ING_CUP', 1, 0),
('R_MNU_LEMONTEA_V1',  'ING_TEA', 4, 0), ('R_MNU_LEMONTEA_V1',    'ING_LEMON', 0.5, 10), ('R_MNU_LEMONTEA_V1', 'ING_SUGR', 15, 0), ('R_MNU_LEMONTEA_V1', 'ING_WATR', 250, 0), ('R_MNU_LEMONTEA_V1', 'ING_CUP', 1, 0),
('R_MNU_ICETEA_V1',    'ING_TEA', 4, 0), ('R_MNU_ICETEA_V1',      'ING_SUGR', 15, 0), ('R_MNU_ICETEA_V1',      'ING_WATR', 250, 0), ('R_MNU_ICETEA_V1', 'ING_CUP', 1, 0),
('R_MNU_CROIS_V1',     'ING_CROIS', 1, 0), ('R_MNU_CROIS_V1',     'ING_BOX', 1, 0),
('R_MNU_TOAST_V1',     'ING_BREAD', 2, 0), ('R_MNU_TOAST_V1',     'ING_CHSE', 30, 0), ('R_MNU_TOAST_V1',      'ING_BOX', 1, 0),
('R_MNU_NGORENG_V1',   'ING_RICE', 90, 0), ('R_MNU_NGORENG_V1',   'ING_EGG', 1, 0), ('R_MNU_NGORENG_V1',      'ING_CHKN', 60, 8), ('R_MNU_NGORENG_V1', 'ING_VEG', 30, 10), ('R_MNU_NGORENG_V1', 'ING_BOX', 1, 0),
('R_MNU_MIEGOR_V1',    'ING_NOOD', 120, 0), ('R_MNU_MIEGOR_V1',   'ING_EGG', 1, 0), ('R_MNU_MIEGOR_V1',       'ING_VEG', 30, 10), ('R_MNU_MIEGOR_V1', 'ING_BOX', 1, 0),
('R_MNU_CHKRICE_V1',   'ING_RICE', 90, 0), ('R_MNU_CHKRICE_V1',   'ING_CHKN', 100, 8), ('R_MNU_CHKRICE_V1',   'ING_VEG', 50, 10), ('R_MNU_CHKRICE_V1', 'ING_BOX', 1, 0),
('R_MNU_EGGSAND_V1',   'ING_BREAD', 2, 0), ('R_MNU_EGGSAND_V1',   'ING_EGG', 1, 0), ('R_MNU_EGGSAND_V1',      'ING_CHSE', 20, 0), ('R_MNU_EGGSAND_V1', 'ING_BOX', 1, 0)
ON CONFLICT DO NOTHING;

-- Modifier. qty_delta boleh negatif (ganti susu: -150 ml fresh milk, +150 ml oat milk).
INSERT INTO fnb.modifiers (modifier_id, modifier_name, modifier_group, price_delta) VALUES
('MOD_XSHOT',    'Extra Shot',      'Add-on', 8000),
('MOD_OAT',      'Ganti Oat Milk',  'Milk',   10000),
('MOD_LARGE',    'Large Size',      'Size',   6000),
('MOD_LESSSUG',  'Less Sugar',      'Sugar',  0),
('MOD_XAREN',    'Extra Aren',      'Add-on', 4000),
('MOD_XCHEESE',  'Extra Cheese',    'Add-on', 6000)
ON CONFLICT DO NOTHING;
INSERT INTO fnb.modifier_lines (modifier_id, ingredient_id, qty_delta) VALUES
('MOD_XSHOT',   'ING_ESPR', 18),
('MOD_OAT',     'ING_MILK', -150), ('MOD_OAT', 'ING_OAT', 150),
('MOD_LARGE',   'ING_ESPR', 9),
('MOD_LESSSUG', 'PRP_AREN', -8),
('MOD_XAREN',   'PRP_AREN', 15),
('MOD_XCHEESE', 'ING_CHSE', 20)
ON CONFLICT DO NOTHING;

-- ============================ INVENTORI ==============================
INSERT INTO fnb.waste_reasons (reason_code, reason_name, controllability) VALUES
('EXPIRED',     'Expired',          'Controllable'),
('PREP_SPOIL',  'Prep Spoilage',    'Controllable'),
('DROPPED',     'Dropped / Spilled','Controllable'),
('QC_REJECT',   'QC Reject',        'Controllable'),
('CUST_RETURN', 'Customer Return',  'Uncontrollable')
ON CONFLICT DO NOTHING;

-- ============================== KEUANGAN =============================
INSERT INTO fnb.expense_categories (category_code, category_name, pnl_line) VALUES
('LABOR',   'Gaji & Tunjangan',      'Labor'),
('RENT',    'Sewa Tempat',           'Occupancy'),
('ELEC',    'Listrik & Gas',         'Utilities'),
('REPAIR',  'Perawatan Peralatan',   'Repairs & Maintenance'),
('MKT',     'Marketing',             'Marketing'),
('ADMIN',   'Administrasi HQ',       'G&A')
ON CONFLICT DO NOTHING;
