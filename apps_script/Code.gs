/**
 * F&B Reporting: sync mart BigQuery -> Google Sheets, alert KPI, web dashboard.
 * KPI & threshold dihitung di dbt (mart_kpi_monthly_status); script ini tidak mendefinisikan ulang rumus.
 */
const TZ = 'Asia/Jakarta';
const MAX_BYTES_BILLED = '2000000000';
const RP = 'Rp#,##0';
const PCT = '0.00"%"';

function cfg_() {
  const p = PropertiesService.getScriptProperties();
  const projectId = p.getProperty('GCP_PROJECT_ID') || 'fnb-data-platform';
  return {
    projectId: projectId,
    location: p.getProperty('BQ_LOCATION') || 'asia-southeast2',
    dataset: p.getProperty('BQ_DATASET') || 'marts',
    alertEmails: p.getProperty('ALERT_EMAILS') || Session.getEffectiveUser().getEmail(),
  };
}

function table_(name) {
  const c = cfg_();
  return '`' + c.projectId + '.' + c.dataset + '.' + name + '`';
}

// ------------------------------------------------------------------ BigQuery
function runQuery_(sql) {
  const c = cfg_();
  let res = BigQuery.Jobs.query({
    query: sql,
    useLegacySql: false,
    location: c.location,
    maximumBytesBilled: MAX_BYTES_BILLED,
    timeoutMs: 30000,
  }, c.projectId);

  const jobId = res.jobReference.jobId;
  let waitMs = 500;
  while (!res.jobComplete) {
    Utilities.sleep(waitMs);
    waitMs = Math.min(waitMs * 2, 8000);
    res = BigQuery.Jobs.getQueryResults(c.projectId, jobId, { location: c.location, timeoutMs: 30000 });
  }

  const fields = res.schema.fields;
  let rows = res.rows || [];
  let pageToken = res.pageToken;
  while (pageToken) {
    const page = BigQuery.Jobs.getQueryResults(c.projectId, jobId, { location: c.location, pageToken: pageToken });
    rows = rows.concat(page.rows || []);
    pageToken = page.pageToken;
  }

  return {
    header: fields.map(f => f.name),
    types: fields.map(f => f.type),
    values: rows.map(r => r.f.map((cell, i) => cast_(cell.v, fields[i].type))),
  };
}

function cast_(v, type) {
  if (v === null || v === undefined) return '';
  if (['INTEGER', 'INT64', 'FLOAT', 'FLOAT64', 'NUMERIC', 'BIGNUMERIC'].indexOf(type) >= 0) return Number(v);
  if (type === 'BOOLEAN' || type === 'BOOL') return v === true || v === 'true';
  return v;
}

// ------------------------------------------------------------------ Sheets
function ss_() {
  const active = SpreadsheetApp.getActiveSpreadsheet();
  if (active) return active;
  const sheetId = PropertiesService.getScriptProperties().getProperty('SPREADSHEET_ID');
  if (!sheetId) {
    throw new Error('Spreadsheet tidak ditemukan. Jika script dijalankan standalone (bukan container-bound), set Script Property "SPREADSHEET_ID".');
  }
  return SpreadsheetApp.openById(sheetId);
}

/** Tulis hasil query ke tab; format & chart di tab dipertahankan (clearContents, bukan clear). */
function writeTable_(sheetName, result, formats) {
  const sh = ss_().getSheetByName(sheetName) || ss_().insertSheet(sheetName);
  sh.clearContents();
  const nRows = result.values.length;
  const nCols = result.header.length;

  result.types.forEach((t, i) => {
    if ((t === 'STRING' || t === 'DATE') && nRows > 0) sh.getRange(2, i + 1, nRows, 1).setNumberFormat('@');
  });

  sh.getRange(1, 1, 1, nCols).setValues([result.header])
    .setFontWeight('bold').setBackground('#1f4e78').setFontColor('#ffffff');
  if (nRows > 0) sh.getRange(2, 1, nRows, nCols).setValues(result.values);

  Object.keys(formats || {}).forEach(fmt => {
    formats[fmt].forEach(col => {
      const idx = result.header.indexOf(col);
      if (idx >= 0 && nRows > 0) sh.getRange(2, idx + 1, nRows, 1).setNumberFormat(fmt);
    });
  });
  sh.setFrozenRows(1);
}

