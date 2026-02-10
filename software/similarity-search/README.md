# Similarity Search Optimization Guides

This section contains optimization guides for vector similarity search workloads on Intel hardware. These guides help users of popular vector search solutions achieve optimal performance on Intel Xeon processors.

## Overview

Vector similarity search is a core component of modern AI applications including:

- Retrieval-Augmented Generation (RAG)
- Semantic search
- Recommendation systems
- Image and video similarity
- Anomaly detection

## Intel Scalable Vector Search (SVS)

[Intel Scalable Vector Search (SVS)](https://intel.github.io/ScalableVectorSearch/) is a high-performance library for vector similarity search, optimized for Intel hardware. SVS can be used directly as a standalone library, and we are working on integrating it into various popular solutions to bring these optimizations to a wider audience.

SVS features:

- **Vamana Algorithm**: Graph-based approximate nearest neighbor search
- **Vector Compression**: LVQ and LeanVec for significant memory reduction
- **Hardware Optimization**: Best performance on servers with AVX-512 support

## Understanding LVQ and LeanVec Compression

Traditional vector compression methods face limitations in graph-based search. Product Quantization (PQ) requires keeping full-precision vectors for re-ranking, defeating compression benefits. Standard scalar quantization with global bounds fails to efficiently utilize available quantization levels.

### LVQ (Locally-adaptive Vector Quantization)

LVQ addresses these limitations by applying **per-vector normalization and scalar quantization**, adapting the quantization bounds individually for each vector. This local adaptation ensures efficient use of the available bit range, resulting in high-quality compressed representations.

Key benefits:
- Minimal decompression overhead enables fast, on-the-fly distance computations
- Significantly reduces memory bandwidth and storage requirements
- Maintains high search accuracy and throughput
- SIMD-optimized layout ([Turbo LVQ](https://arxiv.org/abs/2402.02044)) for efficient distance computations

LVQ achieves a **four-fold reduction** of vector size while maintaining search accuracy. A typical 768-dimensional float32 vector requiring 3072 bytes can be reduced to just a few hundred bytes.

### LeanVec (LVQ with Dimensionality Reduction)

[LeanVec](https://openreview.net/forum?id=wczqrpOrIc) builds on LVQ by first applying **linear dimensionality reduction**, then compressing the reduced vectors with LVQ. This two-step approach significantly cuts memory and compute costs, enabling faster similarity search and index construction with minimal accuracy loss—especially effective for high-dimensional deep learning embeddings.

Best suited for:
- High-dimensional vectors (768+ dimensions)
- Text embeddings from large language models
- Cases where maximum memory savings are needed

### Two-Level Compression

Both LVQ and LeanVec support two-level compression schemes:

1. **Level 1**: Fast candidate retrieval using compressed vectors
2. **Level 2**: Re-ranking using residual encoding for accuracy

The naming convention reflects bits per dimension at each level:
- `LVQ4x8`: 4 bits for Level 1, 8 bits for Level 2 (12 bits total per dimension)
- `LVQ8`: Single-level, 8 bits per dimension
- `LeanVec4x8`: Dimensionality reduction + 4-bit Level 1 + 8-bit Level 2

## Vector Compression Selection

| Compression | Best For | Observations |
|-------------|----------|--------------|
| LVQ4x4 | Fast search and low memory use | Consider LeanVec for even faster search |
| LeanVec4x8 | Fastest search and ingestion | LeanVec dimensionality reduction might reduce recall |
| LVQ4 | Maximum memory saving | Recall might be insufficient |
| LVQ8 | Faster ingestion than LVQ4x4 | Search likely slower than LVQ4x4 |
| LeanVec8x8 | Improved recall when LeanVec4x8 is insufficient | LeanVec dimensionality reduction might reduce recall |
| LVQ4x8 | Improved recall when LVQ4x4 is insufficient | Slightly worse memory savings |

**Rule of thumb:**
- Dimensions < 768 → Use LVQ (LVQ4x4, LVQ4x8, or LVQ8)
- Dimensions ≥ 768 → Use LeanVec (LeanVec4x8 or LeanVec8x8)

## Available Guides

| Software | Description | Guide |
|----------|-------------|-------|
| **Redis** | Redis Query Engine with SVS-VAMANA | [Redis Guide](redis/README.md) |
| **FAISS** | Facebook AI Similarity Search with SVS indexes | [FAISS Guide](faiss/README.md) |

## References

- [Intel Scalable Vector Search](https://intel.github.io/ScalableVectorSearch/)
- [SVS GitHub Repository](https://github.com/intel/ScalableVectorSearch)
- [LVQ Paper (VLDB 2023)](https://www.vldb.org/pvldb/vol16/p2769-aguerrebere.pdf)
- [LeanVec Paper (TMLR 2024)](https://openreview.net/forum?id=Y5Mvyusf1u)
- [Turbo LVQ Paper](https://arxiv.org/abs/2402.02044)
