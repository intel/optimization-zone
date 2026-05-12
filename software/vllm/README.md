# vLLM on Intel Xeon CPUs

This recipe gets vLLM's CPU backend running on Intel Xeon processors and captures the few settings that usually move performance: BF16, AMX, NUMA placement, KV cache size, and batch limits. Use it with the official [vLLM CPU installation guide](https://docs.vllm.ai/en/stable/getting_started/installation/cpu/) for release-specific details.

## Requirements

| Item | Recommendation |
| --- | --- |
| OS | Linux |
| Python | 3.10 through 3.13 |
| vLLM | `0.17.0` or newer for x86 CPU wheels/images |
| CPU flags | `avx512f` recommended; `avx2` has limited features |
| Intel Xeon | 4th Gen or newer with `amx_tile`, `amx_bf16`, and `amx_int8` for best BF16/INT8 performance |
| dtype | Start with `--dtype=bfloat16` |

Install the small host tools used by the commands below:

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends curl git jq numactl htop
```

Install [uv](https://docs.astral.sh/uv/#getting-started) before using the Python wheel or source-build path.

## Performance Knobs

| Setting | Starting point | Why it matters |
| --- | --- | --- |
| `--dtype=bfloat16` | Always on AMX-capable Xeon | Enables the preferred CPU dtype and AMX BF16 kernels. |
| `VLLM_CPU_KVCACHE_SPACE` | `20` to `40` GiB per rank | Larger values allow more concurrency and context, but must fit per NUMA node. |
| `VLLM_CPU_OMP_THREADS_BIND` | `auto` | Binds OpenMP worker threads to NUMA-local cores. Use ranges such as `0-31\|32-63` for manual control. |
| `VLLM_CPU_NUM_OF_RESERVED_CPU` | `1` or `2` | Leaves cores for API serving, tokenization, networking, logging, and OS work. |
| `--tensor-parallel-size` | NUMA node count, where supported | Keeps model shards close to local memory; current vLLM CPU releases do not support `6`. |
| `--max-num-batched-tokens` | Online: `2048 * world_size`; offline: `4096 * world_size` | Tune for prefill throughput and time to first token. |
| `--max-num-seqs` | Online: `128 * world_size`; offline: `256 * world_size` | Tune for decode throughput and inter-token latency. |
| `--block-size` | Default or multiples of `32` | Useful during controlled CPU sweeps. |
| `VLLM_CPU_SGL_KERNEL` | `0`, try `1` for low-latency SLM serving | Experimental x86 small-batch kernels; requires AMX, BF16 weights, and compatible shapes. |

`world_size` is the product of tensor, pipeline, and data parallel ranks.

## Check the Hardware

```bash
lscpu | grep -E "Model name|Socket|Core|Thread|NUMA node|Flags"
lscpu | grep -E "avx512f|avx2|amx_(tile|bf16|int8)|avx512_bf16"
numactl --hardware
```

## Fast Path: Docker

```bash
export VLLM_VERSION=0.20.2
docker pull vllm/vllm-openai-cpu:v${VLLM_VERSION}-x86_64

docker run --rm \
  --name vllm-cpu \
  --security-opt seccomp=unconfined \
  --cap-add SYS_NICE \
  --shm-size=4g \
  -p 8000:8000 \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  -e HF_TOKEN="${HF_TOKEN}" \
  -e VLLM_CPU_KVCACHE_SPACE=40 \
  -e VLLM_CPU_OMP_THREADS_BIND=auto \
  -e VLLM_CPU_NUM_OF_RESERVED_CPU=1 \
  vllm/vllm-openai-cpu:v${VLLM_VERSION}-x86_64 \
  ibm-granite/granite-3.0-3b-a800m-instruct \
  --dtype=bfloat16 \
  --max-num-batched-tokens 2048 \
  --max-num-seqs 64
```

Use the `-x86_64` CPU image tag when pinning a version; `latest-x86_64` is the unpinned option.

`SYS_NICE` and `seccomp=unconfined` allow vLLM's NUMA memory policy calls inside Docker. Without them, serving can still work, but NUMA placement may be weaker and logs can show `get_mempolicy: Operation not permitted`.

Validate the OpenAI-compatible endpoint:

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "ibm-granite/granite-3.0-3b-a800m-instruct",
    "messages": [{"role": "user", "content": "Give three CPU inference tuning tips."}],
    "max_tokens": 128
  }'
```

## Python Wheel Install

Use this path when you need a local Python environment instead of Docker.

```bash
uv venv --python 3.12 --seed --managed-python
source .venv/bin/activate

export VLLM_VERSION=$(curl -s https://api.github.com/repos/vllm-project/vllm/releases/latest | jq -r .tag_name | sed 's/^v//')
uv pip install \
  "https://github.com/vllm-project/vllm/releases/download/v${VLLM_VERSION}/vllm-${VLLM_VERSION}+cpu-cp38-abi3-manylinux_2_35_x86_64.whl" \
  --torch-backend cpu
```

