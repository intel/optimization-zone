This workload tuning guide describes the best known practices to optimize performance on Intel Xeon CPUs when running Apache Kafka. Default configurations may vary across hardware vendors, thus this guide helps provide a set of recommended settings for getting the best performance throughput/latency. This document assumes the user is running Kafka in cloud instances, with a section recommending settings for single node benchmarking at the end of the document. 

# This document is organized with the following topics:
- [Document Nomenclature](#document-nomenclature)
- [Kafka Cluster Topology](#kafka-cluster-topology)
  - [Cloud Topology](#cloud-topology)
- [Hardware Configuration Recommendations](#hardware-configuration-recommendations)
  - [CPU](#cpu)
  - [Memory](#memory)
  - [Network](#network)
  - [Storage](#storage)
- [Operating System, Kernel, & Software Configuration](#operating-system-kernel--software-configuration)
  - [Operating System Settings](#operating-system-settings)
  - [Storage Options](#storage-options)
  - [Additional Operating System Configuration](#additional-operating-system-configuration)
- [Kafka Cluster-wide Configuration](#kafka-cluster-wide-configuration)
  - [Encryption](#encryption)
- [Kafka Controller Configuration](#kafka-controller-configuration)
- [Kafka Broker Configuration](#kafka-broker-configuration)
- [Kafka Producer Configuration](#kafka-producer-configuration)
  - [Producer Java Configuration](#producer-java-configuration)
  - [Payload](#payload)
  - [Topic Configuration](#topic-configuration)
- [Kafka Consumer Configuration](#kafka-consumer-configuration)
- [Measurement Process](#measurement-process)
  - [Message Batching](#message-batching)
  - [Throughput Sweeps](#throughput-sweeps)
  - [Evaluation of Performance and System Health](#evaluation-of-performance-and-system-health)
- [Single Node Configuration](#single-node-configuration)
  - [Single-node Topology](#single-node-topology)
  - [Single-node Hardware Recommendations](#single-node-hardware-recommendations)
  - [Single-node BIOS Configuration Recommendations](#single-node-bios-configuration-recommendations)
- [Example System Startup Script](#example-system-startup-script)

# Document Nomenclature
This document uses the following terminology:

- **Client**: Applies only to client systems running the load generator like `kafka-producer-perf-test`, or other benchmarks. Clients can be either Producers or Consumers
- **Server**: Applies only to server systems running the Kafka brokers
- **Single node**: Applies only to systems running Kafka brokers in one socket and producers in another socket for benchmarking in a single bare-metal system
- **Cloud**: Where applicable, notes differences between bare-metal and cloud instances 
- **Message or Record**: Used interchangeably, a message or record is a key-value pair stored by Kafka. The value represents the message contents and the key may be empty as is frequently the case in benchmarking Kafka
- **Topic**: In a Kafka cluster, the top-level logical division of data where a message is sent to a specific topic
- **Producer**: In a Kafka cluster, the producer sends messages to the Kafka cluster on a given topic
- **Partition**: Logical subdivision of a topic. Partition count can be set at topic creation or use defaults from Broker configuration. Messages sent to a given partition maintain temporal ordering. The specific partition can be chosen by a producer at send time or can be selected round-robin.
- **Consumer**: In a Kafka cluster, the consumer reads messages from one or more partitions and one or more topics
- **Controller**: The Kafka server that keeps track of cluster members, topics, and partition locations. Controllers can operate as a stand-alone controller or also participate in the Kafka cluster as a broker.
- **Broker**: The Kafka server process which receives messages from producers and stores them until they are read by other brokers or consumers 

# Kafka Cluster Topology
For Kafka 4.0+, a Kafka cluster consists of a set of brokers, at least one controller which may also function as a broker, producers, and consumers. When testing Kafka in a single system, broker and producer performance may be isolated by pinning each process to separate CPUs. In a cloud deployment, each broker resides in its own instance and a single instance can serve as the load generator and run a set of producers. The Kafka workload is an I/O-intensive workload meaning it needs high performing networking and storage subsystems for good performance. Cloud deployments often enable selecting instances with higher performance or configuring select subsystems like storage for higher performance. Where possible, instances should be selected with enhanced networking and storage.

## Cloud Topology
- One Kafka controller (non-data-broker) running in a small instance, containing at least 4vCPU such as m8i.xlarge. If seeking to build a small cluster, the controller process can run on a broker or on a producer node.
- Four Kafka Brokers running on *4XL systems (16 vCPU) such as m8i.4xlarge. Brokers can scale out to handle higher load on the cluster.
- Scale up Producers running on a large system like m8i.24xlarge or similar; 96vCPU to enable producer scale-up with minimal resource constraints
- Consumers are optional when running a benchmark and can increase the load on the Kafka cluster for a potentially more realistic test. Consumers should typically run a consumer group to evenly distribute the work of reading a topic. Consumer processes should be run on relatively large instances but shouldn't need as many CPU resources as producers.

### Example Cluster and Scaling
  - Controller: one controller process running on the Producer node. Larger clusters with many topics may require additional controllers.
  - Brokers: four Kafka brokers, each running on a m8i.4xlarge instances, each with GP3 storage configured for at least 4000 IOPS and 1000 MBps throughput. Additional brokers can be added to scale out the system or brokers may be moved up to larger instances for scale up.
  - Producer: Producer processes running on an m8i.24xlarge instance. Increase the count of producers running on this system until the results of the producer performance test reaches the desired SLA. If the producer instance approaches saturation of CPU, storage, or network, additional instances may be utilized to scale out the producers.

# Hardware Configuration Recommendations
## CPU
If a Kafka cluster has a specific SLA that it must meet, the Broker nodes should not run at 100% CPU utilization at the risk of increasing latency. Since Kafka is so I/O heavy, a broker's storage and network subsystems are often near full utilization with a somewhat underutilized CPU when a Kafka cluster meets the desired SLA. Additionally, a single Kafka broker does not scale well beyond a single NUMA node or socket so care should be taken when sharing those resources among a set of brokers. Finally, newer CPU generations like m8i typically offer higher performance than older nodes like the m5 generation due to CPU enhancements with each generation. For that reason, it's recommended to use instances with at least 8vCPU, 16vCPU preferred. General-purpose Intel-based systems such as m8i.4xlarge offer a good compromise of CPU and memory resources. When benchmarking Kafka, CPU resources should always be monitored to ensure the Kafka process is not limited by available CPU.

## Memory
The main job of Kafka brokers is to receive and store messages until they're needed. Kafka heavily utilizes the filesystem page cache and its behavior of holding files in free memory until they need to be written back to improve fetch performance for recent messages. For this purpose, any additional free memory, not used by the Kafka JVM, may be utilized as page cache, so additional memory is usually beneficial for Kafka. Additional memory may not improve Kafka's performance on the producer perf test, but can increase the time that older messages are held in cache before writing back to the slower storage medium. 

## Network
In cloud deployments, resources such as network and storage bandwidth can be limited through various mechanisms. When network bandwidth is a limiting resource, many clouds offer network-enhanced instances with higher allotments of network bandwidth. Since Kafka is such a network-intensive workload, it's recommended to use these network-optimized instances when possible. While network-optimized instances may not directly improve Kafka performance, they may increase the robustness of the cluster by removing or minimizing limitations to network performance. Similar to the CPU, network resources should be monitored with telemetry tooling to ensure they are not limiting Kafka performance. 

## Storage
Another potential resource bottleneck in a cloud deployment can be the storage bandwidth of volumes in their default configuration. It's usually possible to increase the I/O operations per second (IOPS) and bandwidth for a volume at creation time. It's recommended that these volumes be configured with at least 4000 IOPS and >=1000 MBps where possible. If storage performance of a single volume that's been configured for maximum throughput is still insufficient to meet an SLA, additional volumes may be attached to brokers or the brokers may be moved to instances with direct-attached NVMes like i7i. As with other system resources, storage telemetry should be monitored to ensure individual devices are not operating beyond their allotted steady-state performance.

# Operating System, Kernel, & Software Configuration
We recommend using the latest LTS version of Linux OS and kernel with current security and performance patches applied. We describe specific versions of Kafka and Java for testing and compatibility.
- **Kafka version**: 4.2.0 is recommended because it released with an enhancement of the producer performance test that enables a warmup before collecting steady-state statistics.
- **Java version**: Java version 17 or 23 are officially supported by Kafka 4.2.0. Do not use Java 8 because it has been deprecated since Kafka 4.0. Additionally, Java 11 is not recommended due to incomplete support for Kafka Connect and Kafka Server. See [Compatibility](https://kafka.apache.org/41/getting-started/compatibility/) for further information.<!--TODO: Update URL with Kafka 4.2 release-->

## Operating System Settings
In this section, we describe some Linux operating system settings that can help optimize storage and networking resources to improve Kafka's request latency performance.

### Operating System Tuning
The Linux adaptive tuning system `tuned` can automatically apply tuning to the operating system based on profiles designed to optimize latency, throughput, power savings, or other goals. For Kafka, we use `tuned` to apply the `latency-performance` profile to improve the response time of Kafka brokers and minimize request latency. 
- `# systemctl enable tuned.service; systemctl start tuned.service; tuned-adm profile latency-performance`
Another system-tuning tool used to improve the latency of Kafka is the tool [perfspect](https://github.com/intel/PerfSpect/). Perfspect is a multifunction tool that can be used to gather system metadata and telemetry as well as view and change various system configuration parameters. In the case of Kafka, we use perfspect to apply the `latency-optimized` profile to the Efficiency Latency Control (ELC) system. ELC is only available on Intel Xeon 6 family of CPUs comprising Granite Rapids processors, which can be found in the m8i series of instances.
- `# perfspect config --elc latency-optimized`

## Storage Options
### Mounting Volumes
Since Kafka is an I/O heavy workload, we want to minimize unnecessary I/O when possible. One way to do this is to use the flags `noatime` and `nodiratime` when mounting volumes to an instance. These flags prevent the filesystem from modifying the access time metadata for files and disks, thereby removing these disk operations. These can be applied as mounting flags in `fstab` or in an ad hoc `mount` command
- `mount -o noatime,nodiratime <storage identifier>`

### Enable Frequent Write-back to Storage (IMPORTANT!)
High storage latency tends to increase the latency of producer requests as the broker's I/O path becomes congested. When storage subsystems are heavily utilized, write-back events where large quantities of data are sent to storage tend to have higher latency than smaller write-backs. To minimize the volume of data written back to storage at each event, we can decrease the amount of data that will sit in the page cache before a write-back is triggered, known as `vm.dirty_background_bytes`. This will cause the kernel to write-back to storage more frequently as this smaller cache fills up. While this will utilize more of the CPU in the kernel context, this additional utilization reduces write bandwidth and latency which helps clear the I/O path to minimize Kafka's request latency. To choose the optimal value for `dirty_background_bytes`, the user should inspect the output of `iostat` to observe how write latency changes with changes to `dirty_background_bytes`. Absent this telemetry monitoring, setting `dirty_background_bytes` to about 400MB seems to work well for most instances.
- Example: for an m8i.4xlarge, with 16 GB of system memory, 400MB would represent about 2.5% of its 16 GB memory. This can be read and written with `sysctl` or echo'd into the proc fs:
  - `sysctl -w vm.dirty_background_bytes=400000000`
  - `echo 400000000 > /proc/sys/vm/dirty_background_bytes`

## Additional Operating System Configuration
Multiple additional settings for the Linux OS can be modified from their defaults to improve Kafka performance. 
See the example at [Example System Startup Script](#example-system-startup-script)

# Kafka Cluster-wide Configuration
Settings in this section apply to all members of the Kafka cluster

## Encryption
These settings enable TLS encryption, but common stores and passwords are not recommended for production clusters. For more information, see [Encryption and Authentication using SSL](https://kafka.apache.org/41/security/encryption-and-authentication-using-ssl/)<!--TODO: update when Kafka 4.2 releases-->
- `ssl.enabled.protocols=TLSv1.2,TLSv1.3`
- Common truststore (copy) between brokers and clients
- Common keystore (copy) between brokers and clients
- Common passwords for `ssl.keystore.password`, `ssl.key.password`, `ssl.truststore.password`
- `ssl.endpoint.identification.algorithm=` (empty for simplified authentication)

# Kafka Controller Configuration
- At least one Controller running in KRaft mode
- Controller doesn't participate in the cluster to separate the controller workload from the broker message-processing workload
  - `process.roles=controller`
- Most other Controller settings can be defaults

# Kafka Broker Configuration
<!--Kafka pre-release candidate for version 4.2, commit ID 4a8ad8ec63953e56b4de2502b74ffa0b8c7f4bab -->
- Kafka 4.2.0 (containing warmup patch from KIP-1052), released on XX/YY/ZZ <!--TODO: update with 4.2 release-->
  - [Downloads | Apache Kafka](https://kafka.apache.org/downloads)
  - [Release Plan 4.2.0 - Apache Kafka - Apache Software Foundation](https://cwiki.apache.org/confluence/display/KAFKA/Release+Plan+4.2.0)
- **Threads**: Increase network and replica fetcher threads since replication is the slow part of producing a message. Increase socket receive and socket send buffers to minimize dropped packets at the network.
  - Example: m8i.4xlarge system with 16 vCPUs
    - `num.network.threads=6`: should be less than or equal to half the CPU cores assigned to a broker
    - `num.io.threads=8`: should be less than or equal to the count of CPU cores assigned to a broker
    - `num.replica.fetchers=2`: increased beyond the default of 2 to improve replication latency
    - `socket.receive.buffer.bytes=102400000`: Increased to 100MB from the default of 100kB to improve network performance
    - `socket.send.buffer.bytes=102400000`: Increased to 100MB from the default of 100kB to improve network performance

- **Broker Heap Size**: Set the Java heap to at least 4GB and prevent the heap from growing or shrinking by using the same value for its minimum size:
  - `export KAFKA_HEAP_OPTS="-Xms4G -Xmx4G"` 
- **Broker Java EXTRA_ARGS**: `"-name kafkaServer -loggc -Xlog:gc* -XX:+PrintFlagsFinal -Xlog:safepoint,gc*,gc+ergo*=trace,gc+age*=trace,gc+phases*=debug:file=$KAFKA_GC_LOG -XX:+AlwaysPreTouch -XX:+UnlockExperimentalVMOptions -XX:G1ReservePercent=2 -XX:G1NewSizePercent=50 -XX:G1MaxNewSizePercent=100`

# Kafka Producer Configuration

## Producer Java Configuration 
When running Producers on systems with high core counts like an m8i.24xlarge which has 92 vCPUs, it's important to limit each JVM's access to Garbage Collection (GC) threads so they don't each attempt to use all the vCPUs in the system. Producers reading from payloads should also increase their heap size to store the payload.
- Each producer only needs a handful of threads for effective GC, so add this to the producer's Java command line:
  - `-XX:ParallelGCThreads=5"` 
- Export this environment variable to set the producer to use a 1GB heap and don't grow or shrink the heap:
  - `export KAFKA_HEAP_OPTS="-Xms1G -Xmx1G"` 

## Payload
When running the kafka producer performance test, producers may generate messages ad hoc or utilize a payload. Utilizing a payload should reduce the compute load on the producers, which helps ensure that the test is only limited by and measuring the performance of the Kafka cluster, rather than the producers themselves. 

For a production cluster, Kafka will usually use a schema to enforce data structure. These data are serialized by producers into a Kafka Message and sent to the cluster. For benchmarking, it's best if a payload can be assembled from data that at least resembles production data, but a payload of a consistent record size can be useful to assess cluster performance under more controlled conditions.

Absent production data, data that can be compressed with a compression ratio similar to production data can be a good proxy for a benchmark. A very simple payload file can be constructed with messages delimited by a special character that should not appear in the text such as a pipe character, "`|`". Further information for designing realistic production-quality payloads can be found here [Tips for designing payloads](https://aiven.io/blog/tips-for-designing-payloads).

## Topic Configuration
Although brokers can set defaults for the following configurations in their server.properties config file, these settings are often set for a given topic when it is created.
- `Replicas=3` - A leader and two followers will each hold a copy of a given partition. As the number of brokers in a cluster increases, the work of replication is spread out across the available brokers. To ensure data integrity, a replication factor of at least 3 should be used.
- `Partitions=8` - Partitions are evenly divided among the available brokers in the cluster. More partitions can increase parallelism and throughput for both producers and consumers. Partitions also consume compute and file resources on Brokers so high partition counts may need additional tuning for good performance. To better understand benchmarking results, the number of partitions can be set as a multiple of the number of brokers to ensure even division of work across the brokers.
- `compression.type=zstd` - zstd usually has the highest throughput of the available compression codecs and is typically recommended for latency-sensitive environments (good balance between compression speed and compression ratio)

# Kafka Consumer Configuration
While not strictly necessary to measure Kafka producer performance, when testing end-to-end latency of the path Producer -> Kafka Broker -> Consumer, Consumer clients can read data from brokers that contain data on their topic of interest.
It should be noted, however, that the Kafka Consumer test does not spend time processing the messages, so they will not add load mimicking "real consumer latency", but will increase the Fetch and network load on the brokers.
In this case, the work done by Consumers is very similar to the "Fetch" operations done by follower brokers.
Consumers of a given topic that are collaborating on their ingestion of that topic should participate in a Consumer Group so they can evenly share the processing of that topic's data.
The number of Consumers in a group should be tuned to their ability to ingest data from the shared topic.
That is, if a given consumer can ingest more than one partition concurrently without adding latency to the operation, the partitions can outnumber the Consumers.
The number of Consumers in a consumer group attached to a given topic should not exceed the number of partitions in that topic, else the additional consumers in the group will sit idle.
Multiple Consumer processes may share a large system that is configured similarly to a producer instance.

# Measurement Process
Benchmarking Kafka is typically accomplished with the `kafka-producer-perf-test`.
In this test, the producer sends data to Kafka on a specified topic at a provided rate for a provided number of records. 
This test measures the latency of a producer request which is composed of the producer generating a message, sending the message to the brokers, the message being replicated among brokers, and the response from the leader broker to the producer.
At the end of the test, the producer reports resulting statistics comprising average latency and throughput as well as median and tail latencies like p99 which is used for the SLA.
While this default behavior is useful to measure Kafka cluster performance, the resulting statistics of these measurements are often significantly affected by the startup behavior of the Kafka brokers and the Kafka producers.
To get a more accurate measurement of a Kafka cluster's performance during steady-state operation, utilize the `warmup-records` feature added to the `kafka-producer-perf-test` in Kafka 4.2.0.
The `--warmup-records` parameter instructs the producer to classify a fraction of the provided `num-records` as a "warmup" and keep them separate from the steady-state performance which is reported separately from the whole test in the metrics summary statistics lines printed at the end of the test run.
In choosing the test duration, `num-records`, the test should be long enough to get sufficient repeatability in the steady-state p99 measurements. 
A warmup allows some time for the broker and producer JVMs to warm up, network connections to be established, and variability from these changes to relax as the cluster reaches steady state.
Often, one minute of warmup is sufficient for these purposes so warmup records should be set based on the producer throughput requested and should be tested iteratively to ensure producer throughput and latency are consistent during steady-state operation.

## Message Batching
When configuring the producer's sending behavior, two important items stand out to control the flow of data from the producer: batch size and linger. These can be specified in the producer's configuration file `producer.properties` or specified on the command line.
- `linger.ms=5` - Very low linger values can influence batches to be partially filled, reducing overall bandwidth, whereas high linger values can increase latency
- `batch.size=114688` - For our text-based corpus (Shakespeare), larger batches achieve better compression ratio, but can increase batch record-queue-time, since it takes longer to fill the batch at a given rate of message production. These statistics can be viewed in Producer metrics & JMX ouput

An example producer perf test command line is as follows: 
- `$ kafka/bin/kafka-producer-perf-test.sh --topic test-PR78-BR4-PA32-R3 --bootstrap-server 127.0.0.1:9093 --num-records 15000000 --warmup-records 3000000 --payload-file /opt/kafka/kafka-payload.txt --payload-delimiter '\|' --throughput 50000 --print-metrics --producer-props compression.type=zstd acks=all batch.size=114688 linger.ms=5 --command-config /opt/kafka/kafka/config/producer.properties`

In the command line above, we have a single producer, sending messages from the kafka-payload.txt to a topic named "test-PR78-BR4-PA32-R3". One of the brokers in the cluster is located at the bootstrap-server IP address and listening on port 9093, per its configuration. The producer will send 15M records at a rate of 50k records/second. The first 3M of these records will count as warmup records, where the warmup will last approximately 60 s. This producer will print a summary or internal JMX metrics at the end of the test. The producer will send data with zstd compression, and request acks from all brokers once they have a replica of the message. The producer will wait up to 5 ms to accumulate messages into a batch of size no greater than 112kB, before sending a batch of messages to a single broker. 

<!--TODO: Keep following lines ?-->
A cluster which is highly loaded may require more time to stabilize its performance
  - e.g. at 50k records per second or producer throughput, 3M `warmup-records` and 15M `num-records` will enable a 1 minute warmup, followed by 4 minutes of steady-state
  - e.g. at 100k records per second in the same cluster as above, a 2 minute warmup may be required for all producers to successfully establish steady-state flows to the cluster, which would require 2 × 60 × 100k  = 12M warmup records to achieve steady-state performance

Steady-state readiness should be assessed iteratively to ensure that producer throughput and latency during steady-state have stabilized.
<!--Keep above?-->

Finally, while measuring performance of the brokers and producers, tools like `perfspect` should be used to collect a quick system configuration summary with `perfspect report`.

## Throughput Sweeps
To determine the throughput at which a given cluster hits a desired SLA such as "p99 latency must be less than or equal to 20 ms", we run `kafka-producer-perf-test.sh` with a varied number of producers until the resulting p99 is at or just below the SLA.
This gives us our desired key performance indicator (KPI) of "cluster throughput at a specific latency".
To improve the consistency of the measurement, each producer should send data to the specified topic at the same rate, 50k records/sec here.

In the figure below, we have the p99 latency measured at various load levels on the cluster.
Each point represents the addition of another producer running at 50k records per second to give the resulting Throughput.
We see that the trend crosses 20 ms at about 350k records/sec so that is our resulting KPI.
```
Example Latency vs Throughput Curve (p99 Latency)
                
p99 Latency                                                     
(ms)
  40│                                                    
    │                                   ●               
  35│                                                       
    │                                ●                   
  30│                                                       
    │                            ●                       
  25│                                                       
    │                         ●                           
  20│─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ●─ ─ ─ ─ ─ ─ ─ ─
    │                                                       
  15│                   ●                                   
    │                ●                                       
  10│             ●                                       
    │          ●                                             
   5│   ●   ●                                             
    │                                                       
   0└─┴─────┴─────┴─────┴─────┴─────┴─────┴
     0    100   200   300   400   500   600   
      Cluster Throughput (1000 records/sec)

     ● = Measured data point
     ─ = SLA threshold line at 20ms
     SLA met at ~350k records/sec @ 20ms p99
```

- The `kafka-producer-perf-test.sh` can be run within a scripted for-loop to launch many producers with minimal delay between their start times. This ensures the cluster runs at a consistent load during steady state operation
- Barring some specific use-cases, Producers should typically all send messages to the Kafka cluster at the same rate (e.g. 50,000 records per second) so that they may be evaluated as a group and maintain consistent loading of the cluster
- A "sweep" of producer counts is frequently useful where the test is run at a given load (producer count), then that load is increased in subsequent iterations until the SLA target is reached. Gathering additional data points at loads beyond the SLA ensures the SLA has been met

<!--TODO: Results: Data collected at a specific topology as a guide-->

## Evaluation of Performance and System Health
When benchmarking, we should always pay close attention to the resources used on the system(s) under test (SUT).
Once we've identified our SLA throughput, it's wise to examine the system resources for the test at that throughput to ensure that the performance is not limited by configuration or a particular subsystem.
Many tools are available to monitor the system including [perfspect](https://github.com/intel/PerfSpect) and [SAR](https://www.man7.org/linux/man-pages/man1/sar.1.html) which can both gather metrics from Linux that monitor important system resources such as CPU, storage bandwidth, storage IOPS, storage latency, and network bandwidth. 

One important analysis is to inspect the CPU utilization of the brokers and producers.
If their CPUs are above 80% utilized, there is likely some performance reduction so the cluster admin should consider scaling out the cluster or scaling up the individual systems.
This same analysis should be performed for storage bandwidth, storage IOPS, and network to be sure the systems are not hitting their limits.
With storage, if write latency is high during the run, the cluster should likely scale out or at least scale up the storage of the individual brokers.
For the network, the systems only need to operate under the limits enabled by the instance and consider scaling out or up if at or beyond these limits.

When operating Kafka in production, it's often undesirable to use multiple additional telemetry tools for fear of affecting performance.
In these cases, Kafka has Java Management Extensions (JMX) metrics that can be passively gathered by Kafka and either logged or displayed on dashboards such as Grafana. Since it's built into Kafka and Java, JMX can offer additional insights into the internal operations of Kafka that cannot otherwise be monitored with external tooling.

Finally, if users need to better understand the call stacks of Kafka or where Kafka is spending time on CPU, tools such as [flamegraphs](https://www.brendangregg.com/flamegraphs.html) can be extremely useful to gather and understand their call stacks.

# Single Node Configuration
Here we discuss changes to the configuration and topology of a Kafka cluster when measuring Kafka performance in a single system.

## Single-node Topology
If running in a single physical system, arrange brokers and producers so they do not interfere with each other's performance. Here are examples of using `numactl` to pin Controllers, Brokers, and Producers to various CPUs in a two-socket, six NUMA node system.
- One Kafka controller (non-data-broker) pinned to socket 0, non-specific CPUs or CPUs not occupied by brokers
  - `$ numactl -m "0,1,2" -N "0,1,2" /opt/kafka/kafka/bin/kafka-server-start.sh controller.properties …`
- Four Kafka Brokers on socket 0, pinned to "private" cores
  - 4 brokers pinned to NUMA nodes: ( 0 0 1 2 )
  - Example mapping: Start Broker_1 on CPUs 0-15:
    - `$ numactl -m 0 -N 0 -C 0-15 /opt/kafka/kafka/bin/kafka-server-start.sh broker0.properties …`
- When running in a lab environment, rather than the cloud, it's preferred to run Producers on a separate system with a very fast network connecting it to the Broker system(s), in which case, pinning producers is not necessary. If only one system is available, Producers should be pinned to a different socket than Brokers if possible to minimize interference in each other's workload. The number of Producers should be scaled up to meet throughput and latency targets.
  - Example of pinning producers to Socket 1 in a GNR system with 3 NUMA nodes per socket:
    - `$ numactl -m "3,4,5" -N "3,4,5" /opt/kafka/kafka/bin/kafka-producer-perf-test.sh …`

## Single-node Hardware Recommendations
### Storage
Ensure that each broker has sufficient storage bandwidth by assigning at least one storage drive per broker. Setting up a striped RAID0 array is probably not necessary for drives with at least 1GBps write throughput. While it's possible for brokers to share a single physical drive by using different directories for their log dirs, the user must ensure that drive has sufficient write performance to operate at high throughput without incurring additional latency.

## Single-node BIOS Configuration Recommendations
If the user has access to the BIOS for a system, here are some parameters that can be changed to improve Kafka performance.
- **SNC**: enabled (GNR 3 NUMA nodes per socket)
- **Hyperthreading**: enabled
- **Latency Optimized mode**: Some Xeon BIOS use this parameter. This setting optimizes for latency vs. power of the memory subsystem which helps latency-sensitive workloads, like Kafka

### Single-node System Configuration
In contrast to cloud instances, physical servers can often have hundreds of gigabytes of memory installed. In these cases, it's usually more useful to use the setting `vm.dirty_background_bytes` instead of `vm.dirty_background_ratio` since even 1% of 512 GB would be 5 GB which could cause additional latency during write-back. In such a system, even a modest size for `vm.dirty_background_bytes` such as 400MB can enable good performance.
- `vm.dirty_background_bytes=400000000`

# Example System Startup Script
```bash
############################################
# recommended kernel settings #
############################################
ulimit -n 1048576
ulimit -l unlimited
ulimit -u 32768
# Disable reclaim mode, disable swap, disable defrag for Transparent 
# Hugepages in accordance with DataStax
echo 0 > /proc/sys/vm/zone_reclaim_mode
swapoff –all
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
##############################
# Network production settings#
##############################
sysctl -w \
net.ipv4.tcp_keepalive_time=60 \
net.ipv4.tcp_keepalive_probes=3 \
net.ipv4.tcp_keepalive_intvl=10
sysctl -w \
net.core.rmem_max=16777216 \
net.core.wmem_max=16777216 \
net.core.rmem_default=16777216 \
net.core.wmem_default=16777216 \
net.core.optmem_max=40960 \
net.ipv4.tcp_rmem='4096 87380 16777216' \
net.ipv4.tcp_wmem='4096 65536 16777216'
###############################################################
# Neworking adding 3 additional static IP address on the #
# same network interface for my Cassandra instances # 
###############################################################
ifconfig eno1:1 134.134.101.218 up 
ifconfig eno1:2 134.134.101.219 up 
ifconfig eno1:3 134.134.101.220 up 
################################################################
#setting the system to performance mode for best possible perf #
################################################################
for CPUFREQ in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
do
 [ -f $CPUFREQ ] || continue
 echo -n performance > $CPUFREQ
done
for CPUFREQ in /sys/devices/system/cpu/cpu*/power/energy_perf_bias
do
 [ -f $CPUFREQ ] || continue
 echo -n performance > $CPUFREQ
done
##################################################################
# Disk Optimizations for storage devices in Database # 
# - changing scheduler to none #
# - rotational to zero # 
# - changing the read ahead buffer # 
##################################################################
touch /var/lock/subsys/local
echo none > /sys/block/nvme1n1/queue/scheduler
echo none > /sys/block/nvme2n1/queue/scheduler
echo none > /sys/block/nvme3n1/queue/scheduler
echo none > /sys/block/nvme4n1/queue/scheduler
echo 0 > /sys/class/block/nvme1n1/queue/rotational
echo 0 > /sys/class/block/nvme2n1/queue/rotational
echo 0 > /sys/class/block/nvme3n1/queue/rotational
echo 0 > /sys/class/block/nvme4n1/queue/rotational
###################################################################### 
# Note this change alone will double Cassandra throughput #
# as the Linux default is 128 read_ahead_kb, this can bottleneck the #
# NVME device bandwidth when you have small random requests, like #
# those on cassandra-stress #
######################################################################
echo 8 > /sys/class/block/nvme1n1/queue/read_ahead_kb
echo 8 > /sys/class/block/nvme2n1/queue/read_ahead_kb
echo 8 > /sys/class/block/nvme3n1/queue/read_ahead_kb
echo 8 > /sys/class/block/nvme4n1/queue/read_ahead_kb

```


<!--## Java Management Extensions (JMX) TODO: add to tools and advanced telemetry section
**JMX_PORT**: To enable monitoring of Kafka cluster metrics in real time, this environment variable may be set for brokers, producers, and consumers. This will enable gathering of JMX metrics on `JMX_PORT` with the Kafka utility JmxTool. For more info on See https://kafka.apache.org/42/operations/monitoring/-->

<!--
JVM option explanations:

Performance enhancement: 
   -XX:-AlwaysPreTouch (will cause the JVM to pre-touch all of the pages in its heap to speed up page faults once the memory is required)
  
Memory Utilization enhancement: 
  Typically, Kafka creates many new objects in the young generation as new requests arrive and are enqueued. These objects are typically short-lived and do not contribute much to  old generation of objects does not grow much 
  
  -XX+UnlockExperimentalVMOptions (enables others)
  
  -XX:G1ReservePercent=2 (specifies the percentage of memory to keep free to reduce the risk of memory overflow during garbage collection. Setting it to 2% means that the JVM will reserve 2% of the heap memory for this purpose, which can help manage memory more effectively.)
  
  -XX:G1NewSizePercent=50 (specifies the percentage of the heap that should be allocated to the young generation during garbage collection. Setting it to 50 means that half of the total heap size will be used for the young generation, which can help manage memory more effectively in applications that frequently create new objects in the young generation)
  
  -XX:G1MaxNewSizePercent=100 (specifies the maximum percentage of the heap that can be allocated to the new generation in the G1 garbage collector. Setting it to 100% allows the new generation to use the entire heap, which can be useful in certain scenarios but may lead to inefficient memory usage and longer garbage collection pauses.)
  
  -XX:ParallelGCThreads=5 (Limit parallel GC threads to 5, so the JVM doesn't use all of the virtual threads in the system.  Particularly important when multiple producers share a system with many CPU cores)

Options for enabling accurate flame graphs: 
  -XX:-PreserveFramePointer -XX:+UnlockDiagnosticVMOptions -XX:-DebugNonSafepoints
Telemetry enabling:
  -XX:+FlightRecorder -XX:NativeMemoryTracking=summary
JMX-enabling on single-node: 
  -Djava.rmi.server.hostname=127.0.0.1
-->