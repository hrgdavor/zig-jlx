# jlx

A fast command-line utility for reading and formatting structured JSON log files. Or other text files where each line contains serialized json object.

Reason for existence is to be able to write logs as JSON without sacrificing readability from shell. And then it gets even better as much more is within reach when log is structured.

Each log line can be optionally be preceded by arbitrary text (the first `{` marks the start of JSON). Lines that are not contain valid JSON (starting at first `{` until end of line) are silently skipped.

---

## Building from Source

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

---

## Usage

```
jlx -c <config> [options] [file]
```

### Options

| Flag        | Long form       | Description                                          |
|-------------|-----------------|------------------------------------------------------|
| `-c <path>` | `--config`      | Config file (**required**)                           |
| `-t`        | `--tail`        | Tail the file — shows only newly appended lines      |
| `-p <name>` | `--profile`     | Profile name to use from the matched config section  |
| `-o <path>` | `--output`      | Write output to a file (default: stdout)             |
| `-x`        | `--passthrough` | Echo original line as-is (valid JSON lines only)     |
| `-i <text>` | `--include`     | Include only lines matching filter (repeatable)      |
| `-e <text>` | `--exclude`     | Exclude lines matching filter (repeatable)           |
| `-r <range>`| `--range`       | Filter by time/date range (e.g. "08:00..09:30")      |
| `-z <zone>` | `--zone`        | Timezone offset (e.g. "+01:00", "-05:00", "UTC")     |
| `-v <spec>` | `--values`      | Collect unique values for a key (prefix:key)         |
|             | `--keys`        | Collect and list all unique JSON keys discovered     |

### Input modes

```sh
# Read a file (positional argument)
jlx -c app.conf app.log

# Tail a file — shows only NEW lines appended after start
jlx -c app.conf -t app.log

# Read from stdin (no file argument)
cat app.log | jlx -c app.conf
tail -f app.log | jlx -c app.conf -p timed
```

---

## Configuration file

The config file uses an INI-like format. Comments start with `;`.

### Structure

```ini
[folders]
paths   = /path/one, /path/two   ; directories this section applies to
output  = {timestamp} [{level}]: {message}

[profile.myprofile]
output  = {timestamp:datetime} [{level}]: {message}

[folders]
; second [folders] section with no paths = fallback for any directory
output  = [{level}] {timestamp}: {message}
```

A config file can have **multiple `[folders]` sections**.

- **File mode**: `jlx` resolves the **parent directory of the log file**.
  - `paths`: (Optional) Comma-separated list of absolute folder paths. `jlx` matches the log file's parent directory against each section's `paths` list (prefix match, case-insensitive). The first match wins.
  - If `paths` is omitted, the section acts as a **fallback** for any log file that doesn't match other sections.
- **Stdin mode**: no file path is available, so the **first `[folders]` section** is used unconditionally. Place your most general section first if you use stdin regularly.

Each `[folders]` section can contain **`[profile.<name>]`** sub-sections that override specific settings. Select a profile at runtime with `-p <name>`.

### `[folders]` keys

| Key        | Default                          | Description                                            |
|------------|----------------------------------|--------------------------------------------------------|
| `paths`    | *(none — fallback)*              | Comma-separated directory prefixes to match            |
| `output`   | `{level} {timestamp} {message}`  | Output format string (see Placeholders below)          |
| `timestamp`| `ts`                             | JSON key for the timestamp field                       |
| `level`    | `level`                          | JSON key for the log level field                       |
| `message`  | `message`                        | JSON key for the log message field                     |
| `thread`   | `thread`                         | JSON key for the thread field                          |
| `logger`   | `logger`                         | JSON key for the logger name field                     |
| `trace`    | `trace`                          | JSON key for the stack trace field                     |
| `include`  | *(none)*                         | Comma-separated filters — only matching lines shown. Supports key-specific and regex matching.   |
| `exclude`  | *(none)*                         | Comma-separated filters — matching lines are hidden. Supports key-specific and regex matching.   |

### `[profile.<name>]` keys

Profiles inherit all values from the parent `[folders]` section and can override any of the keys above (except `paths`).

### Full example

```ini
[folders]
paths     = /home/user/myapp, /srv/logs/myapp
timestamp = @timestamp
level     = level
message   = message
output    = [{level}] {timestamp}: {message}
exclude   = healthcheck, ping

[profile.timed]
output    = {timestamp:datetime} [{level}]: {message}

[profile.verbose]
output    = {timestamp:datetime} [{level}] ({logger}): {message}
include   = ERROR, level:WARN, message:re:^Connection.*

[folders]
; fallback — used when CWD doesn't match any paths above
output    = [{level}] {timestamp}: {message}
```

---

## Filtering Rules (`-i`, `-e`, `include`, `exclude`)

You can filter log messages by providing a comma-separated list of match patterns. Filters can be global (searching the raw JSON line before parsing, which is very fast) or key-specific. They also support basic substrings or Regular Expressions using the fast, lightweight `mvzr` engine.

