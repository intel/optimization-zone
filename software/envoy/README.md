# Envoy + Fortio Benchmarking: Spin Lock Overhead & Optimization Guide

## Overview

This tuning guide describes best known practises to optimize Fortio + Envoy performance. It evaluates Envoy running as a TCP proxy in front of Fortio, which acts as the backend load generator. The benchmark focuses on proxy-path performance and behavior under load, measuring metrics such as QPS and latency. Both server-side and client-side components are used to generate traffic and collect results, with Envoy and Fortio running in Docker containers based on the images listed below:

- **Fortio**: `fortio/fortio:1.71.1`
- **Envoy**: `envoyproxy/envoy:v1.31.10`



A client machine drives load using:

```bash
# Plain HTTP through Envoy
sudo GOMAXPROCS=16 CONCURRENCY=1000 ./client.sh <server-ip>

# Secure mesh direct mode (no Envoy sidecars, raw application performance)
sudo GOMAXPROCS=16 SECURE_MESH=true CONCURRENCY=1000 ./client.sh <server-ip> direct-bench
```

---

## What Fortio Does

[Fortio](https://github.com/fortio/fortio) is a fast, multi-protocol load testing tool and echo server written in Go.

- **Server mode**: Listens on a port and echoes HTTP requests back. Minimal business logic - it is purely a throughput target.
- **Client mode**: Sends a configurable number of concurrent connections at a target QPS, collecting per-request latency histograms (p50, p90, p99, p99.9).
- **Why it matters here**: Fortio saturates Envoy so we can observe how the proxy performs under real concurrency.

---

## What Envoy Does

[Envoy](https://www.envoyproxy.io/) is a high-performance, C++ L4/L7 proxy used as the data plane in service meshes.

- **Event-driven, non-blocking I/O**: Each worker thread runs an independent libevent loop.
- **`--concurrency N`**: Spawns N worker threads. Each thread owns its own listener socket and connection pool, so there is near-zero cross-thread coordination for established connections.
- **TCP proxy mode** (used here): Envoy accepts a TCP connection on port 9090, opens a connection to Fortio on 8080, and shuttles bytes between them. No L7 parsing overhead.

---

## Topology / Setup

```mermaid

flowchart RL
    subgraph CLIENT[Client Machine - network host B]
        FC["Fortio Client\ncpus 16, GOMAXPROCS=16\nconcurrency=N, qps=0, t=30s"]
        CE["Envoy client-side\ncpus 8, concurrency 8\nlisten :9091"]
    end

    subgraph SERVER[Server Machine - network host A]
        SE["Envoy server-side\ncpus 8, concurrency 8\nlisten :9090"]
        FS["Fortio Server\ncpus 16, GOMAXPROCS=16\nlisten :8080"]
    end


    FC -- "1. localhost:9091" --> CE
    CE -- "1. TCP to REMOTE_IP:9090" --> SE
    SE -- "1. forward to 127.0.0.1:8080" --> FS
    FC -. "2. direct-bench to REMOTE_IP:8080" .-> FS
```

> **1.** Default proxy mode - traffic traverses both Envoy proxies.  
> **2.** `direct-bench(secure mesh)` mode - both Envoys (side cars) are bypassed. Fortio client hits Fortio server directly.  
> **3.** Server and Client are run on different machines & Clinet side measures QPS/latencies.  
> **4.** Setup: Used a high core count machine such as Intel Xeon 6 (Granite Rapids)-- 6980P (128C/256T) for both server & Client

---

## Scripts Overview

### server.sh

Starts two Docker containers on the server machine using host networking:

1. **Fortio server** — echo HTTP server, accepts traffic on `:8080`
2. **Envoy server-side** — TCP proxy, listens on `:9090` and forwards to `127.0.0.1:8080`

Key configs:

| Parameter | Fortio | Envoy |
|---|---|---|
| `--cpus` | 16 | 8 |
| `GOMAXPROCS` | optional, via env | N/A |
| listen port | 8080 | 9090 |
| `--concurrency` | N/A | 8 |
| circuit breaker | N/A | max_connections=20000 |

```bash
# Run on the server machine
./server.sh
```

---

### client.sh

Starts containers on the client machine and drives load toward the server. Supports two modes:

**Default mode** — spins up a client-side Envoy that proxies to the server, then runs Fortio through it:

1. Writes `envoy_client.yaml` pointing to `REMOTE_IP:9090`
2. Starts **Envoy client-side** listening on `localhost:9091`
3. Runs **Fortio client** sending load to `localhost:9091`

**direct-bench mode** — skips both Envoys and sends Fortio traffic directly to `REMOTE_IP:8080`. Optionally sets secure mesh labels (`UBER_NET_CLASSID`, `com.uber.secure_service_mesh`) if `SECURE_MESH=true`.

Key configs:

| Parameter | Fortio client | Envoy client-side |
|---|---|---|
| `--cpus` | 16 | 8 |
| `GOMAXPROCS` | optional, via env | N/A |
| `-c` (concurrency) | `CONCURRENCY` env (default 2000) | N/A |
| `-t` (duration) | 30s | N/A |
| `--payload-size` | 5000 bytes | N/A |
| `-qps` | 0 (max throughput) | N/A |
| listen port | N/A | 9091 |
| `--concurrency` | N/A | 8 |
| circuit breaker | N/A | max_connections=20000 |

```bash
# Default mode: Fortio -> client Envoy :9091 -> server Envoy :9090 -> Fortio server :8080
GOMAXPROCS=16 CONCURRENCY=1000 ./client.sh <server-ip>

# Direct-bench mode: Fortio -> Fortio server :8080 (no Envoy)
GOMAXPROCS=16 SECURE_MESH=true CONCURRENCY=1000 ./client.sh <server-ip> direct-bench
```

---

## CPU Utilization and CPU Quota

The script applies Docker CPU quotas (`--cpus 16` for Fortio, `--cpus 8` for Envoy). On a high core-count server (eg., 128 cores/256Threads), Docker enforces these quotas via cgroup CPU BW control. The OS spreads threads across all cores but throttles aggregate CPU time, resulting in roughly **6 - 7% per-core utilization** across all server cores - not saturation. The CPU quota is the binding constraint, not the WL.

---

## Spin Lock Overhead on High Core Count Machines

### What happens

On a high core-count server, running Fortio without concurrency limits causes significant `native_queued_spin_lock_slowpath` overhead. This behavior is observed with the fortio/fortio:1.71.1 image, which does not confine execution to a small number of CPU cores. Newer Fortio releases built with updated Go versions generally show reduced spin-lock overhead, as they tend to use fewer cores by default, hence better OOB QPS/latencies:

1. **Go runtime (Fortio)**: By default, Go sets `GOMAXPROCS` to the number of logical CPUs visible to the process. On a 128-core/256Threads machine, Go spawns up to 128 OS threads. The Go scheduler uses spin loops - a thread that finds its run queue empty will busy-spin for a short window before parking. With many threads occasionally spinning, aggregate spin overhead becomes significant.

2. **Cache coherency traffic**: Spin locks and atomic CAS operations on shared scheduler state cause cache line bouncing across all sockets. On a multi-socket NUMA system, cross-socket coherency traffic adds latency to every lock acquisition and scales with core count.

3. **Kernel paths involved** (from `perf report` — see [Perf Report](#perf-report-baseline) below):
   - Futex contention: `runtime.lock()` -> `futex()` -> `native_queued_spin_lock_slowpath`
   - Go GC work-stealing: `gcAssistAlloc`, `gcDrainN`, `lfstack.pop`
   - TCP send/recv paths: `tcp_sendmsg`, `tcp_recvmsg`
   - Netpoll: `runtime.netpoll`, `netpollblock`

4. **Envoy `--concurrency` and NUMA**: If Envoy threads are allowed to migrate across NUMA nodes, each worker incurs NUMA-remote memory accesses and LLC  thrashing.

### Symptom

Latency p99/p99.9 climbs, throughput plateaus below the theoretical limit, and `perf` shows high `native_queued_spin_lock_slowpath`, `context-switches`. Spin lock overhead in perf traces is markedly higher in secure-mesh mode than proxy mode due to the additional TLS workload.

---

## Perf Report (Baseline) <a name="perf-report-baseline"></a>

`perf report` output from a baseline run (no optimizations applied), 112K samples of `cycles:P`:

```
# Samples: 112K of event 'cycles:P'
# Event count (approx.): 1869921275007
#
# Overhead  Command          Shared Object            Symbol
# ........  ...............  .......................  .........................................................................................................
#
    29.50%  fortio           fortio                   [.] runtime.(*lfstack).pop
    17.38%  fortio           [kernel.kallsyms]        [k] native_queued_spin_lock_slowpath
     4.41%  fortio           fortio                   [.] runtime.(*lfstack).push
     2.56%  fortio           fortio                   [.] runtime.gcDrain
     1.53%  swapper          [kernel.kallsyms]        [k] intel_idle_xstate
     1.31%  fortio           fortio                   [.] internal/runtime/atomic.(*Uint32).CompareAndSwap
     1.14%  fortio           fortio                   [.] runtime.gcDrainN
     1.07%  fortio           [kernel.kallsyms]        [k] update_sg_lb_stats
     1.04%  fortio           fortio                   [.] runtime.procyield.abi0
     0.86%  fortio           fortio                   [.] runtime.lock2
     0.73%  fortio           fortio                   [.] runtime.getempty
     0.73%  swapper          [kernel.kallsyms]        [k] intel_idle
     0.67%  fortio           fortio                   [.] runtime.stealWork
     0.56%  fortio           fortio                   [.] runtime.markBits.setMarked
     0.55%  fortio           fortio                   [.] internal/runtime/atomic.(*Uint64).CompareAndSwap
     0.53%  fortio           fortio                   [.] runtime.(*gcBits).bytep
     0.51%  fortio           fortio                   [.] runtime.(*activeSweep).begin
     0.47%  fortio           fortio                   [.] runtime.(*activeSweep).end
     0.47%  fortio           fortio                   [.] internal/runtime/atomic.(*Uint64).Load
     0.44%  fortio           fortio                   [.] internal/runtime/atomic.(*Uint64).Add
     0.41%  fortio           fortio                   [.] runtime.(*atomicHeadTailIndex).load
     0.40%  fortio           fortio                   [.] runtime.(*sweepClass).load
     0.37%  fortio           [kernel.kallsyms]        [k] idle_cpu
     0.35%  fortio           fortio                   [.] runtime.pMask.read
     0.34%  fortio           [kernel.kallsyms]        [k] _raw_spin_lock
     0.33%  fortio           [kernel.kallsyms]        [k] osq_lock
     0.30%  fortio           fortio                   [.] runtime.(*mSpanStateBox).get
     0.29%  fortio           fortio                   [.] runtime.runqgrab
     0.25%  fortio           fortio                   [.] internal/runtime/atomic.(*Uint32).Load
     0.24%  fortio           fortio                   [.] runtime.(*spanSet).pop
     0.23%  swapper          [kernel.kallsyms]        [k] menu_select
     0.23%  fortio           fortio                   [.] internal/runtime/atomic.(*Bool).Load
     0.23%  fortio           fortio                   [.] runtime.spanOf
     0.19%  fortio           fortio                   [.] runtime.(*lfstack).empty
     0.19%  swapper          [kernel.kallsyms]        [k] switch_mm_irqs_off
     0.18%  fortio           fortio                   [.] sync.(*Pool).getSlow
     0.18%  fortio           [kernel.kallsyms]        [k] nohz_balance_exit_idle
     0.17%  fortio           fortio                   [.] internal/runtime/atomic.(*Int64).Add
     0.16%  fortio           fortio                   [.] runtime.scanobject
     0.15%  fortio           fortio                   [.] runtime.greyobject
     0.15%  fortio           fortio                   [.] runtime.findObject
     0.15%  swapper          [kernel.kallsyms]        [k] cpuidle_enter_state
     0.15%  fortio           [kernel.kallsyms]        [k] kick_ilb
     0.14%  fortio           fortio                   [.] sync.(*Mutex).Lock
     0.14%  fortio           fortio                   [.] runtime.(*timers).wakeTime
     0.13%  fortio           [kernel.kallsyms]        [k] _find_next_and_bit
     0.13%  fortio           [kernel.kallsyms]        [k] nohz_balancer_kick
     0.13%  fortio           fortio                   [.] runtime.unlock2
     0.13%  fortio           fortio                   [.] internal/runtime/atomic.(*Int64).Load
     0.13%  fortio           [kernel.kallsyms]        [k] update_cfs_group
     0.13%  fortio           fortio                   [.] sync.(*poolChain).popTail
```

Key observations:
- **`runtime.(*lfstack).pop` (29.5%) + `push` (4.4%)** — Go's lock-free stack used for GC work queues and `sync.Pool`; dominant cost here is cache-line contention across many threads
- **`native_queued_spin_lock_slowpath` (17.4%)** — cross-NUMA kernel spin lock contention driven by too many Go OS threads spread across sockets
- **`gcDrain` (2.56%) + `gcDrainN` (1.14%) + GC atomics** — GC scanning overhead; high allocation rate from concurrent Fortio requests forces frequent GC cycles
- **`procyield` (1.04%) + `lock2` (0.86%) + `stealWork` (0.67%)** — Go scheduler spin-waiting and work-stealing across processors, worsened by high `GOMAXPROCS`

---

## Optimizations

### 1. NUMA Pinning (Most Impactful)

Pin both Fortio and Envoy to a single NUMA node on server side. This is the single most impactful optimization - it substantially reduces `native_queued_spin_lock_slowpath` overhead by keeping all memory allocations, thread migrations, and NIC interrupts on the same socket.

```bash
# Pin both containers to NUMA node 0
sudo docker run ... --cpuset-cpus "<numa0 CPU range based on the SKU>" --cpuset-mems "0" fortio/fortio:1.71.1 ...
sudo docker run ... --cpuset-cpus "<numa0 CPU range based on the SKU>" --cpuset-mems "0" envoyproxy/envoy:v1.31.10 ...
```

Or on the host directly:

```bash
numactl --cpunodebind=0 --membind=0 -- envoy -c envoy.yaml --concurrency 16
```

**Why it helps**: Cross-socket coherency traffic is the dominant cause of `native_queued_spin_lock_slowpath` overhead on high core-count systems. Confining the WL to NUMA node 0 eliminates this entirely.

---

### 2. Increase CPU Quota for Both Containers

With NUMA pinning in place, increasing the CPU quota for both Fortio and Envoy containers further reduces scheduling delays and spin lock overhead. Keep `--concurrency` equal to `--cpus` to avoid over-subscription. The numbers are just examples. Tune this based on the SKU/cores used. 

```bash
# Example: raise Fortio from --cpus 16 to --cpus 32, Envoy from --cpus 8 to --cpus 16
sudo docker run ... --cpus 32 -e GOMAXPROCS=32 fortio/fortio:1.71.1 ...
sudo docker run ... --cpus 16 ... envoyproxy/envoy:v1.31.10 -c /etc/envoy/envoy.yaml --concurrency 16
```

Always apply NUMA pinning first; increasing quota without NUMA pinning gives diminishing returns on high core-count machines.

---

### 3. Limit GOMAXPROCS (Fortio)

Set `GOMAXPROCS` to match the Docker `--cpus` allocation so the Go scheduler does not create more OS threads than there are physical CPUs available. The numbers are just examples. Tune this based on the SKU/cores used. :

```bash
sudo docker run ... --cpus 16 -e GOMAXPROCS=16 fortio/fortio:1.71.1 ...
```

**Go &le; 1.24**: `GOMAXPROCS` must be set manually as shown above.  
**Go 1.25+**: Go reads the cgroup v2 CPU quota and automatically sets `GOMAXPROCS` without any env var.

---

### 4. GC Overhead Reduction - Go's GreenTea GC

Fortio's load generator creates large numbers of short-lived objects (request/response structs, buffers, timers). The default Go GC (tricolor mark-and-sweep) scans the object graph one object at a time, causing poor spatial locality, high contention on global queues, and significant cycles spent in the scan loop.

**GreenTea GC** (prototype in Go 1.24, available in Go 1.25.1(as exp feature)) is a span-centric generational collector. Should be enabled by default in Go 1.26:

- Scans in aligned 8 KB spans rather than individual objects -> better cache behavior and less evictions.
- Reduces overhead from `gcDrain`, `trygetfull`, and `lfstack` paths observed in perf traces.
- New span operations (`tryDeferToSpanScan`, `localSpanQueue.stealFrom`) distribute GC work more evenly across processors.
- Results in less time spent in GC and more CPU available for the application.

To use GreenTea GC, build Fortio with Go 1.25.1 and the GreenTea flag enabled or use 1.26 where its enabled by default.


---
### 5. Use fewer CPU cores as possible to run Envoy + fortio
Fortio and Envoy are intentionally run on a reduced number of CPU cores to avoid excessive spin-lock contention and busy-waiting behavior. By limiting core availability, the benchmark prevents threads from continuously spinning on shared locks and instead exposes meaningful contention, scheduling, and proxy-path behavior under realistic CPU pressure 

---
### 6. Other Envoy Tuning -- which can be explored

#### Worker and socket tuning
- **`SO_REUSEPORT`**: Already used by Envoy by default. Verify it is not disabled by any sysctls - it distributes `accept()` load evenly across worker threads without a shared accept mutex.
- **`--concurrency`**: Tune thread concurrency to match the number of physical cores assigned to the container. Over-provisioning causes false sharing, under-provisioning wastes hardware.

#### Huge pages (TLB pressure)
Envoy's memory allocator (`tcmalloc` / `jemalloc`) benefits from 2 MB huge pages, which reduce TLB miss rates when proxying many concurrent flows:

```bash
echo 512 > /proc/sys/vm/nr_hugepages
```

#### CPU frequency governor & BIOS/OS settings
Disable dynamic frequency scaling to eliminate governor-induced latency spikes:

```bash
cpupower frequency-set -g performance
```
Ensure you have configured the floowing as deflaut in BIOS or from the OS(using perfspect tool) on Granite Rapids (Xeon6) or later systems 

1. `Efficiency Latency Control`: Latency Optimized
2. `Energy Performance Bias`: Performance (0)
3. `Energy Performance Preference`:  Performance (0)


---

## Quick Diagnosis Checklist

| Symptom | Likely cause | Fix |
|---|---|---|
| High `native_queued_spin_lock_slowpath` in perf | Cross-NUMA memory access | Pin both containers to NUMA node 0 |
| High TLB in perf or spinlocks | Cross-NUMA memory access | Ensure Huge Pages are enabled |
| High `native_queued_spin_lock_slowpath` from Go threads | Too many Go OS threads | Set `GOMAXPROCS` = `--cpus` value |
| High LLC-load-misses in `perf stat` | Cross-NUMA memory access | Pin to single NUMA node |
| GC overhead in perf traces (`gcDrain`, `trygetfull`) | High allocation rate with default GC | Build Fortio with GreenTea GC (Go 1.25.1); raise `GOGC` |
| Envoy CPU bottlenecked in TLS | mTLS handshake overhead | Enable TLS session resumption. Make TLS communicaiton/handshake Async |
| NIC softirq on same cores as Envoy | IRQ affinity not set or not part of of same NUMA | Separate NIC IRQ cores from Envoy worker cores or ensure cores + mem + NIC are on same NUMA |
| Latency spikes every few seconds | CPU frequency scaling | Set `performance` governor |
| Throughput limited despite headroom | CPU quota too low | Increase `--cpus` for both containers together with `--concurrency` |
