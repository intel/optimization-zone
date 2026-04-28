# Natural Language Processing (NLP): Inference with BERT-Large (Uncased)

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

BERT (Bidirectional Encoder Representations from Transformers) is a transformer model pretrained on large English text corpora using self-supervised objectives. This example shows how to run BERT-Large (uncased, Hugging Face) for sequence (binary) classification on Intel Xeon processors with AMX acceleration using bfloat16 (BF16) mixed precision.

## Prerequisites

- Intel Xeon 4th Gen (or newer) with AMX BF16 support
- Python environment with pip
- Internet access to download model weights

## Install Required Packages

Pinned versions are shown below for reproducibility.

```bash
pip install tensorflow==2.20.0
pip install tf-keras==2.20.1 --no-deps
pip install transformers==4.49.0
```

## Quick Start: Keras Mixed Precision

To reuse the standard FP32 (pretrained) BERT-Large model while executing layers in BF16 on AMX, enable a `mixed_bfloat16` policy BEFORE creating/loading the model. This keeps model weights in FP32 for stability while executing math (matmul, attention, feed‑forward) in BF16 on AMX-capable Intel Xeon processors. Note that this approach to enable auto-mixed precision can be used for any Keras model.

```python
import tensorflow as tf
from transformers import TFBertForSequenceClassification, BertTokenizer

tf.keras.mixed_precision.set_global_policy("mixed_bfloat16")

model_name = "bert-large-uncased"
tokenizer = BertTokenizer.from_pretrained(model_name)
model = TFBertForSequenceClassification.from_pretrained(model_name, num_labels=2)

text = "This is a great movie!"
inputs = tokenizer(text, return_tensors="tf", padding=True, truncation=True)

outputs = model(
    inputs["input_ids"],
    attention_mask=inputs["attention_mask"],
    training=False
)

logits = tf.cast(outputs.logits, tf.float32)  # ensure float32 for downstream usage
pred = tf.argmax(logits, axis=-1)

print("Logits:", logits.numpy())
print("Predicted class:", pred.numpy())
```

Notes:
- Set `ONEDNN_VERBOSE=1` to confirm AMX usage (look for `brg_matmul ... amx`).
- Revert to full FP32 by removing the policy or setting mixed_precision to float32.

## Deploying with TensorFlow Serving (BF16 Auto Mixed Precision)

### Export the Model (SavedModel, FP32 weights)

> **Note:** We don't need to explicitly enable `bfloat16` mixed precision with Keras while exporting the model, because the `--mixed_precision=bfloat16` flag passed when starting the inference server handles that automatically (see [Start the Server (Enable bfloat16)](#start-the-server-enable-bfloat16) below).

Create `export_bert_large.py`:

```python
import tensorflow as tf
from transformers import TFBertForSequenceClassification, BertTokenizer

model_name = "bert-large-uncased"
tokenizer = BertTokenizer.from_pretrained(model_name)
model = TFBertForSequenceClassification.from_pretrained(model_name, num_labels=2)

@tf.function(input_signature=[
    tf.TensorSpec([None, None], tf.int32, name="input_ids"),
    tf.TensorSpec([None, None], tf.int32, name="attention_mask")
])
def serving_fn(input_ids, attention_mask):
    out = model(input_ids, attention_mask=attention_mask, training=False)
    logits = tf.cast(out.logits, tf.float32)
    return {"logits": tf.identity(logits, name="float32_output")}

output_model_path = "/tmp/bert_large_hf/1"  # versioned directory
model.save(output_model_path, include_optimizer=False, signatures={"serving_default": serving_fn})
print("Exported to:", output_model_path)
```

Run:

```bash
python export_bert_large.py
```

### Pull TensorFlow Serving

Pull the official TensorFlow Serving CPU image:

```bash
docker pull tensorflow/serving
```

Reference setup guide: https://github.com/tensorflow/serving?tab=readme-ov-file#set-up

### Start the Server (Enable BF16)

TensorFlow Serving (CPU) currently supports bfloat16 mixed precision (fp16 not yet enabled for CPU).

```bash
docker run -t --rm \
  -p 8501:8501 \
  -v /tmp/bert_large_hf:/models/bert_large_hf \
  -e MODEL_NAME=bert_large_hf \
  -e ONEDNN_VERBOSE=1 \
  tensorflow/serving --mixed_precision=bfloat16
```

