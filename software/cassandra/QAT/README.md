# Cassandra with Intel® QuickAssist Technology (Intel® QAT) Optimization Guide
## Table of Contents

- [Overview](#overview)
- [QAT Hardware Requirement](#qat-hardware-requirement)
- [QAT Software Requirement](#qat-software-requirement)
- [Cassandra Configuration](#cassandra-configuration)
- [Building and configuring zlib-accel](#building-zlib-accel)
- [Using Cassandra with zlib-accel](#cassandra-with-zlib-accel)
- [Future Enhancements](#future-enhancements)
- [References](#references)

## Overview

Intel® QuickAssist Technology (Intel® QAT) zlib-accel library.

Without sacrificing compression ratios, zlib-accel with QAT offers higher throughput using a workload of NoSQLBench , 18% higher than
zstd, 98% higher than zlib, and 36% higher than zlib-ng.  CPU cycles per Cassandra operation is also better; compared to zlib, using QAT with zlib-accel uses only 43% of the CPU cycles per Cassandra operation.


## QAT Hardware Requirement


At least one Intel® QAT engine is required.  This can be verified by running the following command:

```
echo `(lspci -d 8086:4940 && lspci -d 8086:4941 && lspci -d 8086:4942 && lspci -d 8086:4943 && lspci -d 8086:4944 && lspci -d 8086:4945 && lspci -d 8086:4946 && lspci -d 8086:4947) | wc -l` supported devices found.
```

If a device is found, the output of the command with be:

```
8 supported devices found.
```

Verify that the QAT firmware is already loaded by using the following command:

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
wget https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/intel/qat/qat_4xxx.bin
wget https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/intel/qat/qat_4xxx_mmp.bin
wget https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/intel/qat/qat_402xx.bin
wget https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/intel/qat/qat_402xx_mmp.bin
sudo cp qat_4xxx*.bin qat_402xx*.bin /lib/firmware
rm qat_4xxx*.bin qat_402xx*.bin
```

## QAT Software Requirement

QAT drivers, available in-tree in Linux kernel
QATlib library
QATzip library (v1.3.0 and above)

## Cassandra Configuration

OpenJDK 17
Cassandra 5.0.6

The Cassandra configuration mentioned in the base optimization-zone article.  

https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/tree/intel/qat

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

Once the zlib-accel library has been built, It is simple to use Cassandra to build the 

```
LD_PRELOAD=/opt/zlib-accel/build/libzlib-accel.so bin/cassandra -R
```

## Future Enhancements

Support for QAT plugin into Cassandra is in progress and waiting to be upstreamed.  This includes support for ZSTD and Deflate.

## References


zib-accel: https://github.com/intel/zlib-accel
NoSQLBench: https://github.com/nosqlbench/nosqlbench
