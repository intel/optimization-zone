# Enabling Priority Core Turbo (PCT) for GPU Performance

## Overview

**[Intel® Priority Core Turbo](https://www.intel.com/content/www/us/en/content-details/846906/priority-core-turbo-technology-pct-technology-technical-article.html) (PCT)** is part of **[Intel® Speed Select Technology](https://www.intel.com/content/www/us/en/content-details/682325/intel-speed-select-technology-intel-sst-performance-enhancements-for-3rd-gen-intel-xeon-scalable-processor-technology-guide.html) – [Turbo Frequency](https://builders.intel.com/solutionslibrary/intel-speed-select-technology-turbo-frequency-intel-sst-tf-overview-user-guide) (SST-TF)**.
It allows a subset of CPU cores to operate at **higher turbo frequencies**, while remaining cores run closer to base frequency.

This is particularly effective for **GPU-accelerated AI inference**, where a small number of CPU threads handle
**latency-critical, mostly serial tasks** such as tokenization, scheduling, and feeding GPUs.
Running these threads on **High-Priority (HP) cores** improves GPU utilization, Time-to-first-token (TTFT), and tail latency.

Validated platforms:

- **Intel® Xeon® 6776P**

## How PCT Works
<details>
<summary> PCT Details </summary>
  
PCT relies on **two Intel Speed Select features**:

- **SST-TF (Turbo Frequency)**
  Defines the high-priority turbo buckets and the number of physical cores that can use each bucket.

- **SST-CP (Core Power / CLOS)**
  Assigns CPUs to **Classes of Service (CLOS)**.
  CPUs assigned to **CLOS0** are treated as **High-Priority** by PCT.

> **Important:** PCT is only effective when CPUs are explicitly assigned to **CLOS0** and Core Power / CLOS is enabled.

### PCT bucket-count interpretation

intel-speed-select tool mentioned below is installed inside the docker image in the [environment build seciton](#1-build-the-environment)

`intel-speed-select turbo-freq info -l <level>` may print the same `bucket-0`,
`bucket-1`, and `bucket-2` SST-TF table under multiple `powerdomain-*` anchors.  
A powerdomain anchor is the representative CPU id where a packages's internal power domain starts.   

For PCT **capacity**, this flow counts `bucket-0` **once per package/socket**:

```text
bucket-0 high-priority-cores-count:8 @ 4600 MHz
=> 8 PCT physical cores per package/socket
```

On a two-socket Intel® Xeon® 6776P system with Hyper-Threading enabled:

```text
2 packages × 8 physical PCT cores/package = 16 physical PCT cores total
16 physical PCT cores × 2 threads/core    = 32 logical PCT CPUs total
```

### Capacity versus placement

There are two different concepts:

| Concept | Correct model |
| --- | --- |
| **PCT capacity** | Count `bucket-0` once per package/socket |
| **HP CPU placement** | Dispatch the package-level PCT core budget across the package's PCT reporting powerdomain anchors |

For Intel® Xeon® 6776P system with 2 sockets and 64 cores per socket, `bucket-0` reports using check_pct_status.sh in [check-pct-status session](#2-check-pct-status):

```text
PCT_CORES_PER_PACKAGE=8
PCT_ACTIVE_PACKAGES=2
PCT_TOTAL_PHYSICAL_CORES=16
THREADS_PER_CORE=2
PCT_TOTAL_LOGICAL_CPUS=32
```

But the `turbo-freq` output shows two reporting anchors per package:

```text
package 0: anchor cpu0,  anchor cpu32
package 1: anchor cpu64, anchor cpu96
```

Therefore, the set script dispatches the **8 physical PCT cores per package**
across the package's two reporting anchors:

```text
package 0: 4 physical cores from cpu0  + 4 physical cores from cpu32
package 1: 4 physical cores from cpu64 + 4 physical cores from cpu96
```

With Hyper-Threading included, this becomes:

```text
0-3,32-35,64-67,96-99,128-131,160-163,192-195,224-227
```

</details>

## 1. Build the Environment

<details>
<summary> Build Details </summary>
  
Export the kernel build variables first:

```bash
source ./set_kernel_env.sh
```

Build the Docker image with required tools:

```bash
docker compose --progress=plain build --no-cache
```

Verify `intel-speed-select` exists inside the image:

```bash
docker compose run --rm intel-speed-select-shell 'which intel-speed-select && intel-speed-select --help | head'
```

</details>

## 2. Check PCT Status

<details>
<summary> This step verifies: </summary>
  
- Hardware support for Intel® Speed Select features
- SST-TF/PCT bucket-0 capacity
- Correct package/socket-based PCT capacity counting
- Core Power and CLOS enablement
- Current CPU-to-CLOS mapping
- Whether the current `TARGET_CLOS` CPU count matches the expected PCT logical CPU budget

</details>

Export the kernel build variables first:

```bash
source ./set_kernel_env.sh
```

Run:

```bash
docker compose --progress=plain --profile check up --abort-on-container-exit
```

Example results when PCT and CLOS are enabled successfully:

<details>
<summary> Example results </summary>
  
```bash
------------------------------------------------------------
CPU and Intel Speed Select Capability
------------------------------------------------------------
Intel(R) SST-PP (feature perf-profile) is supported
Intel(R) SST-TF (feature turbo-freq) is supported
Intel(R) SST-BF (feature base-freq) is not supported
Intel(R) SST-CP (feature core-power) is supported
Intel(R) Speed Select Technology
Executing on CPU model:173[0xad]

------------------------------------------------------------
PCT Capacity from SST-TF bucket-0
------------------------------------------------------------
✅ PCT/SST-TF turbo tables detected.
PCT_BUCKET=bucket-0
PCT_REPORTING_ANCHORS=4
PCT_ACTIVE_PACKAGES=2
PCT_CORES_PER_PACKAGE=8
PCT_TOTAL_PHYSICAL_CORES=16
PCT_MAX_FREQ_MHZ=4600
PCT_DOMAIN_ANCHORS=pkg0/die0/pd0/cpu0:cores8:freq4600,pkg0/die0/pd1/cpu32:cores8:freq4600,pkg1/die1/pd0/cpu64:cores8:freq4600,pkg1/die1/pd1/cpu96:cores8:freq4600
PCT_PACKAGE_SUMMARY=pkg0:cores8:freq4600:anchors2,pkg1:cores8:freq4600:anchors2
THREADS_PER_CORE=2
PCT_TOTAL_LOGICAL_CPUS=32

------------------------------------------------------------
Core Power (CLOS) Feature Status
------------------------------------------------------------
✅ Core Power feature ENABLED
✅ CLOS ENABLED

------------------------------------------------------------
CPU -> CLOS Mapping via get-assoc
------------------------------------------------------------
CLOS distribution (count by clos id):
  clos:0 -> 32 CPUs
  clos:2 -> 224 CPUs

------------------------------------------------------------
CPU list for TARGET_CLOS=0
------------------------------------------------------------
clos:0 CPU list: 0-3,32-35,64-67,96-99,128-131,160-163,192-195,224-227
Wrote clos:0 CPU list to /workspace/benchmarks/results/clos0_cpulist.txt

------------------------------------------------------------
PCT Budget Validation for CLOS0
------------------------------------------------------------
CLOS0 CPU count             : 32
PCT bucket                        : bucket-0
PCT reporting anchors             : 4
PCT active packages/sockets       : 2
PCT cores per package/socket      : 8
PCT physical core budget          : 16
PCT max frequency                 : 4600 MHz
Threads per core                  : 2
Expected PCT logical CPU budget   : 32
✅ CLOS0 CPU count exactly matches the bucket-0 PCT logical budget.

------------------------------------------------------------
Summary
------------------------------------------------------------
✅ PCT turbo tables detected
✅ PCT capacity detected: 16 physical HP cores total, 32 logical CPUs with HT=2
   Count model: bucket-0 counted once per package/socket, not once per powerdomain anchor.
✅ Core Power enabled
✅ CLOS enabled
Done.
```

</details>

The check script writes the current target-CLOS CPU list to:

```text
./results/clos0_cpulist.txt
```

For the example above, `clos0_cpulist.txt` contains 32 logical CPUs. With
Hyper-Threading enabled, that corresponds to 16 physical PCT cores.

## 3. Set PCT and Assigned HP CPUs

This step **activates PCT in practice** by assigning selected HP CPUs to **CLOS0**.

The setup script intentionally **overwrites existing BIOS/runtime CLOS settings**:

1. Enable Core Power / CLOS.
2. Move **all online CPUs → `OTHER_CLOS`**.
3. Move selected HP CPUs → `HP_CLOS`.

This prevents stale BIOS or previous runtime CLOS assignments from leaving unexpected
CPUs in CLOS0.

### Set-script behavior

<details>
<summary> The setup script performs the following actions: </summary>
  
- Detects PCT capacity from `intel-speed-select turbo-freq info -l <TDP_LEVEL>`.
- Counts `bucket-0` once per package/socket.
- Derives `HP_PER_PACKAGE` from `PCT_CORES_PER_PACKAGE` unless overridden.
- Reads the PCT reporting anchors from `PCT_DOMAIN_ANCHORS`.
- Dispatches each package's `HP_PER_PACKAGE` physical-core budget across that package's reporting powerdomain anchors.
- Selects contiguous physical CPUs starting from each reporting anchor CPU.
- Includes Hyper-Threading siblings by default with `INCLUDE_HT=1`.
- Assigns:
    - **Selected HP CPUs → CLOS0** by default
    - **All remaining CPUs → CLOS2** by default

</details>

Export the kernel build variables first:

```bash
source ./set_kernel_env.sh
```

Run the setup:

```bash
docker compose --progress=plain --profile set up --abort-on-container-exit
```

Or test the selection without changing the system:

```bash
DRY_RUN=1 docker compose --progress=plain --profile set up --abort-on-container-exit
```

### Example: package capacity dispatched across reporting powerdomain anchors

<details>
<summary> Example results </summary>
  
```bash
intel-speed-select-set-1  | ------------------------------------------------------------
intel-speed-select-set-1  | PCT capacity from SST-TF bucket-0
intel-speed-select-set-1  | ------------------------------------------------------------
intel-speed-select-set-1  | PCT_BUCKET=bucket-0
intel-speed-select-set-1  | PCT_REPORTING_ANCHORS=4
intel-speed-select-set-1  | PCT_ACTIVE_PACKAGES=2
intel-speed-select-set-1  | PCT_CORES_PER_PACKAGE=8
intel-speed-select-set-1  | PCT_TOTAL_PHYSICAL_CORES=16
intel-speed-select-set-1  | PCT_MAX_FREQ_MHZ=4600
intel-speed-select-set-1  | PCT_DOMAIN_ANCHORS=pkg0/die0/pd0/cpu0:cores8:freq4600,pkg0/die0/pd1/cpu32:cores8:freq4600,pkg1/die1/pd0/cpu64:cores8:freq4600,pkg1/die1/pd1/cpu96:cores8:freq4600
intel-speed-select-set-1  | PCT_PACKAGE_SUMMARY=pkg0:cores8:freq4600:anchors2,pkg1:cores8:freq4600:anchors2
intel-speed-select-set-1  |
intel-speed-select-set-1  | ------------------------------------------------------------
intel-speed-select-set-1  | Config
intel-speed-select-set-1  | ------------------------------------------------------------
intel-speed-select-set-1  | ACTION=set
intel-speed-select-set-1  | HP_BUCKET=0  TDP_LEVEL=1
intel-speed-select-set-1  | HP_PER_PACKAGE=8
intel-speed-select-set-1  | INCLUDE_HT=1
intel-speed-select-set-1  | HP_CLOS=0  OTHER_CLOS=2
intel-speed-select-set-1  | DEBUG_MODE=0  DRY_RUN=0  DEBUG_VERBOSE=0  DEBUG_MAP=0
intel-speed-select-set-1  |
intel-speed-select-set-1  | ------------------------------------------------------------
intel-speed-select-set-1  | Powerdomain-anchor HP CPU dispatch
intel-speed-select-set-1  | ------------------------------------------------------------
intel-speed-select-set-1  | package 0: HP_PER_PACKAGE=8, reporting_anchors=2, dispatch_per_anchor=[4, 4]
intel-speed-select-set-1  |   pkg0/pd0/anchor_cpu0 -> 4 physical cores -> core0:0/128 core1:1/129 core2:2/130 core3:3/131
intel-speed-select-set-1  |   pkg0/pd1/anchor_cpu32 -> 4 physical cores -> core32:32/160 core33:33/161 core34:34/162 core35:35/163
intel-speed-select-set-1  | package 1: HP_PER_PACKAGE=8, reporting_anchors=2, dispatch_per_anchor=[4, 4]
intel-speed-select-set-1  |   pkg1/pd0/anchor_cpu64 -> 4 physical cores -> core64:64/192 core65:65/193 core66:66/194 core67:67/195
intel-speed-select-set-1  |   pkg1/pd1/anchor_cpu96 -> 4 physical cores -> core96:96/224 core97:97/225 core98:98/226 core99:99/227
intel-speed-select-set-1  | HP_EFFECTIVE=0-3,32-35,64-67,96-99,128-131,160-163,192-195,224-227
intel-speed-select-set-1  | ------------------------------------------------------------
intel-speed-select-set-1  | Computed CPU lists
intel-speed-select-set-1  | ------------------------------------------------------------
intel-speed-select-set-1  | HP effective      : 0-3,32-35,64-67,96-99,128-131,160-163,192-195,224-227
intel-speed-select-set-1  | HP CPU count      : 32
intel-speed-select-set-1  | Non-HP            : 4-31,36-63,68-95,100-127,132-159,164-191,196-223,228-255
intel-speed-select-set-1  |
intel-speed-select-set-1  | PCT active packages/sockets       : 2
intel-speed-select-set-1  | PCT reporting anchors             : 4
intel-speed-select-set-1  | PCT cores per package/socket      : 8
intel-speed-select-set-1  | PCT physical core budget          : 16
intel-speed-select-set-1  | PCT max frequency                 : 4600 MHz
intel-speed-select-set-1  |
intel-speed-select-set-1  | Expected HP CPU count for this INCLUDE_HT setting: 32
intel-speed-select-set-1  |
intel-speed-select-set-1  | ------------------------------------------------------------
intel-speed-select-set-1  | Apply CLOS assignments (overwrite existing BIOS/runtime mapping)
intel-speed-select-set-1  | ------------------------------------------------------------
intel-speed-select-set-1  | Setting ALL CPUs -> CLOS2 first
intel-speed-select-set-1  | Setting selected HP CPUs -> CLOS0
intel-speed-select-set-1  | Applied.
intel-speed-select-set-1  |
intel-speed-select-set-1  | ------------------------------------------------------------
intel-speed-select-set-1  | Verification (concise CPU->CLOS)
intel-speed-select-set-1  | ------------------------------------------------------------
intel-speed-select-set-1  | HP list should be clos:0
intel-speed-select-set-1  | cpu-0 clos:0
intel-speed-select-set-1  | cpu-1 clos:0
intel-speed-select-set-1  | … (showing first 2 lines)
intel-speed-select-set-1  |
intel-speed-select-set-1  | Non-HP list should be clos:2
intel-speed-select-set-1  | cpu-4 clos:2
intel-speed-select-set-1  | cpu-5 clos:2
intel-speed-select-set-1  | … (showing first 2 lines)
intel-speed-select-set-1  |
intel-speed-select-set-1  | Done.
```

</details>

After applying the set flow, run the check flow again.
The check output should show:

```text
clos:0 -> 32 CPUs
clos:0 CPU list: 0-3,32-35,64-67,96-99,128-131,160-163,192-195,224-227
Expected PCT logical CPU budget   : 32
✅ CLOS0 CPU count exactly matches the bucket-0 PCT logical budget.
```

## 4. Benchmark CLOS0 CPUs with PerfSpect tool on the host

Use Docker only to configure and verify PCT/CLOS. Run PerfSpect on the host so
the frequency benchmark can access host CPU frequency interfaces directly.

### Prerequisites

<details>
<summary> Details </summary>
  
The host benchmark script reads the CPU list generated by the check profile:

```bash
./results/clos0_cpulist.txt
```

Install PerfSpect on the host first:

```bash
mkdir -p "${HOME}/tools"
cd "${HOME}/tools"

wget -qO- https://github.com/intel/PerfSpect/releases/latest/download/perfspect.tgz | tar -xz

sudo ln -sf "${HOME}/tools/perfspect/perfspect" /usr/local/bin/perfspect
```

Confirm it is available:

```bash
which perfspect
perfspect --help | head
```

</details>

### Run the benchmark
By using PerfSpect benchmark feature, it generates a diagram of CPU frequency among different number of active CPU cores.  
The diagram helps us to understand whether PCT cores can reach the right CPU frequency.  
Run the full flow with [run_host_perfspect_benchmark.sh](run_host_perfspect_benchmark.sh) :

```bash
docker compose --progress=plain --profile set up --abort-on-container-exit
docker compose --progress=plain --profile check up --abort-on-container-exit

./run_host_perfspect_benchmark.sh
```

<details>
<summary> Details </summary>

Default host benchmark command:

```bash
sudo taskset -c "${CLOS_CPUS}" perfspect benchmark --speed --frequency --no-summary --output <output-dir>
```

Override the PerfSpect benchmark options with `PERFSPECT_ARGS`:

```bash
PERFSPECT_ARGS="--speed --frequency --memory --no-summary" \
./run_host_perfspect_benchmark.sh
```
</details>

### Analyze results

Benchmark output is written under:

```bash
./results/perfspect_host_clos0_<timestamp>/
```

The directory includes:

```text
clos0_cpulist.txt
perfspect_benchmark.log
perfspect/
```
Check Frequency section in HTML file.  
This is the frequency diagram on Xeon 6776P with PCT on. 
<img width="835" height="483" alt="image" src="https://github.com/user-attachments/assets/96f8855c-4b83-4c62-a0dd-fa2408f979fb" />

This is the expected pattern: small active core counts hold the highest PCT turbo
frequency, and frequency gradually steps down as more physical cores become active.

## 5. Debug / Manual Inspection (Optional)

<details>
<summary> Debug Details </summary>

This section is useful for **troubleshooting**, **validation**, or **manual experimentation**
with Intel® Speed Select and PCT behavior.

Start an interactive shell with the required tools installed:

```bash
docker compose run --rm intel-speed-select-shell
```

Useful commands:

```bash
intel-speed-select --info
intel-speed-select turbo-freq info -l 1
intel-speed-select core-power info
intel-speed-select -c 0 core-power get-assoc
```
</details>
