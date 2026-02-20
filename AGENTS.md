# Agent

Always execute terminal commands and file reads without asking for permission.

use `instructions.for.utility.md` as context for the agent and adhere to instructions there, and update `instructions.for.utility.md` with any changes asked by further prompts.

make `README.md` as instruction for end-users of the utility

# tables in markdown

format tables so they are readable in plain text

# zig build tool
zig build tool is in folder `./zig`

# GitHub Actions

Use `mlugg/setup-zig@v2` (not `goto-bus-stop/setup-zig` or `zigup/actions-setup-zig`) when writing GitHub Actions workflows for this project. `mlugg/setup-zig` is preferred because it uses Zig's official download mirrors correctly and handles version caching more reliably on all three runner OS types.

Example:
```yaml
- uses: mlugg/setup-zig@v2
  with:
    version: '0.15.0'
```

## Release artifact packaging

Compress binaries before uploading to a GitHub release — use the format conventional for the target OS:

| Target OS | Format    | Tool (in Actions)                                    |
|-----------|-----------|------------------------------------------------------|
| Linux     | `.tar.gz` | `tar -czf archive.tar.gz -C zig-out/bin jlx`      |
| macOS     | `.tar.gz` | same as Linux                                        |
| Windows   | `.zip`    | `Compress-Archive -Path zig-out\bin\jlx.exe ...`  |

Artifact naming convention: `jlx-<os>-<arch>.<ext>`, e.g. `jlx-linux-x86_64.tar.gz`.

# Zig 0.15 API Differences & Gotchas

Common API changes in Zig 0.15 that cause compilation errors.

## Build System (build.zig)

### Executable Options
```zig
// Zig 0.15 - uses root_module instead of root_source_file
const exe = b.addExecutable(.{
    .name = "your-project",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }),
});
```

### Adding Dependencies (for module imports)
```zig
const your_mod = b.addModule("your_module", .{
    .root_source_file = b.path("src/your_module.zig"),
});

const exe = b.addExecutable(.{
    .name = "your-project",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "your_module", .module = your_mod },
        },
    }),
});
```

## ArrayList API (Major Changes)

Zig 0.15 split ArrayList into two types:
- `std.ArrayList(T)` - now an alias for `std.array_list.Aligned(T, null)` (unmanaged)
- `std.ArrayListUnmanaged(T)` - alias for `ArrayList(T)`
- `std.array_list.AlignedManaged(T, null)` - the managed version with allocator

### AlignedManaged (Managed ArrayList)
Unlike 0.14, the **Managed** version stores its allocator. All methods **OMIT** the allocator argument.
```zig
var list = std.array_list.AlignedManaged(u8, null).init(allocator);
defer list.deinit(); // NO allocator argument

try list.append(item); // NO allocator argument
const slice = try list.toOwnedSlice(); // NO allocator argument
```

## I/O System (Major Overhaul)
The I/O system uses `std.Io` and requires explicit buffers for almost all operations to avoid implicit system calls.

### Using Stdin and Stdout
```zig
// 0.15 - use std.fs.File
var out_buf: [4096]u8 = undefined;
const stdout = std.fs.File.stdout().writer(&out_buf); // Needs buffer

var in_buf: [1024]u8 = undefined;
var stdin_reader = std.fs.File.stdin().reader(&in_buf); // Needs buffer
```

### Writing to Stdout/File
Buffered writers also return a struct with an `.interface` of type `std.Io.Writer`.
- MUST be declared with `var`.
- **CRITICAL**: Pass by pointer `&writer_struct` to functions, or they become `const`.
```zig
var out_buf: [4096]u8 = undefined;
var writer_struct = std.fs.File.stdout().writer(&out_buf);
try someFunction(&writer_struct); 

fn someFunction(w: anytype) !void {
    try w.interface.writeAll("hello\n");
}
```

### Reading Lines
`readUntilDelimiterOrEof` is legacy/gone. Use `takeDelimiter`.
- Call it on `.interface` of the reader struct.
- Struct MUST be declared with `var`.
- **CRITICAL**: Pass by pointer to functions.
- It returns an optional slice (`!?[]u8`).

