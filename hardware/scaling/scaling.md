# Basic software scaling principles on large multi-core servers

## Scope

This guide provides some basic principles to improve scaling of multi-threaded software with shared data on large multi-core systems.

## Basic scaling principles of a distributed system

Scaling is about improving performance with more resources. 
When scaling distributed application in a network some basic scaling principles are:

* Don’t overload network nodes to maintain latency and throughput
* Avoid thundering herds and hotspots
* Prefer talking to nearby nodes
* Don’t overload intermediates
* For latency avoid unnecessary round trips

The distributed cores and caches of a multi-core system can be thought of a network, with certain
cache operations acting like message-passing.

These principles should be applied to make software scale on large multi-core systems inside a node.

## Cache operations as message passing in a nut shell

Memory on Intel x86 servers is organized as 64 byte cache lines in distributed caches using [MESIF states](https://en.wikipedia.org/wiki/MESIF_protocol)

Multiple applications reading the same line will do so independently.
However the first read of a line from a second core will have a latency penalty.

When a core modifies a line this involves sending messages and waiting for replies to all other cores that have a copy of the line.

For performance under contention minimize the number of messages.

## Contended memory operations

When multiple cores modify a line frequently this causes cache line contention ("cache line ping-pong")
This can happen:
* between threads when operating on shared data
* in otherwise shared data structures, for example in explicit shared memory files or segments, or inside the kernel
The system serializes contended operations per line and transfers data for updates.
The data transfers are latency critical and directly affect the program performance.

## Performance of cache message passing under contention

The latencies and bandwidth of the cache message passing depend on the distance between the communicating cores.
Communication within a die is faster than between dies. Communication between sockets is slower than within a socket.

The worst case latencies will increase and effective bandwidth decrease as the the number of cores involved grows,
due to [Little's law](https://en.wikipedia.org/wiki/Little%27s_law).

## How to diagnose contended memory operations

### Basic scaling test

Test with increasing number of threads sharing memory. Does the performance curve flatten?
This is the basic test, however other factors (such as bandwidth limitations on memory or IO, "Turbo" frequency or socket power limits) may also cause bottlenecks.

### Using Perfmon to identify memory contention

The Intel Performance Monitoring Unit (PMU) can be used to identify memory contention in programs.
The availability of these features in cloud instances may vary.

#### Using Perfmon metrics

Intel TMA metrics can be used to identify memory contention in a workload (but not where it happens)
This can be done using tools like [Linux perf](https://perfwiki.github.io/main/), [Intel VTune Profiler](https://www.intel.com/content/www/us/en/developer/tools/oneapi/vtune-profiler.html), [PerfSpect](https://github.com/intel/PerfSpect), [gprofiler](https://github.com/intel/gprofiler), [toplev](https://github.com/andikleen/pmu-tools).

The metrics of interest are Contended_Accesses, Data_Sharing and False_Sharing.

### Using Hotspot sampling

Another approach is to use cycle (or time) sampling to identify hot code regions, using tools like Intel VTune, Linux perf, gprofiler. 
This can be either done using the PMU, or when it is not available, using
software sampling. It can be useful to compare the hot spots under increasing loads, many profiling tools have ways to diff profiles.

Significant time in synchronization related functions (e.g. lock/unlock) or in code using atomics indicates a scaling bottleneck.
However other code might also have contended memory, for example for shared statistics and performance counters.

It is important to collect a call graph because most lock tuning needs to happen in the callers of the lock functions.

### Advanced PMU techniques

Intel CPUs can directly sample for contended cache lines using [SNOOP_HITM events](https://perfmon-events.intel.com/platforms/graniterapids/offcore-events/offcore/#event-OCR.DEMAND_DATA_RD.SNC_CACHE.HITM), as an example (the actual event name may vary):

        perf record –e OCR.DEMAND_RFO.L3_HIT.SNOOP_HITM –g –a sleep 1

On Linux perf the "perf c2c" tool can be used to directly compare contended virtual addresses for a workload.

        perf record c2c -a  && perf c2c report --double-cl --full-symbols --stdio

For example varying offsets of conflicts within a 64byte cache line may indicate false sharing. 
This requires support for Intel Precise Event Based Sampling (PEBS)
 
# System level tuning: basic optimizations

* Improve locality of data accesses

In programs it can help to reorganize data structures to be more locality aware. This typically requires a low level programing language that allows control over data structure layout. For reorganizing C/C++ data structures for 64/128 byte cache line alignment the pahole tool in [dwarves](https://github.com/acmel/dwarves) can be useful.

 In some cases there are easy global configuration improvements, for example the "green tea" garbage collector in Golang can help scalability.

When using multiple NUMA nodes localize part that has scaling issues to node if possible
This can be done using taskset or [cpusets](https://docs.kernel.org/admin-guide/cgroup-v1/cpusets.html) (e.g. through thedocker --cpu-set) arguments. This has to be balanced against whole machine utilization.

Under severe contention, splitting workload into multiple copies of a workload can perform better, especially for latencies.

Smaller cloud instances can avoid scaling problems, but should be balanced with other performance benefits of larger instances

# System level tuning: Avoid kernel hotspots

Indicator: kernel time percentage goes up when increasing load

Sometimes newer kernel versions can help

Often can avoid kernel scaling problems by spreading workload over multiple kernel “objects”: multiple files, directories, sockets, processes, file systems, etc.
This requires identifying which kernel object is contended by profiling the kernel with call graphs (perf top –g --no-children).

An often-seen case is contention on the kernel futex hash table through glibc sleeping mutexes. In this case the contention on the mutex needs to be lowered. Sometimes it can be also mitigated by increasing the futex hash table size.

Avoid IO hotspots: Make use of interrupt balancing for NICs and block devices to localize work.

Make use of multiple device queues by spreading out IO over multiple threads.

Contended memory-mapped IO operations (driver mailboxes, single doorbell bottleneck etc.) could be work-arounded by spreading the load to multiple doorbells with SR-IOV.

Avoid scheduler overhead from frequent load balancing.

Processes that go idle very frequently can be affinitized to a subset to minimize work.

NUMA locality minimizes memory management overhead.

Hotspots in kernel memory page handling (protected by a lock) resulting from a frequent concurrent memory allocation and deallocation can be mitigated by using a tcmalloc or jemalloc with user-space thread local caching of memory.

# Low level tuning: basic lock tuning

Reduce critical section lengths to reduce lock contention. Split locks as needed to avoid locking overhead. For example for a hash table consider locking buckets instead of a single lock. 

However don't reduce the critical section too much to minimize contended cache line transfers for passing the locks around. A rule of thumb: a contended critical section should do hundreds of cycles work to amortize its communication cost.

The two previous rules are the most important.

Use backoffs in spinlocks to reduce interconnect load. Standard locking libraries generally do the right thing. When using backoffs avoid fixed latencies which may change on different systems.

Consider the trade-offs for read/write locks: Most read locks transfers the lock cache line even for readers, which involves the latency of message passing. Generally read/write locks are only worth it for long critical sections, unless they are distributed (but that will penalize writers). Lock elision with Intel TSX can be also considered for read/write locks which are most effective for prevalent read scenarios avoiding lock cache line transfers for readers.

Chose the right lock type. Trade off spin locks versus sleeping locks such as glibc mutexes. Sleeping locks should be only used for very long critical sections, as they can have high transfer overhead. For spin locks advanced ticket locks can perform much better under contention (however it is usually better to reduce contention instead of tuning the locks itself). Ticket locks should be avoided when the CPUs are over subscribed because they have inherent ordering which may conflict with scheduling decisions.

Example implementation of advanced locks are in [ConcurrencyKit](https://concurrencykit.org/) or [Intel TBB](https://uxlfoundation.github.io/oneTBB/) 

# Low level tuning: Basic cache line tuning

The first step is to use profiling to identify contended cache lines (for example using the SNOOP_HITM event referenced above or the perf c2c tool)
The basic tuning strategy is to split the line so that only a subset of the cores write to it.

Global statistic counters should be distributed. This will slow down reading due to aggregation cost, but significantly reduces the overhead of writes updating the stats.

When using CMPXCHG CPU instruction for lockless accesses, read the line first to avoid unnecessary cache line dirtying. Adding backoffs on retries (using PAUSE or TPAUSE instruction) can be also beneficial.

Avoid false sharing of data, adding alignment/padding as needed. This can be common for globals, or with memory allocations that are not aligned to 64 bytes. In some cases alignment/padding to 128 byte is needed because of adjacent line prefetching.

Minimize contention for true sharing:

```
        global_flag = true   =>    if (global_flag) global_flag = true
```

avoids unnecessary writes to a shared cache line.

Use a scalable malloc such as [jemalloc](https://jemalloc.net/) or [tcmalloc](https://github.com/google/tcmalloc) or [oneTBB malloc](https://uxlfoundation.github.io/oneTBB/main/tbb_userguide/automatically-replacing-malloc.html) if malloc library contention shows up. 