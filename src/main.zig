const std = @import("std");
const args_mod = @import("args.zig");
const config_mod = @import("config.zig");
const processor_mod = @import("processor.zig");

const HELP =
    \\Usage: jlx -c <config> [options] [file]
    \\Run `jlx --help` for a full list of options.
    \\When no file is given, jlx reads from stdin.
    \\
    \\--- Sample config (save as jlx.conf and edit paths/keys as needed) ---
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
    \\[profile.time]
    \\output    = {timestamp:timems} [{level}]: {message}
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

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parse_allocator = parse_arena.allocator();

    const args = try args_mod.Args.parse(parse_allocator);

    if (args.config_path == null and !args.keys) {
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

    var config = config_mod.Config.init(parse_allocator);

    if (args.config_path) |path| {
        try config.load(path);
    }

    var processor = processor_mod.Processor.init(allocator, args, config);
    try processor.run();
}
