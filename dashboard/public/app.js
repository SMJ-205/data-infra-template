/**
 * GoMeal. - Modern F&B Multi-Outlet Analytics & Cost Control Platform
 * Front-end Application logic & Chart.js rendering (GoMeal Theme)
 */

// State
const state = {
  data: {},
  meta: null,
  activeTab: 'pnl',
  selectedOutlet: 'ALL',
  datePreset: 'MTD',
  dateRange: { start: '', end: '' },
  minAvailableDate: '',
  maxAvailableDate: '',
  selectedCategory: 'ALL',
  explorer: {
    mart: 'pnl_monthly',
    search: '',
    page: 1,
    pageSize: 25,
  },
  charts: {},
};

// Global Chart.js Light Theme Configuration
if (window.Chart) {
  Chart.defaults.font.family = "'Plus Jakarta Sans', -apple-system, BlinkMacSystemFont, sans-serif";
  Chart.defaults.font.weight = '600';
  Chart.defaults.color = '#7E8299';
  Chart.defaults.scale.grid.color = '#F0F1F6';
  Chart.defaults.plugins.tooltip.backgroundColor = '#FFFFFF';
  Chart.defaults.plugins.tooltip.titleColor = '#1C1D21';
  Chart.defaults.plugins.tooltip.bodyColor = '#464E5F';
  Chart.defaults.plugins.tooltip.borderColor = '#EFF0F6';
  Chart.defaults.plugins.tooltip.borderWidth = 1;
  Chart.defaults.plugins.tooltip.cornerRadius = 12;
  Chart.defaults.plugins.tooltip.boxPadding = 6;
  Chart.defaults.plugins.tooltip.padding = 12;
  Chart.defaults.plugins.tooltip.usePointStyle = true;
}

// Utilities
const fmtRp = (v) => 'Rp\u00A0' + Math.round(Number(v) || 0).toLocaleString('id-ID');
const fmtRpCompact = (v) => `<span class="kpi-currency">Rp</span><span>${Math.round(Number(v) || 0).toLocaleString('id-ID')}</span>`;
const fmtPct = (v) => (v === null || v === undefined || isNaN(v) ? '-' : Number(v).toFixed(1) + '%');
const fmtNum = (v) => Math.round(Number(v) || 0).toLocaleString('id-ID');

const INGREDIENT_NAMES = {
  ING_ESPR: 'Espresso Beans',
  ING_MILK: 'Fresh Milk',
  ING_OAT: 'Oat Milk',
  ING_CHSE: 'Cheddar Cheese',
  ING_PALM: 'Gula Aren Cair',
  ING_CHOC: 'Chocolate Powder',
  ING_MATCHA: 'Matcha Powder',
  ING_TEA: 'Black Tea Leaves',
  ING_SUGR: 'Gula Pasir',
  ING_WATR: 'Air Mineral Galon',
  ING_LEMON: 'Lemon',
  ING_VEG: 'Sayur Mix',
  ING_CROIS: 'Croissant (frozen)',
  ING_BREAD: 'Roti Tawar (slice)',
  ING_EGG: 'Telur Ayam',
  ING_CHKN: 'Ayam Fillet',
  ING_RICE: 'Beras',
  ING_NOOD: 'Mie Kuning',
  ING_CUP: 'Paper Cup & Lid',
  ING_BOX: 'Food Box',
  PRP_CBREW: 'Cold Brew Base',
  PRP_CHKN_MRN: 'Marinated Chicken',
  PRP_RICE_CKD: 'Cooked Rice',
};

// Pemetaan pill kategori sidebar -> category_name sebenarnya di mart_menu_engineering
const CATEGORY_MAP = {
  Beverage: ['Coffee', 'Tea', 'Non-Coffee'],
  Food: ['Main Course'],
  Bakery: ['Bakery'],
};

function syncCategoryPills(cat) {
  document.querySelectorAll('.category-pill-card').forEach((p) => {
    p.classList.toggle('active', p.getAttribute('data-cat') === cat);
  });
}

function dateAddDays(dateStr, days) {
  const d = new Date(dateStr);
  d.setDate(d.getDate() + days);
  return d.toISOString().split('T')[0];
}

function applyDatePreset(preset) {
  const maxDate = state.maxAvailableDate || '2026-10-11';
  const minDate = state.minAvailableDate || '2025-07-01';
  state.datePreset = preset;

  if (preset === 'ALL') {
    state.dateRange.start = minDate;
    state.dateRange.end = maxDate;
  } else if (preset === 'MTD') {
    const parts = maxDate.split('-');
    state.dateRange.start = `${parts[0]}-${parts[1]}-01`;
    state.dateRange.end = maxDate;
  } else if (preset === 'LAST_30') {
    state.dateRange.start = dateAddDays(maxDate, -29);
    state.dateRange.end = maxDate;
  } else if (preset === 'LAST_7') {
    state.dateRange.start = dateAddDays(maxDate, -6);
    state.dateRange.end = maxDate;
  }

  const inputStart = document.getElementById('input-start-date');
  const inputEnd = document.getElementById('input-end-date');
  const selectPreset = document.getElementById('select-date-preset');
  if (selectPreset) selectPreset.value = preset;
  if (inputStart && inputEnd) {
    inputStart.value = state.dateRange.start;
    inputEnd.value = state.dateRange.end;
    inputStart.min = minDate;
    inputStart.max = maxDate;
    inputEnd.min = minDate;
    inputEnd.max = maxDate;
  }
}

// Initialize application
document.addEventListener('DOMContentLoaded', async () => {
  setupSidebarToggle();
  setupTabs();
  setupFilterListeners();
  setupCategoryPills();
  setupGlobalSearch();
  setupSimulator();
  setupExplorer();
  await loadData();
});

function setupSidebarToggle() {
  const sidebar = document.getElementById('dashboard-sidebar');
  const toggleBtns = document.querySelectorAll('.btn-toggle-sidebar');
  if (!sidebar) return;

  const isCollapsed = localStorage.getItem('dashboard_sidebar_collapsed') === 'true';
  if (isCollapsed && window.innerWidth > 992) {
    sidebar.classList.add('collapsed');
  }

  toggleBtns.forEach((btn) => {
    btn.addEventListener('click', () => {
      if (window.innerWidth <= 992) {
        sidebar.classList.toggle('mobile-open');
      } else {
        sidebar.classList.toggle('collapsed');
        const collapsed = sidebar.classList.contains('collapsed');
        localStorage.setItem('dashboard_sidebar_collapsed', collapsed ? 'true' : 'false');
      }

      setTimeout(() => {
        window.dispatchEvent(new Event('resize'));
      }, 300);
    });
  });
}

function setupTabs() {
  const tabBtns = document.querySelectorAll('.tab-btn');
  tabBtns.forEach((btn) => {
    btn.addEventListener('click', () => {
      tabBtns.forEach((b) => b.classList.remove('active'));
      document.querySelectorAll('.tab-section').forEach((sec) => sec.classList.remove('active'));

      btn.classList.add('active');
      const tabId = btn.getAttribute('data-tab');
      state.activeTab = tabId;
      const targetSec = document.getElementById(`sec-${tabId}`);
      if (targetSec) targetSec.classList.add('active');

      renderActiveTab();
    });
  });
}

function setupFilterListeners() {
  document.getElementById('select-outlet').addEventListener('change', (e) => {
    state.selectedOutlet = e.target.value;
    renderActiveTab();
  });

  const presetSelect = document.getElementById('select-date-preset');
  if (presetSelect) {
    presetSelect.addEventListener('change', (e) => {
      const p = e.target.value;
      if (p !== 'CUSTOM') {
        applyDatePreset(p);
        renderActiveTab();
      }
    });
  }

  const inputStart = document.getElementById('input-start-date');
  const inputEnd = document.getElementById('input-end-date');
  const onDateChange = () => {
    if (!inputStart.value || !inputEnd.value) return;
    if (inputStart.value > inputEnd.value) {
      inputEnd.value = inputStart.value;
    }
    state.dateRange.start = inputStart.value;
    state.dateRange.end = inputEnd.value;
    state.datePreset = 'CUSTOM';
    if (presetSelect) presetSelect.value = 'CUSTOM';
    renderActiveTab();
  };

  if (inputStart) inputStart.addEventListener('change', onDateChange);
  if (inputEnd) inputEnd.addEventListener('change', onDateChange);

  document.getElementById('select-menu-category').addEventListener('change', (e) => {
    state.selectedCategory = e.target.value;
    syncCategoryPills(state.selectedCategory);
    renderMenuEngineering();
  });
}

