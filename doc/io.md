# I/O Buffering Strategies: Single vs Double

This document compares **Single Buffer with Sliding Window** (the standard Zig `std.io.Reader` approach) and **Double Buffering** (high-performance asynchronous streaming).

## 1. Single Buffer with Sliding Window
Used by Zig's `std.io.Reader`. It maintains a single contiguous block of memory. When the buffer is exhausted, any remaining unconsumed data (the "tail") is moved back to the start.

| Category          | Description                                                                                                                                              |
| :---------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Complexity**     | **Low.** Simple to implement. Manage one head pointer and one end offset. Logic for "peek N bytes" is straightforward.                                   |
| **Performance**    | **Moderate.** Incurs `memmove` (rebase) costs. Performance drops if the buffer is large and refills are frequent.                                        |
| **Async Ability**  | **Limited.** Operates on a "Pull" basis. CPU waits for I/O when the buffer is empty, leading to idle cycles.                                             |
| **Edge Cases**     | **Easy.** Lines longer than the buffer can be handled by `realloc` or returning an error.                                                                |

## 2. Double Buffering
Uses two distinct buffers (A and B). While the CPU processes Buffer A, the hardware (via `io_uring` or DMA) fills Buffer B in the background.

| Category          | Description                                                                                                                                              |
| :---------------- | :------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Complexity**     | **High.** Requires a state machine to track buffer readiness. Crossing buffer boundaries ("straddling") requires complex pointer logic or a temporary side buffer. |
| **Performance**    | **Maximum.** Zero-copy (no `memmove`). Overlaps I/O and computation, keeping both the CPU and Disk/Network fully saturated.                               |
| **Async Ability**  | **Natural.** The native pattern for `io_uring`. A read for the next buffer is submitted immediately when processing starts on the current one.          |
| **Edge Cases**     | **Hard.** Requires special handling for data fragments that split across the two buffers.                                                                |

---

## Summary Comparison

| Feature            | Sliding Window (Zig Std)   | Double Buffering (High Perf)   |
| :----------------- | :------------------------- | :----------------------------- |
| **CPU Overhead**   | Higher (due to `memmove`)  | Lower (Zero-copy)              |
| **Latency**        | Higher (Wait-Process-Wait) | Lower (Continuous throughput)  |
| **Throughput**     | Good                       | Excellent                      |
| **Implementation** | ~50 lines of code          | ~200+ lines of code            |
| **Memory Usage**   | 1x Buffer Size            | 2x Buffer Size                |

## Recommendation

- **Use Sliding Window** for general-purpose tools where simplicity and safety are paramount. It is sufficient for gigabyte-scale logs.
- **Use Double Buffering** (with `io_uring`) for high-performance engines meant to saturate multi-gigabit network links or top-tier NVMe storage.

---

## SIMD Scanning: Standard vs. Custom

Our codebase uses a hybrid approach to find delimiters:

### 1. Forward Scanning: `std.mem.indexOfScalarPos`
For the primary log processing loop, we rely on the Zig standard library's `indexOfScalarPos`.
- **Pro**: It is highly optimized, inlined, and uses SIMD (`@Vector`) internally on supported architectures.
- **Why**: For forward processing, it is difficult to beat the standard library's heavily tuned implementation.

### 2. Backward Scanning: `findNthNewlineFromEndSIMD`
For "tail" functionality (reading the last N lines), we use a custom SIMD implementation.
- **Pro**: Zig 0.15.2's `lastIndexOfScalar` is a **scalar-only loop** (no SIMD). Our custom version uses 256-bit SIMD to scan backwards.
- **Why**: Finding the end of a log file requires skipping thousands of lines in milliseconds; scalar loops are a bottleneck here.

### 3. Multi-Match Efficiency
Our custom `findNthNewlineFromEndSIMD` is designed to find the **N-th occurrence** within a single bitmask evaluation. 
- While `indexOfScalarPos` is fast for one match, finding 1,000 matches would require 1,000 separate calls and bounds checks. 
- Custom kernels allow us to process an entire bitmask of matches in one pass, reducing the overhead of loop management.

---

## Optimal Buffer Sizes

Choosing the right buffer size for double buffering depends on the underlying hardware and filesystem:

### 1. The 4KB Rule (Alignment)
Most modern filesystems (EXT4, XFS, NTFS) and SSDs (Advanced Format) use **4KB blocks**.
- **Rule**: Always use a buffer size that is a multiple of 4KB.
- **Benefit**: This ensures that every read aligns perfectly with a physical disk sector, avoiding "read amplification" where the drive has to read two physical blocks to satisfy one logical request.

### 2. Memory Paging
Memory is managed in **4KB pages**. Using `std.heap.page_size_min` (typically 4KB) for alignment is critical when using `io_uring` with `O_DIRECT`. Without page alignment, `O_DIRECT` may fail or fall back to slower buffered I/O.

