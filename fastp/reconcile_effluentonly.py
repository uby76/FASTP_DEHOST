#!/usr/bin/env python3
import argparse
import csv
import pathlib
import re


RUN_RE = re.compile(r"^([SED]RR\d+)")


def read_new_runs(path):
    with path.open(newline="", encoding="utf-8-sig") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        candidates = [x for x in ("ena_run_acc", "Run", "run_accession") if x in (reader.fieldnames or [])]
        if len(candidates) != 1:
            raise SystemExit(f"ambiguous run ID column: {candidates}; columns={reader.fieldnames}")
        runs = [row[candidates[0]].strip() for row in reader]
    if any(not RUN_RE.fullmatch(x) for x in runs) or len(runs) != len(set(runs)):
        raise SystemExit("new run list contains blank, invalid, or duplicate IDs")
    return candidates[0], set(runs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, required=True)
    parser.add_argument("--new-input", type=pathlib.Path, required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    column, new_runs = read_new_runs(args.new_input)
    old_list = root / "input/run_accessions.txt"
    old_runs = set(old_list.read_text().split()) if old_list.exists() else set()

    delete_paths = []
    kept_data = []
    for folder in (root / "fastq", root / "metadata/ena_reports"):
        if not folder.exists():
            continue
        for path in folder.iterdir():
            if not path.is_file():
                continue
            match = RUN_RE.match(path.name)
            if match and match.group(1) not in new_runs:
                delete_paths.append(path)
            elif match:
                kept_data.append(path)

    stale_metadata = [
        root / "metadata/fastq_file_manifest.tsv",
        root / "metadata/unavailable_runs.tsv",
        root / "metadata/aria2_input.txt",
        root / "metadata/downloaded_FASTQ_files.tsv",
        root / "metadata/failed_FASTQ_downloads.tsv",
        root / "metadata/completed_runs.txt",
        root / "metadata/download_summary.tsv",
        root / "metadata/input_audit.tsv",
        root / "status/download_finished.tsv",
    ]
    stale_metadata = [p for p in stale_metadata if p.exists()]
    audit = root / "metadata/reconciliation_audit.tsv"
    audit.parent.mkdir(parents=True, exist_ok=True)
    metrics = {
        "new_input_column": column,
        "old_unique_runs": len(old_runs),
        "new_unique_runs": len(new_runs),
        "retained_runs": len(old_runs & new_runs),
        "newly_added_runs": len(new_runs - old_runs),
        "removed_runs": len(old_runs - new_runs),
        "retained_existing_data_files": len(kept_data),
        "files_selected_for_deletion": len(delete_paths),
        "stale_summary_files_to_reset": len(stale_metadata),
        "apply": str(args.apply),
    }
    with audit.open("w") as out:
        out.write("metric\tvalue\n")
        for key, value in metrics.items():
            out.write(f"{key}\t{value}\n")
    for label, values in (
        ("retained_run_ids.txt", old_runs & new_runs),
        ("newly_added_run_ids.txt", new_runs - old_runs),
        ("removed_run_ids.txt", old_runs - new_runs),
    ):
        (audit.parent / label).write_text("\n".join(sorted(values)) + ("\n" if values else ""))
    (audit.parent / "files_selected_for_deletion.txt").write_text(
        "\n".join(str(p) for p in sorted(delete_paths)) + ("\n" if delete_paths else "")
    )

    if args.apply:
        for path in delete_paths + stale_metadata:
            resolved = path.resolve()
            if root not in resolved.parents or not resolved.is_file():
                raise SystemExit(f"refusing unsafe deletion: {resolved}")
            resolved.unlink()
        target = root / "input/data.txt"
        args.new_input.replace(target)
    for key, value in metrics.items():
        print(f"{key}={value}")


if __name__ == "__main__":
    main()
