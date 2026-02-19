# Agent

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

## Formatting

### Using fmt.format with anytype
The `std.fmt.format` has issues with File.Writer in 0.15. Use direct write instead:

```zig
// Avoid this - may have issues:
try std.fmt.format(writer, "...", .{});

// Better approach - direct writes:
_ = try stdout.write("text");
_ = try stdout.write(std.fmt.comptimePrint("{}", .{number})); // only for comptime-known values

// Runtime formatting:
var buf: [16]u8 = undefined;
const str = std.fmt.bufPrint(&buf, "{}", .{number}) catch "";
_ = try stdout.write(str);
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
