# CI Fix Plan — zig-jlx (working document, continue in new session)

Last updated: 2026-10-22 (local, Europe/Zagreb). Status: **in progress — hashes fixed, not yet committed.**

## TL;DR for the new session

1. The original CI failure (hash mismatches in `build.zig.zon`) is **fixed in the working tree** via `zig fetch --save`. All three new hashes match exactly what CI's zig 0.15.2 computed.
2. A **second, latent failure** exists: the pinned mvzr source does not compile with **zig 0.17.0** (the toolchain we must use): `src/mvzr.zig:104:56: error: binary operator '*' has whitespace on one side, but not the other`. Leading hypothesis: `**` (binary power) is **no longer a token in zig 0.17.0**, so `} ** ops` tokenizes as `}` `*` `*` `ops` and the whitespace-mismatch diagnostic fires (char after the single `*` token is `*`, not whitespace).
3. The user decided: **CI must use zig 0.17.0 too** (`.github/workflows/release.yml` currently pins `mlugg/setup-zig@v2` version `'0.15.2'`). 0.17.0 **is an official release** (ziglang.org/news/0.17.0-released), so the workflow can pin `version: '0.17.0'`.
4. Blocker to resolve: find an mvzr pin that compiles under 0.17.0 (or otherwise make the build green), then update the workflow, verify locally with zig 17, commit, push, and re-trigger the tag-based release.

## RULE (from user, already recorded in `agents.md` at repo root)

Always use `D:\wrk\zig\17\zig.exe` (Zig 0.17.0) for all Zig commands in this repo. Do NOT use bare `zig` from PATH (that is `D:\wrk\zig\16`, Zig 0.16.0 — wrong toolchain). Running it needs sandbox escalation `danger-full-access` because the process must read its own `lib\` and TLS cert bundle from `D:\wrk\zig\17` (outside the workspace).

```powershell
cd D:\wrk\zig\zig-jlx
& "D:\wrk\zig\17\zig.exe" build --summary all
& "D:\wrk\zig\17\zig.exe" fetch --save <url>
```

## What failed originally (user-pasted CI log)

`release.yml` build (matrix, e.g. `x86_64-freebsd`), all 3 attempts failed at manifest verification:

| dep    | manifest declared                                                      | CI fetched                                                  |
| ------ | ---------------------------------------------------------------------- | ----------------------------------------------------------- |
| mvzr   | `mvzr-0.3.7-ZSOky5FtAQB2VrFQPNbXHQCFJxWTMAYEK7ljYEaMR6jt`              | `mvzr-0.3.9-ZSOky6t2AQCA7efmm5EYbPb5sOdbXa4EFsUgYbQ6hZv9`   |
| libxev | `libxev-0.0.0-86vtc0IbEwBzMSXa-ZPZ8JpcV4Mw1SrsTuvtJmFAQ7Uu`            | `libxev-0.0.0-86vtc8QQFACz0sVc7U-VDiDIgH-XfBuEY5JpABLjHNpn` |
| args   | `N-V-__8AAI_RAADz2TiHUzG5-0Mk7IZHR-h1SZgUrb_k4c7d` (malformed old pin) | `args-0.0.0-CiLiqmHiAABlN6icC9sZHdp8HVplOXDxuUNz2VUY_K2X`   |

Root cause: `build.zig.zon` URLs were bumped (mvzr → tag `v0.3.12`, libxev → commit `451a2bc03644c2b70fb28a808313d12989bfa8e3`, args → commit `ad3c89ecdb2979b8b5d52b43b78e79bf51293235`) but the `.hash` fields were never regenerated.

## Done so far

- [x] Regenerated all three hashes with `zig fetch --save <url>` (mvzr via PATH zig 0.16.0 first, then libxev+args via zig 17). Current `build.zig.zon` (lines 35–46):
  - mvzr `mvzr-0.3.9-ZSOky6t2AQCA7efmm5EYbPb5sOdbXa4EFsUgYbQ6hZv9` — matches CI's fetched hash exactly
  - libxev `libxev-0.0.0-86vtc8QQFACz0sVc7U-VDiDIgH-XfBuEY5JpABLjHNpn` — matches CI's fetched hash exactly
  - args `args-0.0.0-CiLiqmHiAABlN6icC9sZHdp8HVplOXDxuUNz2VUY_K2X` — matches CI format
- [x] Confirmed hash algorithm is identical across 0.15.2 / 0.16.0 / 0.17.0 (CI's 0.15.2-computed hash == local computed hash), so the new hashes are valid for any of these toolchains.
- [x] Created `agents.md` (repo root) documenting the zig 17 toolchain rule + escalation note.
- [x] Reproduced build locally with zig 17 → second error found (mvzr, below).

Working tree state: `build.zig.zon` modified, `agents.md` new/untracked. Nothing committed yet. HEAD = `324d8d3` "v1.0.1rc1". `zig-pkg/`, `test.zig`, `.zig-cache` are gitignored.

## Second failure (the real blocker)

zig 17 build output:

```
zig-pkg\mvzr-0.3.9-ZSOky6t2AQCA7efmm5EYbPb5sOdbXa4EFsUgYbQ6hZv9\src\mvzr.zig:104:56: error: binary operator '*' has whitespace on one side, but not the other
        patt: [ops]RegOp = [1]RegOp{.{ .unused = {} }} ** ops,
                                                       ^
