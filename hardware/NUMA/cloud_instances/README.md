# Introduction

Cloud instance types built on Intel® Xeon® 6 processors (codenamed Granite Rapids) expose the
processor's Sub-NUMA Cluster (SNC3) feature, presenting each socket to the operating system as
three NUMA nodes. Understanding how a given instance size maps onto sockets, NUMA nodes, and
compute dies is a prerequisite for NUMA-aware placement, and the mapping is not the same from one
cloud provider to the next — even for the same processor generation.

This directory documents the NUMA topology of Granite Rapids instance families per cloud provider:
how many NUMA nodes each instance size reports, how wide a node is, which sizes stay within a
single socket, and where a topology is asymmetric.

Actual improvements will vary depending on a given workload's characteristics. It is recommended to
use a profiling solution such as
[VTune Profiler](https://github.com/intel/optimization-zone/tree/main/tools/vtune/README.md) to
more accurately gauge where an application's hotpaths are and which optimizations would have the
greatest effect. Always confirm the topology reported on a running instance with `lscpu` or
`numactl -H` before tuning.

## What's Inside

- [GNR (8i) on AWS](aws_gnr.md): NUMA and compute-die topology of the AWS EC2 8i instance family,
  including per-size socket and NUMA node counts versus the 6i and 7i generations.
- [GNR (C4) on GCP](gcp_gnr.md): NUMA and compute-die topology of the Google Cloud C4 machine
  series on Granite Rapids, including per-shape node counts versus C3.
- [Cross-Cloud Comparison](cross_cloud.md): AWS 8i versus GCP C4-GNR side by side, plus portability
  guidance.

The cross-cloud document covers the key portability concern: a NUMA node is 32 cores on AWS 8i but
24 cores on GCP C4, so thread pools and pinning logic should be derived from the node width reported
at runtime rather than assumed from a socket count.
