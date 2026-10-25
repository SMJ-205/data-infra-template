"""Forecasting pemakaian bahan kelas A per outlet + Safety Stock & Reorder Point (analisis sekali jalan).

Dijalankan di GitHub Actions (.github/workflows/analysis_forecast.yml) atau lokal:
    set -a && source .env && set +a && python3 analysis/cost_inventory/forecast.py

Alur:
  1. Ambil pemakaian harian (resep + waste) per outlet x bahan dari BigQuery (queries/08_forecast_input.sql).
  2. Bahan kelas A (query 05) saja: nilai pemakaian terbesar, paling berdampak ke modal kerja.
  3. Backtest rolling-origin 8 minggu terakhir, horizon 7 hari, 3 model:
       - MA7: rata-rata 7 hari terakhir (baseline guideline)
       - Seasonal naive: nilai hari yang sama minggu lalu
       - Holt-Winters: exponential smoothing, musiman mingguan (aditif), tren teredam
     Metrik: MAPE harian per seri (hari tutup / pemakaian 0 dikeluarkan dari MAPE).
  4. Model terbaik per seri -> forecast 14 hari ke depan.
  5. Safety stock = z x sigma(error forecast harian) x sqrt(lead time); ROP = rata-rata forecast x lead time + SS.
     Lead time adalah ASUMSI (tidak ada di data sumber): 1 hari untuk bahan segar yang dikirim harian
     (umur simpan <= 4 hari), 2 hari untuk bahan lain. Service level 95% (z = 1,65).
Output CSV di analysis/cost_inventory/output/forecast_*.csv
"""
import os
import pathlib
import warnings

import numpy as np
import pandas as pd
from statsmodels.tsa.holtwinters import ExponentialSmoothing

warnings.filterwarnings("ignore")
HERE = pathlib.Path(__file__).parent
OUT = HERE / "output"
PROJECT = os.environ.get("GCP_PROJECT_ID", "fnb-data-platform")
CLOSED_DAYS = pd.to_datetime(["2026-03-20", "2026-03-21"])      # Lebaran: semua outlet tutup (outlier)
BACKTEST_WEEKS, HORIZON, FORECAST_DAYS = 8, 7, 14
Z_95 = 1.65


def load():
    from google.cloud import bigquery
    client = bigquery.Client(project=PROJECT, location="asia-southeast2")
    cfg = bigquery.QueryJobConfig(maximum_bytes_billed=2_000_000_000, labels={"app": "analysis_cost_inventory"})
    run = lambda name: client.query(
        (HERE / "queries" / name).read_text(encoding="utf-8").replace("fnb-data-platform", PROJECT),
        job_config=cfg).result().to_dataframe()
    usage, abc = run("08_forecast_input.sql"), run("05_abc_xyz.sql")
    usage["balance_date"] = pd.to_datetime(usage["balance_date"])
    return usage, abc


def fit_predict(train, model, horizon):
    if model == "MA7":
        return np.repeat(train.iloc[-7:].mean(), horizon)
    if model == "Seasonal naive":
        return np.resize(train.iloc[-7:].to_numpy(), horizon)
    fit = ExponentialSmoothing(train.to_numpy(), trend="add", damped_trend=True, seasonal="add",
                               seasonal_periods=7, initialization_method="estimated").fit(optimized=True)
    return np.clip(fit.forecast(horizon), 0, None)


def clean(series):
    """Hari tutup (Lebaran) diganti nilai hari yang sama minggu sebelumnya agar tidak merusak pola musiman."""
    s = series.copy()
    for d in CLOSED_DAYS:
        if d in s.index:
            s.loc[d] = s.get(d - pd.Timedelta(days=7), s.mean())
    return s


def mape(actual, pred):
    a, p = np.asarray(actual, float), np.asarray(pred, float)
    mask = a > 0
    return float(np.mean(np.abs((a[mask] - p[mask]) / a[mask])) * 100)