function setupCategoryPills() {
  const pills = document.querySelectorAll('.category-pill-card');
  pills.forEach((pill) => {
    pill.addEventListener('click', () => {
      pills.forEach((p) => p.classList.remove('active'));
      pill.classList.add('active');
      const cat = pill.getAttribute('data-cat');
      state.selectedCategory = cat;

      const selectMenuCat = document.getElementById('select-menu-category');
      if (selectMenuCat) selectMenuCat.value = cat;

      renderActiveTab();
    });
  });
}

function setupGlobalSearch() {
  const searchInput = document.getElementById('global-search-input');
  if (searchInput) {
    searchInput.addEventListener('input', (e) => {
      const q = e.target.value.toLowerCase().trim();
      const explorerSearch = document.getElementById('input-explorer-search');
      if (explorerSearch) {
        explorerSearch.value = q;
        state.explorer.search = q;
        state.explorer.page = 1;
      }
      if (state.activeTab === 'explorer') {
        renderExplorer();
      }
    });
  }
}

// Data Fetching
async function loadData() {
  const badgeSync = document.getElementById('badge-sync');
  try {
    const metaRes = await fetch('data/meta.json');
    state.meta = await metaRes.json();
    if (state.meta.generated_at_utc) {
      const date = new Date(state.meta.generated_at_utc);
      badgeSync.textContent = `Sync: ${date.toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })} WIB`;
    }

    const files = [
      'pnl_monthly',
      'pnl_daily',
      'kpi_status',
      'menu_engineering',
      'inventory_variance',
      'waste',
      'channel_daily',
      'orders_hourly',
      'category_daily',
    ];

    await Promise.all(
      files.map(async (file) => {
        const res = await fetch(`data/${file}.json`);
        state.data[file] = await res.json();
      })
    );

    const totalRows = Object.values(state.meta.rows || {}).reduce((a, b) => a + b, 0);
    document.getElementById('badge-records-count').textContent = `Total: ${fmtNum(totalRows)} baris (${state.meta.total_size_kb || 0} KB)`;

    populateFilters();
    renderActiveTab();
  } catch (err) {
    console.error('Error loading data:', err);
    badgeSync.textContent = 'Gagal memuat data JSON';
  }
}

function populateFilters() {
  // Populate outlets
  const outletsSet = new Set();
  (state.data.pnl_daily || state.data.pnl_monthly || []).forEach((r) => {
    if (r.outlet_id) outletsSet.add(r.outlet_id);
  });
  const selectOutlet = document.getElementById('select-outlet');
  selectOutlet.innerHTML = '<option value="ALL">Semua Outlet (Konsolidasi)</option>';
  [...outletsSet].sort().forEach((outlet) => {
    const opt = document.createElement('option');
    opt.value = outlet;
    opt.textContent = `Outlet ${outlet}`;
    selectOutlet.appendChild(opt);
  });

  // Rentang tanggal tersedia = hanya hari yang benar-benar punya transaksi
  // (mart membuat baris untuk setiap hari s/d hari ini, termasuk hari yang belum ada datanya)
  const allDates = [
    ...new Set(
      (state.data.pnl_daily || [])
        .filter((r) => (Number(r.net_sales) || 0) > 0 || (Number(r.order_count) || 0) > 0)
        .map((r) => r.report_date)
        .filter(Boolean)
    ),
  ].sort();
  if (allDates.length > 0) {
    state.minAvailableDate = allDates[0];
    state.maxAvailableDate = allDates[allDates.length - 1];
  } else {
    state.minAvailableDate = '2025-07-01';
    state.maxAvailableDate = '2026-10-11';
  }
  state.lastDataDate = state.maxAvailableDate;

  // Set default preset to MTD (Bulan Terakhir)
  applyDatePreset('MTD');
}

function renderActiveTab() {
  switch (state.activeTab) {
    case 'pnl':
      renderPnlExecutive();
      break;
    case 'cost':
      renderCostVariance();
      break;
    case 'menu':
      renderMenuEngineering();
      break;
    case 'channel':
      renderChannels();
      break;
    case 'simulator':
      updateSimulator();
      break;
    case 'explorer':
      renderExplorer();
      break;
  }
}

