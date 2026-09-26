#!/usr/bin/env bash
#SBATCH --job-name=eff_hsignals
#SBATCH --partition=highmem
#SBATCH --nodes=1
#SBATCH --ntasks-per-node=32
#SBATCH --cpus-per-task=1
#SBATCH --mem=64G
#SBATCH --time=3-00:00:00
#SBATCH --output=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/effluentonly/human_signals_20260806/logs/slurm_%j.out
#SBATCH --error=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/effluentonly/human_signals_20260806/logs/slurm_%j.err

set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/config.sh"
phase=${PHASE:?PHASE required}
manifest="$ROOT/manifests/${phase}.tsv"
audit="$ROOT/manifests/${phase}.audit.tsv"
mkdir -p "$ROOT"/{logs,logs/per_sample,manifests,results,status,summary,test}

if [[ "$phase" == phase1 ]]; then
  [[ -s "$manifest" ]] || { echo "missing frozen phase1 manifest" >&2; exit 20; }
else
  python3 "$SCRIPT_DIR/build_manifest.py" --batch "$BATCH1" --batch "$BATCH2" \
    --exclude-done-dir "$ROOT/status" --exclude-manifest "$ROOT/manifests/phase1.tsv" \
    --output "$manifest" --audit "$audit"
fi

first=$(awk 'NR==2{print $1}' "$manifest")
if [[ -z "$first" ]]; then
  echo "No remaining samples for $phase"
  python3 "$SCRIPT_DIR/aggregate.py" "$ROOT" "$manifest" "$phase"
  exit 0
fi

if [[ ! -f "$ROOT/status/SMOKE_TEST_OK" ]]; then
  rm -rf "$ROOT/test/$first"
  bash "$SCRIPT_DIR/run_one.sh" "$first" "$manifest" test
  test -s "$ROOT/test/$first/summary.tsv"
  touch "$ROOT/status/SMOKE_TEST_OK"
fi

export SCRIPT_DIR manifest
awk 'NR>1{print $1}' "$manifest" | xargs -r -n 1 -P "$PARALLEL_SAMPLES" bash -c 'bash "$SCRIPT_DIR/run_one_safe.sh" "$1" "$manifest"' _
python3 "$SCRIPT_DIR/aggregate.py" "$ROOT" "$manifest" "$phase"
touch "$ROOT/status/${phase}.complete"
