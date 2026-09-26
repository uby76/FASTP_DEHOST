# FASTP_DEHOST

用于 Falcon/Slurm 集群的双端测序数据处理脚本：从 ENA 下载 FASTQ，经 `fastp` 质控，再去除人源 reads，并计算 mtDNA 深度和 crAssphage 信号。

> 本仓库只保存代码，不包含 FASTQ、BAM、参考基因组、Bowtie2 索引、运行结果或日志。脚本保留了 Falcon 上的绝对路径，换服务器时必须先修改路径和 Slurm 参数。

## 处理流程

```text
ENA run ID
  → 下载并校验 FASTQ
  → fastp 质控
  → Bowtie2 比对 GRCh38，保留非人源成对 reads
  → 计算人源比例、mtDNA 平均深度和 crAssphage 信号
  → 汇总 TSV
```

## 目录

```text
FASTP_DEHOST/
├── fastp/    # ENA 下载、fastp 质控和批次汇总
├── dehost/   # 去人源、mtDNA/crAssphage 计算和结果汇总
└── README.md
```

## 运行环境

- Slurm 集群及 Bash、Python 3。
- `fastp 1.0.1`、`Bowtie2 2.5.4`、`SAMtools 1.21`、`minimap2 2.30`、`MetaBAT2 2.17`。
- 下载步骤还需 `curl` 和 `aria2c`。
- GRCh38、chrM 和 crAssphage BK010471 参考序列/索引。

## fastp 目录中的代码

### `run_effluentonly_download.sbatch`

ENA 下载主程序。从 `input/data.txt` 读取 `ena_run_acc`、`Run` 或 `run_accession` 列，校验并去重 run ID，并行获取 ENA 元数据，用 `aria2c` 断点续传 FASTQ，最后校验文件大小和 MD5。下载失败的文件会被记录并跳过，不会中断整批任务。

```bash
sbatch fastp/run_effluentonly_download.sbatch
```

主要输出：`metadata/fastq_file_manifest.tsv`、`metadata/download_summary.tsv`、`fastq/*.fastq.gz`。

### `build_ena_manifest.py`

读取 ENA API 返回的每个 run TSV，生成 FASTQ 文件清单、不可用 run 清单和 `aria2c` 输入文件。

```bash
python3 fastp/build_ena_manifest.py REPORT_DIR META_DIR FASTQ_DIR
```

### `audit_downloads.py`

根据清单检查 FASTQ 是否存在、是否为空、大小是否一致，并在 ENA 提供 MD5 时计算校验值。输出已验证文件、失败文件、完成 run 及数量汇总。

```bash
python3 fastp/audit_downloads.py FILE_MANIFEST FASTQ_DIR META_DIR
```

### `reconcile_effluentonly.py`

对比新旧 run 列表，生成保留、新增、移除及待删文件审计记录。默认只审计；加 `--apply` 才会删除不属于新列表的 FASTQ/ENA 报告、清理旧汇总，并将新输入移到 `input/data.txt`。

```bash
# 先审计
python3 fastp/reconcile_effluentonly.py --root ROOT --new-input NEW_DATA
# 确认审计文件后再应用
python3 fastp/reconcile_effluentonly.py --root ROOT --new-input NEW_DATA --apply
```

### `build_fastp_snapshot.py`

根据 run 列表、ENA 清单和本地 FASTQ 构建不可变的 fastp 批次快照。只选择 R1/R2 齐全、大小正确、不在下载且以前未完成的样本。批次目录必须不存在。

```bash
python3 fastp/build_fastp_snapshot.py --root ROOT --batch-dir ROOT/fastp_batches/batch_YYYYMMDD_HHMMSS
```

### `run_fastp_snapshot.sbatch`

fastp 批处理主程序。先做小型运行预检，再按 4 个样本并行质控；检查快照后输入是否变化，并用临时文件+原子替换避免半成品被当作成功结果。

```bash
BATCH_DIR=/path/to/batch sbatch fastp/run_fastp_snapshot.sbatch
# 如批次目录尚未建立，可自动构建快照
AUTO_BUILD_SNAPSHOT=1 BATCH_DIR=/path/to/new_batch sbatch fastp/run_fastp_snapshot.sbatch
```

`DELETE_RAW_AFTER_SUCCESS=1` 会在每个样本质控成功后删除对应原始 FASTQ；默认为 `0`。

### `aggregate_fastp_batch.py`

读取快照清单、样本状态和 fastp JSON，汇总原始/质控后 reads、bases、Q20 和 Q30，生成 `fastp_batch_summary.tsv` 和 `fastp_batch_counts.tsv`。

```bash
python3 fastp/aggregate_fastp_batch.py BATCH_DIR
```

### `cleanup_prior_fastp_raw.py`

