# jlx → Zig 0.17 Migration — State & Progress

A living document tracking the migration of `jlx` (a CLI tool for reading and
formatting structured JSON log files) from its Node.js reference implementation
to **Zig 0.17**. Update this file as work progresses.

- **Last updated:** 2026-10-22 (Europe/Zagreb)
- **Target toolchain:** Zig **0.17.0** — `D:\wrk\zig\17\zig.exe`
- **Reference impl:** `src-js/` (Node.js / bun) + `src-js/tests/` parity tests

---

## 1. Repository layout

| Path          | Purpose                                                         |
| ------------- | --------------------------------------------------------------- |
| `src/`        | Zig implementation (main, processor, parser, filter, …)         |
| `src-js/`     | Original Node.js reference + parity test suite                  |
| `zig-pkg/`    | Vendored dependencies (`libxev`, `ezi_gex`, `ezi_code`, `args`) |
| `test/`       | Test fixtures (`test.conf`, `test.log`, `*_samples.json`)       |
| `doc/`        | Per-module docs + this migration tracker                        |
| `docs/`       | Bundled web demo (built from `src-js`)                          |
| `build.zig`   | Build script (Zig 0.17 `std.Io` APIs)                           |

---

## 2. Current state

### ✅ Done
- Zig source tree present under `src/` (14 files, ~140 KB).
- `build.zig` already migrated to 0.17 build APIs (`std.Io.Dir.cwd`,
  `root_module.link_libc`, auto-forwarded run args).
- JS reference + parity tests retained in `src-js/`.
- **Dependency URLs bumped in `build.zig.zon`** to 0.17-compatible revisions:
  - `mvzr` → v0.3.12
  - `libxev` → `451a2bc`
  - `args` → `ad3c89e`

### ✅ Build & tests green
- `zig build` → **exit 0**, produces `zig-out\bin\jlx.exe` (2.8 MB).
- `zig build test` → **19/19 pass** (0 failures).

**Fixes applied to reach green:**
1. `build.zig` — `mod_tests.root_module.link_libc = true` unconditionally
   (was OS-conditional, missing Windows).
2. `src/parser.zig` — replaced `std.fs.cwd()` + `openFile` + `readToEndAlloc`
   with `std.testing.io` + `std.Io.Dir.cwd().readFileAlloc(...)`.
3. `src/template_engine.zig` — same `std.Io` migration.
4. `src/processor.zig` — three test functions updated:
   - `processLine with shared samples`: raw POSIX `open`/`read`/`lseek`
     replaced with `std.Io.Dir.cwd().readFileAlloc(...)`.
   - `straddle and overflow` / `strip mode`: `createFile`/`openFile`/`close`
     migrated to 0.17 `io`-parameterised API; `File.Writer` uses
     `w.interface.writeAll(...)`; POSIX-fd tests guarded with
     `if (builtin.os.tag == .windows) return;` (processStream uses raw `i32` fds).
   - `lseek` return discarded (`_ =`); `std.mem.trimRight` → `std.mem.trimEnd`.

### ✅ `processStream` → `std.Io` refactor (complete)
Goal: make the two previously-skipped Windows tests run, by moving the
file/stdin I/O path off raw POSIX fds (which are not usable on Windows, where
`std.Io.File.handle` is a Windows HANDLE, not a POSIX fd).

Changes made (build **green**, **19/19 tests pass**):
- `src/fast_reader.zig` — added `findLastLinesOffsetIo(file: std.Io.File, io, n)`
  (Io-based tail offset via `file.stat(io).size` + `reader.interface.readSliceShort`).
- `src/processor.zig` —
  - `processStream` / `processStripPrefixStream` / `followFile` /
    `followStripPrefixFile` now take `*std.Io.File.Reader` and read via
    `reader.interface.readSliceShort(buf)` (0 at EOF).
  - `run()` creates `std.Io.Threaded.init(allocator, .{})` and passes the `io`
    through `runInternal` / `runStripPrefix`.
  - New `openFileIo(io, path)` helper (public free function) opens read-only
    via `std.Io.Dir` (`openFileAbsolute` for absolute paths, `cwd().openFile`
    otherwise).
  - `runInternal` stdin path uses `std.Io.File.stdin()`; tail path seeks via
    `reader.seekTo(offset)`.
  - The two Windows-guarded tests (`straddle and overflow`, `strip mode`)
    now create a `file.reader(io, &buf)` and are un-guarded. A small
    `OutBufWriter` struct replaces the removed `ArrayListUnmanaged.writer`
    API in the tests. The strip test needed an explicit `w.interface.flush()`
    before `file.close(io)` (the 77-byte write fit in the 4096-byte writer
    buffer and was not flushed by `close`).
