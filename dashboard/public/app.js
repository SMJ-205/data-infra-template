/**
 * F&B Multi-Outlet Analytics Platform
 * Front-end Application logic & Chart.js rendering
 */

// State
const state = {
  data: {},
  meta: null,
  activeTab: 'pnl',
  selectedOutlet: 'ALL',
  selectedMonth: 'ALL',
  selectedCategory: 'ALL',
  explorer: {
    mart: 'pnl_monthly',
    search: '',
    page: 1,
    pageSize: 25,
  },
  charts: {},
};

// Utilities
const fmtRp = (v) => 'Rp ' + Math.round(Number(v) || 0).toLocaleString('id-ID');
const fmtPct = (v) => (v === null || v === undefined || isNaN(v) ? '-' : (Number(v)).toFixed(1) + '%');
const fmtNum = (v) => Math.round(Number(v) || 0).toLocaleString('id-ID');

// Initialize application
document.addEventListener('DOMContentLoaded', async () => {
  setupTabs();
  setupFilterListeners();
  setupSimulator();
  setupExplorer();
  await loadData();
});

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

  document.getElementById('select-month').addEventListener('change', (e) => {
    state.selectedMonth = e.target.value;
    renderActiveTab();
  });

  document.getElementById('select-menu-category').addEventListener('change', (e) => {
    state.selectedCategory = e.target.value;
    renderMenuEngineering();
  });
}

// Data Fetching
async function loadData() {
  const badgeSync = document.getElementById('badge-sync');
  try {
    const metaRes = await fetch('data/meta.json');
    state.meta = await metaRes.json();
    if (state.meta.generated_at_utc) {
      const date = new Date(state.meta.generated_at_utc);
      badgeSync.textContent = `🕒 Sync: ${date.toLocaleString('id-ID', { timeZone: 'Asia/Jakarta' })} WIB`;
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
    ];

    await Promise.all(
      files.map(async (file) => {
        const res = await fetch(`data/${file}.json`);
        state.data[file] = await res.json();
      })
    );

    const totalRows = Object.values(state.meta.rows || {}).reduce((a, b) => a + b, 0);
    document.getElementById('badge-records-count').textContent = `Total Data: ${fmtNum(totalRows)} baris (${state.meta.total_size_kb || 0} KB)`;

    populateFilters();
    renderActiveTab();
  } catch (err) {
    console.error('Error loading data:', err);
    badgeSync.textContent = '❌ Gagal memuat data JSON';
  }
}

