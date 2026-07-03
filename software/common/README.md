# Introduction

Here are the common recommendations about your system configuration that are beneficial for getting maximum performance from the workloads.

# Contents

- [Energy Performance Bias](#energy-performance-bias-epb)
- [CPU Frequency Scaling](#cpu-frequency-scaling)

## Energy Performance Bias (EPB)

Energy Performance Bias (EPB) is an Intel Xeon hardware setting that controls the trade-off between power consumption and processing performance. For the best performance, it is recommended to set it to `0` (Performance mode).

### On Windows

Run the following command in `cmd`:

```
powercfg -setacvalueindex scheme_current sub_processor PERFEPP 0
```

[More info about `powercfg`](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfenergypreference).

### On Linux

To check the current value of EPB, run:
```
sudo cpupower info
```

To set EPB to Performance mode:
```
sudo cpupower set -b 0
```

## CPU Frequency Scaling

CPU Frequency Scaling is a technique that dynamically adjusts the processor clock speed based on workload demands. It lowers CPU core frequencies during idle periods to reduce power consumption. For better performance, it is recommended to set the clock speed to a higher frequency.

### On Windows 11

Select **Start** > **Settings** > **System** > **Power & battery**.

Under [**Power**](https://support.microsoft.com/en-us/windows/change-the-power-mode-for-your-windows-pc-c2aff038-22c9-f46d-5ca0-78696fdf2de8#category=windows_11) mode, choose the **Best performance** option for **Plugged in** or **On battery**.

### On Linux

Use the CPU scaling governor:

```
sudo cpupower frequency-set --governor performance
sudo x86_energy_perf_policy -c all performance
```

**Note:** If the maximum CPU frequency cannot be achieved, check the [BIOS limitations](https://wiki.archlinux.org/title/CPU_frequency_scaling#BIOS_frequency_limitation).
