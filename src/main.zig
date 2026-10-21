const std = @import("std");
const args_mod = @import("args.zig");
const config_mod = @import("config.zig");
const processor_mod = @import("processor.zig");
const server_mod = @import("server.zig");

extern "c" fn GetStdHandle(nStdHandle: i32) ?*anyopaque;
extern "c" fn WriteFile(hFile: ?*anyopaque, lpBuffer: *const anyopaque, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) i32;

fn writeStderr(s: []const u8) void {
    const handle = GetStdHandle(-12) orelse return; // STD_ERROR_HANDLE
    var written: u32 = 0;
    _ = WriteFile(handle, @ptrCast(s.ptr), @intCast(s.len), &written, null);
}

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
    const allocator = std.heap.c_allocator;

    var parse_arena = std.heap.ArenaAllocator.init(allocator);
    defer parse_arena.deinit();
    const parse_allocator = parse_arena.allocator();

    const args = try args_mod.Args.parse(parse_allocator);

    if (args.help) {
        try args_mod.Args.printHelp();
        std.process.exit(1);
    }

    if (args.config == null and !args.keys and !args.strip and !args.serve) {
        writeStderr(HELP);

        // If a file path was given, inject a suggestion
        if (args.file_path != null) {
            writeStderr("; Suggested paths for your file:\npaths = <parent directory of your file>\n");
        }

        writeStderr("\n");
        std.process.exit(1);
    }

    var config = config_mod.Config.init(parse_allocator);
    defer config.deinit();

    if (args.config) |path| {
        try config.load(path);
    }

    if (args.serve) {
        var final_args = args;
        if (final_args.port == null) final_args.port = "3000";
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
