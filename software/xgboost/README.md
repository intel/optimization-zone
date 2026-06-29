# Gradient Boosting Inference Optimization on Intel® Processors

## Introduction

[XGBoost](https://xgboost.readthedocs.io/), [LightGBM](https://lightgbm.readthedocs.io/), and [CatBoost](https://catboost.ai/) are among the most popular and efficient gradient boosting frameworks for classification and regression tasks on tabular data. This guide covers techniques to significantly accelerate inference for these frameworks on Intel® Xeon® processors using [oneDAL (oneAPI Data Analytics Library)](http://uxlfoundation.github.io/oneDAL/) via its Python interface, `daal4py`, provided through the [`scikit-learn-intelex`](https://github.com/intel/scikit-learn-intelex) package.

By converting trained models to oneDAL, you can achieve **orders of magnitude faster inference** with no loss in prediction quality and minimal code changes. oneDAL leverages Intel® Advanced Vector Extensions 512 (AVX-512) and optimized memory access patterns to maximize performance on Intel hardware.

> **Note:** `daal4py` supports a specific subset of GBT model configurations (e.g., standard classification and regression trees). For model types not supported by daal4py, consider alternatives such as [ONNX Runtime](https://onnxruntime.ai/) for optimized inference.

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
- [scikit-learn-intelex Model Builders Documentation](https://uxlfoundation.github.io/scikit-learn-intelex/latest/model_builders.html)
- [About daal4py](https://uxlfoundation.github.io/scikit-learn-intelex/latest/about_daal4py.html)
- [oneDAL GitHub Repository](https://github.com/uxlfoundation/oneDAL)
- [scikit-learn-intelex (sklearnex)](https://github.com/intel/scikit-learn-intelex)

## Prerequisites

- Intel® Xeon® Scalable Processor (2nd Generation or newer recommended for AVX-512 support)
- Python version supported by [scikit-learn-intelex](https://github.com/intel/scikit-learn-intelex) (currently 3.10+)
- One or more gradient boosting libraries: [XGBoost](https://xgboost.readthedocs.io/) (`xgboost` from PyPI or `py-xgboost` from conda-forge), [LightGBM](https://lightgbm.readthedocs.io/) (`lightgbm`), [CatBoost](https://catboost.ai/) (`catboost`)

## Installation

The `daal4py` module is provided through the `scikit-learn-intelex` package. Install from PyPI:

```bash
pip install scikit-learn-intelex
```

Or from conda-forge:

```bash
conda install -c conda-forge scikit-learn-intelex --override-channels
```

Install the gradient boosting libraries you need:

```bash
pip install xgboost lightgbm catboost
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

For classification tasks, you can request both labels and probabilities using the high-level API:

```python
import daal4py as d4p

# Convert the model
d4p_model = d4p.mb.convert_model(clf)

# Get class labels
predictions = d4p_model.predict(X_test)

# Get prediction probabilities
probabilities = d4p_model.predict_proba(X_test)
```

For full documentation on supported model types and options, see the [Model Builders documentation](https://uxlfoundation.github.io/scikit-learn-intelex/latest/model_builders.html).

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

### daal4py (oneDAL) Inference Speedup over Native Libraries (Batch Size = 1)

The following results were measured on an AWS r8i.12xlarge instance (Intel® Xeon® Scalable Processor, Granite Rapids, 48 vCPUs, 384 GB RAM). Each model was trained with 1,000 estimators. Inference was measured at batch size = 1 (single-row prediction). Speedup = native library inference time / daal4py inference time.

| Dataset | Rows | Features | Task | daal4py vs XGBoost | daal4py vs LightGBM | daal4py vs CatBoost |
|:--------|-----:|---------:|:-----|-------------------:|--------------------:|--------------------:|
| Abalone | 4,177 | 8 | Regression | 12.56x | 10.06x | 4.91x |
| Airline | 26,969 | 6,452 | Classification (binary) | 11.27x | 13.01x | 1.85x |
| Airline-OHE | 940,160 | 24 | Classification (binary) | 5.32x | 51.03x | 46.86x |
| Bosch | 6,000,960 | 136 | Classification (binary) | 10.98x | 21.84x | 15.01x |
| Covtype | 500,000 | 45 | Classification (7-class) | 2.56x | 1.49x | 0.20x |
| Epsilon | 200,000 | 60 | Classification (binary) | 8.69x | 28.34x | 23.19x |
| Fraud | 76,020 | 370 | Classification (binary) | 15.78x | 41.55x | 3.58x |
| HIGGS | 26,969 | 7 | Classification (binary) | 10.82x | 13.53x | 2.36x |
| HIGGS-1M | 1,183,747 | 968 | Classification (binary) | 12.26x | 13.91x | 3.01x |
| MLSR | 581,012 | 54 | Regression | 13.67x | 11.61x | 5.73x |
| Mortgage-1Q | 500,000 | 2,000 | Regression | 13.05x | 8.91x | 4.09x |
| PLAsTiCC | 200,000 | 60 | Classification (14-class) | 2.42x | 1.07x | 0.11x |
| Santander | 940,160 | 24 | Classification (binary) | 11.07x | 17.22x | 7.42x |
| Year Prediction MSD | 515,345 | 90 | Regression | 11.59x | 10.46x | 4.56x |

**Software versions used for benchmarking:** XGBoost 3.2.0, LightGBM 4.6.0, CatBoost 1.2.10, scikit-learn-intelex 2026.0.0, Python 3.10.12, scikit-learn 1.7.2. For best results, use the latest available versions of these packages.

**Hardware:** AWS r8i.12xlarge (Intel® Xeon® Scalable Processor, Granite Rapids, 48 vCPUs, 384 GB RAM)

Across all datasets, daal4py consistently accelerates inference for all three gradient boosting frameworks. LightGBM sees the largest gains (up to 51x on Airline-OHE), XGBoost achieves 5–16x speedup across all workloads, and CatBoost benefits most on high-dimensional binary classification tasks. 

For multiclass classification, default XGBoost, LightGBM, and daal4py all use one tree per class. CatBoost, on the other hand, uses vectorized trees. This means all other approaches end up processing `num_classes x` more trees compared to CatBoost, e.g., 7,000 vs 1,000 for Covtype. For smaller `num_estimators` like `100`, `daal4py` outperforms CatBoost, but as `num_estimators` gets larger, CatBoost provides better inference latency. 

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

The speedup from oneDAL comes from three primary factors:

### 1. Python/Framework Overhead Elimination

Native Python-based prediction (XGBoost, LightGBM, CatBoost) incurs significant per-prediction overhead: interpreter dispatch, type checking, array conversion, reference counting, and Python-to-C++ data marshalling. The majority of CPU time in native inference is spent in this framework glue code rather than actual tree traversal.

By converting the model to a native C++ representation, oneDAL eliminates this overhead entirely. The prediction hot path runs without any Python interpreter involvement.

### 2. Vectorized Tree Traversal

oneDAL uses SIMD instructions (AVX2/AVX-512) to traverse decision trees. Instead of scalar node-by-node comparisons, it processes multiple tree nodes or observations in parallel using vector gather and compare operations. This means the actual tree traversal computation is concentrated in a tight, optimized loop rather than being spread across many small framework functions.

### 3. Reduced Kernel and Synchronization Overhead

Native frameworks spend a notable portion of time in kernel space due to Python GIL contention and threading layer interactions (syscalls, thread scheduling, locks). oneDAL minimizes this by keeping execution in user space with efficient thread parallelism.

## Configuration Recommendations

| Setting | Recommendation |
|:--------|:---------------|
| Data Format | Use NumPy contiguous arrays (`np.ascontiguousarray()`) as input for best performance |
| Data Type | Use `float32` for maximum throughput; `float64` is also supported |
| Batch Size | oneDAL performs well across batch sizes, with the largest advantage at batch size = 1 (online inference) |
| NUMA | For multi-socket systems, pin processes to a single NUMA node to minimize cross-socket memory access |
| scikit-learn-intelex Version | Use the latest version of `scikit-learn-intelex` for best performance, newest model support, and bug fixes |

### Scaling Inference on Multi-Socket Systems

On multi-socket Intel Xeon systems, there are two key decisions that significantly impact daal4py inference performance: **how to scale across NUMA nodes** and **whether to use hyperthreads**.

#### Thread Scaling vs. Process Scaling

A single daal4py process uses internal threading (TBB/OpenMP) to parallelize across available cores. Alternatively, you can run multiple independent OS-level processes, each pinned to a separate NUMA node with its own copy of the model and data. These approaches offer different tradeoffs.

Testing on a 4-NUMA-node Intel Xeon Platinum 8592+ (`airline-ohe` dataset, 200K rows, 24 features, 100 trees, `numactl --localalloc`) showed:

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

#### Hyper-threading can Hurt Performance

daal4py's AVX-512 vectorized tree traversal is [backend-bound](https://www.intel.com/content/www/us/en/docs/vtune-profiler/cookbook/2023-0/top-down-microarchitecture-analysis-method.html) — whether the bottleneck is core execution units or memory bandwidth, adding hyperthreads increases resource contention on the shared physical core, harming performance.

> **Cloud instance note:** On AWS and GCP, each vCPU does not necessarily map to a hyperthread. Smaller instance sizes use soft partitioning, so you may not know how many physical cores vs. hyperthreads you are getting. The guidance below applies most directly to bare-metal or dedicated-host instances where the physical topology is known. On shared instances, benchmark with your specific instance size to determine whether pinning provides a benefit.

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