function populateFilters() {
  // Populate outlets
  const outletsSet = new Set();
  (state.data.pnl_monthly || []).forEach((r) => {
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

  // Populate months
  const monthsSet = new Set();
  (state.data.pnl_monthly || []).forEach((r) => {
    if (r.report_month) monthsSet.add(r.report_month);
  });
  const selectMonth = document.getElementById('select-month');
  selectMonth.innerHTML = '<option value="ALL">Semua Bulan (Trailing)</option>';
  [...monthsSet].sort().reverse().forEach((month) => {
    const opt = document.createElement('option');
    opt.value = month;
    opt.textContent = month;
    selectMonth.appendChild(opt);
  });
}

function renderActiveTab() {
  switch (state.activeTab) {
    case 'pnl':
      renderExecutivePnL();
      break;
    case 'cost':
      renderCostControl();
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
function renderExecutivePnL() {
  const pnlMonthly = state.data.pnl_monthly || [];
  let filtered = pnlMonthly;
  if (state.selectedOutlet !== 'ALL') {
    filtered = filtered.filter((r) => r.outlet_id === state.selectedOutlet);
  }

  // Monthly aggregated totals
  const monthsMap = {};
  filtered.forEach((r) => {
    const m = r.report_month;
    if (!monthsMap[m]) {
      monthsMap[m] = {
        month: m,
        net_sales: 0,
        gross_sales: 0,
        discounts: 0,
        actual_cost_of_sales: 0,
        cogs_standard: 0,
        waste_cost: 0,
        channel_commission: 0,
        payment_fees: 0,
        labor_cost: 0,
        other_opex: 0,
        gross_profit: 0,
        outlet_ebitda: 0,
        order_count: 0,
      };
    }
    monthsMap[m].net_sales += Number(r.net_sales) || 0;
    monthsMap[m].gross_sales += Number(r.gross_sales) || 0;
    monthsMap[m].discounts += Number(r.discounts) || 0;
    monthsMap[m].actual_cost_of_sales += Number(r.actual_cost_of_sales) || 0;
    monthsMap[m].cogs_standard += Number(r.cogs_standard) || 0;
    monthsMap[m].waste_cost += Number(r.waste_cost) || 0;
    monthsMap[m].channel_commission += Number(r.channel_commission) || 0;
    monthsMap[m].payment_fees += Number(r.payment_fees) || 0;
    monthsMap[m].labor_cost += Number(r.labor_cost) || 0;
    monthsMap[m].other_opex += Number(r.other_opex) || 0;
    monthsMap[m].gross_profit += Number(r.gross_profit) || 0;
    monthsMap[m].outlet_ebitda += Number(r.outlet_ebitda) || 0;
    monthsMap[m].order_count += Number(r.order_count) || 0;
  });

  const sortedMonths = Object.keys(monthsMap).sort();
  const latestMonthKey = state.selectedMonth !== 'ALL' ? state.selectedMonth : sortedMonths[sortedMonths.length - 1];
  const prevMonthKey = sortedMonths[sortedMonths.indexOf(latestMonthKey) - 1];

  const cur = monthsMap[latestMonthKey] || {};
  const prev = monthsMap[prevMonthKey] || {};

  // KPI Calculations
  const curFoodCostPct = (cur.actual_cost_of_sales / cur.net_sales) * 100 || 0;
  const prevFoodCostPct = (prev.actual_cost_of_sales / prev.net_sales) * 100 || 0;

  const curPrimeCostPct = ((cur.actual_cost_of_sales + cur.labor_cost) / cur.net_sales) * 100 || 0;
  const prevPrimeCostPct = ((prev.actual_cost_of_sales + prev.labor_cost) / prev.net_sales) * 100 || 0;

  const curWastePct = (cur.waste_cost / cur.net_sales) * 100 || 0;
  const prevWastePct = (prev.waste_cost / prev.net_sales) * 100 || 0;

  const curEbitdaPct = (cur.outlet_ebitda / cur.net_sales) * 100 || 0;
  const prevEbitdaPct = (prev.outlet_ebitda / prev.net_sales) * 100 || 0;

  const curAov = cur.order_count ? cur.net_sales / cur.order_count : 0;
  const prevAov = prev.order_count ? prev.net_sales / prev.order_count : 0;

  // Render Cards
  const cardsHtml = `
    <div class="kpi-card highlight-cyan">
      <div class="kpi-header">
        <span class="kpi-title">Net Sales</span>
        <span class="badge-tag badge-plowhorse">${latestMonthKey}</span>
      </div>
      <div class="kpi-value">${fmtRp(cur.net_sales)}</div>
      <div class="kpi-delta ${cur.net_sales >= prev.net_sales ? 'good' : 'bad'}">
        ${cur.net_sales >= prev.net_sales ? '▲' : '▼'} ${fmtRp(Math.abs(cur.net_sales - prev.net_sales))} vs MoM
      </div>
      <div class="kpi-subtext">Gross: ${fmtRp(cur.gross_sales)} (Diskon ${fmtRp(cur.discounts)})</div>
    </div>

    <div class="kpi-card highlight-rose">
      <div class="kpi-header">
        <span class="kpi-title">Actual Food Cost %</span>
        <span class="badge-tag ${curFoodCostPct <= 32 ? 'badge-status-ok' : 'badge-status-critical'}">Target ≤ 32%</span>
      </div>
      <div class="kpi-value">${fmtPct(curFoodCostPct)}</div>
      <div class="kpi-delta ${curFoodCostPct <= prevFoodCostPct ? 'good' : 'bad'}">
        ${curFoodCostPct <= prevFoodCostPct ? '▼' : '▲'} ${Math.abs(curFoodCostPct - prevFoodCostPct).toFixed(1)} pp vs MoM
      </div>
      <div class="kpi-subtext">HPP Aktual: ${fmtRp(cur.actual_cost_of_sales)}</div>
    </div>

    <div class="kpi-card highlight-amber">
      <div class="kpi-header">
        <span class="kpi-title">Prime Cost % (HPP + Labor)</span>
        <span class="badge-tag ${curPrimeCostPct <= 60 ? 'badge-status-ok' : 'badge-status-warn'}">Target ≤ 60%</span>
      </div>
      <div class="kpi-value">${fmtPct(curPrimeCostPct)}</div>
      <div class="kpi-delta ${curPrimeCostPct <= prevPrimeCostPct ? 'good' : 'bad'}">
        ${curPrimeCostPct <= prevPrimeCostPct ? '▼' : '▲'} ${Math.abs(curPrimeCostPct - prevPrimeCostPct).toFixed(1)} pp vs MoM
      </div>
      <div class="kpi-subtext">Labor Opex: ${fmtRp(cur.labor_cost)}</div>
    </div>

    <div class="kpi-card highlight-rose">
      <div class="kpi-header">
        <span class="kpi-title">Waste to Sales %</span>
        <span class="badge-tag ${curWastePct <= 2 ? 'badge-status-ok' : 'badge-status-warn'}">Target ≤ 2%</span>
      </div>
      <div class="kpi-value">${fmtPct(curWastePct)}</div>
      <div class="kpi-delta ${curWastePct <= prevWastePct ? 'good' : 'bad'}">
        ${curWastePct <= prevWastePct ? '▼' : '▲'} ${Math.abs(curWastePct - prevWastePct).toFixed(1)} pp vs MoM
      </div>
      <div class="kpi-subtext">Biaya Limbah: ${fmtRp(cur.waste_cost)}</div>
    </div>

    <div class="kpi-card highlight-emerald">
      <div class="kpi-header">
        <span class="kpi-title">Outlet EBITDA Margin</span>
        <span class="badge-tag badge-status-ok">Bottom-Line</span>
      </div>
      <div class="kpi-value">${fmtPct(curEbitdaPct)}</div>
      <div class="kpi-delta ${curEbitdaPct >= prevEbitdaPct ? 'good' : 'bad'}">
        ${curEbitdaPct >= prevEbitdaPct ? '▲' : '▼'} ${Math.abs(curEbitdaPct - prevEbitdaPct).toFixed(1)} pp vs MoM
      </div>
      <div class="kpi-subtext">EBITDA: ${fmtRp(cur.outlet_ebitda)}</div>
    </div>

    <div class="kpi-card highlight-purple">
      <div class="kpi-header">
        <span class="kpi-title">Avg Order Value (AOV)</span>
        <span class="badge-tag badge-puzzle">${fmtNum(cur.order_count)} Order</span>
      </div>
      <div class="kpi-value">${fmtRp(curAov)}</div>
      <div class="kpi-delta ${curAov >= prevAov ? 'good' : 'bad'}">
        ${curAov >= prevAov ? '▲' : '▼'} ${fmtRp(Math.abs(curAov - prevAov))} vs MoM
      </div>
      <div class="kpi-subtext">Keranjang Belanja Bersih</div>
    </div>
  `;
  document.getElementById('kpi-cards-container').innerHTML = cardsHtml;

  // Render Monthly Trend Chart
  renderTrendChart(sortedMonths, monthsMap);

  // Render Waterfall Chart
  renderWaterfallChart(cur);

  // Render KPI Status Table
  renderKpiTable(latestMonthKey);
}

function renderTrendChart(months, map) {
  const ctx = document.getElementById('chart-pnl-trend').getContext('2d');
  if (state.charts.trend) state.charts.trend.destroy();

  const labels = months;
  const netSales = months.map((m) => map[m].net_sales);
  const foodCostPct = months.map((m) => ((map[m].actual_cost_of_sales / map[m].net_sales) * 100).toFixed(1));

  state.charts.trend = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: labels,
      datasets: [
        {
          type: 'bar',
          label: 'Net Sales (IDR)',
          data: netSales,
          backgroundColor: 'rgba(56, 189, 248, 0.45)',
          borderColor: '#38bdf8',
          borderWidth: 1,
          borderRadius: 4,
          yAxisID: 'ySales',
        },
        {
          type: 'line',
          label: 'Food Cost %',
          data: foodCostPct,
          borderColor: '#ef4444',
          backgroundColor: '#ef4444',
          borderWidth: 2,
          pointRadius: 4,
          pointHoverRadius: 6,
          yAxisID: 'yPct',
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      interaction: { mode: 'index', intersect: false },
      plugins: {
        legend: { labels: { color: '#94a3b8' } },
        tooltip: {
          callbacks: {
            label: (ctx) => {
              if (ctx.dataset.yAxisID === 'ySales') return `Net Sales: ${fmtRp(ctx.raw)}`;
              return `Food Cost: ${ctx.raw}%`;
            },
          },
        },
      },
      scales: {
        x: { grid: { color: 'rgba(255, 255, 255, 0.05)' }, ticks: { color: '#94a3b8' } },
        ySales: {
          type: 'linear',
          position: 'left',
          grid: { color: 'rgba(255, 255, 255, 0.05)' },
          ticks: { color: '#94a3b8', callback: (v) => 'Rp ' + (v / 1e6).toFixed(0) + 'M' },
        },
        yPct: {
          type: 'linear',
          position: 'right',
          min: 20,
          max: 45,
          grid: { drawOnChartArea: false },
          ticks: { color: '#f87171', callback: (v) => v + '%' },
        },
      },
    },
  });
}

function renderWaterfallChart(cur) {
  const ctx = document.getElementById('chart-waterfall').getContext('2d');
  if (state.charts.waterfall) state.charts.waterfall.destroy();

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
    if (i === 0 || i === 2) return 'rgba(56, 189, 248, 0.7)';
    if (i === 8) return v >= 0 ? 'rgba(16, 185, 129, 0.8)' : 'rgba(244, 63, 94, 0.8)';
    return 'rgba(244, 63, 94, 0.65)';
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
          borderRadius: 4,
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
        x: { grid: { color: 'rgba(255, 255, 255, 0.05)' }, ticks: { color: '#94a3b8', font: { size: 10 } } },
        y: {
          grid: { color: 'rgba(255, 255, 255, 0.05)' },
          ticks: { color: '#94a3b8', callback: (v) => 'Rp ' + (v / 1e6).toFixed(0) + 'M' },
        },
      },
    },
  });
}

