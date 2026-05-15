# Intel® Optimized NumPy with oneMKL

## Table of contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Install](#install)
  - [Option A: Full Intel Distribution for Python](#option-a-full-intel-distribution-for-python)
  - [Option B: Add MKL to an existing conda-forge environment](#option-b-add-mkl-to-an-existing-conda-forge-environment)
- [Activating MKL extensions](#activating-mkl-extensions)
  - [mkl_fft: FFT](#mkl_fft-fft)
  - [mkl_random: random number generation](#mkl_random-random-number-generation)
  - [mkl_umath: vectorized math functions](#mkl_umath-vectorized-math-functions)
- [Thread control](#thread-control)
- [Benchmark results](#benchmark-results)
- [Verification](#verification)
- [Key considerations](#key-considerations)

---

## Overview

conda-forge NumPy ships with OpenBLAS as its linear algebra backend. On Intel® Xeon® processors, replacing that backend with Intel® oneAPI Math Kernel Library (oneMKL) unlocks AVX-512 implementations for BLAS, LAPACK, FFT, random number generation, and vectorized math. The gains vary by workload and thread count; measured results are in the [Benchmark results](#benchmark-results) section below.

---

## Prerequisites

- Intel® Xeon® Scalable processor, 3rd Gen (Ice Lake) or newer
- Linux: Ubuntu 22.04+, RHEL 8.x/9.x, or SLES 15 SP4+
- Python 3.10–3.14
- `conda` package manager

The following command can be used to confirm the CPU model:

```bash
lscpu | grep "Model name"
```

Ice Lake is 3rd Gen Xeon Scalable (model names beginning with 83xx or higher).

This guide uses `conda` for package management. pip-installed NumPy environments are not covered; the `libblas` symlink swap that enables oneMKL is a conda-managed operation.

---

## Install

Option A is recommended for new environments. Option B is suitable for existing conda-forge environments where reinstalling from scratch is not practical.

### Option A: Full Intel® Distribution for Python

A single command installs NumPy, SciPy, the oneMKL extension packages, and the correct runtime libraries, all pre-configured.

```bash
conda create -n idp_env -y python=3.13 intelpython3_full \
  -c https://software.repos.intel.com/python/conda \
  -c conda-forge --override-channels && \
  conda activate idp_env
```

The `python=3.13` version may be changed to match the project's requirements. The supported range is 3.10–3.14.

### Option B: Add oneMKL to an existing conda-forge environment

```bash
conda install -y \
  -c https://software.repos.intel.com/python/conda \
  -c conda-forge --override-channels \
  "blas=*=*_intelmkl" \
  mkl mkl_fft mkl_random mkl_umath mkl-service
```

`--override-channels` ensures packages are resolved only from the two specified channels, preventing conda from mixing in packages from other configured channels that may pull in OpenBLAS.

The following environment variable should be set before running anything that imports NumPy:

```bash
export MKL_THREADING_LAYER=INTEL
```

This tells oneMKL to use Intel's OpenMP runtime (`libiomp5`). Skipping it can cause thread over-subscription when both Intel OpenMP and GNU OpenMP end up loaded in the same process.

---

## Activating MKL extensions

The BLAS swap happens at install time by rewiring the `libblas` symlink. Linear algebra calls (`np.dot`, `np.matmul`, `np.linalg.*`) go through oneMKL automatically from that point on, no code changes needed.

The three extension packages work differently. `mkl_fft`, `mkl_random`, and `mkl_umath` patch NumPy internals at runtime and are inactive at import. Each supports two activation modes. The context manager is recommended when oneMKL acceleration is needed for a specific block of code while stock NumPy behavior is required elsewhere. The patch/restore pair is appropriate when oneMKL should remain active for the lifetime of the process.

### mkl_fft: FFT

`mkl_fft` is a Python interface to Intel® oneAPI Math Kernel Library (oneMKL) Fourier Transform functions. It handles arbitrarily strided arrays (non-contiguous, negatively strided, multi-dimensional) directly, without copying data into a contiguous buffer first. It covers real and complex data, single and double precision, and in-place and out-of-place transforms.

Existing code that calls `np.fft.*` functions works unchanged inside the context manager. No call site modifications are required.

The example below patches `numpy.fft` for the duration of a block and prints the wall time for both:

```python
import timeit
import numpy as np
import mkl_fft

a = np.random.randn(4096, 4096)

stock_ms = timeit.timeit(lambda: np.fft.fft2(a), number=10) / 10 * 1000

with mkl_fft.mkl_fft():
    mkl_ms = timeit.timeit(lambda: np.fft.fft2(a), number=10) / 10 * 1000

print(f"stock numpy.fft : {stock_ms:.1f} ms")
print(f"mkl_fft         : {mkl_ms:.1f} ms")
print(f"speedup         : {stock_ms / mkl_ms:.1f}x")
```

Expected output: Measured on AWS, Intel® Xeon® 6975P-C, 16 cores / 32 threads (HT on), 1 socket, Ubuntu 26.04 LTS. Numbers vary by hardware.

```
stock numpy.fft : 722.7 ms
mkl_fft         : 43.0 ms
speedup         : 16.8x
```

To keep oneMKL active for the whole process rather than a single block, the patch/restore pair can be used:

```python
mkl_fft.patch_numpy_fft()
result = np.fft.rfft2(a)
mkl_fft.restore_numpy_fft()
```

For scipy users, there is a separate backend:

```python
import scipy.fft
import mkl_fft.interfaces.scipy_fft as mkl_scipy_fft

with scipy.fft.set_backend(mkl_scipy_fft):
    result = scipy.fft.fft2(a)
```

Covered transforms: `fft`, `ifft`, `fft2`, `ifft2`, `fftn`, `ifftn`, `rfft`, `irfft`, `rfft2`, `irfft2`, `rfftn`, `irfftn`, `hfft`, `ihfft`, `fftshift`, `ifftshift`, `fftfreq`, `rfftfreq`.

---

### mkl_random: random number generation

`mkl_random` is a Python interface to Intel® oneAPI Math Kernel Library (oneMKL) Vector Statistics Library (VSL). It samples from the same distributions as `numpy.random` but is not a fixed-seed drop-in: the same seed produces different sequences, so do not swap them in code that depends on reproducible values.

The example below compares wall time for generating 100 million normal samples:

```python
import timeit
import numpy as np
import mkl_random

N = 100_000_000

np.random.seed(0)
stock_ms = timeit.timeit(lambda: np.random.standard_normal(N), number=3) / 3 * 1000

rng = mkl_random.RandomState(seed=0, brng='MT19937')
mkl_ms = timeit.timeit(lambda: rng.standard_normal(N, method='BoxMuller'), number=3) / 3 * 1000

print(f"stock numpy.random : {stock_ms:.1f} ms")
print(f"mkl_random         : {mkl_ms:.1f} ms")
print(f"speedup            : {stock_ms / mkl_ms:.1f}x")
```

Expected output: Measured on AWS, Intel® Xeon® 6975P-C, 16 cores / 32 threads (HT on), 1 socket, Ubuntu 26.04 LTS. Numbers vary by hardware.

```
stock numpy.random : 1302.4 ms
mkl_random         : 286.2 ms
speedup            : 4.6x
```

> **Reproducibility note:** `mkl_random` and `numpy.random` produce different sequences from the same seed. If your tests or simulations depend on specific random values, do not swap them.

`brng='MT19937'` selects the Mersenne Twister generator, which matches `numpy.random`'s default algorithm. `method='BoxMuller'` is the faster of the two normal sampling methods oneMKL supports; the alternative is `'ICDF'` (inverse CDF), which is slower but more accurate in the tails.

Existing `numpy.random` calls can be routed through oneMKL without changing call sites:

```python
with mkl_random.mkl_random():
    arr = np.random.standard_normal(1_000_000)  # backed by oneMKL VSL
```

For parallel Monte Carlo workloads, the `MT2203` family produces statistically independent streams per member ID. Each worker receives its own stream with no coordination or locking required:

```python
import mkl_random

n_workers = 4
streams = [
    mkl_random.RandomState(seed=42, brng=("MT2203", i))
    for i in range(n_workers)
]

samples_per_worker = [s.standard_normal(1_000_000) for s in streams]
```

---

### mkl_umath: vectorized math functions

`mkl_umath` exposes Intel® oneAPI Math Kernel Library (oneMKL) Vector Math Library (VML) loops as replacements for NumPy's ufunc inner loops. It is now a standalone package. The patch swaps C-level loop functions inside existing ufuncs, so call sites using `np.sin`, `np.exp`, `np.log`, etc. get VML acceleration without any source changes.

VML takes over above a minimum array size: 8,192 elements for transcendentals (`sin`, `cos`, `exp`, `log`), 8,000 for `divide`, 100,000 for `add`/`subtract`/`multiply`. Smaller arrays continue using NumPy's native loops.

The example below times a transcendental-heavy computation with and without the patch:

```python
import timeit
import numpy as np
import mkl_umath

a = np.linspace(0.0, 2 * np.pi, 10_000_000)

stock_ms = timeit.timeit(lambda: np.sin(a) + np.exp(a) + np.log(np.abs(a) + 1), number=10) / 10 * 1000

with mkl_umath.mkl_umath():
    mkl_ms = timeit.timeit(lambda: np.sin(a) + np.exp(a) + np.log(np.abs(a) + 1), number=10) / 10 * 1000

print(f"stock numpy ufuncs : {stock_ms:.1f} ms")
print(f"mkl_umath          : {mkl_ms:.1f} ms")
print(f"speedup            : {stock_ms / mkl_ms:.1f}x")
```

Expected output: Measured on AWS, Intel® Xeon® 6975P-C, 16 cores / 32 threads (HT on), 1 socket, Ubuntu 26.04 LTS. Numbers vary by hardware.

```
stock numpy ufuncs : 135.3 ms
mkl_umath          : 12.9 ms
speedup            : 10.5x
```

To keep the patch active for the whole process, the patch/restore pair can be used:

```python
mkl_umath.patch_numpy_umath()
out = np.exp(a)
mkl_umath.restore_numpy_umath()
```

In multithreaded code, the patch should be applied before any threads start computing, or all threads should be wrapped in the context manager. Patching while other threads are mid-computation is unsafe: the ufunc inner loop pointers are swapped without locking, which can cause incorrect results or a crash in threads that are simultaneously executing a ufunc.

---

## Thread control

### Environment variables

| Variable | Recommended value | Effect |
|---|---|---|
| `MKL_THREADING_LAYER` | `INTEL` | Use Intel OpenMP (`libiomp5`) |
| `MKL_NUM_THREADS` | physical core count | Cap MKL thread count |
| `MKL_DYNAMIC` | `FALSE` | Disable automatic thread scaling |
| `KMP_AFFINITY` | `granularity=fine,compact,1,0` | Pin threads to physical cores |

`KMP_AFFINITY=granularity=fine,compact,1,0` is appropriate for single-socket systems or when running one process per socket. On multi-socket systems without `numactl`, it may bind threads across sockets. Verify the actual binding with `KMP_AFFINITY=verbose`.

For workloads that spawn multiple Python processes, it is recommended to reduce oneMKL to one thread per process to avoid over-subscription:

```bash
export MKL_NUM_THREADS=1
export MKL_THREADING_LAYER=SEQUENTIAL
```

This applies to `multiprocessing.Pool`, `concurrent.futures.ProcessPoolExecutor`, and tools like Dask or Ray that spawn worker processes. Each worker initializes its own oneMKL instance; without capping, N workers × default thread count threads will all compete for the same cores.

### Runtime control with mkl-service

```python
import mkl

print(mkl.get_version_string())               # confirm MKL version at runtime
print(mkl.get_max_threads())                  # current thread count

mkl.set_num_threads(8)                        # cap all MKL operations
mkl.domain_set_num_threads(1, domain="fft")  # cap FFT specifically
mkl.free_buffers()                            # return MKL scratch memory to OS
```

Valid domain values: `"blas"`, `"fft"`, `"vml"`, `"all"`. (`"pardiso"` is oneMKL's sparse direct solver, not used by NumPy directly.)

### NUMA pinning on multi-socket systems

On multi-socket Intel® Xeon®, keeping all oneMKL threads within one socket avoids inter-socket memory traffic. The benchmarks below show 3.60x geomean at one socket (T=288) vs 2.79x at both sockets (T=576) on a 2x288-core machine. That gap is NUMA overhead, not a compute limit.

Single process, one socket:

```bash
export MKL_NUM_THREADS=<cores_per_socket>
export MKL_THREADING_LAYER=INTEL
numactl --cpunodebind=0 --membind=0 python your_script.py
```

Two data-parallel processes, one per socket:

```bash
numactl --cpunodebind=0 --membind=0 python worker.py &
numactl --cpunodebind=1 --membind=1 python worker.py &
```

---

## Benchmark results

The benchmarks are drawn from [npbench](https://github.com/spcl/npbench), an open-source suite of NumPy-heavy scientific workloads. The nine selected cover a representative mix: matrix and vector operations, Cholesky factorization, element-wise transcendentals, and reductions. Measured on Intel® Xeon® 6980P (Granite Rapids), 2 sockets, 128 physical cores per socket, hyperthreading on, SLES 15-SP7. Stock numpy used OpenBLAS; Intel® optimized numpy used oneMKL with all three patches active. Both ran the same conda-forge numpy 2.4.3 binary. Results reflect the full setup: BLAS backend swap plus all three extension patches active. Enabling only the BLAS swap without the extension patches will produce lower speedups on benchmarks that exercise FFT, random, or transcendental math.

### Geomean speedup by thread count

| Threads | Geomean speedup |
|---|---|
| **128** | **3.95x** |
| 256 | 3.66x |

T=128 fills one socket. T=256 crosses to the second socket, and the NUMA overhead pulls the average down.

### Per-benchmark at T=128 (Intel® Xeon® 6980P)

| Benchmark | Stock NumPy (ms) | Intel NumPy (ms) | Speedup |
|---|---|---|---|
| go_fast | 511 | 30 | **17.0x** |
| gesummv | 543 | 35 | **15.5x** |
| arc_distance | 445 | 67 | 6.6x |
| doitgen | 2,067 | 387 | 5.3x |
| cholesky2 | 1,556 | 430 | 3.6x |
| gemver | 515 | 262 | 2.0x |
| covariance | 1,104 | 689 | 1.6x |
| correlation | 1,141 | 735 | 1.6x |
| softmax | 774 | 553 | 1.4x |

At T=256, threads span both sockets and cross-socket memory traffic reduces speedups across the board. Keeping all threads within one socket (T=128 here) avoids that overhead, which is why the per-benchmark table uses T=128.

---

## Verification

Confirm oneMKL is actually running:

```python
from threadpoolctl import threadpool_info
import pprint
pprint.pprint(threadpool_info())
```

Look for `"internal_api": "mkl"` in the output:

```
[{'internal_api': 'mkl',
  'num_threads': 288,
  'threading_layer': 'intel',
  'user_api': 'blas', ...}]
```

Note: `np.show_config()` will show `name: blas, version: 3.9.0` even with oneMKL active. That's expected. It reflects the generic interface numpy compiled against, not the runtime library. `threadpoolctl` is the reliable check.

Confirm oneMKL is dispatching to hardware:

```bash
MKL_VERBOSE=1 python your_script.py 2>&1 | head -20
```

The output should include lines like:

```
MKL_VERBOSE Intel(R) oneAPI Math Kernel Library 2026.0 ...
MKL_VERBOSE DGEMM(N,N,4096,4096,4096,...) 2.1s CNT=1
```

If only the banner line appears and no `DGEMM`/`DFFT`/`VML` lines follow, oneMKL loaded but isn't being called.

Confirm the extension patches are active:

```python
import mkl_fft, mkl_random, mkl_umath
print(mkl_fft.is_patched())    # True after patch_numpy_fft()
print(mkl_random.is_patched()) # True after patch_numpy_random()
print(mkl_umath.is_patched())  # True after patch_numpy_umath()
```

---

## Key considerations

**The extension packages do not activate themselves.** `mkl_fft`, `mkl_random`, and `mkl_umath` do not replace NumPy functions at import. The patch function or context manager must be used to activate them.

**`mkl_random` is not a drop-in replacement for `numpy.random`.** The same seed produces different sequences. Swapping them in code that depends on reproducible random values is not recommended.

**AMX does not apply to standard NumPy operations.** NumPy's `float32` and `float64` operations use oneMKL's AVX-512 code paths. AMX tiles only activate for bfloat16 GEMM, which NumPy does not call natively.

**Package versions used in the benchmarks above:**

| Package | Version |
|---|---|
| `numpy` | 2.4.3 |
| `mkl` | 2026.0.0 |
| `mkl_fft` | 2.2.0 |
| `mkl_random` | 1.4.0 |
| `mkl_umath` | 0.4.0 |

Intel conda channel: `https://software.repos.intel.com/python/conda`