For latest main-branch CPU wheels:

```bash
uv pip install vllm \
  --extra-index-url https://wheels.vllm.ai/nightly/cpu \
  --index-strategy first-index \
  --torch-backend cpu
```

Before serving from CPU wheels or source builds, preload TCMalloc and Intel OpenMP:

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends libtcmalloc-minimal4

TC_PATH=$(find /usr -name 'libtcmalloc_minimal.so.4' 2>/dev/null | head -n 1)
IOMP_PATH=$(find .venv -name 'libiomp5.so' 2>/dev/null | head -n 1)
export LD_PRELOAD="${TC_PATH}:${IOMP_PATH}:${LD_PRELOAD}"
```

Run locally:

```bash
export VLLM_CPU_KVCACHE_SPACE=40
export VLLM_CPU_OMP_THREADS_BIND=auto
export VLLM_CPU_NUM_OF_RESERVED_CPU=1

vllm serve ibm-granite/granite-3.0-3b-a800m-instruct \
  --device cpu \
  --dtype=bfloat16 \
  --max-num-batched-tokens 2048 \
  --max-num-seqs 64
```

## Source Build Escape Hatch

Use source only when CPU wheels/images are unavailable or you need a local vLLM change.

```bash
sudo apt-get update
sudo apt-get install -y gcc-12 g++-12 libnuma-dev

git clone https://github.com/vllm-project/vllm.git vllm_source
cd vllm_source

uv venv --python 3.12 --seed --managed-python
source .venv/bin/activate
uv pip install -r requirements/build/cpu.txt --torch-backend cpu
uv pip install -r requirements/cpu.txt --torch-backend cpu
VLLM_TARGET_DEVICE=cpu uv pip install . --no-build-isolation
```

If CMake detects CUDA during a CPU build, add `CMAKE_DISABLE_FIND_PACKAGE_CUDA=ON`. If NumPy breaks imports, pin `numpy<2.0`.

## Model and Quantization Notes

- This README uses `ibm-granite/granite-3.0-3b-a800m-instruct` as a compact Granite MoE example: 3.3B total parameters with about 800M active parameters per token.
- Check the official [CPU-supported model list](https://docs.vllm.ai/en/stable/models/hardware_supported_models/cpu/) before choosing a model.
- Prefer BF16 first; compare INT8 only after functional quality is acceptable.
- CPU quantization support includes AWQ and GPTQ on x86, plus compressed-tensors INT8 W8A8 on x86 and s390x.
- INT8 can reduce weight memory and bandwidth pressure, especially during decode-heavy serving.

## Validate and Tune

Start the Docker or Python server first. If it is running in the foreground, open another terminal for these checks:

```bash
# Docker path, because the server above is named vllm-cpu.
docker exec vllm-cpu vllm collect-env

# Python wheel or source-build path.
vllm collect-env

curl -s http://localhost:8000/v1/models | jq .
SERVER_PID=$(pgrep -f 'vllm serve|api_server' | head -n 1)
htop
numastat -p "${SERVER_PID}"
```

Use one known-good model and change one knob at a time. Track TTFT, TPOT, output tokens per second, requests per second, peak RSS, NUMA locality, and OOM events.

The vLLM Benchmark Suite lives in the vLLM source tree. Clone it, or reuse the source checkout from the source-build path, even if vLLM is already installed. Exact `MODEL_FILTER` values must exist in the CPU test JSON; the current suite includes `ibm-granite/granite-3.2-2b-instruct` as the pre-curated Granite profile.

```bash
git clone https://github.com/vllm-project/vllm.git vllm_source
cd vllm_source

ON_CPU=1 SERVING_JSON=serving-tests-cpu-text.json DRY_RUN=1 \
  MODEL_FILTER=ibm-granite/granite-3.2-2b-instruct DTYPE_FILTER=bfloat16 \
  bash .buildkite/performance-benchmarks/scripts/run-performance-benchmarks.sh

find benchmark/results -maxdepth 2 -name "*.commands" -print
```

Use the generated `.commands` files as the baseline. When moving back to the Granite MoE serving model, replace the model ID and change only one of `VLLM_CPU_KVCACHE_SPACE`, `VLLM_CPU_OMP_THREADS_BIND`, `--max-num-batched-tokens`, `--max-num-seqs`, or `--block-size` per run.

## References

- [vLLM CPU installation guide](https://docs.vllm.ai/en/stable/getting_started/installation/cpu/)
- [vLLM CPU-supported models](https://docs.vllm.ai/en/stable/models/hardware_supported_models/cpu/)
- [vLLM optimization and tuning guide](https://docs.vllm.ai/en/stable/configuration/optimization/)
- [vLLM Intel quantization support](https://docs.vllm.ai/en/stable/features/quantization/inc/)
