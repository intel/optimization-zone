# Cassandra with Intel® QuickAssist Technology (Intel® QAT) Optimization Guide
## Table of Contents

- [Overview](#overview)
- [QAT Hardware Requirement](#qat-hardware-requirement)
- [QAT Software Requirement and Prequisites](#qat-software-requirement-and-prerequisites)
- [Cassandra Configuration](#cassandra-configuration)
- [Building and configuring zlib-accel](#building-and-configuring-zlib-accel)
- [Using Cassandra with zlib-accel](#using-cassandra-with-zlib-accel)
- [Benchmarking Cassandra with QAT](#benchmarking-cassandra-with-qat)
- [Future Enhancements](#future-enhancements)
- [Details](#Details)
- [References](#references)

## Overview

Compression takes up a significant portion of resources in the data center.   Hardware acceleration like Intel® QuickAssist Technology (Intel® QAT) can be used to offload the compression portion of a workload.  Offloading these operations will free up CPU cores to do other work and will improve compress/decompress performance.  The zlib-accel library uses a shim approach to seamless integrate Intel® QAT for compression operations using the Deflate algorithm.  Using zlib-accel allows the user to take advantage of hardware compression with QAT without having to make code changes to the underlying Cassandra codebase.

Without sacrificing compression ratios, zlib-accel with QAT offers higher throughput using a workload of NoSQLBench.  The compression throughput of zlib-accel with QAT is 18% higher than zstd, 98% higher than zlib, and 36% higher than zlib-ng.  CPU cycles per Cassandra operation is also better; compared to zlib, using QAT with zlib-accel uses only 43% of the CPU cycles per Cassandra operation.


## QAT Hardware Requirement

At least one Intel® QAT engine is required and the individual engine might need to be updated in the BIOS.  The following steps should be performed to be reading to use the QAT device(s). 

1.  Check for QAT device availability.  This can be verified by running the following command:

```
echo `(lspci -d 8086:4940 && lspci -d 8086:4941 && lspci -d 8086:4942 && lspci -d 8086:4943 && lspci -d 8086:4944 && lspci -d 8086:4945 && lspci -d 8086:4946 && lspci -d 8086:4947) | wc -l` supported devices found.
```

If a device is found, the output of the command with be:

```
8 supported devices found.
```

2. Verify that the QAT firmware is already loaded by using the following command:

```
ls /lib/firmware/{qat_4xxx,qat_402xx,qat_420xx}.bin* 2>/dev/null
ls /lib/firmware/{qat_4xxx,qat_402xx,qat_420xx}_mmp.bin* 2>/dev/null
```

The output of the above command should include 2 firmware files.  Note that this can vary depending on the exact QAT device on your hardware.

```
 /lib/firmware/qat_402xx.bin
 /lib/firmware/qat_402xx_mmp.bin
```

If the firmware is not already available.  It can be downloaded from the Linux kernel repository:
https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/intel/qat

```
cd ~
wget https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/intel/qat/qat_4xxx.bin
wget https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/intel/qat/qat_4xxx.bin
wget https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/intel/qat/qat_402xx.bin
wget https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/intel/qat/qat_402xx.bin
wget https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/intel/qat/qat_420xx.bin
wget https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/intel/qat/qat_420xx.bin
sudo cp qat_4xxx*.bin qat_402xx*.bin qat_420xx*.bin /lib/firmware
rm qat_4xxx*.bin qat_402xx*.bin qat_420xx*.bin
```

After firmware is updated, the initramfs must be updated.  This differs based on the Linux distribution.  

3.  Verify that the kernel drivers are loaded using the following command.

```
lsmod | grep qat
```

The output should be similar to the following:

```
qat_4xxx               16384  0
intel_qat             172032  1 qat_4xxx
```

If the kernel modules are not found, they can be installed using:

```
sudo modprobe intel_qat
sudo modprobe qat_4xxx
```

If the kernel modules could not be installed, it might be needed to either install them through a kernel configuration or to install that with the distribution's package manger.  

## QAT Software Requirements and Prerequisites

The QAT driver is available either "in-tree" as part of a release kernel or can be built outside of the release.  This document assumes the use of the in-tree driver that is already available with kernel after version 5.19.  The distribution used for this benchmarking was Ubuntu 24.04 with the in-tree driver. 

QATLib provides user space libraries that allows QAT device access and expose APIs for use by higher level applications.  The QATLib driver can be installed using your distributions package manager.  For Ubuntu 24.04:

```
sudo -E apt install -y libqat4 libqat-dev qatlib-service qatlib-examples libusdm-dev
```

QATzip is a user-space library built on top of the Intel® QuickAssist Technology (QAT) user-space library. It provides extended compression and decompression capabilities by offloading these operations to Intel® QAT Accelerators.

```
sudo -E apt install -y qatzip libqatzip3
```

Depending on the use case, the user can configure the number of QAT engines to use with the workload.  In "Managed Mode", the QATLib can be used to restrict the workload to a specific number of engines.

Please note that "intel_iommu=on" will be required as a kernel parameter.

## Cassandra Configuration

The Cassandra configuration mentioned in the base [optimization-zone] (https://github.com/intel/optimization-zone/tree/main/software/cassandra) repository can still be used with zlib-accel.  This Cassandra with QAT/zlib-accel optimization was tested the following software versions:

OpenJDK 17
Cassandra 5.0.6

## Building and configuring zlib-accel

```
mkdir build
cd build
cmake -DDEBUG_LOG -DCOVERAGE=OFF -CMAKE_BUILD_TYPE=Release ..
make
```

Edit /etc/zlib-accel.conf and add the following lines

```
use_qat_compress=1
use_qat_uncompress=1
use_iaa_compress=0
use_iaa_uncompress=0
use_zlib_compress=1
use_zlib_uncompress=1
```

## Using Cassandra with zlib-accel

Once the zlib-accel library has been built, It is simple to use Cassandra to enable hardware compression.

```
LD_PRELOAD=/opt/zlib-accel/build/libzlib-accel.so bin/cassandra -R
```

## Benchmarking Cassandra with QAT

NoSQLBench is used for benchmarking Cassandra.  The results mentioned in the Overview section were generated by using 6 independent Cassandra servers and servers.  The benchmark used a mix of 80% reads and 20% writes using the default CQL timeseries schema.

## Future Enhancements

Support for QAT plugin into Cassandra is in progress and waiting to be upstreamed.  This includes support for ZSTD.  Please refer to the [enhancement proposal] (https://cwiki.apache.org/confluence/display/CASSANDRA/CEP-49%3A+Hardware-accelerated+compression) for more info and the latest status and  on the QAT plugin.


## Details

Cassandra on GNR 128c (Intel Xeon 6980P): 1-node, 2x Intel(R) Xeon(R) 6980P, 128 cores, 500W TDP, HT On, Turbo On, NUMA 6, Total Memory 1536GB (24x64GB DDR5 6400 MT/s [6400 MT/s]), BIOS F23, microcode 0x10003f3, 2x 1350 Gigabit Network Connection, 1x14.3G SanDisk 3.2Gen1, 8x3.5T Samsung MZQL23T8HCL5-00A07, 1x7T Micron_7450_MTFDK8G1T9TFR, Ubuntu 24.04.3  LTS, 6.8.0-86-generic. Test by Intel as of Nov 18, 2025, Apache Cassandra 5.0.5, OpenJDK 64-Bit Server VM 17.0.16, NoSQLBench version 4.15.104

Results may vary.

## References

zib-accel: https://github.com/intel/zlib-accel

NoSQLBench: https://github.com/nosqlbench/nosqlbench

QATLib Users Guide: https://intel.github.io/quickassist/qatlib/index.html
