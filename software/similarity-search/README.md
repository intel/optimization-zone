# Similarity Search Optimization Guides

This section contains optimization guides for vector similarity search workloads on Intel hardware. These guides help users of popular vector search solutions achieve optimal performance on Intel Xeon processors.

## Overview

Vector similarity search is a core component of modern AI applications including:

- Retrieval-Augmented Generation (RAG)
- Semantic search
- Recommendation systems
- Image and video similarity
- Anomaly detection

Intel provides optimized solutions through the **Scalable Vector Search (SVS)** library, which delivers state-of-the-art performance on Intel hardware.

## Intel Scalable Vector Search (SVS)

[Intel SVS](https://intel.github.io/ScalableVectorSearch/) is a high-performance library for vector similarity search, featuring:

- **Vamana Algorithm**: Graph-based approximate nearest neighbor search
- **Vector Compression**: LVQ and LeanVec for up to 16x memory reduction
- **AVX-512 Optimization**: Native acceleration on Intel Xeon processors
- **Streaming Support**: DynamicVamana for real-time data updates

### Key Performance Benefits

| Metric | Intel SVS Advantage |
|--------|---------------------|
| Throughput | Up to 13.5x vs. alternatives at billion scale |
| Memory | Up to 16x reduction with compression |
| Latency | Optimized for both batch and single queries |

## Available Guides

| Software | Description | Guide |
|----------|-------------|-------|
| **Redis** | Redis Query Engine with SVS-VAMANA | [Redis Guide](redis/README.md) |
| **FAISS** | Facebook AI Similarity Search with SVS indexes | Coming soon |

## Common Optimization Topics

### Hardware Recommendations

For optimal vector search performance on Intel:

- **CPU**: 4th Gen Intel Xeon Scalable (Sapphire Rapids) or newer
- **Memory**: DDR5 for higher bandwidth
- **Storage**: NVMe SSD for large datasets

### BIOS Settings

| Setting | Recommendation | Impact |
|---------|----------------|--------|
| Hyperthreading | Enabled | Up to 20% throughput |
| Sub-NUMA Clustering | SNC2/SNC4 | Up to 15% with pinning |
| Hardware Prefetcher | Enabled | 5-10% improvement |

### Vector Compression Selection

```
Dimensions < 512  →  LVQ4x4 or LVQ4x8
Dimensions ≥ 512  →  LeanVec4x8 or LeanVec8x8
Maximum savings   →  LVQ4 (may reduce recall)
```

## References

- [Intel Scalable Vector Search](https://intel.github.io/ScalableVectorSearch/)
- [SVS GitHub Repository](https://github.com/intel/ScalableVectorSearch)
- [LVQ Paper (VLDB 2023)](https://www.vldb.org/pvldb/vol16/p2769-aguerrebere.pdf)
- [LeanVec Paper (TMLR 2024)](https://openreview.net/forum?id=Y5Mvyusf1u)

## Contributing

We welcome contributions! If you have optimization tips for additional vector search solutions, please open a pull request.
