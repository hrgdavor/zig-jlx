# gtlogj

A fast command-line utility for reading and formatting structured JSON log files.

Each log line is expected to be a JSON object, optionally preceded by arbitrary text (the first `{` marks the start of JSON). Lines that are not valid JSON are silently skipped.

---

## Usage

```
gtlogj -c <config> [options] [file]
```

### Options

| Flag        | Long form   | Description                                         |
|-------------|-------------|-----------------------------------------------------|
| `-c <path>` | `--config`  | Config file (**required**)                          |
| `-t`        | `--tail`    | Tail the file — shows only newly appended lines     |
| `-p <name>` | `--profile` | Profile name to use from the matched config section |
| `-o <path>` | `--output`  | Write output to a file (default: stdout)            |
| `-r`        | `--raw`     | Echo original line as-is (only for valid JSON lines)|
| `-i <text>` | `--include` | Include only lines matching this filter (repeatable)|
| `-e <text>` | `--exclude` | Exclude lines matching this filter (repeatable)     |

### Input modes

```sh
# Read a file (positional argument)
gtlogj -c app.conf app.log

# Tail a file (positional argument)
gtlogj -c app.conf -t app.log

# Read from stdin (no file argument)
cat app.log | gtlogj -c app.conf
tail -f app.log | gtlogj -c app.conf -p timed
```

---

## Configuration file

The config file uses an INI-like format with one or more `[folders]` sections.

### Folder matching

When `gtlogj` starts it compares the **current working directory** against the `paths` listed in each `[folders]` section (case-insensitive). The first match wins. A section with no `paths` key is used as the fallback default.

### Per-section settings

| Key | Default | Description |
|-----|---------|-------------|
| `paths` | *(none)* | Comma-separated directory paths this section applies to |
| `output` | `[{level}] {timestamp}: {message}` | Output format string |
| `timestamp` | `ts` | JSON key for the timestamp field |
| `level` | `level` | JSON key for the log level field |
| `message` | `message` | JSON key for the message field |
| `thread` | `thread` | JSON key for the thread field |
| `logger` | `logger` | JSON key for the logger field |
| `trace` | `trace` | JSON key for the stack trace field |

### Profiles

Each `[folders]` section can have named sub-profiles (`[profile.<name>]`) that override individual settings. Select a profile with `-p <name>`.

### Example config

```ini
[folders]
paths = /home/user/myapp, /srv/logs
timestamp = @timestamp
level = level
message = message
output = [{level}] {timestamp}: {message}

[profile.timed]
output = {timestamp:datetime} [{level}]: {message}

[profile.verbose]
output = {timestamp:datetime} [{level}] ({logger}): {message}

[folders]
; fallback — matches any directory
output = [{level}] {timestamp}: {message}
```

---

## Output placeholders

Use `{key}` in the `output` format string. Any JSON key can be used; missing keys produce an empty string.

### Predefined aliases

| Placeholder | Value |
|------------|-------|
| `{timestamp}` | Configured timestamp key — raw value |
| `{timestamp:datetime}` | Configured timestamp key — ISO `YYYY-MM-DD HH:MM:SS` |
| `{level}` | Configured level key |
| `{message}` | Configured message key |
| `{thread}` | Configured thread key |
| `{logger}` | Configured logger key |
| `{trace}` | Configured trace key |

### Arbitrary JSON keys

Any key from the log line can be referenced directly:

```
output = {timestamp} |{request_id}|{user_id}|: {message}
```

If `request_id` or `user_id` is absent from a line, it is replaced with `""`.

---

## Examples

```sh
# Default format using folder config
gtlogj -c myapp.conf -f app.log

# ISO timestamp profile
gtlogj -c myapp.conf -f app.log -p timed

# Pipe from another command
kubectl logs my-pod | gtlogj -c k8s.conf -p timed

# Show raw valid JSON lines (useful for piping to jq)
gtlogj -c myapp.conf -f app.log -r | jq .message
```
