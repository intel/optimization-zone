# Zstandard (zstd) Compression with Intel® QAT

## Overview

Zstandard (zstd) is a widely used lossless compression format known for fast
compression and decompression with strong compression ratios. Its flexibility
makes it suitable for many types of data and applications.

At a high level, zstd compression has two stages. First, a dictionary coder
such as LZ77 finds repeated data and represents it as sequences containing
matches, offsets, and literals. Then, zstd encodes those sequences using
Finite State Entropy (FSE) or Huffman coding.

## Intel® QuickAssist Technology

Intel® QuickAssist Technology (Intel® QAT) is an integrated workload
acceleration feature on Intel® Xeon® Scalable processors. It is designed to
improve performance and efficiency for compute-intensive workloads, including
AI, analytics, application and content delivery, and high-speed networking.

## Intel® QAT ZSTD Plugin

The Intel® QuickAssist Technology ZSTD Plugin (QAT ZSTD Plugin) accelerates
Zstandard compression using Intel® QAT hardware. Starting with zstd v1.5.4,
the block-level sequence producer API allows custom sequence producers to be
registered. The QAT sequence producer offloads generation of block-level
sequences (literals and matches) to QAT, targeting compression levels L1–L12.
Zstd then post-processes the sequences to produce valid compressed blocks,
preserving compatibility and compression results.

## Performance

Intel® QAT-ZSTD delivers up to **3.2× higher throughput** than zstd compression
level 5 and up to **2.5× higher throughput** than zstd compression level 4.[^1](#test-configuration)

The following compression ratios are reported for the Silesia Corpus:

| Configuration | Compression ratio |
| --- | ---: |
| QAT-ZSTD level 9 | 2.76 |
| zstd level 4 | 2.74 |
| zstd level 5 | 2.77 |

The compression ratio is calculated as the input size divided by the
compressed output size. A higher ratio means the compressed output is smaller
relative to the input.

For more details about the QAT ZSTD Plugin, see the
[Intel® QAT ZSTD Plugin project on GitHub](https://github.com/intel/QAT-ZSTD-Plugin).

<a id="test-configuration"></a>
## [^1] Test Configuration

<div markdown="1" style="font-size: 0.85em;">

### System & Hardware Configuration

- **Processor**: Intel® Xeon® Platinum 8470N Processor (2 sockets, 52 cores per socket)
- **QAT Hardware**: Intel® 4xxx (Intel® QuickAssist Technology Gen 4)
- **Hyper-Threading**: Enabled
- **Turbo Mode**: Disabled
- **SpeedStep (P-states)**: Disabled
- **Memory**: 512 GB (16 × 32 GB DDR5 4800 MT/s)
- **BIOS**: EGSDCRB1.SYS.9409.P01.2211280753
- **Operating System / Kernel**: Ubuntu 22.04.1 LTS (5.15.0-56-generic)
- **QAT Driver**: QAT20.L.1.0.40

### QAT Configuration

- `ServicesEnabled`: `dc`
- `NumberCyInstances`: `0`
- `NumberDcInstances`: `1-64`
- SVM & ATS: Disabled

### Software & Workload

- **Zstandard**: [v1.5.5](https://github.com/facebook/zstd/releases/tag/v1.5.5)
- **QAT ZSTD Plugin**: [v0.0.1](https://github.com/intel/QAT-ZSTD-Plugin/releases/tag/v0.0.1)
- **Benchmark Tool**: Included with Intel® QAT ZSTD Plugin
- **Test File**: [Silesia corpus](http://sun.aei.polsl.pl/~sdeor/corpus/silesia.zip)
- **Tuning**: Disable `searchForExternalRepcodes`
- **Test Command**:
  ```bash
  ./benchmark -m${mode} -l1 -t${threads} -c${blocksize} -L${compression_level} -E2
  ```
- **Example**:
  ```bash
  numactl -C 1-18,105-122 ./test/benchmark -l2 -t36 -L9 -c16K -m1 -E2 silesia.concat
  ```

### More Details

Test by Intel as of 05/22/23. 1-node, 2x Intel(R) Xeon(R) Platinum 8470N, 52 cores, HT On, Turbo On, Total Memory 512GB (16x32GB DDR5 4800 MT/s [4800 MT/s]), BIOS EGSDCRB1.SYS.9409.P01.2211280753, microcode 0x2b000161, 2x 223.6G KINGSTON SUV400S37240G, 1x 447.1G INTEL SSDSC2BB480G7, 1x 240M Disk, Ubuntu 22.04.1 LTS, 5.15.0-56-generic, GCC 11.3.0, QAT ZSTD: v1.5.5, QAT-ZSTD-Plugin: v0.0.1, QAT Driver: QAT20.L.1.0.40.

</div>
