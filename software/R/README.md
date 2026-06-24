# R Optimization Guide

This guide describes best practices for ensuring optimal performance in data-related workflows in the [R](https://www.r-project.org/) language, whether by tuning configurations or by slightly modifying workflows. It covers data preparations, model fitting, and model serving workflows.

## Contents

* [Backends behind R](#backends-behind-r)
    * [BLAS and LAPACK](#blas-and-lapack)
        * [System installs](#system-installs)
            * [Linux](#linux)
            * [Windows](#windows)
        * [Conda environments](#conda-environments)
        * [Verifying backends](#verifying-backends)
    * [OpenMP](#openmp)
    * [oneMKL configurations](#onemkl-configurations)
* [Enabling SIMD in packages](#enabling-simd-in-packages)
    * [Using oneMKL with Eigen](#using-onemkl-with-eigen)
    * [Building from source on Windows](#building-from-source-on-windows)
* [Parallelism in R](#parallelism-in-r)
    * [Parallelizing compilation](#parallelizing-compilation)
    * [Serving models](#serving-models)
* [Data frame operations](#data-frame-operations)
* [Sparse data formats](#sparse-data-formats)

**********************************************

## Backends behind R

Being a statistical language, workflows in R usually involve computations on matrices and vectors, such as matrix multiplications, factorizations, solutions to linear systems, among others. When it comes to matrix/vector operations, R typically calls BLAS and LAPACK libraries as backends behind the scenes (e.g. when performing a matrix multiplication) - there are multiple versions of these from different vendors, and by default, R might not use the version that's most performant for a given hardware configuration.

Within these BLAS and LAPACK libraries, and when it comes to R packages with extensions such as `data.table`, operations might be parallelized across multiple CPU cores/threads, typically using an OpenMP backend to achieve this. Just like with BLAS/LAPACK, there are also different OpenMP backends from different vendors that can have different performance on different hardware, and R's defaults might not be the most optimal, particularly when it comes to CPUs with heterogeneous cores (P-cores and E-cores).

### BLAS and LAPACK

These libraries provide low-level functionalities for linear algebra operations, and are used by both base R and R packages alike for purposes such as multiplying matrices, factorizing matrices, solving linear systems in different forms, among others. Different versions of BLAS and LAPACK can show very different performance, and just picking the right backend with the right configuration might be able to speed up some workflows by 1 or 2 orders of magnitude without further changes.

It is highly recommended to use Intel's [oneMKL](https://www.intel.com/content/www/us/en/developer/tools/oneapi/onemkl.html) as BLAS and LAPACK backend for optimal performance on Intel CPUs, especially when it comes to cutting-edge hardware. Note that, depending on the operating system and OpenMP backend, it might be necessary to use a non-default oneMKL configuration to ensure things work smoothly, which will be explained below.

#### System installs

##### Linux

On Linux, by default, R will link to a generic `libblas` and `liblapack`. On Debian-based systems, the vendor version behind those can be controlled through the [Debian alternatives system](https://wiki.debian.org/DebianAlternatives). To set oneMKL as the system provider for `libblas` and `liblapack`, after installing it through [Intel's APT packages](https://www.intel.com/content/www/us/en/developer/tools/oneapi/onemkl-download.html?operatingsystem=linux&linux-install=apt), execute the following commands and choose oneMKL (`libmkl_rt.so`) as provider:

```shell
sudo update-alternatives --config libblas.so-x86_64-linux-gnu
sudo update-alternatives --config liblapack.so-x86_64-linux-gnu
```

If oneMKL is installed through means other than APT, one might first need to [source its environment script](https://www.intel.com/content/www/us/en/docs/onemkl/developer-guide-linux/2026-0/setting-environment-variables.html#SETTING-ENVIRONMENT-VARIABLES) **before** executing the commands above:

```shell
source /opt/intel/oneapi/setvars.sh
```

##### Windows

By default, on Windows, R will ship with its own unoptimized reference implementation of BLAS and LAPACK. These can be switched to oneMKL by either copying all oneMKL DLL files to R's binary folder, or by building custom DLLs - see this guide for full instructions:
https://www.intel.com/content/www/us/en/developer/articles/technical/using-onemkl-with-r.html

Alternatively, for an easier way of using R with oneMKL on Windows, one might prefer to install R in a conda environment instead ([miniforge](https://github.com/conda-forge/miniforge) distribution is recommended).

#### Conda environments

If R is installed in a conda environment ([miniforge](https://github.com/conda-forge/miniforge) distribution is recommended) instead of being a system-level install, the backends for BLAS and LAPACK are likewise controllable through generic `libblas` and `liblapack` metapackages whose underlying backend can be modified, but with these being conda packages instead of system packages.

To create a conda environment with an installation of R:
```shell
conda create -n intelenv -c conda-forge r-base
```

Then activate it as follows:
```shell
conda activate intelenv
```

The `R` executable should now come from the conda environment for the rest of the terminal session.

To set oneMKL as the system backend for these libraries, execute the following after activating the desired conda environment:
```shell
conda install -c conda-forge libblas=*=*mkl* liblapack=*=*mkl*
```

**It's highly recommended to install these from the conda-forge channel**, where uploads are performed directly by Intel and the most recent versions are always available, compared to the Anaconda channel. The miniforge distribution by default installs packages exclusively from the conda-forge channel, and as such might be a more desirable choice than others.

Note that if a system has multiple R versions (e.g. system-managed and conda-managed), the R version to use in RStudio Desktop can be managed through environmnet variable `RSTUDIO_WHICH_R`, but this is **not recommended for conda-managed R setups** as it will not pre-activate the conda environment. For desktop usage, one might consider installing RStudio Desktop in the same conda environment and launching it from the command line instead:
```shell
conda install -c conda-forge rstudio-desktop
rstudio
```

On some of the commercial versions of RStudio Server / Posit Workbench, depending on the purchased features, the R interpreter may be selectable graphically from the top-right menu of RStudio.

#### Verifying Backends

To verify which backends for BLAS and LAPACK are being used, execute the following inside R:
```r
sessionInfo()
```

It will show entries for BLAS and LAPACK showing which files (`.so` / `.dll`) provide them. When oneMKL is used, those will have `libmkl_rt` in the name.

### OpenMP

OpenMP is a widely used standard for parallelizing operations across CPU cores/threads, endorsed by CRAN for usage in R packages. Many packages rely on OpenMP for parallelization of computations (e.g. `data.table`, `xgboost`, etc.), and just like for BLAS and LAPACK, the defaults offered by R might not be the most optimal.

It is highly recommended to use LLVM's [LibOMP](https://openmp.llvm.org/design/Runtimes.html#openmp-runtimes) as OpenMP backend, particularly on CPUs with heterogeneous cores. Note that LibOMP was initially developed by Intel as 'Intel OpenMP', but the library was later on upstreamed into the LLVM project. As such, there is also an IntelOMP library providing the same kinds of optimizations, but LibOMP is suggested for broader compatibility with package managers.

**On Linux**, the OpenMP runtime backend that packages use can be modified by either compiling them from source with a modified system-wide R configuration, or in conda environments, by changing the OpenMP backend provider.

The easiest way to make R packages use LibOMP is by installing R in a conda environment instead of using a system-level install. To set LibOMP as OpenMP provider on Linux, execute the following in the conda environment where R is installed:
```shell
conda install _openmp_mutex=*=*_llvm
```

On system-wide installs, when packages from CRAN are compiled from source, if they use OpenMP, they will get compilation flags from R through macros `$SHLIB_OPENMP_CFLAGS` (in C code), `$SHLIB_OPENMP_CXXFLAGS` (in C++ code) and `$SHLIB_OPENMP_FFLAGS` (in Fortran code). These are defined in file `/etc/R/Makeconf`, and can be edited to link to a different OpenMP backend, but note that **this is not recommended** (conda environments are a safer option) as they are prone towards creating incompatibilities with other options there using flag `-fopenmp`. When Clang is used as compiler (which is **not** the default in most Linux distributions) - controlled by other macros in that file such as `$CC` and `$CXX` - replacing `-fopenmp` with `-fopenmp=libomp` in the OpenMP macros should make them link to LibOMP (system packages like `libomp-dev` and `libomp5` are required).

Note again that it is not recommended to manually edit such flags at the sytem level, unless one is entirely sure that it will not create further incompatibilities.

### oneMKL configurations

By default, most R setups will use GNU's LibGOMP as default OpenMP provider. However, onMKL by default might load Intel's OpenMP runtime to parallelize operations, which can cause incompatibilities with packages that load LibGOMP.

If not using LLVM's LibOMP as OpenMP backend (see section above), oneMKL needs to be configured to use LibGOMP as its backend instead to avoid incompatibilities, which can be done by setting the following environment variable:
```shell
export MKL_THREADING_LAYER=GNU
```

**Importantly:** this environment variable needs to be set **before** R is started, otherwise it will have no effect.

On Linux, this can be achieved by defining it in a file such as `/etc/profile`.

On Windows, it can be configured as a user environment variable through the control panel.

## Enabling SIMD in packages

On Linux, when installing R packages from CRAN which contain native extensions (code written in compiled languages such as C, C++, and Fortran), those packages will be compiled from source, using default compiler flags for the platform which will not make the generated binary use SIMD instruction sets available in modern CPUs such as AVX2 or AVX512. Note that lots of compute-heavy operations in R packages happen through calls to BLAS and LAPACK (see previous sections), where usage of SIMD can be enabled by using oneMKL as backend, but many packages still have custom code with vectorizable operations outside of BLAS/LAPACK where these flags can make a large difference, particularly when those packages use `RcppEigen` (such as `glmnet`) or `RcppArmadillo` (such as `rsparse`).

On Windows, packages from CRAN by default will be installed as precompiled binaries with flags set by CRAN, which likewise do not enable usage of SIMD instructions.

To set custom compilation flags that will enable SIMD instructions for R packages, **assuming that the library will be used in the same system** (as opposed to Docker images used in a different machine and similar), create a file `~/.R/Makevars` (or edit the file returned by R function `tools::makevars_user()` if any) with the following contents:
```
PKG_CPPFLAGS += -march=native
PKG_CXXFLAGS += -march=native
PKG_FFLAGS += -march=native
```

Some packages might additionally need the following lines:
```
PKG_CXX11FLAGS += -march=native
PKG_CXX14FLAGS += -march=native
PKG_CXX17FLAGS += -march=native
PKG_CXX20FLAGS += -march=native
PKG_FCFLAGS += -march=native
```

**Importantly:** adding `-march=native` will make the compiler consider all the possible CPU instructions available in the machine where this is being compiled, which is recommended in scenarios such as baremetal systems. If one wishes to create a Docker image or virtual machine, where the hardware that executes the result might not be the same hardware that created the images/containers, usage of `-march=native` might be suboptimal and/or might lead to creating binaries that use instructions that others machines will not support, so one might want to set flags for a specific instruction set instead.

If it is known apriori that the target machine will support a given instruction set such as AVX512, one may use the following:
```
PKG_CPPFLAGS += -mavx512
PKG_CXXFLAGS += -mavx512
PKG_FFLAGS += -mavx512
```

Or for machines that only support AVX2:
```
PKG_CPPFLAGS += -mavx2
PKG_CXXFLAGS += -mavx2
PKG_FFLAGS += -mavx2
```

**Additionally**, one might also want to enable [link-time optimization](https://gcc.gnu.org/wiki/LinkTimeOptimization) by adding a line like the following and adding argument `-flto` to all sections with flags:
```
PKG_LIBS += -flto=auto
PKG_CPPFLAGS += -march=native -flto
PKG_CXXFLAGS += -march=native -flto
PKG_FFLAGS += -march=native -flto
```

Note that this might increase compilation times substantially. See subsequent sections for how to make compilation of packages multi-threaded (thereby making compilation faster).

### Using oneMKL with Eigen

In addition to the flags for SIMD outlined in the previous section, when it comes to packages that use `RcppEigen` (such as `glmnet`), if oneMKL is set as the BLAS/LAPACK provider, one might want to configure those packages to use Eigen's oneMKL backend, which can be more performant than compiler-generated SIMD code even after adding additional flags. This can be achieved by adding the following additional lines in `Makevars`:

```
PKG_CPPFLAGS += -DEIGEN_USE_MKL_ALL
PKG_LIBS += $(LAPACK_LIBS) $(BLAS_LIBS) $(FLIBS)
```

Note again that this will only apply to packages that are installed by compiling them from source after these modifications.

### Building from source on Windows

On Windows, packages distributed by CRAN are precompiled and distributed in binary form, with compilation flags and configurations chosen by CRAN that aim at offering the broadest possible compatibility. If one wishes to compile packages from source in order to enable additional functionalities (such as SIMD flags), it is necessary to install [RTools](https://cran.r-project.org/bin/windows/Rtools/) for system-level installs of R, or conda package `compilers` for conda-managed installs.

With those installed, packages from CRAN can be installed by building them from source as follows:
```r
install.packages(<package name>, type="source")
```

Note again that changing compilation flags for a package will only have an effect if the package is compiled from source after setting the flags.

## Parallelism in R

R is a single-threaded language, but many packages are able to exploit multiple CPU cores to parallelize operations, typically through the OpenMP framework (see previous sections).

By default however, some packages might not be configured to exploit all of the cores available in the machine, and some packages might see better performance when using only physical cores (as opposed to hyperthreads).

The default number of cores for BLAS/LAPACK and for OpenMP used in packages can be configured at runtime through package [RhpcBLASctl](https://cran.r-project.org/web/packages/RhpcBLASctl/index.html), which can also be used to query the number of physical cores in the system:
```r
RhpcBLASctl::get_num_cores()
```

For example, to set the number of OpenMP threads to the number of **virtual threads**:
```r
RhpcBLASctl::blas_set_num_threads(RhpcBLASctl::get_num_procs())
```

Note that some packages see better performance when restricted to the number of physical cores, while others see better performance when using all available threads - this is highly specific to each invidivual package, and is not possible to determine apriori unless documented by the package authors.

Some widely-used packages such as `data.table` and `duckdb` might not follow those variables, and instead use their own configuration. For example, `data.table` by default will use a number of threads that is smaller than the number of physical cores, and their recommendation is not to use hyperthreading - for more optimal performance, can be configured to use all physical cores as follows:
```r
data.table::setDTthreads(RhpcBLASctl::get_num_cores())
```

Although in general, most packages will take the number of threads that they will use as an argument - for instance:
```r
xgboost::xgboost(..., nthreads=RhpcBLASctl::get_num_procs())
```

Be aware that, despite many packages offering a similar argument, when they use BLAS or LAPACK behind the scenes, those libraries will not follow the package setting, relying instead on their own configuration, which in the case of oneMKL amounts to using all threads by default. The number of threads for those can again be controlled through `RhpcBLASctl::blas_set_num_threads`.

If operations involving matrices are parallelized at a higher level in R through process-based parallelism (e.g. `parallel::mcapply`, `parallel::parLapply`), one might want to set the number of BLAS threads to 1 before starting those operations in order to avoid nested parallelism. If packages parallelize their operations **with OpenMP** and those operations involve calls to oneMKL, it will automatically configure its threads to avoid overparallelization, so this kind of configuration is not needed, but other BLAS providers such as OpenBLAS-pthreads (default on Linux) will not do this automatically.

### Parallelizing compilation

Outside of R code execution, one might also want to enable multi-threading in **compilation** of packages that happens during their install. This can be configured by adding a line like the following in the `~/.R/Makevars` file created in earlier sections, assuming a Linux system:
```
MAKEFLAGS += -j$(nproc)
```

### Serving models

Oftentimes, models and routines in R are deployed as microservices with a REST interface for usage in online scenarios.

The most popular framework for building REST applications in R is [PlumbeR](https://www.rplumber.io), but this framework is not concurrent - i.e. requests are processed one at a time, oftentimes not being able to exploit all of the CPU cores in the machine, unless every request involves a very compute-heavy workload (e.g. fitting a model, as opposed to making predictions from a fitted model).

For better performance, assuming requests constitude relatively small tasks, one might want to use [RestRServe](https://restrserve.org) instead, which is able to process requests in parallel through process forking.

Note however that forking-based parallelism brings additional challenges:
* If using LibGOMP as OpenMP runtime, parallelized operations inside a forked process will hang indefinitely. Thus, if LibGOMP (default OpenMP backend) is used, one needs to be careful to disable OpenMP parallelism in all packages that use it - for example through a combination of `RhpcBLASctl::omp_set_num_threads(1)` (can be set globally, no need to do it on a per-request basis) or environment variable `OMP_NUM_THREADS=1`, `data.table::setDTthreads(1)`, and passing arguments like `nthreads=1` to all functions / methods that might trigger parallelism. This is not strictly required if using LibOMP, but if requests are already parallelized at a higher-level through process forking, one will likely observe better performance when disabling nested parallelism.
* Likewise, one might also want to disable BLAS parallelism through `RhpcBLASctl::blas_set_num_threads(1)` or environment variable `MKL_NUM_THREADS=1` (if using oneMKL as BLAS provider) to avoid nested parallelism. Note that environment variables like `MKL_NUM_THREADS` and `OMP_NUM_THREADS` must be set **before** the R process is started.
* Environment changes that happen inside a forked process do not propagate to the parent process - e.g. if a global variable is modified, that modification will be contained to the lifetime of the request where it happened. Some libraries might perform additional operations during the first call to a method like `predict(...)` - for example, if a LightGBM model is loaded through `readRDS`, the first call to `predict` on the resulting object will trigger creation of a C++ handle, which can be a slow operation, and if done in forked processes, every call to `predict` will trigger this again and again. Thus, one might want to call a function like `lgb.restore_handle(model)` globally after `readRDS` but before starting serving requests. This is highly specific to each package so be sure to read their documentation pages. Package [bundle](https://rstudio.github.io/bundle/) might provide alternatives to `saveRDS` and `readRDS` that automate these kinds of operations for _some_ selected packages (but not for LightGBM, for instance).

If requests mostly involve compute-heavy operations (e.g. matrix multiplications, as opposed to fetching data from online databases), it is recommended to limit the number of parallel requests to number of threads or to number of physical cores in the machine, as otherwise requests will compete for resources and this will cause slowdowns and decreased throughput. Likewise, If using [Kubernetes](https://kubernetes.io) (also known as 'k8s'), avoid allocating less than a full CPU core to a compute-heavy pod, and avoid fractional core allocations.

## Data frame operations

Workflows in R typically involve data frame objects, which are two-dimensional tables made of columns of potentially different types (e.g. numeric, integer, character, etc.), as opposed to arrays and matrices which are homogeneous and represented in memory as a contiguous block.

R provides a base class `data.frame` and functions / methods to operate on them, but better performance might be achieved by using other frameworks that built atop of them, especially on systems with many cores where these libraries might be able to use multi-threading to parallelize operations.

The most popular data frame libraries in this regards are [dplyr](https://github.com/tidyverse/dplyr) (together with its [tidyverse](https://tidyverse.org) ecosystem) and [data.table](https://r-datatable.com), both of which offer their own data frame subclasses with additional features, additional methods, and a different syntax for operations.

When it comes to small data and short operations (e.g. reordering columns, summing two columns), `data.table` is usually a good choice. Compared to base R which follows copy-on-write semantics, `data.table` also offers in-place operations which avoid making unnecessary copies of data, and should be preferred for performance-sensitive scenarios. For example:
```r
library(data.table)
df <- data.frame(a=c(1,2), b=c(3,4))
# to convert from base R to data.table:
setDT(df)
# can also do it by copying: dt <- as.data.table(df)
# whereas 'setDT' modifies the object in-place

df[, .(a = a + b, b)] # this copies the data, returns a new object
df[, a := a + b] # this overwrites 'a', doesn't make a copy
```

Note that, while `data.table` will parallelize many operations like joins and group-by, for the most part, it relies on built-in R functions and expects the user to call those base R functions inside `data.table` chains, oftentimes wrapped in `lapply`. In many cases, one might also be able to parallelize those operations **on Linux** by substituting `lapply` calls that operate on many columns with `mclapply`:
```r
df[, lapply(.SD, sqrt)] # single-threaded
df[, parallel::mclapply(.SD, sqrt, mc.cores=RhpcBLASctl::get_num_cores())] # uses multiple cores
```

For larger datasets and for more complex operations, one might instead prefer to use a library that would allow lazy evaluation and automated optimization of query executions - for example, if one wishes to read a data file and summarize some columns but only among rows meeting certain conditions, it would be more efficient to avoid reading unnecessary rows, not load columns that will not be used, and return only the aggregates instead of the full data. These kinds of optimizations are not always possible to craft manually with frameworks like `data.table`, and are oftentimes easy to miss, but can be easily detected by automated optimizers from some libraries.

The most popular lazy-evaluated and optimized frameworks when it comes to in-memory data frames are perhaps [DuckDB](https://cran.r-project.org/web/packages/duckdb/index.html) and [Polars](https://pola-rs.github.io/r-polars/). DuckDB is oriented towards SQL-based workflows, but it can be used to query R data frames that exist in a session - for example:

```r
library(duckdb)
library(DBI)

df <- data.frame(a=c(1,2), b=c(3,4))
conn <- dbConnect(duckdb::duckdb(), dbdir=":memory:", read_only=FALSE)
duckdb_register(conn, "df", df)

dbGetQuery(conn, "SELECT a + b as a, b from df") # will return a data.frame
```

_Tip: do not attempt to compile DuckDB from source using the `Makevars` sketched early as it will try to use several GB of RAM per core. Try lowering the number of compilation threads instead._

As an easier alternative, DuckDB can be used as a backend for `dplyr` through packages [duckdplyr](https://duckplyr.tidyverse.org) (recommended) and `dbplyr`, which makes it easier to create programmatic workflows, all using `dplyr`'s user-friendly syntax:
```r
library(duckplyr)

df <- data.frame(a=c(1,2), b=c(3,4))

df |>
    as_duckdb_tibble() |>
    mutate(a = a + b) |> # lazy operation, only evaluated at 'collect'
    collect() # materializes the result, triggering all lazy operations
```

As another alternative, which might be less performant but cover more functionalities, DuckDB can be used as a database backend for `dbplyr` to perform operations on data frames:
```r
library(duckdb)
library(DBI)
library(dplyr)

df <- data.frame(a=c(1,2), b=c(3,4))
conn <- dbConnect(duckdb::duckdb(), dbdir=":memory:", read_only=FALSE)
duckdb_register(conn, "df", df)

df_dbplyr <- tbl(conn, "df")
df_dbplyr |>
    mutate(a = a + b) |> 
    collect()
```

As yet another alternative that might be able to cover more operations with optimizations, one may also use the [R bindings for Polars](https://pola-rs.github.io/r-polars/), but note that (a) this package is not available from CRAN (see installation instructions in link); (b) it uses custom classes which are not compatible with base R's data frames and which have different print methods and similar; (c) it requires using a less idiomatic syntax which follows the Python bindings of Polars.

Example:

```r
library(polars)

df <- data.frame(a=c(1,2), b=c(3,4))
df_polars <- as_polars_df(df)

result_polars <- (
    df_polars
    $lazy()
    $with_columns(
        a = pl$col("a") + pl$col("b")
    )
    $collect()
)
# to convert to base class
as.data.frame(result_polars)
```

## Sparse data formats

Oftentimes, data of interest might represent something where most values are zero by nature.

For example, if data represents counts or presence/absence of specific words in a text, it is likely that many words will only ever appear in a minority of texts of interest, with their value indicating missingness represented as zero (known as a [bag-of-words](https://en.wikipedia.org/wiki/Bag-of-words_model) representation). Or, if the data consists of `factor` variables with many levels, it is likely that it will need to be encoded as a design matrix where observations will have a '1' for the level they contain and a '0' for everything else, perhaps with an unencoded base level (known as [dummy variables](https://en.wikipedia.org/wiki/Dummy_variable_(statistics))).

If it is expected that more than 90% of the values in data will be zeros, it will usually be more efficient to operate on specialized data formats that only take into account the non-zero values, known as [sparse matrices](https://en.wikipedia.org/wiki/Sparse_matrix). The [Matrix](https://cran.r-project.org/web/packages/Matrix/index.html) library provides a rich variety of classes to represent sparse data and methods to operate efficiently on them (e.g. matrix multiplications, Cholesky factorizations, subsetting columns, etc.). The most relevant classes are `dgCMatrix` (standard CSC format), `dgRMatrix` (standard CSR formats), and `dgTMatrix` (triplets or COO format).

If one wishes to create dummy encodings and it is known that the result will be sparse, functions `sparse.model.matrix` and `fac2sparse` from package `Matrix` can be used to create sparse dummy-encodings out of them, similarly to `model.matrix` from base R which produces dense matrices.

Those sparse objects will be accepted as input by many modeling-related packages, such as `glmnet`, `xgboost`, `ranger`, `rsparse` and others, which have routines to operate efficiently on them.

As a general rule, sparse representations only start being advantageous when the number of non-zeros in the data is less than 10%, but the exact threshold at which switching is optimal can vary a lot by use-case. If the amount of non-zeros is less than 1% however, it is very unlikely that a regular dense data representation would be more efficient when a sparse format is supported.