function renderKpiTable(monthKey) {
  const kpiData = state.data.kpi_status || [];
  let filtered = kpiData.filter((r) => r.report_month === monthKey);
  if (state.selectedOutlet !== 'ALL') {
    filtered = filtered.filter((r) => r.outlet_id === state.selectedOutlet);
  }

  const tbody = document.querySelector('#table-kpi-status tbody');
  if (filtered.length === 0) {
    tbody.innerHTML = '<tr><td colspan="4" style="text-align:center;">Tidak ada data KPI</td></tr>';
    return;
  }

  tbody.innerHTML = filtered
    .map((r) => {
      const badgeCls = r.status === 'OK' ? 'badge-status-ok' : r.status === 'WARN' ? 'badge-status-warn' : 'badge-status-critical';
      return `
      <tr>
        <td><strong>${r.metric_name}</strong></td>
        <td>${fmtPct(r.metric_value)}</td>
        <td>Warn: ${fmtPct(r.warn_threshold)} | Crit: ${fmtPct(r.critical_threshold)}</td>
        <td><span class="badge-tag ${badgeCls}">${r.status}</span></td>
      </tr>
    `;
    })
    .join('');
}

// TAB 2: COST CONTROL & VARIANCE
function renderCostControl() {
  const variances = state.data.inventory_variance || [];
  const wasteData = state.data.waste || [];
  const pnlMonthly = state.data.pnl_monthly || [];

  // 1. Top 10 Variance by ingredient
  const ingMap = {};
  variances.forEach((r) => {
    if (state.selectedOutlet !== 'ALL' && r.outlet_id !== state.selectedOutlet) return;
    const ing = r.ingredient_id;
    if (!ingMap[ing]) ingMap[ing] = 0;
    ingMap[ing] += Number(r.unexplained_variance_value) || 0;
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
          data: sortedIngs.map((i) => i[1]),
          backgroundColor: 'rgba(239, 68, 68, 0.65)',
          borderColor: '#ef4444',
          borderWidth: 1,
          borderRadius: 4,
        },
      ],
    },
    options: {
      indexAxis: 'y',
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { display: false },
        tooltip: { callbacks: { label: (ctx) => fmtRp(ctx.raw) } },
      },
      scales: {
        x: { grid: { color: 'rgba(255, 255, 255, 0.05)' }, ticks: { color: '#94a3b8', callback: (v) => 'Rp ' + (v / 1e3).toFixed(0) + 'k' } },
        y: { ticks: { color: '#94a3b8' } },
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
          backgroundColor: [
            'rgba(244, 63, 94, 0.75)',
            'rgba(245, 158, 11, 0.75)',
            'rgba(56, 189, 248, 0.75)',
            'rgba(168, 85, 247, 0.75)',
            'rgba(16, 185, 129, 0.75)',
          ],
          borderColor: '#0f172a',
          borderWidth: 2,
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { position: 'right', labels: { color: '#94a3b8', font: { size: 11 } } },
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
          data: sortedMonths.map((m) => ((monthsMap[m].theo / monthsMap[m].sales) * 100).toFixed(2)),
          borderColor: '#38bdf8',
          backgroundColor: '#38bdf8',
          borderWidth: 2,
        },
        {
          label: 'Actual Food Cost % (Termasuk Stock Opname Variance)',
          data: sortedMonths.map((m) => ((monthsMap[m].act / monthsMap[m].sales) * 100).toFixed(2)),
          borderColor: '#ef4444',
          backgroundColor: '#ef4444',
          borderWidth: 2,
          borderDash: [5, 5],
        },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { labels: { color: '#94a3b8' } },
        tooltip: { callbacks: { label: (ctx) => `${ctx.dataset.label}: ${ctx.raw}%` } },
      },
      scales: {
        x: { grid: { color: 'rgba(255, 255, 255, 0.05)' }, ticks: { color: '#94a3b8' } },
        y: { grid: { color: 'rgba(255, 255, 255, 0.05)' }, ticks: { color: '#94a3b8', callback: (v) => v + '%' } },
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
  if (state.selectedCategory !== 'ALL') {
    filtered = filtered.filter((r) => r.category_name === state.selectedCategory);
  }

  // Deduplicate menu items for latest month
  const latestMonth = [...new Set(filtered.map((r) => r.report_month))].sort().pop();
  const latestItems = filtered.filter((r) => r.report_month === latestMonth);

  const ctxMenu = document.getElementById('chart-menu-engineering').getContext('2d');
  if (state.charts.menu) state.charts.menu.destroy();

  // Groups by class
  const classColors = {
    Star: { bg: 'rgba(245, 158, 11, 0.8)', border: '#f59e0b' },
    Plowhorse: { bg: 'rgba(56, 189, 248, 0.8)', border: '#38bdf8' },
    Puzzle: { bg: 'rgba(168, 85, 247, 0.8)', border: '#a855f7' },
    Dog: { bg: 'rgba(244, 63, 94, 0.8)', border: '#f43f5e' },
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
      pointRadius: 6,
      pointHoverRadius: 9,
    };
  });

  state.charts.menu = new Chart(ctxMenu, {
    type: 'scatter',
    data: { datasets: datasets },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { labels: { color: '#94a3b8' } },
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
          title: { display: true, text: 'Popularitas (Menu Mix %)', color: '#94a3b8' },
          grid: { color: 'rgba(255, 255, 255, 0.05)' },
          ticks: { color: '#94a3b8', callback: (v) => v + '%' },
        },
        y: {
          title: { display: true, text: 'Rata-rata Margin Kontribusi (IDR)', color: '#94a3b8' },
          grid: { color: 'rgba(255, 255, 255, 0.05)' },
          ticks: { color: '#94a3b8', callback: (v) => 'Rp ' + (v / 1e3).toFixed(0) + 'k' },
        },
      },
    },
  });

  // Table
  const strategyRec = {
    Star: 'Pertahankan kualitas & spesifikasi resep secara ketat; menu flagship utama.',
    Plowhorse: 'Tinjau kenaikan harga bertahap atau kurangi porsi bahan mahal (re-engineer).',
    Puzzle: 'Tingkatkan visibilitas di aplikasi delivery, bundling paket promo barista pick.',
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
        <td style="color: var(--text-secondary); font-size: 12px;">${strategyRec[r.menu_class]}</td>
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
        { label: 'Net Sales', data: channels.map((c) => chMap[c].sales), backgroundColor: 'rgba(56, 189, 248, 0.7)' },
        { label: 'Komisi Platform', data: channels.map((c) => chMap[c].comm), backgroundColor: 'rgba(239, 68, 68, 0.7)' },
        { label: 'Margin Kontribusi', data: channels.map((c) => chMap[c].contrib), backgroundColor: 'rgba(16, 185, 129, 0.7)' },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { labels: { color: '#94a3b8' } },
        tooltip: { callbacks: { label: (ctx) => `${ctx.dataset.label}: ${fmtRp(ctx.raw)}` } },
      },
      scales: {
        x: { grid: { color: 'rgba(255, 255, 255, 0.05)' }, ticks: { color: '#94a3b8' } },
        y: { grid: { color: 'rgba(255, 255, 255, 0.05)' }, ticks: { color: '#94a3b8', callback: (v) => 'Rp ' + (v / 1e6).toFixed(0) + 'M' } },
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
          backgroundColor: 'rgba(168, 85, 247, 0.7)',
          borderRadius: 4,
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
        x: { grid: { color: 'rgba(255, 255, 255, 0.05)' }, ticks: { color: '#94a3b8' } },
        y: { grid: { color: 'rgba(255, 255, 255, 0.05)' }, ticks: { color: '#94a3b8', callback: (v) => fmtRp(v) } },
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
      const bg = intensity === 0 ? 'rgba(255, 255, 255, 0.03)' : `rgba(56, 189, 248, ${0.15 + intensity * 0.8})`;
      const color = intensity > 0.4 ? '#fff' : 'rgba(255, 255, 255, 0.5)';
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
  const pnlMonthly = state.data.pnl_monthly || [];
  let baseSales = 0,
    baseCogs = 0,
    baseWaste = 0,
    baseComm = 0,
    baseOpex = 0,
    baseEbitda = 0;

  pnlMonthly.forEach((r) => {
    if (state.selectedOutlet !== 'ALL' && r.outlet_id !== state.selectedOutlet) return;
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
    <div class="kpi-card highlight-cyan">
      <div class="kpi-header"><span class="kpi-title">Simulasi Net Sales</span></div>
      <div class="kpi-value">${fmtRp(simSales)}</div>
      <div class="kpi-delta ${simSales >= baseSales ? 'good' : 'bad'}">
        ${simSales >= baseSales ? '▲ +' : '▼ '}${fmtRp(simSales - baseSales)}
      </div>
    </div>

    <div class="kpi-card highlight-rose">
      <div class="kpi-header"><span class="kpi-title">Simulasi Komisi Platform</span></div>
      <div class="kpi-value">${fmtRp(simComm)}</div>
      <div class="kpi-delta ${simComm <= baseComm ? 'good' : 'bad'}">
        ${simComm <= baseComm ? '▼ -' : '▲ +'}${fmtRp(Math.abs(simComm - baseComm))}
      </div>
    </div>

    <div class="kpi-card highlight-emerald">
      <div class="kpi-header"><span class="kpi-title">Simulasi Outlet EBITDA</span></div>
      <div class="kpi-value">${fmtRp(simEbitda)}</div>
      <div class="kpi-delta ${deltaEbitda >= 0 ? 'good' : 'bad'}">
        ${deltaEbitda >= 0 ? '▲ +' : '▼ '}${fmtRp(deltaEbitda)} vs Baseline
      </div>
    </div>

    <div class="kpi-card highlight-purple">
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
        { label: 'Baseline Saat Ini', data: [baseSales, baseCogs + baseWaste, baseComm, baseEbitda], backgroundColor: 'rgba(148, 163, 184, 0.6)' },
        { label: 'Skenario Simulasi Baru', data: [simSales, simCostOfSales, simComm, simEbitda], backgroundColor: 'rgba(56, 189, 248, 0.8)' },
      ],
    },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      plugins: {
        legend: { labels: { color: '#94a3b8' } },
        tooltip: { callbacks: { label: (ctx) => `${ctx.dataset.label}: ${fmtRp(ctx.raw)}` } },
      },
      scales: {
        x: { grid: { color: 'rgba(255, 255, 255, 0.05)' }, ticks: { color: '#94a3b8' } },
        y: { grid: { color: 'rgba(255, 255, 255, 0.05)' }, ticks: { color: '#94a3b8', callback: (v) => 'Rp ' + (v / 1e6).toFixed(0) + 'M' } },
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
