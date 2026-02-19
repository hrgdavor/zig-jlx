const std = @import("std");

pub const Args = struct {
    config_path: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
    use_stdin: bool = false,
    tail: bool = false,
    output_path: ?[]const u8 = null,
    raw: bool = false,

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
            } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
                args.file_path = try allocator.dupe(u8, process_args.next() orelse return error.NoFilePath);
            } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--stdin")) {
                args.use_stdin = true;
            } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tail")) {
                args.tail = true;
            } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                args.output_path = try allocator.dupe(u8, process_args.next() orelse return error.NoOutputPath);
            } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "--raw")) {
                args.raw = true;
            }
        }

        return args;
    }

    pub fn deinit(self: *Args, allocator: std.mem.Allocator) void {
        if (self.config_path) |p| allocator.free(p);
        if (self.profile) |p| allocator.free(p);
        if (self.file_path) |p| allocator.free(p);
        if (self.output_path) |p| allocator.free(p);
    }
};
