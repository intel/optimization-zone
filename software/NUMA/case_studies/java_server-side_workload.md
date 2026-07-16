# Java Server-Side Workload Performance Comparison: Taking Advantage of NUMA in Xeon 6th Generation

## Introduction

Modern server systems are engineered with sophisticated hardware architectures designed to deliver exceptional performance—especially when workloads are configured to leverage them properly. This guide demonstrates how a simple configuration change can unlock dramatic performance improvements by aligning your application with your system's underlying hardware topology.

Using real-world benchmark data from Intel Xeon 6972P systems, we show how **matching your workload configuration to your hardware architecture** delivers up to **30% better performance** without any code changes, hardware upgrades, or additional investment. The key insight is straightforward: **when you configure your workload to work with your hardware, you maximize the value of your existing infrastructure**.

Whether you're deploying Java applications, databases, or other enterprise workloads on modern multi-NUMA systems, this guide will help you:

- **Understand why hardware topology matters** for application performance
- **Identify configuration mismatches** that leave performance on the table
- **Apply proven configuration patterns** to optimize your deployments
- **Measure the impact** using real performance data from your own environment

The techniques shown here apply broadly across modern server platforms. While we use a Java server-side workload as our example, the principles of hardware-aware configuration translate directly to production Java applications, containerized workloads, and other enterprise software running on NUMA-capable systems.

**Bottom line:** You've invested in powerful hardware. This guide ensures you're getting the full performance out of it.

---

## Executive Summary

Two Java server-side MultiJVM configurations were tested on the same Intel Xeon 6972P system. The **NUMA-aware 3-JVM configuration significantly outperformed** the suboptimal 2-JVM configuration, demonstrating the importance of proper NUMA topology alignment for Java workloads.

| Metric | Performance Improvement |
|--------|------------------------|
| **server-side-java with SLA requirements** | **+30.0%** |

**Key Finding:** Aligning the JVM group count with the system's 3-NUMA-node topology (changing from 2 to 3 JVM groups) resulted in a **30% improvement in server-side-java with SLA requirements**, the primary performance metric for response time under service level agreements (SLAs).

---

## System Configuration

Both tests were conducted on the same hardware:

| Component | Specification |
|-----------|---------------|
| **CPU Model** | Intel Xeon 6972P (Granite Rapids) |
| **Microarchitecture** | GNR_X3 |
| **Sockets** | 1 |
| **Cores per Socket** | 96 |
| **Total Threads** | 192 (Hyperthreading enabled) |
| **NUMA Nodes** | **3** |
| **Memory** | 768GB (12x64GB DDR5 6400MT/s) |
| **OS** | Ubuntu 22.04.5 LTS |
| **Kernel** | 5.15.0-173-generic |
| **JDK** | Zulu 17.46.19-ca-jdk17.0.9 |

### NUMA Topology

The system has **3 NUMA nodes** with the following latency characteristics:

| From/To | Node 0 | Node 1 | Node 2 |
|---------|--------|--------|--------|
| **Node 0** | 117.1 ns | 140.3 ns | 163.8 ns |
| **Node 1** | 135.9 ns | 117.1 ns | 143.2 ns |
| **Node 2** | 158.6 ns | 135.0 ns | 119.0 ns |

**Remote memory access latency penalty:** Up to **40% higher** when accessing memory from a different NUMA node.

---

## Configuration Comparison

### 2-JVM Configuration (Suboptimal)

**Test Date:** March 31, 2026  

```
Groups = 2
Fork and join threads: Tier 1 = 192, Tier 2 = 96, Tier 3 = 96
```

- **2 JVM groups** running on a **3-NUMA-node** system
- Worker threads: 192/96/96 distributed across tiers
- **Mismatch:** Group count does not align with NUMA topology

**Problem:** With only 2 groups on a 3-node system, at least one JVM group must span multiple NUMA nodes, causing increased memory access latency and reduced cache efficiency.

### 3-JVM Configuration (NUMA-Optimized)

**Test Date:** March 29, 2026  

```
Groups = 3
Fork and join threads: Tier 1 = 128, Tier 2 = 64, Tier 3 = 64
```

