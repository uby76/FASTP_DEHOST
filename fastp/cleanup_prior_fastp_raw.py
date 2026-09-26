#!/usr/bin/env python3
import argparse
import csv
import datetime
import pathlib
import re


RUN_RE = re.compile(r"[SED]RR\d+")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=pathlib.Path)
    parser.add_argument("--current-batch", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()
    root = args.root.resolve()
    current = args.current_batch.resolve()
    fastq = (root / "fastq").resolve()
    rows = []
    for marker in sorted((root / "fastp_batches").glob("batch_*/status/*.done")):
        batch = marker.parent.parent.resolve()
        if batch == current:
            continue
        sample = marker.stem
        if not RUN_RE.fullmatch(sample):
            rows.append((sample, str(batch), "SKIPPED_INVALID_SAMPLE_ID", "", "", ""))
            continue
        clean1 = batch / "clean_reads" / f"{sample}_clean_R1.fastq.gz"
        clean2 = batch / "clean_reads" / f"{sample}_clean_R2.fastq.gz"
        raw1 = fastq / f"{sample}_1.fastq.gz"
        raw2 = fastq / f"{sample}_2.fastq.gz"
        if not clean1.is_file() or clean1.stat().st_size == 0 or not clean2.is_file() or clean2.stat().st_size == 0:
            rows.append((sample, str(batch), "SKIPPED_MISSING_CLEAN_PAIR", str(raw1), str(raw2), ""))
            continue
        # Exact resolved parent and exact filename checks prevent broad deletion.
        if raw1.parent.resolve() != fastq or raw2.parent.resolve() != fastq:
            raise SystemExit(f"unsafe raw path for {sample}")
        existed = raw1.exists() or raw2.exists()
        try:
            raw1.unlink(missing_ok=True)
            raw2.unlink(missing_ok=True)
            pathlib.Path(str(raw1) + ".aria2").unlink(missing_ok=True)
            pathlib.Path(str(raw2) + ".aria2").unlink(missing_ok=True)
            if raw1.exists() or raw2.exists():
                raise OSError("raw path still exists after unlink")
            state = "DELETED" if existed else "ALREADY_ABSENT"
        except Exception as exc:
            state = f"ERROR_SKIPPED:{type(exc).__name__}:{exc}"
        rows.append((sample, str(batch), state, str(raw1), str(raw2), datetime.datetime.now(datetime.timezone.utc).isoformat()))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="") as out:
        writer = csv.writer(out, delimiter="\t")
        writer.writerow(["sample_id", "source_fastp_batch", "status", "raw_read1", "raw_read2", "action_utc"])
        writer.writerows(rows)
    print(f"prior completed samples audited={len(rows)} raw pairs deleted={sum(r[2] == 'DELETED' for r in rows)}")


if __name__ == "__main__":
    main()
