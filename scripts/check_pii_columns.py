"""Gagal jika kolom bernama mirip PII tidak ditandai meta.pii di YAML model."""
import pathlib
import re
import sys

import yaml

PII = re.compile(r"(email|phone|telp|full_name|address|alamat|birth|nik|account_number)", re.I)
ALLOWED = {"hashed", "generalized", "dropped"}

bad = []
model_dir = sys.argv[1] if len(sys.argv) > 1 else "dbt/models"
for path in pathlib.Path(model_dir).rglob("*.yml"):
    try:
        doc = yaml.safe_load(path.read_text()) or {}
    except Exception:
        continue
    for model in doc.get("models", []):
        for col in model.get("columns", []):
            meta = (col.get("config") or {}).get("meta") or col.get("meta") or {}
            if PII.search(col.get("name", "")) and meta.get("pii") not in ALLOWED:
                bad.append(f"{path}: {model.get('name', 'unknown')}.{col.get('name', '')}")

print("\n".join(bad) or "PII guard OK")
sys.exit(1 if bad else 0)
