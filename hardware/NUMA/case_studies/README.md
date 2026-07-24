# Introduction

This directory collects case studies of performance opportunities for running workloads in NUMA environments. The goal is to help you understand why hardware topology matters, identify configuration mismatches that leave performance on the table, and apply proven, hardware-aware patterns to your deployments. Aligning workloads with the underlying NUMA topology can deliver significant performance gains. 

## What's Inside

- **Case Studies**: Real-world, data-driven examples demonstrating the performance impact of NUMA-aware configuration.
  - [Java Server-Side Workload Performance](java_server_side_workload.md): Demonstrates how aligning JVM group count with a 3-NUMA-node Intel Xeon 6972P topology delivered up to a 30% improvement in server-side Java performance under SLA requirements.
