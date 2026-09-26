#!/usr/bin/env python3
import argparse
import csv
import datetime
import pathlib
import re


PAIR_RE = re.compile(r"^([SED]RR\d+)_([12])\.fastq\.gz$")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, required=True)
    parser.add_argument("--batch-dir", type=pathlib.Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    batch = args.batch_dir.resolve()
    batch.mkdir(parents=True, exist_ok=False)
    for sub in ("clean_reads", "reports", "logs", "status"):
        (batch / sub).mkdir()

    target_runs = set((root / "input/run_accessions.txt").read_text().split())
    rows = list(csv.DictReader((root / "metadata/fastq_file_manifest.tsv").open(), delimiter="\t"))
    pair_files = {}
    for row in rows:
        match = PAIR_RE.fullmatch(row["filename"])
        if match and match.group(1) == row["run_accession"]:
            pair_files.setdefault(match.group(1), {})[match.group(2)] = row

    previously_done = set()
    batches_root = root / "fastp_batches"
    if batches_root.exists():
        for marker in batches_root.glob("batch_*/status/*.done"):
            previously_done.add(marker.stem)

    eligible, excluded = [], []
    snapshot_time = datetime.datetime.now(datetime.timezone.utc).isoformat()
    for run in sorted(target_runs):
        if run in previously_done:
            excluded.append((run, "already_completed_in_previous_fastp_batch"))
            continue
        mates = pair_files.get(run, {})
        if set(mates) != {"1", "2"}:
            excluded.append((run, "ENA_manifest_does_not_have_exact_R1_R2_pair"))
            continue
        paths, reason = {}, ""
        for mate in ("1", "2"):
            row = mates[mate]
            path = root / "fastq" / row["filename"]
            partial = pathlib.Path(str(path) + ".aria2")
            expected = int(row["bytes"]) if row.get("bytes") else -1
            if partial.exists():
                reason = f"R{mate}_still_downloading"
                break
            if not path.is_file() or path.stat().st_size == 0:
                reason = f"R{mate}_missing_or_empty"
                break
            if expected >= 0 and path.stat().st_size != expected:
                reason = f"R{mate}_size_mismatch"
                break
            paths[mate] = (path, path.stat().st_size)
        if reason:
            excluded.append((run, reason))
        else:
            eligible.append((run, paths["1"][0], paths["2"][0], paths["1"][1], paths["2"][1], snapshot_time))

    manifest = batch / "fastp_snapshot_manifest.tsv"
    with manifest.open("w", newline="") as out:
        writer = csv.writer(out, delimiter="\t")
        writer.writerow(["sample_id", "read1", "read2", "read1_bytes", "read2_bytes", "snapshot_utc"])
        writer.writerows(eligible)
    with (batch / "excluded_from_fastp_snapshot.tsv").open("w", newline="") as out:
        writer = csv.writer(out, delimiter="\t")
        writer.writerow(["sample_id", "reason"])
        writer.writerows(excluded)
    with (batch / "fastp_snapshot_audit.tsv").open("w") as out:
        out.write("metric\tvalue\n")
        out.write(f"target_runs\t{len(target_runs)}\n")
        out.write(f"ENA_FASTQ_manifest_files\t{len(rows)}\n")
        out.write(f"previously_fastp_completed_runs\t{len(previously_done & target_runs)}\n")
        out.write(f"current_complete_paired_runs_selected\t{len(eligible)}\n")
        out.write(f"not_selected_runs\t{len(excluded)}\n")
        out.write(f"snapshot_utc\t{snapshot_time}\n")
    print(f"selected_complete_pairs={len(eligible)} excluded={len(excluded)} previous_done={len(previously_done & target_runs)}")


if __name__ == "__main__":
    main()
