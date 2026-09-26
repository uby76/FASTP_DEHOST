#!/usr/bin/env bash
set -euo pipefail

ROOT=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/effluentonly/human_signals_20260806

declare -A source_batch
while IFS=$'\t' read -r sample layout r1 r2 batch; do
  [[ "$sample" == sample_id ]] && continue
  source_batch["$sample"]="$batch"
done < <(awk 'FNR==1 && NR!=1{next} {print}' "$ROOT/manifests/phase1.tsv" "$ROOT/manifests/phase2.tsv")

mapfile -t samples < <(printf '%s\n' "${!source_batch[@]}" | sort)
human_restored=0
crass_restored=0
summary_restored=0

for sample in "${samples[@]}"; do
  out="$ROOT/results/$sample"
  bam="$out/human/${sample}.human_mapped.sorted.bam"
  non1="$out/dehost/${sample}.nonhuman_R1.fastq.gz"
  non2="$out/dehost/${sample}.nonhuman_R2.fastq.gz"
  human_log="$out/logs/${sample}.GRCh38.bowtie2.log"
  idxstats="$out/human/${sample}.idxstats.tsv"
  mt_jgi="$out/mtDNA/${sample}.jgi_depth.txt"
  crass_count="$out/crAssphage/${sample}.mapped_reads.txt"
  done_log="$ROOT/logs/per_sample/${sample}.log"

  if [[ -s "$bam" && -s "$bam.bai" && -s "$non1" && -s "$non2" && -s "$human_log" && -s "$idxstats" ]] && samtools quickcheck "$bam"; then
    touch "$out/human/.done"
    human_restored=$((human_restored + 1))
  fi
  if [[ -s "$crass_count" && -s "$out/logs/${sample}.BK010471.bowtie2.log" ]]; then
    touch "$out/crAssphage/.done"
    crass_restored=$((crass_restored + 1))
  fi

  done_line=$(grep -E "^DONE ${sample} " "$done_log" 2>/dev/null | tail -1 || true)
  if [[ -n "$done_line" && -f "$out/human/.done" && -f "$out/mtDNA/.done" && -f "$out/crAssphage/.done" && -s "$mt_jgi" ]]; then
    clean=$(sed -n 's/.* clean=\([0-9][0-9]*\).*/\1/p' <<< "$done_line")
    dehost=$(sed -n 's/.* dehost=\([0-9][0-9]*\).*/\1/p' <<< "$done_line")
    human=$((clean - dehost))
    hbam=$(awk '{s+=$3} END{print s+0}' "$idxstats")
    mt=$(awk 'NR==2{print $3; found=1} END{if(!found) print 0}' "$mt_jgi")
    crass=$(awk '{print $1+0}' "$crass_count")
    summary="$out/summary.tsv"
    printf 'sample_id\tclean_reads\tdehost_reads\thuman_reads_by_removal\thuman_mapped_percent\thuman_bam_mapped_records\tmtDNA_mean_depth_jgi\tcrAssphage_mapped_read_records\tcrAssphageratio\tsource_fastp_batch\thuman_bam\tdehost_r1\tdehost_r2\n' > "$summary"
    awk -v s="$sample" -v clean="$clean" -v dehost="$dehost" -v human="$human" -v hbam="$hbam" -v mt="$mt" -v crass="$crass" -v source="${source_batch[$sample]}" -v bam="$bam" -v n1="$non1" -v n2="$non2" \
      'BEGIN{OFS="\t"; print s,clean,dehost,human,(clean?100*human/clean:0),hbam,mt,crass,(dehost?crass/dehost:0),source,bam,n1,n2}' >> "$summary"
    touch "$ROOT/status/${sample}.done"
    summary_restored=$((summary_restored + 1))
  fi
done

printf 'samples=%d human_steps_restored=%d crAssphage_steps_restored=%d completed_summaries_restored=%d mtDNA_steps_retained=%d\n' \
  "${#samples[@]}" "$human_restored" "$crass_restored" "$summary_restored" \
  "$(find "$ROOT/results" -mindepth 3 -maxdepth 3 -path '*/mtDNA/.done' -type f 2>/dev/null | wc -l)"