// TAB 1: EXECUTIVE P&L
function renderPnlExecutive() {
  const { start, end } = state.dateRange;
  if (!start || !end) return;

  const dStart = new Date(start);
  const dEnd = new Date(end);
  const dayCount = Math.max(1, Math.round((dEnd - dStart) / 86400000) + 1);
  const prevEnd = dateAddDays(start, -1);
  const prevStart = dateAddDays(prevEnd, -(dayCount - 1));
  const dateLabel = `${start.substring(5)} s/d ${end.substring(5)} (${dayCount} hr)`;

  const isCategoryMode = Boolean(state.selectedCategory && state.selectedCategory !== 'ALL');
  const catLabelMap = {
    Beverage: 'Beverage & Coffee',
    Food: 'Burger & Rice Meals',
    Bakery: 'Bakery & Pastry',
  };
  const categoryTitle = catLabelMap[state.selectedCategory] || state.selectedCategory;

  let cardsHtml = '';
  let curDataForWaterfall = null;

  if (isCategoryMode) {
    // Mode Kontribusi Kategori: gunakan category_daily
    const allowedCats = CATEGORY_MAP[state.selectedCategory] || [state.selectedCategory];
    let catRows = state.data.category_daily || [];
    if (state.selectedOutlet !== 'ALL') {
      catRows = catRows.filter((r) => r.outlet_id === state.selectedOutlet);
    }
    catRows = catRows.filter((r) => allowedCats.includes(r.category_name));

    const curCatDaily = catRows.filter((r) => r.report_date >= start && r.report_date <= end);
    const prevCatDaily = catRows.filter((r) => r.report_date >= prevStart && r.report_date <= prevEnd);
    const hasPrev = prevCatDaily.length > 0;

    const aggregateCatRows = (rows) => {
      const acc = {
        net_sales: 0,
        gross_sales: 0,
        discounts: 0,
        cogs_standard: 0,
        actual_cost_of_sales: 0,
        gross_profit: 0,
        units_sold: 0,
        line_count: 0,
      };
      rows.forEach((r) => {
        acc.net_sales += Number(r.net_sales) || 0;
        acc.gross_sales += Number(r.gross_sales) || 0;
        acc.discounts += Number(r.discounts) || 0;
        acc.cogs_standard += Number(r.cogs_standard) || 0;
        acc.actual_cost_of_sales += Number(r.cogs_standard) || 0;
        acc.gross_profit += Number(r.gross_profit) || 0;
        acc.units_sold += Number(r.units_sold) || 0;
        acc.line_count += Number(r.line_count) || 0;
      });
      return acc;
    };

    const cur = aggregateCatRows(curCatDaily);
    const prev = hasPrev ? aggregateCatRows(prevCatDaily) : null;
    curDataForWaterfall = cur;

    const curFoodCostPct = cur.net_sales ? (cur.cogs_standard / cur.net_sales) * 100 : 0;
    const prevFoodCostPct = prev && prev.net_sales ? (prev.cogs_standard / prev.net_sales) * 100 : null;
    const curGrossMarginPct = cur.net_sales ? (cur.gross_profit / cur.net_sales) * 100 : 0;
    const prevGrossMarginPct = prev && prev.net_sales ? (prev.gross_profit / prev.net_sales) * 100 : null;

    const formatDelta = (currentVal, previousVal, isPct = false, higherIsGood = true) => {
      if (!hasPrev || previousVal === undefined || previousVal === null) {
        return `<div class="kpi-delta neutral">- n/a vs Periode Lalu -</div>`;
      }
      const diff = currentVal - previousVal;
      if (Math.abs(diff) < 0.001) {
        return `<div class="kpi-delta neutral">0${isPct ? '.0 pp' : ''} vs Periode Lalu</div>`;
      }
      const isGood = higherIsGood ? diff >= 0 : diff <= 0;
      const arrow = diff >= 0 ? '▲ +' : '▼ -';
      const valStr = isPct ? `${Math.abs(diff).toFixed(1)} pp` : fmtRp(Math.abs(diff));
      return `<div class="kpi-delta ${isGood ? 'good' : 'bad'}">${arrow}${valStr} vs Periode Lalu</div>`;
    };

    cardsHtml = `
      <div class="kpi-card">
        <div class="kpi-header">
          <span class="kpi-title">Net Sales: ${categoryTitle}</span>
          <div class="kpi-badge-row">
            <span class="badge-tag badge-star">${dateLabel}</span>
          </div>
        </div>
        <div class="kpi-value">${fmtRpCompact(cur.net_sales)}</div>
        ${formatDelta(cur.net_sales, prev ? prev.net_sales : null, false, true)}
        <div class="kpi-subtext">Gross: ${fmtRp(cur.gross_sales)} (Diskon ${fmtRp(cur.discounts)})</div>
      </div>

      <div class="kpi-card">
        <div class="kpi-header">
          <span class="kpi-title">HPP Bahan (Food Cost %)</span>
          <div class="kpi-badge-row">
            <span class="badge-tag ${curFoodCostPct <= 32 ? 'badge-status-ok' : 'badge-status-critical'}">Target ≤ 32%</span>
          </div>
        </div>
        <div class="kpi-value">${fmtPct(curFoodCostPct)}</div>
        ${formatDelta(curFoodCostPct, prevFoodCostPct, true, false)}
        <div class="kpi-subtext">HPP Bahan Baku: ${fmtRp(cur.cogs_standard)}</div>
      </div>

      <div class="kpi-card">
        <div class="kpi-header">
          <span class="kpi-title">Gross Margin % (Laba Kotor)</span>
          <div class="kpi-badge-row">
            <span class="badge-tag ${curGrossMarginPct >= 65 ? 'badge-status-ok' : 'badge-status-warn'}">Target ≥ 65%</span>
          </div>
        </div>
        <div class="kpi-value">${fmtPct(curGrossMarginPct)}</div>
        ${formatDelta(curGrossMarginPct, prevGrossMarginPct, true, true)}
        <div class="kpi-subtext">Total Laba Kotor: ${fmtRp(cur.gross_profit)}</div>
      </div>

      <div class="kpi-card">
        <div class="kpi-header">
          <span class="kpi-title">Volume Porsi Terjual</span>
          <div class="kpi-badge-row">
            <span class="badge-tag badge-star">Unit Sales</span>
          </div>
        </div>
        <div class="kpi-value">${fmtNum(cur.units_sold)} Item</div>
        ${formatDelta(cur.units_sold, prev ? prev.units_sold : null, false, true)}
        <div class="kpi-subtext">${fmtNum(cur.line_count)} Baris Menu Terjual</div>
      </div>

      <div class="kpi-card">
        <div class="kpi-header">
          <span class="kpi-title">Kontribusi Margin Kotor</span>
          <div class="kpi-badge-row">
            <span class="badge-tag badge-status-ok">Product Profit</span>
          </div>
        </div>
        <div class="kpi-value">${fmtRpCompact(cur.gross_profit)}</div>
        ${formatDelta(cur.gross_profit, prev ? prev.gross_profit : null, false, true)}
        <div class="kpi-subtext">Margin sebelum alokasi beban opex outlet</div>
      </div>

      <div class="kpi-card">
        <div class="kpi-header">
          <span class="kpi-title">Rata-rata Harga / Porsi</span>
          <div class="kpi-badge-row">
            <span class="badge-tag badge-puzzle">Avg Item Price</span>
          </div>
        </div>
        <div class="kpi-value">${fmtRpCompact(cur.units_sold ? cur.net_sales / cur.units_sold : 0)}</div>
        ${formatDelta(
          cur.units_sold ? cur.net_sales / cur.units_sold : 0,
          prev && prev.units_sold ? prev.net_sales / prev.units_sold : null,
          false,
          true
        )}
        <div class="kpi-subtext">Realisasi netto per porsi menu</div>
      </div>

      <div class="data-note data-note-wide">
        <strong>Mode Kontribusi Kategori: ${categoryTitle}.</strong>
        Menampilkan sumbangsih penjualan, HPP bahan baku resep, laba kotor, dan volume terjual khusus produk kategori ini.
        <em>(Beban Staf/Labor dan Opex outlet melekat di tingkat outlet secara keseluruhan, dapat ditinjau pada filter "Semua Kategori").</em>
      </div>
    `;

    renderDynamicTrendChart(curCatDaily, dayCount, true, categoryTitle);
    renderWaterfallChart(cur, true, categoryTitle);
  } else {
    // Mode Keseluruhan Outlet: gunakan pnl_daily
    const pnlDaily = state.data.pnl_daily || [];
    let filtered = pnlDaily;
    if (state.selectedOutlet !== 'ALL') {
      filtered = filtered.filter((r) => r.outlet_id === state.selectedOutlet);
    }

    const curDaily = filtered.filter((r) => r.report_date >= start && r.report_date <= end);
    const prevDaily = filtered.filter((r) => r.report_date >= prevStart && r.report_date <= prevEnd);
    const hasPrev = prevDaily.length > 0;

    const aggregateRows = (rows) => {
      const acc = {
        net_sales: 0,
        gross_sales: 0,
        discounts: 0,
        cost_of_sales: 0,
        actual_cost_of_sales: 0,
        waste_cost: 0,
        labor_cost: 0,
        other_opex: 0,
        channel_commission: 0,
        payment_fees: 0,
        outlet_ebitda: 0,
        order_count: 0,
      };
      rows.forEach((r) => {
        acc.net_sales += Number(r.net_sales) || 0;
        acc.gross_sales += Number(r.gross_sales) || 0;
        acc.discounts += Number(r.discounts) || 0;
        acc.actual_cost_of_sales += Number(r.cost_of_sales || r.actual_cost_of_sales) || 0;
        acc.cost_of_sales += Number(r.cost_of_sales) || 0;
        acc.waste_cost += Number(r.waste_cost) || 0;
        acc.labor_cost += Number(r.labor_cost) || 0;
        acc.other_opex += Number(r.other_opex) || 0;
        acc.channel_commission += Number(r.channel_commission) || 0;
        acc.payment_fees += Number(r.payment_fees) || 0;
        acc.outlet_ebitda += Number(r.outlet_ebitda) || 0;
        acc.order_count += Number(r.order_count) || 0;
      });
      return acc;
    };

    const cur = aggregateRows(curDaily);
    const prev = hasPrev ? aggregateRows(prevDaily) : null;
    curDataForWaterfall = cur;

    const curFoodCostPct = cur.net_sales ? (cur.actual_cost_of_sales / cur.net_sales) * 100 : 0;
    const prevFoodCostPct = prev && prev.net_sales ? (prev.actual_cost_of_sales / prev.net_sales) * 100 : null;
    const curPrimeCostPct = cur.net_sales ? ((cur.actual_cost_of_sales + cur.labor_cost) / cur.net_sales) * 100 : 0;
    const prevPrimeCostPct = prev && prev.net_sales ? ((prev.actual_cost_of_sales + prev.labor_cost) / prev.net_sales) * 100 : null;
    const curEbitdaPct = cur.net_sales ? (cur.outlet_ebitda / cur.net_sales) * 100 : 0;
    const prevEbitdaPct = prev && prev.net_sales ? (prev.outlet_ebitda / prev.net_sales) * 100 : null;
    const curWastePct = cur.net_sales ? (cur.waste_cost / cur.net_sales) * 100 : 0;
    const prevWastePct = prev && prev.net_sales ? (prev.waste_cost / prev.net_sales) * 100 : null;
    const curAov = cur.order_count ? cur.net_sales / cur.order_count : 0;
    const prevAov = prev && prev.order_count ? prev.net_sales / prev.order_count : null;

    const formatDelta = (currentVal, previousVal, isPct = false, higherIsGood = true) => {
      if (!hasPrev || previousVal === undefined || previousVal === null) {
        return `<div class="kpi-delta neutral">- n/a vs Periode Lalu -</div>`;
      }
      const diff = currentVal - previousVal;
      if (Math.abs(diff) < 0.001) {
        return `<div class="kpi-delta neutral">0${isPct ? '.0 pp' : ''} vs Periode Lalu</div>`;
      }
      const isGood = higherIsGood ? diff >= 0 : diff <= 0;
      const arrow = diff >= 0 ? '▲ +' : '▼ -';
      const valStr = isPct ? `${Math.abs(diff).toFixed(1)} pp` : fmtRp(Math.abs(diff));
      return `<div class="kpi-delta ${isGood ? 'good' : 'bad'}">${arrow}${valStr} vs Periode Lalu</div>`;
    };

    cardsHtml = `
      <div class="kpi-card">
        <div class="kpi-header">
          <span class="kpi-title">Net Sales Bersih</span>
          <div class="kpi-badge-row">
            <span class="badge-tag badge-star">${dateLabel}</span>
          </div>
        </div>
        <div class="kpi-value">${fmtRpCompact(cur.net_sales)}</div>
        ${formatDelta(cur.net_sales, prev ? prev.net_sales : null, false, true)}
        <div class="kpi-subtext">Gross: ${fmtRp(cur.gross_sales)} (Diskon ${fmtRp(cur.discounts)})</div>
      </div>

      <div class="kpi-card">
        <div class="kpi-header">
          <span class="kpi-title">Actual Food Cost %</span>
          <div class="kpi-badge-row">
            <span class="badge-tag ${curFoodCostPct <= 32 ? 'badge-status-ok' : 'badge-status-critical'}">Target ≤ 32%</span>
          </div>
        </div>
        <div class="kpi-value">${fmtPct(curFoodCostPct)}</div>
        ${formatDelta(curFoodCostPct, prevFoodCostPct, true, false)}
        <div class="kpi-subtext">HPP Aktual: ${fmtRp(cur.actual_cost_of_sales)}</div>
      </div>

      <div class="kpi-card">
        <div class="kpi-header">
          <span class="kpi-title">Prime Cost % (HPP + Gaji)</span>
          <div class="kpi-badge-row">
            <span class="badge-tag ${curPrimeCostPct <= 60 ? 'badge-status-ok' : 'badge-status-warn'}">Target ≤ 60%</span>
          </div>
        </div>
        <div class="kpi-value">${fmtPct(curPrimeCostPct)}</div>
        ${formatDelta(curPrimeCostPct, prevPrimeCostPct, true, false)}
        <div class="kpi-subtext">Biaya Staf: ${fmtRp(cur.labor_cost)}</div>
      </div>

      <div class="kpi-card">
        <div class="kpi-header">
          <span class="kpi-title">Waste to Sales %</span>
          <div class="kpi-badge-row">
            <span class="badge-tag ${curWastePct <= 2 ? 'badge-status-ok' : 'badge-status-warn'}">Target ≤ 2%</span>
          </div>
        </div>
        <div class="kpi-value">${fmtPct(curWastePct)}</div>
        ${formatDelta(curWastePct, prevWastePct, true, false)}
        <div class="kpi-subtext">Biaya Limbah: ${fmtRp(cur.waste_cost)}</div>
      </div>

      <div class="kpi-card">
        <div class="kpi-header">
          <span class="kpi-title">Outlet EBITDA Margin</span>
          <div class="kpi-badge-row">
            <span class="badge-tag badge-status-ok">Bottom-Line</span>
          </div>
        </div>
        <div class="kpi-value">${fmtPct(curEbitdaPct)}</div>
        ${formatDelta(curEbitdaPct, prevEbitdaPct, true, true)}
        <div class="kpi-subtext">EBITDA: ${fmtRp(cur.outlet_ebitda)}</div>
      </div>

      <div class="kpi-card">
        <div class="kpi-header">
          <span class="kpi-title">Avg Order Value (AOV)</span>
          <div class="kpi-badge-row">
            <span class="badge-tag badge-puzzle">${fmtNum(cur.order_count)} Order</span>
          </div>
        </div>
        <div class="kpi-value">${fmtRpCompact(curAov)}</div>
        ${formatDelta(curAov, prevAov, false, true)}
        <div class="kpi-subtext">Keranjang Belanja Bersih</div>
      </div>

      <div class="data-note data-note-wide">
        <strong>Catatan:</strong>
        (1) <em>Actual Food Cost %</em> &amp; <em>HPP Aktual</em> pada tampilan harian = HPP standar resep + waste tercatat;
        <u>belum</u> memuat selisih stock opname (lihat tab Cost Control &amp; Variance untuk nilai aktual bulanan).
        (2) Data penjualan terakhir tersedia: <strong>${state.lastDataDate || '-'}</strong>.
      </div>
    `;

    renderDynamicTrendChart(curDaily, dayCount, false);
    renderWaterfallChart(cur, false);
  }

  document.getElementById('kpi-cards-container').innerHTML = cardsHtml;

  // Render KPI Status Table for corresponding month
  const targetMonthKey = end.substring(0, 7) + '-01';
  renderKpiTable(targetMonthKey);
}