### Global Literals
Any string without special prefixes: Searches the exact string literal across the entire raw JSON line.
`jlx -i ERROR`  — Matches any line containing the word "ERROR".

### Global Regex (`~` prefix)
Prefix the string with `~` to trigger a Regular Expression match on the entire raw JSON line.
`jlx -i "~^\{.*user_id.*123"` — Matches lines using regex syntax.

### Key-Specific Literals (`key:value`)
Use a `:` to isolate a search to a specific JSON key's value. Lines without the key are ignored.
`jlx -i level:WARN` — Matches only if the `"level"` key contains `"WARN"`.

### Key-Specific Regex (`key:re:value`)
Combine the `key:` target prefix with `re:` to evaluate a Regular Expression against a specific JSON key's value. 
`jlx -e "message:re:^Failed.*timeout"`

**Note on performance:** Filtering drops non-matching lines as early as possible. Global filters (literal and regex) are evaluated against the raw JSON string *before* the JSON parser runs. Key-specific target filters require the JSON to be fully parsed first.

---

## Output placeholders

Use `{key}` in the `output` format string. Any JSON key can be used; missing keys produce an empty string.

### Predefined aliases

The following aliases map to the JSON key configured in the matched `[folders]` section (or profile override):

| Placeholder            | Resolves to                                          |
|------------------------|------------------------------------------------------|
| `{timestamp}`          | Configured timestamp key — raw value                 |
| `{timestamp:datetime}` | Configured timestamp key — ISO `YYYY-MM-DD HH:MM:SS` |
| `{timestamp:time}`     | Configured timestamp key — `HH:MM:SS`                |
| `{timestamp:timems}`   | Configured timestamp key — `HH:MM:SS.mmm`            |
| `{level}`              | Configured level key                                 |
| `{message}`            | Configured message key                               |
| `{thread}`             | Configured thread key                                |
| `{logger}`             | Configured logger key                                |
| `{trace}`              | Configured trace key                                 |

### Arbitrary JSON keys

Any key from the log line can be referenced directly by name:

```
output = {timestamp} |{request_id}|{user_id}|: {message}
```

If a key is absent from a line it is replaced with `""`.

---

## Filtering

Filters are simple substring matches (more filter types planned). A line must pass all active filters to be shown.

- **Exclude takes precedence** over include.
- Filters from `[folders]`, `[profile]`, and CLI flags (`-i`/`-e`) are **all merged**.

```sh
# Show only ERROR lines
jlx -c app.conf app.log -i ERROR

# Show everything except DEBUG
jlx -c app.conf app.log -e DEBUG

# Combine: only ERROR lines that don't contain "healthcheck"
jlx -c app.conf app.log -i ERROR -e healthcheck
```

---

## Range Filtering

The `-r` / `--range` flag allows filtering logs by their timestamp. Use the format `from..to`.

### Syntax

- `HH:MM:SS..HH:MM:SS` (time-only: matches time-of-day in the configured timezone)
- `YYYY-MM-DD HH:MM:SS..YYYY-MM-DD HH:MM:SS` (datetime: specific absolute range)
- Either side can be omitted: `..09:00` (until 9 AM), `2024-01-01..` (from Jan 1st)

### Timezone Support

Use `-z` / `--zone` to specify the timezone offset (e.g., `+01:00`, `-05:00`).
- Affects how time-only ranges are interpreted.
- Affects the output of `{timestamp:datetime}`.
- Defaults to UTC if omitted.

### Range Examples

```sh
# Only logs between 8:00 and 9:30 AM (local time)
jlx -c app.conf -r "08:00..09:30" app.log

# Logs from a specific date onwards
jlx -c app.conf -r "2024-02-19.." app.log

# Combine range with includes and timezone
jlx -c app.conf -z "+02:00" -r "10:00..11:00" -i ERROR app.log
```

---

## Value Inspection

The `-v` / `--values` flag silences regular output and collects unique values for a specified JSON key. It also shows the line where each value first appeared.

### Syntax

`-v [prefix:]key`

- `key`: The JSON key to collect unique values for (e.g., `-v level`).
- `prefix`: (Optional) Controls what is printed for each unique value:
    - (None): Prints only the unique values.
    - `datetime:`: Prints the timestamp of the first occurrence followed by the value.
    - `line:`: Prints the full formatted line, then the value, then a blank line.

### Examples

```sh
# List all unique log levels
jlx -v level app.log

# List all unique levels with their first-occurrence timestamp
jlx -v datetime:level app.log

# Show the first full line that triggered each unique error message
jlx -v line:message app.log -i ERROR
```

---

## Key Discovery

The `--keys` flag scans JSON log entries and collects a unique list of all keys encountered. This is useful for exploring unknown log formats.

> [!TIP]
> **For large log files**, use `--keys` with `head` to scan just a sample:
> ```sh
> jlx -c test.conf --keys test.log | head -n 100
> ```

### Examples

```sh
# Discover all keys in a log file (no config required!)
jlx --keys app.log

# Also works with piped input
cat app.log | jlx --keys
```

---

## Examples

### Testing with included assets

