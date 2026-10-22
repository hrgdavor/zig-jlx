# Agents

## Zig toolchain

Use the Zig toolchain at `D:\wrk\zig\17` (`D:\wrk\zig\17\zig.exe`, Zig 0.17.0) for all Zig
commands in this repo. Do **not** rely on bare `zig` from `PATH` — it points at an older toolchain
(`D:\wrk\zig\16`, Zig 0.16.0) and produces results that do not match this project.

Always invoke it with the full path, e.g.:

```powershell
& "D:\wrk\zig\17\zig.exe" build
& "D:\wrk\zig\17\zig.exe" fetch --save <url>
```

Note: running `zig.exe` from outside the workspace requires elevated sandbox file access
(`danger-full-access`), because the process must read its own `lib/` files and TLS certificate
bundle from `D:\wrk\zig\17`.
