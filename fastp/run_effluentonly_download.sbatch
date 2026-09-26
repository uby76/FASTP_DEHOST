#!/usr/bin/env bash
#SBATCH --job-name=effluentonly_DL
#SBATCH --partition=highmem
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=4G
#SBATCH --time=3-00:00:00
#SBATCH --output=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/effluentonly/logs/%x_%j.out
#SBATCH --error=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/effluentonly/logs/%x_%j.err

set -uo pipefail
ROOT=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/effluentonly
INPUT="$ROOT/input/data.txt"
RUNS="$ROOT/input/run_accessions.txt"
REPORTS="$ROOT/metadata/ena_reports"
META="$ROOT/metadata"
FASTQ="$ROOT/fastq"
SCRIPTS="$ROOT/scripts"
STATUS="$ROOT/status"
mkdir -p "$REPORTS" "$META" "$FASTQ" "$STATUS" "$ROOT/logs"

# Exact IDs, safe restart, and input audit. Accept both the original four-column
# table (Run) and the updated one-column table (ena_run_acc).
python3 - "$INPUT" "$RUNS" <<'PY'
import csv
import re
import sys

source, output = sys.argv[1:]
with open(source, newline="", encoding="utf-8-sig") as handle:
    reader = csv.DictReader(handle, delimiter="\t")
    candidates = [name for name in ("ena_run_acc", "Run", "run_accession") if name in (reader.fieldnames or [])]
    if len(candidates) != 1:
        raise SystemExit(f"expected exactly one run ID column, found {candidates}; columns={reader.fieldnames}")
    column = candidates[0]
    runs = [row[column].strip() for row in reader]
if any(not re.fullmatch(r"[SED]RR\d+", run) for run in runs):
    raise SystemExit("blank or invalid run accession in input")
if len(runs) != len(set(runs)):
    raise SystemExit("duplicate run accessions in input")
with open(output, "w") as out:
    out.write("\n".join(sorted(runs)) + "\n")
print(f"run_id_column={column} unique_runs={len(runs)}")
PY
requested=$(wc -l < "$RUNS")
[[ "$requested" -gt 0 ]] || { echo "No run accessions found" >&2; exit 10; }
printf 'metric\tvalue\nrequested_unique_runs\t%s\n' "$requested" > "$META/input_audit.tsv"

# Fetch ENA metadata concurrently. Each run has a finite timeout/retry budget;
# unavailable runs are represented by an empty report and do not stop the job.
export REPORTS
fetch_report() {
  run=$1
  output="$REPORTS/$run.tsv"
  [[ -s "$output" ]] && return 0
  tmp="$output.tmp.$$"
  if curl -fsSL --connect-timeout 15 --max-time 60 --retry 2 --retry-delay 3 \
      --get 'https://www.ebi.ac.uk/ena/portal/api/filereport' \
      --data-urlencode "accession=$run" \
      --data-urlencode 'result=read_run' \
      --data-urlencode 'fields=run_accession,fastq_ftp,fastq_md5,fastq_bytes,library_layout' \
      --data-urlencode 'format=tsv' \
      --data-urlencode 'download=true' -o "$tmp"; then
    mv "$tmp" "$output"
  else
    rm -f "$tmp"
    : > "$output"
  fi
}
export -f fetch_report
xargs -n 1 -P 8 bash -c 'fetch_report "$1"' _ < "$RUNS"

python3 "$SCRIPTS/build_ena_manifest.py" "$REPORTS" "$META" "$FASTQ"
manifest_files=$(awk 'END{print NR-1}' "$META/fastq_file_manifest.tsv")

# aria2: parallel files plus segmented transfer, resumable .aria2 state files.
# Finite retries ensure unavailable files are skipped instead of blocking all runs.
if [[ "$manifest_files" -gt 0 ]]; then
  aria2c \
    --input-file="$META/aria2_input.txt" \
    --dir="$FASTQ" \
    --continue=true \
    --max-concurrent-downloads=8 \
    --max-connection-per-server=8 \
    --split=8 \
    --min-split-size=16M \
    --file-allocation=none \
    --auto-file-renaming=false \
    --allow-overwrite=true \
    --retry-wait=5 \
    --max-tries=3 \
    --timeout=60 \
    --connect-timeout=20 \
    --lowest-speed-limit=10K \
    --summary-interval=60 \
    --console-log-level=notice \
    --download-result=full || true
fi

python3 "$SCRIPTS/audit_downloads.py" "$META/fastq_file_manifest.tsv" "$FASTQ" "$META"
printf 'FINISHED_WITH_SKIP_POLICY\t%s\t%s\n' "${SLURM_JOB_ID:-NA}" "$(date -Is)" > "$STATUS/download_finished.tsv"
echo "[$(date -Is)] finished: unavailable or failed files were recorded and skipped"
