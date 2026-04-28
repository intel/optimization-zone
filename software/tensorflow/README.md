# Quick Start: AMX with TensorFlow

Follow these steps to set up TensorFlow with Intel AMX acceleration (BF16 / FP16).

## 1. (Recommended) Create and activate a virtual environment
```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
```

## 2. Install TensorFlow
```bash
pip install --upgrade tensorflow
```
For platform-specific guidance, see: https://www.tensorflow.org/install

## 3. Verify the installation
```bash
python -c "import tensorflow as tf; print(tf.reduce_sum(tf.random.normal([1000, 1000])))"
```

---


# Sample: Matrix Multiplication with AMX

The example below benchmarks BF16 matrix multiplication.

Notes:
- BF16 mixed precision: broadly supported on AMX‑enabled Intel CPUs.
- FP16 mixed precision: supported only on Intel® Xeon® 6 processors.

```python
import os
import time
import tensorflow as tf

# (Optional) Verbose oneDNN logging for verification
# os.environ["ONEDNN_VERBOSE"] = "1"

# Configuration (adjust as needed)
BATCH_SIZE = 32
INPUT_FEATURES = 4096
HIDDEN_FEATURES = 4096
NUM_ITERATIONS = 10

# Initialize random tensors (BF16)
A = tf.random.uniform([BATCH_SIZE, INPUT_FEATURES], dtype=tf.bfloat16)
B = tf.random.uniform([INPUT_FEATURES, HIDDEN_FEATURES], dtype=tf.bfloat16)

# Benchmark loop
total_time = 0.0
for i in range(NUM_ITERATIONS):
  start = time.time()
  C = tf.matmul(A, B)  # utilizes AMX via oneDNN optimized kernels
  elapsed = time.time() - start
  total_time += elapsed
  print(f"Iteration {i+1}: {elapsed:.6f} seconds")

print(f"Average execution time: {total_time / NUM_ITERATIONS:.6f} seconds")
```

---

## Verifying AMX Utilization

Enable oneDNN verbose output before running the script:

```bash
export ONEDNN_VERBOSE=1
python your_script.py
```

Or set inside the script:
```python
os.environ["ONEDNN_VERBOSE"] = "1"
```

Look for lines indicating AMX usage (example excerpt):
```
onednn_verbose,v1,info,oneDNN v3.7.3 (commit N/A)
onednn_verbose,v1,info,cpu,isa:Intel AVX-512 with float16, Intel DL Boost and bfloat16 support and Intel AMX with bfloat16 and 8-bit integer support
onednn_verbose,v1,primitive,exec,cpu,matmul,brg_matmul:avx10_1_512_amx,...
Iteration 1: 0.012289 seconds
...
Average execution time: 0.001941 seconds
```

Key indicator: **`brg_matmul:avx10_1_512_amx`** (or similar) confirming AMX-backed BF16 matmul.

---

## Troubleshooting

- Missing AMX indicators: Ensure CPU supports AMX and kernel/OS has AMX enabled (XSAVE/XFD configured).
- Slow first iteration: Expected due to cache warmup.
- To test FP16 (Xeon 6 onwards): Replace `tf.bfloat16` dtypes with `tf.float16`.

This completes the setup and verification workflow.

---

# Leveraging AMX for different AI Use-Cases

For guidance on how to enable AMX for different AI use-cases, follow the links below:

| Use Case | Model | Description | README |
|----------|-------|-------------|--------|
| Natural Language Processing | BERT-Large (Uncased) | Sequence classification | [Link](./nlp-transformers-bert/README.md) |
| Graph Neural Networks | R-GAT | Relational graph attention network inference | [Link](./graph-neural-networks-rgat/README.md) |
| Computer Vision | ResNet50 v1.5 | Image classification (CNN) | [Link](./computer-vision-resnet50/README.md) |