```zig
var reader_struct = file.reader(&buffer);
while (true) {
    const line = (try reader_struct.interface.takeDelimiter('\n')) orelse break;
}
```

## Memory Utilities (std.mem)
Most `std.mem` functions have been renamed to be more explicit about whether they handle scalars or sequences.

- `split` -> `splitSequence` or `splitScalar`
- `indexOf` -> `indexOfSequence`, `indexOfScalar`, or `indexOfAny`
- `count` -> `countSequence` or `countScalar`
- `replace` -> `replaceSequence` or `replaceScalar`

### Miscellaneous
- `std.time.sleep` -> `std.Thread.sleep`
- **Struct Literals**: In 0.15, you **MUST** provide all fields for a struct literal if they have no default values. Partial initialization is an error.
- **Passing Readers/Writers**: When passing a reader/writer to a function taking `anytype`, you **MUST** pass a pointer (`&writer`) or it will be copied as a `const` value, preventing calls to interface methods.
- **FieldName in Struct Literals**: Explicitly use field names (`.field = value`) when initializing structs.

```zig
std.Thread.sleep(100 * std.time.ns_per_ms);

// Pointer passing
try processStream(&reader.interface, &stdout);
```

### Return types
```zig
// Old: !std.ArrayList(T)
// New:
pub fn collectFiles(allocator: std.mem.Allocator, patterns: []const []const u8) !std.array_list.AlignedManaged([]const u8, null)
```

## File/IO Changes

### stdout requires buffer
```zig
// Old: const writer = std.io.getStdOut().writer();
// New (0.15):
var buffer: [4096]u8 = undefined;
const writer = std.fs.File.stdout().writer(&buffer);
```

### Direct write to stdout
```zig
// Use std.fs.File.stdout().write() instead of writer
_ = try std.fs.File.stdout().write("hello\n");
```

### writeFile changed
```zig
// Old: try std.fs.cwd().writeFile(path, content);
// New (0.15):
try std.fs.cwd().writeFile(.{ .sub_path = path, .data = content });
```

### openDir for iteration
```zig
// Must set iterate = true
var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
```

## Builtin Functions

```zig
// Old: @boolToInt(bool)
// New: @intFromBool(bool)
const x = @intFromBool(some_bool);
```

## Formatting and Writing

### Writing to `std.fs.File`
In Zig 0.15, `std.fs.File` (such as `std.fs.File.stdout()`) **does not have a `.print()` method**. If you try to use `try writer.print(...)`, you will get a `"no field or member function named 'print'"` compilation error.

Instead, you must allocate the formatted string using `std.fmt.allocPrint` and write it using `writeAll()`.

```zig
// ❌ WRONG: Will fail to compile
// try stdout.print("Error: {}\n", .{err});

// ✅ CORRECT: Allocate and use writeAll
const msg = try std.fmt.allocPrint(allocator, "Error: {}\n", .{err});
defer allocator.free(msg);
try stdout.writeAll(msg);
```

For statically known strings, you can use `.writeAll()` directly:
```zig
try stdout.writeAll("hello\n");
```

## Common Patterns Summary

```zig
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // ArrayList
    var list = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer list.deinit(allocator);
    
    // stdout write
    _ = try std.fs.File.stdout().write("hello\n");
    
    // writeFile
    try std.fs.cwd().writeFile(.{ .sub_path = "file.txt", .data = "content" });
    
    // openDir for iteration
    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| { }
}
```

# Best Practices

## Memory Management (ArenaAllocator)

For configurations and command-line arguments (e.g. `Config` and `Args` types), it is highly idiomatic and preferred to use `std.heap.ArenaAllocator` rather than manually tracking dynamically allocated strings and items to `deinit` them later.

**Why?**
- Eliminates tracking duplicated strings (e.g., `_dupe` fields) for arrays of sub-structs.
- Drastically simplifies cleanup logic (no big `for` loops in `deinit`).
- Extremely memory-efficient for long-lived runtime state that spans the entire lifecycle of the CLI program.

