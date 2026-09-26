#!/usr/bin/env python3
import csv
import sys
from pathlib import Path

root, manifest_s, phase = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
samples = []
with manifest_s.open() as f:
    for row in csv.DictReader(f, delimiter="\t"):
        samples.append(row["sample_id"])
rows, missing = [], []
for sample in samples:
    p = root / "results" / sample / "summary.tsv"
    if not p.is_file() or not p.stat().st_size:
        missing.append(sample)
        continue
    with p.open() as f:
        rows.extend(csv.DictReader(f, delimiter="\t"))
out = root / "summary" / f"{phase}_human_mtDNA_crAssphage_signals.tsv"
out.parent.mkdir(parents=True, exist_ok=True)
fields = list(rows[0]) if rows else ["sample_id"]
with out.open("w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=fields, delimiter="\t", lineterminator="\n")
    w.writeheader(); w.writerows(rows)
(root / "summary" / f"{phase}_missing_samples.txt").write_text("\n".join(missing) + ("\n" if missing else ""))
print(f"phase={phase} target={len(samples)} results={len(rows)} missing={len(missing)} output={out}")