### 3. CPU Cache Locality
- **L1/L2 Cache (32KB - 512KB)**: If your buffer fits in the L1 data cache, SIMD instructions like `indexOfScalarPos` will be lightning fast because the data stays close to the execution units.
- **L3 Cache (8MB - 64MB)**: Once your buffer exceeds ~1MB, you start "thrashing" the higher-speed caches. 
- **The Sweet Spot**: For high-performance log processing, **32KB** is often the ideal balance. It is small enough to fit within most modern L1 data caches while still being large enough to saturate the disk controller.

### 4. Throughput vs Latency
- **Small (4KB - 16KB)**: Lower latency, but high syscall overhead (if not using `io_uring`).
- **Large (1MB - 16MB)**: Maximum throughput for NVMe drives, but higher memory usage and cache misses.

**Recommendation for `jlx`**: Use **32KB** buffers. They align with filesystem blocks, fit in CPU L1/L2 caches, and provide enough data for SIMD instructions to operate efficiently.

---

## Hardware Interaction: `io_uring` and DMA

A common question is whether a larger buffer is "safe" if lines are short and the search stops early.

### 1. DMA and DDIO (Data Direct I/O)
On modern server CPUs (like Intel Xeon), the hardware uses **Data Direct I/O (DDIO)**. When `io_uring` performs a read, the disk controller uses DMA to push data directly into the **L3 cache**, bypassing RAM.

### 2. The "Cache Thrashing" Problem
If your buffer is **8MB** but your CPU's L2 cache is only **1MB**, the hardware will fill the L2 cache as it writes. By the time the disk has finished writing the 8th megabyte into the "tail" of your buffer:
1. The hardware has likely **evicted** the 1st megabyte (the "head") from the cache to make room.
2. When your Zig code starts searching from the beginning of the buffer, it immediately triggers a **cache miss** and has to fetch from slow RAM.

### 3. Conclusion for Large Buffers
Even if your lines are short and you only search the first 50 bytes, a massive buffer size forces the hardware to manage more state and increases the risk that the data you are about to process is evicted before you touch it. 

**Small, aligned buffers (32KB-128KB)** ensure that the "fresh" data provided by `io_uring` is still sitting in the fastest possible cache when the CPU starts its SIMD delimiter search.

---

## Double Buffering: The Scaling Factor

When choosing a size for **Double Buffering**, remember that your memory footprint is **2x the buffer size**.

### The L2 "Sweet Spot"
Modern CPUs (Intel Alder Lake, AMD Zen 4) typically have **1MB to 2MB of L2 cache per core**. 
- **Goal**: Keep both buffers (the one you are processing and the one being filled) entirely within the L2 cache.
- **Why**: As the CPU scans Buffer A, it will also occasionally "peek" at metadata or prepare Buffer B. If the combined size exceeds L2, the CPU is forced to use the shared (and slower) L3 cache.

### Recommended Initial Size: 32KB
A **32KB** buffer size is used in our implementation:
1. **Total Footprint**: 64KB (2 x 32KB for double buffering).
2. **Cache Fit**: Fits comfortably in almost any modern L1 cache (usually 32KB-64KB) and certainly L2, ensuring the CPU searches data at peak speed with minimal eviction of other critical processing data (JSON keys, timestamp state).
3. **Efficiency**: 32KB is large enough to saturate high-speed SSDs while maintaining high "hit" rates in private caches.

### Why 32KB over 64KB?
Modern CPUs typically have 32KB or 64KB L1 Data caches. Using a 32KB buffer leaves "breathing room" in a 64KB L1 cache for the stack, local variables, and the internal state of the JSON parser. If the buffer itself is 64KB, it is guaranteed to push other hot data into the slower L2 cache, causing "cache churn" during the compute-heavy formatting phase.

---

## The Hybrid Strategy: 32KB Static + On-Demand Side Buffer

To balance high-performance I/O and support for arbitrarily long lines, we use a hybrid buffering model across all readers and the core engine:

### 1. Primary I/O Buffers (Static 32KB)
- **Size**: Exactly 32KB.
- **Goal**: Fit entirely within the L2 cache per core.
- **Behavior**: These buffers are never resized or moved. This ensures that the high-speed SIMD scanning always happens on cache-resident data.

### 2. The Side Buffer (On-Demand `ArrayListUnmanaged`)
When a line is too long to fit in the current 32KB buffer, or when it spans ("straddles") across two buffers:
- **Storage**: We copy the unconsumed fragment into a persistent `side_buffer`.
- **Growth**: The `side_buffer` grows dynamically as needed to accommodate full lines up to a configurable limit (default 128MB).
- **Lifecycle**: It is cleared(length reset) after each line is processed but retains its memory capacity to avoid repeated allocations during a single run.

### 3. Key Benefits
- **Optimized Cache Locality**: The hot processing loop always works on fresh data directly from the disk-filled static buffers.
- **Zero-Copy for Common Cases**: Most log lines fit within 32KB and are processed directly without any additional copies.
- **Graceful Degradation**: Extremely long lines are handled safely via the `side_buffer`, preventing costly reallocations of the primary I/O buffers.
