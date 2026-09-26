#!/usr/bin/env python3
import csv
import json
import pathlib
import sys


batch = pathlib.Path(sys.argv[1])
manifest = list(csv.DictReader((batch / "fastp_snapshot_manifest.tsv").open(), delimiter="\t"))
rows = []
for item in manifest:
    sample = item["sample_id"]
    status_file = batch / "status" / f"{sample}.status.tsv"
    status = "NOT_RUN"
    detail = ""
    if status_file.exists():
        values = status_file.read_text().strip().split("\t")
        status = values[1] if len(values) > 1 else "UNKNOWN"
        detail = values[2] if len(values) > 2 else ""
    metrics = [""] * 8
    report = batch / "reports" / f"{sample}.fastp.json"
    if status == "SUCCESS" and report.exists():
        try:
            data = json.loads(report.read_text())
            before = data["summary"]["before_filtering"]
            after = data["summary"]["after_filtering"]
            metrics = [
                before.get("total_reads", ""), after.get("total_reads", ""),
                before.get("total_bases", ""), after.get("total_bases", ""),
                before.get("q20_rate", ""), after.get("q20_rate", ""),
                before.get("q30_rate", ""), after.get("q30_rate", ""),
            ]
        except Exception as exc:
            detail = f"summary_parse_error:{type(exc).__name__}:{exc}"
    rows.append([sample, status, detail, *metrics])

fields = ["sample_id", "status", "detail", "raw_reads", "clean_reads", "raw_bases", "clean_bases", "raw_q20_rate", "clean_q20_rate", "raw_q30_rate", "clean_q30_rate"]
with (batch / "fastp_batch_summary.tsv").open("w", newline="") as out:
    writer = csv.writer(out, delimiter="\t")
    writer.writerow(fields)
    writer.writerows(rows)
success = sum(row[1] == "SUCCESS" for row in rows)
failed = sum(row[1] == "FAILED" for row in rows)
with (batch / "fastp_batch_counts.tsv").open("w") as out:
    out.write("metric\tvalue\n")
    out.write(f"snapshot_samples\t{len(rows)}\n")
    out.write(f"successful_samples\t{success}\n")
    out.write(f"failed_samples\t{failed}\n")
    out.write(f"not_run_samples\t{len(rows)-success-failed}\n")
print(f"snapshot={len(rows)} success={success} failed={failed}")
