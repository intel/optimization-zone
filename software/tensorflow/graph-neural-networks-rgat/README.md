# Graph Neural Networks (GNN): Inference with RGAT using TF-GNN

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Install Required Packages](#install-required-packages)
- [Keras Version Compatibility](#keras-version-compatibility)
- [Quick Start: Keras Mixed Precision](#quick-start-keras-mixed-precision)
- [Deploying with TensorFlow Serving (bfloat16 Auto Mixed Precision)](#deploying-with-tensorflow-serving-bfloat16-auto-mixed-precision)
  - [Export the Model (SavedModel, float32 weights)](#export-the-model-savedmodel-float32-weights)
  - [Pull TensorFlow Serving](#pull-tensorflow-serving)
  - [Start the Server (Enable bfloat16)](#start-the-server-enable-bfloat16)
- [Client Inference (REST)](#client-inference-rest)
- [Key Validation Steps](#key-validation-steps)

## Overview

RGAT (Relational Graph Attention Network) leverages multi-head attention over typed edges to learn rich node representations on heterogeneous graphs, capturing the unique importance of different relationship types. This example shows how to run an RGAT-style model using TensorFlow GNN (TF-GNN) on Intel Xeon processors with AMX acceleration using `bfloat16` mixed precision.

## Prerequisites

- Intel Xeon 4th Gen (or newer) with AMX `bfloat16` support
- Docker (for TensorFlow Serving deployment)
- Python environment with `pip`
- Internet access to download model weights

## Install Required Packages

Pinned versions are shown below for reproducibility.

```bash
pip install tensorflow==2.21.0
pip install tf-keras==2.21.0 --no-deps
pip install tensorflow-gnn==1.0.3
```

### Keras Version Compatibility

`tensorflow_gnn` requires **Keras 2** (the legacy Keras API). TensorFlow 2.16+ ships with Keras 3 by default, which is **not compatible** with `tensorflow_gnn`. Before running any script, you must set the following environment variable to force TensorFlow to use the legacy Keras 2 backend:

```bash
export TF_USE_LEGACY_KERAS=1
```

## Quick Start: Keras Mixed Precision

To execute GNN layers in `bfloat16` on AMX, enable a `mixed_bfloat16` policy BEFORE creating the model. This keeps model weights in `float32` for numerical stability while executing math (`matmul`, attention, feed-forward) in `bfloat16` on AMX-capable Intel Xeon processors. Note that this approach to enable auto-mixed precision can be used for any Keras model, including graph neural networks built with TF-GNN.

```python
import os
# Ensure legacy Keras is being used (required by tensorflow_gnn)
os.environ["TF_USE_LEGACY_KERAS"] = "1"

import tensorflow as tf
import tensorflow_gnn as tfgnn
from tensorflow_gnn.models.gat_v2 import GATv2Conv
from tensorflow.keras import mixed_precision

# 1. Enable AMX via bfloat16 Mixed Precision
# Setting this BEFORE model creation keeps weights in float32 for stability
# while executing matmul, attention, and feed-forward ops in bfloat16 on AMX.
mixed_precision.set_global_policy("mixed_bfloat16")

# 2. Build a graph: 512 nodes, 2048 edges, 256-dim features
num_nodes = 512
num_edges = 2048
hidden_dim = 256

graph = tfgnn.GraphTensor.from_pieces(
    node_sets={
        "paper": tfgnn.NodeSet.from_fields(
            sizes=tf.constant([num_nodes]),
            features={tfgnn.HIDDEN_STATE: tf.random.normal([num_nodes, hidden_dim])}
        )
    },
    edge_sets={
        "cites": tfgnn.EdgeSet.from_fields(
            sizes=tf.constant([num_edges]),
            features={},
            adjacency=tfgnn.Adjacency.from_indices(
                source=("paper", tf.random.uniform([num_edges], 0, num_nodes, dtype=tf.int32)),
                target=("paper", tf.random.uniform([num_edges], 0, num_nodes, dtype=tf.int32))
            )
        )
    }
)

# 3. Define RGAT model (single GATv2Conv layer)
input_graph = tf.keras.layers.Input(type_spec=graph.spec)
output_graph = tfgnn.keras.layers.GraphUpdate(
    node_sets={
        "paper": tfgnn.keras.layers.NodeSetUpdate(
            edge_set_inputs={
                "cites": GATv2Conv(
                    num_heads=8,
                    per_head_channels=32,
                    receiver_tag=tfgnn.TARGET
                )
            },
            next_state=tfgnn.keras.layers.NextStateFromConcat(
                tf.keras.layers.Dense(hidden_dim)
            )
        )
    }
)(input_graph)
model = tf.keras.Model(input_graph, output_graph)

# 4. Run Inference
# In a real scenario, load trained weights here via model.load_weights().
output = model(graph)
result = tf.cast(output.node_sets["paper"][tfgnn.HIDDEN_STATE], tf.float32)

print("Output shape:", result.shape)
print("Compute dtype:", output.node_sets["paper"][tfgnn.HIDDEN_STATE].dtype)
print("Result dtype (cast):", result.dtype)
```

Notes:
- Set `ONEDNN_VERBOSE=1` to confirm AMX usage (look for `brg_matmul ... amx`).
- Revert to full `float32` by removing the policy or setting `mixed_precision` to `float32`.

## Deploying with TensorFlow Serving (`bfloat16` Auto Mixed Precision)

### Export the Model (`SavedModel`, `float32` weights)

TF-GNN models consume `GraphTensor` (a composite tensor). To export a usable `SavedModel` for TF Serving, define a `tf.function` signature that accepts flat tensors and reassembles the graph internally.

> **Note:** We don't need to explicitly enable `bfloat16` mixed precision with Keras while exporting the model, because the `--mixed_precision=bfloat16` flag passed when starting the inference server handles that automatically (see [Start the Server (Enable `bfloat16`)](#start-the-server-enable-bfloat16) below).

Create `export_rgat.py`:

```python
import os
# Ensure legacy Keras is being used (required by tensorflow_gnn)
os.environ["TF_USE_LEGACY_KERAS"] = "1"

import tensorflow as tf
import tensorflow_gnn as tfgnn
from tensorflow_gnn.models.gat_v2 import GATv2Conv
from tensorflow.keras import mixed_precision

# Build a sample graph to derive the spec
num_nodes = 512
num_edges = 2048
hidden_dim = 256

sample_graph = tfgnn.GraphTensor.from_pieces(
    node_sets={
        "paper": tfgnn.NodeSet.from_fields(
            sizes=tf.constant([num_nodes]),
            features={tfgnn.HIDDEN_STATE: tf.random.normal([num_nodes, hidden_dim])}
        )
    },
    edge_sets={
        "cites": tfgnn.EdgeSet.from_fields(
            sizes=tf.constant([num_edges]),
            features={},
            adjacency=tfgnn.Adjacency.from_indices(
                source=("paper", tf.random.uniform([num_edges], 0, num_nodes, dtype=tf.int32)),
                target=("paper", tf.random.uniform([num_edges], 0, num_nodes, dtype=tf.int32))
            )
        )
    }
)

# Define the RGAT model
input_graph = tf.keras.layers.Input(type_spec=sample_graph.spec)
output_graph = tfgnn.keras.layers.GraphUpdate(
    node_sets={
        "paper": tfgnn.keras.layers.NodeSetUpdate(
            edge_set_inputs={
                "cites": GATv2Conv(
                    num_heads=8,
                    per_head_channels=32,
                    receiver_tag=tfgnn.TARGET
                )
            },
            next_state=tfgnn.keras.layers.NextStateFromConcat(
                tf.keras.layers.Dense(hidden_dim)
            )
        )
    }
)(input_graph)
model = tf.keras.Model(input_graph, output_graph)

# Define a flat-tensor serving signature
# TF-GNN models consume GraphTensor (a composite tensor). This serving function
# accepts plain tensors and reassembles the GraphTensor internally.
@tf.function(input_signature=[
    tf.TensorSpec([None, 256], tf.float32, name="paper_features"),
    tf.TensorSpec([None], tf.int32, name="cites_source"),
    tf.TensorSpec([None], tf.int32, name="cites_target"),
])
def serving_fn(paper_features, cites_source, cites_target):
    num_nodes = tf.shape(paper_features)[0]
    num_edges = tf.shape(cites_source)[0]
    g = tfgnn.GraphTensor.from_pieces(
        node_sets={
            "paper": tfgnn.NodeSet.from_fields(
                sizes=tf.expand_dims(num_nodes, axis=0),
                features={tfgnn.HIDDEN_STATE: paper_features}
            )
        },
        edge_sets={
            "cites": tfgnn.EdgeSet.from_fields(
                sizes=tf.expand_dims(num_edges, axis=0),
                features={},
                adjacency=tfgnn.Adjacency.from_indices(
                    source=("paper", cites_source),
                    target=("paper", cites_target)
                )
            )
        }
    )
    out = model(g)
    logits = tf.cast(out.node_sets["paper"][tfgnn.HIDDEN_STATE], tf.float32)
    return {"logits": logits}

# Export as versioned SavedModel (version subdirectory required by TF Serving)
output_model_path = "/tmp/rgat_model/1"
tf.saved_model.save(model, output_model_path, signatures={"serving_default": serving_fn})
print("Exported to:", output_model_path)
```

Run:

```bash
python export_rgat.py
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
  -v /tmp/rgat_model:/models/rgat_model \
  -e MODEL_NAME=rgat_model \
  -e ONEDNN_VERBOSE=1 \
  tensorflow/serving --mixed_precision=bfloat16
```

Sample log indicators:
- `auto_mixed_precision_onednn_bfloat16` graph optimizer
- `brg_matmul` with `amx` and `src_bf16` / `wei_bf16`

```bash
I0000 00:00:0000000000.000000     100 auto_mixed_precision.cc:2335] Running auto_mixed_precision_onednn_bfloat16 graph optimizer
I0000 00:00:0000000000.000000     100 auto_mixed_precision.cc:2263] Converted N/M nodes to bfloat16 precision using K cast(s) to bfloat16 (excluding Const and Variable casts)
```

Troubleshooting 403:
- Ensure URL model name matches `MODEL_NAME`.
- Check container logs: `docker logs <id>`.
- Disable proxies: `export no_proxy=localhost,127.0.0.1`.

## Client Inference (REST)

Install:

```bash
pip install requests==2.33.1 numpy==2.4.4
```

Create `infer_rgat.py`:

```python
import requests, json, numpy as np

num_nodes, num_edges, hidden_dim = 4, 5, 256

payload = {
    "inputs": {
        "paper_features": np.random.randn(num_nodes, hidden_dim).tolist(),
        "cites_source": [0, 1, 2, 3, 0],
        "cites_target": [1, 2, 3, 0, 2]
    }
}

resp = requests.post(
    "http://127.0.0.1:8501/v1/models/rgat_model:predict",
    data=json.dumps(payload),
    headers={"content-type": "application/json"},
    proxies={"http": None, "https": None}
)

if resp.status_code == 200:
    preds = np.array(resp.json()["outputs"])
    print("Inference successful!")
    print("Output shape:", preds.shape)
    print("First node logits:", preds[0][:5], "...")
else:
    print("Error:", resp.status_code, resp.text)
```

Run:

```bash
python infer_rgat.py
```

**Expected Logs on the Server**

```bash
I0000 00:00:0000000000.000000    100 auto_mixed_precision.cc:2335] Running auto_mixed_precision_onednn_bfloat16 graph optimizer
I0000 00:00:0000000000.000000    100 auto_mixed_precision.cc:2263] Converted N/M nodes to bfloat16 precision using K cast(s) to bfloat16 (excluding Const and Variable casts)
```

**Expected Logs on the Client**

Output logits for each node (untrained weights will give random results).

```
Inference successful!
Output shape: (4, 256)
First node logits: [0.625      2.625      0.49414062 0.9453125  0.18359375] ...
```

## Key Validation Steps

- **Functional:** REST returns logits JSON for each node
- **Precision:** Logs show `auto_mixed_precision_onednn_bfloat16`
- **AMX:** `ONEDNN_VERBOSE` lines include `amx` and `bf16` datatypes
- **Rollback:** Remove `--mixed_precision` flag; delete policy in Keras path

## Summary

Enabled `bfloat16` mixed precision for an RGAT model on Xeon with minimal code change using TF-GNN's `GATv2Conv`, deployed via TensorFlow Serving, and verified AMX acceleration.
