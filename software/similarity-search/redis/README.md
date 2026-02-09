# Redis Vector Search Optimization Guide

This guide describes best practices for optimizing vector similarity search performance in Redis on Intel Xeon processors. Redis 8.2+ includes SVS-VAMANA, a graph-based vector index algorithm from Intel's Scalable Vector Search (SVS) library, optimized for Intel hardware.

## Table of Contents

- [Overview](#overview)
- [Hardware Recommendations](#hardware-recommendations)
- [BIOS Configuration](#bios-configuration)
- [Choosing the Right Index Type](#choosing-the-right-index-type)
- [SVS-VAMANA Configuration](#svs-vamana-configuration)
- [Vector Compression](#vector-compression)
- [Performance Tuning](#performance-tuning)
- [Benchmarks](#benchmarks)
- [FAQ](#faq)
- [References](#references)

## Overview

Redis Query Engine supports three vector index types:

| Index Type | Use Case | Accuracy | Performance |
|------------|----------|----------|-------------|
| **FLAT** | Small datasets (<1M vectors) | Exact | Brute-force |
| **HNSW** | Large datasets, general use | Approximate | Good |
| **SVS-VAMANA** | Large datasets on Intel hardware | Approximate | Best on Intel |

**Why SVS-VAMANA on Intel?**

- Optimized for AVX-512 instruction set on Intel Xeon processors
- Advanced compression (LVQ, LeanVec) reduces memory by up to 16x
- Higher throughput with lower latency compared to HNSW

## Hardware Recommendations

### Recommended Intel Xeon Configurations

| Workload Size | CPU | Memory | Storage |
|---------------|-----|--------|---------|
| Small (<1M vectors) | 4th Gen Xeon, 16 cores | 64 GB DDR5 | NVMe SSD |
| Medium (1-10M vectors) | 4th Gen Xeon, 32 cores | 128 GB DDR5 | NVMe SSD |
| Large (10-100M vectors) | 4th/5th Gen Xeon, 64 cores | 256 GB DDR5 | NVMe SSD |
| X-Large (>100M vectors) | 5th Gen Xeon, 128+ cores | 512+ GB DDR5 | NVMe RAID |

> **PerfTip:** 4th Gen Intel Xeon Scalable (Sapphire Rapids) and newer provide optimal AVX-512 performance for vector operations.

### Key Hardware Features

- **AVX-512**: Required for optimal SVS performance
- **AMX**: Additional acceleration on 4th/5th Gen Xeon
- **DDR5 Memory**: Higher bandwidth improves vector search throughput
- **Large L3 Cache**: Helps with graph traversal operations

## BIOS Configuration

| Parameter | Recommended Setting | Description | PerfTip |
|-----------|---------------------|-------------|---------|
| Hyperthreading (SMT) | Enabled | Two threads per core | Up to 20% |
| Sub-NUMA Clustering (SNC) | SNC2 or SNC4 | Better memory locality | Up to 15% |
| Hardware Prefetcher | Enabled | Improves cache utilization | 5-10% |
| Intel Turbo Boost | Enabled | Higher clock speeds | 10-15% |
| Power Profile | Performance | Maximum CPU frequency | Varies |

## Choosing the Right Index Type

```
                    ┌─────────────────────────────────────┐
                    │     Do you need exact results?      │
                    └─────────────────────────────────────┘
                                    │
                    ┌───────────────┴───────────────┐
                    ▼                               ▼
                   Yes                              No
                    │                               │
                    ▼                               ▼
               Use FLAT                   ┌────────────────────┐
                                          │ Running on Intel?  │
                                          └────────────────────┘
                                                    │
                                    ┌───────────────┴───────────────┐
                                    ▼                               ▼
                                   Yes                              No
                                    │                               │
                                    ▼                               ▼
                            Use SVS-VAMANA                      Use HNSW
```

## SVS-VAMANA Configuration

### Creating an SVS-VAMANA Index

```bash
FT.CREATE my_index
  ON HASH
  PREFIX 1 doc:
  SCHEMA embedding VECTOR SVS-VAMANA 12
    TYPE FLOAT32
    DIM 768
    DISTANCE_METRIC COSINE
    GRAPH_MAX_DEGREE 64
    CONSTRUCTION_WINDOW_SIZE 200
    COMPRESSION LVQ4x8
```

### Index Parameters

| Parameter | Description | Default | Tuning Guidance |
|-----------|-------------|---------|-----------------|
| TYPE | Vector data type | - | FLOAT32 for accuracy, FLOAT16 for memory |
| DIM | Vector dimensions | - | Must match your embeddings |
| DISTANCE_METRIC | L2, IP, or COSINE | - | COSINE for normalized embeddings |
| GRAPH_MAX_DEGREE | Max edges per node | 32 | Higher = better recall, more memory |
| CONSTRUCTION_WINDOW_SIZE | Build search window | 200 | Higher = better graph quality |
| SEARCH_WINDOW_SIZE | Query search window | 10 | Higher = better recall, slower |
| COMPRESSION | LVQ/LeanVec type | none | See compression section |

> **PerfTip:** Setting `GRAPH_MAX_DEGREE` to 64 instead of default 32 can improve recall by 2-5% with ~2x memory overhead for the graph structure.

## Vector Compression

Intel SVS provides advanced compression techniques that reduce memory usage while maintaining search quality.

### Compression Options

| Compression | Bits/Dim | Memory Reduction | Best For |
|-------------|----------|------------------|----------|
| None | 32 (FLOAT32) | 1x (baseline) | Maximum accuracy |
| LVQ8 | 8 | 4x | Fast ingestion |
| LVQ4x4 | 4+4 | 8x | Balanced |
| LVQ4x8 | 4+8 | ~6x | High recall with compression |
| LeanVec4x8 | Reduced dim + 4+8 | 8-16x | High-dimensional vectors (768+) |
| LeanVec8x8 | Reduced dim + 8+8 | 4-8x | Best recall with LeanVec |

### Choosing Compression

```
Vector Dimensions < 512?
  └─► Use LVQ4x4 or LVQ4x8

Vector Dimensions >= 512?
  └─► Use LeanVec4x8 or LeanVec8x8

Need maximum memory savings?
  └─► Use LVQ4 (single-level)

Need highest recall with compression?
  └─► Use LVQ4x8 or LeanVec8x8
```

> **PerfTip:** LeanVec4x8 with 768-dimensional vectors (common for text embeddings) can reduce memory by 10x while maintaining 95%+ recall.

### Two-Level Compression

LVQ and LeanVec support two-level compression:

1. **Level 1**: Fast candidate retrieval using compressed vectors
2. **Level 2**: Re-ranking using residual encoding for accuracy

Example: `LVQ4x8` uses 4 bits for Level 1 and 8 bits for Level 2.

### Compression Training

Compression parameters are learned from data. Use `TRAINING_THRESHOLD` to control the sample size:

```bash
FT.CREATE my_index
  ON HASH
  PREFIX 1 doc:
  SCHEMA embedding VECTOR SVS-VAMANA 14
    TYPE FLOAT32
    DIM 768
    DISTANCE_METRIC COSINE
    COMPRESSION LeanVec4x8
    TRAINING_THRESHOLD 20000
    REDUCE 192
```

> **Note:** If recall is low, increase `TRAINING_THRESHOLD`. The default is 10 * 1024 = 10,240 vectors.

## Performance Tuning

### Runtime Query Parameters

```bash
FT.SEARCH my_index
  "*=>[KNN 10 @embedding $BLOB SEARCH_WINDOW_SIZE $SW]"
  PARAMS 4 BLOB "\x12\xa9..." SW 50
  DIALECT 2
```

| Parameter | Effect | Trade-off |
|-----------|--------|-----------|
| SEARCH_WINDOW_SIZE | Larger = higher recall | Higher latency |
| EPSILON | Larger = wider range search | Higher latency |
| SEARCH_BUFFER_CAPACITY | More candidates for re-ranking | Higher latency |

### OS-Level Tuning

```bash
# Enable huge pages for better memory performance
echo 'vm.nr_hugepages = 1024' >> /etc/sysctl.conf
sysctl -p

# Set CPU governor to performance
cpupower frequency-set -g performance

# Disable transparent huge pages (if not using explicitly)
echo never > /sys/kernel/mm/transparent_hugepage/enabled
```

> **PerfTip:** Using 2MB huge pages can improve vector search throughput by 5-10%.

### Redis Configuration

```
# redis.conf optimizations for vector workloads

# Increase memory limit for large vector datasets
maxmemory 200gb

# Use multiple I/O threads for better throughput
io-threads 4
io-threads-do-reads yes

# Disable persistence for pure search workloads (if acceptable)
save ""
appendonly no
```

## Benchmarks

### Redis Query Engine Performance

Based on [Redis benchmarks](https://redis.io/blog/benchmarking-results-for-vector-databases/), Redis significantly outperforms competitors:

| Comparison | Redis Advantage |
|------------|-----------------|
| vs. Qdrant | Up to 3.4x higher QPS |
| vs. Milvus | Up to 3.3x higher QPS |
| vs. Weaviate | Up to 1.7x higher QPS |
| vs. PostgreSQL (pgvector) | Up to 9.5x higher QPS |
| vs. MongoDB Atlas | Up to 11x higher QPS |
| vs. OpenSearch | Up to 53x higher QPS |

### SVS Performance on Intel

Intel SVS benchmarks show significant improvements over alternatives:

| Dataset | SVS QPS | vs. HNSW |
|---------|---------|----------|
| deep-96-1B | 95,931 | 7.0x faster |
| rqa-768-10M | 23,296 | 8.1x faster |
| deep-96-100M | 140,505 | 4.5x faster |

*Source: [Intel SVS Benchmarks](https://intel.github.io/ScalableVectorSearch/benchs/static/latest.html)*

### Memory Savings with Compression

| Configuration | Memory per 1M Vectors (768-dim) | Recall@10 |
|---------------|--------------------------------|-----------|
| FLOAT32 (no compression) | ~3 GB | 100% |
| LVQ4x8 | ~500 MB | ~98% |
| LeanVec4x8 (reduce=192) | ~300 MB | ~95% |

## FAQ

### Q: When should I use SVS-VAMANA vs HNSW?

**A:** Use SVS-VAMANA when:
- Running on Intel Xeon processors (4th Gen+)
- Memory efficiency is important
- You need maximum throughput on Intel hardware

Use HNSW when:
- Running on non-Intel hardware
- You need a well-established, widely-tested algorithm
- Compatibility with Redis Open Source without Intel optimizations

### Q: Are LVQ and LeanVec available in Redis Open Source?

**A:** The basic SVS-VAMANA algorithm with 8-bit scalar quantization is available in Redis Open Source. However, Intel's proprietary LVQ and LeanVec optimizations require:
- Intel hardware
- Redis Software (commercial) or RSALv2 license
- Building with `BUILD_INTEL_SVS_OPT=yes`

### Q: How do I migrate from HNSW to SVS-VAMANA?

**A:** Create a new index with SVS-VAMANA and reindex your data:

```bash
# Create new SVS-VAMANA index
FT.CREATE new_index ON HASH PREFIX 1 doc: SCHEMA embedding VECTOR SVS-VAMANA 8 TYPE FLOAT32 DIM 768 DISTANCE_METRIC COSINE COMPRESSION LVQ4x8

# Reindex data (use your application or Redis CLI)
# The data format is identical, only the index type changes
```

### Q: What if recall is too low with compression?

**A:** Try these steps in order:
1. Increase `TRAINING_THRESHOLD` (e.g., 50000)
2. Switch to higher-bit compression (LVQ4x8 → LVQ8, or LeanVec4x8 → LeanVec8x8)
3. Increase `GRAPH_MAX_DEGREE` (e.g., 64 or 128)
4. Increase `SEARCH_WINDOW_SIZE` at query time

## References

- [Redis Vector Search Documentation](https://redis.io/docs/latest/develop/ai/search-and-query/vectors/)
- [SVS-VAMANA Index Reference](https://redis.io/docs/latest/develop/ai/search-and-query/vectors/#svs-vamana-index)
- [Vector Compression Guide](https://redis.io/docs/latest/develop/ai/search-and-query/vectors/svs-compression/)
- [Intel Scalable Vector Search](https://intel.github.io/ScalableVectorSearch/)
- [Redis Benchmarking Results](https://redis.io/blog/benchmarking-results-for-vector-databases/)
