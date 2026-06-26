This chapter contains information about the practicies that lead to better performance of scikit-learn-intelex on Intel CPUs.

# Hardware Configuration

## Energy Performance Bias (EPB)

Is an Intel Xeon hardware setting controlling the trade-off between power consumption and processing performance.
For the best perfomrance it is recommended to set it to `0` - Performance.

### On Windows

Run following command in `cmd`:

```
powercfg -setacvalueindex scheme_current sub_processor PERFEPP 0
```

[More info about `powercfg`](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfenergypreference).

### On Linux

To check the current value of EPB run:
```
sudo cpupower info
```

To set EPB to Performance mode:
```
sudo cpupower set -b 0
```

## CPU Frequency Scaling

is a technique that dynamically adjusts processor clock speed based on workload demands. It lowers CPU cores frequencies during idle periods to reduce power consumption.
For better performance it is recommended to set clock speed to higher frequency.

### On Windows 11

Select **Start** > **Settings** > **System** > **Power & battery**.

Under [**Power**](https://support.microsoft.com/en-us/windows/change-the-power-mode-for-your-windows-pc-c2aff038-22c9-f46d-5ca0-78696fdf2de8#category=windows_11) mode, choose the **Best performance** option for **Plugged in** or **On Battery**.

### On Linux

Use CPU scaling governor:

```
sudo cpupower frequency-set --governor performance
sudo x86_energy_perf_policy -c all performance
```

**Note:** If the maximal CPU frequency cannot be achieved, check the [BIOS limitations](https://wiki.archlinux.org/title/CPU_frequency_scaling#BIOS_frequency_limitation).

## Low Power Efficient Cores (LPE cores)

are the type of cores available on modern Intel Core processors aimed to manage lightweight background processes independently which allows to power down the main compute tiles and save battery on mobile devices.

For the best performance it is recommended to exclude LPE cores from the list of CPU cores on which the workload is running.

# Workload Configuration

## Hyper-threading

is an Intel's symultaneous multithreading implementaion that can improve parallelisation of computatons.
