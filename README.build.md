# Building `jlx` from Source

### Prerequisites

- **Zig ≥ 0.15.2** — [Download from ziglang.org](https://ziglang.org/download/)
- No other external dependencies; all Zig package dependencies are fetched automatically.

> [!NOTE]
> On **Linux**, `jlx` uses the kernel's native async I/O (`io_uring`/`epoll`) directly and does **not** depend on `libxev`. On **macOS** and **Windows**, it uses the [libxev](https://github.com/mitchellh/libxev) event library, which is fetched automatically.

### Quick build (native — current platform)

```sh
git clone <repo-url>
cd zig-jlx
zig build -Doptimize=ReleaseSafe
# binary is in zig-out/bin/jlx  (or jlx.exe on Windows)
```

### Platform-specific instructions

#### Linux (x86_64)

```sh
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl
# Produces a fully static binary — no glibc dependency
```

#### Linux (ARM64 / aarch64)

```sh
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-musl
```

#### macOS (Apple Silicon — M1/M2/M3)

```sh
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos
```

#### macOS (Intel x86_64)

```sh
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-macos
```

#### Windows (x86_64)

```sh
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows
# Produces zig-out/bin/jlx.exe
```

### Cross-compilation

Zig supports cross-compilation out of the box. You can build for any target from any host:

```sh
# Build a Linux binary from macOS or Windows
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl

# Build a Windows binary from Linux
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-windows

# Build a macOS ARM64 binary from Linux
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-macos
```

### Optimize modes

| Mode           | Description                                      |
|----------------|--------------------------------------------------|
| `Debug`        | *(default)* Fast build, no optimizations, asserts enabled |
| `ReleaseSafe`  | Optimized, with safety checks / bounds checking  |
| `ReleaseFast`  | Maximum performance, no safety checks            |
| `ReleaseSmall` | Smallest binary size                             |

### Running tests

```sh
zig build test
```