查找历史 fastp 批次的 `.done` 样本，确认成对 clean FASTQ 存在后，删除对应原始 FASTQ 和 `.aria2` 文件，并输出审计 TSV。该脚本会实际删除数据，没有 dry-run 模式。

```bash
python3 fastp/cleanup_prior_fastp_raw.py --root ROOT --current-batch BATCH_DIR --output AUDIT.tsv
```

## dehost 目录中的代码

### `config.sh`

集中定义工作目录、fastp 批次、GRCh38/chrM/crAssphage 参考数据、MetaBAT2 路径及并行参数。迁移环境时首先修改此文件。

### `build_manifest.py`

从一个或多个 fastp 批次收集已成功的 clean R1/R2，排除已完成或已分配到前一阶段的样本，生成 dehost manifest 和审计表。

```bash
python3 dehost/build_manifest.py \
  --batch BATCH1 --batch BATCH2 \
  --exclude-done-dir STATUS_DIR \
  --exclude-manifest PHASE1.tsv \
  --output PHASE2.tsv --audit PHASE2.audit.tsv
```

### `run_phase.sbatch`

dehost 阶段的 Slurm 入口。`phase1` 使用已冻结清单，其他阶段会动态生成清单。首次先做单样本 smoke test，通过后并行调用 `run_one_safe.sh`，最后汇总。

```bash
PHASE=phase1 sbatch dehost/run_phase.sbatch
PHASE=phase2 sbatch dehost/run_phase.sbatch
```

### `run_one.sh`

单样本核心流程：

1. Bowtie2 `--sensitive` 对 GRCh38 比对，输出人源 BAM 和成对非人源 FASTQ。
2. 用 minimap2 将 clean reads 比对 chrM，再用 `jgi_summarize_bam_contig_depths` 计算 mtDNA 平均深度。
3. 将非人源 reads 比对 crAssphage BK010471，计算 mapped records 和 `crAssphageratio`。
4. 生成每样本 `summary.tsv` 和 `.done` 状态。

```bash
bash dehost/run_one.sh SAMPLE_ID MANIFEST.tsv full
bash dehost/run_one.sh SAMPLE_ID MANIFEST.tsv test
```

### `run_one_safe.sh`

`run_one.sh` 的容错封装。将单样本标准输出/错误写入日志；失败时写 `.failed` 状态但返回成功码，使其他样本继续运行。

```bash
bash dehost/run_one_safe.sh SAMPLE_ID MANIFEST.tsv
```

### `subset_fastq.py`

从 gzip FASTQ 头部提取指定数量的 records，用于 smoke test。

```bash
python3 dehost/subset_fastq.py INPUT.fastq.gz OUTPUT.fastq.gz RECORDS
```

### `test.sbatch`

取 `phase1.tsv` 的第一个样本执行 test 模式，验证能否产生 `summary.tsv`；成功后写入 `SMOKE_TEST_OK`。

```bash
sbatch dehost/test.sbatch
```

### `aggregate.py`

按 manifest 收集每个样本的 `summary.tsv`，生成阶段汇总 `summary/<phase>_human_mtDNA_crAssphage_signals.tsv`，并记录缺失样本。

```bash
python3 dehost/aggregate.py ROOT MANIFEST.tsv PHASE
```

### `reset_bowtie_sensitive_steps.sh`

用于改变 Bowtie2 参数后重跑。`audit` 只统计状态；`apply` 会删除 human/crAssphage 的 `.done`、样本汇总和阶段完成标记，但保留 mtDNA 完成标记。

```bash
bash dehost/reset_bowtie_sensitive_steps.sh audit
bash dehost/reset_bowtie_sensitive_steps.sh apply
```

### `restore_completed_very_sensitive.sh`

检查已有 BAM、非人源 FASTQ、日志和计数文件，对经验证的旧结果恢复 `.done` 状态和样本汇总，避免重复计算。名称保留了历史参数名，实际恢复前应确认现有结果与当前分析参数一致。

```bash
bash dehost/restore_completed_very_sensitive.sh
```

## 实际 Falcon 目录

- fastp 原脚本：`/shared/scratch/SCWF00047/legacydata/b.jnl24chv/effluentonly/scripts/`
- dehost 原脚本：`/shared/scratch/SCWF00047/legacydata/b.jnl24chv/effluentonly/human_signals_20260806/scripts/`

## 安全提示

- 先修改 `ROOT`、参考数据路径和 `#SBATCH` 参数，再在新环境运行。
- `reconcile_effluentonly.py --apply`、`cleanup_prior_fastp_raw.py`、`DELETE_RAW_AFTER_SUCCESS=1` 和 `reset_bowtie_sensitive_steps.sh apply` 会删除文件或状态，必须先检查路径和审计输出。
- `run_one_safe.sh` 会记录失败但不让批任务立即失败，运行后需检查 `status/*.failed` 和 missing-samples 列表。
