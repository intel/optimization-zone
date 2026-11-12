 # Intel HammerDB TPROC-C Benchmark Configuration and Reproducibility Reference for Microsoft SQL Server on AWS RDS

This guide documents the complete, reproducible configuration of the RDS for SQL Server benchmark harness: the AWS RDS instance and engine settings, the Microsoft SQL Server database configuration, the HammerDB TPROC-C workload, and every metric and artifact collected for analysis. Example used in this guide references:

- Microsoft SQL Server on AWS RDS db.r6i.2xlarge (8 vCPU / 64 GiB), db.r8i.4xlarge (8 vCPU / 128 GiB) and db.r8i.8xlarge (8 vCPU / 256 GiB - using "Optimize CPU" option).

**Revision Record**
| Date | Rev. | Description |
|------|------|-------------|
| 10/15/2026 | 1.0 | Initial Release |

**Table of Contents**

- [Intel HammerDB TPROC-C Benchmark Configuration and Reproducibility Reference for Microsoft SQL Server on AWS RDS](#intel-hammerdb-tproc-c-benchmark-configuration-and-reproducibility-reference-for-microsoft-sql-server-on-aws-rds)
  - [1. Amazon RDS Instance \& Engine Configuration](#1-amazon-rds-instance--engine-configuration)
  - [2. SQL Server Database Configuration](#2-sql-server-database-configuration)
    - [2.1 Indirect checkpoint (TARGET\_RECOVERY\_TIME)](#21-indirect-checkpoint-target_recovery_time)
    - [2.2 tempdb file layout (allocation-page latch relief)](#22-tempdb-file-layout-allocation-page-latch-relief)
    - [2.3 tpcc user-database file layout (optional, measure-first)](#23-tpcc-user-database-file-layout-optional-measure-first)
  - [3. HammerDB TPROC-C Workload Configuration](#3-hammerdb-tproc-c-workload-configuration)
    - [3.1 Schema build](#31-schema-build)
    - [3.2 Connection settings (both build \& run)](#32-connection-settings-both-build--run)
    - [3.3 Timed-run settings (per data point)](#33-timed-run-settings-per-data-point)
    - [3.4 Workload profiles](#34-workload-profiles)
    - [3.5 AWS EC2 Load Generator VM](#35-aws-ec2-load-generator-vm)


## 1. Amazon RDS Instance & Engine Configuration

Common to all instances to be benchmarked unless noted. Storage should be identical on all instances, so EBS should never be the differentiator.

| RDS / engine setting | Value |
| --- | --- |
| Engine | sqlserver-ee (SQL Server Enterprise Edition) |
| Engine version | 16.00 (SQL Server 2022) |
| License model | license-included |
| Storage type | gp3 |
| Allocated storage | 1000 GB |
| Provisioned IOPS | 16000 |
| Storage throughput | 600 MB/s |
| Multi-AZ | false (single-AZ) |
| Publicly accessible | false |
| Backup retention | 1 day |
| Performance Insights | Enabled, 7-day retention |
| Enhanced Monitoring interval | 1 second (OS metrics -> CloudWatch Logs RDSOSMetrics) |

## 2. SQL Server Database Configuration

### 2.1 Indirect checkpoint (TARGET_RECOVERY_TIME)

RDS defaults `TARGET_RECOVERY_TIME` to 60 s. The harness raises it to 300 s on both the `tpcc` user database and `tempdb` so checkpoint behavior is identical and matches the intended configuration. It is re-applied on every drop/restore and again at run time (a snapshot/restore resets `tempdb` to the RDS default).

| Setting | Value |
| --- | --- |
| tpcc TARGET_RECOVERY_TIME | 300 seconds |
| tempdb TARGET_RECOVERY_TIME | 300 seconds |
| RDS default (overridden) | 60 seconds |

Apply on every target after restart/restore so it is re-applied at run time too:

```sql
ALTER DATABASE [tpcc]   SET TARGET_RECOVERY_TIME = 300 SECONDS WITH NO_WAIT;
ALTER DATABASE [tempdb] SET TARGET_RECOVERY_TIME = 300 SECONDS WITH NO_WAIT;

-- Verify: both rows should return 300
SELECT name, target_recovery_time_in_seconds
FROM sys.databases
WHERE name IN (N'tpcc', N'tempdb');
```

### 2.2 tempdb file layout (allocation-page latch relief)

Multiple equal-size `tempdb` data files reduce PFS/GAM/SGAM latch contention (Microsoft rule of thumb: 1 file per logical CPU up to 8). Applied on the baseline at build and re-applied on every run because snapshot/restore resets `tempdb` to the RDS default. `ADD FILE` and grow-only `MODIFY` take effect immediately on RDS (no restart).

| Setting | Value |
| --- | --- |
| tempdb data files | 8 |
| Size per file | 8192 MB (≈ 64 GiB total) |
| Autogrowth per file | 512 MB |
| Data directory | **\<insert here\>** Example: `D:\rdsdbdata\DATA\` |

Inspect the current layout first:

```sql
SELECT name, physical_name,
       size / 128 AS size_mb,
       CASE WHEN is_percent_growth = 1 THEN CONCAT(growth, N'%')
            ELSE CONCAT(growth / 128, N' MB') END AS autogrowth
FROM tempdb.sys.database_files
WHERE type_desc = N'ROWS';
```

Then run the script below. It is idempotent, so you can re-run it after every snapshot restore.
It grows existing data files to the target size (grow-only), sets autogrowth, and adds files
until there are 8:

```sql
DECLARE @target_files int           = 8,
        @size_mb      int           = 8192,
        @growth_mb    int           = 512,
        @data_dir     nvarchar(260) = N'D:\rdsdbdata\DATA\',  -- <insert here>
        @name         sysname,
        @sql          nvarchar(max),
        @i            int           = 2;

-- 1. Resize existing data files and set autogrowth
DECLARE files CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM tempdb.sys.database_files WHERE type_desc = N'ROWS';
OPEN files;
FETCH NEXT FROM files INTO @name;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF (SELECT size / 128 FROM tempdb.sys.database_files WHERE name = @name) < @size_mb
    BEGIN
        SET @sql = CONCAT(N'ALTER DATABASE tempdb MODIFY FILE (NAME = N''', @name,
                          N''', SIZE = ', @size_mb, N'MB);');
        EXEC (@sql);
    END;
    SET @sql = CONCAT(N'ALTER DATABASE tempdb MODIFY FILE (NAME = N''', @name,
                      N''', FILEGROWTH = ', @growth_mb, N'MB);');
    EXEC (@sql);
    FETCH NEXT FROM files INTO @name;
END;
CLOSE files;
DEALLOCATE files;

-- 2. Add data files until there are @target_files.
--    Follows SQL Server naming (logical tempdev<n>, physical tempdb<n>.ndf) and skips
--    any name whose logical or physical file already exists. Stops on the first error.
WHILE (SELECT COUNT(*) FROM tempdb.sys.database_files WHERE type_desc = N'ROWS') < @target_files
BEGIN
    SET @name = CONCAT(N'tempdev', @i);
    IF NOT EXISTS (SELECT 1 FROM tempdb.sys.database_files
                   WHERE name = @name
                      OR physical_name = CONCAT(@data_dir, N'tempdb', @i, N'.ndf'))
    BEGIN
        SET @sql = CONCAT(N'ALTER DATABASE tempdb ADD FILE (NAME = N''', @name,
                          N''', FILENAME = N''', @data_dir, N'tempdb', @i, N'.ndf'', SIZE = ',
                          @size_mb, N'MB, FILEGROWTH = ', @growth_mb, N'MB);');
        BEGIN TRY
            EXEC (@sql);
        END TRY
        BEGIN CATCH
            THROW;
        END CATCH;
    END;
    SET @i += 1;
END;
```

Re-run the inspection query to confirm 8 data files of 8192 MB with 512 MB autogrowth.

### 2.3 tpcc user-database file layout (optional, measure-first)

Extra PRIMARY-filegroup data files can relieve allocation contention for heavy concurrent INSERTs. On RDS all files share one EBS volume, so the only benefit is latch relief (no I/O parallelism). Applied to BOTH instances only if PAGELATCH contention is observed; PRIMARY uses `AUTOGROW_ALL_FILES` so proportional fill stays even.

| Setting | Value |
| --- | --- |
| tpcc PRIMARY data files | 4 |
| Size per file | 51200 MB (≈ 200 GiB total, pre-sized for 1000 warehouses) |
| Autogrowth per file | 4096 MB |
| Filegroup option | AUTOGROW_ALL_FILES|

Check for allocation-page latch contention on `tpcc` while the workload is running. The
`resource_description` of a PAGELATCH wait is `database_id:file_id:page_id`:

```sql
SELECT wait_type, resource_description, COUNT(*) AS waiting_tasks
FROM sys.dm_os_waiting_tasks
WHERE wait_type LIKE N'PAGELATCH[_]%'
  AND resource_description LIKE CONCAT(DB_ID(N'tpcc'), N':%')
GROUP BY wait_type, resource_description
ORDER BY waiting_tasks DESC;
```

If contention is confirmed, inspect the current files, then add data files to `PRIMARY`. Run this
when no workload is connected:

```sql
-- Inspect the current tpcc files and their logical names
SELECT f.name, f.type_desc, fg.name AS filegroup_name, f.physical_name, f.size / 128 AS size_mb
FROM tpcc.sys.database_files AS f
LEFT JOIN tpcc.sys.filegroups AS fg ON f.data_space_id = fg.data_space_id;

-- Grow-only: skip this statement if the existing file is already larger than 51200 MB
ALTER DATABASE [tpcc] MODIFY FILE (NAME = N'tpcc', SIZE = 51200MB, FILEGROWTH = 4096MB);

-- Add three more files for 4 PRIMARY data files in total
ALTER DATABASE [tpcc] ADD FILE (NAME = N'tpcc2', FILENAME = N'D:\rdsdbdata\DATA\tpcc2.ndf',
    SIZE = 51200MB, FILEGROWTH = 4096MB) TO FILEGROUP [PRIMARY];
ALTER DATABASE [tpcc] ADD FILE (NAME = N'tpcc3', FILENAME = N'D:\rdsdbdata\DATA\tpcc3.ndf',
    SIZE = 51200MB, FILEGROWTH = 4096MB) TO FILEGROUP [PRIMARY];
ALTER DATABASE [tpcc] ADD FILE (NAME = N'tpcc4', FILENAME = N'D:\rdsdbdata\DATA\tpcc4.ndf',
    SIZE = 51200MB, FILEGROWTH = 4096MB) TO FILEGROUP [PRIMARY];

-- Grow all PRIMARY files together so proportional fill stays even
ALTER DATABASE [tpcc] MODIFY FILEGROUP [PRIMARY] AUTOGROW_ALL_FILES;
```

Replace the logical name `tpcc` and the `D:\rdsdbdata\DATA\` path with the values that the
inspection query returns.

## 3. HammerDB TPROC-C Workload Configuration

### 3.1 Schema build

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

Save as `build.tcl` and run it from the HammerDB install directory with
`./hammerdbcli auto build.tcl`. It uses the connection settings in `connection.tcl`
(section 4.3):

```tcl
dbset db mssqls
dbset bm TPC-C
source connection.tcl

diset tpcc mssqls_dbase tpcc
diset tpcc mssqls_count_ware 1000
diset tpcc mssqls_num_vu 16
diset tpcc mssqls_use_bcp true

buildschema
vudestroy
checkschema
```

### 3.2 Connection settings (both build & run)

| Setting | Value |
| --- | --- |
| Protocol / port | TCP / 1433 |
| Server fields | `mssqls_server` + `mssqls_linux_server` (Linux driver) |
| Authentication | SQL authentication (`mssqls_authentication sql`) |
| Encrypt connection | true |
| Trust server certificate | true |

Save as `connection.tcl`. Both the build and run scripts source it. The password is read from
the `MSSQL_PASSWORD` environment variable so that it is not stored in the script:

```tcl
diset connection mssqls_server {<insert here: RDS endpoint>}
diset connection mssqls_linux_server {<insert here: RDS endpoint>}
diset connection mssqls_tcp true
diset connection mssqls_port 1433
diset connection mssqls_authentication sql
diset connection mssqls_linux_authent sql
diset connection mssqls_linux_odbc {ODBC Driver 18 for SQL Server}
diset connection mssqls_uid {<insert here: master username>}
diset connection mssqls_pass $::env(MSSQL_PASSWORD)
diset connection mssqls_encrypt_connection true
diset connection mssqls_trust_server_cert true
```

### 3.3 Timed-run settings (per data point)

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

Save as `run.tcl`. It runs one timed data point. The VU count and the workload profile
(section 4.5) come from the `VU` and `PROFILE` environment variables:

```tcl
dbset db mssqls
dbset bm TPC-C
source connection.tcl

set vu      $::env(VU)
set profile $::env(PROFILE)   ;# peak or fixed

diset tpcc mssqls_dbase tpcc
diset tpcc mssqls_count_ware 1000
diset tpcc mssqls_driver timed
diset tpcc mssqls_rampup 15
diset tpcc mssqls_duration 30
diset tpcc mssqls_allwarehouse false
diset tpcc mssqls_checkpoint true
diset tpcc mssqls_timeprofile true
giset timeprofile profiler xtprof
diset tpcc mssqls_keyandthink false

if {$profile eq "fixed"} {
    diset tpcc mssqls_async_scale true
    diset tpcc mssqls_async_client 250
    diset tpcc mssqls_async_delay 0
    giset commandline keepalive_margin 300
} else {
    diset tpcc mssqls_async_scale false
}

loadscript
vuset vu $vu
vuset logtotemp 1
vucreate
vurun
vudestroy
```

### 3.4 Workload profiles

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

Run the VU sweep for both profiles against one target. Each data point runs 3 times
(`RUNS_PER_POINT`) and the median NOPM/TPM is reported:

```bash
#!/usr/bin/env bash
set -euo pipefail

TARGET=r6i2xl-baseline                 # <insert here> target identifier
RUNS_PER_POINT=3
: "${MSSQL_PASSWORD:?Set MSSQL_PASSWORD before running}"
export MSSQL_PASSWORD

declare -A VU_LEVELS=(
  [peak]="2 4 8 16 24 32 48 64"
  [fixed]="8 16 32 64"
)

ulimit -n 65535
mkdir -p "results/${TARGET}"

for profile in peak fixed; do
  for vu in ${VU_LEVELS[$profile]}; do
    for run in $(seq 1 "${RUNS_PER_POINT}"); do
      log="results/${TARGET}/${profile}_vu${vu}_run${run}.log"
      echo "$(date -u +%FT%TZ) ${TARGET} profile=${profile} vu=${vu} run=${run}"
      PROFILE="${profile}" VU="${vu}" ./hammerdbcli auto run.tcl | tee "${log}"
      sleep 120   # settle time between data points
    done
  done
done
```

Record the start and end time of each run. You need them to pull CloudWatch, Performance
Insights and Enhanced Monitoring data for the same time window.

### 3.5 AWS EC2 Load Generator VM

| Setting | Value |
| --- | --- |
| Instance type | m8i.8xlarge |
| Open-file limit | Raised to 65535 at run time (async FD demand) |
| Role | Runs HammerDB CLI; kept otherwise idle for fairness |

Raise the open-file limit in the shell that runs HammerDB, and persist it for the benchmark user:

```bash
# Current shell
ulimit -n 65535
ulimit -n            # verify: 65535

# Persist across logins (replace <user> with the account that runs HammerDB)
echo '<user> soft nofile 65535
<user> hard nofile 65535' | sudo tee /etc/security/limits.d/90-hammerdb.conf
```

HammerDB connects through the Microsoft ODBC driver on Linux. Confirm that the driver is
installed:

```bash
odbcinst -q -d       # expect: [ODBC Driver 18 for SQL Server]
```


