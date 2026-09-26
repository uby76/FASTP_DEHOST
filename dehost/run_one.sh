#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/config.sh"

sample=${1:?sample required}
manifest=${2:?manifest required}
mode=${3:-full}
row=$(awk -F '\t' -v s="$sample" 'NR>1 && $1==s {print; n++} END{if(n!=1) exit 2}' "$manifest") || { echo "manifest row error: $sample" >&2; exit 20; }
IFS=$'\t' read -r sample_id layout clean1 clean2 source_batch <<< "$row"
[[ "$sample_id" == "$sample" && -s "$clean1" && -s "$clean2" ]] || { echo "invalid inputs: $sample" >&2; exit 21; }

module purge
module load Bowtie2/2.5.4-GCC-13.3.0 SAMtools/1.21-GCC-13.3.0 minimap2/2.30-GCCcore-14.3.0
export PATH="$METABAT_BIN:$PATH"

if [[ "$mode" == test ]]; then
  out="$ROOT/test/$sample"
  tmp="${SLURM_TMPDIR:-/tmp}/human_signal_test_${sample}"
  mkdir -p "$out" "$tmp"
  python3 "$SCRIPT_DIR/subset_fastq.py" "$clean1" "$tmp/${sample}.R1.fastq.gz" "$TEST_PAIRS"
  python3 "$SCRIPT_DIR/subset_fastq.py" "$clean2" "$tmp/${sample}.R2.fastq.gz" "$TEST_PAIRS"
  clean1="$tmp/${sample}.R1.fastq.gz"
  clean2="$tmp/${sample}.R2.fastq.gz"
  status="$out/status"
else
  out="$ROOT/results/$sample"
  status="$ROOT/status"
fi
mkdir -p "$out"/{human,dehost,mtDNA,crAssphage,logs} "$status"

done_file="$status/${sample}.done"
if [[ "$mode" == full && -f "$done_file" && -s "$out/summary.tsv" ]]; then
  echo "SKIP $sample complete"
  exit 0
fi
rm -f "$status/${sample}.failed"

# Complete GRCh38 mapping from clean reads. The same mapping creates paired non-host reads.
human_bam="$out/human/${sample}.human_mapped.sorted.bam"
non1="$out/dehost/${sample}.nonhuman_R1.fastq.gz"
non2="$out/dehost/${sample}.nonhuman_R2.fastq.gz"
human_log="$out/logs/${sample}.GRCh38.bowtie2.log"
if [[ ! -f "$out/human/.done" ]]; then
  rm -f "$human_bam" "$human_bam.bai" "$non1" "$non2"
  bowtie2 --sensitive -x "$HUMAN_INDEX" -1 "$clean1" -2 "$clean2" -p "$THREADS_PER_SAMPLE" \
    --un-conc-gz "$out/dehost/${sample}.nonhuman_R%.fastq.gz" 2> "$human_log" \
    | samtools view -@ 2 -b -F 4 - \
    | samtools sort -@ 2 -o "$human_bam.tmp" -
  mv "$human_bam.tmp" "$human_bam"
  samtools quickcheck "$human_bam"
  samtools index -@ 2 "$human_bam"
  samtools flagstat -@ 2 "$human_bam" > "$out/human/${sample}.flagstat.txt"
  samtools idxstats "$human_bam" > "$out/human/${sample}.idxstats.tsv"
  gzip -t "$non1" "$non2"
  touch "$out/human/.done"
fi

clean_pairs=$(awk '/reads; of these:/{gsub(/[^0-9]/,"",$1); print $1; exit}' "$human_log")
[[ "$clean_pairs" =~ ^[0-9]+$ ]] || { echo "cannot parse clean read pairs from $human_log" >&2; exit 22; }
clean_reads=$((clean_pairs * 2))
dehost_pairs=$(awk '/were paired; of these:/{paired=1; next} paired && /aligned concordantly 0 times/{gsub(/[^0-9]/,"",$1); print $1; exit}' "$human_log")
[[ "$dehost_pairs" =~ ^[0-9]+$ ]] || { echo "cannot parse non-host read pairs from $human_log" >&2; exit 23; }
dehost_reads=$((dehost_pairs * 2))
human_by_removal=$((clean_reads - dehost_reads))
human_bam_records=$(samtools view -@ 2 -c "$human_bam")

