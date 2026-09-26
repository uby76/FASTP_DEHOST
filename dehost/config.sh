#!/usr/bin/env bash
set -euo pipefail

ROOT=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/effluentonly/human_signals_20260806
EFF=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/effluentonly
BATCH1=${EFF}/fastp_batches/batch_20260805_195718
BATCH2=${EFF}/fastp_batches/batch_after_download_635718
HUMAN_INDEX=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/databases/bowtie2_human/grch38
MTDNA_REF=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/G194_192_MetaWRAP_refinement_allbins_20260718/results/mtDNA_cleandata192_minimap2_20260801/02_reference/GRCh38_chrM_NC_012920.1.fa
CRASS_INDEX=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/group194_crAssphage_mapping_20260708/index/crAssphage_BK010471
CRASS_REF=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/group194_crAssphage_mapping_20260708/ref/crAssphage_BK010471.fasta
METABAT_BIN=/shared/scratch/SCWF00047/legacydata/b.jnl24chv/software/metabat2_2.17_20260801/bin

THREADS_PER_SAMPLE=${THREADS_PER_SAMPLE:-6}
PARALLEL_SAMPLES=${PARALLEL_SAMPLES:-4}
TEST_PAIRS=${TEST_PAIRS:-10000}