```

Facts established:

- Hexdump of the fetched file: plain ASCII, `0x20` space on **both** sides of `**`, LF line endings. Source is clean.
- Diagnostic condition (zig 17 `lib\std\zig\Parse.zig:1596-1614`):
  ```zig
  const char_before = p.source[p.tokenStart(oper_token) - 1];
  const char_after  = p.source[p.tokenStart(oper_token) + tok_len];
  if (std.ascii.isWhitespace(char_before) != std.ascii.isWhitespace(char_after)) { warnMsg(.mismatched_binary_op_whitespace) }
  ```
  For a two-char `**` token both sides are spaces → no warning. The warning fired ⇒ the token must be a **single `*`** (then `char_after` is the second `*`, non-whitespace). So `**` is apparently **not a single token in 0.17.0**.
- The same diagnostic message exists in zig 0.15.2 (`lib\std\zig\Ast.zig:531`) — but whether 0.15.2 still tokenizes `**` as one token is **unverified** (grep timed out; don't re-run 0.15.2 zig per user instruction — only inspect its files if needed).
- Grep for `binary_pow` in `D:\wrk\zig\17\lib\std\zig` → **no matches** (supports the "operator removed/renamed" hypothesis).
- Build reported "1 errors" — it stopped at this first error; libxev/args compile status under 0.17.0 is untested.
- Oddity: mvzr tag `v0.3.12` content declares internal version `0.3.9` (maintainer tagged v0.3.12 without bumping the manifest version).

## Open questions / next steps

1. **Confirm whether `**` was removed/changed in 0.17.0.**
   - Check 0.17.0 release notes: https://ziglang.org/news/0.17.0-released/ and https://ziglang.org/download/0.17.0/release-notes.html
   - Grep the 0.17.0 tokenizer/operator table for the `**` lexeme (files: `D:\wrk\zig\17\lib\std\zig\tokenizer.zig`, `AstGen.zig` — note `Token.zig` does not exist in this layout).
   - Minimal repro (optional, decisive): create `test.zig` (gitignored) with `const

## Resolution (2026-10-22, later session)

The blocker is resolved by **dropping `mvzr`** rather than hunting for a newer
tag: its `**` usage cannot compile on Zig 0.17. The project now uses
[`ezi_gex`](https://github.com/shaik-abdul-thouhid/ezi-gex) **v0.8.0**, a
linear-time regex engine whose manifest requires Zig 0.17.0 (it pulls `ezi_code`
v0.6.0 transitively).

| Item                            | Change                                                                             |
| ------------------------------- | ---------------------------------------------------------------------------------- |
| `build.zig.zon`                 | `.mvzr` removed; `.ezi_gex` v0.8.0 added (`ezi_gex-0.8.0-fTQAPA9qKQA7mCilJYQta0IEhAr06iMvsCcSzImz6GRb`); `minimum_zig_version` → `0.17.0` |
| `build.zig`                     | `b.dependency("ezi_gex")` / `.module("ezi_gex")`, imported as `@import("ezi_gex")` |
| `src/filter.zig`                | `gex.compileRuntime(gpa, pat, &diag, .{})`; each `Filter` owns a `RegexFilter` (regex + `gex.Scratch`) freed in `Filter.deinit`; bad pattern → `error.InvalidRegex` |
| `.github/workflows/release.yml` | Zig pin `0.15.2` → `0.17.0` (per decision in item 3 above)                         |

Next blocker found after the hash fix: the pinned `args` revision expects
`std.process.Init` in `parseForCurrentProcess`, so `src/main.zig` now takes
`init: std.process.Init` and `src/args.zig` forwards it.

Verified locally with `D:\wrk\zig\17\zig.exe`: `zig build` ok,
`zig build -Doptimize=ReleaseSafe` ok, `zig build test` → **22/22 pass** (3 new
regex-filter tests), regex filters match correctly on `test/test.log`.

Still open (pre-existing, unrelated to the regex swap): non-Windows targets do
not link because `Sleep`, `closesocket`, `GetStdHandle`, `WriteFile` and
`_close` are referenced unconditionally, so the CI matrix's linux/freebsd/macos
legs need platform guards before a release run can go green.

## Follow-up: platform guards — resolved

The non-Windows link failures were fixed with comptime OS gates (Windows
behaviour unchanged):

| File                | Fix                                                                                    |
| ------------------- | -------------------------------------------------------------------------------------- |
| `src/processor.zig` | `sleepMs` uses `Sleep` on Windows, `nanosleep` elsewhere (0.17 moved sleeping into `std.Io`, which the follow loops do not carry) |
| `src/server.zig`    | `closeSocket` (`closesocket` vs `close`) and `closeFile` (`_close` vs `close`) helpers |
| `src/main.zig`      | `writeStderr` uses `GetStdHandle`/`WriteFile` on Windows, `std.debug.print` elsewhere  |

Cross-build matrix verified locally with `D:\wrk\zig\17\zig.exe` (ReleaseSafe):

- `x86_64-linux-musl` — ok
- `x86_64-freebsd` — ok
- `x86_64-windows` — ok
- `x86_64-macos` — ok
- `aarch64-macos` — ok

Native `zig build` + `zig build test` (22/22) remain green. Cross-compilation is
still required in CI for musl, FreeBSD (no hosted runner) and x86_64-macos on
the arm64 runner, so the `-Dtarget` matrix entries stay.