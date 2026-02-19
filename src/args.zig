const std = @import("std");

pub const Args = struct {
    config_path: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
    tail: bool = false,
    output_path: ?[]const u8 = null,
    raw: bool = false,
    /// Raw filter strings from -i / --include flags
    include_filters: std.ArrayListUnmanaged([]const u8) = .{},
    /// Raw filter strings from -e / --exclude flags
    exclude_filters: std.ArrayListUnmanaged([]const u8) = .{},

    pub fn parse(allocator: std.mem.Allocator) !Args {
        var args = Args{};
        var process_args = try std.process.argsWithAllocator(allocator);
        defer process_args.deinit();

        // Skip executable name
        _ = process_args.next();

        while (process_args.next()) |arg| {
            if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
                args.config_path = try allocator.dupe(u8, process_args.next() orelse return error.NoConfigPath);
            } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--profile")) {
                args.profile = try allocator.dupe(u8, process_args.next() orelse return error.NoProfile);
            } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tail")) {
                args.tail = true;
            } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                args.output_path = try allocator.dupe(u8, process_args.next() orelse return error.NoOutputPath);
            } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--raw")) {
                args.raw = true;
            } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--include")) {
                const val = try allocator.dupe(u8, process_args.next() orelse return error.NoIncludeFilter);
                try args.include_filters.append(allocator, val);
            } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--exclude")) {
                const val = try allocator.dupe(u8, process_args.next() orelse return error.NoExcludeFilter);
                try args.exclude_filters.append(allocator, val);
            } else if (arg.len > 0 and arg[0] != '-') {
                // Positional argument: treat as file path
                if (args.file_path == null) {
                    args.file_path = try allocator.dupe(u8, arg);
                }
            }
        }

        return args;
    }

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        if (self.config_path) |p| allocator.free(p);
        if (self.profile) |p| allocator.free(p);
        if (self.file_path) |p| allocator.free(p);
        if (self.output_path) |p| allocator.free(p);
        for (self.include_filters.items) |s| allocator.free(s);
        self.include_filters.deinit(allocator);
        for (self.exclude_filters.items) |s| allocator.free(s);
        self.exclude_filters.deinit(allocator);
    }
};
