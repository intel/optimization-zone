# Computer Vision (CV): Inference with ResNet50 v1.5

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Install Required Packages](#install-required-packages)
- [Quick Start: Keras Mixed Precision](#quick-start-keras-mixed-precision)
- [Deploying with TensorFlow Serving (bfloat16 Auto Mixed Precision)](#deploying-with-tensorflow-serving-bfloat16-auto-mixed-precision)
  - [Export the Model (SavedModel, float32 weights)](#export-the-model-savedmodel-float32-weights)
  - [Pull TensorFlow Serving](#pull-tensorflow-serving)
  - [Start the Server (Enable bfloat16)](#start-the-server-enable-bfloat16)
- [Client Inference (REST)](#client-inference-rest)
- [Optional: Graph Freezing for Additional Performance](#optional-graph-freezing-for-additional-performance)
- [Key Validation Steps](#key-validation-steps)

## Overview

ResNet50 (Residual Network with 50 layers) is a convolutional neural network pretrained on ImageNet for image classification. This example shows how to run ResNet50 v1.5 (Keras built-in) for 1000-class image classification on Intel Xeon processors with AMX acceleration using `bfloat16` mixed precision.

## Prerequisites

- Intel Xeon 4th Gen (or newer) with AMX `bfloat16` support
- Python environment with `pip`
- Internet access to download model weights

## Install Required Packages

Pinned versions are shown below for reproducibility.

```bash
pip install tensorflow==2.21.0
```

## Quick Start: Keras Mixed Precision

To reuse the standard `float32` (pretrained) ResNet50 model while executing layers in `bfloat16` on AMX, enable a `mixed_bfloat16` policy BEFORE creating/loading the model. This keeps model weights in `float32` for stability while executing math (matmul, convolution, batch norm) in `bfloat16` on AMX-capable Intel Xeon processors. Note that this approach to enable auto-mixed precision can be used for any Keras model.

```python
import numpy as np
import tensorflow as tf
import keras

# 1. Enable AMX via bfloat16 Mixed Precision
# Set this BEFORE loading the model so all layers use bfloat16 compute with float32 weights.
keras.mixed_precision.set_global_policy("mixed_bfloat16")

# 2. Load pretrained ResNet50 (ImageNet weights, 1000 classes)
model = keras.applications.ResNet50(weights="imagenet")

# 3. Create a dummy input image (224x224x3, batch of 1)
# In production, use keras.utils.load_img() and keras.applications.resnet50.preprocess_input().
dummy_image = np.random.rand(1, 224, 224, 3).astype(np.float32)
preprocessed = keras.applications.resnet50.preprocess_input(dummy_image)

# 4. Run Inference
predictions = model(preprocessed, training=False)
logits = tf.cast(predictions, tf.float32)  # ensure float32 for downstream usage

top5 = tf.math.top_k(logits, k=5)
print("Top-5 class indices:", top5.indices.numpy())
print("Top-5 logits:", top5.values.numpy())
```

Notes:
- Set `ONEDNN_VERBOSE=1` to confirm AMX usage (look for `brg_matmul ... amx`).
- Revert to full `float32` by removing the policy or setting `mixed_precision` to `float32`.

## Deploying with TensorFlow Serving (`bfloat16` Auto Mixed Precision)

### Export the Model (`SavedModel`, `float32` weights)

> **Note:** We don't need to explicitly enable `bfloat16` mixed precision with Keras while exporting the model, because the `--mixed_precision=bfloat16` flag passed when starting the inference server handles that automatically (see [Start the Server (Enable `bfloat16`)](#start-the-server-enable-bfloat16) below).

Create `export_resnet50.py`:

```python
import numpy as np
import tensorflow as tf
import keras

model = keras.applications.ResNet50(weights="imagenet")

# Export the model in float32 format.
output_model_path = "/tmp/resnet50/1"
model.export(output_model_path)
print("Exported to:", output_model_path)
```

Run:

```bash
python export_resnet50.py
```

### Pull TensorFlow Serving

Pull the official TensorFlow Serving CPU image:

```bash
docker pull tensorflow/serving
```

Reference setup guide: https://github.com/tensorflow/serving?tab=readme-ov-file#set-up

### Start the Server (Enable `bfloat16`)

TensorFlow Serving (CPU) currently supports `bfloat16` mixed precision (`fp16` not yet enabled for CPU on TensorFlow Serving).

```bash
docker run -t --rm \
  -p 8501:8501 \
  -v /tmp/resnet50:/models/resnet50 \
  -e MODEL_NAME=resnet50 \
  -e ONEDNN_VERBOSE=1 \
  tensorflow/serving --mixed_precision=bfloat16
```

Sample log indicators:
- `auto_mixed_precision_onednn_bfloat16` graph optimizer
- `brg_matmul` with `amx` and `src_bf16` / `wei_bf16`

```bash
I0000 00:00:0000000000.000000     905 auto_mixed_precision.cc:2335] Running auto_mixed_precision_onednn_bfloat16 graph optimizer
I0000 00:00:0000000000.000000     905 auto_mixed_precision.cc:2263] Converted N/M nodes to bfloat16 precision using K cast(s) to bfloat16 (excluding Const and Variable casts)
```

Troubleshooting 403:
- Ensure the URL model name matches `MODEL_NAME`.
- Check container logs: `docker logs <id>`.
- Disable proxies: `export no_proxy=localhost,127.0.0.1`.

## Client Inference (REST)

Install:

```bash
pip install requests==2.33.1 numpy==2.4.4
```

Create `infer_resnet50.py`:

```python
import requests, json, numpy as np

# Create a dummy input image (224x224x3, batch of 1)
# In production, load a real image and convert to list.
dummy_image = np.random.rand(1, 224, 224, 3).astype(np.float32)

payload = {
  "instances": dummy_image.tolist()
}

resp = requests.post(
  "http://127.0.0.1:8501/v1/models/resnet50:predict",
  data=json.dumps(payload),
  headers={"content-type": "application/json"},
  proxies={"http": None, "https": None}
)

if resp.status_code == 200:
  preds = np.array(resp.json()["predictions"])
  top5_indices = np.argsort(preds[0])[-5:][::-1]
  top5_logits = preds[0][top5_indices]
  print("Inference successful!")
  print("Top-5 class indices:", top5_indices)
  print("Top-5 logits:", top5_logits)
else:
  print("Error:", resp.status_code, resp.text)
```

Run:

```bash
python infer_resnet50.py
```

**Expected Logs on the Server**

```bash
I0000 00:00:0000000000.000000    3797 auto_mixed_precision.cc:2335] Running auto_mixed_precision_onednn_bfloat16 graph optimizer
I0000 00:00:0000000000.000000    3797 auto_mixed_precision.cc:2263] Converted N/M nodes to bfloat16 precision using K cast(s) to bfloat16 (excluding Const and Variable casts)
```

**Expected Logs on the Client**

Top-5 class indices and logits for ImageNet classification (random input will give arbitrary results).

```
Inference successful!
Top-5 class indices: [916 530 851 644 664]
Top-5 logits: [0.05151367 0.046875   0.04541016 0.04272461 0.03881836]
```

## Optional: Graph Freezing for Additional Performance

Freeze variables to constants for a lean inference graph (removes variable-loading overhead).

**Script (public reference):**
https://raw.githubusercontent.com/oneapi-src/oneAPI-samples/master/AI-and-Analytics/Features-and-Functionality/IntelTensorFlow_InferenceOptimization/scripts/freeze_optimize_v2.py

**Example:**

```bash
python freeze_optimize.py \
  --input_saved_model_dir=/tmp/resnet50/1 \
  --output_saved_model_dir=/tmp/resnet50_frozen/1
```

Run this after exporting the `SavedModel` (server side).

## Key Validation Steps

- **Functional:** REST returns logits JSON with 1000 class scores
- **Precision:** Logs show `auto_mixed_precision_onednn_bfloat16`
- **AMX:** `ONEDNN_VERBOSE` lines include `amx` and `bf16` datatypes
- **Rollback:** Remove `--mixed_precision` flag on TF Serving; delete policy in Keras path

## Summary:

Enabled `bfloat16` mixed precision for ResNet50 on Xeon with minimal code change, deployed via TensorFlow Serving, verified AMX acceleration, and optionally optimized the model by freezing the graph.
