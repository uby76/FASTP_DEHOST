#!/usr/bin/env python3
import csv
import pathlib
import sys


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: build_ena_manifest.py REPORT_DIR META_DIR FASTQ_DIR")
    report_dir, meta_dir, fastq_dir = map(pathlib.Path, sys.argv[1:])
    meta_dir.mkdir(parents=True, exist_ok=True)
    fastq_dir.mkdir(parents=True, exist_ok=True)

    files = []
    unavailable = []
    for report in sorted(report_dir.glob("*.tsv")):
        run = report.stem
        try:
            rows = list(csv.DictReader(report.open(encoding="utf-8"), delimiter="\t"))
        except Exception as exc:
            unavailable.append((run, "invalid_ENA_report", str(exc)))
            continue
        if not rows:
            unavailable.append((run, "no_ENA_record", ""))
            continue
        row = rows[0]
        urls = [x for x in row.get("fastq_ftp", "").split(";") if x]
        md5s = row.get("fastq_md5", "").split(";") if row.get("fastq_md5") else []
        sizes = row.get("fastq_bytes", "").split(";") if row.get("fastq_bytes") else []
        if not urls:
            unavailable.append((run, "no_FASTQ_URL", ""))
            continue
        for index, raw_url in enumerate(urls):
            url = raw_url if "://" in raw_url else "https://" + raw_url
            name = url.rsplit("/", 1)[-1]
            files.append({
                "run_accession": run,
                "file_index": index + 1,
                "filename": name,
                "url": url,
                "md5": md5s[index] if index < len(md5s) else "",
                "bytes": sizes[index] if index < len(sizes) else "",
            })

    fields = ["run_accession", "file_index", "filename", "url", "md5", "bytes"]
    with (meta_dir / "fastq_file_manifest.tsv").open("w", newline="") as out:
        writer = csv.DictWriter(out, delimiter="\t", fieldnames=fields)
        writer.writeheader()
        writer.writerows(files)
    with (meta_dir / "unavailable_runs.tsv").open("w", newline="") as out:
        writer = csv.writer(out, delimiter="\t")
        writer.writerow(["run_accession", "reason", "detail"])
        writer.writerows(unavailable)
    with (meta_dir / "aria2_input.txt").open("w") as out:
        for row in files:
            out.write(row["url"] + "\n")
            out.write(f"  out={row['filename']}\n")
    print(f"FASTQ files in manifest: {len(files)}")
    print(f"Runs unavailable before download: {len(unavailable)}")


if __name__ == "__main__":
    main()
