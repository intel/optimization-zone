# Intel® Optimized NumPy with oneMKL

This guide describes how to get optimal NumPy performance on Intel® Xeon® processors by using Intel® oneAPI Math Kernel Library (oneMKL) as the backend for linear algebra, FFT, random number generation, and vectorized math. It covers installation, how to activate each optimization with minimal code changes, thread and NUMA tuning, and how to verify that oneMKL is active, along with measured benchmark results.

## Table of contents

- [Where NumPy performance comes from](#where-numpy-performance-comes-from)
- [Accelerating NumPy with oneMKL](#accelerating-numpy-with-onemkl)
  - [Installation](#installation)
- [Optimization levers](#optimization-levers)
  - [Linear algebra: BLAS and LAPACK](#linear-algebra-blas-and-lapack)
  - [FFT: mkl_fft](#fft-mkl_fft)
  - [Random number generation: mkl_random](#random-number-generation-mkl_random)
  - [Vectorized math: mkl_umath](#vectorized-math-mkl_umath)
  - [Threads and NUMA](#threads-and-numa)
- [Verifying oneMKL is active](#verifying-onemkl-is-active)
- [Benchmark results](#benchmark-results)
- [Key considerations](#key-considerations)

---

## Where NumPy performance comes from

NumPy is a thin Python layer over compiled native libraries. The array object and the Python API are NumPy's own, but the arithmetic that dominates runtime is handed off: linear algebra goes to a BLAS/LAPACK library, FFTs to an FFT library, random sampling to a generator, and element-wise math (`sin`, `exp`, `log`) to vectorized loops. How fast NumPy runs is mostly decided by *which* native library each of those calls lands in, not by anything in the Python layer.

That backend is a choice made at install time. conda-forge NumPy ships with OpenBLAS, a solid general-purpose implementation. On Intel® Xeon® it leaves performance on the table, because it does not use the newest AVX-512 code paths that the hardware can run.

## Accelerating NumPy with oneMKL

Intel® oneAPI Math Kernel Library (oneMKL) supplies AVX-512 implementations for every one of those backends on 3rd Gen Intel® Xeon® (Ice Lake) and newer: BLAS, LAPACK, FFT, random number generation, and vectorized math. Pointing NumPy at oneMKL is how you turn that hardware capability into wall-clock speedup, with no change to your NumPy code. Across a representative set of NumPy-heavy workloads this is a 3.95x geomean speedup at one socket; the full breakdown is in [Benchmark results](#benchmark-results).

The speedup arrives in two parts that activate differently, and the distinction matters for the rest of this guide:

- **Linear algebra (BLAS and LAPACK)** turns on automatically once oneMKL is the backend. `np.dot`, `np.matmul`, and `np.linalg.*` route to it with no code change.
- **FFT, random, and vectorized math** come from three separate packages (`mkl_fft`, `mkl_random`, `mkl_umath`). These do not activate on import; you switch them on explicitly in code. NumPy itself stays the standard conda-forge build. As of the 2026.0 release, the Intel® Distribution for Python no longer builds its own NumPy: it installs conda-forge NumPy and layers oneMKL underneath, which is exactly why these three are opt-in rather than baked in.

### Installation

There are two practical ways to get a oneMKL-backed NumPy. conda is recommended because it also lets you control the OpenMP runtime (see [Threads and NUMA](#threads-and-numa)).

**conda.** A single command installs NumPy, SciPy, the three extension packages (mkl_fft, mkl_random, mkl_umath), and the runtime libraries. The BLAS/LAPACK backend is wired to oneMKL automatically; the extensions are installed but still need explicit activation.

```bash
conda create -n idp_env -y python=3.13 intelpython3_full \
  -c https://software.repos.intel.com/python/conda \
  -c conda-forge --override-channels && \
  conda activate idp_env
```

The `python=3.13` may be changed to match your project (3.9–3.14 is supported). NumPy is pulled from conda-forge; the Intel channel supplies oneMKL and the extensions. To add oneMKL to an *existing* conda-forge environment instead of creating a new one, install the MKL-variant BLAS and the extensions in place:

```bash
conda install -y \
  -c https://software.repos.intel.com/python/conda \
  -c conda-forge --override-channels \
  "blas=*=*_intelmkl" \
  mkl mkl_fft mkl_random mkl_umath mkl-service
```

`--override-channels` resolves only from the two named channels, so conda does not mix in an OpenBLAS build from elsewhere.

**pip.** Intel publishes NumPy and SciPy wheels already linked against oneMKL, plus the three extensions, on its pip index. There is no symlink to swap; the wheels arrive pre-linked.

```bash
pip install --index-url https://software.repos.intel.com/python/pypi \
  numpy scipy mkl_fft mkl_random mkl_umath mkl-service
```

Use `--index-url`, not `--extra-index-url`: Intel's index is a partial mirror, and with `--extra-index-url` pip would see PyPI's higher-numbered OpenBLAS wheel and install that instead. Packages Intel does not mirror (for example `threadpoolctl`, used for [verification](#verifying-onemkl-is-active)) install normally from PyPI in a separate step. The Intel wheels cover Linux and Windows (CPython 3.9–3.14); there is no macOS build.

Whichever path you take, set the threading layer before anything imports NumPy. This selects Intel's OpenMP runtime (`libiomp5`) for oneMKL; setting it early matters because mixing OpenMP runtimes in one process hurts performance, as explained under [Threads and NUMA](#threads-and-numa):

```bash
export MKL_THREADING_LAYER=INTEL
```

---

## Optimization levers

Each subsection below is one lever: what it accelerates, when it is worth using, and how to switch it on. The first is automatic; the rest are explicit.

The three explicit extensions share an activation model, and the key point is how little code it takes. Activation is a single one-time call: a **context manager** around a block, best when you want oneMKL for one section and stock NumPy elsewhere, or a **patch/restore pair**, best when oneMKL should stay active for the life of the process. That one call is the only addition. It rewires NumPy's internals so your existing `np.fft.*`, `np.random.*`, and `np.sin`/`np.exp`/`np.log` call sites dispatch to oneMKL with their source unchanged.

Concretely, given an existing function, the only edit is the import-and-activate block at the top. The function body is untouched:

```python
import numpy as np

def analyze(signal):
    spectrum = np.fft.fft(signal)    # -> numpy.fft, then mkl_fft after activation
    power = np.abs(spectrum) ** 2    # -> VML after activation (large arrays)
    return np.log(power + 1.0)       # -> VML after activation (large arrays)

# The only addition: import each extension and activate it once, before calling analyze().
import mkl_fft, mkl_umath
mkl_fft.patch_numpy_fft()
mkl_umath.patch_numpy_umath()

result = analyze(np.random.randn(1_000_000))  # same call, now backed by oneMKL
```

After the two `patch_*` calls, `np.fft.fft` and the ufuncs inside `analyze` dispatch to oneMKL; the function itself never changed. (`mkl_random` has the same `patch_numpy_random()` call, with the reproducibility caveat noted in its section below.) The per-lever benchmarks that follow wrap a block to make the before/after timing explicit in one script, but in real code the import plus one activation call is the whole change.

### Linear algebra: BLAS and LAPACK

This is the lever you get for free. Once oneMKL is the backend, `np.dot`, `np.matmul`, `np.linalg.*`, and everything built on them (covariances, distances, decompositions) run on oneMKL's AVX-512 BLAS and LAPACK with no code change and nothing to activate. It is the largest single contributor to the geomean in [Benchmark results](#benchmark-results).

oneMKL parallelizes these calls across cores by default, so the main thing to manage is *how many* threads it uses, covered under [Threads and NUMA](#threads-and-numa).

### FFT: mkl_fft

`mkl_fft` is a Python interface to oneMKL's Fourier transform functions. It handles arbitrarily strided arrays (non-contiguous, negatively strided, multi-dimensional) directly, without first copying into a contiguous buffer, and covers real and complex data, single and double precision, and in-place and out-of-place transforms. It is worth switching on for any FFT-heavy workload.

The example below times the same `np.fft.fft2(a)` call twice. The call is identical in both runs; the only difference is that the second runs inside the context manager, which reroutes it to oneMKL:

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

Measured on AWS, Intel® Xeon® 6975P-C, 16 cores / 32 threads (HT on), 1 socket, Ubuntu 26.04 LTS. Numbers vary by hardware.

```
stock numpy.fft : 722.7 ms
mkl_fft         : 43.0 ms
speedup         : 16.8x
```

To keep oneMKL active for the whole process rather than a single block, use the patch/restore pair:

```python
mkl_fft.patch_numpy_fft()
result = np.fft.rfft2(a)
mkl_fft.restore_numpy_fft()
```

For SciPy users there is a separate backend:

```python
import scipy.fft
import mkl_fft.interfaces.scipy_fft as mkl_scipy_fft

with scipy.fft.set_backend(mkl_scipy_fft):
    result = scipy.fft.fft2(a)
```

Covered transforms: `fft`, `ifft`, `fft2`, `ifft2`, `fftn`, `ifftn`, `rfft`, `irfft`, `rfft2`, `irfft2`, `rfftn`, `irfftn`, `hfft`, `ihfft`, `fftshift`, `ifftshift`, `fftfreq`, `rfftfreq`.

### Random number generation: mkl_random

`mkl_random` is a Python interface to oneMKL's Vector Statistics Library (VSL). It samples from the same distributions as `numpy.random` but is not a fixed-seed drop-in: the same seed produces a different sequence. Use it when generating large volumes of random data is a bottleneck and you do not depend on reproducing specific values.

It can be used two ways. The **context manager** is the zero-code-change path, like the other extensions: existing `np.random.*` call sites keep working and route through VSL (shown [below](#random-number-generation-mkl_random)). The **explicit `RandomState` API** is a small code change, but it lets you pick the generator and the sampling method, which is how you reach the fastest path. The benchmark below uses the explicit API for exactly that reason: `method='BoxMuller'` is the fast normal sampler.

The example below compares wall time for 100 million normal samples:

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

Measured on AWS, Intel® Xeon® 6975P-C, 16 cores / 32 threads (HT on), 1 socket, Ubuntu 26.04 LTS. Numbers vary by hardware.

```
stock numpy.random : 1302.4 ms
mkl_random         : 286.2 ms
speedup            : 4.6x
```

> **Reproducibility note:** `mkl_random` and `numpy.random` produce different sequences from the same seed. If your tests or simulations depend on specific random values, do not swap them.

`brng='MT19937'` selects the Mersenne Twister generator, matching `numpy.random`'s default algorithm. `method='BoxMuller'` is the faster of oneMKL's two normal-sampling methods; the alternative `'ICDF'` (inverse CDF) is slower but more accurate in the tails.

If you do not need to choose the sampling method, the context manager is the zero-code-change path: existing `np.random.*` calls route through oneMKL VSL with their source untouched, exactly like `mkl_fft` and `mkl_umath`.

```python
with mkl_random.mkl_random():
    arr = np.random.standard_normal(1_000_000)  # backed by oneMKL VSL
```

For parallel Monte Carlo workloads, the `MT2203` family produces statistically independent streams per member ID. Each worker gets its own stream with no coordination or locking:

```python
import mkl_random

n_workers = 4
streams = [
    mkl_random.RandomState(seed=42, brng=("MT2203", i))
    for i in range(n_workers)
]

samples_per_worker = [s.standard_normal(1_000_000) for s in streams]
```

### Vectorized math: mkl_umath

`mkl_umath` swaps oneMKL's Vector Math Library (VML) loops in as the C-level inner loops of NumPy's ufuncs, so call sites using `np.sin`, `np.exp`, `np.log`, and similar get VML acceleration with no source change. It is the lever for transcendental-heavy element-wise math.

VML takes over only above a per-operation minimum array size: roughly 8,192 elements for transcendentals (`sin`, `cos`, `exp`, `log`), 8,000 for `divide`, and 100,000 for `add`/`subtract`/`multiply` in `mkl_umath` 0.4.x. Below those sizes NumPy's native loops continue to run. These cutoffs are `mkl_umath` implementation details and can change between versions; the takeaway for tuning is that the extension helps most on large arrays.

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

Measured on AWS, Intel® Xeon® 6975P-C, 16 cores / 32 threads (HT on), 1 socket, Ubuntu 26.04 LTS. Numbers vary by hardware.

```
stock numpy ufuncs : 135.3 ms
mkl_umath          : 12.9 ms
speedup            : 10.5x
```

To keep the patch active for the whole process, use the patch/restore pair:

```python
mkl_umath.patch_numpy_umath()
out = np.exp(a)
mkl_umath.restore_numpy_umath()
```

In multithreaded code, apply the patch before any threads start computing, or wrap all threads in the context manager. Patching while other threads are mid-computation is unsafe: the ufunc inner-loop pointers are swapped without locking, which can cause incorrect results or a crash in threads simultaneously executing a ufunc.

### Threads and NUMA

The levers above decide *which* code runs; this one decides how many cores it runs on, which on server-grade Xeon is often the difference between a good speedup and a great one. oneMKL parallelizes by default, so the goal is to match its thread count to the hardware and avoid over-subscription.

**Environment variables.**

| Variable | Recommended value | Effect |
|---|---|---|
| `MKL_THREADING_LAYER` | `INTEL` | Use Intel OpenMP (`libiomp5`) |
| `MKL_NUM_THREADS` | physical core count | Cap MKL thread count |
| `MKL_DYNAMIC` | `FALSE` | Disable automatic thread scaling |
| `KMP_AFFINITY` | `granularity=fine,compact,1,0` | Pin threads to physical cores |

`KMP_AFFINITY=granularity=fine,compact,1,0` is appropriate for single-socket systems or when running one process per socket. On multi-socket systems without `numactl` it may bind threads across sockets; verify the actual binding with `KMP_AFFINITY=verbose`.

For workloads that spawn multiple Python processes, reduce oneMKL to one thread per process to avoid over-subscription:

```bash
export MKL_NUM_THREADS=1
export MKL_THREADING_LAYER=SEQUENTIAL
```

This applies to `multiprocessing.Pool`, `concurrent.futures.ProcessPoolExecutor`, and tools like Dask or Ray. Each worker initializes its own oneMKL instance; without capping, N workers × default thread count threads all compete for the same cores.

**Runtime control with mkl-service.** When environment variables are too coarse, `mkl-service` adjusts thread counts at runtime, including per domain:

```python
import mkl

print(mkl.get_version_string())               # confirm MKL version at runtime
print(mkl.get_max_threads())                  # current thread count

mkl.set_num_threads(8)                        # cap all MKL operations
mkl.domain_set_num_threads(1, domain="fft")  # cap FFT specifically
mkl.free_buffers()                            # return MKL scratch memory to OS
```

Valid domain values: `"blas"`, `"fft"`, `"vml"`, `"all"`. (`"pardiso"` is oneMKL's sparse direct solver, not used by NumPy directly.)

**NUMA pinning on multi-socket systems.** Keeping all oneMKL threads within one socket avoids inter-socket memory traffic. The benchmarks in [Benchmark results](#benchmark-results) show 3.95x geomean at one socket versus 3.66x across both on a 2-socket machine; that gap is NUMA overhead, not a compute limit.

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

**OpenMP runtime.** oneMKL's threaded paths run on an OpenMP runtime, and which one gets loaded depends on how NumPy was installed. The Intel pip wheels bundle Intel OpenMP (`libiomp5`), and `MKL_THREADING_LAYER=INTEL` keeps oneMKL on it. conda environments resolve the runtime through the `_openmp_mutex` metapackage, whose default may be GNU's `libgomp`, which is less performant on Intel hardware. To pin LLVM's LibOMP (the upstreamed continuation of Intel OpenMP):

```bash
conda install -c conda-forge _openmp_mutex=*=*_llvm
```

The failure to avoid is loading two OpenMP runtimes in one process (for example `libgomp` pulled in by another library alongside oneMKL's `libiomp5`), which causes thread over-subscription and erratic performance. Keeping `MKL_THREADING_LAYER=INTEL` and a single runtime in the environment avoids it. Switching the OpenMP backend in conda environments is not supported on Windows.

---

## Verifying oneMKL is active

Confirm oneMKL is actually the backend:

```python
from threadpoolctl import threadpool_info
import pprint
pprint.pprint(threadpool_info())
```

Look for `"internal_api": "mkl"`:

```
[{'internal_api': 'mkl',
  'num_threads': 288,
  'threading_layer': 'intel',
  'user_api': 'blas', ...}]
```

`np.show_config()` will show `name: blas, version: 3.9.0` even with oneMKL active. That is expected: it reflects the generic interface NumPy compiled against, not the runtime library. `threadpoolctl` is the reliable check.

Confirm oneMKL is dispatching to hardware:

```bash
MKL_VERBOSE=1 python your_script.py 2>&1 | head -20
```

The output should include lines like:

```
MKL_VERBOSE Intel(R) oneAPI Math Kernel Library 2026.0 ...
MKL_VERBOSE DGEMM(N,N,4096,4096,4096,...) 2.1s CNT=1
```

If only the banner appears and no `DGEMM`/`DFFT`/`VML` lines follow, oneMKL loaded but is not being called.

Confirm the explicit extensions are active (they report `False` until you patch them, which is the most common reason an expected FFT/random/math speedup does not show up):

```python
import mkl_fft, mkl_random, mkl_umath
print(mkl_fft.is_patched())    # True after patch_numpy_fft()
print(mkl_random.is_patched()) # True after patch_numpy_random()
print(mkl_umath.is_patched())  # True after patch_numpy_umath()
```

---

## Benchmark results

The benchmarks are drawn from [npbench](https://github.com/spcl/npbench), an open-source suite of NumPy-heavy scientific workloads. The nine selected cover a representative mix: matrix and vector operations, Cholesky factorization, element-wise transcendentals, and reductions. Measured on Intel® Xeon® 6980P (Granite Rapids), 2 sockets, 128 physical cores per socket, hyperthreading on, SLES 15-SP7. Stock NumPy used OpenBLAS; Intel-optimized NumPy used oneMKL with all three extension patches active. Both ran the same conda-forge NumPy 2.4.3 binary. Results reflect the full setup: BLAS backend plus all three extension patches. Enabling only the BLAS backend without the extension patches produces lower speedups on benchmarks that exercise FFT, random, or transcendental math.

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

**Package versions used in these benchmarks:**

| Package | Version |
|---|---|
| `numpy` | 2.4.3 |
| `mkl` | 2026.0.0 |
| `mkl_fft` | 2.2.0 |
| `mkl_random` | 1.4.0 |
| `mkl_umath` | 0.4.0 |

Intel conda channel: `https://software.repos.intel.com/python/conda`

---

## Key considerations

**The extension packages do not activate themselves.** `mkl_fft`, `mkl_random`, and `mkl_umath` do not replace NumPy functions on import. Use the patch function or context manager. Since the 2026.0 release installs the standard conda-forge NumPy rather than a bundled Intel build, there is no longer anything that wires them up at build time, so explicit activation is required even in the full Intel® Distribution for Python.

**`mkl_random` is not a drop-in for `numpy.random`.** The same seed produces a different sequence. Do not swap it into code that depends on reproducible random values.

**AMX does not apply to standard NumPy operations.** NumPy's `float32` and `float64` operations use oneMKL's AVX-512 code paths. AMX tiles only activate for bfloat16 GEMM, which NumPy does not call natively.
