#!/usr/bin/env bash
set -euo pipefail

ROOT=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/effluentonly/human_signals_20260806
MODE=${1:-audit}
[[ "$MODE" == audit || "$MODE" == apply ]] || { echo "usage: $0 audit|apply" >&2; exit 2; }

mapfile -t samples < <(
  awk 'FNR>1{print $1}' "$ROOT/manifests/phase1.tsv" "$ROOT/manifests/phase2.tsv" | sort -u
)

status_done=0
status_failed=0
human_done=0
crass_done=0
summary_present=0
for sample in "${samples[@]}"; do
  [[ -f "$ROOT/status/${sample}.done" ]] && status_done=$((status_done + 1))
  [[ -f "$ROOT/status/${sample}.failed" ]] && status_failed=$((status_failed + 1))
  [[ -f "$ROOT/results/${sample}/human/.done" ]] && human_done=$((human_done + 1))
  [[ -f "$ROOT/results/${sample}/crAssphage/.done" ]] && crass_done=$((crass_done + 1))
  [[ -f "$ROOT/results/${sample}/summary.tsv" ]] && summary_present=$((summary_present + 1))
done

printf 'mode=%s samples=%d status_done=%d status_failed=%d human_done=%d crass_done=%d summaries=%d\n' \
  "$MODE" "${#samples[@]}" "$status_done" "$status_failed" "$human_done" "$crass_done" "$summary_present"

if [[ "$MODE" == apply ]]; then
  for sample in "${samples[@]}"; do
    rm -f \
      "$ROOT/status/${sample}.done" \
      "$ROOT/status/${sample}.failed" \
      "$ROOT/results/${sample}/human/.done" \
      "$ROOT/results/${sample}/crAssphage/.done" \
      "$ROOT/results/${sample}/summary.tsv"
  done
  rm -f "$ROOT/status/phase1.complete" "$ROOT/status/phase2.complete"
  printf 'reset_complete samples=%d retained_mtDNA_done=%d\n' \
    "${#samples[@]}" "$(find "$ROOT/results" -mindepth 3 -maxdepth 3 -path '*/mtDNA/.done' -type f 2>/dev/null | wc -l)"
fi
