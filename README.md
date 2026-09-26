# FASTP_DEHOST

双端测序数据的两模块处理流程：

```text
ENA run ID
  → 模块 1：下载 FASTQ → 校验 → fastp 质控
  → 模块 2：去人源 reads → mtDNA 深度 → crAssphage 信号 → 汇总
```

仓库只包含核心代码，不包含 FASTQ、BAM、参考基因组、索引、日志和分析结果。

## 目录

```text
FASTP_DEHOST/
├── fastp/     # 模块 1：ENA 下载和 fastp 质控
├── dehost/    # 模块 2：去人源和信号计算
└── README.md
```

## 环境

- Slurm、Bash、Python 3
- `curl`、`aria2c`、`fastp 1.0.1`
- `Bowtie2 2.5.4`、`SAMtools 1.21`、`minimap2 2.30`、`MetaBAT2 2.17`
- GRCh38 Bowtie2 索引、chrM FASTA、crAssphage BK010471 Bowtie2 索引

> 脚本保留 Falcon 的绝对路径。在新环境运行前，需修改 `ROOT`、参考数据路径和 `#SBATCH` 参数。

## 模块 1：ENA 下载与 fastp 质控

### 核心入口

`fastp/run_effluentonly_download.sbatch`

- 从 `input/data.txt` 读取 `ena_run_acc`、`Run` 或 `run_accession`。
- 调用 ENA API 获取下载地址、大小和 MD5。
- 用 `aria2c` 并行、断点续传 FASTQ。
- 校验下载文件，记录失败项。

```bash
sbatch fastp/run_effluentonly_download.sbatch
```

`fastp/run_fastp_snapshot.sbatch`

- 检查 fastp 运行环境。
- 按固定快照并行质控。
- 输出 clean R1/R2、HTML/JSON 报告和样本状态。
- 不删除原始 FASTQ。

```bash
# 先手动创建快照
python3 fastp/build_fastp_snapshot.py \
  --root /path/to/effluentonly \
  --batch-dir /path/to/effluentonly/fastp_batches/batch_YYYYMMDD_HHMMSS

BATCH_DIR=/path/to/effluentonly/fastp_batches/batch_YYYYMMDD_HHMMSS \
  sbatch fastp/run_fastp_snapshot.sbatch

# 或让主程序自动创建快照
AUTO_BUILD_SNAPSHOT=1 BATCH_DIR=/path/to/new_batch \
  sbatch fastp/run_fastp_snapshot.sbatch
```

### 依赖代码

- `build_ena_manifest.py`：将 ENA API 报告整理为 FASTQ 清单和 aria2 输入。
- `audit_downloads.py`：检查文件存在性、大小和 MD5。
- `build_fastp_snapshot.py`：选择 R1/R2 齐全且未处理的样本。
- `aggregate_fastp_batch.py`：汇总 reads、bases、Q20、Q30 和运行状态。

### 主要输出

```text
fastq/*.fastq.gz
metadata/fastq_file_manifest.tsv
metadata/download_summary.tsv
fastp_batches/<batch>/clean_reads/*_clean_R[12].fastq.gz
fastp_batches/<batch>/reports/*.fastp.{html,json}
fastp_batches/<batch>/fastp_batch_summary.tsv
```

## 模块 2：去人源与信号计算

### 配置

首先修改 `dehost/config.sh`：

- `ROOT`：dehost 工作目录。
- `BATCH1`/`BATCH2`：fastp 批次目录。
- `HUMAN_INDEX`：GRCh38 Bowtie2 索引。
- `MTDNA_REF`：chrM FASTA。
- `CRASS_INDEX`：crAssphage BK010471 Bowtie2 索引。
- `THREADS_PER_SAMPLE`/`PARALLEL_SAMPLES`：线程和并行样本数。

### 核心入口

`dehost/run_phase.sbatch` 按阶段执行完整流程：

1. 构建或读取样本 manifest。
2. 用小型 FASTQ 子集做 smoke test。
3. 并行处理所有样本。
4. 汇总输出。

```bash
PHASE=phase1 sbatch dehost/run_phase.sbatch
PHASE=phase2 sbatch dehost/run_phase.sbatch
```

`dehost/run_one.sh` 完成单样本的核心计算：

1. clean reads → Bowtie2/GRCh38：生成人源 BAM 和非人源成对 reads。
2. clean reads → minimap2/chrM：计算 `mtDNA_mean_depth_jgi`。
3. 非人源 reads → Bowtie2/BK010471：计算 crAssphage mapped records 和 `crAssphageratio`。
4. 输出单样本 `summary.tsv`。

```bash
bash dehost/run_one.sh SAMPLE_ID MANIFEST.tsv full
```

### 依赖代码

- `build_manifest.py`：从 fastp 批次构建 dehost 样本清单。
- `run_one_safe.sh`：包装单样本运行，记录日志和失败状态。
- `subset_fastq.py`：为 smoke test 提取少量 FASTQ records。
- `aggregate.py`：汇总样本结果并记录缺失样本。

### 主要输出

```text
results/<sample>/human/*.bam
results/<sample>/dehost/*nonhuman_R[12].fastq.gz
results/<sample>/mtDNA/*.jgi_depth.txt
results/<sample>/crAssphage/*.mapped_reads.txt
results/<sample>/summary.tsv
summary/<phase>_human_mtDNA_crAssphage_signals.tsv
```

## 状态检查

- fastp 失败：检查 `fastp_batches/<batch>/status/*.status.tsv`。
- dehost 失败：检查 `status/*.failed` 和 `logs/per_sample/*.log`。
- 缺失结果：检查 `summary/<phase>_missing_samples.txt`。
