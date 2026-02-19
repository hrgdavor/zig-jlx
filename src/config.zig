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
    output_format: []const u8 = "{timestamp} {level} {message}",
    profiles: std.StringHashMap(Profile),
    /// Raw filter strings from config (include = ...)
    include_filters: [][]const u8 = &[_][]const u8{},
    /// Raw filter strings from config (exclude = ...)
    exclude_filters: [][]const u8 = &[_][]const u8{},

    // Track duped strings for deinit
    timestamp_key_dupe: ?[]const u8 = null,
    level_key_dupe: ?[]const u8 = null,
    message_key_dupe: ?[]const u8 = null,
    output_format_dupe: ?[]const u8 = null,
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
            if (f.paths.len > 0) self.allocator.free(f.paths);
            if (f.timestamp_key_dupe) |k| self.allocator.free(k);
            if (f.level_key_dupe) |k| self.allocator.free(k);
            if (f.message_key_dupe) |k| self.allocator.free(k);
            if (f.output_format_dupe) |k| self.allocator.free(k);
            for (f.include_filters) |s| self.allocator.free(s);
            if (f.include_filters.len > 0) self.allocator.free(f.include_filters);
            for (f.exclude_filters) |s| self.allocator.free(s);
            if (f.exclude_filters.len > 0) self.allocator.free(f.exclude_filters);

            var iter = f.profiles.iterator();
            while (iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                const p = entry.value_ptr.*;
                if (p.output_format) |o| self.allocator.free(o);
                if (p.timestamp_key) |o| self.allocator.free(o);
                if (p.level_key) |o| self.allocator.free(o);
                if (p.message_key) |o| self.allocator.free(o);
                if (p.thread_key) |o| self.allocator.free(o);
                if (p.logger_key) |o| self.allocator.free(o);
                if (p.trace_key) |o| self.allocator.free(o);
                for (p.include_filters) |s| self.allocator.free(s);
                if (p.include_filters.len > 0) self.allocator.free(p.include_filters);
                for (p.exclude_filters) |s| self.allocator.free(s);
                if (p.exclude_filters.len > 0) self.allocator.free(p.exclude_filters);
            }
            f.profiles.deinit();
        }
        self.folders.deinit();
    }

    pub fn load(self: *Config, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(&read_buf);

        var current_folder: ?*FolderConfig = null;
        var current_profile: ?*Profile = null;

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
                current_profile = null;
            } else if (std.mem.startsWith(u8, trimmed, "[profile.") and trimmed[trimmed.len - 1] == ']') {
                if (current_folder) |f| {
                    const pname = trimmed[9 .. trimmed.len - 1];
                    const pname_dupe = try self.allocator.dupe(u8, pname);
                    try f.profiles.put(pname_dupe, .{ .name = pname_dupe });
                    current_profile = f.profiles.getPtr(pname_dupe).?;
                }
            } else if (current_folder) |f| {
                if (std.mem.indexOfAny(u8, trimmed, "=")) |idx| {
                    const key = std.mem.trim(u8, trimmed[0..idx], " ");
                    const val = std.mem.trim(u8, trimmed[idx + 1 ..], " ");

                    if (current_profile) |p| {
                        if (std.mem.eql(u8, key, "output")) p.output_format = try self.allocator.dupe(u8, val);
                        if (std.mem.eql(u8, key, "timestamp")) p.timestamp_key = try self.allocator.dupe(u8, val);
                        if (std.mem.eql(u8, key, "level")) p.level_key = try self.allocator.dupe(u8, val);
                        if (std.mem.eql(u8, key, "message")) p.message_key = try self.allocator.dupe(u8, val);
                        if (std.mem.eql(u8, key, "include")) p.include_filters = try parseFilterList(self.allocator, val);
                        if (std.mem.eql(u8, key, "exclude")) p.exclude_filters = try parseFilterList(self.allocator, val);
                    } else {
                        if (std.mem.eql(u8, key, "paths")) {
                            var iter = std.mem.splitSequence(u8, val, ",");
                            var path_list = std.array_list.AlignedManaged([]const u8, null).init(self.allocator);
                            while (iter.next()) |p| {
                                try path_list.append(try self.allocator.dupe(u8, std.mem.trim(u8, p, " ")));
                            }
                            f.paths = try path_list.toOwnedSlice();
                        } else if (std.mem.eql(u8, key, "timestamp")) {
                            f.timestamp_key = try self.allocator.dupe(u8, val);
                            f.timestamp_key_dupe = f.timestamp_key;
                        } else if (std.mem.eql(u8, key, "level")) {
                            f.level_key = try self.allocator.dupe(u8, val);
                            f.level_key_dupe = f.level_key;
                        } else if (std.mem.eql(u8, key, "message")) {
                            f.message_key = try self.allocator.dupe(u8, val);
                            f.message_key_dupe = f.message_key;
                        } else if (std.mem.eql(u8, key, "output")) {
                            f.output_format = try self.allocator.dupe(u8, val);
                            f.output_format_dupe = f.output_format;
                        } else if (std.mem.eql(u8, key, "include")) {
                            f.include_filters = try parseFilterList(self.allocator, val);
                        } else if (std.mem.eql(u8, key, "exclude")) {
                            f.exclude_filters = try parseFilterList(self.allocator, val);
                        }
                    }
                }
            }
        }
    }
};

/// Parse a comma-separated list of filter strings into an owned slice of duped strings.
/// Caller is responsible for freeing each string and the slice itself.
fn parseFilterList(allocator: std.mem.Allocator, val: []const u8) ![][]const u8 {
    var list = std.array_list.AlignedManaged([]const u8, null).init(allocator);
    errdefer list.deinit();
    var iter = std.mem.splitSequence(u8, val, ",");
    while (iter.next()) |item| {
        const trimmed = std.mem.trim(u8, item, " \t");
        if (trimmed.len > 0) {
            try list.append(try allocator.dupe(u8, trimmed));
        }
    }
    return list.toOwnedSlice();
}