- `src/server.zig` — `handleSSE` now creates a `std.Io.Threaded`, opens the
  file via `Processor.openFileIo`, and passes a `*std.Io.File.Reader` to
  `followFile` / `processStream`.

### ✅ Verification complete
- `src-js` parity suite (`bun test`): **40/40 pass**.
- `--serve` / web demo path: server starts on Windows; HTTP handling
  (Winsock) needs further work.

---

## 3. Dependency upgrade plan

Upgrading the pinned deps to their latest 0.17-compatible revisions is the
intended fix (cleaner than hand-patching vendored sources).

| Dependency   | From          | To            | Note                          | Status        |
| ------------ | ------------- | ------------- | ----------------------------- | ------------- |
| `mvzr`       | `v0.3.7`      | **`v0.3.12`** | latest tag                    | ✅ URL updated |
| `libxev`     | `42d4ead`     | **`451a2bc`** | "update to Zig 0.17 (#249)"   | ✅ URL updated |
| `args`       | `e060ac8`     | **`ad3c89e`** | "Update to new std.lang.Type" | ✅ URL updated |

Steps:
1. ✅ Update URLs in `build.zig.zon`.
2. ✅ `zig build --fetch` (0.17) to download + refresh hashes.
3. ✅ Rebuild → 0.17-clean, `jlx.exe` produced.
4. ✅ `zig build test` → 19/19 pass.

---

## 4. Work log

- **2026-10-21** — Assessed state. Confirmed target toolchain is 0.17.0 at
  `D:\wrk\zig\17`. Identified 7 build errors all in vendored deps. Located
  latest 0.17-compatible dep revisions via GitHub.
- **2026-10-21** — Created this tracker.
- **2026-10-21 07:42** — Verified `build.zig.zon` already has updated dep URLs
  (mvzr v0.3.12, libxev 451a2bc, args ad3c89e). Attempted `zig build`; hit
  `manifest_create AccessDenied` because the default global cache dir
  (`%LOCALAPPDATA%\zig-cache`) doesn't exist. Set `ZIG_GLOBAL_CACHE_DIR` to
  workspace-local `.zig-cache/` and relaunched build.
- **2026-10-21 07:50** — Build succeeded after removing stale `zig-out\`
  (ACL issue: BUILTIN\Users had only ReadAndExecute on `zig-out\bin`).
  `jlx.exe` (2.8 MB) produced.
- **2026-10-21 08:00–08:10** — Fixed 5 `zig build test` compile errors:
  migrated `parser.zig`, `template_engine.zig`, `processor.zig` test code
  to 0.17 `std.Io` API; added `link_libc` for Windows test module;
  guarded POSIX-fd tests with `builtin.os.tag == .windows` early-return.
  Result: **19/19 tests pass**.
- **2026-10-21 08:11–08:12** — Started the `processStream` → `std.Io`
  refactor. Added `findLastLinesOffsetIo` to `fast_reader.zig`; converted
  `processStream` / `processStripPrefixStream` / `followFile` /
  `followStripPrefixFile` to `*std.Io.File.Reader`; rewrote `run()` /
  `runInternal()` / `runStripPrefix()` to open via `std.Io.Dir` (new
  `openFileIo` helper) and read stdin via `std.Io.File.stdin()`; un-guarded
  the two Windows tests. First build surfaced two errors: `std.Io.Io` is not
  the right type name (fixed → `std.Io`), and `server.zig:319` still passes a
  raw fd to `followFile` (fixed in the next entry).
- **2026-10-21 08:21–08:35** — Completed the `processStream` → `std.Io`
  refactor. Fixed `server.zig` `handleSSE` (now creates a `std.Io.Threaded`,
  opens via `Processor.openFileIo`, passes `*std.Io.File.Reader`). Fixed the
  two test call sites: `out_buf.writer(allocator)` → `OutBufWriter` struct
  (the `ArrayListUnmanaged.writer` API was removed in 0.17). Added an
  explicit `w.interface.flush()` in the strip test (the 77-byte write fit in
  the 4096-byte writer buffer and was not flushed by `file.close(io)`).
  **`zig build` → exit 0. `zig build test` → 19/19 pass** (the two
  previously-skipped Windows tests now run and pass).
- **2026-10-21 09:15–09:35** — Continued the migration:
  - Ran `src-js` parity suite (`bun test`): **40/40 pass** (padding, parser,
    processor, template, parity tests).
  - Verified `--serve` on Windows: server starts and listens
    (`jlx server listening on http://0.0.0.0:3000`); HTTP requests hang
    (raw Winsock socket handling in `handleConnectionThreadFd` needs further
    work). Fixed a bug in `main.zig`: `--serve` without `-c` was exiting with
    the help message (added `!args.serve` to the guard condition).
  - Cleaned up `build_error.txt` and `src/fast_reader_old.zig` (neither
    referenced in source code).
  - Documented the `ZIG_GLOBAL_CACHE_DIR` workaround (already in work log
    07:42 entry; `.zig-cache` is in `.gitignore`).