- **3 JVM groups** running on a **3-NUMA-node** system
- Worker threads: 128/64/64 distributed across tiers
- **Optimal alignment:** JVM group count matches NUMA node count

**Benefit:** With matching group and node counts, the workload naturally distributes across NUMA nodes more effectively, reducing remote memory access penalties.

---

## Performance Results

### Overall Throughput

| Configuration | server-side-java with SLA requirements Improvement |
|---------------|---------------------------|
| **2-JVM (Suboptimal)** | Baseline |
| **3-JVM (NUMA-Optimized)** | **+30.0%** |

### Server-Side-Java with SLA Requirements by SLA (99th Percentile)

The server-side-java with SLA requirements metric is calculated as the geometric mean of throughput at various SLA response time targets:

| SLA Target | Performance Improvement |
|------------|------------------------|
| **10 ms** | **+50.9%** |
| **25 ms** | **+35.8%** |
| **50 ms** | **+26.4%** |
| **75 ms** | **+24.0%** |
| **100 ms** | **+15.6%** |
| **Overall (server-side-java with SLA requirements)** | **+30.0%** |

**Key Insight:** The performance advantage is **most pronounced at stricter SLA targets** (10ms), where the 3-JVM configuration achieves over **50% higher throughput**. This demonstrates that NUMA optimization significantly reduces tail latencies.

---

## Why the 3-JVM Configuration Performs Better

### 1. **NUMA Locality**
- With 3 JVM groups on a 3-NUMA-node system, the workload distributes more naturally across nodes
- Better memory locality reduces remote access penalties (up to 40% latency overhead)
- More memory requests satisfied with ~117ns local latency instead of 140-164ns cross-node access

### 2. **Reduced Memory Contention**
- 3 smaller groups (128/64/64 threads) vs 2 larger groups (192/96/96 threads)
- Better distribution of memory bandwidth across NUMA nodes
- Each node's local bandwidth (~190 GB/s) is utilized more efficiently

### 3. **Cache Efficiency**
- Smaller working sets per JVM group fit better in L3 cache (per-socket shared cache)
- Reduced cache line migrations between NUMA nodes
- Better cache-to-compute ratio for each group

### 4. **Lower Tail Latencies**
- NUMA-local memory access results in more predictable response times
- Critical for meeting aggressive SLA targets (e.g., 99th percentile < 10ms)
- Explains why server-side java with SLA requirements improved by 30% while server-side java throughput only improved by 1.7%

---

## JVM Configuration Details

### Backend JVM Settings (Both Configurations)

```bash
-Xms24g -Xmx24g -Xmn20g
```

- Heap size: 24 GB
- Young generation: 20 GB
- Same settings for both configurations

### Thread Pool Configuration

| Config | Tier1 Workers | Tier2 Workers | Tier3 Workers | Total Workers |
|--------|---------------|---------------|---------------|---------------|
| **2-JVM** | 192 | 96 | 96 | 384 |
| **3-JVM** | 128 | 64 | 64 | 256 |

The 2-JVM configuration uses more threads but achieves lower performance due to NUMA inefficiencies.

---

## Recommendations

### For This System (Intel Xeon 6972P with 3 NUMA Nodes)

1. **Always use 3 JVM groups** to match the NUMA topology
2. Configure thread pools proportionally to the number of cores per NUMA node (32 cores/node)
3. Use `lscpu` or `numactl --hardware` to verify NUMA topology before configuration

**Note:** The results shown in this document were achieved simply by matching the JVM group count to the NUMA node count—no explicit CPU or memory binding with `numactl` was used. For even greater performance gains, consider explicit NUMA binding as a next optimization step.

### General Best Practices

1. **Match JVM group count to NUMA node count** whenever possible
2. Use `lscpu` or `numactl --hardware` to verify NUMA topology before configuration
3. Monitor cross-NUMA memory traffic using performance counters
5. Test different configurations to find optimal thread pool sizes per NUMA node

### Optional: Explicit NUMA Binding for Further Optimization

For additional performance gains beyond what's shown in this document, you can explicitly bind each JVM group to a dedicated NUMA node using `numactl`:

