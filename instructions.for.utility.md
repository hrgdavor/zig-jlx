
make this a commandline utility that can read log files that are text with each line containing serialized json object, optionally prefixed with some text that can be ignored (look for first '{' in a line to assume json starts there and not required from first character)
- if parsing a line fails, ignore that line

the utility called jlx should work by either:
- reading a file (`-t path`)
- reading stdin (when `-t` is omitted, read from stdin automatically)
- tailing a file (`-t path` — shows only newly appended lines; uses raw read+sleep loop so new bytes are always detected)

A positional (bare) path argument is also accepted as the file path (useful with `-t`).

define a configuration file where options for what the utility does, how it displays results and input parameters.
config file location will be provided as a param (-c --config). If -c is not provided, print usage help to stderr and exit with code 1.
The help text must also include a sample config block (ready to copy-paste) so new users can start immediately.

config file can have multiple sections called [folders] so each folders section can have its global configuration, and:
-  each folders section can define multiple folder paths that it matches (comma-separated on the `paths` key)
- **file mode**: folder matching resolves the **parent directory of the log file** (real path) and compares it against configured paths, case-insensitively (important on Windows where drive letters differ in case); a [folders] section with no `paths` key is used as the fallback/default
- **stdin mode**: no file path available — the **first [folders] section** is used unconditionally
- each folders section also has subsections for additional configuration profiles (`[profile.<name>]`)
- when utility is called, `-p / --profile` selects a profile inside the matched folder section

Supported placeholders:
- Any key from the JSON log line can be used as a placeholder (e.g., `{custom_key}`).
- Predefined aliases (like `{timestamp}`, `{level}`, `{message}`, `{thread}`, `{logger}`, `{trace}`) resolve to the real key configured for that folder/profile.
- Both the alias (e.g., `{level}`) and the actual JSON key (e.g., `{severity}`) are supported.
- If a placeholder key is not present in a specific log line, it is replaced with an empty string.
- `{timestamp:datetime}` — special format for the configured timestamp key, outputs ISO format `YYYY-MM-DD HH:MM:SS`.
- `{timestamp:time}` — outputs `HH:MM:SS`.
- `{timestamp:timems}` — outputs `HH:MM:SS.mmm`.

Folders and profiles define an `output` format string using these placeholders.
Default output format: `[{level}] {timestamp}: {message}`

Placeholder details:
- `{timestamp}` - maps to configured `timestamp` key (default `ts`), displays raw value.
- `{level}` - maps to configured `level` key (default `level`).
- `{message}` - maps to configured `message` key (default `message`).
- `{thread}` - maps to configured `thread` key (default `thread`).
- `{logger}` - maps to configured `logger` key (default `logger`).
- `{trace}` - maps to configured `trace` key (default `trace`).

The `message_expand` configuration option (optional) specifies the syntax used to interpolate additional JSON values into the message string during output. Available options:
- `curly` — interpolates `{name}`
- `js` — interpolates `${name}`
- `brackets` — interpolates `[name]`
- `parens` — interpolates `(name)`
- `printf` — interpolates `%name`
- `ruby` — interpolates `#{name}`
- `double_curly` — interpolates `{{name}}`
- `env` — interpolates `$name`
- `colon` — interpolates `:name`

**Formatting Modifiers:** You can append basic modifiers to expanded fields using `:` (e.g. `{code:hex}` or `%code:hex`):
- Strings: `:upper`, `:lower`
- Integers: `:hex` (e.g. `1a`), `:HEX` (e.g. `1A`)
- Floats: `:2`, `:4` (rounds to decimal places)

**Key-Value Printing:** You can append `=` to the end of any key (e.g., `{custom_field=}` or `{custom_field=:hex}`) to automatically render the output in `key=value` format (producing `custom_field=1A`). If the key does not exist, both the key and the value are completely omitted.

Command line parameters (implemented in `src/args.zig`):
- `-c / --config <path>` - path to configuration file (required for most commands, optional for `--keys`); utility prints help and exits with code 1 if omitted)
- `-p / --profile` - profile to use from config file
- `<file>` - positional argument; path to the input log file; if omitted, reads from **stdin**
- `-t / --tail` - tail the file (the file path is the positional argument)
- `-o / --output` - output file (default: stdout)
- `-x / --passthrough` - output original line as-is, only for lines containing a valid JSON log entry (parsing/filtering is still performed to validate the line)
- `-i / --include <filter>` - include only lines matching filter; repeatable; combined with config-defined include filters
- `-e / --exclude <filter>` - exclude lines matching filter; repeatable; combined with config-defined exclude filters
- `-r / --range <range>` - filter by time/date range (e.g. "08:00..09:30" or "2024-01-01 10:00..")
- `-z / --zone <zone>` - timezone offset string (e.g. "+01:00", "-05:00", "UTC"); used for range matching and `{timestamp:datetime}` output
- `-v / --values <spec>` - collect unique values for a key; format `[prefix:]key`; silences normal output; tracks first occurrence
- `--keys` - collect and list all unique keys appearing in JSON log lines; silences normal output

Filters can also be defined in the config file per folder section or profile:
```
include = ERROR, WARN
exclude = healthcheck
```
Filter priority order: folder config → profile → CLI args (all lists are merged).
Filters can optionally target specific keys (`key:value`) or use regular expressions via the `mvzr` engine by prefixing the search string with `~` (global regex) or `re:` (target key regex, e.g., `key:re:^ERROR`).

test.conf should have a profile called `timed` that outputs: `{timestamp:datetime} [{level}]: {message}`
and a profile called `custom` that demonstrates arbitrary key placeholders, e.g.: `{timestamp} |{custom_field}|{missing_field}|: {message}`

`timestamp:datetime` means: read the timestamp key (using the alias resolution) and display in ISO format.
