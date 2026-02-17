# Tools

This directory contains documentation for performance monitoring and profiling tools used in optimization work.

## Tool Reference

### Intel® gProfiler

System-wide profiler combining multiple sampling profilers across native programs, Java, Python runtimes, and kernel routines. Includes optional gProfiler Performance Studio for cluster-wide aggregation.

📊 **Best for:** Production monitoring, multi-language environments, cluster analysis, low-overhead continuous profiling

### Intel® Performance Counter Monitor (PCM)

API and toolset for monitoring performance and energy metrics of Intel processors including memory bandwidth, cache behavior, PCIe bandwidth, and energy states.

📊 **Best for:** Hardware-level metrics, memory analysis, power consumption, real-time dashboards

### Intel® PerfSpect

**Easy to install and use.** Comprehensive performance engineering toolkit for system health reporting, configuration analysis, flamegraph generation, telemetry collection, and tuning parameter modification. Provides quick insights across multiple dimensions without the learning curve or deep complexity of other tools.

📊 **Best for:** System assessment, configuration validation, quick troubleshooting, health checks, getting started with performance analysis

⚡ **Key advantage:** Accessibility and speed of use, though with less depth than specialized tools

### Intel® VTune™ Profiler

In-depth application and system profiler with microarchitecture analysis, parallelism examination, multi-node analysis, and GPU/accelerator optimization capabilities.

📊 **Best for:** Deep application optimization, microarchitecture analysis, GPU optimization, HPC workloads, complex debugging

## Choosing the Right Tool

Start with your primary goal or problem, then follow the decision path to find the best tool(s).

### START: What is your primary goal?

#### **"I need a quick system assessment" (Easy start)**

→ **Use: PerfSpect** ⭐ Easiest to install and use

- Validating system configuration before performance testing
- Getting a health check and performance baseline
- Quick automated system tuning recommendations
- Pre-flight checks before running benchmarks
- Understanding current system telemetry and state
- **Start here if you're new to performance analysis** – no steep learning curve

---

#### **"My application/workload is slow - I need to find where time is spent"**

**→ Do you need to analyze multiple languages or continuous production monitoring?**

- **YES (multi-language or production monitoring)** → **Use: gProfiler**
  - Multi-language environments (native, Java, Python) requiring unified profiling
  - Finding performance bottlenecks in microservices architectures
  - Analyzing resource utilization across production systems with low overhead
  - Identifying hot functions and stack traces without code instrumentation
  - Compare performance patterns across multiple machines over time

- **NO (single application, development/testing)** → **Use: VTune**
  - Optimizing algorithm efficiency by identifying instruction-level bottlenecks
  - Deep investigation with detailed performance metrics
  - Identifying specific microarchitecture bottlenecks (stalls, cache misses)
  - Complex performance investigations requiring advanced visualization

---

#### **"I'm analyzing/optimizing distributed systems at scale"**

**→ Do you need to aggregate data from multiple machines?**

- **YES** → **Use: gProfiler + gProfiler Performance Studio**
  - Cluster-wide performance analysis
  - Comparing performance patterns across multiple machines or time periods
  - Holistic view of what is happening on your entire cluster

- **NO (single machine analysis)** → **Use: gProfiler or VTune** (based on depth needed)

---

#### **"I'm experiencing memory or bandwidth issues"**

**→ Are you investigating processor-level metrics?**

- **YES** → **Use: PCM**
  - Analyzing memory bandwidth utilization and DRAM behavior
  - Identifying memory bandwidth bottlenecks in data-intensive workloads
  - Detecting inefficient cache usage patterns
  - Monitoring cache miss latencies and PCIe bandwidth
  - Detailed microarchitecture analysis (cache efficiency, memory stalls)
  - Real-time system performance dashboards

- **NO (need application-level insights)** → **Use: VTune**
  - Identify which parts of code are causing memory issues
  - Detailed cache miss analysis at the instruction level

---

#### **"My parallel/multi-threaded application doesn't scale"**

→ **Use: VTune**

- Analyzing multi-threaded parallelism and scalability issues
- Debugging poor thread scaling in parallel applications
- Examining how effectively threads are utilized

---

#### **"I need to optimize GPU or accelerators"**

→ **Use: VTune**

- GPU/accelerator optimization and analysis
- Analyzing GPU utilization and accelerator integration
- Multi-node cluster performance analysis for HPC applications
- AI/ML workload optimization and profiling

---

#### **"I need to monitor power consumption or energy efficiency"**

→ **Use: PCM**

- Tracking energy consumption and CPU sleep states
- Power consumption analysis for cloud deployments
- Integration with monitoring systems like Prometheus for continuous tracking

---

#### **"I need to visualize call stacks and hot code paths"**

**→ Do you want quick, shallow analysis or deep investigation?**

- **Quick and easy** → **Use: PerfSpect**
  - Generating flamegraphs for visualization of call stacks
  - Quick visualization of application hot paths
  - Simple setup and immediate insights

- **Production-scale or deep analysis** → **Use: gProfiler**
  - System-wide flamegraphs across all processes
  - Continuous profiling with minimal overhead
  - More sophisticated analysis capabilities

---

## More Information

- [gProfiler](gprofiler/README.md)
- [PCM](pcm/README.md)
- [PerfSpect](perfspect/README.md)
- [VTune](vtune/README.md)