function renderDynamicTrendChart(dailyRows, dayCount, isCategoryMode = false, categoryTitle = '') {
  const ctx = document.getElementById('chart-pnl-trend').getContext('2d');
  if (state.charts.trend) state.charts.trend.destroy();

  let labels = [];
  let netSales = [];
  let foodCostPct = [];

  if (dayCount <= 45) {
    // Daily granularity
    const dayMap = {};
    dailyRows.forEach((r) => {
      const d = r.report_date;
      if (!dayMap[d]) dayMap[d] = { net: 0, cost: 0 };
      dayMap[d].net += Number(r.net_sales) || 0;
      dayMap[d].cost += Number(r.cogs_standard !== undefined ? r.cogs_standard : (r.cost_of_sales || r.actual_cost_of_sales)) || 0;
    });
    const sortedDays = Object.keys(dayMap).sort();
    labels = sortedDays.map((d) => d.substring(5)); // 'MM-DD'
    netSales = sortedDays.map((d) => dayMap[d].net);
    foodCostPct = sortedDays.map((d) => (dayMap[d].net ? Number(((dayMap[d].cost / dayMap[d].net) * 100).toFixed(1)) : null));
  } else {
    // Monthly grouped granularity
    const mCountMap = {};
    dailyRows.forEach((r) => {
      const m = r.report_month || r.report_date.substring(0, 7) + '-01';
      if (!mCountMap[m]) mCountMap[m] = { net: 0, cost: 0 };
      mCountMap[m].net += Number(r.net_sales) || 0;
      mCountMap[m].cost += Number(r.cogs_standard !== undefined ? r.cogs_standard : (r.cost_of_sales || r.actual_cost_of_sales)) || 0;
    });
    const sortedMonths = Object.keys(mCountMap).sort();
    labels = sortedMonths;
    netSales = sortedMonths.map((m) => mCountMap[m].net);
    foodCostPct = sortedMonths.map((m) => (mCountMap[m].net ? Number(((mCountMap[m].cost / mCountMap[m].net) * 100).toFixed(1)) : null));
  }

  const seriesLabel = isCategoryMode ? `${categoryTitle} Net Sales (IDR)` : 'Net Sales (IDR)';

  state.charts.trend = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: labels,
      datasets: [
        {
          type: 'bar',
          label: seriesLabel,
          data: netSales,
          backgroundColor: '#F8B602',
          borderColor: '#E5A700',
          borderWidth: 1,
          borderRadius: 6,
          yAxisID: 'ySales',
        },
        {
          type: 'line',
          label: 'Food Cost %',
          data: foodCostPct,
          borderColor: '#FF5B5B',
          backgroundColor: '#FF5B5B',
          borderWidth: 2,
          pointRadius: dayCount <= 20 ? 4 : 2,
          pointHoverRadius: 6,
          pointBackgroundColor: '#FF5B5B',
          yAxisID: 'yPct',
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      interaction: { mode: 'index', intersect: false },
      plugins: {
        legend: { labels: { color: '#464E5F' } },
        tooltip: {
          callbacks: {
            label: (ctx) => {
              if (ctx.dataset.yAxisID === 'ySales') return `${seriesLabel}: ${fmtRp(ctx.raw)}`;
              return `Food Cost: ${ctx.raw}%`;
            },
          },
        },
      },
      scales: {
        x: { grid: { color: '#F0F1F6' }, ticks: { color: '#7E8299' } },
        ySales: {
          type: 'linear',
          position: 'left',
          grid: { color: '#F0F1F6' },
          ticks: { color: '#7E8299', callback: (v) => 'Rp ' + (v / 1e6).toFixed(0) + 'M' },
        },
        yPct: {
          type: 'linear',
          position: 'right',
          grid: { drawOnChartArea: false },
          ticks: { color: '#7E8299', callback: (v) => v + '%' },
          min: 0,
          max: 50,
        },
      },
    },
  });
}

