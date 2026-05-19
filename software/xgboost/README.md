# XGBoost Optimization on Intel® Processors

## Introduction

[XGBoost](https://xgboost.readthedocs.io/) is one of the most popular and efficient gradient boosting frameworks for classification and regression tasks on tabular data. This guide covers techniques to significantly accelerate XGBoost inference on Intel® Xeon® processors using [Intel® oneAPI Data Analytics Library (oneDAL)](https://www.intel.com/content/www/us/en/developer/tools/oneapi/onedal.html) via its Python interface, `daal4py`.

By converting trained XGBoost models to oneDAL, you can achieve **up to 36x faster inference** with no loss in prediction quality and minimal code changes. oneDAL leverages Intel® Advanced Vector Extensions 512 (AVX-512) and optimized memory access patterns to maximize performance on Intel hardware.

## Contents

- [References](#references)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Accelerating XGBoost Inference with oneDAL](#accelerating-xgboost-inference-with-onedal)
  - [Convert and Predict (Simplified API)](#convert-and-predict-simplified-api)
  - [Classification Example](#classification-example)
  - [Regression Example](#regression-example)
  - [Getting Prediction Probabilities](#getting-prediction-probabilities)
  - [Saving and Loading Converted Models](#saving-and-loading-converted-models)
- [Performance Results](#performance-results)
- [How It Works](#how-it-works)
- [Configuration Recommendations](#configuration-recommendations)
  - [Scaling Inference on Multi-Socket Systems](#scaling-inference-on-multi-socket-systems)

## References

- [Faster XGBoost, LightGBM, and CatBoost Inference on the CPU (Intel Developer)](https://www.intel.com/content/www/us/en/developer/articles/technical/faster-xgboost-light-gbm-catboost-inference-on-cpu.html)
- [Improving the Performance of XGBoost and LightGBM Inference (Intel Analytics Software)](https://medium.com/intel-analytics-software/improving-the-performance-of-xgboost-and-lightgbm-inference-3b542c03447e)
- [Fast Gradient Boosting Tree Inference for Intel Xeon Processors (Intel Analytics Software)](https://medium.com/intel-analytics-software/fast-gradient-boosting-tree-inference-for-intel-xeon-processors-35756f174f55)
- [daal4py Model Builders Documentation](https://intelpython.github.io/daal4py/model-builders.html)
- [oneDAL GitHub Repository](https://github.com/uxlfoundation/oneDAL)
- [Intel Extension for Scikit-learn (sklearnex)](https://github.com/intel/scikit-learn-intelex)

## Prerequisites

- Intel® Xeon® Scalable Processor (2nd Generation or newer recommended for AVX-512 support)
- Python 3.9 or higher
- XGBoost installed (`xgboost` package)

## Installation

Install `daal4py` from PyPI:

```bash
pip install daal4py
```

Or from conda-forge:

```bash
conda install -c conda-forge daal4py --override-channels
```

## Accelerating XGBoost Inference with oneDAL

The core optimization is straightforward: train your model with XGBoost as usual, then convert it to a oneDAL model for faster inference. No changes to your training code are required.

### Convert and Predict (Simplified API)

The simplest approach uses the `d4p.mb.convert_model()` API:

```python
import xgboost as xgb
import daal4py as d4p

# Train your XGBoost model as usual
clf = xgb.XGBClassifier(**params)
clf.fit(X_train, y_train)

# Convert to oneDAL model (one line)
d4p_model = d4p.mb.convert_model(clf)

# Run inference with oneDAL acceleration
predictions = d4p_model.predict(X_test)
```

This same API also works with LightGBM and CatBoost models:

```python
# LightGBM
d4p_model = d4p.mb.convert_model(lgb_model)

# CatBoost
d4p_model = d4p.mb.convert_model(cb_model)
```

### Classification Example

```python
import numpy as np
import xgboost as xgb
import daal4py as d4p
from sklearn.datasets import make_classification
from sklearn.model_selection import train_test_split

# Generate sample data
X, y = make_classification(n_samples=10000, n_features=50, random_state=42)
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2)

# Train with XGBoost
params = {
    "n_estimators": 100,
    "max_depth": 8,
    "learning_rate": 0.1,
    "objective": "binary:logistic",
    "eval_metric": "logloss",
}
clf = xgb.XGBClassifier(**params)
clf.fit(X_train, y_train)

# Convert to oneDAL for faster inference
d4p_model = d4p.mb.convert_model(clf)

# Predict with oneDAL acceleration
d4p_predictions = d4p_model.predict(X_test)
```

### Regression Example

```python
import xgboost as xgb
import daal4py as d4p
from sklearn.datasets import make_regression
from sklearn.model_selection import train_test_split

# Generate sample data
X, y = make_regression(n_samples=10000, n_features=50, random_state=42)
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2)

# Train with XGBoost
reg = xgb.XGBRegressor(n_estimators=100, max_depth=8, learning_rate=0.1)
reg.fit(X_train, y_train)

# Convert and predict with oneDAL
d4p_model = d4p.mb.convert_model(reg)
d4p_predictions = d4p_model.predict(X_test)
```

### Getting Prediction Probabilities

For classification tasks, you can request both labels and probabilities:

```python
import daal4py as d4p

# Using the lower-level API for more control
daal_model = d4p.get_gbt_model_from_xgboost(clf.get_booster())

predict_algo = d4p.gbt_classification_prediction(
    nClasses=n_classes,
    resultsToEvaluate="computeClassLabels|computeClassProbabilities"
)
daal_prediction = predict_algo.compute(X_test, daal_model)

# Access results
labels = daal_prediction.prediction
probabilities = daal_prediction.probabilities
```

### Saving and Loading Converted Models

Converted oneDAL models can be serialized with `pickle` for deployment:

```python
import pickle
import daal4py as d4p

# Convert from XGBoost
d4p_model = d4p.mb.convert_model(xgb_model)

# Save the converted model
with open("d4p_model.pkl", "wb") as f:
    pickle.dump(d4p_model, f)

# Load and predict (no XGBoost dependency needed at inference time)
with open("d4p_model.pkl", "rb") as f:
    model = pickle.load(f)

predictions = model.predict(X_test)
```

## Performance Results

### daal4py (oneDAL) Inference Speedup over Native Libraries

The following results were measured on an Intel® Xeon® Platinum 8592+ (Emerald Rapids), 2 sockets, 64 cores/socket, 256 threads, 503 GB RAM. Benchmarks were pinned to a single NUMA node (cores 0–31) using `numactl --localalloc --physcpubind=0-31`. Each model was trained with 100 estimators at max depth 8. Inference was measured over 100 iterations after warmup. Speedup = native library inference time / daal4py inference time.

| Dataset | Rows | Features | Task | daal4py vs XGBoost | daal4py vs LightGBM | daal4py vs CatBoost |
|:--------|-----:|---------:|:-----|-------------------:|--------------------:|--------------------:|
| Abalone | 4,177 | 8 | Regression | 2.66x | 3.53x | 6.12x |
| HIGGS-1M | 940,160 | 24 | Classification | 1.87x | 6.10x | 9.25x |
| MLSR | 203 | 12,600 | Regression | 8.02x | 2.51x | 25.91x |
| Mortgage-1Q | 500,000 | 45 | Regression | 1.24x | 1.66x | 5.27x |
| PLAsTiCC | 200,000 | 60 | Classification | 2.81x | 6.50x | 1.11x |
| Airline | 26,969 | 7 | Classification | 1.73x | 3.55x | 10.01x |

**Software versions:** XGBoost 2.1.4, LightGBM 4.6.0, CatBoost 1.2.10, daal4py 2024.7, Python 3.10.12, scikit-learn 1.5.2

**Hardware:** Intel® Xeon® Platinum 8592+ (Emerald Rapids), 2 sockets, 64 cores/socket, 256 threads, HT On, 503 GB DDR5, single NUMA node

Across all datasets, daal4py consistently accelerates inference for all three gradient boosting frameworks. CatBoost sees the largest gains (up to 25.9x on MLSR), while LightGBM and XGBoost benefit most on larger datasets and higher-dimensional feature spaces. Prediction quality is preserved — match rates are 99.7–100% across all tests.

### Reproducing the Benchmark

The core benchmarking loop measures native vs daal4py inference time after warmup:

```python
import time
import numpy as np
import daal4py as d4p

# model = trained XGBoost, LightGBM, or CatBoost model
# X_test = numpy float32 test array

# Convert the model (works for XGBoost, LightGBM, and CatBoost)
d4p_model = d4p.mb.convert_model(model)

# Warmup
for _ in range(5):
    model.predict(X_test)
    d4p_model.predict(X_test)

# Measure native inference
n_iter = 100
native_times = []
for _ in range(n_iter):
    t0 = time.perf_counter()
    model.predict(X_test)
    native_times.append(time.perf_counter() - t0)

# Measure daal4py inference
d4p_times = []
for _ in range(n_iter):
    t0 = time.perf_counter()
    d4p_model.predict(X_test)
    d4p_times.append(time.perf_counter() - t0)

speedup = np.mean(native_times) / np.mean(d4p_times)
print(f"Speedup: {speedup:.2f}x")
```

*Performance varies by use, configuration, and other factors.*

## How It Works

oneDAL achieves faster GBT inference through two key optimizations:

### AVX-512 Vectorized Tree Traversal
oneDAL uses Intel AVX-512 vector instructions (`vpgatherd` and `vcmpp`) to process multiple observations through decision trees simultaneously. Instead of traversing one observation at a time, it processes a block of rows through each tree in parallel using SIMD operations for node comparisons and index computations.

### Cache-Optimized Memory Access
Tree structures are blocked in memory so that a subset of trees and a block of observations fit in the L1 data cache. This ensures the majority of memory accesses are served from L1 cache at maximum bandwidth, rather than incurring costly main memory accesses.

## Configuration Recommendations

| Setting | Recommendation |
|:--------|:---------------|
| Data Format | Use NumPy contiguous arrays (`np.ascontiguousarray()`) as input for best performance |
| Data Type | Use `float32` for maximum throughput; `float64` is also supported |
| Batch Size | oneDAL performs well across batch sizes, with the largest advantage at batch size = 1 (online inference) |
| NUMA | For multi-socket systems, pin processes to a single NUMA node to minimize cross-socket memory access |
| daal4py Version | Use daal4py 2023.2 or newer (required for missing values support). Each release includes additional optimizations and bug fixes, so the latest version is recommended |

### Scaling Inference on Multi-Socket Systems

On multi-socket Intel Xeon systems, there are two key decisions that significantly impact daal4py inference performance: **how to scale across NUMA nodes** and **whether to use hyperthreads**.

#### Thread Scaling vs. Process Scaling

A single daal4py process uses internal threading (TBB/OpenMP) to parallelize across available cores. Alternatively, you can run multiple independent OS-level processes, each pinned to a separate NUMA node with its own copy of the model and data. These approaches offer different tradeoffs.

Testing on a 4-NUMA-node Intel Xeon Platinum 8592+ (200K rows, 24 features, 100 trees, `numactl --localalloc`) showed:

| Configuration | Throughput (rows/s) | p50 Latency (us) | Scaling |
|:--------------|--------------------:|------------------:|:--------|
| **Thread scaling** (single process, daal internal threading) | | | |
| 1 NUMA node (32 cores) | ~15–17M | ~2,300 | 1.0x |
| 1 socket (64 cores) | ~20M | ~1,500 | 1.3x |
| 2 sockets (128 cores) | ~32M | ~1,230 | 2.1x |
| **Process scaling** (separate NUMA-pinned OS processes) | | | |
| 1 process (32 cores) | ~18M | ~2,280 | 1.0x |
| 2 processes, 1 per NUMA node (64 cores) | ~38M | ~2,040 | 2.1x |
| 4 processes, 1 per NUMA node (128 cores) | ~73M | ~2,090 | 4.1x |

Key observations:
- **Process scaling is nearly linear** — 4 NUMA-pinned processes achieve **4.1x** the throughput of a single process. Each worker has its own model, data, and local memory, with zero cross-NUMA traffic.
- **Thread scaling is sub-linear** — using 4x the cores in a single process yields only **2.1x** throughput, because cross-socket memory coherency traffic limits scaling.
- **The tradeoff is latency**: thread scaling achieves **lower per-request latency** (1,230 us at 128 cores) because all cores collaborate on each prediction. Process scaling maintains a fixed latency (~2,000 us per worker, 32 cores each) but delivers **higher aggregate throughput**.

#### Hyper-threading Hurts Performance

daal4py's AVX-512 vectorized tree traversal is [backend-bound](https://www.intel.com/content/www/us/en/docs/vtune-profiler/cookbook/2023-0/top-down-microarchitecture-analysis-method.html) — whether the bottleneck is core execution units or memory bandwidth, adding hyperthreads increases resource contention on the shared physical core, harming performance.

| Configuration (1 NUMA node) | Throughput (rows/s) | p50 Latency (us) |
|:-----------------------------|--------------------:|------------------:|
| 32 physical cores only (`--physcpubind=0-31`) | ~18M | ~2,000 |
| 64 threads with HT (`--physcpubind=0-31,128-159` or `--cpunodebind=0`) | ~8.5M | ~4,760 |

Enabling hyperthreads **halves throughput and doubles latency**, regardless of whether you use `--cpunodebind` or `--physcpubind` to specify them. The penalty comes from HT siblings competing for the same AVX-512 execution units and cache lines that daal4py relies on.

#### Recommendations

**For latency-sensitive inference** (single request at a time), use thread scaling with all physical cores:

```bash
# Use all 128 physical cores across both sockets for lowest per-request latency
numactl --localalloc --physcpubind=0-127 python my_inference.py
```

**For throughput-oriented serving** (batch processing or concurrent clients), run one process per NUMA node, each pinned to physical cores only:

```bash
# 4 NUMA-pinned workers for maximum aggregate throughput
numactl --localalloc --physcpubind=0-31   python my_inference.py --shard=0 &
numactl --localalloc --physcpubind=32-63  python my_inference.py --shard=1 &
numactl --localalloc --physcpubind=64-95  python my_inference.py --shard=2 &
numactl --localalloc --physcpubind=96-127 python my_inference.py --shard=3 &
```

**Always pin to physical cores** — use `--physcpubind` with physical core IDs, not `--cpunodebind` which includes hyperthread siblings. On systems where HT cannot be disabled in BIOS, explicit `--physcpubind` ranges are essential.

#### Memory Allocator

Alternative memory allocators such as jemalloc or tcmalloc can sometimes improve performance over the default glibc malloc. It is recommended to test with these enabled to see if either provides a benefit for your workload:

```bash
# jemalloc
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2 python my_inference.py

# tcmalloc
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libtcmalloc.so.4 python my_inference.py
```
