Changes that can be made to Java application code to improve application performance. The benefits will vary widely depending on how common specific libraries are used and how much compute time they consume. Use of profiling solution such as [VTune Profiler](tools/vtune/README.md) is highly recommended to assess potential improvements. 

## Using String.replace instead of String.replaceAll

The `String` class has two very similar methods for replacing substrings, [replace()](https://www.w3schools.com/java/ref_string_replace.asp) and [replaceAll](https://www.w3schools.com/java/ref_string_replaceall.asp). 

Both methods replace all occurrences of the target. `replaceAll()` is more powerful, because it supports any regex patterns. However, this comes with a cost of compiling the regex pattern and then performing regex matching instead of simpler string searching.

Very commonly, `replaceAll()` is used where `replace()` is perfectly sufficient and less compute intensive. For example, `"a-b-c".replaceAll("-", ":")` is equivalent to `"a-b-c".replace("-", ":")`, but the latter performs much better.

We recommend replacing all instances of `replaceAll()` with `replace()` where the search string is a literal, as opposed to a RegEx pattern. 