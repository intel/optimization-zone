# Intel HammerDB TPROC-C Benchmark Configuration and Reproducibility Reference for Microsoft SQL Server on Amazon RDS

This guide documents the complete, reproducible configuration of the RDS for SQL Server benchmark harness: the AWS RDS instance and engine settings, the Microsoft SQL Server database configuration, the HammerDB TPROC-C workload, and every metric and artifact collected for analysis. Example used in this guide references:

- Microsoft SQL Server on AWS RDS db.r6i.2xlarge (8 vCPU / 64 GiB), db.r8i.4xlarge (8 vCPU / 128 GiB) and db.r8i.8xlarge (8 vCPU / 256 GiB - using Optimize CPU).

**Revision Record**
| Date | Rev. | Description |
|------|------|-------------|
| 10/15/2026 | 1.0 | Initial Release |

**Table of Contents**

- [Intel HammerDB TPROC-C Benchmark Configuration and Reproducibility Reference for Microsoft SQL Server on Amazon RDS](#intel-hammerdb-tproc-c-benchmark-configuration-and-reproducibility-reference-for-microsoft-sql-server-on-amazon-rds)
  - [1. Overview \& Test Design](#1-overview--test-design)
  - [2. Amazon RDS Instance \& Engine Configuration](#2-amazon-rds-instance--engine-configuration)
  - [3. SQL Server Database Configuration](#3-sql-server-database-configuration)
    - [3.1 Indirect checkpoint (TARGET\_RECOVERY\_TIME)](#31-indirect-checkpoint-target_recovery_time)
    - [3.2 tempdb file layout (allocation-page latch relief)](#32-tempdb-file-layout-allocation-page-latch-relief)
    - [3.3 tpcc user-database file layout (optional, measure-first)](#33-tpcc-user-database-file-layout-optional-measure-first)
    - [3.4 Server-configuration capture (per target, at run time)](#34-server-configuration-capture-per-target-at-run-time)
  - [4. HammerDB TPROC-C Workload Configuration](#4-hammerdb-tproc-c-workload-configuration)
    - [4.1 Schema build](#41-schema-build)
    - [4.2 Connection settings (both build \& run)](#42-connection-settings-both-build--run)
    - [4.3 Timed-run settings (per data point)](#43-timed-run-settings-per-data-point)
    - [4.4 Workload profiles](#44-workload-profiles)
    - [4.5 Load driver (EC2)](#45-load-driver-ec2)
  - [5. Metrics \& Data Collected](#5-metrics--data-collected)
    - [5.1 HammerDB result metrics](#51-hammerdb-result-metrics)
    - [5.2 Amazon CloudWatch metrics (AWS/RDS, 60 s period, Average)](#52-amazon-cloudwatch-metrics-awsrds-60-s-period-average)
    - [5.3 Performance Insights](#53-performance-insights)
    - [5.4 Enhanced Monitoring (OS-level, 1 s) — perfmon analogue](#54-enhanced-monitoring-os-level-1-s--perfmon-analogue)
    - [5.5 SQL Server DMV snapshots (before \& after every run; analysis diffs them)](#55-sql-server-dmv-snapshots-before--after-every-run-analysis-diffs-them)
    - [5.6 Pricing / economics inputs](#56-pricing--economics-inputs)
  - [6. Analysis Outputs](#6-analysis-outputs)
  - [7. Fairness Controls](#7-fairness-controls)

## 1. Overview & Test Design

| Item | Description |
| --- | --- |
| Objective | **\<insert here\>** Example: Equal-license cross-generation throughput / latency / cost A/B |
| Baseline (control) | **\<insert here\>** Example: db.r6i.2xlarge — 8 vCPU / 64 GiB, default CPU |
| Newer Generation + Memory | **\<insert here\>** Example: db.r8i.4xlarge (8 vCPU by default due to SMT off, 128 GiB RAM). This isolates the impact of instance generation and increased memory. |
| Optimize CPU (test) | **\<insert here\>** Example: db.r8i.8xlarge with Optimize CPU (native 16 vCPU/256 GiB RAM, manually configured to 8 vCPU). This quantifies "the value of renting a large instance but licensing only 8 vCPUs." |
| Workload tool | **\<insert here\>** Example: HammerDB 5.0, TPROC-C (TPC-C derived; results reported as NOPM/TPM) |
| Load driver | **\<insert here\>** Example: Amazon EC2 c7i.4xlarge (16 vCPU) — never the bottleneck |
| Schema parity | Built once on baseline, cloned via snapshot/restore (identical data/stats) |
| Iterations | 3 runs per data point; median NOPM/TPM reported |

## 2. Amazon RDS Instance & Engine Configuration

Common to all instances to be benchmarked unless noted. Storage is identical on all instances, so EBS is never the differentiator.

| RDS / engine setting | Value |
| --- | --- |
| AWS Region | us-east-1 |
| Engine | sqlserver-ee (SQL Server Enterprise Edition) |
| Engine version | Latest 16.00 (SQL Server 2022), resolved at runtime |
| License model | license-included |
| Baseline instance class | **\<insert here\>** Example: db.r6i.2xlarge (8 vCPU / 64 GiB, default CPU) |
| Baseline identifier | **\<insert here\>** Example: r6i2xl-baseline |
| Optimize-CPU instance class | **\<insert here\>** Example: db.r8i.4xlarge (8 vCPU / 128 GiB on RDS SQL Server, SMT off) |
| Optimize-CPU identifier | **\<insert here\>** Example: r8i4xl-ocpu |
| Optimize CPU: coreCount | **\<insert here\>** Example: 8 (RDS SQL Server default for this class; no vCPU reduction) |
| Optimize CPU: threadsPerCore | **\<insert here\>** Example: 1 (SMT disabled on RDS SQL Server) |
| Effective OCPU vCPUs | **\<insert here\>** Example: 8 (8 physical cores × 1 thread = class default) |
| Real-OCPU instance class | **\<insert here\>** Example: db.r8i.8xlarge (16 vCPU / 256 GiB default on RDS SQL Server, SMT off) |
| Real-OCPU identifier | **\<insert here\>** Example: r8i8xl-ocpu |
| Real-OCPU: coreCount | **\<insert here\>** Example: 8 (genuine 16 -> 8 reduction; ~halves the SQL EE license) |
| Real-OCPU effective vCPUs | **\<insert here\>** Example: 8 (of 16 native; keeps full 256 GiB RAM) |
| Storage type | gp3 |
| Allocated storage | 1000 GB |
| Provisioned IOPS | 16000 |
| Storage throughput | 600 MB/s |
| Master username | **\<insert here\>** |
| Multi-AZ | false (single-AZ) |
| Publicly accessible | false |
| Backup retention | 1 day |
| Performance Insights | Enabled, 7-day retention |
| Enhanced Monitoring interval | 1 second (OS metrics -> CloudWatch Logs RDSOSMetrics) |
| Golden schema snapshot | **\<insert here\>** Example: r6i2xl-tprocc-golden (built on r6i, restored on r8i) |

## 3. SQL Server Database Configuration

### 3.1 Indirect checkpoint (TARGET_RECOVERY_TIME)

RDS defaults `TARGET_RECOVERY_TIME` to 60 s. The harness raises it to 300 s on both the `tpcc` user database and `tempdb` so checkpoint behavior is identical and matches the intended configuration. It is re-applied on every drop/restore and again at run time (a snapshot/restore resets `tempdb` to the RDS default).

| Setting | Value |
| --- | --- |
| tpcc TARGET_RECOVERY_TIME | 300 seconds |
| tempdb TARGET_RECOVERY_TIME | 300 seconds |
| RDS default (overridden) | 60 seconds |

### 3.2 tempdb file layout (allocation-page latch relief)

Multiple equal-size `tempdb` data files reduce PFS/GAM/SGAM latch contention (Microsoft rule of thumb: 1 file per logical CPU up to 8). Applied on the baseline at build and re-applied on every run because snapshot/restore resets `tempdb` to the RDS default. `ADD FILE` and grow-only `MODIFY` take effect immediately on RDS (no restart).

| Setting | Value |
| --- | --- |
| tempdb data files | 8 |
| Size per file | 8192 MB (≈ 64 GiB total) |
| Autogrowth per file | 512 MB |
| Data directory | **\<insert here\>** Example: `D:\rdsdbdata\DATA\` |

### 3.3 tpcc user-database file layout (optional, measure-first)

Extra PRIMARY-filegroup data files can relieve allocation contention for heavy concurrent INSERTs. On RDS all files share one EBS volume, so the only benefit is latch relief (no I/O parallelism). Applied to BOTH instances only if PAGELATCH contention is observed; PRIMARY uses `AUTOGROW_ALL_FILES` so proportional fill stays even.

| Setting | Value |
| --- | --- |
| tpcc PRIMARY data files | 4 |
| Size per file | 51200 MB (≈ 200 GiB total, pre-sized for 1000 warehouses) |
| Autogrowth per file | 4096 MB |
| Filegroup option | AUTOGROW_ALL_FILES |
| Applied when | Only if `50_collect_metrics.sh` flags PAGELATCH on tpcc |

3.4 SQL server trace flags and sp_configure settings done for all 3 instances

### 3.4 Server-configuration capture (per target, at run time)

`config_capture.sql` records the following once per target to `results/<target>/<target>_config_capture.txt`, proving both instances matched:

- Full `sp_configure` (all options incl. advanced) — MAXDOP, cost threshold for parallelism, max server memory, etc.
- Active global/session trace flags (`DBCC TRACESTATUS(-1)`).
- `TARGET_RECOVERY_TIME` + recovery model per database (tpcc, tempdb, model, master, msdb).
- tempdb file layout: file count, size, autogrowth, physical path.
- tpcc file layout: PRIMARY filegroup data/log file count, size, autogrowth.
- SQL Server version banner and capture timestamp (UTC).
- SQL Server error log (via `rdsadmin.dbo.rds_read_error_log`).

Note: statistics are refreshed post-build on a best-effort basis (`ALTER AUTHORIZATION` + `sp_updatestats`); because the OCPU instance is a snapshot/restore clone, statistics are identical on both sides regardless.

## 4. HammerDB TPROC-C Workload Configuration

### 4.1 Schema build

| Setting | Value |
| --- | --- |
| HammerDB version | 5.0 |
| Benchmark | TPROC-C (TPC-C derived) |
| Database backend | mssqls (SQL Server) |
| Warehouses | 1000 (≈ 100 GB) |
| Build virtual users | 16 |
| BCP bulk load | Enabled (`mssqls_use_bcp true`) |
| Target database | tpcc |
| Build verification | `checkschema` after build |

### 4.2 Connection settings (both build & run)

| Setting | Value |
| --- | --- |
| Protocol / port | TCP / 1433 |
| Server fields | `mssqls_server` + `mssqls_linux_server` (Linux driver) |
| Authentication | SQL authentication (`mssqls_authentication sql`) |
| Encrypt connection | true |
| Trust server certificate | true |

### 4.3 Timed-run settings (per data point)

| Setting | Value |
| --- | --- |
| Driver | timed |
| Ramp-up | 15 minutes |
| Measured duration | 30 minutes |
| Time profiling (xtprof) | true (P95/P99 percentile latency per transaction) |
| All-warehouse | false |
| Checkpoint between runs | true |
| Iterations per point (`RUNS_PER_POINT`) | 3 (median NOPM/TPM reported) |
| Warehouse count (`mssqls_count_ware`) | 1000 |
| Active VUs (`mssqls_num_vu`) | Set per data point from the VU sweep |

### 4.4 Workload profiles

Two profiles are run against each target; both now use zero think/keying time.

| Profile setting | Value |
| --- | --- |
| Peak — purpose | Find max NOPM throughput ceiling (CPU saturation) |
| Peak — keying/think time | Disabled (`mssqls_keyandthink false`) |
| Peak — async scale | false |
| Peak — VU levels | 2, 4, 8, 16, 24, 32, 48, 64 |
| Fixed-throughput — purpose | Production-like fixed high concurrency (NOPM + latency) |
| Fixed — keying/think time | Disabled (`mssqls_keyandthink false`) |
| Fixed — async scale | true (asynchronous clients) |
| Fixed — async clients per VU | 250 |
| Fixed — async delay | 0 ms (no think/delay) |
| Fixed — keepalive margin | 300 s (drain in-flight async clients) |
| Fixed — VU levels | 8, 16, 32, 64 |
| Fixed — emulated terminals (max) | 64 VU × 250 = 16,000 |

### 4.5 Load driver (EC2)

| Setting | Value |
| --- | --- |
| Instance type | **\<insert here\>** |
| Open-file limit | Raised to 65535 at run time (async FD demand) |
| Role | Runs HammerDB CLI; kept otherwise idle for fairness |

## 5. Metrics & Data Collected

### 5.1 HammerDB result metrics

- NOPM — New Orders Per Minute (primary throughput metric).
- TPM — SQL Server Transactions Per Minute.
- xtprof percentile latency (P95 / P99) per transaction type: NEW-ORDER, PAYMENT, DELIVERY, STOCK-LEVEL, ORDER-STATUS.
- Median NOPM/TPM across the 3 iterations per (target, profile, VU) data point.

### 5.2 Amazon CloudWatch metrics (AWS/RDS, 60 s period, Average)

- CPUUtilization
- DatabaseConnections
- ReadIOPS
- WriteIOPS
- ReadThroughput
- WriteThroughput
- ReadLatency
- WriteLatency
- DiskQueueDepth
- FreeableMemory
- EBSIOBalance%
- EBSByteBalance%

### 5.3 Performance Insights

- `db.load.avg` (average active sessions) grouped by `db.wait_event` (top 10 waits).
- 7-day retention; pulled per run time-window by DbiResourceId.
- PAGELATCH share is flagged automatically as an allocation-contention hint.

### 5.4 Enhanced Monitoring (OS-level, 1 s) — perfmon analogue

Delivered to CloudWatch Logs group `RDSOSMetrics`, one stream per DbiResourceId. Each event is a JSON blob sampled at 1-second granularity:

- cpuUtilization (per-core and aggregate)
- memory (free, used, cached, etc.)
- diskIO / fileSys utilization
- network throughput
- loadAverage

### 5.5 SQL Server DMV snapshots (before & after every run; analysis diffs them)

`dmv_snapshot.sql` captures these colon-marked sections; `analyze_results.py` computes per-run deltas:

- CPU_CONFIG — cpu_count, scheduler_count, socket_count, cores_per_socket, memory_gb, sqlserver_start_time.
- PERF_COUNTERS — Batch Requests/sec, SQL Compilations/sec, SQL Re-Compilations/sec, Transactions/sec, Log Flushes/sec, Log Bytes Flushed/sec, Page life expectancy, Buffer cache hit ratio, Page reads/sec, Page writes/sec, Checkpoint pages/sec, Lock Waits/sec, Average Wait Time (ms), User Connections.
- WAIT_STATS — top 25 wait types by wait_time_ms (benign/idle waits filtered), with waiting_tasks_count and signal_wait_time_ms.
- FILE_IO — per-database-file reads/writes, bytes, and I/O stall (ms) for tpcc + tempdb.
- SCHEDULER_PRESSURE — avg runnable tasks, total work-queue, visible schedulers.

### 5.6 Pricing / economics inputs

- License-included price (USD/hr) per instance class (baseline & OCPU).
- Derived: cost per 1,000 NOPM-hr and cost per 1,000,000 New Orders.
- Per-core-count rates supported for the Optimize-CPU knee sweep.

## 6. Analysis Outputs

`analyze_results.py` merges the HammerDB manifest, CloudWatch, Performance Insights and DMV deltas, then writes to `results/report/`:

| Artifact | Contents |
| --- | --- |
| `benchmark_summary.csv` | One row per data point PER iteration, all KPIs |
| `benchmark_medians.csv` | Median NOPM/TPM and metrics per (target, profile, VU) |
| `wait_stats_delta.csv` | Top wait types per run (before/after DMV delta) |
| `charts/nopm_<profile>.png` | NOPM-vs-VU throughput curve |
| `charts/p95_<profile>.png` / `p99_<profile>.png` | NEW-ORDER latency percentiles |
| `charts/cpu_<profile>.png` | Steady-state RDS CPU utilization |
| `charts/cost_<profile>.png` | Cost per 1M New Orders (license-included) |
| `charts/knee_nopm_cost_vs_cores.png` | Optimize-CPU throughput & cost vs coreCount |
| `core_sweep_summary.csv` | Per-core-count peak NOPM + NOPM/vCPU (sweep mode) |
| `BENCHMARK_REPORT.md` | Filled comparison report (headline NOPM/TPM medians) |

## 7. Fairness Controls

- Identical engine version, parameter group, storage config and warehouse count on both instances.
- Bit-identical data, indexes and statistics via snapshot/restore clone.
- Equal vCPU license basis example — r8i.4xlarge on RDS SQL Server is 8 vCPU by default (SMT off); coreCount=8 is set explicitly and equals that default.
- Runs alternate only by target; the load driver is kept otherwise idle.
- 2-minute settle time between data points; checkpoint after each run.
- 3 iterations per point with median reporting to suppress single-run anomalies.