The repository includes `test.log` (with hourly entries for 2026-02-19) and `test.conf` to help you explore the utility features:

```sh
# Basic formatting
jlx -c test.conf test.log

# Range filter: morning logs only (UTC)
jlx -c test.conf test.log -r "08:00..12:00"

# Find first occurrence of each unique user in the afternoon
jlx -c test.conf test.log -r "12:00..18:00" -v user_id

# Show full lines for the first time each error message appeared today
jlx -c test.conf test.log -i ERROR -v line:message

# Inspect unique login events with timestamps
jlx -c test.conf test.log -i "User login" -v datetime:user_id
```

### General usage

```sh
# Basic usage (requires a config file for most commands)
jlx -c myapp.conf app.log

# Command-line configuration requirement
# The -c/--config flag is REQUIRED for all operations EXCEPT --keys.

# ISO timestamp using a profile
jlx -c myapp.conf -p timed app.log

# Tail live log with profile
jlx -c myapp.conf -p timed -t app.log

# Pipe from kubectl
kubectl logs my-pod | jlx -c k8s.conf -p timed

# Output raw JSON lines for further processing
jlx -c myapp.conf -x app.log | jq .message

# Filter while tailing
jlx -c myapp.conf -t app.log -i ERROR -e "connection reset"
```

---

## Performance & Architecture

`jlx` is designed for high-performance log processing, employing several memory and allocation optimizations to minimize overhead:

### Dynamic Block Buffering (1MB - 16MB)
Instead of traditionally allocating memory for each line being read, `jlx` utilizes a single, reusable `1MB - 16MB` block buffer. The file stream is bulk-read directly into this buffer. 
Lines are scanned in-place by simply hunting for the `\n` character. Incomplete lines at the end of the buffer are intelligently shifted (using `std.mem.copyForwards`) to the start, and the buffer resumes filling natively.

This approach guarantees zero file-reading allocations for any line under 1MB. If reading encounters a massive log entry, the buffer dynamically doubles up to a hard cap of `16MB`. If a line exceeds 16MB without a newline, `jlx` intercepts it, prints a warning (in verbose mode), and safely skips to the next newline to prevent Out-Of-Memory (OOM) crashes.

### Zero-Allocation JSON Parser
The custom JSON parser avoids generating an Abstract Syntax Tree (AST) or copying strings into a new memory location. It simply outputs a `std.StringHashMap` that references exact `[]const u8` slices straight from the `1MB` static reading buffer. 

### Line-Scoped Arena Allocator
Formatting log output to the terminal requires dynamic string morphing, duplication, substitutions, and replacements (e.g., dynamically substituting `{level}` and `{timestamp}` from templates).
Running standard heap allocators to allocate and free these strings per line, millions of times, degrades performance.

To achieve near-zero string cleanup overhead in the hot path, `jlx` wraps the line expansion functionality in a **Line-Scoped Arena Allocator** (`std.heap.ArenaAllocator`). 
At the start of processing a log line, the arena provides memory for parsed items and format templates. At the end of the line, instead of individually freeing dozens of string permutations, `jlx` instantly resets the arena (`arena.reset(.retain_capacity)`). This allows memory to be inherently pooled and reused for the next line without any continuous malloc overhead.
---

## 🛠️ Log Generation

A high-performance JS script is provided in `scripts/generate-log.js` to create synthetic datasets for testing. 

By default, it generates **session-based ticket logs** for a single day (`2026-03-04`).

```bash
# Generate 10,000 lines of ticket logs
bun scripts/generate-log.js 10000 > test_session_tickets.log
```

The logs include:
- `ts`: Millisecond timestamp
- `level`: INFO/WARN/ERROR/DEBUG/TRACE
- `sessionId`: Random session identifiers (e.g., `sess-123456`)
- `ticketId`: Ticket references (e.g., `TKT-1001`)
- `userId`: User IDs
- `message`: Randomized ticket-related actions (fetching, status updates, assignments)

---

## JavaScript Implementation & Interactive Demo

We provide a reference JavaScript implementation of the `jlx` core logic in the [`src-js`](./src-js) folder, along with an interactive web-based demo.

### 🚀 Interactive Demo

The demo allows you to practice `jlx` usage, live-preview log formatting, and generate equivalent CLI commands directly in your browser.

- **How to refresh everything:**
```bash
cd src-js
bun run generate-test-log     # Refreshes the test log (3000 lines)
bun run build-demo            # Bundles demo and copies the refreshed log
```
    2. Run a local server to enable `fetch` features:
       ```bash
       bun x serve ../docs
       ```
    3. Open the provided `localhost` URL in your browser.

> [!NOTE]
> The demo source is located in [`src-js/demo.html`](./src-js/demo.html). It is bundled into a standalone file using `bun run build-demo` inside the `src-js` folder.

### 🧪 JS Core & Parity Tests

The JS implementation is managed with `bun` and includes a suite of parity tests to ensure it matches the Zig version's logic.

```bash
cd src-js
bun install
bun test
```

See the [src-js README](./src-js/README.md) for more details.

