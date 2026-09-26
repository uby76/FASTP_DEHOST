#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/config.sh"
sample=${1:?sample required}
manifest=${2:?manifest required}
mkdir -p "$ROOT/status" "$ROOT/logs/per_sample"
set +e
bash "$SCRIPT_DIR/run_one.sh" "$sample" "$manifest" full > "$ROOT/logs/per_sample/${sample}.log" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] && exit 0
printf '%s\t%s\t%s\n' "$sample" "$rc" "$(date -Is)" > "$ROOT/status/${sample}.failed"
echo "FAILED $sample rc=$rc; skipped" >&2
exit 0
