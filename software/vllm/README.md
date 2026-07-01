# vLLM on Intel Xeon Processors

This guide provides recommendations for running vLLM on Intel Xeon processors.

## Table of Contents

- [Upstream First](#upstream-first)
- [Intel Xeon SLM/LLM Sizing Guidance](#intel-xeon-slmllm-sizing-guidance)
- [vLLM Requirements Guidance](#vllm-requirements-guidance)
- [Performance Guidance](#performance-guidance)
- [Utility Tools](#utility-tools)
- [Hardware Validation](#hardware-validation)
- [Fast Path: Docker](#fast-path-docker)
- [Validate the OpenAI-compatible endpoint](#validate-the-openai-compatible-endpoint)
- [Benchmarking Guidance](#benchmarking-guidance)
  - [Benchmark](#benchmark)
  - [Concurrency Sweep](#concurrency-sweep)
  - [Testing & Tuning Methodology](#testing--tuning-methodology)
  - [Using the vLLM Benchmark Suite](#using-the-vllm-benchmark-suite)
- [Use with AI Coding Agents](#use-with-ai-coding-agents)
- [References](#references)

## Upstream First

Intel invests significant efforts upstreaming code optimizations and documentation directly to the official vLLM repositories. Those upstream contributions form the foundation of Intel Xeon CPU performance in vLLM. This guide is only a small extension of that work—collecting practical deployment tips in one place. Users should always consult the official documentation.

- [vLLM CPU installation guide](https://docs.vllm.ai/en/stable/getting_started/installation/cpu/)
- [vLLM SLM/LLM Recipes](https://recipes.vllm.ai/)
- [vLLM Benchmarking](https://docs.vllm.ai/en/stable/benchmarking/cli/)

## Intel Xeon SLM/LLM Sizing Guidance

For guidance around SLM/LLM sizing on Intel Xeon CPUs, please see our Xeon Processor Advisor Tool & AI Software Catalog:

- [Intel AI Software Catalog - Model Guidance](https://swcatalog.intel.com/models)
- [Cloud Intel Xeon AI Performance Advisor](https://xeonprocessoradvisor.intel.com/csp-ai-performance-advisor)
- [On-prem Intel Xeon AI Performance Advisor](https://xeonprocessoradvisor.intel.com/on-prem-ai-performance-advisor)

## vLLM Requirements Guidance

| Item | Guidance |
| --- | --- |
| OS | Linux |
| Python | 3.10 through 3.13 |
| vLLM | `v0.17.0` or newer |
| Intel AMX related Xeon CPU Flags | 4th Gen Intel Xeon or newer with `amx_tile`, `amx_bf16`, and `amx_int8` for best BF16/INT8 performance |

## Performance Guidance

The table below mixes two kinds of knobs: **environment variables** (the `VLLM_CPU_*` entries, set
with a shell `export` or a Docker `-e` flag) and **server CLI flags** (the `--*` entries, passed to
`vllm serve`). Set each one in the matching place shown in the Docker and benchmarking examples
below.

| Setting | Guidance | Why it matters |
| --- | --- | --- |
| `--dtype=bfloat16` | Use `bfloat16` on Intel Xeon with Intel AMX | Selects the preferred CPU dtype and enables Intel AMX BF16 acceleration. |
| `VLLM_CPU_KVCACHE_SPACE` | `20` to `40` GiB or larger | Larger values allow more concurrency and context, but must fit into the memory capacity available per NUMA node. |
| `VLLM_CPU_OMP_THREADS_BIND` | `auto` | Binds OpenMP worker threads to NUMA-local cores. Use ranges such as `0-31\|32-63` for manual control, `auto` preferred. |
| `VLLM_CPU_NUM_OF_RESERVED_CPU` | `1` | Reserves one core for API serving, tokenization, networking, logging, and OS work. |
| `--tensor-parallel-size` | Use the default for a single NUMA node, or set it to the NUMA node count | Keeps model shards close to local memory; current vLLM CPU releases do not support `--tensor-parallel-size=6`. |
| `--max-num-batched-tokens` | Online: `2048`; offline: `4096` | Maximum number of batched tokens per iteration. Tune for prefill throughput and time to first token. |
| `--max-num-seqs` | Online: `128`; offline: `256` | Maximum number of sequences per iteration. Tune for decode throughput and inter-token latency. |
| `VLLM_CPU_SGL_KERNEL` | `0`, or try `1` for low-latency SLM serving | Experimental x86 small-batch kernels; requires AMX, BF16 weights, and compatible shapes. |

## Utility Tools

Use the OS package manager to install the tools used by the commands below:

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends curl git jq numactl htop python3-venv python3-full g++ python3-dev
```

## Hardware Validation

Validate the CPU model, core count, thread count, NUMA topology, and important flags such as `avx512f`, `avx2`, `amx_tile`, `amx_bf16`, `amx_int8`, and `avx512_bf16`.

```bash
lscpu | grep -E "Model name|Socket|Core|Thread|NUMA node|Flags"
lscpu | grep -E "avx512f|avx2|amx_(tile|bf16|int8)|avx512_bf16"
numactl --hardware
```

## Fast Path: Docker

<details>
<summary>(Optional) Install Docker on Ubuntu 24.04</summary>

```bash
sudo apt-get update
sudo apt-get install -y docker.io
sudo systemctl enable --now docker
sudo usermod -aG docker $USER
newgrp docker   # apply group without re-login
```

</details>

```bash
export HF_TOKEN=your_hf_token_here  # <<<=== Required for gated Hugging Face models and faster downloads.
export VLLM_VERSION=0.20.2          # <<<=== Update this for newer releases! Check! 
docker pull vllm/vllm-openai-cpu:v${VLLM_VERSION}-x86_64

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
  RedHatAI/Qwen3-4B-Instruct-2507-quantized.w8a8 \
  --dtype=bfloat16 \
  --max-num-batched-tokens 2048 \
  --max-num-seqs 128
```

`SYS_NICE` and `seccomp=unconfined` allow vLLM's NUMA memory policy calls inside Docker. Without them, serving can still work, but NUMA placement may be weaker and logs can show `get_mempolicy: Operation not permitted`.

## Validate the OpenAI-compatible endpoint

**Open a new terminal and use the below command to test that the endpoint is available. Alternatively, you can connect from a remote system but make sure to substitute `localhost` for the server's address.**

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "RedHatAI/Qwen3-4B-Instruct-2507-quantized.w8a8",
    "messages": [{"role": "user", "content": "Give three CPU inference tuning tips."}],
    "max_tokens": 128
  }'
```

## Benchmarking Guidance

This summarizes the official benchmarking and tuning guidance from the vLLM documentation, with a CPU focus. Always consult the [official benchmarking docs](https://docs.vllm.ai/en/latest/benchmarking/cli/) for the latest recommendations and tools.

> **Mind the execution context.** The commands in this section run in one of three places: inside
> the **Docker container** (prefix with `docker exec vllm-cpu ...`), in a **native/host install**
> (`pip install vllm`, run directly), or inside a **Python virtualenv**. Run each command in the
> same environment where vLLM is installed — do not run a host command inside the container or a
> container command on the host. The [Utility Tools](#utility-tools) and
> [Hardware Validation](#hardware-validation) steps are host-level checks: run them once on the
> host before any benchmarking path.

Start the Docker container. If it is running in the foreground, open another terminal for these checks:

```bash
# Docker path, because the container above is named vllm-cpu.
docker exec vllm-cpu vllm collect-env

sudo curl -s http://localhost:8000/v1/models | jq .
SERVER_PID=$(pgrep -f 'vllm serve|api_server' | head -n 1)
numastat -p "${SERVER_PID}"
```

### Benchmark

`vllm bench serve` is vLLM's built-in load generator: it sends requests to an already-running
server and reports latency and throughput. Use it to measure TTFT (time to first token), TPOT
(time per output token), and throughput. Warm up with `--num-warmups` to avoid measuring JIT
compilation overhead. It is a lightweight, single-command alternative to the full
[vLLM Benchmark Suite](#using-the-vllm-benchmark-suite) covered later, which drives this same
underlying benchmark across a curated test matrix.

If you started the server with Docker (as shown above), run the benchmark **inside the container**:

```bash
docker exec vllm-cpu vllm bench serve \
  --model RedHatAI/Qwen3-4B-Instruct-2507-quantized.w8a8 \
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

If you installed vLLM natively (via `pip install vllm`), run directly on the host:

```bash
vllm bench serve \
  --model RedHatAI/Qwen3-4B-Instruct-2507-quantized.w8a8 \
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

> **Troubleshooting: "Failed to infer device type"** — This error means vLLM's platform detection cannot find the CPU backend. The most common cause is installing the generic (CUDA) wheel from PyPI via `pip install vllm` instead of the CPU-specific wheel. The CPU wheel includes `+cpu` in its version string (e.g., `0.20.2+cpu`), which the platform detector requires. Fix by reinstalling the CPU wheel directly:
>
> ```bash
> export VLLM_VERSION=0.20.2
> pip install --force-reinstall --extra-index-url https://download.pytorch.org/whl/cpu \
>   "https://github.com/vllm-project/vllm/releases/download/v${VLLM_VERSION}/vllm-${VLLM_VERSION}+cpu-cp38-abi3-manylinux_2_35_x86_64.whl"
> ```

### Concurrency Sweep

With `--request-rate inf`, all prompts fire simultaneously so `--num-prompts` directly controls concurrency. Sweep to see how latency and throughput scale under increasing batch pressure. The example below runs on the host (native/virtualenv install); if you deployed via Docker, prefix `vllm bench serve` with `docker exec vllm-cpu`:

```bash
for N in 10 50 100 200 500; do
  vllm bench serve \
    --model RedHatAI/Qwen3-4B-Instruct-2507-quantized.w8a8 \
    --dataset-name random \
    --random-input-len 128 \
    --random-output-len 128 \
    --num-prompts "${N}" \
    --num-warmups 5 \
    --request-rate inf \
    --save-result \
    --result-dir ./bench-results \
    --percentile-metrics ttft,tpot,itl
done
```

### Testing & Tuning Methodology

- Test with different input/output lengths to understand how the model performs under different prompt and generation sizes. For example, try `--random-input-len` and `--random-output-len` values of `64`, `128`, `256`, and `512`.
- Test with different user concurrency levels using `--num-prompts` values of `10`, `50`, `100`, `200`, and `500` with `--request-rate inf`.
- Use one known-good model and change one knob at a time. Track TTFT, TPOT, output tokens per second, requests per second, peak RSS, NUMA locality, and OOM events.
- Vary only one of `VLLM_CPU_KVCACHE_SPACE`, `VLLM_CPU_OMP_THREADS_BIND`, `--max-num-batched-tokens`, `--max-num-seqs`, or `--block-size` per run. Compare results across runs using the saved JSON files in `./bench-results`.

### Using the vLLM Benchmark Suite

The vLLM source tree includes a full performance benchmark harness at `.buildkite/performance-benchmarks/scripts/run-performance-benchmarks.sh`. This is the same script used in vLLM's CI to gate regressions. It reads a JSON test definition, generates concrete benchmark commands, and (optionally) executes them.

Prepare the environment and run a dry-run first to inspect the generated commands without executing them:

```bash
export HF_TOKEN=your_hf_token_here # <<<=== Required for gated Hugging Face models and faster downloads.
export VLLM_VERSION=0.20.2
python3 -m venv ~/vllm-venv
source ~/vllm-venv/bin/activate
pip install --extra-index-url https://download.pytorch.org/whl/cpu \
  "https://github.com/vllm-project/vllm/releases/download/v${VLLM_VERSION}/vllm-${VLLM_VERSION}+cpu-cp38-abi3-manylinux_2_35_x86_64.whl" \
  tabulate pandas
```

Clone the source tree (or reuse the checkout from a source build):

```bash
git clone https://github.com/vllm-project/vllm.git vllm_source
cd vllm_source
export VLLM_TARGET_DEVICE=cpu
```

Run a dry-run first to inspect the generated commands without executing them:

```bash
source ~/vllm-venv/bin/activate
HF_TOKEN="${HF_TOKEN}" \
ON_CPU=1 \
SERVING_JSON=serving-tests-cpu-text.json \
DRY_RUN=1 \
MODEL_FILTER=meta-llama/Llama-3.1-8B-Instruct \
DTYPE_FILTER=bfloat16 \
  bash .buildkite/performance-benchmarks/scripts/run-performance-benchmarks.sh
```
To execute the benchmark (remove `DRY_RUN=1`):

```bash
source ~/vllm-venv/bin/activate
HF_TOKEN="${HF_TOKEN}" \
ON_CPU=1 \
SERVING_JSON=serving-tests-cpu-text.json \
MODEL_FILTER=meta-llama/Llama-3.1-8B-Instruct \
DTYPE_FILTER=bfloat16 \
  bash .buildkite/performance-benchmarks/scripts/run-performance-benchmarks.sh
```

Key environment variables:

| Variable | Purpose |
| -------- | ------- |
| `HF_TOKEN` | Hugging Face token — required by the script's `check_hf_token` gate |
| `ON_CPU` | Set to `1` to use CPU-specific test configs |
| `SERVING_JSON` | JSON file defining test matrix (e.g., `serving-tests-cpu-text.json`) |
| `DRY_RUN` | Set to `1` to generate commands without executing |
| `MODEL_FILTER` | Run only benchmarks matching this model ID |
| `DTYPE_FILTER` | Run only benchmarks matching this dtype (e.g., `bfloat16`) |

> **Note:** The `MODEL_FILTER` value must match an entry in the JSON test definition. If the model is not pre-curated in the CPU test JSON, you can add an entry or use the `vllm bench serve` approach above instead.

## Use with AI Coding Agents

This recipe ships a companion [Agent Skill](./skill/SKILL.md) (`vllm-xeon-cpu`) that lets AI coding agents — GitHub Copilot, Claude Code, and other `AGENTS.md`-aware tools — deploy, tune, validate, and benchmark vLLM on Intel Xeon CPUs on a customer's behalf. The skill is a self-contained, markdown-only payload under [`skill/`](./skill/) that you copy into your own workspace or user profile.

> **Folder name must match `name`.** When you install the skill, the destination folder **must** be named `vllm-xeon-cpu` (matching the `name:` field in the skill's frontmatter). Otherwise the agent will not discover it.

Install the skill once per workspace or user profile. Pick the install path for your agent runtime:

| Runtime | Install path | Notes |
| --- | --- | --- |
| GitHub Copilot (workspace) | `.github/skills/vllm-xeon-cpu/` | Shared with everyone working in the repo and with the Copilot coding agent on PRs / issues. |
| GitHub Copilot (personal) | `~/.copilot/skills/vllm-xeon-cpu/` | Available across all your workspaces; not shared. |
| Claude Code (workspace) | `.claude/skills/vllm-xeon-cpu/` | Shared via the repo. |

### GitHub Copilot — Repo Workspace

```bash
mkdir -p .github/skills/vllm-xeon-cpu
curl -L https://github.com/intel/optimization-zone/archive/refs/heads/main.tar.gz \
  | tar -xz --strip-components=4 -C .github/skills/vllm-xeon-cpu \
      optimization-zone-main/software/vllm/skill
```

### GitHub Copilot — User profile

```bash
mkdir -p ~/.copilot/skills/vllm-xeon-cpu
curl -L https://github.com/intel/optimization-zone/archive/refs/heads/main.tar.gz \
  | tar -xz --strip-components=4 -C ~/.copilot/skills/vllm-xeon-cpu \
      optimization-zone-main/software/vllm/skill
```

### Claude Code — Repo Workspace

```bash
mkdir -p .claude/skills/vllm-xeon-cpu
curl -L https://github.com/intel/optimization-zone/archive/refs/heads/main.tar.gz \
  | tar -xz --strip-components=4 -C .claude/skills/vllm-xeon-cpu \
      optimization-zone-main/software/vllm/skill
```

After install, invoke from chat with `/vllm-xeon-cpu` or let the agent auto-load the skill when your request matches keywords like "vLLM", "Xeon".

## References

- [vLLM CPU installation guide](https://docs.vllm.ai/en/stable/getting_started/installation/cpu/)
- [vLLM CPU-supported models](https://docs.vllm.ai/en/stable/models/hardware_supported_models/cpu/)
- [vLLM optimization and tuning guide](https://docs.vllm.ai/en/stable/configuration/optimization/)
- [vLLM bench serve CLI](https://docs.vllm.ai/en/latest/cli/bench/serve.html)
- [vLLM bench latency CLI](https://docs.vllm.ai/en/latest/cli/bench/latency.html)
- [vLLM Intel quantization support](https://docs.vllm.ai/en/stable/features/quantization/inc/)
