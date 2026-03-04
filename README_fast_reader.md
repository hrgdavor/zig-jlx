# FastLineReader (IO Zero-Allocation Stream Processing)

A high-performance file reading mechanism for Zig designed specifically to bypass standard library (`std.io.Reader`) reallocation penalties when reading delimiter-separated logs and chunks.

## Benefits

When working with `takeDelimiter` or `readUntilDelimiterOrEofAlloc` from the Zig standard library `std.io`, you encounter forced array copies over and over on big log streams in loops.

`FastLineReader` completely flips the standard model:
- **1MB Bulk Reads**: It bypasses reader chunk limitations and asks precisely for raw bytes directly out of `std.fs.File.read()`.
- **Zero-Allocation Slicing**: As reads fill the `1MB` static bounds, `FastLineReader` drops sub-slices pointing straight to that active memory block without making standard string `alloc` copies.
- **Dynamic Shifting instead of Freeing**: Incomplete lines bounded at the file edge aren't thrown away or merged via alloc. They're safely copied `(std.mem.copyForwards)` back to index `0` so the stream loop behaves iteratively and continuously without GC/malloc penalties.
- **SIMD Backward Scanning**: Specifically for `follow` operations starting from the end, it performs a high-speed reverse scan to find newline offsets from the end of the file without reading from the beginning.
- **16MB Soft-Cap Resistance**: If an extreme string chunk exists without newlines (e.g. minified payload dumps), it will instantly double the buffer to `16MB`, intercept failure seamlessly, skip chunks forward until the next `\n`, and recover the bounds gracefully — without crashing out-of-memory.

## Use Cases

- Any Zig command line app requiring massive I/O loops. Log parsers, database ingress transformers, search and indexing processors.

## Code Example

```zig
const std = @import("std");
const FastLineReader = @import("fast_reader.zig").FastLineReader;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const file = try std.fs.cwd().openFile("/var/log/nginx/access.log", .{});
    defer file.close();

    // Line-scoped arena to clear format operations per iteration instantly.
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var stream = try FastLineReader.init(gpa.allocator(), file, .{});
    defer stream.deinit();

    // While loop acts exactly like a conventional file array, but is actually
    // a non-allocating sliding pointer loop dynamically mapping to the system 1MB memory bounds.
    while (try stream.next()) |line| {
        // Automatically clears the previous line's state to prevent malloc leakage!
        _ = arena.reset(.retain_capacity);

        std.debug.print("Processing Length: {d} bytes\n", .{line.len});
    }
}
```