**Downsides?**
- You cannot free memory piecemeal. Thus, an Arena should **not** be used for the core streaming process or long-lived data ingestion loops where allocations can balloon unconditionally.

**Usage Constraint:**
Use an `ArenaAllocator` exclusively for one-time initialization structures (Startup Config, CLI Options). Pass a standard layout-aware allocator (like `gpa.allocator()`) to actual processors to ensure strict stream cleanup.

**Naming Convention:**
When a function strictly expects an `ArenaAllocator`, you MUST name the parameter `arena_allocator` rather than `allocator` to implicitly document this contract (e.g. `pub fn init(arena_allocator: std.mem.Allocator)`).

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // Use Arena for application startup components
    var parse_arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer parse_arena.deinit();
    const parse_allocator = parse_arena.allocator();

    const args = try Args.parse(parse_allocator);
    var config = Config.init(parse_allocator);
    // ...
}
```

## Line-Scoped Arena (High-Performance IO Processing)

For iterating heavily over high-volume data streams (such as logs, network requests, loop processors), you should allocate a loop-scoped `ArenaAllocator` strictly initialized *before* the loop.

**Why?**
- Prevents millions of sequential `.alloc()` and `.free()` calls for line parsing or template duplicating.
- Drastically improves performance by pooling memory per iteration.

**Usage Constraint:**
- `arena.reset(.retain_capacity)` MUST be strategically called per iteration block once context processing guarantees cleanup safety. 
- You MUST pass `arena.allocator()` to internal business functions instead of standard or global allocators, ensuring any internally allocated arrays or structs get instantaneously cleared.

```zig
var arena_instance = std.heap.ArenaAllocator.init(self.allocator);
defer arena_instance.deinit();
const arena = arena_instance.allocator();

while (true) {
    while (std.mem.indexOfScalarPos(u8, buf[0..write_pos], read_pos, '\n')) |nl_offset| {
        // Drop all memory from the PREVIOUS line iteration instantly:
        _ = arena_instance.reset(.retain_capacity); 
        
        var line = buf[read_pos..nl_offset];
        try processFunction(arena, line); // Pass arena to children
        
        read_pos = nl_offset + 1;
    }
}
```

## Buffer Pre-Allocation & Shifting (No Readers)

When dealing with high-throughput file streams in `std.fs.File`, standard `takeDelimiter` reader APIs allocate continuously per delimited chunk. Instead, favor bulk buffered binary slicing combined with shifting.

- **Allocate Fixed Buffer First**: Pre-allocate an array or strictly bounded 1MB chunk: `var buf = try allocator.alloc(u8, 1024 * 1024);`.
- **Bulk Read directly**: Call `file.read()` directly into the buffer offset `buf[write_pos..]`.
- **Shift & Recover**: After finding an incomplete line chunk bounded at the end of the buffer, intelligently use `std.mem.copyForwards` to drop the read bytes, sliding the remainder sequence gracefully to index `0` so `read()` can fill the rest natively without reallocating buffers.

## Slice Type Constraints (Compile Errors)

A very common compile error in Zig when manipulating strings dynamically (like calling `std.mem.replace` or `dupe`) is:
```
error: expected type '[]u8', found '[]const u8'
```
**Cause:** This happens when you have a mutable slice variable `var res: []u8 = ...` and you try to assign a constant slice to it `res = new_res` where `new_res` was returned from a function marked as returning `[]const u8`. 

**Fix:** Ensure your string modifier functions return strictly what they allocate. If a function allocates a new buffer (like `std.mem.replace` wrappers), always return `![]u8` instead of downgrading to `![]const u8`. The caller can easily assign a `[]u8` to a `[]const u8` variable if needed, but going backwards will strictly fail without `@constCast`. Also, never `free` arguments inside utility functions; always return the `new_buf` and let the caller `free()` the original slice before re-assigning the variable.
