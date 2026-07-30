---
name: vllm-xeon-cpu
description: "Deploy, tune, validate, and benchmark vLLM on Intel Xeon CPUs (CPU-only inference, no GPU). USE FOR: serving and performance optimizing LLMs on Intel Xeon, vLLM CPU install, CPU inference tuning, AMX bfloat16 setup, NUMA pinning, VLLM_CPU_KVCACHE_SPACE, VLLM_CPU_OMP_THREADS_BIND, --dtype=bfloat16, vllm/vllm-openai-cpu Docker image, hardware validation for AMX (amx_tile, amx_bf16, amx_int8), KV cache sizing per NUMA node, --max-num-batched-tokens / --max-num-seqs tuning, vllm bench serve on CPU, TTFT/TPOT measurement. DO NOT USE FOR: GPU vLLM (use upstream vLLM docs), training, quantization tuning beyond INT8/AWQ pointers, model architecture selection (use Intel Xeon AI Performance Advisor), non-Xeon CPUs, vLLM source build deep-dives."
---

# vLLM on Intel Xeon CPUs

- **Skill version**: 1.1
- **Tested against vLLM**: `v0.20.2`
- **Minimum vLLM**: `v0.17.0`

## Upstream First

Intel upstreams Xeon CPU optimizations directly to vLLM. This skill encodes deployment, tuning, validation, and a short benchmarking walkthrough — always consult upstream for the latest:

