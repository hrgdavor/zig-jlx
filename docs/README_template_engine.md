# TemplateEngine (Arena-Scoped Fast Interpolation)

A lightweight static string template parser written in Zig and strictly bound to `std.heap.ArenaAllocator` properties rather than tracking complicated AST or heap logic. 

## Benefits

When working with string interpolation mappings (like generating `{name}` replacements from a `StringHashMap`), executing standard replacements in loops can trigger huge numbers of `.free()` and `.alloc()` patterns for temporary intermediate arrays whenever substitutions resolve dynamically. 

`TemplateEngine` solves this cleanly:
- **No string tracking leaks**: It demands you pass in a `std.mem.Allocator` that is tied strictly to a `std.heap.ArenaAllocator`. It performs heavy `replace` operations recursively with absolute impunity because the entire memory boundary shrinks contextually outside in `O(1)`.
- **Pre-baked Parsers**: Shipped standard functions for `expandCurly "{...}"`, `expandJs "${...}"`, `expandRuby "#{...}"`, and more.
- **Specifier Resilience**: Understands advanced interpolations using `:` to fall back. E.g. `${time:datetime}` triggers parsing but isolates key targets dynamically.
- **Key Padding**: Direct support for right-padding with `{key:N}` syntax.
- **Flexible Data Types**: Any numeric field can be formatted as a timestamp seamlessly using standard specifiers.

## Use Cases

- Shell environment variable parsing systems.
- Log message decorators that pull `{key}` values transparently off a dynamically compiled metadata block context.
- High-Performance template rendering applications.

## Code Example

```zig
const std = @import("std");
const expandJs = @import("template_engine.zig").expandJs;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Loop iteration arena instantiation standard
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    // Map definition simulating parsed context
    var parsed_values = std.StringHashMap([]const u8).init(gpa.allocator());
    defer parsed_values.deinit();
    try parsed_values.put("server", "nginx");
    try parsed_values.put("status", "200");
    
    // An example log line message
    const msg = "Received response from ${server} with HTTP ${status}";

    // Execute Javascript-style replacement mapping without leaks
    const output = try expandJs(arena.allocator(), msg, &parsed_values);

    std.debug.print("Formatted: \n{s}\n", .{output});
    // Expected Output: "Received response from nginx with HTTP 200"
}
```