Sample log indicators:
- `auto_mixed_precision_onednn_bfloat16` graph optimizer
- `brg_matmul` with `amx` and `src_bf16` / `wei_bf16`

```bash
2025-09-24 22:45:48.953387: I external/org_tensorflow/tensorflow/cc/saved_model/loader.cc:220] Running initialization op on SavedModel bundle at path: /models/bert_large_hf/1
I0000 00:00:1758753949.448357     905 auto_mixed_precision.cc:2335] Running auto_mixed_precision_onednn_bfloat16 graph optimizer
I0000 00:00:1758753949.450298     905 auto_mixed_precision.cc:1511] No allowlist ops found, nothing to do
2025-09-24 22:45:49.465449: I external/org_tensorflow/tensorflow/cc/saved_model/loader.cc:471] SavedModel load for tags { serve }; Status: success: OK. Took 3153824 microseconds.
2025-09-24 22:45:50.229979: I tensorflow_serving/model_servers/server.cc:428] Running gRPC ModelServer at 0.0.0.0:8500 ...
2025-09-24 22:45:50.292271: I tensorflow_serving/model_servers/server.cc:449] Exporting HTTP/REST API at:localhost:8501 ...
```

Troubleshooting 403:
- Ensure URL model name matches MODEL_NAME.
- Check container logs: docker logs <id>.
- Disable proxies: export no_proxy=localhost,127.0.0.1.

## Client Inference (REST)

Install:

```bash
pip install requests==2.32.5 numpy==2.3.3 transformers==4.49.0 tensorflow==2.20.0
pip install tf-keras==2.20.1 --no-deps
```

Create `infer_bert_large.py`:

```python
import requests, json, numpy as np, tensorflow as tf
from transformers import BertTokenizer

tokenizer = BertTokenizer.from_pretrained("bert-large-uncased")
text = "I love this product!"
inputs = tokenizer(
    text,
    return_tensors="tf",
    max_length=128,
    padding="max_length",
    truncation=True
)

payload = {
    "instances": [{
        "input_ids": inputs["input_ids"][0].numpy().tolist(),
        "attention_mask": inputs["attention_mask"][0].numpy().tolist()
    }]
}

resp = requests.post(
    "http://127.0.0.1:8501/v1/models/bert_large_hf:predict",
    data=json.dumps(payload),
    headers={"content-type": "application/json"},
    proxies={"http": None, "https": None}
)

if resp.status_code == 200:
    preds = np.array(resp.json()["predictions"])
    print("Inference successful")
    logits = preds[0]
    probs = tf.nn.softmax(logits).numpy()
    print("Logits:", logits)
    print("Probabilities:", probs)
else:
    print("Error:", resp.text)
```

Run:

```bash
python infer_bert_large.py
```

**Expected Logs on the Server**

```bash
I0000 00:00:1758754431.951130    3797 auto_mixed_precision.cc:2335] Running auto_mixed_precision_onednn_bfloat16 graph optimizer
I0000 00:00:1758754431.978969    3797 auto_mixed_precision.cc:2263] Converted 1837/4155 nodes to bfloat16 precision using 2 cast(s) to bfloat16 (excluding Const and Variable casts)
```

**Expected Logs on the Client**

Logits and probabilities for binary classification (untrained weights will give random results):

## Optional: Graph Freezing for Additional Performance

Freeze variables to constants for a lean inference graph (removes variable-loading overhead).

**Script (public reference):**
https://raw.githubusercontent.com/oneapi-src/oneAPI-samples/master/AI-and-Analytics/Features-and-Functionality/IntelTensorFlow_InferenceOptimization/scripts/freeze_optimize_v2.py

**Example:**

```bash
python freeze_optimize.py \
  --input_saved_model_dir=/tmp/bert_large_hf/1 \
  --output_saved_model_dir=/tmp/bert_large_hf_frozen/1
```

Run this after exporting the `SavedModel` (server side).

## Key Validation Steps

- **Functional:** REST returns logits JSON
- **Precision:** Logs show `auto_mixed_precision_onednn_bfloat16`
- **AMX:** `ONEDNN_VERBOSE` lines include `amx` and `bf16` datatypes
- **Rollback:** Remove `--mixed_precision` flag; delete policy in Keras path

## Summary

Enabled BF16 mixed precision on Xeon with minimal code change, deployed via TensorFlow Serving, verified AMX acceleration, and optionally optimized the model by freezing the graph.
