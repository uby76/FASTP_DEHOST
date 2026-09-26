#!/usr/bin/env python3
import argparse
import csv
from pathlib import Path


def completed(batch: Path):
    status = batch / "status"
    clean = batch / "clean_reads"
    rows = {}
    for marker in sorted(status.glob("*.done")):
        sample = marker.name[:-5]
        r1 = clean / f"{sample}_clean_R1.fastq.gz"
        r2 = clean / f"{sample}_clean_R2.fastq.gz"
        if r1.is_file() and r1.stat().st_size and r2.is_file() and r2.stat().st_size:
            rows[sample] = (r1, r2, batch)
    return rows


p = argparse.ArgumentParser()
p.add_argument("--batch", action="append", required=True)
p.add_argument("--output", required=True)
p.add_argument("--audit", required=True)
p.add_argument("--exclude-done-dir")
p.add_argument("--exclude-manifest", action="append", default=[])
args = p.parse_args()

all_rows = {}
duplicates = []
for batch_s in args.batch:
    batch = Path(batch_s)
    for sample, value in completed(batch).items():
        if sample in all_rows:
            duplicates.append(sample)
        else:
            all_rows[sample] = value

excluded = set()
if args.exclude_done_dir:
    excluded = {p.name[:-5] for p in Path(args.exclude_done_dir).glob("*.done")}

assigned_to_prior_phase = set()
for manifest_s in args.exclude_manifest:
    manifest = Path(manifest_s)
    if not manifest.is_file():
        raise FileNotFoundError(f"exclude manifest not found: {manifest}")
    with manifest.open(newline="") as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        if not reader.fieldnames or "sample_id" not in reader.fieldnames:
            raise ValueError(f"exclude manifest lacks sample_id: {manifest}")
        assigned_to_prior_phase.update(
            row["sample_id"].strip() for row in reader if row.get("sample_id", "").strip()
        )

all_excluded = excluded | assigned_to_prior_phase
selected = [(s, *all_rows[s]) for s in sorted(all_rows) if s not in all_excluded]
out = Path(args.output)
out.parent.mkdir(parents=True, exist_ok=True)
with out.open("w", newline="") as fh:
    w = csv.writer(fh, delimiter="\t", lineterminator="\n")
    w.writerow(["sample_id", "layout", "clean_r1", "clean_r2", "source_fastp_batch"])
    for sample, r1, r2, batch in selected:
        w.writerow([sample, "PE", r1, r2, batch])

with Path(args.audit).open("w", newline="") as fh:
    w = csv.writer(fh, delimiter="\t", lineterminator="\n")
    w.writerow(["metric", "value"])
    w.writerow(["completed_fastp_samples_detected", len(all_rows)])
    w.writerow(["already_signal_done_excluded", len(set(all_rows) & excluded)])
    w.writerow(["assigned_to_prior_phase_excluded", len(set(all_rows) & assigned_to_prior_phase)])
    w.writerow(["selected_samples", len(selected)])
    w.writerow(["duplicate_sample_ids_between_batches", len(set(duplicates))])
print(f"completed={len(all_rows)} excluded={len(set(all_rows)&excluded)} selected={len(selected)}")
