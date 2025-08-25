# Introduction
Intel's Java performance engineering team has identified runtime-level optimizations which can significantly improve application and infrastructure performance. Some optimizations can be applied via configuration tuning, while others via code changes. 

Actual improvements will vary depending on a given workload's characteristics. It is recommended to use a profiling solution such as [VTune Profiler](tools/vtune/README.md) to more accurately gauge where an application's hotpaths are and which optimizations would have the greatest affect. 

## What's Inside
- Suggested Configuration Optimizations: Changes that can be made to Java's configuration and/or parameters to improve application performance. These optimizations are largely unaffected by specific code patterns and as such can be applied in a more generalist manner.  
- Suggested Code Optimizations: Changes that can be made to Java application code to improve application performance. The benefits will vary widely depending on how common specific libraries are used and how much compute time they consume. Use of profiling solution such as VTune highly recommended to assess potential improvements. 


FAQ
Q: Do I have to adopt everything?
A: No. Each recipe is independent. We recommend starting with more generalist optimizations (Configuration Optimizations), and then applying Code Optimizations, prioritized based off of profiler hotpaths. 

Q: Is there any functional risk?
A: The code changes are semantics-preserving; still, run your test suite and a brief canary. Ops flags are reversible.

Q: Are the optimizations x86 specific?
A: No. Optimizations will operate similarly across all major CPU architecture types.