def main():
    OUT.mkdir(exist_ok=True)
    usage, abc = load()
    a_items = abc.loc[abc["abc_xyz"].str.startswith("A"), ["ingredient_id", "abc_xyz"]]
    usage = usage.merge(a_items, on="ingredient_id")
    last_day = usage["balance_date"].max()
    metrics, backtest_rows, forecasts, rops = [], [], [], []

    for (outlet, ing), g in usage.groupby(["outlet_id", "ingredient_id"]):
        g = g.set_index("balance_date").sort_index()
        s = clean(g["usage_qty"].astype(float).asfreq("D").fillna(0))
        if s.sum() == 0:
            continue
        origins = [last_day - pd.Timedelta(days=7 * k) for k in range(BACKTEST_WEEKS, 0, -1)]
        errors = {m: [] for m in ("MA7", "Seasonal naive", "Holt-Winters")}
        preds_all = {m: [] for m in errors}
        for origin in origins:
            train = s.loc[:origin]
            test = s.loc[origin + pd.Timedelta(days=1): origin + pd.Timedelta(days=HORIZON)]
            for m in errors:
                p = fit_predict(train, m, len(test))
                preds_all[m].append(pd.Series(p, index=test.index))
                errors[m].append(test.to_numpy() - p)
        scores = {}
        for m in errors:
            pred = pd.concat(preds_all[m])
            actual = s.loc[pred.index]
            scores[m] = mape(actual, pred)
            metrics.append(dict(outlet_id=outlet, ingredient_id=ing, ingredient_name=g["ingredient_name"].iloc[0],
                                base_uom=g["base_uom"].iloc[0], model=m, mape=round(scores[m], 2)))
            for d, v in pred.items():
                backtest_rows.append(dict(outlet_id=outlet, ingredient_id=ing, date=d.date(), model=m,
                                          actual=round(float(actual[d]), 2), forecast=round(float(v), 2)))
        best = min(scores, key=scores.get)
        resid = np.concatenate(errors[best])
        fc = fit_predict(s, best, FORECAST_DAYS)
        dates = pd.date_range(last_day + pd.Timedelta(days=1), periods=FORECAST_DAYS, freq="D")
        for d, v in zip(dates, fc):
            forecasts.append(dict(outlet_id=outlet, ingredient_id=ing, date=d.date(), model=best, forecast=round(float(v), 2)))

        shelf = g["shelf_life_days"].iloc[0]
        lead_time = 1 if pd.notna(shelf) and shelf <= 4 else 2
        daily = float(np.mean(fc))
        safety = Z_95 * float(np.std(resid, ddof=1)) * np.sqrt(lead_time)
        safety_ma7 = Z_95 * float(np.std(np.concatenate(errors["MA7"]), ddof=1)) * np.sqrt(lead_time)
        rop = daily * lead_time + safety
        on_hand = float(g["on_hand_qty"].iloc[-1])
        unit_cost = float(g["std_cost_per_unit"].iloc[-1])
        rops.append(dict(
            outlet_id=outlet, ingredient_id=ing, ingredient_name=g["ingredient_name"].iloc[0],
            base_uom=g["base_uom"].iloc[0], abc_xyz=g["abc_xyz"].iloc[0], best_model=best,
            mape_best=round(scores[best], 2), mape_ma7=round(scores["MA7"], 2),
            avg_daily_forecast=round(daily, 1), lead_time_days_assumed=lead_time,
            safety_stock=round(safety, 1), safety_stock_ma7=round(safety_ma7, 1), reorder_point=round(rop, 1),
            safety_stock_value=round(safety * unit_cost), safety_stock_value_ma7=round(safety_ma7 * unit_cost),
            on_hand_last_day=round(on_hand, 1), last_day=last_day.date()))

    pd.DataFrame(metrics).to_csv(OUT / "forecast_backtest_metrics.csv", index=False)
    pd.DataFrame(backtest_rows).to_csv(OUT / "forecast_backtest_series.csv", index=False)
    pd.DataFrame(forecasts).to_csv(OUT / "forecast_next14.csv", index=False)
    rop_df = pd.DataFrame(rops)
    rop_df.to_csv(OUT / "forecast_rop.csv", index=False)
    summary = pd.DataFrame(metrics).groupby("model")["mape"].agg(["mean", "median"]).round(2)
    print(summary)
    print(rop_df[["outlet_id", "ingredient_name", "best_model", "mape_best", "mape_ma7", "safety_stock",
                  "reorder_point", "safety_stock_value", "safety_stock_value_ma7"]].to_string(index=False))
    saved = rop_df["safety_stock_value_ma7"].sum() - rop_df["safety_stock_value"].sum()
    print(f"Safety stock: Rp {rop_df['safety_stock_value'].sum():,.0f} (model terbaik) vs "
          f"Rp {rop_df['safety_stock_value_ma7'].sum():,.0f} (MA7) -> hemat Rp {saved:,.0f}")


if __name__ == "__main__":
    main()
