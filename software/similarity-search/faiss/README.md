# FAISS Vector Search Optimization Guide

This guide describes best practices for optimizing vector similarity search performance in FAISS on Intel Xeon processors. FAISS includes native support for Intel SVS indexes (IndexSVSVamana, IndexSVSVamanaLVQ, IndexSVSVamanaLeanVec), providing optimized performance on Intel hardware.

## Table of Contents

- [Overview](#overview)
- [SVS Index Types in FAISS](#svs-index-types-in-faiss)
- [Installation](#installation)
- [Creating SVS Indexes](#creating-svs-indexes)
- [Vector Compression](#vector-compression)
- [Performance Tuning](#performance-tuning)
- [FAQ](#faq)
- [References](#references)

## Overview

FAISS (Facebook AI Similarity Search) is a library for efficient similarity search and clustering of dense vectors. Starting with recent versions, FAISS includes native integration with Intel's Scalable Vector Search (SVS) library.

**SVS Index Types in FAISS:**

| Index Type | Description | Compression |
|------------|-------------|-------------|
| IndexSVSVamana | Base SVS graph-based index | None (full precision) |
| IndexSVSVamanaLVQ | SVS with LVQ compression | LVQ (4-8 bits per dimension) |
| IndexSVSVamanaLeanVec | SVS with LeanVec compression | Dimensionality reduction + LVQ |

**Key Benefits:**

- High-performance graph-based similarity search optimized for Intel CPUs
- Significant memory reduction with LVQ and LeanVec compression
- Best performance on Intel Xeon with AVX-512 support

## SVS Index Types in FAISS

### IndexSVSVamana

The base SVS index using the Vamana graph algorithm without compression. Best for maximum accuracy when memory is not a constraint.

### IndexSVSVamanaLVQ

Combines Vamana with Locally-adaptive Vector Quantization (LVQ). LVQ applies per-vector normalization and scalar quantization, achieving up to 4x memory reduction while maintaining high accuracy.

### IndexSVSVamanaLeanVec

Extends LVQ with dimensionality reduction. Best for high-dimensional vectors (768+ dimensions), achieving up to 8-16x memory reduction. Particularly effective for text embeddings from large language models.

## Installation

### From PyPI (with Intel optimizations)

```bash
pip install faiss-cpu
```

### From Conda (Intel channel)

```bash
conda install -c conda-forge faiss-cpu
```

### Building with SVS Support

To enable Intel SVS optimizations when building from source:

```bash
git clone https://github.com/facebookresearch/faiss.git
cd faiss
cmake -B build \
    -DFAISS_ENABLE_SVS=ON \
    -DCMAKE_BUILD_TYPE=Release \
    .
cmake --build build -j
```

## Creating SVS Indexes

### Using Factory String

FAISS provides a factory string format for creating SVS indexes:

```
SVSVamana<degree>[,<compression>[_<dims>]]
```

**Examples:**

```python
import faiss

# Basic SVS index with graph degree 32
index = faiss.index_factory(768, "SVSVamana32")

# SVS with LVQ8 compression
index = faiss.index_factory(768, "SVSVamana32,LVQ8")

# SVS with LVQ4x8 two-level compression
index = faiss.index_factory(768, "SVSVamana64,LVQ4x8")

# SVS with LeanVec (dimensionality reduction to 128 dims)
index = faiss.index_factory(768, "SVSVamana32,LeanVec4x8_128")
```

### Direct Index Creation

```python
import faiss
import numpy as np

# Sample data
d = 768  # dimension
n = 100000  # number of vectors
xb = np.random.random((n, d)).astype('float32')

# Create SVS index with LVQ compression
index = faiss.IndexSVSVamanaLVQ(
    d,  # dimension
    32,  # graph_max_degree
    8,   # primary bits (LVQ8)
    0    # residual bits (0 = single level)
)

# Build the index
index.train(xb)
index.add(xb)

# Search
k = 10  # number of neighbors
xq = np.random.random((5, d)).astype('float32')
D, I = index.search(xq, k)
```

### Index Parameters

| Parameter | Description | Default | Guidance |
|-----------|-------------|---------|----------|
| dimension | Vector dimensions | - | Must match your embeddings |
| graph_max_degree | Max edges per node | 32 | Higher = better recall, more memory |
| construction_window_size | Build search window | 200 | Higher = better graph quality |
| search_window_size | Query search window | 10 | Higher = better recall |

## Vector Compression

### Compression Options

| Compression | Factory String | Memory Reduction | Best For |
|-------------|----------------|------------------|----------|
| None | `SVSVamana32` | 1x | Maximum accuracy |
| LVQ8 | `SVSVamana32,LVQ8` | ~4x | Good balance |
| LVQ4x8 | `SVSVamana32,LVQ4x8` | ~3x | High recall with compression |
| LeanVec4x8 | `SVSVamana32,LeanVec4x8_128` | 8-16x | High-dimensional vectors |
| LeanVec8x8 | `SVSVamana32,LeanVec8x8_256` | 4-8x | Best recall with LeanVec |

### Choosing Compression

**Rule of thumb:**
- Dimensions < 768: Use LVQ (LVQ8 or LVQ4x8)
- Dimensions ≥ 768: Use LeanVec (LeanVec4x8 or LeanVec8x8)
- Maximum memory savings: LeanVec with aggressive dimension reduction

### LeanVec Dimension Selection

The `_<dims>` suffix in LeanVec specifies the reduced dimension:

```python
# Original: 768 dims, reduced to 192 (768/4)
index = faiss.index_factory(768, "SVSVamana32,LeanVec4x8_192")

# Original: 1536 dims, reduced to 384 (1536/4)
index = faiss.index_factory(1536, "SVSVamana32,LeanVec4x8_384")
```

Lower reduced dimensions = faster search and less memory, but may reduce recall.

## Performance Tuning

### Search Parameters

```python
# Set search window size (higher = better recall, slower)
index.search_window_size = 50

# Perform search
D, I = index.search(queries, k)
```

### Multi-threaded Search

```python
import faiss

# Set number of threads for search
faiss.omp_set_num_threads(16)

# Search will use multiple threads
D, I = index.search(queries, k)
```

### Index Save/Load

```python
# Save index
faiss.write_index(index, "my_index.faiss")

# Load index
index = faiss.read_index("my_index.faiss")
```

## FAQ

### Q: How do I check if SVS is available in my FAISS installation?

```python
import faiss
print(hasattr(faiss, 'IndexSVSVamana'))  # True if SVS is available
```

### Q: Can I convert an existing FAISS index to SVS?

**A:** No direct conversion is available. You need to rebuild the index using SVS index types. Extract your vectors and create a new SVS index.

### Q: What happens on non-Intel hardware?

**A:** SVS indexes are designed for Intel CPUs. On Intel platforms without AVX-512, performance is still good but not optimal. On non-Intel platforms (AMD, ARM), consider using standard FAISS indexes like IndexHNSW.

### Q: How does IndexSVSVamana compare to IndexHNSW?

**A:** Both are graph-based approximate nearest neighbor indexes. SVS typically offers:
- Higher throughput (up to 8x on some datasets)
- Better memory efficiency with compression
- Optimized performance on Intel hardware

Use HNSW if you need broader hardware compatibility or are on ARM.

### Q: What if recall is too low with compression?

**A:** Try these adjustments:
1. Increase `search_window_size` (e.g., 50 or 100)
2. Use higher-bit compression (LVQ4x8 → LVQ8)
3. For LeanVec, increase the reduced dimension
4. Increase `graph_max_degree` when building

## References

- [FAISS GitHub Repository](https://github.com/facebookresearch/faiss)
- [FAISS SVS Integration Wiki](https://github.com/facebookresearch/faiss/wiki/CPU-Faiss---Intel-SVS-%E2%80%90-Overview)
- [FAISS SVS Usage Guide](https://github.com/facebookresearch/faiss/wiki/CPU-Faiss---Intel-SVS-%E2%80%90-Usage)
- [Intel Scalable Vector Search](https://intel.github.io/ScalableVectorSearch/)
- [Intel SVS Benchmarks](https://intel.github.io/ScalableVectorSearch/benchs/static/latest.html)