function renderWaterfallChart(cur, isCategoryMode = false, categoryTitle = '') {
  const ctx = document.getElementById('chart-waterfall').getContext('2d');
  if (state.charts.waterfall) state.charts.waterfall.destroy();

  if (isCategoryMode) {
    const labels = [
      'Gross Sales',
      'Diskon',
      'Net Sales',
      'HPP Bahan (COGS)',
      'Gross Profit (Laba Kotor)',
    ];

    const values = [
      cur.gross_sales || 0,
      -(cur.discounts || 0),
      cur.net_sales || 0,
      -(cur.cogs_standard || 0),
      cur.gross_profit || 0,
    ];

    const colors = values.map((v, i) => {
      if (i === 0 || i === 2) return '#F8B602';
      if (i === 4) return v >= 0 ? '#00B074' : '#FF5B5B';
      return '#FF5B5B';
    });

    state.charts.waterfall = new Chart(ctx, {
      type: 'bar',
      data: {
        labels: labels,
        datasets: [
          {
            label: `Aliran Laba Kotor ${categoryTitle}`,
            data: values.map((v) => Math.abs(v)),
            backgroundColor: colors,
            borderRadius: 6,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { display: false },
          tooltip: {
            callbacks: {
              label: (ctx) => {
                const orig = values[ctx.dataIndex];
                return (orig < 0 ? '- ' : '') + fmtRp(Math.abs(orig));
              },
            },
          },
        },
        scales: {
          x: { grid: { color: '#F0F1F6' }, ticks: { color: '#464E5F', font: { weight: '600', size: 10 } } },
          y: {
            grid: { color: '#F0F1F6' },
            ticks: { color: '#7E8299', callback: (v) => 'Rp ' + (v / 1e6).toFixed(0) + 'M' },
          },
        },
      },
    });
    return;
  }

  const labels = [
    'Gross Sales',
    'Diskon',
    'Net Sales',
    'HPP (COGS)',
    'Komisi Kanal',
    'MDR Bank',
    'Labor',
    'Other Opex',
    'EBITDA',
  ];

  const values = [
    cur.gross_sales || 0,
    -(cur.discounts || 0),
    cur.net_sales || 0,
    -(cur.actual_cost_of_sales || 0),
    -(cur.channel_commission || 0),
    -(cur.payment_fees || 0),
    -(cur.labor_cost || 0),
    -(cur.other_opex || 0),
    cur.outlet_ebitda || 0,
  ];

  const colors = values.map((v, i) => {
    if (i === 0 || i === 2) return '#F8B602';
    if (i === 8) return v >= 0 ? '#00B074' : '#FF5B5B';
    return '#FF5B5B';
  });

  state.charts.waterfall = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: labels,
      datasets: [
        {
          label: 'IDR',
          data: values.map((v) => Math.abs(v)),
          backgroundColor: colors,
          borderRadius: 6,
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { display: false },
        tooltip: {
          callbacks: {
            label: (ctx) => {
              const orig = values[ctx.dataIndex];
              return (orig < 0 ? '- ' : '') + fmtRp(Math.abs(orig));
            },
          },
        },
      },
      scales: {
        x: { grid: { color: '#F0F1F6' }, ticks: { color: '#7E8299', font: { size: 10 } } },
        y: {
          grid: { color: '#F0F1F6' },
          ticks: { color: '#7E8299', callback: (v) => 'Rp ' + (v / 1e6).toFixed(0) + 'M' },
        },
      },
    },
  });
}
// Konsolidasi KPI semua outlet dari pnl_monthly (rasio dihitung dari total, bukan rata-rata)
function consolidateKpiRows(monthRows, monthKey) {
  const pm = (state.data.pnl_monthly || []).filter((r) => r.report_month === monthKey);
  const sum = (k) => pm.reduce((a, r) => a + (Number(r[k]) || 0), 0);
  const net = sum('net_sales');
  if (!pm.length || !net) return [];
  const pct = (n) => Number(((n / net) * 100).toFixed(2));
  const actual = sum('actual_cost_of_sales');
  const values = {
    food_cost_pct: pct(actual),
    prime_cost_pct: pct(actual + sum('labor_cost')),
    waste_pct: pct(sum('waste_cost')),
    gross_margin_pct: pct(sum('gross_profit')),
    channel_cost_pct: pct(sum('channel_commission')),
    inventory_variance_pct: pct(sum('inventory_variance_cost')),
  };

  const seen = {};
  const out = [];
  monthRows.forEach((r) => {
    if (seen[r.metric_code] || values[r.metric_code] === undefined) return;
    seen[r.metric_code] = true;
    const v = values[r.metric_code];
    const warn = Number(r.warn_threshold);
    const crit = Number(r.critical_threshold);
    let status = 'OK';
    if (r.direction === 'higher_is_worse') {
      if (v >= crit) status = 'CRITICAL';
      else if (v >= warn) status = 'WARN';
    } else {
      if (v <= crit) status = 'CRITICAL';
      else if (v <= warn) status = 'WARN';
    }
    out.push({ ...r, outlet_id: 'ALL', metric_value: v, status });
  });
  return out;
}

function renderKpiTable(monthKey) {
  const kpiData = state.data.kpi_status || [];
  let filtered = kpiData.filter((r) => r.report_month === monthKey);
  const isComplete = filtered.length ? filtered.every((r) => r.is_complete_month !== false) : true;
  if (state.selectedOutlet !== 'ALL') {
    filtered = filtered.filter((r) => r.outlet_id === state.selectedOutlet);
  } else {
    filtered = consolidateKpiRows(filtered, monthKey);
  }

  const tbody = document.querySelector('#table-kpi-status tbody');
  if (filtered.length === 0) {
    tbody.innerHTML = '<tr><td colspan="4" style="text-align:center;">Data KPI belum tersedia</td></tr>';
    return;
  }

  const rowsHtml = filtered
    .map((r) => {
      const isPct = r.metric_code.includes('pct');
      const val = isPct ? fmtPct(r.metric_value) : fmtRp(r.metric_value);
      const th = isPct ? fmtPct(r.warn_threshold) : fmtRp(r.warn_threshold);
      const symbol = r.direction === 'higher_is_worse' ? '≤' : '≥';
      const badgeCls = `badge-status-${r.status.toLowerCase()}`;
      return `
      <tr>
        <td><strong>${r.metric_name}</strong></td>
        <td>${val}</td>
        <td>${symbol} ${th}</td>
        <td><span class="badge-tag ${badgeCls}">${r.status}</span></td>
      </tr>
    `;
    })
    .join('');

  const scope = state.selectedOutlet === 'ALL' ? 'konsolidasi seluruh outlet' : `outlet ${state.selectedOutlet}`;
  const note = `<tr><td colspan="4"><span class="data-note">Bulan ${monthKey.substring(0, 7)} (${scope}).${
    isComplete ? '' : ' Bulan berjalan belum lengkap: Prime Cost belum memuat Labor bila alokasi opex bulan ini belum tersedia.'
  }</span></td></tr>`;
  tbody.innerHTML = rowsHtml + note;
}