function appendLog_(startedAt, status, detail) {
  const sh = ss_().getSheetByName('_sync_log') || ss_().insertSheet('_sync_log');
  if (sh.getLastRow() === 0) sh.appendRow(['started_at', 'finished_at', 'status', 'detail']);
  const fmt = d => Utilities.formatDate(d, TZ, 'yyyy-MM-dd HH:mm:ss');
  sh.appendRow([fmt(startedAt), fmt(new Date()), status, detail]);
}

// ------------------------------------------------------------------ Sync
function syncAll() {
  const startedAt = new Date();
  try {
    syncPnl_();
    const kpi = syncKpi_();
    syncWaste_();
    syncMenu_();
    notifyAlerts_(kpi);
    PropertiesService.getScriptProperties().setProperty('LAST_SYNC', startedAt.toISOString());
    appendLog_(startedAt, 'OK', 'pnl,kpi,waste,menu');
  } catch (e) {
    appendLog_(startedAt, 'ERROR', String(e && e.message));
    MailApp.sendEmail(cfg_().alertEmails, '[F&B Report] Sync gagal', String(e && e.stack));
    throw e;
  }
}

function syncPnl_() {
  const sql = `
    SELECT
      FORMAT_DATE('%Y-%m', report_month)                         AS month,
      IFNULL(outlet_id, 'ALL')                                   AS outlet,
      LOGICAL_AND(is_complete_month)                             AS is_complete_month,
      SUM(order_count)                                           AS order_count,
      SUM(gross_sales)                                           AS gross_sales,
      SUM(discounts)                                             AS discounts,
      SUM(refunds)                                               AS refunds,
      SUM(net_sales)                                             AS net_sales,
      SUM(cogs_standard)                                         AS cogs_standard,
      SUM(waste_cost)                                            AS waste_cost,
      SUM(inventory_variance_cost)                               AS inventory_variance,
      SUM(actual_cost_of_sales)                                  AS cost_of_sales,
      SUM(gross_profit)                                          AS gross_profit,
      SUM(channel_commission)                                    AS channel_commission,
      SUM(payment_fees)                                          AS payment_fees,
      SUM(labor_cost)                                            AS labor_cost,
      SUM(other_opex)                                            AS other_opex,
      SUM(channel_commission) + SUM(payment_fees) + SUM(labor_cost) + SUM(other_opex) AS total_opex,
      SUM(outlet_ebitda)                                         AS ebitda,
      ROUND(SAFE_DIVIDE(SUM(net_sales), SUM(order_count)), 0)                                   AS avg_order_value,
      ROUND(SAFE_DIVIDE(SUM(gross_profit), SUM(net_sales)) * 100, 2)                           AS gross_margin_pct,
      ROUND(SAFE_DIVIDE(SUM(actual_cost_of_sales), SUM(net_sales)) * 100, 2)                   AS food_cost_pct,
      ROUND(SAFE_DIVIDE(SUM(waste_cost), SUM(net_sales)) * 100, 2)                             AS waste_pct,
      ROUND(SAFE_DIVIDE(SUM(inventory_variance_cost), SUM(net_sales)) * 100, 2)                AS inventory_variance_pct,
      ROUND(SAFE_DIVIDE(SUM(labor_cost), SUM(net_sales)) * 100, 2)                             AS labor_cost_pct,
      ROUND(SAFE_DIVIDE(SUM(actual_cost_of_sales) + SUM(labor_cost), SUM(net_sales)) * 100, 2) AS prime_cost_pct,
      ROUND(SAFE_DIVIDE(SUM(channel_commission) + SUM(payment_fees) + SUM(labor_cost) + SUM(other_opex), SUM(net_sales)) * 100, 2) AS opex_ratio_pct,
      ROUND(SAFE_DIVIDE(SUM(outlet_ebitda), SUM(net_sales)) * 100, 2)                          AS ebitda_margin_pct,
      ROUND(SAFE_DIVIDE(SUM(discounts), SUM(gross_sales)) * 100, 2)                            AS discount_rate_pct
    FROM ${table_('mart_pnl_monthly')}
    WHERE report_month >= DATE_SUB(DATE_TRUNC(CURRENT_DATE('${TZ}'), MONTH), INTERVAL 12 MONTH)
    GROUP BY GROUPING SETS ((report_month, outlet_id), (report_month))
    ORDER BY month DESC, outlet`;
  writeTable_('PnL_Monthly', runQuery_(sql), {
    [RP]: ['gross_sales', 'discounts', 'refunds', 'net_sales', 'cogs_standard', 'waste_cost', 'inventory_variance',
           'cost_of_sales', 'gross_profit', 'channel_commission', 'payment_fees', 'labor_cost', 'other_opex',
           'total_opex', 'ebitda', 'avg_order_value'],
    [PCT]: ['gross_margin_pct', 'food_cost_pct', 'waste_pct', 'inventory_variance_pct', 'labor_cost_pct',
            'prime_cost_pct', 'opex_ratio_pct', 'ebitda_margin_pct', 'discount_rate_pct'],
  });
}

