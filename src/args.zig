const std = @import("std");
const args_lib = @import("args");

extern "c" fn puts(s: [*:0]const u8) c_int;
extern "c" fn printf(fmt: [*:0]const u8, ...) c_int;

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
    /// Standalone mode: print each line starting from first '{'
    strip: bool = false,
    verbose: bool = false,
    help: bool = false,

    // Server mode
    serve: bool = false,
    port: ?[]const u8 = null,
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
        strip: bool = false,
        verbose: bool = false,
        help: bool = false,

        serve: bool = false,
        port: ?[]const u8 = null,
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
            .strip = "Standalone: strip leading text before first '{'",
            .verbose = "Print errors when output formatting fails",
            .help = "Print this help message and exit",
            .serve = "Start a web server for interactive log analysis",
            .port = "Port to listen on (default 3000)",
            .www = "Path to static files to serve",
        };
    };

    pub fn parse(init: std.process.Init) !Args {
        // This is the core change: parseForCurrentProcess handles flags
        // found anywhere in the command line (interspersed). Since Zig 0.17 it
        // takes the process `Init` (it allocates results in its arena).
        const parsed = try args_lib.parseForCurrentProcess(ArgsConfig, init, args_lib.ErrorHandling.print);

        var args = Args{};

        // Maintain your logic: copy fields from the parser result to your Args struct.
        inline for (@typeInfo(ArgsConfig).@"struct".field_names) |f_name| {
            if (@hasField(Args, f_name)) {
                @field(args, f_name) = @field(parsed.options, f_name);
            }
        }

        // Positional args are now correctly separated from flags.
        if (parsed.positionals.len > 0) {
            args.file_path = parsed.positionals[0];
        }

        return args;
    }

    pub fn printHelp() !void {
        const config = ArgsConfig;

        const usage: [*:0]const u8 = "Usage: [options] [file]\n\nOptions:\n";
        _ = puts(usage);

        inline for (@typeInfo(config).@"struct".field_names) |field_name| {
            // Skip internal metadata fields
            comptime if (std.mem.eql(u8, field_name, "help")) continue;

            // Find if there's a shorthand for this field
            var short_char: ?u8 = null;
            inline for (@typeInfo(@TypeOf(config.shorthands)).@"struct".field_names) |s_name| {
                if (std.mem.eql(u8, @field(config.shorthands, s_name), field_name)) {
                    short_char = s_name[0];
                }
            }

            // Get the help message
            const msg = if (@hasField(@TypeOf(config.__messages__), field_name))
                @field(config.__messages__, field_name)
            else
                "";

            // Print the formatted line
            const fn_name: [*:0]const u8 = field_name;
            const fn_msg: [*:0]const u8 = msg;
            if (short_char) |sc| {
                const fmt: [*:0]const u8 = "  -%c, --%-12s %s\n";
                _ = printf(fmt, sc, fn_name, fn_msg);
            } else {
                const fmt: [*:0]const u8 = "      --%-12s %s\n";
                _ = printf(fmt, fn_name, fn_msg);
            }
        }
    }
};
