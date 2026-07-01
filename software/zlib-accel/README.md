# zlib-accel: Compression Acceleration with Intel Technology

Although zlib is widely used and provides excellent compression ratios, its
relatively high CPU usage can limit overall system performance. The zlib-accel
shim layer addresses this performance bottleneck by leveraging Intel's hardware
acceleration capabilities built into 4th Gen Intel® Xeon® processors and later.
Specifically, it relies on Intel® QuickAssist Technology (Intel® QAT) and
Intel® In-Memory Analytics Accelerator (Intel® IAA). The shim layer's unique
value proposition lies in its transparent approach, which serves as a drop-in
replacement requiring no code modifications. This distinguishes it from other
acceleration solutions that require application modifications for
implementation.

By automatically routing compression workloads to dedicated hardware
accelerators, zlib-accel frees valuable CPU resources for other
applications while simultaneously boosting compression performance.
This transparent integration removes traditional barriers to hardware
acceleration adoption, making it accessible to both legacy applications and new
deployments with little complexity and development overhead. The solution
successfully bridges the gap between specialized hardware requirements and
practical application deployment, which unlocks greater infrastructure value for
increasingly demanding data center environments.

Comprehensive performance evaluations with Apache Cassandra, PostgreSQL, and
RocksDB benchmarking utilities demonstrate substantial improvements in both
throughput and latency. The hardware accelerators consistently outperform not
only standard zlib implementations but also modern optimized compression
algorithms like zstd and LZ4. They also maintain competitive compression
ratios. For more information, refer to the resources linked below.

- [White Paper](https://cdrdv2-public.intel.com/913308/zlib-acceleration-white-paper.pdf)
- [GitHub Repository](https://github.com/intel/zlib-accel)