function syncKpi_() {
  const sql = `
    SELECT FORMAT_DATE('%Y-%m', report_month) AS month, outlet_id AS outlet, is_complete_month,
           metric_code, metric_name, metric_value, warn_threshold, critical_threshold, status
    FROM ${table_('mart_kpi_monthly_status')}
    WHERE report_month >= DATE_SUB(DATE_TRUNC(CURRENT_DATE('${TZ}'), MONTH), INTERVAL 1 MONTH)
    ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END, month DESC, outlet, metric_code`;
  const result = runQuery_(sql);
  writeTable_('KPI_Status', result, { [PCT]: ['metric_value', 'warn_threshold', 'critical_threshold'] });
  return result;
}

function syncWaste_() {
  const sql = `
    SELECT outlet_id AS outlet, reason_name, controllability,
           ROUND(SUM(waste_cost), 0) AS waste_cost
    FROM ${table_('mart_waste_analysis')}
    WHERE waste_date >= DATE_SUB(CURRENT_DATE('${TZ}'), INTERVAL 90 DAY)
    GROUP BY 1, 2, 3
    ORDER BY waste_cost DESC`;
  writeTable_('Waste_By_Reason', runQuery_(sql), { [RP]: ['waste_cost'] });
}

function syncMenu_() {
  const sql = `
    SELECT outlet_id AS outlet, menu_name, category_name, menu_class, qty_sold,
           ROUND(menu_mix_pct * 100, 2) AS menu_mix_pct, ROUND(avg_contribution_margin, 0) AS avg_cm
    FROM ${table_('mart_menu_engineering')}
    WHERE report_month = COALESCE(
      (SELECT MAX(report_month) FROM ${table_('mart_menu_engineering')} WHERE report_month < DATE_TRUNC(CURRENT_DATE('${TZ}'), MONTH)),
      (SELECT MAX(report_month) FROM ${table_('mart_menu_engineering')})
    )
    ORDER BY outlet, qty_sold DESC`;
  writeTable_('Menu_Engineering', runQuery_(sql), { [RP]: ['avg_cm'], [PCT]: ['menu_mix_pct'] });
}

