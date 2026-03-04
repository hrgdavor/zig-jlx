const std = @import("std");
const args_lib = @import("args");

pub const Args = struct {
    config: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
    follow: bool = false,
    output: ?[]const u8 = null,
    passthrough: bool = false,
    /// Filter string from -i / --include flag
    include: ?[]const u8 = null,
    /// Filter string from -e / --exclude flag
    exclude: ?[]const u8 = null,
    /// Raw range string from -r / --range (e.g. "08:00..09:30")
    range: ?[]const u8 = null,
    /// Timezone offset string from -z / --zone (e.g. "+01:00")
    zone: ?[]const u8 = null,
    /// Value inspection string from -v / --values (e.g. "datetime:level")
    values: ?[]const u8 = null,
    /// Collect and list all unique keys found in JSON lines
    keys: bool = false,
    verbose: bool = false,
    help: bool = false,

    // Server mode
    serve: bool = false,
    port: u16 = 3000,
    www: ?[]const u8 = null,

    pub const ArgsConfig = struct {
        config: ?[]const u8 = null,
        profile: ?[]const u8 = null,
        file_path: ?[]const u8 = null,
        follow: bool = false,
        output: ?[]const u8 = null,
        passthrough: bool = false,
        include: ?[]const u8 = null,
        exclude: ?[]const u8 = null,
        range: ?[]const u8 = null,
        zone: ?[]const u8 = null,
        values: ?[]const u8 = null,
        keys: bool = false,
        verbose: bool = false,
        help: bool = false,

        serve: bool = false,
        port: u16 = 3000,
        www: ?[]const u8 = null,

        // zig-args uses this specific field name for short flags
        pub const shorthands = .{
            .c = "config",
            .p = "profile",
            .f = "follow",
            .o = "output",
            .x = "passthrough",
            .i = "include",
            .e = "exclude",
            .r = "range",
            .z = "zone",
            .v = "values",
            .h = "help",
            .s = "serve",
            .w = "www",
        };

        // zig-args doesn't natively use this, but we keep it so your
        // metadata is preserved for the rest of your codebase logic.
        pub const __messages__ = .{
            .config = "Config file (required for most commands)",
            .profile = "Profile to use from config",
            .follow = "Follow the file — shows newly appended lines",
            .output = "Write output to file (default: stdout)",
            .passthrough = "Echo original line as-is (valid JSON lines only)",
            .include = "Include only lines matching filter",
            .exclude = "Exclude lines matching filter",
            .range = "Filter by time/date range",
            .zone = "Timezone offset for range and datetime display",
            .values = "Collect unique values for a key ([prefix:]key)",
            .keys = "Collect and list all unique keys (standalone)",
            .verbose = "Print errors when output formatting fails",
            .help = "Print this help message and exit",
            .serve = "Start a web server for interactive log analysis",
            .port = "Port to listen on (default 3000)",
            .www = "Path to static files to serve",
        };
    };

    pub fn parse(arena_allocator: std.mem.Allocator) !Args {
        // This is the core change: parseForCurrentProcess handles flags
        // found anywhere in the command line (interspersed).
        const parsed = try args_lib.parseForCurrentProcess(ArgsConfig, arena_allocator, args_lib.ErrorHandling.print);

        var args = Args{};

        // Maintain your logic: copy fields from the parser result to your Args struct.
        inline for (@typeInfo(ArgsConfig).@"struct".fields) |f| {
            if (@hasField(Args, f.name)) {
                @field(args, f.name) = @field(parsed.options, f.name);
            }
        }

        // Positional args are now correctly separated from flags.
        if (parsed.positionals.len > 0) {
            args.file_path = parsed.positionals[0];
        }

        return args;
    }

    pub fn printHelp() !void {
        var stdout_buffer: [1024]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
        const stdout = &stdout_writer.interface;
        const config = ArgsConfig;

        try stdout.print("Usage: [options] [file]\n\nOptions:\n", .{});

        inline for (@typeInfo(config).@"struct".fields) |field| {
            // Skip internal metadata fields
            comptime if (std.mem.eql(u8, field.name, "help")) continue;

            // Find if there's a shorthand for this field
            var short_char: ?u8 = null;
            inline for (@typeInfo(@TypeOf(config.shorthands)).@"struct".fields) |s| {
                if (std.mem.eql(u8, @field(config.shorthands, s.name), field.name)) {
                    short_char = s.name[0];
                }
            }

            // Get the help message
            const msg = if (@hasField(@TypeOf(config.__messages__), field.name))
                @field(config.__messages__, field.name)
            else
                "";

            // Print the formatted line
            if (short_char) |c| {
                try stdout.print("  -{c}, --{s:<15} {s}\n", .{ c, field.name, msg });
            } else {
                try stdout.print("      --{s:<15} {s}\n", .{ field.name, msg });
            }
        }

        try stdout.print("  -h, --help            {s}\n", .{config.__messages__.help});

        try stdout.flush();
    }
};
