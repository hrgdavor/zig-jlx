const std = @import("std");

pub const Args = struct {
    config_path: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
    tail: bool = false,
    output_path: ?[]const u8 = null,
    passthrough: bool = false,
    /// Raw filter strings from -i / --include flags
    include_filters: std.ArrayListUnmanaged([]const u8) = .{},
    /// Raw filter strings from -e / --exclude flags
    exclude_filters: std.ArrayListUnmanaged([]const u8) = .{},
    /// Raw range string from -r / --range (e.g. "08:00..09:30")
    range: ?[]const u8 = null,
    /// Timezone offset string from -z / --zone (e.g. "+01:00")
    zone: ?[]const u8 = null,
    /// Value inspection string from -v / --values (e.g. "datetime:level")
    values: ?[]const u8 = null,
    /// Collect and list all unique keys found in JSON lines
    keys: bool = false,
    verbose: bool = false,

    pub const SimArgsConfig = struct {
        config: ?[]const u8 = null,
        profile: ?[]const u8 = null,
        tail: bool = false,
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

        pub const __shorts__ = .{
            .config = .c,
            .profile = .p,
            .tail = .t,
            .output = .o,
            .passthrough = .x,
            .include = .i,
            .exclude = .e,
            .range = .r,
            .zone = .z,
            .values = .v,
            .help = .h,
        };

        pub const __messages__ = .{
            .config = "Config file (required for most commands)",
            .profile = "Profile to use from config",
            .tail = "Tail the file — shows only newly appended lines",
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
        };
    };

    /// Parses command-line arguments.
    /// Uses the provided allocator natively. It's highly recommended to use an
    /// `ArenaAllocator` since `Args` does not track or free individual duplicate
    /// strings or arrays once they are created.
    pub fn parse(arena_allocator: std.mem.Allocator) !Args {
        const simargs = @import("simargs");
        var simargs_parsed = try simargs.parse(arena_allocator, SimArgsConfig, "[file]", "0.1.0");
        defer simargs_parsed.deinit();

        var args = Args{};

        if (simargs_parsed.args.config) |c| args.config_path = try arena_allocator.dupe(u8, c);
        if (simargs_parsed.args.profile) |p| args.profile = try arena_allocator.dupe(u8, p);
        if (simargs_parsed.args.output) |o| args.output_path = try arena_allocator.dupe(u8, o);
        args.tail = simargs_parsed.args.tail;
        args.passthrough = simargs_parsed.args.passthrough;
        args.keys = simargs_parsed.args.keys;
        args.verbose = simargs_parsed.args.verbose;

        if (simargs_parsed.args.include) |i| {
            try args.include_filters.append(arena_allocator, try arena_allocator.dupe(u8, i));
        }
        if (simargs_parsed.args.exclude) |e| {
            try args.exclude_filters.append(arena_allocator, try arena_allocator.dupe(u8, e));
        }

        if (simargs_parsed.args.range) |r| args.range = try arena_allocator.dupe(u8, r);
        if (simargs_parsed.args.zone) |z| args.zone = try arena_allocator.dupe(u8, z);
        if (simargs_parsed.args.values) |v| args.values = try arena_allocator.dupe(u8, v);

        if (simargs_parsed.positional_args.len > 0) {
            args.file_path = try arena_allocator.dupe(u8, simargs_parsed.positional_args[0]);
        }

        return args;
    }
};