// ------------------------------------------------------------------ Alert
function escapeHtml_(str) {
  if (str === null || str === undefined) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function notifyAlerts_(kpi) {
  const h = kpi.header;
  const col = name => h.indexOf(name);
  const alerts = kpi.values.filter(r =>
    (r[col('is_complete_month')] === true && r[col('status')] !== 'OK') ||
    (r[col('is_complete_month')] === false && r[col('status')] === 'CRITICAL'));
  const props = PropertiesService.getScriptProperties();
  if (alerts.length === 0) {
    props.deleteProperty('LAST_ALERT_SIG');
    return;
  }

  const sigPayload = alerts
    .map(r => [r[col('month')], r[col('outlet')], r[col('metric_code')], r[col('status')]].join(':'))
    .sort()
    .join('|');
  const signature = Utilities.base64Encode(
    Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, sigPayload));
  if (props.getProperty('LAST_ALERT_SIG') === signature) return;

  const rowsHtml = alerts.map(r =>
    `<tr><td>${escapeHtml_(r[col('month')])}${r[col('is_complete_month')] ? '' : ' (MTD)'}</td>` +
    `<td>${escapeHtml_(r[col('outlet')])}</td>` +
    `<td>${escapeHtml_(r[col('metric_name')])}</td>` +
    `<td>${escapeHtml_(r[col('metric_value')])}%</td>` +
    `<td>${escapeHtml_(r[col('warn_threshold')])}% / ${escapeHtml_(r[col('critical_threshold')])}%</td>` +
    `<td style="color:${r[col('status')] === 'CRITICAL' ? '#b00020' : '#a15c00'}"><b>${escapeHtml_(r[col('status')])}</b></td></tr>`
  ).join('');

  MailApp.sendEmail({
    to: cfg_().alertEmails,
    subject: `[F&B KPI] ${alerts.length} metrik di luar threshold`,
    htmlBody:
      '<p>KPI berikut melewati threshold (sumber: dbt mart_kpi_monthly_status).</p>' +
      '<table border="1" cellpadding="4" style="border-collapse:collapse">' +
      '<tr><th>Bulan</th><th>Outlet</th><th>Metrik</th><th>Nilai</th><th>Warn / Critical</th><th>Status</th></tr>' +
      rowsHtml + '</table>' +
      `<p><a href="${ss_().getUrl()}">Buka laporan</a></p>`,
  });
  props.setProperty('LAST_ALERT_SIG', signature);
}

// ------------------------------------------------------------------ Trigger & Web app
function installTriggers() {
  ScriptApp.getProjectTriggers()
    .filter(t => t.getHandlerFunction() === 'syncAll')
    .forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('syncAll').timeBased().everyDays(1).atHour(7).inTimezone(TZ).create();
}

function onOpen() {
  SpreadsheetApp.getUi().createMenu('F&B Report')
    .addItem('Sync sekarang', 'syncAll')
    .addItem('Pasang trigger harian', 'installTriggers')
    .addToUi();
}

function doGet() {
  return HtmlService.createHtmlOutputFromFile('Dashboard')
    .setTitle('F&B Performance Hub')
    .addMetaTag('viewport', 'width=device-width, initial-scale=1');
}

/** Dipanggil dari Dashboard.html via google.script.run. Hanya membaca tab cache (tanpa query BigQuery). */
function getDashboardData() {
  const read = name => {
    const sh = ss_().getSheetByName(name);
    if (!sh || sh.getLastRow() < 2) return [];
    const values = sh.getDataRange().getValues();
    const header = values.shift();
    return values.map(r => {
      const o = {};
      header.forEach((k, i) => { o[k] = r[i] instanceof Date ? r[i].toISOString() : r[i]; });
      return o;
    });
  };
  return {
    pnl: read('PnL_Monthly'),
    kpi: read('KPI_Status'),
    waste: read('Waste_By_Reason'),
    menu: read('Menu_Engineering'),
    lastSync: PropertiesService.getScriptProperties().getProperty('LAST_SYNC'),
  };
}