// TAB 2: COST CONTROL & VARIANCE
function renderCostVariance() {
  const varData = (state.data.inventory_variance || []).filter((r) => {
    if (!state.dateRange.start || !state.dateRange.end) return true;
    return r.period_start <= state.dateRange.end && r.period_end >= state.dateRange.start;
  });
  const wasteData = (state.data.waste || []).filter((r) => {
    if (!state.dateRange.start || !state.dateRange.end) return true;
    return r.waste_date >= state.dateRange.start && r.waste_date <= state.dateRange.end;
  });
  const pnlMonthly = state.data.pnl_monthly || [];

  // 1. Top Unexplained Variance
  const ingMap = {};
  varData.forEach((r) => {
    if (state.selectedOutlet !== 'ALL' && r.outlet_id !== state.selectedOutlet) return;
    const rawId = r.ingredient_id || 'Bahan';
    const ingName = INGREDIENT_NAMES[rawId] || r.ingredient_name || rawId;
    const key = `${ingName} (${rawId})`;
    const val = Math.abs(Number(r.unexplained_variance_value) || 0);
    ingMap[key] = (ingMap[key] || 0) + val;
  });

  const sortedIngs = Object.entries(ingMap)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 10);

  const ctxVar = document.getElementById('chart-top-variance').getContext('2d');
  if (state.charts.variance) state.charts.variance.destroy();

  state.charts.variance = new Chart(ctxVar, {
    type: 'bar',
    data: {
      labels: sortedIngs.map((i) => i[0]),
      datasets: [
        {
          label: 'Unexplained Shrinkage (IDR)',
          data: sortedIngs.map((i) => Math.round(i[1])),
          backgroundColor: '#FF5B5B',
          borderColor: '#E64949',
          borderWidth: 1,
          borderRadius: 6,
        },
      ],
    },
    options: {
      indexAxis: 'y',
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { display: false },
        tooltip: { callbacks: { label: (ctx) => `Selisih Opname: ${fmtRp(ctx.raw)}` } },
      },
      scales: {
        x: {
          grid: { color: '#F0F1F6' },
          ticks: {
            color: '#7E8299',
            callback: (v) => {
              if (v >= 1e6) return 'Rp\u00A0' + (v / 1e6).toFixed(1) + 'M';
              if (v >= 1e3) return 'Rp\u00A0' + (v / 1e3).toFixed(0) + 'k';
              return 'Rp\u00A0' + v;
            },
          },
        },
        y: { ticks: { color: '#464E5F' } },
      },
    },
  });

  // 2. Waste by reason
  const wasteMap = {};
  wasteData.forEach((r) => {
    if (state.selectedOutlet !== 'ALL' && r.outlet_id !== state.selectedOutlet) return;
    const key = `${r.reason_name} (${r.controllability})`;
    wasteMap[key] = (wasteMap[key] || 0) + (Number(r.waste_cost) || 0);
  });

  const ctxWaste = document.getElementById('chart-waste-reasons').getContext('2d');
  if (state.charts.waste) state.charts.waste.destroy();

  state.charts.waste = new Chart(ctxWaste, {
    type: 'doughnut',
    data: {
      labels: Object.keys(wasteMap),
      datasets: [
        {
          data: Object.values(wasteMap),
          backgroundColor: ['#F8B602', '#FF5B5B', '#2F80ED', '#8950FC', '#00B074'],
          borderColor: '#FFFFFF',
          borderWidth: 3,
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { position: 'right', labels: { color: '#464E5F', font: { size: 12 } } },
        tooltip: { callbacks: { label: (ctx) => `${ctx.label}: ${fmtRp(ctx.raw)}` } },
      },
    },
  });

  // 3. Theoretical vs Actual Cost Gap
  const monthsMap = {};
  pnlMonthly.forEach((r) => {
    if (state.selectedOutlet !== 'ALL' && r.outlet_id !== state.selectedOutlet) return;
    const m = r.report_month;
    if (!monthsMap[m]) monthsMap[m] = { theo: 0, act: 0, sales: 0 };
    monthsMap[m].theo += Number(r.theoretical_cost_of_sales) || 0;
    monthsMap[m].act += Number(r.actual_cost_of_sales) || 0;
    monthsMap[m].sales += Number(r.net_sales) || 0;
  });

  const sortedMonths = Object.keys(monthsMap).sort();
  const ctxGap = document.getElementById('chart-cost-gap').getContext('2d');
  if (state.charts.costGap) state.charts.costGap.destroy();

  state.charts.costGap = new Chart(ctxGap, {
    type: 'line',
    data: {
      labels: sortedMonths,
      datasets: [
        {
          label: 'Theoretical Food Cost % (Resep + Recorded Waste)',
          data: sortedMonths.map((m) => (monthsMap[m].sales ? Number(((monthsMap[m].theo / monthsMap[m].sales) * 100).toFixed(2)) : 0)),
          borderColor: '#F8B602',
          backgroundColor: '#F8B602',
          borderWidth: 3,
          pointRadius: 4,
        },
        {
          label: 'Actual Food Cost % (Termasuk Stock Opname Variance)',
          data: sortedMonths.map((m) => (monthsMap[m].sales ? Number(((monthsMap[m].act / monthsMap[m].sales) * 100).toFixed(2)) : 0)),
          borderColor: '#FF5B5B',
          backgroundColor: '#FF5B5B',
          borderWidth: 3,
          borderDash: [6, 6],
          pointRadius: 4,
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { labels: { color: '#464E5F' } },
        tooltip: { callbacks: { label: (ctx) => `${ctx.dataset.label}: ${Number(ctx.raw).toFixed(2)}%` } },
      },
      scales: {
        x: { grid: { color: '#F0F1F6' }, ticks: { color: '#7E8299' } },
        y: {
          grid: { color: '#F0F1F6' },
          ticks: {
            color: '#7E8299',
            callback: (v) => Number(v).toFixed(2) + '%',
          },
        },
      },
    },
  });
}

// TAB 3: MENU ENGINEERING (Kasavana & Smith)
function renderMenuEngineering() {
  const menuData = state.data.menu_engineering || [];
  let filtered = menuData;
  if (state.selectedOutlet !== 'ALL') {
    filtered = filtered.filter((r) => r.outlet_id === state.selectedOutlet);
  }
  if (state.selectedCategory !== 'ALL' && CATEGORY_MAP[state.selectedCategory]) {
    const allowed = CATEGORY_MAP[state.selectedCategory];
    filtered = filtered.filter((r) => allowed.includes(r.category_name));
  }

  // Deduplicate menu items for matching month in date range
  const targetMonth = state.dateRange.end ? state.dateRange.end.substring(0, 7) + '-01' : null;
  const availableMonths = [...new Set(filtered.map((r) => r.report_month))].sort();
  const latestMonth = (targetMonth && availableMonths.includes(targetMonth))
    ? targetMonth
    : (availableMonths[availableMonths.length - 1] || '2026-05-01');
  const latestItems = filtered.filter((r) => r.report_month === latestMonth);

  const ctxMenu = document.getElementById('chart-menu-engineering').getContext('2d');
  if (state.charts.menu) state.charts.menu.destroy();

  // Groups by class in GoMeal palette
  const classColors = {
    Star: { bg: 'rgba(248, 182, 2, 0.9)', border: '#F8B602' },
    Plowhorse: { bg: 'rgba(47, 128, 237, 0.9)', border: '#2F80ED' },
    Puzzle: { bg: 'rgba(137, 80, 252, 0.9)', border: '#8950FC' },
    Dog: { bg: 'rgba(255, 91, 91, 0.9)', border: '#FF5B5B' },
  };

  const datasets = ['Star', 'Plowhorse', 'Puzzle', 'Dog'].map((cls) => {
    const items = latestItems.filter((i) => i.menu_class === cls);
    return {
      label: cls,
      data: items.map((i) => ({
        x: (Number(i.menu_mix_pct) * 100).toFixed(2),
        y: Number(i.avg_contribution_margin) || 0,
        name: i.menu_name,
        qty: i.qty_sold,
        cat: i.category_name,
      })),
      backgroundColor: classColors[cls].bg,
      borderColor: classColors[cls].border,
      borderWidth: 1,
      pointRadius: 7,
      pointHoverRadius: 10,
    };
  });

  state.charts.menu = new Chart(ctxMenu, {
    type: 'scatter',
    data: { datasets: datasets },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { labels: { color: '#464E5F' } },
        tooltip: {
          callbacks: {
            label: (ctx) => {
              const raw = ctx.raw;
              return `${raw.name} (${raw.cat}): Popularitas ${raw.x}%, Margin ${fmtRp(raw.y)}, Terjual ${fmtNum(raw.qty)}`;
            },
          },
        },
      },
      scales: {
        x: {
          title: { display: true, text: 'Popularitas (Menu Mix %)', color: '#7E8299' },
          grid: { color: '#F0F1F6' },
          ticks: { color: '#7E8299', callback: (v) => v + '%' },
        },
        y: {
          title: { display: true, text: 'Rata-rata Margin Kontribusi (IDR)', color: '#7E8299' },
          grid: { color: '#F0F1F6' },
          ticks: { color: '#7E8299', callback: (v) => 'Rp ' + (v / 1e3).toFixed(0) + 'k' },
        },
      },
    },
  });

  // Table
  const strategyRec = {
    Star: 'Pertahankan kualitas & resep standar; ini menu andalan profit gerai.',
    Plowhorse: 'Tinjau kenaikan harga bertahap atau kurangi takaran porsi bahan mahal.',
    Puzzle: 'Tingkatkan visibilitas di aplikasi delivery, buat bundling promo barista pick.',
    Dog: 'Evaluasi penghapusan menu (delist) untuk efisiensi ruang simpan bahan baku.',
  };

  const tbody = document.querySelector('#table-menu-engineering tbody');
  tbody.innerHTML = latestItems
    .sort((a, b) => (Number(b.qty_sold) || 0) - (Number(a.qty_sold) || 0))
    .map((r) => {
      const badgeCls = `badge-${r.menu_class.toLowerCase()}`;
      return `
      <tr>
        <td><strong>${r.menu_name}</strong></td>
        <td>${r.category_name}</td>
        <td><span class="badge-tag ${badgeCls}">${r.menu_class}</span></td>
        <td>${fmtNum(r.qty_sold)}</td>
        <td>${(Number(r.menu_mix_pct) * 100).toFixed(1)}%</td>
        <td>${fmtRp(r.avg_contribution_margin)}</td>
        <td style="color: var(--text-muted); font-size: 12px;">${strategyRec[r.menu_class]}</td>
      </tr>
    `;
    })
    .join('');
}

