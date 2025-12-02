# AWS and GCP PMU Availability Matrices

Full explanation and context for this data can be read in our blog post [Get The Most Out of Your Intel Cloud Infrastructure with Virtual Performance Monitoring Units](https://community.intel.com/t5/Blogs/Tech-Innovation/Cloud/Get-The-Most-Out-of-Your-Intel-Cloud-Infrastructure-with-Virtual/post/1723698).
This directory contains detailed availability matrices for [AWS](AWS) and [GCP](GCP) PMUs (for baremetal instance types) and vPMUs (for virtualized instance types). The .csv files provide specific event and metric availability for the listed instance types. 

Cloud service providers such as Amazon Web Services (AWS) and Google Cloud Platform (GCP) expose Virtual Performance Monitoring Units (vPMUs) on select Intel® Xeon® Processor instances that allow one to measure critical performance parameters like instruction cycles, cache misses, and branch mispredictions. While Intel publishes the complete list of supported performance monitoring (perfmon) events and metrics (refer to https://perfmon-events.intel.com/ and https://github.com/intel/perfmon), virtualized cloud instances typically support only a subset of these capabilities. The files in this directory provide a comprehensive list of available metrics for the instance-types provided. 

## Methodology
`perf stat` was used to collect vPMU data for various instance types on AWS and GCP and separated each event and metric into succeeded and failed per instance type. These two categories are further split into additional categories based on the value `perf stat` returned when collecting each metric.
The commands used to measure each event and metric are shown below:

```bash 
perf stat --timeout 3000 -a -e EVENT stress-ng -m num_cores
```

```bash 
perf stat --timeout 3000 -a -M METRIC stress-ng -m num_cores
```

Each event and metric collection was run for 3000 milliseconds, targeting `stress-ng` matrix multiplication as a load generator to stimulate the system into returning more interesting values from the vPMUs.

## Document Layout

### Succeeded Events and Metrics

Based on the value returned by `perf stat`, these are considered supported by that instance-type.

- **Non-Zero**

  The event or metric returned a non-zero value, so there is high confidence that these are supported.

- **Zero**

  The event or metric returned a value of zero, so while no instances of the event was counted, it's likely that this event just didn't occur within the 100 millisecond sampling window. In most cases, events or metrics reporting zero values indicate that the event or metric is supported.

  Events or metrics reporting zero values are more ambiguous with GCP vPMUs. This is because the mechanism GCP uses to disable events for Standard and Architectural PMU types seems to cause the disabled events—and thus the metrics that use them—to report zero. As such, any GCP metric that reports Zero in Standard or Architectural PMU types but returns a non-zero value in Enhanced, is likely not supported. There may be some cases where a metric reports zero in Enhanced as well as the others where it was disabled, but these cases have not been exhaustively tested in this  data.

- **Not a Number (NaN)**

  A small subset of metrics returned a value of "NaN" indicating that none of the underlying events failed, but after calculating the metric formula, the result was not a number. In the cases that we inspected, these were the result of a divide-by-zero, where the event used in the formula's divisor returned zero.
Refer to the metric formulas, and if all the events are considered supported, the metric is too. If one or more event in the formula is not supported, then the metric is not either.

### Failed Events and Metrics

  Based on the value returned by `perf stat`, these are considered not supported by that instance-type.

- **Not Supported**

  On some occasions, after targeting an event or metric with `perf stat`, the process returned but reported that some events were "not supported". These events and the metrics that use them are not supported by that instance-type.

- **Error**

  Most failed events and metrics were identified when `perf stat` errored out while reading the events. These events are not supported by that instance-type.

