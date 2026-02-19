# gtlogj

A fast command-line utility for reading and formatting structured JSON log files. Or other text files where each line contains serialized json object.

Each log line can be optionally be preceded by arbitrary text (the first `{` marks the start of JSON). Lines that are not contain valid JSON (starting at first `{` until end of line) are silently skipped.

---

## Usage

```
gtlogj -c <config> [options] [file]
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

### Input modes

```sh
# Read a file (positional argument)
gtlogj -c app.conf app.log

# Tail a file — shows only NEW lines appended after start
gtlogj -c app.conf -t app.log

# Read from stdin (no file argument)
cat app.log | gtlogj -c app.conf
tail -f app.log | gtlogj -c app.conf -p timed
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

- **File mode**: `gtlogj` resolves the **parent directory of the log file**.
  - `paths`: (Optional) Comma-separated list of absolute folder paths. `gtlogj` matches the log file's parent directory against each section's `paths` list (prefix match, case-insensitive). The first match wins.
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
| `include`  | *(none)*                         | Comma-separated filters — only matching lines shown    |
| `exclude`  | *(none)*                         | Comma-separated filters — matching lines are hidden    |

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
include   = ERROR, WARN

[folders]
; fallback — used when CWD doesn't match any paths above
output    = [{level}] {timestamp}: {message}
```

---

## Output placeholders

Use `{key}` in the `output` format string. Any JSON key can be used; missing keys produce an empty string.

### Predefined aliases

The following aliases map to the JSON key configured in the matched `[folders]` section (or profile override):

| Placeholder            | Resolves to                                          |
|------------------------|------------------------------------------------------|
| `{timestamp}`          | Configured timestamp key — raw value                 |
| `{timestamp:datetime}` | Configured timestamp key — ISO `YYYY-MM-DD HH:MM:SS` |
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
gtlogj -c app.conf app.log -i ERROR

# Show everything except DEBUG
gtlogj -c app.conf app.log -e DEBUG

# Combine: only ERROR lines that don't contain "healthcheck"
gtlogj -c app.conf app.log -i ERROR -e healthcheck
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
gtlogj -c app.conf -r "08:00..09:30" app.log

# Logs from a specific date onwards
gtlogj -c app.conf -r "2024-02-19.." app.log

# Combine range with includes and timezone
gtlogj -c app.conf -z "+02:00" -r "10:00..11:00" -i ERROR app.log
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
gtlogj -v level app.log

# List all unique levels with their first-occurrence timestamp
gtlogj -v datetime:level app.log

# Show the first full line that triggered each unique error message
gtlogj -v line:message app.log -i ERROR
```

---

## Examples

### Testing with included assets

The repository includes `test.log` (with hourly entries for 2026-02-19) and `test.conf` to help you explore the utility features:

```sh
# Basic formatting
gtlogj -c test.conf test.log

# Range filter: morning logs only (UTC)
gtlogj -c test.conf test.log -r "08:00..12:00"

# Find first occurrence of each unique user in the afternoon
gtlogj -c test.conf test.log -r "12:00..18:00" -v user_id

# Show full lines for the first time each error message appeared today
gtlogj -c test.conf test.log -i ERROR -v line:message

# Inspect unique login events with timestamps
gtlogj -c test.conf test.log -i "User login" -v datetime:user_id
```

### General usage

```sh
# Default format
gtlogj -c myapp.conf app.log

# ISO timestamp using a profile
gtlogj -c myapp.conf -p timed app.log

# Tail live log with profile
gtlogj -c myapp.conf -p timed -t app.log

# Pipe from kubectl
kubectl logs my-pod | gtlogj -c k8s.conf -p timed

# Output raw JSON lines for further processing
gtlogj -c myapp.conf -x app.log | jq .message

# Filter while tailing
gtlogj -c myapp.conf -t app.log -i ERROR -e "connection reset"
```
