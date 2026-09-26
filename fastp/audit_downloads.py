#!/usr/bin/env python3
import csv
import hashlib
import pathlib
import sys


def md5sum(path, block=16 * 1024 * 1024):
    digest = hashlib.md5()
    with path.open("rb") as handle:
        while data := handle.read(block):
            digest.update(data)
    return digest.hexdigest()


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: audit_downloads.py FILE_MANIFEST FASTQ_DIR META_DIR")
    manifest, fastq_dir, meta_dir = map(pathlib.Path, sys.argv[1:])
    rows = list(csv.DictReader(manifest.open(), delimiter="\t"))
    ok, failures = [], []
    completed_runs = set()
    expected_by_run = {}
    ok_by_run = {}
    for row in rows:
        expected_by_run[row["run_accession"]] = expected_by_run.get(row["run_accession"], 0) + 1
        path = fastq_dir / row["filename"]
        if not path.is_file() or path.stat().st_size == 0:
            failures.append((row["run_accession"], row["filename"], "missing_or_empty", row["url"]))
            continue
        expected_bytes = row.get("bytes", "")
        if expected_bytes and path.stat().st_size != int(expected_bytes):
            failures.append((row["run_accession"], row["filename"], f"size_mismatch:{path.stat().st_size}!={expected_bytes}", row["url"]))
            continue
        expected_md5 = row.get("md5", "")
        observed_md5 = md5sum(path) if expected_md5 else "NA"
        if expected_md5 and observed_md5.lower() != expected_md5.lower():
            failures.append((row["run_accession"], row["filename"], f"md5_mismatch:{observed_md5}", row["url"]))
            continue
        ok.append((row["run_accession"], row["filename"], path.stat().st_size, expected_md5 or "NA"))
        ok_by_run[row["run_accession"]] = ok_by_run.get(row["run_accession"], 0) + 1
    completed_runs = {run for run, count in ok_by_run.items() if count == expected_by_run[run]}

    with (meta_dir / "downloaded_FASTQ_files.tsv").open("w", newline="") as out:
        writer = csv.writer(out, delimiter="\t")
        writer.writerow(["run_accession", "filename", "bytes", "verified_md5"])
        writer.writerows(ok)
    with (meta_dir / "failed_FASTQ_downloads.tsv").open("w", newline="") as out:
        writer = csv.writer(out, delimiter="\t")
        writer.writerow(["run_accession", "filename", "reason", "url"])
        writer.writerows(failures)
    (meta_dir / "completed_runs.txt").write_text("\n".join(sorted(completed_runs)) + ("\n" if completed_runs else ""))
    with (meta_dir / "download_summary.tsv").open("w") as out:
        out.write("metric\tvalue\n")
        out.write(f"manifest_FASTQ_files\t{len(rows)}\n")
        out.write(f"verified_FASTQ_files\t{len(ok)}\n")
        out.write(f"failed_FASTQ_files\t{len(failures)}\n")
        out.write(f"completed_runs\t{len(completed_runs)}\n")
    print(f"verified files={len(ok)} failed files={len(failures)} completed runs={len(completed_runs)}")


if __name__ == "__main__":
    main()
