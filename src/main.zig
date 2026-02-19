const std = @import("std");
const args_mod = @import("args.zig");
const config_mod = @import("config.zig");
const processor_mod = @import("processor.zig");

const HELP =
    \\Usage: gtlogj -c <config> [options]
    \\
    \\  -c, --config <path>    Config file (required)
    \\  -f, --file   <path>    Input log file (reads stdin if omitted)
    \\  -p, --profile <name>   Profile to use from config
    \\  -t, --tail             Tail the file (only with -f)
    \\  -o, --output <path>    Write output to file (default: stdout)
    \\  -r, --raw              Output original JSON lines (validating only)
    \\
    \\When -f is not given, gtlogj reads from stdin.
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
