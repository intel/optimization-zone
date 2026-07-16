# Introduction

Non-Uniform Memory Access (NUMA) is a memory architecture used in modern multi-socket and multi-die server platforms, where memory access latency and bandwidth depend on the location of the memory relative to the executing core. On Intel® Xeon® platforms, aligning workloads with the underlying NUMA topology can deliver significant performance gains—often without code changes, hardware upgrades, or additional investment.

This directory collects best practices, case studies, and performance opportunities for running workloads in NUMA environments. The goal is to help you understand why hardware topology matters, identify configuration mismatches that leave performance on the table, and apply proven, hardware-aware patterns to your deployments.

Actual improvements will vary depending on a given workload's characteristics. It is recommended to use a profiling solution such as [VTune Profiler](../../tools/vtune/README.md) to more accurately gauge where an application's hotpaths are and which optimizations would have the greatest effect.

## What's Inside

- **Best Practices**: General, workload-agnostic guidance for configuring and tuning applications to align with NUMA topology.
- **Performance Opportunities**: Common NUMA-related bottlenecks and the optimization patterns that address them.
- **Case Studies**: Real-world, data-driven examples demonstrating the performance impact of NUMA-aware configuration.
  - [Java Server-Side Workload Performance](case_studies/java_server-side_workload.md): Demonstrates how aligning JVM group count with a 3-NUMA-node Intel Xeon 6972P topology delivered up to a 30% improvement in server-side Java performance under SLA requirements.