// TAB 4: CHANNELS & HEATMAP
function renderChannels() {
  const channelData = state.data.channel_daily || [];
  const hourlyData = state.data.orders_hourly || [];

  // Channel metrics aggregation
  const chMap = {};
  channelData.forEach((r) => {
    if (state.selectedOutlet !== 'ALL' && r.outlet_id !== state.selectedOutlet) return;
    if (state.dateRange.start && state.dateRange.end) {
      if (r.order_date < state.dateRange.start || r.order_date > state.dateRange.end) return;
    }
    const ch = r.channel_name || r.channel_code;
    if (!chMap[ch]) chMap[ch] = { sales: 0, comm: 0, contrib: 0, orders: 0 };
    chMap[ch].sales += Number(r.net_sales) || 0;
    chMap[ch].comm += Number(r.channel_commission) || 0;
    chMap[ch].contrib += Number(r.contribution_after_channel) || 0;
    chMap[ch].orders += Number(r.order_count) || 0;
  });

  const channels = Object.keys(chMap);

  // 1. Channel Net Sales vs Commission
  const ctxCh = document.getElementById('chart-channel-mix').getContext('2d');
  if (state.charts.channels) state.charts.channels.destroy();

  state.charts.channels = new Chart(ctxCh, {
    type: 'bar',
    data: {
      labels: channels,
      datasets: [
        { label: 'Net Sales', data: channels.map((c) => chMap[c].sales), backgroundColor: '#F8B602', borderRadius: 6 },
        { label: 'Komisi Platform', data: channels.map((c) => chMap[c].comm), backgroundColor: '#FF5B5B', borderRadius: 6 },
        { label: 'Margin Kontribusi', data: channels.map((c) => chMap[c].contrib), backgroundColor: '#00B074', borderRadius: 6 },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { labels: { color: '#464E5F' } },
        tooltip: { callbacks: { label: (ctx) => `${ctx.dataset.label}: ${fmtRp(ctx.raw)}` } },
      },
      scales: {
        x: { grid: { color: '#F0F1F6' }, ticks: { color: '#7E8299' } },
        y: { grid: { color: '#F0F1F6' }, ticks: { color: '#7E8299', callback: (v) => 'Rp ' + (v / 1e6).toFixed(0) + 'M' } },
      },
    },
  });

  // 2. Channel AOV
  const ctxAov = document.getElementById('chart-channel-aov').getContext('2d');
  if (state.charts.aov) state.charts.aov.destroy();

  state.charts.aov = new Chart(ctxAov, {
    type: 'bar',
    data: {
      labels: channels,
      datasets: [
        {
          label: 'AOV (IDR)',
          data: channels.map((c) => (chMap[c].orders ? chMap[c].sales / chMap[c].orders : 0)),
          backgroundColor: '#8950FC',
          borderRadius: 6,
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { display: false },
        tooltip: { callbacks: { label: (ctx) => `AOV: ${fmtRp(ctx.raw)}` } },
      },
      scales: {
        x: { grid: { color: '#F0F1F6' }, ticks: { color: '#7E8299' } },
        y: { grid: { color: '#F0F1F6' }, ticks: { color: '#7E8299', callback: (v) => fmtRp(v) } },
      },
    },
  });

  // 3. Peak Hour Heatmap
  renderHeatmap(hourlyData);
}

function renderHeatmap(data) {
  const container = document.getElementById('orders-heatmap');
  const days = ['Senin', 'Selasa', 'Rabu', 'Kamis', 'Jumat', 'Sabtu', 'Minggu'];
  const dayNums = [2, 3, 4, 5, 6, 7, 1]; // BigQuery 1=Sunday, 2=Monday

  // Aggregate matrix
  const matrix = {};
  let maxOrders = 0;
  data.forEach((r) => {
    if (state.selectedOutlet !== 'ALL' && r.outlet_id !== state.selectedOutlet) return;
    const d = r.day_of_week_num;
    const h = r.order_hour_local;
    const k = `${d}_${h}`;
    matrix[k] = (matrix[k] || 0) + (Number(r.order_count) || 0);
    if (matrix[k] > maxOrders) maxOrders = matrix[k];
  });

  let html = '<div class="heatmap-day-label">Hari / Jam</div>';
  for (let h = 0; h < 24; h++) {
    html += `<div class="heatmap-hour-label">${String(h).padStart(2, '0')}</div>`;
  }

  days.forEach((dayName, idx) => {
    const dayNum = dayNums[idx];
    html += `<div class="heatmap-day-label">${dayName}</div>`;
    for (let h = 0; h < 24; h++) {
      const count = matrix[`${dayNum}_${h}`] || 0;
      const intensity = maxOrders > 0 ? count / maxOrders : 0;
      let bg = '#F8F9FD';
      let color = '#B5B5C3';

      if (intensity > 0) {
        if (intensity < 0.25) {
          bg = '#FFF9E6';
          color = '#8C6000';
        } else if (intensity < 0.5) {
          bg = '#FFE8A3';
          color = '#8C6000';
        } else if (intensity < 0.75) {
          bg = '#F8B602';
          color = '#FFFFFF';
        } else {
          bg = '#FA8B0C';
          color = '#FFFFFF';
        }
      }

      html += `<div class="heatmap-cell" style="background:${bg}; color:${color};" title="${dayName} jam ${h}:00 - ${fmtNum(count)} order">${count > 0 ? fmtNum(count) : '-'}</div>`;
    }
  });

  container.innerHTML = html;
}

// TAB 5: WHAT-IF SIMULATOR
function setupSimulator() {
  const sliderComm = document.getElementById('slider-comm');
  const sliderPrice = document.getElementById('slider-price');
  const sliderWaste = document.getElementById('slider-waste');

  const onInput = () => {
    document.getElementById('val-sim-comm').textContent = `${sliderComm.value >= 0 ? '+' : ''}${sliderComm.value}%`;
    document.getElementById('val-sim-price').textContent = `${sliderPrice.value >= 0 ? '+' : ''}${sliderPrice.value}%`;
    document.getElementById('val-sim-waste').textContent = `${sliderWaste.value >= 0 ? '+' : ''}${sliderWaste.value}%`;
    updateSimulator();
  };

  sliderComm.addEventListener('input', onInput);
  sliderPrice.addEventListener('input', onInput);
  sliderWaste.addEventListener('input', onInput);
}

function updateSimulator() {
  const pnlSource = state.data.pnl_daily || state.data.pnl_monthly || [];
  let baseSales = 0,
    baseCogs = 0,
    baseWaste = 0,
    baseComm = 0,
    baseOpex = 0,
    baseEbitda = 0;

  pnlSource.forEach((r) => {
    if (state.selectedOutlet !== 'ALL' && r.outlet_id !== state.selectedOutlet) return;
    if (r.report_date && state.dateRange.start && state.dateRange.end) {
      if (r.report_date < state.dateRange.start || r.report_date > state.dateRange.end) return;
    }
    baseSales += Number(r.net_sales) || 0;
    baseCogs += Number(r.cogs_standard) || 0;
    baseWaste += Number(r.waste_cost) || 0;
    baseComm += Number(r.channel_commission) || 0;
    baseOpex += (Number(r.labor_cost) || 0) + (Number(r.other_opex) || 0) + (Number(r.payment_fees) || 0);
    baseEbitda += Number(r.outlet_ebitda) || 0;
  });

  const dComm = Number(document.getElementById('slider-comm').value) / 100;
  const dPrice = Number(document.getElementById('slider-price').value) / 100;
  const dWaste = Number(document.getElementById('slider-waste').value) / 100;

  // Simulation calculations
  const simSales = baseSales * (1 + dPrice);
  const simWaste = baseWaste * (1 + dWaste);
  const simComm = baseComm * (1 + dComm) * (1 + dPrice);
  const simCostOfSales = baseCogs + simWaste;
  const simEbitda = simSales - simCostOfSales - simComm - baseOpex;

  const deltaEbitda = simEbitda - baseEbitda;
  const simEbitdaPct = simSales ? (simEbitda / simSales) * 100 : 0;
  const baseEbitdaPct = baseSales ? (baseEbitda / baseSales) * 100 : 0;

  document.getElementById('sim-kpi-container').innerHTML = `
    <div class="kpi-card">
      <div class="kpi-header"><span class="kpi-title">Simulasi Net Sales</span></div>
      <div class="kpi-value">${fmtRpCompact(simSales)}</div>
      <div class="kpi-delta ${simSales >= baseSales ? 'good' : 'bad'}">
        ${simSales >= baseSales ? '▲ +' : '▼ -'}${fmtRp(Math.abs(simSales - baseSales))}
      </div>
    </div>

    <div class="kpi-card">
      <div class="kpi-header"><span class="kpi-title">Simulasi Komisi Platform</span></div>
      <div class="kpi-value">${fmtRpCompact(simComm)}</div>
      <div class="kpi-delta ${simComm <= baseComm ? 'good' : 'bad'}">
        ${simComm <= baseComm ? '▼ -' : '▲ +'}${fmtRp(Math.abs(simComm - baseComm))}
      </div>
    </div>

    <div class="kpi-card">
      <div class="kpi-header"><span class="kpi-title">Simulasi Outlet EBITDA</span></div>
      <div class="kpi-value">${fmtRpCompact(simEbitda)}</div>
      <div class="kpi-delta ${deltaEbitda >= 0 ? 'good' : 'bad'}">
        ${deltaEbitda >= 0 ? '▲ +' : '▼ -'}${fmtRp(Math.abs(deltaEbitda))} vs Baseline
      </div>
    </div>

    <div class="kpi-card">
      <div class="kpi-header"><span class="kpi-title">Simulasi EBITDA Margin</span></div>
      <div class="kpi-value">${fmtPct(simEbitdaPct)}</div>
      <div class="kpi-delta ${simEbitdaPct >= baseEbitdaPct ? 'good' : 'bad'}">
        ${(simEbitdaPct - baseEbitdaPct).toFixed(1)} pp vs ${fmtPct(baseEbitdaPct)}
      </div>
    </div>
  `;

  // Simulator chart
  const ctxSim = document.getElementById('chart-sim-comparison').getContext('2d');
  if (state.charts.sim) state.charts.sim.destroy();

  state.charts.sim = new Chart(ctxSim, {
    type: 'bar',
    data: {
      labels: ['Net Sales', 'Cost of Sales (COGS + Waste)', 'Komisi Kanal', 'Outlet EBITDA'],
      datasets: [
        { label: 'Baseline Saat Ini', data: [baseSales, baseCogs + baseWaste, baseComm, baseEbitda], backgroundColor: '#E2E8F0', borderRadius: 6 },
        { label: 'Skenario Simulasi Baru', data: [simSales, simCostOfSales, simComm, simEbitda], backgroundColor: '#F8B602', borderRadius: 6 },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { labels: { color: '#464E5F' } },
        tooltip: { callbacks: { label: (ctx) => `${ctx.dataset.label}: ${fmtRp(ctx.raw)}` } },
      },
      scales: {
        x: { grid: { color: '#F0F1F6' }, ticks: { color: '#7E8299' } },
        y: { grid: { color: '#F0F1F6' }, ticks: { color: '#7E8299', callback: (v) => 'Rp ' + (v / 1e6).toFixed(0) + 'M' } },
      },
    },
  });
}

// TAB 6: MARTS DATA EXPLORER
function setupExplorer() {
  document.getElementById('select-explorer-mart').addEventListener('change', (e) => {
    state.explorer.mart = e.target.value;
    state.explorer.page = 1;
    renderExplorer();
  });

  document.getElementById('input-explorer-search').addEventListener('input', (e) => {
    state.explorer.search = e.target.value.toLowerCase();
    state.explorer.page = 1;
    renderExplorer();
  });

  document.getElementById('btn-page-prev').addEventListener('click', () => {
    if (state.explorer.page > 1) {
      state.explorer.page--;
      renderExplorer();
    }
  });

  document.getElementById('btn-page-next').addEventListener('click', () => {
    state.explorer.page++;
    renderExplorer();
  });

  document.getElementById('btn-export-csv').addEventListener('click', exportExplorerCsv);
}

function renderExplorer() {
  const rows = state.data[state.explorer.mart] || [];
  const search = state.explorer.search;

  let filtered = rows;
  if (search) {
    filtered = rows.filter((r) => Object.values(r).some((v) => String(v).toLowerCase().includes(search)));
  }

  const thead = document.querySelector('#table-explorer thead');
  const tbody = document.querySelector('#table-explorer tbody');

  if (filtered.length === 0) {
    thead.innerHTML = '';
    tbody.innerHTML = '<tr><td style="text-align:center;">Tidak ada data ditemukan</td></tr>';
    document.getElementById('explorer-pagination-info').textContent = '0 dari 0 baris';
    return;
  }

  const cols = Object.keys(filtered[0]);
  thead.innerHTML = `<tr>${cols.map((c) => `<th>${c}</th>`).join('')}</tr>`;

  const total = filtered.length;
  const start = (state.explorer.page - 1) * state.explorer.pageSize;
  const end = Math.min(start + state.explorer.pageSize, total);
  const pagedRows = filtered.slice(start, end);

  tbody.innerHTML = pagedRows
    .map((r) => `<tr>${cols.map((c) => `<td>${r[c] !== null && r[c] !== undefined ? r[c] : '-'}</td>`).join('')}</tr>`)
    .join('');

  document.getElementById('explorer-pagination-info').textContent = `Menampilkan ${start + 1}–${end} dari ${fmtNum(total)} baris`;
}

function exportExplorerCsv() {
  const rows = state.data[state.explorer.mart] || [];
  if (rows.length === 0) return;
  const cols = Object.keys(rows[0]);
  let csv = cols.join(',') + '\n';
  rows.forEach((r) => {
    csv += cols.map((c) => `"${String(r[c] || '').replace(/"/g, '""')}"`).join(',') + '\n';
  });

  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `${state.explorer.mart}.csv`;
  a.click();
}
