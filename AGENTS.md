# Agent

use instructions.for.utility.md as context and adhere to instructions there, and update instructions.for.utility.md with any changes asked by further prompts.
Do not change instructions.for.utility.md without confirmation from user.

# zig build tool
zig build tool is in folder `./zig`

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
- `std.ArrayList(T)` - now an alias for `array_list.Aligned(T, null)` (unmanaged)
- `std.ArrayListUnmanaged(T)` - alias for `ArrayList(T)`
- `array_list.AlignedManaged(T, null)` - the managed version with allocator

### Creating Managed ArrayList
```zig
// Old (0.14): var list = std.ArrayList(u8).init(allocator);
// New (0.15):
var list = std.array_list.AlignedManaged(u8, null).init(allocator);
defer list.deinit(allocator);
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