# Reproduce the prior mtDNA_mean_depth_jgi method: clean reads -> chrM-only minimap2 -> JGI depth.
mt_bam="$out/mtDNA/${sample}.mtDNA.sorted.bam"
mt_jgi="$out/mtDNA/${sample}.jgi_depth.txt"
if [[ ! -f "$out/mtDNA/.done" ]]; then
  minimap2 -ax sr -t "$THREADS_PER_SAMPLE" "$MTDNA_REF" "$clean1" "$clean2" 2> "$out/logs/${sample}.mtDNA.minimap2.log" \
    | samtools view -@ 2 -b -F 4 - \
    | samtools sort -@ 2 -o "$mt_bam.tmp" -
  mv "$mt_bam.tmp" "$mt_bam"
  samtools quickcheck "$mt_bam"
  samtools index -@ 2 "$mt_bam"
  env -u LD_LIBRARY_PATH "$METABAT_BIN/jgi_summarize_bam_contig_depths" --outputDepth "$mt_jgi.tmp" "$mt_bam"
  mv "$mt_jgi.tmp" "$mt_jgi"
  touch "$out/mtDNA/.done"
fi
mt_depth=$(awk 'NR==2{print $3; found=1} END{if(!found) print 0}' "$mt_jgi")

# Reproduce prior crAssphageratio: dehost reads -> BK010471 Bowtie2, mapped read records / dehost records.
crass_log="$out/logs/${sample}.BK010471.bowtie2.log"
crass_count="$out/crAssphage/${sample}.mapped_reads.txt"
if [[ ! -f "$out/crAssphage/.done" ]]; then
  bowtie2 --sensitive -p "$THREADS_PER_SAMPLE" -x "$CRASS_INDEX" -1 "$non1" -2 "$non2" --no-unal \
    2> "$crass_log" | samtools view -@ 2 -c -F 4 - > "$crass_count.tmp"
  mv "$crass_count.tmp" "$crass_count"
  touch "$out/crAssphage/.done"
fi
crass_reads=$(awk '{print $1+0}' "$crass_count")

python3 - "$sample" "$clean_reads" "$dehost_reads" "$human_by_removal" "$human_bam_records" "$mt_depth" "$crass_reads" "$source_batch" "$human_bam" "$non1" "$non2" "$out/summary.tsv.tmp" <<'PY'
import sys
s, clean, dehost, human, hbam, mt, crass, source, bam, n1, n2, output = sys.argv[1:]
clean, dehost, human, hbam, crass = map(int, (clean, dehost, human, hbam, crass))
with open(output, "w") as f:
    f.write("sample_id\tclean_reads\tdehost_reads\thuman_reads_by_removal\thuman_mapped_percent\thuman_bam_mapped_records\tmtDNA_mean_depth_jgi\tcrAssphage_mapped_read_records\tcrAssphageratio\tsource_fastp_batch\thuman_bam\tdehost_r1\tdehost_r2\n")
    f.write(f"{s}\t{clean}\t{dehost}\t{human}\t{(100*human/clean if clean else 0):.10g}\t{hbam}\t{mt}\t{crass}\t{(crass/dehost if dehost else 0):.10g}\t{source}\t{bam}\t{n1}\t{n2}\n")
PY
mv "$out/summary.tsv.tmp" "$out/summary.tsv"
touch "$done_file"
echo "DONE $sample clean=$clean_reads dehost=$dehost_reads human_percent=$(awk -v h=$human_by_removal -v c=$clean_reads 'BEGIN{print c?100*h/c:0}') mtDNA=$mt_depth crAss=$crass_reads"
