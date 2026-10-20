"""Gagal jika kolom bernama mirip PII / gaji individual tidak ditandai meta.pii di YAML model.

meta.pii yang sah: hashed, generalized, dropped, aggregated (agregat ber-k-anonymity), dan restricted
(apa adanya) - restricted HANYA sah untuk model di folder */restricted/ (dataset hr_restricted).
"""
import pathlib
import re
import sys

import yaml

PII = re.compile(r"(email|phone|telp|mobile|hp|dob|birth|nik|national_id|account_number|full_name|address|alamat"
                 r"|salary|base_pay|net_pay|gross_pay|rating)", re.I)
NAME_EXEMPTIONS = {
    "outlet_name", "menu_name", "channel_name", "reason_name",
    "category_name", "metric_name", "table_name", "supplier_name",
    "ingredient_name",
}
ALLOWED = {"hashed", "generalized", "dropped", "aggregated"}
RESTRICTED_ONLY = {"restricted"}

bad = []
model_dir = sys.argv[1] if len(sys.argv) > 1 else "dbt/models"
for path in pathlib.Path(model_dir).rglob("*.yml"):
    try:
        doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    except Exception as e:
        print(f"Warning: gagal parse YAML di {path}: {e}", file=sys.stderr)
        continue
    for model in doc.get("models", []):
        for col in model.get("columns", []):
            col_name = col.get("name", "")
            meta = (col.get("config") or {}).get("meta") or col.get("meta") or {}
            is_pii = bool(PII.search(col_name))
            if not is_pii and re.search(r"(^|_)name$", col_name, re.I) and col_name.lower() not in NAME_EXEMPTIONS:
                is_pii = True
            if not is_pii:
                continue
            tag = meta.get("pii")
            in_restricted = "restricted" in path.parts
            if tag in RESTRICTED_ONLY and not in_restricted:
                bad.append(f"{path}: {model.get('name', 'unknown')}.{col_name} (pii: restricted di luar folder restricted)")
            elif tag not in ALLOWED and not (tag in RESTRICTED_ONLY and in_restricted):
                bad.append(f"{path}: {model.get('name', 'unknown')}.{col_name}")

# Scan dashboard exported JSON files if directory exists
data_candidates = [pathlib.Path("dashboard/public/data"), pathlib.Path("../dashboard/public/data")]
data_dirs = [d for d in data_candidates if d.exists()]
for data_dir in data_dirs:
    raw_email_re = re.compile(r'"[a-zA-Z0-9_.+-]+@[a-zA-Z0-9-]+\.[a-zA-Z0-9-.]+"')
    raw_phone_re = re.compile(r'"(?:\+62|08)[0-9]{8,12}"')
    for jpath in data_dir.glob("*.json"):
        text = jpath.read_text(encoding="utf-8")
        if raw_email_re.search(text) or raw_phone_re.search(text):
            bad.append(f"{jpath}: Terdeteksi raw email/nomor telepon di file JSON publik!")

print("\n".join(bad) or "PII guard OK")
sys.exit(1 if bad else 0)
