const std = @import("std");

pub const LogEntry = struct {
    parsed: std.json.Parsed(std.json.Value),
    raw_line: []const u8,
    timestamp: ?i64 = null, // Cache for formatting convenience

    pub fn deinit(self: *LogEntry, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.parsed.deinit();
    }
};

pub const Parser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator };
    }

    pub fn parseLine(self: *Parser, line: []const u8, ts_key: []const u8) !?LogEntry {
        const json_start = std.mem.indexOfScalar(u8, line, '{') orelse return null;
        const json_text = std.mem.trim(u8, line[json_start..], " \r\t");

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_text, .{}) catch return null;
        errdefer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            parsed.deinit();
            return null;
        }

        var entry = LogEntry{
            .parsed = parsed,
            .raw_line = line,
        };

        if (root.object.get(ts_key)) |ts_val| {
            entry.timestamp = parseTimestamp(ts_val);
        }

        return entry;
    }

    fn parseTimestamp(val: std.json.Value) ?i64 {
        return switch (val) {
            .integer => val.integer,
            .float => @as(i64, @intFromFloat(val.float)),
            .string => std.fmt.parseInt(i64, val.string, 10) catch {
                // Try parsing as ISO string? For now just return null
                return null;
            },
            else => null,
        };
    }
};
