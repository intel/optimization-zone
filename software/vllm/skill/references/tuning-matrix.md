# vLLM Xeon CPU Tuning Matrix

Full reference for environment variables and CLI flags relevant to vLLM CPU serving on Intel Xeon, with guard rails. Use alongside [SKILL.md](../SKILL.md) Procedure 3.

## Environment Variables

| Variable | Recommended | Guidance | Why it matters |
| --- | --- | --- | --- |
| `VLLM_CPU_KVCACHE_SPACE` | `40` (GiB) | Per **NUMA node**. Increase for more concurrency / longer context; must fit in node-local memory. Halve if the server OOMs or pages. | KV cache is the dominant CPU memory consumer; under-sizing throttles batching, over-sizing causes paging or OOM. |
| `VLLM_CPU_OMP_THREADS_BIND` | `auto` | Binds OpenMP workers to NUMA-local cores. Manual ranges look like `0-31\|32-63` (one range per NUMA node). Verify with `numastat -p <server_pid>`. | Cross-NUMA memory traffic kills decode throughput. |
| `VLLM_CPU_NUM_OF_RESERVED_CPU` | `1` | Reserves cores for the API server, tokenization, networking, logging, and OS work. Raise on noisy hosts. | Prevents OS / serving overhead from preempting OMP workers. |
| `VLLM_CPU_SGL_KERNEL` | `0` (try `1` for low-latency SLM) | Experimental x86 small-batch kernels. Requires AMX, BF16 weights, and compatible shapes. | Can reduce latency for small-batch serving, but is shape-sensitive. |
| `HF_TOKEN` | *(secret)* | Required for gated Hugging Face models. | Authentication. |

## CLI Flags (`vllm serve` / Docker CMD)

| Flag | Recommended | Guidance | Why it matters |
| --- | --- | --- | --- |
| `--dtype=bfloat16` | always on AMX-capable Xeon | Enables AMX BF16 kernels — the preferred CPU dtype. | Largest single performance lever on 4th Gen+ Xeon. |
| `--tensor-parallel-size` | default for single NUMA; `N` for `N` NUMA nodes | Keeps shards local to NUMA memory. **`6` is currently unsupported on CPU.** | Wrong value forces cross-NUMA traffic or fails to start. |
| `--max-num-batched-tokens` | `2048` online / `4096` offline | Cap on batched tokens per iteration. Higher → better prefill throughput, worse TTFT. | Tradeoff between TTFT and prefill throughput. |
| `--max-num-seqs` | `128` online / `256` offline | Cap on concurrent sequences. Higher → better decode throughput, worse ITL. | Tradeoff between ITL and decode throughput. |
| `--block-size` | leave default until baseline is recorded | Tune only after KV cache / OMP / batched-tokens are stable. | Interacts with KV cache layout; change last. |

## Guard Rails

- **One knob per run.** Vary only one of `VLLM_CPU_KVCACHE_SPACE`, `VLLM_CPU_OMP_THREADS_BIND`, `--max-num-batched-tokens`, `--max-num-seqs`, or `--block-size` between benchmark runs. Save results to JSON and compare.
- **Per-NUMA fit.** `VLLM_CPU_KVCACHE_SPACE` is per NUMA node — total memory consumption is `value × NUMA_node_count`. Confirm against `numactl --hardware` output.
- **NUMA locality check.** After starting the server: `numastat -p $(pgrep -f 'vllm serve|api_server' | head -n1)`. Memory should be concentrated on the expected node(s); large `other_node` numbers indicate mis-binding.
- **Docker capabilities.** Without `--cap-add SYS_NICE` and `--security-opt seccomp=unconfined`, vLLM cannot set NUMA memory policy; you will see `get_mempolicy: Operation not permitted` in logs and weaker placement.
- **Unsupported TP.** `--tensor-parallel-size=6` is currently unsupported on CPU. Use `2`, `4`, or `8` depending on socket / NUMA layout.
- **Reserved cores.** With `VLLM_CPU_NUM_OF_RESERVED_CPU=1`, OMP workers will land on the remaining cores. If serving latency spikes under load, raise the reserved count before re-running benchmarks.
- **AMX absent.** If `lscpu` does not list `amx_tile`, `amx_bf16`, `amx_int8`, BF16 throughput collapses to AVX-512 paths. Warn the user and recommend 4th Gen Xeon or newer instead of further tuning.
- **Quantization order.** Validate functional quality with BF16 first; only then evaluate INT8 / AWQ to reduce weight memory and bandwidth.