```bash
# Group 1 - NUMA Node 0
numactl --cpunodebind=0 --membind=0 java -Xms24g -Xmx24g ...

# Group 2 - NUMA Node 1
numactl --cpunodebind=1 --membind=1 java -Xms24g -Xmx24g ...

# Group 3 - NUMA Node 2
numactl --cpunodebind=2 --membind=2 java -Xms24g -Xmx24g ...
```

This approach provides even stricter control over NUMA placement and may yield incremental improvements over the configuration-only approach demonstrated here.

---

## Discussion: Performance Analysis from Performance Counter Data

### Memory Subsystem Latency Improvements

Performance monitoring data collected using Intel's performance counter monitoring tool during both runs reveals significant improvements in memory subsystem latencies for the NUMA-optimized configuration:

**LLC (Last Level Cache) Miss Latency Reductions:**
- **Demand data read miss latencies:** Reduced by **10%**
- **RFO (Read-For-Ownership) miss latencies:** Reduced by more than **15%**
- **Local data read miss latencies:** Reduced by more than **5%**

These latency reductions in the cache and memory hierarchy directly contribute to the overall performance improvement. When memory requests can be satisfied more quickly—whether from local NUMA memory or with fewer cross-node accesses—the compute cores spend less time stalled waiting for data, leading to higher effective throughput.

### Impact on Server-Side Java with SLA Requirements Performance

The memory latency improvements are particularly significant for the server-side java with SLA requirements metric, which measures throughput under strict response time SLAs. Lower memory access latencies translate directly to:

1. **Reduced tail latencies** in transaction processing
2. **More consistent response times** across the 99th percentile measurements
3. **Better sustained performance** when operating near SLA boundaries

This explains why the 3-JVM configuration shows a 30% improvement in server-side java with SLA requirements despite only a 1.7% improvement in server-side java throughput numbers. NUMA optimization primarily benefits latency-sensitive operations rather than raw peak throughput.

### Bandwidth Utilization and Contention

The hardware counters also indicate improved bandwidth utilization patterns in the 3-JVM configuration:

- More balanced memory controller traffic across the three NUMA nodes
- Reduced contention for shared memory resources
- Better alignment between memory allocation patterns and physical memory topology

By distributing the workload across three JVM groups that match the three NUMA nodes, the system avoids "hot spots" where multiple groups compete for the same memory controller bandwidth.

### Memory Bandwidth Throughput Analysis

Beyond latency improvements, the bandwidth counters reveal dramatic increases in memory throughput for the NUMA-optimized configuration:

**Bandwidth Increases (3-JVM vs 2-JVM):**
- **Read bandwidth:** Up **39%**
- **Write bandwidth:** Up **47%**
- **Total bandwidth:** Up **41%**

These substantial bandwidth increases demonstrate that matching the JVM group count to the NUMA topology allows the entire benchmark to capitalize on the balanced system architecture. When the workload naturally distributes across all NUMA nodes:

1. **All three memory controllers are actively utilized** rather than having workload concentrated on fewer nodes
2. **Load balancing across NUMA nodes** prevents bottlenecks at individual memory controllers
3. **Aggregate system bandwidth approaches theoretical maximum** by engaging all available memory channels simultaneously

The 41% increase in total bandwidth is particularly significant—it shows that the 2-JVM configuration was leaving substantial memory bandwidth untapped due to poor NUMA alignment. The NUMA-optimized 3-JVM configuration unlocks this dormant capacity, allowing the benchmark to achieve higher throughput while simultaneously reducing latencies.

**Key Insight:** The combination of reduced latencies (10-15% improvement) and increased bandwidth (41% improvement) creates a multiplier effect, explaining the dramatic 30% gain in server-side java with SLA requirements performance. The system is both faster per-access and capable of handling more concurrent accesses.

### Microarchitectural Efficiency: Top-Down Analysis

Intel's Top-Down Microarchitecture Analysis Method (TMA) provides insight into how CPU cycles are spent across different execution pipeline categories. Comparing the two configurations reveals improved microarchitectural efficiency:

