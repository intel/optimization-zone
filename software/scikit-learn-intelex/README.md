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

# Workload Configuration

## Hyper-threading (HT)

is an Intel's symultaneous multithreading implementaion that can improve parallelisation of computatons.
When HT is enabled, for each processor core that is physically present, the operating system addresses two logical cores and shares the workload between them when possible. In this case the logical cores located on a single physical core use the same resources.
For the recourse-demanding workloads like scikit-learn-intelex it is recommended to disable HT either in BIOS settings or by modifying the affinity settings of the process.

### On Windows

Hyper-threading can be deteched by running **Task Manager**. The navigate to **Performance** > **CPU** tab.

The number of physical and logical cores are listed in bottom right corner of the tab. I case the number of logical cores is greater, HT is enabled:

![alt text](images/cpu-ht.png)

According to this picture the hyper-threading is enabled on two P-cores. Here is an illustration of the locations of the bits corresponding to those P-cores in the affinity mask of the system:

![alt text](images/cpu-cores-indices-ht.png)

To disable the hyper-threading for a process the affinity mask in binary format should look like:

![alt text](images/cpu-affinity-ht.png)

Which is an equivalent to `2BFF` in hexadecimal format. Run following command to disable HT on Windows:

```
start /affinity 2BFF cmd /c <workload.exe>
```

### On Linux

Hyper-threading can be detected by running `lscpu` utility. Here is the example output for Intel Xeon Platinum 8480+:

```
...
Vendor ID:                               GenuineIntel
Model name:                              Intel(R) Xeon(R) Platinum 8480+
CPU family:                              6
Model:                                   143
Thread(s) per core:                      2
Core(s) per socket:                      56
Socket(s):                               2
...
NUMA node(s):                            2
NUMA node0 CPU(s):                       0-55,112-167
NUMA node1 CPU(s):                       56-111,168-223
...
```


## Low Power Efficient Cores (LPE cores)

are the type of cores available on modern Intel Core processors aimed to manage lightweight background processes independently which allows to power down the main compute tiles and save battery on mobile devices.

For the best performance it is recommended to exclude LPE cores from the list of CPU cores on which the workload is running. The affinity settings of the process have to be modified to acheive this.

### On Windows

Use [Intel Processor Identification Utility](https://www.intel.com/content/www/us/en/download/12136/intel-processor-identification-utility-windows-version.html?wapkw=intel%20processor%20identification) to locate the LPE cores within the system affinity mask

```
start /affinity <HexMask> "program.exe"
```

### On Linux
