#!/usr/bin/env bash
#SBATCH --job-name=effluent_fastp
#SBATCH --partition=htc_genoa
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=16G
#SBATCH --time=3-00:00:00
#SBATCH --output=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/effluentonly/logs/%x_%j.out
#SBATCH --error=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/effluentonly/logs/%x_%j.err

set -uo pipefail
ROOT=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/effluentonly
BATCH_DIR=${BATCH_DIR:?BATCH_DIR is required}
MANIFEST="$BATCH_DIR/fastp_snapshot_manifest.tsv"
THREADS_PER_SAMPLE=4
PARALLEL_SAMPLES=4
AUTO_BUILD_SNAPSHOT=${AUTO_BUILD_SNAPSHOT:-0}
DELETE_RAW_AFTER_SUCCESS=${DELETE_RAW_AFTER_SUCCESS:-0}
CLEANUP_PRIOR_RAW=${CLEANUP_PRIOR_RAW:-$DELETE_RAW_AFTER_SUCCESS}

if [[ "$AUTO_BUILD_SNAPSHOT" == 1 && ! -s "$MANIFEST" ]]; then
    if [[ -e "$BATCH_DIR" ]]; then
        echo "ERROR: batch directory exists without a valid manifest: $BATCH_DIR" >&2
        exit 10
    fi
    python3 "$ROOT/scripts/build_fastp_snapshot.py" --root "$ROOT" --batch-dir "$BATCH_DIR"
fi
[[ -s "$MANIFEST" ]] || { echo "ERROR: missing snapshot manifest: $MANIFEST" >&2; exit 11; }

module purge
module load fastp/1.0.1-GCC-13.3.0
fastp --version
mkdir -p "$BATCH_DIR"/{clean_reads,reports,logs,status}

# Architecture/runtime smoke test. This catches an incompatible CPU build
# before any real sample status is changed.
PREFLIGHT="$BATCH_DIR/preflight"
mkdir -p "$PREFLIGHT"
printf '@test/1\nACGTACGTACGTACGTACGT\n+\nIIIIIIIIIIIIIIIIIIII\n' | gzip -c > "$PREFLIGHT/R1.fastq.gz"
printf '@test/2\nTGCATGCATGCATGCATGCA\n+\nIIIIIIIIIIIIIIIIIIII\n' | gzip -c > "$PREFLIGHT/R2.fastq.gz"
rm -f "$PREFLIGHT/clean_R1.fastq.gz" "$PREFLIGHT/clean_R2.fastq.gz" \
    "$PREFLIGHT/fastp.json" "$PREFLIGHT/fastp.html" "$PREFLIGHT/preflight_success.tsv"
if ! fastp --in1 "$PREFLIGHT/R1.fastq.gz" --in2 "$PREFLIGHT/R2.fastq.gz" \
        --out1 "$PREFLIGHT/clean_R1.fastq.gz" --out2 "$PREFLIGHT/clean_R2.fastq.gz" \
        --thread 1 --length_required 1 --json "$PREFLIGHT/fastp.json" \
        --html "$PREFLIGHT/fastp.html" > "$PREFLIGHT/fastp.log" 2>&1 \
    || ! gzip -t "$PREFLIGHT/clean_R1.fastq.gz" "$PREFLIGHT/clean_R2.fastq.gz"; then
    echo "ERROR: fastp runtime preflight failed; no real samples were processed" >&2
    exit 12
fi
printf 'SUCCESS\t%s\t%s\n' "${SLURM_JOB_ID:-NA}" "$(date -Is)" > "$PREFLIGHT/preflight_success.tsv"

if [[ "$CLEANUP_PRIOR_RAW" == 1 ]]; then
    python3 "$ROOT/scripts/cleanup_prior_fastp_raw.py" --root "$ROOT" --current-batch "$BATCH_DIR" \
        --output "$BATCH_DIR/prior_completed_raw_cleanup.tsv"
fi

delete_raw_pair() {
    sample=$1; r1=$2; r2=$3; out1=$4; out2=$5; json=$6
    [[ "$r1" == "$ROOT/fastq/${sample}_1.fastq.gz" ]] || return 40
    [[ "$r2" == "$ROOT/fastq/${sample}_2.fastq.gz" ]] || return 41
    [[ -s "$out1" && -s "$out2" && -s "$json" ]] || return 42
    record="$BATCH_DIR/status/${sample}.raw_deleted.tsv"
    tmp_record="$record.tmp"
    printf 'sample_id\traw_read1\traw_read2\tdeleted_at\n%s\t%s\t%s\t%s\n' \
        "$sample" "$r1" "$r2" "$(date -Is)" > "$tmp_record"
    rm -f -- "$r1" "$r2" "${r1}.aria2" "${r2}.aria2"
    [[ ! -e "$r1" && ! -e "$r2" ]] || return 43
    mv "$tmp_record" "$record"
}

