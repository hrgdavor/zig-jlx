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
    message_expand: ?[]const u8 = null,
    /// Raw filter strings parsed from config (include = ...)
    include_filters: [][]const u8 = &[_][]const u8{},
    /// Raw filter strings parsed from config (exclude = ...)
    exclude_filters: [][]const u8 = &[_][]const u8{},
};

pub const FolderConfig = struct {
    paths: [][]const u8,
    timestamp_key: []const u8 = "ts",
    level_key: []const u8 = "level",
    message_key: []const u8 = "message",
    thread_key: []const u8 = "thread",
    logger_key: []const u8 = "logger",
    trace_key: []const u8 = "trace",
    message_expand: ?[]const u8 = null,
    output_format: []const u8 = "{timestamp} {level} {message}",
    profiles: std.StringHashMap(Profile),
    /// Raw filter strings from config (include = ...)
    include_filters: [][]const u8 = &[_][]const u8{},
    /// Raw filter strings from config (exclude = ...)
    exclude_filters: [][]const u8 = &[_][]const u8{},
};

pub const Config = struct {
    port: ?u16 = null,
    www: ?[]const u8 = null,
    folders: std.ArrayListUnmanaged(FolderConfig) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Config {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Config) void {
        self.folders.deinit(self.allocator);
    }

    pub fn load(self: *Config, path: []const u8) !void {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.debug.print("Critical error: could not open {s} ({})", .{ path, err });
            std.process.exit(1);
        };
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        try self.parse(content);
    }

    pub fn parse(self: *Config, content: []const u8) !void {
        var fbs = std.io.fixedBufferStream(content);
        var reader = fbs.reader();

        var current_folder: ?*FolderConfig = null;
        var current_profile: ?*Profile = null;

        var buf: [4096]u8 = undefined;
        while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\t");
            if (trimmed.len == 0 or trimmed[0] == ';') continue;

            if (std.mem.eql(u8, trimmed, "[folders]")) {
                try self.folders.append(self.allocator, .{
                    .paths = &[_][]const u8{},
                    .profiles = std.StringHashMap(Profile).init(self.allocator),
                });
                current_folder = &self.folders.items[self.folders.items.len - 1];
                current_profile = null;
            } else if (std.mem.startsWith(u8, trimmed, "[profile.") and trimmed[trimmed.len - 1] == ']') {
                if (current_folder) |f| {
                    const pname = trimmed[9 .. trimmed.len - 1];
                    const pname_dupe = try self.allocator.dupe(u8, pname);
                    try f.profiles.put(pname_dupe, .{ .name = pname_dupe });
                    current_profile = f.profiles.getPtr(pname_dupe).?;
                }
            } else {
                if (std.mem.indexOfAny(u8, trimmed, "=")) |idx| {
                    const key = std.mem.trim(u8, trimmed[0..idx], " ");
                    const val = std.mem.trim(u8, trimmed[idx + 1 ..], " ");

                    if (current_profile) |p| {
                        if (std.mem.eql(u8, key, "output")) p.output_format = try self.allocator.dupe(u8, val);
                        if (std.mem.eql(u8, key, "timestamp")) p.timestamp_key = try self.allocator.dupe(u8, val);
                        if (std.mem.eql(u8, key, "level")) p.level_key = try self.allocator.dupe(u8, val);
                        if (std.mem.eql(u8, key, "message")) p.message_key = try self.allocator.dupe(u8, val);
                        if (std.mem.eql(u8, key, "message_expand")) p.message_expand = try self.allocator.dupe(u8, val);
                        if (std.mem.eql(u8, key, "include")) p.include_filters = try parseFilterList(self.allocator, val);
                        if (std.mem.eql(u8, key, "exclude")) p.exclude_filters = try parseFilterList(self.allocator, val);
                    } else if (current_folder) |f| {
                        if (std.mem.eql(u8, key, "paths")) {
                            var piter = std.mem.splitSequence(u8, val, ",");
                            var path_list = std.ArrayListUnmanaged([]const u8){};
                            while (piter.next()) |path_item| {
                                try path_list.append(self.allocator, try self.allocator.dupe(u8, std.mem.trim(u8, path_item, " ")));
                            }
                            f.paths = try path_list.toOwnedSlice(self.allocator);
                        } else if (std.mem.eql(u8, key, "timestamp")) {
                            f.timestamp_key = try self.allocator.dupe(u8, val);
                        } else if (std.mem.eql(u8, key, "level")) {
                            f.level_key = try self.allocator.dupe(u8, val);
                        } else if (std.mem.eql(u8, key, "message")) {
                            f.message_key = try self.allocator.dupe(u8, val);
                        } else if (std.mem.eql(u8, key, "message_expand")) {
                            f.message_expand = try self.allocator.dupe(u8, val);
                        } else if (std.mem.eql(u8, key, "output")) {
                            f.output_format = try self.allocator.dupe(u8, val);
                        } else if (std.mem.eql(u8, key, "include")) {
                            f.include_filters = try parseFilterList(self.allocator, val);
                        } else if (std.mem.eql(u8, key, "exclude")) {
                            f.exclude_filters = try parseFilterList(self.allocator, val);
                        }
                    } else {
                        // Top-level (not in any [folders] or [profile])
                        if (std.mem.eql(u8, key, "port")) {
                            self.port = std.fmt.parseInt(u16, val, 10) catch |err| {
                                std.log.warn("Invalid port in config: {s} ({})", .{ val, err });
                                continue;
                            };
                        } else if (std.mem.eql(u8, key, "www")) {
                            self.www = try self.allocator.dupe(u8, val);
                        }
                    }
                }
            }
        }
    }
};

/// Parse a comma-separated list of filter strings into an owned slice of duped strings.
fn parseFilterList(allocator: std.mem.Allocator, val: []const u8) ![][]const u8 {
    var list = std.ArrayListUnmanaged([]const u8){};
    var iter = std.mem.splitSequence(u8, val, ",");
    while (iter.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " \t");
        if (trimmed.len > 0) {
            try list.append(allocator, try allocator.dupe(u8, trimmed));
        }
    }
    return list.toOwnedSlice(allocator);
}
