# JSON Scanner (Zero-Allocation JSON Parsing)

A highly optimized Zig utility for scanning and extracting top-level keys from JSON payloads. Designed specifically for high-throughput stream processing, log parsers, and API routers that don't need full JSON AST structures.

## Benefits

- **Zero Allocation**: The scanner creates no heap allocations for the strings, objects, or arrays it reads. It yields a `std.StringHashMap` full of `[]const u8` pointers directly referencing the original JSON buffer block.
- **Lazy Evaluation**: It bypasses deep inspection. Nested arrays `[...]` and objects `{...}` are immediately grouped and skipped as single string blocks. They are only parsed if you specifically pass that targeted raw string into a deep parser layer later on.
- **Escape sequence-aware**: Robustly handles string boundaries containing escaped quotes `\"` or nested stringified JSON blobs internally.

## Use Cases
- High-performance Log routers (where you only care about top-level `"level"` or `"request_id"`).
- API Gateways where HTTP request bodies just need primary routing IDs parsed instantly without risking memory bloat.

## Code Example

```zig
const std = @import("std");
const scanTopLevelJson = @import("json_scanner.zig").scanTopLevelJson;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const json_buffer = 
        \\{
        \\    "level": "INFO", 
        \\    "status": 200, 
        \\    "data": { "nested": "complex_structure", "size": 999 },
        \\    "items": [1, 2, 3] 
        \\}
    ;

    if (try scanTopLevelJson(gpa.allocator(), json_buffer)) |*parsed| {
        defer parsed.deinit(); 
        
        // Pointers map immediately to static substrings from the base block.
        std.debug.print("Level: {s}\n", .{parsed.get("level").?});     // "INFO"
        std.debug.print("Status: {s}\n", .{parsed.get("status").?});   // 200
        std.debug.print("Data: {s}\n", .{parsed.get("data").?});       // { "nested": "complex_structure", "size": 999 }
        std.debug.print("Items: {s}\n", .{parsed.get("items").?});     // [1, 2, 3]
    }
}
```
