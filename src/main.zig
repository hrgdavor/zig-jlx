const std = @import("std");
const args_mod = @import("args.zig");
const config_mod = @import("config.zig");
const processor_mod = @import("processor.zig");

const HELP =
    \\Usage: gtlogj -c <config> [options] [file]
    \\
    \\  -c, --config  <path>   Config file (required)
    \\  [file]                 Input log file (reads stdin if omitted)
    \\  -t, --tail             Tail the file — shows only newly appended lines
    \\  -p, --profile <name>   Profile to use from config
    \\  -o, --output  <path>   Write output to file (default: stdout)
    \\  -x, --passthrough      Echo original line as-is (valid JSON lines only)
    \\  -i, --include <text>   Include only lines matching filter (repeatable)
    \\  -e, --exclude <text>   Exclude lines matching filter (repeatable)
    \\
    \\When no file is given, gtlogj reads from stdin.
    \\
    \\--- Sample config (save as gtlogj.conf and edit paths/keys as needed) ---
    \\
    \\[folders]
    \\paths     = /path/to/your/app/logs
    \\timestamp = ts
    \\level     = level
    \\message   = message
    \\output    = {timestamp} [{level}]: {message}
    \\
    \\[profile.timed]
    \\output    = {timestamp:datetime} [{level}]: {message}
    \\
    \\[folders]
    \\; fallback — used when CWD doesn't match any paths above
    \\output    = {timestamp} [{level}]: {message}
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try args_mod.Args.parse(allocator);
    var args_copy = args;
    defer args_copy.deinit(allocator);

    if (args.config_path == null) {
        const stderr = std.fs.File.stderr();
        try stderr.writeAll(HELP);

        // If a file path was given, resolve its parent and inject it into the sample
        if (args.file_path) |fp| {
            var real_buf: [4096]u8 = undefined;
            const real = std.fs.cwd().realpath(fp, &real_buf) catch fp;
            const parent = std.fs.path.dirname(real) orelse real;
            var path_buf: [4096 + 64]u8 = undefined;
            const paths_line = try std.fmt.bufPrint(&path_buf,
                \\
                \\; Suggested paths for your file:
                \\paths     = {s}
                \\
            , .{parent});
            try stderr.writeAll(paths_line);
        }

        try stderr.writeAll("\n");
        std.process.exit(1);
    }

    var config = config_mod.Config.init(allocator);
    defer config.deinit();

    if (args.config_path) |path| {
        try config.load(path);
    }

    var processor = processor_mod.Processor.init(allocator, args, config);
    try processor.run();
}
