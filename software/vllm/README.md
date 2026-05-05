# vLLM on Intel Xeon with Intel AMX

This recipe shows how to configure vLLM for CPU inference and serving on Intel Xeon processors with Intel Advanced Matrix Extensions (Intel AMX). It focuses on the practical settings that most affect performance: BF16 execution, CPU thread binding, NUMA placement, KV cache sizing, batch limits, and model selection.

The goal is not to replace the vLLM documentation. Use the official vLLM CPU installation guide for package-specific setup details, then use this recipe to choose a high-performance Intel Xeon configuration.

## Table of Contents

- [vLLM on Intel Xeon with Intel AMX](#vllm-on-intel-xeon-with-intel-amx)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Recommended Baseline](#recommended-baseline)
  - [Why Intel Xeon for vLLM](#why-intel-xeon-for-vllm)
  - [Prerequisites](#prerequisites)
    - [Docker Quick Start](#docker-quick-start)
  - [Quick Start](#quick-start)
  - [AMX and BF16 Configuration](#amx-and-bf16-configuration)
  - [CPU Threading and NUMA](#cpu-threading-and-numa)
    - [Default Recommendation](#default-recommendation)
    - [Manual Binding Example](#manual-binding-example)
    - [NUMA Checklist](#numa-checklist)
  - [KV Cache and Memory Sizing](#kv-cache-and-memory-sizing)
  - [Xeon 6 for SLM Inference](#xeon-6-for-slm-inference)
  - [Large Models on Xeon Memory Capacity](#large-models-on-xeon-memory-capacity)
  - [Tuning Reference](#tuning-reference)
  - [Validation and Benchmarking](#validation-and-benchmarking)
    - [Functional Validation](#functional-validation)
    - [Placement Validation](#placement-validation)
    - [Benchmark Sweep](#benchmark-sweep)
    - [Example Benchmark Command](#example-benchmark-command)
  - [Troubleshooting](#troubleshooting)
  - [FAQ](#faq)
    - [What is the minimum vLLM version for Intel Xeon AMX deployments?](#what-is-the-minimum-vllm-version-for-intel-xeon-amx-deployments)
    - [Should I use BF16 or FP16 on CPU?](#should-i-use-bf16-or-fp16-on-cpu)
    - [How much KV cache should I allocate?](#how-much-kv-cache-should-i-allocate)
    - [Should tensor parallel size always equal socket count?](#should-tensor-parallel-size-always-equal-socket-count)
    - [When should I use quantization?](#when-should-i-use-quantization)
  - [Disclaimer](#disclaimer)
  - [References](#references)

## Overview

vLLM supports model inferencing and OpenAI-compatible serving on x86 CPUs with FP32, FP16, and BF16. On Intel Xeon processors that expose Intel AMX BF16 instructions, BF16 is the preferred dtype because it reduces memory traffic and enables matrix kernels designed for modern Xeon CPUs.

Use this recipe when you want to:

- Serve small language models (SLMs) without a discrete accelerator.
- Host models or context lengths that benefit from the larger DRAM capacity available on CPU servers.
- Run inference close to CPU-resident data pipelines, vector databases, or enterprise services.
- Tune vLLM CPU deployments beyond a default install.

## Recommended Baseline

| Item | Recommendation |
| --- | --- |
| vLLM version | Use vLLM `0.17.0` or newer as the minimum packaged x86 CPU baseline. vLLM CPU release wheels for x86 with AVX512/AVX2 are available starting with `0.17.0`; prefer the latest stable release for the newest CPU and AMX kernel work. |
| CPU | Intel Xeon 6 recommended as of May 2026. Intel Xeon 4th Gen or newer with `amx_tile` and `amx_bf16` CPU flags.  |
| dtype | Use `--dtype=bfloat16` for AMX-capable Xeon systems. |
| OS | Linux. |
| Python | Python 3.10 through 3.13, following the vLLM CPU installation guide. |
| Threading | Start with `VLLM_CPU_OMP_THREADS_BIND=auto` and reserve 1-2 CPU cores for the serving process. |
| Parallelism | On multi-socket systems, start with tensor parallel size equal to the number of NUMA nodes, except values that the current vLLM release does not support. |
| Memory | Size `VLLM_CPU_KVCACHE_SPACE` per NUMA node so model weight shards, KV cache, runtime workspace, and OS headroom all fit in local memory. |


## Why Intel Xeon for vLLM

Intel Xeon is a strong fit for vLLM CPU deployments when memory capacity, deployment simplicity, and CPU locality matter as much as peak accelerator throughput.

| Use case | Why Xeon helps | Tuning priority |
| --- | --- | --- |
| SLM serving | 1B-8B parameter models can be served with BF16 on AMX-capable Xeon systems, often with enough memory left for a larger KV cache and co-located application services. | BF16, thread binding, small batch limits, reserved serving cores. |
| Large model capacity | CPU servers can be configured with hundreds of GiB to TiB-class DRAM, which can hold models, quantized weights, or long-context KV caches that may not fit in a single GPU's HBM. | NUMA-aware sharding, KV cache sizing, quantization, memory headroom. |
| Enterprise integration | CPU inference can run close to existing data services, retrieval pipelines, security controls, and orchestration tools. | Stable packaging, deterministic placement, observability, repeatable benchmarks. |
| Throughput-oriented batch jobs | Offline inference can trade latency for throughput by increasing batch limits and using more sockets or NUMA nodes. | `--max-num-batched-tokens`, `--max-num-seqs`, DP/TP/PP, KV cache. |

## Prerequisites

Verify the platform before tuning vLLM.

```bash
lscpu | grep -E "Model name|Socket|Core|Thread|NUMA node|Flags"
lscpu | grep -E "amx_(tile|bf16|int8)|avx512_bf16"
numactl --hardware
```

Expected CPU flags for the AMX BF16 path include:

- `amx_tile`
- `amx_bf16`
- `avx512_bf16`
- `amx_int8`

Install vLLM by following the official CPU installation guide. For release-wheel deployments, use vLLM `0.17.0` or newer and install the CPU wheel variant.


For wheel-based installs, TCMalloc and Intel OpenMP must be preloaded before running vLLM:

```bash
# Install TCMalloc (Intel OpenMP is bundled with the vLLM CPU wheel)
sudo apt-get install -y --no-install-recommends libtcmalloc-minimal4

# Locate the libraries
TC_PATH=$(find /usr -name 'libtcmalloc_minimal.so.4' | head -1)
IOMP_PATH=$(python -c "import intel_openmp, os; print(os.path.join(os.path.dirname(intel_openmp.__file__), 'lib', 'libiomp5.so'))" 2>/dev/null \
  || find / -name 'libiomp5.so' 2>/dev/null | head -1)

# Preload them for every vLLM session
export LD_PRELOAD="${TC_PATH}:${IOMP_PATH}:${LD_PRELOAD}"
```

Skipping `LD_PRELOAD` can silently degrade throughput. Add the export to your shell profile or container entrypoint.

After installation, collect the runtime environment:

```bash
vllm collect-env
```

If PyTorch exposes the AMX helper in your environment, this quick check can confirm that the runtime sees AMX tile support:

```bash
python - <<'PY'
import torch

checker = getattr(torch.cpu, "_is_amx_tile_supported", None)
print("AMX tile supported:", checker() if checker else "not reported by this PyTorch build")
PY
```

### Docker Quick Start

vLLM publishes pre-built CPU Docker images. Pull the latest x86_64 CPU image:

```bash
docker pull vllm/vllm-openai-cpu:latest-x86_64
```

Then run it with the environment variables from above:

```bash
docker run --rm \
  --security-opt seccomp=unconfined \
  --cap-add SYS_NICE \
  --shm-size=4g \
  -p 8000:8000 \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  -e VLLM_CPU_KVCACHE_SPACE=20 \
  -e HF_TOKEN="${HF_TOKEN}" \
  vllm/vllm-openai-cpu:latest-x86_64 \
  Qwen/Qwen3-4B \
  --dtype=bfloat16 \
  --max-num-batched-tokens 2048 \
  --max-num-seqs 64
```

Note: `--security-opt seccomp=unconfined` and `--cap-add SYS_NICE` are needed for NUMA memory policy calls inside the container. Omitting them may produce `get_mempolicy: Operation not permitted` warnings.

## Quick Start

Start with a CPU-validated SLM, BF16, automatic NUMA-aware thread binding, and a conservative KV cache size. Increase memory and batch settings only after the baseline is stable.

```bash
export VLLM_CPU_KVCACHE_SPACE=20
export VLLM_CPU_OMP_THREADS_BIND=auto
export VLLM_CPU_NUM_OF_RESERVED_CPU=1

vllm serve Qwen/Qwen3-4B \
  --device cpu \
  --dtype=bfloat16 \
  --max-num-batched-tokens 2048 \
  --max-num-seqs 64
```

Send a test request:

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-4B",
    "messages": [{"role": "user", "content": "Give three tips for CPU inference tuning."}],
    "max_tokens": 128
  }'
```

For a multi-NUMA system, start by matching tensor parallel size to the NUMA node count:

```bash
NUMA_NODES=$(lscpu | awk '/NUMA node\(s\):/ {print $3}')

export VLLM_CPU_KVCACHE_SPACE=40
export VLLM_CPU_OMP_THREADS_BIND=auto
export VLLM_CPU_NUM_OF_RESERVED_CPU=1

vllm serve meta-llama/Llama-3.1-8B-Instruct \
  --device cpu \
  --dtype=bfloat16 \
  --tensor-parallel-size "${NUMA_NODES}" \
  --max-num-batched-tokens $((2048 * NUMA_NODES)) \
  --max-num-seqs $((128 * NUMA_NODES))
```

Before using a generated `NUMA_NODES` value, check the vLLM CPU documentation for currently unsupported tensor parallel sizes. For example, the current CPU guide notes that `tensor-parallel-size=6` is not supported.


## AMX and BF16 Configuration

For AMX-capable Intel Xeon CPUs, the most important vLLM decision is to use BF16 explicitly:

```bash
vllm serve <model> --device cpu --dtype=bfloat16
```

Why this matters:

- BF16 is the recommended CPU dtype when FP16 behavior is unstable or slower on CPU.
- BF16 reduces memory traffic compared with FP32.
- AMX BF16 kernels accelerate matrix-heavy LLM operations when the CPU, PyTorch, and vLLM CPU backend can use them.

Optional small-batch kernel path:

```bash
export VLLM_CPU_SGL_KERNEL=1
```

Use `VLLM_CPU_SGL_KERNEL=1` only after the baseline works. It is x86-only and experimental. The vLLM CPU guide states that it requires AMX, BF16 weights, and weight shapes divisible by 32. It is aimed at low-latency online serving with small batches, so validate it per model and workload before using it in production.

## CPU Threading and NUMA

The CPU backend is sensitive to where OpenMP threads run and where memory is allocated. Start with automatic binding, then move to manual binding if utilization or latency is uneven.

### Default Recommendation

```bash
export VLLM_CPU_OMP_THREADS_BIND=auto
export VLLM_CPU_NUM_OF_RESERVED_CPU=1
```

`auto` binds OpenMP threads for each rank to CPU cores in NUMA nodes. Reserving one or two cores prevents the vLLM API server, tokenizer work, networking, logging, and operating system tasks from competing with inference threads.

### Manual Binding Example

Use manual binding when you need repeatability or when `htop` shows threads crossing NUMA nodes unexpectedly.

```bash
export VLLM_CPU_OMP_THREADS_BIND=0-55|56-111
export VLLM_CPU_KVCACHE_SPACE=40

vllm serve <model> \
  --device cpu \
  --dtype=bfloat16 \
  --tensor-parallel-size 2
```

In this example, rank 0 uses CPU cores `0-55` and rank 1 uses CPU cores `56-111`. Adjust the ranges to physical cores from the same NUMA node. Avoid spreading a single rank across sockets unless you have measured that it helps your workload.

### NUMA Checklist

- Use `numactl --hardware` to identify NUMA nodes and memory per node.
- Keep each tensor-parallel or pipeline-parallel rank within one NUMA node when possible.
- Use `CPU_VISIBLE_MEMORY_NODES` to mask or reorder NUMA memory nodes when using automatic binding.
- Watch CPU placement with `htop` or `perf stat` during warmup and benchmark runs.

## KV Cache and Memory Sizing

`VLLM_CPU_KVCACHE_SPACE` is specified in GiB and applies to each CPU worker/rank. Larger values allow more concurrent requests and longer contexts, but the allocation must fit in the local memory budget for each NUMA node.

Use this sizing rule for each rank:

```text
local NUMA memory > model weight shard + VLLM_CPU_KVCACHE_SPACE + runtime workspace + OS headroom
```

Estimate BF16 model weight memory as:

```text
weight shard GiB ~= model parameters * 2 bytes / tensor_parallel_size / 2^30
```

Then leave headroom for activation buffers, tokenizer/server processes, page cache, framework overhead, and other colocated services. A practical starting point is to reserve at least 10-20% of each NUMA node's memory instead of assigning all free memory to KV cache.

Examples:

| Scenario | Starting point | Why |
| --- | --- | --- |
| SLM, low concurrency | `VLLM_CPU_KVCACHE_SPACE=10` to `20` | Keeps memory pressure low while validating BF16 and thread placement. |
| SLM, higher concurrency | `VLLM_CPU_KVCACHE_SPACE=20` to `40` | Supports more simultaneous sessions and longer prompts. |
| 8B-class model on a large-memory node | `VLLM_CPU_KVCACHE_SPACE=40` or higher | Uses Xeon DRAM capacity for larger batches or context lengths. |
| Multi-NUMA tensor parallel | Size per NUMA node | Each rank needs local memory for its weight shard plus its KV cache. |

If the worker exits with code 9 or the process is killed by the OOM killer, reduce `VLLM_CPU_KVCACHE_SPACE`, reduce batch limits, lower tensor-parallel pressure per node, or use a smaller/quantized model.

## Xeon 6 for SLM Inference

Intel Xeon 6 systems that expose AMX BF16 are well suited for SLM inference because the models are small enough to keep memory pressure manageable while AMX accelerates BF16 matrix operations.

Good first models from the vLLM CPU-validated model list include:

| Model | Typical use | Why start here |
| --- | --- | --- |
| `Qwen/Qwen3-1.7B` | Very small assistant, routing, classification-style generation | Fast baseline for validating install, BF16, and thread binding. |
| `ibm-granite/granite-3.2-2b-instruct` | Enterprise assistant, summarization, RAG | Small enough for CPU serving experiments with room for KV cache. |
| `meta-llama/Llama-3.2-3B-Instruct` | General chat and instruction following | Common SLM shape with broad ecosystem support. |
| `Qwen/Qwen3-4B` | Higher quality SLM serving | Good step up after the 1B-3B baseline is stable. |
| `Qwen/Qwen3-8B` or `meta-llama/Llama-3.1-8B-Instruct` | Larger SLM or compact LLM serving | Useful for multi-NUMA tuning and memory-capacity validation. |

For latency-sensitive SLM serving on Xeon 6:

1. Use `--dtype=bfloat16`.
2. Start with `--max-num-seqs 32` to `64` and `--max-num-batched-tokens 1024` to `2048`.
3. Reserve one or two CPU cores per rank for serving overhead.
4. Validate the optional `VLLM_CPU_SGL_KERNEL=1` path only after the default path is stable.
5. Increase batch limits gradually while watching inter-token latency, time to first token, and CPU utilization.

## Large Models on Xeon Memory Capacity

Many GPU deployments are constrained by the memory capacity of a single accelerator. Intel Xeon servers can be configured with substantially larger system memory, which can be useful when the model, KV cache, or context length does not fit comfortably in accelerator memory.

This does not make CPU inference universally faster than GPU inference. It changes the design space:

- Use Xeon when capacity, cost, data locality, or CPU-only deployment constraints dominate.
- Use quantization to reduce model memory and memory bandwidth pressure.
- Use tensor parallelism across NUMA nodes when a model shard plus KV cache fits cleanly per node.
- Prefer smaller batch sizes for interactive latency and larger batch sizes for offline throughput.
- Avoid filling all DRAM with weights and KV cache; memory headroom is what keeps tail latency stable.

For very large models, benchmark both BF16 and quantized variants. A quantized model may reduce memory traffic enough to improve throughput, but accuracy, prompt behavior, and supported kernels must be validated for your model.

## Tuning Reference

| Setting | What it controls | Starting point | Tune when |
| --- | --- | --- | --- |
| `--dtype=bfloat16` | Model compute dtype | Always use on AMX-capable Xeon unless a model requires otherwise. | Accuracy or compatibility issues appear. |
| `VLLM_CPU_KVCACHE_SPACE` | KV cache memory per CPU worker/rank, in GiB | `20` for SLMs; `40` or higher for larger models or concurrency. | You see preemption, OOM, low concurrency, or long-context failures. |
| `VLLM_CPU_OMP_THREADS_BIND` | OpenMP thread placement | `auto` | CPU utilization is uneven or threads cross NUMA nodes. |
| `VLLM_CPU_NUM_OF_RESERVED_CPU` | Cores reserved from OpenMP binding | `1` for small systems, `1-2` for serving workloads. | API server latency rises or CPU oversubscription appears. |
| `CPU_VISIBLE_MEMORY_NODES` | NUMA memory node visibility and order | Leave unset initially. | You need to mask NUMA nodes or control binding sequence. |
| `--tensor-parallel-size` | Weight sharding across ranks | Number of NUMA nodes, where supported. | Model shard plus KV cache does not fit per node or throughput scales poorly. |
| `--pipeline-parallel-size` | Layer partitioning across ranks | `1` initially. | Model is too large or TP alone does not fit cleanly. |
| `--data-parallel-size` | Independent replica count | `1` initially. | Throughput is limited and enough sockets/nodes are available. |
| `--max-num-batched-tokens` | Tokens allowed in one scheduler batch | Online: `2048 * world_size`; offline: `4096 * world_size`. | Time to first token or throughput misses the target. |
| `--max-num-seqs` | Sequences allowed in one scheduler batch | Online: `128 * world_size`; offline: `256 * world_size`. | Inter-token latency or output throughput misses the target. |
| `--block-size` | KV cache block granularity | Keep the default or use multiples of 32. | You are doing controlled CPU performance sweeps. |
| `VLLM_CPU_SGL_KERNEL` | Experimental small-batch optimized x86 kernels | `0` initially. | Low-latency SLM serving is stable and the model meets AMX/BF16/shape requirements. |

`world_size` is the product of tensor, pipeline, and data parallel ranks used by the vLLM deployment.

## Validation and Benchmarking

Use repeatable validation before changing multiple knobs at once.

### Functional Validation

```bash
vllm collect-env
lscpu | grep -E "amx_(tile|bf16|int8)|avx512_bf16"
numactl --hardware
```

Start the server with one known model and send a short request. Confirm that the response is correct before increasing batch size or parallelism.

### Placement Validation

While vLLM is serving traffic, check that inference threads stay on the intended cores:

```bash
htop
```

For a scriptable check, run a short benchmark and record CPU, memory, and NUMA behavior with tools such as `perf stat`, `numastat`, or platform telemetry.

### Benchmark Sweep

For each model and hardware configuration, sweep these values independently:

- `VLLM_CPU_KVCACHE_SPACE`
- `--max-num-batched-tokens`
- `--max-num-seqs`
- `--tensor-parallel-size`
- `VLLM_CPU_OMP_THREADS_BIND`
- quantized versus BF16 weights

Track at least these metrics:

- Time to first token (TTFT)
- Inter-token latency (ITL)
- Output tokens per second
- Requests per second
- Peak RSS and memory per NUMA node
- CPU utilization per socket
- Error rate and OOM events

Use the vLLM benchmark CLI or the vLLM Benchmark Suite for repeatable comparisons. For CPU-supported models, the vLLM documentation points to CPU benchmark test cases that include optimized example configurations and dry-run command generation.

### Example Benchmark Command

Run a latency benchmark with the vLLM CLI:

```bash
vllm bench latency \
  --model Qwen/Qwen3-4B \
  --input-len 256 \
  --output-len 128 \
  --batch-size 8 \
  --dtype bfloat16 \
  --device cpu
```

Or, from a [vLLM source checkout](https://github.com/vllm-project/vllm), use the Benchmark Suite dry-run to generate optimized serving commands for CPU models:

```bash
ON_CPU=1 SERVING_JSON=serving-tests-cpu-text.json DRY_RUN=1 \
  MODEL_FILTER=Qwen/Qwen3-4B DTYPE_FILTER=bfloat16 \
  bash .buildkite/performance-benchmarks/scripts/run-performance-benchmarks.sh
```

The generated `.commands` files in `./benchmark/results/` contain the full CLI invocations with optimized settings for each model.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Worker exits with code 9 or process is killed | Per-rank model shard plus KV cache exceeds NUMA memory. | Reduce `VLLM_CPU_KVCACHE_SPACE`, lower batch limits, use quantization, or change TP/PP layout. |
| CPU utilization is high but latency is poor | Oversubscription or API server competing with inference threads. | Reserve 1-2 cores with `VLLM_CPU_NUM_OF_RESERVED_CPU` or manual binding. |
| One socket is busy and another is idle | Thread binding or NUMA node visibility is wrong. | Use `VLLM_CPU_OMP_THREADS_BIND=auto`, set `CPU_VISIBLE_MEMORY_NODES`, or manually bind ranks. |
| TTFT is too high | Prefill batch is too large or model/context is too heavy. | Lower `--max-num-batched-tokens`, reduce prompt length, use a smaller model, or increase parallelism. |
| Inter-token latency is too high | Too many active sequences or insufficient compute per rank. | Lower `--max-num-seqs`, use a smaller SLM, tune TP/PP, or test `VLLM_CPU_SGL_KERNEL=1` where supported. |
| BF16 model is slower than expected | AMX not visible, unsupported CPU, wrong wheel/build, or poor binding. | Recheck CPU flags, `vllm collect-env`, PyTorch AMX helper, and thread placement. |
| Docker logs show NUMA permission warnings | Container lacks permissions needed by NUMA calls. | Use the vLLM CPU Docker guidance, including appropriate security options for your environment. |

## FAQ

### What is the minimum vLLM version for Intel Xeon AMX deployments?

Use vLLM `0.17.0` or newer as the minimum packaged x86 CPU deployment baseline. The official CPU installation guide states that pre-built x86 CPU wheels with AVX512/AVX2 are available starting in `0.17.0`. AMX usage is then determined by the CPU flags, the installed CPU wheel or source build, PyTorch CPU capability detection, model dtype, and selected vLLM CPU kernels. Prefer the latest stable vLLM release when tuning AMX systems.

### Should I use BF16 or FP16 on CPU?

Use BF16. vLLM's CPU guide recommends explicitly setting `dtype=bfloat16` if FP16 has performance or accuracy issues on CPU, and BF16 is the natural dtype for AMX BF16 acceleration on Intel Xeon.

### How much KV cache should I allocate?

Allocate only what fits per NUMA node after model weights and headroom. Start with `20` GiB for SLMs, then increase gradually. For multi-rank deployments, remember that `VLLM_CPU_KVCACHE_SPACE` applies per CPU worker/rank.

### Should tensor parallel size always equal socket count?

Not always. It is a good first test when each socket maps cleanly to a NUMA node and the vLLM release supports that tensor parallel size. Use benchmarks to compare TP, PP, and DP layouts for your model.

### When should I use quantization?

Use quantization after you have a BF16 baseline. It is most valuable when memory capacity or memory bandwidth limits the deployment, or when a larger model needs to fit in available DRAM.

## Disclaimer

Performance varies by use, configuration, and other factors. Learn more on the [Performance Index site](https://edc.intel.com/content/www/us/en/products/performance/benchmarks/overview/). No product or component can be absolutely secure. Intel technologies may require enabled hardware, software, or service activation. See [Legal Notices and Disclaimers](https://www.intel.com/LegalNoticesAndDisclaimers).

## References

- [vLLM CPU installation guide](https://docs.vllm.ai/en/stable/getting_started/installation/cpu/)
- [vLLM CPU hardware-supported models for Intel Xeon](https://docs.vllm.ai/en/stable/models/hardware_supported_models/cpu/)
- [vLLM optimization and tuning guide](https://docs.vllm.ai/en/stable/configuration/optimization/)
- [vLLM Intel quantization support](https://docs.vllm.ai/en/stable/features/quantization/inc/)
- [vLLM CPU installation documentation source](https://github.com/vllm-project/vllm/blob/main/docs/getting_started/installation/cpu.md)
- [vLLM GitHub repository](https://github.com/vllm-project/vllm)
