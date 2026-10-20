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
const escapeHtml = (str) => {
  if (str === null || str === undefined) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
};

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

function parseUtcDate(dateStr) {
  const [y, m, d] = dateStr.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d));
}

function dateAddDays(dateStr, days) {
  const d = parseUtcDate(dateStr);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().split('T')[0];
}

function getDaysBetween(startStr, endStr) {
  const d1 = parseUtcDate(startStr);
  const d2 = parseUtcDate(endStr);
  return Math.max(1, Math.round((d2 - d1) / (1000 * 60 * 60 * 24)) + 1);
}

function getShortMonthName(m) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];
  return months[m - 1] || `Bln ${m}`;
}

function getComparisonDateRange(start, end, preset) {
  const dStart = parseUtcDate(start);
  const dEnd = parseUtcDate(end);
  const dayCount = getDaysBetween(start, end);

  const startDay = dStart.getUTCDate();
  const endDay = dEnd.getUTCDate();
  const startMonth = dStart.getUTCMonth();
  const startYear = dStart.getUTCFullYear();
  const endMonth = dEnd.getUTCMonth();
  const endYear = dEnd.getUTCFullYear();

  // If preset is MTD or range starts on day 1 and is within the same month: compare apple-to-apple with same day range last month
  if (preset === 'MTD' || (startDay === 1 && startMonth === endMonth && startYear === endYear)) {
    let prevYear = startYear;
    let prevMonth = startMonth - 1;
    if (prevMonth < 0) {
      prevMonth = 11;
      prevYear -= 1;
    }
    const daysInPrevMonth = new Date(Date.UTC(prevYear, prevMonth + 1, 0)).getUTCDate();
    const targetEndDay = Math.min(endDay, daysInPrevMonth);

    const pad = (n) => String(n).padStart(2, '0');
    const prevStart = `${prevYear}-${pad(prevMonth + 1)}-01`;
    const prevEnd = `${prevYear}-${pad(prevMonth + 1)}-${pad(targetEndDay)}`;
    const compDays = targetEndDay;
    const compLabel = `vs 1-${targetEndDay} ${getShortMonthName(prevMonth + 1)} (${compDays} hr)`;
    return { prevStart, prevEnd, compLabel, dayCount };
  }

  // Otherwise: compare with immediately preceding N days
  const prevEnd = dateAddDays(start, -1);
  const prevStart = dateAddDays(prevEnd, -(dayCount - 1));
  const pStartParts = prevStart.split('-');
  const pEndParts = prevEnd.split('-');
  const compLabel = `vs ${pStartParts[1]}-${pStartParts[2]} s/d ${pEndParts[1]}-${pEndParts[2]} (${dayCount} hr)`;
  return { prevStart, prevEnd, compLabel, dayCount };
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
    btn.addEventListener('click', async () => {
      tabBtns.forEach((b) => b.classList.remove('active'));
      document.querySelectorAll('.tab-section').forEach((sec) => sec.classList.remove('active'));

      btn.classList.add('active');
      const tabId = btn.getAttribute('data-tab');
      state.activeTab = tabId;
      const targetSec = document.getElementById(`sec-${tabId}`);
      if (targetSec) targetSec.classList.add('active');

      await renderActiveTab();
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
  const activatePill = (pill) => {
    pills.forEach((p) => p.classList.remove('active'));
    pill.classList.add('active');
    const cat = pill.getAttribute('data-cat');
    state.selectedCategory = cat;

    const selectMenuCat = document.getElementById('select-menu-category');
    if (selectMenuCat) selectMenuCat.value = cat;

    renderActiveTab();
  };

  pills.forEach((pill) => {
    pill.setAttribute('role', 'button');
    pill.setAttribute('tabindex', '0');
    pill.addEventListener('click', () => activatePill(pill));
    pill.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        activatePill(pill);
      }
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

// Data Fetching & Lazy Loading Architecture
const TAB_DATA_DEPENDENCIES = {
  pnl: ['pnl_monthly', 'pnl_daily', 'kpi_status'],
  cost: ['inventory_variance', 'waste'],
  stock: ['inventory_position', 'inventory_status'],
  menu: ['menu_engineering'],
  channel: ['channel_daily', 'orders_hourly'],
  simulator: ['pnl_daily', 'category_daily'],
  explorer: ['pnl_monthly'],
};

async function fetchFile(file) {
  if (state.data[file]) return state.data[file];
  const ver = state.meta && state.meta.generated_at_utc ? encodeURIComponent(state.meta.generated_at_utc) : Date.now();
  try {
    const res = await fetch(`data/${file}.json?v=${ver}`);
    if (!res.ok) {
      console.warn(`File ${file}.json status HTTP ${res.status}`);
      state.data[file] = [];
      return [];
    }
    const data = await res.json();
    state.data[file] = data;
    return data;
  } catch (err) {
    console.error(`Error loading ${file}.json:`, err);
    state.data[file] = [];
    return [];
  }
}

async function ensureDataForTab(tabId) {
  const deps = TAB_DATA_DEPENDENCIES[tabId] || [];
  const missing = deps.filter((f) => !state.data[f]);
  if (missing.length > 0) {
    await Promise.all(missing.map((f) => fetchFile(f)));
  }
}

async function loadData() {
  const badgeSync = document.getElementById('badge-sync');
  try {
    const metaRes = await fetch(`data/meta.json?t=${Date.now()}`);
    if (!metaRes.ok) throw new Error(`meta.json HTTP ${metaRes.status}`);
    state.meta = await metaRes.json();
    if (state.meta.generated_at_utc) {
      const date = new Date(state.meta.generated_at_utc);
      const dataThru = state.meta.data_through ? `Data s/d ${state.meta.data_through} • ` : '';
      badgeSync.textContent = `${dataThru}Sync: ${date.toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })} WIB`;
    }

    const totalRows = Object.values(state.meta.rows || {}).reduce((a, b) => a + b, 0);
    document.getElementById('badge-records-count').textContent = `Total: ${fmtNum(totalRows)} baris (${state.meta.total_size_kb || 0} KB)`;

    // 1. Muat hanya data esensial untuk Tab Utama (P&L) terlebih dahulu secara instan (<300ms)
    const criticalFiles = ['pnl_daily', 'pnl_monthly', 'kpi_status'];
    await Promise.all(criticalFiles.map((f) => fetchFile(f)));

    populateFilters();
    await renderActiveTab();

    // 2. Prefetch sisa file di latar belakang agar siap ketika tab lain dibuka
    const backgroundFiles = [
      'category_daily',
      'menu_engineering',
      'inventory_variance',
      'waste',
      'inventory_position',
      'inventory_status',
      'channel_daily',
      'orders_hourly',
    ];
    setTimeout(() => {
      Promise.all(backgroundFiles.map((f) => fetchFile(f))).catch((e) => console.warn('Background prefetch notice:', e));
    }, 150);
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
  state.lastDataDate = (state.meta && state.meta.data_through) || state.maxAvailableDate;
  if (state.meta && state.meta.data_through && state.meta.data_through < state.maxAvailableDate) {
    state.maxAvailableDate = state.meta.data_through;
  }

  // Set default preset to MTD (Bulan Terakhir)
  applyDatePreset('MTD');
}

async function renderActiveTab() {
  await ensureDataForTab(state.activeTab);
  switch (state.activeTab) {
    case 'pnl':
      renderPnlExecutive();
      break;
    case 'cost':
      renderCostVariance();
      break;
    case 'stock':
      renderStock();
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
      await fetchFile(state.explorer.mart);
      renderExplorer();
      break;
  }
}

// TAB 1: EXECUTIVE P&L
function renderPnlExecutive() {
  const { start, end } = state.dateRange;
  if (!start || !end) return;

  const { prevStart, prevEnd, compLabel, dayCount } = getComparisonDateRange(start, end, state.datePreset);
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
        return `<div class="kpi-delta neutral">- n/a (${compLabel}) -</div>`;
      }
      const diff = currentVal - previousVal;
      if (Math.abs(diff) < 0.001) {
        return `<div class="kpi-delta neutral">0${isPct ? '.0 pp' : ''} ${compLabel}</div>`;
      }
      const isGood = higherIsGood ? diff >= 0 : diff <= 0;
      const arrow = diff >= 0 ? '▲ +' : '▼ -';
      const valStr = isPct ? `${Math.abs(diff).toFixed(1)} pp` : fmtRp(Math.abs(diff));
      return `<div class="kpi-delta ${isGood ? 'good' : 'bad'}">${arrow}${valStr} ${compLabel}</div>`;
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
        return `<div class="kpi-delta neutral">- n/a (${compLabel}) -</div>`;
      }
      const diff = currentVal - previousVal;
      if (Math.abs(diff) < 0.001) {
        return `<div class="kpi-delta neutral">0${isPct ? '.0 pp' : ''} ${compLabel}</div>`;
      }
      const isGood = higherIsGood ? diff >= 0 : diff <= 0;
      const arrow = diff >= 0 ? '▲ +' : '▼ -';
      const valStr = isPct ? `${Math.abs(diff).toFixed(1)} pp` : fmtRp(Math.abs(diff));
      return `<div class="kpi-delta ${isGood ? 'good' : 'bad'}">${arrow}${valStr} ${compLabel}</div>`;
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
      dayMap[d].cost += isCategoryMode
        ? (Number(r.cogs_standard) || 0)
        : (Number(r.cost_of_sales || r.actual_cost_of_sales) || 0);
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
      mCountMap[m].cost += isCategoryMode
        ? (Number(r.cogs_standard) || 0)
        : (Number(r.cost_of_sales || r.actual_cost_of_sales) || 0);
    });
    const sortedMonths = Object.keys(mCountMap).sort();
    labels = sortedMonths;
    netSales = sortedMonths.map((m) => mCountMap[m].net);
    foodCostPct = sortedMonths.map((m) => (mCountMap[m].net ? Number(((mCountMap[m].cost / mCountMap[m].net) * 100).toFixed(1)) : null));
  }

  const seriesLabel = isCategoryMode ? `${categoryTitle} Net Sales (IDR)` : 'Net Sales (IDR)';
  const costSeriesLabel = isCategoryMode ? 'Theoretical Food Cost % (Resep)' : 'Actual Food Cost %';

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
          label: costSeriesLabel,
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
              return `${costSeriesLabel}: ${ctx.raw}%`;
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
      const badgeCls = `badge-status-${escapeHtml(r.status).toLowerCase()}`;
      return `
      <tr>
        <td><strong>${escapeHtml(r.metric_name)}</strong></td>
        <td>${escapeHtml(val)}</td>
        <td>${escapeHtml(symbol)} ${escapeHtml(th)}</td>
        <td><span class="badge-tag ${badgeCls}">${escapeHtml(r.status)}</span></td>
      </tr>
    `;
    })
    .join('');

  const scope = state.selectedOutlet === 'ALL' ? 'konsolidasi seluruh outlet' : `outlet ${state.selectedOutlet}`;
  const note = `<tr><td colspan="4"><span class="data-note">Bulan ${escapeHtml(monthKey.substring(0, 7))} (${escapeHtml(scope)}).${
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

// TAB: STOK & SUSUT (fct_inventory_balance_daily)
const OUTLET_COLORS = { 'FLG-01': '#2F80ED', 'KIOSK-02': '#F8B602', 'CLOUD-03': '#8950FC' };
const STOCK_STATUS_ORDER = { Habis: 0, Kritis: 1, 'Risiko Kedaluwarsa': 2, 'Tidak Bergerak': 3, Normal: 4 };
const STOCK_STATUS_BADGE = {
  Habis: 'badge-status-critical',
  Kritis: 'badge-status-critical',
  'Risiko Kedaluwarsa': 'badge-status-warn',
  'Tidak Bergerak': 'badge-puzzle',
  Normal: 'badge-status-ok',
};
const rpAxisTick = (v) => {
  const a = Math.abs(v);
  if (a >= 1e6) return 'Rp ' + (v / 1e6).toFixed(1) + 'jt';
  if (a >= 1e3) return 'Rp ' + (v / 1e3).toFixed(0) + 'rb';
  return 'Rp ' + v;
};
const fmtQty = (v, digits = 1) =>
  v === null || v === undefined || isNaN(v) ? '-' : Number(v).toLocaleString('id-ID', { maximumFractionDigits: digits });

function renderStock() {
  const { start, end } = state.dateRange;
  const outletOk = (r) => state.selectedOutlet === 'ALL' || r.outlet_id === state.selectedOutlet;
  const pos = (state.data.inventory_position || []).filter(outletOk);
  const status = (state.data.inventory_status || []).filter(outletOk);
  const inRange = pos.filter((r) => (!start || r.balance_date >= start) && (!end || r.balance_date <= end));

  // KPI: posisi pada tanggal terakhir dalam rentang, susut sepanjang rentang
  const lastDate = inRange.reduce((m, r) => (r.balance_date > m ? r.balance_date : m), '');
  const lastRows = inRange.filter((r) => r.balance_date === lastDate);
  const sum = (rows, k) => rows.reduce((a, r) => a + (Number(r[k]) || 0), 0);
  const stockValue = sum(lastRows, 'on_hand_value');
  const usageValue28 = sum(lastRows, 'avg_daily_usage_value_28d');
  const daysOnHand = usageValue28 ? stockValue / usageValue28 : null;
  const shrink = sum(inRange, 'shrinkage_value');
  const usage = sum(inRange, 'usage_value');
  const shrinkPct = usage ? (shrink / usage) * 100 : null;
  const countDays = new Set(inRange.filter((r) => r.is_count_day).map((r) => r.balance_date)).size;
  const urgent = status.filter((r) => r.stock_status === 'Habis' || r.stock_status === 'Kritis').length;
  const expiryRisk = status.filter((r) => r.stock_status === 'Risiko Kedaluwarsa').length;
  const asOf = status.length ? status[0].as_of_date : '-';

  document.getElementById('kpi-stock-container').innerHTML = `
    <div class="kpi-card">
      <div class="kpi-header">
        <span class="kpi-title">Nilai Stok Akhir</span>
        <div class="kpi-badge-row"><span class="badge-tag badge-star">${escapeHtml(lastDate || '-')}</span></div>
      </div>
      <div class="kpi-value">${fmtRpCompact(stockValue)}</div>
      <div class="kpi-subtext">Dinilai dengan standard cost per tanggal</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-header">
        <span class="kpi-title">Hari Stok (Days on Hand)</span>
        <div class="kpi-badge-row"><span class="badge-tag badge-puzzle">Berbobot nilai</span></div>
      </div>
      <div class="kpi-value">${daysOnHand === null ? '-' : fmtQty(daysOnHand, 1) + ' hari'}</div>
      <div class="kpi-subtext">Pemakaian rata-rata 28 hari: ${fmtRp(usageValue28)} / hari</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-header">
        <span class="kpi-title">Susut Opname (Rentang)</span>
        <div class="kpi-badge-row">
          <span class="badge-tag ${shrinkPct !== null && shrinkPct > 2 ? 'badge-status-critical' : 'badge-status-ok'}">Target ≤ 2%</span>
        </div>
      </div>
      <div class="kpi-value">${fmtRpCompact(shrink)}</div>
      <div class="kpi-subtext">${fmtPct(shrinkPct)} dari pemakaian teoretis • ${countDays} hari opname</div>
    </div>
    <div class="kpi-card">
      <div class="kpi-header">
        <span class="kpi-title">Bahan Perlu Tindakan</span>
        <div class="kpi-badge-row">
          <span class="badge-tag ${urgent > 0 ? 'badge-status-critical' : 'badge-status-ok'}">Per ${escapeHtml(asOf)}</span>
        </div>
      </div>
      <div class="kpi-value">${fmtNum(urgent)}</div>
      <div class="kpi-subtext">Habis/Kritis • ${fmtNum(expiryRisk)} berisiko kedaluwarsa</div>
    </div>`;

  // Chart 1: nilai stok harian (satu garis per outlet)
  const dates = [...new Set(inRange.map((r) => r.balance_date))].sort();
  const outlets = [...new Set(inRange.map((r) => r.outlet_id))].sort();
  const byKey = {};
  inRange.forEach((r) => (byKey[`${r.outlet_id}|${r.balance_date}`] = r));
  if (state.charts.stockValue) state.charts.stockValue.destroy();
  state.charts.stockValue = new Chart(document.getElementById('chart-stock-value').getContext('2d'), {
    type: 'line',
    data: {
      labels: dates,
      datasets: outlets.map((o) => ({
        label: o,
        data: dates.map((d) => (byKey[`${o}|${d}`] ? Number(byKey[`${o}|${d}`].on_hand_value) : null)),
        borderColor: OUTLET_COLORS[o] || '#7E8299',
        backgroundColor: OUTLET_COLORS[o] || '#7E8299',
        borderWidth: 2,
        pointRadius: 0,
        tension: 0.2,
      })),
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      interaction: { mode: 'index', intersect: false },
      plugins: {
        legend: { labels: { color: '#464E5F' } },
        tooltip: { callbacks: { label: (ctx) => `${ctx.dataset.label}: ${fmtRp(ctx.raw)}` } },
      },
      scales: {
        x: { grid: { display: false }, ticks: { color: '#7E8299', maxTicksLimit: 10 } },
        y: { grid: { color: '#F0F1F6' }, ticks: { color: '#7E8299', callback: rpAxisTick } },
      },
    },
  });

  // Chart 2: susut opname per bulan per outlet (seluruh bulan)
  const shrinkMap = {};
  pos.forEach((r) => {
    if (!r.is_count_day) return;
    const m = String(r.balance_date).substring(0, 7);
    shrinkMap[m] = shrinkMap[m] || {};
    shrinkMap[m][r.outlet_id] = (shrinkMap[m][r.outlet_id] || 0) + (Number(r.shrinkage_value) || 0);
  });
  const months = Object.keys(shrinkMap).sort();
  const allOutlets = [...new Set(pos.map((r) => r.outlet_id))].sort();
  if (state.charts.shrinkMonthly) state.charts.shrinkMonthly.destroy();
  state.charts.shrinkMonthly = new Chart(document.getElementById('chart-shrink-monthly').getContext('2d'), {
    type: 'bar',
    data: {
      labels: months,
      datasets: allOutlets.map((o) => ({
        label: o,
        data: months.map((m) => Math.round(shrinkMap[m][o] || 0)),
        backgroundColor: OUTLET_COLORS[o] || '#7E8299',
        borderRadius: 4,
      })),
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { labels: { color: '#464E5F' } },
        tooltip: { callbacks: { label: (ctx) => `${ctx.dataset.label}: ${fmtRp(ctx.raw)}` } },
      },
      scales: {
        x: { stacked: true, grid: { display: false }, ticks: { color: '#7E8299' } },
        y: { stacked: true, grid: { color: '#F0F1F6' }, ticks: { color: '#7E8299', callback: rpAxisTick } },
      },
    },
  });

  // Tabel status bahan
  const rows = [...status].sort(
    (a, b) =>
      (STOCK_STATUS_ORDER[a.stock_status] ?? 9) - (STOCK_STATUS_ORDER[b.stock_status] ?? 9) ||
      (Number(b.shrinkage_value_90d) || 0) - (Number(a.shrinkage_value_90d) || 0)
  );
  document.getElementById('stock-status-desc').textContent =
    `Posisi per ${asOf} (tanggal saldo terakhir), diurutkan dari yang paling mendesak lalu susut terbesar`;
  document.querySelector('#table-stock-status tbody').innerHTML =
    rows
      .map((r) => {
        const name = INGREDIENT_NAMES[r.ingredient_id] || r.ingredient_name || r.ingredient_id;
        const shrinkCls = (Number(r.shrinkage_pct_90d) || 0) > 2 ? 'style="color: var(--danger, #FF5B5B); font-weight: 700;"' : '';
        return `<tr>
          <td>${escapeHtml(r.outlet_id)}</td>
          <td><strong>${escapeHtml(name)}</strong><br><span class="data-note">${escapeHtml(r.ingredient_category || '')}</span></td>
          <td><span class="badge-tag ${STOCK_STATUS_BADGE[r.stock_status] || ''}">${escapeHtml(r.stock_status)}</span></td>
          <td>${fmtQty(r.on_hand_qty)} ${escapeHtml(r.base_uom || '')}</td>
          <td>${r.days_on_hand === null || r.days_on_hand === undefined ? '-' : fmtQty(r.days_on_hand, 1)}</td>
          <td>${fmtQty(r.avg_daily_usage_28d)} ${escapeHtml(r.base_uom || '')}</td>
          <td>${fmtRp(r.on_hand_value)}</td>
          <td ${shrinkCls}>${fmtPct(r.shrinkage_pct_90d)} <span class="data-note">(${fmtRp(r.shrinkage_value_90d)})</span></td>
          <td>${escapeHtml(r.last_count_date || '-')} <span class="data-note">(${fmtNum(r.days_since_last_count)} hr)</span></td>
        </tr>`;
      })
      .join('') || '<tr><td colspan="9">Data stok belum tersedia.</td></tr>';
}

// TAB 3: MENU ENGINEERING (Kasavana & Smith)
function renderMenuEngineering() {
  const menuData = state.data.menu_engineering || [];
  let outletFiltered = menuData;
  if (state.selectedOutlet !== 'ALL') {
    outletFiltered = outletFiltered.filter((r) => r.outlet_id === state.selectedOutlet);
  }

  // Deduplicate menu items for matching month in date range
  const targetMonth = state.dateRange.end ? state.dateRange.end.substring(0, 7) + '-01' : null;
  const availableMonths = [...new Set(outletFiltered.map((r) => r.report_month))].sort();
  const latestMonth = (targetMonth && availableMonths.includes(targetMonth))
    ? targetMonth
    : (availableMonths[availableMonths.length - 1] || '2026-05-01');

  const rawItems = outletFiltered.filter((r) => r.report_month === latestMonth);
  let evaluatedItems = rawItems;

  if (state.selectedOutlet === 'ALL') {
    const itemsMap = {};
    rawItems.forEach((r) => {
      const id = r.menu_item_id;
      if (!itemsMap[id]) {
        itemsMap[id] = {
          menu_item_id: id,
          menu_name: r.menu_name,
          category_name: r.category_name,
          qty_sold: 0,
          net_sales: 0,
          cogs_standard: 0,
        };
      }
      itemsMap[id].qty_sold += Number(r.qty_sold) || 0;
      itemsMap[id].net_sales += Number(r.net_sales) || 0;
      itemsMap[id].cogs_standard += Number(r.cogs_standard) || 0;
    });

    const consolidatedItems = Object.values(itemsMap);
    const totalQty = consolidatedItems.reduce((sum, i) => sum + i.qty_sold, 0);
    const totalCm = consolidatedItems.reduce((sum, i) => sum + (i.net_sales - i.cogs_standard), 0);
    const nItems = consolidatedItems.length;
    const weightedAvgCm = totalQty > 0 ? totalCm / totalQty : 0;
    const popThreshold = nItems > 0 ? 0.7 / nItems : 0;

    evaluatedItems = consolidatedItems.map((i) => {
      const avgCm = i.qty_sold > 0 ? (i.net_sales - i.cogs_standard) / i.qty_sold : 0;
      const mixPct = totalQty > 0 ? i.qty_sold / totalQty : 0;
      const isHighPop = mixPct >= popThreshold;
      const isHighProf = avgCm >= weightedAvgCm;
      let menuClass = 'Dog';
      if (isHighPop && isHighProf) menuClass = 'Star';
      else if (isHighPop) menuClass = 'Plowhorse';
      else if (isHighProf) menuClass = 'Puzzle';

      return {
        ...i,
        avg_contribution_margin: avgCm,
        menu_mix_pct: mixPct,
        menu_class: menuClass,
      };
    });
  }

  // Filter display by category if selected
  let latestItems = evaluatedItems;
  if (state.selectedCategory !== 'ALL' && CATEGORY_MAP[state.selectedCategory]) {
    const allowed = CATEGORY_MAP[state.selectedCategory];
    latestItems = latestItems.filter((r) => allowed.includes(r.category_name));
  }

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
      const badgeCls = `badge-${escapeHtml(r.menu_class).toLowerCase()}`;
      return `
      <tr>
        <td><strong>${escapeHtml(r.menu_name)}</strong></td>
        <td>${escapeHtml(r.category_name)}</td>
        <td><span class="badge-tag ${badgeCls}">${escapeHtml(r.menu_class)}</span></td>
        <td>${fmtNum(r.qty_sold)}</td>
        <td>${(Number(r.menu_mix_pct) * 100).toFixed(1)}%</td>
        <td>${fmtRp(r.avg_contribution_margin)}</td>
        <td style="color: var(--text-muted); font-size: 12px;">${escapeHtml(strategyRec[r.menu_class] || '')}</td>
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

      html += `<div class="heatmap-cell" style="background:${bg}; color:${color};" title="${escapeHtml(dayName)} jam ${h}:00 - ${fmtNum(count)} order">${count > 0 ? fmtNum(count) : '-'}</div>`;
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
    const cogs = (r.cogs_standard !== undefined) ? Number(r.cogs_standard) : (Number(r.cost_of_sales || 0) - Number(r.waste_cost || 0));
    baseCogs += Math.max(0, cogs);
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
  const baselineData = [baseSales, baseCogs + baseWaste, baseComm, baseEbitda];
  const simData = [simSales, simCostOfSales, simComm, simEbitda];

  if (state.charts.sim) {
    state.charts.sim.data.datasets[0].data = baselineData;
    state.charts.sim.data.datasets[1].data = simData;
    state.charts.sim.update('none');
  } else {
    const ctxSim = document.getElementById('chart-sim-comparison').getContext('2d');
    state.charts.sim = new Chart(ctxSim, {
      type: 'bar',
      data: {
        labels: ['Net Sales', 'Cost of Sales (COGS + Waste)', 'Komisi Kanal', 'Outlet EBITDA'],
        datasets: [
          { label: 'Baseline Saat Ini', data: baselineData, backgroundColor: '#E2E8F0', borderRadius: 6 },
          { label: 'Skenario Simulasi Baru', data: simData, backgroundColor: '#F8B602', borderRadius: 6 },
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
}

// TAB 6: MARTS DATA EXPLORER
function getFilteredExplorerRows() {
  const rows = state.data[state.explorer.mart] || [];
  const search = (state.explorer.search || '').trim().toLowerCase();
  if (!search) return rows;
  return rows.filter((r) => Object.values(r).some((v) => String(v !== null && v !== undefined ? v : '').toLowerCase().includes(search)));
}

function setupExplorer() {
  document.getElementById('select-explorer-mart').addEventListener('change', async (e) => {
    state.explorer.mart = e.target.value;
    state.explorer.page = 1;
    await fetchFile(state.explorer.mart);
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
    const filtered = getFilteredExplorerRows();
    const maxPage = Math.max(1, Math.ceil(filtered.length / state.explorer.pageSize));
    if (state.explorer.page < maxPage) {
      state.explorer.page++;
      renderExplorer();
    }
  });

  document.getElementById('btn-export-csv').addEventListener('click', exportExplorerCsv);
}

function renderExplorer() {
  const filtered = getFilteredExplorerRows();
  const thead = document.querySelector('#table-explorer thead');
  const tbody = document.querySelector('#table-explorer tbody');
  const btnPrev = document.getElementById('btn-page-prev');
  const btnNext = document.getElementById('btn-page-next');

  if (filtered.length === 0) {
    thead.innerHTML = '';
    tbody.innerHTML = '<tr><td style="text-align:center;">Tidak ada data ditemukan</td></tr>';
    document.getElementById('explorer-pagination-info').textContent = '0 dari 0 baris';
    if (btnPrev) btnPrev.disabled = true;
    if (btnNext) btnNext.disabled = true;
    return;
  }

  const total = filtered.length;
  const maxPage = Math.max(1, Math.ceil(total / state.explorer.pageSize));
  if (state.explorer.page > maxPage) state.explorer.page = maxPage;
  if (state.explorer.page < 1) state.explorer.page = 1;

  if (btnPrev) btnPrev.disabled = state.explorer.page <= 1;
  if (btnNext) btnNext.disabled = state.explorer.page >= maxPage;

  const cols = Object.keys(filtered[0]);
  thead.innerHTML = `<tr>${cols.map((c) => `<th>${escapeHtml(c)}</th>`).join('')}</tr>`;

  const start = (state.explorer.page - 1) * state.explorer.pageSize;
  const end = Math.min(start + state.explorer.pageSize, total);
  const pagedRows = filtered.slice(start, end);

  tbody.innerHTML = pagedRows
    .map((r) => `<tr>${cols.map((c) => `<td>${r[c] !== null && r[c] !== undefined ? escapeHtml(r[c]) : '-'}</td>`).join('')}</tr>`)
    .join('');

  document.getElementById('explorer-pagination-info').textContent = `Menampilkan ${start + 1}–${end} dari ${fmtNum(total)} baris (Hal ${state.explorer.page}/${maxPage})`;
}

function exportExplorerCsv() {
  const filtered = getFilteredExplorerRows();
  if (filtered.length === 0) return;
  const cols = Object.keys(filtered[0]);
  let csv = cols.join(',') + '\n';
  filtered.forEach((r) => {
    csv += cols.map((c) => {
      const val = (r[c] !== null && r[c] !== undefined) ? String(r[c]) : '';
      return `"${val.replace(/"/g, '""')}"`;
    }).join(',') + '\n';
  });

  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `${state.explorer.mart}.csv`;
  a.click();
}
