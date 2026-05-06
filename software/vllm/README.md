# vLLM on Intel Xeon with Intel AMX

This recipe configures vLLM for CPU inference and serving on Intel Xeon processors with Intel Advanced Matrix Extensions (Intel AMX). It focuses on the settings that most affect performance: BF16 execution, CPU thread binding, NUMA placement, KV cache sizing, batch limits, and model selection. Pair it with the official [vLLM CPU installation guide](https://docs.vllm.ai/en/stable/getting_started/installation/cpu/) for package-specific setup details.

## Table of Contents

- [vLLM on Intel Xeon with Intel AMX](#vllm-on-intel-xeon-with-intel-amx)
  - [Table of Contents](#table-of-contents)
  - [Overview](#overview)
  - [Recommended Baseline](#recommended-baseline)
  - [Prerequisites](#prerequisites)
  - [Serve and validate vLLM with Docker](#serve-and-validate-vllm-with-docker)
  - [AMX and BF16 Configuration](#amx-and-bf16-configuration)
  - [Quantization (INT8 / W8A8)](#quantization-int8--w8a8)
  - [CPU Threading and NUMA](#cpu-threading-and-numa)
    - [Default Recommendation](#default-recommendation)
    - [Manual Binding Example](#manual-binding-example)
    - [NUMA Checklist](#numa-checklist)
  - [KV Cache and Memory Sizing](#kv-cache-and-memory-sizing)
  - [Large Models on Xeon Memory Capacity](#large-models-on-xeon-memory-capacity)
  - [Tuning Reference](#tuning-reference)
  - [Validation and Benchmarking](#validation-and-benchmarking)
    - [Functional Validation](#functional-validation)
    - [Placement Validation](#placement-validation)
    - [Benchmark Sweep](#benchmark-sweep)
    - [Example Benchmark Command](#example-benchmark-command)
  - [Disclaimer](#disclaimer)
  - [References](#references)

## Overview

vLLM serves models on x86 CPUs with FP32, FP16, and BF16. On Intel Xeon processors with Intel AMX, BF16 is the preferred dtype: it cuts memory traffic and enables AMX BF16 matrix kernels. AMX also supports INT8 (`amx_int8`), which vLLM uses automatically for INT8-quantized models (e.g., compressed-tensors W8A8) to further reduce memory and bandwidth.

Use this recipe when you want to:

- Serve small language models (SLMs) without a discrete accelerator.
- Host models or context lengths that benefit from the larger DRAM capacity available on CPU servers.
- Run inference close to CPU-resident data pipelines, vector databases, or enterprise services.
- Tune vLLM CPU deployments beyond a default install.

## Recommended Baseline

| Item | Recommendation |
| --- | --- |
| vLLM version | Use vLLM `0.17.0` cpu container or newer. |
| CPU | Intel Xeon 6 is recommended as of May 2026. Intel Xeon 4th Gen or newer with `amx_tile`, `amx_bf16`, and `amx_int8` CPU flags should be used. |
| dtype | Use `--dtype=bfloat16`. Also works for INT8 quantized models. |
| Memory | Size `VLLM_CPU_KVCACHE_SPACE=40` is a good starting point. |
| Threading | Start with `VLLM_CPU_OMP_THREADS_BIND=auto` . |
| Parallelism | On multi-socket systems, start with tensor parallel size equal to the number of NUMA nodes, except values that the current vLLM release does not support. |
| Python | Python 3.10 through 3.13, following the vLLM CPU installation guide. |

## Prerequisites

Verify the platform before tuning vLLM.

```bash
lscpu | grep -E "Model name|Socket|Core|Thread|NUMA node|Flags"
lscpu | grep -E "amx_(tile|bf16|int8)|avx512_bf16"
```

Expected CPU flags for AMX acceleration:

- `amx_tile` — required base for all AMX paths
- `amx_bf16` — enables AMX BF16 matrix operations (primary inference dtype)
- `amx_int8` — enables AMX INT8 matrix operations (used by INT8 quantized models)
- `avx512_bf16` — scalar/vector BF16 support complementing AMX

## Serve and validate vLLM with Docker

vLLM publishes pre-built CPU Docker images. Pull the latest x86_64 CPU image:

```bash
docker pull vllm/vllm-openai-cpu:latest-x86_64
```

Then run it with the environment variables from above:

```bash
export VLLM_CPU_KVCACHE_SPACE=40
export VLLM_CPU_OMP_THREADS_BIND=auto
export VLLM_CPU_NUM_OF_RESERVED_CPU=1
export VLLM_CPU_SGL_KERNEL=1

docker run --rm \
  --security-opt seccomp=unconfined \
  --cap-add SYS_NICE \
  --shm-size=4g \
  -p 8000:8000 \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  -e VLLM_CPU_KVCACHE_SPACE=40 \
  -e HF_TOKEN="${HF_TOKEN}" \
  vllm/vllm-openai-cpu:latest-x86_64 \
  Qwen/Qwen3-4B \
  --dtype=bfloat16 \
  --max-num-batched-tokens 2048 \
  --max-num-seqs 64
```

Note: `--security-opt seccomp=unconfined` and `--cap-add SYS_NICE` are needed for NUMA memory policy calls inside the container. Omitting them may produce `get_mempolicy: Operation not permitted` warnings.

Or run vLLM directly (same env vars apply):

```bash
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

BF16 is the recommended CPU dtype: it halves memory traffic versus FP32 and unlocks AMX BF16 matrix kernels for matrix-heavy LLM operations. For further gains, use INT8-quantized models to engage AMX INT8 kernels (see next section).

## Quantization (INT8 / W8A8)

INT8 quantization (e.g., `compressed-tensors` W8A8) reduces model weight memory and memory-bandwidth pressure, which is often the bottleneck for CPU LLM inference. vLLM automatically selects AMX INT8 kernels when the model ships a compatible quantization config — no extra CLI flag is required beyond pointing at the quantized model:

```bash
vllm serve <org>/<model>-w8a8 \
  --device cpu \
  --dtype=bfloat16 \
  --max-num-batched-tokens 2048 \
  --max-num-seqs 64
```

`--dtype=bfloat16` here sets the activation/compute dtype; INT8 weights are loaded according to the model's quantization config.

When to consider INT8:

- Memory-bandwidth-bound workloads on Xeon (most LLM decode phases).
- Larger models that don't fit comfortably per NUMA node in BF16.
- Higher-concurrency serving where KV cache competes with weights for DRAM.

Always validate accuracy on your target prompts before adopting INT8, and benchmark BF16 vs INT8 end-to-end — INT8 reduces compute and bandwidth cost but can shift quality on some tasks.

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

Examples:

| Scenario | Starting point | Why |
| --- | --- | --- |
| SLM, low concurrency | `VLLM_CPU_KVCACHE_SPACE=10` to `20` | Keeps memory pressure low while validating BF16 and thread placement. |
| SLM, higher concurrency | `VLLM_CPU_KVCACHE_SPACE=20` to `40` | Supports more simultaneous sessions and longer prompts. |
| 8B-class model on a large-memory node | `VLLM_CPU_KVCACHE_SPACE=40` or higher | Uses Xeon DRAM capacity for larger batches or context lengths. |
| Multi-NUMA tensor parallel | Size per NUMA node | Each rank needs local memory for its weight shard plus its KV cache. |

If the worker exits with code 9 or the process is killed by the OOM killer, reduce `VLLM_CPU_KVCACHE_SPACE`, reduce batch limits, lower tensor-parallel pressure per node, or use a smaller/quantized model.

## Large Models on Xeon Memory Capacity

Intel Xeon servers can be configured with substantially more system memory than a single accelerator, which is useful when the model, KV cache, or context length doesn't fit comfortably in accelerator memory. This doesn't make CPU inference universally faster than GPU — it changes the design space:

- Use Xeon when capacity, cost, data locality, or CPU-only constraints dominate.
- Use quantization (see [Quantization](#quantization-int8--w8a8)) to cut weight memory and bandwidth pressure.
- Use tensor parallelism across NUMA nodes when a shard plus KV cache fits cleanly per node.
- Prefer smaller batches for interactive latency, larger batches for offline throughput.
- Keep DRAM headroom — filling all memory with weights and KV cache destabilizes tail latency.

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

## Disclaimer

Performance varies by use, configuration, and other factors. Learn more on the [Performance Index site](https://edc.intel.com/content/www/us/en/products/performance/benchmarks/overview/). No product or component can be absolutely secure. Intel technologies may require enabled hardware, software, or service activation. See [Legal Notices and Disclaimers](https://www.intel.com/LegalNoticesAndDisclaimers).

## References

- [vLLM CPU installation guide](https://docs.vllm.ai/en/stable/getting_started/installation/cpu/)
- [vLLM CPU hardware-supported models for Intel Xeon](https://docs.vllm.ai/en/stable/models/hardware_supported_models/cpu/)
- [vLLM optimization and tuning guide](https://docs.vllm.ai/en/stable/configuration/optimization/)
- [vLLM Intel quantization support](https://docs.vllm.ai/en/stable/features/quantization/inc/)
- [vLLM CPU installation documentation source](https://github.com/vllm-project/vllm/blob/main/docs/getting_started/installation/cpu.md)
- [vLLM GitHub repository](https://github.com/vllm-project/vllm)