process_one() {
    sample=$1; r1=$2; r2=$3; r1_bytes=$4; r2_bytes=$5
    out1="$BATCH_DIR/clean_reads/${sample}_clean_R1.fastq.gz"
    out2="$BATCH_DIR/clean_reads/${sample}_clean_R2.fastq.gz"
    json="$BATCH_DIR/reports/${sample}.fastp.json"
    html="$BATCH_DIR/reports/${sample}.fastp.html"
    tmp1="$BATCH_DIR/clean_reads/${sample}_clean_R1.tmp.fastq.gz"
    tmp2="$BATCH_DIR/clean_reads/${sample}_clean_R2.tmp.fastq.gz"
    tmp_json="$BATCH_DIR/reports/${sample}.fastp.tmp.json"
    tmp_html="$BATCH_DIR/reports/${sample}.fastp.tmp.html"
    log="$BATCH_DIR/logs/${sample}.fastp.log"
    status="$BATCH_DIR/status/${sample}.status.tsv"
    done="$BATCH_DIR/status/${sample}.done"
    if [[ -s "$done" && -s "$out1" && -s "$out2" && -s "$json" ]]; then
        if [[ "$DELETE_RAW_AFTER_SUCCESS" == 1 && ! -s "$BATCH_DIR/status/${sample}.raw_deleted.tsv" ]]; then
            delete_raw_pair "$sample" "$r1" "$r2" "$out1" "$out2" "$json" || return 1
        fi
        return 0
    fi
    # Recover safely if clean outputs were finalized before an interruption.
    if [[ -s "$out1" && -s "$out2" && -s "$json" ]] && gzip -t "$out1" "$out2"; then
        if [[ "$DELETE_RAW_AFTER_SUCCESS" == 1 ]]; then
            delete_raw_pair "$sample" "$r1" "$r2" "$out1" "$out2" "$json" || return 1
        fi
        printf '%s\tSUCCESS\tfastp_complete_recovered\n' "$sample" > "$status"
        touch "$done"
        return 0
    fi
    if [[ ! -s "$r1" || ! -s "$r2" || $(stat -c %s "$r1") -ne "$r1_bytes" || $(stat -c %s "$r2") -ne "$r2_bytes" ]]; then
        printf '%s\tFAILED\tinput_changed_after_snapshot\n' "$sample" > "$status"
        return 1
    fi
    rm -f "$tmp1" "$tmp2" "$tmp_json" "$tmp_html"
    if fastp \
        --in1 "$r1" --in2 "$r2" \
        --out1 "$tmp1" --out2 "$tmp2" \
        --thread "$THREADS_PER_SAMPLE" \
        --detect_adapter_for_pe --trim_poly_g \
        --cut_front --cut_tail --cut_window_size 4 --cut_mean_quality 20 \
        --qualified_quality_phred 20 --unqualified_percent_limit 40 \
        --n_base_limit 5 --length_required 50 \
        --html "$tmp_html" --json "$tmp_json" > "$log" 2>&1 \
        && gzip -t "$tmp1" "$tmp2"; then
        mv "$tmp1" "$out1"; mv "$tmp2" "$out2"
        mv "$tmp_json" "$json"; mv "$tmp_html" "$html"
        if [[ "$DELETE_RAW_AFTER_SUCCESS" == 1 ]]; then
            if ! delete_raw_pair "$sample" "$r1" "$r2" "$out1" "$out2" "$json"; then
                printf '%s\tFAILED\traw_deletion_safety_check_failed\n' "$sample" > "$status"
                return 1
            fi
        fi
        printf '%s\tSUCCESS\tfastp_complete\n' "$sample" > "$status"
        touch "$done"
        return 0
    fi
    printf '%s\tFAILED\tfastp_or_gzip_validation_failed\n' "$sample" > "$status"
    rm -f "$tmp1" "$tmp2" "$tmp_json" "$tmp_html"
    return 1
}
export -f process_one
export -f delete_raw_pair
export ROOT BATCH_DIR THREADS_PER_SAMPLE DELETE_RAW_AFTER_SUCCESS

failures=0
mapfile -t rows < <(tail -n +2 "$MANIFEST")
for ((i=0; i<${#rows[@]}; i+=PARALLEL_SAMPLES)); do
    pids=()
    for ((j=i; j<i+PARALLEL_SAMPLES && j<${#rows[@]}; j++)); do
        IFS=$'\t' read -r sample r1 r2 r1_bytes r2_bytes snapshot_utc <<< "${rows[j]}"
        process_one "$sample" "$r1" "$r2" "$r1_bytes" "$r2_bytes" &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do
        wait "$pid" || failures=$((failures + 1))
    done
    done_count=$(find "$BATCH_DIR/status" -maxdepth 1 -name '*.done' | wc -l)
    echo "[$(date -Is)] fastp progress ${done_count}/${#rows[@]} failures=${failures}"
done

python3 "$ROOT/scripts/aggregate_fastp_batch.py" "$BATCH_DIR"
printf 'FINISHED\t%s\t%s\tfailures=%s\n' "${SLURM_JOB_ID:-NA}" "$(date -Is)" "$failures" > "$BATCH_DIR/fastp_job_finished.tsv"
if [[ "$failures" -gt 0 ]]; then
    printf 'FINISHED_WITH_SKIPPED_FAILURES\t%s\t%s\tfailures=%s\n' \
        "${SLURM_JOB_ID:-NA}" "$(date -Is)" "$failures" > "$BATCH_DIR/fastp_job_finished.tsv"
    echo "[$(date -Is)] completed with ${failures} failed samples recorded and skipped" >&2
else
    printf 'SUCCESS\t%s\t%s\tfailures=0\n' \
        "${SLURM_JOB_ID:-NA}" "$(date -Is)" > "$BATCH_DIR/fastp_job_finished.tsv"
fi
exit 0