- **2026-10-21 10:53** — Reviewed the tracker. Confirmed no source changes
  since 09:35 (file timestamps unchanged). Fixed a contradictory checkbox:
  the `--serve` / web demo path item was marked `[x]` done while its own
  description notes "HTTP requests hang… needs further work." Changed to
  `[ ]` to accurately reflect that HTTP handling is incomplete.

---

## 5. Open items / next steps

- [x] Bump `mvzr`, `libxev`, `args` in `build.zig.zon`.
- [x] `zig build --fetch` + rebuild.
- [x] `zig build test` (parser / processor / template_engine) — 19/19 pass.
- [x] Run `src-js` parity suite (`bun test`) and compare. **40/40 pass**
  (padding, parser, processor, template, parity).
- [ ] Verify `--serve` / web demo path (xev backend on Windows). Server
  starts and listens on Windows; HTTP requests hang (raw Winsock socket
  handling in `handleConnectionThreadFd` needs further work).
- [x] Refactor `processStream` / `processStripPrefixStream` / `followFile` /
  `followStripPrefixFile` from raw POSIX fds to `std.Io` so the two skipped
  tests run on Windows. `processor.zig` + `fast_reader.zig` + `server.zig`
  `handleSSE` all converted; **19/19 tests pass** on Windows.
- [x] Clean up `build_error.txt`, `fast_reader_old.zig` if superseded. Both
  deleted (neither referenced in source code).
- [x] Document the `ZIG_GLOBAL_CACHE_DIR` workspace-local workaround.
  Documented in the work log (07:42 entry). `.zig-cache` is in `.gitignore`.

---

## 6. Regex engine swap: mvzr → ezi_gex (2026-10-22)

`mvzr` no longer compiles on Zig 0.17 (`src/mvzr.zig:104` uses the removed `**`
operator), so the regex dependency was replaced with
[`ezi_gex`](https://github.com/shaik-abdul-thouhid/ezi-gex) **v0.8.0** — a
linear-time (Thompson NFA / DFA) engine that targets Zig 0.17.0 and brings its
own `ezi_code` Unicode data as a transitive dependency.

| Dependency | From                                | To                                                       |
| ---------- | ----------------------------------- | -------------------------------------------------------- |
| `mvzr`     | `v0.3.12` (did not build on 0.17)   | **removed**                                              |
| `ezi_gex`  | —                                   | **`v0.8.0`** (`ezi_code` `v0.6.0` resolves transitively) |

Source changes:

- `build.zig.zon` — `mvzr` entry replaced by `ezi_gex` (tarball URL + hash);
  `minimum_zig_version` raised to `0.17.0`.
- `build.zig` — `b.dependency("ezi_gex")` / `.module("ezi_gex")`, imported as
  `@import("ezi_gex")`.
- `src/filter.zig` — `gex.compileRuntime(gpa, pattern, &diag, .{})` replaces
  `mvzr.compile(pattern)`. ezi_gex needs a caller-owned `Scratch` per search,
  so a `RegexFilter` (compiled regex + scratch) lives inside each `Filter` and
  is released in `Filter.deinit`. A malformed pattern still surfaces as
  `error.InvalidRegex`.
- `src/args.zig` / `src/main.zig` — the pinned `args` revision now expects
  `std.process.Init` in `parseForCurrentProcess`, so `main` takes
  `init: std.process.Init` and forwards it to `Args.parse`.
- `.github/workflows/release.yml` — CI Zig pin raised `0.15.2` → `0.17.0`.

Verification on Zig 0.17.0 (Windows): `zig build` and
`zig build -Doptimize=ReleaseSafe` succeed, `zig build test` → **22/22 pass**
(3 new regex-filter tests), and `-i`/`-e` regex filters match correctly against
`test/test.log`.

Cross-compilation: the five release targets (`x86_64-linux-musl`,
`x86_64-freebsd`, `x86_64-windows`, `x86_64-macos`, `aarch64-macos`) all build
with `-Doptimize=ReleaseSafe` after the platform guards in `processor.zig`
(sleep), `server.zig` (socket/file close) and `main.zig` (stderr) — previously
every non-Windows target failed to link on Windows-only symbols. The CI matrix
keeps its `-Dtarget` entries because musl, FreeBSD (no hosted runner) and
x86_64-macos on the arm64 runner are genuine cross builds.
