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
