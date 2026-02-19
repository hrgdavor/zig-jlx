const std = @import("std");

pub const LogEntry = struct {
    timestamp: ?i64 = null,
    level: ?[]const u8 = null,
    message: ?[]const u8 = null,
    thread: ?[]const u8 = null,
    logger: ?[]const u8 = null,
    trace: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    raw_line: []const u8,

    // Original JSON object for formatting specific keys
    json_data: std.json.Value,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Parser {
        return .{ .allocator = allocator };
    }

    pub fn parseLine(self: *Parser, line: []const u8, ts_key: []const u8, level_key: []const u8, msg_key: []const u8, thread_key: []const u8, logger_key: []const u8, trace_key: []const u8) !?LogEntry {
        const json_start = std.mem.indexOfScalar(u8, line, '{') orelse return null;
        const json_text = line[json_start..];

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_text, .{}) catch return null;
        // Note: we don't deinit 'parsed' here because we want to keep the Value in LogEntry.
        // The caller will need to clean up.

        const root = parsed.value;
        if (root != .object) {
            parsed.deinit();
            return null;
        }

        var entry = LogEntry{
            .raw_line = line,
            .json_data = root,
        };

        const obj = root.object;

        if (obj.get(ts_key)) |ts_val| {
            entry.timestamp = parseTimestamp(ts_val);
        }
        if (obj.get(level_key)) |lv| {
            if (lv == .string) entry.level = lv.string;
        }
        if (obj.get(msg_key)) |m| {
            if (m == .string) entry.message = m.string;
        }
        if (obj.get(thread_key)) |t| {
            if (t == .string) entry.thread = t.string;
        }
        if (obj.get(logger_key)) |l| {
            if (l == .string) entry.logger = l.string;
        }
        if (obj.get(trace_key)) |tr| {
            if (tr == .string) entry.trace = tr.string;
        }
        // Added parsing for profile key
        if (obj.get("profile")) |p| { // Assuming "profile" is the key for profile data
            if (p == .string) entry.profile = p.string;
        }

        return entry;
    }

    fn parseTimestamp(val: std.json.Value) ?i64 {
        const ts = switch (val) {
            .integer => val.integer,
            .float => @as(i64, @intFromFloat(val.float)),
            .string => std.fmt.parseInt(i64, val.string, 10) catch return null,
            else => return null,
        };

        // Determine if ms or unix (seconds)
        // Heuristic: if > 10^10, it's likely ms (10^10 seconds is year 2286)
        return ts;
    }
};
