#!/usr/bin/env bash
#SBATCH --job-name=eff_hsig_test
#SBATCH --partition=dev
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=01:00:00
#SBATCH --output=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/effluentonly/human_signals_20260806/logs/test_%j.out
#SBATCH --error=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/effluentonly/human_signals_20260806/logs/test_%j.err

set -euo pipefail
SCRIPT_DIR=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/effluentonly/human_signals_20260806/scripts
source "$SCRIPT_DIR/config.sh"
manifest="$ROOT/manifests/phase1.tsv"
first=$(awk 'NR==2{print $1}' "$manifest")
rm -rf "$ROOT/test/$first"
bash "$SCRIPT_DIR/run_one.sh" "$first" "$manifest" test
test -s "$ROOT/test/$first/summary.tsv"
touch "$ROOT/status/SMOKE_TEST_OK"
cat "$ROOT/test/$first/summary.tsv"
