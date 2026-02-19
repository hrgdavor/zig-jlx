const std = @import("std");

pub const Profile = struct {
    name: []const u8,
    output_format: ?[]const u8 = null,
    timestamp_key: ?[]const u8 = null,
    level_key: ?[]const u8 = null,
    message_key: ?[]const u8 = null,
    thread_key: ?[]const u8 = null,
    logger_key: ?[]const u8 = null,
    trace_key: ?[]const u8 = null,
};

pub const FolderConfig = struct {
    paths: [][]const u8,
    timestamp_key: []const u8 = "ts",
    level_key: []const u8 = "level",
    message_key: []const u8 = "message",
    thread_key: []const u8 = "thread",
    logger_key: []const u8 = "logger",
    trace_key: []const u8 = "trace",
    output_format: []const u8 = "{timestamp} {level} {message}",
    profiles: std.StringHashMap(Profile),
};

pub const Config = struct {
    folders: std.array_list.AlignedManaged(FolderConfig, null),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .folders = std.array_list.AlignedManaged(FolderConfig, null).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Config) void {
        for (self.folders.items) |*f| {
            for (f.paths) |p| self.allocator.free(p);
            self.allocator.free(f.paths);
            var iter = f.profiles.valueIterator();
            while (iter.next()) |p| {
                self.allocator.free(p.name);
                if (p.output_format) |o| self.allocator.free(o);
                // ... free other keys
            }
            f.profiles.deinit();
        }
        self.folders.deinit();
    }

    pub fn load(self: *Config, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        // Simple INI-like parser for the specific structure requested
        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(&read_buf);

        var current_folder: ?*FolderConfig = null;

        while (true) {
            const line = (try reader.interface.takeDelimiter('\n')) orelse break;
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0 or trimmed[0] == ';') continue;

            if (std.mem.eql(u8, trimmed, "[folders]")) {
                try self.folders.append(.{
                    .paths = &[_][]const u8{},
                    .profiles = std.StringHashMap(Profile).init(self.allocator),
                });
                current_folder = &self.folders.items[self.folders.items.len - 1];
            } else if (current_folder) |f| {
                if (std.mem.startsWith(u8, trimmed, "paths = ")) {
                    const paths_str = trimmed["paths = ".len..];
                    var iter = std.mem.splitSequence(u8, paths_str, ",");
                    var path_list = std.array_list.AlignedManaged([]const u8, null).init(self.allocator);
                    while (iter.next()) |p| {
                        try path_list.append(try self.allocator.dupe(u8, std.mem.trim(u8, p, " ")));
                    }
                    f.paths = try path_list.toOwnedSlice();
                } else if (std.mem.indexOfAny(u8, trimmed, "=")) |idx| {
                    const key = std.mem.trim(u8, trimmed[0..idx], " ");
                    const val = std.mem.trim(u8, trimmed[idx + 1 ..], " ");
                    if (std.mem.eql(u8, key, "timestamp")) f.timestamp_key = try self.allocator.dupe(u8, val);
                    if (std.mem.eql(u8, key, "level")) f.level_key = try self.allocator.dupe(u8, val);
                    if (std.mem.eql(u8, key, "message")) f.message_key = try self.allocator.dupe(u8, val);
                    if (std.mem.eql(u8, key, "output")) f.output_format = try self.allocator.dupe(u8, val);
                }
            }
        }
    }
};
