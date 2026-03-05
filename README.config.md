# JLX Configuration Guide

`jlx` is designed to be a high-performance, structure-aware tool for JSON logs. Unlike `grep` or `less`, which are format-agnostic, `jlx` requires a small "mandatory step" of configuration to unlock its full potential.

## Why Configure?

Every application logs JSON differently. One app might use `ts` for timestamps, while another uses `timestamp` or `time`. Without knowing which key is which, a tool cannot provide rich features like:
- **Consistent Time Formatting**: Converting varied raw timestamps into readable local time.
- **Level-Based Highlighting**: Color-coding lines based on their severity (`info`, `warn`, `error`).
- **Rich Web Interaction**: The web interface allows for custom JS scripting and deep analysis using browser tools—but only if it knows the structure of your data.

## Configuration File Structure

The configuration file (default `test.conf` or specified via `--config`) uses a simple key-value format organized into sections.

### Top-Level Settings
Global settings that apply to the entire `jlx` instance.

| Key    | Description                            | Example         |
| :----- | :------------------------------------- | :-------------- |
| `port` | The port for the web interface server. | `port = 8080`   |
| `www`  | Path to the web assets directory.      | `www = ./src-js`|

---

### [folders] Section
Defines how `jlx` should interpret logs in specific filesystem paths. 

```ini
[folders]
paths = /var/log/myapp, /tmp/app-logs
timestamp = ts
level = lvl
message = msg
output = {timestamp} {level} {message}
```

| Key              | Default                         | Description                                              |
| :--------------- | :------------------------------ | :------------------------------------------------------- |
| `paths`          | (Required)                      | Comma-separated list of directories to watch or process. |
| `timestamp`      | `ts`                            | The JSON key containing the log timestamp.               |
| `level`          | `level`                         | The JSON key containing the log level (info, warn, etc). |
| `message`        | `message`                       | The JSON key containing the primary log message.         |
| `output`         | `{timestamp} {level} {message}` | The template for console/file output.                    |
| `message_expand` | `null`                          | Syntax for expanding keys inside the message field.     |
| `include`        | `[]`                            | Comma-separated list of default include filters.         |
| `exclude`        | `[]`                            | Comma-separated list of default exclude filters.         |

---

### [profile.NAME] Section
Profiles allow you to override folder defaults for specific use cases (e.g., a "debugging" profile). They are nested under a `[folders]` section.

```ini
[folders]
paths = /var/log/myapp
timestamp = ts

[profile.debug]
output = {timestamp} [{level}] {message} -- {trace_id}
include = level:error, key:value
```

Enable a profile via the CLI: `jlx --profile debug /path/to/log`

---

## Output Template Syntax

The `output` field supports placeholders wrapped in `{}`. These correspond to standard keys or any raw key found in your JSON.

- `{timestamp}`: Formatted timestamp.
- `{level}`: Colorized log level.
- `{message}`: The message text (potentially expanded).
- `{any_key}`: Any other key from the JSON object.

---

## Message Expansion (`message_expand`)

Sometimes log messages themselves contain variables (e.g., `"msg": "user {id} logged in"`). `jlx` can interpolate these variables from the same JSON object.

| Syntax         | Example Message      | Target Variable |
| :------------- | :------------------- | :-------------- |
| `curly`        | `user {id} failed`   | `id`            |
| `double_curly` | `user {{id}} failed` | `id`            |
| `js`           | `user ${id} failed`  | `id`            |
| `ruby`         | `user #{id} failed`  | `id`            |
| `brackets`     | `user [id] failed`   | `id`            |
| `parens`       | `user (id) failed`   | `id`            |
| `printf`       | `user %id% failed`   | `id`            |
| `env`          | `user $id failed`    | `id`            |
| `colon`        | `user :id failed`    | `id`            |

---

## A World of Opportunities

While configuring keys might seem like an extra step, it transforms your log stream into a queryable database.

1. **Web Interface**: Browse logs in a rich UI with real-time filtering.
2. **Browser Console Power**: Open the browser tools on the `jlx` web page. You can write custom snippets to analyze trends, count occurrences, or visualize data using standard JavaScript.
3. **Smart Tail**: Instantly jump to the last N lines or follow files while still benefiting from structured formatting and filtering.

By defining your structure once, you stop "grepping" through noise and start analyzing data.
