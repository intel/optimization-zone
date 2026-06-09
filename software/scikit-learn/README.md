# Scikit-learn Optimization Guide

This guide describes best practices for ensuring optimal performance in machine learning workflows that use the [scikit-learn](https://scikit-learn.org) Python library, whether by tuning configurations or by slightly modifying workflows. It covers both training and model serving (inference) workflows.

## Contents

* [Extension for scikit-learn](#extension-for-scikit-learn)
* [Backends behind scikit-learn](#backends-behind-scikit-learn)
    * [BLAS and LAPACK](#blas-and-lapack)
    * [OpenMP](#openmp)
    * [Verifying backends](#verifying-backends)
* [Parallelism in scikit-learn](#parallelism-in-scikit-learn)
    * [Serving models (inference)](#serving-models-inference)
        * [Asynchronous calls](#asynchronous-calls)
        * [Concurrent requests in REST frameworks](#concurrent-requests-in-rest-frameworks)
    * [Risk of overparallelization](#risk-of-overparallelization)
    * [Meta-estimators](#meta-estimators)
* [Pipelines and data copies](#pipelines-and-data-copies)
* [Sparse data representations](#sparse-data-representations)
* [Feature selection and feature generation](#feature-selection-and-feature-generation)
* [Natural efficiencies when designing workflows](#natural-efficiencies-when-designing-workflows)
    * [CV estimators](#cv-estimators)
    * [Warm starts](#warm-starts)
    * [Stochastic routines](#stochastic-routines)
    * [Different solvers and parameters](#different-solvers-and-parameters)
    * [Equivalent and near-equivalent estimators](#equivalent-and-near-equivalent-estimators)
        * [Scikit-learn-compatible libraries](#scikit-learn-compatible-libraries)

**********************************************

## Extension for scikit-learn

The easiest way to unlock optimal performance in scikit-learn is to use the [Extension for scikit-learn](https://uxlfoundation.github.io/scikit-learn-intelex), which can monkeypatch the `sklearn` module to use more optimized versions of classes and functions:

```python
from sklearnex import patch_sklearn
patch_sklearn()

from sklearn.linear_model import LogisticRegression # <- will now run faster!

...
LogisticRegression().fit(...)
LogisticRegression().predict(...)
```

No further code changes are required - just a call to `patch_sklearn()` that will affect all the functionalities from scikit-learn covered by the Extension.

See the documentation for more details about what the Extension for scikit-learn covers under its optimizations:
https://uxlfoundation.github.io/scikit-learn-intelex/latest/algorithms.html

The Extension for scikit-learn can be easily installed through package managers such as `pip` and `conda`/`mamba` as package `scikit-learn-intelex`:

```shell
pip install scikit-learn-intelex
```

```shell
conda install -c conda-forge scikit-learn-intelex
```

If a particular use-case is not covered by the Extension, or if one still wishes to use the classes / functions from stock scikit-learn, the rest of this guide will cover other considerations for optimal performance.

## Backends behind scikit-learn

Scikit-learn, being a Python library, calls other lower-level Python libraries behind the scenes that provide functionalities such as operations on data arrays, matrix multiplications, mathematical algorithms such as linear and quadratic solvers, parallelization of functions through sub-processes and thread pools, among others. Those other Python libraries in turn call lower-level native libraries (written in compiled languages), which typically contain highly optimized code for different hardware but where configurations and versions are not very visible to users.

Note that different versions of lower-level libraries are made available from different vendors, but not all of them offer the same kind of performance on the same hardware. By default, scikit-learn and its dependencies will not install the most performant libraries for Intel hardware, and it's oftentimes possible to make things run much faster just by installing different backend libraries, with no changes on user code.

In particular, scikit-learn leverages the following key libraries behind the scenes:
* [NumPy](https://numpy.org).
* [SciPy](https://scipy.org)
* [OpenMP runtimes](https://en.wikipedia.org/wiki/OpenMP) through [Cython](https://cython.org).

NumPy and SciPy in turn leverage [BLAS](https://en.wikipedia.org/wiki/Basic_Linear_Algebra_Subprograms) and [LAPACK](https://en.wikipedia.org/wiki/LAPACK) libraries, which may in turn also leverage OpenMP.

It is highly recommended to use conda environments instead of virtual environments to manage Python packages where possible ([miniforge](https://github.com/conda-forge/miniforge) distribution is recommended), because they allow finer-grained control of key non-Python dependencies used by Python libraries. Alternatively, if using a conda environment is problematic (e.g. Docker containers with complex flows) or not possible due to lacking some dependencies, [Pixi](https://pixi.prefix.dev) might be used as an environment manager that can mix dependencies from different sources such as conda-forge and PyPI.

### BLAS and LAPACK

These libraries are used by NumPy and SciPy for operations involving matrices and linear algebra concepts (e.g. matrix multiplications, eigenvalue decompositions, among others).

By default, if NumPy and SciPy are installed through `pip` from the default PyPI index, they will use [OpenBLAS](https://www.openmathlib.org/OpenBLAS/) as backend for them, and this will also be the case if installing them through `conda` on Linux, but OpenBLAS is not the most optimized backend for Intel hardware, and might not provide optimized operations for the most recently-launched hardware models either. Note that scikit-learn might also make direct usage of these libraries, but it takes from SciPy rather than depending on them directly.

It is highly recommended to use Intel's [oneMKL](https://www.intel.com/content/www/us/en/developer/tools/oneapi/onemkl.html) as BLAS and LAPACK backend for optimal performance, especially when it comes to cutting-edge hardware.

To make NumPy and SciPy (and by extension scikit-learn) use oneMKL as backend, the easiest way is to use a conda environment ([miniforge](https://github.com/conda-forge/miniforge) distribution is recommended), where these backends are explicitly controllable through metapackages `libblas` and `liblapack`. **It's highly recommended to install them from the conda-forge channel**, where uploads are performed directly by Intel and the most recent versions are always available, compared to the Anaconda channel.

* To create a new environment with oneMKL-backed libraries:
    ```shell
    conda create -n intelenv -c conda-forge scikit-learn libblas=*=*mkl* liblapack=*=*mkl*
    ```
* To switch libraries to oneMKL in an existing environment:
    ```shell
    conda install -c conda-forge libblas=*=*mkl* liblapack=*=*mkl*
    ```

    **Note:** in order for this to have an effect, NumPy and SciPy must also have been installed through `conda` in the same environment - if installed from `pip` in a conda environment, they will not use the `libblas` and `liblapack` packages.

If using a conda environment is not possible, versions of NumPy and SciPy using oneMKL can alternatively be installed through the `pip` package manager from Intel's index:
```shell
pip install --index-url https://software.repos.intel.com/python/pypi numpy scipy mkl-service
```

Note that, if these were previously installed from PyPI in a given environment, the command above might not have any effect, in which case one might want to uninstall those packages first (`pip uninstall numpy scipy`), or pass additional arguments to `pip install`:
```shell
pip install -U --force-reinstall --index-url https://software.repos.intel.com/python/pypi numpy scipy mkl-service
```

If NumPy and SciPy are installed as system packages from APT (not recommended as versions will be out of date), similar system libraries `libblas` and `liblapack` can be made to be backed by oneMKL through the Debian alternatives system, after [installing oneMKL through APT](https://www.intel.com/content/www/us/en/developer/tools/oneapi/onemkl-download.html?operatingsystem=linux&linux-install=apt):
https://www.intel.com/content/www/us/en/developer/articles/technical/using-onemkl-with-r.html#inpage-nav-2-undefined

Backends for BLAS and LAPACK mostly affect procedures from scikit-learn that rely on linear algebra, such as linear models and procedures involving covariances, distances, and similar (e.g. [LinearRegression](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.LinearRegression.html), [LogisticRegression](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.LogisticRegression.html), [KMeans](https://scikit-learn.org/stable/modules/generated/sklearn.cluster.KMeans.html), [PCA](https://scikit-learn.org/stable/modules/generated/sklearn.decomposition.PCA.html), [EmpiricalCovariance](https://scikit-learn.org/stable/modules/generated/sklearn.covariance.EmpiricalCovariance.html), etc.), but do not have any effect on tree-based models (e.g. [RandomForestClassifier](https://scikit-learn.org/stable/modules/generated/sklearn.ensemble.RandomForestClassifier.html), [HistGradientBoostingRegressor](https://scikit-learn.org/stable/modules/generated/sklearn.ensemble.HistGradientBoostingRegressor.html), etc.), nor on meta-estimators (e.g. [GridSearchCV](https://scikit-learn.org/stable/modules/generated/sklearn.model_selection.GridSearchCV.html)).

### OpenMP

Scikit-learn uses different forms of parallelization to scale across multiple CPU cores. Some estimators, such as tree-based models like [RandomForestClassifier](https://scikit-learn.org/stable/modules/generated/sklearn.ensemble.RandomForestClassifier.html) and [HistGradientBoostingRegressor](https://scikit-learn.org/stable/modules/generated/sklearn.ensemble.HistGradientBoostingRegressor.html), rely on OpenMP for efficient parallelization, and the backend used for OpenMP can make a large difference in running times, particularly when it comes to heterogeneous CPU architectures.

It is highly recommended to use LLVM's [LibOMP](https://openmp.llvm.org/design/Runtimes.html#openmp-runtimes) as OpenMP backend, but depending on how scikit-learn is installed and used, it might not be the default backend. Note that LibOMP was initially developed by Intel as 'Intel OpenMP', but the library was later on upstreamed into the LLVM project. As such, there is also an IntelOMP library providing the same kinds of optimizations, but LibOMP is suggested for broader compatibility with package managers.

If using scikit-learn in a conda environment on Linux, the OpenMP backend can be controlled through a metapackage `_openmp_mutex`. To make it use LLVM's LibOMP, execute the following command on an existing environment:
```shell
conda install -c conda-forge _openmp_mutex=*=*_llvm
```

Or, to ensure LLVM's LibOMP is used when creating an environment:
```shell
conda create -n intelenv -c conda-forge \
    scikit-learn \
    _openmp_mutex=*=*_llvm \
    libblas=*=*mkl* liblapack=*=*mkl* # <- see previous sections
```

On Windows, switching of OpenMP backends in conda environments is unfortunately not possible.

When packages are installed through `pip` or APT, switching OpenMP backends is unfortunately not as easy unless packages are compiled from source, and the default choice for backend in those channels is usually GNU's LibGOMP, which is not as performant on Intel hardware. Thus, it is recommended to use a conda environment to manage the Python installation, where the OpenMP backend can be easily changed as needed.

### Verifying backends

To verify which backends are being used for BLAS and OpenMP, the following can be executed in the Python environment where scikit-learn will be used:
```shell
python -m threadpoolctl -i sklearn
```

If MKL is being used, it will show an entry like the following:
```json
  {
    "user_api": "blas",
    "internal_api": "mkl",
    "num_threads": <threads>,
    "prefix": "libmkl_rt",
    "filepath": "/path/to/environment/prefix/lib/libmkl_rt.so.3",
    "version": "2026.0-Product",
    "threading_layer": "intel"
  }
```

If LLVM's LibOMP is being used, it will show an entry like the following:
```json
  {
    "user_api": "openmp",
    "internal_api": "openmp",
    "num_threads": <threads>,
    "prefix": "libomp",
    "filepath": "/path/to/environment/prefix/lib/libomp.so",
    "version": null
  }
```

If the `prefix` entry mentions something different, such as `libgomp`, then it means another backend is in usage. Alternatively, if Intel's OpenMP is being used, it will show as `libiomp`.

Note that the command above might return multiple backends - if that happens, the entry that appears first in the list is most likely to be used in practice by scikit-learn.

## Parallelism in scikit-learn

Many estimators and functions in scikit-learn allow an argument `n_jobs` which is used to control parallelism (i.e. running on multiple CPU cores or threads).

By default, most estimators will run single-threaded (`n_jobs=None`), but they can be made to use all available threads (thereby running faster) by passing `n_jobs=-1`. For example:
```python
from sklearn.ensemble import RandomForestRegressor

RandomForestRegressor().fit(...) # <- single threaded, slow
RandomForestRegressor(n_jobs=-1).fit(...) # <- multi threaded, faster
```

Note however that the `n_jobs` argument in scikit-learn does not influence parallelism when that parallelism comes from the BLAS and LAPACK libraries. Those in turn can be controlled through the [threadpoolctl](https://github.com/joblib/threadpoolctl) library.

If using MKL, by default, BLAS and LAPACK operations will be executed using all threads, so no further configuration for them is needed.

### Serving models (inference)

While `n_jobs=-1` is usually desirable for model fitting/training, when it comes to serving a model / estimator (i.e. calling `.predict()`, or "inferencing") after fitting, this might not be the most desirable option, especially if requests consist in predicting on one observation at a time.

For example, models from scikit-learn are typically deployed in the form of HTTP microservices, through tools such as [Flask](https://flask.palletsprojects.com/en/stable/) or [FastAPI](https://fastapi.tiangolo.com) where parallelization of requests is already handled through other tools such as [Gunicorn](https://gunicorn.org) or [Uvicorn](https://uvicorn.dev).

In such cases, one might want to make scikit-learn run each independent model prediction in a single thread. This can be achieved as follows (both conditions are necessary):

1. Setting `n_jobs` to 1 in the estimator object. This can be done either before or after serializing the object for serving:
   ```python
   est = RandomForestRegressor(n_jobs=-1).fit(...)
   ...
   est.set_params(n_jobs=1)
   ```
   
2. Controlling parallelism in BLAS and LAPACK:
   ```python
   import threadpoolctl
   with threadpool_limits(limits=1):
    est.predict(...)
   ```
   
   or
   
   ```python
   from threadpoolctl import ThreadpoolController
   controller = ThreadpoolController()
   controller.limit(limits=1)
   est.predict(...)
   ```
   
Alternatively, when using MKL, threads for BLAS / LAPACK can be controlled by setting an environment variable `MKL_NUM_THREADS=1` before importing any numeric library like NumPy or scikit-learn.

Be aware however that these changes will not necessarily extend to other libraries that might be typically used together with scikit-learn. For example, Polars is likely to be used as an input and/or intermediate format in scikit-learn pipelines, but its number of threads is controlled instead by an environment variable `POLARS_MAX_THREADS`.

Thus, one might want to set multiple environment variables like that in the Python process that will be serving scikit-learn requests:

```shell
export MKL_NUM_THREADS=1
export OMP_NUM_THREADS=1
export POLARS_MAX_THREADS=1
export ARROW_IO_THREADS=1
# etc.
```

Note again that these need to be set **before** importing the libraries that they will affect. For example, if they were to be set inside the Python process instead:

```python
# correct
import os
os.environ["POLARS_MAX_THREADS"] = "1"
import polars as pl

# incorrect - has no effect
import polars as pl
import os
os.environ["POLARS_MAX_THREADS"] = "1"
```

#### Asynchronous calls

When it comes to operations computed through scikit-learn, it is usually not beneficial to use Python asynchronous calls for parallelization, because scikit-learn estimators do not typically perform any operations that could be `await`-ed. Thus, if most of the workload in serving a request comes from calls scikit-learn, one might not get optimal performance out of an asynch framework such as FastAPI. Frameworks with non-asynchronous concurrency are recommended instead, such as Flask + Gunicorn.

#### Concurrent requests in REST frameworks

In most cases, operations performed by scikit-learn objects are compute-heavy, with no disk or network IO being involved, keeping CPU cores fully occupied during their workflow. Hence, trying to run a larger number of scikit-learn operations in parallel / concurrently than the number of threads / cores available in the system will cause the requests to compete for the same resources, resulting in decreased throughput and increased latencies.

To achieve optimal throughput, if the majority of the computational workload in serving a request comes from calls to scikit-learn, it is recommended to limit concurrency in the underlying framework where scikit-learn objects will be served:
* Gunicorn [recommends](https://gunicorn.org/design/#how-many-workers) using `workers = (2 × CPU cores) + 1`, but for scikit-learn-heavy workflows, `workers = CPU cores` is usually a more optimal choice.
* If using [Kubernetes](https://kubernetes.io) (also known as 'k8s'), avoid allocating less than a full CPU core to a scikit-learn-heavy pod.

### Risk of overparallelization

Usually, when it comes to fitting models on large amounts of data, the more CPU cores that are used, the faster the operations will be, but if the amount of data is small, the computational overhead from launching and managing multiple threads or processes can be larger than the operation itself.

Meaning: if the amount of data is small, or if the operation is very fast, one might get better performance when using a single thread, both for scikit-learn and for BLAS / LAPACK.

Likewise, for medium-sized data, it might also be the case that running with a small number of threads provides better performance than either a single thread or all available threads.

When it comes to server-grade hardware, where CPU cores may be organized across sockets and [NUMA](https://en.wikipedia.org/wiki/Non-uniform_memory_access) nodes, it might be beneficial to also limit scikit-learn to run within a single NUMA node, which needs to be done by launching the Python interpreter where scikit-learn is imported under further restrictions, for example through `numactl`:

```shell
numactl --cpunodebind=0 python script_that_runs_sklearn.py
```

On multi-socket and multi-NUMA-node systems, operations that are limited by memory bandwidth and do not scale well to many cores may in some cases also benefit from using interleaved NUMA assignments, which can be triggered as follows:

```shell
numactl --interleave=all script_that_runs_sklearn.py
```

This is particularly useful for training linear models that use iterative procedures in scikit-learn, such as [LogisticRegression](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.LogisticRegression.html), [PoissonRegression](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.PoissonRegressor.html) and [Ridge(solver="lbfgs")](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.Ridge.html).

### Meta-estimators

Scikit-learn offers many "meta-estimator" classes, which are classes that take an estimator object as input and perform multiple operations on it, typically in parallel, such as [GridSearchCV](https://scikit-learn.org/stable/modules/generated/sklearn.model_selection.GridSearchCV.html) which fits a given estimator multiple times with different parameters.

For these, parallelization can happen either at the estimator level (by passing `n_jobs=1` to the meta-estimator, and `n_jobs=-1` to the estimator), or at the meta-estimator level (by passing `n_jobs=-1` to the meta-estimator). In many cases - particularly when OpenMP is involved, such as in tree-based models like [RandomForestClassifier](https://scikit-learn.org/stable/modules/generated/sklearn.ensemble.RandomForestClassifier.html) - parallelization at the estimator level can be faster than at the meta-estimator level, but otherwise, parallelization at the meta-estimator level is typically more performant at the cost of increased memory usage, and allows parallelizing operations in estimators that do not offer an `n_jobs` parameter.

Note that, if estimators come from scikit-learn-compatible libraries instead of from scikit-learn itself, such as [XGBoost](https://xgboost.readthedocs.io/en), then one might need to configure the underlying estimators to use `n_jobs=1` in order to avoid nested parallelism:
```python
from sklearn.model_selection import GridSearchCV
from xgboost import XGBClassifier

...

GridSearchCV(
    estimator=XGBClassifier(n_jobs=1),
    ...
    n_jobs=-1,
).fit(...)
```

Meta-estimators from scikit-learn typically parallelize all their operations through the [joblib](https://joblib.readthedocs.io/en/stable/) library, which by default uses process-level parallelism, but can be also made to use thread-level parallelism, with Python threads.

Note that, if thread-level parallelism is used, for example by configuring joblib as follows before using a scikit-learn meta-estimator:
```python
import joblib
joblib.parallel_config(backend="threading")

from sklearn.model_selection import GridSearchCV
GridSearchCV(..., n_jobs=-1)
```

.. then it will not necessarily limit parallelism in BLAS / LAPACK libraries used by the estimator, for which additional `threadpoolctl` calls might be required:
```python
import threadpoolctl

import joblib
joblib.parallel_config(backend="threading")

from sklearn.model_selection import GridSearchCV

with threadpoolctl.limits(limits=1, user_api="blas"):
    GridSearchCV(..., n_jobs=-1)
```

Be aware that, unless using free-threaded Python interpreters, thread-level parallelism in scikit-learn will not always successfully parallelize workloads, as it can only introduce parallelization in operations that raise the Python [GIL](https://en.wikipedia.org/wiki/Global_interpreter_lock). Thus, the default process-level parallelism might oftentimes be a better choice.

## Pipelines and data copies

Typically, end-to-end solutions involving scikit-learn have multi-step data pipelines, where for example there might be some feature engineering or transformations done before passing data to an estimator, together perhaps with feature selection, hyperparameter tuning, among others. These typically use the [Pipeline](https://scikit-learn.org/stable/modules/generated/sklearn.pipeline.Pipeline.html) class to chain mutliple steps together.

When there are multiple steps in a pipeline, particularly when [Transformer-type](https://scikit-learn.org/stable/glossary.html#term-transformer) objects from scikit-learn are involved (such as [ColumnTransformer](https://scikit-learn.org/stable/modules/generated/sklearn.compose.ColumnTransformer.html)), data might be inefficiently casted, copied, and re-arranged in memory before and after operations.

For example, if one has a tabular dataset in the form of a `DataFrame` object from a library like [Pandas](https://pandas.pydata.org) or [Polars](https://pola.rs), and one wishes to apply  missing value imputations to some columns and standardizatinon before passing the data to an estimator, like this:
```python
import pandas as pd

df = pd.read_parquet(...)
X = df[...]
y = df[...]

from sklearn.compose import ColumnTransformer
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler
from sklearn.impute import SimpleImputer
from sklearn.linear_model import LogisticRegression

pipeline = Pipeline([
    (
        "imputer",
        ColumnTransformer([
            (
                "imputer",
                SimpleImputer(),
                ["colA", "colB"],
            ),
        ], remainder="passthrough"),
    ),
    (
        "standardizer",
        StandardScaler(),
    ),
    (
        "classifier",
        LogisticRegression()
    ),
])

pipeline.fit(X, y)
```

Then what will happen is:
* The `ColumnTransformer` will subset the columns of the `DataFrame` before passing it to the `SimpleImputer` object. The `SimpleImputer`, in turn, will convert the `DataFrame` (a [column-major](https://en.wikipedia.org/wiki/Row-_and_column-major_order) structure, which might not necessarily be a single memory-contiguous array) into a NumPy array (a memory-contiguous array, rather than a collection of columns) before passing it to the next step.
* Then, `ColumnTransformer` will subset the other columns of the `DataFrame` that did not go into the `SimpleImputer`, and will join the result of the `SimpleImputer` - now a NumPy array - with those other columns, which will first need to be converted to NumPy.
* Then, the data will be concatenated into a single, memory contiguous NumPy array, which will then be passed to the `StandardScaler`.
* The `StandardScaler`, in turn, will receive a NumPy array and operate on it, generating another NumPy array as result.

This means the data is copied and casted more than once, whereas it would be more efficient if the `ColumnTransformer` could join `DataFrame` objects, which is just a concatenation of references to columns instead of allocation of a single memory-continuous array as in NumPy objects. The `StandardScaler` in turn will operate with a NumPy array, which in this particular case will be in column-major layout but this is not always guaranteed, while the operations that it performs could be done faster in a column-oriented `DataFrame` object, particularly when using a different `DataFrame` library such as Polars.

These redundancies and inefficiencies could be avoided by configuring either the whole pipeline or the transformer objects to use `DataFrame` (recommended to use Polars instead of Pandas) as the format for intermediate steps:
```python
pipeline.named_steps["imputer"].set_output(transform="polars")
pipeline.named_steps["standardizer"].set_output(transform="polars")
pipeline.fit(X, y)

# or

pipeline.set_output(transform="polars")
pipeline.fit(X, y)

# or

from sklearn import config_context
with config_context(transform_output="polars"):
    pipeline.fit(X, y)
```

## Sparse data representations

Oftentimes, data of interest might represent something where most values are zero by nature.

For example, if data represents counts or presence/absence of specific words in a text, it is likely that many words will only ever appear in a minority of texts of interest, with their value indicating missingness represented as zero (known as a [bag-of-words](https://en.wikipedia.org/wiki/Bag-of-words_model) representation). Or, if the data consists of categorical variables with many possible categories, it is likely that it will need to be encoded as a design matrix where each categorical feature spans a number of columns equals to its categories and observations will have a '1' for the category they contain and a '0' for everything else (known as [one-hot encoding](https://en.wikipedia.org/wiki/One-hot)).

If it is expected that more than 90% of the values in data will be zeros, it will usually be more efficient to operate on specialized data formats that only take into account the non-zero values, known as [sparse matrices](https://en.wikipedia.org/wiki/Sparse_matrix). The SciPy library contains a module dedicated to [sparse data](https://docs.scipy.org/doc/scipy/reference/sparse.html), providing classes such as [csr_array](https://docs.scipy.org/doc/scipy/reference/generated/scipy.sparse.csr_array.html) and [csc_array](https://docs.scipy.org/doc/scipy/reference/generated/scipy.sparse.csc_array.html#scipy.sparse.csc_array) implementing many common operators and methods for tabular data.

Many scikit-learn transformers and estimators (such as [LogisticRegression](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.LogisticRegression.html)) support input data in sparse formats from the SciPy library and can operate efficiently on them. Additionally, some transformer classes can output data in sparse format when it is advantageous, such as [OneHotEncoder](https://scikit-learn.org/stable/modules/generated/sklearn.preprocessing.OneHotEncoder.html) which allows an argument `sparse_output`.

As a general rule, sparse representations only start being advantageous when the number of non-zeros in the data is less than 10%, but the exact threshold at which switching is optimal can vary a lot by use-case. If the amount of non-zeros is less than 1% however, it is very unlikely that a regular dense data representation would be more efficient when a sparse format is supported.

Note that the Pandas library also supports `DataFrame` formats in which columns can be sparse, but scikit-learn will only interpret such objects as being sparse if every single column in them is in a sparse format.

## Feature selection and feature generation

Many estimators and meta-estimators in scikit-learn can be used to perform feature selection, whether implicitly or explicitly.

For example, [LogisticRegression](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.LogisticRegression.html) allows an `l1_ratio` argument, where values larger than zero may make some (usually many) coefficients exactly equal to zero in the solution, which means some features will have no effect in the numbers calculated when calling `.predict()` or `.predict_proba()` - i.e. they are selected out.

Due to the way in which scikit-learn works however, even if features are not used by an estimator, if the features existed in the data to which the estimator was fitted, then subsequent data passed to methods such as `.predict()` will need to have those features present regardless.

Thus, for more efficient workflows, one might want to re-create minimalistic versions of estimators and pipelines, where only the useful features are present, and avoid having to create the unneeded features in previous steps such as transformers when serving said models / estimators. For example, after determining which coefficients in a `LogisticRegression` model are non-zero, one might want to rebuild a new estimator or pipeline in which the selected-out features are never generated and never passed to the new estimator's `.fit()` method.

Alternatively, if this is not possible or not convenient, if it is known a priori that a feature will not be used (e.g. due to having a coefficient equal to zero), one might save the steps that generate the irrelevant features by filling the data with zeros.

Note that, in the specific case of [LogisticRegression](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.LogisticRegression.html) and [linear models](https://scikit-learn.org/stable/api/sklearn.linear_model.html) for regression and classification (such as [Lasso](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.Lasso.html), [ElasticNet](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.ElasticNet.html), [SGDClassifier](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.SGDClassifier.html), [SGDRegressor](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.SGDRegressor.html), among others), if the amount of selected-in features is less than 10% of the total and one wishes to use that same estimator instead of creating a minimalistic one, one might also consider calling the [sparsify](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.LogisticRegression.html#sklearn.linear_model.LogisticRegression.sparsify) method, which will turn the fitted coefficients into a sparse structure on which computations are typically faster.

## Natural efficiencies when designing workflows

Oftentimes, there are multiple ways of achieving the same end result in scikit-learn workflows, but not all possible ways are equally as fast.

This section highlights a few features and tricks that can have large performance impacts:

### CV estimators

Scikit-learn offers many generic cross-validation tools that are compatible with all or most of their estimators, such as [GridSearchCV](https://scikit-learn.org/stable/modules/generated/sklearn.model_selection.GridSearchCV.html) which can be used to choose optimal hyperparameters (e.g. the "C" argument in [LogisticRegression](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.LogisticRegression.html)), but in some cases, it's possible to exploit mathematical tricks in estimators that can achieve the same result more efficiently.

Several estimators from the [sklearn.linear_model](https://scikit-learn.org/stable/api/sklearn.linear_model.html) module scikit-learn have an analog version with 'CV' as suffix, such as [LogisticRegressionCV](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.LogisticRegressionCV.html) or [ElasticNetCV](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.ElasticNetCV.html), which can perform hyperparameter tuning more efficiently than a generic procedure as performed by GridSearchCV.

When available, 'CV' versions of estimators are recommended to use instead of tools from the `sklearn.model_selection` module.

### Warm starts

Oftentimes, estimators are fitted more than once to different datasets, for example when data is continuously coming in at regular intervals.

If all the datasets to which a given estimator will be fit have the same features and results from refits do not differ as much from each other as they would from random data - which will be the case when fitting incrementally to progressively larger datasets - then one might want to use warm-started routines, which kickstart the mathematical optiization routines done by scikit-learn from where the last solution ended instead of from a blank state.

This can be enabled through the `warm_start` parameter that is offered by some scikit-learn estimators, such as [LogisticRegression](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.LogisticRegression.html) and [MLPClassifier](https://scikit-learn.org/stable/modules/generated/sklearn.neural_network.MLPClassifier.html).

Note that, if multiple refits are done to the same data in order to try out different hyperparameters, it will be faster to use the 'CV' version when available, as those will additionally create an optimal schedule for the order in which the hyperparameters will be tried.

### Stochastic routines

Most estimators in scikit-learn perform mathematical procedures during their `.fit()` method that guarantee an optimal solution in theory, but these procedures might not always scale well to large datasets.

When the amount of data grows large, it might be possible to obtain near-optimal solutions to the same mathematical problem by using sub-samples of the data in batches, which can oftentimes be orders of magnitude faster than a procedure that always uses the full data to guarantee optimality. This is known as [stochastic optimization](https://en.wikipedia.org/wiki/Stochastic_optimization).

Oftentimes, the cross-validated results from a near-optimal stochastic solution might not even differ from those of an optimal solution, particularly when the amount of data grows very large.

Scikit-learn offers stochastic versions of some types of models, for example:
* [SGDClassifier](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.SGDClassifier.html) is a stochastic analog to [LogisticRegression](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.LogisticRegression.html) and [LinearSVC](https://scikit-learn.org/stable/modules/generated/sklearn.svm.LinearSVC.html).
* [SGDRegressor](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.SGDRegressor.html) is a stochastic analog to several regressors such as [ElasticNet](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.ElasticNet.html) or [LinearSVR](https://scikit-learn.org/stable/modules/generated/sklearn.svm.LinearSVR.html).
* [MiniBatchKMeans](https://scikit-learn.org/stable/modules/generated/sklearn.cluster.MiniBatchKMeans.html) is an analog to [KMeans](https://scikit-learn.org/stable/modules/generated/sklearn.cluster.KMeans.html).

As a general rule, when the amount of rows is in the millions, the stochastic variants might be preferable over the regular variants, but this might vary a lot across estimators and datasets - for example, LogisticRegression might scale efficiently to much larger datasets than LinearSVC, and might be competitive against SGDClassifier up to many millions of rows.

### Different solvers and parameters

Many estimators in scikit-learn allow choosing the underlying solver algorithm that will be used during `.fit()`, but the default choice might not always be the most appropriate for the data. For example:
* [LogisticRegression](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.LogisticRegression.html) has a default solver that scales well for L2-regularized problems with both rows and columns, but if the amount of columns is small while the amount of rows is large, then `solver="newton-cholesky"` might provide both better performance and more numerically accurate results. Likewise, for L1-regularized problems on sparse datasets, `solver="liblinear"` might be a better choice.
* [Ridge](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.Ridge.html) can likewise use `solver="cholesky"` which is typically faster than the default `solver="svd"` for dense datasets.
* [GraphicalLasso](https://scikit-learn.org/stable/modules/generated/sklearn.covariance.GraphicalLasso.html) allows a `mode` argument akin to `solver` in other estimators, and the scikit-learn page provides some hints for how to choose it, but does not implement automated heuristics to decide between the options.

Other estimators might perform additional operations by default that might not be required for some use-cases - for example:
* [EmpiricalCovariance](https://scikit-learn.org/stable/modules/generated/sklearn.covariance.EmpiricalCovariance.html) allows an argument `store_precision` (`default=True`) which calculates the inverse of the covariance matrix. Oftentimes, one might be interested in only the covariance matrix and not its inverse, in which case `store_precision=False` will speed up things without any downside.
* [PCA](https://scikit-learn.org/stable/modules/generated/sklearn.decomposition.PCA.html) allows selecting the number of components to produce. The components are deterministic and ordered, so calculating fewer components will not change the results if only a few are used in practice.

### Equivalent and near-equivalent estimators

In some cases, different estimators from scikit-learn might be able to produce the exact same solution when passed different parameters, particularly when it comes to linear models. For example:
* [ElasticNet](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.ElasticNet.html) can mimic the results from [Ridge](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.Ridge.html) with `l1_ratio=0`, from [Lasso](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.Lasso.html) with `l1_ratio=1`, and from [LinearRegression](https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.LinearRegression.html) with `alpha=0`, but it will use more general routines that will be slower than the more specialized ones used by those other classes.
* [SVC](https://scikit-learn.org/stable/modules/generated/sklearn.svm.SVC.html) with `kernel="linear"` can mimic the results from [LinearSVC](https://scikit-learn.org/stable/modules/generated/sklearn.svm.LinearSVC.html), but it does so following less efficient procedures which scale much poorly with number of rows. Same with [SVR](https://scikit-learn.org/stable/modules/generated/sklearn.svm.SVR.html) and [LinearSVR](https://scikit-learn.org/stable/modules/generated/sklearn.svm.LinearSVR.html).

In general, if the same result can be achieved with a more specialized estimator, then it will be faster to do so than with the more general estimator.

Additionally, some estimators follow fitting procedures that might allow mathematical tricks that make the underlying algorithms much faster at the expense of reaching slightly different results, which oftentimes have no impact at all on model quality or cross-validated metrics. For example:
* [Birch](https://scikit-learn.org/stable/modules/generated/sklearn.cluster.Birch.html) can produce almost the same results as [KMeans](https://scikit-learn.org/stable/modules/generated/sklearn.cluster.KMeans.html), but if the data consists of millions of rows and only a handful columns, then Birch will be orders of magnitude faster than either KMeans or MiniBatchKMeans.
* [HistGradientBoostingClassifier](https://scikit-learn.org/stable/modules/generated/sklearn.ensemble.HistGradientBoostingClassifier.html) can produce almost the same results (and oftentimes better) as [GradientBoostingClassifier](https://scikit-learn.org/stable/modules/generated/sklearn.ensemble.GradientBoostingClassifier.html), but HistGradientBoostingClassifier scales much better with increased number of rows in the data, and with larger core counts in CPUs. Note that there is also an analog [HistGradientBoostingRegressor](https://scikit-learn.org/stable/modules/generated/sklearn.ensemble.HistGradientBoostingRegressor.html) for [GradientBoostingRegressor](https://scikit-learn.org/stable/modules/generated/sklearn.ensemble.GradientBoostingRegressor.html).

For large datasets, the near-equivalent variants of estimators are usually preferable, as they scale better and the differences in results become smaller as the amount of data grows.

#### Scikit-learn-compatible libraries

Oftentimes, Python libraries for machine learning offer scikit-learn-compatible interfaces to their algorithms, which in many cases can be swapped in place of scikit-learn estimators.

See the scikit-learn central to learn about other compatible libraries in the ecosystem: <https://scikit-learn-central.probabl.ai/#/catalog>

In many cases, better performance might be obtained by using similar estimators from other libraries. For example:
* [XGBoost](https://xgboost.readthedocs.io/en) provides classes such as `XGBRegressor` and `XGBClassifier` that might be more performant than scikit-learn's `HistGradientBoostingRegressor` and `HistGradientBoostingClassifier`. Same for `XGBRFRegressor` as an analog to `RandomForestRegressor`, but note that estimators are not entirely equivalent (e.g. `XGBRFClassifier` follows a very different methodology from `RandomForestClassifier` in scikit-learn).
* [Glum](https://glum.readthedocs.io/en) provides classes `GeneralizedLinearRegressor` which might be more performant than scikit-learn's `ElasticNet` and `LogisticRegression`, along with a CV analog `GeneralizedLinearRegressorCV`.
* [FAISS](https://faiss.ai/index.html) provides approximate versions of [NearestNeighbors](https://scikit-learn.org/stable/modules/generated/sklearn.neighbors.NearestNeighbors.html#sklearn.neighbors.NearestNeighbors), but note that it does not do so through scikit-learn-compatible interfaces.


See also the Extension for scikit-learn: <https://uxlfoundation.github.io/scikit-learn-intelex>