**Top-Down Metric Changes (3-JVM vs 2-JVM):**
- **Front-End Bound:** Reduced by **2.6%**
- **Retiring:** Increased by **~2%**

This shift indicates that the NUMA-optimized configuration allows the CPU to spend more time on productive work (Retiring) rather than stalling in the Front-End (instruction fetch and decode stages). The reduction in Front-End bound cycles suggests:

1. **Better instruction cache utilization** due to improved memory locality
2. **Fewer pipeline bubbles** caused by memory-related stalls propagating to the front-end
3. **More consistent instruction flow** when data is readily available from local NUMA memory

The fact that nearly all of the Front-End reduction flows directly into Retiring operations demonstrates that the NUMA optimization removes bottlenecks without introducing new ones. The CPU cores are doing more useful work per cycle, translating directly to higher application-level throughput.

### CPU Utilization: Unlocking Available Capacity

Beyond per-cycle efficiency, the NUMA optimization also dramatically improves overall CPU utilization:

**CPU Utilization Changes:**
- **2-JVM configuration:** 76% average CPU utilization
- **3-JVM configuration:** 90% average CPU utilization
- **Improvement:** +14 percentage points

This increase reveals that the 2-JVM configuration was leaving significant compute capacity untapped. The 76% utilization indicates cores were frequently idle—not because the workload was light, but because threads were **blocked waiting** for memory operations, likely due to:

- Remote NUMA memory access latencies
- Contention for memory controllers on oversubscribed NUMA nodes
- Cache coherency traffic across NUMA boundaries

The NUMA-optimized 3-JVM configuration removes these barriers, allowing cores to remain active and productive. The 90% utilization demonstrates that the system is now able to keep cores busy doing useful work rather than stalling in wait states.

**Efficiency Multiplier:** The combination of improved per-cycle efficiency (Top-Down metrics) and improved CPU utilization creates a compounding effect:
- Cores spend more time doing useful work per cycle (Retiring +2%)
- More cores are actively engaged (utilization 76% → 90%)
- Result: 30% improvement in server-side java with SLA requirements with better resource utilization

**Combined Impact:** The microarchitectural improvements (more Retiring, less Front-End bound) complement the memory subsystem gains (lower latency, higher bandwidth) to create a holistically optimized system where all components—cache, memory, and execution units—work in harmony.

---

## Conclusion

The **30% improvement in server-side java with SLA requirements** demonstrates that proper NUMA configuration is critical for Java workload performance on modern multi-NUMA-node systems. The 3-JVM configuration's alignment with the system's 3-NUMA-node topology:

- Minimizes remote memory access penalties
- Reduces tail latencies (improving 99th percentile response times)
- Delivers dramatically better performance at strict SLA targets

For production deployments on Intel Xeon 6972P or similar NUMA-aware architectures, **matching the JVM group count to the NUMA topology is essential** for optimal performance.

---

## Appendix: Test Environment Details

### Test Configuration

| Parameter | Value |
|-----------|-------|
| **Benchmark** | MultiJVM Server-Side Java  |
| **Controller Type** | High Injection Rate with SLA Requirement |
| **Connection Pool Size** | 232 |
| **Worker Pool** | min=24, max=81 |
| **Customer Driver Threads** | probe=69, saturate=85 |

### System Tuning

- **CPU Scaling Governor:** performance
- **Energy Performance Bias:** Performance (0)
- **Efficiency Latency Control:** Latency Optimized Mode (LOM)
- **CPU Frequency:** All-core max 3.5 GHz

### Memory Characteristics

- **Peak Bandwidth:** 572.8 GB/s
- **Minimum Latency:** 116.95 ns (local NUMA access)
- **Remote Latency:** 135-163 ns (40% penalty for cross-NUMA access)

---

## Disclaimers

Performance varies by use, configuration, and other factors. Laboratory tests may not reflect actual customer use cases and are based on testing as of the dates reflected in this document. Costs and results may vary.

Intel and Xeon are trademarks of Intel Corporation or its subsidiaries.

Other names and brands may be claimed as the property of others.

---

*Generated from server-side java workload test results dated March 29 and March 31, 2026*
