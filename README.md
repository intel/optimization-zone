<p align="center">
  <img src="https://github.com/intel/optimization-zone/blob/main/images/logo-classicblue-800px.png?raw=true" alt="Intel Logo" width="250"/>
</p>

# Intel Optimization Zone - Intel Tuning Guides

This repository contains a collection of Intel tuning guides and Intel optimization recipes specifically designed for Software, Workloads, Performance Analysis, Monitoring Tools, and Hardware optimal configurations. Our comprehensive resources include detailed configuration recommendations, performance tuning techniques, and best practices to help you unlock the full potential of your Intel Architecture.

## What You'll Find Here

### 💻 Software Tuning Guides

Comprehensive optimization tuning guides for various software including databases (i.e. Cassandra, MySQL, PostgreSQL), data processing frameworks (i.e. Spark, Gluten), and programming languages (i.e. Java), covering configuration tuning, memory management, and best practices for Intel architectures.

### 🔧 Workloads & Benchmarks

Industry-standard benchmark configurations and execution guides including enabling you to measure, validate, and compare your optimization results against established performance baselines.

### 📊 Performance Analysis & Monitoring Tools

Detailed guides for leveraging performance analysis and monitoring tools to identify bottlenecks, analyze system behavior, and optimize your workloads on Intel hardware.

### ⚙️ Intel Hardware Optimal Configurations

Best practices and configuration recommendations for getting the most out of your Intel architecture, including BIOS settings, CPU tuning, memory optimization, and system-level configurations to efficiency and performance.

### 🚀 Goal

We aim to provide a dynamic resource where users can find the latest optimization strategies, contribute feedback, and report issues.

## Table of Contents

- Software
  - [Cassandra](software/cassandra/README.md)
  - [Gluten](software/gluten/README.md)
  - [Java](software/java/README.md)
  - [Similarity Search](software/similarity-search/README.md)
    - [Redis](software/similarity-search/redis/README.md)
    - [FAISS](software/similarity-search/faiss/README.md)
  - [Spark](software/spark/README.md)
  - [MySQL & PostgreSQL](software/mysql-postgresql/README.md)
- Workloads
  - [Cassandra Stress](workloads/cassandra-stress/README.md)
  - [HPC](workloads/hpc/README.md)
  - [TPC-DS](workloads/tpc-ds/README.md)
  - [TPC-H](workloads/tpc-h/README.md)
- [Performance Analysis and Monitoring Tools](tools/README.md "A summary of the tools included in this directory")
  - [gProfiler](tools/gprofiler/README.md)
  - [PCM](tools/pcm/README.md)
  - [PerfSpect](tools/perfspect/README.md)
  - [VTune Profiler](tools/vtune/README.md)
- Hardware
  - [PMU](hardware/PMU/README.md)

## Contributing

We welcome community contributions to this project. Whether you are an Intel
hardware enthusiast, a software developer, or a performance engineer, your
input is valuable to us. Here are some ways you can contribute:

1. Open Pull Requests: If you have optimization recipes, tuning guides, or any
other relevant content for Intel Hardware, feel free to open a pull request.
Our maintainers, who are Intel engineers with expertise in specific areas, will
review and approve your contributions.

2. Report Issues/Make Suggestions: If you encounter any issues or bugs, or if
you have suggestions for additional materials, or missing any favorite
workloads or software recipes please report them through GitHub issues.

3. Review and Feedback: You can also contribute by reviewing existing content
and providing feedback. This helps us maintain high-quality documentation and
ensures that the information remains up-to-date and relevant.

## License

Unless otherwise stated, documentation in this repository is licensed under
the [Creative Commons Attribution 4.0 International (CC BY 4.0) license](LICENSES/CC-BY-4.0.txt)
and source code snippets included in the documentation are licensed under
the [MIT license](/LICENSE/MIT.txt).

Please check individual files for any exceptions or additional terms.

## Disclaimer

Performance varies by use, configuration and other factors. Learn more on the [Performance Index site](https://edc.intel.com/content/www/us/en/products/performance/benchmarks/overview/). Performance results are based on testing as of dates shown in configurations and may not reflect all publicly available updates. No product or component can be absolutely secure. Your costs and results may vary. Intel technologies may require enabled hardware, software or service activation. See our complete [Legal Notices and Disclaimers](https://www.intel.com/LegalNoticesAndDisclaimers).

© Intel Corporation.  Intel, the Intel logo, and other Intel marks are trademarks of Intel Corporation or its subsidiaries.  Other names and brands may be claimed as the property of others.
