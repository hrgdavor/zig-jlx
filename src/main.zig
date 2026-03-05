const std = @import("std");
const args_mod = @import("args.zig");
const config_mod = @import("config.zig");
const processor_mod = @import("processor.zig");
const server_mod = @import("server.zig");

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

    if (args.help) {
        try args_mod.Args.printHelp();
        std.process.exit(1);
    }

    if (args.config == null and !args.keys) {
        var stderr_buffer: [4096]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
        const stderr = &stderr_writer.interface;

        try stderr.writeAll(HELP);

        // If a file path was given, resolve its parent and inject it into the sample
        if (args.file_path) |fp| {
            var real_buf: [4096]u8 = undefined;
            const real = std.fs.cwd().realpath(fp, &real_buf) catch fp;
            const parent = std.fs.path.dirname(real) orelse real;
            try stderr.print(
                \\
                \\; Suggested paths for your file:
                \\paths     = {s}
                \\
            , .{parent});
        }

        try stderr.writeAll("\n");
        try stderr.flush();
        std.process.exit(1);
    }

    var config = config_mod.Config.init(parse_allocator);
    defer config.deinit();

    if (args.config) |path| {
        try config.load(path);
    }

    if (args.serve) {
        var final_args = args;
        if (final_args.port == null) final_args.port = config.port orelse 3000;
        if (final_args.www == null) final_args.www = config.www;

        var server = server_mod.Server.init(allocator, final_args, &config);
        try server.run();
        return;
    }

    var processor = processor_mod.Processor.init(allocator, args, &config);
    defer processor.deinit();
    processor.run() catch |err| {
        std.debug.print("\n[Application Error: {}]\n", .{err});
        std.process.exit(1);
    };
}
