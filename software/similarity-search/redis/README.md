# Redis Vector Search Optimization Guide

This guide describes best practices for optimizing vector similarity search performance in Redis on Intel Xeon processors. Redis 8.2+ includes SVS-VAMANA, a graph-based vector index algorithm from Intel's Scalable Vector Search (SVS) library.

## Table of Contents

- [Overview](#overview)
- [SVS-VAMANA Configuration](#svs-vamana-configuration)
- [Vector Compression](#vector-compression)
- [Performance Tuning](#performance-tuning)
- [Benchmarks](#benchmarks)
- [FAQ](#faq)
- [References](#references)

## Overview

Redis Query Engine supports three vector index types: FLAT, HNSW, and SVS-VAMANA. SVS-VAMANA combines the Vamana graph-based search algorithm with Intel's compression technologies (LVQ and LeanVec), delivering optimal performance on servers with AVX-512 support.

**Key Benefits of SVS-VAMANA:**

- **Memory Efficiency**: 26–37% total memory savings compared to HNSW, with 51–74% reduction in index memory
- **Higher Throughput**: Up to 144% higher QPS compared to HNSW on high-dimensional datasets
- **Lower Latency**: Up to 60% reduction in p50/p95 latencies under load
- **Maintained Accuracy**: Matches HNSW precision levels while delivering performance improvements

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
| TYPE | Vector data type (FLOAT16, FLOAT32) | - | FLOAT32 for accuracy, FLOAT16 for memory |
| DIM | Vector dimensions | - | Must match your embeddings |
| DISTANCE_METRIC | L2, IP, or COSINE | - | COSINE for normalized embeddings |
| GRAPH_MAX_DEGREE | Max edges per node | 32 | Higher = better recall, more memory |
| CONSTRUCTION_WINDOW_SIZE | Build search window | 200 | Higher = better graph quality |
| SEARCH_WINDOW_SIZE | Query search window | 10 | Higher = better recall, slower |
| COMPRESSION | LVQ/LeanVec type | none | See compression section |
| TRAINING_THRESHOLD | Vectors for learning compression | 10240 | Increase if recall is low |
| REDUCE | Target dimension for LeanVec | DIM/2 | Lower = faster search, may reduce recall |

## Vector Compression

Intel SVS provides advanced compression techniques that reduce memory usage while maintaining search quality.

### Compression Options

| Compression | Bits/Dim | Memory Reduction | Best For |
|-------------|----------|------------------|----------|
| None | 32 (FLOAT32) | 1x (baseline) | Maximum accuracy |
| LVQ8 | 8 | ~4x | Fast ingestion, good balance |
| LVQ4x4 | 4+4 | ~4x | Fast search, dimensions < 768 |
| LVQ4x8 | 4+8 | ~3x | High recall with compression |
| LeanVec4x8 | Reduced + 4+8 | ~3x | High-dimensional vectors (768+) |
| LeanVec8x8 | Reduced + 8+8 | ~2.5x | Best recall with LeanVec |

### Choosing Compression by Use Case

| Embedding Category | Example Embeddings | Compression Strategy |
|--------------------|-------------------|---------------------|
| Text Embeddings | Cohere embed-v3 (1024), OpenAI ada-002 (1536) | LeanVec4x8 |
| Image Embeddings | ResNet-152 (2048), ViT (768+) | LeanVec4x8 |
| Multimodal | CLIP ViT-B/32 (512) | LVQ8 |
| Lower Dimensional | Custom embeddings (<768) | LVQ4x4 or LVQ4x8 |

### Example with LeanVec Compression

```bash
FT.CREATE my_index
  ON HASH
  PREFIX 1 doc:
  SCHEMA embedding VECTOR SVS-VAMANA 14
    TYPE FLOAT32
    DIM 1536
    DISTANCE_METRIC COSINE
    COMPRESSION LeanVec4x8
    REDUCE 384
    TRAINING_THRESHOLD 20000
```

## Performance Tuning

### Runtime Query Parameters

Adjust search parameters at query time for precision/performance trade-offs:

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

### Redis Configuration

```
# redis.conf optimizations for vector workloads

# Use multiple I/O threads for better throughput
io-threads 4
io-threads-do-reads yes
```

## Benchmarks

Based on [Redis and Intel benchmarking](https://redis.io/blog/tech-dive-comprehensive-compression-leveraging-quantization-and-dimensionality-reduction/), SVS-VAMANA delivers significant improvements over HNSW:

### Memory Savings

SVS-VAMANA with LVQ8 compression achieves consistent memory reductions across datasets:

| Dataset | Dimensions | Total Memory Reduction | Index Memory Reduction |
|---------|------------|----------------------|----------------------|
| LAION | 512 | 26% | 51% |
| Cohere | 768 | 35% | 70% |
| DBpedia | 1536 | 37% | 74% |

### Throughput Improvements (FP32)

At 0.95+ precision, compared to HNSW:

| Dataset | Dimensions | QPS Improvement |
|---------|------------|-----------------|
| Cohere | 768 | Up to 144% higher |
| DBpedia | 1536 | Up to 60% higher |
| LAION | 512 | 0-15% (marginal) |

SVS-VAMANA is most effective for medium-to-high dimensional embeddings (768–3072 dimensions).

### Latency Improvements (FP32, High Concurrency)

| Dataset | p50 Latency Reduction | p95 Latency Reduction |
|---------|----------------------|----------------------|
| Cohere (768d) | 60% | 57% |
| DBpedia (1536d) | 46% | 36% |

### Precision vs. Performance

At every precision point from ~0.92 to 0.99, SVS-VAMANA matches HNSW accuracy while delivering higher throughput. At high precision (0.99), SVS-VAMANA sustains up to 1.5x better throughput.

### Ingestion Trade-offs

SVS-VAMANA index construction is slower than HNSW due to compression overhead. On x86 platforms:
- LeanVec: Can be up to 25% faster or 33% slower than HNSW depending on dataset
- LVQ: Up to 2.6x slower than HNSW

This trade-off is acceptable for workloads where query performance and memory efficiency are priorities.

## FAQ

### Q: When should I use SVS-VAMANA vs HNSW?

**A:** Use SVS-VAMANA when:
- Running on Intel Xeon processors with AVX-512
- Memory efficiency is important (26-37% savings)
- You have medium-to-high dimensional vectors (768+)
- Query throughput and latency are priorities

Use HNSW when:
- Running on ARM platforms (HNSW performs well on ARM)
- You need faster index construction
- Working with lower-dimensional vectors (<512)

### Q: Are LVQ and LeanVec available in Redis Open Source?

**A:** The basic SVS-VAMANA algorithm with 8-bit scalar quantization (SQ8) is available in Redis Open Source on all platforms. Intel's proprietary LVQ and LeanVec optimizations require:
- Intel hardware with AVX-512
- Redis Software (commercial) or building with `BUILD_INTEL_SVS_OPT=yes`

**⚠️ Licensing Note:** If you use Redis Open Source under AGPLv3 or SSPLv1, you cannot use Intel's proprietary LVQ/LeanVec binaries—the Intel SVS license is incompatible with those licenses. LVQ and LeanVec optimizations are only available when Redis Open Source is distributed under RSALv2. See [Redis SVS compression docs](https://redis.io/docs/latest/develop/ai/search-and-query/vectors/svs-compression/) for details.

On non-Intel platforms (AMD, ARM), SVS-VAMANA falls back to SQ8 compression.

### Q: What if recall is too low with compression?

**A:** Try these steps in order:
1. Increase `TRAINING_THRESHOLD` (e.g., 50000)
2. Switch to higher-bit compression (LVQ4x8 → LVQ8, or LeanVec4x8 → LeanVec8x8)
3. Increase `GRAPH_MAX_DEGREE` (e.g., 64 or 128)
4. Increase `SEARCH_WINDOW_SIZE` at query time
5. For LeanVec, try a larger `REDUCE` value (closer to original dimensions)

### Q: How does performance compare across CPU vendors?

**A:** Based on benchmarks:
- **Intel**: Best performance with LVQ and LeanVec optimizations
- **AMD**: Strong performance with SQ8 fallback, comparable to Intel in many cases
- **ARM**: HNSW is recommended; SVS-VAMANA SQ8 fallback has slower ingestion on ARM

## References

- [Redis Vector Search Documentation](https://redis.io/docs/latest/develop/ai/search-and-query/vectors/)
- [SVS-VAMANA Index Reference](https://redis.io/docs/latest/develop/ai/search-and-query/vectors/#svs-vamana-index)
- [Vector Compression Guide](https://redis.io/docs/latest/develop/ai/search-and-query/vectors/svs-compression/)
- [Tech Dive: Comprehensive Compression](https://redis.io/blog/tech-dive-comprehensive-compression-leveraging-quantization-and-dimensionality-reduction/)
- [Intel Scalable Vector Search](https://intel.github.io/ScalableVectorSearch/)
