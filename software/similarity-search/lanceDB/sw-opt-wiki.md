
# Lance IVF_PQ Exact Partition Assignment Optimization Guide

This guide describes how Lance and LanceDB accelerate IVF_PQ index construction on Intel Xeon 6 processors by using Intel Advanced Matrix Extensions with FP16 (`AMX-FP16`) for exact partition assignment.

Starting with Lance v11.0.0, supported workloads automatically replace the default approximate HNSW search over IVF centroids with an exact, batched vector-to-centroid calculation. No application code or configuration changes are required.

## Table of Contents

- [Overview](#overview)
- [Key Benefits](#key-benefits)
- [Requirements and Configuration](#requirements-and-configuration)
- [How It Works](#how-it-works)
- [Performance Tuning](#performance-tuning)
- [Benchmarks](#benchmarks)
- [Verification and Reproduction](#verification-and-reproduction)
- [FAQ](#faq)
- [References](#references)

## Overview

When building an IVF index, Lance must assign every vector to its nearest partition centroid. The original path builds a small HNSW graph over the centroids and searches that graph for each vector. Because the search is approximate, some vectors can be assigned to a non-nearest partition.

The optimized path introduced by [lance-format/lance#8540](https://github.com/lance-format/lance/pull/8540) calculates the distance from every vector to every centroid. It batches 32 vectors and uses an AMX-FP16 GEMM kernel to make exact assignment practical at production scale.

```text
Default:    1 vector  -> HNSW search over K centroids -> approximate nearest partition
Optimized: 32 vectors x K centroids -> AMX-FP16 GEMM -> exact nearest partition
```

### Key Benefits

- **Higher search throughput:** 1.4-2.1x higher QPS at the same recall@10 in the tested 100M-vector workload.
- **Lower search latency:** 1.4-2.0x lower p50 latency at recall@10 targets from 0.90 to 0.95.
- **Comparable or faster index construction:** 1.055-1.158x end-to-end build speedup over the default `ef=15` assignment path.
- **Better partition quality:** Exact assignment reduces the number of partitions that queries must probe to reach the same recall.
- **Transparent enablement:** The optimized path is selected automatically when the data, binary, operating system, and processor meet the requirements.

## Requirements and Configuration

### Supported Software

| Component          | Requirement                                                                   |
| ------------------ | ----------------------------------------------------------------------------- |
| Lance              | v11.0.0 or later                                                              |
| LanceDB Python SDK | v0.38.0 or later, bundling Lance 11.0.0                                       |
| Operating system   | Linux x86_64                                                                  |
| Python wheel       | `manylinux_2_28` wheel includes the AMX kernel; `manylinux_2_17` does not |

### Supported Hardware

The optimized path requires an Intel Xeon 6 P-core processor with AMX-FP16 support, such as Granite Rapids. It was tested on an Intel Xeon 6986P-C.

Intel Xeon processors from generations 4 and 5 support AMX-BF16 and AMX-INT8, but not AMX-FP16, so Lance keeps the default path on those processors.

### Workload Requirements

The exact AMX path is selected only when all of the following conditions are met:

| Requirement         | Value                                                   |
| ------------------- | ------------------------------------------------------- |
| Vector type         | `fp16`                                                |
| Distance metric     | Dot product                                             |
| Vector dimension    | At least 32                                             |
| Number of centroids | At least 32                                             |
| Processor features  | `amx-tile` and `amx-fp16`                           |
| AMX permission      | Linux grants `XTILEDATA` through `arch_prctl`       |
| Disable switch      | `LANCE_DISABLE_AMX` is not `1`, `true`, or `on` |

If any condition is not met, Lance uses the default path and behaves as before.

### Build Requirements

At build time, Lance tries the following compilers in order:

1. The compiler specified by `LANCE_AMX_FP16_CC`, if set.
2. The default `cc` compiler.
3. `clang-18`, `clang-17`, and `clang-16`.

The kernel requires Clang 16 or later, or GCC 13 or later. No Cargo feature is required. If no compatible compiler is found, Lance skips the AMX-FP16 kernel and emits a warning.

### A/B Testing and Rollback

Disable the optimized path for index construction with:

```bash
export LANCE_DISABLE_AMX=1
```

The variable is read once per process. Build the same dataset once with the default setting and once with `LANCE_DISABLE_AMX=1`, then compare search latency and throughput at equal recall.

## How It Works

### Default Approximate Assignment

The default path creates an HNSW graph over the IVF centroids and searches the graph independently for every input vector. Its graph parameters are fixed at `ef=15`, `ef_construction=15`, and 12 edges per node.

Because graph traversal can stop at a local candidate, the selected centroid is not always the true nearest centroid. A vector assigned to the wrong partition can require a larger `nprobes` value during search, increasing the amount of data scanned per query.

### Exact Assignment with AMX-FP16

PR #8540 converts partition assignment into a batched matrix multiplication:

```text
N input vectors x K centroids -> vector-to-centroid dot products -> exact nearest centroid
```

The implementation uses:

- AMX-FP16 tile matrix multiplication with FP16 inputs and FP32 accumulation.
- Blocks of 32 vectors, allowing the centroid table to be reused across the batch.
- The same AMX kernel for k-means assignment during IVF training.

An AMX tile instruction calculates a 16 x 16 block of dot products. Processing one vector at a time uses only one of the 16 result columns, while a batched matrix multiplication can use the full tile.

### Interaction with Other AMX Users

The kernel loads its tile configuration on entry and releases it on exit. This allows the same process to use other AMX-enabled libraries, such as oneDNN through PyTorch or ONNX Runtime, without leaving a conflicting tile configuration active.

### Search-Time Behavior

At query time, Lance compares the query with every centroid to select the nearest `nprobes` partitions. The optimized implementation can process centroids with AMX, but a single query uses only a small fraction of each tile. Most of the measured search improvement therefore comes from better partition assignment during index construction rather than from query-kernel acceleration.

## Performance Tuning

### Choose `nlist` Based on Build and Search Priorities

Exact assignment performs work proportional to `N x K`, where `N` is the number of vectors and `K` is `nlist`. The default graph path scales approximately with `N x log(K)`. As a result, the build-time advantage of exact assignment becomes smaller as `nlist` increases.

The tested values were:

```text
nlist = 4000, 10000, 15000
```

### Compare at Equal Recall

Do not compare two indexes using a single identical `nprobes` value. Exact and approximate assignment produce different partition layouts. Instead:

1. Sweep `nprobes` and `refine_factor` for both indexes.
2. Select the lowest-latency operating point that reaches the target recall.
3. Compare latency and throughput at the same recall target.

The benchmark used:

```text
nprobes       = {5, 8, 12, 16, 20, 25, 32, 40, 50, 65, 80, 100}
refine_factor = {10, 15, 20, 25, 30, 40, 50}
```

This creates 84 operating points per index.

## Benchmarks

### Test Environment

| Item             | Configuration                                |
| ---------------- | -------------------------------------------- |
| Machine          | Volcano Engine cloud VM                      |
| Processor        | Intel Xeon 6986P-C, Granite Rapids           |
| CPU allocation   | 32 cores / 64 threads                        |
| Memory           | 247 GB                                       |
| Storage          | Local SSD                                    |
| Operating system | Ubuntu 24.04, Linux kernel 6.8               |
| Dataset          | LAION-100M, 100,000,000 vectors              |
| Vector shape     | 768-dimensional FP16                         |
| Index            | IVF_PQ, 192 sub-vectors x 8 bits             |
| Metric           | Dot product                                  |
| Build threads    | `LANCE_CPU_THREADS=64`                     |
| Queries          | 1,000 queries with exact top-10 ground truth |
| Query load       | 64 concurrent clients                        |
| Repeats          | Three builds per arm per `nlist`           |

### Index Build Time

Three-run mean, in seconds:

| `nlist` | Exact + AMX | Default (`ef=15`) | Speedup |
| --------: | ----------: | ------------------: | ------: |
|     4,000 |       1,186 |               1,373 |  1.158x |
|    10,000 |       1,640 |               1,759 |  1.072x |
|    15,000 |       2,042 |               2,155 |  1.055x |

The main difference appears in the shuffle stage, where partition assignment runs:

| `nlist` | Exact + AMX |   Default |
| --------: | ----------: | --------: |
|     4,000 |     858.0 s | 1,042.1 s |
|    10,000 |     919.0 s | 1,070.2 s |
|    15,000 |   1,000.8 s | 1,110.0 s |

### Search at Equal Recall@10

Three-run means with 64 concurrent clients:

| Recall target | Metric             | `nlist=4000` | `nlist=10000` | `nlist=15000` |
| ------------: | ------------------ | -------------: | --------------: | --------------: |
|          0.90 | p50, exact + AMX   |         134 ms |           98 ms |           92 ms |
|          0.90 | p50, default       |         182 ms |          158 ms |          140 ms |
|          0.90 | QPS, exact/default |      431 / 317 |       611 / 354 |       612 / 408 |
|          0.90 | p99, exact/default |   342 / 449 ms |    223 / 462 ms |    278 / 376 ms |
|          0.95 | p50, exact + AMX   |         322 ms |          234 ms |          227 ms |
|          0.95 | p50, default       |         547 ms |          474 ms |         392 ms* |
|          0.95 | QPS, exact/default |      188 / 114 |       259 / 126 |      259 / 156* |
|          0.96 | p50, exact + AMX   |         570 ms |          355 ms |          370 ms |
|          0.96 | p50, default       |         820 ms |     Not reached |     Not reached |

\* The default path reached 0.95 recall for `nlist=15000` in only two of three runs.

“Not reached” means that no point in the tested grid, up to `nprobes=100` and `refine_factor=50`, met the target. Exact + AMX reached 0.96 in all three runs for every tested `nlist`.

### Why AMX Is Required

A separate test compared exact assignment using AMX-FP16 with exact assignment using AVX-512 FP16 at `nlist=10000`.

| Scope                       | Exact + AMX | Exact + AVX-512 | AMX speedup |
| --------------------------- | ----------: | --------------: | ----------: |
| Assignment calculation      |           - |               - |  15.8-19.9x |
| Shuffle stage, two-run mean |    867.65 s |      2,563.05 s |       2.95x |
| End-to-end index build      |   1,552.9 s |       3,292.4 s |       2.12x |

Without AMX, exact assignment would roughly double end-to-end build time. This is why Lance retains approximate assignment on processors without AMX-FP16.

## Verification and Reproduction

### Check Processor Support

AMX-FP16 is indicated by CPUID leaf 7, sub-leaf 1, EAX bit 21. Older Linux kernels, including some 5.15 builds, may not display `amx_fp16` in `lscpu` or `/proc/cpuinfo` even when the processor supports it. Lance checks CPUID directly.

### Check Whether the Kernel Is Present

```bash
llvm-objdump -d lance.abi3.so | grep -c tdpfp16ps
```

A non-zero result indicates that the AMX-FP16 kernel is present. GNU `objdump` 2.38 does not decode `TDPFP16PS`; with that version, count `ldtilecfg` instructions instead.

### Confirm Which Route Was Used

Enable debug logging during index construction:

```bash
RUST_LOG=lance_index=debug <your-index-build-command> 2>&1 | grep num_centroids
```

Expected routes:

```text
AMX path:     route=flat+amx
Default path: route=hnsw
```

### Run a Controlled A/B Test

1. Use the same binary, dataset, index parameters, and CPU allocation.
2. Build the optimized index with the default environment.
3. Build the baseline index with `LANCE_DISABLE_AMX=1`.
4. Run the same `nprobes x refine_factor` grid against both indexes.
5. Compare p50, p99, and QPS at equal recall.

Do not use `LANCE_USE_HNSW_SPEEDUP_INDEXING=enabled` to emulate the default path.

## FAQ

### Do I need to change application code?

No. Lance selects the AMX path automatically when all runtime and workload requirements are satisfied.

### Does this optimization accelerate every Lance vector index?

No. It applies to IVF training and assignment for FP16 vectors using dot-product distance, with dimensions and centroid counts of at least 32, on supported Linux x86_64 systems.

### Why can exact assignment improve query performance?

A vector stored in its true nearest partition is more likely to be found with fewer partition probes. This can reduce data scanning and improve latency and QPS at the same recall.

### Why not use exact assignment on AVX-512 processors?

In the measured `nlist=10000` test, the AMX assignment kernel was 15.8-19.9x faster than the AVX-512 FP16 kernel, and the AVX-512 exact path increased end-to-end build time by about 2.12x relative to AMX.

### Does the AMX query kernel explain the search speedup?

Only to a limited extent. A single query does not fully utilize an AMX tile. The primary benefit comes from the higher-quality index created by exact partition assignment.

### How can I disable the optimization?

Set `LANCE_DISABLE_AMX=1` before starting the process and building the index.

## References

- [Lance AMX acceleration documentation](https://github.com/lance-format/lance/blob/main/docs/src/guide/performance.md#amx-acceleration)
- [Rendered Lance performance guide](https://lance.org/guide/performance/#amx-acceleration)
- [PR #8540: Route FP16 IVF partition assignment through an AMX-FP16 GEMM](https://github.com/lance-format/lance/pull/8540)
- [Lance repository](https://github.com/lance-format/lance)
- [LanceDB repository](https://github.com/lancedb/lancedb)