- [vLLM CPU installation guide](https://docs.vllm.ai/en/stable/getting_started/installation/cpu/)
- [vLLM SLM/LLM Recipes](https://recipes.vllm.ai/)
- [vLLM optimization and tuning](https://docs.vllm.ai/en/stable/configuration/optimization/)
- [vLLM bench serve CLI](https://docs.vllm.ai/en/latest/cli/bench/serve.html)

## When to Use

Invoke this skill when the user wants to:
- Deploy or serve vLLM on an Intel Xeon CPU (no GPU).
- Tune CPU-serving performance knobs (KV cache, OMP bind, batched tokens, num seqs).
- Validate Xeon hardware (AMX flags, NUMA topology) before deploying.
- Run a minimal CPU benchmark to measure TTFT / TPOT / throughput.

**Do not use** for GPU vLLM, model training, deep quantization tuning, model selection (point users at the [Intel Xeon AI Performance Advisor](https://xeonprocessoradvisor.intel.com/csp-ai-performance-advisor)), or non-Xeon CPUs.

## Prerequisites

| Item | Requirement |
| --- | --- |
| OS | Linux |
| Python | 3.10–3.13 (only if not using Docker) |
| CPU | 4th Gen Intel Xeon or newer; must expose `amx_tile`, `amx_bf16`, `amx_int8` for best BF16/INT8 performance |
| Tools | `curl`, `numactl`, `jq`, `g++`, `python3-dev`, `python3-venv` (`sudo apt-get install -y --no-install-recommends curl git jq numactl htop python3-venv python3-full g++ python3-dev`). `g++` and Python headers are required by PyTorch inductor to JIT-compile CPU kernels. |
| Docker | Recent Docker with `--cap-add SYS_NICE` and `--security-opt seccomp=unconfined` permitted |

## Procedure 1 — Validate Hardware

Goal: confirm Xeon generation, AMX support, and NUMA topology before deploying.

1. Inspect CPU model, sockets, cores, threads, NUMA nodes:
   ```bash
   lscpu | grep -E "Model name|Socket|Core|Thread|NUMA node"
   ```
2. Check for AMX and AVX-512 flags:
   ```bash
   lscpu | grep -E "amx_(tile|bf16|int8)|avx512_bf16|avx512f|avx2"
   ```
   - **All of `amx_tile`, `amx_bf16`, `amx_int8` present** → proceed; BF16 AMX kernels will activate.
   - **AMX missing** --> Warn user. vLLM will still run, but inference throughput will be substantially lower. Recommend a 4th Gen Xeon (Sapphire Rapids) or newer.
3. Inspect NUMA topology:
   ```bash
   numactl --hardware
   ```
   Record the NUMA node count `N` — it drives `--tensor-parallel-size` and KV cache sizing.

## Procedure 2 — Deploy (Docker Fast Path)

Goal: serve a model via the official `vllm/vllm-openai-cpu` image with Xeon-tuned env vars.

0. (Optional) Install Docker if not present (Ubuntu 24.04):
   ```bash
   sudo apt-get update
   sudo apt-get install -y docker.io
   sudo systemctl enable --now docker
   sudo usermod -aG docker $USER
   newgrp docker   # apply group without re-login
   ```
1. Pin a release tag (do not use `latest-x86_64` in production):
   ```bash
   export VLLM_VERSION=0.20.2   # update to the latest release that meets the minimum above
   docker pull vllm/vllm-openai-cpu:v${VLLM_VERSION}-x86_64
   ```
2. Run the container with the required Xeon env vars and Docker capabilities:
   ```bash
   docker run --rm \
     --name vllm-cpu \
     --security-opt seccomp=unconfined \
     --cap-add SYS_NICE \
     --shm-size=8g \
     -p 8000:8000 \
     -e HF_TOKEN="${HF_TOKEN}" \
     -e VLLM_CPU_KVCACHE_SPACE=20 \
     -e VLLM_CPU_OMP_THREADS_BIND=auto \
     -e VLLM_CPU_NUM_OF_RESERVED_CPU=1 \
     vllm/vllm-openai-cpu:v${VLLM_VERSION}-x86_64 \
     <model-id> \
     --dtype=bfloat16 \
     --max-num-batched-tokens 2048 \
     --max-num-seqs 128
   ```
   - `SYS_NICE` + `seccomp=unconfined` enable vLLM's NUMA memory-policy calls. Without them serving still works but logs may show `get_mempolicy: Operation not permitted` and NUMA placement weakens.
   - `VLLM_CPU_KVCACHE_SPACE` is in GiB **per NUMA node** (start `20`–`40`) — must fit in node-local memory.
   - `VLLM_CPU_OMP_THREADS_BIND=auto` binds OpenMP workers to NUMA-local cores. For manual control use ranges like `0-31|32-63`.
   - `VLLM_CPU_NUM_OF_RESERVED_CPU=1` keeps a core free for API serving, tokenization, networking, and OS work.
3. Validate the OpenAI-compatible endpoint:
   ```bash
   curl http://localhost:8000/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{
       "model": "<model-id>",
       "messages": [{"role": "user", "content": "Give three CPU inference tuning tips."}],
       "max_tokens": 128
     }'
   ```

## Procedure 3 — Tune Performance Knobs

Goal: improve TTFT / TPOT / throughput methodically. **Change one knob per run** and compare.

1. Pick the use case:
   - **Online serving** → start `--max-num-batched-tokens 2048`, `--max-num-seqs 128`.
   - **Offline batch** → start `--max-num-batched-tokens 4096`, `--max-num-seqs 256`.
2. Set `--tensor-parallel-size`:
   - Single NUMA node → leave default.
   - Multi NUMA → set to the NUMA node count `N` from Procedure 1.
   - **`--tensor-parallel-size=6` is currently unsupported on CPU; avoid it.**
3. Size `VLLM_CPU_KVCACHE_SPACE` (GiB per NUMA node):
   - Start at `20`–`40`. Larger value → more concurrency / longer context, but must fit in node-local RAM.
   - If the server OOMs or pages, halve and retry.
4. Bind OpenMP threads with `VLLM_CPU_OMP_THREADS_BIND`:
   - Prefer `auto`. Use manual ranges (`0-31|32-63`) only when `auto` mis-pins (verify with `numastat -p $(pgrep -f 'vllm serve|api_server' | head -n1)`).
5. (Experimental) Low-latency small-batch serving:
   - `VLLM_CPU_SGL_KERNEL=1` enables x86 small-batch kernels. Requires AMX, BF16 weights, and compatible shapes. 
6. Quantization (when functional quality is acceptable):
   - Try INT8 or AWQ to reduce weight memory and memory-bandwidth pressure. Validate quality before promoting.

Full knob reference: [tuning matrix](./references/tuning-matrix.md).

## Procedure 4 — Benchmark (Minimal CPU Walkthrough)

Goal: measure TTFT, TPOT, and throughput against the running server with a reproducible warm-up.

1. Confirm the server is reachable and inspect environment:
   ```bash
   curl -s http://localhost:8000/v1/models | jq .
   docker exec vllm-cpu vllm collect-env   # or `vllm collect-env` for native installs
   SERVER_PID=$(pgrep -f 'vllm serve|api_server' | head -n 1)
   numastat -p "${SERVER_PID}"             # verify NUMA locality
   ```
2. Run `vllm bench serve` with warm-ups (warm-ups avoid measuring JIT/compile overhead):
   ```bash
   vllm bench serve \
     --model <model-id> \
     --dataset-name random \
     --random-input-len 128 \
     --random-output-len 128 \
     --num-prompts 100 \
     --num-warmups 5 \
     --request-rate inf \
     --save-result \
     --result-dir ./bench-results \
     --percentile-metrics ttft,tpot,itl
   ```
   > **Execution context:** prefix `vllm bench serve` with `docker exec vllm-cpu` if you deployed via Procedure 2 (Docker), or run it directly on a native/venv install. A native `Failed to infer device type` error means the generic CUDA wheel is installed instead of the CPU wheel — reinstall the wheel whose version ends in `+cpu` (e.g. `0.20.2+cpu`) from `https://download.pytorch.org/whl/cpu`.
3. Sweep methodically — **one variable per run**:
   - Vary input/output lengths: `64`, `128`, `256`, `512`.
   - Vary concurrency via `--num-prompts`: `10`, `50`, `100`, `200`, `500`.
   - Track TTFT, TPOT, output tokens/sec, requests/sec, peak RSS, NUMA locality, and any OOM events.
   - When tuning, change only one of `VLLM_CPU_KVCACHE_SPACE`, `VLLM_CPU_OMP_THREADS_BIND`, `--max-num-batched-tokens`, `--max-num-seqs`, or `--block-size` per run. Compare results across runs using the saved JSON files in `./bench-results`.
4. For the full CI-grade harness (`run-performance-benchmarks.sh` with `ON_CPU=1`, `SERVING_JSON`, `DRY_RUN`, `MODEL_FILTER`, `DTYPE_FILTER`), see the upstream [vLLM benchmarking docs](https://docs.vllm.ai/en/latest/benchmarking/cli/).

## Output the Agent Should Produce

After running these procedures, return to the user:
- The hardware validation summary (Xeon generation, AMX flags present, NUMA node count).
- The exact `docker run` command used, with values chosen for their hardware.
- Any tuning recommendations with the **one knob changed** per recommendation and the expected metric impact.
- Benchmark numbers (TTFT, TPOT, throughput) with the corresponding configuration.

## References

- [Tuning matrix](./references/tuning-matrix.md) — full env-var / CLI knob table with guard rails.
- [vLLM CPU installation guide](https://docs.vllm.ai/en/stable/getting_started/installation/cpu/)
- [vLLM CPU-supported models](https://docs.vllm.ai/en/stable/models/hardware_supported_models/cpu/)
- [vLLM optimization and tuning guide](https://docs.vllm.ai/en/stable/configuration/optimization/)
- [vLLM Intel quantization support](https://docs.vllm.ai/en/stable/features/quantization/inc/)
- [Intel Xeon AI Performance Advisor (cloud)](https://xeonprocessoradvisor.intel.com/csp-ai-performance-advisor)
- [Intel Xeon AI Performance Advisor (on-prem)](https://xeonprocessoradvisor.intel.com/on-prem-ai-performance-advisor)
- [Intel AI Software Catalog — Model Guidance](https://swcatalog.intel.com/models)
